#!/bin/bash
# setup/steps/cron.sh — Step 6: cron schedule

_step_cron() {
    [[ -n "$JUMP_STEP" && "$JUMP_STEP" != "cron" ]] && return
    _header "Step 6 of 7 — Cron Schedule"

    local existing_cron
    existing_cron=$(crontab -l 2>/dev/null | grep -F "$BACKUP_SCRIPT" || true)

    if [[ -n "$existing_cron" ]]; then
        _ok "PABS is already scheduled:"
        _dim "  $existing_cron"
        _ask_yn "Update the schedule?" "n" || return
    fi

    _step "Choose a backup schedule"
    echo ""
    echo "  ${BOLD}Presets:${RESET}"
    echo "  ${GREEN}1)${RESET} Weekly  — Sunday at 03:00    (recommended)"
    echo "  ${GREEN}2)${RESET} Weekly  — Saturday at 02:00"
    echo "  ${GREEN}3)${RESET} Daily   — Every day at 03:00"
    echo "  ${GREEN}4)${RESET} Monthly — 1st of month at 03:00"
    echo "  ${GREEN}5)${RESET} Custom cron expression"
    echo ""

    local schedule_choice cron_expr
    schedule_choice=$(_ask "Schedule" "1")

    case "$schedule_choice" in
        1) cron_expr="0 3 * * 0" ;;
        2) cron_expr="0 2 * * 6" ;;
        3) cron_expr="0 3 * * *" ;;
        4) cron_expr="0 3 1 * *" ;;
        *)
            _info "Format: minute hour day-of-month month day-of-week"
            _dim "(e.g. '0 3 * * 0' = Sunday at 03:00)"
            cron_expr=$(_ask "Cron expression" "0 3 * * 0")
            ;;
    esac

    local cron_line="${cron_expr}  bash ${BACKUP_SCRIPT} >> /var/log/pabs-cron.log 2>&1"
    _info "Cron line: $cron_line"

    if _ask_yn "Add this to root's crontab?"; then
        (crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT" || true; echo "$cron_line") \
            | crontab -
        if crontab -l 2>/dev/null | grep -qF "$BACKUP_SCRIPT"; then
            _ok "Cron job added and verified"
        else
            _warn "Could not verify crontab entry — check with: crontab -l"
        fi
    else
        _info "Skipping cron setup"
        _dim "Add manually:  crontab -e"
        _dim "Cron line:     $cron_line"
    fi

    echo ""
    _ok "Cron schedule configured"
}
