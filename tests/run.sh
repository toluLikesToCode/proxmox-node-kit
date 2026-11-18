#!/bin/bash
# Plain-bash test suite; run it in Docker with tests/docker.sh.
# shellcheck disable=SC2016  # single-quoted bash -c and jq programs expand in their own shell
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
ok()    { echo "ok   - $1"; PASS=$((PASS+1)); }
bad()   { echo "FAIL - $1"; FAIL=$((FAIL+1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
G=(git -c user.name=t -c user.email=t@t)

# ---------- static ----------
check "shellcheck" shellcheck host/setup.sh app/*.sh app/advisor/sync.sh tests/run.sh tests/docker.sh tests/integration.sh tests/integration-run.sh
check "compose.yaml pins an image tag" python3 -c '
import yaml,sys
img=yaml.safe_load(open("app/compose.yaml"))["services"]["open-webui"]["image"]
sys.exit(0 if ":" in img and not img.endswith((":main",":latest")) else 1)'

# ---------- setup.sh dry run ----------
T=$(mktemp -d)
printf 'dir: local\n\tpath /var/lib/vz\n\tcontent iso,vztmpl,backup\n\nlvmthin: local-lvm\n\tthinpool data\n' > "$T/storage.cfg"
dry() { env -i PATH="$PWD/tests/stubs:/usr/bin:/bin" HOME="$T" ARCH=amd64 STUB_LOG="$T/log" \
        STORAGE_CFG="$T/storage.cfg" DRY_SNIPPET_DIR="$T/snip" IMG="$T/none.img" DRY_RUN=1 "$@" bash host/setup.sh; }
: > "$T/log"; OUT=$(dry 2>&1); RC=$?
check "dry run exits 0" test "$RC" -eq 0
check "dry run makes no changing call" bash -c "! grep -qE '^(pvesm set|pct create|pct exec|qm create|qm set|qm start|pveam download|curl)' '$T/log'"
check "dry run plans the VM" grep -q 'DRY: qm create 401 --name agent-node' <<<"$OUT"
check "dry run plans the container on the newest Debian for this CPU" grep -q 'DRY: pct create 402 local:vztmpl/debian-13-standard_13.1-2_amd64' <<<"$OUT"
check "dry run downloads the Ubuntu image for this CPU" grep -q 'noble-server-cloudimg-amd64.img' <<<"$OUT"
check "dry run adds snippets to local" grep -q 'DRY: pvesm set local --content iso,vztmpl,backup,snippets' <<<"$OUT"
check "dry run says nothing changed" grep -q 'Nothing was changed' <<<"$OUT"
: > "$T/log"; OUT2=$(dry TAKEN_ID=402 2>&1); RC=$?
check "an ID in use stops the run before any change" bash -c "[ $RC -eq 1 ] && grep -q 'ID 402 is in use' <<<\"\$1\" && ! grep -qE 'pvesm|create' '$T/log'" _ "$OUT2"

V="$T/snip/agent-node.yaml"
python3 -c 'import yaml,sys; print(yaml.safe_load(open(sys.argv[1]))["write_files"][0]["content"])' "$V" > "$T/guard.nft"
check "first-boot file has the network filled in" bash -c "grep -q '192.0.2.0/24' '$T/guard.nft' && ! grep -q '@LAN@' '$T/guard.nft'"
check "firewall rules pass nft -c" nft -c -f "$T/guard.nft"
check "firewall blocks the local network and the tailnet" bash -c "grep -q 'ip daddr 192.0.2.0/24 drop' '$T/guard.nft' && grep -q '100.64.0.0/10 drop' '$T/guard.nft'"

# ---------- advisor config ----------
quiet() { "$@" >/dev/null; }
M=app/advisor/model.json; SP=app/advisor/system-prompt.md
check "model.json is valid JSON" quiet jq -e . "$M"
check "model.json pins the base model, native function calling and a token cap" quiet jq -e \
  '.id == "homelab-advisor" and .base_model_id == "deepseek/deepseek-v4.1-flash-1017" and .params.function_calling == "native" and (.params.max_tokens | type == "number" and . > 0)' "$M"
check "model.json asks OpenRouter to deny providers that keep or train on prompts" quiet jq -e '.params.custom_params.provider.data_collection == "deny"' "$M"
check "system prompt is under 1,500 tokens (chars/4)" test "$(( $(wc -c < "$SP") / 4 ))" -lt 1500
check "system prompt has the retrieval rule" grep -q 'Before answering a question about this homelab, call list_knowledge, then query_knowledge_files' "$SP"
check "system prompt has a Knowledge index section" grep -q '^# Knowledge index' "$SP"
check "system prompt is static (no dates or variables)" bash -c '! grep -qE "[0-9]{4}-[0-9]{2}-[0-9]{2}|\{\{|\\$\{" "$1"' _ "$SP"
prompts_ok() {
  local files=(app/advisor/prompts/*.md)
  [ "${#files[@]}" -eq 3 ] || return 1
  for f in "${files[@]}"; do
    [ "$(sed -n 1p "$f")" = --- ] && sed -n 2p "$f" | grep -q '^command: [a-z-]*$' &&
      sed -n 3p "$f" | grep -q '^name: ' && [ "$(sed -n 4p "$f")" = --- ] || return 1
  done
}
check "three saved prompts, each with a command and a name" prompts_ok
check "compose turns off background generation and sets the default model" python3 -c '
import yaml,sys
e=yaml.safe_load(open("app/compose.yaml"))["services"]["open-webui"]["environment"]
off=["ENABLE_TAGS_GENERATION","ENABLE_FOLLOW_UP_GENERATION","ENABLE_AUTOCOMPLETE_GENERATION"]
sys.exit(0 if all(e[k]=="false" for k in off) and e["ENABLE_TITLE_GENERATION"]=="true" and e["TASK_MODEL_EXTERNAL"]=="openai/gpt-oss-20b" and e["DEFAULT_MODELS"]=="homelab-advisor" else 1)'
leaks() { grep -rEoh '[0-9]{1,3}(\.[0-9]{1,3}){3}' app README.md | grep -vE '^(127\.0\.0\.1|192\.0\.2\.[0-9]+)$'; }
check "no stray IPv4 address in app/ or README.md" test -z "$(leaks)"
check "no email address in app/ or README.md" bash -c '! grep -rqE "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}" app README.md'
check "no sk- key in app/ or README.md" bash -c '! grep -rqE "sk-[A-Za-z0-9_-]{10,}" app README.md'

S=$(mktemp -d); : > "$S/log"
python3 tests/stubs/owui_stub.py "$S/port" "$S/log" & STUB_PID=$!
until [ -s "$S/port" ]; do sleep 0.1; done
printf 'OWUI_API_KEY=testkey\n' > "$S/key.env"
run_sync() { OWUI_URL="http://127.0.0.1:$(cat "$S/port")" KEY_FILE="$1" bash app/advisor/sync.sh; }
# seen JQ_CONDITION: true when some recorded request matches
seen() { jq -es --argjson n "${2:-1}" "[.[] | select($1)] | length >= \$n" "$S/log" | grep -qx true; }
run_sync "$S/key.env" >"$S/out" 2>&1; RC=$?
check "sync exits 0 with a key" test "$RC" -eq 0
check "sync sends the API key on every request" bash -c '[ -s "$1" ] && ! jq -e "select(.auth != \"Bearer testkey\")" "$1" >/dev/null' _ "$S/log"
WANT=$(jq -c --rawfile s "$SP" '[.id, .base_model_id, .params.function_calling, $s] | tojson' "$M")
check "sync upserts the model with the system prompt inlined" bash -c '[ "$(jq -c "select(.path == \"/api/v1/models/import\") | .body.models[0] | [.id, .base_model_id, .params.function_calling, .params.system] | tojson" "$1")" = "$2" ]' _ "$S/log" "$WANT"
check "sync creates the prompts that are missing" bash -c '[ "$(jq -r "select(.path == \"/api/v1/prompts/create\") | .body.command" "$1" | sort | tr "\n" " ")" = "diagnose plan-change " ]' _ "$S/log"
check "sync updates the prompt that exists" seen '.path == "/api/v1/prompts/id/p1/update" and .body.command == "review" and (.body.content | startswith("Review this"))'
check "sync turns off background generation and sets the task model" seen '.path == "/api/v1/tasks/config/update" and .body.ENABLE_TAGS_GENERATION == false and .body.ENABLE_FOLLOW_UP_GENERATION == false and .body.ENABLE_AUTOCOMPLETE_GENERATION == false and .body.ENABLE_TITLE_GENERATION == true and .body.TASK_MODEL_EXTERNAL == "openai/gpt-oss-20b"'
check "sync sets the default model" seen '.path == "/api/v1/configs/models" and .method == "POST" and .body.DEFAULT_MODELS == "homelab-advisor"'
: > "$S/log"; run_sync "$S/key.env" >/dev/null 2>&1
check "sync is idempotent: a second run creates nothing and updates all three prompts" bash -c '! jq -e "select(.path == \"/api/v1/prompts/create\")" "$1" >/dev/null && [ "$(jq -r "select(.path | test(\"^/api/v1/prompts/id/.*/update$\")) | .path" "$1" | wc -l)" -eq 3 ]' _ "$S/log"
: > "$S/log"; OUT=$(run_sync "$S/missing.env" 2>&1); RC=$?
check "sync without a key file exits 0 and says how to create one" bash -c '[ "$1" -eq 0 ] && grep -q "pct exec 402" <<<"$2"' _ "$RC" "$OUT"
check "sync without a key file calls nothing" test ! -s "$S/log"
kill "$STUB_PID"

# ---------- update.sh ----------
A=$(mktemp -d); mkdir -p "$A/bin"
# shellcheck disable=SC2016  # written for the stub to expand
printf '#!/bin/bash\necho "docker $*" >> "$APPLY_LOG"\n' > "$A/bin/docker"
cat > "$A/bin/curl" <<'STUB'
#!/bin/bash
echo "curl $*" >> "$APPLY_LOG"
case "$*" in *"${CURL_FAIL_ON:-@@none@@}"*) exit 1;; esac
[ "${HEALTH:-up}" = up ]
STUB
chmod +x "$A/bin/"*
git init -q --bare "$A/origin.git"
git clone -q "$A/origin.git" "$A/work" 2>/dev/null
cp -r app "$A/work/"
( cd "$A/work" && "${G[@]}" add -A && "${G[@]}" commit -qm one && git push -q origin HEAD:live )
git clone -q -b live "$A/origin.git" "$A/deployed"
mkdir -p "$A/data"; echo v1 > "$A/data/webui.db"
update() { env PATH="$A/bin:$PATH" APPLY_LOG="$A/log" REPO_DIR="$A/deployed" DATA_DIR="$A/data" \
          BACKUP_DIR="$A/bak" STATE_DIR="$A/state" HEALTH_TIMEOUT=0 "$@" bash app/update.sh; }
synced() { grep -q '/api/v1/models/import' "$A/log"; }
push_change() { ( cd "$A/work" && echo "# $1" >> app/compose.yaml && "${G[@]}" commit -qam "$1" && git push -q origin HEAD:live ); }

: > "$A/log"; update >/dev/null 2>&1; RC=$?
check "update: no change does nothing" bash -c "[ $RC -eq 0 ] && [ ! -s '$A/log' ]"
push_change two; : > "$A/log"; update >/dev/null 2>&1; RC=$?
check "update: new commit deploys" bash -c "[ $RC -eq 0 ] && grep -q 'up -d' '$A/log' && [ \"\$(git -C '$A/deployed' rev-parse HEAD)\" = \"\$(git -C '$A/origin.git' rev-parse live)\" ]"
check "update: backup taken before deploy" bash -c "ls '$A/bak'/*.tgz >/dev/null 2>&1"
GOOD=$(git -C "$A/deployed" rev-parse HEAD)
push_change three; echo v2 > "$A/data/webui.db"; : > "$A/log"
update HEALTH=down >/dev/null 2>&1; RC=$?
check "update: unhealthy deploy exits 1" test "$RC" -eq 1
check "update: unhealthy deploy rolls back the commit" test "$(git -C "$A/deployed" rev-parse HEAD)" = "$GOOD"
check "update: unhealthy deploy restores the data" grep -qx v2 "$A/data/webui.db"

push_change four; : > "$A/log"; printf 'OWUI_API_KEY=k\n' > "$A/key.env"
update KEY_FILE="$A/key.env" CURL_FAIL_ON=/api/v1/models/import >"$A/out" 2>&1; RC=$?
check "update: deploy stands when the advisor sync fails" bash -c "[ $RC -eq 0 ] && grep -q 'up -d' '$A/log' && grep -q 'Advisor sync failed' '$A/out' && [ \"\$(git -C '$A/deployed' rev-parse HEAD)\" = \"\$(git -C '$A/origin.git' rev-parse live)\" ]"

# Without a new commit the timer still syncs when a key appears or changes, and retries a failed sync.
tick() { : > "$A/log"; update KEY_FILE="$A/key.env" "$@" >"$A/out" 2>&1; }
rm -f "$A/key.env"; tick
check "update: no key and no new commit does nothing" bash -c "[ ! -s '$A/log' ] && [ ! -s '$A/out' ]"
printf 'OWUI_API_KEY=k1\n' > "$A/key.env"; tick
check "update: a key added later is synced without a new commit" bash -c "grep -q '/api/v1/models/import' '$A/log' && ! grep -q 'up -d' '$A/log'"
tick
check "update: nothing changed since the last sync: no sync" bash -c "[ ! -s '$A/log' ]"
printf 'OWUI_API_KEY=k2\n' > "$A/key.env"; tick
check "update: a changed key is synced again" synced
echo '{}' >> "$A/deployed/app/advisor/model.json"; tick
check "update: changed advisor config is synced again" synced
tick
check "update: ...and then left alone" bash -c "[ ! -s '$A/log' ]"
printf 'OWUI_API_KEY=k3\n' > "$A/key.env"; tick CURL_FAIL_ON=/api/v1/models/import; RC=$?
check "update: a failed sync without a new commit is logged and exits 0" bash -c "[ $RC -eq 0 ] && grep -q 'Advisor sync failed' '$A/out'"
tick
check "update: a failed sync is retried on the next tick" synced
git -C "$A/deployed" checkout -q app/advisor/model.json

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
