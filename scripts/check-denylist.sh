#!/usr/bin/env bash
# Fail when the repository contains a string from private-denylist.txt.
#
#   scripts/check-denylist.sh            # tracked files, file names, whole history
#   scripts/check-denylist.sh --staged   # only what is staged for the next commit
#
# See private-denylist.example.txt for the format of the list.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

list=private-denylist.txt
if [ ! -f "$list" ]; then
    echo "check-denylist: $list is missing." >&2
    echo "  Create it from private-denylist.example.txt (it is git-ignored)." >&2
    echo "  The check fails without it so that it cannot be skipped by accident." >&2
    exit 1
fi
if git ls-files --error-unmatch "$list" >/dev/null 2>&1; then
    echo "check-denylist: $list is tracked by git. Remove it from the index: git rm --cached $list" >&2
    exit 1
fi

patterns=$(mktemp)
trap 'rm -f "$patterns"' EXIT
sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$list" | grep -v -e '^#' -e '^$' > "$patterns" || true
if [ ! -s "$patterns" ]; then
    echo "check-denylist: $list contains no strings. Add your private values." >&2
    exit 1
fi
if awk 'length($0) < 4 { found = 1 } END { exit !found }' "$patterns"; then
    echo "check-denylist: $list has entries shorter than 4 characters; they would match almost anything." >&2
    exit 1
fi

bad=0
report() { echo "check-denylist: private string found in $1:" >&2; sed 's/^/    /' >&2; bad=1; }

if [ "${1:-}" = "--staged" ]; then
    out=$(git diff --cached --no-color -U0 | grep -E '^\+' | grep -v -E '^\+\+\+ ' | grep -n -i -F -f "$patterns" || true)
    [ -z "$out" ] || report "staged changes" <<< "$out"
    out=$(git diff --cached --name-only | grep -i -F -f "$patterns" || true)
    [ -z "$out" ] || report "staged file names" <<< "$out"
else
    out=$(git grep -n -i -I -F -f "$patterns" -- . || true)
    [ -z "$out" ] || report "tracked files" <<< "$out"
    out=$(git ls-files | grep -i -F -f "$patterns" || true)
    [ -z "$out" ] || report "file names" <<< "$out"
    if git rev-parse --verify -q HEAD >/dev/null; then
        out=$(git log --all --format='commit %h%nauthor %an <%ae>%ncommitter %cn <%ce>%n%B' | grep -n -i -F -f "$patterns" || true)
        [ -z "$out" ] || report "commit messages or author fields" <<< "$out"
        out=$(git log --all -p --no-color --format='commit %h' | grep -E '^(commit |[+-])' | grep -i -F -f "$patterns" | sort -u | head -n 40 || true)
        [ -z "$out" ] || report "the history (also in changes that were removed again)" <<< "$out"
    fi
fi

if [ "$bad" -ne 0 ]; then
    echo "check-denylist: FAILED. Remove the strings above (and rewrite the commits that contain them)." >&2
    exit 1
fi
echo "check-denylist: ok ($(wc -l < "$patterns") strings checked)"
