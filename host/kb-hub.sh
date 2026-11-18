#!/bin/bash
# The advisor-kb master repo: a bare git repo on one node, with the leak and deny-list checks run
# there before anything reaches `live`. No git host, CI service or branch protection is involved.
#
#   kb-hub.sh init                    create the bare repo, install the hook, make the state dirs
#   kb-hub.sh promote [SHA]           full checks on SHA (default: tip of main), then move `live` to it
#   kb-hub.sh rollback                move `live` back to the last-good commit
#   kb-hub.sh install-tools [SRC]     copy tools/, tests/ and .gitleaks.toml to $KB_TOOLS; SRC is a reviewed
#                                     commit in this repo (default live) or a checkout directory (first install)
#   kb-hub.sh install-gitleaks        download the pinned gitleaks, verify its sha256, install it in $KB_TOOLS/bin
#   kb-hub.sh add-reader NAME PUBKEY  allow a read-only key: it can only run git-upload-pack on this repo
#   kb-hub.sh status                  main, live and the last-good list
#   kb-hub.sh check SHA [quick|full]  run the checks only (what the hook and promote call)
#   kb-hub.sh pre-receive             the hook body; reads "old new ref" lines on stdin
#
# Rules: pushes may only fast-forward `main` and only when the quick checks pass on the new tip;
# nobody pushes `live` or `last-good`: promote is the only way to move it, and it re-checks the
# whole history. The owner's deny-list lives only on this node ($KB_DENYLIST), never in the repo.
# The checks are the repo's tools/ and tests/ (the same as in CI), but run from a copy installed on
# this node ($KB_TOOLS): a push that edits tools/ is still judged by the old tools until the owner
# reviews it and runs install-tools. gitleaks is a pinned, sha256-verified binary, not Docker, so the
# user that runs the hook needs no Docker access.
set -euo pipefail
BARE=${KB_BARE:-/srv/advisor-kb.git}
KB_DENYLIST=${KB_DENYLIST:-/etc/advisor-kb/denylist.txt}
KEEP_LAST_GOOD=${KEEP_LAST_GOOD:-5}
KB_TOOLS=${KB_TOOLS:-/usr/local/lib/advisor-kb}
GITLEAKS_VERSION=8.30.0
GITLEAKS_URL=${KB_GITLEAKS_URL:-https://github.com/gitleaks/gitleaks/releases/download/v$GITLEAKS_VERSION}
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
export GIT_DIR=${GIT_DIR:-$BARE}
log() { echo "kb-hub: $*" >&2; }
die() { log "$*"; exit 1; }

# The checks that CI runs, from the node's installed copy, against a checked-out tree. Fails closed
# without the deny-list, the installed tools or the gitleaks binary.
run_checks() { # run_checks DIR quick|full
  local d=$1 mode=$2
  [ -s "$KB_DENYLIST" ] || die "no owner deny-list at $KB_DENYLIST; failing closed"
  [ -d "$KB_TOOLS/tools" ] || die "no installed tools in $KB_TOOLS; run 'kb-hub.sh install-tools <reviewed commit>'; failing closed"
  [ -d "$KB_TOOLS/tests" ] || die "installed tools in $KB_TOOLS are incomplete; failing closed"
  [ -x "$KB_TOOLS/bin/gitleaks" ] || die "no gitleaks at $KB_TOOLS/bin/gitleaks; run 'kb-hub.sh install-gitleaks'; failing closed"
  if ! diff -rq -x __pycache__ "$d/tools" "$KB_TOOLS/tools" >/dev/null 2>&1; then log "tools/ in this commit differs from the installed tools; the installed ones are used"; fi
  rm -rf "$d/tools" "$d/tests" "$d/.gitleaks.toml"
  cp -a "$KB_TOOLS/tools" "$KB_TOOLS/tests" "$d/"; cp -a "$KB_TOOLS/.gitleaks.toml" "$d/"
  ( cd "$d"
    export PYTHONDONTWRITEBYTECODE=1 OWNER_DENYLIST GITLEAKS_BIN=$KB_TOOLS/bin/gitleaks; OWNER_DENYLIST=$(cat "$KB_DENYLIST")
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

# install_tools [REF]: the node's copy of the checks, taken from a commit the owner has reviewed.
install_tools() {
  local src=${1:-refs/heads/live} sha tmp; tmp=$(mktemp -d)
  if [ -d "$src" ]; then
    sha=dir:$(cd "$src" && pwd)
    mkdir "$tmp/x"; cp -a "$src/tools" "$src/tests" "$src/.gitleaks.toml" "$tmp/x/" || { rm -rf "$tmp"; die "$src has no tools/, tests/ or .gitleaks.toml"; }
    tmp_src=$tmp/x
  else
    sha=$(git rev-parse --verify -q "$src^{commit}") || { rm -rf "$tmp"; die "no commit $src; pass a reviewed SHA or a checkout directory"; }
    git archive "$sha" tools tests .gitleaks.toml | tar -x -C "$tmp" || { rm -rf "$tmp"; die "$sha has no tools/, tests/ or .gitleaks.toml"; }
    tmp_src=$tmp
  fi
  find "$tmp_src" -name __pycache__ -prune -exec rm -rf {} +
  mkdir -p "$KB_TOOLS/bin"
  rm -rf "$KB_TOOLS/tools" "$KB_TOOLS/tests" "$KB_TOOLS/.gitleaks.toml"
  mv "$tmp_src/tools" "$tmp_src/tests" "$tmp_src/.gitleaks.toml" "$KB_TOOLS/"; rm -rf "$tmp"
  echo "$sha" > "$KB_TOOLS/INSTALLED_FROM"
  log "installed the checks from ${sha:0:12} into $KB_TOOLS"
}

install_gitleaks() {
  local arch want got tmp; tmp=$(mktemp -d)
  case $(uname -m) in
    x86_64) arch=linux_x64; want=79a3ab579b53f71efd634f3aaf7e04a0fa0cf206b7ed434638d1547a2470a66e ;;
    aarch64|arm64) arch=linux_arm64; want=b4cbbb6ddf7d1b2a603088cd03a4e3f7ce48ee7fd449b51f7de6ee2906f5fa2f ;;
    *) die "no pinned gitleaks for $(uname -m)" ;;
  esac
  curl -fsSL -o "$tmp/g.tgz" "$GITLEAKS_URL/gitleaks_${GITLEAKS_VERSION}_$arch.tar.gz" || { rm -rf "$tmp"; die "download failed"; }
  got=$( (sha256sum "$tmp/g.tgz" 2>/dev/null || shasum -a 256 "$tmp/g.tgz") | cut -d' ' -f1)
  [ "$got" = "$want" ] || { rm -rf "$tmp"; die "sha256 of the gitleaks download does not match the pinned value; nothing installed"; }
  tar -xzf "$tmp/g.tgz" -C "$tmp" gitleaks || { rm -rf "$tmp"; die "bad archive"; }
  mkdir -p "$KB_TOOLS/bin"; mv "$tmp/gitleaks" "$KB_TOOLS/bin/gitleaks"; chmod 755 "$KB_TOOLS/bin/gitleaks"; rm -rf "$tmp"
  log "installed gitleaks $GITLEAKS_VERSION ($arch) into $KB_TOOLS/bin"
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
  printf '#!/bin/sh\nexport KB_BARE=%q KB_DENYLIST=%q KB_TOOLS=%q\nexec %q pre-receive\n' "$BARE" "$KB_DENYLIST" "$KB_TOOLS" "$SELF" > "$BARE/hooks/pre-receive"
  chmod +x "$BARE/hooks/pre-receive"
  git config receive.denyNonFastForwards true
  git config receive.denyDeletes true
  log "ready at $BARE; before the first push: deny-list in $KB_DENYLIST (mode 600), then install-gitleaks and install-tools <reviewed checkout>"
}

case ${1:-} in
  init) init ;;
  install-tools) install_tools "${2:-}" ;;
  install-gitleaks) install_gitleaks ;;
  promote) promote "${2:-}" ;;
  rollback) rollback ;;
  add-reader) add_reader "${2:?NAME}" "${3:?PUBKEY}" ;;
  status) status ;;
  check) check_sha "${2:?SHA}" "${3:-full}" ;;
  pre-receive) hook ;;
  *) sed -n 2,12p "$0"; exit 2 ;;
esac
