#!/usr/bin/python
# -*- coding: utf-8 -*-

from __future__ import absolute_import, division, print_function

__metaclass__ = type

DOCUMENTATION = r"""
module: logs_retention
short_description: Archive old raw days and expire old archives
description:
  - Compresses every raw day older than I(raw_days) into
    C(archive/YYYY/YYYY-MM-DD.tar.zst), verifies the archive and only then
    deletes the raw directory. Manifests are never touched.
  - Afterwards deletes archives older than I(archive_days) and, oldest
    first, archives above I(archive_max_bytes). Both limits are off at 0.
options:
  root: {type: path, required: true}
  today: {type: str, required: true, description: "Current day, YYYY-MM-DD."}
  raw_days: {type: int, default: 60}
  archive_days: {type: int, default: 0}
  archive_max_bytes: {type: int, default: 0}
  zstd_level: {type: int, default: 19}
  zstd_window_log: {type: int, default: 25}
  zstd_threads: {type: int, default: 1}
"""

import datetime
import os
import re
import shutil
import subprocess

from ansible.module_utils.basic import AnsibleModule
from ansible.module_utils.logs_common import archive_path, parts_dir

ARCHIVE_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})\.tar\.zst$")


def raw_days(root):
    """Yield (day, path) for every raw/YYYY/MM/DD directory."""
    base = os.path.join(root, "raw")
    for year in sorted(os.listdir(base)) if os.path.isdir(base) else []:
        if not re.match(r"^\d{4}$", year):
            continue
        for month in sorted(os.listdir(os.path.join(base, year))):
            if not re.match(r"^\d{2}$", month):
                continue
            for dom in sorted(os.listdir(os.path.join(base, year, month))):
                path = os.path.join(base, year, month, dom)
                if re.match(r"^\d{2}$", dom) and os.path.isdir(path):
                    yield "%s-%s-%s" % (year, month, dom), path


def members(day_dir):
    """Relative paths of all regular files of a day, sorted."""
    found = []
    for host in sorted(os.listdir(day_dir)):
        host_dir = os.path.join(day_dir, host)
        if host.startswith(".") or not os.path.isdir(host_dir):
            continue
        for name in sorted(os.listdir(host_dir)):
            if not name.startswith(".") and os.path.isfile(os.path.join(host_dir, name)):
                found.append(host + "/" + name)
    return found


def verify(archive, expected, window_log):
    """zstd -t checks the frame checksum; the listing proves every file is inside."""
    test = subprocess.run(["zstd", "-t", "-q", "--long=%d" % window_log, archive],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if test.returncode != 0:
        raise RuntimeError("zstd -t failed for %s: %s" % (archive, test.stderr.decode("utf-8", "replace")[-300:]))
    unz = subprocess.Popen(["zstd", "-dc", "-q", "--long=%d" % window_log, archive], stdout=subprocess.PIPE)
    listing = subprocess.run(["tar", "-tf", "-"], stdin=unz.stdout, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, check=False)
    unz.stdout.close()
    if unz.wait() != 0 or listing.returncode != 0:
        raise RuntimeError("could not list %s" % archive)
    inside = sorted(n for n in listing.stdout.decode("utf-8", "replace").splitlines() if n and not n.endswith("/"))
    if inside != sorted(expected):
        raise RuntimeError("%s does not contain exactly the raw files (%d in archive, %d on disk)"
                           % (archive, len(inside), len(expected)))


def compress(day_dir, files, archive, p):
    os.makedirs(os.path.dirname(archive), exist_ok=True)
    tmp = os.path.join(os.path.dirname(archive), "." + os.path.basename(archive) + ".tmp")
    if os.path.exists(tmp):
        os.unlink(tmp)
    tar = subprocess.Popen(["tar", "-C", day_dir, "-cf", "-", "--"] + files,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    zstd = subprocess.run(
        ["nice", "-n", "19", "zstd", "-q", "-%d" % p["zstd_level"], "--long=%d" % p["zstd_window_log"],
         "-T%d" % p["zstd_threads"], "-o", tmp],
        stdin=tar.stdout, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    tar.stdout.close()
    tar_err = tar.stderr.read().decode("utf-8", "replace")
    if tar.wait() != 0 or zstd.returncode != 0:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise RuntimeError("compression failed: %s %s" % (tar_err[-300:], zstd.stderr.decode("utf-8", "replace")[-300:]))
    verify(tmp, files, p["zstd_window_log"])
    os.replace(tmp, archive)


def remove_empty_parents(path, stop):
    path = os.path.dirname(path)
    while path != stop and path.startswith(stop):
        try:
            os.rmdir(path)
        except OSError:
            return
        path = os.path.dirname(path)


def main():
    module = AnsibleModule(
        argument_spec=dict(
            root=dict(type="path", required=True),
            today=dict(type="str", required=True),
            raw_days=dict(type="int", default=60),
            archive_days=dict(type="int", default=0),
            archive_max_bytes=dict(type="int", default=0),
            zstd_level=dict(type="int", default=19),
            zstd_window_log=dict(type="int", default=25),
            zstd_threads=dict(type="int", default=1),
        ),
        supports_check_mode=True,
    )
    p = module.params
    root = p["root"]
    if p["raw_days"] < 1:
        module.fail_json(msg="raw_days must be at least 1")
    if not 1 <= p["zstd_level"] <= 22 or not 10 <= p["zstd_window_log"] <= 31:
        module.fail_json(msg="zstd_level must be 1-22 and zstd_window_log 10-31")
    for tool in ("tar", "zstd"):
        if not shutil.which(tool):
            module.fail_json(msg="%s is not installed on the collector" % tool)

    archived, removed_raw, expired, errors = [], [], [], []
    try:
        today = datetime.date.fromisoformat(p["today"])
        raw_cutoff = (today - datetime.timedelta(days=p["raw_days"])).isoformat()

        # 1. raw -> archive. A day is "older than N days" when day < today - N.
        for day, day_dir in raw_days(root):
            if day >= raw_cutoff:
                continue
            archive = archive_path(root, day)
            files = members(day_dir)
            if module.check_mode:
                archived.append(day)
                continue
            try:
                if files:
                    if os.path.exists(archive):
                        verify(archive, files, p["zstd_window_log"])  # finish an interrupted run
                    else:
                        compress(day_dir, files, archive, p)
                        archived.append(day)
                shutil.rmtree(day_dir)
                shutil.rmtree(parts_dir(root, day), ignore_errors=True)
                remove_empty_parents(day_dir, os.path.join(root, "raw"))
                removed_raw.append(day)
            except (OSError, RuntimeError) as exc:
                errors.append("%s: %s" % (day, exc))  # keep the raw day, try the next one

        # 2. expire archives by age, then by total size (oldest first).
        archives = []
        base = os.path.join(root, "archive")
        for year in sorted(os.listdir(base)) if os.path.isdir(base) else []:
            year_dir = os.path.join(base, year)
            if not os.path.isdir(year_dir):
                continue
            for name in sorted(os.listdir(year_dir)):
                match = ARCHIVE_RE.match(name)
                if match:
                    path = os.path.join(year_dir, name)
                    archives.append((match.group(1), path, os.path.getsize(path)))
        doomed = []
        if p["archive_days"] > 0:
            cutoff = (today - datetime.timedelta(days=p["archive_days"])).isoformat()
            doomed = [a for a in archives if a[0] < cutoff]
        keep = [a for a in archives if a not in doomed]
        if p["archive_max_bytes"] > 0:
            total = sum(a[2] for a in keep)
            while keep and total > p["archive_max_bytes"]:
                oldest = keep.pop(0)
                total -= oldest[2]
                doomed.append(oldest)
        for day, path, _size in doomed:
            if not module.check_mode:
                os.unlink(path)
                remove_empty_parents(path, base)
            expired.append(day)
        archive_bytes = sum(a[2] for a in keep)
    except Exception as exc:  # pylint: disable=broad-except
        module.fail_json(msg="retention failed: %s" % exc, archived=archived, expired=expired, errors=errors)

    result = dict(changed=bool(archived or removed_raw or expired), archived=archived, removed_raw=removed_raw,
                  expired=expired, errors=errors, archive_bytes=archive_bytes)
    if errors:
        module.fail_json(msg="retention finished with errors: " + "; ".join(errors), **result)
    module.exit_json(**result)


if __name__ == "__main__":
    main()
