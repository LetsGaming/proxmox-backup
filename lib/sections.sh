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
        backup_cmd_output "$s/zfs-pool-status.txt"       "ZFS pool status"              zpool status
        backup_cmd_output "$s/zfs-pool-status-by-id.txt" "ZFS pool status (by-id paths)" zpool status -P
        backup_cmd_output "$s/zfs-pool-list.txt"         "ZFS pool list"                zpool list -v
        backup_cmd_output "$s/zfs-dataset-list.txt"      "ZFS dataset list"             zfs list -t all

        local zfs_dir="$STAGE_DIR/$s/zfs-configs"
        mkdir -p "$zfs_dir"
        while IFS= read -r pool; do
            [[ -z "$pool" ]] && continue
            zpool get all "$pool" > "$zfs_dir/${pool}-properties.txt" 2>>"$LOG" \
                && log "  ✓ ZFS pool properties: $pool" \
                || log_warn "ZFS pool property export failed: $pool"
        done < <(zpool list -H -o name 2>/dev/null)
    fi

    # LVM — export human-readable summaries and a machine-readable vgcfgbackup
    # that can be restored with: vgcfgrestore -f lvm-vg-<name>.cfg <vg-name>
    if command -v vgs &>/dev/null && vgs &>/dev/null 2>/dev/null; then
        backup_cmd_output "$s/lvm-pvs.txt" "LVM physical volumes" pvs  --units b --nosuffix
        backup_cmd_output "$s/lvm-vgs.txt" "LVM volume groups"    vgs  --units b --nosuffix
        backup_cmd_output "$s/lvm-lvs.txt" "LVM logical volumes"  lvs  --units b --nosuffix
        vgcfgbackup -f "$STAGE_DIR/$s/lvm-vg-%s.cfg" 2>>"$LOG" \
            && log "  ✓ LVM VG configs (machine-readable, restorable with vgcfgrestore)" \
            || log_warn "LVM vgcfgbackup failed (non-fatal — may require root or lvm2 installed)"
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
# SECTION 8: VM / LXC agent backups
#
# Minecraft backups are handled here via the VM agent — no separate section.
# Add your Minecraft VM to VM_AGENTS in config.sh:
#   "minecraft-vm  <ip>  minecraft  /opt/pabs-agent/agent.sh"
# -----------------------------------------------------------------------------

section_vm_agents() {
    log "[8/8] VM agent backups"

    # VM_AGENTS is defined in config.sh as an array of strings, one per VM/LXC.
    # Each entry format: "label  ip-or-hostname  ssh-user  agent-path"
    #   label       — short name used for the backup subfolder and log output
    #   ip/host     — address reachable from this Proxmox host
    #   ssh-user    — user to SSH in as (must have read access + can run agent.sh)
    #   agent-path  — full path to agent.sh on the remote host

    if [[ ${#VM_AGENTS[@]} -eq 0 ]]; then
        log "  No VM_AGENTS configured — skipping"
        return
    fi

    local total_ok=0
    local total_fail=0
    local total_skip=0

    for entry in "${VM_AGENTS[@]}"; do
        # Parse the 4 fields — tolerates multiple spaces/tabs as delimiter
        read -r label vm_host ssh_user agent_path <<< "$entry"

        if [[ -z "$label" || -z "$vm_host" || -z "$ssh_user" || -z "$agent_path" ]]; then
            log_warn "  Skipping malformed VM_AGENTS entry: '$entry'"
            log_warn "  Expected: \"label  ip-or-hostname  ssh-user  /path/to/agent.sh\""
            (( total_skip++ )) || true
            continue
        fi

        log "  [$label] $ssh_user@$vm_host"

        # Build SSH options for this VM.
        # Per-VM key: VM_SSH_KEY_<label> (dashes → underscores) takes precedence.
        # Falls back to shared VM_SSH_KEY, then to the host's default key.
        local ssh_opts=("${VM_AGENT_SSH_OPTS[@]}")
        local key_var="VM_SSH_KEY_${label//-/_}"
        if [[ -n "${!key_var:-}" ]]; then
            ssh_opts+=(-i "${!key_var}")
        elif [[ -n "${VM_SSH_KEY:-}" ]]; then
            ssh_opts+=(-i "$VM_SSH_KEY")
        fi

        # Check connectivity before attempting the backup
        if ! ssh "${ssh_opts[@]}" "$ssh_user@$vm_host" exit 2>/dev/null; then
            log_err "  [$label] Cannot connect to $vm_host — skipping"
            (( total_fail++ )) || true
            continue
        fi

        # Temporary bundle path on the remote host's /tmp
        local remote_bundle="/tmp/pabs-bundle-${label}-${DATE}.tar.zst"

        # Local destination inside the staging tree
        local local_dest="$STAGE_DIR/vm-agents/$label"
        mkdir -p "$local_dest"

        # Step 1: Run the agent on the remote host
        log "    Running agent on $vm_host..."
        if ! ssh "${ssh_opts[@]}" "$ssh_user@$vm_host" \
                "$agent_path" "--bundle-output" "$remote_bundle" 2>>"$LOG"; then
            log_err "  [$label] Agent failed on $vm_host"
            (( total_fail++ )) || true
            # Clean up any partial bundle left on the remote
            ssh "${ssh_opts[@]}" "$ssh_user@$vm_host" \
                "rm -f $remote_bundle" 2>/dev/null || true
            continue
        fi

        # Step 2: Rsync the bundle back to local staging
        log "    Pulling bundle from $vm_host..."
        if rsync -a -e "ssh ${ssh_opts[*]@Q}" \
                "$ssh_user@$vm_host:$remote_bundle" "$local_dest/" 2>>"$LOG"; then
            local size_kb
            size_kb=$(du -sk "$local_dest/$(basename "$remote_bundle")" 2>/dev/null | cut -f1)
            log "  ✓ [$label] bundle pulled (${size_kb}KB)"
            (( total_ok++ )) || true
        else
            log_err "  [$label] rsync of bundle failed"
            (( total_fail++ )) || true
        fi

        # Step 3: Remove the temporary bundle from the remote host
        ssh "${ssh_opts[@]}" "$ssh_user@$vm_host" \
            "rm -f $remote_bundle" 2>/dev/null || true

        # Step 4: Prune old bundles for this VM on USB (enforces VM_AGENT_KEEP_BUNDLES)
        # Note: this runs against STAGE_DIR (local SSD) — USB rotation happens
        # via the normal rotate_old_backups() which operates on whole backup dirs.
        # Per-VM bundle retention within a single backup dir is handled here.
        local keep="${VM_AGENT_KEEP_BUNDLES:-2}"
        mapfile -t existing_bundles < <(
            find "$local_dest" -maxdepth 1 -type f -name "*.tar.zst" \
                -printf '%T@ %p\n' | sort -n | awk '{print $2}'
        )
        if [[ ${#existing_bundles[@]} -gt $keep ]]; then
            local excess=$(( ${#existing_bundles[@]} - keep ))
            for (( i=0; i<excess; i++ )); do
                rm -f "${existing_bundles[$i]}"
                log "    pruned old bundle: $(basename "${existing_bundles[$i]}")"
            done
        fi
    done

    log "  VM agents: $total_ok OK, $total_fail failed, $total_skip skipped"

    if [[ $total_fail -gt 0 ]]; then
        log_err "  $total_fail VM agent(s) failed — see log for details"
    fi
}
