# PABS documentation

**Proxmox Automated Backup System** — backs up a Proxmox node to a USB stick with optional offsite sync.

→ [Back to project root](../README.md)

---

## Getting started

| Step | Document |
| :--- | :------- |
| 1. Install and configure | [Setup wizard](setup-wizard.md) |
| 2. Understand every config option | [Configuration reference](configuration.md) |
| 3. Add VM / LXC agents | [VM agent backups](vm-agents.md) |
| 4. Set up cloud backup | [Offsite sync](offsite.md) |

---

## Documents

### [Setup wizard](setup-wizard.md)

Interactive installer and configuration tool. Covers all 7 steps, re-run scenarios, non-interactive mode, and the file structure of the wizard modules.

Sections: [Usage](setup-wizard.md#usage) · [What each step does](setup-wizard.md#what-each-step-does) · [Re-running the wizard](setup-wizard.md#re-running-the-wizard) · [Non-interactive mode](setup-wizard.md#non-interactive-mode-yes) · [File structure](setup-wizard.md#file-structure)

---

### [Configuration reference](configuration.md)

Every `config.sh` variable with type, default, and examples. The only reference you need to fine-tune the backup beyond what the wizard covers.

Sections: [USB target](configuration.md#usb-target) · [Local staging](configuration.md#local-staging) · [VM / LXC agent backups](configuration.md#vm-lxc-agent-backups) · [Notifications](configuration.md#notifications) · [Offsite sync](configuration.md#offsite-sync) · [Secret redaction](configuration.md#secret-redaction) · [Internal variables](configuration.md#internal-variables)

---

### [VM agent backups](vm-agents.md)

Lightweight per-VM agents that collect application state — compose files, HA snapshots, Minecraft archives, `/etc/` — without touching disk images.

Sections: [Supported types](vm-agents.md#supported-types) · [Installation](vm-agents.md#installation) · [Configuring agents with `--set`](vm-agents.md#configuring-agents-with-set) · [Type-specific configuration](vm-agents.md#type-specific-configuration) · [SSH key management](vm-agents.md#ssh-key-management) · [Bundle structure](vm-agents.md#bundle-structure)

---

### [Restore procedures](restore.md)

All restore scenarios: partial config restore on a live system, full disaster recovery from USB, full disaster recovery from offsite, and per-VM bundle restore.

Sections: [Before you start](restore.md#before-you-start) · [Partial restore](restore.md#scenario-1-partial-restore-proxmox-still-running) · [Full DR from USB](restore.md#scenario-2-full-disaster-recovery-from-usb) · [Full DR from offsite](restore.md#scenario-3-full-disaster-recovery-from-offsite) · [VM bundle restore](restore.md#vm-bundle-restore) · [Section reference](restore.md#section-reference)

---

### [Offsite sync](offsite.md)

rclone-based cloud backup with transparent AES-256 encryption. Covers remote setup, retention limits, free-tier sizing, and OAuth token refresh.

Sections: [Setting up a remote](offsite.md#setting-up-a-remote) · [Retention](offsite.md#retention) · [Encryption](offsite.md#encryption) · [OAuth token refresh](offsite.md#oauth-token-refresh-google-drive-onedrive) · [What is and is not synced](offsite.md#what-is-and-is-not-synced)

---

### [USB drive health checks](usb-health.md)

Four-layer passive health assessment: kernel I/O errors, read-only remount detection, ext4 superblock error counter, and SMART overall health.

Sections: [Filesystem requirements](usb-health.md#filesystem-requirements) · [What is checked](usb-health.md#what-is-checked) · [Final verdict](usb-health.md#final-verdict) · [Example output](usb-health.md#example-output) · [Responding to health warnings](usb-health.md#responding-to-health-warnings)

---

### [Architecture](architecture.md)

PABS internals: the full backup run sequence, integrity guarantees (manifest verification, atomic commit, UUID targeting), VM agent execution flow, secret redaction, offsite encryption, and rotation logic.

Sections: [Data flow](architecture.md#data-flow) · [Backup run sequence](architecture.md#backup-run-sequence) · [Integrity guarantees](architecture.md#integrity-guarantees) · [VM agent execution flow](architecture.md#vm-agent-execution-flow) · [Secret redaction](architecture.md#secret-redaction) · [Offsite encryption](architecture.md#offsite-encryption) · [Rotation logic](architecture.md#rotation-logic) · [Staging size estimates](architecture.md#staging-size-estimates)

---

### [Testing](testing.md)

BATS test suite covering rotation logic, manifest generation, and log counter safety under `set -e`. Includes setup instructions, test isolation approach, and a guide for adding new tests.

Sections: [Prerequisites](testing.md#prerequisites) · [Running the tests](testing.md#running-the-tests) · [What is tested](testing.md#what-is-tested) · [What is not tested](testing.md#what-is-not-tested) · [Adding a test](testing.md#adding-a-test)
