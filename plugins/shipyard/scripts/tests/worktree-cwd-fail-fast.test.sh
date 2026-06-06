#!/usr/bin/env bash
# Test: the step-0 cwd fail-fast detection predicate (issue #486).
#
# Background — issue #486: an `isolation: "worktree"` dispatch can land with
# its process cwd pinned to the PRIMARY checkout root instead of the created
# worktree. This is a Claude Code *harness*-level misroute — shipyard cannot
# force the dispatch's cwd at the source (AC items (1) and (2) of #486 are out
# of shipyard's control). When it happens on any repo with the global
# enforce-worktree.sh PreToolUse hook installed, every git-mutating command
# targets the user's primary checkout and the hook hard-blocks the worker's
# final `git commit` — but only AFTER the worker has burned its entire run
# (the repro: ~94 min of Opus dying at the final commit).
#
# The shipyard-implementable mitigation (AC items (3) and (4)) is a step-0
# pre-flight assertion in skills/worker-preamble/SKILL.md that fails fast with
# a clear "dispatch-isolation cwd override is wrong" message instead of running
# the full task and dying at commit. The detection predicate it prescribes:
#
#   git rev-parse --git-dir  ==  git rev-parse --git-common-dir
#       ⇒ this cwd is a PRIMARY checkout, NOT an isolated worktree.
#
# The equality holds ONLY for a primary checkout: a linked worktree has a
# separate per-worktree git dir (<common>/worktrees/<name>) distinct from the
# common dir, so git-dir != git-common-dir there.
#
# This test is the behavioral regression guard for AC (4): it builds a real
# primary checkout + a real linked worktree with `git worktree add` and asserts
# the predicate classifies each correctly — independent of the doc-grep guard
# in worker-preamble.test.sh. If the predicate ever stops distinguishing the
# two (a git behavior change, a logic inversion in a future edit of the SKILL),
# this test fails loudly.
#
# Pure bash + git, no network, no external deps. Run with:
#
#   bash plugins/shipyard/scripts/tests/worktree-cwd-fail-fast.test.sh

set -u

GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
pass=0
fail=0

ok()   { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad()  { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

# The exact predicate the SKILL.md step-0 guard prescribes, factored out so the
# test exercises the real classification logic. Echoes "primary" or "worktree"
# for the git checkout rooted at the cwd it is invoked from.
classify_cwd() {
  local git_dir common_dir
  git_dir="$(git rev-parse --git-dir 2>/dev/null)"
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null)"
  # Canonicalize both (they may be relative to cwd) before comparing.
  git_dir="$(cd "$git_dir" 2>/dev/null && pwd -P)"
  common_dir="$(cd "$common_dir" 2>/dev/null && pwd -P)"
  if [ -n "$git_dir" ] && [ "$git_dir" = "$common_dir" ]; then
    echo "primary"
  else
    echo "worktree"
  fi
}

echo "step-0 cwd fail-fast detection-predicate tests (issue #486)"
echo

# Build a throwaway primary checkout. Pin the default branch so the fixture is
# deterministic regardless of the host's init.defaultBranch (worker-preamble
# § "Pin the default branch in git-using test fixtures", issue #475).
tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

primary="$tmproot/primary"
git init -q -b main "$primary"
(
  cd "$primary" || exit 1
  git config user.email test@example.com
  git config user.name 'Test User'
  echo "seed" > seed.txt
  git add seed.txt
  git commit -q -m "seed"
)

# (1) The primary checkout classifies as "primary" (git-dir == git-common-dir).
result="$(cd "$primary" && classify_cwd)"
if [ "$result" = "primary" ]; then
  ok "primary checkout classified as 'primary' (the mispinned-cwd / #486 case)"
else
  bad "primary checkout misclassified as '$result' (expected 'primary')"
fi

# Add a linked worktree mirroring the orchestrated agent worktree layout
# (<primary>/.claude/worktrees/agent-<id>).
worktree="$primary/.claude/worktrees/agent-deadbeef"
(
  cd "$primary" || exit 1
  git worktree add -q -b do-work/issue-486 "$worktree" >/dev/null 2>&1
)

# (2) The linked worktree classifies as "worktree" (git-dir != git-common-dir).
if [ -d "$worktree" ]; then
  result="$(cd "$worktree" && classify_cwd)"
  if [ "$result" = "worktree" ]; then
    ok "linked worktree classified as 'worktree' (the correct-dispatch / no-op case)"
  else
    bad "linked worktree misclassified as '$result' (expected 'worktree')"
  fi

  # (3) The predicate must also hold from a SUBDIRECTORY of the linked worktree
  # — the guard keys on the git-dir relationship, not on the absolute path, so a
  # worker whose cwd is nested inside the worktree still classifies correctly.
  subdir="$worktree/plugins/shipyard"
  mkdir -p "$subdir"
  result="$(cd "$subdir" && classify_cwd)"
  if [ "$result" = "worktree" ]; then
    ok "subdir of linked worktree classified as 'worktree' (path-independent detection)"
  else
    bad "subdir of linked worktree misclassified as '$result' (expected 'worktree')"
  fi

  # (4) A SUBDIRECTORY of the primary checkout still classifies as "primary" —
  # the failure mode #486 documents is the cwd resolving anywhere inside the
  # primary tree, including nested dirs, so the guard must catch those too.
  primary_subdir="$primary/some/nested/dir"
  mkdir -p "$primary_subdir"
  result="$(cd "$primary_subdir" && classify_cwd)"
  if [ "$result" = "primary" ]; then
    ok "subdir of primary checkout classified as 'primary' (catches nested mispin)"
  else
    bad "subdir of primary checkout misclassified as '$result' (expected 'primary')"
  fi
else
  bad "could not create linked worktree fixture (git worktree add failed)"
fi

# (5) The SKILL.md guard must actually wire this predicate in. Grep the skill
# for the load-bearing git-common-dir comparison so a future edit can't quietly
# drop the detection while leaving the prose.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$here"
while [[ "$repo_root" != "/" ]]; do
  if [[ -d "$repo_root/.git" || -f "$repo_root/CHANGELOG.md" ]]; then
    break
  fi
  repo_root="$(dirname "$repo_root")"
done
skill_path="$repo_root/plugins/shipyard/skills/worker-preamble/SKILL.md"
if grep -qF -- "git rev-parse --git-common-dir" "$skill_path" 2>/dev/null; then
  ok "SKILL.md wires the git-common-dir detection predicate the test exercises"
else
  bad "SKILL.md no longer references git rev-parse --git-common-dir (detection dropped)"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
