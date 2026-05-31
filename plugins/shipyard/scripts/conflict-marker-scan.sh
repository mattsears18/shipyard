#!/usr/bin/env bash
# conflict-marker-scan.sh — fail if any tracked file carries an unresolved
# Git conflict marker.
#
# Background (issue #436): during a high-concurrency `/shipyard:do-work`
# session, a fix-rebase/merge force-pushed a `CHANGELOG.md` carrying
# unresolved conflict markers (`=======` / `>>>>>>> <sha>`) which then
# merged to `main`. None of the existing CI gates (shellcheck, bash tests,
# secret-scan) grep for conflict markers, so the corruption rode a green
# CI run onto the default branch and every subsequent PR branched from a
# poisoned base. This script is the cheap repo-side catch-net: a single
# `git grep` that fails loudly the moment a marker reaches a tracked file.
#
# It mirrors the `check-merge-conflict` pre-commit hook in
# `.pre-commit-config.yaml`, but unlike that hook (opt-in / local-only) it
# runs in CI on every push + PR (see `.github/workflows/conflict-markers.yml`)
# so the gate fires even when a contributor hasn't run `pre-commit install`.
#
# Detection: a real conflict marker is exactly seven of `<`, `=`, or `>` at
# the start of a line, followed by a space or end-of-line:
#
#   <<<<<<< HEAD
#   =======
#   >>>>>>> 0ff725a
#
# The anchored, exactly-7, trailing-space-or-EOL regex is precise enough
# that prose discussing markers inline (e.g. a doc that writes `=======`
# inside backticks, or this script's own comments) does NOT match — those
# are mid-line, backtick-wrapped, or not exactly seven chars. The pattern
# matches the one the fix-rebase worker uses before force-pushing
# (`agents/issue-worker/fix-rebase.md` step 5) so the local-worker assertion
# and this CI gate agree on what "a marker" is.
#
# Files that legitimately contain bare marker lines (test fixtures that
# CONSTRUCT a conflicted file to exercise this very scanner) opt out with a
# `conflict-marker-scan: allow` directive somewhere in the file. Keep that
# allowlist as small as possible — it is a hole in the gate.
#
# Usage:
#   bash plugins/shipyard/scripts/conflict-marker-scan.sh            # scan tracked files
#   bash plugins/shipyard/scripts/conflict-marker-scan.sh <path>...  # scan explicit paths
#
# Exit status: 0 = clean, 1 = marker(s) found (prints offending file:line),
# 2 = usage / environment error (not in a git repo, etc.).

set -u

# Anchored conflict-marker pattern, shared with fix-rebase.md step 5.
MARKER_RE='^(<{7}|={7}|>{7})( |$)'

# Opt-out directive a fixture file can carry to exclude itself from the gate.
ALLOW_DIRECTIVE='conflict-marker-scan: allow'

usage() {
  cat >&2 <<'EOF'
usage: conflict-marker-scan.sh [path ...]
  With no args, scans every tracked file in the current git repo.
  With paths, scans only those (still skips files carrying the
  `conflict-marker-scan: allow` opt-out directive).
EOF
  exit 2
}

case "${1:-}" in
  -h|--help) usage ;;
esac

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "conflict-marker-scan: not inside a git work tree" >&2
  exit 2
fi

# Build the candidate file list. Explicit args win; otherwise scan all
# tracked files. `git grep` already restricts to tracked content, so an
# untracked scratch file with markers won't trip the gate (it can't merge
# to main anyway).
candidates=()
if [[ $# -gt 0 ]]; then
  candidates=("$@")
else
  while IFS= read -r -d '' f; do
    candidates+=("$f")
  done < <(git ls-files -z)
fi

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "conflict-marker-scan: no tracked files to scan" >&2
  exit 0
fi

found=0
for f in "${candidates[@]}"; do
  [[ -f "$f" ]] || continue
  # Skip files that explicitly opt out (test fixtures that construct a
  # conflicted file on purpose).
  if grep -qF -- "$ALLOW_DIRECTIVE" "$f" 2>/dev/null; then
    continue
  fi
  # `grep -nE` prints `<line>:<text>`; prefix with the filename ourselves so
  # the output is `file:line:text` regardless of how many files matched.
  if hits=$(grep -nE -- "$MARKER_RE" "$f" 2>/dev/null); then
    while IFS= read -r line; do
      printf '%s:%s\n' "$f" "$line"
    done <<<"$hits"
    found=1
  fi
done

if [[ "$found" -eq 1 ]]; then
  echo >&2
  echo "conflict-marker-scan: unresolved Git conflict marker(s) found in tracked file(s)." >&2
  echo "Resolve the conflict and remove the marker lines before merging (issue #436)." >&2
  exit 1
fi

echo "conflict-marker-scan: no conflict markers in tracked files."
exit 0
