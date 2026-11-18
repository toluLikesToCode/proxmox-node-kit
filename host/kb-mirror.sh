#!/bin/bash
# Nightly backup of the advisor-kb master repo, run on a machine we control (not on the node that
# holds the repo, whose firewall blocks outbound traffic to us). It PULLS: git fetch --mirror over a
# key that can only run git-upload-pack on that one repo, verifies the copy, writes a git bundle
# of every ref, and hands the bundle to the existing offsite flow. A failed fetch or a copy that fails
# verification never replaces the last good mirror or deletes a bundle.
#   KB_MIRROR_REMOTE   ssh URL of the master repo (required), e.g. ssh://git@agent-node/srv/advisor-kb.git
#   KB_MIRROR_KEY      private key file for the read-only key (default /etc/advisor-kb-mirror-key)
#   KB_MIRROR_KNOWN_HOSTS  pinned host key of the master (required with an ssh URL)
#   KB_MIRROR          mirror path (default /srv/advisor-kb-mirror.git)
#   KB_BUNDLE_DIR      where bundles go (default /srv/advisor-kb-bundles); KEEP_BUNDLES (default 14)
#   KB_OFFSITE_CMD     optional command run as: $KB_OFFSITE_CMD <bundle path>, e.g. an rclone copyto to B2
set -euo pipefail
: "${KB_MIRROR_REMOTE:?set KB_MIRROR_REMOTE}"
KB_MIRROR=${KB_MIRROR:-/srv/advisor-kb-mirror.git}
KB_BUNDLE_DIR=${KB_BUNDLE_DIR:-/srv/advisor-kb-bundles}
KEEP_BUNDLES=${KEEP_BUNDLES:-14}
KB_MIRROR_KEY=${KB_MIRROR_KEY:-/etc/advisor-kb-mirror-key}
KB_MIRROR_KNOWN_HOSTS=${KB_MIRROR_KNOWN_HOSTS:-}
log() { echo "kb-mirror: $*" >&2; }
die() { log "$*"; exit 1; }

if [[ $KB_MIRROR_REMOTE == ssh://* || $KB_MIRROR_REMOTE == *@*:* ]]; then
  [ -s "$KB_MIRROR_KEY" ] || die "no key at $KB_MIRROR_KEY"
  [ -s "$KB_MIRROR_KNOWN_HOSTS" ] || die "set KB_MIRROR_KNOWN_HOSTS to the master's pinned host key"
  export GIT_SSH_COMMAND="ssh -i $KB_MIRROR_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KB_MIRROR_KNOWN_HOSTS -o BatchMode=yes"
fi

mkdir -p "$KB_BUNDLE_DIR"
stage=$(mktemp -d "$(dirname "$KB_MIRROR")/.kb-mirror-XXXXXX"); trap 'rm -rf "$stage"' EXIT
if [ -d "$KB_MIRROR" ]; then cp -a "$KB_MIRROR" "$stage/m.git"; else git init -q --bare "$stage/m.git"; fi
git --git-dir="$stage/m.git" fetch -q --prune "$KB_MIRROR_REMOTE" '+refs/*:refs/*' || die "fetch failed; mirror unchanged"
git --git-dir="$stage/m.git" rev-parse -q --verify refs/heads/main >/dev/null || die "remote has no main; mirror unchanged"
git --git-dir="$stage/m.git" fsck --no-progress >/dev/null 2>&1 || die "fsck failed on the fetched copy; mirror unchanged"
rm -rf "$KB_MIRROR.old"; [ ! -d "$KB_MIRROR" ] || mv "$KB_MIRROR" "$KB_MIRROR.old"
mv "$stage/m.git" "$KB_MIRROR"; rm -rf "$KB_MIRROR.old"

refs=$(git --git-dir="$KB_MIRROR" for-each-ref --format='%(objectname) %(refname)' | sha256sum | cut -c1-12)
bundle="$KB_BUNDLE_DIR/advisor-kb-$(date -u +%Y%m%d)-$refs.bundle"
if ls "$KB_BUNDLE_DIR"/advisor-kb-*-"$refs".bundle >/dev/null 2>&1; then log "no change since the last bundle"; exit 0; fi
git --git-dir="$KB_MIRROR" bundle create "$bundle.part" --all >/dev/null 2>&1 || { rm -f "$bundle.part"; die "bundle create failed"; }
git --git-dir="$KB_MIRROR" bundle verify "$bundle.part" >/dev/null 2>&1 || { rm -f "$bundle.part"; die "bundle did not verify"; }
mv "$bundle.part" "$bundle"
if [ -n "${KB_OFFSITE_CMD:-}" ]; then $KB_OFFSITE_CMD "$bundle" || die "offsite command failed for $bundle (bundle kept locally)"; fi
# shellcheck disable=SC2012  # bundle names are generated here
ls -1t "$KB_BUNDLE_DIR"/advisor-kb-*.bundle | tail -n +$((KEEP_BUNDLES + 1)) | while read -r old; do rm -f "$old"; done
log "mirrored and wrote $(basename "$bundle")"
