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
check "shellcheck" shellcheck -x -P SCRIPTDIR host/setup.sh host/kb-hub.sh host/kb-mirror.sh app/*.sh app/advisor/*.sh tests/run.sh tests/docker.sh tests/integration.sh tests/integration-run.sh
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
check "firewall also blocks containers (forward hook) from the local network and the tailnet" bash -c "sed -n '/chain forward/,/}/p' '$T/guard.nft' | grep -q 'hook forward' && sed -n '/chain forward/,/}/p' '$T/guard.nft' | grep -q 'ip daddr 192.0.2.0/24 drop' && sed -n '/chain forward/,/}/p' '$T/guard.nft' | grep -q '100.64.0.0/10 drop'"

# ---------- advisor config ----------
quiet() { "$@" >/dev/null; }
M=app/advisor/model.json; SP=app/advisor/system-prompt.md
check "model.json is valid JSON" quiet jq -e . "$M"
check "model.json pins the base model, native function calling and a token cap" quiet jq -e \
  '.id == "homelab-advisor" and .base_model_id == "deepseek/deepseek-v4.1-flash-1017" and .params.function_calling == "native" and (.params.max_tokens | type == "number" and . > 0)' "$M"
check "model.json asks OpenRouter to deny providers that keep or train on prompts" quiet jq -e '.params.custom_params.provider.data_collection == "deny"' "$M"
check "system prompt is under 1,500 tokens (chars/4)" test "$(( $(wc -c < "$SP") / 4 ))" -lt 1500
check "system prompt has the retrieval rule" grep -q 'Before answering anything about this homelab, call list_knowledge once, then query_knowledge_files' "$SP"
check "system prompt names both knowledge bases" bash -c 'grep -q "\"HomeLab notes\"" "$1" && grep -q "\"Reference homelab\"" "$1"' _ "$SP"
check "system prompt labels reference facts, cites files and prefers the newest as_of" bash -c 'grep -q "In the reference lab" "$1" && grep -q "Cite the file name" "$1" && grep -q "newest as_of" "$1" && grep -q "not in your notes" "$1"' _ "$SP"
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

# ---------- knowledge bases: kb-sync.sh ----------
K=$(mktemp -d)
make_kb() { # make_kb DIR: two files in friend-notes/, two in reference/, and a manifest
  mkdir -p "$1/friend-notes" "$1/reference"
  printf 'alpha\n' > "$1/friend-notes/Net - One.md"; printf 'beta\n' > "$1/friend-notes/Net - Two.md"
  printf 'gamma\n' > "$1/reference/Ref - One.md"; printf 'delta\n' > "$1/reference/Ref - Two.md"
  write_manifest "$1"
}
write_manifest() { python3 - "$1" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
files = {str(p.relative_to(root)): {"bytes": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
         for d in ("friend-notes", "reference") for p in sorted((root / d).glob("*.md"))}
(root / "MANIFEST.json").write_text(json.dumps({"files": files}))
PY
}
stub_start() { # stub_start [ENV=VALUE...]: fresh stub on a new port; sets S and STUB_PID
  S=$(mktemp -d); : > "$S/log"; env "$@" python3 tests/stubs/owui_stub.py "$S/port" "$S/log" & STUB_PID=$!
  until [ -s "$S/port" ]; do sleep 0.1; done; printf 'OWUI_API_KEY=testkey\n' > "$S/key.env"
}
kbsync() { OWUI_URL="http://127.0.0.1:$(cat "$S/port")" KEY_FILE="$S/key.env" STATE_DIR="$S/state" RETRY_DELAY=0 POLL_DELAY=0 bash app/advisor/kb-sync.sh "${1:-$K/kb}"; }
uploads() { jq -rs '[.[] | select(.path == "/api/v1/files/") | .body.filename] | sort | join(",")' "$S/log"; }
removals() { jq -s '[.[] | select(.path | test("/file/remove\\?delete_file=true$"))] | length' "$S/log"; }
sha() { sha256sum < "$1" | cut -d' ' -f1; }

make_kb "$K/kb"; stub_start
kbsync >"$S/out" 2>&1; RC=$?
check "kb-sync exits 0 and uploads the four files" bash -c '[ "$1" -eq 0 ] && [ "$(sed -n "s/^/x/;T" /dev/null; echo "$2")" = "Net - One.md,Net - Two.md,Ref - One.md,Ref - Two.md" ]' _ "$RC" "$(uploads)"
check "kb-sync uploads each file with the sha256 from the manifest" bash -c '[ "$(jq -rs "[.[] | select(.path == \"/api/v1/files/\") | select(.body.filename == \"Net - Two.md\") | .body.sha256][0]" "$1")" = "$2" ]' _ "$S/log" "$(sha "$K/kb/friend-notes/Net - Two.md")"
check "kb-sync creates the two bases by name" bash -c '[ "$(jq -rs "[.[] | select(.path == \"/api/v1/knowledge/create\") | .body.name] | sort | join(\",\")" "$1")" = "HomeLab notes,Reference homelab" ]' _ "$S/log"
check "kb-sync attaches both bases to the model and keeps the other knowledge" bash -c '[ "$(jq -rs "[.[] | select(.path == \"/api/v1/models/model/update\") | .body.meta.knowledge[].name] | sort | join(\",\")" "$1")" = "HomeLab notes,Reference homelab,Someone'"'"'s own base" ]' _ "$S/log"
: > "$S/log"; kbsync >"$S/out" 2>&1; RC=$?
check "kb-sync is idempotent: a second run uploads, removes and creates nothing" bash -c '[ "$1" -eq 0 ] && [ -z "$2" ] && [ "$3" -eq 0 ] && ! jq -es "any(.[]; .path == \"/api/v1/knowledge/create\")" "$4" | grep -qx true' _ "$RC" "$(uploads)" "$(removals)" "$S/log"
printf 'alpha changed\n' > "$K/kb/friend-notes/Net - One.md"; write_manifest "$K/kb"; : > "$S/log"; kbsync >/dev/null 2>&1
check "kb-sync replaces only the file whose hash changed" bash -c '[ "$1" = "Net - One.md" ] && [ "$2" -eq 1 ]' _ "$(uploads)" "$(removals)"
rm "$K/kb/reference/Ref - Two.md"; write_manifest "$K/kb"; : > "$S/log"; kbsync >/dev/null 2>&1
check "kb-sync deletes a file that left the manifest and uploads nothing" bash -c '[ -z "$1" ] && [ "$2" -eq 1 ]' _ "$(uploads)" "$(removals)"
printf 'alpha changed\n' | cmp -s - "$K/kb/friend-notes/Net - One.md"
cp -r app/advisor "$K/advisor2"; echo '{"TOP_K": 3}' > "$K/advisor2/retrieval.json"; : > "$S/log"
OWUI_URL="http://127.0.0.1:$(cat "$S/port")" KEY_FILE="$S/key.env" STATE_DIR="$S/state" RETRY_DELAY=0 POLL_DELAY=0 bash "$K/advisor2/kb-sync.sh" "$K/kb" >/dev/null 2>&1
check "kb-sync re-uploads everything when retrieval.json changed" bash -c '[ "$1" = "Net - One.md,Net - Two.md,Ref - One.md" ] && [ "$2" -eq 3 ]' _ "$(uploads)" "$(removals)"
kill "$STUB_PID"

make_kb "$K/kb2"; stub_start STUB_UPLOAD_FAILS="Net - Two.md:1"
kbsync "$K/kb2" >"$S/out" 2>&1; RC=$?
check "kb-sync retries a failed upload and succeeds" bash -c '[ "$1" -eq 0 ] && [ "$(grep -c "Net - Two.md" "$2")" -ge 2 ]' _ "$RC" "$S/log"
kill "$STUB_PID"

stub_start STUB_UPLOAD_FAILS="Net - Two.md:99"
kbsync "$K/kb2" >"$S/out" 2>&1; RC=$?
check "kb-sync exits 1 when a file keeps failing, still uploads the others" bash -c '[ "$1" -eq 1 ] && grep -q "FAILED to upload Net - Two.md" "$2" && grep -q "Ref - One.md" "$3"' _ "$RC" "$S/out" "$S/log"
check "kb-sync does not record success after a failure (next run retries)" test ! -e "$S/state/kb-retrieval.stamp"
kill "$STUB_PID"

stub_start STUB_PROCESS_STATUS=failed
kbsync "$K/kb2" >"$S/out" 2>&1; RC=$?
check "kb-sync treats a file whose processing failed as a failure and deletes it" bash -c '[ "$1" -eq 1 ] && jq -es "any(.[]; .method == \"DELETE\" and (.path | startswith(\"/api/v1/files/\")))" "$2" | grep -qx true' _ "$RC" "$S/log"
kill "$STUB_PID"

make_kb "$K/kb3"; printf 'tampered\n' > "$K/kb3/friend-notes/Net - One.md"; stub_start
kbsync "$K/kb3" >"$S/out" 2>&1; RC=$?
check "kb-sync refuses a file that differs from the manifest" bash -c '[ "$1" -eq 1 ] && grep -q "differs from manifest" "$2" && ! grep -q "Net - One.md" "$3"' _ "$RC" "$S/out" "$S/log"
: > "$S/log"; OUT=$(kbsync "$K/nothing" 2>&1); RC=$?
check "kb-sync without a pulled tree exits 0, says so and calls nothing" bash -c '[ "$1" -eq 0 ] && grep -q "no knowledge pull" <<<"$2" && [ ! -s "$3" ]' _ "$RC" "$OUT" "$S/log"
kill "$STUB_PID"

# sync.sh applies retrieval.json and runs kb-sync
make_kb "$K/kb4"; stub_start
OWUI_URL="http://127.0.0.1:$(cat "$S/port")" KEY_FILE="$S/key.env" STATE_DIR="$S/state" KB_ROOT="$K/none" bash app/advisor/sync.sh >/dev/null 2>&1; RC=$?
check "sync applies retrieval.json to Open WebUI" bash -c '[ "$1" -eq 0 ] && [ "$(jq -cs "[.[] | select(.path == \"/api/v1/retrieval/config/update\") | .body][0]" "$2")" = "$(jq -c . app/advisor/retrieval.json)" ]' _ "$RC" "$S/log"
check "retrieval.json: header splitting, vector-only, top 15" jq -e '.ENABLE_MARKDOWN_HEADER_TEXT_SPLITTER == true and .ENABLE_RAG_HYBRID_SEARCH == false and .RAG_RERANKING_MODEL == "" and .TOP_K == 15' app/advisor/retrieval.json
check "compose seeds the same retrieval settings for a fresh install" python3 -c '
import json,sys,yaml
e=yaml.safe_load(open("app/compose.yaml"))["services"]["open-webui"]["environment"]; r=json.load(open("app/advisor/retrieval.json"))
sys.exit(0 if int(e["RAG_TOP_K"])==r["TOP_K"] and int(e["CHUNK_SIZE"])==r["CHUNK_SIZE"] and int(e["CHUNK_OVERLAP"])==r["CHUNK_OVERLAP"] and e["ENABLE_RAG_HYBRID_SEARCH"]=="false" else 1)'
kill "$STUB_PID"

# ---------- knowledge bases: kb-pull.sh ----------
make_kb "$K/src"
git init -q -b main "$K/src"; ( cd "$K/src" && "${G[@]}" add -A && "${G[@]}" commit -qm one )
git init -q --bare "$K/kb-origin.git"; git -C "$K/src" push -q "$K/kb-origin.git" HEAD:live
pull() { env KB_REPO="$K/kb-origin.git" KB_KEY="${KB_KEY:-$K/key}" KB_ROOT="$K/root" RETRY_DELAY=0 ATTEMPTS=2 bash app/advisor/kb-pull.sh; }
echo placeholder > "$K/key"
OUT=$(KB_KEY="$K/absent" pull 2>&1); RC=$?
check "kb-pull without a deploy key exits 0 and says so" bash -c '[ "$1" -eq 0 ] && grep -q "no deploy key" <<<"$2" && [ ! -e "$3" ]' _ "$RC" "$OUT" "$K/root"
pull >/dev/null 2>&1; RC=$?
check "kb-pull publishes a verified tree as current" bash -c '[ "$1" -eq 0 ] && [ -f "$2/current/friend-notes/Net - One.md" ] && [ ! -e "$2/current/.git" ]' _ "$RC" "$K/root"
R1=$(readlink "$K/root/current")
OUT=$(pull 2>&1); RC=$?
check "kb-pull with nothing new does nothing" bash -c '[ "$1" -eq 0 ] && [ -z "$2" ] && [ "$(readlink "$3/current")" = "$4" ]' _ "$RC" "$OUT" "$K/root" "$R1"
printf 'ALPHA\n' > "$K/src/friend-notes/Net - One.md"; ( cd "$K/src" && "${G[@]}" commit -qam bad && git push -q "$K/kb-origin.git" HEAD:live )
OUT=$(pull 2>&1); RC=$?
check "kb-pull rejects a tree that does not match its manifest and keeps the old one" bash -c '[ "$1" -eq 1 ] && grep -q "hash differs" <<<"$2" && [ "$(readlink "$3/current")" = "$4" ] && grep -qx alpha "$3/current/friend-notes/Net - One.md"' _ "$RC" "$OUT" "$K/root" "$R1"
( cd "$K/src" && "${G[@]}" reset -q --hard HEAD~1 && printf 'extra\n' > reference/Extra.md && "${G[@]}" add -A && "${G[@]}" commit -qm extra && git push -q -f "$K/kb-origin.git" HEAD:live )
OUT=$(pull 2>&1); RC=$?
check "kb-pull rejects a file that is not in the manifest" bash -c '[ "$1" -eq 1 ] && grep -q "differ from the manifest" <<<"$2"' _ "$RC" "$OUT"
( cd "$K/src" && rm reference/Extra.md && printf 'new content\n' > "friend-notes/Net - Two.md" && write_manifest "$K/src" && "${G[@]}" add -A && "${G[@]}" commit -qm good && git push -q -f "$K/kb-origin.git" HEAD:live )
pull >/dev/null 2>&1; RC=$?
check "kb-pull moves current to the new commit and keeps the old release" bash -c '[ "$1" -eq 0 ] && [ "$(readlink "$2/current")" != "$3" ] && [ -d "$2/$3" ] && grep -qx "new content" "$2/current/friend-notes/Net - Two.md"' _ "$RC" "$K/root" "$R1"
OUT=$(KB_REPO="$K/does-not-exist.git" KB_KEY="$K/key" KB_ROOT="$K/root" RETRY_DELAY=0 ATTEMPTS=2 bash app/advisor/kb-pull.sh 2>&1); RC=$?
check "kb-pull retries, logs and exits 1 when the repo is unreachable, current untouched" bash -c '[ "$1" -eq 1 ] && grep -q "attempt 1/2" <<<"$2" && [ -f "$3/current/MANIFEST.json" ]' _ "$RC" "$OUT" "$K/root"
check "kb-pull pins GitHub's host keys (ed25519, ecdsa, rsa)" bash -c '[ "$(grep -c "^github.com ssh-ed25519\|^github.com ecdsa-\|^github.com ssh-rsa" app/advisor/github_known_hosts)" -eq 3 ]'

# ---------- kb-hub.sh: the master repo and its checks on the node ----------
HUB=$(mktemp -d); mkdir "$HUB/etc"; echo "owner-secret-word" > "$HUB/etc/denylist.txt"
hub() { KB_BARE="$HUB/kb.git" KB_TOOLS="$HUB/node-tools" KB_DENYLIST="${HUB_DENYLIST:-$HUB/etc/denylist.txt}" bash host/kb-hub.sh "$@"; }
# The repo's own tools are stood in by tiny ones with the same interface: each fails on a planted marker.
make_work() { # make_work DIR
  mkdir -p "$1/tools" "$1/tests" "$1/friend-notes"
  printf 'import unittest\nclass T(unittest.TestCase):\n    def test_ok(self): pass\n' > "$1/tests/test_ok.py"
  printf '#!/bin/bash\nexit 0\n' > "$1/tests/test_gitleaks.sh"
  for t in lint.py manifest.py; do printf 'import sys\nsys.exit(0)\n' > "$1/tools/$t"; done
  printf 'import os, sys, pathlib\nw = os.environ["OWNER_DENYLIST"].strip()\nbad = [p for p in pathlib.Path(".").rglob("*.md") if w in p.read_text()]\nprint("DENYLIST", bad) if bad else None\nsys.exit(1 if bad else 0)\n' > "$1/tools/check_denylist.py"
  printf '#!/bin/bash\n! grep -rq PLANTED-SECRET friend-notes || { echo LEAK; exit 1; }\n' > "$1/tools/scan.sh"; chmod +x "$1/tools/scan.sh" "$1/tests/test_gitleaks.sh"
  printf 'hello\n' > "$1/friend-notes/a.md"; printf '# stand-in rules\n' > "$1/.gitleaks.toml"
}
hub init >/dev/null 2>&1
make_work "$HUB/w"; git init -q -b main "$HUB/w"; ( cd "$HUB/w" && "${G[@]}" add -A && "${G[@]}" commit -qm one )
OUT=$(git -C "$HUB/w" push "$HUB/kb.git" HEAD:main 2>&1); RC=$?
check "a push fails closed while the node has no installed tools or gitleaks" bash -c '[ "$1" -ne 0 ] && grep -q "failing closed" <<<"$2" && ! git --git-dir="$3" rev-parse -q --verify main >/dev/null' _ "$RC" "$OUT" "$HUB/kb.git"
hub install-tools "$HUB/w" >/dev/null 2>&1
OUT=$(git -C "$HUB/w" push "$HUB/kb.git" HEAD:main 2>&1); RC=$?
check "a push still fails closed with tools installed but no gitleaks binary" bash -c '[ "$1" -ne 0 ] && grep -q "install-gitleaks" <<<"$2"' _ "$RC" "$OUT"
printf '#!/bin/sh\nexit 0\n' > "$HUB/node-tools/bin/gitleaks"; chmod +x "$HUB/node-tools/bin/gitleaks"
check "kb-hub init creates a bare repo whose pre-receive hook calls kb-hub.sh" bash -c '[ -x "$1/hooks/pre-receive" ] && grep -q "kb-hub.sh pre-receive" "$1/hooks/pre-receive"' _ "$HUB/kb.git"
OUT=$(git -C "$HUB/w" push "$HUB/kb.git" HEAD:main 2>&1); RC=$?
check "a clean push to main is accepted" test "$RC" -eq 0
OUT=$(git -C "$HUB/w" push "$HUB/kb.git" HEAD:live 2>&1); RC=$?
check "a push to live is rejected, naming the promote command" bash -c '[ "$1" -ne 0 ] && grep -q "kb-hub.sh promote" <<<"$2"' _ "$RC" "$OUT"
printf 'x PLANTED-SECRET y\n' > "$HUB/w/friend-notes/leak.md"; ( cd "$HUB/w" && "${G[@]}" add -A && "${G[@]}" commit -qm leak )
OUT=$(git -C "$HUB/w" push "$HUB/kb.git" HEAD:main 2>&1); RC=$?
check "a push that leaks a secret is rejected and main does not move" bash -c '[ "$1" -ne 0 ] && grep -q "checks failed" <<<"$2" && [ "$(git --git-dir="$3" rev-parse main)" != "$(git -C "$4" rev-parse HEAD)" ]' _ "$RC" "$OUT" "$HUB/kb.git" "$HUB/w"
( cd "$HUB/w" && "${G[@]}" reset -q --hard HEAD~1 && printf 'owner-secret-word\n' > friend-notes/b.md && "${G[@]}" add -A && "${G[@]}" commit -qm deny )
OUT=$(git -C "$HUB/w" push "$HUB/kb.git" HEAD:main 2>&1); RC=$?
check "a push that hits the node-only deny-list is rejected" bash -c '[ "$1" -ne 0 ] && grep -q "DENYLIST" <<<"$2"' _ "$RC" "$OUT"
( cd "$HUB/w" && "${G[@]}" reset -q --hard HEAD~1 && printf 'two\n' > friend-notes/c.md && "${G[@]}" add -A && "${G[@]}" commit -qm two )
git -C "$HUB/w" push -q "$HUB/kb.git" HEAD:main 2>/dev/null
OUT=$(git -C "$HUB/w" push -f "$HUB/kb.git" HEAD~1:main 2>&1); RC=$?
check "a force push that rewrites main is rejected" test "$RC" -ne 0
OUT=$(HUB_DENYLIST="$HUB/etc/missing" hub promote 2>&1); RC=$?
check "promote fails closed without the deny-list and live does not exist" bash -c '[ "$1" -ne 0 ] && grep -q "failing closed" <<<"$2" && ! git --git-dir="$3" rev-parse -q --verify live >/dev/null' _ "$RC" "$OUT" "$HUB/kb.git"
hub promote >/dev/null 2>&1; RC=$?; C1=$(git -C "$HUB/w" rev-parse HEAD)
check "promote moves live to the tip of main after the checks pass" bash -c '[ "$1" -eq 0 ] && [ "$(git --git-dir="$2" rev-parse live)" = "$3" ]' _ "$RC" "$HUB/kb.git" "$C1"
( cd "$HUB/w" && printf 'three\n' > friend-notes/d.md && "${G[@]}" add -A && "${G[@]}" commit -qm three ) ; C2=$(git -C "$HUB/w" rev-parse HEAD)
git -C "$HUB/w" push -q "$HUB/kb.git" HEAD:main 2>/dev/null
git --git-dir="$HUB/kb.git" update-ref refs/heads/main "$C2"
hub promote >/dev/null 2>&1; RC=$?
check "promote moves live again and keeps the previous commit as last-good" bash -c '[ "$1" -eq 0 ] && [ "$(git --git-dir="$2" rev-parse live)" = "$3" ] && git --git-dir="$2" for-each-ref --format="%(objectname)" refs/last-good | grep -qx "$4"' _ "$RC" "$HUB/kb.git" "$C2" "$C1"
hub rollback >/dev/null 2>&1; RC=$?
check "rollback puts live back on the last-good commit" bash -c '[ "$1" -eq 0 ] && [ "$(git --git-dir="$2" rev-parse live)" = "$3" ]' _ "$RC" "$HUB/kb.git" "$C1"
# A push that edits tools/ is judged by the node's installed copy, not by the pushed one.
( cd "$HUB/w" && printf '#!/bin/bash\nexit 0\n' > tools/scan.sh && printf 'x PLANTED-SECRET y\n' > friend-notes/f.md && "${G[@]}" add -A && "${G[@]}" commit -qm "neuter scan and leak" )
OUT=$(git -C "$HUB/w" push "$HUB/kb.git" HEAD:main 2>&1); RC=$?
check "a push that neuters tools/scan.sh and leaks is still rejected by the installed tools" bash -c '[ "$1" -ne 0 ] && grep -q "LEAK" <<<"$2" && [ "$(git --git-dir="$3" rev-parse main)" != "$(git -C "$4" rev-parse HEAD)" ]' _ "$RC" "$OUT" "$HUB/kb.git" "$HUB/w"
# A leaking commit that got onto main some other way (disk edit, old hook) must still not go live.
( cd "$HUB/w" && printf 'x PLANTED-SECRET y\n' > friend-notes/e.md && "${G[@]}" add -A && "${G[@]}" commit -qm bad ) ; C3=$(git -C "$HUB/w" rev-parse HEAD)
git --git-dir="$HUB/kb.git" fetch -q "$HUB/w" "$C3"
git --git-dir="$HUB/kb.git" update-ref refs/heads/main "$C3"
OUT=$(hub promote 2>&1); RC=$?
check "promote refuses a leaking commit even if it reached main, and live stays put" bash -c '[ "$1" -ne 0 ] && [ "$(git --git-dir="$2" rev-parse live)" = "$3" ]' _ "$RC" "$HUB/kb.git" "$C1"
OUT=$(hub promote 0000000000000000000000000000000000000001 2>&1); RC=$?
check "promote refuses a commit that is not on main" test "$RC" -ne 0
# gitleaks is a pinned binary: a download whose sha256 differs is refused and nothing is installed; no Docker is involved.
GL=$(mktemp -d); printf 'not gitleaks\n' > "$GL/gitleaks"; tar -czf "$GL/gitleaks_8.30.0_linux_x64.tar.gz" -C "$GL" gitleaks; cp "$GL/gitleaks_8.30.0_linux_x64.tar.gz" "$GL/gitleaks_8.30.0_linux_arm64.tar.gz"
rm -f "$HUB/node-tools/bin/gitleaks"
OUT=$(KB_GITLEAKS_URL="file://$GL" hub install-gitleaks 2>&1); RC=$?
check "install-gitleaks refuses a download whose sha256 is not the pinned one" bash -c '[ "$1" -ne 0 ] && grep -q "does not match the pinned" <<<"$2" && [ ! -e "$3/bin/gitleaks" ]' _ "$RC" "$OUT" "$HUB/node-tools"
check "kb-hub.sh runs no Docker and pins gitleaks 8.30.0 by sha256" bash -c '! grep -v "^ *#" host/kb-hub.sh | grep -qi docker && grep -q "GITLEAKS_VERSION=8.30.0" host/kb-hub.sh && [ "$(grep -c "want=[0-9a-f]\{64\} " host/kb-hub.sh)" -eq 2 ]'
check "kb-hub logs every promotion and rollback" bash -c '[ "$(grep -c "promote\|rollback" "$1/promotions.log")" -eq 3 ]' _ "$HUB/kb.git"

# kb-hub.sh add-reader and kb-mirror.sh
AK="$HUB/authorized_keys"; PUB="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkeytestkeytestkeytestkeytestkey1"
KB_AUTHORIZED_KEYS="$AK" hub add-reader mirror "$PUB" >/dev/null 2>&1; RC=$?
check "add-reader writes a key that can only run git-upload-pack on the repo" bash -c '[ "$1" -eq 0 ] && grep -qF "command=\"git-upload-pack '"'"'$2'"'"'\",restrict $3 advisor-kb-mirror" "$4"' _ "$RC" "$HUB/kb.git" "$PUB" "$AK"
OUT=$(KB_AUTHORIZED_KEYS="$AK" hub add-reader evil 'command="sh" ssh-ed25519 AAAA' 2>&1); RC=$?
check "add-reader rejects a key that carries its own options" bash -c '[ "$1" -ne 0 ] && [ "$(wc -l < "$2")" -eq 1 ]' _ "$RC" "$AK"
KB_AUTHORIZED_KEYS="$AK" hub add-reader mirror "$PUB" >/dev/null 2>&1
check "add-reader does not add the same key twice" bash -c '[ "$(wc -l < "$1")" -eq 1 ]' _ "$AK"
mirror() { KB_MIRROR_REMOTE="$HUB/kb.git" KB_MIRROR="$HUB/mirror.git" KB_BUNDLE_DIR="$HUB/bundles" "$@" bash host/kb-mirror.sh; }
mkdir -p "$HUB/offsite"
OUT=$(mirror env KB_OFFSITE_CMD="cp -t $HUB/offsite" 2>&1); RC=$?
check "kb-mirror fetches every ref, writes a verified bundle and hands it to the offsite command" bash -c '[ "$1" -eq 0 ] && [ "$(git --git-dir="$2" rev-parse live)" = "$(git --git-dir="$3" rev-parse live)" ] && b=$(ls "$4"/*.bundle) && git --git-dir="$2" bundle verify "$b" >/dev/null 2>&1 && [ -f "$5/$(basename "$b")" ]' _ "$RC" "$HUB/mirror.git" "$HUB/kb.git" "$HUB/bundles" "$HUB/offsite"
OUT=$(mirror env 2>&1); RC=$?
check "kb-mirror with nothing new writes no second bundle" bash -c '[ "$1" -eq 0 ] && [ "$(ls "$2" | wc -l)" -eq 1 ] && grep -q "no change" <<<"$3"' _ "$RC" "$HUB/bundles" "$OUT"
BEFORE=$(git --git-dir="$HUB/mirror.git" rev-parse main)
OUT=$(KB_MIRROR_REMOTE="$HUB/gone.git" KB_MIRROR="$HUB/mirror.git" KB_BUNDLE_DIR="$HUB/bundles" bash host/kb-mirror.sh 2>&1); RC=$?
check "kb-mirror leaves the mirror and the bundles alone when the master is unreachable" bash -c '[ "$1" -ne 0 ] && grep -q "fetch failed" <<<"$2" && [ "$(git --git-dir="$3" rev-parse main)" = "$4" ] && [ "$(ls "$5" | wc -l)" -eq 1 ]' _ "$RC" "$OUT" "$HUB/mirror.git" "$BEFORE" "$HUB/bundles"
git init -q --bare -b main "$HUB/empty.git"
OUT=$(KB_MIRROR_REMOTE="$HUB/empty.git" KB_MIRROR="$HUB/mirror.git" KB_BUNDLE_DIR="$HUB/bundles" bash host/kb-mirror.sh 2>&1); RC=$?
check "kb-mirror refuses a master with no main (an emptied repo must not overwrite the backup)" bash -c '[ "$1" -ne 0 ] && [ "$(git --git-dir="$2" rev-parse main)" = "$3" ]' _ "$RC" "$HUB/mirror.git" "$BEFORE"
OUT=$(KB_MIRROR_REMOTE="ssh://git@node/srv/x.git" KB_MIRROR_KEY="$HUB/nokey" KB_MIRROR="$HUB/m2.git" bash host/kb-mirror.sh 2>&1); RC=$?
check "kb-mirror over ssh needs the key and the pinned host key" bash -c '[ "$1" -ne 0 ] && grep -q "no key" <<<"$2"' _ "$RC" "$OUT"
check "kb-mirror units: nightly, persistent timer; oneshot service" bash -c 'grep -q "^OnCalendar=" host/kb-mirror.timer && grep -q "^Persistent=true" host/kb-mirror.timer && grep -q "^Type=oneshot" host/kb-mirror.service'

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
