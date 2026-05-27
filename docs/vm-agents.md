# VM Agent Backups

PABS backs up VMs and LXCs with a lightweight agent deployed to each one.
The agent auto-detects the VM type, collects only what's needed to restore,
and produces a self-contained `.tar.zst` bundle that PABS pulls back to USB.

No disk images are involved. Each bundle is self-contained with a
`restore-notes.txt` — no PABS installation is required on the recovery machine.

---

## Supported types

| Type | Detection | What's backed up |
|---|---|---|
| **docker** | `docker` CLI present | All compose files + `.env`, Docker daemon config, named volumes (under threshold), package list |
| **haos** | `ha` CLI present + `/config/configuration.yaml` exists | Full native HA snapshot (`.tar`) via `ha` CLI — one-click restore via HA UI |
| **minecraft** | `minecraft` system user, or `MINECRAFT_BASE` directory present | Weekly `.tar.zst` archives from `minecraft-server-setup`, server config files, mods/plugins |
| **generic** | everything else | `/etc` (full), cron jobs, `/usr/local/bin`, `/root/scripts`, package list |

Detection runs in the order above — first match wins. Override with
`--set PABS_TYPE=<type>` during installation.

---

## Installation

### Step 1 — Deploy the agent

Run `install-agent.sh` from the Proxmox host once per VM. It copies the
agent files, runs first-time setup, registers the SSH host key, and prints
the `VM_AGENTS` line to add to `config.sh`.

```bash
chmod +x /opt/pabs/install-agent.sh

# Basic install
./install-agent.sh root@192.168.1.10

# With a dedicated SSH key
./install-agent.sh root@192.168.1.10 --key /root/.ssh/id_ed25519_pabs_agent

# Custom remote install path
./install-agent.sh root@192.168.1.10 --dir /home/backup/pabs-agent

# Pass configuration values during install — no SSH required afterwards
./install-agent.sh alice@192.168.1.40 \
    --set MINECRAFT_BASE=/home/alice/servers/backups \
    --set MINECRAFT_SERVER_BASE=/home/alice/servers \
    --set MC_KEEP_WEEKLY=2
```

### Step 2 — Add to config.sh

Copy the `VM_AGENTS` line printed by `install-agent.sh` into `config.sh`:

```bash
VM_AGENTS=(
    "docker-vm    192.168.1.10   root     /opt/pabs-agent/agent.sh"
    "haos         192.168.1.20   root     /opt/pabs-agent/agent.sh"
    "pihole-lxc   192.168.1.30   root     /opt/pabs-agent/agent.sh"
    "mc-server    192.168.1.40   alice    /opt/pabs-agent/agent.sh"
)
```

### Step 3 — Test

```bash
/opt/pabs/backup.sh --dry-run
```

Then run a full backup and verify the bundles appear under
`/mnt/backup-usb/proxmox-backup/<date>/vm-agents/<label>/`.

---

## Configuring agents with `--set`

All agent configuration is done from the Proxmox host during installation
via `--set KEY=VALUE` flags — you never need to SSH into a VM to edit
`/etc/pabs-agent/config` manually.

`--set` can be repeated for multiple values:

```bash
./install-agent.sh root@192.168.1.10 \
    --set PABS_TYPE=docker \
    --set DOCKER_MANAGER=dockge \
    --set DOCKGE_STACKS_DIR=/opt/mystacks
```

To update a setting after initial installation, simply re-run `install-agent.sh`
with the new `--set` value — it will overwrite the previous value in the config
file on the VM. The agent files are also updated to the latest version at the
same time.

---

## Type-specific configuration reference

### Docker (`types/docker.sh`)

| Variable | Default | Description |
|---|---|---|
| `DOCKER_COMPOSE_DIR` | `""` | If set, search only this directory for compose files (skips auto-detection) |
| `DOCKER_SEARCH_PATHS` | `/opt /srv /home /root /var/lib/docker/compose` | Directories to search for compose files when no manager is detected |
| `DOCKER_SEARCH_DEPTH` | `3` | How deep to recurse when searching for compose files |
| `DOCKER_MANAGER` | `auto` | Manager override: `auto` \| `none` \| `dockge` \| `portainer` |
| `DOCKGE_STACKS_DIR` | `/opt/stacks` | Dockge stacks directory |
| `DOCKGE_DATA_DIR` | `/opt/dockge` | Dockge data/config directory |
| `PORTAINER_URL` | `http://localhost:9000` | Portainer API URL |
| `PORTAINER_TOKEN` | `""` | Portainer API token for stack export (`ptr_...`) |
| `DOCKER_INCLUDE_VOLUMES` | `""` | Comma-separated named volumes to always include |
| `DOCKER_VOLUME_AUTO_THRESHOLD_MB` | `5` | Auto-include volumes smaller than this many MB |
| `DOCKER_SKIP_VOLUMES` | `false` | Set to `true` to skip all volume backups |
| `DOCKER_EXTRA_PATHS` | `""` | Space-separated extra paths to always include |

**Examples:**

```bash
# Dockge with a non-default stacks directory
./install-agent.sh root@192.168.1.10 \
    --set DOCKER_MANAGER=dockge \
    --set DOCKGE_STACKS_DIR=/srv/stacks \
    --set DOCKGE_DATA_DIR=/srv/dockge

# Portainer with API export
./install-agent.sh root@192.168.1.10 \
    --set DOCKER_MANAGER=portainer \
    --set PORTAINER_URL=http://localhost:9000 \
    --set PORTAINER_TOKEN=ptr_abc123xyz

# Force-include specific named volumes
./install-agent.sh root@192.168.1.10 \
    --set DOCKER_INCLUDE_VOLUMES=portainer_data,traefik_certs,vaultwarden_data
```

---

### Home Assistant OS (`types/haos.sh`)

Must be run inside the HAOS SSH add-on shell. The agent triggers a native
HA snapshot via the `ha` CLI — the same format as HA's own backup system.

| Variable | Default | Description |
|---|---|---|
| `HAOS_BACKUP_DIR` | `/backup` | Where HA stores snapshots (inside the add-on shell) |
| `HAOS_BACKUP_NAME` | `pabs-auto` | Prefix for the generated backup name (shown in HA UI) |
| `HAOS_BACKUP_TYPE` | `full` | `full` or `partial` |
| `HAOS_BACKUP_PASSWORD` | `""` | Encrypt the HA snapshot (leave empty for no encryption) |
| `HAOS_WAIT_SECONDS` | `300` | Max seconds to wait for HA to finish creating the snapshot |
| `HAOS_POLL_INTERVAL` | `10` | How often to poll for snapshot completion (seconds) |
| `HAOS_KEEP_ON_HOST` | `1` | How many `pabs-*` backups to keep on the HA host; oldest pruned after pull |
| `HAOS_PARTIAL_ADDONS` | `""` | Comma-separated add-on slugs (partial backup only) |
| `HAOS_PARTIAL_FOLDERS` | `""` | Comma-separated folders (partial backup only): `homeassistant,ssl,share,media,addons/local` |

**Examples:**

```bash
# Full backup with encryption (separate from PABS offsite encryption)
./install-agent.sh root@192.168.1.20 \
    --set HAOS_BACKUP_TYPE=full \
    --set HAOS_BACKUP_PASSWORD=mysecretpassword \
    --set HAOS_KEEP_ON_HOST=2

# Partial backup — HA config + SSL only
./install-agent.sh root@192.168.1.20 \
    --set HAOS_BACKUP_TYPE=partial \
    --set HAOS_PARTIAL_FOLDERS=homeassistant,ssl
```

---

### Minecraft (`types/minecraft.sh`)

Designed to work in tandem with
[minecraft-server-setup](https://github.com/LetsGaming/minecraft-server-setup).
The defaults match an unmodified install — only set these if you changed
the username, install path, or backup path in `variables.json`.

| Variable | Default | Description |
|---|---|---|
| `MINECRAFT_BASE` | `/home/minecraft/minecraft-server/backups` | Parent directory containing per-instance backup folders (each subdirectory is one instance) |
| `MINECRAFT_SERVER_BASE` | `/home/minecraft/minecraft-server` | Root of the server install — used to capture `server.properties`, mods, plugins, etc. |
| `MC_KEEP_WEEKLY` | `4` | How many weekly archives to include per instance |
| `MC_KEEP_DAILY` | `0` | How many daily archives to include (0 = skip daily entirely) |
| `MC_MIN_AGE_MINUTES` | `5` | Only include archives older than this — age-gate against in-progress compression |
| `MC_INCLUDE_MODS` | `true` | Include the `mods/` directory from each server instance |
| `MC_EXTRA_PATHS` | `""` | Space-separated extra paths to always include |

**The most common reason to use `--set` for Minecraft:**
`minecraft-server-setup` lets you customise the system username and install
path via `variables.json`. If you changed either, tell PABS during install:

```bash
# Default minecraft-server-setup install — no --set needed
./install-agent.sh minecraft@192.168.1.40

# Non-default username (e.g. "alice") with default path structure
./install-agent.sh alice@192.168.1.40 \
    --set MINECRAFT_BASE=/home/alice/minecraft-server/backups \
    --set MINECRAFT_SERVER_BASE=/home/alice/minecraft-server

# Completely custom paths
./install-agent.sh mc@192.168.1.40 \
    --set MINECRAFT_BASE=/srv/mc/backups \
    --set MINECRAFT_SERVER_BASE=/srv/mc \
    --set MC_KEEP_WEEKLY=2 \
    --set MC_KEEP_DAILY=3

# Multiple instances, include daily archives
./install-agent.sh minecraft@192.168.1.40 \
    --set MC_KEEP_WEEKLY=4 \
    --set MC_KEEP_DAILY=2 \
    --set MC_MIN_AGE_MINUTES=10
```

---

### Generic (`types/generic.sh`)

Catch-all for Pi-hole, AdGuard Home, Nginx, Vaultwarden, Gitea, and any
other plain Debian/Ubuntu VM or LXC. Backs up `/etc` (the primary config
store for most Linux services), cron jobs, scripts, and packages.

| Variable | Default | Description |
|---|---|---|
| `GENERIC_INCLUDE_ETC` | `true` | Back up `/etc` (full) |
| `GENERIC_INCLUDE_CRON` | `true` | Back up crontabs |
| `GENERIC_INCLUDE_SCRIPTS` | `true` | Back up `/usr/local/bin` and `/root/scripts` |
| `GENERIC_INCLUDE_PACKAGES` | `true` | Save dpkg selections and apt marks |
| `GENERIC_EXCLUDE_PATHS` | `""` | Space-separated paths to exclude from `/etc` (rsync `--exclude` syntax) |
| `EXTRA_PATHS` | `""` | Space-separated extra paths to always include |

The agent also detects common services that store data outside `/etc` and
logs a hint if found (AdGuard, Vaultwarden, Gitea, Nextcloud, etc.) — add
their data paths to `EXTRA_PATHS` to include them.

**Examples:**

```bash
# Pi-hole — /etc/pihole is already under /etc, no EXTRA_PATHS needed
./install-agent.sh root@192.168.1.30

# AdGuard Home — data dir is outside /etc
./install-agent.sh root@192.168.1.31 \
    --set EXTRA_PATHS=/opt/AdGuardHome

# Vaultwarden
./install-agent.sh root@192.168.1.32 \
    --set EXTRA_PATHS=/opt/vaultwarden/data

# Nextcloud (config only — not media files)
./install-agent.sh www-data@192.168.1.33 \
    --set EXTRA_PATHS=/var/www/nextcloud/config

# Exclude sensitive paths from /etc backup
./install-agent.sh root@192.168.1.34 \
    --set GENERIC_EXCLUDE_PATHS=/etc/ssl/private
```

---

## SSH key setup

`install-agent.sh` registers the VM's SSH host key in
`/root/.ssh/pabs_known_hosts` automatically. This enables
`StrictHostKeyChecking=yes` in the cron backup runs (configured in
`VM_AGENT_SSH_OPTS` in `config.sh`), which protects against
man-in-the-middle attacks on the SSH connection.

If a VM's host key changes (e.g. after an OS reinstall), re-run
`install-agent.sh` to update the registered key:

```bash
./install-agent.sh root@<vm-ip>
```

To manually inspect or remove a registered key:

```bash
ssh-keygen -F <vm-ip> -f /root/.ssh/pabs_known_hosts   # check if registered
ssh-keygen -R <vm-ip> -f /root/.ssh/pabs_known_hosts   # remove
```

---

## Updating agents

To update the agent code on a VM (e.g. after a PABS upgrade), re-run
`install-agent.sh`. It will rsync the latest agent files and re-apply
any previously set configuration values you pass again via `--set`.

The agent version is recorded in `agent-meta.txt` inside each bundle, so
you can verify which version produced a given backup.

---

## Bundle structure

Each agent bundle is a `.tar.zst` archive containing:

```
agent-meta.txt          PABS agent version, type, hostname, date
restore-notes.txt       Type-specific restore instructions (human-readable)
<type-specific files>   Compose files, HA snapshot, MC archives, /etc, etc.
system-state/           OS info, package list, hostname
```

To inspect without extracting:
```bash
tar -I zstd -tf vm-agents/my-vm/pabs-bundle-my-vm-<date>.tar.zst
```

To read the restore notes:
```bash
tar -I zstd -xOf vm-agents/my-vm/pabs-bundle-my-vm-<date>.tar.zst restore-notes.txt
```