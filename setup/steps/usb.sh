#!/bin/bash
# setup/steps/usb.sh — Step 2: USB target, UUID, fstab, retention, staging

_step_usb() {
    [[ -n "$JUMP_STEP" && "$JUMP_STEP" != "usb" ]] && return
    _header "Step 2 of 7 — USB Backup Target"

    _step "Connected block devices:"
    echo ""
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL 2>/dev/null | head -30 | sed 's/^/    /'
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

    if [[ ! -d "$mount_point" ]]; then
        if _ask_yn "Directory $mount_point does not exist. Create it?"; then
            mkdir -p "$mount_point"
            _ok "Created $mount_point"
        fi
    fi

    # --- UUID ---
    _step "UUID targeting (prevents writing to wrong drive)"
    local current_uuid
    current_uuid=$(_cfg_get "TARGET_UUID")
    _info "Current TARGET_UUID: ${current_uuid:-not set (UUID check disabled)}"

    local detected_uuid=""
    if mountpoint -q "$mount_point" 2>/dev/null; then
        local dev
        dev=$(findmnt -n -o SOURCE "$mount_point" 2>/dev/null || true)
        if [[ -n "$dev" ]]; then
            detected_uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null || true)
        fi
        if [[ -n "$detected_uuid" ]]; then
            _ok "USB mounted. Detected UUID: $detected_uuid"
            if _ask_yn "Use this UUID?"; then
                _cfg_set "TARGET_UUID" "$detected_uuid"
                _ok "TARGET_UUID set to $detected_uuid"
            fi
        fi
    else
        _warn "Drive not currently mounted at $mount_point"
        if _ask_yn "Mount a partition now?"; then
            local device
            device=$(_ask "Device to mount (e.g. /dev/sdb1)")
            if [[ -b "$device" ]]; then
                mount "$device" "$mount_point" \
                    && _ok "Mounted $device at $mount_point" \
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

    if [[ -z "$(_cfg_get "TARGET_UUID")" ]]; then
        _warn "TARGET_UUID not set — PABS will write to any drive at $mount_point"
        local manual_uuid
        manual_uuid=$(_ask "TARGET_UUID (leave empty to skip UUID check)" "")
        if [[ -n "$manual_uuid" ]]; then
            _cfg_set "TARGET_UUID" "$manual_uuid"
            _ok "TARGET_UUID set"
        fi
    fi

    # --- fstab ---
    _step "Auto-mount on boot (fstab)"
    local uuid_for_fstab
    uuid_for_fstab=$(_cfg_get "TARGET_UUID")

    if [[ -n "$uuid_for_fstab" ]]; then
        if grep -q "$uuid_for_fstab" /etc/fstab 2>/dev/null; then
            _ok "fstab entry already present for UUID $uuid_for_fstab"
        else
            _info "Without an fstab entry the USB must be mounted manually before each backup."
            if _ask_yn "Add fstab entry for auto-mount at boot?"; then
                local dev_for_fs fs_type
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

    # --- Retention ---
    _step "Backup retention"
    local current_keep
    current_keep=$(_cfg_get "KEEP_BACKUPS")
    _info "How many weekly backups to keep on USB (oldest rotated when full)"
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

    local current_stage suggestion="/var/tmp/pabs-stage"
    current_stage=$(_cfg_get "LOCAL_STAGE_BASE")

    local root_avail_gb
    root_avail_gb=$(df -BG / --output=avail 2>/dev/null | tail -1 | tr -d 'G ' || echo 0)
    if [[ "$root_avail_gb" =~ ^[0-9]+$ && "$root_avail_gb" -lt 20 ]]; then
        _warn "Root partition has only ${root_avail_gb}GB free."
        if command -v zpool &>/dev/null && zpool list &>/dev/null 2>&1; then
            local pool
            pool=$(zpool list -H -o name 2>/dev/null | head -1 || true)
            [[ -n "$pool" ]] && suggestion="/rpool/data/pabs-stage"
            _info "ZFS detected — consider: /rpool/data/pabs-stage"
        fi
        ls /mnt/pve/ &>/dev/null 2>&1 && _info "Proxmox storage under /mnt/pve/ — consider using it"
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
