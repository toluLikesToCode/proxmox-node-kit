#!/bin/bash
# One-time setup inside the container: Docker, this repo, and the update timer.
set -euo pipefail
REPO_URL=${REPO_URL:-https://github.com/toluLikesToCode/proxmox-node-kit.git}
apt-get update -q
apt-get install -yq git qrencode curl ca-certificates
command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh
[ -d /opt/node-kit/.git ] || git clone -q -b live "$REPO_URL" /opt/node-kit
install -m 0644 /opt/node-kit/app/open-webui-update.service /opt/node-kit/app/open-webui-update.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now open-webui-update.timer
FORCE=1 /opt/node-kit/app/update.sh
