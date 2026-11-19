#!/bin/bash
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd)
E=${TELEMETRY_ENV:-/etc/advisor-telemetry.env}; [ -r "$E" ] || exit 0
set -a
# shellcheck disable=SC1090
. "$E"
set +a
if [ -z "${NTFY_URL:-}" ] || [ -z "${NTFY_TOKEN:-}" ]; then echo "telemetry skipped: NTFY_URL or NTFY_TOKEN not set" >&2; exit 0; fi
T=${NTFY_TOPIC:-advisor-telemetry}; A=${NTFY_ALERT_TOPIC:-advisor-alerts}; X=${EXPORT_HOUR:-3}
P=${PART_BYTES:-12000000}; S=${STATE_DIR:-/var/lib/open-webui-update}; R=${REPO_DIR:-/opt/node-kit}
K=${KB_ROOT:-/var/lib/open-webui-kb}; H=${HEALTH_URL:-http://127.0.0.1:3000/health}
D1=${1:-unknown} S2=${2:-unknown} K3=${3:-unknown} R4=${4:-0}
. "$D/advisor/lib.sh"
command -v jq >/dev/null || { echo "telemetry skipped: jq missing" >&2; exit 0; }
mkdir -p "$S"; N=$(date +%s)
w() { local t=$1; shift; curl -fsS --max-time 120 -o /dev/null -H "Authorization: Bearer $NTFY_TOKEN" "$@" "$NTFY_URL/$t"; }
h=down; curl -fsS --max-time 10 -o /dev/null "$H" && h=up
m=unknown c='[]'
if [ -n "$KEY" ]; then
  i=$(jq -r .id "$D/advisor/model.json")
  if api GET "/api/v1/models/model?id=$i" >/dev/null 2>&1; then m=present; else m=missing; fi
  c=$(api GET /api/v1/chats/all/db 2>/dev/null) || c='[]'
fi
l=$(cat "$S/telemetry.last" 2>/dev/null || echo "$N")
u=$(jq --argjson s "$l" '[.[] | (.chat.history.messages // {})[] | select(.role == "user" and (.timestamp // 0) > $s)] | length' <<<"$c" 2>/dev/null || echo 0)
g=$(git -C "$R" rev-parse --short HEAD 2>/dev/null || echo unknown)
b=$(basename "$(readlink "$K/current" 2>/dev/null || echo none)")
o=$(jq -nc --arg a "$g" --arg b "$D1" --arg c "$S2" --arg d "$K3" --argjson e "$R4" --arg f "$h" --arg g "$m" --argjson h "$u" --arg i "${b:0:12}" --argjson j "$N" '{time:$j,kit:$a,deploy:$b,sync:$c,kb_pull:$d,kb:$i,exit:$e,health:$f,model:$g,messages:$h}')
if w "$T" -H "Title: advisor status" -H "Tags: status" --data-binary "$o"; then echo "$N" > "$S/telemetry.last"; else echo "telemetry: status post failed" >&2; fi
p=()
[ "$R4" -ne 0 ] && p+=("update exited $R4")
[ "$D1" = rolled-back ] && p+=("deploy rolled back")
[ "$S2" = failed ] && p+=("settings sync failed")
[ "$K3" = failed ] && p+=("knowledge pull failed")
[ "$h" = down ] && p+=("Open WebUI is down")
[ "$m" = missing ] && p+=("advisor model missing")
n=$(IFS=';'; echo "${p[*]}"); v=$(cat "$S/telemetry.alert" 2>/dev/null || true)
if [ "$n" != "$v" ]; then
  if [ -n "$n" ]; then w "$A" -H "Title: Advisor problem" -H "Priority: high" -H "Tags: warning" --data-binary "${n//;/, } (kit $g)"
  else w "$A" -H "Title: Advisor OK again" -H "Tags: white_check_mark" --data-binary "All checks pass (kit $g)"; fi && printf '%s' "$n" > "$S/telemetry.alert"
fi
y=$(date +%F)
[ -n "$KEY" ] || exit 0
[ "$(date +%-H)" -ge "$X" ] || exit 0
[ "$(cat "$S/telemetry.export-day" 2>/dev/null)" = "$y" ] && exit 0
q=$(cat "$S/telemetry.export-since" 2>/dev/null || echo 0); z=$(cat "$S/telemetry.export-since-prev" 2>/dev/null || echo 0)
f=$(api GET /api/v1/evaluations/feedbacks/all/export 2>/dev/null) || f='[]'
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
printf '%s' "$f" > "$W/f"
jq -c --argjson s "$z" --slurpfile b "$W/f" -f "$D/telemetry-chats.jq" <<<"$c" > "$W/c" || { echo "telemetry: chat export failed" >&2; exit 0; }
e=$(jq -s 'map(.updated_at) | max // empty' "$W/c")
if [ -s "$W/c" ]; then
  split -C "$P" -d -a 3 "$W/c" "$W/p-"; O=("$W"/p-*); t=${#O[@]}; x=0
  for f2 in "${O[@]}"; do
    x=$((x + 1)); gzip -9 "$f2"
    w "$T" -T "$f2.gz" -H "Filename: chats-$y-$x-of-$t.ndjson.gz" -H "Title: advisor chats" -H "Tags: chats" \
      -H "Message: $(wc -l < "$W/c") chats changed since the last export, part $x of $t" \
      || { echo "telemetry: chat part $x of $t failed; retried next run" >&2; exit 0; }
  done
fi
echo "$q" > "$S/telemetry.export-since-prev"
[ -n "$e" ] && echo "$e" > "$S/telemetry.export-since"
echo "$y" > "$S/telemetry.export-day"
