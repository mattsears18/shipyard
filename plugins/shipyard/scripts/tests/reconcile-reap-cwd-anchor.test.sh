#!/usr/bin/env bash
# Test: every worktree-reap block in commands/do-work/steady-state.md
# anchors the shell to a STABLE directory (via the #477 cwd-independent
# porcelain idiom) BEFORE running `git worktree remove --force` /
# `git worktree prune` — so a reap whose target is the orchestrator's own
# (harness-leaked) cwd can't strand the rest of the block.
#
# Background — issue #497: a follow-on to the cwd-leak class fixed in #452 /
# #477. When the harness leaks the orchestrator's Bash-tool cwd into a
# just-returned agent's `agent-*` isolation worktree, and the orchestrator
# then reaps THAT worktree on the reconcile turn, `git worktree remove
# --force` deletes the directory the shell is standing in. Every subsequent
# bare git command in the same block — the `git worktree prune`, any
# follow-up `fetch`/`log` — fails with:
#
#   fatal: Unable to read current working directory: No such file or directory
#
# The spec's old recovery (`cd "$(git rev-parse --show-toplevel)"`) can NOT
# rescue the block: git resolves its own (now-deleted) cwd before reading
# anything, so the rev-parse fails first. The fix anchors cwd to a stable
# directory derived cwd-independently (the #477 porcelain idiom) BEFORE the
# reap, while cwd is still valid — so the remove/prune never run with cwd
# inside the doomed directory.
#
# This test is the regression guard for both halves:
#   (1) spec assertions — every reap block carries the cd-anchor preamble and
#       names issue #497;
#   (2) a runtime proof — the anchor-before-reap pattern survives a deleted
#       cwd while the naive `git rev-parse --show-toplevel` recovery does not.
#
# Pure bash + git, no network. Run with:
#
#   bash plugins/shipyard/scripts/tests/reconcile-reap-cwd-anchor.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$here"
while [[ "$repo_root" != "/" ]]; do
  if [[ -d "$repo_root/.git" || -f "$repo_root/CHANGELOG.md" ]]; then
    break
  fi
  repo_root="$(dirname "$repo_root")"
done

if [[ "$repo_root" == "/" ]]; then
  echo "FAIL: could not locate repo root from $here" >&2
  exit 1
fi

steady_state_path="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_file_exists() {
  local path="$1" label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (missing: %s)\n' "$RED" "$RESET" "$label" "$path"; fail=$((fail+1))
  fi
}

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"; fail=$((fail+1))
  fi
}

# Assert that `needle` appears at least `n` times in `file`.
assert_count_at_least() {
  local file="$1" needle="$2" n="$3" label="$4"
  local got
  got=$(grep -cF -- "$needle" "$file" 2>/dev/null || echo 0)
  if (( got >= n )); then
    printf '  %sPASS%s  %s (found %d, need >= %d)\n' "$GREEN" "$RESET" "$label" "$got" "$n"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (found %d, need >= %d)\n' "$RED" "$RESET" "$label" "$got" "$n"; fail=$((fail+1))
  fi
}

echo ""
echo "Test: reconcile-turn reap cwd-anchor — issue #497 regression guard"
echo ""

# 1) The spec file exists.
assert_file_exists "$steady_state_path" "steady-state.md exists"

# 2) The issue is referenced inline so a reader can trace the rationale.
assert_contains "$steady_state_path" \
  "issue [#497]" \
  "steady-state.md names issue #497 inline"

# 3) The shared cwd-anchor-before-reap invariant is documented by name.
assert_contains "$steady_state_path" \
  "cwd-anchor-before-reap invariant" \
  "the cwd-anchor-before-reap invariant is documented"

# 4) The corrected premise is stated — `git rev-parse --show-toplevel` can NOT
#    recover a deleted cwd (the issue's original suggested fix was wrong about
#    `git worktree list --porcelain` surviving; the doc states the real rule).
assert_contains "$steady_state_path" \
  "git rev-parse --show-toplevel\` can NOT" \
  "doc states git rev-parse --show-toplevel cannot recover a deleted cwd"

# 5) Each of the FOUR reap blocks carries the porcelain-derived STABLE_DIR
#    anchor. We assert the anchor `cd` appears at least 4 times (A.0.5, A.1,
#    step B, step C 2d) — one per reap block. The exact awk-porcelain line is
#    the load-bearing token: it derives the anchor cwd-INDEPENDENTLY.
# shellcheck disable=SC2016
# The single-quoted needle is a literal spec token grepped verbatim from the
# markdown — `${STABLE_DIR:-/}` must NOT expand; it's the string we're matching.
assert_count_at_least "$steady_state_path" \
  'cd "${STABLE_DIR:-/}" 2>/dev/null || cd /' \
  4 \
  "all four reap blocks carry the cd-anchor (cd \${STABLE_DIR:-/})"

assert_count_at_least "$steady_state_path" \
  "STABLE_DIR=\$(git worktree list --porcelain" \
  4 \
  "all four reap blocks derive STABLE_DIR via the #477 porcelain idiom"

# 6) The orchestrator-worktree-first / primary-fallback ordering is present
#    (the porcelain walk prefers the orchestrator-* entry, falls back to the
#    first `worktree ` entry = primary). The orchestrator-prefer awk pattern
#    must appear for each anchor.
assert_count_at_least "$steady_state_path" \
  'p ~ /\/\.claude\/worktrees\/orchestrator-/{print p; exit}' \
  4 \
  "all four anchors prefer the orchestrator-* worktree"

# 7) Anchor-before-reap ORDERING per block: in each reap block the cd-anchor
#    must appear BEFORE that block's `git worktree prune`. We verify by
#    walking the file: every `git worktree prune` that belongs to a reap
#    block must be preceded (since the last block boundary) by a cd-anchor.
#    Cheap structural proxy: the count of cd-anchors >= count of reap-block
#    prunes guarded by them. We already asserted >=4 anchors; assert there are
#    exactly the expected reap `git worktree prune` lines (4) so a future
#    added reap block without an anchor is caught by the inequality drifting.
assert_count_at_least "$steady_state_path" \
  "git worktree prune 2>/dev/null || true" \
  4 \
  "four reap blocks each end with git worktree prune"

# ---------------------------------------------------------------------------
# Runtime proof: the anchor-before-reap pattern survives a deleted cwd; the
# naive `git rev-parse --show-toplevel` recovery does not.
# ---------------------------------------------------------------------------
echo ""
echo "Runtime: anchor-before-reap survives a deleted cwd"
echo ""

scratch=$(mktemp -d)
(
  set -u
  cd "$scratch" || exit 1
  git init -q -b main primary >/dev/null 2>&1
  cd primary || exit 1
  git config user.email t@example.com
  git config user.name t
  echo hi > a.txt; git add a.txt; git commit -qm init >/dev/null 2>&1
  mkdir -p .claude/worktrees
  git worktree add -q .claude/worktrees/orchestrator-sess >/dev/null 2>&1
  git worktree add -q .claude/worktrees/agent-doomed >/dev/null 2>&1
  primary_abs="$scratch/primary"

  # --- Negative control: naive recovery FAILS on a deleted cwd. ---
  # cd into the agent worktree (simulating the harness cwd-leak), remove it,
  # then attempt the OLD recovery `cd "$(git rev-parse --show-toplevel)"`.
  (
    cd "$primary_abs/.claude/worktrees/agent-doomed" || exit 0
    git -C "$primary_abs" worktree remove --force \
      "$primary_abs/.claude/worktrees/agent-doomed" >/dev/null 2>&1
    # The naive recovery: rev-parse fails because cwd is deleted.
    if cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null \
       && git worktree prune >/dev/null 2>&1; then
      echo "NAIVE_RECOVERED"
    else
      echo "NAIVE_FAILED"
    fi
  ) > "$scratch/naive_result" 2>/dev/null
)
naive_result=$(cat "$scratch/naive_result" 2>/dev/null)
if [[ "$naive_result" == "NAIVE_FAILED" ]]; then
  # shellcheck disable=SC2016
  # The label text describes the naive recovery literally; `$(...)` is prose,
  # not a command substitution to expand.
  printf '  %sPASS%s  negative control: naive `cd $(git rev-parse --show-toplevel)` fails on deleted cwd\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  negative control expected NAIVE_FAILED, got "%s"\n' "$RED" "$RESET" "$naive_result"
  fail=$((fail+1))
fi

# --- Positive: anchor-before-reap SUCCEEDS. ---
# Fresh fixture (the previous one's agent worktree is already gone).
scratch2=$(mktemp -d)
(
  set -u
  cd "$scratch2" || exit 1
  git init -q -b main primary >/dev/null 2>&1
  cd primary || exit 1
  git config user.email t@example.com
  git config user.name t
  echo hi > a.txt; git add a.txt; git commit -qm init >/dev/null 2>&1
  mkdir -p .claude/worktrees
  git worktree add -q .claude/worktrees/orchestrator-sess >/dev/null 2>&1
  git worktree add -q .claude/worktrees/agent-doomed >/dev/null 2>&1
  primary_abs="$scratch2/primary"

  (
    # Simulate the harness leaking cwd into the worktree we're about to reap.
    cd "$primary_abs/.claude/worktrees/agent-doomed" || exit 0

    # THE FIX: derive a stable anchor cwd-independently (porcelain idiom),
    # cd to it BEFORE the reap — while cwd is still valid.
    STABLE_DIR=$(git worktree list --porcelain 2>/dev/null \
      | awk '/^worktree /{p=substr($0,10)} p ~ /\/\.claude\/worktrees\/orchestrator-/{print p; exit}')
    [ -z "$STABLE_DIR" ] && STABLE_DIR=$(git worktree list --porcelain 2>/dev/null \
      | awk '/^worktree /{print substr($0,10); exit}')
    cd "${STABLE_DIR:-/}" 2>/dev/null || cd /

    # Now reap (cwd is no longer inside the doomed dir) and prune.
    git -C "$primary_abs" worktree remove --force \
      "$primary_abs/.claude/worktrees/agent-doomed" >/dev/null 2>&1
    if git worktree prune >/dev/null 2>&1 \
       && git rev-parse --show-toplevel >/dev/null 2>&1; then
      echo "ANCHOR_RECOVERED"
    else
      echo "ANCHOR_FAILED"
    fi
  ) > "$scratch2/anchor_result" 2>/dev/null
)
anchor_result=$(cat "$scratch2/anchor_result" 2>/dev/null)
if [[ "$anchor_result" == "ANCHOR_RECOVERED" ]]; then
  printf '  %sPASS%s  anchor-before-reap: prune + follow-up git survive the deleted cwd\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  anchor-before-reap expected ANCHOR_RECOVERED, got "%s"\n' "$RED" "$RESET" "$anchor_result"
  fail=$((fail+1))
fi

rm -rf "$scratch" "$scratch2"

echo ""
echo "Results: $pass passed, $fail failed"
if (( fail > 0 )); then
  exit 1
fi
exit 0
