# PABS VM Agent — Integration Guide

This tells you exactly where to add each piece to your existing PABS files.
No existing code needs to change — this is purely additive.

---

## File layout after integration

```
pabs/
├── backup.sh              ← edit: add one line
├── config.sh              ← edit: add VM_AGENTS block
├── lib/
│   ├── sections.sh        ← edit: add section_vm_agents() at the bottom
│   └── ...                (unchanged)
└── vm-agent/              ← new directory (copy as-is)
    ├── agent.sh
    └── types/
        ├── docker.sh
        ├── haos.sh
        └── generic.sh

install-agent.sh           ← run from Proxmox host to set up each VM
```

---

## Step 1 — Copy vm-agent/ into your pabs directory

```bash
cp -r vm-agent/ /opt/pabs/vm-agent/
chmod +x /opt/pabs/vm-agent/agent.sh
chmod +x /opt/pabs/install-agent.sh
```

---

## Step 2 — Add the section function to lib/sections.sh

Open `lib/sections.sh` and paste `section_vm_agents()` from
`pabs-integration.sh` at the **very bottom** of the file, after
`section_minecraft_archives()`.

---

## Step 3 — Call the new section from backup.sh

Open `backup.sh` and find the block that calls all section_* functions.
It will look something like:

```bash
section_proxmox_configs
section_vm_ct_definitions
section_cron_jobs
section_firewall
section_ssh_keys
section_system_state
section_custom_scripts
section_minecraft_archives
```

Add one line at the end:

```bash
section_vm_agents
```

Also update the section counter comment if you have one (8/8 → 9/9).

---

## Step 4 — Add the config block to config.sh

Open `config.sh` and paste the `VM / LXC AGENT BACKUPS` block from
`pabs-integration.sh` after the `MINECRAFT VM` section.

---

## Step 5 — Set up each VM with the agent

Run this from your Proxmox host for each VM or LXC you want to back up:

```bash
# Basic usage
/opt/pabs/install-agent.sh root@192.168.1.10

# With a specific SSH key
/opt/pabs/install-agent.sh root@192.168.1.10 --key /root/.ssh/id_ed25519_pabs_agent

# Custom install directory
/opt/pabs/install-agent.sh root@192.168.1.10 --dir /usr/local/pabs-agent
```

`install-agent.sh` will:
- Copy `vm-agent/` to the target
- Run `agent.sh --install` (creates `/etc/pabs-agent/config`)
- Print the `VM_AGENTS` line to add to `config.sh`

---

## Step 6 — Edit /etc/pabs-agent/config on each VM

After install, SSH into each VM and review its config:

```bash
nano /etc/pabs-agent/config
```

The defaults work for most setups, but you may want to set:

**Docker VM (no manager):**
```bash
DOCKER_COMPOSE_DIR="/opt"        # if all your apps are under /opt
```

**Docker VM (Dockge):**
```bash
DOCKER_MANAGER="dockge"          # or leave as "auto" — it detects it
DOCKGE_STACKS_DIR="/opt/stacks"  # default, only change if different
```

**Docker VM (Portainer with API export):**
```bash
DOCKER_MANAGER="portainer"
PORTAINER_URL="http://localhost:9000"
PORTAINER_TOKEN="ptr_xxxxxxxxxxxx"
```

**HAOS:**
```bash
HAOS_BACKUP_TYPE="full"          # default — covers everything
HAOS_KEEP_ON_HOST=1              # keep 1 pabs-* snapshot on the HA host
```

**Generic LXC (Pi-hole example):**
```bash
# /etc is already backed up automatically.
# Pi-hole's data is in /etc/pihole — already covered.
# Only needed if you have data outside /etc:
# EXTRA_PATHS="/opt/pihole-extra"
```

---

## Step 7 — Add VMs to config.sh

Open `/opt/pabs/config.sh` and fill in `VM_AGENTS`:

```bash
VM_AGENTS=(
    "docker-vm    192.168.1.10   root    /opt/pabs-agent/agent.sh"
    "haos         192.168.1.20   root    /opt/pabs-agent/agent.sh"
    "pihole-lxc   192.168.1.30   root    /opt/pabs-agent/agent.sh"
)
```

Optionally set a shared SSH key (recommended):

```bash
VM_SSH_KEY="/root/.ssh/id_ed25519_pabs_agent"
```

---

## Step 8 — Test

```bash
# Test a single VM agent manually
ssh root@192.168.1.10 /opt/pabs-agent/agent.sh --bundle-output /tmp/test-bundle.tar.zst
ls -lh /tmp/test-bundle.tar.zst   # check size looks right

# Run a full PABS backup
/opt/pabs/backup.sh

# Check the result
ls /mnt/backup-usb/proxmox-backup/
# You should see vm-agents/ alongside the host config files
```

---

## What ends up on the USB

```
proxmox-backup/
└── 2025-06-01_03-00/
    ├── etc-pve.tar
    ├── vm-ct-definitions/
    ├── ...                          ← existing host backups
    ├── vm-agents/
    │   ├── docker-vm/
    │   │   └── pabs-bundle-docker-vm-2025-06-01_03-00.tar.zst
    │   ├── haos/
    │   │   └── pabs-bundle-haos-2025-06-01_03-00.tar.zst
    │   └── pihole-lxc/
    │       └── pabs-bundle-pihole-lxc-2025-06-01_03-00.tar.zst
    ├── proxmox-restore.sh
    └── MANIFEST.sha256
```

Each `.tar.zst` bundle is self-contained and includes a `restore-notes.txt`
explaining exactly how to restore that specific VM type.

To inspect a bundle:
```bash
# List contents
zstd -d pabs-bundle-docker-vm-*.tar.zst --stdout | tar -t

# Extract restore notes only
zstd -d pabs-bundle-docker-vm-*.tar.zst --stdout | tar -x --to-stdout restore-notes.txt

# Extract everything
mkdir restore && zstd -d pabs-bundle-docker-vm-*.tar.zst --stdout | tar -x -C restore/
```

---

## SSH key setup (recommended)

Generate a dedicated key on the Proxmox host so you're not depending on root's
default key for these connections:

```bash
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519_pabs_agent -N ""

# Copy to each VM
for vm_ip in 192.168.1.10 192.168.1.20 192.168.1.30; do
    ssh-copy-id -i /root/.ssh/id_ed25519_pabs_agent.pub root@$vm_ip
done

# Add to config.sh
# VM_SSH_KEY="/root/.ssh/id_ed25519_pabs_agent"
```

---

## HAOS notes

The SSH community add-on gives you a shell inside a container, not on the
HAOS host itself. The agent runs there and calls `ha backup new` which goes
through the Supervisor — this is the correct, officially supported way to
create HAOS backups programmatically.

The resulting `.tar` file is a native HAOS snapshot. Restore it via:
- HA web UI: Settings → Backups → Upload backup
- CLI: `ha backup restore <slug>`

The snapshot can be 500MB+ for a full backup with many add-ons. On a slow
USB stick this will take longer to write. The HAOS handler already handles this
gracefully — it streams the file into the bundle and lets PABS's normal
staging-then-write pipeline deal with USB transfer.

If the HAOS snapshot is too large and you want to keep USB usage down, set:
```bash
VM_AGENT_KEEP_BUNDLES=1    # in config.sh — keeps only the latest snapshot per VM
```
