#!/usr/bin/env bash
# Stop hook: shellcheck the *.sh files changed this session, mirroring the
# CI gate (shellcheck.yml) so a shell regression can't sit in the working tree
# across turns (issue #401). Fast by design — it only lints changed files, so
# a typical turn finishes well under the 10s budget.
#
# Exit codes follow the Claude Code hook contract:
#   0 — nothing to lint, or clean. Turn ends normally.
#   2 — shellcheck found issues; stderr is fed back to Claude as a blocking
#       reason so it fixes the script before finishing.
set -euo pipefail

# Loop guard: when Claude re-runs after a blocking Stop hook it sets
# stop_hook_active. Bail out so we never wedge the turn in a retry loop.
input=$(cat 2>/dev/null || true)
if printf '%s' "$input" | grep -q '"stop_hook_active":[[:space:]]*true'; then
  exit 0
fi

# No shellcheck installed (e.g. fresh clone) → don't block; CI still gates.
command -v shellcheck >/dev/null 2>&1 || exit 0

# Changed tracked *.sh (added/copied/modified/renamed vs HEAD — deletions
# excluded so we never lint a missing path) plus new untracked *.sh. Read with
# a while-loop rather than mapfile so this works on bash 3.2 (macOS default).
present=()
while IFS= read -r f; do
  [[ -n "$f" && -f "$f" ]] && present+=("$f")
done < <(
  {
    git diff --name-only --diff-filter=ACMR HEAD -- '*.sh'
    git ls-files --others --exclude-standard -- '*.sh'
  } | sort -u
)

[[ ${#present[@]} -eq 0 ]] && exit 0

if ! shellcheck "${present[@]}"; then
  echo "Stop hook: shellcheck found issues in changed *.sh files (matches the shellcheck.yml CI gate). Fix them before finishing." >&2
  exit 2
fi
