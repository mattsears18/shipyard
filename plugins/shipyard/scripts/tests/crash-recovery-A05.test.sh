#!/usr/bin/env bash
# Test: the pre-reap recovery check added to A.0.5 (issue #493) is
# documented in commands/do-work/steady-state.md with the correct
# semantics: before reaping a crashed worker's worktree, check for
# committed-but-unpushed work and recover it via push + PR-create.
#
# Background — issue #493: a worker that crashes AFTER committing locally
# but BEFORE pushing has already done the expensive work (pre-commit hooks
# passed). The previous spec discarded this work unconditionally (reap +
# re-enqueue from scratch). The fix adds a pre-reap recovery check:
# `git rev-list --count origin/<default>..HEAD > 0` → push the branch →
# open a PR (if none exists) → arm auto-merge → then reap.
#
# This test is the regression guard: if the recovery check is removed,
# the issue-work-only scope guard is lost, the rev-list signal is dropped,
# or the fire-and-forget posture is broken, the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/crash-recovery-A05.test.sh

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
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (missing: %s)\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail+1))
  fi
}

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s:\n    %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

assert_section_ordering() {
  local file="$1"
  local before="$2"
  local after="$3"
  local label="$4"
  local before_line after_line
  before_line=$(grep -nF -- "$before" "$file" | head -1 | cut -d: -f1)
  after_line=$(grep -nF -- "$after" "$file" | head -1 | cut -d: -f1)
  if [[ -z "$before_line" ]]; then
    printf '  %sFAIL%s  %s (could not find before-marker: %s)\n' "$RED" "$RESET" "$label" "$before"
    fail=$((fail+1))
    return
  fi
  if [[ -z "$after_line" ]]; then
    printf '  %sFAIL%s  %s (could not find after-marker: %s)\n' "$RED" "$RESET" "$label" "$after"
    fail=$((fail+1))
    return
  fi
  if (( before_line < after_line )); then
    printf '  %sPASS%s  %s (before @ line %d, after @ line %d)\n' "$GREEN" "$RESET" "$label" "$before_line" "$after_line"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (expected before-marker before after-marker; got before @ %d, after @ %d)\n' "$RED" "$RESET" "$label" "$before_line" "$after_line"
    fail=$((fail+1))
  fi
}

echo ""
echo "Test: pre-reap crash-recovery in A.0.5 — issue #493 regression guard"
echo ""

# 1) The spec file exists.
assert_file_exists "$steady_state_path" "steady-state.md exists"

# 2) The A.0.5 section still exists (regression guard for the parent feature).
assert_contains "$steady_state_path" \
  "#### A.0.5. Post-return worktree reap for crashed / narrative-non-terminal returns" \
  "A.0.5 header present"

# 3) The issue is referenced inline — traceability requirement.
assert_contains "$steady_state_path" \
  "[#493]" \
  "A.0.5 names issue #493 inline"

# 4) The recovery section header is present.
assert_contains "$steady_state_path" \
  "Pre-reap recovery check" \
  "A.0.5 contains Pre-reap recovery check section"

# 5) The rev-list signal is documented — this is the load-bearing "does the
#    worker have committed-but-unpushed work?" check.
assert_contains "$steady_state_path" \
  "rev-list --count" \
  "A.0.5 recovery uses rev-list --count to detect committed work"
assert_contains "$steady_state_path" \
  "origin/\${DEFAULT_BRANCH}..HEAD" \
  "A.0.5 recovery compares origin/<default>..HEAD"

# 6) The scope guard is documented — recovery only applies to issue-work
#    dispatches (slot kind == "issue"), not synthetic diverts or fix-* modes.
assert_contains "$steady_state_path" \
  "slot_kind" \
  "A.0.5 recovery checks slot kind"
# shellcheck disable=SC2016
# Literal grep needle — the $slot_kind is matched verbatim in the spec, not expanded.
assert_contains "$steady_state_path" \
  '[ "$slot_kind" = "issue" ]' \
  "A.0.5 recovery is gated on slot kind == issue"

# 7) The push step is documented.
# shellcheck disable=SC2016
# Literal grep needle — ${slot_issue} is matched verbatim in the spec, not expanded.
assert_contains "$steady_state_path" \
  'push origin "do-work/issue-${slot_issue}"' \
  "A.0.5 recovery pushes the branch to origin"

# 8) The PR-create step is documented, including the existing-PR check that
#    handles the case where the worker pushed but crashed before PR creation.
assert_contains "$steady_state_path" \
  "existing_pr" \
  "A.0.5 recovery checks for an existing open PR"
assert_contains "$steady_state_path" \
  "gh pr create" \
  "A.0.5 recovery calls gh pr create"
assert_contains "$steady_state_path" \
  "Closes #" \
  "A.0.5 recovery PR body includes Closes keyword"
assert_contains "$steady_state_path" \
  "--label shipyard" \
  "A.0.5 recovery PR carries --label shipyard"

# 9) Auto-merge is armed after recovery — the recovery PR enters the normal
#    merge train rather than sitting as a stale open PR.
assert_contains "$steady_state_path" \
  "gh pr merge" \
  "A.0.5 recovery arms auto-merge on the recovered PR"
assert_contains "$steady_state_path" \
  "--auto --merge --delete-branch" \
  "A.0.5 recovery uses --auto --merge --delete-branch"

# 10) The recovered PR is appended to session_prs so drain/summary see it.
# shellcheck disable=SC2016
# Literal grep needle — $recovered_pr is matched verbatim in the spec, not expanded.
assert_contains "$steady_state_path" \
  'session_prs+=("$recovered_pr")' \
  "A.0.5 recovery appends recovered PR to session_prs"

# 11) The recovery log prefix is documented — operators can grep for it.
assert_contains "$steady_state_path" \
  "[reconcile-A.0.5-recovery]" \
  "A.0.5 recovery uses [reconcile-A.0.5-recovery] log prefix"

# 12) Fire-and-forget posture is explicitly stated for recovery steps —
#     a failed push/PR-create must not abort the reconcile turn.
assert_contains "$steady_state_path" \
  "A failed recovery step is not a reason to abort" \
  "A.0.5 recovery explicitly states fire-and-forget posture"

# 13) The recovery check runs BEFORE the actual reap call — ordering is
#     load-bearing (can't recover from a reaped worktree).
assert_section_ordering "$steady_state_path" \
  "Pre-reap recovery check" \
  "Crash-aware reap: unlike step B" \
  "recovery check precedes reap call in document order"

# 14) The zero-commits-ahead case is handled — when count == 0, skip
#     recovery and proceed directly to reap (no false-positive recovery
#     attempts on true-redo crashes).
assert_contains "$steady_state_path" \
  '"0"' \
  "A.0.5 recovery skips when ahead_count is 0"

echo ""
echo "Results: $pass passed, $fail failed"
if (( fail > 0 )); then
  exit 1
fi
exit 0
