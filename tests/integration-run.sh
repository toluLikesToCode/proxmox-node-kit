#!/bin/bash
# Runs inside the test container of tests/integration.sh: Open WebUI is at owui:8080 and a stub
# OpenRouter at upstream:8000.
# shellcheck disable=SC2016  # jq programs expand in their own shell
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
ok()    { echo "ok   - $1"; PASS=$((PASS+1)); }
bad()   { echo "FAIL - $1"; FAIL=$((FAIL+1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
quiet() { "$@" >/dev/null; }
export OWUI_URL=http://owui:8080
M=app/advisor/model.json; SP=app/advisor/system-prompt.md

waited=0
until curl -s -f -o /dev/null "$OWUI_URL/health"; do
  [ "$waited" -ge 300 ] && { echo "Open WebUI ($IMAGE) did not become healthy" >&2; exit 1; }
  sleep 3; waited=$((waited + 3))
done

# First admin account, then an API key for it.
PASSWORD=$(head -c 12 /dev/urandom | base64)
jwt=$(curl -fsS -H 'Content-Type: application/json' "$OWUI_URL/api/v1/auths/signup" \
  -d "$(jq -nc --arg p "$PASSWORD" '{name: "Admin", email: "admin@example.com", password: $p}')" | jq -r .token)
K=$(mktemp -d)
curl -fsS -X POST -H "Authorization: Bearer $jwt" "$OWUI_URL/api/v1/auths/api_key" | jq -r '"OWUI_API_KEY=" + .api_key' > "$K/key.env"
chmod 600 "$K/key.env"
KEY=$(sed -n 's/^OWUI_API_KEY=//p' "$K/key.env")
get() { curl -fsS -H "Authorization: Bearer $KEY" "$OWUI_URL$1"; }
run_sync() { KEY_FILE="$K/key.env" bash app/advisor/sync.sh; }

check "before the sync: Open WebUI has no advisor and the wrong settings" quiet bash -c \
  'curl -fsS -H "Authorization: Bearer $1" "$2/api/v1/tasks/config" | jq -e ".ENABLE_TAGS_GENERATION == true and .ENABLE_TITLE_GENERATION == false and .TASK_MODEL_EXTERNAL != \"openai/gpt-oss-20b\"" && [ "$(curl -fsS -H "Authorization: Bearer $1" "$2/api/v1/models/list" | jq ".items | length")" = 0 ]' _ "$KEY" "$OWUI_URL"
run_sync >"$K/out" 2>&1; RC=$?
check "sync exits 0 against the real Open WebUI" test "$RC" -eq 0
[ "$RC" -eq 0 ] || cat "$K/out"

# What Open WebUI holds now. Run twice, so the second pass proves idempotence.
verify() {
  local n=$1
  check "$n: one advisor model" bash -c '[ "$(curl -fsS -H "Authorization: Bearer $1" "$2/api/v1/models/list" | jq "[.items[] | select(.id == \"homelab-advisor\")] | length")" = 1 ]' _ "$KEY" "$OWUI_URL"
  check "$n: model has the system prompt, native function calling and the answer cap" bash -c '
    get() { curl -fsS -H "Authorization: Bearer $1" "$2/api/v1/models/list"; }
    [ "$(get "$1" "$2" | jq -c --rawfile s "$3" --slurpfile m "$4" ".items[] | select(.id == \"homelab-advisor\") | [.base_model_id, .params.system, .params.function_calling, .params.max_tokens, .is_active] == [\$m[0].base_model_id, \$s, \"native\", \$m[0].params.max_tokens, true]")" = true ]' _ "$KEY" "$OWUI_URL" "$SP" "$M"
  check "$n: the three prompts exist once each, with the file contents" bash -c '
    prompts=$(curl -fsS -H "Authorization: Bearer $1" "$2/api/v1/prompts/")
    [ "$(jq -r "[.[] | .command] | sort | join(\" \")" <<<"$prompts")" = "diagnose plan-change review" ] &&
    for f in app/advisor/prompts/*.md; do
      c=$(sed -n "2s/^command: //p" "$f"); want=$(sed "1,4d" "$f")
      [ "$(jq -r --arg c "$c" ".[] | select(.command == \$c) | .content" <<<"$prompts")" = "$want" ] || exit 1
    done' _ "$KEY" "$OWUI_URL"
  check "$n: titles on gpt-oss-20b; tags, follow-ups, autocomplete and query generation off" quiet bash -c \
    'curl -fsS -H "Authorization: Bearer $1" "$2/api/v1/tasks/config" | jq -e ".TASK_MODEL_EXTERNAL == \"openai/gpt-oss-20b\" and .ENABLE_TITLE_GENERATION == true and .ENABLE_TAGS_GENERATION == false and .ENABLE_FOLLOW_UP_GENERATION == false and .ENABLE_AUTOCOMPLETE_GENERATION == false and .ENABLE_SEARCH_QUERY_GENERATION == false and .ENABLE_RETRIEVAL_QUERY_GENERATION == false"' _ "$KEY" "$OWUI_URL"
  check "$n: the advisor is the default model" quiet bash -c \
    'curl -fsS -H "Authorization: Bearer $1" "$2/api/v1/configs/models" | jq -e ".DEFAULT_MODELS == \"homelab-advisor\""' _ "$KEY" "$OWUI_URL"
}
verify "first sync"
# Someone edits a prompt and a setting in the UI; the next sync puts them back.
rid=$(get /api/v1/prompts/ | jq -r '.[] | select(.command == "review") | .id')
curl -fsS -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' "$OWUI_URL/api/v1/prompts/id/$rid/update" \
  -d '{"command": "review", "name": "Review", "content": "drifted"}' >/dev/null
get /api/v1/tasks/config | jq -c '.ENABLE_TAGS_GENERATION = true' |
  curl -fsS -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' "$OWUI_URL/api/v1/tasks/config/update" -d @- >/dev/null
run_sync >"$K/out2" 2>&1; RC=$?
check "second sync exits 0" test "$RC" -eq 0
verify "second sync"

# What actually reaches OpenRouter when someone chats with the advisor.
chat=$(curl -sS -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' "$OWUI_URL/api/chat/completions" \
  -d '{"model": "homelab-advisor", "stream": false, "messages": [{"role": "user", "content": "hello"}]}')
check "a chat through the advisor gets the stub's answer" bash -c '[ "$(jq -r ".choices[0].message.content" <<<"$1")" = ok ]' _ "$chat"
sent=$(curl -fsS http://upstream:8000/_log | jq -sc '[.[] | select(.path | endswith("/chat/completions"))] | last | .body')
check "OpenRouter receives data_collection: deny" bash -c 'jq -e ".provider.data_collection == \"deny\"" <<<"$1" >/dev/null' _ "$sent"
check "OpenRouter receives the base model and the answer cap" bash -c 'jq -e --slurpfile m "$2" ".model == \$m[0].base_model_id and .max_tokens == \$m[0].params.max_tokens" <<<"$1" >/dev/null' _ "$sent" "$M"
check "OpenRouter receives the system prompt" bash -c 'jq -e --rawfile s "$2" "[.messages[] | select(.role == \"system\") | .content] | any(contains(\$s | .[0:60]))" <<<"$1" >/dev/null' _ "$sent" "$SP"
echo "upstream request: $sent" | cut -c1-600

echo; echo "$PASS passed, $FAIL failed ($IMAGE)"
[ "$FAIL" -eq 0 ]
