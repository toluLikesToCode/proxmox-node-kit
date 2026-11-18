# proxmox-node-kit

One script that sets up two guests on a Proxmox node:

| Guest | What it is |
|---|---|
| VM `agent-node` (401) | An Ubuntu 24.04 VM for remote work. It joins a Tailscale network. Its firewall stops it from opening connections to the local network or the tailnet. |
| Container `open-webui` (402) | [Open WebUI](https://github.com/open-webui/open-webui) using OpenRouter models. It is reachable at `http://<container-ip>:3000` on the local network. |

## Install

On the Proxmox node, as root:

    curl -fsSL https://raw.githubusercontent.com/toluLikesToCode/proxmox-node-kit/live/host/setup.sh -o setup.sh
    DRY_RUN=1 bash setup.sh   # show the plan, change nothing
    bash setup.sh             # create both guests

When it finishes, the script prints a QR code for each step that needs a login or a key: approving the VM on Tailscale, reserving its IP, creating the first Open WebUI account, and adding the OpenRouter key. All of them can be done on a phone.

Settings such as `VMID`, `CTID`, `STORE` and `BR` can be overridden with environment variables.

## Updates

1. Push to `main`.
2. CI runs the tests. If they pass, it moves the `live` branch to that commit.
3. Every 15 minutes the container checks `live`. When it has moved, `app/update.sh`:
   - backs up the app data,
   - deploys the new commit,
   - checks the app's health.

   If the health check fails, it restores the previous commit and data.

To upgrade Open WebUI, change the image tag in `app/compose.yaml`. The last five backups are kept in `/var/backups/open-webui/`.

## Tests

    bash tests/docker.sh

The tests run in Docker:
- the setup script's dry run, against stub Proxmox tools;
- a syntax check of the firewall rules with `nft -c`;
- the update script's deploy, backup and rollback, against a local git remote.

## Security

- The repo holds no secrets. The OpenRouter key is entered in Open WebUI.
- The VM accepts only the SSH key in `host/authorized_keys`.
