#!/bin/bash
# Makes two Open WebUI knowledge bases match a verified pull of the advisor-kb repo:
#   "HomeLab notes"      <- friend-notes/   (the friend's own lab)
#   "Reference homelab"  <- reference/      (another lab's playbook: examples only)
# Idempotent: a file is uploaded only when its sha256 differs from the one Open WebUI stores,
# files no longer in the manifest are deleted, and a changed retrieval.json re-uploads everything
# (chunking settings only apply at upload time). Then attaches both bases to the advisor model,
# keeping any other knowledge already attached. Exits 1 if any file failed; the rest still ran.
# Usage: kb-sync.sh [KB_DIR]
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$DIR/lib.sh"
KB_DIR=${1:-${KB_ROOT:-/var/lib/open-webui-kb}/current}
STATE_DIR=${STATE_DIR:-/var/lib/open-webui-update}
ATTEMPTS=${ATTEMPTS:-3}
RETRY_DELAY=${RETRY_DELAY:-5}
POLL_DELAY=${POLL_DELAY:-2}
PROCESS_TIMEOUT=${PROCESS_TIMEOUT:-300}
MODEL_ID=$(jq -r .id "$DIR/model.json")
[ -n "$KEY" ] || { echo "kb sync skipped: no API key in $KEY_FILE"; exit 0; }
[ -f "$KB_DIR/MANIFEST.json" ] || { echo "kb sync skipped: no knowledge pull at $KB_DIR"; exit 0; }
SETTINGS_STAMP=$(sha256sum < "$DIR/retrieval.json" | cut -d' ' -f1)
FORCE_ALL=0
[ "$(cat "$STATE_DIR/kb-retrieval.stamp" 2>/dev/null || true)" = "$SETTINGS_STAMP" ] || FORCE_ALL=1
FAILED=0

retry() {
  local n=1
  until "$@"; do
    [ "$n" -ge "$ATTEMPTS" ] && return 1
    echo "retry $n/$ATTEMPTS: $1 $2 $3" >&2; sleep $((n * RETRY_DELAY)); n=$((n + 1))
  done
}

# kb_id NAME DESCRIPTION: id of the knowledge base with that name, created when missing.
kb_id() {
  local id
  id=$(retry api GET /api/v1/knowledge/ | jq -r --arg n "$1" '[.items[] | select(.name == $n) | .id][0] // empty')
  [ -n "$id" ] || id=$(retry api POST /api/v1/knowledge/create "$(jq -nc --arg n "$1" --arg d "$2" '{name: $n, description: $d}')" | jq -r .id)
  echo "$id"
}

# kb_files ID: "filename<TAB>sha256<TAB>file id" for every file in the base, all pages.
kb_files() {
  local page=1 total=0 got=0 body n
  while :; do
    body=$(retry api GET "/api/v1/knowledge/$1/files?page=$page")
    jq -r '.items[] | [.filename, (.hash // ""), .id] | @tsv' <<<"$body"
    n=$(jq '.items | length' <<<"$body"); total=$(jq '.total' <<<"$body"); got=$((got + n))
    [ "$n" -gt 0 ] || break
    [ "$got" -lt "$total" ] || break
    page=$((page + 1))
  done
}

remove_file() { retry api POST "/api/v1/knowledge/$1/file/remove?delete_file=true" "$(jq -nc --arg f "$2" '{file_id: $f}')" >/dev/null; }

# upload_file KB_ID PATH NAME: uploads, waits for processing, adds to the base.
upload_file() {
  local fid status waited=0 resp
  resp=$(retry curl -fsS -H "Authorization: Bearer $KEY" -F "file=@$2;filename=$3" "$URL/api/v1/files/?process=true") || return 1
  fid=$(jq -r '.id // empty' <<<"$resp"); [ -n "$fid" ] || return 1
  while :; do
    status=$(retry api GET "/api/v1/files/$fid/process/status" | jq -r .status)
    case $status in completed) break ;; failed) retry api DELETE "/api/v1/files/$fid" >/dev/null || true; return 1 ;; esac
    [ "$waited" -ge "$PROCESS_TIMEOUT" ] && return 1
    sleep "$POLL_DELAY"; waited=$((waited + POLL_DELAY))
  done
  retry api POST "/api/v1/knowledge/$1/file/add" "$(jq -nc --arg f "$fid" '{file_id: $f}')" >/dev/null
}

# sync_kb NAME DESCRIPTION SUBDIR: sets KB_ID.
sync_kb() {
  local name=$1 subdir=$2 id fname hash fid path want have added=0 removed=0 same=0
  id=$(kb_id "$name" "$3"); KB_ID=$id
  want=$(jq -r --arg p "$subdir/" '.files | to_entries[] | select(.key | startswith($p)) | [.key[($p | length):], .value.sha256] | @tsv' "$KB_DIR/MANIFEST.json")
  have=$(kb_files "$id")
  local kept=""
  while IFS=$'\t' read -r fname hash fid; do
    [ -n "$fid" ] || continue
    if [ "$FORCE_ALL" = 0 ] && ! grep -qxF "$fname" <<<"$kept" && grep -qxF "$fname"$'\t'"$hash" <<<"$want"; then
      kept+="$fname"$'\n'; same=$((same + 1)); continue
    fi
    if remove_file "$id" "$fid"; then removed=$((removed + 1)); else echo "FAILED to remove $fname" >&2; FAILED=$((FAILED + 1)); fi
  done <<<"$have"
  while IFS=$'\t' read -r fname hash; do
    [ -n "$fname" ] || continue
    ! grep -qxF "$fname" <<<"$kept" || continue
    path="$KB_DIR/$subdir/$fname"
    if [ "$(sha256sum < "$path" | cut -d' ' -f1)" != "$hash" ]; then echo "FAILED $fname: file differs from manifest" >&2; FAILED=$((FAILED + 1)); continue; fi
    if upload_file "$id" "$path" "$fname"; then added=$((added + 1)); else echo "FAILED to upload $fname" >&2; FAILED=$((FAILED + 1)); fi
  done <<<"$want"
  echo "kb '$name': $added uploaded, $same unchanged, $removed removed"
}

sync_kb "HomeLab notes" friend-notes "The friend's own lab notes. The truth for their lab."; HOME_ID=$KB_ID
sync_kb "Reference homelab" reference "Another person's homelab: patterns and examples, not facts about this lab."; REF_ID=$KB_ID

# Attach both bases, keeping other knowledge that is already on the model.
model=$(retry api GET "/api/v1/models/model?id=$MODEL_ID")
attached=$(jq -c --arg h "$HOME_ID" --arg r "$REF_ID" '
  .meta.knowledge = ([(.meta.knowledge // [])[] | select(.name != "HomeLab notes" and .name != "Reference homelab")]
    + [{type: "collection", id: $h, name: "HomeLab notes", description: "The friend'"'"'s own lab notes"},
       {type: "collection", id: $r, name: "Reference homelab", description: "Another lab'"'"'s playbook: examples only"}])' <<<"$model")
retry api POST /api/v1/models/model/update "$attached" >/dev/null
echo "attached both knowledge bases to $MODEL_ID"

if [ "$FAILED" -gt 0 ]; then echo "kb sync: $FAILED file(s) failed" >&2; exit 1; fi
mkdir -p "$STATE_DIR"; echo "$SETTINGS_STAMP" > "$STATE_DIR/kb-retrieval.stamp"
