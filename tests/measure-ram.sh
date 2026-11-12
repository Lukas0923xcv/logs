#!/usr/bin/env bash
# Measure the memory use of logs-webui against a generated share.
#
#   tests/gen-testdata.py /tmp/share --days 730 --hosts 15 --big-mb 1024 --archive-mb 600
#   tests/measure-ram.sh ./logs-webui /tmp/share
set -euo pipefail
bin=$1 data=$2 port=${3:-18484}
rss() { awk '/^VmRSS|^VmHWM/ {printf "%s %.1f MiB  ", $1, $2/1024}' "/proc/$pid/status"; echo; }

LOGS_DATA_DIR=$data LOGS_LISTEN=127.0.0.1:$port GOMEMLIMIT=48MiB LOGS_FILTER_TIMEOUT=120s "$bin" 2>/dev/null &
pid=$!
trap 'kill $pid 2>/dev/null' EXIT
for _ in $(seq 50); do curl -fs "localhost:$port/healthz" >/dev/null && break; sleep 0.2; done
url="http://127.0.0.1:$port"
latest=$(curl -fs "$url/healthz" | sed 's/.*"latest_day":"\([0-9-]*\)".*/\1/')
arch=$(basename "$(find "$data/archive" -name '*.tar.zst' | sort | tail -1)" .tar.zst)

sleep 2;                                                   echo -n "idle after start:              "; rss
for p in / '/?period=all&range=all' /days "/day/$latest"; do curl -fs "$url$p" >/dev/null; done
sleep 1;                                                   echo -n "after dashboard + browse:      "; rss
n=$(curl -fs "$url/raw/$latest/host01/journald.log" | wc -c); echo -n "download raw file ($((n >> 20)) MiB):   "; rss
curl -fs "$url/view/$latest/host01/journald.log?tail=1" >/dev/null; echo -n "tail page of that file:        "; rss
m=$(curl -fs "$url/view/$latest/host01/journald.log?q=id%3Dffff" | grep -c 'class="off"' || true)
echo -n "filter whole file ($m hits):   "; rss
n=$(curl -fs "$url/extract/$arch/host01/journald.log" | wc -c); echo -n "extract from archive ($((n >> 20)) MiB): "; rss
sleep 5;                                                   echo -n "idle again:                    "; rss
