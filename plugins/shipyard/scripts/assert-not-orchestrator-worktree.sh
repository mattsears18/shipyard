#!/usr/bin/env bash
# assert-not-orchestrator-worktree.sh — a cheap predicate for "is this
# worker's worktree actually the /shipyard:do-work ORCHESTRATOR's own
# worktree?"
#
# Background (issue #1613)
# -------------------------
# worker-preamble's step-0 cwd fail-fast compares `git rev-parse --git-dir`
# against `--git-common-dir`: equal means a PRIMARY checkout, different means
# "a linked worktree — proceed". The orchestrator's own worktree
# (`.claude/worktrees/orchestrator-<session-id>`, or a hand-named variant such
# as lightwork's `do-work-orchestrator-<date>`) is ALSO a linked worktree, so
# a worker whose Bash isolation the harness pinned to the orchestrator's tree
# sails straight through that check. Claude Code's own isolation guard doesn't
# catch it either: it refuses the MAIN checkout, and the orchestrator's tree
# isn't the main checkout.
#
# #1613 observed this twice in one lightwork session (plugin 4.55.28), once in
# fix-checks-only and once in issue-work — both Agent-tool dispatches against
# shims declaring `isolation: worktree`, while four sibling issue-work
# dispatches in the same session got correct `agent-*` worktrees. The first
# worker was unwarned and wrote into the orchestrator's tree (checked it out
# detached at a PR head, left an uncommitted edit, and the orchestrator's
# `.shipyard-session-id` stash was gone afterwards). The pin itself is set by
# the harness at launch and can't be fixed from this repo; this script is the
# shipyard-side tripwire that turns the silent case into a loud one.
#
# Detection — either signal is sufficient:
#   (a) the toplevel's basename matches `orchestrator-*` or `*-orchestrator-*`
#       (setup step 0.5's naming, plus hand-named variants);
#   (b) an orchestrator-only stash file is present at the toplevel:
#       `.shipyard-session-id` (setup step 0.55) or `.shipyard-primary-root`
#       (step 0.56). A worker's own `agent-*` worktree never carries either.
#
# Usage:
#   assert-not-orchestrator-worktree.sh <DIR>
#
#   -> exit 0, prints `ok`           DIR is not the orchestrator's worktree.
#   -> exit 1, prints `orchestrator` DIR IS the orchestrator's worktree (or
#                                    carries its stash files). The caller must
#                                    not write here — see worker-preamble's
#                                    orchestrator-worktree-pin.md fragment.
#   -> exit 2, prints `error`        DIR doesn't resolve to a git working tree.
#
# Diagnostics (toplevel + which signal fired) go to stderr, matching
# assert-branch-switched.sh's stdout-terse / stderr-diagnostic convention.
# Read-only: it never writes, moves, or deletes anything.

set -u

usage() {
  cat >&2 <<'EOF'
usage: assert-not-orchestrator-worktree.sh <DIR>

  DIR is required — the caller's own re-derived worktree path, never
  defaulted. Prints `ok` (exit 0) when DIR is not the /shipyard:do-work
  orchestrator's worktree, `orchestrator` (exit 1) when it is (basename
  orchestrator-* / *-orchestrator-*, or a .shipyard-session-id /
  .shipyard-primary-root stash at its toplevel), `error` (exit 2) when DIR
  doesn't resolve to a git working tree. See issue #1613. --help exits 0.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

dir="${1:-}"
if [ -z "$dir" ]; then
  usage
  exit 2
fi

toplevel="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$toplevel" ]; then
  echo "assert-not-orchestrator-worktree: '$dir' does not resolve to a git working tree" >&2
  printf 'error\n'
  exit 2
fi

base="${toplevel##*/}"
reason=""
case "$base" in
  orchestrator-*|*-orchestrator-*) reason="basename '$base' is an orchestrator worktree name" ;;
esac

if [ -z "$reason" ]; then
  for marker in .shipyard-session-id .shipyard-primary-root; do
    if [ -e "$toplevel/$marker" ]; then
      reason="orchestrator stash file '$marker' is present at the toplevel"
      break
    fi
  done
fi

printf 'toplevel=%s\n' "$toplevel" >&2
if [ -n "$reason" ]; then
  echo "verdict=orchestrator -- $reason (see issue #1613)" >&2
  printf 'orchestrator\n'
  exit 1
fi

echo "verdict=ok -- not the orchestrator's worktree." >&2
printf 'ok\n'
exit 0
