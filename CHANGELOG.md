# Changelog

All notable changes are listed here. Versions follow
[Semantic Versioning](https://semver.org/). New or changed configuration
variables are listed under "Configuration" for each version, so you can
compare your files in `/etc/logs/` after an upgrade.

## [0.1.1] - 2026-11-12

### Changed

- **SMB mounts are configured in one file, `/etc/logs/install.conf`.** The
  first install creates it from the new `install.example.conf` (mode 0600,
  owner root) and never overwrites it. Running the installer again, or
  `sudo logs-install --apply`, writes `/etc/logs/smb-rw.cred` and
  `smb-ro.cred`, replaces the `# logs-archive` lines in `/etc/fstab` and
  remounts. The file is parsed, never sourced: only the known keys are
  accepted, optional surrounding quotes are removed, and unknown keys,
  duplicates and malformed lines stop the run with a message that names the
  line (and never shows a value). A bad file is detected before anything is
  changed. Passwords may contain any character except a line break.
- `install.sh` is installed as `/usr/local/sbin/logs-install`. New option
  `--apply` applies `install.conf` only (no download, no reinstall) and exits
  with 1 if a mount failed.
- `--no-mount` now means "do not touch `install.conf` and the mounts".
  `--non-interactive` still works but does nothing: the installer never asks.
- The release bundle now contains `install.sh` and `install.example.conf`.
- `/etc/fstab` is only backed up when the lines really change.

### Removed

- The interactive mount questions and the `LOGS_SMB_*`, `LOGS_RW_OWNER`,
  `LOGS_RW_MOUNT` and `LOGS_RO_MOUNT` environment variables of the installer.
  Put the values in `/etc/logs/install.conf` instead.

### Fixed

- `install.sh` failed on real systems with `--version vX.Y.Z` and without it:
  `/etc/os-release` overwrote the script's `VERSION` variable, so the download
  URL was built from the distribution version. The installer test now also
  covers the real download path and a tampered download.
- The question "Set up the SMB mounts?" always read an empty answer (a `local`
  variable shadowed the caller's variable). The questions are gone.

### Configuration

New file `/etc/logs/install.conf` with the keys `LOGS_SMB_SHARE`,
`LOGS_SMB_DOMAIN`, `LOGS_SMB_RW_USER`, `LOGS_SMB_RW_PASSWORD`,
`LOGS_SMB_RO_USER`, `LOGS_SMB_RO_PASSWORD`, `LOGS_RW_OWNER` (default
`logs-collector`), `LOGS_RW_MOUNT` (default `/mnt/logs-rw`) and
`LOGS_RO_MOUNT` (default `/mnt/logs-ro`). No collector or web UI variables
changed.

Upgrading from 0.1.0: a first run creates `install.conf`; copy your share,
users and passwords into it and run `sudo logs-install --apply`.

## [0.1.0] - 2026-11-12

First release.

### Added

- Collector playbook `ansible/collect.yml`: exact daily window for journald
  and `docker logs`, offset-tracked extra log files, per-day manifest,
  unreachable hosts recorded without stopping the run, idempotent re-runs,
  optional mail on failure.
- Retention playbook `ansible/retention.yml`: raw days to verified
  `.tar.zst` archives, optional expiry by age and total size, manifests kept.
- Web UI `logs-webui`: statistics from manifests, browse, paged viewer,
  streamed text filter, raw downloads, single-file extraction from archives,
  `/healthz`, optional basic auth. Read-only, no JavaScript.
- `install.sh` for Ubuntu Server 24.04 and 26.04: install, upgrade in place,
  `--uninstall`, `--purge`, optional SMB mounts.
- Helper `helpers/logs-push.sh` and the `rsyslog_receiver` role for machines
  that Ansible cannot reach.
- Release binaries for amd64 and arm64 with `SHA256SUMS`.
- gitleaks and public-repository checks as git hooks and in CI.

### Configuration

Web UI (`/etc/logs/webui.env`): `LOGS_DATA_DIR`, `LOGS_LISTEN`, `LOGS_TITLE`,
`LOGS_BASIC_AUTH_FILE`, `LOGS_INDEX_REFRESH`, `LOGS_FILTER_MAX_RESULTS`,
`LOGS_FILTER_TIMEOUT`, `LOGS_PAGE_BYTES`, `LOGS_ARCHIVE_STREAMS`,
`LOGS_ZSTD_MAX_WINDOW_MB`.

Collector (`/etc/logs/group_vars/all.yml`): `logs_root`, `logs_root_fstypes`,
`logs_targets`, `logs_collect_localhost`, `logs_localhost_name`,
`logs_localhost_become`, `logs_day`, `logs_timezone`, `logs_force`,
`logs_journal`, `logs_journal_format`, `logs_docker`, `logs_extra_files`,
`logs_extra_files_by_host`, `logs_count_levels`, `logs_remote_tmp`,
`logs_remote_state_dir`, `logs_push_hosts`, `logs_syslog_spool`,
`logs_syslog_names`, `logs_syslog_keep_days`, `logs_raw_days`,
`logs_archive_days`, `logs_archive_max_gb`, `logs_zstd_level`,
`logs_zstd_window_log`, `logs_zstd_threads`, `logs_fail_on_host_failure`,
`logs_notify_on_failure`, `logs_smtp_host`, `logs_smtp_port`,
`logs_smtp_security`, `logs_smtp_user`, `logs_smtp_from`, `logs_smtp_to`.
Environment: `LOGS_SMTP_PASSWORD`.

Syslog receiver role: `logs_syslog_spool`, `logs_syslog_udp_port`,
`logs_syslog_tcp_port`, `logs_syslog_listen_address`,
`logs_syslog_allowed_senders`, `logs_syslog_spool_group`,
`logs_syslog_spool_max_age`.

[0.1.1]: https://github.com/Lukas0923xcv/logs/releases/tag/v0.1.1
[0.1.0]: https://github.com/Lukas0923xcv/logs/releases/tag/v0.1.0
