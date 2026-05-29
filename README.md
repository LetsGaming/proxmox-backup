```
  ██████╗  █████╗ ██████╗ ███████╗
  ██╔══██╗██╔══██╗██╔══██╗██╔════╝
  ██████╔╝███████║██████╔╝███████╗
  ██╔═══╝ ██╔══██║██╔══██╗╚════██║
  ██║     ██║  ██║██████╔╝███████║
  ╚═╝     ╚═╝  ╚═╝╚═════╝ ╚══════╝
  Proxmox Automated Backup System
```

# PABS — Proxmox Automated Backup System

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Proxmox%20VE-7.x%20–%209.x-e57000.svg)](https://www.proxmox.com/)
[![Tests](https://img.shields.io/badge/Tests-BATS-brightgreen.svg)](tests/pabs.bats)
[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25.svg)](backup.sh)

Backs up a Proxmox node — configs, VM/CT definitions, SSH keys, firewall rules, package state, and per-VM application bundles — to a USB stick. Optionally syncs offsite with AES-256 encryption.

**Power-loss safe. Atomic commit. One config file. Self-contained restore script in every backup.**

---

## Install

**Requires:** Proxmox VE 7.x – 9.x · root access · a partitioned USB stick · internet access during setup only

```bash
git clone https://github.com/your-org/pabs /opt/pabs
chmod +x /opt/pabs/*.sh
sudo bash /opt/pabs/setup.sh
```

The wizard handles everything: dependencies, USB config, VM agents, offsite sync, cron schedule. Safe to re-run.

After setup, restrict the config file:

```bash
chmod 600 /opt/pabs/config.sh
```

**Updating PABS** (preserves your `config.sh` automatically):

```bash
sudo bash /opt/pabs/setup.sh --update
```

---

## Restore

```bash
cd /mnt/backup-usb/proxmox-backup/2026-05-25_03-00-00/
./proxmox-restore.sh
```

Every backup is self-contained — `proxmox-restore.sh` and `DISASTER-RECOVERY.md` are written into each backup folder at backup time. No dependency on this repo at restore time. Use `--dry-run` to preview, `--section ssh` to target a single section.

→ [Full restore guide](docs/restore.md)

---

## How it works

All data stages on the host's local SSD first, gets SHA256-verified, then transfers to USB in a single atomic commit. A second verification runs on USB after transfer. A partial write never appears as a complete backup.

| Guarantee | Detail |
| :-------- | :----- |
| Staged write | USB sees one sequential write — no partial-file corruption |
| UUID targeting | Refuses to write to any drive other than `TARGET_UUID` |
| Atomic commit | Written to `<date>.tmp/` then renamed — power loss leaves a `.tmp/`, not a corrupt backup |
| Dual verification | SHA256 manifest checked on SSD before transfer, re-checked on USB after |
| Auto space recovery | Purges oldest backup if USB is full; refuses if it's the last copy |
| Offsite sync | AES-256 via rclone crypt; failure is non-fatal, USB backup is always intact |

---

## What gets backed up

**Proxmox host (always):** `/etc/pve/`, network interfaces, SSH keys, firewall rules, cron jobs, APT sources, ZFS/LVM layout, package selections, `/usr/local/bin/`, `/root/scripts/`.

**Per-VM agent bundles (optional):**

| Type | What's collected |
| :--- | :--------------- |
| `docker` | All `docker-compose.yml` + `.env` files, named volumes (under threshold), daemon config |
| `haos` | Full native HA snapshot via `ha` CLI — one-click restore in HA UI |
| `minecraft` | Weekly `.tar.zst` archives, `server.properties`, mods, plugins |
| `generic` | `/etc/` (full), cron jobs, `/usr/local/bin/`, `/root/scripts/`, package list |

VM disk images are not backed up — agent bundles contain full application state. Rebuild path: fresh OS → `install-agent.sh` → restore bundle.

→ [VM agents guide](docs/vm-agents.md) · [Offsite sync guide](docs/offsite.md)

---

## Health check

```bash
/opt/pabs/pabs-status.sh
```

Reports USB mount state, drive health (kernel I/O errors, filesystem error counters, SMART), latest backup integrity, VM agent reachability, and offsite status. Exit codes: `0` OK · `1` error · `2` warning.

---

## Documentation

| | |
| :-- | :-- |
| [Setup wizard](docs/setup-wizard.md) | Guided install, step reference, re-run scenarios |
| [Configuration](docs/configuration.md) | Every `config.sh` variable with type, default, and examples |
| [Restore](docs/restore.md) | Partial restore, full DR from USB, full DR from offsite |
| [VM agents](docs/vm-agents.md) | Docker, HAOS, Minecraft, generic — `--set` flag reference |
| [Offsite sync](docs/offsite.md) | rclone setup, free-tier sizing, encryption, OAuth refresh |
| [USB health](docs/usb-health.md) | Signal layers, example output, when to act |
| [Architecture](docs/architecture.md) | Data flow, integrity model, module structure |
| [Testing](docs/testing.md) | Running the BATS suite, what's covered |

<details>
<summary>File layout</summary>

```
pabs/
├── backup.sh            Entry point — run directly or schedule with cron
├── config.sh            Your configuration — the only file you edit
├── setup.sh             Interactive setup wizard — start here
├── install-agent.sh     Deploys the VM agent to a guest over SSH (run once per VM)
├── pabs-status.sh       Health check — USB, backup integrity, agents, offsite
├── docs/                Full documentation
├── lib/                 core.sh · offsite.sh · preflight.sh · sections.sh · usb_health.sh
├── helpers/             manifest.sh · output.sh
├── setup/               ui.sh · config_editor.sh · steps/
├── tests/               pabs.bats
└── vm-agent/            agent.sh · types/ (docker · haos · minecraft · generic)
```

</details>
