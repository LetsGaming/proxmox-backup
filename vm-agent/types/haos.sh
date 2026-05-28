#!/bin/bash
# =============================================================================
# types/haos.sh — Home Assistant OS backup handler
#
# Sourced by agent.sh when type=haos. Must implement run_backup().
#
# WHAT THIS BACKS UP:
#   A full HAOS native snapshot (.tar) triggered via the `ha` CLI, which is
#   available inside the community SSH add-on. The snapshot is the officially
#   supported HAOS backup format — it can be restored in one click via the
#   HA UI (Settings → Backups → Upload) or via `ha backup restore <slug>`.
#
# HOW IT WORKS:
#   1. Triggers: ha backup new --name "pabs-<date>"
#   2. Polls until the backup appears in: ha backup list
#   3. The backup file lives at /backup/<slug>.tar inside the add-on shell
#   4. agent.sh copies it into the bundle; PABS pulls it back to USB
#
# ALL DEFAULTS ARE OVERRIDABLE in /etc/pabs-agent/config:
#
#   HAOS_BACKUP_DIR="/backup"           Where HA stores snapshots (inside add-on shell)
#   HAOS_BACKUP_NAME="pabs-auto"        Prefix for the generated backup name
#   HAOS_BACKUP_TYPE="full"             "full" or "partial"
#   HAOS_BACKUP_PASSWORD=""             Encrypt the snapshot (leave empty = no encryption)
#   HAOS_WAIT_SECONDS=300               Max seconds to wait for backup to finish
#   HAOS_POLL_INTERVAL=10               How often to poll (seconds)
#   HAOS_KEEP_ON_HOST=1                 How many pabs-* backups to keep on the HA host
#                                       (oldest auto-pruned after successful pull)
#   HAOS_PARTIAL_ADDONS=""              Comma-separated add-on slugs (partial backup only)
#   HAOS_PARTIAL_FOLDERS=""             Comma-separated folders (partial backup only)
#                                       Valid folders: homeassistant,ssl,share,media,addons/local
# =============================================================================

# --- Defaults ---
HAOS_BACKUP_DIR="${HAOS_BACKUP_DIR:-/backup}"
HAOS_BACKUP_NAME="${HAOS_BACKUP_NAME:-pabs-auto}"
HAOS_BACKUP_TYPE="${HAOS_BACKUP_TYPE:-full}"
HAOS_BACKUP_PASSWORD="${HAOS_BACKUP_PASSWORD:-}"
HAOS_WAIT_SECONDS="${HAOS_WAIT_SECONDS:-300}"
HAOS_POLL_INTERVAL="${HAOS_POLL_INTERVAL:-10}"
HAOS_KEEP_ON_HOST="${HAOS_KEEP_ON_HOST:-1}"
HAOS_PARTIAL_ADDONS="${HAOS_PARTIAL_ADDONS:-}"
HAOS_PARTIAL_FOLDERS="${HAOS_PARTIAL_FOLDERS:-}"

# -----------------------------------------------------------------------------
# HA CLI WRAPPER
# -----------------------------------------------------------------------------

# Check that the ha CLI is available — it's present in the SSH add-on shell
_check_ha_cli() {
    command -v ha &>/dev/null || die "ha CLI not found. Is this running inside the HAOS SSH add-on?"
}

# Run a ha CLI command and return its JSON output.
# The ha CLI outputs YAML by default; --raw-json returns clean JSON.
_ha() {
    ha --raw-json "$@" 2>/dev/null
}

# -----------------------------------------------------------------------------
# TRIGGER BACKUP
# -----------------------------------------------------------------------------

_trigger_backup() {
    local backup_label
    backup_label="${HAOS_BACKUP_NAME}-$(date '+%Y%m%d-%H%M')"
    log "Triggering HAOS $HAOS_BACKUP_TYPE backup: '$backup_label'"

    # Build the ha backup new command
    local cmd_args=("backup" "new" "--name" "$backup_label")

    if [[ "$HAOS_BACKUP_TYPE" == "partial" ]]; then
        # Partial backup — add-ons and/or folders
        if [[ -n "$HAOS_PARTIAL_ADDONS" ]]; then
            IFS=',' read -ra addon_slugs <<< "$HAOS_PARTIAL_ADDONS"
            for slug in "${addon_slugs[@]}"; do
                slug="$(echo "$slug" | xargs)"
                cmd_args+=("--addons" "$slug")
            done
        fi
        if [[ -n "$HAOS_PARTIAL_FOLDERS" ]]; then
            IFS=',' read -ra folders <<< "$HAOS_PARTIAL_FOLDERS"
            for folder in "${folders[@]}"; do
                folder="$(echo "$folder" | xargs)"
                cmd_args+=("--folders" "$folder")
            done
        fi
        log "  Partial backup: addons='$HAOS_PARTIAL_ADDONS' folders='$HAOS_PARTIAL_FOLDERS'"
    fi

    if [[ -n "$HAOS_BACKUP_PASSWORD" ]]; then
        cmd_args+=("--password" "$HAOS_BACKUP_PASSWORD")
        log "  Backup will be encrypted"
    fi

    # ha backup new returns a JSON object: {"slug": "abcd1234"}
    local result
    result=$(_ha "${cmd_args[@]}") || die "ha backup new failed: $result"

    local slug
    slug=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('slug',''))" 2>/dev/null)

    [[ -n "$slug" ]] || die "ha backup new did not return a slug. Output: $result"

    echo "$slug"
}

# -----------------------------------------------------------------------------
# WAIT FOR BACKUP TO COMPLETE
# -----------------------------------------------------------------------------

_wait_for_backup() {
    local slug="$1"
    local waited=0

    log "Waiting for backup '$slug' to appear (max ${HAOS_WAIT_SECONDS}s)..."

    while true; do
        # ha backup list returns all backups; we look for our slug
        local list_json
        list_json=$(_ha backup list 2>/dev/null) || true

        local found
        found=$(echo "$list_json" | python3 -c '
import json, sys
slug = sys.argv[1]
try:
    data = json.load(sys.stdin)
    # The API returns either a list directly or {"backups": [...]}
    backups = data if isinstance(data, list) else data.get("backups", [])
    for b in backups:
        if b.get("slug") == slug:
            print("found")
            break
except Exception:
    pass
' "$slug") || true

        if [[ "$found" == "found" ]]; then
            log "  ✓ Backup '$slug' ready"
            return 0
        fi

        if [[ $waited -ge $HAOS_WAIT_SECONDS ]]; then
            die "Timed out waiting for HAOS backup '$slug' after ${HAOS_WAIT_SECONDS}s"
        fi

        sleep "$HAOS_POLL_INTERVAL"
        waited=$(( waited + HAOS_POLL_INTERVAL ))
        log "  ...still waiting (${waited}s elapsed)"
    done
}

# -----------------------------------------------------------------------------
# PULL BACKUP FILE
# -----------------------------------------------------------------------------

_pull_backup_file() {
    local slug="$1"
    local backup_file="$HAOS_BACKUP_DIR/${slug}.tar"

    [[ -f "$backup_file" ]] || die "Backup file not found at expected path: $backup_file"

    local size_mb
    size_mb=$(du -sm "$backup_file" 2>/dev/null | cut -f1)
    log "Pulling backup file: $backup_file (${size_mb}MB)"

    # Copy into staging as haos-backup/<slug>.tar
    mkdir -p "$STAGE_DIR/haos-backup"
    cp "$backup_file" "$STAGE_DIR/haos-backup/${slug}.tar"

    log "  ✓ Backup file staged (${size_mb}MB)"
    echo "${size_mb}"
}

# -----------------------------------------------------------------------------
# PRUNE OLD PABS BACKUPS FROM HA HOST
# -----------------------------------------------------------------------------

_prune_old_host_backups() {
    [[ $HAOS_KEEP_ON_HOST -le 0 ]] && return

    log "Pruning old pabs-* backups on HA host (keeping $HAOS_KEEP_ON_HOST)..."

    local list_json
    list_json=$(_ha backup list 2>/dev/null) || return

    # Collect pabs-* backup slugs sorted by date (oldest first)
    local old_slugs
    old_slugs=$(echo "$list_json" | python3 -c '
import json, sys
prefix = sys.argv[1]
keep = int(sys.argv[2])
try:
    data = json.load(sys.stdin)
    backups = data if isinstance(data, list) else data.get("backups", [])
    pabs = [b for b in backups if b.get("name", "").startswith(prefix)]
    # Sort by date ascending (oldest first)
    pabs.sort(key=lambda b: b.get("date", ""))
    to_remove = pabs[:-keep] if keep > 0 else pabs
    for b in to_remove:
        print(b["slug"])
except Exception as e:
    import sys; print(f"# error: {e}", file=sys.stderr)
' "$HAOS_BACKUP_NAME" "$HAOS_KEEP_ON_HOST") || true

    if [[ -z "$old_slugs" ]]; then
        log "  Nothing to prune"
        return
    fi

    while IFS= read -r slug; do
        [[ -z "$slug" || "$slug" == \#* ]] && continue
        log "  Removing old backup: $slug"
        _ha backup remove "$slug" >/dev/null 2>&1 \
            && log "  ✓ Removed $slug" \
            || log_warn "  Could not remove $slug (non-fatal)"
    done <<< "$old_slugs"
}

# -----------------------------------------------------------------------------
# RESTORE NOTES
# -----------------------------------------------------------------------------

_write_restore_notes() {
    local slug="$1"
    local size_mb="$2"

    cat > "$STAGE_DIR/restore-notes.txt" << EOF
PABS Home Assistant OS Restore Notes
Generated: $(date '+%Y-%m-%d %H:%M:%S')  Host: $(hostname)
Backup slug: $slug
Backup size: ${size_mb}MB
Backup type: $HAOS_BACKUP_TYPE
Encrypted:   $([ -n "$HAOS_BACKUP_PASSWORD" ] && echo "YES (password required)" || echo "no")
========================================

THE BACKUP FILE:
  haos-backup/${slug}.tar

  This is a native HAOS snapshot — the standard format supported by
  Home Assistant. It contains the full HA configuration, add-ons,
  and (for a full backup) all HA data.

HOW TO RESTORE:

  OPTION A — Web UI (easiest):
    1. Fresh HAOS install on new hardware (proxmox-helper-scripts)
    2. Wait for onboarding to appear
    3. Click "Restore from backup" on the onboarding screen
    4. Upload haos-backup/${slug}.tar
    5. Select what to restore and confirm
    6. HA will restore and reboot automatically

  OPTION B — CLI (if HA is already running):
    1. Copy ${slug}.tar into the HA /backup/ directory
    2. SSH into the add-on shell
    3. ha backup restore ${slug}$([ -n "$HAOS_BACKUP_PASSWORD" ] && echo " --password <your-password>")
    4. Wait for restore + reboot

  OPTION C — Supervisor API:
    POST /api/backups/${slug}/restore/full
    Header: Authorization: Bearer <long-lived-token>
$([ -n "$HAOS_BACKUP_PASSWORD" ] && echo "    Body: {\"password\": \"<your-password>\"}")

NOTES:
$([ "$HAOS_BACKUP_TYPE" == "partial" ] && echo "  - This is a PARTIAL backup (addons: $HAOS_PARTIAL_ADDONS / folders: $HAOS_PARTIAL_FOLDERS)")
$([ "$HAOS_BACKUP_TYPE" == "full" ] && echo "  - Full backup includes: HA config, add-ons, SSL, share, media, local add-ons")
  - The snapshot was created with: ha backup new --name pabs-auto-... (native HAOS command)
  - HAOS version at backup time: $(ha core info --raw-json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('version','unknown'))" 2>/dev/null || echo "unknown")

EOF
    log "  ✓ restore-notes.txt written"
}

# -----------------------------------------------------------------------------
# ENTRY POINT
# -----------------------------------------------------------------------------

run_backup() {
    log "HAOS backup starting on $(hostname)"
    _check_ha_cli

    # Trigger the backup
    local slug
    slug=$(_trigger_backup)
    log "Backup slug: $slug"

    # Wait for it to finish
    _wait_for_backup "$slug"

    # Pull the file into staging
    local size_mb
    size_mb=$(_pull_backup_file "$slug")

    # Write restore instructions
    _write_restore_notes "$slug" "$size_mb"

    # Clean up old pabs-* backups from the HA host
    _prune_old_host_backups

    log "HAOS backup complete — slug: $slug (${size_mb}MB)"
}
