#!/usr/bin/env bash
# Test: the latest-per-name `statusCheckRollup` projection (issue #333)
# correctly filters out stale superseded check runs while keeping real
# failures on the latest run.
#
# Background — issue #333: `gh pr view --json statusCheckRollup` returns
# the UNION of every check run for the PR's head SHA, including stale
# superseded runs. A check that ran, failed, was re-triggered, and
# passed appears twice (FAILURE entry + SUCCESS entry). The pre-#333
# rollup walks were of the shape:
#
#   .statusCheckRollup[] | select(.conclusion == "FAILURE")
#
# which false-positives on every such PR. Two distinct failure modes:
#
#   - fix-rebase bails ("PR has failing checks — needs fix-checks") on
#     a PR that's actually green, leaving DIRTY PRs unrebased.
#   - fix-checks workers + orchestrator trust-but-verify keep re-queuing
#     the PR. Each dispatch returns `noop: already green`. ~50k tokens
#     wasted per affected PR.
#
# Both observed in lightwork session c6afe19d-a6a6-40e4-9eb8-de409d046a49
# against PRs #1193 / #1211 — ~270k tokens lost across 3 dispatch slots.
#
# The fix is a jq reduction applied at every rollup walk:
#
#   .statusCheckRollup
#   | group_by(.name)
#   | map(sort_by(.completedAt // .startedAt // "") | last)
#   | .[]
#   | select((.conclusion // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))
#
# This test pins the projection's behavior. It uses synthetic
# `statusCheckRollup` fixtures (no `gh` call), pipes them through jq,
# and asserts the count is correct for both the naïve walk (proving the
# bug exists pre-fix) and the latest-per-name walk (proving the fix
# works post-fix).
#
# Pure bash + jq. Run with:
#
#   bash plugins/shipyard/scripts/tests/rollup-latest-per-name.test.sh

set -u

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_equals() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf '  %sPASS%s  %s (got %s)\n' "$GREEN" "$RESET" "$label" "$actual"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (expected %s, got %s)\n' "$RED" "$RESET" "$label" "$expected" "$actual"
    fail=$((fail+1))
  fi
}

# The canonical latest-per-name jq pipeline. Mirror the snippet that
# lives in fix-rebase.md, fix-checks-only.md, fix-failing-prs-batch.md,
# setup.md (3c, 4.5b, 5), steady-state.md (trust-but-verify, unrecognized
# return, 2a stale-failure), drain.md (R_new/D_dirty), and worker-preamble
# (snapshot+return). Keep this string in sync if the projection changes.
JQ_LATEST_PER_NAME='
  [.statusCheckRollup
   | group_by(.name)
   | map(sort_by(.completedAt // .startedAt // "") | last)
   | .[]
   | select((.conclusion // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))]
  | length
'

JQ_NAIVE_WALK='
  [.statusCheckRollup[] | select(.conclusion == "FAILURE" or .conclusion == "ERROR" or .conclusion == "TIMED_OUT")]
  | length
'

echo "rollup latest-per-name projection (issue #333)"
echo

# Fixture 1: the exact repro from the issue body. "Lint PR title" failed
# at 17:30:45, was re-triggered, and passed at 17:31:24. A second check
# is solidly SUCCESS.
ROLLUP_REPRO=$(cat <<'JSON'
{
  "statusCheckRollup": [
    {"name": "Lint PR title", "status": "COMPLETED", "conclusion": "FAILURE", "completedAt": "2026-05-24T17:30:45Z"},
    {"name": "Lint PR title", "status": "COMPLETED", "conclusion": "SUCCESS", "completedAt": "2026-05-24T17:31:24Z"},
    {"name": "Unit Tests",    "status": "COMPLETED", "conclusion": "SUCCESS", "completedAt": "2026-05-24T17:32:00Z"}
  ]
}
JSON
)

naive=$(echo "$ROLLUP_REPRO" | jq "$JQ_NAIVE_WALK")
assert_equals "naive walk false-positives on the repro from issue body (1 stale FAILURE)" "1" "$naive"

latest=$(echo "$ROLLUP_REPRO" | jq "$JQ_LATEST_PER_NAME")
assert_equals "latest-per-name correctly filters out the stale FAILURE (PR is green)" "0" "$latest"

# Fixture 2: a real failure on the latest run. The naïve walk and
# latest-per-name both report 1 — neither under-reports a genuine failure.
ROLLUP_REAL_FAIL=$(cat <<'JSON'
{
  "statusCheckRollup": [
    {"name": "Unit Tests", "status": "COMPLETED", "conclusion": "SUCCESS", "completedAt": "2026-05-24T17:00:00Z"},
    {"name": "Unit Tests", "status": "COMPLETED", "conclusion": "FAILURE", "completedAt": "2026-05-24T17:05:00Z"}
  ]
}
JSON
)
naive_real=$(echo "$ROLLUP_REAL_FAIL" | jq "$JQ_NAIVE_WALK")
assert_equals "naive walk catches real failure (1 entry, on latest run)" "1" "$naive_real"
latest_real=$(echo "$ROLLUP_REAL_FAIL" | jq "$JQ_LATEST_PER_NAME")
assert_equals "latest-per-name catches real failure (latest run is FAILURE)" "1" "$latest_real"

# Fixture 3: in-progress check that was previously failing. The latest
# entry has `conclusion: null` and `status: IN_PROGRESS` — neither
# FAILURE nor a terminal state — so we should NOT count it as a hard
# failure. The naïve walk under-counts (it requires conclusion="FAILURE"
# exactly, so the stale FAILURE entry IS counted; latest-per-name
# correctly drops it because the LATEST entry is in-progress).
ROLLUP_IN_PROGRESS=$(cat <<'JSON'
{
  "statusCheckRollup": [
    {"name": "E2E", "status": "COMPLETED",   "conclusion": "FAILURE", "completedAt": "2026-05-24T17:00:00Z"},
    {"name": "E2E", "status": "IN_PROGRESS", "conclusion": null,      "startedAt":   "2026-05-24T17:10:00Z"}
  ]
}
JSON
)
in_prog_fails=$(echo "$ROLLUP_IN_PROGRESS" | jq "$JQ_LATEST_PER_NAME")
assert_equals "latest-per-name treats in-progress (post-failure) as not-failing" "0" "$in_prog_fails"

# Fixture 4: all-green rollup — sanity check, no false negatives or positives.
ROLLUP_GREEN=$(cat <<'JSON'
{
  "statusCheckRollup": [
    {"name": "Unit Tests", "conclusion": "SUCCESS", "completedAt": "2026-05-24T17:00:00Z"},
    {"name": "Lint",       "conclusion": "SUCCESS", "completedAt": "2026-05-24T17:01:00Z"}
  ]
}
JSON
)
green_fails=$(echo "$ROLLUP_GREEN" | jq "$JQ_LATEST_PER_NAME")
assert_equals "all-green rollup → 0 failures" "0" "$green_fails"

# Fixture 5: empty rollup (no checks configured on this repo).
empty_fails=$(echo '{"statusCheckRollup": []}' | jq "$JQ_LATEST_PER_NAME")
assert_equals "empty rollup → 0 failures" "0" "$empty_fails"

# Fixture 6: extra-broad failure conclusion (CANCELLED, ACTION_REQUIRED).
# These were NOT covered by the naïve walk's narrow set, but the
# latest-per-name projection captures them too (matches the
# orchestrator's reconcile path which already named these conclusions).
ROLLUP_CANCELLED=$(cat <<'JSON'
{
  "statusCheckRollup": [
    {"name": "Deploy",  "conclusion": "CANCELLED",        "completedAt": "2026-05-24T17:00:00Z"},
    {"name": "Approve", "conclusion": "ACTION_REQUIRED",  "completedAt": "2026-05-24T17:01:00Z"}
  ]
}
JSON
)
broad_fails=$(echo "$ROLLUP_CANCELLED" | jq "$JQ_LATEST_PER_NAME")
assert_equals "latest-per-name catches CANCELLED + ACTION_REQUIRED on latest run" "2" "$broad_fails"

# Fixture 7: status-only check-run (no conclusion field — old API shape).
# The `(.conclusion // .status // "")` fallback should pick up `.status`
# when conclusion is absent.
ROLLUP_STATUS_FALLBACK=$(cat <<'JSON'
{
  "statusCheckRollup": [
    {"name": "Old API check", "status": "FAILURE", "startedAt": "2026-05-24T17:00:00Z"}
  ]
}
JSON
)
status_fails=$(echo "$ROLLUP_STATUS_FALLBACK" | jq "$JQ_LATEST_PER_NAME")
assert_equals "latest-per-name falls back to .status when .conclusion is absent" "1" "$status_fails"

# Fixture 8: tie-breaking when two entries for the same check name have
# identical completedAt. jq's `sort_by` is stable — last-arrived wins
# (matches the GitHub list order which is the actual chronological
# order GitHub returns). The fix is correct regardless of tie-break
# direction because either ordering picks ONE of the two as the latest
# and discards the other, which is the semantic we want — both can't
# be "the latest run."
ROLLUP_TIE=$(cat <<'JSON'
{
  "statusCheckRollup": [
    {"name": "Check", "conclusion": "FAILURE", "completedAt": "2026-05-24T17:00:00Z"},
    {"name": "Check", "conclusion": "SUCCESS", "completedAt": "2026-05-24T17:00:00Z"}
  ]
}
JSON
)
# After dedup, one entry survives. Whichever it is, the count is 0 or 1.
tie_fails=$(echo "$ROLLUP_TIE" | jq "$JQ_LATEST_PER_NAME")
# Document the actual behavior — jq sort_by is stable so the second one
# (SUCCESS) wins, giving count 0. Pin it as the expected behavior so a
# future jq upgrade that changes sort stability is caught.
assert_equals "tie-broken-by-stable-sort: second entry (SUCCESS) wins → 0 failures" "0" "$tie_fails"

# Fixture 9: many entries per check name (5+). The reduction should still
# pick exactly one (the latest by completedAt).
ROLLUP_MANY=$(cat <<'JSON'
{
  "statusCheckRollup": [
    {"name": "Build", "conclusion": "FAILURE", "completedAt": "2026-05-24T15:00:00Z"},
    {"name": "Build", "conclusion": "FAILURE", "completedAt": "2026-05-24T15:15:00Z"},
    {"name": "Build", "conclusion": "FAILURE", "completedAt": "2026-05-24T15:30:00Z"},
    {"name": "Build", "conclusion": "FAILURE", "completedAt": "2026-05-24T15:45:00Z"},
    {"name": "Build", "conclusion": "SUCCESS", "completedAt": "2026-05-24T16:00:00Z"}
  ]
}
JSON
)
many_fails=$(echo "$ROLLUP_MANY" | jq "$JQ_LATEST_PER_NAME")
assert_equals "5 entries for one check name → latest (SUCCESS) wins → 0 failures" "0" "$many_fails"

# Fixture 10: mixed — one check that's a real failure on the latest run +
# another that's been re-triggered and now passes. The latest-per-name
# should report exactly 1 (only the genuine failure).
ROLLUP_MIXED=$(cat <<'JSON'
{
  "statusCheckRollup": [
    {"name": "Stale-then-pass", "conclusion": "FAILURE", "completedAt": "2026-05-24T17:00:00Z"},
    {"name": "Stale-then-pass", "conclusion": "SUCCESS", "completedAt": "2026-05-24T17:10:00Z"},
    {"name": "Genuinely-failing","conclusion": "SUCCESS","completedAt": "2026-05-24T17:00:00Z"},
    {"name": "Genuinely-failing","conclusion": "FAILURE","completedAt": "2026-05-24T17:10:00Z"}
  ]
}
JSON
)
mixed_fails=$(echo "$ROLLUP_MIXED" | jq "$JQ_LATEST_PER_NAME")
assert_equals "mixed rollup (one stale-then-pass + one genuinely-failing) → 1 failure on latest" "1" "$mixed_fails"

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
