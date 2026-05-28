# Offsite sync

PABS implements the 3-2-1 backup rule: 3 copies, 2 different storage media (local SSD staging + USB stick), 1 offsite copy (cloud or remote server).

The offsite sync runs automatically after each successful USB commit. It is non-fatal — if the remote is unreachable, the USB backup is always intact and you receive an alert. No data is ever lost due to an offsite failure.

---

## Prerequisites

```bash
apt install rclone
```

---

## Setting up a remote

Run the interactive wizard once to configure your provider:

```bash
rclone config
```

rclone supports 70+ storage backends. Common choices for a homelab:

| Provider | Free tier | Auth type | Notes |
| :------- | :-------- | :-------- | :---- |
| Google Drive | 15 GB | OAuth token | Needs browser for initial auth |
| OneDrive | 5 GB | OAuth token | Needs browser for initial auth |
| Backblaze B2 | 10 GB | API key | No token expiry issues |
| Hetzner Storage Box | — | SFTP | Good EU option; fixed pricing |
| Wasabi | — | S3-compatible | No egress fees |
| Local NAS / second server | — | SFTP or `local` | |

For Google Drive and OneDrive, initial auth requires a browser. On a headless Proxmox server, use `rclone authorize` on a desktop machine and paste the token. See the [rclone remote setup docs](https://rclone.org/remote_setup/) for the full procedure.

Verify the remote after configuration:

```bash
rclone lsd gdrive:
rclone mkdir gdrive:proxmox-backup
rclone lsd gdrive:proxmox-backup
```

---

## Basic configuration

> **Using the wizard?** Run `sudo bash /opt/pabs/setup.sh --step offsite` — it handles provider selection, rclone config verification, retention presets, and encryption in one session. The steps below are for manual configuration.

Minimum required in `config.sh`:

```bash
RCLONE_REMOTE="gdrive:proxmox-backup"
RCLONE_EXTRA_OPTS="--bwlimit 5M"    # optional: cap upload speed
```

---

## Retention

Without retention limits the remote grows indefinitely. Configure limits to fit within free-tier storage or cap costs.

```bash
RCLONE_KEEP_MIN=1           # never delete below this many offsite copies
RCLONE_KEEP_MAX=4           # prune oldest when count exceeds this
RCLONE_MAX_STORAGE_GB=0     # hard storage cap in GB (0 = unlimited)
```

**How pruning works:**

After each successful upload, PABS lists all backup directories on the remote. If count exceeds `RCLONE_KEEP_MAX`, oldest backups are marked for deletion. If total usage exceeds `RCLONE_MAX_STORAGE_GB`, more are marked. `RCLONE_KEEP_MIN` is applied as a final safety gate — PABS never deletes the last N copies regardless of other limits.

**Free-tier sizing:**

```bash
# Google Drive (15 GB free) — leave 1 GB headroom
RCLONE_KEEP_MIN=1
RCLONE_KEEP_MAX=4
RCLONE_MAX_STORAGE_GB=14

# OneDrive (5 GB free) — leave 1 GB headroom
RCLONE_KEEP_MIN=1
RCLONE_KEEP_MAX=2
RCLONE_MAX_STORAGE_GB=4
```

---

## Encryption

By default, the remote receives backup data in plaintext. Anyone with access to the remote — including the provider — can read it. This includes sensitive content in VM agent bundles: `.env` files, SSH keys, API tokens.

PABS supports transparent AES-256 encryption via rclone's built-in `crypt` backend. The provider sees only opaque encrypted blobs; filenames are encrypted too.

### Setup

No extra `rclone config` steps required. Set the password in `config.sh`:

```bash
RCLONE_ENCRYPTION_PASSWORD="a strong passphrase"
RCLONE_ENCRYPTION_SALT=""       # optional second factor; recommended
```

PABS creates an ephemeral `pabs_crypt_runtime` crypt remote at runtime, wrapping your base `RCLONE_REMOTE`. The same password always produces the same key material (via scrypt derivation), so existing offsite data remains readable across backup runs.

### The salt (`RCLONE_ENCRYPTION_SALT`)

rclone's `password2` — a second passphrase that prevents rainbow-table attacks against the main password. Recommended if your main password is short or memorable. Both passwords are required for decryption.

### Keeping the passphrase safe

The encryption password is the only thing that can decrypt your offsite data.

- Store it in a password manager (Bitwarden, 1Password, KeePass, etc.), separately from the USB stick
- PABS automatically redacts it from the `config.sh` copy written to USB, so it does not travel with the local backup
- The `DISASTER-RECOVERY.md` generated inside each backup contains the exact `rclone config create` command needed to reconstruct the crypt remote at restore time

### Verifying encryption is active

After a backup with encryption enabled:

```bash
rclone lsf gdrive:proxmox-backup
```

You should see only encrypted filenames (random-looking strings), not date-formatted directory names. Readable names mean encryption is not active.

Access and verify the encrypted data directly:

```bash
# Re-create the crypt remote manually
rclone config create pabs_crypt_runtime crypt \
    remote                    "gdrive:proxmox-backup" \
    filename_encryption       standard \
    directory_name_encryption true \
    password                  "$(rclone obscure 'your passphrase')" \
    password2                 "$(rclone obscure 'your salt')"   # omit if no salt

# List through the crypt layer — should show date-formatted directory names
rclone lsf pabs_crypt_runtime:
```

---

## OAuth token refresh (Google Drive / OneDrive)

OAuth tokens can expire or be revoked if the account password changes, the token hasn't been used for an extended period, or the provider revokes it for security reasons.

rclone handles token refresh automatically using the refresh token stored in its config file. On a headless Proxmox server this works silently. If a token does expire, the offsite sync fails and you receive an alert. To re-authenticate:

```bash
rclone config reconnect gdrive:    # or onedrive:
```

This requires a browser. On a headless server, use `rclone authorize` on a desktop machine and paste the result.

The USB backup is always intact during a token failure — offsite sync issues do not affect the local backup.

To avoid token expiry entirely: Backblaze B2, Wasabi, and SFTP-based remotes use API keys and do not have this issue.

---

## What is and isn't synced

**Synced:** the final backup directory (`BACKUP_ROOT/<date>/`) — all PABS-staged data: Proxmox configs, VM/CT definitions, system state, VM agent bundles, the restore script, the DR playbook, and the SHA256 manifest.

**Not synced:**

- `backup.log` — the persistent log lives one level above per-backup directories and is not included
- Old backup directories after pruning — PABS syncs only the new backup, then prunes old ones from the remote separately

---

## Monitoring offsite status

```bash
/opt/pabs/pabs-status.sh
```

The offsite section reports: encryption on/off, retention policy, remote reachability, number of remote backups and total GB used, and warnings if below `RCLONE_KEEP_MIN` or over `RCLONE_MAX_STORAGE_GB`.