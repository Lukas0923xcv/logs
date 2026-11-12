#!/usr/bin/env python3
"""Generate a synthetic log share for tests, demos and memory measurements.

    tests/gen-testdata.py DIR [--days 90] [--hosts 12] [--big-mb 0] [--archive-mb 0]

Every line is made up by this script. --big-mb adds one large raw file to the
newest day, --archive-mb one large archived day (needs the zstd command).
"""
import argparse
import datetime
import json
import os
import random
import subprocess

WORDS = ["connection accepted", "request served", "cache refreshed", "job finished", "session opened",
         "WARNING slow response", "ERROR upstream timed out", "health check passed"]


def line(rng, ts, host, n):
    return "%s %s app[%d]: %s id=%08x\n" % (ts.isoformat(), host, n % 900 + 100, rng.choice(WORDS), rng.getrandbits(32))


def write_log(path, rng, day, host, size):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    ts = datetime.datetime.combine(day, datetime.time())
    written = lines = errors = warnings = 0
    with open(path, "w", encoding="utf-8") as out:
        while written < size:
            text = line(rng, ts + datetime.timedelta(seconds=lines % 86400), host, lines)
            out.write(text)
            written += len(text)
            lines += 1
            errors += "ERROR" in text
            warnings += "WARNING" in text
    return {"bytes": written, "lines": lines, "errors": errors, "warnings": warnings, "ok": True, "msg": ""}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--days", type=int, default=90)
    ap.add_argument("--hosts", type=int, default=12)
    ap.add_argument("--raw-days", type=int, default=14)
    ap.add_argument("--big-mb", type=int, default=0)
    ap.add_argument("--archive-mb", type=int, default=0)
    ap.add_argument("--window-log", type=int, default=25)
    args = ap.parse_args()
    rng = random.Random(1)
    last = datetime.date.today() - datetime.timedelta(days=1)

    for back in range(args.days):
        day = last - datetime.timedelta(days=back)
        raw = back < args.raw_days
        day_dir = os.path.join(args.root, "raw", "%04d" % day.year, "%02d" % day.month, "%02d" % day.day)
        hosts = {}
        for h in range(1, args.hosts + 1):
            host = "host%02d" % h
            if rng.random() < 0.02:
                hosts[host] = {"status": "failed", "origin": "ansible", "error": "unreachable (generated)", "sources": []}
                continue
            sources = []
            for src in ["journald", "docker-web", "docker-db"][: 1 + h % 3]:
                size = int(rng.uniform(2000, 60000) * (1 + h / 4))
                if back == 0 and h == 1 and src == "journald" and args.big_mb:
                    size = args.big_mb << 20
                if back == args.raw_days and h == 1 and src == "journald" and args.archive_mb:
                    size = args.archive_mb << 20
                if raw or back == args.raw_days:
                    stats = write_log(os.path.join(day_dir, host, src + ".log"), rng, day, host, size)
                else:  # older days: statistics only, as if the archive had expired
                    stats = {"bytes": size, "lines": size // 80, "errors": size // 8000, "warnings": size // 6000,
                             "ok": True, "msg": ""}
                stats.update(name=src, file=src + ".log")
                sources.append(stats)
            hosts[host] = {"status": "ok", "origin": "ansible", "error": "", "sources": sources}
        mdir = os.path.join(args.root, "manifests", "%04d" % day.year)
        os.makedirs(mdir, exist_ok=True)
        with open(os.path.join(mdir, day.isoformat() + ".json"), "w", encoding="utf-8") as out:
            json.dump({"version": 1, "day": day.isoformat(), "hosts": hosts}, out)
        if back == args.raw_days:  # turn this day into an archive
            adir = os.path.join(args.root, "archive", "%04d" % day.year)
            os.makedirs(adir, exist_ok=True)
            archive = os.path.join(adir, day.isoformat() + ".tar.zst")
            tar = subprocess.Popen(["tar", "-C", day_dir, "-cf", "-"] + sorted(os.listdir(day_dir)), stdout=subprocess.PIPE)
            subprocess.run(["zstd", "-q", "-f", "-3", "--long=%d" % args.window_log, "-o", archive],
                           stdin=tar.stdout, check=True)
            tar.wait()
            subprocess.run(["rm", "-rf", day_dir], check=True)


if __name__ == "__main__":
    main()
