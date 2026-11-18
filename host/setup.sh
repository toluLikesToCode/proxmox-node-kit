#!/bin/bash
# Creates two guests on a Proxmox node:
#   VM  agent-node  Ubuntu VM for remote work. It joins a Tailscale network and cannot open
#                   connections to the local network.
#   CT  open-webui  Open WebUI chat app. It updates itself from this repo's `live` branch.
# Run as root on the node. DRY_RUN=1 prints the plan and changes nothing.
# Each login step is printed as a QR code, so it can be done on a phone.
set -euo pipefail

VMID=${VMID:-401}
CTID=${CTID:-402}
STORE=${STORE:-local-lvm}
BR=${BR:-vmbr0}
REPO_URL=${REPO_URL:-https://github.com/toluLikesToCode/proxmox-node-kit.git}
REPO_RAW=${REPO_RAW:-https://raw.githubusercontent.com/toluLikesToCode/proxmox-node-kit/live}
STORAGE_CFG=${STORAGE_CFG:-/etc/pve/storage.cfg}
SNIPPET_DIR=${SNIPPET_DIR:-/var/lib/vz/snippets}
ARCH=${ARCH:-$(dpkg --print-architecture)}
IMG=${IMG:-/var/lib/vz/template/iso/noble-server-cloudimg-$ARCH.img}
DRY_RUN=${DRY_RUN:-0}
HERE=$(cd "$(dirname "$0")" && pwd)

run() {
  if [ "$DRY_RUN" = 1 ]; then echo "DRY: $*"; else "$@"; fi
}

# The QR is drawn inside the container, so the host needs no extra package.
qr() {
  printf '\n== %s ==\n%s\n' "$1" "$2"
  [ "$DRY_RUN" = 1 ] && return 0
  pct exec "$CTID" -- qrencode -t ansiutf8 -m 2 "$2" || true
}

local_storage_content() {
  awk '/^dir: local$/{f=1;next} /^[a-z]+: /{f=0} f&&$1=="content"{print $2}' "$STORAGE_CFG"
}

# ---- checks ----
for id in "$VMID" "$CTID"; do
  if qm status "$id" >/dev/null 2>&1 || pct status "$id" >/dev/null 2>&1; then
    echo "ID $id is in use. Set VMID or CTID to a free ID and run again."; exit 1
  fi
done
GW=$(ip -4 route show default dev "$BR" | awk '{print $3; exit}')
LAN=$(ip -4 route show dev "$BR" scope link | awk '{print $1; exit}')
T=$(pveam available --section system | awk -v a="_$ARCH." '/debian-1[2-9]-standard/ && index($2, a) {print $2}' | sort -V | tail -1)
if [ -z "$GW" ] || [ -z "$LAN" ]; then echo "Could not read the network of $BR."; exit 1; fi
if [ -z "$T" ]; then echo "No Debian container template found for $ARCH."; exit 1; fi
KEYFILE="$HERE/authorized_keys"
[ -f "$KEYFILE" ] || { KEYFILE=$(mktemp); curl -fsSL "$REPO_RAW/host/authorized_keys" -o "$KEYFILE"; }
echo "Node $(hostname), network $LAN, gateway $GW, dry run: $DRY_RUN"

# ---- VM first-boot settings (cloud-init) ----
CUR=$(local_storage_content)
case ",$CUR," in *,snippets,*) ;; *) run pvesm set local --content "${CUR},snippets" ;; esac
[ "$DRY_RUN" = 1 ] && SNIPPET_DIR=${DRY_SNIPPET_DIR:-$(mktemp -d)}
mkdir -p "$SNIPPET_DIR"
sed "s|@LAN@|$LAN|g" > "$SNIPPET_DIR/agent-node.yaml" <<'YAML'
#cloud-config
package_update: true
packages: [qemu-guest-agent, nftables, curl, git]
write_files:
  - path: /etc/nftables.conf
    permissions: '0644'
    content: |
      #!/usr/sbin/nft -f
      # Outbound filter: no new connections to the local network or the tailnet.
      # Replies to inbound connections are allowed, as are DNS and DHCP.
      table inet node_guard
      delete table inet node_guard
      table inet node_guard {
        chain output {
          type filter hook output priority 0; policy accept;
          ct state established,related accept
          oifname "lo" accept
          ip daddr @LAN@ udp dport 53 accept
          ip daddr @LAN@ tcp dport 53 accept
          udp dport 67 accept
          ip daddr 100.100.100.100 accept
          ip daddr @LAN@ drop
          ip daddr 100.64.0.0/10 drop
          ip6 daddr fc00::/7 drop
        }
      }
runcmd:
  - systemctl enable --now qemu-guest-agent
  - systemctl enable --now nftables
  - nft -f /etc/nftables.conf
  - curl -fsSL https://tailscale.com/install.sh | sh
  - nohup tailscale up --hostname=agent-node >/var/log/tailscale-up.log 2>&1 &
YAML
echo "Wrote $SNIPPET_DIR/agent-node.yaml"

# ---- container: Open WebUI ----
pveam list local | grep -q "$T" || run pveam download local "$T"
run pct create "$CTID" "local:vztmpl/$T" --hostname open-webui --cores 2 --memory 2048 --swap 1024 \
  --rootfs "$STORE:20" --net0 "name=eth0,bridge=$BR,ip=dhcp" --unprivileged 1 \
  --features nesting=1,keyctl=1 --onboot 1 --start 1
[ "$DRY_RUN" = 1 ] || sleep 10
run pct exec "$CTID" -- bash -c "apt-get update -q && apt-get install -yq curl ca-certificates && curl -fsSL $REPO_RAW/app/bootstrap.sh | REPO_URL=$REPO_URL bash"

# ---- VM: agent-node ----
[ -f "$IMG" ] || run curl -fL --create-dirs -o "$IMG" "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-$ARCH.img"
run qm create "$VMID" --name agent-node --memory 8192 --balloon 4096 --cores 4 --cpu host \
  --net0 "virtio,bridge=$BR" --scsihw virtio-scsi-pci --agent enabled=1 --ostype l26 \
  --onboot 1 --serial0 socket --vga serial0
run qm set "$VMID" --scsi0 "$STORE:0,import-from=$IMG,discard=on,ssd=1" --boot order=scsi0 \
  --ide2 "$STORE:cloudinit" --ciuser ops --sshkeys "$KEYFILE" --ipconfig0 ip=dhcp \
  --cicustom vendor=local:snippets/agent-node.yaml
run qm resize "$VMID" scsi0 100G
run qm start "$VMID"

if [ "$DRY_RUN" = 1 ]; then echo "Dry run finished. Nothing was changed."; exit 0; fi

# ---- next steps, each as a QR ----
CTIP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
MAC=$(qm config "$VMID" | sed -n 's/^net0: virtio=\([^,]*\).*/\1/p')
echo "Waiting for the VM's Tailscale login link (up to 10 minutes)..."
URL=""
for _ in $(seq 60); do
  URL=$(qm guest exec "$VMID" -- tailscale status 2>/dev/null | grep -o 'https://login.tailscale.com/a/[A-Za-z0-9]*' | head -1 || true)
  [ -n "$URL" ] && break
  sleep 10
done
qr "1. Approve the VM on your tailnet" "${URL:-Not ready yet. Run: qm guest exec $VMID -- tailscale status}"
qr "2. Reserve an IP for the VM on the router (MAC $MAC)" "http://$GW"
qr "3. Open WebUI: create the first account now (it becomes the admin)" "http://$CTIP:3000"
qr "4. Create an OpenRouter API key with a monthly limit" "https://openrouter.ai/settings/keys"
qr "5. Add the key in Open WebUI: Admin, Settings, Connections" "http://$CTIP:3000/admin/settings/connections"
