#!/usr/bin/env bash
# install.sh - install, upgrade or remove the log archive (web UI + collector).
#
#   curl -fsSL https://raw.githubusercontent.com/Lukas0923xcv/logs/main/install.sh | sudo bash
#
# Safer: download it, read it, then run it:
#
#   curl -fsSLO https://raw.githubusercontent.com/Lukas0923xcv/logs/main/install.sh
#   less install.sh
#   sudo bash install.sh
#
# Run with --help for all options. Running it again upgrades in place and
# keeps your configuration.
set -euo pipefail

REPO="Lukas0923xcv/logs"
BIN=/usr/local/bin/logs-webui
SHARE_DIR=/usr/local/share/logs
ETC_DIR=/etc/logs
UNIT_DIR=/etc/systemd/system
WEB_USER=logs-web
COLLECT_USER=logs-collector
COLLECT_HOME=/var/lib/logs-collector
FSTAB_TAG="# logs-archive"
UNITS="logs-webui.service logs-collect.service logs-collect.timer logs-retention.service logs-retention.timer"

WANT_VERSION=""  # not VERSION: /etc/os-release defines that name too
WEBUI=1
TIMERS=1
MOUNT=1
INTERACTIVE=1
UNINSTALL=0
PURGE=0

usage() {
    cat <<'EOF'
Usage: sudo bash install.sh [options]

  --version vX.Y.Z    install this release instead of the latest one
  --no-webui          do not install the web UI service
  --no-timers         do not install the collector and retention timers
                      (use this when the collector runs from Semaphore)
  --no-mount          do not offer to set up the SMB mounts
  --non-interactive   never ask; take the values from environment variables
  --uninstall         remove binary and units; keep configuration and logs
  --purge             with --uninstall: also remove configuration, mounts
                      entries and the service users (never the logs on the share)
  -h, --help          show this help

Environment variables for --non-interactive (the SMB mounts are only set up
when LOGS_SMB_SHARE is set):

  LOGS_SMB_SHARE         share, e.g. //nas.example.com/logs
  LOGS_SMB_RW_USER       SMB user with write access (collector)
  LOGS_SMB_RW_PASSWORD   its password
  LOGS_SMB_RO_USER       SMB user with read-only access (web UI)
  LOGS_SMB_RO_PASSWORD   its password
  LOGS_SMB_DOMAIN        optional SMB domain / workgroup
  LOGS_RW_OWNER          local user that owns the read-write mount
                         (default: logs-collector; with Semaphore: its user)
  LOGS_RW_MOUNT          default /mnt/logs-rw
  LOGS_RO_MOUNT          default /mnt/logs-ro

For tests: LOGS_DIST_DIR=<dir> installs from local release files instead of
downloading them.
EOF
}

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --version) [ $# -ge 2 ] || die "--version needs a value, e.g. --version v1.0.0"; WANT_VERSION=$2; shift ;;
        --version=*) WANT_VERSION=${1#*=} ;;
        --no-webui) WEBUI=0 ;;
        --no-timers) TIMERS=0 ;;
        --no-mount) MOUNT=0 ;;
        --non-interactive) INTERACTIVE=0 ;;
        --uninstall) UNINSTALL=1 ;;
        --purge) PURGE=1 ;;
        -h | --help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
done
[ "$PURGE" -eq 0 ] || [ "$UNINSTALL" -eq 1 ] || die "--purge only works together with --uninstall"
case "$WANT_VERSION" in
    "" | v[0-9]*) ;;
    *) die "--version must look like v1.2.3, got: $WANT_VERSION" ;;
esac

# ---------------------------------------------------------------- checks ----

[ "$(id -u)" -eq 0 ] || die "this installer must run as root. Run it with sudo."

[ -r /etc/os-release ] || die "cannot read /etc/os-release; only Ubuntu Server 24.04 LTS and 26.04 LTS are supported."
# Read os-release in a subshell: it defines VERSION, ID and more, and must not
# leak into this script's variables.
# shellcheck disable=SC1091
os_id=$(. /etc/os-release && printf '%s' "${ID:-}")
# shellcheck disable=SC1091
os_version=$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")
# shellcheck disable=SC1091
os_name=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown}")
if [ "$os_id" != ubuntu ] || { [ "$os_version" != 24.04 ] && [ "$os_version" != 26.04 ]; }; then
    die "unsupported system: $os_name. The collector and web UI host must run Ubuntu Server 24.04 LTS or 26.04 LTS. (The hosts you collect logs from may run Ubuntu or Debian.)"
fi

case "$(dpkg --print-architecture)" in
    amd64) ARCH=amd64 ;;
    arm64) ARCH=arm64 ;;
    *) die "unsupported CPU architecture: $(dpkg --print-architecture). Release binaries exist for amd64 and arm64." ;;
esac

HAVE_SYSTEMD=0
[ -d /run/systemd/system ] && HAVE_SYSTEMD=1

# With "curl | sudo bash" stdin is the script, so questions go to the terminal.
TTY=""
if [ "$INTERACTIVE" -eq 1 ]; then
    if [ -r /dev/tty ] && [ -w /dev/tty ] && : 2>/dev/null </dev/tty; then
        TTY=/dev/tty
    else
        INTERACTIVE=0
        say "No terminal available: continuing without questions (as with --non-interactive)."
    fi
fi

ask() { # ask <variable> <prompt> [default]
    local answer=""
    if [ -n "${3:-}" ]; then
        printf '%s [%s]: ' "$2" "$3" >"$TTY"
    else
        printf '%s: ' "$2" >"$TTY"
    fi
    IFS= read -r answer <"$TTY" || true
    printf -v "$1" '%s' "${answer:-${3:-}}"
}

ask_secret() { # ask_secret <variable> <prompt>; the input is not shown
    local answer=""
    printf '%s: ' "$2" >"$TTY"
    IFS= read -rs answer <"$TTY" || true
    printf '\n' >"$TTY"
    printf -v "$1" '%s' "$answer"
}

systemd_do() { # run systemctl only where systemd is running
    [ "$HAVE_SYSTEMD" -eq 1 ] || return 0
    systemctl "$@"
}

remove_fstab_entries() {
    [ -f /etc/fstab ] || return 0
    if grep -qF "$FSTAB_TAG" /etc/fstab; then
        cp -p /etc/fstab "/etc/fstab.logs-backup.$(date +%Y%m%d%H%M%S)"
        grep -vF "$FSTAB_TAG" /etc/fstab >/etc/fstab.logs-new || true
        cat /etc/fstab.logs-new >/etc/fstab
        rm -f /etc/fstab.logs-new
    fi
}

# ------------------------------------------------------------- uninstall ----

uninstall() {
    step "Removing services, timers and program files"
    local unit
    for unit in $UNITS; do
        if [ -e "$UNIT_DIR/$unit" ]; then
            systemd_do disable --now "$unit" >/dev/null 2>&1 || true
            rm -f "$UNIT_DIR/$unit"
            say "removed $UNIT_DIR/$unit"
        fi
    done
    systemd_do daemon-reload || true
    rm -f "$BIN" && say "removed $BIN"
    rm -rf "$SHARE_DIR" && say "removed $SHARE_DIR"

    if [ "$PURGE" -eq 1 ]; then
        step "Purging configuration, mount entries and service users"
        local mp
        # shellcheck disable=SC2013  # mount points cannot contain spaces here
        for mp in $(awk -v tag="$FSTAB_TAG" 'index($0, tag) {print $2}' /etc/fstab 2>/dev/null); do
            umount "$mp" 2>/dev/null || true
            rmdir "$mp" 2>/dev/null || true
            say "removed mount $mp"
        done
        remove_fstab_entries
        systemd_do daemon-reload || true
        rm -rf "$ETC_DIR" && say "removed $ETC_DIR (including the SMB credentials files)"
        local user
        for user in "$WEB_USER" "$COLLECT_USER"; do
            if id "$user" >/dev/null 2>&1; then
                userdel "$user" >/dev/null 2>&1 || true
                say "removed user $user"
            fi
        done
        rm -rf "$COLLECT_HOME"
        say
        say "Purged. The logs on the share were not touched."
    else
        say
        say "Uninstalled. Kept: $ETC_DIR (configuration and SMB credentials), the mount"
        say "entries in /etc/fstab, the service users and all logs on the share."
        say "Run again with --uninstall --purge to remove those too (never the logs)."
    fi
}

if [ "$UNINSTALL" -eq 1 ]; then
    uninstall
    exit 0
fi

# --------------------------------------------------------------- install ----

step "Installing packages from the Ubuntu archive"
PACKAGES="ca-certificates curl tar zstd cifs-utils"
[ "$TIMERS" -eq 1 ] && PACKAGES="$PACKAGES ansible-core openssh-client python3"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# shellcheck disable=SC2086
apt-get install -y -qq --no-install-recommends $PACKAGES >/dev/null
say "installed: $PACKAGES"

step "Getting the release files"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# LOGS_RELEASE_BASE only exists for the installer test (plain http, local server).
RELEASE_BASE=${LOGS_RELEASE_BASE:-https://github.com/$REPO/releases}
CURL_PROTO='=https'
[ -z "${LOGS_RELEASE_BASE:-}" ] || CURL_PROTO='=http,https'
if [ -n "${LOGS_DIST_DIR:-}" ]; then
    SOURCE="local directory $LOGS_DIST_DIR"
    fetch() { cp "$LOGS_DIST_DIR/$1" "$WORK/$1"; }
else
    if [ -n "$WANT_VERSION" ]; then
        SOURCE="$RELEASE_BASE/download/$WANT_VERSION"
    else
        SOURCE="$RELEASE_BASE/latest/download"
    fi
    fetch() { curl -fsSL --retry 3 --proto "$CURL_PROTO" --tlsv1.2 -o "$WORK/$1" "$SOURCE/$1"; }
fi
FILES="logs-bundle.tar.gz"
[ "$WEBUI" -eq 1 ] && FILES="$FILES logs-webui-linux-$ARCH"
for f in SHA256SUMS $FILES; do
    fetch "$f" || die "could not get $f from $SOURCE. Check the version and your network connection."
done
for f in $FILES; do
    grep -E "  $f\$" "$WORK/SHA256SUMS" >"$WORK/$f.sha256" || die "$f is not listed in SHA256SUMS; refusing to install."
    (cd "$WORK" && sha256sum --check --quiet "$f.sha256") || die "checksum of $f does not match SHA256SUMS; refusing to install."
done
say "verified against SHA256SUMS: $FILES"

mkdir -p "$WORK/bundle"
tar -xzf "$WORK/logs-bundle.tar.gz" -C "$WORK/bundle" --no-same-owner
RELEASE=$(cat "$WORK/bundle/VERSION")

step "Installing program files ($RELEASE)"
UPGRADE_FROM=""
[ -f "$SHARE_DIR/VERSION" ] && UPGRADE_FROM=$(cat "$SHARE_DIR/VERSION")
rm -rf "$SHARE_DIR.new"
mkdir -p "$SHARE_DIR.new"
cp -R "$WORK/bundle/." "$SHARE_DIR.new/"
chown -R root:root "$SHARE_DIR.new"
chmod -R u=rwX,go=rX "$SHARE_DIR.new"
rm -rf "$SHARE_DIR"
mv "$SHARE_DIR.new" "$SHARE_DIR"
say "installed $SHARE_DIR (playbooks, helper scripts, example configuration)"
if [ "$WEBUI" -eq 1 ]; then
    install -o root -g root -m 0755 "$WORK/logs-webui-linux-$ARCH" "$BIN.new"
    mv -f "$BIN.new" "$BIN"
    say "installed $BIN"
fi

step "Creating service users"
if [ "$WEBUI" -eq 1 ] && ! id "$WEB_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$WEB_USER"
    say "created user $WEB_USER (no login)"
fi
if [ "$TIMERS" -eq 1 ]; then
    if ! id "$COLLECT_USER" >/dev/null 2>&1; then
        useradd --system --create-home --home-dir "$COLLECT_HOME" --shell /usr/sbin/nologin "$COLLECT_USER"
        say "created user $COLLECT_USER (no login, home $COLLECT_HOME)"
    fi
    install -d -o "$COLLECT_USER" -g "$COLLECT_USER" -m 0700 "$COLLECT_HOME" "$COLLECT_HOME/.ssh"
    if [ ! -f "$COLLECT_HOME/.ssh/id_ed25519" ]; then
        runuser -u "$COLLECT_USER" -- ssh-keygen -q -t ed25519 -N "" -C "logs-collector" -f "$COLLECT_HOME/.ssh/id_ed25519"
        say "created an SSH key for the collector: $COLLECT_HOME/.ssh/id_ed25519.pub"
    fi
fi

step "Configuration in $ETC_DIR (existing files are kept)"
install -d -o root -g root -m 0755 "$ETC_DIR"
place_config() { # place_config <source> <target> <group> <mode>
    local group=$3
    getent group "$group" >/dev/null 2>&1 || group=root
    if [ -e "$2" ]; then
        say "kept    $2"
    else
        install -o root -g "$group" -m "$4" "$1" "$2"
        say "created $2"
    fi
}
[ "$WEBUI" -eq 1 ] && place_config "$SHARE_DIR/config.example.env" "$ETC_DIR/webui.env" "$WEB_USER" 0640
if [ "$TIMERS" -eq 1 ]; then
    install -d -o root -g root -m 0755 "$ETC_DIR/group_vars"
    place_config "$SHARE_DIR/ansible/inventory.example.yml" "$ETC_DIR/inventory.yml" "$COLLECT_USER" 0640
    place_config "$SHARE_DIR/ansible/group_vars/all.example.yml" "$ETC_DIR/group_vars/all.yml" "$COLLECT_USER" 0640
fi

# ---------------------------------------------------------------- mounts ----

RW_MOUNT=${LOGS_RW_MOUNT:-/mnt/logs-rw}
RO_MOUNT=${LOGS_RO_MOUNT:-/mnt/logs-ro}
RW_OWNER=${LOGS_RW_OWNER:-}
MOUNT_STATE="not set up"

write_credentials() { # write_credentials <file> <user> <password> [domain]; nothing is echoed
    local old_umask
    old_umask=$(umask)
    umask 077
    {
        printf 'username=%s\n' "$2"
        printf 'password=%s\n' "$3"
        [ -z "${4:-}" ] || printf 'domain=%s\n' "$4"
    } >"$1"
    umask "$old_umask"
    chown root:root "$1"
    chmod 600 "$1"
}

setup_mounts() {
    local share=${LOGS_SMB_SHARE:-} rw_user=${LOGS_SMB_RW_USER:-} ro_user=${LOGS_SMB_RO_USER:-}
    local rw_pass=${LOGS_SMB_RW_PASSWORD:-} ro_pass=${LOGS_SMB_RO_PASSWORD:-} domain=${LOGS_SMB_DOMAIN:-}
    local answer=""

    if [ "$INTERACTIVE" -eq 1 ]; then
        if grep -qF "$FSTAB_TAG" /etc/fstab 2>/dev/null; then
            ask answer "SMB mounts for the log archive already exist in /etc/fstab. Set them up again? (y/N)" "N"
        else
            ask answer "Set up the SMB mounts for the log share now? (y/N)" "N"
        fi
        case "$answer" in y | Y | yes | Yes) ;; *) return 0 ;; esac
        ask share "SMB share (//server/share)" "$share"
        if [ "$TIMERS" -eq 1 ] || [ -n "$RW_OWNER" ]; then
            ask rw_user "SMB user with WRITE access (for the collector)" "$rw_user"
        else
            say "The read-write mount is for the collector. If the collector runs on this"
            say "host (for example from Semaphore), enter its SMB user; otherwise leave it empty."
            ask rw_user "SMB user with WRITE access (empty: no read-write mount)" "$rw_user"
        fi
        if [ -n "$rw_user" ]; then
            ask_secret rw_pass "Password of $rw_user (input hidden)"
            if [ "$TIMERS" -eq 0 ] && [ -z "$RW_OWNER" ]; then
                ask RW_OWNER "Local user that runs the collector and must own the read-write mount (e.g. semaphore)" ""
            fi
        fi
        if [ "$WEBUI" -eq 1 ]; then
            ask ro_user "SMB user with READ-ONLY access (for the web UI)" "$ro_user"
            [ -z "$ro_user" ] || ask_secret ro_pass "Password of $ro_user (input hidden)"
        fi
        ask domain "SMB domain or workgroup (empty for none)" "$domain"
    elif [ -z "$share" ]; then
        return 0
    fi

    case "$share" in
        //*/*) ;;
        *) warn "the share must look like //server/share; skipping the mount setup."; return 0 ;;
    esac
    case "$share$RW_MOUNT$RO_MOUNT$RW_OWNER" in
        *[[:space:]]*) warn "share, mount points and owner must not contain spaces; skipping the mount setup."; return 0 ;;
    esac
    [ -n "$RW_OWNER" ] || RW_OWNER=$COLLECT_USER
    remove_fstab_entries
    local lines=""
    if [ -n "$rw_user" ]; then
        if ! id "$RW_OWNER" >/dev/null 2>&1; then
            warn "local user $RW_OWNER does not exist; skipping the read-write mount."
        elif [ -z "$rw_pass" ]; then
            warn "no password given for $rw_user; skipping the read-write mount."
        else
            write_credentials "$ETC_DIR/smb-rw.cred" "$rw_user" "$rw_pass" "$domain"
            mkdir -p "$RW_MOUNT"
            lines="$share $RW_MOUNT cifs credentials=$ETC_DIR/smb-rw.cred,uid=$RW_OWNER,gid=$(id -gn "$RW_OWNER"),file_mode=0640,dir_mode=0750,_netdev,nofail 0 0 $FSTAB_TAG"
        fi
    fi
    if [ "$WEBUI" -eq 1 ] && [ -n "$ro_user" ]; then
        if [ -z "$ro_pass" ]; then
            warn "no password given for $ro_user; skipping the read-only mount."
        else
            write_credentials "$ETC_DIR/smb-ro.cred" "$ro_user" "$ro_pass" "$domain"
            mkdir -p "$RO_MOUNT"
            lines="${lines:+$lines
}$share $RO_MOUNT cifs ro,credentials=$ETC_DIR/smb-ro.cred,uid=$WEB_USER,gid=$WEB_USER,file_mode=0440,dir_mode=0550,_netdev,nofail 0 0 $FSTAB_TAG"
        fi
    fi
    rw_pass="" ro_pass=""
    [ -n "$lines" ] || return 0
    printf '%s\n' "$lines" >>/etc/fstab
    systemd_do daemon-reload || true
    MOUNT_STATE="configured in /etc/fstab"
    local mp
    for mp in "$RW_MOUNT" "$RO_MOUNT"; do
        grep -qE "[[:space:]]${mp}[[:space:]]+cifs.*$FSTAB_TAG" /etc/fstab || continue
        if mountpoint -q "$mp"; then umount "$mp" 2>/dev/null || true; fi
        if mount "$mp" 2>/dev/null; then
            say "mounted $mp"
        else
            warn "could not mount $mp now. Check the share, the user and the password, then run: sudo mount $mp"
            MOUNT_STATE="configured in /etc/fstab, but at least one mount failed"
        fi
    done
}

if [ "$MOUNT" -eq 1 ]; then
    step "SMB mounts"
    setup_mounts
    say "mounts: $MOUNT_STATE"
fi
# The web UI needs an existing data directory even while the share is offline.
if [ "$WEBUI" -eq 1 ]; then
    DATA_DIR=$(sed -n 's/^LOGS_DATA_DIR=//p' "$ETC_DIR/webui.env" | tail -n 1)
    [ -z "$DATA_DIR" ] || [ -d "$DATA_DIR" ] || mkdir -p "$DATA_DIR"
fi

# ----------------------------------------------------------------- units ----

step "systemd units"
for unit in $UNITS; do
    case "$unit" in
        logs-webui.*) [ "$WEBUI" -eq 1 ] || continue ;;
        *) [ "$TIMERS" -eq 1 ] || continue ;;
    esac
    install -o root -g root -m 0644 "$SHARE_DIR/systemd/$unit" "$UNIT_DIR/$unit"
    say "installed $UNIT_DIR/$unit"
done
if [ "$HAVE_SYSTEMD" -eq 1 ]; then
    systemctl daemon-reload
    if [ "$WEBUI" -eq 1 ]; then
        systemctl enable --quiet logs-webui.service
        systemctl restart logs-webui.service || warn "logs-webui did not start; see: journalctl -u logs-webui"
    fi
    [ "$TIMERS" -eq 0 ] || systemctl enable --quiet --now logs-collect.timer logs-retention.timer
else
    warn "systemd is not running here (container?). The units are installed but not started."
fi

# --------------------------------------------------------------- summary ----

LISTEN=$(sed -n 's/^LOGS_LISTEN=//p' "$ETC_DIR/webui.env" 2>/dev/null | tail -n 1)
LISTEN=${LISTEN:-127.0.0.1:8484}
state() { # state <unit>
    if [ "$HAVE_SYSTEMD" -eq 1 ]; then systemctl is-active "$1" 2>/dev/null || true; else echo "not started (no systemd)"; fi
}

step "Summary"
if [ -n "$UPGRADE_FROM" ]; then
    say "Upgraded the log archive from $UPGRADE_FROM to $RELEASE. Your configuration was kept."
else
    say "Installed the log archive $RELEASE."
fi
say
say "  Program files   $SHARE_DIR"
[ "$WEBUI" -eq 1 ] && say "  Web UI binary   $BIN"
say "  Configuration   $ETC_DIR"
say "  SMB mounts      $MOUNT_STATE"
say
if [ "$WEBUI" -eq 1 ]; then
    say "  logs-webui.service      $(state logs-webui.service)"
else
    say "  logs-webui.service      not installed (--no-webui)"
fi
if [ "$TIMERS" -eq 1 ]; then
    say "  logs-collect.timer      $(state logs-collect.timer)   (daily 02:30)"
    say "  logs-retention.timer    $(state logs-retention.timer)   (daily 04:30)"
else
    say "  collector timers        not installed (--no-timers); run the playbooks from Semaphore or by hand"
fi
say
if [ "$WEBUI" -eq 1 ]; then
    say "Open the web UI:  http://$LISTEN/   (health check: http://$LISTEN/healthz)"
    case "$LISTEN" in
        127.0.0.1:* | localhost:*) say "It listens on this host only. From another machine: ssh -L 8484:$LISTEN <this host>" ;;
    esac
    say
fi
say "Next steps:"
n=1
if [ "$MOUNT_STATE" = "not set up" ]; then
    say "  $n. Mount the log share: run this installer again and answer the mount questions,"
    say "     or add the mounts yourself (see README, \"SMB mounts\")."
    n=$((n + 1))
fi
if [ "$WEBUI" -eq 1 ]; then
    say "  $n. Review $ETC_DIR/webui.env, then: sudo systemctl restart logs-webui"
    n=$((n + 1))
fi
if [ "$TIMERS" -eq 1 ]; then
    say "  $n. List your hosts in $ETC_DIR/inventory.yml and adjust $ETC_DIR/group_vars/all.yml."
    n=$((n + 1))
    say "  $n. Allow the collector to log in to your hosts with this public key:"
    say "       $(cat "$COLLECT_HOME/.ssh/id_ed25519.pub" 2>/dev/null || echo "(missing: $COLLECT_HOME/.ssh/id_ed25519.pub)")"
    n=$((n + 1))
    say "  $n. Test a run now: sudo systemctl start logs-collect.service && journalctl -u logs-collect -e"
else
    say "  $n. Point Semaphore (or cron) at ansible/collect.yml and ansible/retention.yml; see the README."
fi
say
say "Logs can contain secrets. Keep the share and this web UI restricted to admins."
