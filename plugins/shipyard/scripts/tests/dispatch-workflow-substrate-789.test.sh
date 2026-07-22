#!/usr/bin/env bash
# Test: Dynamic Workflows substrate wiring for the remaining six worker modes —
# issue #789, phase 3 of the #782 epic.
#
# Background
# ----------
# #787 (phase 1) committed workflows/do-work-dispatch.workflow.js and
# schemas/worker-return.schema.json as INERT scaffolding. #788 (phase 2) wired
# ONE mode — `issue-work` — to actually run through the script (regression
# guard: dispatch-workflow-substrate-788.test.sh). This is the #789 slice: it
# wires the REMAINING SIX modes — `fix-checks-only`, `fix-rebase`,
# `fix-main-ci`, `fix-failing-prs-batch`, `investigate`, `spike` — against the
# same script, so that with `dispatch.substrate: "workflow"` set, all seven
# `mode:`-driven workers dispatch through it with schema-validated returns.
# `dispatch.substrate` itself still defaults to `"agent"` — #789 is purely
# additive, exactly like #787/#788 before it.
#
# This test is the regression guard for the phase-3-specific additions — if
# anyone reverts one of the six new prompt builders back to a placeholder,
# drops dispatch-rules.md's per-mode args.issues[] documentation, or the
# translation table's per-mode rows, the suite fails. It does NOT re-assert
# the issue-work-specific mechanics phase 2 shipped — those are covered by
# dispatch-workflow-substrate-788.test.sh (updated in this same PR to its
# phase-3-accurate wording where the two suites' assertions would otherwise
# have overlapped/contradicted).
#
# Pure bash (+ jq + node, both already assumed present by CI's ubuntu-latest
# runner and by other suites in this repo), no other external dependencies.
# Run with:
#
#   bash plugins/shipyard/scripts/tests/dispatch-workflow-substrate-789.test.sh

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

workflow_js_path="$repo_root/plugins/shipyard/workflows/do-work-dispatch.workflow.js"
workflow_readme_path="$repo_root/plugins/shipyard/workflows/README.md"
dispatch_rules_path="$repo_root/plugins/shipyard/commands/do-work/dispatch-rules.md"
steady_state_path="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
config_schema_path="$repo_root/plugins/shipyard/schemas/shipyard.config.schema.json"
enforce_isolation_hook_path="$repo_root/plugins/shipyard/hooks/enforce-worktree-isolation.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_file_exists() {
  local path="$1" label="$2"
  if [[ -f "$path" ]]; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    missing: %s\n' "$path"
  fi
}

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    expected to find in %s:\n    %s\n' "$file" "$needle"
  fi
}

for f in "$workflow_js_path" "$workflow_readme_path" "$dispatch_rules_path" \
         "$steady_state_path" "$config_schema_path"; do
  assert_file_exists "$f" "$(basename "$f") exists"
done

echo
echo "== (A) do-work-dispatch.workflow.js — valid syntax, phase-3 status"

if command -v node >/dev/null 2>&1; then
  if node --check "$workflow_js_path" >/dev/null 2>&1; then
    assert_pass "do-work-dispatch.workflow.js has valid JS syntax (node --check)"
  else
    assert_fail "do-work-dispatch.workflow.js has valid JS syntax (node --check)"
  fi
else
  echo "  SKIP  node not on PATH — skipping syntax check"
fi

assert_contains "$workflow_js_path" "PHASE 3 (issue #789" \
  "header comment declares phase 3 (#789) status"
assert_contains "$workflow_js_path" "all seven \`mode:\`-driven workers dispatch" \
  "header comment declares every mode is wired"

echo
echo "== (B) do-work-dispatch.workflow.js — a real builder for each of the six new modes"

for pair in \
  "fix-checks-only:buildFixChecksOnlyPrompt" \
  "fix-rebase:buildFixRebasePrompt" \
  "fix-main-ci:buildFixMainCiPrompt" \
  "fix-failing-prs-batch:buildFixFailingPrsBatchPrompt" \
  "investigate:buildInvestigatePrompt" \
  "spike:buildSpikePrompt"
do
  mode="${pair%%:*}"
  fn="${pair##*:}"
  assert_contains "$workflow_js_path" "function ${fn}(unit, repoSlug)" \
    "a real ${fn} function exists (mode: ${mode})"
  assert_contains "$workflow_js_path" "case '${mode}':" \
    "buildWorkerPrompt routes ${mode} to ${fn}"
  assert_contains "$workflow_js_path" "return ${fn}(unit, repoSlug)" \
    "buildWorkerPrompt's ${mode} case actually calls ${fn}"
done

echo
echo "== (C) do-work-dispatch.workflow.js — per-mode fields consumed by the new builders"

assert_contains "$workflow_js_path" "unit.pr" \
  "fix-checks-only/fix-rebase builders consume a pr field"
assert_contains "$workflow_js_path" "unit.headRefName" \
  "fix-checks-only/fix-rebase builders consume a headRefName field"
assert_contains "$workflow_js_path" "unit.versionCoordinationParagraph" \
  "fix-rebase builder consumes a versionCoordinationParagraph field (§4.6 carve-out)"
assert_contains "$workflow_js_path" "unit.earliestRedRunUrl" \
  "fix-main-ci builder consumes an earliestRedRunUrl field"
assert_contains "$workflow_js_path" "unit.earliestRedSha" \
  "fix-main-ci builder consumes an earliestRedSha field"
assert_contains "$workflow_js_path" "unit.failingPrCountAll" \
  "fix-failing-prs-batch builder consumes a failingPrCountAll field"
assert_contains "$workflow_js_path" "unit.failingPrNumbers" \
  "fix-failing-prs-batch builder consumes a failingPrNumbers field"
assert_contains "$workflow_js_path" "unit.triageAutoClose" \
  "investigate builder consumes a triageAutoClose field"
assert_contains "$workflow_js_path" "unit.decomposeMaxSubissues" \
  "spike builder consumes a decomposeMaxSubissues field"

echo
echo "== (D) do-work-dispatch.workflow.js — shared worktree-anchor helper used by all six new builders"

assert_contains "$workflow_js_path" "function worktreeAnchorLines(unit, mode)" \
  "a shared worktreeAnchorLines helper exists"
assert_contains "$workflow_js_path" "worktreeAnchorLines(unit, 'fix-checks-only')" \
  "fix-checks-only builder uses the shared anchor helper"
assert_contains "$workflow_js_path" "worktreeAnchorLines(unit, 'fix-rebase')" \
  "fix-rebase builder uses the shared anchor helper"
assert_contains "$workflow_js_path" "worktreeAnchorLines(unit, 'fix-main-ci')" \
  "fix-main-ci builder uses the shared anchor helper"
assert_contains "$workflow_js_path" "worktreeAnchorLines(unit, 'fix-failing-prs-batch')" \
  "fix-failing-prs-batch builder uses the shared anchor helper"
assert_contains "$workflow_js_path" "worktreeAnchorLines(unit, 'investigate')" \
  "investigate builder uses the shared anchor helper"
assert_contains "$workflow_js_path" "worktreeAnchorLines(unit, 'spike')" \
  "spike builder uses the shared anchor helper"

echo
echo "== (E) dispatch-rules.md — the workflow-substrate section now covers every mode"

assert_contains "$dispatch_rules_path" "Workflow-substrate dispatch for every worker mode" \
  "dispatch-rules.md's substrate section heading covers every mode"
assert_contains "$dispatch_rules_path" "#789" \
  "dispatch-rules.md's substrate section cites #789"
assert_contains "$dispatch_rules_path" "changes real behavior for **every** \`mode:\`-driven dispatch site" \
  "dispatch-rules.md is explicit that every mode is affected by the flag, not just issue-work"

for mode in "fix-checks-only" "fix-rebase" "fix-main-ci" "fix-failing-prs-batch" "investigate" "spike"; do
  assert_contains "$dispatch_rules_path" "\"mode\": \"${mode}\"" \
    "dispatch-rules.md's substrate section shows an args.issues[] example for ${mode}"
done

# shellcheck disable=SC2016  # literal needle — must NOT expand $WORKTREE_PATH
assert_contains "$dispatch_rules_path" 'git worktree add "$WORKTREE_PATH" -B "<headRefName>"' \
  "dispatch-rules.md documents the existing-branch worktree pre-provisioning for fix-checks-only/fix-rebase"
assert_contains "$dispatch_rules_path" "resolve-dispatch-model.sh <mode>" \
  "dispatch-rules.md documents mode-parameterized model resolution (preserves per-mode pins)"

echo
echo "== (F) dispatch-rules.md — translation table covers every mode's outcome vocabulary"

for needle in \
  "green #M" \
  "flake #M: re-ran failed jobs" \
  "rebased #M" \
  "blocked rebase #M" \
  "shipped main-ci-fix via PR #M" \
  "noop: main already green" \
  "blocked main-ci-fix" \
  "shipped pr-batch-fix via PR #M" \
  "noop: pileup already cleared" \
  "blocked pr-batch-fix" \
  "investigated+fixed #N via PR #M" \
  "investigated+needs-human-review #N" \
  "investigated+closed-noise #N" \
  "investigated+duplicate #N of #K" \
  "spiked+shipped #N via PR #M" \
  "spiked+needs-human-review #N"
do
  assert_contains "$dispatch_rules_path" "$needle" \
    "translation table covers: $needle"
done

echo
echo "== (G) steady-state.md — A.1 generalized to every mode, not issue-work-only"

assert_contains "$steady_state_path" "for every mode, as of phase 3" \
  "steady-state.md's A.1 note generalizes the translation shim to every mode"
assert_contains "$steady_state_path" "#789" \
  "steady-state.md's A.1 note cites #789"

echo
echo "== (H) shipyard.config.schema.json — dispatch.substrate description names all seven modes"

for mode in "fix-checks-only" "fix-rebase" "fix-main-ci" "fix-failing-prs-batch" "investigate" "spike"; do
  assert_contains "$config_schema_path" "$mode" \
    "dispatch.substrate description names ${mode} among the affected modes"
done
assert_contains "$config_schema_path" '"default": "agent"' \
  "dispatch.substrate default is still agent (unchanged by #789)"

if command -v jq >/dev/null 2>&1; then
  if jq empty "$config_schema_path" >/dev/null 2>&1; then
    assert_pass "shipyard.config.schema.json is still valid JSON after the description edit"
  else
    assert_fail "shipyard.config.schema.json is still valid JSON after the description edit"
  fi
fi

echo
echo "== (I) workflows/README.md — phase-3 status, no stale phase-2-only-issue-work framing"

assert_contains "$workflow_readme_path" "Phase 3" \
  "README declares phase 3 status"
assert_contains "$workflow_readme_path" "#789" \
  "README cites #789"

echo
echo "== (J) enforce-worktree-isolation.sh — guarded-set unaffected by the substrate migration"

# The workflow substrate is an ADDITIVE dispatch mechanism — it doesn't touch
# the Agent-tool isolation contract. Every shim this hook guards must still be
# guarded; #789 must not have quietly narrowed the guarded set while adding
# workflow-substrate wiring.
for shim in "shipyard:fix-checks-worker" "shipyard:fix-rebase-worker" \
            "shipyard:fix-main-ci-worker" "shipyard:fix-pr-batch-worker" \
            "shipyard:investigate-worker" "shipyard:spike-worker" "shipyard:issue-worker"; do
  assert_contains "$enforce_isolation_hook_path" "$shim" \
    "enforce-worktree-isolation.sh still guards ${shim} (unaffected by the #789 substrate wiring)"
done

echo
printf 'passed: %d  failed: %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]] || exit 1
