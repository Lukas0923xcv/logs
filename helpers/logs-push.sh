#!/bin/sh
# logs-push.sh - push this machine's own logs of one day to the log archive.
#
# For machines the collector cannot reach with Ansible (hypervisors, storage
# appliances). Run it from cron on that machine, after midnight and before
# the collector runs, for example:
#
#   15 0 * * * root LOGS_DEST=/mnt/logs LOGS_HOST=hypervisor01 /usr/local/sbin/logs-push.sh
#
# LOGS_DEST is the root of the log share as seen from this machine (a mount
# of the share, or the dataset path on the storage appliance itself).
#
# Settings (environment variables):
#   LOGS_DEST         required  root of the share (contains raw/)
#   LOGS_HOST         optional  name in the archive (default: short hostname)
#   LOGS_DAY          optional  YYYY-MM-DD (default: yesterday)
#   LOGS_JOURNAL      optional  auto | yes | no   (default: auto)
#   LOGS_DOCKER       optional  auto | yes | no   (default: auto)
#   LOGS_EXTRA_FILES  optional  space separated paths or globs; files changed
#                               on or after that day are copied whole
#   LOGS_REQUIRE_MOUNT optional yes | no (default: no). With yes the script
#                               refuses to write unless LOGS_DEST is a mount point.
#
# Needs GNU date (Linux). Devices without it, such as BSD based firewalls,
# should send syslog to the rsyslog receiver instead.
set -eu

die() { echo "logs-push: $*" >&2; exit 1; }

[ -n "${LOGS_DEST:-}" ] || die "LOGS_DEST is not set"
[ -d "$LOGS_DEST" ] || die "LOGS_DEST ($LOGS_DEST) is not a directory"
if [ "${LOGS_REQUIRE_MOUNT:-no}" = yes ]; then
    mountpoint -q "$LOGS_DEST" || die "$LOGS_DEST is not mounted"
fi

host=${LOGS_HOST:-$(hostname -s)}
host=$(printf '%s' "$host" | tr -c 'A-Za-z0-9._-' '_')
day=${LOGS_DAY:-$(date -d yesterday +%F)}
day=$(date -d "$day" +%F) || die "invalid LOGS_DAY"
since=$(date -d "$day 00:00:00" +%s)
until=$(( $(date -d "$day 00:00:00 +1 day" +%s) - 1 ))
[ "$until" -lt "$(date +%s)" ] || die "$day is not over yet"

day_dir="$LOGS_DEST/raw/$(printf '%s' "$day" | tr - /)"
stage="$day_dir/.$host.partial"
final="$day_dir/$host"
umask 027
rm -rf "$stage"
mkdir -p "$stage"
trap 'rm -rf "$stage"' EXIT

use() { # use <setting> <command>: should this source be collected?
    case "$1" in
        no) return 1 ;;
        yes) command -v "$2" >/dev/null 2>&1 || die "$2 not found"; return 0 ;;
        *) command -v "$2" >/dev/null 2>&1 ;;
    esac
}

if use "${LOGS_JOURNAL:-auto}" journalctl; then
    journalctl --no-pager --quiet --output short-iso-precise \
        --since "@$since" --until "@$until.999999" > "$stage/journald.log"
fi

if use "${LOGS_DOCKER:-auto}" docker; then
    docker ps --all --format '{{.Names}}' | while IFS= read -r name; do
        [ -n "$name" ] || continue
        out="$stage/docker-$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_').log"
        docker logs --timestamps --since "$since" --until "$until.999999999" "$name" > "$out" 2>&1 || true
        [ -s "$out" ] || rm -f "$out"
    done
fi

# shellcheck disable=SC2086  # globs in LOGS_EXTRA_FILES are meant to expand
for path in ${LOGS_EXTRA_FILES:-}; do
    [ -f "$path" ] || continue
    [ "$(stat -c %Y "$path")" -ge "$since" ] || continue
    name=$(printf '%s' "${path%.log}" | tr -c 'A-Za-z0-9._-' '_' | sed 's/^[._-]*//')
    cp -- "$path" "$stage/file-$name.log"
done

rm -rf "$final"
mv "$stage" "$final"
trap - EXIT
echo "logs-push: wrote $final"
