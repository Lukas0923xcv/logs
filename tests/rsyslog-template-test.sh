#!/usr/bin/env bash
# Render the rsyslog receiver template for each protocol combination and check
# the result with `rsyslogd -N1`. A port of 0 must switch that protocol off
# completely: no module, no listener, no $AllowedSender line.
#
#   tests/rsyslog-template-test.sh      # needs ansible-core and rsyslog
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
role=$repo/ansible/roles/rsyslog_receiver
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

command -v rsyslogd >/dev/null || fail "rsyslogd is not installed (apt install rsyslog)"

# render <name> <udp port> <tcp port>: renders the template to $work/<name>.conf
# and builds a main config around it, so that the check sees a complete setup.
render() {
    (cd "$repo/ansible" && ANSIBLE_NOCOLOR=1 ansible localhost -m template \
        -a "src=$role/templates/30-logs-receiver.conf.j2 dest=$work/$1.conf" \
        -e "@$role/defaults/main.yml" \
        -e "{\"logs_syslog_udp_port\": $2, \"logs_syslog_tcp_port\": $3, \"logs_syslog_spool\": \"$work/spool\", \"logs_syslog_spool_group\": \"adm\", \"logs_syslog_allowed_senders\": [\"192.0.2.1\", \"198.51.100.0/24\"]}" \
        > "$work/$1.render" 2>&1) || { cat "$work/$1.render"; fail "rendering $1 failed"; }
    {
        echo 'module(load="builtin:omfile")'
        echo '*.* /dev/null'
        echo "\$IncludeConfig $work/$1.conf"
    } > "$work/$1.main"
}
check() { # check <name>: the configuration must pass rsyslogd -N1
    rsyslogd -N1 -f "$work/$1.main" > "$work/$1.out" 2>&1 || { cat "$work/$1.out"; fail "rsyslogd -N1 rejects the $1 configuration"; }
}
has() { grep -q -- "$2" "$work/$1.conf"; }

render both 514 514
check both
has both 'module(load="imudp")' || fail "both: imudp missing"
has both 'module(load="imtcp")' || fail "both: imtcp missing"
has both 'input(type="imudp" port="514"' || fail "both: the udp input is missing"
has both 'input(type="imtcp" port="514"' || fail "both: the tcp input is missing"
has both 'AllowedSender UDP, 192.0.2.1' || fail "both: UDP AllowedSender missing"
has both 'AllowedSender TCP, 192.0.2.1' || fail "both: TCP AllowedSender missing"
ok "udp=514 tcp=514: both modules, both inputs, both AllowedSender kinds; rsyslogd -N1 passes"

render udp-only 514 0
check udp-only
has udp-only 'module(load="imudp")' || fail "udp-only: imudp missing"
! has udp-only 'imtcp' || fail "udp-only: imtcp still mentioned"
! has udp-only 'AllowedSender TCP' || fail "udp-only: TCP AllowedSender emitted"
has udp-only 'AllowedSender UDP, 198.51.100.0/24' || fail "udp-only: UDP AllowedSender missing"
ok "udp=514 tcp=0: only imudp; no imtcp, no TCP lines; rsyslogd -N1 passes"

render tcp-only 0 514
check tcp-only
has tcp-only 'module(load="imtcp")' || fail "tcp-only: imtcp missing"
! has tcp-only 'imudp' || fail "tcp-only: imudp still mentioned"
! has tcp-only 'AllowedSender UDP' || fail "tcp-only: UDP AllowedSender emitted"
has tcp-only 'AllowedSender TCP, 198.51.100.0/24' || fail "tcp-only: TCP AllowedSender missing"
ok "udp=0 tcp=514: only imtcp; no imudp, no UDP lines; rsyslogd -N1 passes"

# Both ports 0: the role must stop at once, before it installs or changes anything.
cat > "$work/play.yml" <<PLAY
- hosts: localhost
  connection: local
  gather_facts: false
  roles:
    - rsyslog_receiver
PLAY
if (cd "$repo/ansible" && ANSIBLE_NOCOLOR=1 ANSIBLE_ROLES_PATH="$repo/ansible/roles" ansible-playbook "$work/play.yml" \
        -e '{"logs_syslog_udp_port": 0, "logs_syslog_tcp_port": 0}' > "$work/zero.out" 2>&1); then
    fail "the role accepted both ports 0"
fi
grep -q "are both 0, so the receiver would" "$work/zero.out" || { cat "$work/zero.out"; fail "no clear message for both ports 0"; }
! grep -q "Install rsyslog" "$work/zero.out" || fail "the role started installing before it checked the ports"
ok "both ports 0: the role fails first, with a clear message"
echo "RSYSLOG TEMPLATE TESTS PASSED"
