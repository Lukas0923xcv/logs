#!/usr/bin/python
# -*- coding: utf-8 -*-

from __future__ import absolute_import, division, print_function

__metaclass__ = type

DOCUMENTATION = r"""
module: logs_manifest
short_description: Write the manifest of one collected day
description:
  - Runs on the collector. Merges the per-host results written during the
    run with whatever else is in the day's raw directory (logs pushed by
    helper scripts, imported syslog files) into C(manifests/YYYY/YYYY-MM-DD.json).
  - Optionally imports the day's files of an rsyslog spool first.
options:
  root: {type: path, required: true}
  day: {type: str, required: true}
  since: {type: int, required: true}
  until: {type: int, required: true}
  timezone: {type: str, default: ""}
  expected_hosts: {type: list, elements: str, default: []}
  push_hosts: {type: list, elements: str, default: []}
  syslog_spool: {type: path}
  syslog_names: {type: dict, default: {}}
  syslog_keep_days: {type: int, default: 7}
  count_levels: {type: bool, default: true}
"""

import datetime
import json
import os
import shutil

from ansible.module_utils.basic import AnsibleModule
from ansible.module_utils.logs_common import (VALID_NAME, manifest_path, parts_dir, raw_day_dir,
                                              safe_name, scan_file)


def import_syslog(p, day_dir):
    """Copy <spool>/<sender>/<day>.log to raw/.../<name>/syslog.log."""
    spool = p["syslog_spool"]
    imported = []
    if not spool or not os.path.isdir(spool):
        return imported
    horizon = (datetime.date.fromisoformat(p["day"]) - datetime.timedelta(days=p["syslog_keep_days"])).isoformat()
    for sender in sorted(os.listdir(spool)):
        sender_dir = os.path.join(spool, sender)
        if not os.path.isdir(sender_dir):
            continue
        name = safe_name(p["syslog_names"].get(sender, sender))
        src = os.path.join(sender_dir, p["day"] + ".log")
        if os.path.isfile(src):
            host_dir = os.path.join(day_dir, name)
            os.makedirs(host_dir, exist_ok=True)
            tmp = os.path.join(host_dir, ".syslog.log.tmp")
            shutil.copyfile(src, tmp)
            if os.path.getsize(tmp) != os.path.getsize(src):
                raise RuntimeError("short copy of %s" % src)
            os.replace(tmp, os.path.join(host_dir, "syslog.log"))
            imported.append(name)
        for old in os.listdir(sender_dir):
            if old.endswith(".log") and old[:-4] < horizon:
                try:
                    os.unlink(os.path.join(sender_dir, old))
                except OSError:
                    pass  # not ours to delete; rsyslog owns the spool
    return imported


def main():
    module = AnsibleModule(
        argument_spec=dict(
            root=dict(type="path", required=True),
            day=dict(type="str", required=True),
            since=dict(type="int", required=True),
            until=dict(type="int", required=True),
            timezone=dict(type="str", default=""),
            expected_hosts=dict(type="list", elements="str", default=[]),
            push_hosts=dict(type="list", elements="str", default=[]),
            syslog_spool=dict(type="path"),
            syslog_names=dict(type="dict", default={}),
            syslog_keep_days=dict(type="int", default=7),
            count_levels=dict(type="bool", default=True),
        ),
        supports_check_mode=False,
    )
    p = module.params
    try:
        day = p["day"]
        day_dir = raw_day_dir(p["root"], day)
        os.makedirs(day_dir, exist_ok=True)
        syslog_hosts = import_syslog(p, day_dir)

        hosts = {}
        for name in p["expected_hosts"]:
            part = os.path.join(parts_dir(p["root"], day), name + ".json")
            try:
                with open(part, "r", encoding="utf-8") as handle:
                    hosts[name] = json.load(handle)
            except (OSError, ValueError):
                hosts[name] = {"status": "failed", "origin": "ansible", "sources": [],
                               "error": "no result: the host was unreachable or the run was aborted"}

        # Everything else in the day's directory: pushed or imported logs.
        for name in sorted(os.listdir(day_dir)):
            host_dir = os.path.join(day_dir, name)
            if name.startswith(".") or not os.path.isdir(host_dir) or not VALID_NAME.match(name):
                continue
            host = hosts.setdefault(name, {"status": "ok", "origin": "push", "error": "", "sources": []})
            known = set(s.get("file") for s in host["sources"])
            extra = []
            for fname in sorted(os.listdir(host_dir)):
                fpath = os.path.join(host_dir, fname)
                if fname.startswith(".") or fname in known or not os.path.isfile(fpath):
                    continue
                entry = {"name": fname[:-4] if fname.endswith(".log") else fname, "file": fname, "ok": True, "msg": ""}
                entry.update(scan_file(fpath, p["count_levels"]))
                extra.append(entry)
            host["sources"].extend(extra)
            if host.get("origin") == "push" and extra and all(e["file"] == "syslog.log" for e in host["sources"]):
                host["origin"] = "syslog"

        for name in p["push_hosts"]:
            if name not in hosts:
                hosts[name] = {"status": "failed", "origin": "push", "sources": [],
                               "error": "no logs were pushed for this day"}

        totals = {"bytes": 0, "lines": 0, "errors": 0, "warnings": 0, "hosts_ok": 0, "hosts_failed": 0}
        for host in hosts.values():
            for src in host["sources"]:
                for key in ("bytes", "lines", "errors", "warnings"):
                    totals[key] += int(src.get(key, 0))
            totals["hosts_ok" if host["status"] == "ok" else "hosts_failed"] += 1

        manifest = {
            "version": 1,
            "day": day,
            "window": {"since": p["since"], "until": p["until"], "timezone": p["timezone"]},
            "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "hosts": hosts,
            "totals": totals,
        }
        path = manifest_path(p["root"], day)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(manifest, handle, indent=1, sort_keys=True)
            handle.write("\n")
        os.replace(tmp, path)
    except Exception as exc:  # pylint: disable=broad-except
        module.fail_json(msg="could not write the manifest: %s" % exc)

    problems = dict((n, h.get("error") or "; ".join(
        "%s: %s" % (s["name"], s.get("msg", "")) for s in h["sources"] if not s.get("ok", True)))
        for n, h in hosts.items() if h["status"] != "ok")
    module.exit_json(changed=True, manifest=path, totals=totals, problem_hosts=problems,
                     syslog_hosts=syslog_hosts)


if __name__ == "__main__":
    main()
