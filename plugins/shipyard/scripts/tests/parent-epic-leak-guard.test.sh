#!/usr/bin/env bash
# Test: the issue-work worker contract documents a post-PR-create guard that
# stops a child PR from silently auto-closing a "do NOT close" parent epic it
# was told only to *reference*.
#
# Background — issue #624: when an issue-work dispatch is told to reference a
# parent epic but NOT close it, GitHub can still promote a bare `#<E>` token
# (in the PR body, a squashed-commit message, or a CHANGELOG entry that rides
# the merge) into the PR's `closingIssuesReferences` — so merging the PR
# auto-closes the epic, even though no closing keyword was ever written.
# Observed twice: PR #621 carried only "Part of #613" / "Does NOT close #613"
# bare phrasing yet GitHub added #613 to closingIssuesReferences and the merge
# closed epic #613; PR #623 also leaked #613 on create and the worker only
# caught it because the orchestrator had hand-rolled a closingIssuesReferences
# check into that dispatch prompt.
#
# The fix makes the guard intrinsic to the worker contract (not dependent on a
# dispatch-prompt instruction) by adding §5.85 to
# `agents/issue-worker/issue-work.md`:
#   - When a non-close parent/epic relationship is in scope, after `gh pr
#     create` assert the epic is absent from `closingIssuesReferences`.
#   - If it leaked: rewrite the PR body to reference the epic by bare URL (not
#     a `#<n>` token), re-verify, and reopen the epic if the PR already merged.
#   - Document the real trigger (bare `#N` tokens + commit/CHANGELOG mentions,
#     NOT only closing keywords) and the bare-URL mitigation.
#
# This is the inverse of issue #481 (a resolving PR leaving its own issue stuck
# OPEN); here a non-resolving mention silently CLOSES an epic it should only
# reference.
#
# This test is the regression guard: if the §5.85 guard is removed or its
# load-bearing semantics regress, the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/parent-epic-leak-guard.test.sh

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

echo "parent-epic leak guard regression tests (issue #624)"
echo

# (1) The issue-work spec must exist.
assert_file_exists "$issue_work_path" "agents/issue-worker/issue-work.md exists"

if [[ -f "$issue_work_path" ]]; then
  # (2) The §5.85 guard section exists.
  assert_contains "$issue_work_path" "### 5.85 Post-PR-create non-close parent/epic leak verification" \
    "issue-work.md adds a §5.85 non-close parent/epic leak verification (issue #624)"
  assert_contains "$issue_work_path" "https://github.com/mattsears18/shipyard/issues/624" \
    "issue-work.md links to the originating issue #624"

  # (3) The guard verifies closingIssuesReferences after PR create.
  assert_contains "$issue_work_path" "closingIssuesReferences" \
    "issue-work.md verifies closingIssuesReferences for the protected epic"

  # (4) The guard remediates a leak: bare-URL body rewrite + reopen-if-merged.
  assert_contains "$issue_work_path" "bare URL" \
    "issue-work.md documents the bare-URL mitigation"
  assert_contains "$issue_work_path" "gh issue reopen" \
    "issue-work.md reopens the epic if the PR already merged and closed it"
  assert_contains "$issue_work_path" "blocked #<N> at parent-epic-leak-verify:" \
    "issue-work.md uses the blocked #<N> at parent-epic-leak-verify: return format"

  # (5) The guidance names the REAL trigger — not only the closing keywords,
  # but bare #N tokens + commit/CHANGELOG mentions.
  assert_contains "$issue_work_path" "squashed-commit message" \
    "issue-work.md names squashed-commit messages as a leak vector"
  assert_contains "$issue_work_path" "CHANGELOG" \
    "issue-work.md names CHANGELOG entries as a leak vector"
  assert_contains "$issue_work_path" "even with NO closing keyword" \
    "issue-work.md states the trigger is broader than closing keywords"

  # (6) The §5.85 check MUST be placed after §5.8 (dispatched-issue closing-link
  # verification) and before §6 (Enable auto-merge) so a protected epic can
  # never ride an armed auto-merge to a silent close.
  assert_section_ordering "$issue_work_path" \
    "### 5.8 Post-PR-create closing-link verification" \
    "### 5.85 Post-PR-create non-close parent/epic leak verification" \
    "§5.85 lands after §5.8 closing-link verification"
  assert_section_ordering "$issue_work_path" \
    "### 5.85 Post-PR-create non-close parent/epic leak verification" \
    "### 6. Enable auto-merge" \
    "§5.85 lands before §6 Enable auto-merge"
fi

# (7) Scope guard — the other modes' specs MUST NOT contain the §5.85 guard.
# Only issue-work writes a Closes #N / references a parent epic in a PR body;
# the other modes (fix-checks-only, fix-rebase, fix-main-ci,
# fix-failing-prs-batch) don't open issue-closing PRs, so the guard would be
# dead weight there.
assert_file_exists "$fix_checks_path" "agents/issue-worker/fix-checks-only.md exists"
assert_file_exists "$fix_rebase_path" "agents/issue-worker/fix-rebase.md exists"
assert_file_exists "$fix_main_ci_path" "agents/issue-worker/fix-main-ci.md exists"
assert_file_exists "$fix_failing_prs_path" "agents/issue-worker/fix-failing-prs-batch.md exists"

for path in "$fix_checks_path" "$fix_rebase_path" "$fix_main_ci_path" "$fix_failing_prs_path"; do
  if [[ -f "$path" ]]; then
    base=$(basename "$path")
    assert_not_contains "$path" \
      "blocked #<N> at parent-epic-leak-verify:" \
      "$base does not contain the issue-work parent-epic-leak bail string"
    assert_not_contains "$path" \
      "non-close parent/epic leak verification" \
      "$base does not duplicate the issue-work §5.85 header"
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
