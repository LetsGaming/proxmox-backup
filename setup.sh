#!/bin/bash
# =============================================================================
# setup.sh — PABS Interactive Setup Wizard
#
# Orchestrator only — all step logic lives in setup/steps/*.sh.
# This file handles argument parsing, preflight, module loading, and the
# final summary. Nothing else.
#
# Usage:
#   sudo bash setup.sh                  # full wizard
#   sudo bash setup.sh --step usb       # jump to a specific step
#   sudo bash setup.sh --yes            # non-interactive / CI mode
#
# Steps: deps | usb | notifications | agents | offsite | cron | run
# =============================================================================

# Interactive wizard — do NOT use set -e here.
# set -e causes silent exits on any non-zero command, which is catastrophic in
# a wizard: the user has no idea why the program disappeared. Every step handles
# its own errors explicitly instead.
#
# set -o pipefail is also omitted: grep exits 1 on no matches, which under
# pipefail silently kills any pipeline containing a grep that found nothing.
#
# set -u (unbound variables) is kept — an unbound variable is a real bug that
# should be loud, not silently treated as empty.
#
# backup.sh (the actual backup runner) still uses set -euo pipefail because
# there, bailing out on any error is the right behaviour.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/config.sh"
INSTALL_AGENT="$SCRIPT_DIR/install-agent.sh"
BACKUP_SCRIPT="$SCRIPT_DIR/backup.sh"
STATUS_SCRIPT="$SCRIPT_DIR/pabs-status.sh"
export CONFIG INSTALL_AGENT BACKUP_SCRIPT STATUS_SCRIPT

# Wizard state — read by step modules and ui helpers
JUMP_STEP=""
AUTO_YES=false
CHANGED=false   # set to true by _cfg_set/_cfg_set_raw; triggers final reminder
export AUTO_YES CHANGED

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --step) JUMP_STEP="$2"; shift 2 ;;
        --yes)  AUTO_YES=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--step STEP] [--yes]"
            echo "Steps: deps | usb | notifications | agents | offsite | cron | run"
            exit 0
            ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done
export JUMP_STEP

# ---------------------------------------------------------------------------
# Load shared modules
# ---------------------------------------------------------------------------

source "$SCRIPT_DIR/setup/ui.sh"
source "$SCRIPT_DIR/setup/config_editor.sh"

# Load all step modules
for _step_file in "$SCRIPT_DIR"/setup/steps/*.sh; do
    source "$_step_file"
done
unset _step_file

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

_preflight() {
    [[ "$(id -u)" -eq 0 ]]        || _die "setup.sh must be run as root (sudo bash setup.sh)"
    [[ -f "$CONFIG" ]]             || _die "config.sh not found at $CONFIG"
    [[ -f "$INSTALL_AGENT" ]]      || _die "install-agent.sh not found at $INSTALL_AGENT"
    command -v apt-get &>/dev/null || _die "Requires a Debian/Ubuntu system (apt-get not found)"
}

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------

_final_summary() {
    _header "Setup Complete"
    _ok "PABS is configured and ready"
    echo ""
    echo "  ${BOLD}Useful commands:${RESET}"
    echo ""
    printf "  %-45s %s\n" "Run a backup:"          "bash $BACKUP_SCRIPT"
    printf "  %-45s %s\n" "Dry run (no writes):"   "bash $BACKUP_SCRIPT --dry-run"
    printf "  %-45s %s\n" "Health check:"          "bash $STATUS_SCRIPT"
    printf "  %-45s %s\n" "Check cron:"            "crontab -l"
    printf "  %-45s %s\n" "View log:"              "tail -f $(_cfg_get "USB_MOUNT")/proxmox-backup/backup.log"
    printf "  %-45s %s\n" "Add a VM agent:"        "bash $SCRIPT_DIR/install-agent.sh root@<ip>"
    printf "  %-45s %s\n" "Re-run wizard:"         "bash $SCRIPT_DIR/setup.sh"
    printf "  %-45s %s\n" "Jump to a step:"        "bash $SCRIPT_DIR/setup.sh --step offsite"
    echo ""
    echo "  ${BOLD}Documentation:${RESET}"
    printf "  %-45s %s\n" "All options:"           "$SCRIPT_DIR/docs/configuration.md"
    printf "  %-45s %s\n" "VM agents:"             "$SCRIPT_DIR/docs/vm-agents.md"
    printf "  %-45s %s\n" "Offsite sync:"          "$SCRIPT_DIR/docs/offsite.md"
    printf "  %-45s %s\n" "Restore procedures:"    "$SCRIPT_DIR/docs/restore.md"
    echo ""
    if $CHANGED; then
        _info "config.sh was updated during this session."
        _dim  "Review it at: $CONFIG"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

_preflight

[[ -z "$JUMP_STEP" ]] && _step_welcome

_step_deps
_step_usb
_step_notifications
_step_agents
_step_offsite
_step_cron
_step_run

_final_summary
