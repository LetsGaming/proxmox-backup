#!/bin/bash
# =============================================================================
# PABS — Proxmox Automated Backup System
# Version 3.3
#
# Entry point. Sources config and library files, then runs the backup.
# The only logic here is the top-level execution sequence.
#
# File layout:
#   backup.sh              ← you are here (run this)
#   config.sh              ← edit this to configure your setup
#   lib/core.sh            ← logging, lock, trap, notifications
#   lib/preflight.sh       ← pre-flight validation checks
#   lib/sections.sh        ← 8 backup section functions + helpers
#   lib/manifest.sh        ← SHA256 manifest generation/verification, rotation
#   lib/output.sh          ← generates restore script and README inside each backup
#   vm-agent/agent.sh      ← deployed to VMs/LXCs for lightweight agent backups
#   install-agent.sh       ← one-time setup: deploys vm-agent to a VM over SSH
#
# Usage:
#   ./backup.sh
#   (schedule with cron: 0 3 * * 0 /path/to/pabs/backup.sh)
# =============================================================================

set -euo pipefail

# Resolve the directory this script lives in, regardless of how it was called
PABS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source config first — defines all variables consumed by the libs
source "$PABS_DIR/config.sh"

# Source libs in dependency order:
#   core.sh sets up logging and the ERR/EXIT trap; everything after needs log()
source "$PABS_DIR/lib/core.sh"
source "$PABS_DIR/lib/preflight.sh"
source "$PABS_DIR/lib/sections.sh"
source "$PABS_DIR/lib/manifest.sh"
source "$PABS_DIR/lib/output.sh"

# =============================================================================
# MAIN
# =============================================================================

check_root
check_usb_mounted

mkdir -p "$BACKUP_ROOT" "$LOCAL_STAGE_BASE"
acquire_lock

log "========================================"
log "PABS backup started — $DATE"
log "Version        : $SCRIPT_VERSION"
log "Host           : $(hostname)"
log "USB mount      : $USB_MOUNT"
log "Local stage    : $LOCAL_STAGE_BASE"
log "MC VM          : (handled via VM agent)"
log "VM agents      : ${#VM_AGENTS[@]} configured"
log "========================================"

check_local_stage_space
check_usb_space

mkdir -p "$STAGE_DIR"

# --- Backup sections — all output goes to STAGE_DIR on local SSD --------
# The USB drive is completely untouched during this phase.
section_proxmox_configs      # [1/8] /etc/pve (tar), network, hosts, APT
section_vm_ct_definitions    # [2/8] qm/pct config exports + raw pmxcfs files
section_cron_jobs            # [3/8] crontabs
section_firewall             # [4/8] nftables, iptables, Proxmox firewall
section_ssh_keys             # [5/8] sshd_config, /root/.ssh
section_system_state         # [6/8] packages, disk layout, ZFS (if enabled)
section_custom_scripts       # [7/8] /usr/local/bin, /root/scripts, this script
section_vm_agents            # [8/8] lightweight agent backups for all VMs and LXCs

# Verify integrity on local SSD before a single byte goes to USB.
# A failed check aborts cleanly; _on_exit cleans up STAGE_DIR.
generate_and_verify_manifest

# --- Atomic USB commit sequence -----------------------------------------

log "Flushing local write buffers..."
sync

log "Transferring verified backup to USB..."
# Detach the cleanup trap before the transfer. From here we handle errors
# manually so we can distinguish "local stage still exists" from "already on USB".
trap - ERR EXIT

# --whole-file disables rsync's delta algorithm — this is a local copy, not a
# network transfer, so there are no checksums to compare and no partial files
# to resume. A direct sequential stream is faster and kinder to flash storage.
# --inplace is intentionally NOT used: it writes in-place, leaving a
# partial/corrupt file indistinguishable from a complete one after power loss.
# Atomicity is provided by the .tmp → mv rename below.
if rsync -a --whole-file "$STAGE_DIR/" "$FINAL_DIR.tmp/" 2>>"$LOG"; then
    log "  Transfer complete."
else
    log "FATAL: rsync to USB failed. Cleaning up."
    rm -rf "$FINAL_DIR.tmp" "$STAGE_DIR"
    dispatch_alert "FAILED: rsync to USB failed during transfer. Backup not committed."
    release_lock
    exit 1
fi

sync

# Atomic rename — backup only becomes "visible" after all bytes are on flash
mv "$FINAL_DIR.tmp" "$FINAL_DIR"
sync

# Local staging freed — USB holds the only copy now
rm -rf "$STAGE_DIR"

# Re-attach trap for post-commit work (generate_restore_script, verification)
trap '_on_exit' ERR EXIT

generate_restore_script
generate_readme
generate_dr_playbook
sync

# Belt-and-suspenders: re-verify the manifest against what landed on USB
verify_manifest_on_usb

# Rotate old backups only after the new one is successfully committed
rotate_old_backups

release_lock
trap - ERR EXIT

# --- Summary ----------------------------------------------------------------
BACKUP_SIZE=$(du -sh "$FINAL_DIR" 2>/dev/null | cut -f1)
log "========================================"
log "Backup complete!"
log "Location : $FINAL_DIR"
log "Size     : $BACKUP_SIZE"
log "Warnings : $WARNINGS"
log "Errors   : $ERRORS"
log "========================================"

if [[ $ERRORS -gt 0 ]]; then
    log "⚠  Backup finished with $ERRORS error(s). Review the log."
    dispatch_alert "Backup $DATE finished with $ERRORS error(s). Review: $LOG"
    exit 1
fi

[[ $WARNINGS -gt 0 ]] && log "ℹ  $WARNINGS warning(s) — non-fatal, review log if unexpected."

dispatch_alert "SUCCESS — backup $DATE complete. Size: $BACKUP_SIZE. Warnings: $WARNINGS"

exit 0
