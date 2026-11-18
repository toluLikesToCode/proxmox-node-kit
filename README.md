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

## Requirements

The Open WebUI container runs a custom model, Homelab Advisor, defined in `app/advisor/`.

- It advises one homelab owner on Proxmox, Docker and Compose, Linux, networking and DNS, backups, remote access (Tailscale, Cloudflare-style tunnels), monitoring and media servers, and on git, testing, CI, security and code review.
- It answers from attached knowledge when there is any (the model calls Open WebUI's knowledge tools) and says when it does not know.
- It is cheap to run. Every model call goes through OpenRouter, the advisor asks it to skip providers that keep or train on prompts (`data_collection: deny`), background calls (tags, follow-ups, autocomplete, search and retrieval queries) are off, and answers are capped in length.
- It is safe. It never asks for or repeats secrets, gives steps with an undo, and warns before destructive commands.

What is in `app/advisor/`:

| File | What it is |
|---|---|
| `system-prompt.md` | The model's identity, under 1,500 tokens and static so it can be cached. |
| `model.json` | The model: base model, native function calling, temperature, answer cap. |
| `prompts/` | Saved prompts: `/diagnose`, `/plan-change`, `/review`. |
| `sync.sh` | Pushes the model, the prompts and the cost settings into Open WebUI through its API. |

### One-time setup for sync

Once the key is in place, the advisor appears in Open WebUI within 15 minutes. No manual run is needed. `update.sh` runs `sync.sh` after every healthy deploy, and on each 15-minute check when the key or the files in `app/advisor/` changed since the last successful sync. A failed sync is retried on the next check, logged, and never rolls the deploy back. Without a key, `sync.sh` only prints these steps:

1. In Open WebUI, go to Settings > Admin > Authentication and turn on API keys. A fresh install has this on already; an existing one keeps its saved setting.
2. Go to Settings > Account > API Keys and create a key.
3. On the Proxmox node, as root:

       pct exec 402 -- sh -c 'umask 077; echo OWUI_API_KEY=<key> > /etc/open-webui-sync.env'

Open WebUI saves most settings in its database on first start, so the settings in `app/compose.yaml` only seed a fresh install. `sync.sh` applies the same values to an existing one.

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
- the update script's deploy, backup and rollback, against a local git remote;
- the advisor files, and `sync.sh` against a stub Open WebUI API;
- the update timer's advisor sync when only the key or the advisor files changed.

The integration test needs a few minutes and pulls the Open WebUI image, so CI runs it as a separate job. It is also the one to run after changing `sync.sh` or the Open WebUI tag:

    bash tests/integration.sh

It starts the exact image tag from `app/compose.yaml` with a stub OpenRouter, creates the admin account and an API key, runs `sync.sh` twice, then checks the model, prompts and settings in Open WebUI and the request sent to OpenRouter, including `data_collection: deny`.

## Security

- The repo holds no secrets. The OpenRouter key is entered in Open WebUI.
- The VM accepts only the SSH key in `host/authorized_keys`.
