#!/bin/bash
# =============================================================================
# PABS Configuration
# Proxmox Automated Backup System — v3.3
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
# (roughly: all configs + Minecraft archives + VM agent bundles combined).
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
# VM / LXC AGENT BACKUPS
# -----------------------------------------------------------------------------
# Each entry backs up one VM or LXC using the PABS agent installed on that
# host. The agent auto-detects the VM type and produces a minimal,
# restore-ready bundle:
#
#   docker  — all docker-compose.yml + .env files, Docker daemon config,
#             package list. Works with or without a manager (Dockge, Portainer).
#   haos    — full native HA snapshot (.tar) via the ha CLI — one-click
#             restore via the HA UI or ha backup restore <slug>.
#   generic — /etc (full), cron jobs, scripts, package list. Covers Pi-hole,
#             AdGuard, Nginx, and any plain Debian/Ubuntu LXC or VM.
#
# The agent is deployed once per VM with install-agent.sh, and its behaviour
# is configured via /etc/pabs-agent/config on each VM. See INTEGRATION.md
# for the full setup guide and all available options.
#
# FORMAT:  "label  ip-or-hostname  ssh-user  /path/to/agent.sh"
#
#   label       Short name. Used for the backup subfolder and log output.
#               Must be unique. Use lowercase-with-dashes.
#   ip/host     Address reachable from this Proxmox host.
#   ssh-user    SSH user on the VM. Needs read access to config paths,
#               write access to /tmp, and permission to run the agent.
#               Typically 'root' for LXCs, or a dedicated 'backup' user.
#   agent-path  Full path to agent.sh on the remote VM.
#               Default install location: /opt/pabs-agent/agent.sh
#
# EXAMPLE:
#   VM_AGENTS=(
#       "docker-vm    192.168.1.10   root    /opt/pabs-agent/agent.sh"
#       "haos         192.168.1.20   root    /opt/pabs-agent/agent.sh"
#       "pihole-lxc   192.168.1.30   root    /opt/pabs-agent/agent.sh"
#       "adguard-lxc  192.168.1.31   backup  /opt/pabs-agent/agent.sh"
#   )
#
# Leave empty to skip VM agent backups entirely:
VM_AGENTS=()

# Shared SSH key for all VM agent connections.
# Leave empty to use the Proxmox host's default key (~/.ssh/id_ed25519 etc.)
# Recommended: use a dedicated key so rotating root's default key doesn't
# silently break agent backups.
#   Generate: ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519_pabs_agent -N ""
#   Deploy:   ssh-copy-id -i /root/.ssh/id_ed25519_pabs_agent.pub root@<vm-ip>
VM_SSH_KEY=""

# Per-VM SSH key override — set VM_SSH_KEY_<label> (dashes become underscores).
# Takes precedence over VM_SSH_KEY for that specific VM.
# Example for label "docker-vm":
#   VM_SSH_KEY_docker_vm="/root/.ssh/id_ed25519_dockervm"

# How many agent bundles to keep per VM on the USB before rotating old ones.
# Set to 1 to keep only the latest (saves space — especially for HAOS snapshots
# which can be 500MB+).
VM_AGENT_KEEP_BUNDLES=2

# SSH options applied to every VM agent connection.
# Adjust ConnectTimeout if VMs are slow to respond.
# StrictHostKeyChecking=yes is used for cron safety (TOFU attack prevention).
# Run install-agent.sh to register host keys in /root/.ssh/pabs_known_hosts first.
VM_AGENT_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 \
                   -o StrictHostKeyChecking=yes \
                   -o UserKnownHostsFile=/root/.ssh/pabs_known_hosts)

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
# Default is "true" because ZFS is the standard Proxmox installer choice since PVE 6.x.
# Set to "false" only on setups that do not use ZFS at all.
BACKUP_ZFS="true"

# =============================================================================
# INTERNAL VARS — do not edit below this line
# =============================================================================

SCRIPT_VERSION="3.3"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")

BACKUP_ROOT="$USB_MOUNT/proxmox-backup"
STAGE_DIR="$LOCAL_STAGE_BASE/.tmp-$DATE"
FINAL_DIR="$BACKUP_ROOT/$DATE"

# Persistent log lives outside per-backup dirs so it survives rotation
LOG="$BACKUP_ROOT/backup.log"
LOCK_FILE="$LOCAL_STAGE_BASE/.backup.lock"

WARNINGS=0
ERRORS=0
