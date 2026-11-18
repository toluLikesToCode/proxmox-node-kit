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
COMPOSE=(docker compose -f "$REPO_DIR/app/compose.yaml")

cd "$REPO_DIR"
git fetch -q origin "$BRANCH"
OLD=$(git rev-parse HEAD)
NEW=$(git rev-parse "origin/$BRANCH")
if [ "$OLD" = "$NEW" ] && [ "${FORCE:-0}" != 1 ]; then exit 0; fi

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
  echo "Deployed ${NEW:0:8}."; exit 0
fi

echo "Deploy of ${NEW:0:8} is unhealthy. Restoring ${OLD:0:8}." >&2
"${COMPOSE[@]}" down || true
git reset -q --hard "$OLD"
find "$DATA_DIR" -mindepth 1 -delete
tar xzf "$BACKUP" -C "$DATA_DIR"
"${COMPOSE[@]}" up -d
exit 1
