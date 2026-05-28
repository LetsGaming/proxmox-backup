# Restore procedures

Covers all restore scenarios: partial config restore on a live system, full disaster recovery from USB, full disaster recovery from offsite, and per-VM bundle restore.

Every completed PABS backup is self-contained. `proxmox-restore.sh` and `DISASTER-RECOVERY.md` are written into the backup folder at backup time. This repository is not required at restore time.

---

## Before you start

### Verify the drive

Run the health check before relying on a backup:

```bash
sudo bash /opt/pabs/pabs-status.sh
```

Check the `--- USB Drive Health ---` section. If it reports kernel I/O errors or a forced read-only remount, use the offsite copy instead, or use a backup predating the errors. See [`docs/usb-health.md`](usb-health.md) for signal interpretation.

### Verify integrity

Always verify the SHA256 manifest before restoring anything:

```bash
cd /mnt/backup-usb/proxmox-backup/<date>/
sha256sum --check MANIFEST.sha256
```

Every file in the backup is listed. Any mismatch means corruption — use a different backup or the offsite copy.

### Choose the right backup

```bash
ls /mnt/backup-usb/proxmox-backup/
# 2026-05-11_03-00-00/
# 2026-05-18_03-00-00/
# 2026-05-25_03-00-00/   ← most recent
```

Use the most recent backup unless the corruption you're recovering from was present in the latest run — in that case use an older one.

---

## Scenario 1 — Partial restore (Proxmox still running)

Use this to recover specific configs on a live system: wrong network setting, lost cron job, missing SSH key, etc.

### Mount the USB

```bash
mount /dev/sdX1 /mnt/backup-usb
cd /mnt/backup-usb/proxmox-backup/<date>/
```

### Run the interactive restore script

```bash
chmod +x proxmox-restore.sh
./proxmox-restore.sh
```

The script prompts before each section. Skip anything you don't need.

### Target a single section

```bash
./proxmox-restore.sh --section ssh        # SSH keys and daemon config only
./proxmox-restore.sh --section configs    # /etc/pve/, network, hosts, resolv.conf
./proxmox-restore.sh --section cron       # crontabs
./proxmox-restore.sh --section firewall   # nftables, iptables, PVE firewall
./proxmox-restore.sh --section packages   # dpkg package selections
./proxmox-restore.sh --section scripts    # /usr/local/bin/, /root/scripts/
./proxmox-restore.sh --section vms        # VM and CT config definitions
./proxmox-restore.sh --section vm-agents  # VM application bundles
```

### Dry-run mode (preview only, no changes)

```bash
./proxmox-restore.sh --dry-run
./proxmox-restore.sh --dry-run --section configs
```

---

## Scenario 2 — Full disaster recovery from USB

Use this after total hardware failure: new hardware, fresh Proxmox install, restore everything.

Follow `DISASTER-RECOVERY.md` inside the backup folder first — it is generated at backup time with your exact hostname, Proxmox version, disk layout, and VM list. The steps below are a summary.

### Phase 1 — Install Proxmox

Install the same Proxmox version as at backup time (recorded in `system-state/proxmox-version.txt`). Use the same hostname and IP where possible to minimise post-restore changes.

### Phase 2 — Restore Proxmox configs

```bash
mount /dev/sdX1 /mnt/backup-usb
cd /mnt/backup-usb/proxmox-backup/<date>/

# Verify before touching anything
sha256sum --check MANIFEST.sha256

chmod +x proxmox-restore.sh
./proxmox-restore.sh
```

**Restore order matters:**

1. `configs` — network, `/etc/pve/`, hosts. Do this first; reboot if network changes.
2. `ssh` — restore before trying to SSH in from another machine.
3. `firewall` — restore after network is confirmed working.
4. `cron` — restore after services are up.
5. `packages` — run `apt-get dselect-upgrade` after (requires internet).
6. `scripts` — `/usr/local/bin/`, `/root/scripts/`.
7. `vms` — VM/CT config definitions (reference specs; VMs need fresh OS installs).
8. `vm-agents` — restores application state into each VM (see Phase 3).

**Restoring `/etc/pve/`:**

Do not extract `etc-pve.tar` wholesale onto a live Proxmox node — it can corrupt the cluster database. Restore individual files selectively:

```bash
# Inspect
tar -tf etc-pve.tar

# Restore a single file (e.g. storage config)
tar -C / -xf etc-pve.tar etc/pve/storage.cfg

# Restore all firewall rules
tar -C / -xf etc-pve.tar --wildcards 'etc/pve/firewall/*'
```

### Phase 3 — Rebuild VMs

VM disk images are not backed up — and not needed. Each agent bundle contains the full application state. Rebuild path for each VM:

1. Create fresh VM/LXC in Proxmox (use `vm-ct-definitions/` for the specs)
2. Install base OS
3. Deploy the PABS agent: `./install-agent.sh <user>@<new-ip>`
4. Restore the bundle (see [VM bundle restore](#vm-bundle-restore) below)

### Phase 4 — Verify

```bash
# Proxmox WebUI
https://<hostname>:8006

# Network
ip link show && ip addr show

# Storage
pvesm status

# VMs / CTs
qm list && pct list

# Backup integrity on USB
sha256sum --check MANIFEST.sha256
```

---

## Scenario 3 — Full disaster recovery from offsite

Use this when the USB stick is lost, damaged, or unavailable.

### Prerequisites

You need your `RCLONE_ENCRYPTION_PASSWORD` and `RCLONE_ENCRYPTION_SALT` (if set). Retrieve them from your password manager before proceeding. Without them, the offsite data cannot be decrypted.

### Step 1 — Install rclone and configure the base remote

```bash
apt install rclone
rclone config   # re-configure the same remote as on the original host
```

### Step 2 — Re-create the encryption wrapper (if encryption was enabled)

```bash
rclone config create pabs_crypt_runtime crypt \
    remote                  "gdrive:proxmox-backup" \
    filename_encryption     standard \
    directory_name_encryption true \
    password                "$(rclone obscure 'YOUR_MAIN_PASSWORD')" \
    password2               "$(rclone obscure 'YOUR_SALT')"   # omit if no salt was set
```

Access the data as `pabs_crypt_runtime:` going forward.

### Step 3 — Download the backup

```bash
# List available backups
rclone lsf pabs_crypt_runtime:    # encrypted remote
# or without encryption:
rclone lsf gdrive:proxmox-backup

# Download a specific backup
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

### Docker

```bash
cd /tmp/restore-my-vm

# Restore compose projects
cp -r compose/ /opt/stacks/      # adjust path to match your setup

# Bring services up
cd /opt/stacks/myapp
docker compose up -d
```

If Portainer stack exports are present (`portainer-stacks/`), import them via the Portainer UI or API.

### Home Assistant OS

The bundle contains a native HA snapshot (`.tar`). Restore via:

**HA UI:** Settings → System → Backups → ⋮ → Upload backup → select the `.tar` → Restore

**CLI (SSH add-on):**
```bash
ha backup restore <slug>
```

The slug is the filename without the `.tar` extension, visible in the HA UI after uploading.

### Minecraft

```bash
cd /tmp/restore-my-vm

# The restore-notes.txt contains the full procedure for this instance.
# General approach: stop the server, extract the archive, start.
tar -I zstd -xf weekly-archives/survival-world-2026-05-25.tar.zst \
    -C /home/minecraft/minecraft-server/
```

### Generic VM/LXC

```bash
cd /tmp/restore-my-vm

# Restore /etc/
rsync -a etc/ /etc/

# Restore scripts
rsync -a usr/local/bin/ /usr/local/bin/

# Restore packages (requires internet)
dpkg --set-selections < package-list.txt
apt-get dselect-upgrade
```

### Restore via the interactive script (`--section vm-agents`)

The restore script handles VM bundle restore with prompts:

```bash
./proxmox-restore.sh --section vm-agents
```

It lists available bundles, prompts per VM, and handles type-specific steps. For Minecraft VMs that received a new IP after a hardware rebuild:

```bash
./proxmox-restore.sh --section vm-agents --mc-ip 192.168.1.41
```

---

## Section reference

| Section | What is restored | Notes |
| :------ | :--------------- | :---- |
| `configs` | `/etc/pve/`, `/etc/network/`, `/etc/hosts`, `/etc/hostname`, `/etc/resolv.conf`, APT sources | Restore first; reboot if network config changes |
| `ssh` | `/etc/ssh/`, `/root/.ssh/` | Includes host keys and `authorized_keys` |
| `firewall` | `/etc/nftables.conf`, `/etc/iptables/`, `/etc/pve/firewall/` | Only formats present at backup time are restored |
| `cron` | `/etc/crontab`, `/etc/cron.d/`, `/var/spool/cron/` | |
| `packages` | dpkg selections, apt marks, held packages | Reinstall with `apt-get dselect-upgrade` |
| `scripts` | `/usr/local/bin/`, `/root/scripts/` | |
| `vms` | `vm-ct-definitions/` — `qm config` and `pct config` exports | Config reference only; VMs need fresh OS installs |
| `vm-agents` | `vm-agents/<label>/` — application bundles | Requires fresh OS on each VM first |