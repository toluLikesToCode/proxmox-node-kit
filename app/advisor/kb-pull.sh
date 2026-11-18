#!/bin/bash
# Pulls the `live` branch of the advisor-kb repo with a read-only deploy key, verifies every file
# against MANIFEST.json, and publishes it atomically as $KB_ROOT/current (a symlink to
# releases/<commit>). A failed or partial pull leaves `current` untouched. Retried, logged to
# stderr, never touches the app. The host is configuration, not code: KB_REPO, KB_SSH_USER and
# KNOWN_HOSTS point it at GitHub (default) or any other git server. Without a deploy key it explains how to add one and exits 0.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
KB_REPO=${KB_REPO:-ssh://github.com/toluLikesToCode/homelab-advisor-kb.git}
KB_BRANCH=${KB_BRANCH:-live}
KB_KEY=${KB_KEY:-/etc/advisor-kb-deploy-key}
KB_ROOT=${KB_ROOT:-/var/lib/open-webui-kb}
KNOWN_HOSTS=${KNOWN_HOSTS:-$DIR/github_known_hosts}
KB_SSH_USER=${KB_SSH_USER:-git}
ATTEMPTS=${ATTEMPTS:-3}
RETRY_DELAY=${RETRY_DELAY:-10}
KEEP_RELEASES=${KEEP_RELEASES:-3}

log() { echo "kb-pull: $*" >&2; }
if [ ! -s "$KB_KEY" ]; then
  echo "kb pull skipped: no deploy key at $KB_KEY (read-only key for $KB_REPO)"
  exit 0
fi
command -v jq >/dev/null || apt-get install -yq jq >/dev/null
export GIT_SSH_COMMAND="ssh -i $KB_KEY -o User=$KB_SSH_USER -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS -o BatchMode=yes"

retry() {
  local n=1
  until "$@"; do
    [ "$n" -ge "$ATTEMPTS" ] && return 1
    log "attempt $n/$ATTEMPTS failed: $1 $2"; sleep $((n * RETRY_DELAY)); n=$((n + 1))
  done
}

# verify_tree DIR: every manifest entry exists with the right size and sha256, and no .md file is unlisted.
verify_tree() {
  local d=$1 path bytes sum
  [ -f "$d/MANIFEST.json" ] || { log "no MANIFEST.json"; return 1; }
  while IFS=$'\t' read -r path bytes sum; do
    [ -f "$d/$path" ] || { log "missing $path"; return 1; }
    [ "$(wc -c < "$d/$path" | tr -d ' ')" = "$bytes" ] || { log "size differs: $path"; return 1; }
    [ "$(sha256sum < "$d/$path" | cut -d' ' -f1)" = "$sum" ] || { log "hash differs: $path"; return 1; }
  done < <(jq -r '.files | to_entries[] | [.key, .value.bytes, .value.sha256] | @tsv' "$d/MANIFEST.json")
  local listed found
  listed=$(jq -r '.files | keys[]' "$d/MANIFEST.json" | sort)
  found=$(cd "$d" && find friend-notes reference -type f 2>/dev/null | sort)
  [ "$listed" = "$found" ] || { log "files on disk differ from the manifest"; return 1; }
}

mkdir -p "$KB_ROOT/releases"
cd "$KB_ROOT"
head=$(retry git ls-remote "$KB_REPO" "refs/heads/$KB_BRANCH" | cut -f1)
[ -n "$head" ] || { log "branch $KB_BRANCH not found in $KB_REPO"; exit 1; }
if [ "$(basename "$(readlink "$KB_ROOT/current" 2>/dev/null || true)")" = "$head" ]; then exit 0; fi

stage=$(mktemp -d "$KB_ROOT/stage.XXXXXX"); trap 'rm -rf "$stage"' EXIT
retry git clone -q --depth 1 --branch "$KB_BRANCH" "$KB_REPO" "$stage/src"
got=$(git -C "$stage/src" rev-parse HEAD)
[ "$got" = "$head" ] || { log "branch moved during the pull ($head -> $got); next run picks it up"; exit 1; }
verify_tree "$stage/src" || { log "verification failed for $head; keeping the previous knowledge"; exit 1; }
rm -rf "$stage/src/.git"
rm -rf "${KB_ROOT:?}/releases/$head"
mv "$stage/src" "$KB_ROOT/releases/$head"
ln -sfn "releases/$head" "$KB_ROOT/current.new"
mv -T "$KB_ROOT/current.new" "$KB_ROOT/current"
# shellcheck disable=SC2012  # release names are commit hashes
ls -1t "$KB_ROOT/releases" | tail -n +$((KEEP_RELEASES + 1)) | while read -r old; do rm -rf "${KB_ROOT:?}/releases/$old"; done
log "published ${head:0:8}"
