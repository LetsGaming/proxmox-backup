# PABS Integration Guide

## Adding a VM or LXC to the agent system

PABS backs up VMs and containers by SSHing into each one, running a small
agent script, and pulling the resulting bundle back to the Proxmox host. No
extra software is required on the recovery machine — each bundle is
self-contained with a `restore-notes.txt`.

### Step 1 — Install the agent on the VM

From the Proxmox host, run:

```bash
bash install-agent.sh <ip-or-hostname> <ssh-user>
```

This copies `vm-agent/agent.sh` and the type handlers to
`/opt/pabs-agent/` on the target machine and sets correct permissions.

### Step 2 — Verify the agent

SSH into the VM and do a test run:

```bash
ssh <user>@<vm-ip> sudo /opt/pabs-agent/agent.sh --dry-run
```

You should see the agent detect its type (docker / haos / minecraft / generic)
and print what it would back up. Fix any errors before continuing.

### Step 3 — Add the VM to config.sh on the Proxmox host

Open `config.sh` and add an entry to the `VM_AGENTS` array:

```bash
VM_AGENTS=(
    # Format: "label  ip-or-hostname  ssh-user  agent-path"
    "homeassistant  10.0.0.10  root    /opt/pabs-agent/agent.sh"
    "minecraft-vm   10.0.0.11  mcuser  /opt/pabs-agent/agent.sh"
    "docker-host    10.0.0.12  ubuntu  /opt/pabs-agent/agent.sh"
)
```

The label is used as the directory name under `vm-agents/` in each backup.

### Step 4 — Run PABS and confirm

```bash
sudo bash backup.sh
```

After completion, check that `vm-agents/<label>/<label>.tar.zst` exists on
the USB stick and that `README.txt` lists the `vm-agents/` directory.

---

## Type-specific configuration

Each agent type has config variables you can set in the agent's environment
(via `/etc/pabs-agent/config` on the VM, created by `install-agent.sh`):

| Type      | Key variables                                                             |
|-----------|---------------------------------------------------------------------------|
| docker    | `DOCKER_MANAGER`, `PORTAINER_TOKEN`, `PORTAINER_URL`, `DOCKER_VOLUME_MAX_MB` |
| haos      | `HAOS_WAIT_SECONDS`, `HAOS_KEEP_SNAPSHOTS`                               |
| minecraft | `MC_INSTANCES_DIR`, `MC_KEEP_WEEKLY`, `MC_KEEP_DAILY`, `MC_MIN_AGE_MINUTES` |
| generic   | `GENERIC_PATHS`, `GENERIC_EXCLUDE_PATHS`                                  |

See the comments at the top of each `vm-agent/types/<type>.sh` for full
documentation.

---

## SSH host key setup

On the first connection to each VM, PABS uses `StrictHostKeyChecking=accept-new`
so it can run unattended without pre-populating `known_hosts`. This means the
**first connection provides no MITM protection**.

After initial setup, harden this:

1. Verify each VM's host key fingerprint:
   ```bash
   ssh-keyscan <vm-ip> | ssh-keygen -lf -
   ```
2. Add the verified key to root's `known_hosts` on the Proxmox host:
   ```bash
   ssh-keyscan <vm-ip> >> /root/.ssh/known_hosts
   ```
3. Change `StrictHostKeyChecking=accept-new` to `StrictHostKeyChecking=yes`
   in `VM_AGENT_SSH_OPTS` in `config.sh`.
