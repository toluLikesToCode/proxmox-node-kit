#!/bin/bash
# Posts one status message to ntfy after every update check, and an alert when the set of problems
# changes. Usage: telemetry.sh DEPLOY SYNC KB RC. Optional NAME=value overrides in $TELEMETRY_ENV
# (NTFY_URL, NTFY_TOKEN, NTFY_TOPIC, NTFY_ALERT_TOPIC; TELEMETRY=off turns it off).
# Never fails the caller.
set -uo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
TELEMETRY_ENV=${TELEMETRY_ENV:-/etc/advisor-telemetry.env}
# shellcheck disable=SC1090  # operator-written file, path set by TELEMETRY_ENV
if [ -r "$TELEMETRY_ENV" ]; then set -a; . "$TELEMETRY_ENV"; set +a; fi
[ "${TELEMETRY:-on}" = off ] && exit 0
NTFY_URL=${NTFY_URL:-https://ntfy.jactus.net}
TOPIC=${NTFY_TOPIC:-advisor-telemetry}
ALERT_TOPIC=${NTFY_ALERT_TOPIC:-advisor-alerts}
STATE_DIR=${STATE_DIR:-/var/lib/open-webui-update}
REPO_DIR=${REPO_DIR:-/opt/node-kit}
DATA_DIR=${DATA_DIR:-/srv/open-webui}
KB_ROOT=${KB_ROOT:-/var/lib/open-webui-kb}
HEALTH_URL=${HEALTH_URL:-http://127.0.0.1:3000/health}
DEPLOY=${1:-unknown} SYNC=${2:-unknown} KB=${3:-unknown} RC=${4:-0}
# shellcheck source=advisor/lib.sh
. "$DIR/advisor/lib.sh"
command -v jq >/dev/null || { echo "telemetry skipped: jq missing" >&2; exit 0; }

post() {
  local topic=$1; shift
  local auth=(); [ -n "${NTFY_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $NTFY_TOKEN")
  curl -fsS --max-time 30 -o /dev/null "${auth[@]}" "$@" "$NTFY_URL/$topic"
}

health=down; curl -fsS --max-time 10 -o /dev/null "$HEALTH_URL" && health=up
owui=$(curl -fsS --max-time 10 "$URL/api/version" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
model=unknown
if [ -n "$KEY" ]; then
  if api GET "/api/v1/models/model?id=$(jq -r .id "$DIR/advisor/model.json")" >/dev/null 2>&1; then model=present; else model=missing; fi
fi
kit=$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)
kb=$(basename "$(readlink "$KB_ROOT/current" 2>/dev/null || echo none)")
mem_mb() { awk -v k="$1:" '$1 == k {print int($2 / 1024)}' /proc/meminfo 2>/dev/null; }
free_gb() { df -Pk "$1" 2>/dev/null | awk 'NR == 2 {print int($4 / 1048576)}'; }

status=$(jq -nc --arg host "$(hostname)" --arg kit "$kit" --arg owui "${owui:-unknown}" --arg deploy "$DEPLOY" \
  --arg sync "$SYNC" --arg kbpull "$KB" --arg kb "${kb:0:12}" --argjson rc "$RC" --arg health "$health" --arg model "$model" \
  --arg load "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)" --arg mem_total "$(mem_mb MemTotal)" --arg mem_free "$(mem_mb MemAvailable)" \
  --arg disk_free "$(free_gb /)" --arg data_free "$(free_gb "$DATA_DIR")" --arg uptime "$(cut -d. -f1 /proc/uptime 2>/dev/null)" \
  '{host: $host, kit: $kit, owui: $owui, deploy: $deploy, sync: $sync, kb_pull: $kbpull, kb: $kb, exit: $rc, health: $health,
    model: $model, load: $load, mem_total_mb: $mem_total, mem_free_mb: $mem_free, disk_free_gb: $disk_free,
    data_free_gb: $data_free, uptime_s: $uptime}')
post "$TOPIC" -H "Title: advisor status" -H "Tags: status" --data-binary "$status" || echo "telemetry: status post failed" >&2

problems=()
[ "$RC" -ne 0 ] && problems+=("update exited $RC")
[ "$DEPLOY" = rolled-back ] && problems+=("deploy rolled back")
[ "$SYNC" = failed ] && problems+=("settings sync failed")
[ "$KB" = failed ] && problems+=("knowledge pull failed")
[ "$health" = down ] && problems+=("Open WebUI is down")
[ "$model" = missing ] && problems+=("advisor model missing")
now=$(IFS=';'; echo "${problems[*]}")
was=$(cat "$STATE_DIR/telemetry.alert" 2>/dev/null || true)
[ "$now" = "$was" ] && exit 0
if [ -n "$now" ]; then
  post "$ALERT_TOPIC" -H "Title: Advisor problem" -H "Priority: high" -H "Tags: warning" --data-binary "${now//;/, } (kit $kit)"
else
  post "$ALERT_TOPIC" -H "Title: Advisor OK again" -H "Tags: white_check_mark" --data-binary "All checks pass (kit $kit)"
fi && mkdir -p "$STATE_DIR" && printf '%s' "$now" > "$STATE_DIR/telemetry.alert"
exit 0
