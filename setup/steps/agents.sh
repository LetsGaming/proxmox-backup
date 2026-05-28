#!/bin/bash
# setup/steps/agents.sh — Step 4: VM/LXC agent deployment
#
# Handles SSH key setup, per-VM type configuration questions, and
# invokes install-agent.sh with the appropriate --set flags.
# Each agent type's questions are isolated in a dedicated function.

# ---------------------------------------------------------------------------
# Type-specific configuration questionnaires
# Each function receives a nameref to an array and appends --set flags.
# ---------------------------------------------------------------------------

_agent_type_docker() {
    local -n _flags=$1
    _flags+=(--set "PABS_TYPE=docker")
    echo ""
    _info "Docker manager: auto | none | dockge | portainer"
    local mgr
    mgr=$(_ask "Docker manager (empty = auto-detect)" "")
    [[ -n "$mgr" ]] && _flags+=(--set "DOCKER_MANAGER=$mgr")

    if [[ "${mgr,,}" == "dockge" ]]; then
        local dir
        dir=$(_ask "Dockge stacks directory" "/opt/stacks")
        [[ "$dir" != "/opt/stacks" ]] && _flags+=(--set "DOCKGE_STACKS_DIR=$dir")
    fi

    if [[ "${mgr,,}" == "portainer" ]]; then
        local url token
        url=$(_ask "Portainer URL" "http://localhost:9000")
        [[ "$url" != "http://localhost:9000" ]] && _flags+=(--set "PORTAINER_URL=$url")
        token=$(_ask "Portainer API token (ptr_...)")
        [[ -n "$token" ]] && _flags+=(--set "PORTAINER_TOKEN=$token")
    fi
}

_agent_type_haos() {
    local -n _flags=$1
    _flags+=(--set "PABS_TYPE=haos")
    echo ""
    local btype
    btype=$(_ask "Backup type (full/partial)" "full")
    [[ "$btype" != "full" ]] && _flags+=(--set "HAOS_BACKUP_TYPE=$btype")
    if _ask_yn "Encrypt the HA snapshot?" "n"; then
        local pass
        pass=$(_ask_secret "HA snapshot password")
        [[ -n "$pass" ]] && _flags+=(--set "HAOS_BACKUP_PASSWORD=$pass")
    fi
    local keep
    keep=$(_ask "Snapshots to keep on HA host after pull" "1")
    [[ "$keep" != "1" ]] && _flags+=(--set "HAOS_KEEP_ON_HOST=$keep")
}

_agent_type_minecraft() {
    local -n _flags=$1
    _flags+=(--set "PABS_TYPE=minecraft")
    echo ""
    _info "Defaults match an unmodified minecraft-server-setup install."
    _info "Only change these if you customised the username or paths in variables.json."

    local sys_user
    sys_user=$(_ask "System username running Minecraft" "minecraft")
    local base_default="/home/${sys_user}/minecraft-server/backups"
    local server_default="/home/${sys_user}/minecraft-server"

    local base server weekly daily
    base=$(_ask "MINECRAFT_BASE (backup archives dir)" "$base_default")
    [[ "$base" != "$base_default" ]] && _flags+=(--set "MINECRAFT_BASE=$base")

    server=$(_ask "MINECRAFT_SERVER_BASE (server root)" "$server_default")
    [[ "$server" != "$server_default" ]] && _flags+=(--set "MINECRAFT_SERVER_BASE=$server")

    weekly=$(_ask "Weekly archives to keep per instance" "4")
    [[ "$weekly" != "4" ]] && _flags+=(--set "MC_KEEP_WEEKLY=$weekly")

    daily=$(_ask "Daily archives to keep (0 = skip)" "0")
    [[ "$daily" != "0" ]] && _flags+=(--set "MC_KEEP_DAILY=$daily")
}

_agent_type_generic() {
    local -n _flags=$1
    _flags+=(--set "PABS_TYPE=generic")
    echo ""
    local extra
    extra=$(_ask "Extra paths to include (space-separated, empty to skip)" "")
    [[ -n "$extra" ]] && _flags+=(--set "EXTRA_PATHS=$extra")
}

# ---------------------------------------------------------------------------
# SSH key setup — runs once before the per-VM loop
# ---------------------------------------------------------------------------

_agents_setup_ssh_key() {
    _step "SSH key for agent connections"
    local current_key key_path="/root/.ssh/id_ed25519_pabs_agent"
    current_key=$(_cfg_get "VM_SSH_KEY")

    if [[ -n "$current_key" ]]; then
        _ok "Shared agent SSH key already set: $current_key"
        return
    fi

    if [[ -f "$key_path" ]]; then
        _ok "Dedicated PABS key already exists at $key_path"
        if _ask_yn "Use $key_path as the shared agent key?"; then
            _cfg_set "VM_SSH_KEY" "$key_path"
            _ok "VM_SSH_KEY set to $key_path"
        fi
        return
    fi

    _info "A dedicated SSH key is recommended so rotating root's key"
    _info "doesn't silently break agent backups."
    if _ask_yn "Generate a dedicated PABS agent key at $key_path?"; then
        if ssh-keygen -t ed25519 -f "$key_path" -N "" -C "pabs-agent@$(hostname)"; then
            _ok "Key generated: $key_path"
            _cfg_set "VM_SSH_KEY" "$key_path"
            _ok "VM_SSH_KEY set to $key_path"
        else
            _warn "Key generation failed — continuing without dedicated key"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Deploy one VM — called inside the add-VM loop
# ---------------------------------------------------------------------------

_agents_add_one() {
    _step "Add a VM or LXC"

    local vm_host vm_user vm_label default_label
    vm_host=$(_ask "VM IP or hostname")
    [[ -z "$vm_host" ]] && { _warn "No host entered — skipping"; return 1; }

    vm_user=$(_ask "SSH user on the VM" "root")
    default_label="${vm_host//./-}"
    vm_label=$(_ask "Label (folder name in backup)" "$default_label")

    _step "VM type"
    _info "The agent auto-detects the type; only override if your setup is non-standard."
    echo ""
    echo "  ${BOLD}Types:${RESET}"
    echo "  ${GREEN}1)${RESET} Docker            — compose files, .env, volumes"
    echo "  ${GREEN}2)${RESET} Home Assistant OS — native HA snapshot"
    echo "  ${GREEN}3)${RESET} Minecraft         — weekly archives (minecraft-server-setup)"
    echo "  ${GREEN}4)${RESET} Generic           — /etc, cron, scripts, packages"
    echo "  ${GREEN}5)${RESET} Auto-detect       — let the agent figure it out"
    echo ""

    local type_choice
    type_choice=$(_ask "VM type" "5")

    local -a set_flags=()
    case "$type_choice" in
        1) _agent_type_docker  set_flags ;;
        2) _agent_type_haos    set_flags ;;
        3) _agent_type_minecraft set_flags ;;
        4) _agent_type_generic set_flags ;;
        *) _info "Using auto-detection" ;;
    esac

    local -a install_cmd=("bash" "$INSTALL_AGENT" "${vm_user}@${vm_host}")
    local agent_key
    agent_key=$(_cfg_get "VM_SSH_KEY")
    [[ -n "$agent_key" && -f "$agent_key" ]] && install_cmd+=(--key "$agent_key")
    install_cmd+=("${set_flags[@]}")

    echo ""
    _step "Deploying agent to ${vm_user}@${vm_host}..."
    _dim "Running: ${install_cmd[*]}"
    echo ""

    if "${install_cmd[@]}"; then
        _ok "Agent deployed to ${vm_host}"
        _cfg_append_vm_agent "${vm_label}  ${vm_host}  ${vm_user}  /opt/pabs-agent/agent.sh"
        _ok "Added to VM_AGENTS: $vm_label  $vm_host  $vm_user"
    else
        _err "Agent deployment failed for ${vm_host}"
        _info "Retry later with:"
        _dim "  bash install-agent.sh ${vm_user}@${vm_host} ${set_flags[*]}"
    fi
}

# ---------------------------------------------------------------------------
# Step entry point
# ---------------------------------------------------------------------------

_step_agents() {
    [[ -n "$JUMP_STEP" && "$JUMP_STEP" != "agents" ]] && return
    _header "Step 4 of 7 — VM / LXC Agent Backups"

    _info "PABS backs up VMs and LXCs with a lightweight agent — no disk images."
    _info "Types: Docker, Home Assistant OS, Minecraft, Generic"
    echo ""

    local agent_count
    agent_count=$(grep -c '".*\.sh"' "$CONFIG" 2>/dev/null || echo 0)
    if [[ "$agent_count" -gt 0 ]]; then
        _ok "$agent_count agent(s) already configured:"
        grep '".*\.sh"' "$CONFIG" | sed 's/^/    /'
        echo ""
    fi

    if ! _ask_yn "Add a VM/LXC agent now?" "n"; then
        _info "Skipping VM agent setup"
        _dim "Add agents later: bash setup.sh --step agents"
        _dim "Or directly:      bash install-agent.sh root@<vm-ip>"
        return
    fi

    _agents_setup_ssh_key

    while true; do
        echo ""
        _agents_add_one || true   # failure inside one VM never aborts the loop
        echo ""
        _ask_yn "Add another VM/LXC?" "n" || break
    done

    # Parallelism — only offer if there are multiple agents
    local final_count
    final_count=$(grep -c '".*\.sh"' "$CONFIG" 2>/dev/null || echo 0)
    if [[ "$final_count" -gt 1 ]]; then
        _step "Agent parallelism"
        local current_parallel parallel
        current_parallel=$(_cfg_get "VM_AGENT_MAX_PARALLEL")
        _info "Run multiple agents simultaneously to cut total backup time."
        _info "Recommended: 1 per 500 MB of expected bundle size."
        parallel=$(_ask "Max parallel agents" "${current_parallel:-1}")
        if [[ "$parallel" != "${current_parallel:-1}" ]]; then
            _cfg_set_raw "VM_AGENT_MAX_PARALLEL" "$parallel"
            _ok "VM_AGENT_MAX_PARALLEL set to $parallel"
        fi
    fi

    echo ""
    _ok "VM agent configuration complete"
}
