#!/bin/bash
# Deploys the latest `live` commit. Before deploying it backs up the data. If the app is not
# healthy afterwards, it restores the previous commit and data and exits 1.
set -euo pipefail
REPO_DIR=${REPO_DIR:-/opt/node-kit}
DATA_DIR=${DATA_DIR:-/srv/open-webui}
BACKUP_DIR=${BACKUP_DIR:-/var/backups/open-webui}
HEALTH_URL=${HEALTH_URL:-http://127.0.0.1:3000/health}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-300}
KEEP_BACKUPS=${KEEP_BACKUPS:-5}
BRANCH=${BRANCH:-live}
KEY_FILE=${KEY_FILE:-/etc/open-webui-sync.env}
STATE_DIR=${STATE_DIR:-/var/lib/open-webui-update}
KB_KEY=${KB_KEY:-/etc/advisor-kb-deploy-key}
KB_ROOT=${KB_ROOT:-/var/lib/open-webui-kb}
export KB_KEY KB_ROOT
# KB_REPO, KNOWN_HOSTS and KB_SSH_USER name the git server; the systemd unit is installed once, so they live in this file.
KB_ENV=${KB_ENV:-/etc/advisor-kb.env}
# shellcheck disable=SC1090  # operator-written file, path set by KB_ENV
if [ -r "$KB_ENV" ]; then set -a; . "$KB_ENV"; set +a; fi
COMPOSE=(docker compose -f "$REPO_DIR/app/compose.yaml")

# Every run ends with a telemetry report, rollbacks included; it never changes the exit code.
DEPLOY=none SYNC=unchanged KB=skipped
# shellcheck disable=SC2317  # called by the trap
report() {
  local rc=$?
  timeout 120 bash "$REPO_DIR/app/telemetry.sh" "$DEPLOY" "$SYNC" "$KB" "$rc" || echo "Telemetry failed." >&2
  exit "$rc"
}
trap report EXIT

# The advisor config is not part of the deploy: a failed sync is logged, never rolled back.
# Fingerprint = advisor files + key file + the pulled knowledge manifest; empty without a key. The
# stamp holds the fingerprint of the last successful sync, so the timer retries a failed sync and
# picks up a key added later or new knowledge.
fingerprint() {
  [ -s "$KEY_FILE" ] || return 0
  { find "$REPO_DIR/app/advisor" -type f | sort | xargs sha256sum | sed "s# $REPO_DIR/# #"; sha256sum < "$KEY_FILE"
    sha256sum < "$KB_ROOT/current/MANIFEST.json" 2>/dev/null || true; } | sha256sum
}
sync_advisor() {
  local fp; fp=$(fingerprint)
  if bash "$REPO_DIR/app/advisor/sync.sh"; then
    SYNC=ok
    if [ -n "$fp" ]; then mkdir -p "$STATE_DIR"; echo "$fp" > "$STATE_DIR/advisor-sync.stamp"; fi
  else
    SYNC=failed
    echo "Advisor sync failed; the deploy stands." >&2
  fi
}

# The knowledge comes from the advisor-kb repo, not from this one. A failed pull keeps the previous knowledge.
pull_kb() {
  [ -s "$KB_KEY" ] || return 0
  if bash "$REPO_DIR/app/advisor/kb-pull.sh"; then KB=ok; else
    KB=failed; echo "Knowledge pull failed; keeping the previous knowledge." >&2
  fi
}

cd "$REPO_DIR"
pull_kb
git fetch -q origin "$BRANCH"
OLD=$(git rev-parse HEAD)
NEW=$(git rev-parse "origin/$BRANCH")
if [ "$OLD" = "$NEW" ] && [ "${FORCE:-0}" != 1 ]; then
  fp=$(fingerprint)
  if [ -n "$fp" ] && [ "$fp" != "$(cat "$STATE_DIR/advisor-sync.stamp" 2>/dev/null || true)" ]; then sync_advisor; fi
  exit 0
fi

healthy() {
  local waited=0
  until curl -fsS -o /dev/null "$HEALTH_URL"; do
    [ "$waited" -ge "$HEALTH_TIMEOUT" ] && return 1
    sleep 5; waited=$((waited + 5))
  done
}

mkdir -p "$BACKUP_DIR" "$DATA_DIR"
BACKUP="$BACKUP_DIR/$(date +%Y%m%d-%H%M%S)-${OLD:0:8}.tgz"
"${COMPOSE[@]}" stop || true
tar czf "$BACKUP" -C "$DATA_DIR" .
find "$BACKUP_DIR" -name '*.tgz' -printf '%T@ %p\n' | sort -rn | tail -n +$((KEEP_BACKUPS + 1)) | cut -d' ' -f2- | xargs -r rm -f

git merge -q --ff-only "origin/$BRANCH"
"${COMPOSE[@]}" pull -q
"${COMPOSE[@]}" up -d
if healthy; then
  DEPLOY=deployed
  echo "Deployed ${NEW:0:8}."
  sync_advisor
  exit 0
fi

DEPLOY=rolled-back
echo "Deploy of ${NEW:0:8} is unhealthy. Restoring ${OLD:0:8}." >&2
"${COMPOSE[@]}" down || true
git reset -q --hard "$OLD"
find "$DATA_DIR" -mindepth 1 -delete
tar xzf "$BACKUP" -C "$DATA_DIR"
"${COMPOSE[@]}" up -d
exit 1
