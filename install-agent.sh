#!/bin/bash
# =============================================================================
# install-agent.sh — Deploy the PABS agent to a VM or LXC over SSH
#
# Run this FROM the Proxmox host to set up a new VM for PABS backups.
# config.sh is the only file you ever need to edit — agent configuration is
# written to the VM during installation via --set flags.
#
# Usage:
#   ./install-agent.sh <user@host> [options]
#
# Options:
#   --key  /path/to/key     SSH private key to use for this VM
#   --dir  /remote/path     Remote install path (default: /opt/pabs-agent)
#   --set  KEY=VALUE        Write a config value into /etc/pabs-agent/config
#                           on the VM. Can be repeated for multiple values.
#                           Values are written as uncommented assignments so
#                           they take effect immediately without manual SSH.
#
# Examples:
#   # Standard install — auto-detect type, use defaults
#   ./install-agent.sh root@192.168.1.10
#
#   # Minecraft VM with a non-default username and install path
#   ./install-agent.sh minecraft@192.168.1.40 \
#       --set MINECRAFT_BASE=/home/alice/servers/backups \
#       --set MINECRAFT_SERVER_BASE=/home/alice/servers \
#       --set MC_KEEP_WEEKLY=2
#
#   # Docker VM with Portainer token configured from the Proxmox host
#   ./install-agent.sh root@192.168.1.20 \
#       --set PORTAINER_TOKEN=ptr_abc123 \
#       --set DOCKER_MANAGER=portainer
#
#   # HAOS with custom backup retention
#   ./install-agent.sh root@192.168.1.30 \
#       --set HAOS_KEEP_ON_HOST=2 \
#       --set HAOS_BACKUP_TYPE=full
#
#   # Dedicated SSH key
#   ./install-agent.sh root@192.168.1.10 --key /root/.ssh/id_ed25519_pabs_agent
#
# What it does:
#   1. Copies vm-agent/ to the target (default: /opt/pabs-agent)
#   2. Runs agent.sh --install on the target (creates /etc/pabs-agent/config)
#   3. Applies any --set values into the remote config (no SSH needed afterwards)
#   4. Registers the host key in /root/.ssh/pabs_known_hosts (used by cron backups)
#   5. Prints the VM_AGENTS line to add to PABS config.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_SOURCE="$SCRIPT_DIR/vm-agent"
REMOTE_DIR="/opt/pabs-agent"
SSH_KEY=""
PABS_KNOWN_HOSTS="/root/.ssh/pabs_known_hosts"
# accept-new is appropriate here (first contact); cron backups use StrictHostKeyChecking=yes
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
          -o UserKnownHostsFile="$PABS_KNOWN_HOSTS")

# Collected --set KEY=VALUE pairs
declare -a SET_VARS=()

usage() {
    echo "Usage: $0 <user@host> [--dir /remote/path] [--key /path/to/key] [--set KEY=VALUE ...]"
    echo ""
    echo "  --set KEY=VALUE   Write a config value into /etc/pabs-agent/config on the VM."
    echo "                    Repeat for multiple values. Example:"
    echo "                    --set MINECRAFT_BASE=/home/alice/servers/backups"
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
        --set)
            [[ "$2" == *=* ]] || { echo "--set requires KEY=VALUE format"; exit 1; }
            SET_VARS+=("$2")
            shift 2
            ;;
        *) echo "Unknown argument: $1"; usage ;;
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
[[ ${#SET_VARS[@]} -gt 0 ]] && log "Config overrides: ${SET_VARS[*]}"
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
rsync -a --delete \
    -e "ssh ${SSH_OPTS[*]@Q}" \
    "$AGENT_SOURCE/" "$TARGET:$REMOTE_DIR/"
# Fix permissions
rrun "chmod +x $REMOTE_DIR/agent.sh"
rrun "chmod 644 $REMOTE_DIR/types/*.sh"

# --- Run install mode on remote ---
log "Running agent --install on $TARGET ..."
rrun "$REMOTE_DIR/agent.sh --install"

# --- Apply --set overrides into /etc/pabs-agent/config ---
# For each KEY=VALUE:
#   - If the key already appears (commented or uncommented), replace that line
#     with an active assignment so the intent is clear in the file.
#   - If the key is not present at all, append it.
# This makes the config file readable and self-documenting — the user can SSH
# in later and see exactly what was set, with the rest of the options as
# commented reference.
if [[ ${#SET_VARS[@]} -gt 0 ]]; then
    log "Applying config overrides to /etc/pabs-agent/config ..."
    AGENT_CONFIG="/etc/pabs-agent/config"

    for kv in "${SET_VARS[@]}"; do
        local_key="${kv%%=*}"
        local_val="${kv#*=}"

        log "  $local_key=$local_val"

        # Build a small Python script to do the replacement safely without
        # complex sed escaping. Passed via stdin to avoid shell quoting issues
        # with values that contain slashes, quotes, or special characters.
        python3_script=$(cat << 'PYEOF'
import sys, re, os

config_path = sys.argv[1]
key         = sys.argv[2]
value       = sys.argv[3]

with open(config_path, 'r') as f:
    lines = f.readlines()

pattern = re.compile(r'^\s*#?\s*' + re.escape(key) + r'\s*=')
new_line = f'{key}="{value}"\n'
replaced = False

for i, line in enumerate(lines):
    if pattern.match(line):
        lines[i] = new_line
        replaced = True
        break

if not replaced:
    # Key not in file at all — append under a generated comment
    lines.append(f'\n# Set by install-agent.sh\n{new_line}')

with open(config_path, 'w') as f:
    f.writelines(lines)
PYEOF
)
        # Pass the script and arguments safely: script via stdin, args as positional
        rrun "python3 - '$AGENT_CONFIG' '$local_key' '$local_val'" << EOF
$python3_script
EOF
    done

    log "  ✓ Config overrides applied"
fi

# --- Register host key in pabs_known_hosts ---
# This enables StrictHostKeyChecking=yes in cron backups (config.sh: VM_AGENT_SSH_OPTS)
log "Registering host key in $PABS_KNOWN_HOSTS ..."
HOST_PART="${TARGET##*@}"
mkdir -p "$(dirname "$PABS_KNOWN_HOSTS")"
touch "$PABS_KNOWN_HOSTS"
chmod 600 "$PABS_KNOWN_HOSTS"
# Remove any stale entry for this host first, then add the current key
ssh-keygen -R "$HOST_PART" -f "$PABS_KNOWN_HOSTS" 2>/dev/null || true
ssh-keyscan -H "$HOST_PART" >> "$PABS_KNOWN_HOSTS" 2>/dev/null \
    && log "  ✓ Host key registered for $HOST_PART" \
    || log "  ⚠ ssh-keyscan failed — add the key manually or re-run install-agent.sh"

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
log "============================================================"