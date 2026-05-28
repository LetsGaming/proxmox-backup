#!/bin/bash
# =============================================================================
# install-agent.sh — Deploy the PABS agent to a VM or LXC over SSH
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_SOURCE="$SCRIPT_DIR/vm-agent"
REMOTE_DIR="/opt/pabs-agent"
SSH_KEY=""
PABS_KNOWN_HOSTS="/root/.ssh/pabs_known_hosts"

SSH_OPTS=(
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile="$PABS_KNOWN_HOSTS"
)

declare -a SET_VARS=()

usage() {
    echo "Usage: $0 <user@host> [--dir /remote/path] [--key /path/to/key] [--set KEY=VALUE ...]"
    exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

[[ $# -lt 1 ]] && usage

TARGET="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)
            REMOTE_DIR="$2"
            shift 2
            ;;
        --key)
            SSH_KEY="$2"
            shift 2
            ;;
        --set)
            [[ "$2" == *=* ]] || {
                echo "--set requires KEY=VALUE format"
                exit 1
            }

            SET_VARS+=("$2")
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            ;;
    esac
done

if [[ -n "$SSH_KEY" ]]; then
    [[ -f "$SSH_KEY" ]] || {
        echo "SSH key not found: $SSH_KEY"
        exit 1
    }

    SSH_OPTS+=(-i "$SSH_KEY")
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    echo "[install-agent] $*"
}

rrun() {
    ssh "${SSH_OPTS[@]}" "$TARGET" "$@"
}

# ---------------------------------------------------------------------------
# Verify agent source exists
# ---------------------------------------------------------------------------

[[ -f "$AGENT_SOURCE/agent.sh" ]] || {
    echo "vm-agent/agent.sh not found at $AGENT_SOURCE"
    exit 1
}

log "Target:       $TARGET"
log "Remote dir:   $REMOTE_DIR"

if [[ ${#SET_VARS[@]} -gt 0 ]]; then
    log "Config overrides: ${SET_VARS[*]}"
fi

log ""

# ---------------------------------------------------------------------------
# Check remote dependencies
# ---------------------------------------------------------------------------

log "Checking remote dependencies..."

rrun "command -v rsync >/dev/null || apt-get install -y rsync >/dev/null 2>&1"
rrun "command -v zstd >/dev/null || apt-get install -y zstd >/dev/null 2>&1"
rrun "command -v python3 >/dev/null || apt-get install -y python3 >/dev/null 2>&1"

# ---------------------------------------------------------------------------
# Copy agent files
# ---------------------------------------------------------------------------

log "Copying agent files to $TARGET:$REMOTE_DIR ..."

rrun "mkdir -p $REMOTE_DIR/types"

set +e

RSYNC_OUTPUT="$(
    rsync -a --delete \
        -e "ssh ${SSH_OPTS[*]@Q}" \
        "$AGENT_SOURCE/" \
        "$TARGET:$REMOTE_DIR/" 2>&1
)"
RSYNC_RC=$?

set -e

if [[ $RSYNC_RC -ne 0 ]]; then
    echo "$RSYNC_OUTPUT"
    log "ERROR: rsync failed"
    exit $RSYNC_RC
fi

rrun "chmod +x $REMOTE_DIR/agent.sh"
rrun "chmod 644 $REMOTE_DIR/types/*.sh"

# ---------------------------------------------------------------------------
# Run remote installer
# ---------------------------------------------------------------------------

log "Running agent --install on $TARGET ..."

set +e

INSTALL_OUTPUT="$(
    rrun "$REMOTE_DIR/agent.sh --install" 2>&1
)"
INSTALL_RC=$?

set -e

echo "$INSTALL_OUTPUT"

if [[ $INSTALL_RC -ne 0 ]]; then
    if grep -q "Install complete" <<< "$INSTALL_OUTPUT"; then
        log "WARNING: agent returned non-zero but install completed successfully"
    else
        log "ERROR: remote install failed"
        exit $INSTALL_RC
    fi
fi

# ---------------------------------------------------------------------------
# Apply config overrides
# ---------------------------------------------------------------------------

if [[ ${#SET_VARS[@]} -gt 0 ]]; then
    log "Applying config overrides to /etc/pabs-agent/config ..."

    AGENT_CONFIG="/etc/pabs-agent/config"

    for kv in "${SET_VARS[@]}"; do
        local_key="${kv%%=*}"
        local_val="${kv#*=}"

        log "  $local_key=$local_val"

        python3_script=$(cat << 'PYEOF'
import sys
import re

config_path = sys.argv[1]
key = sys.argv[2]
value = sys.argv[3]

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
    lines.append(f'\n# Set by install-agent.sh\n{new_line}')

with open(config_path, 'w') as f:
    f.writelines(lines)
PYEOF
)

        rrun "python3 - '$AGENT_CONFIG' '$local_key' '$local_val'" << EOF
$python3_script
EOF
    done

    log "✓ Config overrides applied"
fi

# ---------------------------------------------------------------------------
# Register SSH host key
# ---------------------------------------------------------------------------

log "Registering host key in $PABS_KNOWN_HOSTS ..."

HOST_PART="${TARGET##*@}"

mkdir -p "$(dirname "$PABS_KNOWN_HOSTS")"

touch "$PABS_KNOWN_HOSTS"
chmod 600 "$PABS_KNOWN_HOSTS"

ssh-keygen -R "$HOST_PART" -f "$PABS_KNOWN_HOSTS" 2>/dev/null || true

ssh-keyscan -H "$HOST_PART" >> "$PABS_KNOWN_HOSTS" 2>/dev/null \
    && log "✓ Host key registered for $HOST_PART" \
    || log "⚠ ssh-keyscan failed"

# ---------------------------------------------------------------------------
# Detect VM type
# ---------------------------------------------------------------------------

log ""
log "Detecting VM type..."

DETECTED_TYPE="$(
    rrun "$REMOTE_DIR/agent.sh --type" 2>/dev/null | tail -1 || echo "unknown"
)"

log "Detected type: $DETECTED_TYPE"

# --- Auto-register VM in config.sh ---
CONFIG_FILE="$SCRIPT_DIR/config.sh"

HOST_PART="${TARGET##*@}"
LABEL="${HOST_PART//./-}"
VM_ENTRY="    \"$LABEL  $HOST_PART  ${TARGET%%@*}  $REMOTE_DIR/agent.sh\""

log ""
log "Registering VM agent in config.sh ..."

if grep -Fq "\"$LABEL  $HOST_PART" "$CONFIG_FILE"; then
    log "  ✓ VM already present in VM_AGENTS"
else
    TMP_FILE="$(mktemp)"

    in_vm_agents=0
    inserted=0

    while IFS= read -r line; do
        echo "$line" >> "$TMP_FILE"

        # Detect the REAL VM_AGENTS block
        if [[ "$line" =~ ^VM_AGENTS=\($ ]]; then
            in_vm_agents=1
            continue
        fi

        # Insert BEFORE the closing ) of the real block
        if [[ $in_vm_agents -eq 1 && "$line" == ")" ]]; then
            sed -i "\|^)$|i\\$VM_ENTRY" "$TMP_FILE"
            inserted=1
            in_vm_agents=0
        fi
    done < "$CONFIG_FILE"

    if [[ $inserted -eq 1 ]]; then
        mv "$TMP_FILE" "$CONFIG_FILE"
        log "  ✓ Added VM to VM_AGENTS"
    else
        rm -f "$TMP_FILE"
        log "  ERROR: failed to locate VM_AGENTS block"
        exit 1
    fi
fi

log ""
log "============================================================"
log "VM registration complete"
log "============================================================"