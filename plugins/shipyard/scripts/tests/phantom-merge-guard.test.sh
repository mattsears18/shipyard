#!/usr/bin/env bash
# Test: the issue-work worker contract documents a pre-PR-create diff
# sanity check that bails when the implementation produced 0 file changes
# against the base branch, plus a defense-in-depth post-PR-create diff
# sanity check that refuses to arm auto-merge on an empty PR.
#
# Background — issue #356: a shipyard worker can ship a PR whose body
# claims substantial scope (new files, modified files, acceptance criteria
# checked) while the actual diff is **0 files changed**. The PR merges,
# the body's `Closes #N` keyword closes the linked issue, and the backlog
# claims work shipped — but nothing landed. Repro:
# mattsears18/lightwork#1169 merged on 2026-05-25 with an empty diff,
# auto-closing mattsears18/lightwork#1160. The fix adds a pre-PR-create
# diff sanity check (primary) and a post-PR-create / pre-auto-merge diff
# sanity check (belt + suspenders) to `agents/issue-worker/issue-work.md`
# so the worker bails with `blocked: implementation produced no changes —
# manual triage required` rather than opening / arming auto-merge on an
# empty PR.
#
# Scope: the check applies to **issue-work mode only**. The other modes
# (fix-checks-only, fix-rebase, fix-main-ci, fix-failing-prs-batch) can
# legitimately produce 0-file diffs (e.g., a fix-checks-only retry where
# the original CI failure resolved itself) so they are intentionally
# untouched.
#
# This test is the regression guard: if the guard is removed or its
# load-bearing semantics (the bail string, the pre-PR-create placement,
# the issue-work-only scope) regress, the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/phantom-merge-guard.test.sh

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
fix_checks_path="$repo_root/plugins/shipyard/agents/issue-worker/fix-checks-only.md"
fix_rebase_path="$repo_root/plugins/shipyard/agents/issue-worker/fix-rebase.md"
fix_main_ci_path="$repo_root/plugins/shipyard/agents/issue-worker/fix-main-ci.md"
fix_failing_prs_path="$repo_root/plugins/shipyard/agents/issue-worker/fix-failing-prs-batch.md"

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
    printf '    expected to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if ! grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected NOT to find in %s: %s\n' "$file" "$needle"
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

echo "phantom-merge guard regression tests (issue #356)"
echo

# (1) The issue-work spec must exist.
assert_file_exists "$issue_work_path" "agents/issue-worker/issue-work.md exists"

if [[ -f "$issue_work_path" ]]; then
  # (2) Pre-PR-create diff sanity check — the primary guard.
  #
  # The worker MUST verify the working tree has non-zero diff vs the base
  # branch BEFORE opening the PR. If the diff is empty, bail with the
  # documented `blocked:` string rather than opening an empty PR.
  assert_contains "$issue_work_path" "### 4.5 Pre-PR-create diff sanity check" \
    "issue-work.md adds a §4.5 Pre-PR-create diff sanity check (issue #356)"
  assert_contains "$issue_work_path" "phantom-merge" \
    "issue-work.md names the phantom-merge failure mode by name"
  assert_contains "$issue_work_path" "git diff --name-only" \
    "issue-work.md uses git diff --name-only to count changed files"
  assert_contains "$issue_work_path" "implementation produced no changes" \
    "issue-work.md documents the canonical bail string substring"
  assert_contains "$issue_work_path" "blocked #<N> at pre-pr-create:" \
    "issue-work.md uses the blocked #<N> at pre-pr-create: return format"
  assert_contains "$issue_work_path" "https://github.com/mattsears18/shipyard/issues/356" \
    "issue-work.md links to the originating issue #356"

  # (3) The pre-PR-create check MUST be placed between step 4 (Implement)
  # and step 5 (Commit + push + PR). Putting it after step 5 would defeat
  # the purpose (the empty PR is already open).
  assert_section_ordering "$issue_work_path" \
    "### 4. Implement" \
    "### 4.5 Pre-PR-create diff sanity check" \
    "§4.5 lands after §4 Implement"
  assert_section_ordering "$issue_work_path" \
    "### 4.5 Pre-PR-create diff sanity check" \
    "### 5. Commit + push + PR" \
    "§4.5 lands before §5 Commit + push + PR"

  # (4) Defense-in-depth: post-PR-create / pre-auto-merge diff sanity check.
  #
  # Even if a worker skips step 4.5 (mode drift, future refactor), the
  # auto-merge step's sanity check refuses to arm auto-merge on a PR
  # whose `changedFiles == 0`. This is the belt + suspenders pattern.
  assert_contains "$issue_work_path" "### 5.7 Post-PR-create diff sanity check" \
    "issue-work.md adds a §5.7 Post-PR-create diff sanity check (issue #356)"
  assert_contains "$issue_work_path" "gh pr view <pr-num> --repo <owner/repo> --json changedFiles" \
    "issue-work.md uses gh pr view --json changedFiles for the post-create check"
  assert_contains "$issue_work_path" "blocked #<N> at pre-auto-merge:" \
    "issue-work.md uses the blocked #<N> at pre-auto-merge: return format"
  assert_contains "$issue_work_path" "0-file diff" \
    "issue-work.md names the 0-file diff condition for the defense-in-depth check"

  # The post-create check MUST be placed before step 6 (Enable auto-merge).
  assert_section_ordering "$issue_work_path" \
    "### 5. Commit + push + PR" \
    "### 5.7 Post-PR-create diff sanity check" \
    "§5.7 lands after §5 Commit + push + PR"
  assert_section_ordering "$issue_work_path" \
    "### 5.7 Post-PR-create diff sanity check" \
    "### 6. Enable auto-merge" \
    "§5.7 lands before §6 Enable auto-merge"

  # (5) Scope marker — the guard is documented as issue-work-only.
  #
  # The other modes (fix-checks-only, fix-rebase, fix-main-ci,
  # fix-failing-prs-batch) can legitimately produce 0-file diffs, so the
  # spec must NOT spread the guard to them. The marker text inside
  # issue-work.md just clarifies the scope; the regression below also
  # checks that the other modes' specs don't accidentally inherit the
  # bail strings.
  assert_contains "$issue_work_path" "issue-work mode only" \
    "issue-work.md documents the guard is issue-work-mode-only (issue #356)"
fi

# (6) Scope guard — the other modes' specs MUST NOT contain the pre-pr-create
# bail string. They can legitimately produce 0-file diffs; spreading the
# check to them would regress fix-checks-only retries that resolve themselves.
assert_file_exists "$fix_checks_path" "agents/issue-worker/fix-checks-only.md exists"
assert_file_exists "$fix_rebase_path" "agents/issue-worker/fix-rebase.md exists"
assert_file_exists "$fix_main_ci_path" "agents/issue-worker/fix-main-ci.md exists"
assert_file_exists "$fix_failing_prs_path" "agents/issue-worker/fix-failing-prs-batch.md exists"

for path in "$fix_checks_path" "$fix_rebase_path" "$fix_main_ci_path" "$fix_failing_prs_path"; do
  if [[ -f "$path" ]]; then
    base=$(basename "$path")
    assert_not_contains "$path" \
      "blocked #<N> at pre-pr-create:" \
      "$base does not contain the issue-work pre-pr-create bail string"
    assert_not_contains "$path" \
      "Pre-PR-create diff sanity check" \
      "$base does not duplicate the issue-work §4.5 header"
  fi
done

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
