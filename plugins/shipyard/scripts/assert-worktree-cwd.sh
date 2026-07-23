#!/usr/bin/env bash
# assert-worktree-cwd.sh — the SINGLE EXECUTABLE SOURCE OF TRUTH for shipyard's
# worktree-vs-primary-checkout cwd predicate.
#
# Background (issues #486, #748, #802, #826)
# -------------------------------------------
# Two worker-preamble guards both need to answer "is this directory an
# isolated linked worktree, or the PRIMARY checkout?":
#
#   - Step-0 cwd fail-fast (#486): asked once, at dispatch start, before any
#     task work — catches an `isolation: "worktree"` dispatch whose process
#     cwd was pinned to the primary checkout root instead of the created
#     worktree (a harness-level misroute shipyard cannot fix at the source).
#   - Mid-session cwd anchoring (#748): re-asked immediately before every
#     mutating git/gh call, against a cached WORKTREE_PATH, because plain
#     relative-path Bash calls were observed drifting onto the primary
#     checkout later in the same dispatch with no `cd` ever issued.
#
# Both used to inline the SAME predicate directly in
# skills/worker-preamble/SKILL.md as a compound `if` + command-substitution
# snippet. That compound shape is exactly what the harness's Auto Mode
# classifier refuses to run as one Bash tool call ("this command is too
# complex to verify that it stays inside the worktree; break it into plain,
# separate commands" — #826's repro). #802 first decomposed the compound into
# three separate plain `git rev-parse` calls with the WORKER doing the
# comparison by reading the outputs; #826 finishes that job by extracting the
# comparison itself into this script, so the rule exists in exactly one place
# instead of prose duplicated across two SKILL.md sections that can drift —
# the same fix #716 applied to the ungated-admin-direct-merge rule via
# detect-ungated-admin-direct-merge.sh, cited in #826 as the precedent.
#
# The predicate itself is UNCHANGED from #486 / #748 — this script does not
# reinterpret it, only relocates it:
#
#   git rev-parse --git-dir  ==  git rev-parse --git-common-dir
#     => this directory is a PRIMARY checkout, NOT an isolated worktree.
#
# The equality holds ONLY for a primary checkout: a linked worktree has a
# separate per-worktree git dir (<common>/worktrees/<name>) distinct from the
# common dir, so git-dir != git-common-dir there — regardless of how deep
# under the tree the directory sits. `git rev-parse --git-dir` /
# `--git-common-dir` can each return either an absolute path or a path
# relative to the queried directory depending on how deep that directory is
# nested (observed: both relative at a worktree root, one absolute one
# relative from a subdirectory) — so both are canonicalized (`cd` + `pwd -P`)
# before comparing; a bare string compare of the raw values is NOT reliable.
#
# This script is a PURE PREDICATE, not a message generator. Step-0 and
# mid-session use DIFFERENT `blocked:` wording for the SAME underlying
# signal (#486's "dispatch-isolation cwd override is wrong" vs #748's "cwd
# anchor drifted mid-session") — composing the exact `blocked:` text stays the
# CALLER's job (worker-preamble § "Step-0 cwd fail-fast" / § "Mid-session cwd
# anchoring"). Baking one message in here would make it wrong at the other
# call site — this is why the two prose copies existed as prose in the first
# place, and why this script only returns a terse verdict rather than either
# message verbatim.
#
# Usage:
#   bash assert-worktree-cwd.sh [DIR]
#     DIR defaults to the cwd (`.`) when omitted. Every git read is issued as
#     `git -C DIR ...`, so a caller holding a cached WORKTREE_PATH can assert
#     against it directly without first `cd`-ing there (this is exactly how
#     worker-preamble's mid-session anchoring re-verification uses it).
#
#     -> exit 0, prints `worktree` on stdout: DIR is a correctly-isolated
#        linked worktree (git-dir != git-common-dir). This is the healthy,
#        common-case path and is a no-op for the caller.
#     -> exit 1, prints `primary` on stdout: DIR is the PRIMARY checkout
#        (git-dir == git-common-dir). The caller MUST stop and return a
#        `blocked:` string worded per its own section — see the "PURE
#        PREDICATE" note above.
#     -> exit 2, prints `error` on stdout: DIR does not resolve to a git
#        working tree at all (the `git rev-parse` reads themselves failed —
#        e.g. DIR doesn't exist, or isn't inside any git repo). The caller
#        should also treat this as blocked, but cannot cite a meaningful
#        TOPLEVEL for it.
#
#   Full diagnostics (dir/toplevel/git-dir/common-dir/verdict) always go to
#   stderr, mirroring the stdout-terse/stderr-diagnostic convention already
#   used by scripts/detect-ungated-admin-direct-merge.sh.
#
# Fail-safe posture: any signal that cannot be read resolves toward the
# stricter outcome (`error`, treated as blocked by the caller), never toward
# silently reporting `worktree`. Matches the mispinned-cwd guard's own
# asymmetry — a false "worktree" here is the one outcome that lets a
# catastrophic mispinned-cwd dispatch run to completion undetected.

set -u

usage() {
  cat >&2 <<'EOF'
usage: assert-worktree-cwd.sh [DIR]
  DIR defaults to the cwd ('.') when omitted.

  Prints `worktree` (exit 0) if DIR is a correctly-isolated linked git
  worktree, `primary` (exit 1) if DIR is the PRIMARY checkout (git-dir ==
  git-common-dir), or `error` (exit 2) if DIR doesn't resolve to a git
  working tree at all. Full diagnostics always go to stderr.

  See the header comment in this file for the #486 / #748 / #826 background.
EOF
  exit 2
}

case "${1:-}" in
  -h|--help) usage ;;
esac

dir="${1:-.}"

toplevel="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)"
git_dir_raw="$(git -C "$dir" rev-parse --git-dir 2>/dev/null)"
common_dir_raw="$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null)"

if [ -z "$git_dir_raw" ] || [ -z "$common_dir_raw" ]; then
  {
    echo "assert-worktree-cwd: '$dir' does not resolve to a git working tree"
    echo "(git rev-parse --git-dir / --git-common-dir failed against it)"
  } >&2
  printf 'error\n'
  exit 2
fi

# Canonicalize — each raw value may be printed relative to $dir (observed:
# both are relative at a worktree root; one absolute and one relative from a
# subdirectory), so a bare string compare of the raw values is unreliable.
git_dir_abs="$(cd "$dir" 2>/dev/null && cd "$git_dir_raw" 2>/dev/null && pwd -P)"
common_dir_abs="$(cd "$dir" 2>/dev/null && cd "$common_dir_raw" 2>/dev/null && pwd -P)"

if [ -z "$git_dir_abs" ] || [ -z "$common_dir_abs" ]; then
  {
    echo "assert-worktree-cwd: could not canonicalize git-dir/git-common-dir for '$dir'"
    echo "git-dir(raw)=$git_dir_raw common-dir(raw)=$common_dir_raw"
  } >&2
  printf 'error\n'
  exit 2
fi

{
  printf 'dir=%s toplevel=%s\n' "$dir" "$toplevel"
  printf 'git-dir=%s\n' "$git_dir_abs"
  printf 'git-common-dir=%s\n' "$common_dir_abs"
} >&2

if [ "$git_dir_abs" = "$common_dir_abs" ]; then
  echo "verdict=primary -- this is the PRIMARY checkout, not an isolated worktree." >&2
  printf 'primary\n'
  exit 1
fi

echo "verdict=worktree -- this is a correctly-isolated linked worktree." >&2
printf 'worktree\n'
exit 0
