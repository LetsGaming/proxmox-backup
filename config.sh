#!/bin/bash
# =============================================================================
# PABS Configuration
# Proxmox Automated Backup System — v3.2
#
# This is the ONLY file you need to edit for a standard setup.
# All other files are library code that should not require changes.
# =============================================================================

# -----------------------------------------------------------------------------
# USB TARGET
# -----------------------------------------------------------------------------

# Mount point of your USB stick
USB_MOUNT="/mnt/backup-usb"

# UUID of the USB partition — get this with: blkid /dev/sdX1
# Leave empty to skip UUID check (less safe — any drive at USB_MOUNT will be used)
TARGET_UUID=""

# How many completed weekly backups to keep before rotating old ones
KEEP_BACKUPS=4

# -----------------------------------------------------------------------------
# LOCAL STAGING
# -----------------------------------------------------------------------------
# All backup data is assembled here on the Proxmox host's own disk first.
# The USB drive sees only a single sequential write at the very end.
# This directory needs enough free space to hold one full backup
# (roughly: all configs + Minecraft archives combined).
#
# DEFAULT: /var/tmp/pabs-stage  (survives reboots, lives on root LVM)
#
# ⚠  On Proxmox nodes with a small root partition (common with LVM-thin or
#    ZFS installs), root may only be 20–30 GB. If your archives are large,
#    point this at a bigger volume instead:
#
#    ZFS install:        LOCAL_STAGE_BASE="/rpool/data/pabs-stage"
#    Directory storage:  LOCAL_STAGE_BASE="/mnt/pve/mystore/pabs-stage"
#
# The script will warn at startup if the staging filesystem is the same
# device as / and has less than LOCAL_STAGE_WARN_GB free.
LOCAL_STAGE_BASE="/var/tmp/pabs-stage"
LOCAL_STAGE_WARN_GB=5

# -----------------------------------------------------------------------------
# MINECRAFT VM (KVM guest)
# -----------------------------------------------------------------------------
# Minecraft runs inside a KVM VM — its filesystem is opaque to the Proxmox
# host. Archives are pulled over SSH from inside the guest.

# IP address of the Minecraft VM (must be reachable from the Proxmox host).
# Leave empty to skip Minecraft backups entirely.
MC_VM_IP=""

# SSH user inside the VM (must have read access to MINECRAFT_BASE)
MC_VM_USER="minecraft"

# Path INSIDE the Minecraft VM where instance directories live
MINECRAFT_BASE="/home/minecraft/minecraft-server/scripts"

# Only copy archives whose mtime is older than this many minutes.
# Guards against copying a .tar.zst that the guest is still compressing.
# The VM backup script takes up to ~2 min; 5 gives a comfortable margin.
# Set to 0 to disable the age check (not recommended).
MC_ARCHIVE_MIN_AGE_MINUTES=5

# How many weekly Minecraft archive files to keep per instance
KEEP_WEEKLY_ARCHIVES=4

# SSH identity file for the Minecraft VM connection.
# Leave empty to use the default key (~/.ssh/id_rsa or ~/.ssh/id_ed25519).
# For hardened setups, use a dedicated restricted key so rotating root's
# default identity doesn't silently break Minecraft backups.
#   Generate: ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519_mc_backup
MC_SSH_KEY=""

# -----------------------------------------------------------------------------
# NOTIFICATIONS
# -----------------------------------------------------------------------------

# Discord webhook URL — alerts fire on failure, space recovery, and success.
# Create one at: Server Settings → Integrations → Webhooks
# Leave empty to disable.
DISCORD_WEBHOOK=""

# Email address for fallback failure alerts (leave empty to disable).
# Requires: apt install mailutils + a working MTA (e.g. postfix/nullmailer)
NOTIFY_EMAIL=""

# -----------------------------------------------------------------------------
# OPTIONAL FEATURES
# -----------------------------------------------------------------------------

# Set to "true" to export ZFS pool/dataset layout into system-state/
BACKUP_ZFS="false"

# =============================================================================
# INTERNAL VARS — do not edit below this line
# =============================================================================

SCRIPT_VERSION="3.2"
DATE=$(date +"%Y-%m-%d_%H-%M")

BACKUP_ROOT="$USB_MOUNT/proxmox-backup"
STAGE_DIR="$LOCAL_STAGE_BASE/.tmp-$DATE"
FINAL_DIR="$BACKUP_ROOT/$DATE"

# Persistent log lives outside per-backup dirs so it survives rotation
LOG="$BACKUP_ROOT/backup.log"
LOCK_FILE="$LOCAL_STAGE_BASE/.backup.lock"

WARNINGS=0
ERRORS=0

# SSH options array for every MC_VM connection — array avoids word-splitting
# issues when a path with spaces is used in the identity file argument.
SSH_OPTS=( -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new )

if [[ -n "$MC_SSH_KEY" ]]; then
    if [[ -f "$MC_SSH_KEY" ]]; then
        SSH_OPTS+=( -i "$MC_SSH_KEY" )
    else
        echo "WARNING: MC_SSH_KEY is set but the file was not found: $MC_SSH_KEY" >&2
    fi
fi