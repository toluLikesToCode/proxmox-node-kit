#!/bin/bash
# Plain-bash test suite; run it in Docker with tests/docker.sh.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
ok()    { echo "ok   - $1"; PASS=$((PASS+1)); }
bad()   { echo "FAIL - $1"; FAIL=$((FAIL+1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
G=(git -c user.name=t -c user.email=t@t)

# ---------- static ----------
check "shellcheck" shellcheck host/setup.sh app/*.sh tests/run.sh tests/docker.sh
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

# ---------- update.sh ----------
A=$(mktemp -d); mkdir -p "$A/bin"
# shellcheck disable=SC2016  # written for the stub to expand
printf '#!/bin/bash\necho "docker $*" >> "$APPLY_LOG"\n' > "$A/bin/docker"
# shellcheck disable=SC2016
printf '#!/bin/bash\n[ "${HEALTH:-up}" = up ]\n' > "$A/bin/curl"
chmod +x "$A/bin/"*
git init -q --bare "$A/origin.git"
git clone -q "$A/origin.git" "$A/work" 2>/dev/null
cp -r app "$A/work/"
( cd "$A/work" && "${G[@]}" add -A && "${G[@]}" commit -qm one && git push -q origin HEAD:live )
git clone -q -b live "$A/origin.git" "$A/deployed"
mkdir -p "$A/data"; echo v1 > "$A/data/webui.db"
update() { env PATH="$A/bin:$PATH" APPLY_LOG="$A/log" REPO_DIR="$A/deployed" DATA_DIR="$A/data" \
          BACKUP_DIR="$A/bak" HEALTH_TIMEOUT=0 "$@" bash app/update.sh; }
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

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
