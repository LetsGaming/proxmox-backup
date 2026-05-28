#!/bin/bash
# setup/steps/notifications.sh — Step 3: Discord webhook and email alerts

_step_notifications() {
    [[ -n "$JUMP_STEP" && "$JUMP_STEP" != "notifications" ]] && return
    _header "Step 3 of 7 — Notifications"

    _info "PABS sends alerts on backup success, failure, and low-space events."

    # --- Discord ---
    _step "Discord webhook"
    local current_webhook
    current_webhook=$(_cfg_get "DISCORD_WEBHOOK")

    if [[ -n "$current_webhook" ]]; then
        _ok "Discord webhook already configured"
        _ask_yn "Update it?" "n" || { echo ""; _ok "Keeping existing webhook"; }
        _ask_yn "Update it?" "n" && current_webhook=""
    fi

    if [[ -z "$current_webhook" ]]; then
        _info "Create a webhook: Server Settings → Integrations → Webhooks"
        if _ask_yn "Set up Discord notifications?" "n"; then
            local webhook
            webhook=$(_ask "Discord webhook URL")
            if [[ -n "$webhook" ]]; then
                _info "Sending test message..."
                local http_code
                http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                    -H "Content-Type: application/json" \
                    -d '{"content":"✅ PABS setup test — Discord notifications working"}' \
                    "$webhook" 2>/dev/null || echo "000")
                if [[ "$http_code" == "204" ]]; then
                    _ok "Test message sent (check your Discord channel)"
                    _cfg_set "DISCORD_WEBHOOK" "$webhook"
                    _ok "DISCORD_WEBHOOK set"
                else
                    _warn "Test failed (HTTP $http_code) — check the webhook URL"
                    _ask_yn "Save it anyway?" "n" && _cfg_set "DISCORD_WEBHOOK" "$webhook"
                fi
            fi
        else
            _info "Skipping Discord notifications"
        fi
    fi

    # --- Email ---
    _step "Email notifications (failure alerts only)"
    local current_email
    current_email=$(_cfg_get "NOTIFY_EMAIL")

    if [[ -n "$current_email" ]]; then
        _ok "Email already configured: $current_email"
        if _ask_yn "Update it?" "n"; then
            current_email=""
        fi
    fi

    if [[ -z "$current_email" ]]; then
        if command -v mail &>/dev/null || command -v sendmail &>/dev/null; then
            if _ask_yn "Set up email failure alerts?" "n"; then
                local email
                email=$(_ask "Email address for failure alerts")
                if [[ -n "$email" ]]; then
                    _cfg_set "NOTIFY_EMAIL" "$email"
                    _ok "NOTIFY_EMAIL set to $email"
                    if _ask_yn "Send a test email now?"; then
                        echo "PABS setup test — email notifications working" \
                            | mail -s "PABS test alert" "$email" 2>/dev/null \
                            && _ok "Test email sent" \
                            || _warn "mail command failed — check MTA configuration"
                    fi
                fi
            fi
        else
            _info "mailutils not installed — skipping email setup"
            _dim "(Install with: apt install mailutils)"
        fi
    fi

    echo ""
    _ok "Notification configuration complete"
}
