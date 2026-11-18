# shellcheck shell=bash
# Sourced by sync.sh and kb-sync.sh: Open WebUI URL, admin API key and the api() helper.
URL=${OWUI_URL:-http://127.0.0.1:3000}
KEY_FILE=${KEY_FILE:-/etc/open-webui-sync.env}
KEY=$(sed -n 's/^OWUI_API_KEY=//p' "$KEY_FILE" 2>/dev/null | tail -n 1 || true)

# api METHOD PATH [JSON]: prints the response body, fails on an HTTP error.
api() {
  local args=(-fsS -X "$1" -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json')
  [ $# -ge 3 ] && args+=(--data-binary "$3")
  curl "${args[@]}" "$URL$2"
}
