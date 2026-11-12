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
# The SMB mounts are configured in /etc/logs/install.conf (created on the
# first install). After editing it, apply it without downloading anything:
#
#   sudo logs-install --apply
#
# Run with --help for all options. Running it again upgrades in place and
# keeps your configuration.
set -euo pipefail

REPO="Lukas0923xcv/logs"
BIN=/usr/local/bin/logs-webui
SBIN_LINK=/usr/local/sbin/logs-install
SHARE_DIR=/usr/local/share/logs
ETC_DIR=/etc/logs
CONF=$ETC_DIR/install.conf
UNIT_DIR=/etc/systemd/system
WEB_USER=logs-web
COLLECT_USER=logs-collector
COLLECT_HOME=/var/lib/logs-collector
FSTAB_TAG="# logs-archive"
UNITS="logs-webui.service logs-collect.service logs-collect.timer logs-retention.service logs-retention.timer"
KNOWN_KEYS="LOGS_SMB_SHARE LOGS_SMB_DOMAIN LOGS_SMB_RW_USER LOGS_SMB_RW_PASSWORD LOGS_SMB_RO_USER LOGS_SMB_RO_PASSWORD LOGS_RW_OWNER LOGS_RW_MOUNT LOGS_RO_MOUNT"

WANT_VERSION=""  # not VERSION: /etc/os-release defines that name too
WEBUI=1
WEBUI_FLAG=""    # set when --no-webui is given
TIMERS=1
MOUNT=1
UNINSTALL=0
PURGE=0
APPLY=0

usage() {
    cat <<'EOF'
Usage: sudo bash install.sh [options]
       sudo logs-install [options]        (installed by this script)

  --version vX.Y.Z    install this release instead of the latest one
  --no-webui          do not install the web UI service
  --no-timers         do not install the collector and retention timers
                      (use this when the collector runs from Semaphore)
  --no-mount          do not apply the SMB mount settings
  --apply             only apply /etc/logs/install.conf (credentials files,
                      /etc/fstab, mounts). Downloads and installs nothing.
  --non-interactive   accepted for compatibility; the installer never asks
  --uninstall         remove binary and units; keep configuration and logs
  --purge             with --uninstall: also remove configuration, mount
                      entries and the service users (never the logs on the share)
  -h, --help          show this help

The SMB mounts come from one file, /etc/logs/install.conf, which the first
install creates from install.example.conf and never overwrites. It holds the
SMB passwords (mode 0600, owner root). Edit it, then run:

  sudo logs-install --apply

If LOGS_SMB_SHARE is empty, no mounts are set up.

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
        --no-webui) WEBUI=0; WEBUI_FLAG=1 ;;
        --no-timers) TIMERS=0 ;;
        --no-mount) MOUNT=0 ;;
        --apply) APPLY=1 ;;
        --non-interactive) ;; # nothing to ask any more; kept so existing command lines still work
        --uninstall) UNINSTALL=1 ;;
        --purge) PURGE=1 ;;
        -h | --help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
done
[ "$PURGE" -eq 0 ] || [ "$UNINSTALL" -eq 1 ] || die "--purge only works together with --uninstall"
if [ "$APPLY" -eq 1 ]; then
    [ "$UNINSTALL" -eq 0 ] || die "--apply and --uninstall cannot be combined"
    [ -z "$WANT_VERSION" ] || die "--apply installs nothing, so --version makes no sense with it"
    [ "$MOUNT" -eq 1 ] || die "--apply and --no-mount contradict each other"
fi
case "$WANT_VERSION" in
    "" | v[0-9]*) ;;
    *) die "--version must look like v1.2.3, got: $WANT_VERSION" ;;
esac

# ---------------------------------------------------------------- checks ----

[ "$(id -u)" -eq 0 ] || die "this installer must run as root. Run it with sudo."

if [ "$APPLY" -eq 0 ]; then
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
fi

HAVE_SYSTEMD=0
[ -d /run/systemd/system ] && HAVE_SYSTEMD=1

systemd_do() { # run systemctl only where systemd is running
    [ "$HAVE_SYSTEMD" -eq 1 ] || return 0
    systemctl "$@"
}

# Replace all "# logs-archive" lines of /etc/fstab by the given lines (may be
# empty). A backup is kept, but only when the file really changes.
update_fstab() { # update_fstab <lines>
    local new
    [ -f /etc/fstab ] || : >/etc/fstab
    new=$(mktemp)
    grep -vF -- "$FSTAB_TAG" /etc/fstab >"$new" || true
    [ -z "$1" ] || printf '%s\n' "$1" >>"$new"
    if ! cmp -s "$new" /etc/fstab; then
        cp -p /etc/fstab "/etc/fstab.logs-backup.$(date +%Y%m%d%H%M%S)"
        cat "$new" >/etc/fstab
    fi
    rm -f "$new"
}

# ---------------------------------------------------- install.conf parser ----
#
# The file is never sourced or evaluated. It is read line by line:
#   KEY=value     known keys only; the value is everything after the first "="
#   # comment     only at the start of a line (passwords may contain "#")
#   (blank lines are ignored)
# An unquoted value loses leading and trailing whitespace. A value wrapped in
# one pair of "double" or 'single' quotes loses the quotes and is otherwise
# kept exactly. Error messages name the line and never show a value.

C_SHARE="" C_DOMAIN="" C_RW_USER="" C_RW_PASS="" C_RO_USER="" C_RO_PASS=""
C_RW_OWNER="" C_RW_MOUNT="" C_RO_MOUNT=""

parse_conf() { # parse_conf <file>
    local file=$1 line stripped key value n=0 seen=" "
    local LC_ALL=C
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        case $line in
            *$'\r') die "$file line $n: the file has Windows line endings (CR LF). Convert it first, for example with: sed -i 's/\\r\$//' $file" ;;
        esac
        stripped=${line#"${line%%[![:space:]]*}"}
        case $stripped in '' | '#'*) continue ;; esac
        [[ $stripped == *=* ]] || die "$file line $n: not a KEY=value line (comments must start with #)."
        key=${stripped%%=*}
        value=${stripped#*=}
        if ! [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            die "$file line $n: malformed key before the first \"=\". The format is KEY=value with no spaces around the \"=\"."
        fi
        case " $KNOWN_KEYS " in
            *" $key "*) ;;
            *)
                if [[ $key =~ ^LOGS_[A-Z0-9_]{1,40}$ ]]; then
                    die "$file line $n: unknown key $key. Known keys: $KNOWN_KEYS"
                fi
                die "$file line $n: unknown key. Known keys: $KNOWN_KEYS"
                ;;
        esac
        case $seen in
            *" $key "*) die "$file line $n: $key is set twice." ;;
        esac
        seen="$seen$key "
        value=${value#"${value%%[![:space:]]*}"}
        value=${value%"${value##*[![:space:]]}"}
        if [ "${#value}" -ge 2 ]; then
            case $value in
                \"*\") value=${value:1:${#value}-2} ;;
                \'*\') value=${value:1:${#value}-2} ;;
            esac
        fi
        case $key in
            LOGS_SMB_SHARE) C_SHARE=$value ;;
            LOGS_SMB_DOMAIN) C_DOMAIN=$value ;;
            LOGS_SMB_RW_USER) C_RW_USER=$value ;;
            LOGS_SMB_RW_PASSWORD) C_RW_PASS=$value ;;
            LOGS_SMB_RO_USER) C_RO_USER=$value ;;
            LOGS_SMB_RO_PASSWORD) C_RO_PASS=$value ;;
            LOGS_RW_OWNER) C_RW_OWNER=$value ;;
            LOGS_RW_MOUNT) C_RW_MOUNT=$value ;;
            LOGS_RO_MOUNT) C_RO_MOUNT=$value ;;
        esac
    done <"$file"
    [ -n "$C_RW_OWNER" ] || C_RW_OWNER=$COLLECT_USER
    [ -n "$C_RW_MOUNT" ] || C_RW_MOUNT=/mnt/logs-rw
    [ -n "$C_RO_MOUNT" ] || C_RO_MOUNT=/mnt/logs-ro
}

# Problems that make the whole file unusable. They stop the run (before
# anything is changed when the installer starts).
validate_conf() {
    [ -n "$C_SHARE" ] || return 0
    case "$C_SHARE" in
        //?*/?*) ;;
        *) die "$CONF: LOGS_SMB_SHARE must look like //server/share." ;;
    esac
    case "$C_SHARE$C_RW_MOUNT$C_RO_MOUNT$C_RW_OWNER" in
        *[[:space:]]*) die "$CONF: LOGS_SMB_SHARE, LOGS_RW_MOUNT, LOGS_RO_MOUNT and LOGS_RW_OWNER must not contain spaces." ;;
    esac
    case "$C_RW_MOUNT" in /?*) ;; *) die "$CONF: LOGS_RW_MOUNT must be an absolute path." ;; esac
    case "$C_RO_MOUNT" in /?*) ;; *) die "$CONF: LOGS_RO_MOUNT must be an absolute path." ;; esac
    [ "$C_RW_MOUNT" != "$C_RO_MOUNT" ] || die "$CONF: LOGS_RW_MOUNT and LOGS_RO_MOUNT must differ."
}

# The file holds passwords: make sure nobody else can read it.
secure_conf() {
    [ -f "$CONF" ] || return 0
    if [ "$(stat -c '%a %U:%G' "$CONF")" != "600 root:root" ]; then
        chown root:root "$CONF"
        chmod 600 "$CONF"
        say "fixed the permissions of $CONF (now mode 600, owner root)"
    fi
}

load_conf() {
    secure_conf
    parse_conf "$CONF"
    validate_conf
}

# Create the file from the example on the first install; never overwrite it.
create_conf() {
    if [ -e "$CONF" ]; then
        say "kept    $CONF"
    elif [ -f "$SHARE_DIR/install.example.conf" ]; then
        install -o root -g root -m 0600 "$SHARE_DIR/install.example.conf" "$CONF"
        say "created $CONF (mode 600)"
    else
        warn "this release has no install.example.conf (needs v0.1.1 or newer); the mount settings cannot be created."
        return 1
    fi
}

write_credentials() { # write_credentials <file> <user> <password> [domain]; nothing is echoed
    local old_umask
    old_umask=$(umask)
    umask 077
    rm -f "$1"
    {
        printf 'username=%s\n' "$2"
        printf 'password=%s\n' "$3"
        [ -z "${4:-}" ] || printf 'domain=%s\n' "$4"
    } >"$1"
    umask "$old_umask"
    chown root:root "$1"
    chmod 600 "$1"
}

# ------------------------------------------------------------------ mounts ----

MOUNT_NOTE=""      # set when there is nothing to apply
MOUNT_FAILED=0
MOUNT_RESULT=""
RW_REPORT="" RO_REPORT=""

mount_one() { # mount_one <mount point>; sets MOUNT_RESULT, and MOUNT_FAILED on failure
    local mp=$1 err
    if mountpoint -q "$mp" && ! umount "$mp" 2>/dev/null; then
        MOUNT_FAILED=1
        MOUNT_RESULT="NOT remounted: $mp is busy and still uses the old settings. Unmount it, then run: sudo mount $mp"
        return 0
    fi
    if err=$(timeout 90 mount "$mp" 2>&1); then
        MOUNT_RESULT="mounted"
    else
        MOUNT_FAILED=1
        err=$(printf '%s' "$err" | tail -n 1 | cut -c1-160)
        MOUNT_RESULT="NOT mounted (${err:-no message}). Check the share, user and password, then run: sudo mount $mp"
    fi
}

apply_mounts() {
    local lines="" rw_ok=0 ro_ok=0 gid
    if [ -z "$C_SHARE" ]; then
        MOUNT_NOTE="not configured"
        return 0
    fi

    if [ -z "$C_RW_USER" ]; then
        RW_REPORT="not configured (LOGS_SMB_RW_USER is empty)"
    elif [ -z "$C_RW_PASS" ]; then
        RW_REPORT="skipped: LOGS_SMB_RW_PASSWORD is empty"
    elif ! id "$C_RW_OWNER" >/dev/null 2>&1; then
        RW_REPORT="skipped: the local user $C_RW_OWNER does not exist (LOGS_RW_OWNER)"
    else
        write_credentials "$ETC_DIR/smb-rw.cred" "$C_RW_USER" "$C_RW_PASS" "$C_DOMAIN"
        mkdir -p "$C_RW_MOUNT"
        gid=$(id -gn "$C_RW_OWNER")
        lines="$C_SHARE $C_RW_MOUNT cifs credentials=$ETC_DIR/smb-rw.cred,uid=$C_RW_OWNER,gid=$gid,file_mode=0640,dir_mode=0750,_netdev,nofail 0 0 $FSTAB_TAG"
        rw_ok=1
    fi
    [ "$rw_ok" -eq 1 ] || rm -f "$ETC_DIR/smb-rw.cred"

    if [ "$WEBUI" -eq 0 ]; then
        RO_REPORT="not set up (no web UI on this host)"
    elif [ -z "$C_RO_USER" ]; then
        RO_REPORT="not configured (LOGS_SMB_RO_USER is empty)"
    elif [ -z "$C_RO_PASS" ]; then
        RO_REPORT="skipped: LOGS_SMB_RO_PASSWORD is empty"
    elif ! id "$WEB_USER" >/dev/null 2>&1; then
        RO_REPORT="skipped: the local user $WEB_USER does not exist (web UI not installed)"
    else
        write_credentials "$ETC_DIR/smb-ro.cred" "$C_RO_USER" "$C_RO_PASS" "$C_DOMAIN"
        mkdir -p "$C_RO_MOUNT"
        lines="${lines:+$lines
}$C_SHARE $C_RO_MOUNT cifs ro,credentials=$ETC_DIR/smb-ro.cred,uid=$WEB_USER,gid=$WEB_USER,file_mode=0440,dir_mode=0550,_netdev,nofail 0 0 $FSTAB_TAG"
        ro_ok=1
    fi
    [ "$ro_ok" -eq 1 ] || rm -f "$ETC_DIR/smb-ro.cred"

    update_fstab "$lines"
    systemd_do daemon-reload || true
    if [ "$rw_ok" -eq 1 ]; then mount_one "$C_RW_MOUNT"; RW_REPORT=$MOUNT_RESULT; fi
    if [ "$ro_ok" -eq 1 ]; then mount_one "$C_RO_MOUNT"; RO_REPORT=$MOUNT_RESULT; fi
}

# Prints what was applied. Passwords are never printed.
mount_report() {
    if [ -n "$MOUNT_NOTE" ]; then
        say "  SMB mounts      $MOUNT_NOTE"
        return 0
    fi
    say "  SMB share       $C_SHARE${C_DOMAIN:+  (domain $C_DOMAIN)}"
    say "  read-write      user ${C_RW_USER:-none}, $C_RW_MOUNT, owner $C_RW_OWNER: $RW_REPORT"
    say "  read-only       user ${C_RO_USER:-none}, $C_RO_MOUNT: $RO_REPORT"
}

# --------------------------------------------------------------- --apply ----

if [ "$APPLY" -eq 1 ]; then
    if [ -z "$WEBUI_FLAG" ]; then
        WEBUI=0
        ! id "$WEB_USER" >/dev/null 2>&1 || WEBUI=1
    fi
    install -d -o root -g root -m 0755 "$ETC_DIR"
    if [ ! -e "$CONF" ]; then
        # Not installed yet, or installed by an older release.
        [ -f "$SHARE_DIR/install.example.conf" ] || die "$CONF does not exist and there is no example to create it from. Run the installer first."
        create_conf
    fi
    step "Applying $CONF"
    load_conf
    apply_mounts
    say
    mount_report
    if [ "$MOUNT_NOTE" = "not configured" ]; then
        say
        say "LOGS_SMB_SHARE is empty in $CONF, so nothing was changed. Fill it in, then run: sudo logs-install --apply"
    fi
    [ "$MOUNT_FAILED" -eq 0 ] || exit 1
    exit 0
fi

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
    rm -f "$SBIN_LINK" && say "removed $SBIN_LINK"

    if [ "$PURGE" -eq 1 ]; then
        step "Purging configuration, mount entries and service users"
        local mp
        # shellcheck disable=SC2013  # mount points cannot contain spaces here
        for mp in $(awk -v tag="$FSTAB_TAG" 'index($0, tag) {print $2}' /etc/fstab 2>/dev/null); do
            umount "$mp" 2>/dev/null || true
            rmdir "$mp" 2>/dev/null || true
            say "removed mount $mp"
        done
        update_fstab ""
        systemd_do daemon-reload || true
        rm -rf "$ETC_DIR" && say "removed $ETC_DIR (including install.conf and the SMB credentials files)"
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
        say "Uninstalled. Kept: $ETC_DIR (configuration, install.conf and SMB credentials), the mount"
        say "entries in /etc/fstab, the service users and all logs on the share."
        say "Run again with --uninstall --purge to remove those too (never the logs)."
    fi
}

if [ "$UNINSTALL" -eq 1 ]; then
    uninstall
    exit 0
fi

# --------------------------------------------------------------- install ----

# An existing install.conf is checked first, so a typo stops the run before
# anything has been changed.
if [ "$MOUNT" -eq 1 ] && [ -f "$CONF" ]; then
    step "Checking $CONF"
    load_conf
    say "ok"
fi

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
# logs-install: this installer, so the config can be applied later without curl.
# The copy that belongs to the release is preferred; releases that do not
# contain one fall back to the script that is running now (when it is a file).
INSTALLER_SRC=""
if [ -f "$SHARE_DIR/install.sh" ]; then
    INSTALLER_SRC=$SHARE_DIR/install.sh
elif [ -f "${BASH_SOURCE[0]:-}" ] && ! [ "${BASH_SOURCE[0]}" -ef "$SBIN_LINK" ]; then
    INSTALLER_SRC=${BASH_SOURCE[0]}
fi
if [ -n "$INSTALLER_SRC" ]; then
    install -d -o root -g root -m 0755 "$(dirname "$SBIN_LINK")"
    install -o root -g root -m 0755 "$INSTALLER_SRC" "$SBIN_LINK.new"
    mv -f "$SBIN_LINK.new" "$SBIN_LINK"
    say "installed $SBIN_LINK"
else
    warn "could not install $SBIN_LINK: this release has no install.sh and the installer was piped in. Download install.sh and run it as a file."
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

if [ "$MOUNT" -eq 1 ]; then
    step "SMB mounts (from $CONF)"
    if create_conf; then
        load_conf
        apply_mounts
    else
        MOUNT_NOTE="not available: this release has no install.example.conf (use v0.1.1 or newer)"
    fi
else
    MOUNT_NOTE="skipped (--no-mount)"
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
# The options that a later "sudo logs-install" has to repeat.
REPEAT=""
[ "$WEBUI" -eq 1 ] || REPEAT="$REPEAT --no-webui"
[ "$TIMERS" -eq 1 ] || REPEAT="$REPEAT --no-timers"

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
mount_report
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
if [ "$MOUNT_NOTE" = "not configured" ]; then
    say "  $n. Edit $CONF, then run: sudo logs-install$REPEAT"
    say "     (or: sudo logs-install --apply, which only applies the mounts and downloads nothing)"
    n=$((n + 1))
elif [ "$MOUNT_FAILED" -eq 1 ]; then
    say "  $n. Fix the failed mount: edit $CONF, then run: sudo logs-install --apply"
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
