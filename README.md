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
| `sync.sh` | Pushes the model, the prompts and the cost and search settings into Open WebUI through its API, then runs `kb-sync.sh`. |
| `retrieval.json` | Search settings: header-aware splitting, 1,024-character chunks, vector-only search, top 15 chunks. Measured on the real notes; the reasons are in the advisor-kb report. |
| `kb-pull.sh` | Pulls the `live` branch of the private advisor-kb repo over a read-only deploy key, checks every file against `MANIFEST.json` and swaps `/var/lib/open-webui-kb/current` atomically. A failed pull keeps the previous knowledge. |
| `kb-sync.sh` | Uploads the pulled notes into two Open WebUI knowledge bases, "HomeLab notes" (the owner's notes, the truth) and "Reference homelab" (another lab's playbook, examples only). It compares content hashes, removes what left the manifest, retries, and leaves other attached knowledge alone. |

### One-time setup for sync

Once the key is in place, the advisor appears in Open WebUI within 15 minutes. No manual run is needed. `update.sh` runs `sync.sh` after every healthy deploy, and on each 15-minute check when the key or the files in `app/advisor/` changed since the last successful sync. A failed sync is retried on the next check, logged, and never rolls the deploy back. Without a key, `sync.sh` only prints these steps:

1. In Open WebUI, go to Settings > Admin > Authentication and turn on API keys. A fresh install has this on already; an existing one keeps its saved setting, because Open WebUI stores it in its database after the first start and ignores `ENABLE_API_KEYS` from then on. Until it is on, `sync.sh` gets 401.
2. Go to Settings > Account > API Keys and create a key.
3. On the Proxmox node, as root:

       pct exec 402 -- sh -c 'umask 077; echo OWUI_API_KEY=<key> > /etc/open-webui-sync.env'

### Hosting the advisor-kb repo on the node (no git host)

`host/kb-hub.sh` turns one machine into the master of the advisor-kb repo: a bare repo with a `pre-receive` hook that runs the checks (unit tests, lint, manifest, deny-list, gitleaks) before `main` moves. The checks come from a copy installed on that machine (`kb-hub.sh install-tools <reviewed checkout or commit>`, directory `/usr/local/lib/advisor-kb`), never from the pushed commit, so a push that edits `tools/` is still judged by the old tools until someone reviews it and reinstalls. gitleaks is a pinned, sha256-verified binary (`kb-hub.sh install-gitleaks`), so the git user needs no Docker access, and a `promote` command that re-runs them on the whole history before it moves `live`. Nobody can push `live`; `rollback` puts it back on the last good commit. The owner's deny-list stays on that machine (`/etc/advisor-kb/denylist.txt`), never in the repo. `sudo -u git kb-hub.sh add-reader NAME 'ssh-ed25519 AAAA...'` installs a key that can only run `git-upload-pack` on the repo (run it as the git user so the key lands in that user's `authorized_keys`, and pass the key without its trailing comment); use one for the node's pull (`KB_REPO` points `kb-pull.sh` at this machine) and one for the backup.

`host/kb-mirror.sh` (with `kb-mirror.service` and `kb-mirror.timer`) runs on another machine we control, pulls a mirror nightly, verifies it, writes a bundle and hands it to the offsite command (`KB_OFFSITE_CMD`). A failed or empty fetch never replaces the last good mirror.

The homelab's offsite flow (`homelab-offsite.service` on the Proxmox nodes) is an rclone crypt remote named `offsite` over a B2 bucket, configured by `RCLONE_CONFIG_OFFSITE_*` variables in `/etc/rclone/homelab-offsite.env`. Its key cannot delete, so use the same remote with a prefix outside the bucket's expiring `weekly/` folder. On the machine that runs the mirror, with that env file present (without the Kuma URL), set `KB_OFFSITE_CMD=/usr/local/sbin/kb-offsite.sh`, where the script is:

    #!/bin/bash
    set -euo pipefail
    set -a; . /etc/rclone/homelab-offsite.env; set +a
    exec rclone copy --b2-hard-delete=false --bwlimit 12M "$1" offsite:advisor-kb/

Bundles are named by date and ref hash, are small, and are never deleted offsite (the key cannot delete), so growth is one small file per change.

### Knowledge from the advisor-kb repo

Only what is merged to `main` and promoted to the `live` branch of the advisor-kb repo reaches the node. `update.sh` runs `kb-pull.sh` on every check; when new knowledge arrives the fingerprint changes and `sync.sh` uploads it. Without the deploy key the pull is skipped and the advisor keeps its current knowledge. To turn it on, as root on the node:

1. Create a key pair on the node: `ssh-keygen -t ed25519 -N '' -f /etc/advisor-kb-deploy-key -C advisor-kb-readonly` (put it inside the container that runs the timer, `pct exec 402`, if `update.sh` runs there).
2. Add `/etc/advisor-kb-deploy-key.pub` as a read-only deploy key on the advisor-kb repo.
3. The next 15-minute check pulls, verifies and syncs. `KB_REPO` and `KNOWN_HOSTS` (a file holding the git server's host key) have no default and must be set for the pull to run: put them (and `KB_SSH_USER`, `KB_BRANCH`) as `NAME=value` lines in `/etc/advisor-kb.env`, which `update.sh` reads on every run; without `KB_REPO` the pull logs `kb pull skipped: KB_REPO not set` and exits 0. `KB_BRANCH`, `KB_KEY`, `KB_ROOT` and `KB_SSH_USER` override their defaults.

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

## Telemetry

After every update check, `app/telemetry.sh` posts a status to ntfy (`https://ntfy.jactus.net`, topic `advisor-telemetry`, no login): kit commit, Open WebUI version, update/sync/knowledge results, health, CPU load, memory and free disk. A change in problems also posts to `advisor-alerts`. Override or turn off with `/etc/advisor-telemetry.env` (`NTFY_URL`, `NTFY_TOKEN`, `NTFY_TOPIC`, `NTFY_ALERT_TOPIC`, `TELEMETRY=off`). Failures never fail the update.

## Tests

    bash tests/docker.sh

The tests run in Docker:
- the setup script's dry run, against stub Proxmox tools;
- a syntax check of the firewall rules with `nft -c`;
- the update script's deploy, backup and rollback, against a local git remote;
- the advisor files, and `sync.sh` against a stub Open WebUI API;
- the update timer's advisor sync when only the key or the advisor files changed;
- `kb-sync.sh` against the stub (idempotent, changed and removed files, failed uploads, retries, tampered files) and `kb-pull.sh` against a local git origin (verification, atomic swap, unreachable remote).

The integration test needs a few minutes and pulls the Open WebUI image, so CI runs it as a separate job. It is also the one to run after changing `sync.sh` or the Open WebUI tag:

    bash tests/integration.sh

It starts the exact image tag from `app/compose.yaml` with a stub OpenRouter, creates the admin account and an API key, runs `sync.sh` several times with a small knowledge tree (changed and removed files included), then checks the model, prompts, retrieval settings, both knowledge bases and a real search in Open WebUI and the request sent to OpenRouter, including `data_collection: deny`.

## Security

- The repo holds no secrets. The OpenRouter key is entered in Open WebUI.
- The VM accepts only the SSH key in `host/authorized_keys`.
