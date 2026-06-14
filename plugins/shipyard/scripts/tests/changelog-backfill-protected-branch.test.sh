#!/usr/bin/env bash
# Test: the CHANGELOG #TBD backfill in steady-state.md A.1 handles protected
# default branches (pull_request ruleset) correctly (#583).
#
# Background — issue #583: the backfill step added in #581 (PR #582) attempted
# to write the corrected CHANGELOG entry via a direct Contents API PUT to the
# default branch. On any repo whose default branch is protected by a
# pull_request ruleset, that direct write is rejected — `gh api -X PUT` exits
# non-zero with a 422 "push declined due to repository rule violations"
# response. Because the prior implementation was fire-and-forget with
# `>/dev/null 2>&1`, the failure was silent: the placeholder stayed `PR #TBD`
# and nothing surfaced to the operator.
#
# Verified live on mattsears18/shipyard immediately after #582 merged:
# attempting the backfill via git push returned "push declined due to
# repository rule violations". The default-branch ruleset is:
#
#   $ gh api repos/mattsears18/shipyard/rules/branches/main \
#       --jq '[.[].type] | unique'
#   ["deletion","non_fast_forward","pull_request"]
#
# The fix (#583) adds three layers:
#
#   1. Probe the branch ruleset before attempting the write so the write-path
#      decision is explicit (not discovered via failure).
#   2. If the direct Contents API write fails AND the branch has a
#      pull_request rule: fall back to an auto-merged PR on a short-lived
#      do-work/changelog-backfill-<M> branch.
#   3. If both paths fail: emit a VISIBLE `WARNING` advisory — never a silent
#      no-op.
#
# This test is the regression guard: if any of those three layers is dropped
# from the spec, the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/changelog-backfill-protected-branch.test.sh

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
    printf '    expected to find in %s: %s\n' "$file" "$needle"
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

echo "CHANGELOG backfill protected-branch regression tests (issue #583)"
echo

# (1) The steady-state spec must exist.
assert_file_exists "$steady_state_path" "commands/do-work/steady-state.md exists"

if [[ -f "$steady_state_path" ]]; then

  # (2) Ruleset probe — the fix must probe the branch ruleset BEFORE attempting
  # the write. The probe is the gh api call to rules/branches/{branch}; without
  # it the write path is chosen blindly (the original bug).
  # shellcheck disable=SC2016
  # Literal grep needle — ${DEFAULT_BRANCH} is matched verbatim in the spec, not expanded.
  assert_contains "$steady_state_path" \
    'gh api "repos/<owner/repo>/rules/branches/${DEFAULT_BRANCH}"' \
    "steady-state.md probes the branch ruleset before attempting the Contents API write (#583)"

  assert_contains "$steady_state_path" \
    'contains(["pull_request"])' \
    "steady-state.md checks for a pull_request rule type in the ruleset (#583)"

  # (3) The probe result must be stored in a variable and used to branch the
  # write-path logic. The canonical variable name from the spec is has_pr_rule.
  assert_contains "$steady_state_path" \
    'has_pr_rule=' \
    "steady-state.md stores the ruleset probe result in has_pr_rule variable (#583)"

  # shellcheck disable=SC2016
  # Literal grep needle — "$has_pr_rule" is matched verbatim in the spec, not expanded.
  assert_contains "$steady_state_path" \
    '"$has_pr_rule" = "true"' \
    "steady-state.md branches on has_pr_rule to choose the write path (#583)"

  # (4) Contents API PUT attempt — the direct write is still attempted first
  # (it succeeds on repos without a pull_request rule or with a bypass actor).
  # The key change from the original: the exit code is captured (not swallowed
  # by the `>/dev/null 2>&1 &&` pattern that made failures silent).
  assert_contains "$steady_state_path" \
    'put_ok=false' \
    "steady-state.md initializes put_ok=false before the Contents API PUT attempt (#583)"

  assert_contains "$steady_state_path" \
    'put_ok=true' \
    "steady-state.md sets put_ok=true only on a successful Contents API PUT (#583)"

  # shellcheck disable=SC2016
  # Literal grep needle — "$put_ok" is matched verbatim in the spec, not expanded.
  assert_contains "$steady_state_path" \
    '[ "$put_ok" = "false" ]' \
    "steady-state.md checks put_ok=false before the protected-branch fallback (#583)"

  # (5) PR-based fallback — when the direct write fails and the branch has a
  # pull_request rule, the backfill must fall back to creating an auto-merged PR.
  assert_contains "$steady_state_path" \
    'do-work/changelog-backfill-<M>' \
    "steady-state.md uses do-work/changelog-backfill-<M> as the fallback branch name (#583)"

  assert_contains "$steady_state_path" \
    'gh pr create' \
    "steady-state.md creates a PR for the fallback path (#583)"

  # shellcheck disable=SC2016
  # Literal grep needle — "$backfill_pr_num" is matched verbatim in the spec, not expanded.
  assert_contains "$steady_state_path" \
    'gh pr merge "$backfill_pr_num"' \
    "steady-state.md arms auto-merge on the backfill PR (#583)"

  assert_contains "$steady_state_path" \
    '--label shipyard' \
    "steady-state.md labels the backfill PR with the shipyard label (#583)"

  # (6) Backfill PR cleanup — the fallback branch must be deleted if PR
  # creation fails (no orphan branch leaks).
  # shellcheck disable=SC2016
  # Literal grep needle — ${backfill_branch} is matched verbatim in the spec, not expanded.
  assert_contains "$steady_state_path" \
    'gh api -X DELETE "repos/<owner/repo>/git/refs/heads/${backfill_branch}"' \
    "steady-state.md cleans up the backfill branch when PR creation fails (#583)"

  # (7) Visible WARNING advisory — when both paths fail the spec MUST emit a
  # WARNING line visible to the operator, never a silent no-op. This is the
  # load-bearing "never silent" requirement from the acceptance criteria.
  assert_contains "$steady_state_path" \
    '[changelog-backfill] WARNING PR #<M>: could not backfill' \
    "steady-state.md emits a VISIBLE WARNING when both write paths fail (#583)"

  # (8) The WARNING advisory for the non-pull_request-rule failure case must
  # also be visible (not silenced by >/dev/null).
  assert_contains "$steady_state_path" \
    '[changelog-backfill] WARNING PR #<M>: backfill Contents API PUT failed for an unknown reason' \
    "steady-state.md emits a visible WARNING for non-pull_request-rule PUT failures (#581)"

  # (9) Ordering: the ruleset probe must precede the Contents API PUT attempt.
  # shellcheck disable=SC2016
  # Literal grep needle — ${DEFAULT_BRANCH} and ${vc_changelog} are matched verbatim, not expanded.
  assert_section_ordering "$steady_state_path" \
    'has_pr_rule=$(gh api "repos/<owner/repo>/rules/branches/${DEFAULT_BRANCH}"' \
    'gh api -X PUT "repos/<owner/repo>/contents/${vc_changelog}"' \
    "ruleset probe (has_pr_rule) precedes the Contents API PUT attempt (#583)"

  # (10) Issue reference — the spec must link to #583 so the fix is traceable.
  assert_contains "$steady_state_path" \
    '#583' \
    "steady-state.md references issue #583 (#583)"

  # (11) Write-path selection bullet in Scope and conditions.
  assert_contains "$steady_state_path" \
    'Write-path selection' \
    "steady-state.md documents the write-path selection logic in Scope and conditions (#583)"

fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
