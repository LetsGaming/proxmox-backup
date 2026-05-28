#!/bin/bash
# setup/steps/offsite.sh — Step 5: rclone remote, bandwidth, retention, encryption

# ---------------------------------------------------------------------------
# Provider selection → (remote_name, remote_path)
# Sets the two local variables in the caller's scope via nameref.
# ---------------------------------------------------------------------------

_offsite_select_provider() {
    local -n _name=$1 _path=$2

    echo "  ${BOLD}Common providers:${RESET}"
    echo "  ${GREEN}1)${RESET} Google Drive   — 15 GB free, OAuth token"
    echo "  ${GREEN}2)${RESET} OneDrive       — 5 GB free, OAuth token"
    echo "  ${GREEN}3)${RESET} Backblaze B2   — 10 GB free, API key"
    echo "  ${GREEN}4)${RESET} Hetzner SFTP   — paid, fixed pricing, EU"
    echo "  ${GREEN}5)${RESET} Custom         — any rclone-supported remote"
    echo ""

    local choice
    choice=$(_ask "Provider" "1")

    case "$choice" in
        1) _name="gdrive";    _path="proxmox-backup" ;;
        2) _name="onedrive";  _path="proxmox-backup" ;;
        3) _name="backblaze"; _path="my-bucket/proxmox-backup" ;;
        4) _name="hetzner";   _path="backup/proxmox" ;;
        *)
            _name=$(_ask "rclone remote name (as in 'rclone config')")
            _path=$(_ask "Path within remote" "proxmox-backup")
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Retention questions — defaults vary by provider choice number
# ---------------------------------------------------------------------------

_offsite_configure_retention() {
    local provider_choice="$1"

    _step "Offsite retention"
    _info "How many backups to keep on the remote."
    echo ""

    local keep_min keep_max max_gb

    case "$provider_choice" in
        1) # Google Drive 15 GB
            _info "Google Drive free tier: 15 GB — suggested: keep 4, cap at 14 GB"
            keep_min=$(_ask "RCLONE_KEEP_MIN (never delete below this)" "1")
            keep_max=$(_ask "RCLONE_KEEP_MAX (prune oldest above this)"  "4")
            max_gb=$(_ask   "RCLONE_MAX_STORAGE_GB (0 = unlimited)"      "14")
            ;;
        2) # OneDrive 5 GB
            _info "OneDrive free tier: 5 GB — suggested: keep 1-2, cap at 4 GB"
            keep_min=$(_ask "RCLONE_KEEP_MIN" "1")
            keep_max=$(_ask "RCLONE_KEEP_MAX" "2")
            max_gb=$(_ask   "RCLONE_MAX_STORAGE_GB (0 = unlimited)" "4")
            ;;
        *)
            keep_min=$(_ask "RCLONE_KEEP_MIN (never delete below this)" "1")
            keep_max=$(_ask "RCLONE_KEEP_MAX (0 = unlimited)"           "4")
            max_gb=$(_ask   "RCLONE_MAX_STORAGE_GB (0 = unlimited)"     "0")
            ;;
    esac

    _cfg_set_raw "RCLONE_KEEP_MIN"       "$keep_min"
    _cfg_set_raw "RCLONE_KEEP_MAX"       "$keep_max"
    _cfg_set_raw "RCLONE_MAX_STORAGE_GB" "$max_gb"
    _ok "Retention: min=${keep_min}, max=${keep_max}, cap=${max_gb}GB"
}

# ---------------------------------------------------------------------------
# Encryption setup
# ---------------------------------------------------------------------------

_offsite_configure_encryption() {
    _step "Encryption"
    _info "Encrypts all data before upload — the provider sees only opaque blobs."
    _info "Filenames are encrypted too. You need the passphrase to restore."
    _info "⚠  Store the passphrase in a password manager, separate from the USB stick."
    echo ""

    local current_pw
    current_pw=$(_cfg_get "RCLONE_ENCRYPTION_PASSWORD")
    if [[ -n "$current_pw" ]]; then
        _ok "Encryption already configured"
        _ask_yn "Update the password?" "n" || return
    fi

    if ! _ask_yn "Enable encryption?" "y"; then
        _warn "Encryption disabled — your provider can read your backup data"
        return
    fi

    local pw pw2
    pw=$(_ask_secret "Encryption passphrase")
    if [[ -z "$pw" ]]; then
        _warn "Empty passphrase — encryption not configured"
        return
    fi

    pw2=$(_ask_secret "Confirm passphrase")
    if [[ "$pw" != "$pw2" ]]; then
        _err "Passphrases do not match — encryption NOT configured"
        _info "Re-run: bash setup.sh --step offsite"
        return
    fi

    _cfg_set "RCLONE_ENCRYPTION_PASSWORD" "$pw"
    _ok "Encryption password set"

    if _ask_yn "Add a second passphrase (salt)? Recommended for short passwords." "n"; then
        local salt
        salt=$(_ask_secret "Salt passphrase")
        [[ -n "$salt" ]] && _cfg_set "RCLONE_ENCRYPTION_SALT" "$salt" && _ok "Salt set"
    fi

    echo ""
    _warn "IMPORTANT: passphrase is stored in config.sh on this host."
    _warn "It is automatically REDACTED from the copy written to USB."
    _warn "Back it up somewhere safe NOW — without it, offsite data cannot be decrypted."
    _pause "Acknowledge"
}

# ---------------------------------------------------------------------------
# Step entry point
# ---------------------------------------------------------------------------

_step_offsite() {
    [[ -n "$JUMP_STEP" && "$JUMP_STEP" != "offsite" ]] && return
    _header "Step 5 of 7 — Offsite Sync (3-2-1 Backup)"

    _info "Offsite sync completes the 3-2-1 backup strategy:"
    _info "  copy 1  local SSD staging"
    _info "  copy 2  USB stick"
    _info "  copy 3  cloud or remote server via rclone"
    echo ""

    local current_remote
    current_remote=$(_cfg_get "RCLONE_REMOTE")
    if [[ -n "$current_remote" ]]; then
        _ok "Offsite already configured: $current_remote"
        _ask_yn "Update offsite configuration?" "n" || return
    fi

    if ! command -v rclone &>/dev/null; then
        _warn "rclone is not installed."
        if _ask_yn "Install rclone now?"; then
            apt-get install -y rclone && _ok "rclone installed"
        else
            _info "Skipping — configure later with: bash setup.sh --step offsite"
            return
        fi
    fi

    if ! _ask_yn "Set up offsite sync?"; then
        _info "Skipping — configure later with: bash setup.sh --step offsite"
        return
    fi

    # Provider selection
    _step "Select provider"
    echo ""
    local remote_name remote_path
    _offsite_select_provider remote_name remote_path
    local remote_full="${remote_name}:${remote_path}"

    # Configure the rclone remote if it isn't already
    if rclone listremotes 2>/dev/null | grep -q "^${remote_name}:"; then
        _ok "rclone remote '${remote_name}' already configured"
    else
        _warn "rclone remote '${remote_name}' not configured yet"
        echo ""
        _info "Configure it with: rclone config"
        _info "For OAuth remotes (Drive/OneDrive) on a headless server use remote auth:"
        _info "  1. Run 'rclone config' here and create a new remote"
        _info "  2. When asked for auto config choose 'n'"
        _info "  3. Run the shown command on a machine with a browser"
        _info "  4. Paste the resulting token back here"
        echo ""
        _ask_yn "Open rclone config now?" && rclone config \
            || _warn "Continuing without verifying the remote"
    fi

    # Connectivity check
    _step "Verifying remote connectivity..."
    if rclone lsd "${remote_name}:" --max-depth 1 &>/dev/null 2>&1; then
        _ok "Remote '${remote_name}' is reachable"
        rclone mkdir "$remote_full" 2>/dev/null \
            && _ok "Remote path ready: $remote_full" \
            || _warn "Could not create $remote_full — check permissions"
    else
        _warn "Could not reach '${remote_name}'"
        _ask_yn "Save remote setting anyway?" "n" || { _info "Skipping offsite config"; return; }
    fi

    _cfg_set "RCLONE_REMOTE" "$remote_full"
    _ok "RCLONE_REMOTE set to $remote_full"

    # Bandwidth
    _step "Bandwidth limiting"
    _info "Recommended: cap upload speed to avoid saturating your connection"
    local bwlimit
    bwlimit=$(_ask "Upload speed limit (e.g. 5M, 10M, 0 for unlimited)" "5M")
    if [[ "$bwlimit" == "0" ]]; then
        _cfg_set "RCLONE_EXTRA_OPTS" ""
    else
        _cfg_set "RCLONE_EXTRA_OPTS" "--bwlimit $bwlimit"
    fi

    # Retention — pass provider_choice derived from remote_name for preset defaults
    local provider_num=5
    case "$remote_name" in
        gdrive)    provider_num=1 ;;
        onedrive)  provider_num=2 ;;
    esac
    _offsite_configure_retention "$provider_num"

    # Encryption
    _offsite_configure_encryption

    echo ""
    _ok "Offsite configuration complete"
}
