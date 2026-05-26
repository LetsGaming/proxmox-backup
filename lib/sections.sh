#!/bin/bash
# =============================================================================
# lib/sections.sh — Backup section functions (1/8 through 8/8)
#
# Each section_*() function stages one logical group of data into STAGE_DIR.
# Helpers backup_path() and backup_cmd_output() are defined here too since
# they're only used by the section functions.
# =============================================================================

# -----------------------------------------------------------------------------
# HELPERS
# -----------------------------------------------------------------------------

# Copy a filesystem path into the local staging tree, preserving its absolute
# path via rsync's --relative flag.
backup_path() {
    local src="$1"
    local label="$2"

    if [[ -e "$src" ]]; then
        if rsync -a --relative "$src" "$STAGE_DIR/" 2>>"$LOG"; then
            log "  ✓ $label"
        else
            log_err "rsync failed: $src — $label"
        fi
    else
        log_warn "Not found, skipped: $src — $label"
    fi
}

# Run a command and write its stdout to a relative path inside the staging tree.
# Usage: backup_cmd_output "relative/dest.txt" "Label" command [args...]
backup_cmd_output() {
    local dest_relative="$1"
    local label="$2"
    shift 2

    local dest="$STAGE_DIR/$dest_relative"
    mkdir -p "$(dirname "$dest")"

    if "$@" > "$dest" 2>>"$LOG"; then
        log "  ✓ $label"
    else
        log_warn "$label — command failed or partially failed"
    fi
}

# -----------------------------------------------------------------------------
# SECTION 1: Proxmox core configs
# -----------------------------------------------------------------------------

section_proxmox_configs() {
    log "[1/8] Proxmox core configs"

    # /etc/pve is a pmxcfs FUSE filesystem backed by SQLite.
    # tar reads the directory tree in one uninterrupted pass, avoiding the
    # edge-case lockups that rsync can trigger against a live pmxcfs mount.
    # --warning=no-file-ignored suppresses non-fatal noise from FUSE sockets
    # and named pipes that tar cannot serialize and skips automatically.
    # We do NOT suppress --warning=no-file-changed because a file changing
    # while being read is a genuine data integrity signal worth logging.
    local pve_tar="$STAGE_DIR/etc-pve.tar"
    if tar --warning=no-file-ignored -C / -cf "$pve_tar" etc/pve 2>>"$LOG"; then
        log "  ✓ /etc/pve (tar snapshot)"
    else
        log_err "/etc/pve tar failed"
    fi

    backup_path "/etc/network/interfaces"   "Network interfaces"
    backup_path "/etc/network/interfaces.d" "Network interfaces.d"
    backup_path "/etc/hosts"                "Hosts file"
    backup_path "/etc/hostname"             "Hostname"
    backup_path "/etc/resolv.conf"          "DNS resolver config"
    backup_path "/etc/apt/sources.list"     "APT sources.list"
    backup_path "/etc/apt/sources.list.d"   "APT sources.list.d"
}

# -----------------------------------------------------------------------------
# SECTION 2: VM and container definitions
# -----------------------------------------------------------------------------

section_vm_ct_definitions() {
    log "[2/8] VM and container definitions"

    local vm_dest="$STAGE_DIR/vm-ct-definitions"
    mkdir -p "$vm_dest/vms" "$vm_dest/containers"

    # Export individual configs via qm/pct for human-readable restore reference.
    # Raw config files from pmxcfs are also copied as a secondary source.
    local vm_count=0
    while IFS= read -r vmid; do
        [[ -z "$vmid" ]] && continue
        if qm config "$vmid" > "$vm_dest/vms/vm-${vmid}.conf" 2>>"$LOG"; then
            log "  ✓ VM $vmid"
            (( vm_count++ )) || true
        else
            log_warn "Could not export config for VM $vmid"
        fi
    done < <(qm list 2>/dev/null | awk 'NR>1{print $1}')

    local ct_count=0
    while IFS= read -r ctid; do
        [[ -z "$ctid" ]] && continue
        if pct config "$ctid" > "$vm_dest/containers/ct-${ctid}.conf" 2>>"$LOG"; then
            log "  ✓ CT $ctid"
            (( ct_count++ )) || true
        else
            log_warn "Could not export config for CT $ctid"
        fi
    done < <(pct list 2>/dev/null | awk 'NR>1{print $1}')

    log "  VMs: $vm_count  CTs: $ct_count"

    backup_path "/etc/pve/qemu-server" "Raw VM qemu-server configs"
    backup_path "/etc/pve/lxc"         "Raw CT lxc configs"
}

# -----------------------------------------------------------------------------
# SECTION 3: Cron jobs
# -----------------------------------------------------------------------------

section_cron_jobs() {
    log "[3/8] Cron jobs"
    backup_path "/etc/crontab"              "System crontab"
    backup_path "/etc/cron.d"              "Cron.d jobs"
    backup_path "/etc/cron.daily"          "Daily cron jobs"
    backup_path "/etc/cron.weekly"         "Weekly cron jobs"
    backup_path "/var/spool/cron/crontabs" "User crontabs"
}

# -----------------------------------------------------------------------------
# SECTION 4: Firewall rules
# -----------------------------------------------------------------------------

section_firewall() {
    log "[4/8] Firewall rules"
    backup_path "/etc/nftables.conf" "nftables rules"
    backup_path "/etc/iptables"      "iptables rules"
    backup_path "/etc/pve/firewall"  "Proxmox firewall rules"
}

# -----------------------------------------------------------------------------
# SECTION 5: SSH keys and daemon config
# -----------------------------------------------------------------------------

section_ssh_keys() {
    log "[5/8] SSH keys and daemon config"
    backup_path "/etc/ssh/sshd_config"   "SSH daemon config"
    backup_path "/etc/ssh/sshd_config.d" "SSH daemon config.d"
    backup_path "/root/.ssh"             "Root SSH keys / authorized_keys"
}

# -----------------------------------------------------------------------------
# SECTION 6: System state snapshot
# -----------------------------------------------------------------------------

section_system_state() {
    log "[6/8] System state snapshot"
    local s="system-state"
    mkdir -p "$STAGE_DIR/$s"

    # Package state — lets you reproduce the exact package set:
    #   dpkg --set-selections < dpkg-selections.txt && apt-get dselect-upgrade
    backup_cmd_output "$s/dpkg-selections.txt"   "Installed packages"          dpkg --get-selections
    backup_cmd_output "$s/apt-holds.txt"         "APT held packages"           apt-mark showhold
    backup_cmd_output "$s/apt-manual.txt"        "Manually installed packages" apt-mark showmanual

    backup_cmd_output "$s/proxmox-version.txt"   "Proxmox version"             pveversion --verbose
    backup_cmd_output "$s/kernel-version.txt"    "Kernel version"              uname -r
    backup_cmd_output "$s/disk-layout-lsblk.txt" "Disk layout (lsblk)" \
        lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,UUID
    backup_cmd_output "$s/disk-layout-fdisk.txt" "Disk layout (fdisk -l)"     fdisk -l

    backup_path "/etc/fstab" "fstab"

    if [[ "$BACKUP_ZFS" == "true" ]]; then
        backup_cmd_output "$s/zfs-pool-status.txt"  "ZFS pool status"   zpool status
        backup_cmd_output "$s/zfs-pool-list.txt"    "ZFS pool list"     zpool list -v
        backup_cmd_output "$s/zfs-dataset-list.txt" "ZFS dataset list"  zfs list -t all

        local zfs_dir="$STAGE_DIR/$s/zfs-configs"
        mkdir -p "$zfs_dir"
        while IFS= read -r pool; do
            [[ -z "$pool" ]] && continue
            zpool get all "$pool" > "$zfs_dir/${pool}-properties.txt" 2>>"$LOG" \
                && log "  ✓ ZFS pool properties: $pool" \
                || log_warn "ZFS pool property export failed: $pool"
        done < <(zpool list -H -o name 2>/dev/null)
    fi
}

# -----------------------------------------------------------------------------
# SECTION 7: Custom scripts
# -----------------------------------------------------------------------------

section_custom_scripts() {
    log "[7/8] Custom scripts"
    backup_path "/usr/local/bin"   "Custom scripts in /usr/local/bin"
    backup_path "/root/scripts"    "Root scripts folder"
    # Back up the backup script itself so it travels with the backup
    backup_path "$(realpath "${BASH_SOURCE[0]%/lib/*}/backup.sh")" "backup.sh"
    backup_path "$(realpath "${BASH_SOURCE[0]%/lib/*}/config.sh")"  "config.sh"
}

# -----------------------------------------------------------------------------
# SECTION 8: Minecraft weekly archives (SSH bridge to KVM guest)
# -----------------------------------------------------------------------------

section_minecraft_archives() {
    log "[8/8] Minecraft weekly archives (SSH bridge to KVM guest)"

    # Minecraft runs inside a KVM VM — its filesystem is opaque to this host.
    # We reach it over SSH, discover instances, age-gate files to guard against
    # copying archives still being compressed by the guest, then pull via rsync.

    if [[ -z "$MC_VM_IP" ]]; then
        log_warn "MC_VM_IP not set in config.sh — skipping Minecraft archives."
        return 0
    fi

    if ! ssh "${SSH_OPTS[@]}" "$MC_VM_USER@$MC_VM_IP" "exit" 2>/dev/null; then
        log_warn "Cannot connect to Minecraft VM at $MC_VM_IP (user: $MC_VM_USER). Skipping."
        return 0
    fi

    # Discover instance directories inside the VM; mapfile handles names with spaces
    mapfile -t instance_dirs < <(
        ssh "${SSH_OPTS[@]}" "$MC_VM_USER@$MC_VM_IP" \
            "find \"$MINECRAFT_BASE\" -mindepth 1 -maxdepth 1 -type d 2>/dev/null" \
            2>/dev/null || true
    )

    if [[ ${#instance_dirs[@]} -eq 0 ]]; then
        log_warn "No Minecraft instance directories found at $MINECRAFT_BASE inside VM."
        return 0
    fi

    local total_copied=0
    local total_skipped=0
    local total_failed=0
    local found_any=false

    for instance_dir in "${instance_dirs[@]}"; do
        local instance_name
        instance_name=$(basename "$instance_dir")
        local weekly_dir="$instance_dir/backups/archives/weekly"
        local dest="$STAGE_DIR/minecraft/$instance_name"

        # Build the remote find command.
        # -mmin +N: only files untouched for at least MC_ARCHIVE_MIN_AGE_MINUTES.
        # This is the KVM-safe replacement for fuser: we cannot inspect file locks
        # across the hypervisor boundary, so mtime age-gating is the safeguard.
        local find_cmd="find \"$weekly_dir\" -maxdepth 1 -type f"
        find_cmd+=" \\( -name '*.tar.zst' -o -name '*.tar.gz' -o -name '*.zip' \\)"
        if [[ $MC_ARCHIVE_MIN_AGE_MINUTES -gt 0 ]]; then
            find_cmd+=" -mmin +${MC_ARCHIVE_MIN_AGE_MINUTES}"
        fi
        find_cmd+=" 2>/dev/null | sort | tail -n $KEEP_WEEKLY_ARCHIVES"

        mapfile -t safe_files < <(
            ssh "${SSH_OPTS[@]}" "$MC_VM_USER@$MC_VM_IP" "$find_cmd" 2>/dev/null || true
        )

        if [[ ${#safe_files[@]} -eq 0 ]]; then
            log_warn "$instance_name — no finalized archives found (still writing, or none exist)."
            (( total_skipped++ )) || true
            continue
        fi

        mkdir -p "$dest"
        found_any=true
        log "  Instance: $instance_name (${#safe_files[@]} archive(s) ready)"

        for remote_file in "${safe_files[@]}"; do
            [[ -z "$remote_file" ]] && continue
            local fname
            fname=$(basename "$remote_file")

            if rsync -a -e "ssh ${SSH_OPTS[*]}" \
                    "$MC_VM_USER@$MC_VM_IP:$remote_file" "$dest/" 2>>"$LOG"; then
                log "    ✓ $fname"
                (( total_copied++ )) || true
            else
                log_err "    rsync failed: $fname"
                (( total_failed++ )) || true
            fi
        done

        # Prune local staging to KEEP_WEEKLY_ARCHIVES.
        # Sort by mtime (Unix epoch, oldest first) so pruning is independent of
        # filename conventions — we always remove the genuinely oldest files.
        mapfile -t local_files < <(
            find "$dest" -maxdepth 1 -type f -printf '%T@ %p\n' | sort -n | awk '{print $2}'
        )
        if [[ ${#local_files[@]} -gt $KEEP_WEEKLY_ARCHIVES ]]; then
            local excess=$(( ${#local_files[@]} - KEEP_WEEKLY_ARCHIVES ))
            for (( i=0; i<excess; i++ )); do
                rm -f "${local_files[$i]}"
                log "    pruned: $(basename "${local_files[$i]}")"
            done
        fi
    done

    $found_any || log_warn "No Minecraft instances had finalized weekly archives."
    log "  Minecraft: $total_copied copied, $total_skipped skipped, $total_failed failed"
}