#!/usr/bin/env bash
# Test: the issue-work spec documents the canonical `PR #TBD` CHANGELOG
# PR-reference placeholder, and the worker + orchestrator sides are one contract.
#
# Background — issue #690: the orchestrator's CHANGELOG backfill (#581 / #583)
# assumes every worker writes the literal token `PR #TBD` in its CHANGELOG entry
# and replaces it with the real PR number at `shipped` reconcile time via a
# literal `grep -qF "PR #TBD"`. But no worker spec documented that contract, so
# workers improvised the placeholder and did so inconsistently:
#   - Some PREDICTED a PR number (`PR #683`) — but a worker cannot know its PR
#     number before `gh pr create` returns, and interleaved backfill/sibling PRs
#     shift any prediction off-by-one. The backfill finds no `PR #TBD` and the
#     wrong number ships to main verbatim.
#   - One wrote a NON-CANONICAL placeholder (`PR #<PR>`) — the literal grep never
#     matches it, so the placeholder itself ships to main, unresolved.
# In the #690 repro (5 sequential release entries) 3 of 5 shipped wrong.
#
# The fix is the worker-side mandate: issue-work.md must name `PR #TBD` as the
# required PR-reference form, forbid predicting a number, and cross-reference the
# orchestrator backfill so the two sides are visibly one contract.
#
# This test is the regression guard for that documentation. If the guidance
# regresses, workers silently revert to improvising the placeholder.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/changelog-pr-ref-placeholder.test.sh

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

echo "CHANGELOG PR-ref placeholder guidance regression tests (issue #690)"
echo

# --- Worker-side mandate (issue-work.md) ---
assert_file_exists "$issue_work_path" "agents/issue-worker/issue-work.md exists"
if [[ -f "$issue_work_path" ]]; then
  # The guidance must name the canonical placeholder as the required PR-ref form.
  assert_contains "$issue_work_path" "PR #TBD" \
    "issue-work.md names the canonical PR #TBD placeholder"
  # It must link the originating issue.
  assert_contains "$issue_work_path" "https://github.com/mattsears18/shipyard/issues/690" \
    "issue-work.md links to originating issue #690"
  # It must forbid predicting a PR number.
  assert_contains "$issue_work_path" "NEVER predict a PR number" \
    "issue-work.md forbids predicting a PR number"
  # It must cross-reference the orchestrator backfill contract (#581 / #583).
  assert_contains "$issue_work_path" "https://github.com/mattsears18/shipyard/issues/581" \
    "issue-work.md cross-references the #581 backfill contract"
  assert_contains "$issue_work_path" "https://github.com/mattsears18/shipyard/issues/583" \
    "issue-work.md cross-references the #583 backfill fallback"
  # It must call out that a non-canonical placeholder shape is never backfilled.
  assert_contains "$issue_work_path" 'PR #<PR>' \
    "issue-work.md names the non-canonical PR #<PR> shape as a failure mode"
fi

# --- Orchestrator side: the backfill this contract joins actually greps PR #TBD ---
assert_file_exists "$steady_state_path" "commands/do-work/steady-state.md exists"
if [[ -f "$steady_state_path" ]]; then
  # The load-bearing literal grep the worker-side token must match exactly.
  assert_contains "$steady_state_path" 'grep -qF "PR #TBD"' \
    "steady-state.md backfill matches the literal PR #TBD token"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
