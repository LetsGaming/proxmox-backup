#!/bin/bash
# =============================================================================
# PABS VM Agent — runs INSIDE a VM or LXC, called by the Proxmox host over SSH
#
# Usage:
#   agent.sh --bundle-output /tmp/pabs-bundle.tar.zst   # normal backup mode
#   agent.sh --install                                   # first-time setup
#   agent.sh --type                                      # print detected type and exit
#
# The agent auto-detects its VM/LXC type, collects only what's needed for a
# restore, and writes a self-contained .tar.zst bundle to the requested path.
# PABS on the Proxmox host rsync's that bundle back to USB staging.
#
# Type detection (first match wins, all overridable via /etc/pabs-agent/config):
#   haos    — ha CLI present + /config/configuration.yaml exists
#   docker  — docker CLI present
#   generic — everything else (Pi-hole, AdGuard, Nginx, plain Debian LXC, etc.)
#
# /etc/pabs-agent/config is a sourced bash file. All variables documented in
# each types/*.sh file can be set there. Common keys:
#   PABS_TYPE="docker"       Force a specific type (skip detection)
#   AGENT_LABEL="my-vm"      Human-readable label in restore notes
#   EXTRA_PATHS="/opt/myapp" Extra paths to always include (generic + docker)
# =============================================================================

set -euo pipefail

AGENT_VERSION="1.0"
AGENT_CONFIG="/etc/pabs-agent/config"
STAGE_DIR=""

# -----------------------------------------------------------------------------
# LOGGING  (writes to stderr so stdout stays clean for any future pipe use)
# -----------------------------------------------------------------------------

log()      { echo "[pabs-agent] $*"        >&2; }
log_warn() { echo "[pabs-agent] ⚠  $*"    >&2; }
log_err()  { echo "[pabs-agent] ✗  $*"    >&2; }
die()      { echo "[pabs-agent] FATAL: $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# CLEANUP
# -----------------------------------------------------------------------------

_cleanup() {
    [[ -n "$STAGE_DIR" && -d "$STAGE_DIR" ]] && rm -rf "$STAGE_DIR"
}
trap _cleanup EXIT

# -----------------------------------------------------------------------------
# STAGING HELPERS  (used by all type handlers)
# -----------------------------------------------------------------------------

# Copy a path into the staging tree, preserving its absolute path via rsync --relative.
# Non-fatal: logs a warning if the source doesn't exist.
stage_path() {
    local src="$1"
    local label="${2:-$src}"
    if [[ -e "$src" ]]; then
        rsync -a --relative "$src" "$STAGE_DIR/" 2>/dev/null \
            && log "  ✓ $label" \
            || log_warn "  rsync partial: $label"
    else
        log_warn "  not found, skipped: $label"
    fi
}

# Write a command's stdout to a relative path inside the staging tree.
stage_cmd() {
    local dest_rel="$1"
    local label="$2"
    shift 2
    local dest="$STAGE_DIR/$dest_rel"
    mkdir -p "$(dirname "$dest")"
    if "$@" > "$dest" 2>/dev/null; then
        log "  ✓ $label"
    else
        log_warn "  command failed or partial: $label"
    fi
}

# Write a string directly into a file in the staging tree.
stage_write() {
    local dest_rel="$1"
    local content="$2"
    local dest="$STAGE_DIR/$dest_rel"
    mkdir -p "$(dirname "$dest")"
    printf '%s\n' "$content" > "$dest"
}

# -----------------------------------------------------------------------------
# CONFIG
# -----------------------------------------------------------------------------

load_config() {
    if [[ -f "$AGENT_CONFIG" ]]; then
        # shellcheck source=/dev/null
        source "$AGENT_CONFIG"
        log "Loaded config from $AGENT_CONFIG"
    fi
}

# -----------------------------------------------------------------------------
# TYPE DETECTION
# -----------------------------------------------------------------------------

detect_type() {
    # Explicit override always wins
    if [[ -n "${PABS_TYPE:-}" ]]; then
        echo "$PABS_TYPE"
        return
    fi

    # HAOS: ha CLI + the canonical config file
    if command -v ha &>/dev/null && [[ -f "/config/configuration.yaml" ]]; then
        echo "haos"
        return
    fi

    # Docker host: docker CLI present
    if command -v docker &>/dev/null; then
        echo "docker"
        return
    fi

    # Minecraft: minecraft-server-setup's default install creates
    # /home/minecraft/minecraft-server — check for that or any configured base.
    local mc_base="${MINECRAFT_BASE:-/home/minecraft/minecraft-server/backups}"
    local mc_server_root
    mc_server_root="$(dirname "$mc_base")"
    if [[ -d "$mc_base" ]] \
    || [[ -d "$mc_server_root" && -f "$mc_server_root/server.properties" ]]; then
        echo "minecraft"
        return
    fi
    # Also detect by the minecraft system user existing with the expected home
    if id minecraft &>/dev/null && [[ -d "/home/minecraft" ]]; then
        echo "minecraft"
        return
    fi

    echo "generic"
}

# -----------------------------------------------------------------------------
# TYPE HANDLER LOADER
# -----------------------------------------------------------------------------

load_type_handler() {
    local type="$1"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local handler="$script_dir/types/${type}.sh"
    [[ -f "$handler" ]] || die "No handler for type '$type' at $handler"
    # shellcheck source=/dev/null
    source "$handler"
}

# -----------------------------------------------------------------------------
# INSTALL MODE
# -----------------------------------------------------------------------------

do_install() {
    local detected
    detected=$(detect_type)

    log "Installing PABS agent — detected type: $detected"
    mkdir -p /etc/pabs-agent

    cat > "$AGENT_CONFIG" << EOF
# PABS Agent Configuration — $(hostname)
# Generated by agent.sh --install on $(date '+%Y-%m-%d')
#
# All settings are optional. Uncomment and edit what you need.
# The agent works out of the box for most setups without any changes here.
# Full list of options: see the types/*.sh file for your VM type.
# ============================================================

# --- Type override ---
# Force a specific type instead of auto-detecting.
# Options: haos | docker | generic
# PABS_TYPE="$detected"

# --- Human-readable label (shown in restore notes) ---
# AGENT_LABEL="$(hostname)"

# --- Extra paths to always include (all types) ---
# Space-separated list of additional files or directories to back up.
# EXTRA_PATHS="/opt/myapp/config /var/lib/myservice"

EOF

    # Append type-specific comments
    case "$detected" in
        docker)
            cat >> "$AGENT_CONFIG" << 'EOF'
# --- Docker options ---
# Root directory where your compose projects live.
# Set this if all your stacks are under one directory.
# DOCKER_COMPOSE_DIR="/opt"

# Directories to search for compose files when no manager is detected.
# DOCKER_SEARCH_PATHS="/opt /srv /home /root"

# How deep to recurse when searching (2 = appname/docker-compose.yml)
# DOCKER_SEARCH_DEPTH=3

# Docker manager override. Options: auto | none | dockge | portainer
# DOCKER_MANAGER="auto"

# Dockge paths (if using Dockge)
# DOCKGE_STACKS_DIR="/opt/stacks"
# DOCKGE_DATA_DIR="/opt/dockge"

# Portainer API (if using Portainer and want stack export)
# PORTAINER_URL="http://localhost:9000"
# PORTAINER_TOKEN="ptr_..."

# Named volumes to always include regardless of size
# DOCKER_INCLUDE_VOLUMES="portainer_data,traefik_certs"

# Auto-include volumes smaller than this many MB (0 = disable auto-include)
# DOCKER_VOLUME_AUTO_THRESHOLD_MB=5

# Set to "true" to skip all volume backups
# DOCKER_SKIP_VOLUMES="false"
EOF
            ;;
        haos)
            cat >> "$AGENT_CONFIG" << 'EOF'
# --- HAOS options ---
# Backup type: "full" (everything) or "partial" (select add-ons/folders)
# HAOS_BACKUP_TYPE="full"

# Prefix for the backup name shown in HA UI
# HAOS_BACKUP_NAME="pabs-auto"

# Encrypt the snapshot with a password (leave empty for no encryption)
# HAOS_BACKUP_PASSWORD=""

# How many pabs-* backups to keep on the HA host (oldest are pruned after pull)
# HAOS_KEEP_ON_HOST=1

# Max seconds to wait for HA to finish creating the snapshot
# HAOS_WAIT_SECONDS=300

# Partial backup options (only used when HAOS_BACKUP_TYPE="partial")
# HAOS_PARTIAL_ADDONS="core_mosquitto,core_mariadb"
# HAOS_PARTIAL_FOLDERS="homeassistant,ssl"
EOF
            ;;
        minecraft)
            cat >> "$AGENT_CONFIG" << 'EOF'
# --- Minecraft options ---
# Parent directory containing per-instance backup folders.
# Matches minecraft-server-setup's default layout — only change if you
# set a custom TARGET_DIR_NAME or BACKUPS_PATH in variables.json.
# MINECRAFT_BASE="/home/minecraft/minecraft-server/backups"

# Root of the server install — used to capture server.properties, mods, etc.
# MINECRAFT_SERVER_BASE="/home/minecraft/minecraft-server"

# How many weekly archives to include per instance
# MC_KEEP_WEEKLY=4

# How many daily archives to include per instance (0 = skip daily entirely)
# MC_KEEP_DAILY=0

# Only include archives older than this many minutes (age-gate against
# in-progress compression). Should be >= your worlds' compression time.
# MC_MIN_AGE_MINUTES=5

# Include the mods/ directory from each server instance
# MC_INCLUDE_MODS="true"

# Extra paths to always include (space-separated)
# MC_EXTRA_PATHS="/home/minecraft/minecraft-server/shared-configs"
EOF
            ;;
        generic)
            cat >> "$AGENT_CONFIG" << 'EOF'
# --- Generic / LXC options ---
# Toggle individual backup sections
# GENERIC_INCLUDE_ETC="true"
# GENERIC_INCLUDE_CRON="true"
# GENERIC_INCLUDE_SCRIPTS="true"
# GENERIC_INCLUDE_PACKAGES="true"

# Paths to exclude from the /etc backup (rsync --exclude syntax)
# GENERIC_EXCLUDE_PATHS="/etc/ssl/private /etc/shadow"
EOF
            ;;
    esac

    chmod 600 "$AGENT_CONFIG"
    log "Config written to $AGENT_CONFIG (mode 600)"
    log ""
    log "Next step: add this VM to VM_AGENTS in PABS config.sh on the Proxmox host."
    log "Install complete."
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------

main() {
    local output_path=""
    local mode="backup"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bundle-output) output_path="$2"; shift 2 ;;
            --install)       mode="install";   shift   ;;
            --type)          mode="type";      shift   ;;
            *) die "Unknown argument: $1" ;;
        esac
    done

    if [[ "$mode" == "install" ]]; then
        do_install
        exit 0
    fi

    load_config

    local vm_type
    vm_type=$(detect_type)

    if [[ "$mode" == "type" ]]; then
        echo "$vm_type"
        exit 0
    fi

    # --- Backup mode ---
    [[ -n "$output_path" ]] || die "--bundle-output is required"
    [[ $EUID -eq 0 ]] || die "Run as root"

    log "PABS Agent v${AGENT_VERSION} | type: $vm_type | host: $(hostname)"

    STAGE_DIR=$(mktemp -d /tmp/pabs-agent-XXXXXX)

    load_type_handler "$vm_type"
    run_backup   # defined by the loaded handler

    # Write agent metadata (always, regardless of type)
    stage_write "agent-meta.txt" \
"PABS Agent v${AGENT_VERSION}
Type:     $vm_type
Label:    ${AGENT_LABEL:-$(hostname)}
Host:     $(hostname)
Date:     $(date '+%Y-%m-%d %H:%M:%S')
Kernel:   $(uname -r)
"

    # Compress the staging tree into the requested output bundle
    log "Compressing bundle..."
    local bundle_tmp="${output_path}.tmp"
    tar -C "$STAGE_DIR" -cf - . | zstd -q -T0 -o "$bundle_tmp"
    mv "$bundle_tmp" "$output_path"

    local size_kb
    size_kb=$(du -sk "$output_path" | cut -f1)
    log "Bundle written: $output_path (${size_kb}KB)"
}

main "$@"
