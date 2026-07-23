#!/usr/bin/env bash
# Test: Dynamic Workflows substrate wiring for `mode: issue-work` — issue #788,
# phase 2 of the #782 epic.
#
# Background
# ----------
# #787 (phase 1) committed workflows/do-work-dispatch.workflow.js and
# schemas/worker-return.schema.json as INERT scaffolding: no worker mode
# dispatched through the script, and dispatch-rules.md never mentioned the
# `Workflow` tool at all. #788 (phase 2) wired ONE mode — `issue-work` — to
# actually run through the script when the merged config sets
# `dispatch.substrate: "workflow"`.
#
# SUPERSEDED IN PART BY #789 (phase 3): the remaining six modes are now wired
# too, so a handful of assertions below that originally asserted "ONLY
# issue-work is affected" were updated to their phase-3-accurate wording (the
# substrate section's heading generalized from "for `mode: issue-work`" to
# "for every worker mode", and the config-schema description no longer singles
# out issue-work as the sole affected mode). See
# dispatch-workflow-substrate-789.test.sh for the phase-3-specific coverage
# (the six new prompt builders, the per-mode `args.issues[]` shapes, and the
# extended translation table). This file is kept — rather than deleted — as
# the regression guard for the issue-work-specific mechanics phase 2 shipped
# (the `buildIssueWorkPrompt` builder itself, its augmentations, and the
# worktree-anchor verification), which are all still present unmodified.
#
# This test is the regression guard — if anyone reverts the issue-work
# prompt builder back to a placeholder, drops dispatch-rules.md's substrate
# branch, or lets the two schema copies (schemas/worker-return.schema.json
# and the workflow script's own `workerReturnSchema` literal) drift apart on
# their enum values, the suite fails.
#
# Pure bash (+ jq + node, both already assumed present by CI's ubuntu-latest
# runner and by other suites in this repo), no other external dependencies.
# Run with:
#
#   bash plugins/shipyard/scripts/tests/dispatch-workflow-substrate-788.test.sh

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
worker_return_schema_path="$repo_root/plugins/shipyard/schemas/worker-return.schema.json"
dispatch_rules_path="$repo_root/plugins/shipyard/commands/do-work/dispatch-rules.md"
steady_state_path="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
config_schema_path="$repo_root/plugins/shipyard/schemas/shipyard.config.schema.json"

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

assert_not_contains() {
  local file="$1" needle="$2" label="$3"
  if [[ ! -f "$file" ]] || ! grep -qF -- "$needle" "$file" 2>/dev/null; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    did NOT expect to find in %s:\n    %s\n' "$file" "$needle"
  fi
}

for f in "$workflow_js_path" "$workflow_readme_path" "$worker_return_schema_path" \
         "$dispatch_rules_path" "$steady_state_path" "$config_schema_path"; do
  assert_file_exists "$f" "$(basename "$f") exists"
done

echo
echo "== (A) do-work-dispatch.workflow.js — valid syntax, phase-2 status, issue-work builder"

if command -v node >/dev/null 2>&1; then
  if node --check "$workflow_js_path" >/dev/null 2>&1; then
    assert_pass "do-work-dispatch.workflow.js has valid JS syntax (node --check)"
  else
    assert_fail "do-work-dispatch.workflow.js has valid JS syntax (node --check)"
  fi
else
  echo "  SKIP  node not on PATH — skipping syntax check"
fi

assert_contains "$workflow_js_path" "#788" \
  "header comment still cites #788 (phase 2, issue-work wiring)"
assert_contains "$workflow_js_path" "function buildIssueWorkPrompt(unit, repoSlug)" \
  "a real buildIssueWorkPrompt function exists"
assert_contains "$workflow_js_path" "case 'issue-work':" \
  "buildWorkerPrompt routes issue-work to buildIssueWorkPrompt"
assert_contains "$workflow_js_path" "unit.worktreePath" \
  "issue-work prompt builder consumes a worktreePath field"
assert_contains "$workflow_js_path" "GIT_DIR" \
  "issue-work prompt embeds the git-dir vs git-common-dir worktree-anchor verification"
assert_contains "$workflow_js_path" "unit.verifyGate" \
  "issue-work prompt builder consumes a verifyGate field"
assert_contains "$workflow_js_path" "unit.userFeedback" \
  "issue-work prompt builder consumes a userFeedback field"
assert_contains "$workflow_js_path" "unit.phase1Scope" \
  "issue-work prompt builder consumes a phase1Scope field"
assert_contains "$workflow_js_path" "unit.nextAvailableVersion" \
  "issue-work prompt builder consumes a nextAvailableVersion field"
assert_contains "$workflow_js_path" "GENUINE GAP, closed by the caller" \
  "header comment documents the worktree-isolation gap against the Dynamic Workflows docs"
assert_contains "$workflow_js_path" "the orchestrator provisions the isolated" \
  "header comment documents the caller-side git worktree add mitigation"

echo
echo "== (B) schema parity — workerReturnSchema literal in the .js mirrors worker-return.schema.json"

if command -v jq >/dev/null 2>&1; then
  json_modes=$(jq -r '.properties.mode.enum | sort | join(",")' "$worker_return_schema_path" 2>/dev/null)
  json_outcomes=$(jq -r '.properties.outcome.enum | sort | join(",")' "$worker_return_schema_path" 2>/dev/null)

  # Extract the same two enums from the JS literal via a small inline Node script —
  # avoids a second hand-maintained regex against a moving JS literal.
  if command -v node >/dev/null 2>&1; then
    js_enums=$(node -e "
      const fs = require('fs');
      const src = fs.readFileSync(process.argv[1], 'utf8');
      const modeMatch = src.match(/mode:\s*\{\s*type:\s*'string',\s*enum:\s*\[([^\]]+)\]/);
      const outcomeMatch = src.match(/outcome:\s*\{\s*type:\s*'string',\s*enum:\s*\[([^\]]+)\]/);
      const parseList = (m) => m ? m[1].split(',').map(s => s.trim().replace(/^'|'\$/g, '')).filter(Boolean).sort().join(',') : '';
      console.log(parseList(modeMatch));
      console.log(parseList(outcomeMatch));
    " "$workflow_js_path" 2>/dev/null)
    js_modes=$(printf '%s' "$js_enums" | sed -n '1p')
    js_outcomes=$(printf '%s' "$js_enums" | sed -n '2p')

    if [[ "$json_modes" == "$js_modes" && -n "$json_modes" ]]; then
      assert_pass "mode enum matches between worker-return.schema.json and the .js literal ($json_modes)"
    else
      assert_fail "mode enum matches between worker-return.schema.json and the .js literal"
      printf '    schema: %s\n    js:     %s\n' "$json_modes" "$js_modes"
    fi

    if [[ "$json_outcomes" == "$js_outcomes" && -n "$json_outcomes" ]]; then
      assert_pass "outcome enum matches between worker-return.schema.json and the .js literal ($json_outcomes)"
    else
      assert_fail "outcome enum matches between worker-return.schema.json and the .js literal"
      printf '    schema: %s\n    js:     %s\n' "$json_outcomes" "$js_outcomes"
    fi
  else
    echo "  SKIP  node not on PATH — skipping schema-parity extraction"
  fi
else
  echo "  SKIP  jq not on PATH — skipping schema-parity check"
fi

assert_contains "$worker_return_schema_path" '"issue-work"' \
  "worker-return.schema.json's mode enum includes issue-work"

echo
echo "== (C) dispatch-rules.md — the workflow-substrate dispatch site (all modes)"
echo "   (NOTE: #789 phase 3 widened this section to every mode; #791 phase 5 made it"
echo "   UNCONDITIONAL — the dispatch_substrate branch and the legacy Agent-tool branch"
echo "   were removed along with the config knob. Assertions below track that.)"

assert_contains "$dispatch_rules_path" "Workflow-substrate dispatch" \
  "dispatch-rules.md has the workflow-substrate dispatch section"
assert_not_contains "$dispatch_rules_path" 'dispatch_substrate == "workflow"' \
  "dispatch-rules.md no longer branches on dispatch_substrate (#791 removed the knob)"
assert_not_contains "$dispatch_rules_path" 'dispatch_substrate == "agent"' \
  "dispatch-rules.md no longer carries the legacy Agent-tool substrate branch (#791)"
assert_contains "$dispatch_rules_path" "do-work-dispatch.workflow.js" \
  "dispatch-rules.md's substrate section names the workflow script"
assert_contains "$dispatch_rules_path" "Pre-provision the isolated worktree yourself" \
  "dispatch-rules.md documents caller-side worktree pre-provisioning"
assert_contains "$dispatch_rules_path" "git worktree add" \
  "dispatch-rules.md's substrate section shows the git worktree add invocation"
assert_contains "$dispatch_rules_path" "Translate the structured result back into the existing free-text vocabulary" \
  "dispatch-rules.md documents the structured-to-free-text translation step"
assert_contains "$dispatch_rules_path" "One work unit per \`Workflow\` call — not a batch" \
  "dispatch-rules.md documents the one-unit-per-call concurrency model"

echo
echo "== (D) steady-state.md — A.1 documents the translation shim, doesn't re-parse structured returns"

assert_contains "$steady_state_path" "worker-return.schema.json" \
  "steady-state.md's A.1 documents the structured-return schema the translation shim consumes"
assert_contains "$steady_state_path" "translated into free text before reaching this step, not parsed here directly" \
  "steady-state.md's A.1 documents the translation happens before this step"
assert_contains "$steady_state_path" "#788" \
  "steady-state.md's A.1 note cites #788"

echo
echo "== (E) shipyard.config.schema.json — the dispatch.substrate knob is GONE (#791)"

# #788 wired the first mode behind this knob and #790 flipped its default; #791
# retired the legacy substrate entirely, so the knob is dead config and was
# removed from the schema. Guard against it being reintroduced.
assert_not_contains "$config_schema_path" '"substrate"' \
  "shipyard.config.schema.json no longer declares dispatch.substrate (#791)"

if command -v jq >/dev/null 2>&1; then
  if jq empty "$config_schema_path" >/dev/null 2>&1; then
    assert_pass "shipyard.config.schema.json is still valid JSON after the description edit"
  else
    assert_fail "shipyard.config.schema.json is still valid JSON after the description edit"
  fi
fi

echo
echo "== (F) workflows/README.md — current phase status, no stale phase-1-inert framing"

assert_contains "$workflow_readme_path" "Phase 5" \
  "README declares the current (phase 5) status"
assert_not_contains "$workflow_readme_path" "nothing here is wired yet" \
  "README no longer claims nothing is wired"

echo
printf 'passed: %d  failed: %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]] || exit 1
