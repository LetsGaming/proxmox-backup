# PABS Integration Guide

> **This file is a quick-reference summary.** The full documentation has moved
> to the `docs/` folder:
>
> - **[docs/vm-agents.md](docs/vm-agents.md)** — complete agent setup guide, `--set` flags, per-type config reference
> - **[docs/configuration.md](docs/configuration.md)** — every `config.sh` variable documented
> - **[docs/offsite.md](docs/offsite.md)** — cloud sync, encryption, free-tier sizing
> - **[docs/restore.md](docs/restore.md)** — restore procedures and DR walkthrough
> - **[docs/architecture.md](docs/architecture.md)** — data flow and design decisions

---

## Adding a VM or LXC — quick reference

### 1. Deploy the agent

```bash
# From the Proxmox host — run once per VM/LXC
./install-agent.sh root@<vm-ip>

# With a dedicated SSH key
./install-agent.sh root@<vm-ip> --key /root/.ssh/id_ed25519_pabs_agent

# Pass configuration values — no SSH into the VM needed afterwards
./install-agent.sh alice@<mc-vm-ip> \
    --set MINECRAFT_BASE=/home/alice/minecraft-server/backups \
    --set MINECRAFT_SERVER_BASE=/home/alice/minecraft-server

./install-agent.sh root@<docker-vm-ip> \
    --set DOCKER_MANAGER=portainer \
    --set PORTAINER_TOKEN=ptr_abc123
```

`install-agent.sh` copies the agent files, runs first-time setup on the VM,
applies any `--set` values into `/etc/pabs-agent/config`, registers the SSH
host key, and prints the `VM_AGENTS` line to add to `config.sh`.

### 2. Add to config.sh

```bash
VM_AGENTS=(
    "docker-vm    192.168.1.10   root     /opt/pabs-agent/agent.sh"
    "haos         192.168.1.20   root     /opt/pabs-agent/agent.sh"
    "pihole-lxc   192.168.1.30   root     /opt/pabs-agent/agent.sh"
    "mc-server    192.168.1.40   alice    /opt/pabs-agent/agent.sh"
)
```

### 3. Test

```bash
sudo /opt/pabs/backup.sh --dry-run
sudo /opt/pabs/backup.sh
```

---

## Type-specific `--set` flags — quick reference

| Type | Key variables |
|---|---|
| `docker` | `DOCKER_MANAGER` (`auto`/`none`/`dockge`/`portainer`), `DOCKGE_STACKS_DIR`, `PORTAINER_TOKEN`, `PORTAINER_URL`, `DOCKER_INCLUDE_VOLUMES` |
| `haos` | `HAOS_BACKUP_TYPE` (`full`/`partial`), `HAOS_BACKUP_PASSWORD`, `HAOS_KEEP_ON_HOST`, `HAOS_WAIT_SECONDS` |
| `minecraft` | `MINECRAFT_BASE`, `MINECRAFT_SERVER_BASE`, `MC_KEEP_WEEKLY`, `MC_KEEP_DAILY`, `MC_MIN_AGE_MINUTES` |
| `generic` | `EXTRA_PATHS`, `GENERIC_EXCLUDE_PATHS`, `GENERIC_INCLUDE_ETC`, `GENERIC_INCLUDE_PACKAGES` |
| all types | `PABS_TYPE` (override auto-detection), `AGENT_LABEL`, `EXTRA_PATHS` |

See [docs/vm-agents.md](docs/vm-agents.md) for the full per-type reference.

---

## SSH host key setup

`install-agent.sh` registers each VM's host key in `/root/.ssh/pabs_known_hosts`
automatically, enabling `StrictHostKeyChecking=yes` in cron runs.

If a VM's host key changes (e.g. after OS reinstall), re-run `install-agent.sh`
to update it:

```bash
./install-agent.sh root@<vm-ip>    # updates agent files + host key
```
