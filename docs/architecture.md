# Architecture & Design

This document explains how PABS works internally: the data flow through a
backup run, how integrity is guaranteed, and the reasoning behind key design
decisions.

---

## Data flow

A complete backup run moves data through three locations:

```
1. Proxmox SSD (staging)          2. USB stick               3. Offsite remote
/var/tmp/pabs-stage/               /mnt/backup-usb/            gdrive:proxmox-backup/
└── .tmp-2026-06-01_03-00-00/     └── proxmox-backup/         └── 2026-06-01_03-00-00/
    ├── etc/                           ├── 2026-06-01_03-00-00/    (rclone-synced copy)
    ├── etc-pve.tar                    │   ├── etc/
    ├── vm-ct-definitions/             │   ├── etc-pve.tar
    ├── system-state/                  │   ├── vm-ct-definitions/
    ├── vm-agents/                     │   ├── system-state/
    │   └── my-vm/                     │   ├── vm-agents/
    │       └── bundle.tar.zst         │   ├── MANIFEST.sha256
    ├── config.sh (redacted)           │   ├── proxmox-restore.sh
    ├── backup.sh                      │   ├── README.txt
    └── MANIFEST.sha256                │   └── DISASTER-RECOVERY.md
                                       └── backup.log
```

The staging directory always has a `.tmp-` prefix while in progress. The
USB directory never gets the final name until the rename succeeds.

---

## Backup run sequence

```
backup.sh
│
├── source config.sh
├── source lib/core.sh       (logging, lock, trap, offsite functions)
├── source lib/preflight.sh  (check functions)
├── source lib/sections.sh   (the 8 backup sections)
├── source helpers/manifest.sh
├── source helpers/output.sh
│
├── acquire_lock             ← lock file prevents concurrent runs
├── check_root               ← must run as root
├── check_usb_mounted        ← USB at USB_MOUNT, UUID matches TARGET_UUID
├── mkdir BACKUP_ROOT + STAGE_DIR
│
├── SECTION 1: section_proxmox_configs    /etc/pve tar, storage.cfg, datacenter.cfg
├── SECTION 2: section_network            /etc/network, hosts, hostname, resolv.conf
├── SECTION 3: section_system_state       disk layout, kernel, ZFS, LVM, packages
├── SECTION 4: section_cron               /etc/crontab, /etc/cron.d, user crontabs
├── SECTION 5: section_firewall           nftables, iptables, PVE firewall
├── SECTION 6: section_ssh                /etc/ssh, /root/.ssh
├── SECTION 7: section_custom_scripts     /usr/local/bin, /root/scripts
│                                         config.sh (secrets redacted), backup.sh
├── SECTION 8: section_vm_agents          SSH into each VM, pull bundle
│
├── generate_manifest        ← SHA256 of every staged file → MANIFEST.sha256
├── verify_manifest          ← re-read and verify on SSD (catches staging corruption)
├── generate_restore_script  ← proxmox-restore.sh (self-contained)
├── generate_readme          ← README.txt
├── generate_dr_playbook     ← DISASTER-RECOVERY.md (hostname/version-specific)
│
│   ┌── detach trap ──────────────────────────────────────────────────────────┐
│   │                                                                          │
├── atomic_commit            ← rsync STAGE_DIR → FINAL_DIR.tmp, then rename  │
│   │                                                                          │
│   └── reattach trap ───────────────────────────────────────────────────────┘
│
├── verify_manifest_on_usb   ← re-verify on USB (catches transfer corruption)
├── rotate_old_backups        ← prune USB backups beyond KEEP_BACKUPS
│
├── offsite_sync              ← rclone to remote (if configured)
│   ├── _offsite_effective_remote  ← wrap with crypt if password set
│   ├── rclone sync FINAL_DIR → remote
│   └── _offsite_prune             ← enforce KEEP_MIN/KEEP_MAX/MAX_STORAGE_GB
│
├── release_lock
└── dispatch_alert "SUCCESS"
```

On any error, the `ERR EXIT` trap calls `_on_exit`, which:
- Cleans up `STAGE_DIR` (prevents partial staging dirs accumulating)
- Releases the lock file
- Sends a failure alert

---

## Integrity guarantees

### Pre-commit manifest verification

After all sections complete on the local SSD, `generate_manifest` walks the
staging directory and writes a `MANIFEST.sha256` with the SHA256 of every file.
`verify_manifest` immediately re-reads and verifies all checksums.

This catches:

- Filesystem corruption on the local SSD
- Files modified or truncated during staging (race condition with live system)
- rsync from agent VMs that produced a truncated bundle

If verification fails, the backup aborts before anything is written to USB.

### Atomic commit to USB

Data is written to `<FINAL_DIR>.tmp/` and only renamed to `<FINAL_DIR>/` after
the full rsync completes. This means:

- The USB never contains a directory that looks like a complete backup but isn't
- A power loss mid-transfer leaves a `.tmp/` directory, not a corrupt "complete" backup
- `rotate_old_backups` and `pabs-status.sh` only see complete backups

The lock (trap detach/reattach) ensures the cleanup trap does not delete the
staging dir during the rename window.

### Post-transfer manifest verification

After the USB rename, `verify_manifest_on_usb` re-reads and verifies all
checksums from `MANIFEST.sha256` on the USB. This catches:

- USB write errors (bad sectors, failing flash, write-behind cache issues)
- Filesystem corruption introduced during the rsync
- Silent data corruption (bit rot) on the USB medium

Only after both verifications pass does PABS proceed to offsite sync and
backup rotation.

### UUID targeting

`check_usb_mounted` reads the UUID of whatever is mounted at `USB_MOUNT` and
compares it to `TARGET_UUID`. The backup aborts if they don't match.

This prevents writing to the wrong drive if:
- A second USB stick is connected and automounted at the same path
- The USB stick is not present and something else (e.g. `/tmp` tmpfs) is mounted there
- The mount point was reconfigured to point at a different device

---

## Lock file

`LOCK_FILE` at `$LOCAL_STAGE_BASE/.backup.lock` prevents concurrent runs.

The lock is acquired at startup (fails immediately if already held) and
released on exit via the `ERR EXIT` trap. If a previous run was killed hard
(SIGKILL, power loss mid-run), the lock file may remain. `pabs-status.sh`
warns about a stale lock file. To clear it manually:

```bash
rm /var/tmp/pabs-stage/.backup.lock
```

---

## VM agent architecture

```
Proxmox host (sections.sh: _run_agent)
│
│  SSH connection
│  ssh -i $key $user@$ip "sudo $agent_path $label"
│
VM (agent.sh)
│
├── source /etc/pabs-agent/config    ← written by install-agent.sh
├── detect_type                      ← haos / docker / minecraft / generic
├── source types/<type>.sh           ← handler provides do_backup()
│
├── do_backup()
│   ├── create staging dir on VM: /tmp/pabs-<label>-<date>/
│   ├── collect type-specific files
│   ├── write restore-notes.txt
│   └── tar -I zstd → /tmp/pabs-bundle-<label>-<date>.tar.zst
│
└── print bundle path to stdout
    ↓
Proxmox host (sections.sh: _run_agent continued)
│
├── rsync bundle from VM to local staging
├── cleanup remote bundle
└── continue with next agent
```

The agent runs entirely inside the VM's own `/tmp` — it never writes to
any persistent path on the VM, only reads. The bundle is pulled back by
the Proxmox host over the same SSH connection used to invoke the agent.

### Parallel agent execution

When `VM_AGENT_MAX_PARALLEL > 1`, agents are launched in the background
with `_run_agent &`. A `_wait_one` polling loop enforces the parallelism
cap: it waits until a slot is free before launching the next agent.

Each parallel worker writes to a private temp file; results are assembled
in order after all workers complete. The shared `$LOG` file is written to
sequentially via the `log` function (which uses `tee -a`, which is atomic
for short writes on Linux).

---

## Secret redaction

`config.sh` is written into each backup as a reference (useful for
restoring paths, SSH options, and flags). Secrets are redacted before
writing so the backup medium does not expose credentials:

**Explicit patterns** (always redacted, even if value is short):
- `DISCORD_WEBHOOK`
- `NOTIFY_EMAIL`
- `PORTAINER_TOKEN`
- `RCLONE_ENCRYPTION_PASSWORD`
- `RCLONE_ENCRYPTION_SALT`

**Generic catch-all** (values ≥ 4 chars matching these patterns):
- Any variable containing `Password`, `Secret`, `_TOKEN`, `_KEY`, or `WEBHOOK`
  (case-insensitive for Password/Secret)

The redaction is done with `sed` on a copy — the original `config.sh` on the
host is never modified.

---

## Staging directory size

A typical full backup with 4 VM agents stages approximately:

| Component | Size |
|---|---|
| Proxmox `/etc/pve` tar | 1–5 MB |
| Network + system state | < 1 MB |
| VM/CT config exports | < 1 MB |
| Docker agent bundle | 1–20 MB (compose files + small volumes) |
| HAOS agent bundle | 200 MB – 2 GB (full HA snapshot) |
| Minecraft agent bundle | 50–500 MB (weekly archive) |
| Generic agent bundle | 1–50 MB (/etc + packages) |

Total typical range: **300 MB – 3 GB**. The staging filesystem needs at
least this much free space. `LOCAL_STAGE_WARN_GB` (default: 5 GB) triggers
a warning if available space is below the threshold.

---

## Offsite encryption implementation

When `RCLONE_ENCRYPTION_PASSWORD` is set, `_offsite_effective_remote` calls:

```bash
rclone config create pabs_crypt_runtime crypt \
    remote        "$RCLONE_REMOTE" \
    filename_encryption standard \
    directory_name_encryption true \
    password      "$(rclone obscure "$RCLONE_ENCRYPTION_PASSWORD")" \
    password2     "$(rclone obscure "${RCLONE_ENCRYPTION_SALT:-}")"
```

This creates (or overwrites) a named rclone remote `pabs_crypt_runtime` in
rclone's config file at runtime. Because rclone's `crypt` remote is
deterministic — the same password + salt always produces the same key
material — overwriting the config each run is idempotent and existing
offsite data remains readable.

The `rclone obscure` step converts the plaintext password to rclone's
internal obscured format (simple XOR, not encryption — this is rclone's
config storage format, not the actual encryption key). The actual AES-256
encryption key is derived from the passwords using scrypt.

All subsequent rclone operations use `pabs_crypt_runtime:` instead of the
base remote. The retention pruning functions (`_offsite_list_remote_backups`,
`_offsite_prune`) also operate through the crypt remote so they see decrypted
directory names.

---

## Rotation logic

### USB rotation (`rotate_old_backups`)

Lists all `YYYY-MM-DD_*` directories under `BACKUP_ROOT`, sorts
oldest-first, and deletes until the count is at or below `KEEP_BACKUPS`.
Never deletes the directory that was just created in this run (guards
against `KEEP_BACKUPS=0`).

The rotation happens **after** offsite sync, so the USB always has the
freshest backup when the offsite sync fires.

### Offsite rotation (`_offsite_prune`)

Runs after a successful upload. Two passes:

1. **Count pass:** marks oldest backups for deletion if count > `RCLONE_KEEP_MAX`
2. **Storage pass:** iterates oldest-first marking more for deletion until
   `rclone size` reports usage below `RCLONE_MAX_STORAGE_GB`

Then applies `RCLONE_KEEP_MIN` as a safety gate: trims the delete list from
the newest end until `survivors >= RCLONE_KEEP_MIN`. Deletions use
`rclone purge` (recursive directory delete). Non-fatal on individual failures.

---

## Alert flow

```
backup.sh completion
│
├── SUCCESS → dispatch_alert "SUCCESS — backup $DATE complete"
│             + offsite success/failure sub-alerts
│
└── FAILURE → _on_exit trap fires
              dispatch_alert "FAILED with exit code $n. Review log: $LOG"

dispatch_alert (lib/core.sh)
│
├── Discord webhook (if DISCORD_WEBHOOK set)
│   curl POST to webhook URL
│   Non-fatal: log warning if curl fails
│
└── Email (if NOTIFY_EMAIL set, and backup FAILED only)
    mail -s "PABS alert: ..." $NOTIFY_EMAIL
    Requires working MTA (postfix, nullmailer, etc.)
```

Discord fires on both success and failure. Email fires on failure only
(to avoid inbox noise on every weekly success).
