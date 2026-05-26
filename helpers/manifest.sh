#!/bin/bash
# =============================================================================
# lib/manifest.sh — SHA256 manifest generation/verification and backup rotation
# =============================================================================

# -----------------------------------------------------------------------------
# MANIFEST
# Generates checksums against STAGE_DIR (local SSD) and verifies them BEFORE
# the atomic USB write. A corrupt local write aborts cleanly; the USB is never
# touched with unverified data. A second verification runs post-USB-transfer.
# -----------------------------------------------------------------------------

generate_and_verify_manifest() {
    log "Generating SHA256 manifest in staging..."

    local manifest="$STAGE_DIR/MANIFEST.sha256"
    (
        cd "$STAGE_DIR"
        find . -type f ! -name "MANIFEST.sha256" -print0 \
            | sort -z \
            | xargs -0 sha256sum \
            > MANIFEST.sha256
    )

    local file_count
    file_count=$(wc -l < "$manifest")
    log "  Manifest written ($file_count files). Verifying on local stage..."

    if ( cd "$STAGE_DIR" && sha256sum --quiet --check MANIFEST.sha256 2>>"$LOG" ); then
        log "  ✓ All $file_count checksums verified on local stage"
    else
        # _on_exit (core.sh) will clean up STAGE_DIR and fire the alert
        die "Manifest verification FAILED on local stage. Aborting before USB write."
    fi
}

verify_manifest_on_usb() {
    log "Re-verifying manifest on USB..."
    if ( cd "$FINAL_DIR" && sha256sum --quiet --check MANIFEST.sha256 2>>"$LOG" ); then
        log "  ✓ USB transfer integrity verified"
    else
        log_err "Manifest verification FAILED on USB. Backup may be corrupt — do not rely on it."
        dispatch_alert "USB write verification FAILED for backup $DATE. Backup may be corrupt."
    fi
}

# -----------------------------------------------------------------------------
# ROTATION
# Removes the oldest completed backup directories once we exceed KEEP_BACKUPS.
# Called only after a new backup has been successfully committed to USB.
# -----------------------------------------------------------------------------

rotate_old_backups() {
    log "Rotating old backups (keeping last $KEEP_BACKUPS)..."

    mapfile -t old_backups < <(
        find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name ".*" \
            | sort | head -n -"$KEEP_BACKUPS"
    )

    if [[ ${#old_backups[@]} -gt 0 ]]; then
        for dir in "${old_backups[@]}"; do
            log "  Removing: $dir"
            rm -rf "$dir"
        done
        sync
    else
        log "  Nothing to rotate."
    fi
}