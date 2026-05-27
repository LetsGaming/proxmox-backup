#!/bin/bash
# =============================================================================
# types/minecraft.sh — Minecraft VM backup handler
#
# Sourced by agent.sh when type=minecraft. Must implement run_backup().
#
# Designed to work in tandem with minecraft-server-setup:
#   https://github.com/LetsGaming/minecraft-server-setup
#
# minecraft-server-setup runs its own independent GFS backup rotation inside
# the VM, producing .tar.zst archives under:
#   $BACKUPS_PATH/<instance>/archives/weekly/
#   $BACKUPS_PATH/<instance>/archives/daily/     (if MC_INCLUDE_DAILY="true")
#
# This handler finds those archives, age-gates them to avoid in-progress files,
# and stages them into the bundle for PABS to pull to USB. It also captures
# the server config files so the server itself can be rebuilt from scratch
# without needing a world restore.
#
# ALL DEFAULTS MATCH AN UNMODIFIED minecraft-server-setup INSTALL.
# Override in /etc/pabs-agent/config only if you changed variables.json.
#
#   MINECRAFT_BASE="/home/minecraft/minecraft-server/backups"
#                           Parent backups/ directory. Each subdirectory is one
#                           INSTANCE_NAME. Matches minecraft-server-setup's
#                           default TARGET_DIR_NAME + BACKUPS_PATH layout.
#
#   MINECRAFT_SERVER_BASE="/home/minecraft/minecraft-server"
#                           Root of the server install — used to capture
#                           server.properties, ops.json, whitelist.json, etc.
#                           Leave empty to skip server config capture.
#
#   MC_KEEP_WEEKLY=4        How many weekly archives to include per instance.
#   MC_KEEP_DAILY=0         How many daily archives to include (0 = skip daily).
#   MC_MIN_AGE_MINUTES=5    Only include archives older than this (age-gate
#                           against in-progress compression). Must match or
#                           exceed minecraft-server-setup's compression time.
#   MC_INCLUDE_MODS="true"  Include the mods/ directory from each server
#                           instance (typically small — just .jar files).
#   MC_EXTRA_PATHS=""       Space-separated extra paths to always include.
# =============================================================================

# --- Defaults (all match unmodified minecraft-server-setup) ---
MINECRAFT_BASE="${MINECRAFT_BASE:-/home/minecraft/minecraft-server/backups}"
MINECRAFT_SERVER_BASE="${MINECRAFT_SERVER_BASE:-/home/minecraft/minecraft-server}"
MC_KEEP_WEEKLY="${MC_KEEP_WEEKLY:-4}"
MC_KEEP_DAILY="${MC_KEEP_DAILY:-0}"
MC_MIN_AGE_MINUTES="${MC_MIN_AGE_MINUTES:-5}"
MC_INCLUDE_MODS="${MC_INCLUDE_MODS:-true}"
MC_EXTRA_PATHS="${MC_EXTRA_PATHS:-}"

# Populated during run_backup, used by restore notes
_mc_instances=()
_mc_total_archives=0
_mc_total_size_mb=0

# -----------------------------------------------------------------------------
# ARCHIVE DISCOVERY
# -----------------------------------------------------------------------------

# Find finalized archives in a given directory.
# Usage: _find_archives <dir> <keep_count>
# Prints the N most recent files by mtime, filtered by age-gate.
_find_archives() {
    local dir="$1"
    local keep="$2"

    [[ -d "$dir" ]] || return 0
    [[ "$keep" -gt 0 ]] || return 0

    # Age-gate: skip files still being written/compressed by MC backup script.
    # fuser/lsof would be ideal but are unreliable inside containers/VMs under
    # some configurations. mtime age-gating is the safe universal alternative.
    local age_args=()
    if [[ "$MC_MIN_AGE_MINUTES" -gt 0 ]]; then
        age_args=( -mmin "+${MC_MIN_AGE_MINUTES}" )
    fi

    # Sort by mtime ascending (oldest first), then take the last N (newest N).
    # Using -printf '%T@ %p\n' + sort-n + tail avoids eval entirely; $dir is
    # passed as a direct argument so shell metacharacters in the path are safe.
    find "$dir" -maxdepth 1 -type f \
        \( -name '*.tar.zst' -o -name '*.tar.gz' \) \
        "${age_args[@]}" \
        -printf '%T@ %p\n' 2>/dev/null \
        | sort -n | tail -n "$keep" | awk '{print $2}'
}

# -----------------------------------------------------------------------------
# INSTANCE BACKUP
# -----------------------------------------------------------------------------

_backup_instance() {
    local instance_name="$1"
    local instance_backup_dir="$MINECRAFT_BASE/$instance_name"
    local dest="$STAGE_DIR/minecraft/$instance_name"
    mkdir -p "$dest/archives"

    log "  Instance: $instance_name"

    local instance_archives=0

    # --- Weekly archives ---
    local weekly_dir="$instance_backup_dir/archives/weekly"
    if [[ -d "$weekly_dir" ]]; then
        while IFS= read -r archive; do
            [[ -z "$archive" ]] && continue
            local fname size_mb
            fname=$(basename "$archive")
            size_mb=$(du -sm "$archive" 2>/dev/null | cut -f1)

            if cp "$archive" "$dest/archives/$fname" 2>/dev/null; then
                log "    ✓ weekly: $fname (${size_mb}MB)"
                (( instance_archives++ )) || true
                (( _mc_total_archives++ )) || true
                (( _mc_total_size_mb += size_mb )) || true
            else
                log_warn "    failed to stage: $fname"
            fi
        done < <(_find_archives "$weekly_dir" "$MC_KEEP_WEEKLY")
    else
        log_warn "    no weekly archive dir found at $weekly_dir"
    fi

    # --- Daily archives (opt-in) ---
    if [[ "$MC_KEEP_DAILY" -gt 0 ]]; then
        local daily_dir="$instance_backup_dir/archives/daily"
        if [[ -d "$daily_dir" ]]; then
            while IFS= read -r archive; do
                [[ -z "$archive" ]] && continue
                local fname size_mb
                fname=$(basename "$archive")
                size_mb=$(du -sm "$archive" 2>/dev/null | cut -f1)

                if cp "$archive" "$dest/archives/daily-$fname" 2>/dev/null; then
                    log "    ✓ daily: $fname (${size_mb}MB)"
                    (( instance_archives++ )) || true
                    (( _mc_total_archives++ )) || true
                    (( _mc_total_size_mb += size_mb )) || true
                else
                    log_warn "    failed to stage daily: $fname"
                fi
            done < <(_find_archives "$daily_dir" "$MC_KEEP_DAILY")
        else
            log_warn "    MC_KEEP_DAILY>0 but no daily archive dir at $daily_dir"
        fi
    fi

    if [[ $instance_archives -eq 0 ]]; then
        log_warn "    no finalized archives found for $instance_name"
        log_warn "    (still compressing, or no backup has run yet)"
    fi

    _mc_instances+=("$instance_name ($instance_archives archives)")
}

# -----------------------------------------------------------------------------
# SERVER CONFIG FILES
# -----------------------------------------------------------------------------

_backup_server_configs() {
    [[ -n "$MINECRAFT_SERVER_BASE" ]] || return
    [[ -d "$MINECRAFT_SERVER_BASE" ]] || {
        log_warn "  MINECRAFT_SERVER_BASE not found: $MINECRAFT_SERVER_BASE"
        return
    }

    log "  Staging server config files from $MINECRAFT_SERVER_BASE..."

    # Scan each instance directory under the server base for config files.
    # minecraft-server-setup uses TARGET_DIR_NAME/INSTANCE_NAME layout, so
    # each subdirectory of MINECRAFT_SERVER_BASE is one server instance.
    while IFS= read -r instance_dir; do
        local instance_name
        instance_name=$(basename "$instance_dir")
        local config_dest="$STAGE_DIR/minecraft/$instance_name/server-config"
        mkdir -p "$config_dest"

        # Core server config files — everything needed to rebuild the server
        # without restoring a world backup
        for cfg in \
            server.properties \
            ops.json \
            whitelist.json \
            banned-players.json \
            banned-ips.json \
            eula.txt \
            bukkit.yml \
            spigot.yml \
            paper.yml \
            paper-global.yml \
            paper-world-defaults.yml \
            config/paper-global.yml \
            config/paper-world-defaults.yml \
            plugins; do
            local src="$instance_dir/$cfg"
            [[ -e "$src" ]] && stage_path "$src" "  config: $instance_name/$cfg"
        done

        # Mods directory (opt-in, typically just .jar files — small)
        if [[ "$MC_INCLUDE_MODS" == "true" ]]; then
            local mods_dir="$instance_dir/mods"
            if [[ -d "$mods_dir" ]]; then
                stage_path "$mods_dir" "  mods: $instance_name/mods"
            fi
        fi

    done < <(find "$MINECRAFT_SERVER_BASE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
}

# -----------------------------------------------------------------------------
# RESTORE NOTES
# -----------------------------------------------------------------------------

_write_restore_notes() {
    cat > "$STAGE_DIR/restore-notes.txt" << EOF
PABS Minecraft VM Restore Notes
Generated: $(date '+%Y-%m-%d %H:%M:%S')  Host: $(hostname)
minecraft-server-setup: https://github.com/LetsGaming/minecraft-server-setup
========================================

INSTANCES BACKED UP:
$(printf "  %s\n" "${_mc_instances[@]:-  (none found)}")

Total archives: $_mc_total_archives  (~${_mc_total_size_mb}MB)
Age-gate:       files older than ${MC_MIN_AGE_MINUTES} minute(s) only

ARCHIVE LOCATIONS IN BUNDLE:
  minecraft/<instance>/archives/          Weekly (and optionally daily) .tar.zst files
  minecraft/<instance>/server-config/     server.properties, ops.json, mods/, plugins/, etc.

HOW TO RESTORE A WORLD:

  The .tar.zst archives are native minecraft-server-setup backups.
  Restore using minecraft-server-setup's own restore tooling, or manually:

  1. Stop the server:
       systemctl stop minecraft@<instance>   # or however you manage it

  2. Extract the archive to the server's world directory:
       cd /home/minecraft/minecraft-server/<instance>
       tar -I zstd -xf /path/to/archive.tar.zst

  3. Verify the world files are in place, then start the server:
       systemctl start minecraft@<instance>

HOW TO REBUILD THE SERVER FROM SCRATCH:

  1. Fresh Debian VM (proxmox-helper-scripts or manual)
  2. Re-run minecraft-server-setup install:
       https://github.com/LetsGaming/minecraft-server-setup
  3. Restore server config files from minecraft/<instance>/server-config/:
       cp server.properties /home/minecraft/minecraft-server/<instance>/
       cp ops.json whitelist.json banned-*.json /home/minecraft/minecraft-server/<instance>/
$([ "$MC_INCLUDE_MODS" == "true" ] && echo "       rsync -a mods/ /home/minecraft/minecraft-server/<instance>/mods/")
  4. Restore the world from the archive (see above)
  5. Start the server

NOTES:
  - Archives are produced by minecraft-server-setup's GFS rotation
  - World data is whatever minecraft-server-setup chose to include
  - Config files (server.properties, ops, whitelist) are captured separately
    so you can rebuild the server without necessarily restoring a world
  - Server version / mod list is reproducible from server-config/mods/ and
    minecraft-server-setup's variables.json (not backed up here — lives in
    the minecraft-server-setup repo or your own config management)

EOF
    log "  ✓ restore-notes.txt written"
}

# -----------------------------------------------------------------------------
# ENTRY POINT
# -----------------------------------------------------------------------------

run_backup() {
    log "Minecraft backup starting on $(hostname)"

    [[ -d "$MINECRAFT_BASE" ]] || {
        die "MINECRAFT_BASE not found: $MINECRAFT_BASE — set it in /etc/pabs-agent/config"
    }

    # Discover instances — each subdirectory of MINECRAFT_BASE is one instance
    local instance_dirs=()
    while IFS= read -r d; do
        instance_dirs+=("$(basename "$d")")
    done < <(find "$MINECRAFT_BASE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

    if [[ ${#instance_dirs[@]} -eq 0 ]]; then
        log_warn "No instance directories found under $MINECRAFT_BASE"
        log_warn "Has minecraft-server-setup run at least one backup cycle?"
    else
        log "Found ${#instance_dirs[@]} instance(s): ${instance_dirs[*]}"
        for instance in "${instance_dirs[@]}"; do
            _backup_instance "$instance"
        done
    fi

    # Server config files (server.properties, mods, plugins, etc.)
    _backup_server_configs

    # Extra paths
    if [[ -n "$MC_EXTRA_PATHS" ]]; then
        log "  Staging extra paths..."
        for path in $MC_EXTRA_PATHS; do
            stage_path "$path" "extra: $path"
        done
    fi

    # System state — useful if you need to know what OS/Java version was running
    stage_cmd "system-state/java-version.txt"  "Java version"  bash -c 'java -version 2>&1'
    stage_cmd "system-state/os-release.txt"    "OS release"    cat /etc/os-release
    stage_cmd "system-state/hostname.txt"      "Hostname"      hostname

    _write_restore_notes

    log "Minecraft backup complete — $_mc_total_archives archive(s), ~${_mc_total_size_mb}MB"
}
