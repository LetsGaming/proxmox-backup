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
    : $(( WARNINGS++ ))
}

log_err() {
    log "✗  $*"
    # Use the same safe-increment pattern as log_warn:
    # (( ERRORS++ )) returns exit 1 when ERRORS is 0, which would abort under set -e.
    : $(( ERRORS++ ))
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

# -----------------------------------------------------------------------------
# OFFSITE SYNC — encryption, upload, retention pruning
#
# Called after USB commit + manifest verification. Non-fatal on failure.
# Handles three concerns in order:
#   1. Resolve the effective remote (plain or crypt-wrapped)
#   2. Upload the new backup
#   3. Prune old offsite backups to honour KEEP_MAX / MAX_STORAGE_GB / KEEP_MIN
# -----------------------------------------------------------------------------

# _offsite_effective_remote [remote]
# Returns the remote to actually pass to rclone commands.
# When RCLONE_ENCRYPTION_PASSWORD is set, creates (or verifies) an ephemeral
# crypt remote on top of the base remote and returns its name.
_offsite_effective_remote() {
    local base_remote="$1"

    if [[ -z "${RCLONE_ENCRYPTION_PASSWORD:-}" ]]; then
        echo "$base_remote"
        return 0
    fi

    local crypt_name="pabs_crypt_runtime"

    # Create or overwrite the ephemeral crypt config — idempotent, same
    # inputs always produce the same crypt remote, so existing offsite data
    # remains readable across runs.
    rclone config create "$crypt_name" crypt \
        remote        "$base_remote" \
        filename_encryption standard \
        directory_name_encryption true \
        password      "$(rclone obscure "$RCLONE_ENCRYPTION_PASSWORD")" \
        password2     "$(rclone obscure "${RCLONE_ENCRYPTION_SALT:-}")" \
        >/dev/null 2>&1 || {
            log_err "Failed to configure rclone crypt remote — skipping offsite sync"
            return 1
        }

    echo "${crypt_name}:"
}

# _offsite_list_remote_backups [effective_remote_root]
# Lists backup directory names on the remote (sorted oldest-first).
# Each name is a DATE-formatted directory matching our local naming convention.
_offsite_list_remote_backups() {
    local remote_root="$1"
    rclone lsf "$remote_root" \
        --dirs-only \
        --format p \
        2>/dev/null \
        | sed 's|/$||' \
        | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$' \
        | sort
}

# _offsite_remote_storage_gb [effective_remote_root]
# Returns total storage used by PABS backup directories on the remote, in GB.
_offsite_remote_storage_gb() {
    local remote_root="$1"
    local bytes
    bytes=$(rclone size "$remote_root" --json 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('bytes', 0))" 2>/dev/null \
        || echo 0)
    python3 -c "print(round($bytes / 1073741824, 2))" 2>/dev/null || echo 0
}

# _offsite_prune [effective_remote_root]
# Removes oldest remote backups to satisfy KEEP_MAX and MAX_STORAGE_GB,
# but never drops below KEEP_MIN copies.
_offsite_prune() {
    local remote_root="$1"

    local keep_min="${RCLONE_KEEP_MIN:-1}"
    local keep_max="${RCLONE_KEEP_MAX:-4}"
    local max_gb="${RCLONE_MAX_STORAGE_GB:-0}"

    # Collect existing remote backups oldest-first
    local -a remote_backups
    mapfile -t remote_backups < <(_offsite_list_remote_backups "$remote_root")
    local count="${#remote_backups[@]}"

    if [[ $count -eq 0 ]]; then
        return 0
    fi

    log "  Offsite: $count backup(s) on remote"

    # Build the set of directories to delete; start empty.
    local -a to_delete=()

    # --- Pass 1: count-based pruning (KEEP_MAX) ---
    if [[ $keep_max -gt 0 && $count -gt $keep_max ]]; then
        local excess=$(( count - keep_max ))
        log "  Offsite: count $count > RCLONE_KEEP_MAX $keep_max — marking $excess for pruning"
        for (( i=0; i<excess; i++ )); do
            to_delete+=("${remote_backups[$i]}")
        done
    fi

    # --- Pass 2: storage-based pruning (MAX_STORAGE_GB) ---
    if [[ $max_gb -gt 0 ]]; then
        local used_gb
        used_gb=$(_offsite_remote_storage_gb "$remote_root")
        log "  Offsite: remote usage ${used_gb}GB / ${max_gb}GB cap"

        if python3 -c "import sys; sys.exit(0 if float('$used_gb') > float('$max_gb') else 1)" 2>/dev/null; then
            log "  Offsite: storage cap exceeded — pruning oldest until under cap"
            for dir in "${remote_backups[@]}"; do
                # Re-check usage each iteration (after deletes take effect)
                used_gb=$(_offsite_remote_storage_gb "$remote_root")
                python3 -c "import sys; sys.exit(0 if float('$used_gb') > float('$max_gb') else 1)" 2>/dev/null \
                    || break
                # Only add if not already marked
                if ! printf '%s\n' "${to_delete[@]}" | grep -qxF "$dir"; then
                    to_delete+=("$dir")
                fi
                # Simulate deletion for storage re-check on next iteration
                # (actual delete happens below)
            done
        fi
    fi

    # --- KEEP_MIN safety gate: never delete below the minimum ---
    # Count how many backups survive after planned deletes
    local survivors=$(( count - ${#to_delete[@]} ))
    while [[ $survivors -lt $keep_min && ${#to_delete[@]} -gt 0 ]]; do
        local rescued="${to_delete[-1]}"
        to_delete=("${to_delete[@]::${#to_delete[@]}-1}")
        log "  Offsite: rescued $rescued from pruning (would breach RCLONE_KEEP_MIN=$keep_min)"
        (( survivors++ ))
    done

    if [[ ${#to_delete[@]} -eq 0 ]]; then
        log "  Offsite: nothing to prune"
        return 0
    fi

    # --- Execute deletions ---
    for dir in "${to_delete[@]}"; do
        local target="${remote_root}/${dir}"
        log "  Offsite: pruning old backup: $dir"
        if rclone purge "$target" 2>>"$LOG"; then
            log "  Offsite:   ✓ removed $dir"
        else
            log_warn "Offsite: failed to remove $dir — non-fatal, will retry next run"
        fi
    done
}

offsite_sync() {
    [[ -z "${RCLONE_REMOTE:-}" ]] && return 0

    if ! command -v rclone &>/dev/null; then
        log_warn "RCLONE_REMOTE is set but rclone is not installed — skipping offsite sync"
        log_warn "  Install with: apt install rclone"
        return 0
    fi

    # Resolve effective remote (may wrap with crypt)
    local effective_remote
    effective_remote=$(_offsite_effective_remote "$RCLONE_REMOTE") || return 0

    local encryption_active="false"
    [[ -n "${RCLONE_ENCRYPTION_PASSWORD:-}" ]] && encryption_active="true"

    log "Offsite sync starting"
    log "  Remote   : $RCLONE_REMOTE"
    log "  Encrypted: $encryption_active"

    # shellcheck disable=SC2206
    local extra_opts=($RCLONE_EXTRA_OPTS)

    local dest="${effective_remote}$(basename "$FINAL_DIR")"
    log "  Uploading: $(basename "$FINAL_DIR") → $RCLONE_REMOTE"

    if rclone sync "$FINAL_DIR" "$dest" \
            "${extra_opts[@]}" \
            --log-file="$LOG" \
            --log-level INFO \
            2>>"$LOG"; then
        log "  ✓ Offsite upload complete"
        dispatch_alert "SUCCESS — offsite sync $DATE complete to $RCLONE_REMOTE (encrypted: $encryption_active)"
    else
        log_err "Offsite sync to $RCLONE_REMOTE failed — local USB backup is intact"
        dispatch_alert "WARNING — offsite sync $DATE FAILED to $RCLONE_REMOTE. USB backup intact. Review: $LOG"
        return 0  # non-fatal
    fi

    # Prune old offsite backups according to retention config
    _offsite_prune "${effective_remote}"
}