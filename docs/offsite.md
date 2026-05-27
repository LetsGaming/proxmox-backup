# Offsite Sync

PABS implements the **3-2-1 backup principle**:

- **3** copies of the data
- **2** different storage media (local SSD staging + USB stick)
- **1** offsite copy (cloud or remote server)

The offsite sync runs automatically after each successful USB commit. It is
**non-fatal** — if the remote is unreachable, the USB backup is always intact
and you receive an alert. No data is ever lost due to an offsite failure.

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

| Provider | Free tier | Notes |
|---|---|---|
| Google Drive | 15 GB | OAuth token; auto-refreshes; needs browser for initial auth |
| OneDrive | 5 GB | OAuth token; auto-refreshes; needs browser for initial auth |
| Backblaze B2 | 10 GB | S3-compatible; API key auth; no token refresh issues |
| Hetzner Storage Box | — | SFTP; fixed pricing; good EU option |
| Wasabi | — | S3-compatible; no egress fees |
| Local NAS / second server | — | Use `sftp` or `local` remote type |

For **Google Drive** and **OneDrive**, the initial auth requires a browser.
On a headless Proxmox server, use `rclone authorize` on a desktop machine
and paste the token. See the [rclone docs](https://rclone.org/remote_setup/)
for the remote setup procedure.

After configuration, verify the remote works:

```bash
rclone lsd gdrive:
rclone mkdir gdrive:proxmox-backup
rclone lsd gdrive:proxmox-backup
```

---

## Basic configuration

In `config.sh`:

```bash
RCLONE_REMOTE="gdrive:proxmox-backup"
RCLONE_EXTRA_OPTS="--bwlimit 5M"    # optional: cap upload speed
```

That's all that's needed for a working offsite sync. Retention and encryption
are optional but recommended.

---

## Retention

Without retention limits, the remote grows indefinitely. Configure limits to
fit within free-tier storage or to cap costs.

```bash
RCLONE_KEEP_MIN=1           # never delete below this many offsite copies
RCLONE_KEEP_MAX=4           # prune oldest when count exceeds this
RCLONE_MAX_STORAGE_GB=0     # hard storage cap in GB (0 = unlimited)
```

**How pruning works:**

1. After each successful upload, PABS lists all backup directories on the remote.
2. If the count exceeds `RCLONE_KEEP_MAX`, oldest backups are marked for deletion.
3. If total usage exceeds `RCLONE_MAX_STORAGE_GB`, more are marked for deletion.
4. `RCLONE_KEEP_MIN` is applied as a safety gate — PABS will never delete the
   last N copies regardless of the other limits.

**Free-tier examples:**

```bash
# Google Drive (15 GB free)
RCLONE_KEEP_MIN=1
RCLONE_KEEP_MAX=4
RCLONE_MAX_STORAGE_GB=14    # leave 1 GB headroom

# OneDrive (5 GB free)
RCLONE_KEEP_MIN=1
RCLONE_KEEP_MAX=2
RCLONE_MAX_STORAGE_GB=4     # leave 1 GB headroom
```

---

## Encryption

By default, the remote receives your backup data in plaintext. Anyone with
access to the remote — including the provider — can read it. This includes
sensitive data in VM agent bundles: `.env` files, SSH keys, API tokens.

PABS supports transparent encryption via rclone's built-in `crypt` remote.
When enabled, the provider sees only opaque encrypted blobs — filenames are
encrypted too. You need the passphrase to read anything.

### Setup

No extra `rclone config` steps are needed. Just set the password in `config.sh`:

```bash
RCLONE_ENCRYPTION_PASSWORD="a strong passphrase"
RCLONE_ENCRYPTION_SALT=""       # optional second factor; recommended
```

PABS creates an ephemeral `pabs_crypt_runtime` crypt remote at runtime,
wrapping your base `RCLONE_REMOTE`. The same password always produces the
same encryption, so existing offsite data remains readable across runs.

### The salt (`RCLONE_ENCRYPTION_SALT`)

The salt is rclone's `password2` — a second passphrase that prevents
rainbow-table attacks against the main password. It is recommended if your
main password is short or memorable. Both passwords are required for decryption.

```bash
RCLONE_ENCRYPTION_PASSWORD="main passphrase"
RCLONE_ENCRYPTION_SALT="second passphrase"
```

### Keeping the passphrase safe

The encryption password is the **only thing** that can decrypt your offsite data.

- Store it in a password manager (Bitwarden, 1Password, KeePass, etc.)
- Store it somewhere physically separate from the USB stick
- PABS automatically redacts it from the `config.sh` copy written to USB,
  so it does not travel with the local backup

The `DISASTER-RECOVERY.md` generated inside each backup contains the exact
`rclone config create` command needed to reconstruct the crypt remote from
the password at restore time.

### Verifying encryption is working

After running a backup with encryption enabled, check the remote:

```bash
rclone lsf gdrive:proxmox-backup
```

You should see only encrypted filenames (gibberish), not date-formatted
directory names. If you see readable names, encryption is not active.

To access the encrypted data directly for verification:

```bash
# The crypt remote is created by PABS at runtime; re-create it manually:
rclone config create pabs_crypt_runtime crypt \
    remote "gdrive:proxmox-backup" \
    filename_encryption standard \
    directory_name_encryption true \
    password "$(rclone obscure 'your passphrase')" \
    password2 "$(rclone obscure 'your salt')"    # omit if no salt

# Now list through the crypt layer — should show readable date-format names:
rclone lsf pabs_crypt_runtime:
```

---

## OAuth token refresh (Google Drive / OneDrive)

OAuth tokens for Google Drive and OneDrive can expire or be revoked if:
- The account password changes
- The token hasn't been used in an extended period
- Google/Microsoft revokes it for security reasons

rclone normally handles token refresh automatically using the refresh token
stored in its config file. On a headless Proxmox server this works silently.

If a token does expire (e.g. after a very long period of inactivity), the
offsite sync will fail and you will receive an alert. To re-authenticate:

```bash
rclone config reconnect gdrive:    # or onedrive:
```

This requires a browser. On a headless server, use `rclone authorize` on a
desktop machine and paste the result. See [rclone remote setup](https://rclone.org/remote_setup/).

The USB backup is always intact during a token failure — it is not affected
by offsite sync issues.

**To avoid token expiry:** Backblaze B2, Wasabi, and SFTP-based remotes use
API keys instead of OAuth and do not have this issue.

---

## What is and isn't synced offsite

**Synced:** the final backup directory (`BACKUP_ROOT/<date>/`) — everything
PABS stages: Proxmox configs, VM/CT definitions, system state, VM agent bundles,
the restore script, the DR playbook, and the SHA256 manifest.

**Not synced:**
- `backup.log` — the persistent log lives one level above the per-backup
  directories and is not included in the sync
- Old backup directories after pruning — PABS only syncs the new backup, then
  prunes old ones from the remote separately

---

## Monitoring offsite status

```bash
/opt/pabs/pabs-status.sh
```

The offsite section reports:
- Encryption on/off
- Retention policy (min/max/cap)
- Whether the remote is reachable
- Number of remote backups and total GB used
- Warning if below `RCLONE_KEEP_MIN` or over `RCLONE_MAX_STORAGE_GB`