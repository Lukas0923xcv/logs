#!/usr/bin/env bash
# End-to-end test of the collector and retention playbooks on one machine.
# Everything it reads is generated here; nothing leaves the temporary directory.
#
#   tests/integration.sh            # needs ansible-core, zstd, tar
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap '[ -n "${KEEP:-}" ] && echo "kept $work" || rm -rf "$work"' EXIT
root="$work/share"
mkdir -p "$root" "$work/src" "$work/spool/192.0.2.50"

day=$(date -d '2 days ago' +%F)
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

# --- generated test data -----------------------------------------------------
for i in $(seq 1 200); do
  case $((i % 10)) in
    0) level=ERROR ;; 5) level=WARNING ;; *) level=INFO ;;
  esac
  echo "2025-01-01T00:00:$((i % 60)) app[$i]: $level generated test line $i"
done > "$work/src/app.log"
printf '<13>generated syslog line 1\n<13>generated syslog line 2\n' > "$work/spool/192.0.2.50/$day.log"
mkdir -p "$root/raw/${day//-//}/pusher"
echo "pushed line" > "$root/raw/${day//-//}/pusher/journald.log"

cat > "$work/inventory.yml" <<INV
all:
  hosts:
    web01:
      ansible_connection: local
      logs_extra_files: ["$work/src/app.log", "$work/src/missing-*.log"]
    db01:
      ansible_connection: local
    down01:
      ansible_host: 192.0.2.1
      ansible_ssh_common_args: "-o ConnectTimeout=3 -o BatchMode=yes"
  vars:
    ansible_python_interpreter: "$(command -v python3)"
    ansible_become: false
INV

vars=(-e "logs_root=$root" -e '{"logs_root_fstypes": []}' -e "logs_remote_tmp=$work/stage"
      -e "logs_remote_state_dir=$work/state" -e "logs_syslog_spool=$work/spool"
      -e '{"logs_syslog_names": {"192.0.2.50": "firewall"}, "logs_push_hosts": ["pusher", "silent"]}'
      -e "logs_day=$day" -e logs_docker=no)
play() { ANSIBLE_NOCOLOR=1 ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i "$work/inventory.yml" "$@"; }
manifest="$root/manifests/${day:0:4}/$day.json"
q() { python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$manifest" "$1"; }

# --- 1. collect: one host is unreachable, the others must still be collected --
set +e
play "$repo/ansible/collect.yml" "${vars[@]}" > "$work/run1.log" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "run with a failed host should end non-zero"
[ -f "$manifest" ] || { tail -40 "$work/run1.log"; fail "no manifest written"; }
[ "$(q 'm["hosts"]["web01"]["status"]')" = ok ] || fail "web01 not ok"
[ "$(q 'm["hosts"]["db01"]["status"]')" = ok ] || fail "db01 not ok"
[ "$(q 'm["hosts"]["down01"]["status"]')" = failed ] || fail "down01 should be failed"
[ "$(q 'm["hosts"]["silent"]["status"]')" = failed ] || fail "missing push host should be failed"
[ "$(q 'm["hosts"]["pusher"]["origin"]')" = push ] || fail "pusher not picked up"
[ "$(q 'm["hosts"]["firewall"]["origin"]')" = syslog ] || fail "syslog spool not imported"
ok "unreachable host recorded, other hosts collected"

src='[s for s in m["hosts"]["web01"]["sources"] if s["name"].startswith("file-")][0]'
[ "$(q "${src}[\"lines\"]")" = 200 ] || fail "expected 200 lines"
[ "$(q "${src}[\"errors\"]")" = 20 ] || fail "expected 20 error lines"
[ "$(q "${src}[\"warnings\"]")" = 20 ] || fail "expected 20 warning lines"
file="$root/raw/${day//-//}/web01/$(q "${src}[\"file\"]")"
cmp -s "$file" "$work/src/app.log" || fail "collected file differs from the source"
ok "extra file collected with correct statistics"

# --- 2. second run for the same day: nothing is duplicated -------------------
echo "2025-01-01T00:01:00 app: INFO written after the first run" >> "$work/src/app.log"
sum1=$(cd "$root/raw" && find . -type f -exec sha256sum {} + | sort | sha256sum)
play "$repo/ansible/collect.yml" "${vars[@]}" -e logs_force=true -e logs_fail_on_host_failure=false > "$work/run2.log" 2>&1 \
  || { tail -40 "$work/run2.log"; fail "second run failed"; }
sum2=$(cd "$root/raw" && find . -type f -exec sha256sum {} + | sort | sha256sum)
[ "$sum1" = "$sum2" ] || fail "second run changed the collected data"
ok "second run for the same day is idempotent"

# --- 3. next day gets only the new line ---------------------------------------
day2=$(date -d yesterday +%F)
play "$repo/ansible/collect.yml" "${vars[@]}" -e "logs_day=$day2" -e logs_fail_on_host_failure=false > "$work/run3.log" 2>&1 \
  || { tail -40 "$work/run3.log"; fail "third run failed"; }
[ "$(cat "$root/raw/${day2//-//}/web01/"file-*.log | wc -l)" = 1 ] || fail "next day should hold exactly the one new line"
ok "next day contains only new data (no gap, no duplicate)"

# --- 4. retention: archive, verify, delete raw, keep manifests ---------------
future=$(date -d '+70 days' +%F)
play "$repo/ansible/retention.yml" "${vars[@]}" -e "logs_retention_today=$future" > "$work/run4.log" 2>&1 \
  || { tail -40 "$work/run4.log"; fail "retention failed"; }
archive="$root/archive/${day:0:4}/$day.tar.zst"
[ -f "$archive" ] || fail "archive missing"
zstd -t -q "$archive" || fail "archive does not verify"
[ ! -d "$root/raw/${day//-//}" ] || fail "raw day still there"
[ -f "$manifest" ] || fail "manifest must survive archiving"
zstd -dc "$archive" | tar -xO web01/"$(basename "$file")" | head -1 | grep -q 'generated test line 1$' \
  || fail "archive content wrong"
ok "raw day archived, verified and removed; manifest kept"

play "$repo/ansible/retention.yml" "${vars[@]}" -e "logs_retention_today=$future" -e logs_archive_days=30 > "$work/run5.log" 2>&1 \
  || { tail -40 "$work/run5.log"; fail "archive expiry failed"; }
[ ! -f "$archive" ] || fail "old archive should be deleted"
[ -f "$manifest" ] || fail "manifest must survive archive expiry"
ok "old archives expire, manifests stay"
echo "ALL INTEGRATION TESTS PASSED"
