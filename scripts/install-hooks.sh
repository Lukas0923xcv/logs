#!/usr/bin/env bash
# Enable the repository's git hooks (pre-commit and pre-push) for this clone.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit .githooks/pre-push
echo "Hooks enabled (core.hooksPath = .githooks)."
command -v gitleaks >/dev/null 2>&1 || echo "Note: install gitleaks, the hooks need it: https://github.com/gitleaks/gitleaks"
[ -f private-denylist.txt ] || echo "Note: create private-denylist.txt from private-denylist.example.txt; the hooks need it."
