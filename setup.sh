#!/bin/bash
# =============================================================================
# setup.sh — PABS Interactive Setup Wizard
#
# Guides you through the complete PABS setup:
#   1. Dependency installation
#   2. USB stick configuration
#   3. Notification setup (Discord / email)
#   4. VM agent deployment
#   5. Offsite sync + encryption
#   6. Cron scheduling
#   7. First backup run
#
# Safe to re-run — skips steps already completed and offers to update
# values that are already configured.
#
# Usage:
#   bash setup.sh                # full wizard
#   bash setup.sh --step usb    # jump to a specific step
#   bash setup.sh --yes         # accept defaults without prompting (CI use)
#
# Steps: deps | usb | notifications | agents | offsite | cron | run
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/config.sh"
INSTALL_AGENT="$SCRIPT_DIR/install-agent.sh"
BACKUP_SCRIPT="$SCRIPT_DIR/backup.sh"
STATUS_SCRIPT="$SCRIPT_DIR/pabs-status.sh"

# Wizard state
JUMP_STEP=""
AUTO_YES=false
CHANGED=false   # whether config.sh was modified — triggers final reminder

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --step) JUMP_STEP="$2"; shift 2 ;;
        --yes)  AUTO_YES=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--step STEP] [--yes]"
            echo "Steps: deps | usb | notifications | agents | offsite | cron | run"
            exit 0
            ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# =============================================================================
# COLOURS AND OUTPUT HELPERS
# =============================================================================

# Detect colour support — disable in pipes/CI
if [[ -t 1 ]] && command -v tput &>/dev/null && tput colors &>/dev/null; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    CYAN=$(tput setaf 6)
    BOLD=$(tput bold)
    DIM=$(tput dim)
    RESET=$(tput sgr0)
else
    RED="" GREEN="" YELLOW="" CYAN="" BOLD="" DIM="" RESET=""
fi

_header() {
    echo ""
    echo "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"
    echo "${BOLD}${CYAN}  $*${RESET}"
    echo "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"
    echo ""
}

_step() {
    echo ""
    echo "${BOLD}▸ $*${RESET}"
}

_ok()   { echo "  ${GREEN}✓${RESET}  $*"; }
_warn() { echo "  ${YELLOW}⚠${RESET}  $*"; }
_info() { echo "  ${CYAN}ℹ${RESET}  $*"; }
_err()  { echo "  ${RED}✗${RESET}  $*"; }
_dim()  { echo "  ${DIM}$*${RESET}"; }

_die() {
    _err "$*"
    exit 1
}

# _ask PROMPT [DEFAULT]
# Prints prompt, reads input. Returns DEFAULT if input is empty.
_ask() {
    local prompt="$1"
    local default="${2:-}"
    local input

    if [[ -n "$default" ]]; then
        printf "  %s [%s]: " "$prompt" "${DIM}${default}${RESET}"
    else
        printf "  %s: " "$prompt"
    fi

    if $AUTO_YES && [[ -n "$default" ]]; then
        echo "$default"
        return
    fi

    read -r input
    echo "${input:-$default}"
}

# _ask_yn PROMPT [default: y|n]
# Returns 0 for yes, 1 for no.
_ask_yn() {
    local prompt="$1"
    local default="${2:-y}"
    local yn

    if $AUTO_YES; then
        [[ "$default" == "y" ]] && return 0 || return 1
    fi

    while true; do
        if [[ "$default" == "y" ]]; then
            printf "  %s [Y/n]: " "$prompt"
        else
            printf "  %s [y/N]: " "$prompt"
        fi
        read -r yn
        yn="${yn:-$default}"
        case "${yn,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     _warn "Please answer y or n" ;;
        esac
    done
}

# _ask_secret PROMPT
# Reads without echo. Does not fall back for --yes (secrets can't be defaulted).
_ask_secret() {
    local prompt="$1"
    local input
    printf "  %s: " "$prompt"
    read -rs input
    echo ""
    echo "$input"
}

# _pause [message]
# Wait for Enter. Skipped in --yes mode.
_pause() {
    $AUTO_YES && return
    printf "  ${DIM}%s — press Enter to continue...${RESET}" "${1:-}"
    read -r
}

# =============================================================================
# CONFIG.SH HELPERS
# =============================================================================

# _cfg_get KEY
# Reads the current active (uncommented) value of KEY from config.sh.
# Returns empty string if not set or commented out.
_cfg_get() {
    local key="$1"
    grep -E "^${key}=" "$CONFIG" 2>/dev/null \
        | tail -1 \
        | sed -E 's/^[^=]+=["'"'"']?([^"'"'"']*)["'"'"']?.*$/\1/'
}

# _cfg_set KEY VALUE
# Sets KEY=VALUE in config.sh. Creates/replaces the active assignment.
# Preserves surrounding comments. Never touches the INTERNAL VARS section.
_cfg_set() {
    local key="$1"
    local value="$2"

    # Escape value for use in sed replacement (handle / in paths)
    local escaped_value
    escaped_value=$(printf '%s' "$value" | sed 's/[\/&]/\\&/g')

    if grep -qE "^${key}=" "$CONFIG" 2>/dev/null; then
        # Replace existing active assignment
        sed -i -E "s|^(${key}=).*|\1\"${escaped_value}\"|" "$CONFIG"
    elif grep -qE "^#.*${key}=" "$CONFIG" 2>/dev/null; then
        # Uncomment the first commented occurrence
        sed -i -E "0,/^#.*${key}=.*/{s|^#.*${key}=.*|${key}=\"${escaped_value}\"|}" "$CONFIG"
    else
        # Append before the INTERNAL VARS line
        sed -i "/^# =*$/,/INTERNAL VARS/{/^# =*.*INTERNAL VARS/i ${key}=\"${escaped_value}\"
}" "$CONFIG"
    fi

    CHANGED=true
}

# _cfg_set_raw KEY RAW_VALUE
# Like _cfg_set but writes the value without quoting (for arrays, booleans, integers)
_cfg_set_raw() {
    local key="$1"
    local value="$2"

    local escaped_value
    escaped_value=$(printf '%s' "$value" | sed 's/[\/&]/\\&/g')

    if grep -qE "^${key}=" "$CONFIG" 2>/dev/null; then
        sed -i -E "s|^(${key}=).*|\1${escaped_value}|" "$CONFIG"
    else
        sed -i "/^# =*.*INTERNAL VARS/i ${key}=${escaped_value}" "$CONFIG"
    fi

    CHANGED=true
}

# _cfg_append_vm_agent ENTRY
# Appends an agent entry to the VM_AGENTS array in config.sh.
_cfg_append_vm_agent() {
    local entry="$1"
    # If array is empty ( VM_AGENTS=() ), replace with the new entry
    if grep -qE "^VM_AGENTS=\(\)" "$CONFIG"; then
        sed -i -E "s|^VM_AGENTS=\(\)|VM_AGENTS=(\n    \"${entry}\"\n)|" "$CONFIG"
    else
        # Insert before the closing ) of the array
        sed -i "/^VM_AGENTS=(/,/)/{/)$/i\\    \"${entry}\"
}" "$CONFIG"
    fi
    CHANGED=true
}

# =============================================================================
# PREFLIGHT
# =============================================================================

_preflight() {
    [[ "$(id -u)" -eq 0 ]] || _die "setup.sh must be run as root (sudo bash setup.sh)"
    [[ -f "$CONFIG" ]]     || _die "config.sh not found at $CONFIG — run setup.sh from the PABS directory"
    [[ -f "$INSTALL_AGENT" ]] || _die "install-agent.sh not found at $INSTALL_AGENT"
    command -v apt-get &>/dev/null || _die "setup.sh requires a Debian/Ubuntu-based system (apt-get not found)"
}

# =============================================================================
# STEP: WELCOME
# =============================================================================

_step_welcome() {
    clear
    echo ""
    echo "${BOLD}${CYAN}"
    cat << 'BANNER'
  ██████╗  █████╗ ██████╗ ███████╗
  ██╔══██╗██╔══██╗██╔══██╗██╔════╝
  ██████╔╝███████║██████╔╝███████╗
  ██╔═══╝ ██╔══██║██╔══██╗╚════██║
  ██║     ██║  ██║██████╔╝███████║
  ╚═╝     ╚═╝  ╚═╝╚═════╝ ╚══════╝
  Proxmox Automated Backup System
BANNER
    echo "${RESET}"
    _dim "Version: $(grep '^SCRIPT_VERSION=' "$CONFIG" | cut -d'"' -f2)"
    _dim "Config:  $CONFIG"
    echo ""
    echo "  This wizard will guide you through:"
    echo "  ${GREEN}1.${RESET} Installing dependencies"
    echo "  ${GREEN}2.${RESET} Configuring the USB backup target"
    echo "  ${GREEN}3.${RESET} Setting up notifications"
    echo "  ${GREEN}4.${RESET} Deploying VM/LXC agents (optional)"
    echo "  ${GREEN}5.${RESET} Configuring offsite sync (optional)"
    echo "  ${GREEN}6.${RESET} Scheduling with cron"
    echo "  ${GREEN}7.${RESET} Running the first backup"
    echo ""
    echo "  ${DIM}You can re-run this wizard at any time to update settings.${RESET}"
    echo "  ${DIM}Press Ctrl+C at any prompt to abort without saving.${RESET}"
    echo ""
    _pause "Ready to start"
}

# =============================================================================
# STEP 1: DEPENDENCIES
# =============================================================================

_step_deps() {
    [[ -n "$JUMP_STEP" && "$JUMP_STEP" != "deps" ]] && return
    _header "Step 1 of 7 — Dependencies"

    local missing=()
    local optional_missing=()

    _step "Checking required packages..."
    for pkg in rsync zstd tar gzip curl python3 ssh; do
        if command -v "$pkg" &>/dev/null; then
            _ok "$pkg"
        else
            _err "$pkg — missing"
            missing+=("$pkg")
        fi
    done

    _step "Checking optional packages..."

    # rclone — only needed for offsite sync
    if command -v rclone &>/dev/null; then
        _ok "rclone (offsite sync)"
    else
        _warn "rclone — not installed (needed for offsite sync)"
        optional_missing+=("rclone")
    fi

    # mail — only needed for email notifications
    if command -v mail &>/dev/null || command -v sendmail &>/dev/null; then
        _ok "mail / sendmail (email notifications)"
    else
        _warn "mailutils — not installed (needed for email notifications)"
        optional_missing+=("mailutils")
    fi

    # Install missing required packages
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo ""
        _warn "Required packages are missing: ${missing[*]}"
        if _ask_yn "Install missing required packages now?"; then
            apt-get update -qq
            apt-get install -y "${missing[@]}"
            _ok "Required packages installed"
        else
            _die "Cannot continue without required packages"
        fi
    fi

    # Install optional packages
    if [[ ${#optional_missing[@]} -gt 0 ]]; then
        echo ""
        _info "Optional packages not installed: ${optional_missing[*]}"

        if [[ " ${optional_missing[*]} " == *" rclone "* ]]; then
            if _ask_yn "Install rclone? (needed for offsite cloud/SFTP sync)" "n"; then
                apt-get install -y rclone
                _ok "rclone installed"
                optional_missing=("${optional_missing[@]/rclone}")
            fi
        fi

        if [[ " ${optional_missing[*]} " == *" mailutils "* ]]; then
            if _ask_yn "Install mailutils? (needed for email failure alerts)" "n"; then
                apt-get install -y mailutils
                _ok "mailutils installed"
            fi
        fi
    fi

    echo ""
    _ok "Dependency check complete"
}

# =============================================================================
# STEP 2: USB
# =============================================================================

_step_usb() {
    [[ -n "$JUMP_STEP" && "$JUMP_STEP" != "usb" ]] && return
    _header "Step 2 of 7 — USB Backup Target"

    # Show connected block devices to help the user identify their USB stick
    _step "Connected block devices:"
    echo ""
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL 2>/dev/null | head -30 \
        | sed 's/^/    /'
    echo ""

    # --- Mount point ---
    local current_mount
    current_mount=$(_cfg_get "USB_MOUNT")
    _info "Current USB_MOUNT: ${current_mount:-not set}"

    local mount_point
    mount_point=$(_ask "USB mount point" "${current_mount:-/mnt/backup-usb}")

    if [[ "$mount_point" != "$current_mount" ]]; then
        _cfg_set "USB_MOUNT" "$mount_point"
        _ok "USB_MOUNT set to $mount_point"
    fi

    # Create mount point directory if it doesn't exist
    if [[ ! -d "$mount_point" ]]; then
        if _ask_yn "Directory $mount_point does not exist. Create it?"; then
            mkdir -p "$mount_point"
            _ok "Created $mount_point"
        fi
    fi

    # --- UUID check ---
    _step "UUID targeting (prevents writing to wrong drive)"
    local current_uuid
    current_uuid=$(_cfg_get "TARGET_UUID")
    _info "Current TARGET_UUID: ${current_uuid:-not set (UUID check disabled)}"

    # If drive is currently mounted, offer to read its UUID automatically
    local detected_uuid=""
    if mountpoint -q "$mount_point" 2>/dev/null; then
        local dev
        dev=$(findmnt -n -o SOURCE "$mount_point" 2>/dev/null || true)
        if [[ -n "$dev" ]]; then
            detected_uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null || true)
            if [[ -n "$detected_uuid" ]]; then
                _ok "USB is currently mounted. Detected UUID: ${detected_uuid}"
                if _ask_yn "Use this UUID?"; then
                    _cfg_set "TARGET_UUID" "$detected_uuid"
                    _ok "TARGET_UUID set to $detected_uuid"
                fi
            fi
        fi
    else
        _warn "Drive not currently mounted at $mount_point"
        echo ""
        if _ask_yn "Mount a partition now? (you'll be prompted for the device)"; then
            local device
            device=$(_ask "Device to mount (e.g. /dev/sdb1)")
            if [[ -b "$device" ]]; then
                mount "$device" "$mount_point" && _ok "Mounted $device at $mount_point" \
                    || _warn "Mount failed — check the device name and filesystem"
                detected_uuid=$(blkid -s UUID -o value "$device" 2>/dev/null || true)
                if [[ -n "$detected_uuid" ]]; then
                    _ok "Detected UUID: $detected_uuid"
                    if _ask_yn "Set this as TARGET_UUID?"; then
                        _cfg_set "TARGET_UUID" "$detected_uuid"
                        _ok "TARGET_UUID set"
                    fi
                fi
            else
                _warn "$device is not a block device — skipping mount"
            fi
        fi
    fi

    # Manual UUID entry if not set yet
    if [[ -z "$(_cfg_get "TARGET_UUID")" ]]; then
        _warn "TARGET_UUID is not set — PABS will write to any drive at $mount_point"
        _info "To set it manually: blkid /dev/sdX1  then enter the UUID below"
        local manual_uuid
        manual_uuid=$(_ask "TARGET_UUID (leave empty to skip UUID check)" "")
        if [[ -n "$manual_uuid" ]]; then
            _cfg_set "TARGET_UUID" "$manual_uuid"
            _ok "TARGET_UUID set"
        fi
    fi

    # --- fstab auto-mount ---
    _step "Auto-mount on boot (fstab)"
    local uuid_for_fstab
    uuid_for_fstab=$(_cfg_get "TARGET_UUID")

    if [[ -n "$uuid_for_fstab" ]]; then
        if grep -q "$uuid_for_fstab" /etc/fstab 2>/dev/null; then
            _ok "fstab entry already present for UUID $uuid_for_fstab"
        else
            _info "Without an fstab entry, the USB must be mounted manually before each backup."
            if _ask_yn "Add fstab entry for auto-mount at boot?"; then
                local fs_type
                local dev_for_fs
                dev_for_fs=$(blkid -U "$uuid_for_fstab" 2>/dev/null || true)
                fs_type=$(blkid -s TYPE -o value "$dev_for_fs" 2>/dev/null || echo "auto")
                echo "UUID=$uuid_for_fstab  $mount_point  $fs_type  defaults,nofail  0  0" >> /etc/fstab
                _ok "fstab entry added (filesystem type: $fs_type)"
                _info "Run 'mount -a' or reboot to activate"
            fi
        fi
    else
        _info "Skipping fstab (no TARGET_UUID set)"
    fi

    # --- Backup retention ---
    _step "Backup retention"
    local current_keep
    current_keep=$(_cfg_get "KEEP_BACKUPS")
    _info "How many weekly backups to keep on USB (oldest are rotated when full)"
    local keep
    keep=$(_ask "KEEP_BACKUPS" "${current_keep:-4}")
    if [[ "$keep" != "$current_keep" ]]; then
        _cfg_set_raw "KEEP_BACKUPS" "$keep"
        _ok "KEEP_BACKUPS set to $keep"
    fi

    # --- Staging directory ---
    _step "Local staging directory"
    _info "Backup data is assembled here first — USB gets one clean write at the end."
    _info "Needs ~500 MB – 3 GB free (more with large VM bundles)."

    local current_stage
    current_stage=$(_cfg_get "LOCAL_STAGE_BASE")

    # Detect if root partition is small (< 20 GB) and suggest alternatives
    local root_avail_gb
    root_avail_gb=$(df -BG / --output=avail 2>/dev/null | tail -1 | tr -d 'G ' || echo 0)
    local suggestion="/var/tmp/pabs-stage"

    if [[ "$root_avail_gb" =~ ^[0-9]+$ && "$root_avail_gb" -lt 20 ]]; then
        _warn "Root partition has only ${root_avail_gb}GB free."
        # Detect ZFS
        if command -v zpool &>/dev/null && zpool list &>/dev/null 2>&1; then
            local zpool_name
            zpool_name=$(zpool list -H -o name 2>/dev/null | head -1 || true)
            [[ -n "$zpool_name" ]] && suggestion="/rpool/data/pabs-stage"
            _info "ZFS detected — consider: /rpool/data/pabs-stage"
        fi
        # Detect directory storage
        if ls /mnt/pve/ &>/dev/null 2>&1; then
            _info "Proxmox storage detected under /mnt/pve/ — consider mounting there"
        fi
    fi

    local stage_dir
    stage_dir=$(_ask "LOCAL_STAGE_BASE" "${current_stage:-$suggestion}")
    if [[ "$stage_dir" != "$current_stage" ]]; then
        _cfg_set "LOCAL_STAGE_BASE" "$stage_dir"
        _ok "LOCAL_STAGE_BASE set to $stage_dir"
    fi

    echo ""
    _ok "USB configuration complete"
}

# =============================================================================
# STEP 3: NOTIFICATIONS
# =============================================================================

_step_notifications() {
    [[ -n "$JUMP_STEP" && "$JUMP_STEP" != "notifications" ]] && return
    _header "Step 3 of 7 — Notifications"

    _info "PABS can send alerts on backup success, failure, and low-space events."

    # --- Discord ---
    _step "Discord webhook"
    local current_webhook
    current_webhook=$(_cfg_get "DISCORD_WEBHOOK")

    if [[ -n "$current_webhook" ]]; then
        _ok "Discord webhook already configured"
        if ! _ask_yn "Update it?"; then
            : # keep existing
        else
            current_webhook=""
        fi
    fi

    if [[ -z "$current_webhook" ]]; then
        _info "Create a webhook at: Server Settings → Integrations → Webhooks"
        if _ask_yn "Set up Discord notifications?" "n"; then
            local webhook
            webhook=$(_ask "Discord webhook URL")
            if [[ -n "$webhook" ]]; then
                # Quick test
                _info "Sending test message..."
                local http_code
                http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                    -H "Content-Type: application/json" \
                    -d '{"content":"✅ PABS setup test — Discord notifications working"}' \
                    "$webhook" 2>/dev/null || echo "000")
                if [[ "$http_code" == "204" ]]; then
                    _ok "Test message sent (check your Discord channel)"
                    _cfg_set "DISCORD_WEBHOOK" "$webhook"
                    _ok "DISCORD_WEBHOOK set"
                else
                    _warn "Test message failed (HTTP $http_code) — check the webhook URL"
                    if _ask_yn "Save it anyway?"; then
                        _cfg_set "DISCORD_WEBHOOK" "$webhook"
                    fi
                fi
            fi
        else
            _info "Skipping Discord notifications"
        fi
    fi

    # --- Email ---
    _step "Email notifications (failure alerts only)"
    local current_email
    current_email=$(_cfg_get "NOTIFY_EMAIL")

    if [[ -n "$current_email" ]]; then
        _ok "Email already configured: $current_email"
        if ! _ask_yn "Update it?"; then
            : # keep existing
        else
            current_email=""
        fi
    fi

    if [[ -z "$current_email" ]]; then
        if command -v mail &>/dev/null || command -v sendmail &>/dev/null; then
            if _ask_yn "Set up email failure alerts?" "n"; then
                local email
                email=$(_ask "Email address for failure alerts")
                if [[ -n "$email" ]]; then
                    _cfg_set "NOTIFY_EMAIL" "$email"
                    _ok "NOTIFY_EMAIL set to $email"
                    # Quick test
                    if _ask_yn "Send a test email now?"; then
                        echo "PABS setup test — email notifications working" \
                            | mail -s "PABS test alert" "$email" 2>/dev/null \
                            && _ok "Test email sent" \
                            || _warn "mail command failed — check MTA configuration"
                    fi
                fi
            fi
        else
            _info "mailutils not installed — skipping email setup"
            _dim "(Install with: apt install mailutils)"
        fi
    fi

    echo ""
    _ok "Notification configuration complete"
}

# =============================================================================
# STEP 4: VM AGENTS
# =============================================================================

_step_agents() {
    [[ -n "$JUMP_STEP" && "$JUMP_STEP" != "agents" ]] && return
    _header "Step 4 of 7 — VM / LXC Agent Backups"

    _info "PABS can back up VMs and LXCs with a lightweight agent."
    _info "The agent auto-detects the VM type (Docker, HAOS, Minecraft, Generic)"
    _info "and produces a self-contained restore bundle."
    echo ""

    # Show existing configured agents
    local agent_count
    agent_count=$(grep -c '".*\.sh"' "$CONFIG" 2>/dev/null || echo 0)
    if [[ "$agent_count" -gt 0 ]]; then
        _ok "$agent_count VM agent(s) already configured in config.sh"
        _dim "Existing entries:"
        grep '".*\.sh"' "$CONFIG" | sed 's/^/    /'
        echo ""
    fi

    if ! _ask_yn "Add a VM/LXC agent now?"; then
        _info "Skipping VM agent setup"
        _dim "You can add agents later with: bash setup.sh --step agents"
        _dim "Or directly: bash install-agent.sh root@<vm-ip>"
        return
    fi

    # Dedicated SSH key setup
    _step "SSH key for agent connections"
    local current_ssh_key
    current_ssh_key=$(_cfg_get "VM_SSH_KEY")
    local key_path="/root/.ssh/id_ed25519_pabs_agent"

    if [[ -n "$current_ssh_key" ]]; then
        _ok "Shared agent SSH key already set: $current_ssh_key"
    elif [[ -f "$key_path" ]]; then
        _ok "Dedicated PABS key already exists at $key_path"
        if _ask_yn "Use $key_path as the shared agent key?"; then
            _cfg_set "VM_SSH_KEY" "$key_path"
            _ok "VM_SSH_KEY set to $key_path"
        fi
    else
        _info "A dedicated SSH key is recommended so rotating root's key"
        _info "doesn't silently break agent backups."
        if _ask_yn "Generate a dedicated PABS agent SSH key at $key_path?"; then
            ssh-keygen -t ed25519 -f "$key_path" -N "" -C "pabs-agent@$(hostname)" \
                && _ok "Key generated: $key_path" \
                || _warn "Key generation failed — continuing without dedicated key"
            if [[ -f "$key_path" ]]; then
                _cfg_set "VM_SSH_KEY" "$key_path"
                _ok "VM_SSH_KEY set to $key_path"
            fi
        fi
    fi

    # Loop: add VMs
    while true; do
        echo ""
        _step "Add a VM or LXC"

        local vm_user
        local vm_host
        local vm_label
        local vm_type_hint=""

        vm_host=$(_ask "VM IP or hostname")
        [[ -z "$vm_host" ]] && { _warn "No host entered — skipping"; break; }

        vm_user=$(_ask "SSH user on the VM" "root")
        local default_label
        default_label="${vm_host//./-}"
        vm_label=$(_ask "Label (used as folder name in backup)" "$default_label")

        # --- Type-specific configuration ---
        _step "VM type configuration"
        _info "The agent auto-detects the type — you only need to override if"
        _info "your setup differs from the defaults (e.g. non-standard paths)."
        echo ""
        echo "  ${BOLD}Types:${RESET}"
        echo "  ${GREEN}1)${RESET} Docker       — compose files, .env, volumes"
        echo "  ${GREEN}2)${RESET} Home Assistant OS — native HA snapshot"
        echo "  ${GREEN}3)${RESET} Minecraft    — weekly archives (minecraft-server-setup)"
        echo "  ${GREEN}4)${RESET} Generic      — /etc, cron, scripts, packages"
        echo "  ${GREEN}5)${RESET} Auto-detect  — let the agent figure it out"
        echo ""

        local type_choice
        type_choice=$(_ask "VM type" "5")

        local set_flags=()

        case "$type_choice" in
            1) # Docker
                vm_type_hint="docker"
                set_flags+=(--set "PABS_TYPE=docker")
                echo ""
                _info "Docker manager detection: auto | none | dockge | portainer"
                local docker_manager
                docker_manager=$(_ask "Docker manager (leave empty for auto-detect)" "")
                [[ -n "$docker_manager" ]] && set_flags+=(--set "DOCKER_MANAGER=$docker_manager")

                if [[ "${docker_manager,,}" == "dockge" ]]; then
                    local dockge_dir
                    dockge_dir=$(_ask "Dockge stacks directory" "/opt/stacks")
                    [[ "$dockge_dir" != "/opt/stacks" ]] && set_flags+=(--set "DOCKGE_STACKS_DIR=$dockge_dir")
                fi

                if [[ "${docker_manager,,}" == "portainer" ]]; then
                    local portainer_url
                    portainer_url=$(_ask "Portainer URL" "http://localhost:9000")
                    [[ "$portainer_url" != "http://localhost:9000" ]] && set_flags+=(--set "PORTAINER_URL=$portainer_url")
                    local portainer_token
                    portainer_token=$(_ask "Portainer API token (ptr_...)")
                    [[ -n "$portainer_token" ]] && set_flags+=(--set "PORTAINER_TOKEN=$portainer_token")
                fi
                ;;

            2) # HAOS
                vm_type_hint="haos"
                set_flags+=(--set "PABS_TYPE=haos")
                echo ""
                local haos_type
                haos_type=$(_ask "Backup type (full/partial)" "full")
                [[ "$haos_type" != "full" ]] && set_flags+=(--set "HAOS_BACKUP_TYPE=$haos_type")
                if _ask_yn "Encrypt the HA snapshot?" "n"; then
                    local haos_pass
                    haos_pass=$(_ask_secret "HA snapshot password")
                    [[ -n "$haos_pass" ]] && set_flags+=(--set "HAOS_BACKUP_PASSWORD=$haos_pass")
                fi
                local haos_keep
                haos_keep=$(_ask "Backups to keep on HA host after pull" "1")
                [[ "$haos_keep" != "1" ]] && set_flags+=(--set "HAOS_KEEP_ON_HOST=$haos_keep")
                ;;

            3) # Minecraft
                vm_type_hint="minecraft"
                set_flags+=(--set "PABS_TYPE=minecraft")
                echo ""
                _info "Defaults match an unmodified minecraft-server-setup install."
                _info "Only change these if you customised the username or paths."

                local mc_default_user="minecraft"
                local mc_current_user
                mc_current_user=$(_ask "System username running Minecraft" "$mc_default_user")

                local mc_base_default="/home/${mc_current_user}/minecraft-server/backups"
                local mc_server_default="/home/${mc_current_user}/minecraft-server"

                local mc_base
                mc_base=$(_ask "MINECRAFT_BASE (backup archives dir)" "$mc_base_default")
                [[ "$mc_base" != "$mc_base_default" ]] && set_flags+=(--set "MINECRAFT_BASE=$mc_base")

                local mc_server
                mc_server=$(_ask "MINECRAFT_SERVER_BASE (server install root)" "$mc_server_default")
                [[ "$mc_server" != "$mc_server_default" ]] && set_flags+=(--set "MINECRAFT_SERVER_BASE=$mc_server")

                local mc_weekly
                mc_weekly=$(_ask "Weekly archives to keep per instance" "4")
                [[ "$mc_weekly" != "4" ]] && set_flags+=(--set "MC_KEEP_WEEKLY=$mc_weekly")

                local mc_daily
                mc_daily=$(_ask "Daily archives to keep (0 = skip daily)" "0")
                [[ "$mc_daily" != "0" ]] && set_flags+=(--set "MC_KEEP_DAILY=$mc_daily")
                ;;

            4) # Generic
                vm_type_hint="generic"
                set_flags+=(--set "PABS_TYPE=generic")
                echo ""
                local extra_paths
                extra_paths=$(_ask "Extra paths to include (space-separated, leave empty to skip)" "")
                [[ -n "$extra_paths" ]] && set_flags+=(--set "EXTRA_PATHS=$extra_paths")
                ;;

            5|*) # Auto
                _info "Using auto-detection"
                ;;
        esac

        # --- Deploy ---
        echo ""
        _step "Deploying agent to ${vm_user}@${vm_host}..."
        _info "This will SSH into the VM and install the agent."
        echo ""

        local install_cmd=("bash" "$INSTALL_AGENT" "${vm_user}@${vm_host}")

        # Use configured SSH key if available
        local agent_key
        agent_key=$(_cfg_get "VM_SSH_KEY")
        [[ -n "$agent_key" && -f "$agent_key" ]] && install_cmd+=(--key "$agent_key")

        # Add --set flags
        install_cmd+=("${set_flags[@]}")

        # Echo the command for transparency
        _dim "Running: ${install_cmd[*]}"
        echo ""

        if "${install_cmd[@]}"; then
            _ok "Agent deployed to ${vm_host}"
            # Add to VM_AGENTS in config.sh
            local agent_entry="${vm_label}  ${vm_host}  ${vm_user}  /opt/pabs-agent/agent.sh"
            _cfg_append_vm_agent "$agent_entry"
            _ok "Added to VM_AGENTS: $agent_entry"
        else
            _err "Agent deployment failed for ${vm_host}"
            _info "You can retry later with:"
            _dim "  bash install-agent.sh ${vm_user}@${vm_host} ${set_flags[*]}"
        fi

        echo ""
        if ! _ask_yn "Add another VM/LXC?"; then
            break
        fi
    done

    # Parallelism setting
    if [[ "$agent_count" -gt 1 ]] || grep -c '".*\.sh"' "$CONFIG" &>/dev/null; then
        _step "Agent parallelism"
        local current_parallel
        current_parallel=$(_cfg_get "VM_AGENT_MAX_PARALLEL")
        _info "Run multiple agents simultaneously to reduce total backup time."
        _info "Recommended: 1 per 500 MB of expected bundle size."
        local parallel
        parallel=$(_ask "Max parallel agents" "${current_parallel:-1}")
        if [[ "$parallel" != "${current_parallel:-1}" ]]; then
            _cfg_set_raw "VM_AGENT_MAX_PARALLEL" "$parallel"
            _ok "VM_AGENT_MAX_PARALLEL set to $parallel"
        fi
    fi

    echo ""
    _ok "VM agent configuration complete"
}

# =============================================================================
# STEP 5: OFFSITE SYNC
# =============================================================================

_step_offsite() {
    [[ -n "$JUMP_STEP" && "$JUMP_STEP" != "offsite" ]] && return
    _header "Step 5 of 7 — Offsite Sync (3-2-1 Backup)"

    _info "Offsite sync completes the 3-2-1 backup strategy:"
    _info "  1 copy on local SSD (staging)"
    _info "  2 copies on USB stick"
    _info "  3 offsite via rclone (cloud or remote server)"
    echo ""

    local current_remote
    current_remote=$(_cfg_get "RCLONE_REMOTE")

    if [[ -n "$current_remote" ]]; then
        _ok "Offsite already configured: $current_remote"
        if ! _ask_yn "Update offsite configuration?"; then
            return
        fi
    fi

    if ! command -v rclone &>/dev/null; then
        _warn "rclone is not installed."
        if _ask_yn "Install rclone now?"; then
            apt-get install -y rclone
            _ok "rclone installed"
        else
            _info "Skipping offsite sync setup"
            _dim "Install rclone later with: apt install rclone, then run: bash setup.sh --step offsite"
            return
        fi
    fi

    if ! _ask_yn "Set up offsite sync?"; then
        _info "Skipping offsite sync setup"
        _dim "Configure it later with: bash setup.sh --step offsite"
        return
    fi

    # --- Remote selection ---
    _step "Select provider"
    echo ""
    echo "  ${BOLD}Common providers:${RESET}"
    echo "  ${GREEN}1)${RESET} Google Drive   — 15 GB free, OAuth token"
    echo "  ${GREEN}2)${RESET} OneDrive       — 5 GB free, OAuth token"
    echo "  ${GREEN}3)${RESET} Backblaze B2   — 10 GB free, API key (no token refresh issues)"
    echo "  ${GREEN}4)${RESET} Hetzner SFTP   — paid, fixed pricing, EU"
    echo "  ${GREEN}5)${RESET} Custom         — any rclone-supported remote"
    echo ""

    local provider_choice
    provider_choice=$(_ask "Provider" "1")

    local remote_name remote_path remote_full

    case "$provider_choice" in
        1) remote_name="gdrive";    remote_path="proxmox-backup" ;;
        2) remote_name="onedrive";  remote_path="proxmox-backup" ;;
        3) remote_name="backblaze"; remote_path="my-bucket/proxmox-backup" ;;
        4) remote_name="hetzner";   remote_path="backup/proxmox" ;;
        5)
            remote_name=$(_ask "rclone remote name (as configured with 'rclone config')")
            remote_path=$(_ask "Path within remote" "proxmox-backup")
            ;;
    esac
    remote_full="${remote_name}:${remote_path}"

    # Check if the remote already exists in rclone config
    if rclone listremotes 2>/dev/null | grep -q "^${remote_name}:"; then
        _ok "rclone remote '${remote_name}' is already configured"
    else
        _warn "rclone remote '${remote_name}' is not configured yet"
        echo ""
        _info "You need to configure it with: rclone config"
        _info "For OAuth remotes (Google Drive, OneDrive) on a headless server,"
        _info "use the 'remote auth' method:"
        _info "  1. Run 'rclone config' here and choose 'n' for new remote"
        _info "  2. When prompted for auto config, choose 'n'"
        _info "  3. Run the shown command on a machine with a browser"
        _info "  4. Paste the resulting token back here"
        echo ""
        if _ask_yn "Open rclone config now?"; then
            rclone config
        else
            _warn "Continuing without verifying the remote — backup will fail if not configured"
        fi
    fi

    # Verify the remote works
    _step "Verifying remote connectivity..."
    if rclone lsd "${remote_name}:" --max-depth 1 &>/dev/null 2>&1; then
        _ok "Remote '${remote_name}' is reachable"
        # Create the backup directory on the remote
        rclone mkdir "$remote_full" 2>/dev/null \
            && _ok "Created remote path: $remote_full" \
            || _warn "Could not create $remote_full — check permissions"
    else
        _warn "Could not reach remote '${remote_name}' — check rclone config"
        if ! _ask_yn "Save remote setting anyway?"; then
            _info "Skipping offsite config"
            return
        fi
    fi

    _cfg_set "RCLONE_REMOTE" "$remote_full"
    _ok "RCLONE_REMOTE set to $remote_full"

    # --- Bandwidth ---
    _step "Bandwidth limiting"
    local current_bwlimit
    current_bwlimit=$(_cfg_get "RCLONE_EXTRA_OPTS")
    _info "Recommended: cap upload speed to avoid saturating your internet connection"
    local bwlimit
    bwlimit=$(_ask "Upload speed limit (e.g. 5M, 10M, 0 for unlimited)" "5M")
    if [[ "$bwlimit" == "0" ]]; then
        _cfg_set "RCLONE_EXTRA_OPTS" ""
    else
        _cfg_set "RCLONE_EXTRA_OPTS" "--bwlimit $bwlimit"
    fi

    # --- Retention ---
    _step "Offsite retention"
    _info "How many backups to keep on the remote."
    echo ""

    # Suggest free-tier presets
    case "$provider_choice" in
        1) # Google Drive 15 GB
            _info "Google Drive free tier: 15 GB — suggested: keep 4 backups, cap at 14 GB"
            local keep_min; keep_min=$(_ask "RCLONE_KEEP_MIN (never delete below this)" "1")
            local keep_max; keep_max=$(_ask "RCLONE_KEEP_MAX (prune oldest above this)" "4")
            local max_gb;   max_gb=$(_ask "RCLONE_MAX_STORAGE_GB (0 = unlimited)" "14")
            ;;
        2) # OneDrive 5 GB
            _info "OneDrive free tier: 5 GB — suggested: keep 1-2 backups, cap at 4 GB"
            local keep_min; keep_min=$(_ask "RCLONE_KEEP_MIN (never delete below this)" "1")
            local keep_max; keep_max=$(_ask "RCLONE_KEEP_MAX (prune oldest above this)" "2")
            local max_gb;   max_gb=$(_ask "RCLONE_MAX_STORAGE_GB (0 = unlimited)" "4")
            ;;
        *)
            local keep_min; keep_min=$(_ask "RCLONE_KEEP_MIN (never delete below this)" "1")
            local keep_max; keep_max=$(_ask "RCLONE_KEEP_MAX (prune oldest above this, 0=unlimited)" "4")
            local max_gb;   max_gb=$(_ask "RCLONE_MAX_STORAGE_GB (0 = unlimited)" "0")
            ;;
    esac

    _cfg_set_raw "RCLONE_KEEP_MIN"          "$keep_min"
    _cfg_set_raw "RCLONE_KEEP_MAX"          "$keep_max"
    _cfg_set_raw "RCLONE_MAX_STORAGE_GB"    "$max_gb"
    _ok "Retention: min=${keep_min}, max=${keep_max}, cap=${max_gb}GB"

    # --- Encryption ---
    _step "Encryption"
    _info "Encrypts all data before upload — the provider sees only opaque blobs."
    _info "Filenames are encrypted too. You need the passphrase to restore."
    _info "⚠  Store the passphrase in a password manager, separate from the USB stick."
    echo ""

    local current_enc_pw
    current_enc_pw=$(_cfg_get "RCLONE_ENCRYPTION_PASSWORD")
    if [[ -n "$current_enc_pw" ]]; then
        _ok "Encryption already configured (password set)"
        if ! _ask_yn "Update the encryption password?"; then
            return
        fi
    fi

    if _ask_yn "Enable encryption?" "y"; then
        local enc_pw
        enc_pw=$(_ask_secret "Encryption passphrase")
        if [[ -z "$enc_pw" ]]; then
            _warn "Empty passphrase — encryption disabled"
        else
            local enc_pw2
            enc_pw2=$(_ask_secret "Confirm passphrase")
            if [[ "$enc_pw" != "$enc_pw2" ]]; then
                _err "Passphrases do not match — encryption NOT configured"
                _info "Re-run 'bash setup.sh --step offsite' to set the password"
            else
                _cfg_set "RCLONE_ENCRYPTION_PASSWORD" "$enc_pw"
                _ok "Encryption password set"

                if _ask_yn "Add a second passphrase (salt)? Recommended for short passwords." "n"; then
                    local enc_salt
                    enc_salt=$(_ask_secret "Salt passphrase")
                    [[ -n "$enc_salt" ]] && _cfg_set "RCLONE_ENCRYPTION_SALT" "$enc_salt"
                    _ok "Salt set"
                fi

                echo ""
                _warn "IMPORTANT: Your passphrase is stored in config.sh on this host."
                _warn "It is automatically REDACTED from the copy written to USB."
                _warn "Back it up somewhere safe NOW — without it, offsite data"
                _warn "cannot be decrypted."
                _pause "Acknowledge"
            fi
        fi
    else
        _warn "Encryption disabled — your provider can read your backup data"
    fi

    echo ""
    _ok "Offsite configuration complete"
}

# =============================================================================
# STEP 6: CRON
# =============================================================================

_step_cron() {
    [[ -n "$JUMP_STEP" && "$JUMP_STEP" != "cron" ]] && return
    _header "Step 6 of 7 — Cron Schedule"

    # Check if already scheduled
    local existing_cron
    existing_cron=$(crontab -l 2>/dev/null | grep -F "$BACKUP_SCRIPT" || true)

    if [[ -n "$existing_cron" ]]; then
        _ok "PABS is already scheduled in cron:"
        _dim "  $existing_cron"
        if ! _ask_yn "Update the schedule?"; then
            return
        fi
    fi

    _step "Choose a backup schedule"
    echo ""
    echo "  ${BOLD}Presets:${RESET}"
    echo "  ${GREEN}1)${RESET} Weekly  — Sunday at 03:00  (recommended for most homelabs)"
    echo "  ${GREEN}2)${RESET} Weekly  — Saturday at 02:00"
    echo "  ${GREEN}3)${RESET} Daily   — Every day at 03:00"
    echo "  ${GREEN}4)${RESET} Monthly — 1st of month at 03:00"
    echo "  ${GREEN}5)${RESET} Custom cron expression"
    echo ""

    local schedule_choice
    schedule_choice=$(_ask "Schedule" "1")
    local cron_expr

    case "$schedule_choice" in
        1) cron_expr="0 3 * * 0" ;;
        2) cron_expr="0 2 * * 6" ;;
        3) cron_expr="0 3 * * *" ;;
        4) cron_expr="0 3 1 * *" ;;
        5)
            _info "Format: minute hour day-of-month month day-of-week"
            _dim "(e.g. '0 3 * * 0' = Sunday at 03:00)"
            cron_expr=$(_ask "Cron expression" "0 3 * * 0")
            ;;
    esac

    # Build the full cron line with log output
    local log_path
    log_path=$(_cfg_get "USB_MOUNT")
    local cron_line="${cron_expr}  bash ${BACKUP_SCRIPT} >> /var/log/pabs-cron.log 2>&1"

    _info "Cron line: $cron_line"

    if _ask_yn "Add this to root's crontab?"; then
        # Remove any existing PABS entry first
        (crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT" || true; echo "$cron_line") \
            | crontab -
        _ok "Cron job added"

        # Verify
        if crontab -l 2>/dev/null | grep -qF "$BACKUP_SCRIPT"; then
            _ok "Verified in crontab"
        else
            _warn "Could not verify crontab entry — check with: crontab -l"
        fi
    else
        _info "Skipping cron setup"
        _dim "Add manually:  crontab -e"
        _dim "Cron line:     $cron_line"
    fi

    echo ""
    _ok "Cron schedule configured"
}

# =============================================================================
# STEP 7: FIRST RUN
# =============================================================================

_step_run() {
    [[ -n "$JUMP_STEP" && "$JUMP_STEP" != "run" ]] && return
    _header "Step 7 of 7 — First Backup"

    # Show config summary
    _step "Configuration summary"
    echo ""

    local usb_mount;    usb_mount=$(_cfg_get "USB_MOUNT")
    local target_uuid;  target_uuid=$(_cfg_get "TARGET_UUID")
    local keep_backups; keep_backups=$(_cfg_get "KEEP_BACKUPS")
    local stage_base;   stage_base=$(_cfg_get "LOCAL_STAGE_BASE")
    local discord;      discord=$(_cfg_get "DISCORD_WEBHOOK")
    local email;        email=$(_cfg_get "NOTIFY_EMAIL")
    local rclone;       rclone=$(_cfg_get "RCLONE_REMOTE")
    local enc_pw;       enc_pw=$(_cfg_get "RCLONE_ENCRYPTION_PASSWORD")
    local agent_lines
    agent_lines=$(grep '".*\.sh"' "$CONFIG" 2>/dev/null | wc -l || echo 0)

    printf "  %-25s %s\n" "USB_MOUNT"       "${usb_mount:-not set}"
    printf "  %-25s %s\n" "TARGET_UUID"     "${target_uuid:-not set (unsafe)}"
    printf "  %-25s %s\n" "KEEP_BACKUPS"    "${keep_backups:-4}"
    printf "  %-25s %s\n" "LOCAL_STAGE_BASE" "${stage_base:-/var/tmp/pabs-stage}"
    printf "  %-25s %s\n" "VM_AGENTS"       "${agent_lines} configured"
    printf "  %-25s %s\n" "Discord"         "$( [[ -n "$discord" ]] && echo "configured" || echo "disabled")"
    printf "  %-25s %s\n" "Email"           "$( [[ -n "$email" ]] && echo "$email" || echo "disabled")"
    printf "  %-25s %s\n" "Offsite remote"  "${rclone:-disabled}"
    printf "  %-25s %s\n" "Offsite encrypt" "$( [[ -n "$enc_pw" ]] && echo "enabled" || echo "disabled")"
    echo ""

    # Run pabs-status.sh as a pre-run check
    _step "Running health check (pabs-status.sh)..."
    echo ""
    if bash "$STATUS_SCRIPT" 2>&1 | sed 's/^/  /'; then
        echo ""
        _ok "Health check passed"
    else
        echo ""
        _warn "Health check reported issues (see above) — you may still run the backup"
    fi
    echo ""

    _step "Ready to run"
    echo ""
    echo "  ${BOLD}Options:${RESET}"
    echo "  ${GREEN}1)${RESET} Dry run     — verify everything without writing any data"
    echo "  ${GREEN}2)${RESET} Full backup — run the complete backup now"
    echo "  ${GREEN}3)${RESET} Skip        — exit the wizard (backup will run on schedule)"
    echo ""

    local run_choice
    run_choice=$(_ask "Choose" "1")

    case "$run_choice" in
        1)
            echo ""
            _info "Running dry run..."
            echo ""
            bash "$BACKUP_SCRIPT" --dry-run 2>&1 | sed 's/^/  /' || true
            echo ""
            _ok "Dry run complete — check output above for any issues"
            if _ask_yn "Run full backup now?"; then
                echo ""
                _info "Running full backup..."
                echo ""
                bash "$BACKUP_SCRIPT" 2>&1 | sed 's/^/  /' \
                    && _ok "Backup complete" \
                    || _warn "Backup reported errors — check the log"
            fi
            ;;
        2)
            echo ""
            _info "Running full backup..."
            echo ""
            bash "$BACKUP_SCRIPT" 2>&1 | sed 's/^/  /' \
                && _ok "Backup complete" \
                || _warn "Backup reported errors — check the log"
            ;;
        3|*)
            _info "Skipping first backup run"
            _dim "Run manually at any time: bash $BACKUP_SCRIPT"
            ;;
    esac

    echo ""
    _ok "Setup complete"
}

# =============================================================================
# FINAL SUMMARY
# =============================================================================

_final_summary() {
    _header "Setup Complete"

    _ok "PABS is configured and ready"
    echo ""
    echo "  ${BOLD}Useful commands:${RESET}"
    echo ""
    printf "  %-45s %s\n" "Run a backup:" "bash $BACKUP_SCRIPT"
    printf "  %-45s %s\n" "Dry run (no writes):" "bash $BACKUP_SCRIPT --dry-run"
    printf "  %-45s %s\n" "Health check:" "bash $STATUS_SCRIPT"
    printf "  %-45s %s\n" "Check cron:" "crontab -l"
    printf "  %-45s %s\n" "View log:" "tail -f $(_cfg_get "USB_MOUNT")/proxmox-backup/backup.log"
    printf "  %-45s %s\n" "Add a VM agent:" "bash $SCRIPT_DIR/install-agent.sh root@<ip>"
    printf "  %-45s %s\n" "Re-run wizard:" "bash $SCRIPT_DIR/setup.sh"
    printf "  %-45s %s\n" "Jump to a step:" "bash $SCRIPT_DIR/setup.sh --step offsite"
    echo ""
    echo "  ${BOLD}Documentation:${RESET}"
    printf "  %-45s %s\n" "All options:" "$SCRIPT_DIR/docs/configuration.md"
    printf "  %-45s %s\n" "VM agents:" "$SCRIPT_DIR/docs/vm-agents.md"
    printf "  %-45s %s\n" "Offsite sync:" "$SCRIPT_DIR/docs/offsite.md"
    printf "  %-45s %s\n" "Restore procedures:" "$SCRIPT_DIR/docs/restore.md"
    echo ""

    if $CHANGED; then
        _info "config.sh was updated during this session."
        _dim "Review it at: $CONFIG"
    fi

    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    _preflight

    if [[ -z "$JUMP_STEP" ]]; then
        _step_welcome
    fi

    _step_deps
    _step_usb
    _step_notifications
    _step_agents
    _step_offsite
    _step_cron
    _step_run

    _final_summary
}

main "$@"
