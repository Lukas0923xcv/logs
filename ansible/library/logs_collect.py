#!/usr/bin/python
# -*- coding: utf-8 -*-

from __future__ import absolute_import, division, print_function

__metaclass__ = type

DOCUMENTATION = r"""
module: logs_collect
short_description: Export one day of logs on a host into a staging directory
description:
  - Exports journald and C(docker logs) for an exact time window and the new
    part of extra log files into I(dest), one file per source.
  - Returns size and line statistics per source. A failing source does not
    fail the module; it is reported in the result.
options:
  day: {type: str, required: true, description: "Day being collected, YYYY-MM-DD."}
  since: {type: int, required: true, description: "First second of the window (Unix time)."}
  until: {type: int, required: true, description: "Last second of the window (Unix time)."}
  dest: {type: path, required: true, description: "Staging directory. It is wiped and recreated."}
  owner: {type: str, description: "User that gets ownership of the staging directory."}
  journal: {type: str, default: auto, choices: [auto, "yes", "no"]}
  journal_format: {type: str, default: short-iso-precise}
  docker: {type: str, default: auto, choices: [auto, "yes", "no"]}
  extra_files: {type: list, elements: str, default: [], description: "Paths or globs of extra log files."}
  state_dir: {type: path, default: /var/lib/logs-collect}
  count_levels: {type: bool, default: true}
"""

import datetime
import glob
import json
import os
import shutil
import subprocess

from ansible.module_utils.basic import AnsibleModule
from ansible.module_utils.logs_common import safe_name, scan_file

COMPRESSED = (".gz", ".zst", ".xz", ".bz2", ".lz4", ".zip")
STATE_KEEP_DAYS = 45


def run_to_file(cmd, path):
    """Run cmd with stdout and stderr streamed into path. Returns (rc, tail of stderr)."""
    with open(path, "wb") as out:
        proc = subprocess.run(cmd, stdout=out, stderr=subprocess.PIPE, check=False)
    return proc.returncode, proc.stderr.decode("utf-8", "replace").strip()[-400:]


def want(setting, binary):
    if setting == "no":
        return False, None
    found = shutil.which(binary)
    if setting == "auto" and not found:
        return False, None
    return True, found


def finish(sources, name, path, ok, msg, count_levels):
    entry = {"name": name, "file": os.path.basename(path), "ok": ok, "msg": msg,
             "bytes": 0, "lines": 0, "errors": 0, "warnings": 0}
    if os.path.exists(path):
        entry.update(scan_file(path, count_levels))
    sources.append(entry)
    return entry


def collect_journal(p, sources):
    enabled, binary = want(p["journal"], "journalctl")
    if not enabled:
        return
    path = os.path.join(p["dest"], "journald.log")
    if not binary:
        finish(sources, "journald", path, False, "journalctl not found", False)
        return
    # journalctl treats both ends as inclusive, so the window ends one
    # microsecond before the next day starts: no gap and no duplicate.
    cmd = [binary, "--no-pager", "--quiet", "--output", p["journal_format"],
           "--since", "@%d" % p["since"], "--until", "@%d.999999" % p["until"]]
    rc, err = run_to_file(cmd, path)
    finish(sources, "journald", path, rc == 0, err if rc != 0 else "", p["count_levels"])


def collect_docker(p, sources):
    enabled, binary = want(p["docker"], "docker")
    if not enabled:
        return
    if not binary:
        sources.append({"name": "docker", "file": "", "ok": False, "msg": "docker not found",
                        "bytes": 0, "lines": 0, "errors": 0, "warnings": 0})
        return
    listing = subprocess.run([binary, "ps", "--all", "--format", "{{.Names}}"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if listing.returncode != 0:
        sources.append({"name": "docker", "file": "", "ok": False,
                        "msg": listing.stderr.decode("utf-8", "replace").strip()[-400:],
                        "bytes": 0, "lines": 0, "errors": 0, "warnings": 0})
        return
    for container in sorted(listing.stdout.decode("utf-8", "replace").split()):
        name = "docker-" + safe_name(container)
        path = os.path.join(p["dest"], name + ".log")
        # docker also treats --until as inclusive; it has nanosecond precision.
        cmd = [binary, "logs", "--timestamps", "--since", "%d" % p["since"],
               "--until", "%d.999999999" % p["until"], container]
        with open(path, "wb") as out:
            proc = subprocess.run(cmd, stdout=out, stderr=subprocess.STDOUT, check=False)
        if proc.returncode != 0:
            with open(path, "rb") as handle:
                msg = handle.read(400).decode("utf-8", "replace").strip()
            os.unlink(path)
            finish(sources, name, path, False, msg or "docker logs failed", False)
        elif os.path.getsize(path) == 0:
            os.unlink(path)  # container wrote nothing that day
        else:
            finish(sources, name, path, True, "", p["count_levels"])


def load_state(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            state = json.load(handle)
        if isinstance(state.get("files"), dict):
            return state
    except (OSError, ValueError):
        pass
    return {"files": {}}


def save_state(path, state):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(state, handle, indent=1, sort_keys=True)
    os.replace(tmp, path)


def copy_range(src, start, end, out):
    with open(src, "rb") as handle:
        handle.seek(start)
        left = end - start
        while left > 0:
            chunk = handle.read(min(1024 * 1024, left))
            if not chunk:
                break
            out.write(chunk)
            left -= len(chunk)


def find_rotated(path, inode):
    """Find the uncompressed rotated predecessor of path by its inode."""
    for candidate in glob.glob(glob.escape(path) + "[.-]*"):
        if candidate.endswith(COMPRESSED):
            continue
        try:
            if os.stat(candidate).st_ino == inode:
                return candidate
        except OSError:
            continue
    return None


def collect_extra(p, sources):
    """Copy the part of each extra file that was written since the previous run.

    Plain files carry no reliable timestamps, so they are tracked by inode and
    byte offset instead of by time: every byte is collected exactly once, and
    a second run for the same day copies the same byte range again.
    """
    if not p["extra_files"]:
        return
    state_file = os.path.join(p["state_dir"], "state.json")
    state = load_state(state_file)
    files = state["files"]
    day = p["day"]
    seen = set()

    paths = []
    for pattern in p["extra_files"]:
        matches = sorted(glob.glob(pattern))
        if not matches and not glob.has_magic(pattern):
            name = "file-" + safe_name(pattern)
            sources.append({"name": name, "file": "", "ok": False, "msg": "file not found: " + pattern,
                            "bytes": 0, "lines": 0, "errors": 0, "warnings": 0})
        paths.extend(matches)

    for src in paths:
        if src in seen or not os.path.isfile(src) or src.endswith(COMPRESSED):
            continue
        seen.add(src)
        name = "file-" + safe_name(src[:-4] if src.endswith(".log") else src)
        out_path = os.path.join(p["dest"], name + ".log")
        entry = files.setdefault(src, {"days": {}})
        days = entry["days"]
        added = False
        try:
            st = os.stat(src)
            msg = ""
            plan = []  # (file, start, end)
            if day in days:  # second run for this day: repeat the same range
                rec = days[day]
                if rec["inode"] == st.st_ino and st.st_size >= rec["end"]:
                    plan.append((src, rec["start"], rec["end"]))
                else:
                    old = find_rotated(src, rec["inode"])
                    if not old:
                        raise RuntimeError("rotated since this day was first collected; it cannot be collected again")
                    plan.append((old, rec["start"], rec["end"]))
            elif any(d > day for d in days):
                raise RuntimeError("this file was already collected for a later day")
            else:
                earlier = sorted(d for d in days if d < day)
                start = 0
                if earlier:
                    prev = days[earlier[-1]]
                    if prev["inode"] == st.st_ino and st.st_size >= prev["end"]:
                        start = prev["end"]
                    else:  # rotated or truncated: fetch the rest of the old file first
                        old = find_rotated(src, prev["inode"])
                        if old:
                            plan.append((old, prev["end"], os.stat(old).st_size))
                        else:
                            msg = "rotated; the end of the previous file was not found (compressed or deleted)"
                plan.append((src, start, st.st_size))
                days[day] = {"inode": st.st_ino, "start": start, "end": st.st_size}
                added = True
            with open(out_path, "wb") as out:
                for part, start, end in plan:
                    copy_range(part, start, end, out)
            if os.path.getsize(out_path) == 0 and not msg:
                os.unlink(out_path)  # nothing new
            else:
                finish(sources, name, out_path, True, msg, p["count_levels"])
        except (OSError, RuntimeError, KeyError) as exc:
            if os.path.exists(out_path):
                os.unlink(out_path)
            if added:
                del days[day]  # not collected after all: let the next run retry
            finish(sources, name, out_path, False, str(exc)[:400], False)

    # Forget old day records, and files that disappeared long ago.
    horizon = (datetime.date.fromisoformat(day) - datetime.timedelta(days=STATE_KEEP_DAYS)).isoformat()
    for src in list(files):
        days = files[src]["days"]
        for old in sorted(days)[:-1]:
            if old < horizon:
                del days[old]
        if src not in seen and (not days or max(days) < horizon):
            del files[src]
    save_state(state_file, state)


def main():
    module = AnsibleModule(
        argument_spec=dict(
            day=dict(type="str", required=True),
            since=dict(type="int", required=True),
            until=dict(type="int", required=True),
            dest=dict(type="path", required=True),
            owner=dict(type="str"),
            journal=dict(type="str", default="auto", choices=["auto", "yes", "no"]),
            journal_format=dict(type="str", default="short-iso-precise"),
            docker=dict(type="str", default="auto", choices=["auto", "yes", "no"]),
            extra_files=dict(type="list", elements="str", default=[]),
            state_dir=dict(type="path", default="/var/lib/logs-collect"),
            count_levels=dict(type="bool", default=True),
        ),
        supports_check_mode=False,
    )
    p = module.params
    dest = p["dest"]
    if not os.path.isabs(dest) or dest.rstrip("/").count("/") < 2:
        module.fail_json(msg="dest must be an absolute path at least two levels deep, got %s" % dest)

    sources = []
    try:
        shutil.rmtree(dest, ignore_errors=True)
        os.makedirs(dest, mode=0o700)
        collect_journal(p, sources)
        collect_docker(p, sources)
        collect_extra(p, sources)
        if p["owner"]:
            shutil.chown(dest, user=p["owner"])
            for name in os.listdir(dest):
                shutil.chown(os.path.join(dest, name), user=p["owner"])
                os.chmod(os.path.join(dest, name), 0o600)
    except Exception as exc:  # pylint: disable=broad-except
        shutil.rmtree(dest, ignore_errors=True)
        module.fail_json(msg="log collection failed: %s" % exc)

    failed = [s["name"] for s in sources if not s["ok"]]
    files = sorted(s["file"] for s in sources if s["file"] and os.path.exists(os.path.join(dest, s["file"])))
    module.exit_json(changed=True, dest=dest, sources=sources, failed_sources=failed, files=files)


if __name__ == "__main__":
    main()
