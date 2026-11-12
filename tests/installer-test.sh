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
# Write /etc/logs/install.conf from stdin (the file keeps its owner and mode).
put_conf() { docker exec -i "$name" sh -c 'cat > /etc/logs/install.conf'; }
# Apply the file with the installed logs-install; output goes to /tmp/apply.log.
apply() { docker exec "$name" /usr/local/sbin/logs-install --apply > /tmp/apply.log 2>&1; }
fstab_hash() { inc sh -c 'sha256sum < /etc/fstab'; }

# --- 1. fresh install ---------------------------------------------------------
run_installer > /tmp/install1.log 2>&1 || { tail -30 /tmp/install1.log; fail "first install failed"; }
grep -q "Installed the log archive" /tmp/install1.log || fail "no install summary"
[ "$(inc stat -c '%a %U:%G' /etc/logs/install.conf)" = "600 root:root" ] || fail "install.conf is not mode 600, owner root"
inc cmp /usr/local/sbin/logs-install /src/install.sh || fail "logs-install is not the installer"
[ "$(inc stat -c '%a' /usr/local/sbin/logs-install)" = 755 ] || fail "logs-install is not executable"
grep -q "Edit /etc/logs/install.conf, then run: sudo logs-install" /tmp/install1.log || fail "summary does not say how to configure the mounts"
! inc grep -q 'logs-archive' /etc/fstab || fail "fstab was changed although LOGS_SMB_SHARE is empty"
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
ok "fresh install: service active, install.conf created (600 root), logs-install installed, no mounts without a share"

# --- 1b. the real download path (URL building, SHA256SUMS) against a local server
# This path once broke because /etc/os-release overwrote the version variable.
inc sh -c 'rm -rf /srv/rel && mkdir -p /srv/rel/download/v0.0.0-test /srv/rel/latest && cp /src/dist/* /srv/rel/download/v0.0.0-test/ && cp -r /srv/rel/download/v0.0.0-test /srv/rel/latest/download'
docker exec -d "$name" python3 -m http.server 8099 --directory /srv/rel >/dev/null 2>&1 || true
inc sh -c 'command -v python3 >/dev/null || { apt-get install -y -qq python3 >/dev/null 2>&1; }'
docker exec -d "$name" python3 -m http.server 8099 --directory /srv/rel >/dev/null 2>&1 || true
for _ in $(seq 20); do inc curl -fs http://127.0.0.1:8099/latest/download/SHA256SUMS >/dev/null 2>&1 && break; sleep 0.5; done
inc env LOGS_RELEASE_BASE=http://127.0.0.1:8099 bash /src/install.sh --non-interactive --no-mount --version v0.0.0-test > /tmp/install1b.log 2>&1 \
    || { tail -20 /tmp/install1b.log; fail "install with --version over the download path failed"; }
grep -q "download/v0.0.0-test" /tmp/install1b.log || grep -q "verified against SHA256SUMS" /tmp/install1b.log || fail "download path not used"
inc env LOGS_RELEASE_BASE=http://127.0.0.1:8099 bash /src/install.sh --non-interactive --no-mount > /tmp/install1c.log 2>&1 \
    || { tail -20 /tmp/install1c.log; fail "install of the latest release over the download path failed"; }
inc sh -c 'cd /srv/rel/latest/download && echo tampered >> logs-bundle.tar.gz'
! inc env LOGS_RELEASE_BASE=http://127.0.0.1:8099 bash /src/install.sh --non-interactive --no-mount > /tmp/install1d.log 2>&1 || fail "a tampered download was accepted"
grep -q "checksum of logs-bundle.tar.gz does not match" /tmp/install1d.log || fail "tampering not reported"
inc sh -c 'cp /src/dist/logs-bundle.tar.gz /srv/rel/latest/download/'
ok "download path: --version and latest work, tampered file is refused"

# --- 2. second run upgrades in place and keeps the configuration -------------
inc sh -c 'echo "LOGS_TITLE=kept-by-upgrade" >> /etc/logs/webui.env; echo "# my hosts" >> /etc/logs/inventory.yml'
before=$(inc sha256sum /etc/logs/webui.env /etc/logs/inventory.yml /etc/logs/group_vars/all.yml /etc/logs/install.conf)
key=$(inc cat /var/lib/logs-collector/.ssh/id_ed25519.pub)
run_installer > /tmp/install2.log 2>&1 || { tail -30 /tmp/install2.log; fail "second run failed"; }
grep -q "Upgraded the log archive" /tmp/install2.log || fail "second run did not report an upgrade"
[ "$before" = "$(inc sha256sum /etc/logs/webui.env /etc/logs/inventory.yml /etc/logs/group_vars/all.yml /etc/logs/install.conf)" ] || fail "configuration (or install.conf) was overwritten"
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

# --- 4. install.conf: parsing, applying, special characters, rejections ------
inc useradd --system --no-create-home semaphore   # an owner like Semaphore's user
valid_conf() {
    put_conf <<'CONF'
# generated test values (documentation address, made-up users)
LOGS_SMB_SHARE=//192.0.2.10/logs
LOGS_SMB_DOMAIN=EXAMPLE
LOGS_SMB_RW_USER=logcollector
LOGS_SMB_RW_PASSWORD=p4 ss"w'o$rd #1 \ `id` end
LOGS_SMB_RO_USER=logviewer
LOGS_SMB_RO_PASSWORD="quoted pw $HOME"
CONF
}
valid_conf
if apply; then rc=0; else rc=$?; fi    # exit 1 is fine: there is no SMB server to mount
[ "$rc" -le 1 ] || { cat /tmp/apply.log; fail "apply crashed (exit $rc)"; }
grep -q "read-write      user logcollector, /mnt/logs-rw, owner logs-collector" /tmp/apply.log || { cat /tmp/apply.log; fail "report lacks the read-write line"; }
grep -q "read-only       user logviewer, /mnt/logs-ro" /tmp/apply.log || fail "report lacks the read-only line"
! grep -q -E 'Installing packages|Getting the release files' /tmp/apply.log || fail "--apply downloaded or installed something"
! grep -q -E 'p4 ss|quoted pw' /tmp/apply.log || fail "a password appears in the output"
expected_fstab='//192.0.2.10/logs /mnt/logs-rw cifs credentials=/etc/logs/smb-rw.cred,uid=logs-collector,gid=logs-collector,file_mode=0640,dir_mode=0750,_netdev,nofail 0 0 # logs-archive
//192.0.2.10/logs /mnt/logs-ro cifs ro,credentials=/etc/logs/smb-ro.cred,uid=logs-web,gid=logs-web,file_mode=0440,dir_mode=0550,_netdev,nofail 0 0 # logs-archive'
[ "$(inc grep 'logs-archive' /etc/fstab)" = "$expected_fstab" ] || { inc grep 'logs-archive' /etc/fstab; fail "fstab lines are wrong"; }
! inc grep -q -E 'p4 ss|quoted pw' /etc/fstab || fail "a password is in fstab"
expected_rw=$(cat <<'CRED'
username=logcollector
password=p4 ss"w'o$rd #1 \ `id` end
domain=EXAMPLE
CRED
)
[ "$(inc cat /etc/logs/smb-rw.cred)" = "$expected_rw" ] || fail "rw credentials differ: special characters were changed"
expected_ro=$(cat <<'CRED'
username=logviewer
password=quoted pw $HOME
domain=EXAMPLE
CRED
)
[ "$(inc cat /etc/logs/smb-ro.cred)" = "$expected_ro" ] || fail "ro credentials differ"
for f in smb-rw.cred smb-ro.cred; do
    [ "$(inc stat -c '%a %U:%G' /etc/logs/$f)" = "600 root:root" ] || fail "$f is not 600 root:root"
done
ok "apply: fstab lines and credential files exact; password with spaces, quotes, \$, #, backslash, backtick survives; nothing leaked"

# applying again changes nothing and makes no new fstab backup
backups=$(inc sh -c 'ls /etc/fstab.logs-backup.* 2>/dev/null | wc -l')
apply || true
[ "$(inc grep -c 'logs-archive' /etc/fstab)" = 2 ] || fail "second apply duplicated or lost fstab lines"
[ "$backups" = "$(inc sh -c 'ls /etc/fstab.logs-backup.* 2>/dev/null | wc -l')" ] || fail "an unchanged apply made a new fstab backup"

# a changed file replaces the lines: other owner, other mount point, no read-only user
put_conf <<'CONF'
LOGS_SMB_SHARE=//192.0.2.10/logs
LOGS_SMB_RW_USER=logcollector
LOGS_SMB_RW_PASSWORD='  keep my spaces  '
LOGS_RW_OWNER=semaphore
LOGS_RW_MOUNT=/mnt/logs-data
CONF
apply || true
[ "$(inc grep -c 'logs-archive' /etc/fstab)" = 1 ] || fail "changed file did not replace the fstab lines"
inc grep 'logs-archive' /etc/fstab | grep -q '^//192.0.2.10/logs /mnt/logs-data cifs credentials=/etc/logs/smb-rw.cred,uid=semaphore,gid=semaphore,' || fail "owner or mount point not applied"
[ "$(inc cat /etc/logs/smb-rw.cred)" = "$(printf 'username=logcollector\npassword=  keep my spaces  ')" ] || fail "quoted password with spaces not kept exactly"
! inc test -e /etc/logs/smb-ro.cred || fail "stale read-only credentials file was not removed"
ok "apply: a changed file replaces fstab lines and credentials; unchanged apply is a no-op"

# permissions are repaired
inc chmod 644 /etc/logs/install.conf
apply || true
grep -q "fixed the permissions" /tmp/apply.log || fail "loose permissions not reported"
[ "$(inc stat -c '%a %U:%G' /etc/logs/install.conf)" = "600 root:root" ] || fail "permissions not repaired"

# rejections: nothing may change, the message names the line, no value is shown
reject() { # reject <description> <expected text in the message>
    h=$(fstab_hash)
    if apply; then cat /tmp/apply.log; fail "accepted: $1"; fi
    grep -q -- "$2" /tmp/apply.log || { cat /tmp/apply.log; fail "message for '$1' lacks: $2"; }
    [ "$h" = "$(fstab_hash)" ] || fail "fstab changed although the file was rejected ($1)"
    ! grep -q -E 'hunter2|secretvalue' /tmp/apply.log || fail "a value was printed ($1)"
}
printf 'LOGS_SMB_SHARE=//192.0.2.10/logs\nLOGS_SMB_SHAER=x\n' | put_conf;  reject "unknown key" "line 2: unknown key LOGS_SMB_SHAER"
printf '# ok\nthis is hunter2 and not a setting\n' | put_conf;                reject "malformed line" "line 2: not a KEY=value"
printf 'LOGS_SMB_SHARE = //192.0.2.10/logs\n' | put_conf;                    reject "spaces around =" "line 1: malformed key"
printf 'secretvalue=1\n' | put_conf;                                        reject "unknown free-form key" "line 1: unknown key"
printf 'LOGS_SMB_SHARE=//a/b\nLOGS_SMB_SHARE=//c/d\n' | put_conf;            reject "duplicate key" "line 2: LOGS_SMB_SHARE is set twice"
printf 'LOGS_SMB_SHARE=//192.0.2.10/logs\r\n' | put_conf;                    reject "CRLF" "Windows line endings"
printf 'LOGS_SMB_SHARE=192.0.2.10/logs\n' | put_conf;                        reject "share without //" "must look like //server/share"
printf 'LOGS_SMB_SHARE=//192.0.2.10/my logs\n' | put_conf;                   reject "space in share" "must not contain spaces"
printf 'LOGS_SMB_SHARE=//192.0.2.10/logs\nLOGS_RW_MOUNT=relative/path\n' | put_conf; reject "relative mount path" "absolute path"
printf 'LOGS_SMB_SHARE=//192.0.2.10/logs\nLOGS_RW_MOUNT=/mnt/x\nLOGS_RO_MOUNT=/mnt/x\n' | put_conf; reject "same mount twice" "must differ"
# a full installer run refuses a bad file before it changes anything
printf 'LOGS_NOPE=1\n' | put_conf
if run_installer > /tmp/install-bad.log 2>&1; then fail "installer accepted a bad install.conf"; fi
grep -q "line 1: unknown key LOGS_NOPE" /tmp/install-bad.log || fail "installer message does not name the line"
! grep -q "Installing packages" /tmp/install-bad.log || fail "installer started changing the system before checking install.conf"
ok "rejections: unknown key, malformed line, duplicates, CRLF, bad paths; message names the line, nothing changes, no value printed"

# missing pieces skip that mount with a reason instead of failing
printf 'LOGS_SMB_SHARE=//192.0.2.10/logs\nLOGS_SMB_RW_USER=logcollector\nLOGS_SMB_RO_USER=logviewer\nLOGS_SMB_RO_PASSWORD=x\nLOGS_RW_OWNER=nobody-here\n' | put_conf
apply || true
grep -q "skipped: LOGS_SMB_RW_PASSWORD is empty" /tmp/apply.log || fail "missing password not reported"
printf 'LOGS_SMB_SHARE=//192.0.2.10/logs\nLOGS_SMB_RW_USER=logcollector\nLOGS_SMB_RW_PASSWORD=x\nLOGS_RW_OWNER=nobody-here\n' | put_conf
apply || true
grep -q "skipped: the local user nobody-here does not exist" /tmp/apply.log || fail "missing owner not reported"
! inc grep -q 'logs-archive' /etc/fstab || fail "a skipped mount got an fstab line"

# empty share: nothing is touched and the summary says what to do
valid_conf; apply || true
h=$(fstab_hash)
printf 'LOGS_SMB_SHARE=\n' | put_conf
apply || fail "empty share should not be an error"
grep -q "nothing was changed" /tmp/apply.log || fail "empty share not explained"
[ "$h" = "$(fstab_hash)" ] || fail "empty share changed fstab"
run_installer > /tmp/install-empty.log 2>&1 || fail "installer with an empty install.conf failed"
grep -q "Edit /etc/logs/install.conf, then run: sudo logs-install" /tmp/install-empty.log || fail "summary lacks the hint"
ok "skipped mounts are explained; an empty share touches nothing and the summary says what to do"

# a full upgrade run applies the filled-in file too, without duplicating lines
valid_conf
run_installer > /tmp/install4.log 2>&1 || { tail -30 /tmp/install4.log; fail "upgrade run with a filled-in install.conf failed"; }
! grep -q -E 'p4 ss|quoted pw' /tmp/install4.log || fail "installer output shows a password"
[ "$(inc grep 'logs-archive' /etc/fstab)" = "$expected_fstab" ] || fail "upgrade run did not apply install.conf"
grep -q "SMB share       //192.0.2.10/logs  (domain EXAMPLE)" /tmp/install4.log || fail "summary lacks the share"
ok "upgrade run applies install.conf (summary shows share, users, owner and mount result, never a password)"

# --- 5. uninstall keeps configuration; purge removes it ----------------------
run_installer --uninstall > /tmp/uninstall.log 2>&1 || fail "uninstall failed"
! inc test -e /usr/local/bin/logs-webui || fail "binary still there"
! inc test -e /etc/systemd/system/logs-webui.service || fail "unit still there"
inc test -f /etc/logs/webui.env || fail "uninstall removed the configuration"
inc test -f /etc/logs/install.conf || fail "uninstall removed install.conf"
! inc test -e /usr/local/sbin/logs-install || fail "logs-install still there"
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
