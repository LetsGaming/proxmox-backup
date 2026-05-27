#!/bin/bash
# =============================================================================
# install-agent.sh — Deploy the PABS agent to a VM or LXC over SSH
#
# Run this FROM the Proxmox host to set up a new VM for PABS backups.
#
# Usage:
#   ./install-agent.sh <user@host>
#   ./install-agent.sh root@192.168.1.10
#   ./install-agent.sh backup@my-docker-vm --key /root/.ssh/id_ed25519_backup
#   ./install-agent.sh root@192.168.1.20 --dir /opt/pabs-agent
#
# What it does:
#   1. Copies vm-agent/ to the target (default: /opt/pabs-agent)
#   2. Runs agent.sh --install on the target (creates /etc/pabs-agent/config)
#   3. Prints the VM_AGENTS line to add to PABS config.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_SOURCE="$SCRIPT_DIR/vm-agent"
REMOTE_DIR="/opt/pabs-agent"
SSH_KEY=""
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

usage() {
    echo "Usage: $0 <user@host> [--dir /remote/path] [--key /path/to/key]"
    exit 1
}

# --- Argument parsing ---
[[ $# -lt 1 ]] && usage
TARGET="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir) REMOTE_DIR="$2"; shift 2 ;;
        --key) SSH_KEY="$2";    shift 2 ;;
        *)     echo "Unknown argument: $1"; usage ;;
    esac
done

if [[ -n "$SSH_KEY" ]]; then
    [[ -f "$SSH_KEY" ]] || { echo "SSH key not found: $SSH_KEY"; exit 1; }
    SSH_OPTS+=(-i "$SSH_KEY")
fi

# --- Helpers ---
log()  { echo "[install-agent] $*"; }
rrun() { ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }

# --- Verify agent source exists ---
[[ -f "$AGENT_SOURCE/agent.sh" ]] \
    || { echo "vm-agent/agent.sh not found at $AGENT_SOURCE"; exit 1; }

log "Target:       $TARGET"
log "Remote dir:   $REMOTE_DIR"
log ""

# --- Check dependencies on remote ---
log "Checking remote dependencies..."
rrun "command -v rsync  >/dev/null || apt-get install -y rsync  >/dev/null 2>&1"
rrun "command -v zstd   >/dev/null || apt-get install -y zstd   >/dev/null 2>&1"
# python3 is required by some handlers (HAOS JSON parsing, Portainer API)
rrun "command -v python3 >/dev/null || apt-get install -y python3 >/dev/null 2>&1"

# --- Copy agent files ---
log "Copying agent files to $TARGET:$REMOTE_DIR ..."
rrun "mkdir -p $REMOTE_DIR/types"
rsync -a --delete "${SSH_OPTS[@]/#/-e ssh }" \
    -e "ssh ${SSH_OPTS[*]}" \
    "$AGENT_SOURCE/" "$TARGET:$REMOTE_DIR/"
# Fix permissions
rrun "chmod +x $REMOTE_DIR/agent.sh"
rrun "chmod 644 $REMOTE_DIR/types/*.sh"

# --- Run install mode on remote ---
log "Running agent --install on $TARGET ..."
rrun "$REMOTE_DIR/agent.sh --install"

# --- Detect type for the config hint ---
log ""
log "Detecting VM type..."
DETECTED_TYPE=$(rrun "$REMOTE_DIR/agent.sh --type" 2>/dev/null | tail -1 || echo "unknown")
log "Detected type: $DETECTED_TYPE"

# --- Print the config line ---
log ""
log "============================================================"
log "Add this to VM_AGENTS in PABS config.sh:"
log ""

# Extract just the host/IP portion for the label suggestion
HOST_PART="${TARGET##*@}"
LABEL="${HOST_PART//./-}"  # replace dots with dashes for a clean label

echo "  \"$LABEL  $HOST_PART  ${TARGET%%@*}  $REMOTE_DIR/agent.sh\""
log ""
log "Format: \"label  ip-or-hostname  ssh-user  agent-path\""
log ""
log "Before adding, review /etc/pabs-agent/config on the VM and"
log "adjust any settings for your setup."
log "============================================================"
