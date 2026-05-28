# PABS — Proxmox Automated Backup System

Backs up a Proxmox node's configuration, VM/CT definitions, network settings,
cron jobs, SSH keys, firewall rules, package state, and per-VM restore bundles
to a USB stick — then optionally syncs to a cloud or SFTP remote.

Designed to be **power-loss safe**, **restore-ready out of the box**, and
**configurable entirely from one file** (`config.sh`) without ever touching
library or agent code.

---

## How it works

```
Proxmox host
│
├── config.sh          ← the only file you edit
├── backup.sh          ← run this (or schedule via cron)
│
│   1. Pre-flight checks (USB mounted, space, UUID)
│   2. Stage everything on local SSD  ──→  /var/tmp/pabs-stage/.tmp-<date>/
│   3. Generate + verify SHA256 manifest on SSD
│   4. Atomic rsync to USB           ──→  /mnt/backup-usb/proxmox-backup/<date>/
│   5. Re-verify manifest on USB
│   6. Sync to offsite remote        ──→  gdrive:/proxmox-backup/<date>/  (optional)
│   7. Rotate old backups
│
└── vm-agent/          ← deployed once to each VM via install-agent.sh
    │   Called over SSH during step 2 — produces a self-contained .tar.zst bundle
    └── types/
        ├── docker.sh      compose files, .env, volumes, daemon config
        ├── haos.sh        native HA snapshot (.tar) via ha CLI
        ├── minecraft.sh   weekly archives from minecraft-server-setup
        └── generic.sh     /etc, cron, scripts, packages (Pi-hole, AdGuard, etc.)
```

Each completed backup contains a self-contained `proxmox-restore.sh` and
`DISASTER-RECOVERY.md` — no dependency on this repository at restore time.

---

## File layout

```
pabs/
├── backup.sh              Entry point — run this or schedule with cron
├── config.sh              Your configuration — the only file you need to edit
├── setup.sh               Interactive setup wizard — start here
├── install-agent.sh       One-time setup: deploys the VM agent to a VM over SSH
├── pabs-status.sh         Health check — USB, backup state, VM reachability, offsite
├── docs/
│   ├── configuration.md   Every config.sh variable documented in full
│   ├── vm-agents.md       How to set up and configure VM/LXC agent backups
│   ├── offsite.md         Cloud and SFTP offsite sync with encryption
│   ├── restore.md         Step-by-step restore and disaster recovery procedures
│   └── architecture.md   Design decisions, data flow, and integrity guarantees
├── lib/
│   ├── core.sh            Logging, lock, trap, alerts, offsite sync
│   ├── preflight.sh       Pre-flight checks (USB, space)
│   └── sections.sh        The 8 backup sections
├── helpers/
│   ├── manifest.sh        SHA256 manifest generation, verification, rotation
│   └── output.sh          Generates restore script, README, DR playbook per backup
├── tests/
│   └── pabs.bats          Automated test suite (requires bats-core)
└── vm-agent/
    ├── agent.sh           Runs inside the VM — auto-detects type, produces bundle
    └── types/
        ├── docker.sh
        ├── haos.sh
        ├── minecraft.sh
        └── generic.sh
```

---

## Quick start

### 1. Install

```bash
git clone <repo> /opt/pabs
chmod +x /opt/pabs/*.sh
```

### 2. Run the setup wizard

```bash
sudo bash /opt/pabs/setup.sh
```

The wizard walks through every setting, installs dependencies, deploys VM
agents, configures offsite sync, adds a cron job, and offers to run the first
backup — all from one interactive session. It is safe to re-run at any time
to update settings or add new VMs.

To jump directly to a specific step:
```bash
sudo bash setup.sh --step offsite   # reconfigure offsite only
sudo bash setup.sh --step agents    # add a new VM agent
```

**Available steps:** `deps` | `usb` | `notifications` | `agents` | `offsite` | `cron` | `run`

### Manual configuration (alternative to the wizard)

Edit `config.sh` directly — it is the **only file you need to touch**. At minimum:

```bash
USB_MOUNT="/mnt/backup-usb"
TARGET_UUID=""        # get with: blkid /dev/sdX1  (leave empty to skip UUID check)
```

See [`docs/configuration.md`](docs/configuration.md) for every option.

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
/opt/pabs/backup.sh --dry-run    # checks only, no data written
/opt/pabs/backup.sh              # full backup
```

Logs go to `/mnt/backup-usb/proxmox-backup/backup.log`.

### 5. Schedule with cron

```bash
crontab -e
```

```
# Run every Sunday at 03:00
0 3 * * 0 /opt/pabs/backup.sh
```

### 6. Add VM agent backups (optional)

Deploy the agent to each VM once — all configuration is passed from the
Proxmox host via `--set`, no SSH-in-and-edit required afterwards:

```bash
# Standard VM — auto-detect type, use defaults
./install-agent.sh root@192.168.1.10

# Minecraft VM with a non-default user and path
./install-agent.sh alice@192.168.1.40 \
    --set MINECRAFT_BASE=/home/alice/servers/backups \
    --set MINECRAFT_SERVER_BASE=/home/alice/servers

# Docker VM with Portainer
./install-agent.sh root@192.168.1.20 \
    --set DOCKER_MANAGER=portainer \
    --set PORTAINER_TOKEN=ptr_abc123
```

Then add each VM to `config.sh`:

```bash
VM_AGENTS=(
    "docker-vm    192.168.1.10   root     /opt/pabs-agent/agent.sh"
    "haos         192.168.1.20   root     /opt/pabs-agent/agent.sh"
    "mc-server    192.168.1.40   alice    /opt/pabs-agent/agent.sh"
)
```

See [`docs/vm-agents.md`](docs/vm-agents.md) for the full guide.

### 7. Set up offsite sync (optional, recommended)

```bash
apt install rclone
rclone config    # set up Google Drive, OneDrive, Backblaze, etc.
```

In `config.sh`:

```bash
RCLONE_REMOTE="gdrive:proxmox-backup"
RCLONE_KEEP_MIN=1
RCLONE_MAX_STORAGE_GB=14    # stay within Google Drive's 15 GB free tier
RCLONE_ENCRYPTION_PASSWORD="a strong passphrase"
```

See [`docs/offsite.md`](docs/offsite.md) for the full guide.

### 8. Health check

```bash
/opt/pabs/pabs-status.sh
```

Reports: USB state, latest backup integrity, VM agent reachability, offsite
remote status and storage usage, local stage space. Returns 0 (OK), 1 (error),
2 (warning).

---

## What is and isn't backed up

**Proxmox host — always backed up:**

| What | Where in backup |
|---|---|
| `/etc/pve` (cluster/node config) | `etc-pve.tar` (pmxcfs-safe tar snapshot) |
| VM and CT configs (`qm config`, `pct config`) | `vm-ct-definitions/` |
| Network, hosts, hostname, resolv.conf | `etc/` |
| APT sources | `etc/apt/` |
| Cron jobs | `etc/cron*`, `var/spool/cron/` |
| Firewall rules (nftables, iptables, PVE) | `etc/nftables.conf`, `etc/iptables/`, `etc/pve/firewall/` |
| SSH keys and daemon config | `etc/ssh/`, `root/.ssh/` |
| Installed packages (dpkg selections + holds) | `system-state/` |
| Disk layout, kernel version, Proxmox version | `system-state/` |
| ZFS pool/dataset info (if `BACKUP_ZFS=true`) | `system-state/zfs-*` |
| LVM VG configs (restorable with vgcfgrestore) | `system-state/lvm-*` |
| `/usr/local/bin`, `/root/scripts` | preserved path |
| `backup.sh` and `config.sh` (secrets redacted) | `backup.sh`, `config.sh` |

**VM/LXC agent bundles — backed up when `VM_AGENTS` is configured:**

| VM type | What's in the bundle |
|---|---|
| Docker | All `docker-compose.yml` + `.env` files, Docker daemon config, named volumes (under threshold), package list |
| Home Assistant OS | Full native HA snapshot (`.tar`) — one-click restore via HA UI |
| Minecraft | Weekly `.tar.zst` archives from `minecraft-server-setup`, `server.properties`, ops/whitelist/banned, mods, plugins |
| Generic | `/etc` (full), cron jobs, `/usr/local/bin`, `/root/scripts`, package list |

**Not backed up:**

- VM and CT disk images — not needed. Agent bundles contain full application state. Rebuild path: fresh OS → `install-agent.sh` → restore bundle. See [`docs/restore.md`](docs/restore.md).
- Docker volumes over the auto-include size threshold (configurable; opt-in via `DOCKER_INCLUDE_VOLUMES`)
- Minecraft world data directly — the agent copies archives that `minecraft-server-setup` already produced

---

## Key design properties

- **Staging on local SSD first** — USB sees one sequential write, minimising flash wear and corruption risk
- **UUID targeting** — refuses to write to any drive other than the configured one
- **Pre-commit integrity check** — SHA256 manifest verified on local SSD before any data reaches USB
- **Atomic commit** — written to `<date>.tmp/` then renamed; a partial transfer never appears as complete
- **Post-transfer verification** — manifest re-checked on USB after transfer
- **Auto space recovery** — purges the oldest backup if USB is full; refuses if it's the last copy
- **Dual-channel alerts** — Discord webhook (primary) + local mail (fallback)
- **3-2-1 offsite sync** — optional rclone sync with retention limits and transparent encryption

---

## Documentation

| Doc | Contents |
|---|---|
| [`docs/configuration.md`](docs/configuration.md) | Every `config.sh` variable with type, default, and examples |
| [`docs/vm-agents.md`](docs/vm-agents.md) | Agent setup, `--set` flags, per-type config reference |
| [`docs/offsite.md`](docs/offsite.md) | Cloud remotes, free-tier sizing, encryption, retention |
| [`docs/restore.md`](docs/restore.md) | Restore procedures, DR walkthrough, bundle extraction |
| [`docs/architecture.md`](docs/architecture.md) | Data flow, integrity guarantees, design decisions |

Run `sudo bash setup.sh` for guided setup, or edit `config.sh` directly and refer to the docs above.
