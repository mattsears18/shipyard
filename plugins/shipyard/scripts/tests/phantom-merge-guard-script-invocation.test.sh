#!/usr/bin/env bash
# Test: the issue-work and spike worker specs invoke the standalone
# assert-worktree-change-present.sh script for their phantom-merge guards
# (issue-work.md §4.5, spike.md §7.5) instead of re-inlining the miscounting
# `--name-only | wc -l` / `--porcelain | wc -l` shape (issue #1340).
#
# Background — issue #1340, the sibling of #1336/#1341 (which fixed the same
# failure shape in fix-rebase.md §5.7). §4.5/§7.5's guard exists to stop a
# worker that reached the end of implementation with no real change from
# opening a PR that still claims one — the PR merges, `Closes #N` closes the
# linked issue, and the backlog claims work shipped when nothing landed.
#
# This test is the regression guard on the SPEC files themselves (a sibling
# to assert-worktree-change-present.test.sh, which covers the script's own
# behavior): if either spec is edited to re-inline the vulnerable shape, or
# to stop calling the script, or to treat the script's INDETERMINATE exit as
# a pass, this test fails. It is written against the CURRENT (fixed) specs
# and is expected to fail if run against the pre-fix specs — the assertions
# below (assert_not_contains on the vulnerable inline shape, assert_contains
# on the script invocation) are false on the pre-#1340 versions of both
# files, which is exactly the regression this test exists to catch.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/phantom-merge-guard-script-invocation.test.sh

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

issue_work_path="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"
spike_path="$repo_root/plugins/shipyard/agents/issue-worker/spike.md"
rationale_path="$repo_root/docs/design/issue-work-rationale.md"
script_path="$repo_root/plugins/shipyard/scripts/assert-worktree-change-present.sh"

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
    printf '    expected to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

assert_not_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected NOT to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  fi
}

echo "phantom-merge guard script-invocation regression tests (issue #1340)"
echo

assert_file_exists "$issue_work_path" "agents/issue-worker/issue-work.md exists"
assert_file_exists "$spike_path" "agents/issue-worker/spike.md exists"
assert_file_exists "$rationale_path" "agents/issue-worker/issue-work-rationale.md exists"
assert_file_exists "$script_path" "scripts/assert-worktree-change-present.sh exists"

if [[ -x "$script_path" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "scripts/assert-worktree-change-present.sh has the exec bit set"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "scripts/assert-worktree-change-present.sh has the exec bit set"
  fail=$((fail+1))
fi

# shellcheck disable=SC2016
if [[ -f "$issue_work_path" ]]; then
  # (1) The vulnerable inline shapes must be GONE from issue-work.md §4.5.
  assert_not_contains "$issue_work_path" 'CHANGED_FILES=$(git diff --name-only' \
    "issue-work.md no longer inlines the CHANGED_FILES wc -l pipeline (issue #1340)"
  assert_not_contains "$issue_work_path" 'WORKING_TREE_DIRTY=$(git status --porcelain' \
    "issue-work.md no longer inlines the WORKING_TREE_DIRTY wc -l pipeline (issue #1340)"

  # (2) The script must be invoked as a plain, standalone call.
  assert_contains "$issue_work_path" 'scripts/assert-worktree-change-present.sh" "origin/$DEFAULT_BRANCH"' \
    "issue-work.md §4.5 invokes assert-worktree-change-present.sh with origin/\$DEFAULT_BRANCH"

  # (3) The INDETERMINATE exit (2) must be documented as a bail, never a pass.
  assert_contains "$issue_work_path" "Treat exactly like exit 1 — never as a pass" \
    "issue-work.md §4.5 treats the script's INDETERMINATE exit 2 as a bail, not a pass"

  # (4) The EMPTY_DIFF exit (1) must still produce the canonical bail string.
  assert_contains "$issue_work_path" "blocked #<N> at pre-pr-create: implementation produced no changes — manual triage required" \
    "issue-work.md §4.5 preserves the canonical empty-diff bail string"

  # (5) Links to both originating issues.
  assert_contains "$issue_work_path" "https://github.com/mattsears18/shipyard/issues/1340" \
    "issue-work.md §4.5 links to issue #1340"

  # (6) Scope constraint (only issue-work; not the fix-* modes) must survive.
  assert_contains "$issue_work_path" "Scope: issue-work mode only" \
    "issue-work.md §4.5 states the issue-work-only scope constraint"
fi

# shellcheck disable=SC2016
if [[ -f "$spike_path" ]]; then
  # (7) The vulnerable inline shapes must be GONE from spike.md §7.5 too.
  assert_not_contains "$spike_path" 'CHANGED_FILES=$(git diff --name-only' \
    "spike.md no longer inlines the CHANGED_FILES wc -l pipeline (issue #1340)"
  assert_not_contains "$spike_path" 'WORKING_TREE_DIRTY=$(git status --porcelain' \
    "spike.md no longer inlines the WORKING_TREE_DIRTY wc -l pipeline (issue #1340)"

  # (8) spike.md must call the SAME script as issue-work.md (not a fork).
  assert_contains "$spike_path" 'scripts/assert-worktree-change-present.sh" "origin/$DEFAULT_BRANCH"' \
    "spike.md §7.5 invokes assert-worktree-change-present.sh with origin/\$DEFAULT_BRANCH"

  # (9) The INDETERMINATE exit (2) must be documented as a bail here too.
  assert_contains "$spike_path" "treat exactly like exit 1, never as a pass" \
    "spike.md §7.5 treats the script's INDETERMINATE exit 2 as a bail, not a pass"

  # (10) The spike-specific "design doc counts" bail message must survive.
  assert_contains "$spike_path" "spike produced no design doc and no code changes — manual triage required" \
    "spike.md §7.5 preserves the spike-specific empty-diff bail string"
fi

# (11) The RATIONALE file must carry the measured-evidence writeup issue-work.md links to.
if [[ -f "$rationale_path" ]]; then
  assert_contains "$rationale_path" "Why the phantom-merge guard is a script, not an inline snippet" \
    "issue-work-rationale.md documents the #1340 measured evidence"
  assert_contains "$rationale_path" "script-internal invocation is immune to both" \
    "issue-work-rationale.md documents the script-internal-immunity finding"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
