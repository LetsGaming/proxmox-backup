#!/bin/bash
# =============================================================================
# lib/core.sh — Logging, lock management, trap, and alert dispatch
#
# Sourced by backup.sh after config.sh. All other lib files depend on the
# functions defined here (log, die, dispatch_alert).
# =============================================================================

# -----------------------------------------------------------------------------
# LOGGING
# -----------------------------------------------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

log_warn() {
    log "⚠  $*"
    (( WARNINGS++ )) || true
}

log_err() {
    log "✗  $*"
    (( ERRORS++ )) || true
}

die() {
    log "FATAL: $*"
    exit 1
}

# -----------------------------------------------------------------------------
# NOTIFICATIONS — dual-channel: Discord (primary) + mail (fallback)
# -----------------------------------------------------------------------------

dispatch_alert() {
    local message="$1"
    local full_msg="[$(hostname)] Proxmox Backup v${SCRIPT_VERSION}: $message"

    # Primary: Discord webhook via HTTPS.
    # python3 handles JSON serialization correctly for all edge cases (tabs,
    # control characters, non-ASCII, nested quotes). The message is passed as
    # sys.argv[1] — never interpolated into Python code — so there is no
    # injection surface. python3 is a base Debian/Proxmox dependency.
    if [[ -n "$DISCORD_WEBHOOK" ]]; then
        local json
        json=$(python3 -c \
            'import json,sys; print(json.dumps({"content":sys.argv[1]}))' \
            "$full_msg")
        curl -s -X POST \
             -H "Content-Type: application/json" \
             -d "$json" \
             --max-time 10 \
             "$DISCORD_WEBHOOK" >/dev/null 2>&1 || true
    fi

    # Fallback: local mail
    if [[ -n "$NOTIFY_EMAIL" ]]; then
        echo "$full_msg" \
            | mail -s "PABS Alert: $(hostname)" "$NOTIFY_EMAIL" 2>/dev/null || true
    fi
}

# -----------------------------------------------------------------------------
# LOCK — prevents concurrent runs from corrupting each other
# -----------------------------------------------------------------------------

acquire_lock() {
    mkdir -p "$LOCAL_STAGE_BASE"
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo "Another backup is already running (lock: $LOCK_FILE). Aborting." >&2
        exit 1
    fi
}

release_lock() {
    flock -u 9 2>/dev/null || true
    rm -f "$LOCK_FILE"
}

# -----------------------------------------------------------------------------
# TRAP — cleanup on unexpected exit
# -----------------------------------------------------------------------------

_on_exit() {
    local exit_code=$?

    # STAGE_DIR may be on local SSD or may already have been renamed to USB.
    # Only clean up if it still exists at the local path.
    if [[ -d "$STAGE_DIR" ]]; then
        log "Cleaning up local staging directory after unexpected exit..."
        rm -rf "$STAGE_DIR"
    fi

    release_lock

    if [[ $exit_code -ne 0 ]]; then
        dispatch_alert "FAILED with exit code $exit_code. Review log: $LOG"
    fi
}

# Attach on source — backup.sh detaches/reattaches around the atomic commit
trap '_on_exit' ERR EXIT