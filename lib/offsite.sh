#!/bin/bash
# =============================================================================
# lib/offsite.sh — Offsite sync: encryption wrapper, upload, retention pruning
#
# Sourced by backup.sh after core.sh and config.sh.
# Entry point: offsite_sync() — called once per backup run after USB commit.
# Non-fatal: a remote failure never aborts a backup that is already on USB.
# =============================================================================

# ---------------------------------------------------------------------------
# _offsite_effective_remote REMOTE
# Prints the rclone remote string to use for all subsequent rclone calls.
# When RCLONE_ENCRYPTION_PASSWORD is set, creates an ephemeral crypt remote
# on top of REMOTE and returns its name. Idempotent across runs.
# ---------------------------------------------------------------------------
_offsite_effective_remote() {
    local base_remote="$1"

    if [[ -z "${RCLONE_ENCRYPTION_PASSWORD:-}" ]]; then
        echo "$base_remote"
        return 0
    fi

    local crypt_name="pabs_crypt_runtime"

    rclone config create "$crypt_name" crypt \
        remote                  "$base_remote" \
        filename_encryption     standard \
        directory_name_encryption true \
        password                "$(rclone obscure "$RCLONE_ENCRYPTION_PASSWORD")" \
        password2               "$(rclone obscure "${RCLONE_ENCRYPTION_SALT:-}")" \
        >/dev/null 2>&1 || {
            log_err "Failed to configure rclone crypt remote — skipping offsite sync"
            return 1
        }

    echo "${crypt_name}:"
}

# ---------------------------------------------------------------------------
# _offsite_list_backups REMOTE_ROOT
# Lists PABS backup directory names on the remote, sorted oldest-first.
# Only matches our date-format names (YYYY-MM-DD_HH-MM-SS).
# ---------------------------------------------------------------------------
_offsite_list_backups() {
    local remote_root="$1"
    rclone lsf "$remote_root" \
        --dirs-only \
        --format p \
        2>/dev/null \
        | sed 's|/$||' \
        | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$' \
        | sort
}

# ---------------------------------------------------------------------------
# _offsite_usage_gb REMOTE_ROOT
# Returns total GB used by all PABS directories on the remote.
# ---------------------------------------------------------------------------
_offsite_usage_gb() {
    local remote_root="$1"
    local bytes
    bytes=$(rclone size "$remote_root" --json 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('bytes',0))" 2>/dev/null \
        || echo 0)
    python3 -c "print(round($bytes / 1073741824, 2))" 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# _offsite_prune REMOTE_ROOT
# Deletes oldest remote backups to satisfy KEEP_MAX and MAX_STORAGE_GB,
# but never drops below KEEP_MIN copies.
# ---------------------------------------------------------------------------
_offsite_prune() {
    local remote_root="$1"
    local keep_min="${RCLONE_KEEP_MIN:-1}"
    local keep_max="${RCLONE_KEEP_MAX:-4}"
    local max_gb="${RCLONE_MAX_STORAGE_GB:-0}"

    local -a remote_backups=()
    mapfile -t remote_backups < <(_offsite_list_backups "$remote_root")
    local count="${#remote_backups[@]}"
    [[ $count -eq 0 ]] && return 0

    log "  Offsite: $count backup(s) on remote"

    local -a to_delete=()

    # Pass 1 — count cap
    if [[ $keep_max -gt 0 && $count -gt $keep_max ]]; then
        local excess=$(( count - keep_max ))
        log "  Offsite: count $count > RCLONE_KEEP_MAX $keep_max — marking $excess for pruning"
        for (( i=0; i<excess; i++ )); do
            to_delete+=("${remote_backups[$i]}")
        done
    fi

    # Pass 2 — storage cap
    if [[ $max_gb -gt 0 ]]; then
        local used_gb
        used_gb=$(_offsite_usage_gb "$remote_root")
        log "  Offsite: remote usage ${used_gb}GB / ${max_gb}GB cap"

        if python3 -c "import sys; sys.exit(0 if float('$used_gb') > float('$max_gb') else 1)" 2>/dev/null; then
            log "  Offsite: storage cap exceeded — marking oldest for pruning"
            # Track estimated remaining usage locally to avoid an rclone size RPC
            # per iteration (slow and costly on paid remotes like Backblaze B2).
            # We subtract a conservative 100MB per directory marked for deletion;
            # the safety gate below ensures we never drop below KEEP_MIN.
            local estimated_gb="$used_gb"
            for dir in "${remote_backups[@]}"; do
                python3 -c "import sys; sys.exit(0 if float('$estimated_gb') > float('$max_gb') else 1)" 2>/dev/null \
                    || break
                printf '%s\n' "${to_delete[@]+"${to_delete[@]}"}" | grep -qxF "$dir" \
                    || { to_delete+=("$dir"); estimated_gb=$(python3 -c "print(round(float('$estimated_gb') - 0.1, 2))"); }
            done
        fi
    fi

    # Safety gate — never prune below KEEP_MIN
    local survivors=$(( count - ${#to_delete[@]} ))
    while [[ $survivors -lt $keep_min && ${#to_delete[@]} -gt 0 ]]; do
        log "  Offsite: rescued ${to_delete[-1]} from pruning (RCLONE_KEEP_MIN=$keep_min)"
        to_delete=("${to_delete[@]::${#to_delete[@]}-1}")
        survivors=$(( survivors + 1 ))
    done

    if [[ ${#to_delete[@]} -eq 0 ]]; then
        log "  Offsite: nothing to prune"
        return 0
    fi

    for dir in "${to_delete[@]}"; do
        log "  Offsite: pruning $dir"
        if rclone purge "${remote_root}/${dir}" 2>>"$LOG"; then
            log "  Offsite:   ✓ removed $dir"
        else
            log_warn "Offsite: failed to remove $dir — will retry next run"
        fi
    done
}

# ---------------------------------------------------------------------------
# offsite_sync — public entry point
# ---------------------------------------------------------------------------
offsite_sync() {
    [[ -z "${RCLONE_REMOTE:-}" ]] && return 0

    if ! command -v rclone &>/dev/null; then
        log_warn "RCLONE_REMOTE is set but rclone is not installed — skipping offsite sync"
        log_warn "  Install with: apt install rclone"
        return 0
    fi

    local effective_remote
    effective_remote=$(_offsite_effective_remote "$RCLONE_REMOTE") || return 0

    local encrypted="false"
    [[ -n "${RCLONE_ENCRYPTION_PASSWORD:-}" ]] && encrypted="true"

    log "Offsite sync starting"
    log "  Remote   : $RCLONE_REMOTE"
    log "  Encrypted: $encrypted"

    # shellcheck disable=SC2206
    # Intentional word-split so multiple flags (e.g. "--transfers 4 --checkers 8") are
    # passed as separate argv elements. Callers must not put glob characters in
    # RCLONE_EXTRA_OPTS (e.g. --filter='*.bak') as they would undergo filename expansion.
    local -a extra_opts=($RCLONE_EXTRA_OPTS)
    local dest
    dest="${effective_remote%/}/$(basename "$FINAL_DIR")"

    if rclone sync "$FINAL_DIR" "$dest" \
            "${extra_opts[@]}" \
            --log-file="$LOG" \
            --log-level INFO \
            2>>"$LOG"; then
        log "  ✓ Offsite upload complete"
        dispatch_alert "SUCCESS — offsite sync $DATE complete to $RCLONE_REMOTE (encrypted: $encrypted)"
    else
        log_err "Offsite sync to $RCLONE_REMOTE failed — USB backup is intact"
        dispatch_alert "WARNING — offsite sync $DATE FAILED to $RCLONE_REMOTE. USB backup intact. Review: $LOG"
        return 0  # non-fatal
    fi

    _offsite_prune "${effective_remote}"
}
