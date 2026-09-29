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

# The return contract advertises SIX strings now (green/noop/pending/dirty/flake/blocked) —
# widened from five to six by #1015's `dirty` disposition.
assert_contains "$fix_checks_path" \
  "one of the six strings below" \
  "return contract widened from five to six terminal strings"

# --- The `dirty` disposition (#1015) ----------------------------------------

assert_contains "$fix_checks_path" \
  "## DIRTY-PR short-circuit" \
  "DIRTY-PR short-circuit section heading present"
assert_contains "$fix_checks_path" \
  "github.com/mattsears18/shipyard/issues/1015" \
  "links issue #1015 for provenance"
assert_contains "$fix_checks_path" \
  "dirty #<M>: PR conflicts with <default-branch>; no merge ref, so no checks will run" \
  "documents the distinct dirty return string"
assert_contains "$fix_checks_path" \
  "Does **not** count toward the 3-attempt cap and does **not** earn" \
  "return contract notes dirty does not burn a fix attempt or earn blocked:ci"

assert_section_before "$fix_checks_path" \
  "## DIRTY-PR short-circuit" \
  "## Hard rules" \
  "DIRTY-PR short-circuit precedes the Hard rules section (checked before any fix attempt)"
assert_section_before "$fix_checks_path" \
  "## DIRTY-PR short-circuit" \
  "## Fix-loop" \
  "DIRTY-PR short-circuit precedes the Fix-loop section"

# --- Step A: never bail 'logs unavailable' on an in-progress run ------------
# Step A's heading and body were updated by issue #984 to scope the wait to
# the SPECIFIC failing job (not the whole run) — see
# fix-checks-infra-flake-classification-984.test.sh for the #984 regression
# guard. This test still asserts the underlying #654 invariant survived the
# #984 rewrite: a premature "logs unavailable" bail is still named and still
# forbidden, just no longer phrased as "wait for the whole run to settle."

assert_contains "$fix_checks_path" \
  "resolve the failing job's own logs; don't wait on siblings" \
  "Step A: in-progress run is a wait-signal (scoped to the specific job), not a bail"

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

# --- #1609: contended-host in-test step timeout ------------------------------
# The likeliest self-hosted flake shape (a clean job start, then the heaviest
# route's page.goto times out under load) was missing from the list, so a
# worker had to classify it by analogy. It is admitted ONLY with a
# corroborating contention probe and a local pass of the timed-out spec — a
# test timeout, unlike the other four, can be a real defect.
assert_contains "$fix_checks_path" \
  "contended-host in-test step timeout" \
  "#1609 signature: contended-host in-test step timeout"
assert_contains "$fix_checks_path" \
  "contended-host-step-timeout" \
  "#1609 signature tag listed in the flake return vocabulary"
assert_contains "$fix_checks_path" \
  "git cat-file -e <sha>^{commit}" \
  "#1609 corroborating probe (a): unrelated trivial command timed out in the same job"
assert_contains "$fix_checks_path" \
  "detect-ci-runner-capacity.sh" \
  "#1609 corroborating probe (b): saturated-pool read"
assert_contains "$fix_checks_path" \
  "The timed-out spec(s) pass locally." \
  "#1609 signature requires the timed-out spec to pass locally"
assert_contains "$fix_checks_path" \
  "Never \"fix\" a contention timeout by weakening the test" \
  "#1609 forbids weakening the test to satisfy a contention timeout"
assert_contains "$dispatch_rules_path" \
  "CI pool state at dispatch" \
  "#1609 dispatch-rules hands the fix-checks worker fresh pool state on a self-hosted pool"
assert_contains "$repo_root/plugins/shipyard/workflows/prompt-templates/fix-checks-only.mjs" \
  "unit.ciPoolState" \
  "#1609 workflow-substrate fix-checks prompt renders ciPoolState"
assert_contains "$repo_root/plugins/shipyard/workflows/do-work-dispatch.core.js" \
  "ciPoolState: it.ciPoolState" \
  "#1609 core.js passes ciPoolState through the unit normalizer (#1615)"

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
  "\`green\`, \`noop:\`, \`pending\`, \`dirty\`, \`flake\`, or \`blocked\`" \
  "unrecognized-return path lists flake and dirty as recognized prefixes"

# --- The `dirty` disposition reconcile branch (#1015) -----------------------

assert_contains "$steady_state_path" \
  "dirty #<M>: PR conflicts with" \
  "steady-state reconcile has a dirty branch"
assert_contains "$steady_state_path" \
  "[fix-checks-dirty]" \
  "reconcile logs a distinct [fix-checks-dirty] advisory"
assert_contains "$steady_state_path" \
  "mergeStateStatus == \"DIRTY\"" \
  "unrecognized-return synthesis checks mergeStateStatus before the empty-rollup rule"

# The dirty branch must NOT label blocked:ci and must NOT push onto failed_prs.
if grep -A6 "dirty #<M>: PR conflicts with \`<default-branch>\`; no merge ref, so no checks will run\*\* (\[#1015\]" "$steady_state_path" 2>/dev/null \
     | grep -q "do \*\*NOT\*\* label \`blocked:ci\`"; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "dirty branch does not label blocked:ci"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "dirty branch does not label blocked:ci"; fail=$((fail+1))
fi

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

# --- Dispatch prompt advertises the dirty return value (#1015) -------------

assert_contains "$dispatch_rules_path" \
  "dirty #<M>: PR conflicts with <default-branch>; no merge ref, so no checks will run" \
  "fix-checks-only dispatch prompt advertises the dirty return value"

# --- Structured-return schema recognizes the dirty outcome (#1015) ---------

schema_path="$repo_root/plugins/shipyard/schemas/worker-return.schema.json"
core_js_path="$repo_root/plugins/shipyard/workflows/do-work-dispatch.core.js"
workflow_js_path="$repo_root/plugins/shipyard/workflows/do-work-dispatch.workflow.js"
prompt_template_path="$repo_root/plugins/shipyard/workflows/prompt-templates/fix-checks-only.mjs"

assert_contains "$schema_path" '"dirty"' "canonical schema outcome enum includes dirty"
assert_contains "$core_js_path" "'dirty'" "do-work-dispatch.core.js workerReturnSchema literal includes dirty"
assert_contains "$workflow_js_path" "'dirty'" "regenerated do-work-dispatch.workflow.js includes dirty"
assert_contains "$prompt_template_path" '"outcome": "dirty"' \
  "fix-checks-only.mjs prompt template documents the dirty structured-return example"

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
