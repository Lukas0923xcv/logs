# logs

A small central log archive for a handful of Linux machines.

Once a day an Ansible playbook collects yesterday's logs from every host and
writes them, unchanged, to an SMB share. Old days are compressed with zstd.
A small read-only web UI shows how much each host and service logs and lets
you read, search and download the logs.

There is no database, no search cluster and no agent on the hosts.

```
hosts (Ubuntu / Debian)          collector (Ubuntu Server)             SMB share
  journald        ── Ansible ──▶   collect.yml    (daily)   ── rw ──▶   raw/2025/01/31/web01/journald.log
  docker logs                      retention.yml  (daily)               manifests/2025/2025-01-31.json
  extra log files                  logs-webui     (127.0.0.1:8484) ◀─ ro ─ archive/2025/2025-01-31.tar.zst
```

## Contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Install](#install)
- [Upgrade](#upgrade)
- [Uninstall](#uninstall)
- [Configuration](#configuration)
- [Running the collector](#running-the-collector)
- [Retention](#retention)
- [Web UI](#web-ui)
- [Reading and restoring logs](#reading-and-restoring-logs)
- [Hosts without Ansible](#hosts-without-ansible)
- [Security notes](#security-notes)
- [Development](#development)

## What it does

**Collector** (Ansible, runs once a day)

- Collects exactly one day per run: yesterday from 00:00:00 to 23:59:59.999999
  in the collector's time zone. Days neither overlap nor leave gaps.
- Per host it takes
  - the journal (`journalctl --since --until`),
  - `docker logs --since --until` of every container (not the json files,
    which rotate early),
  - optional extra log files that you list per host.
- Writes `raw/YYYY/MM/DD/<host>/<source>.log` on the share.
- Writes one manifest per day, `manifests/YYYY/YYYY-MM-DD.json`: which hosts
  were ok or failed, and bytes, lines and error/warning line counts per host
  and source.
- A host that is unreachable or fails is recorded in the manifest. The other
  hosts are still collected. Optionally you get a mail.
- Running the same day twice does not duplicate anything: hosts that already
  succeeded are skipped, failed hosts are tried again.

**Retention** (Ansible, runs once a day)

- Keeps N days uncompressed (default 60), then packs each day into
  `archive/YYYY/YYYY-MM-DD.tar.zst`, verifies the archive and only then
  deletes the raw directory. Compression is lossless.
- Optionally deletes archives after M days or above a total size.
- Manifests are never deleted, so the statistics stay complete.

**Web UI** (one static binary, read-only)

- Statistics from the manifests, browse day → host → source, paged viewer,
  streamed text filter, downloads, single files out of archives.
- About 20 MiB of memory when idle; runs under a hard 64 MB limit.

## Requirements

| What | Needed |
| --- | --- |
| Collector and web UI host | Ubuntu Server 24.04 LTS or 26.04 LTS, amd64 or arm64. `install.sh` refuses anything else. |
| Hosts to collect from | Ubuntu or Debian (VMs or containers) with `python3`, reachable over SSH, and a user with passwordless `sudo`. |
| Storage | An SMB share. Ideally two SMB users: one with write access (collector) and one read-only (web UI). |
| On the collector | `ansible-core`, `cifs-utils`, `zstd`, `tar` (installed by `install.sh` from the Ubuntu archive). |

The collector and the web UI may run on the same host or on different ones.

## Install

One line, on the Ubuntu host that will run the collector and the web UI:

```bash
curl -fsSL https://raw.githubusercontent.com/Lukas0923xcv/logs/main/install.sh | sudo bash
```

Safer: download the script, read it, then run it.

```bash
curl -fsSLO https://raw.githubusercontent.com/Lukas0923xcv/logs/main/install.sh
```

```bash
less install.sh
```

```bash
sudo bash install.sh
```

What the installer does:

1. Checks that it runs as root on Ubuntu 24.04 or 26.04.
2. Installs `ansible-core`, `cifs-utils`, `zstd` and a few base tools with
   `apt`. Nothing comes from third-party package sources.
3. Downloads the web UI binary and the playbook bundle from the latest GitHub
   release (or the one given with `--version`), checks both against
   `SHA256SUMS`, and installs them to `/usr/local/bin/logs-webui` and
   `/usr/local/share/logs`.
4. Creates two system users without login: `logs-web` (web UI) and
   `logs-collector` (collector, with its own SSH key).
5. Creates the configuration in `/etc/logs/` from the example files. Existing
   files are never overwritten. This includes `/etc/logs/install.conf`, which
   holds the SMB mount settings.
6. Installs itself as `/usr/local/sbin/logs-install`, so the mount settings
   can be applied later without downloading anything.
7. Installs the systemd units: `logs-webui.service`, `logs-collect.timer`
   (02:30) and `logs-retention.timer` (04:30).
8. Applies `install.conf`: SMB credentials files, `/etc/fstab` lines and the
   mounts (see [SMB mounts](#smb-mounts)). Nothing is mounted while
   `LOGS_SMB_SHARE` is empty, which is the case after the first install.
9. Prints a summary with the service status, the URL and the next steps.

The installer never asks questions. Everything it needs for the mounts comes
from one file.

Options:

| Option | Effect |
| --- | --- |
| `--version vX.Y.Z` | Install this release instead of the latest. |
| `--no-webui` | Do not install the web UI. |
| `--no-timers` | Do not install the collector and retention timers. Use it when the collector runs from Semaphore. |
| `--no-mount` | Do not touch `install.conf` and the mounts. |
| `--apply` | Only apply `/etc/logs/install.conf` (credentials files, `/etc/fstab`, mounts). Downloads and installs nothing. Exits with 1 if a mount failed. |
| `--non-interactive` | Accepted for compatibility. The installer never asks anything. |
| `--uninstall` | Remove binary and units. Keeps configuration and logs. |
| `--uninstall --purge` | Also remove configuration, credentials, fstab entries and the users. Never the logs. |

With the one-liner, pass options after `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/Lukas0923xcv/logs/main/install.sh | sudo bash -s -- --no-timers
```

### SMB mounts

All mount settings live in one file, `/etc/logs/install.conf`. The first
install creates it from [`install.example.conf`](install.example.conf) (mode
0600, owner root, because it holds the SMB passwords) and never overwrites
it. Each key is explained in the file.

| Key | Default | Meaning |
| --- | --- | --- |
| `LOGS_SMB_SHARE` | empty | The share, for example `//nas.example.com/logs`. Empty means: set up no mounts. |
| `LOGS_SMB_DOMAIN` | empty | Optional SMB domain or workgroup. |
| `LOGS_SMB_RW_USER` | empty | SMB user with write access (collector). |
| `LOGS_SMB_RW_PASSWORD` | empty | Its password. |
| `LOGS_SMB_RO_USER` | empty | SMB user with read-only access (web UI). |
| `LOGS_SMB_RO_PASSWORD` | empty | Its password. |
| `LOGS_RW_OWNER` | `logs-collector` | Local user that owns the read-write mount. If Semaphore (or anything else) runs the playbooks, use its user, for example `semaphore`. |
| `LOGS_RW_MOUNT` | `/mnt/logs-rw` | Mount point of the read-write mount. |
| `LOGS_RO_MOUNT` | `/mnt/logs-ro` | Mount point of the read-only mount. |

Edit the file, then apply it:

```bash
sudo nano /etc/logs/install.conf
```

```bash
sudo logs-install --apply
```

`--apply` rewrites `/etc/logs/smb-rw.cred` and `/etc/logs/smb-ro.cred` (mode
0600, owner root), replaces the `# logs-archive` lines in `/etc/fstab` and
mounts both shares again. It needs no network access. Running the installer
again (`sudo logs-install`, or the one-liner) applies the file as well. Both
print the share, the users, the owner and whether each mount worked, and never
a password.

The resulting `/etc/fstab` lines look like this:

```
//nas.example.com/logs /mnt/logs-rw cifs credentials=/etc/logs/smb-rw.cred,uid=logs-collector,gid=logs-collector,file_mode=0640,dir_mode=0750,_netdev,nofail 0 0 # logs-archive
//nas.example.com/logs /mnt/logs-ro cifs ro,credentials=/etc/logs/smb-ro.cred,uid=logs-web,gid=logs-web,file_mode=0440,dir_mode=0550,_netdev,nofail 0 0 # logs-archive
```

The collector writes through the read-write mount. The web UI only ever sees
the read-only mount, which uses an SMB user without write permission on the
server.

**File format.** `KEY=value`, one per line, no spaces around the `=`. The file
is read, never executed:

- A `#` starts a comment only at the start of a line, never after a value.
- `$`, backticks, backslashes, `#` and quotes inside a value are taken
  literally. A password may contain any character except a line break.
- Unquoted values lose leading and trailing spaces. A value wrapped in one
  pair of `"..."` or `'...'` loses those quotes and is otherwise kept
  exactly. To keep spaces at the ends, or a password that starts and ends with
  a quote character, add one more pair of quotes.
- Unknown keys, duplicate keys, lines that are not `KEY=value` and Windows
  line endings stop the installer with a message that names the line (never
  the value). The check runs before anything is changed.

Things that only skip one mount, with the reason shown in the summary: a
missing user or password, or a `LOGS_RW_OWNER` that does not exist. If
`LOGS_SMB_SHARE` is empty nothing is touched.

The summary of a first install ends with the next step:
`Edit /etc/logs/install.conf, then run: sudo logs-install`. If you installed
with options such as `--no-timers`, repeat them (`sudo logs-install
--no-timers`), or use `sudo logs-install --apply` which needs none.

### Manual installation

If you do not want to run the installer:

1. `sudo apt install ansible-core cifs-utils zstd`
2. Download `logs-webui-linux-<arch>`, `logs-bundle.tar.gz` and `SHA256SUMS`
   from the [releases page](https://github.com/Lukas0923xcv/logs/releases) and
   run `sha256sum --check --ignore-missing SHA256SUMS`.
3. Copy the binary to `/usr/local/bin/logs-webui` (mode 755) and unpack the
   bundle to `/usr/local/share/logs`.
4. Create the users: `useradd --system --shell /usr/sbin/nologin logs-web` and
   `useradd --system --create-home --home-dir /var/lib/logs-collector --shell /usr/sbin/nologin logs-collector`.
5. Copy `config.example.env` to `/etc/logs/webui.env`,
   `ansible/inventory.example.yml` to `/etc/logs/inventory.yml` and
   `ansible/group_vars/all.example.yml` to `/etc/logs/group_vars/all.yml`.
6. Mount the share twice, with lines like the ones shown under
   [SMB mounts](#smb-mounts) (or copy `install.example.conf` to
   `/etc/logs/install.conf`, fill it in and run `sudo bash install.sh --apply`
   from the unpacked bundle).
7. Copy `systemd/*` to `/etc/systemd/system/`, then
   `systemctl daemon-reload && systemctl enable --now logs-webui.service logs-collect.timer logs-retention.timer`.

## Upgrade

Run the installer again (the one-liner, or `sudo logs-install` with the same
options you used the first time, for example `--no-timers`). It replaces the
binary, the playbooks, the units and `/usr/local/sbin/logs-install` and keeps
everything in `/etc/logs/`, including `install.conf`, which is applied again.
A bad `install.conf` stops the upgrade before anything is changed. New
configuration variables are listed in the [CHANGELOG](CHANGELOG.md); compare
your files with the new examples in `/usr/local/share/logs/`.

Upgrading from 0.1.0: the installer no longer asks questions and ignores the
old `LOGS_SMB_*` environment variables. A first run creates `install.conf`;
copy your share, users and passwords into it and run `sudo logs-install
--apply`. Mount lines that an older installer wrote are replaced.

## Uninstall

```bash
sudo bash install.sh --uninstall
```

removes the binary, the units and `/usr/local/share/logs`. It keeps
`/etc/logs`, the fstab entries, the users and all logs. Add `--purge` to
remove those as well. The logs on the share are never deleted by the
installer.

## Configuration

### Web UI: `/etc/logs/webui.env`

| Variable | Default | Meaning |
| --- | --- | --- |
| `LOGS_DATA_DIR` | `/mnt/logs-ro` | Directory with `raw/`, `archive/`, `manifests/`. |
| `LOGS_LISTEN` | `127.0.0.1:8484` | Address and port. |
| `LOGS_TITLE` | `Log archive` | Title in the page header. |
| `LOGS_BASIC_AUTH_FILE` | unset | htpasswd file with bcrypt hashes; turns on basic auth. |
| `LOGS_INDEX_REFRESH` | `5m` | How often new manifests are picked up. |
| `LOGS_FILTER_MAX_RESULTS` | `500` | Text filter stops after this many lines. |
| `LOGS_FILTER_TIMEOUT` | `15s` | Text filter stops after this time. |
| `LOGS_PAGE_BYTES` | `65536` | Size of one viewer page. |
| `LOGS_ARCHIVE_STREAMS` | `1` | Parallel downloads out of archives (single files and zips of archived days). |
| `LOGS_ZIP_STREAMS` | `2` | Parallel zip downloads of raw days. Further requests wait up to 20 seconds, then get "try again". |
| `LOGS_ZSTD_MAX_WINDOW_MB` | `32` | Largest zstd window the UI will decompress. |

After a change: `sudo systemctl restart logs-webui`.

### Collector: `/etc/logs/group_vars/all.yml` and `/etc/logs/inventory.yml`

All variables are optional. `ansible/group_vars/all.example.yml` documents
each one; the defaults live in `ansible/roles/logs_defaults/defaults/main.yml`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `logs_root` | `/mnt/logs-rw` | Read-write mount of the share. |
| `logs_root_fstypes` | `[cifs, smb3]` | The collector refuses to write to any other filesystem, so an unmounted share cannot fill the system disk. `[]` turns the check off. |
| `logs_targets` | `all` | Ansible host pattern. |
| `logs_collect_localhost` | `false` | Also collect the collector host itself. |
| `logs_localhost_name` | `collector` | Its name in the archive. |
| `logs_localhost_become` | `true` | Use sudo for the collector's own logs. |
| `logs_day` | yesterday | Day to collect, `YYYY-MM-DD`. |
| `logs_timezone` | collector's | Time zone that defines the day. |
| `logs_force` | `false` | Collect hosts again that already succeeded. |
| `logs_journal` | `auto` | `auto`, `yes` or `no`. |
| `logs_journal_format` | `short-iso-precise` | Any `journalctl --output` format (`json`, `export`, ...). |
| `logs_docker` | `auto` | `auto`, `yes` or `no`. |
| `logs_extra_files` | `[]` | Extra files (paths or globs), usually per host. |
| `logs_extra_files_by_host` | `{}` | The same as a map hostname → list. |
| `logs_count_levels` | `true` | Count lines that mention error or warning words. |
| `logs_remote_tmp` | `/var/tmp/logs-collect` | Staging directory on the hosts. |
| `logs_remote_state_dir` | `/var/lib/logs-collect` | Where hosts remember offsets of extra files. |
| `logs_push_hosts` | `[]` | Hosts that push their logs themselves; reported when missing. |
| `logs_syslog_spool` | unset | Spool of the syslog receiver to import. |
| `logs_syslog_names` | `{}` | Sender IP → name in the archive. |
| `logs_syslog_keep_days` | `7` | Days to keep imported spool files. |
| `logs_raw_days` | `60` | Days kept uncompressed. |
| `logs_archive_days` | `0` | Delete archives older than this. `0` keeps them forever. |
| `logs_archive_max_gb` | `0` | Delete the oldest archives above this total size. `0` is no cap. |
| `logs_zstd_level` | `19` | zstd level. |
| `logs_zstd_window_log` | `25` | zstd `--long` window (2^n bytes). See [Retention](#retention). |
| `logs_zstd_threads` | `1` | zstd threads. |
| `logs_fail_on_host_failure` | `true` | End the run as failed when a host had problems. |
| `logs_notify_on_failure` | `false` | Send a mail when a host had problems. |
| `logs_smtp_host`, `logs_smtp_port`, `logs_smtp_security` | –, `587`, `starttls` | Mail server. |
| `logs_smtp_user`, `logs_smtp_from`, `logs_smtp_to` | – | Login, sender, list of recipients. |

The SMTP password is never a variable. It is read from the environment
variable `LOGS_SMTP_PASSWORD`: a secret environment variable in Semaphore, or
`/etc/logs/collector.secrets.env` (mode 600, owner root) for the systemd
timer.

Per-host settings go in the inventory:

```yaml
all:
  vars:
    ansible_user: logcollector
    ansible_become: true
  hosts:
    web01.example.com:
      ansible_host: 192.0.2.11
      logs_extra_files:
        - /var/log/nginx/access.log
        - /var/log/nginx/error.log
    db01.example.com:
      ansible_host: 192.0.2.12
```

### How the sources are collected

- **journald and Docker** are cut by time, so each day is exact. Docker logs
  are read through `docker logs`; logs of a container that was removed before
  the nightly run are gone. If that matters, use Docker's `journald` log
  driver for that container: its output is then part of the journal.
- **Extra files** have no reliable timestamps, so they are cut by position:
  each run takes what was written since the previous run (tracked by inode and
  byte offset on the host). Nothing is collected twice and nothing is skipped,
  but the cut is at the time of the run, not at midnight. The first run takes
  the whole file. After a rotation the end of the rotated file is taken first
  if it is still uncompressed (`delaycompress`); otherwise the manifest notes
  a possible gap. Compressed files are skipped.

## Running the collector

### systemd timers (default)

`install.sh` enables `logs-collect.timer` (02:30) and `logs-retention.timer`
(04:30). To change a time: `sudo systemctl edit logs-collect.timer`, then

```ini
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:30:00
```

Run once by hand and look at the output:

```bash
sudo systemctl start logs-collect.service
```

```bash
journalctl -u logs-collect -e
```

### Plain ansible-playbook

```bash
cd /usr/local/share/logs/ansible
```

```bash
ansible-playbook -i /etc/logs/inventory.yml collect.yml
```

```bash
ansible-playbook -i /etc/logs/inventory.yml collect.yml -e logs_day=2025-01-31
```

```bash
ansible-playbook -i /etc/logs/inventory.yml retention.yml --check
```

### Semaphore

Install with `--no-timers` on the Semaphore host so that it has the mounts
and, if you want it there, the web UI. Set `LOGS_RW_OWNER=semaphore` (or
whichever user Semaphore runs as) in `/etc/logs/install.conf` so that user can
write to the read-write mount. Then in Semaphore:

1. **Repository**: this repository over HTTPS, branch `main` (or a release tag).
2. **Inventory**: your existing inventory.
3. **Variable group**: the `logs_*` variables you want to change as extra
   variables (JSON), for example
   `{"logs_targets": "linux", "logs_collect_localhost": true}`. Add
   `LOGS_SMTP_PASSWORD` as a secret environment variable if you use mail.
4. **Task templates**: one for `ansible/collect.yml`, one for
   `ansible/retention.yml`.
5. **Schedules**: collect once a day after midnight, retention an hour or two
   later.

The read-write mount must be writable by the user Semaphore runs as, and
`zstd` must be installed on that host. If Semaphore runs in a container, the
mount has to be passed into it.

## Retention

```
day is younger than logs_raw_days         raw/YYYY/MM/DD/...           viewable in the browser
day is older                              archive/YYYY/YYYY-MM-DD.tar.zst
archive older than logs_archive_days      deleted (if set)
archives larger than logs_archive_max_gb  oldest deleted first (if set)
manifests                                 kept forever
```

For every day older than `logs_raw_days` the retention run

1. packs the day with `tar | zstd -19 --long=25`,
2. checks it with `zstd -t` and compares the file list in the archive with the
   files on disk,
3. moves the archive into place,
4. deletes the raw directory.

If any step fails, the raw day stays and the run reports the error. An
interrupted run is finished by the next one.

**About `--long`.** zstd's plain `--long` means a 128 MiB window
(`--long=27`). Whoever decompresses such an archive needs that much memory,
which is more than the web UI's 64 MB limit. The default here is therefore
`--long=25` (32 MiB window): measured peak memory of the web UI while
extracting is about 52 MiB. If you prefer the larger window, set
`logs_zstd_window_log: 27`, `LOGS_ZSTD_MAX_WINDOW_MB=128` and raise
`MemoryMax` of `logs-webui.service` to about 192M
(`systemctl edit logs-webui`). Compression with level 19 itself needs a few
hundred MB of memory on the collector for a short time.

## Web UI

Open `http://127.0.0.1:8484/` on the host, or tunnel to it:
`ssh -L 8484:127.0.0.1:8484 <host>`.

- **Overview**: raw and archive size, free space on the share, collected size
  per day, ranking of hosts and services by bytes and lines (latest day, 7
  days, 30 days, all), growth per service (last 7 days against the 7 before),
  hosts with problems per day.
- **Browse**: day → host → source.
  - Raw days: view page by page, jump to the tail, filter by text, download.
  - Archived days: download a single file (decompressed on the fly) or the
    whole `.tar.zst`.
  - **Zip downloads** (raw and archived days): "Download all as zip" gives
    every host and source of the day in one zip. Tick sources (per file, or
    the box next to a host) and use "Download selected as zip" to get only
    those; "Download host as zip" gets one host. The zip is streamed while
    the files are read, so memory does not grow with its size, and it is
    compressed with fast deflate. Entries are named
    `<day>/<host>/<source>.log`; files that were selected but are missing
    are listed in `<day>/MISSING.txt`. For an archived day the `.tar.zst` is
    read once, in order, and only the selected files are written to the zip.
    An empty selection is refused, never treated as "everything". The
    checkboxes, the per-host links and the download work without
    JavaScript; the small script (`/static/select.js`) only adds "Select
    all/none", host toggles and a running size.
- **Filter**: case-insensitive text search in one file. It streams results,
  stops at `LOGS_FILTER_MAX_RESULTS` lines or after `LOGS_FILTER_TIMEOUT`, and
  then offers to continue from where it stopped.
- **Health**: `GET /healthz` returns JSON and status 200, or 503 when the data
  directory cannot be read. It needs no login.

The UI needs no JavaScript (one optional 50-line script helps with the
zip selection) and has no write or delete actions; only `GET` and `HEAD` are
answered. Statistics come from the manifests only. Log files are
never scanned for them.

Memory, measured on amd64 with a generated share (730 days, 15 hosts, one
1 GiB log file, one 600 MiB file inside an archive):

| Situation | Resident memory |
| --- | --- |
| Idle after start | 19 MiB |
| After loading overview and browse pages | 21 MiB |
| Downloading the 1 GiB raw file | 21 MiB |
| Filtering the whole 1 GiB file | 22 MiB |
| Extracting the 600 MiB file from the archive (peak) | 52 MiB |
| Zip of a raw day with a 1 GiB file (215 MiB zip) | 29 MiB |
| Zip of two files out of an archive (peak) | 53 MiB |
| Idle again | 17 MiB |

The same requests also pass inside a container limited to 64 MB without swap,
including a raw zip, an archive zip and a third zip running at the same time.
Reproduce with `tests/gen-testdata.py` and `tests/measure-ram.sh`.

The systemd unit sets `MemoryMax=64M`, `CPUQuota=50%`, `NoNewPrivileges`,
`ProtectSystem=strict`, an empty capability set and more; see
`systemd/logs-webui.service`.

A `Dockerfile` and `docker-compose.example.yml` exist for those who prefer a
container. The systemd install is the main path.

## Reading and restoring logs

Everything is plain files; you never need the web UI to get at your logs.

"Show me the logs of the container `authserver` on host `web01` from March
3rd, 2025":

In the web UI: **Browse** → 2025-03-03 → `web01` → `docker-authserver` →
**View** (or **Download from archive** if the day is already archived).

On the collector, if the day is still raw:

```bash
less /mnt/logs-ro/raw/2025/03/03/web01/docker-authserver.log
```

```bash
grep -i "login failed" /mnt/logs-ro/raw/2025/03/03/web01/docker-authserver.log
```

If the day is archived, list what is inside:

```bash
zstd -dc --long=27 /mnt/logs-ro/archive/2025/2025-03-03.tar.zst | tar -t
```

Print one file without unpacking the rest:

```bash
zstd -dc --long=27 /mnt/logs-ro/archive/2025/2025-03-03.tar.zst | tar -xO web01/docker-authserver.log | less
```

Restore the whole day to a directory of your choice:

```bash
mkdir -p /tmp/restore && zstd -dc --long=27 /mnt/logs-ro/archive/2025/2025-03-03.tar.zst | tar -x -C /tmp/restore
```

(`--long=27` on decompression only raises the allowed window; it works for
every archive this tool writes.)

The manifest of the day tells you what was collected and what failed:

```bash
python3 -m json.tool /mnt/logs-ro/manifests/2025/2025-03-03.json | less
```

Collect a missed or failed day again (journald and Docker still need to hold
that day):

```bash
ansible-playbook -i /etc/logs/inventory.yml collect.yml -e logs_day=2025-03-03
```

## Hosts without Ansible

**Machines that can run a shell script** (hypervisors, storage appliances):
copy `helpers/logs-push.sh` to the machine and run it from cron shortly after
midnight, before the collector runs. It writes the machine's own journal,
Docker logs and listed files for yesterday straight to the share:

```
15 0 * * * root LOGS_DEST=/mnt/logs LOGS_HOST=hypervisor01 /usr/local/sbin/logs-push.sh
```

List such hosts in `logs_push_hosts` so the manifest reports them when
nothing arrived.

**Devices that can only send syslog** (firewalls, switches): turn the
collector host into a syslog receiver once,

```bash
sudo ansible-playbook /usr/local/share/logs/ansible/syslog-receiver.yml -e '{"logs_syslog_allowed_senders": ["192.0.2.1"]}'
```

point the device at the collector (UDP or TCP 514), and set

```yaml
logs_syslog_spool: /var/spool/logs-syslog
logs_syslog_names: {"192.0.2.1": "firewall"}
```

The receiver writes one file per sender and day; the collector imports the
finished day as `raw/.../firewall/syslog.log`.

## Security notes

Logs routinely contain secrets and personal data: tokens in URLs, passwords
in failed commands, IP addresses, e-mail addresses, session IDs. Debug
logging makes this worse. Treat the archive like a backup of your
credentials.

- **Share**: allow only the two service users and your admins. Give the web
  UI's user read-only rights on the server, not just a read-only mount.
- **Web UI**: it listens on `127.0.0.1` by default. If you open it to the
  network, put it behind a reverse proxy that authenticates, or turn on
  `LOGS_BASIC_AUTH_FILE` (bcrypt htpasswd), or both. Basic auth without TLS
  sends the password in clear text; terminate TLS in the proxy.
- **Web UI isolation**: it runs as its own user without login, cannot write
  anywhere, refuses path traversal (names are validated and every file is
  opened through a directory handle that cannot be escaped, including by
  symlinks), and answers only `GET` and `HEAD`.
- **Collector**: needs root on the hosts (to read the journal and Docker).
  Protect its SSH key (`/var/lib/logs-collector/.ssh/`) accordingly.
- **Syslog receiver**: syslog is unauthenticated. Restrict senders with
  `logs_syslog_allowed_senders` and your firewall.
- **Credentials**: SMB passwords live only in `/etc/logs/install.conf` and the
  `/etc/logs/*.cred` files made from it (all mode 600, owner root).
  The SMTP password comes from the environment. Neither belongs in git.
- **Offsite copies and snapshots** of the share carry the same secrets.

Please report security problems privately through GitHub's "Report a
vulnerability" on this repository.

## Development

```bash
scripts/install-hooks.sh        # enable the pre-commit and pre-push hooks
```

```bash
cd webui && go test ./...       # web UI tests
```

```bash
tests/integration.sh            # collector and retention, end to end, generated data
```

```bash
scripts/build-release.sh v0.0.0-test && tests/installer-test.sh ubuntu:24.04
```

Rules for this repository:

- No real addresses, hostnames, domains, users or paths from anyone's setup.
  Examples use `192.0.2.0/24`, `198.51.100.0/24`, `example.com` and the user
  `logcollector`.
- No sample logs from real systems. Tests generate their data.
- Site settings are variables with safe defaults, documented in the example
  files. The real files are git-ignored.

The hooks enforce this: gitleaks scans for secrets, `scripts/check-public.sh`
rejects private IP ranges, site files and log files, and
`scripts/check-denylist.sh` rejects every string listed in your git-ignored
`private-denylist.txt` (format: `private-denylist.example.txt`). The same
gitleaks and public checks run in CI.

Releases: push a tag `vX.Y.Z`. The release workflow builds the amd64 and
arm64 binaries, the bundle and `SHA256SUMS`.

## License

[MIT](LICENSE)
