# PABS Configuration Reference

`config.sh` is the **only file you need to edit**. Every variable is documented
here with its type, default value, and examples. The file is divided into
clearly marked sections — the internal variables at the bottom are derived
automatically and should not be changed.

---

## USB Target

### `USB_MOUNT`
**Type:** string | **Default:** `"/mnt/backup-usb"`

Mount point of the USB stick. PABS refuses to run if nothing is mounted here.

```bash
USB_MOUNT="/mnt/backup-usb"
```

### `TARGET_UUID`
**Type:** string | **Default:** `""` (disabled)

UUID of the USB partition. When set, PABS verifies the partition at `USB_MOUNT`
matches this UUID before writing anything — ensuring you never accidentally back
up to the wrong drive.

Get the UUID with:
```bash
blkid /dev/sdX1
```

Leave empty to skip the check (less safe — any drive at `USB_MOUNT` will be used):
```bash
TARGET_UUID=""
TARGET_UUID="a1b2c3d4-e5f6-7890-abcd-ef1234567890"   # recommended
```

### `KEEP_BACKUPS`
**Type:** positive integer | **Default:** `4`

Number of completed weekly backups to keep on USB before rotating old ones.
Rotation only deletes if the new backup has been successfully committed first.

```bash
KEEP_BACKUPS=4    # keep the last 4 weekly backups (~1 month)
KEEP_BACKUPS=8    # keep ~2 months
```

---

## Local Staging

All backup data is assembled on the Proxmox host's own disk first. The USB
drive sees a single sequential write at the end. This staging directory must
have enough free space to hold one complete backup.

### `LOCAL_STAGE_BASE`
**Type:** path | **Default:** `"/var/tmp/pabs-stage"`

Base directory for the temporary staging area. On Proxmox installs with a
small root partition (common with LVM-thin or ZFS), consider pointing this
at a larger volume:

```bash
LOCAL_STAGE_BASE="/var/tmp/pabs-stage"          # default — root LVM
LOCAL_STAGE_BASE="/rpool/data/pabs-stage"        # ZFS pool
LOCAL_STAGE_BASE="/mnt/pve/mystore/pabs-stage"  # directory storage
```

### `LOCAL_STAGE_WARN_GB`
**Type:** integer (GB) | **Default:** `5`

PABS warns at startup if the staging filesystem is the same device as `/`
and has less than this many GB free. This is a soft warning — the backup
continues, but you should take action before the next run.

```bash
LOCAL_STAGE_WARN_GB=5
```

---

## VM / LXC Agent Backups

PABS can back up VMs and LXCs with a lightweight agent that produces
self-contained, restore-ready bundles. No disk images required.

### `VM_AGENTS`
**Type:** array | **Default:** `()` (empty — no agents)

Each entry is a space-separated string with four fields:

```
"label  ip-or-hostname  ssh-user  agent-path"
```

| Field | Description |
|---|---|
| `label` | Unique short name. Used as the backup subfolder name and in log output. Lowercase with dashes. |
| `ip-or-hostname` | Address reachable from the Proxmox host. |
| `ssh-user` | SSH user on the VM. Needs read access to config paths. Typically `root` for LXCs or a dedicated `backup` user. |
| `agent-path` | Full path to `agent.sh` on the remote VM. Default install: `/opt/pabs-agent/agent.sh`. |

```bash
VM_AGENTS=(
    "docker-vm    192.168.1.10   root      /opt/pabs-agent/agent.sh"
    "haos         192.168.1.20   root      /opt/pabs-agent/agent.sh"
    "pihole-lxc   192.168.1.30   root      /opt/pabs-agent/agent.sh"
    "mc-server    192.168.1.40   alice     /opt/pabs-agent/agent.sh"
)
```

Leave empty to skip VM agent backups entirely:
```bash
VM_AGENTS=()
```

### `VM_SSH_KEY`
**Type:** path | **Default:** `""` (use host default key)

Shared SSH private key for all VM agent connections. Leave empty to use the
Proxmox host's default key (`~/.ssh/id_ed25519` etc.).

Using a dedicated key is recommended so rotating the host's default key
doesn't silently break agent backups:

```bash
# Generate a dedicated key (one time):
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519_pabs_agent -N ""
# Deploy to each VM:
ssh-copy-id -i /root/.ssh/id_ed25519_pabs_agent.pub root@<vm-ip>

VM_SSH_KEY="/root/.ssh/id_ed25519_pabs_agent"
```

### Per-VM SSH key override
**Format:** `VM_SSH_KEY_<label>` (dashes in label become underscores)

Takes precedence over `VM_SSH_KEY` for that specific VM:

```bash
VM_SSH_KEY_docker_vm="/root/.ssh/id_ed25519_dockervm"
VM_SSH_KEY_pihole_lxc="/root/.ssh/id_ed25519_pihole"
```

### `VM_AGENT_KEEP_BUNDLES`
**Type:** positive integer | **Default:** `2`

How many agent bundles to keep per VM on the USB before rotating old ones.
Set to `1` to keep only the latest (saves space — especially for HAOS
snapshots which can be 500 MB+).

```bash
VM_AGENT_KEEP_BUNDLES=2
VM_AGENT_KEEP_BUNDLES=1    # saves space for large HAOS snapshots
```

### `VM_AGENT_MAX_PARALLEL`
**Type:** integer | **Default:** `1` (sequential)

Maximum number of VM agents to run simultaneously. Increase if you have
many agents and want to cut total backup time. Log lines from parallel
workers are written sequentially via the shared log file.

```bash
VM_AGENT_MAX_PARALLEL=1    # default: sequential
VM_AGENT_MAX_PARALLEL=3    # run up to 3 agents at once
```

### `VM_AGENT_STAGE_MIN_FREE_KB`
**Type:** integer (KB) | **Default:** `524288` (512 MB)

Minimum free space on local staging after each agent bundle pull.
If breached, the agent section aborts immediately to avoid filling the disk.

```bash
VM_AGENT_STAGE_MIN_FREE_KB=524288    # 512 MB
VM_AGENT_STAGE_MIN_FREE_KB=1048576   # 1 GB
```

### `VM_AGENT_SSH_OPTS`
**Type:** array | **Default:** (see below)

SSH options applied to every VM agent connection.

```bash
VM_AGENT_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15
                   -o StrictHostKeyChecking=yes
                   -o UserKnownHostsFile=/root/.ssh/pabs_known_hosts)
```

`StrictHostKeyChecking=yes` requires host keys to be pre-registered via
`install-agent.sh` (which does this automatically). Do not change to
`accept-new` for production use — it defeats MITM protection.

---

## Notifications

### `DISCORD_WEBHOOK`
**Type:** string | **Default:** `""` (disabled)

Discord webhook URL. Alerts fire on: backup success, backup failure, low USB
space with auto-purge, offsite sync success/failure.

Create a webhook at: **Server Settings → Integrations → Webhooks**

```bash
DISCORD_WEBHOOK="https://discord.com/api/webhooks/..."
```

### `NOTIFY_EMAIL`
**Type:** string | **Default:** `""` (disabled)

Email address for fallback failure alerts. Requires a working MTA:

```bash
apt install mailutils    # plus postfix or nullmailer

NOTIFY_EMAIL="admin@example.com"
```

---

## Optional Features

### `BACKUP_ZFS`
**Type:** `"true"` | `"false"` | **Default:** `"true"`

Exports ZFS pool and dataset layout into `system-state/`. Enabled by default
because ZFS is the standard Proxmox storage backend since PVE 6.x. Set to
`"false"` only on setups with no ZFS at all.

```bash
BACKUP_ZFS="true"
BACKUP_ZFS="false"   # non-ZFS setups only
```

---

## Offsite Sync

The offsite sync runs after each successful USB commit. Failure is
non-fatal — the USB backup is always intact regardless.

### `RCLONE_REMOTE`
**Type:** string | **Default:** `""` (disabled)

rclone remote name and path. Configure the base remote with `rclone config`
(interactive wizard). PABS handles encryption transparently on top of this.

```bash
RCLONE_REMOTE=""                              # disabled
RCLONE_REMOTE="gdrive:proxmox-backup"         # Google Drive (15 GB free)
RCLONE_REMOTE="onedrive:proxmox-backup"       # OneDrive (5 GB free)
RCLONE_REMOTE="backblaze:bucket/proxmox"      # Backblaze B2
RCLONE_REMOTE="hetzner-sftp:backup/proxmox"  # Hetzner Storage Box
```

### `RCLONE_EXTRA_OPTS`
**Type:** string | **Default:** `"--bwlimit 5M"`

Extra flags passed to every `rclone sync` call.

```bash
RCLONE_EXTRA_OPTS="--bwlimit 5M"        # cap upload at 5 MB/s
RCLONE_EXTRA_OPTS="--bwlimit 2M --transfers 1"
RCLONE_EXTRA_OPTS=""                    # no limits
```

### `RCLONE_KEEP_MIN`
**Type:** positive integer | **Default:** `1`

Minimum number of offsite backups to always keep. PABS will never delete
below this count, even if `RCLONE_KEEP_MAX` or `RCLONE_MAX_STORAGE_GB`
would require it. This is your safety floor.

```bash
RCLONE_KEEP_MIN=1    # always keep at least one offsite copy
RCLONE_KEEP_MIN=2    # always keep at least two
```

### `RCLONE_KEEP_MAX`
**Type:** integer | **Default:** `4`

Maximum number of offsite backups to keep. Oldest are pruned when this
count is exceeded after a new upload. Set to `0` to disable count-based
pruning (rely on storage cap only).

```bash
RCLONE_KEEP_MAX=4    # keep up to 4 offsite copies
RCLONE_KEEP_MAX=0    # no count limit — rely on RCLONE_MAX_STORAGE_GB only
```

### `RCLONE_MAX_STORAGE_GB`
**Type:** integer (GB) | **Default:** `0` (disabled)

Hard cap on total remote storage used by PABS (in GB). Oldest backups are
pruned to stay under this limit, subject to `RCLONE_KEEP_MIN`.

Useful for fitting within free-tier limits:

```bash
RCLONE_MAX_STORAGE_GB=0     # no storage cap (default)
RCLONE_MAX_STORAGE_GB=4     # stay under OneDrive's 5 GB free tier
RCLONE_MAX_STORAGE_GB=14    # stay under Google Drive's 15 GB free tier
```

### `RCLONE_ENCRYPTION_PASSWORD`
**Type:** string | **Default:** `""` (disabled)

Main passphrase for offsite encryption. When set, PABS automatically wraps
`RCLONE_REMOTE` with rclone's `crypt` remote — no manual rclone config steps
needed. The provider sees only encrypted blobs; filenames are encrypted too.

**Store this passphrase safely** (e.g. in a password manager), separately
from the USB backup. It is required to decrypt the offsite data and is
automatically redacted from the `config.sh` copy written to USB.

```bash
RCLONE_ENCRYPTION_PASSWORD=""                  # disabled
RCLONE_ENCRYPTION_PASSWORD="a strong passphrase here"
```

### `RCLONE_ENCRYPTION_SALT`
**Type:** string | **Default:** `""` (disabled)

Optional second passphrase (rclone `password2`). Protects against
rainbow-table attacks on the main password. Recommended if your main
password is short or memorable. Also redacted from the USB copy.

```bash
RCLONE_ENCRYPTION_SALT=""
RCLONE_ENCRYPTION_SALT="another passphrase"
```

---

## Free-tier configuration examples

### Google Drive (15 GB free)

```bash
RCLONE_REMOTE="gdrive:proxmox-backup"
RCLONE_KEEP_MIN=1
RCLONE_KEEP_MAX=4
RCLONE_MAX_STORAGE_GB=14
RCLONE_ENCRYPTION_PASSWORD="your passphrase"
```

### OneDrive (5 GB free)

```bash
RCLONE_REMOTE="onedrive:proxmox-backup"
RCLONE_KEEP_MIN=1
RCLONE_KEEP_MAX=2
RCLONE_MAX_STORAGE_GB=4
RCLONE_ENCRYPTION_PASSWORD="your passphrase"
```

---

## Internal variables (do not edit)

These are derived automatically at the bottom of `config.sh`:

| Variable | Value |
|---|---|
| `SCRIPT_VERSION` | Current PABS version string |
| `DATE` | Timestamp for this run (`YYYY-MM-DD_HH-MM-SS`) |
| `BACKUP_ROOT` | `$USB_MOUNT/proxmox-backup` |
| `STAGE_DIR` | `$LOCAL_STAGE_BASE/.tmp-$DATE` |
| `FINAL_DIR` | `$BACKUP_ROOT/$DATE` |
| `LOG` | `$BACKUP_ROOT/backup.log` |
| `LOCK_FILE` | `$LOCAL_STAGE_BASE/.backup.lock` |
| `WARNINGS` | Warning counter (initialised to 0) |
| `ERRORS` | Error counter (initialised to 0) |

`SCRIPT_VERSION`, `USB_MOUNT`, `BACKUP_ROOT`, `LOCAL_STAGE_BASE`, `LOG`,
and `LOCK_FILE` are marked `readonly` after sourcing to prevent accidental
re-assignment by scripts sourced later.