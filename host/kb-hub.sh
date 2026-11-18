#!/bin/bash
# The advisor-kb master repo: a bare git repo on one node, with the leak and deny-list checks run
# there before anything reaches `live`. No git host, CI service or branch protection is involved.
#
#   kb-hub.sh init                    create the bare repo, install the hook, make the state dirs
#   kb-hub.sh promote [SHA]           full checks on SHA (default: tip of main), then move `live` to it
#   kb-hub.sh rollback                move `live` back to the last-good commit
#   kb-hub.sh add-reader NAME PUBKEY  allow a read-only key: it can only run git-upload-pack on this repo
#   kb-hub.sh status                  main, live and the last-good list
#   kb-hub.sh check SHA [quick|full]  run the checks only (what the hook and promote call)
#   kb-hub.sh pre-receive             the hook body; reads "old new ref" lines on stdin
#
# Rules: pushes may only fast-forward `main` and only when the quick checks pass on the new tip;
# nobody pushes `live` or `last-good`: promote is the only way to move it, and it re-checks the
# whole history. The owner's deny-list lives only on this node ($KB_DENYLIST), never in the repo.
# The checks are the ones in the repo's own tools/ and tests/, so they are the same as in CI.
set -euo pipefail
BARE=${KB_BARE:-/srv/advisor-kb.git}
KB_DENYLIST=${KB_DENYLIST:-/etc/advisor-kb/denylist.txt}
KEEP_LAST_GOOD=${KEEP_LAST_GOOD:-5}
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
export GIT_DIR=${GIT_DIR:-$BARE}
log() { echo "kb-hub: $*" >&2; }
die() { log "$*"; exit 1; }

# The checks that CI runs, against a checked-out tree. Fails closed without the deny-list.
run_checks() { # run_checks DIR quick|full
  local d=$1 mode=$2
  [ -s "$KB_DENYLIST" ] || die "no owner deny-list at $KB_DENYLIST; failing closed"
  ( cd "$d"
    export PYTHONDONTWRITEBYTECODE=1 OWNER_DENYLIST; OWNER_DENYLIST=$(cat "$KB_DENYLIST")
    python3 -m unittest discover -s tests >/dev/null 2>&1 || { echo "unit tests failed"; exit 1; }
    python3 tools/lint.py || exit 1
    python3 tools/manifest.py verify || exit 1
    python3 tools/check_denylist.py || exit 1
    if [ "$mode" = full ]; then
      env -u OWNER_DENYLIST bash tests/test_gitleaks.sh >/dev/null 2>&1 || { echo "gitleaks rules no longer catch planted violations"; exit 1; }
      tools/scan.sh || exit 1
    else
      SCAN_HISTORY=0 tools/scan.sh || exit 1
    fi
  )
}

# check_sha SHA MODE: checks SHA in a scratch copy; full mode clones the whole history.
check_sha() {
  local sha=$1 mode=$2 tmp rc=0; tmp=$(mktemp -d)
  if [ "$mode" = full ]; then
    ( unset GIT_DIR; git clone -q --no-hardlinks "$BARE" "$tmp/w" && cd "$tmp/w" && git checkout -q "$sha" ) || rc=1
  else
    mkdir "$tmp/w"; git archive "$sha" | tar -x -C "$tmp/w" || rc=1
  fi
  [ "$rc" -eq 0 ] || log "cannot read $sha"
  [ "$rc" -ne 0 ] || run_checks "$tmp/w" "$mode" || rc=1
  rm -rf "$tmp"
  return "$rc"
}

hook() {
  local old new ref rc=0
  while read -r old new ref; do
    case $ref in
      refs/heads/main) ;;
      *) log "rejected $ref: only main can be pushed; live moves with 'kb-hub.sh promote' on the node"; rc=1; continue ;;
    esac
    [[ $new =~ ^0+$ ]] && { log "rejected: main cannot be deleted"; rc=1; continue; }
    if ! [[ $old =~ ^0+$ ]] && ! git merge-base --is-ancestor "$old" "$new"; then
      log "rejected: main must fast-forward (no force pushes)"; rc=1; continue
    fi
    check_sha "$new" quick || { log "rejected $new: checks failed"; rc=1; }
  done
  exit "$rc"
}

promote() {
  local sha=${1:-$(git rev-parse --verify -q refs/heads/main)} old stamp
  [ -n "$sha" ] || die "main does not exist yet"
  sha=$(git rev-parse --verify -q "$sha^{commit}") || die "unknown commit"
  git merge-base --is-ancestor "$sha" refs/heads/main || die "$sha is not on main"
  old=$(git rev-parse --verify -q refs/heads/live || true)
  [ "$old" != "$sha" ] || { log "live is already ${sha:0:8}"; return 0; }
  check_sha "$sha" full || die "checks failed; live stays at ${old:0:8}"
  if [ -n "$old" ]; then
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    git update-ref "refs/last-good/$stamp" "$old"
    git for-each-ref --format='%(refname)' refs/last-good | sort -r | tail -n +$((KEEP_LAST_GOOD + 1)) | while read -r r; do git update-ref -d "$r"; done
  fi
  git update-ref refs/heads/live "$sha" "${old:-$(printf '0%.0s' {1..40})}"
  echo "$(date -u +%FT%TZ) promote ${old:0:8} -> ${sha:0:8}" >> "$BARE/promotions.log"
  log "live is now ${sha:0:8}"
}

rollback() {
  local ref prev
  ref=$(git for-each-ref --format='%(refname)' refs/last-good | sort -r | head -n 1)
  [ -n "$ref" ] || die "no last-good commit to go back to"
  prev=$(git rev-parse "$ref")
  git update-ref refs/heads/live "$prev"
  git update-ref -d "$ref"
  echo "$(date -u +%FT%TZ) rollback -> ${prev:0:8}" >> "$BARE/promotions.log"
  log "live is back at ${prev:0:8}"
}

status() {
  echo "main: $(git rev-parse --verify -q refs/heads/main || echo none)"
  echo "live: $(git rev-parse --verify -q refs/heads/live || echo none)"
  git for-each-ref --format='last-good: %(objectname) %(refname:short)' refs/last-good | sort -r
}

# One line per reader in $KB_AUTHORIZED_KEYS (the git user's authorized_keys on this node). The key can
# fetch this repo and do nothing else: forced command, no shell, no forwarding, no tty.
add_reader() {
  local name=$1 key=$2 f=${KB_AUTHORIZED_KEYS:-/home/git/.ssh/authorized_keys}
  [[ $key =~ ^ssh-(ed25519|rsa)\ [A-Za-z0-9+/=]+$ ]] || die "PUBKEY must be 'ssh-ed25519 AAAA...' (no options, no comment)"
  [[ $name =~ ^[a-z0-9-]+$ ]] || die "NAME must be lowercase letters, digits and dashes"
  mkdir -p "$(dirname "$f")"; touch "$f"
  grep -qF "$key" "$f" && { log "that key is already installed"; return 0; }
  printf 'command="git-upload-pack %s",restrict %s advisor-kb-%s\n' "'$BARE'" "$key" "$name" >> "$f"
  log "added read-only key $name to $f"
}

init() {
  [ -d "$BARE" ] || git init -q --bare -b main "$BARE"
  mkdir -p "$BARE/hooks" "$(dirname "$KB_DENYLIST")"
  printf '#!/bin/sh\nexport KB_BARE=%q KB_DENYLIST=%q\nexec %q pre-receive\n' "$BARE" "$KB_DENYLIST" "$SELF" > "$BARE/hooks/pre-receive"
  chmod +x "$BARE/hooks/pre-receive"
  git config receive.denyNonFastForwards true
  git config receive.denyDeletes true
  log "ready at $BARE; put the owner deny-list in $KB_DENYLIST (mode 600) before the first push"
}

case ${1:-} in
  init) init ;;
  promote) promote "${2:-}" ;;
  rollback) rollback ;;
  add-reader) add_reader "${2:?NAME}" "${3:?PUBKEY}" ;;
  status) status ;;
  check) check_sha "${2:?SHA}" "${3:-full}" ;;
  pre-receive) hook ;;
  *) sed -n 2,12p "$0"; exit 2 ;;
esac
