#!/bin/bash
# =============================================================================
# setup/ui.sh — Terminal output and interactive input helpers
#
# Sourced by setup.sh before any step modules. Defines all colour variables
# and every _ask / _header / _ok / _warn / ... function used across steps.
# Nothing in here reads or writes files — pure UI primitives only.
# =============================================================================

# ---------------------------------------------------------------------------
# Colour detection — disabled automatically in pipes / CI / dumb terminals
# ---------------------------------------------------------------------------

if [[ -t 1 ]] && command -v tput &>/dev/null && tput colors &>/dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    CYAN=$(tput setaf 6)
    BOLD=$(tput bold)
    DIM=$(tput dim)
    RESET=$(tput sgr0)
else
    RED="" GREEN="" YELLOW="" CYAN="" BOLD="" DIM="" RESET=""
fi

export RED GREEN YELLOW CYAN BOLD DIM RESET

# ---------------------------------------------------------------------------
# Structural output
# ---------------------------------------------------------------------------

_header() {
    echo ""
    echo "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"
    echo "${BOLD}${CYAN}  $*${RESET}"
    echo "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"
    echo ""
}

_step() {
    echo ""
    echo "${BOLD}▸ $*${RESET}"
}

# ---------------------------------------------------------------------------
# Status line helpers
# ---------------------------------------------------------------------------

_ok()   { echo "  ${GREEN}✓${RESET}  $*"; }
_warn() { echo "  ${YELLOW}⚠${RESET}  $*"; }
_info() { echo "  ${CYAN}ℹ${RESET}  $*"; }
_err()  { echo "  ${RED}✗${RESET}  $*"; }
_dim()  { echo "  ${DIM}$*${RESET}"; }

_die() {
    _err "$*"
    exit 1
}

# ---------------------------------------------------------------------------
# Interactive input
# ---------------------------------------------------------------------------

# _ask PROMPT [DEFAULT]
# Prompts the user and returns the typed value, or DEFAULT if empty.
# In --yes mode, returns DEFAULT immediately (non-interactive).
_ask() {
    local prompt="$1"
    local default="${2:-}"
    local input

    if [[ -n "$default" ]]; then
        printf "  %s [%s]: " "$prompt" "${DIM}${default}${RESET}"
    else
        printf "  %s: " "$prompt"
    fi

    if ${AUTO_YES:-false} && [[ -n "$default" ]]; then
        echo "$default"
        return
    fi

    read -r input
    echo "${input:-$default}"
}

# _ask_yn PROMPT [DEFAULT: y|n]
# Returns 0 for yes, 1 for no.
# Default is 'y' when not specified.
_ask_yn() {
    local prompt="$1"
    local default="${2:-y}"
    local yn

    if ${AUTO_YES:-false}; then
        [[ "$default" == "y" ]] && return 0 || return 1
    fi

    while true; do
        if [[ "$default" == "y" ]]; then
            printf "  %s [Y/n]: " "$prompt"
        else
            printf "  %s [y/N]: " "$prompt"
        fi
        read -r yn
        yn="${yn:-$default}"
        case "${yn,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     _warn "Please answer y or n" ;;
        esac
    done
}

# _ask_secret PROMPT
# Reads without echo. Never auto-fills in --yes mode (secrets must be explicit).
_ask_secret() {
    local prompt="$1"
    local input
    printf "  %s: " "$prompt"
    read -rs input
    echo ""
    echo "$input"
}

# _pause [MESSAGE]
# Waits for Enter. Skipped silently in --yes mode.
_pause() {
    ${AUTO_YES:-false} && return
    printf "  ${DIM}%s — press Enter to continue...${RESET}" "${1:-}"
    read -r
}
