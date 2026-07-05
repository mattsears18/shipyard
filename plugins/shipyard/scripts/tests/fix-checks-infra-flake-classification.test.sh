#!/usr/bin/env bash
# Test: the fix-checks-only worker contract documents an infra-flake
# classification-and-re-run path, and the orchestrator reconcile recognizes
# the resulting `flake #<M>` disposition.
#
# Background — issue #654: a `shipyard:fix-checks-worker` (Haiku) dispatch
# against lightwork PR #2273 (session 01XU6TMaDdGnDyptZqJJJiDm, 2026-07-05)
# saw required checks in a failed/cancelled state (Lint & Typecheck cancelled,
# Unit Tests cancelled, E2E all 3 shards failed) and returned
# `blocked #2273 at fix-checks: … logs unavailable while run still in progress`
# — pushing no fix and burning ~139k tokens. The root cause was pure
# INFRASTRUCTURE: the repo runs CI on self-hosted runners on the same host the
# orchestrator dispatches workers to, so runner contention cancelled jobs and
# timed out dev-server boots. All changes passed their local gates; a re-run on
# the idle host was the fix.
#
# The fix adds an "Infra-flake classification and re-run" gate to
# `agents/issue-worker/fix-checks-only.md`: (1) never declare "logs unavailable"
# on an in-progress run — wait for completion first; (2) classify the failure —
# a cancellation / dev-server-timeout / setup-job-failure / runner-lost
# signature WITH passing local gates AND no deterministic code error means the
# worker `gh run rerun --failed`s and returns the distinct `flake #<M>` string
# (bounded by the run's attempt count) instead of attempting a code fix, and
# this does NOT count toward the `blocked:ci` 3-attempt cap; (3) fall through to
# the code-fixing loop only on a deterministic code error. The orchestrator's
# reconcile (steady-state.md) recognizes `flake #<M>` so it doesn't
# mis-handle it as an unrecognized narrative and does NOT label `blocked:ci`.
#
# This test is the regression guard: if the classification gate, the `flake`
# return string, or the reconcile branch regress, the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/fix-checks-infra-flake-classification.test.sh

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

fix_checks_path="$repo_root/plugins/shipyard/agents/issue-worker/fix-checks-only.md"
steady_state_path="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
dispatch_rules_path="$repo_root/plugins/shipyard/commands/do-work/dispatch-rules.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_file_exists() {
  local path="$1"; local label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (missing: %s)\n' "$RED" "$RESET" "$label" "$path"; fail=$((fail+1))
  fi
}

assert_contains() {
  local file="$1"; local needle="$2"; local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"; fail=$((fail+1))
  fi
}

assert_section_before() {
  local file="$1"; local before="$2"; local after="$3"; local label="$4"
  local before_line after_line
  before_line=$(grep -nF -- "$before" "$file" | head -1 | cut -d: -f1)
  after_line=$(grep -nF -- "$after" "$file" | head -1 | cut -d: -f1)
  if [[ -z "$before_line" ]]; then
    printf '  %sFAIL%s  %s (could not find before-marker: %s)\n' "$RED" "$RESET" "$label" "$before"; fail=$((fail+1)); return
  fi
  if [[ -z "$after_line" ]]; then
    printf '  %sFAIL%s  %s (could not find after-marker: %s)\n' "$RED" "$RESET" "$label" "$after"; fail=$((fail+1)); return
  fi
  if (( before_line < after_line )); then
    printf '  %sPASS%s  %s (before @ %d, after @ %d)\n' "$GREEN" "$RESET" "$label" "$before_line" "$after_line"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (before @ %d NOT < after @ %d)\n' "$RED" "$RESET" "$label" "$before_line" "$after_line"; fail=$((fail+1))
  fi
}

echo "fix-checks-only infra-flake classification-and-re-run gate (issue #654)"
echo

assert_file_exists "$fix_checks_path" "fix-checks-only.md exists"
assert_file_exists "$steady_state_path" "steady-state.md exists"
assert_file_exists "$dispatch_rules_path" "dispatch-rules.md exists"

# --- Worker contract: the classification section + its anchor ---------------

assert_contains "$fix_checks_path" \
  "## Infra-flake classification and re-run (load-bearing)" \
  "infra-flake classification section heading present"

assert_contains "$fix_checks_path" \
  "#infra-flake-classification-and-re-run-load-bearing" \
  "anchor slug referenced (cross-links resolve to the classification section)"

assert_contains "$fix_checks_path" \
  "github.com/mattsears18/shipyard/issues/654" \
  "links issue #654 for provenance"

# The distinct terminal return string.
assert_contains "$fix_checks_path" \
  "flake #<M>: re-ran failed jobs" \
  "documents the distinct flake return string"

# The return contract advertises FOUR strings now, not three.
assert_contains "$fix_checks_path" \
  "one of the four strings below" \
  "return contract widened from three to four terminal strings"

# --- Step A: never bail 'logs unavailable' on an in-progress run ------------

assert_contains "$fix_checks_path" \
  "never declare \"logs unavailable\" on an in-progress run" \
  "Step A: in-progress run is a wait-signal, not a bail"

assert_contains "$fix_checks_path" \
  "logs unavailable while run in progress" \
  "names the premature 'logs unavailable' bail as the #654 failure mode"

# --- Step B: the infra-flake signature set ---------------------------------

assert_contains "$fix_checks_path" \
  "The operation was canceled." \
  "signature: cancelled required job"
assert_contains "$fix_checks_path" \
  "config.webServer" \
  "signature: dev-server / webServer boot timeout"
assert_contains "$fix_checks_path" \
  "trivial no-code setup job failed" \
  "signature: setup-job failure"
assert_contains "$fix_checks_path" \
  "runner-level error" \
  "signature: runner-lost / shutdown"

# Local gates MUST pass — the proof the diff is not the cause.
assert_contains "$fix_checks_path" \
  "Local gates pass." \
  "classification requires local gates to pass"

# Deterministic code error present => NOT a flake, fall through to fix-loop.
assert_contains "$fix_checks_path" \
  "No deterministic code error in the logs." \
  "classification excludes a deterministic code error"

# --- Step C: bounded re-run then return flake ------------------------------

assert_contains "$fix_checks_path" \
  "gh run rerun" \
  "re-runs the failed jobs via gh run rerun --failed"
assert_contains "$fix_checks_path" \
  "--json attempt" \
  "reads the run attempt count for the re-run bound"
# shellcheck disable=SC2016  # single-quoted needle is a literal shell expression to grep for, not an expansion
assert_contains "$fix_checks_path" \
  '"${ATTEMPT:-1}" -ge 2' \
  "bounds the re-run at attempt >= 2 (chronic flake escalates to blocked)"

# The re-run must NOT count toward the 3-attempt cap.
assert_contains "$fix_checks_path" \
  "is NOT a fix attempt and does not count toward this cap" \
  "Hard rules: infra-flake re-run does not count toward the 3-attempt cap"

# fix-loop invokes the classification BEFORE any code fix.
assert_contains "$fix_checks_path" \
  "Infra-flake classification (before any code fix)." \
  "fix-loop runs the classification before attempting a code fix"

# --- Don't section entries -------------------------------------------------

assert_contains "$fix_checks_path" \
  "Don't bail \`blocked … logs unavailable while run in progress\`." \
  "Don't section forbids the premature logs-unavailable bail"
assert_contains "$fix_checks_path" \
  "Don't treat a cancelled job / dev-server boot timeout / setup-job failure as an undiagnosable code failure." \
  "Don't section names the infra-flake signature as re-runnable"

# --- Ordering: classification section sits after the named-check gate and
#     before the Fix-loop (so it's read as part of the return contract). -----

assert_section_before "$fix_checks_path" \
  "## Named-failing-check re-verification gate (load-bearing)" \
  "## Infra-flake classification and re-run (load-bearing)" \
  "named-check gate precedes the infra-flake classification"
assert_section_before "$fix_checks_path" \
  "## Infra-flake classification and re-run (load-bearing)" \
  "## Fix-loop" \
  "infra-flake classification precedes the Fix-loop section"

# --- Orchestrator reconcile recognizes the flake disposition ---------------

assert_contains "$steady_state_path" \
  "flake #<M>: re-ran failed jobs" \
  "steady-state reconcile has a flake branch"
assert_contains "$steady_state_path" \
  "[fix-checks-flake]" \
  "reconcile logs a distinct [fix-checks-flake] advisory"
assert_contains "$steady_state_path" \
  "\`green\`, \`noop:\`, \`flake\`, or \`blocked\`" \
  "unrecognized-return path lists flake as a recognized prefix"

# The reconcile must NOT label blocked:ci and must NOT push onto failed_prs.
if grep -A6 "flake #<M>: re-ran failed jobs\*\* (\[#654\]" "$steady_state_path" 2>/dev/null \
     | grep -q "Do \*\*NOT\*\* label \`blocked:ci\`"; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "flake branch does not label blocked:ci"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "flake branch does not label blocked:ci"; fail=$((fail+1))
fi

# --- Dispatch prompt advertises the flake return value ---------------------

assert_contains "$dispatch_rules_path" \
  "flake #<M>: re-ran failed jobs" \
  "fix-checks-only dispatch prompt advertises the flake return value"

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
