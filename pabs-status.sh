#!/bin/bash
# =============================================================================
# pabs-status.sh — PABS pre-flight status check
#
# Checks the current state of PABS without running a backup:
#   - USB mounted and space available
#   - Most recent backup: date, size, manifest integrity
#   - All configured VM agents: SSH reachable
#   - Offsite remote reachable (if configured)
#   - Local stage disk space
#
# Usage:
#   ./pabs-status.sh
#
# Exit codes: 0 = OK, 1 = error, 2 = warning
# =============================================================================

set -euo pipefail

PABS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for arg in "$@"; do
    case "$arg" in
        --help|-h)
            echo "Usage: $0"
            echo "  Checks PABS health without running a backup."
            echo "  Exit: 0=OK  1=error  2=warning"
            exit 0 ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

source "$PABS_DIR/config.sh"

PASS="✓"; FAIL="✗"; WARN="⚠"
OVERALL=0  # 0=OK, 1=error, 2=warning

_ok()   { echo "  $PASS  $*"; }
_warn() { echo "  $WARN  $*"; [[ $OVERALL -eq 0 ]] && OVERALL=2; }
_fail() { echo "  $FAIL  $*"; OVERALL=1; }

echo ""
echo "=== PABS Status ==="

# ---------------------------------------------------------------------------
# Root
# ---------------------------------------------------------------------------
echo ""
echo "--- Environment ---"
[[ $EUID -eq 0 ]] && _ok "Running as root" || _warn "Not running as root — some checks may be inaccurate"

# ---------------------------------------------------------------------------
# USB
# ---------------------------------------------------------------------------
echo ""
echo "--- USB / Backup Storage ---"

USB_OK=false
if mountpoint -q "$USB_MOUNT" 2>/dev/null; then
    _ok "USB mounted at $USB_MOUNT"
    USB_OK=true

    USB_FREE_GB=$(df -k "$USB_MOUNT" | awk 'NR==2{ printf "%.0f", $4/1024/1024 }')
    USB_USED_PCT=$(df -k "$USB_MOUNT" | awk 'NR==2{ printf "%.0f", $3/$2*100 }')
    _ok "USB free: ${USB_FREE_GB}GB  (${USB_USED_PCT}% used)"

    BACKUP_COUNT=0
    [[ -d "$BACKUP_ROOT" ]] && \
        BACKUP_COUNT=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l)
    _ok "$BACKUP_COUNT backup(s) in $BACKUP_ROOT"
else
    _fail "USB not mounted at $USB_MOUNT"
fi

# ---------------------------------------------------------------------------
# Most recent backup
# ---------------------------------------------------------------------------
echo ""
echo "--- Most Recent Backup ---"

LATEST=""
if [[ "$USB_OK" == "true" && -d "$BACKUP_ROOT" ]]; then
    LATEST=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name '.*' \
        | sort | tail -1)
fi

if [[ -n "$LATEST" ]]; then
    LATEST_SIZE=$(du -sh "$LATEST" 2>/dev/null | cut -f1 || echo "unknown")
    _ok "Latest: $(basename "$LATEST")  ($LATEST_SIZE)"

    if [[ -f "$LATEST/MANIFEST.sha256" ]]; then
        if ( cd "$LATEST" && sha256sum --quiet --check MANIFEST.sha256 2>/dev/null ); then
            _ok "Manifest: all checksums OK"
        else
            _fail "Manifest: checksum failures in $(basename "$LATEST")"
        fi
    else
        _warn "Manifest: MANIFEST.sha256 not found"
    fi

    [[ -f "$LATEST/DISASTER-RECOVERY.md" ]] \
        && _ok "DISASTER-RECOVERY.md present" \
        || _warn "DISASTER-RECOVERY.md missing from latest backup"
else
    _warn "No backups found in $BACKUP_ROOT"
fi

# ---------------------------------------------------------------------------
# Local stage
# ---------------------------------------------------------------------------
echo ""
echo "--- Local Stage (SSD) ---"

mkdir -p "$LOCAL_STAGE_BASE" 2>/dev/null || true
STAGE_FREE_GB=$(df -k "$LOCAL_STAGE_BASE" | awk 'NR==2{ printf "%.0f", $4/1024/1024 }')
if [[ "$STAGE_FREE_GB" -lt 2 ]]; then
    _warn "Stage free: ${STAGE_FREE_GB}GB — low (< 2GB)"
else
    _ok "Stage free: ${STAGE_FREE_GB}GB"
fi

# ---------------------------------------------------------------------------
# VM agents
# ---------------------------------------------------------------------------
echo ""
echo "--- VM Agent Connectivity ---"

if [[ ${#VM_AGENTS[@]} -eq 0 ]]; then
    _warn "No VM_AGENTS configured"
else
    for entry in "${VM_AGENTS[@]}"; do
        read -r label vm_host ssh_user agent_path <<< "$entry"
        [[ -z "$label" ]] && continue

        ssh_opts=("${VM_AGENT_SSH_OPTS[@]}")
        key_var="VM_SSH_KEY_${label//-/_}"
        [[ -n "${!key_var:-}" ]] && ssh_opts+=(-i "${!key_var}")
        [[ -n "${VM_SSH_KEY:-}" && -z "${!key_var:-}" ]] && ssh_opts+=(-i "$VM_SSH_KEY")

        if ssh "${ssh_opts[@]}" -o ConnectTimeout=5 "$ssh_user@$vm_host" exit 2>/dev/null; then
            _ok "[$label] $ssh_user@$vm_host"
        else
            _fail "[$label] $ssh_user@$vm_host — unreachable"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Offsite sync
# ---------------------------------------------------------------------------
echo ""
echo "--- Offsite Sync (rclone) ---"

if [[ -z "${RCLONE_REMOTE:-}" ]]; then
    _warn "RCLONE_REMOTE not configured — no offsite backup (3-2-1 incomplete)"
elif ! command -v rclone &>/dev/null; then
    _fail "RCLONE_REMOTE is set but rclone is not installed (apt install rclone)"
elif rclone lsd "$RCLONE_REMOTE" --max-depth 1 &>/dev/null; then
    _ok "rclone remote reachable: $RCLONE_REMOTE"
else
    _fail "rclone remote unreachable: $RCLONE_REMOTE"
fi

# ---------------------------------------------------------------------------
# Lock
# ---------------------------------------------------------------------------
echo ""
echo "--- Lock ---"
[[ -f "$LOCK_FILE" ]] \
    && _warn "Lock file exists: $LOCK_FILE (backup may be running or crashed)" \
    || _ok "No lock file"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
case $OVERALL in
    0) echo "  Overall: OK" ;;
    1) echo "  Overall: ERROR" ;;
    2) echo "  Overall: WARNING" ;;
esac
echo ""

exit $OVERALL
