#!/bin/bash
# Pushes the advisor model, its saved prompts and the cost settings into Open WebUI through its
# REST API. Safe to run repeatedly. Needs an admin API key in $KEY_FILE; without one it explains
# how to create it and exits 0.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
URL=${OWUI_URL:-http://127.0.0.1:3000}
KEY_FILE=${KEY_FILE:-/etc/open-webui-sync.env}
TASK_MODEL=${TASK_MODEL:-deepseek/deepseek-v4.1-flash-1017}

KEY=$(sed -n 's/^OWUI_API_KEY=//p' "$KEY_FILE" 2>/dev/null | tail -n 1 || true)
if [ -z "$KEY" ]; then
  cat <<MSG
advisor sync skipped: no API key in $KEY_FILE.
In Open WebUI create one (Settings > Account > API Keys), then on the Proxmox node run:
  pct exec 402 -- sh -c 'umask 077; echo OWUI_API_KEY=<key> > $KEY_FILE'
MSG
  exit 0
fi
command -v jq >/dev/null || apt-get install -yq jq >/dev/null

# api METHOD PATH [JSON]: prints the response body, fails on an HTTP error.
api() {
  local args=(-fsS -X "$1" -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json')
  [ $# -ge 3 ] && args+=(--data-binary "$3")
  curl "${args[@]}" "$URL$2"
}

# Model: import is an upsert by id.
payload=$(jq -c --rawfile system "$DIR/system-prompt.md" '{models: [.params.system = $system]}' "$DIR/model.json")
api POST /api/v1/models/import "$payload" >/dev/null
echo "synced model $(jq -r .id "$DIR/model.json")"

# Prompts: create, or update by id when the command exists.
existing=$(api GET /api/v1/prompts/)
for file in "$DIR"/prompts/*.md; do
  command=$(sed -n '2s/^command: //p' "$file")
  name=$(sed -n '3s/^name: //p' "$file")
  body=$(sed '1,4d' "$file")
  form=$(jq -nc --arg command "$command" --arg name "$name" --arg content "$body" \
    '{command: $command, name: $name, content: $content}')
  id=$(jq -r --arg command "$command" '[.[] | select(.command == $command) | .id][0] // empty' <<<"$existing")
  if [ -n "$id" ]; then
    api POST "/api/v1/prompts/id/$id/update" "$form" >/dev/null
  else
    api POST /api/v1/prompts/create "$form" >/dev/null
  fi
  echo "synced prompt /$command"
done

# Cost settings. Open WebUI keeps these in its database after the first start, so the
# environment in compose.yaml only seeds a fresh install; this applies them to an existing one.
tasks=$(api GET /api/v1/tasks/config | jq -c --arg model "$TASK_MODEL" '
  .ENABLE_TAGS_GENERATION = false | .ENABLE_FOLLOW_UP_GENERATION = false
  | .ENABLE_AUTOCOMPLETE_GENERATION = false | .ENABLE_SEARCH_QUERY_GENERATION = false
  | .ENABLE_RETRIEVAL_QUERY_GENERATION = false | .ENABLE_TITLE_GENERATION = true
  | .TASK_MODEL_EXTERNAL = $model')
api POST /api/v1/tasks/config/update "$tasks" >/dev/null
models=$(api GET /api/v1/configs/models | jq -c --arg id "$(jq -r .id "$DIR/model.json")" '.DEFAULT_MODELS = $id')
api POST /api/v1/configs/models "$models" >/dev/null
echo "synced settings"
