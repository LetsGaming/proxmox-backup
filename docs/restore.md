# Restoring from a PABS Backup

This document covers all restore scenarios: partial config restore, full
disaster recovery from USB, full disaster recovery from offsite, and
per-VM bundle restore.

Each completed PABS backup is self-contained — `proxmox-restore.sh` and
`DISASTER-RECOVERY.md` are written into every backup folder at backup time.
You do not need this repository or PABS itself to restore.

---

## Before you start

### Verify integrity first

Always verify the SHA256 manifest before restoring anything:

```bash
cd /mnt/backup-usb/proxmox-backup/<date>
sha256sum --check MANIFEST.sha256
```

Every file in the backup is listed. Any mismatch indicates corruption —
use a different backup or the offsite copy.

### Choose the right backup

```bash
ls /mnt/backup-usb/proxmox-backup/
# 2026-05-18_03-00-00/
# 2026-05-25_03-00-00/
# 2026-06-01_03-00-00/   ← most recent
```

Use the most recent backup unless you are recovering from data corruption
that was already present in the latest run (in which case use an older one).

---

## Scenario 1 — Partial restore (Proxmox is still running)

Use this when you need to recover specific configs on a live system —
wrong network setting, lost cron job, missing SSH key, etc.

### Mount the USB

```bash
mount /dev/sdX1 /mnt/backup-usb
cd /mnt/backup-usb/proxmox-backup/<date>
```

### Run the interactive restore script

```bash
chmod +x proxmox-restore.sh
./proxmox-restore.sh
```

The script prompts before each section. Skip anything you don't need.

### Run a single section only

```bash
./proxmox-restore.sh --section ssh        # SSH keys and daemon config only
./proxmox-restore.sh --section configs    # /etc/pve, network, hosts, resolv.conf
./proxmox-restore.sh --section cron       # crontabs
./proxmox-restore.sh --section firewall   # nftables, iptables, PVE firewall
./proxmox-restore.sh --section packages   # dpkg package selections
./proxmox-restore.sh --section scripts    # /usr/local/bin, /root/scripts
./proxmox-restore.sh --section vms        # VM and CT config definitions
./proxmox-restore.sh --section vm-agents  # restore VM agent bundle(s)
```

### Dry-run mode (preview only, no changes)

```bash
./proxmox-restore.sh --dry-run
./proxmox-restore.sh --dry-run --section configs
```

---

## Scenario 2 — Full disaster recovery from USB

Use this after total hardware failure: new hardware, fresh Proxmox install,
restore everything.

Follow `DISASTER-RECOVERY.md` inside the backup folder — it is generated at
backup time with your exact hostname, Proxmox version, and VM list. The steps
below are a summary.

### Phase 1 — Install Proxmox

Install the same Proxmox version as at backup time (recorded in
`system-state/proxmox-version.txt`). Use the same hostname and IP if possible
to minimise changes needed after restore.

### Phase 2 — Restore Proxmox configs

```bash
# Mount USB
mount /dev/sdX1 /mnt/backup-usb
cd /mnt/backup-usb/proxmox-backup/<date>

# Verify integrity
sha256sum --check MANIFEST.sha256

# Restore (interactive — skip sections you don't need)
chmod +x proxmox-restore.sh
./proxmox-restore.sh
```

**Restore order matters:**

1. `configs` — network, `/etc/pve`, hosts. Do this first; reboot if network changes.
2. `ssh` — restore SSH keys before trying to SSH in from another machine.
3. `firewall` — restore after network is working.
4. `cron` — restore after services are up.
5. `packages` — run `apt-get dselect-upgrade` (requires internet).
6. `scripts` — `/usr/local/bin`, `/root/scripts`.
7. `vms` — VM/CT config definitions (specs reference; VMs need fresh OS install).
8. `vm-agents` — restores application state into each VM (see Phase 3).

**Restoring `/etc/pve`:**

Do not extract `etc-pve.tar` wholesale onto a live Proxmox node — it can
corrupt the cluster DB. Restore individual files selectively:

```bash
# Inspect contents
tar -tf etc-pve.tar

# Restore a specific file (e.g. storage config)
tar -C / -xf etc-pve.tar etc/pve/storage.cfg

# Restore all firewall rules
tar -C / -xf etc-pve.tar --wildcards 'etc/pve/firewall/*'
```

### Phase 3 — Rebuild VMs

VM disk images are not backed up — and not needed. Each agent bundle contains
the full application state. The rebuild path is:

1. Create fresh VM/LXC in Proxmox (use `vm-ct-definitions/` for specs)
2. Install base OS
3. Deploy the PABS agent: `./install-agent.sh <user>@<new-ip>`
4. Restore the bundle (see [VM bundle restore](#vm-bundle-restore) below)

### Phase 4 — Verify

```bash
# Proxmox WebUI
https://<hostname>:8006

# Network
ip link show
ip addr show

# Storage
pvesm status

# VMs/CTs
qm list
pct list

# Backup integrity on USB
sha256sum --check MANIFEST.sha256
```

---

## Scenario 3 — Full disaster recovery from offsite

Use this when the USB stick is lost, damaged, or unavailable.

### If offsite encryption was enabled

You need your `RCLONE_ENCRYPTION_PASSWORD` and `RCLONE_ENCRYPTION_SALT`
(if set). Retrieve them from your password manager before proceeding.
Without them, the offsite data cannot be decrypted.

### Step 1 — Install rclone and configure the base remote

```bash
apt install rclone
rclone config   # re-configure the same remote as on the original host
```

### Step 2 — Re-create the encryption wrapper (if encryption was enabled)

```bash
rclone config create pabs_crypt_runtime crypt \
    remote          "gdrive:proxmox-backup" \
    filename_encryption standard \
    directory_name_encryption true \
    password        "$(rclone obscure 'YOUR_MAIN_PASSWORD')" \
    password2       "$(rclone obscure 'YOUR_SALT')"    # omit if no salt was set
```

Access the remote as `pabs_crypt_runtime:` going forward.

### Step 3 — Download the backup

```bash
# List available backups
rclone lsf pabs_crypt_runtime:    # encrypted remote
# or: rclone lsf gdrive:proxmox-backup    # unencrypted remote

# Download the most recent backup
mkdir -p /mnt/restore
rclone copy "pabs_crypt_runtime:<YYYY-MM-DD_HH-MM-SS>" /mnt/restore/ --progress
```

### Step 4 — Verify and restore

```bash
cd /mnt/restore
sha256sum --check MANIFEST.sha256
chmod +x proxmox-restore.sh
./proxmox-restore.sh
```

From here, follow the same Phase 2–4 steps as [Scenario 2](#scenario-2----full-disaster-recovery-from-usb).

---

## VM bundle restore

### Inspect a bundle

```bash
# List contents
tar -I zstd -tf vm-agents/my-vm/pabs-bundle-my-vm-<date>.tar.zst

# Read restore instructions
tar -I zstd -xOf vm-agents/my-vm/pabs-bundle-my-vm-<date>.tar.zst restore-notes.txt
```

### Extract a bundle

```bash
mkdir /tmp/restore-my-vm
tar -I zstd -xf vm-agents/my-vm/pabs-bundle-my-vm-<date>.tar.zst \
    -C /tmp/restore-my-vm
```

### Docker VM

```bash
# After deploying a fresh VM and running install-agent.sh:
cd /tmp/restore-my-vm

# Restore compose projects
cp -r compose/ /opt/stacks/      # adjust path to match your setup

# Bring services up
cd /opt/stacks/myapp
docker compose up -d
```

If Portainer stack exports are present (`portainer-stacks/`), import them
via the Portainer UI or API.

### Home Assistant OS

The bundle contains a native HA snapshot (`.tar`). Restore via:

**HA UI:** Settings → System → Backups → Three-dot menu → Upload backup → select the `.tar` file → Restore

**CLI (SSH add-on):**
```bash
ha backup restore <slug>
```

The slug is the filename without the `.tar` extension, visible in the HA UI
after uploading.

### Minecraft

```bash
# After deploying a fresh VM with minecraft-server-setup:
cd /tmp/restore-my-vm

# Find the weekly archive
ls weekly-archives/

# The restore-notes.txt inside the bundle contains the full procedure.
# Generally: stop the server, extract the archive, start the server.
tar -I zstd -xf weekly-archives/survival-world-2026-05-25.tar.zst \
    -C /home/minecraft/minecraft-server/
```

### Generic VM/LXC

```bash
cd /tmp/restore-my-vm

# Restore /etc
rsync -a etc/ /etc/

# Restore scripts
rsync -a usr/local/bin/ /usr/local/bin/

# Restore packages (requires internet)
dpkg --set-selections < package-list.txt
apt-get dselect-upgrade
```

---

## Restoring from within the restore script (`--section vm-agents`)

The interactive restore script handles VM bundle restore with prompts:

```bash
./proxmox-restore.sh --section vm-agents
```

It lists available bundles, prompts per VM, and handles the type-specific
restore steps automatically. For Minecraft VMs that got a new IP after
a hardware rebuild:

```bash
./proxmox-restore.sh --section vm-agents --mc-ip 192.168.1.41
```

---

## Reference: what each backup section contains

| Section | Files restored | Notes |
|---|---|---|
| `configs` | `/etc/pve`, `/etc/network`, `/etc/hosts`, `/etc/hostname`, `/etc/resolv.conf`, APT sources | Restore first; may require reboot if network changes |
| `ssh` | `/etc/ssh/`, `/root/.ssh/` | Includes host keys and authorized_keys |
| `firewall` | `/etc/nftables.conf`, `/etc/iptables/`, `/etc/pve/firewall/` | Only the rules formats present at backup time are restored |
| `cron` | `/etc/crontab`, `/etc/cron.d/`, `/var/spool/cron/` | |
| `packages` | dpkg selections, apt marks, holds | Reinstall with `apt-get dselect-upgrade` |
| `scripts` | `/usr/local/bin/`, `/root/scripts/` | |
| `vms` | `vm-ct-definitions/` — `qm config` and `pct config` exports | Config reference only; VMs need fresh OS install |
| `vm-agents` | `vm-agents/<label>/` — application bundles | Requires fresh OS on each VM first |
