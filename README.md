# PABS — Proxmox Automated Backup System

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Proxmox%20VE%207.x%20%2F%208.x-e57000.svg)](https://www.proxmox.com/)
[![Tests](https://img.shields.io/badge/Tests-BATS-brightgreen.svg)](tests/pabs.bats)
[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25.svg)](backup.sh)

Backs up a Proxmox node's configuration, VM/CT definitions, network settings, cron jobs, SSH keys, firewall rules, package state, and per-VM restore bundles to a USB stick — then optionally syncs to any rclone-compatible remote (Google Drive, Backblaze, SFTP, etc.).

**Power-loss safe. Atomic commit. Zero external runtime dependencies beyond standard Debian tooling.**

Each completed backup drops a self-contained `proxmox-restore.sh` and `DISASTER-RECOVERY.md` directly into the backup folder. No dependency on this repo at restore time.

---

## Disaster recovery

This is what a full restore looks like. Mount the USB, pick a backup, run one script:

```bash
mount /dev/sdX1 /mnt/backup-usb
cd /mnt/backup-usb/proxmox-backup/2026-05-25_03-00-00/
chmod +x proxmox-restore.sh && ./proxmox-restore.sh
```

The script walks through each section interactively (`configs`, `ssh`, `firewall`, `vms`, `vm-agents`). Target a single section with `--section ssh`, or preview every action without writing anything with `--dry-run`.

Full restore procedures: [`docs/restore.md`](docs/restore.md)

---

## How it works

```
┌─────────────────────────────────────────┐
│             PROXMOX HOST                │
│                                         │
│  config.sh   ← the only file you edit  │
│  backup.sh   ← run directly or via cron│
│                                         │
│  1. Pre-flight   (USB mount, space,     │
│                   UUID identity check)  │
│  2. Stage on local SSD ─────────────────┼──────────────────────────┐
│  3. SHA256 manifest + verify on SSD     │                          │
│  4. Atomic rsync ───────────────────────┼──────────────────┐       │
│  5. Re-verify manifest on USB           │                  │       │
│  6. Sync offsite ───────────────────────┼──────────────┐   │       │
│  7. Rotate old backups                  │              │   │       │
└─────────────────────────────────────────┘              │   │       │
                                                         │   │       │
┌──────────────────────────────┐  ┌─────────────────┐   │   │       │
│         USB STICK            │  │ LOCAL SSD STAGE │   │   │       │
│                              │  │                 │   │   │       │
│  proxmox-backup/             │◄─│  .tmp-<date>/   │◄──┘   │       │
│  └── <date>/                 │  │  ├── etc/       │       │       │
│      ├── etc-pve.tar         │  │  ├── etc-pve.tar│       │       │
│      ├── vm-ct-definitions/  │  │  ├── system-    │       │       │
│      ├── system-state/       │  │  │   state/     │       │       │
│      ├── vm-agents/          │  │  ├── vm-agents/ │◄──────┘       │
│      ├── MANIFEST.sha256     │  │  └── MANIFEST.  │               │
│      ├── proxmox-restore.sh  │  │      sha256     │               │
│      └── DISASTER-RECOVERY.md│  └─────────────────┘               │
│  backup.log                  │                                     │
└──────────────────────────────┘                                     │
                                                                     │
┌──────────────────────────────┐                                     │
│    OFFSITE REMOTE (optional) │◄────────────────────────────────────┘
│                              │
│  gdrive:proxmox-backup/      │
│  └── <date>/  (AES-256 blobs)│
└──────────────────────────────┘
```

VM agents run inside each guest during step 2, called over SSH from the Proxmox host. Each produces a self-contained `.tar.zst` restore bundle:

| Agent type | Collected |
| :--------- | :-------- |
| `docker`   | All `docker-compose.yml` + `.env` files, Docker daemon config, named volumes (under threshold), package list |
| `haos`     | Full native HA snapshot (`.tar`) via `ha` CLI — one-click restore in the HA UI |
| `minecraft`| Weekly `.tar.zst` archives, `server.properties`, ops/whitelist/banned lists, mods, plugins |
| `generic`  | `/etc/` (full), cron jobs, `/usr/local/bin/`, `/root/scripts/`, package list |

---

## Prerequisites

- Proxmox VE 7.x or 8.x (Debian-based host)
- Root access (direct root shell or `sudo`)
- A USB stick already partitioned with a single partition
- Internet access during initial setup only (dependency installation)
- SSH key-based access to any VMs you want to back up via agents

---

## Quick start

### 1. Clone and install

```bash
git clone https://github.com/your-org/pabs /opt/pabs
chmod +x /opt/pabs/*.sh
```

### 2. Run the setup wizard

```bash
sudo bash /opt/pabs/setup.sh
```

The wizard installs dependencies, configures the USB target, deploys VM agents, sets up offsite sync, and schedules a cron job — all in one session. Safe to re-run at any time.

Jump to a specific step directly:

```bash
sudo bash /opt/pabs/setup.sh --step offsite   # reconfigure offsite only
sudo bash /opt/pabs/setup.sh --step agents    # add a new VM agent
sudo bash /opt/pabs/setup.sh --step usb       # change USB target or UUID
```

Available steps: `deps` | `usb` | `notifications` | `agents` | `offsite` | `cron` | `run`

### 3. Mount the USB stick

```bash
mount /dev/sdX1 /mnt/backup-usb
```

For automatic mount at boot, add to `/etc/fstab`:

```
UUID=<your-uuid>  /mnt/backup-usb  vfat  defaults,nofail  0  0
```

### 4. Test run

```bash
/opt/pabs/backup.sh --dry-run   # pre-flight checks only, no data written
/opt/pabs/backup.sh             # full backup
```

Logs land at `/mnt/backup-usb/proxmox-backup/backup.log`.

### 5. Schedule

```bash
crontab -e
```

```
# Every Sunday at 03:00
0 3 * * 0 /opt/pabs/backup.sh
```

---

## Manual configuration (skip the wizard)

`config.sh` is the only file you need to edit. Minimum to get running:

```bash
USB_MOUNT="/mnt/backup-usb"
TARGET_UUID=""   # get with: blkid /dev/sdX1  (leave empty to skip UUID check)
```

> **Security:** `config.sh` may contain webhook URLs, API tokens, and encryption passphrases. Restrict it immediately after setup:
> ```bash
> chmod 600 /opt/pabs/config.sh
> ```
> Secrets are redacted from the copy stored inside each backup — the `config.sh` written to the backup folder has all token and password values stripped.

Full variable reference: [`docs/configuration.md`](docs/configuration.md)

---

## VM agents (optional)

Deploy once per VM. All configuration is passed from the Proxmox host at deploy time via `--set`:

```bash
# Auto-detect type, use defaults
./install-agent.sh root@192.168.1.10

# Docker VM with Portainer
./install-agent.sh root@192.168.1.20 \
    --set DOCKER_MANAGER=portainer \
    --set PORTAINER_TOKEN=ptr_abc123

# Minecraft VM with non-default paths
./install-agent.sh alice@192.168.1.40 \
    --set MINECRAFT_BASE=/home/alice/servers/backups \
    --set MINECRAFT_SERVER_BASE=/home/alice/servers
```

Then register each VM in `config.sh`:

```bash
VM_AGENTS=(
    "docker-vm   192.168.1.10  root   /opt/pabs-agent/agent.sh"
    "haos        192.168.1.20  root   /opt/pabs-agent/agent.sh"
    "mc-server   192.168.1.40  alice  /opt/pabs-agent/agent.sh"
)
```

Full guide: [`docs/vm-agents.md`](docs/vm-agents.md)

---

## Offsite sync (optional, recommended)

```bash
apt install rclone
rclone config   # configure Google Drive, Backblaze, OneDrive, SFTP, etc.
```

In `config.sh`:

```bash
RCLONE_REMOTE="gdrive:proxmox-backup"
RCLONE_KEEP_MIN=1
RCLONE_MAX_STORAGE_GB=14        # stays within Google Drive's 15 GB free tier
RCLONE_ENCRYPTION_PASSWORD="a strong passphrase"
```

Offsite copies are encrypted with AES-256 via rclone's built-in crypt backend before upload. The passphrase never leaves `config.sh`.

Full guide: [`docs/offsite.md`](docs/offsite.md)

---

## Health check

```bash
/opt/pabs/pabs-status.sh
```

Reports: USB mount state, USB drive health (kernel I/O errors, filesystem error counters, SMART data), latest backup integrity (manifest re-verification), VM agent reachability, offsite remote status and storage usage, local stage space.

Exit codes: `0` = healthy, `1` = error, `2` = warning.

---

## What gets backed up

### Proxmox host (always)

| What | Path in backup |
| :--- | :------------- |
| `/etc/pve/` — cluster and node config | `etc-pve.tar` (pmxcfs-safe snapshot) |
| VM and CT definitions (`qm config`, `pct config`) | `vm-ct-definitions/` |
| Network config, `/etc/hosts`, hostname, `resolv.conf` | `etc/` |
| APT sources and package selections | `etc/apt/`, `system-state/` |
| Cron jobs (all users) | `etc/cron*/`, `var/spool/cron/` |
| Firewall rules (nftables, iptables, PVE) | `etc/nftables.conf`, `etc/iptables/`, `etc/pve/firewall/` |
| SSH keys and daemon config | `etc/ssh/`, `root/.ssh/` |
| Installed packages (dpkg selections + holds) | `system-state/` |
| Disk layout, kernel version, Proxmox version | `system-state/` |
| ZFS pool/dataset info (if `BACKUP_ZFS=true`) | `system-state/zfs-*/` |
| LVM VG configs (restorable with `vgcfgrestore`) | `system-state/lvm-*/` |
| `/usr/local/bin/`, `/root/scripts/` | preserved path |
| `backup.sh` and `config.sh` (secrets redacted) | `backup.sh`, `config.sh` |

### VM/LXC agent bundles (when `VM_AGENTS` is configured)

| VM type | Bundle contents |
| :------ | :-------------- |
| Docker | All `docker-compose.yml` + `.env` files, Docker daemon config, named volumes (under threshold), package list |
| Home Assistant OS | Full native HA snapshot (`.tar`) — one-click restore via HA UI |
| Minecraft | Weekly `.tar.zst` archives, `server.properties`, ops/whitelist/banned lists, mods, plugins |
| Generic | `/etc/` (full), cron jobs, `/usr/local/bin/`, `/root/scripts/`, package list |

### Not backed up

- VM and CT disk images. Not needed — agent bundles contain full application state. Rebuild path: fresh OS install → `install-agent.sh` → restore bundle. See [`docs/restore.md`](docs/restore.md).
- Docker volumes over the auto-include size threshold (configurable; opt in via `DOCKER_INCLUDE_VOLUMES`).
- Minecraft world data directly — the agent copies the archives that `minecraft-server-setup` already produced.

---

## Integrity guarantees

| Property | Behavior |
| :-------- | :------- |
| Staged write | All data assembled on local SSD first — USB sees one sequential write, minimizing flash wear and partial-write corruption |
| UUID targeting | Refuses to write to any drive other than the one matching `TARGET_UUID` |
| Pre-commit verification | SHA256 manifest verified on local SSD before a single byte reaches USB |
| Atomic commit | Written to `<date>.tmp/` then renamed — a partial transfer never appears as a valid backup |
| Post-transfer verification | Manifest re-checked on USB after transfer, catching write errors and silent bit rot |
| Auto space recovery | Purges the oldest backup when USB is full; refuses if it would be the last remaining copy |
| Drive health monitoring | `pabs-status.sh` checks kernel I/O errors, forced read-only remounts, filesystem error counters, and SMART health |
| Dual-channel alerts | Discord webhook (primary) + local mail (fallback) on both success and failure |
| Offsite encryption | AES-256 via rclone crypt before upload; provider never sees plaintext |

---

## File layout

<details>
<summary>Expand file tree</summary>

```
pabs/
├── backup.sh               Entry point — run directly or schedule with cron
├── config.sh               Your configuration — the only file you edit
├── setup.sh                Interactive setup wizard — start here
├── install-agent.sh        Deploys the VM agent to a guest over SSH (run once per VM)
├── pabs-status.sh          Health check — USB, backup integrity, agents, offsite
├── docs/
│   ├── setup-wizard.md     Wizard guide, step reference, module structure
│   ├── configuration.md    Every config.sh variable with type, default, and examples
│   ├── vm-agents.md        Agent setup, --set flags, per-type config reference
│   ├── offsite.md          Cloud remotes, free-tier sizing, encryption, retention
│   ├── usb-health.md       USB health checks, signal layers, example output
│   ├── restore.md          Restore procedures, DR walkthrough, bundle extraction
│   └── architecture.md     Data flow, integrity model, module structure, design decisions
├── lib/
│   ├── core.sh             Logging, lock file, trap, alerts
│   ├── offsite.sh          rclone encryption, upload, retention pruning
│   ├── preflight.sh        Pre-flight checks (USB mount, free space, UUID)
│   ├── sections.sh         The 8 backup sections
│   └── usb_health.sh       USB drive health signal checks
├── helpers/
│   ├── manifest.sh         SHA256 manifest generation, verification, rotation
│   └── output.sh           Writes restore script, README, and DR playbook per backup
├── setup/
│   ├── ui.sh               Terminal output and input helpers
│   ├── config_editor.sh    config.sh read/write functions
│   └── steps/              One file per wizard step (deps, usb, agents, offsite, ...)
├── tests/
│   └── pabs.bats           Automated test suite (requires bats-core)
└── vm-agent/
    ├── agent.sh            Runs inside the VM — auto-detects type, produces bundle
    └── types/
        ├── docker.sh
        ├── haos.sh
        ├── minecraft.sh
        └── generic.sh
```

</details>

---

## Documentation

| Doc | Contents |
| :-- | :------- |
| [`docs/setup-wizard.md`](docs/setup-wizard.md) | Wizard guide, step reference, module structure |
| [`docs/configuration.md`](docs/configuration.md) | Every `config.sh` variable with type, default, and examples |
| [`docs/vm-agents.md`](docs/vm-agents.md) | Agent setup, `--set` flags, per-type config reference |
| [`docs/offsite.md`](docs/offsite.md) | Cloud remotes, free-tier sizing, encryption, retention |
| [`docs/usb-health.md`](docs/usb-health.md) | USB health checks, signal layers, example output |
| [`docs/restore.md`](docs/restore.md) | Restore procedures, DR walkthrough, bundle extraction |
| [`docs/architecture.md`](docs/architecture.md) | Data flow, integrity guarantees, module structure, design decisions |