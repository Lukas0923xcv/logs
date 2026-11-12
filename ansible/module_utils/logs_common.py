# -*- coding: utf-8 -*-
# Shared helpers for the logs_* modules. Python 3 standard library only.

from __future__ import absolute_import, division, print_function

__metaclass__ = type

import os
import re

SAFE_NAME = re.compile(r"[^A-Za-z0-9._-]")
VALID_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._@+-]{0,200}$")
DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

# A line counts as an error (or warning) line when it mentions one of these
# words. This is a cheap heuristic for the statistics, nothing more.
ERROR_RE = re.compile(rb"^[^\n]*?\b(?:error|fatal|panic|crit|critical|emerg)\b", re.I | re.M)
WARN_RE = re.compile(rb"^[^\n]*?\b(?:warn|warning)\b", re.I | re.M)

CHUNK = 1024 * 1024


def safe_name(value, fallback="unnamed"):
    """Reduce a host, container or path name to the alphabet the web UI accepts."""
    name = SAFE_NAME.sub("_", str(value)).strip("._-")[:180]
    return name or fallback


def scan_file(path, count_levels=True):
    """Return bytes, lines and (optionally) error/warning line counts.

    The file is read in 1 MiB chunks; an unfinished last line is carried over
    so every line is tested exactly once.
    """
    size = lines = errors = warnings = 0
    carry = b""
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(CHUNK)
            if not chunk:
                break
            size += len(chunk)
            lines += chunk.count(b"\n")
            if not count_levels:
                continue
            data = carry + chunk
            cut = data.rfind(b"\n")
            if cut < 0:
                # No line end yet. Keep at most one chunk of a very long line.
                carry = data[-CHUNK:]
                continue
            carry = data[cut + 1:]
            block = data[:cut]
            errors += sum(1 for _m in ERROR_RE.finditer(block))
            warnings += sum(1 for _m in WARN_RE.finditer(block))
    if carry:
        lines += 1  # last line without a newline
        if count_levels:
            errors += 1 if ERROR_RE.search(carry) else 0
            warnings += 1 if WARN_RE.search(carry) else 0
    return {"bytes": size, "lines": lines, "errors": errors, "warnings": warnings}


def day_parts(day):
    if not DAY_RE.match(day):
        raise ValueError("day must look like YYYY-MM-DD, got %r" % (day,))
    return day[0:4], day[5:7], day[8:10]


def raw_day_dir(root, day):
    year, month, dom = day_parts(day)
    return os.path.join(root, "raw", year, month, dom)


def manifest_path(root, day):
    return os.path.join(root, "manifests", day[0:4], day + ".json")


def parts_dir(root, day):
    return os.path.join(root, "manifests", day[0:4], ".parts", day)


def archive_path(root, day):
    return os.path.join(root, "archive", day[0:4], day + ".tar.zst")
