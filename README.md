# PABS — Proxmox Automated Backup System

Backs up a Proxmox node's configuration, VM/CT definitions, network settings,
cron jobs, SSH keys, package state, and Minecraft weekly archives to a USB
stick. Designed to be power-loss safe and restore-ready out of the box.

---

## File layout

```
pabs/
├── backup.sh              Entry point — run this (or schedule it in cron)
├── config.sh              Your configuration — the only file you need to edit
├── install-agent.sh       One-time setup: deploys the VM agent to a VM over SSH
├── INTEGRATION.md         Step-by-step guide for adding VM agent support
├── lib/
│   ├── core.sh            Logging, lock management, trap, and notifications
│   ├── preflight.sh       Pre-flight validation (USB, space checks)
│   ├── sections.sh        The 8 backup sections and their helper functions
│   ├── manifest.sh        SHA256 manifest generation/verification and rotation
│   └── output.sh          Generates the restore script and README in each backup
└── vm-agent/              Agent deployed to each VM/LXC for lightweight backups
    ├── agent.sh           Entry point — called by PABS over SSH
    └── types/
        ├── docker.sh      Docker VMs (with or without a manager like Dockge/Portainer)
        ├── haos.sh        Home Assistant OS (triggers native HA snapshot)
        ├── minecraft.sh   Minecraft VMs (works with minecraft-server-setup)
        └── generic.sh     All other VMs and LXCs (Pi-hole, AdGuard, plain Debian, etc.)
```

Every completed backup on the USB also contains a self-contained
`proxmox-restore.sh` — no dependency on this repository at restore time.

---

## Setup

### 1. Install the scripts

```bash
git clone <repo> /opt/pabs
chmod +x /opt/pabs/backup.sh
```

Or copy the `pabs/` directory wherever you prefer. The scripts resolve their
own location at runtime, so they work from any path.

### 2. Edit config.sh

Open `config.sh` and fill in:

| Variable | What to set |
|---|---|
| `USB_MOUNT` | Mount point of your USB stick |
| `TARGET_UUID` | UUID of the USB partition (`blkid /dev/sdX1`) |
| `VM_AGENTS` | List of VMs/LXCs to back up via the agent (leave empty to skip) |
| `VM_SSH_KEY` | Shared SSH key for VM agent connections (leave empty for default) |
| `DISCORD_WEBHOOK` | Discord webhook URL for alerts (leave empty to disable) |
| `NOTIFY_EMAIL` | Fallback email for failure alerts (leave empty to disable) |

Everything else has sensible defaults.

### 3. Set up VM agent backups (optional)

PABS can back up your VMs and LXCs with a lightweight agent — collecting only
what's needed to restore each one, not full disk images. Supported types:

| VM type | What gets backed up |
|---|---|
| **Docker VM** | All `docker-compose.yml` + `.env` files, Docker daemon config, package list. Works with or without a manager (Dockge, Portainer). |
| **Home Assistant OS** | Full native HA snapshot (`.tar`) via the `ha` CLI — one-click restore via the HA UI. |
| **Generic LXC / VM** | `/etc` (full), cron jobs, scripts, package list. Covers Pi-hole, AdGuard, Nginx, and any plain Debian/Ubuntu service. |

**Deploy the agent to each VM:**

```bash
# From the Proxmox host — run once per VM/LXC
chmod +x /opt/pabs/install-agent.sh
/opt/pabs/install-agent.sh root@<vm-ip>

# With a dedicated SSH key (recommended)
/opt/pabs/install-agent.sh root@<vm-ip> --key /root/.ssh/id_ed25519_pabs_agent
```

This copies `vm-agent/` to the VM, installs dependencies, and prints the
`VM_AGENTS` line to add to `config.sh`. Then review `/etc/pabs-agent/config`
on the VM to adjust any type-specific settings.

**Add VMs to config.sh:**

```bash
VM_AGENTS=(
    "docker-vm    192.168.1.10   root    /opt/pabs-agent/agent.sh"
    "haos         192.168.1.20   root    /opt/pabs-agent/agent.sh"
    "pihole-lxc   192.168.1.30   root    /opt/pabs-agent/agent.sh"
)
```

See `INTEGRATION.md` for the full setup guide, all configuration options,
and how to integrate the new section into the existing PABS scripts.

### 4. Mount your USB stick

```bash
# Find the device
lsblk

# Mount it
mount /dev/sdX1 /mnt/backup-usb

# Or add to /etc/fstab for auto-mount:
# UUID=<your-uuid>  /mnt/backup-usb  vfat  defaults,nofail  0  0
```

### 5. Test run

```bash
/opt/pabs/backup.sh
```

Check `/mnt/backup-usb/proxmox-backup/backup.log` for results.

### 6. Schedule with cron

```bash
crontab -e
```

Add (runs every Sunday at 03:00):

```
0 3 * * 0 /opt/pabs/backup.sh
```

### Minecraft integration

PABS backs up Minecraft via the VM agent (type=`minecraft`), designed to work
in tandem with **[LetsGaming/minecraft-server-setup](https://github.com/LetsGaming/minecraft-server-setup)**.

Deploy the agent to the Minecraft VM the same way as any other VM:

```bash
./install-agent.sh root@<mc-vm-ip>
```

Then add it to `VM_AGENTS` in `config.sh`:

```bash
VM_AGENTS=(
    "minecraft-vm  192.168.1.40  minecraft  /opt/pabs-agent/agent.sh"
)
```

The agent auto-detects the type as `minecraft` (looks for the `minecraft` system
user and the default `minecraft-server-setup` directory layout). It backs up:

- Weekly `.tar.zst` archives produced by `minecraft-server-setup` (age-gated to
  avoid in-progress files)
- `server.properties`, `ops.json`, `whitelist.json`, `banned-*.json`
- `mods/` and `plugins/` directories
- Optionally daily archives (set `MC_KEEP_DAILY` in `/etc/pabs-agent/config`)

All options (`MINECRAFT_BASE`, keep counts, age-gate, daily archives) are
configured in `/etc/pabs-agent/config` on the Minecraft VM itself — the
defaults match an unmodified `minecraft-server-setup` install without any
changes needed.

---

## Restoring from a backup

The USB contains a self-contained restore script inside each backup folder:

```bash
# Mount the USB on the new/recovered system
mount /dev/sdX1 /mnt/backup-usb

# Navigate to the backup you want
cd /mnt/backup-usb/proxmox-backup/2025-06-01_03-00

# Run the interactive restore
chmod +x proxmox-restore.sh
./proxmox-restore.sh

# Dry-run mode (no changes made)
./proxmox-restore.sh --dry-run

# Restore only one section
./proxmox-restore.sh --section ssh

# If the Minecraft VM got a new IP after a rebuild
./proxmox-restore.sh --section minecraft --mc-ip 10.0.0.50
```

**Available sections:** `configs` | `vms` | `cron` | `firewall` | `ssh` | `packages` | `scripts` | `minecraft`

### Restoring VM agent bundles

Each VM bundle is stored separately under `vm-agents/<label>/` and contains
its own `restore-notes.txt` with type-specific instructions.

```bash
# Inspect a bundle without extracting
zstd -d vm-agents/docker-vm/pabs-bundle-*.tar.zst --stdout | tar -t

# Read the restore instructions
zstd -d vm-agents/docker-vm/pabs-bundle-*.tar.zst --stdout \
    | tar -x --to-stdout restore-notes.txt

# Extract everything
mkdir restore-docker && \
    zstd -d vm-agents/docker-vm/pabs-bundle-*.tar.zst --stdout \
    | tar -x -C restore-docker/
```

**HAOS:** the bundle contains a native `.tar` snapshot. Restore via
Settings → Backups → Upload in the HA UI, or `ha backup restore <slug>` via CLI.

### Verify integrity before restoring

```bash
cd /mnt/backup-usb/proxmox-backup/2025-06-01_03-00
sha256sum --check MANIFEST.sha256
```

---

## What is and isn't backed up

**Backed up:**
- `/etc/pve` — Proxmox cluster/node config (tar snapshot, pmxcfs-safe)
- VM and CT config exports (`qm config`, `pct config`)
- `/etc/network`, `/etc/hosts`, `/etc/hostname`, `/etc/resolv.conf`
- `/etc/apt/sources.list*`
- Cron jobs (`/etc/crontab`, `/etc/cron.d`, user crontabs)
- Firewall rules (nftables, iptables, Proxmox firewall)
- SSH keys and daemon config
- Installed package list (dpkg selections, holds)
- Disk layout, kernel version, Proxmox version
- ZFS pool/dataset info (if `BACKUP_ZFS="true"`)
- `/usr/local/bin`, `/root/scripts`
- **VM/LXC restore bundles** (if `VM_AGENTS` is configured) — compose files for Docker VMs, native snapshots for HAOS, weekly archives + server config for Minecraft, `/etc` + package list for generic LXCs

**Not backed up:**
- VM and CT disk images — **not needed**. Agent bundles (see above) contain the full application state for each VM and replace `vzdump`. For disaster recovery: fresh OS install → deploy agent → restore bundle. See `DISASTER-RECOVERY.md` (generated inside each backup) for the full procedure.
- Docker container data volumes beyond the auto-include size threshold (configurable per VM in `/etc/pabs-agent/config`)
- Minecraft world data directly — the agent copies the `.tar.zst` archives produced by `minecraft-server-setup`; world data is whatever that tool chose to include

---

## Key design properties

- **Staging on local SSD first** — the USB drive sees one sequential write at the end, minimising flash wear and corruption risk from interrupted writes
- **UUID targeting** — won't write to the wrong drive if a different USB is mounted
- **Pre-commit integrity check** — SHA256 manifest is verified on local SSD before any data reaches the USB; a corrupt staging write aborts cleanly
- **Atomic commit** — data is written to `<date>.tmp/` then renamed; a partial transfer never appears as a complete backup
- **Post-transfer verification** — manifest is re-checked on the USB after transfer
- **Auto space recovery** — purges the oldest backup if the USB is full, refuses if it's the last one
- **Dual-channel alerts** — Discord webhook (primary) + local mail (fallback)