#!/usr/bin/env bash
# Test install.sh in a fresh Ubuntu container that runs systemd:
# install, second run (upgrade, config kept), --uninstall, --uninstall --purge.
#
#   scripts/build-release.sh v0.0.0-test
#   tests/installer-test.sh ubuntu:24.04
#
# Needs Docker with permission to run privileged containers and a host with
# cgroup v2 (systemd 258 and newer, as in Ubuntu 26.04, do not start on cgroup v1).
# On other hosts, NO_SYSTEMD=1 tests everything except the running services:
# the web UI and the playbooks are then started by hand inside the container.
set -euo pipefail
nosd=${NO_SYSTEMD:-}

image=${1:-ubuntu:24.04}
repo=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$repo/dist/SHA256SUMS" ] || { echo "run scripts/build-release.sh first" >&2; exit 1; }
name="logs-installer-test-$$"
tag="logs-installer-test:$(echo "$image" | tr -c 'a-z0-9.\n' '-')"
fail() { echo "FAIL: $*" >&2; docker exec "$name" journalctl -u logs-webui --no-pager -n 30 2>/dev/null || true; exit 1; }
ok() { echo "ok: $*"; }
inc() { docker exec "$name" "$@"; }

docker build -q -t "$tag" - >/dev/null <<DOCKERFILE
FROM $image
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends systemd systemd-sysv dbus sudo >/dev/null
CMD ["/sbin/init"]
DOCKERFILE
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
if [ -n "$nosd" ]; then
    docker run -d --name "$name" -v "$repo:/src:ro" "$tag" sleep infinity >/dev/null
    state="not used"
else
    docker run -d --name "$name" --privileged --cgroupns=host --tmpfs /run --tmpfs /run/lock \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw -v "$repo:/src:ro" "$tag" >/dev/null
    for _ in $(seq 60); do
        state=$(inc systemctl is-system-running 2>/dev/null || true)
        case "$state" in running | degraded) break ;; esac
        sleep 1
    done
    case "${state:-}" in running | degraded) ;; *) echo "FAIL: systemd did not start in the container (cgroup v1 host? try NO_SYSTEMD=1)" >&2; exit 1 ;; esac
fi
echo "container $image is up (systemd: ${state:-unknown})"
# Start the web UI the way the unit would, when there is no systemd to do it.
webui_by_hand() {
    [ -n "$nosd" ] || return 0
    inc pkill -x logs-webui 2>/dev/null || true
    docker exec -d "$name" runuser -u logs-web -- sh -c 'set -a; . /etc/logs/webui.env; exec /usr/local/bin/logs-webui'
}
unit_run() { # unit_run <unit>: start a oneshot unit, or its command by hand
    if [ -z "$nosd" ]; then inc systemctl start "$1.service"; return; fi
    inc runuser -u logs-collector -- sh -c "cd /usr/local/share/logs/ansible && HOME=/var/lib/logs-collector $(sed -n 's/^ExecStart=//p' "$repo/systemd/$1.service")"
}
run_installer() { inc env LOGS_DIST_DIR=/src/dist bash /src/install.sh --non-interactive "$@"; }

# --- 1. fresh install ---------------------------------------------------------
run_installer --no-mount > /tmp/install1.log 2>&1 || { tail -30 /tmp/install1.log; fail "first install failed"; }
grep -q "Installed the log archive" /tmp/install1.log || fail "no install summary"
if [ -z "$nosd" ]; then
    [ "$(inc systemctl is-active logs-webui)" = active ] || fail "logs-webui is not active"
    [ "$(inc systemctl is-enabled logs-collect.timer)" = enabled ] || fail "collect timer not enabled"
    [ "$(inc systemctl is-enabled logs-retention.timer)" = enabled ] || fail "retention timer not enabled"
    [ "$(inc systemctl show logs-webui -p MemoryMax --value)" = 67108864 ] || fail "MemoryMax is not 64M"
    [ "$(inc systemctl show logs-webui -p User --value)" = logs-web ] || fail "web UI does not run as logs-web"
fi
inc test -f /etc/systemd/system/logs-webui.service || fail "unit file missing"
webui_by_hand
for _ in $(seq 20); do inc curl -fs http://127.0.0.1:8484/healthz >/dev/null 2>&1 && break; sleep 0.5; done
inc curl -fs http://127.0.0.1:8484/healthz | grep -q '"status":"ok"' || fail "healthz not ok"
inc curl -fs http://127.0.0.1:8484/ | grep -q "read-only" || fail "dashboard not served"
[ "$(inc stat -c %a /etc/logs/webui.env)" = 640 ] || fail "webui.env mode"
inc sh -c 'getent passwd logs-web | grep -q nologin' || fail "logs-web can log in"
ok "fresh install: service active, health ok, limits applied"

# --- 2. second run upgrades in place and keeps the configuration -------------
inc sh -c 'echo "LOGS_TITLE=kept-by-upgrade" >> /etc/logs/webui.env; echo "# my hosts" >> /etc/logs/inventory.yml'
before=$(inc sha256sum /etc/logs/webui.env /etc/logs/inventory.yml /etc/logs/group_vars/all.yml)
key=$(inc cat /var/lib/logs-collector/.ssh/id_ed25519.pub)
run_installer --no-mount > /tmp/install2.log 2>&1 || { tail -30 /tmp/install2.log; fail "second run failed"; }
grep -q "Upgraded the log archive" /tmp/install2.log || fail "second run did not report an upgrade"
[ "$before" = "$(inc sha256sum /etc/logs/webui.env /etc/logs/inventory.yml /etc/logs/group_vars/all.yml)" ] || fail "configuration changed"
[ "$key" = "$(inc cat /var/lib/logs-collector/.ssh/id_ed25519.pub)" ] || fail "SSH key was replaced"
[ -n "$nosd" ] || [ "$(inc systemctl is-active logs-webui)" = active ] || fail "logs-webui not active after upgrade"
webui_by_hand
for _ in $(seq 20); do inc curl -fs http://127.0.0.1:8484/healthz >/dev/null 2>&1 && break; sleep 0.5; done
inc curl -fs http://127.0.0.1:8484/ | grep -q "kept-by-upgrade" || fail "service does not use the kept config"
ok "second run: upgraded in place, configuration kept"

# --- 3. the collector and retention units really run -------------------------
inc sh -c 'mkdir -p /mnt/logs-rw && chown logs-collector: /mnt/logs-rw && echo "logs_root_fstypes: []" >> /etc/logs/group_vars/all.yml'
unit_run logs-collect || { inc journalctl -u logs-collect --no-pager -n 60 | grep -B3 -A6 -E "fatal|ERROR"; fail "logs-collect.service failed"; }
inc sh -c 'ls /mnt/logs-rw/manifests/*/*.json >/dev/null' || fail "collector wrote no manifest"
unit_run logs-retention || { inc journalctl -u logs-retention --no-pager -n 40; fail "logs-retention.service failed"; }
ok "collector and retention services run with the distribution's ansible-core ($(inc ansible --version | head -1))"

# --- 4. mounts: credentials file is protected, password is not leaked ---------
inc env LOGS_DIST_DIR=/src/dist LOGS_SMB_SHARE=//192.0.2.10/logs LOGS_SMB_RW_USER=logcollector \
    LOGS_SMB_RW_PASSWORD=generated-pw-1 LOGS_SMB_RO_USER=logviewer LOGS_SMB_RO_PASSWORD=generated-pw-2 \
    bash /src/install.sh --non-interactive > /tmp/install3.log 2>&1 || { tail -30 /tmp/install3.log; fail "mount setup run failed"; }
! grep -q "generated-pw" /tmp/install3.log || fail "password appears in the installer output"
[ "$(inc stat -c '%a %U' /etc/logs/smb-rw.cred)" = "600 root" ] || fail "credentials file is not 600 root"
[ "$(inc grep -c 'logs-archive' /etc/fstab)" = 2 ] || fail "expected two fstab entries"
inc grep -q '_netdev,nofail' /etc/fstab || fail "fstab options missing"
inc grep 'logs-ro' /etc/fstab | grep -q ' cifs ro,' || fail "read-only mount is not ro"
! inc grep -q "generated-pw" /etc/fstab || fail "password in fstab"
run_installer > /tmp/install4.log 2>&1 || fail "run after mount setup failed"
[ "$(inc grep -c 'logs-archive' /etc/fstab)" = 2 ] || fail "fstab entries duplicated or lost"
ok "mount setup: fstab entries, credentials 600, no password in output"

# --- 5. uninstall keeps configuration; purge removes it ----------------------
run_installer --uninstall > /tmp/uninstall.log 2>&1 || fail "uninstall failed"
! inc test -e /usr/local/bin/logs-webui || fail "binary still there"
! inc test -e /etc/systemd/system/logs-webui.service || fail "unit still there"
inc test -f /etc/logs/webui.env || fail "uninstall removed the configuration"
inc test -d /mnt/logs-rw/manifests || fail "uninstall touched the logs"
[ -n "$nosd" ] || [ "$(inc systemctl is-active logs-webui || true)" != active ] || fail "service still running"
ok "uninstall: binary and units removed, configuration and logs kept"

run_installer --uninstall --purge > /tmp/purge.log 2>&1 || fail "purge failed"
! inc test -e /etc/logs || fail "purge left /etc/logs"
! inc grep -q 'logs-archive' /etc/fstab || fail "purge left fstab entries"
! inc id logs-web >/dev/null 2>&1 || fail "purge left the user"
inc test -d /mnt/logs-rw/manifests || fail "purge must never delete logs"
ok "purge: configuration, credentials, fstab entries and users removed; logs untouched"
echo "INSTALLER TEST PASSED on $image"
