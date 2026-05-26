# PABS — Proxmox Automated Backup System

Backs up a Proxmox node's configuration, VM/CT definitions, network settings,
cron jobs, SSH keys, package state, and Minecraft weekly archives to a USB
stick. Designed to be power-loss safe and restore-ready out of the box.

---

## File layout

```
pabs/
├── backup.sh          Entry point — run this (or schedule it in cron)
├── config.sh          Your configuration — the only file you need to edit
└── lib/
    ├── core.sh        Logging, lock management, trap, and notifications
    ├── preflight.sh   Pre-flight validation (USB, space checks)
    ├── sections.sh    The 8 backup sections and their helper functions
    ├── manifest.sh    SHA256 manifest generation/verification and rotation
    └── output.sh      Generates the restore script and README in each backup
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
| `MC_VM_IP` | IP of the Minecraft KVM guest (leave empty to skip) |
| `DISCORD_WEBHOOK` | Discord webhook URL for alerts (leave empty to disable) |
| `NOTIFY_EMAIL` | Fallback email for failure alerts (leave empty to disable) |

Everything else has sensible defaults.

### 3. Set up passwordless SSH to the Minecraft VM

The script connects to the Minecraft VM as `MC_VM_USER` to pull archives.
Root on the Proxmox host needs an SSH key that the VM trusts:

```bash
# Generate a dedicated backup key (recommended)
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519_mc_backup -N ""

# Copy the public key to the VM
ssh-copy-id -i /root/.ssh/id_ed25519_mc_backup.pub minecraft@<MC_VM_IP>

# Set MC_SSH_KEY="/root/.ssh/id_ed25519_mc_backup" in config.sh
```

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

If Minecraft also runs a weekly backup, make sure it finishes before PABS
starts. The default `MC_ARCHIVE_MIN_AGE_MINUTES=5` in `config.sh` provides
a safety margin, but scheduling the host backup a couple of hours after the
VM backup is the safest approach.

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
- Minecraft weekly archives (pulled from KVM guest via SSH)

**Not backed up:**
- VM and CT disk images — use Proxmox's built-in `vzdump` for those
- Minecraft world data (only the weekly archive files created by your MC backup script)

---

## Key design properties

- **Staging on local SSD first** — the USB drive sees one sequential write at the end, minimising flash wear and corruption risk from interrupted writes
- **UUID targeting** — won't write to the wrong drive if a different USB is mounted
- **Pre-commit integrity check** — SHA256 manifest is verified on local SSD before any data reaches the USB; a corrupt staging write aborts cleanly
- **Atomic commit** — data is written to `<date>.tmp/` then renamed; a partial transfer never appears as a complete backup
- **Post-transfer verification** — manifest is re-checked on the USB after transfer
- **Auto space recovery** — purges the oldest backup if the USB is full, refuses if it's the last one
- **Dual-channel alerts** — Discord webhook (primary) + local mail (fallback)