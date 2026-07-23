#!/usr/bin/env bash
# Test: the legacy `Agent`-tool dispatch path is RETIRED — issue #791, phase 5
# of 5 (the final phase) of the #782 Dynamic Workflows epic.
#
# Background — issue #791
# -----------------------
# #787 committed workflows/do-work-dispatch.workflow.js as inert scaffolding.
# #788 wired `issue-work` to it. #789 wired the remaining six modes. #790 flipped
# the built-in `dispatch.substrate` default from "agent" to "workflow" (the 3.0.0
# major bump) while RETAINING the hand-rolled `Agent`-tool orchestrator for one
# release as an instant-revert override. #791 removes that legacy path and the
# now-dead `dispatch.substrate` knob.
#
# THE CORRECTNESS BAR THIS SUITE ENFORCES
# ---------------------------------------
# Removing the legacy path removes the fallback, so the surviving `Workflow`-
# substrate instructions must be COMPLETE and SELF-SUFFICIENT: an orchestrator
# reading the post-removal spec must be able to dispatch every one of the seven
# worker modes end-to-end with no reference to a deleted `Agent`-tool branch, AND
# the worktree-isolation guarantee must still be enforced by a concrete
# mechanism. That is what sections (A)-(F) below pin:
#
#   (A) the knob is gone from the built-in defaults and the schema, and a stale
#       config carrying it is REJECTED rather than silently ignored;
#   (B) dispatch-rules.md's substrate section is unconditional (no flag read, no
#       two-branch fork) and still documents all five call-site steps;
#   (C) SELF-SUFFICIENCY — every one of the seven modes has both a worktree
#       pre-provisioning shape and an args.issues[] example, and the workflow
#       script has a real prompt builder for each;
#   (D) the worktree-isolation guarantee is still MECHANICALLY enforced: the
#       PreToolUse hook blocks a `Workflow` dispatch whose work unit carries no
#       worktreePath, and still guards the `Agent` shape for the agents that
#       legitimately still use it (shipyard:verify-worker);
#   (E) the orphaned-worktree cleanup #791 introduces — because the orchestrator
#       now creates the worktree BEFORE the dispatch call, a classifier-denied
#       dispatch strands one that no other reap path would find;
#   (F) worker-preamble re-scoped: anchor-first (Rule 0) worktree discipline and
#       a return contract that names the structured shape.
#
# Pure bash + jq. Run with:
#   bash plugins/shipyard/scripts/tests/legacy-agent-dispatch-retired-791.test.sh

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

helper="$repo_root/plugins/shipyard/scripts/shipyard-config.sh"
config_schema="$repo_root/plugins/shipyard/schemas/shipyard.config.schema.json"
worker_return_schema="$repo_root/plugins/shipyard/schemas/worker-return.schema.json"
dispatch_rules="$repo_root/plugins/shipyard/commands/do-work/dispatch-rules.md"
steady_state="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
pool_fill="$repo_root/plugins/shipyard/commands/do-work/setup/07-pool-fill.md"
workflow_js="$repo_root/plugins/shipyard/workflows/do-work-dispatch.workflow.js"
workflow_readme="$repo_root/plugins/shipyard/workflows/README.md"
hook="$repo_root/plugins/shipyard/hooks/enforce-worktree-isolation.sh"
preamble="$repo_root/plugins/shipyard/skills/worker-preamble/SKILL.md"

MODES=(issue-work fix-checks-only fix-rebase fix-main-ci fix-failing-prs-batch investigate spike)

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    expected: %q\n    actual:   %q\n' "$expected" "$actual"
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

# ==========================================================================
echo "== (A) the dispatch.substrate knob is removed — defaults, schema, and stale configs"
# ==========================================================================
assert_not_contains "$helper" '"substrate"' \
  "shipyard-config.sh built-in defaults no longer declare dispatch.substrate"
assert_not_contains "$config_schema" '"substrate"' \
  "shipyard.config.schema.json no longer declares dispatch.substrate"

cfg_repo=$(mktemp -d)
cfg_home=$(mktemp -d)
export SHIPYARD_REPO_ROOT="$cfg_repo"
export SHIPYARD_HOME="$cfg_home"

"$helper" get dispatch.substrate >/dev/null 2>&1
assert_eq "$?" "3" "get dispatch.substrate exits 3 (path not present in the effective config)"

# A stale config carrying the retired knob must FAIL loudly rather than be
# silently ignored — that's what tells an upgrading repo to delete the block,
# and it's the breaking change behind the major version bump.
printf '{"version":1,"dispatch":{"substrate":"agent"}}' > "$cfg_repo/shipyard.config.json"
"$helper" validate --layer repo >/dev/null 2>&1
assert_eq "$?" "70" "a stale dispatch.substrate config is REJECTED, not silently ignored"

rm -rf "$cfg_repo" "$cfg_home"
unset SHIPYARD_REPO_ROOT SHIPYARD_HOME

# ==========================================================================
echo
echo "== (B) dispatch-rules.md — the substrate section is unconditional, no legacy fork"
# ==========================================================================
assert_not_contains "$dispatch_rules" 'dispatch_substrate == "agent"' \
  "dispatch-rules.md has no legacy Agent-tool substrate branch"
assert_not_contains "$dispatch_rules" 'dispatch_substrate == "workflow"' \
  "dispatch-rules.md has no workflow substrate branch either (nothing to branch on)"
assert_not_contains "$dispatch_rules" 'get dispatch.substrate' \
  "dispatch-rules.md no longer reads the retired config knob"
assert_contains "$dispatch_rules" "for all seven \`mode:\` values" \
  "dispatch-rules.md states the substrate is the mechanism for all seven modes"
assert_contains "$dispatch_rules" "Migration — the retired \`dispatch.substrate\` knob" \
  "dispatch-rules.md carries a migration note for repos that set the retired knob"

# The routing table must no longer name an Agent-tool subagent_type per mode.
for shim in shipyard:issue-worker shipyard:fix-checks-worker shipyard:fix-rebase-worker \
            shipyard:fix-main-ci-worker shipyard:fix-pr-batch-worker shipyard:investigate-worker \
            shipyard:spike-worker; do
  # The shim name may still appear in the historical/rationale paragraph, but not
  # as a `subagent_type: "<shim>"` dispatch directive.
  assert_not_contains "$dispatch_rules" "subagent_type: \"${shim}\"" \
    "dispatch-rules.md no longer issues subagent_type: \"${shim}\""
done

# ...but the Agent tool is NOT globally banned: decompose-worker still uses it.
assert_contains "$dispatch_rules" 'subagent_type: "shipyard:decompose-worker"' \
  "decompose-worker's Agent-tool dispatch is deliberately retained (not a mode: worker)"

# ==========================================================================
echo
echo "== (C) SELF-SUFFICIENCY — every mode is dispatchable from the surviving spec alone"
# ==========================================================================
# Each mode needs (1) a worktree pre-provisioning shape, (2) an args.issues[]
# example in dispatch-rules.md, and (3) a real prompt builder in the script.
# Without all three an orchestrator reading the post-removal spec could not
# actually dispatch that mode.
assert_contains "$dispatch_rules" "Pre-provision the isolated worktree yourself" \
  "dispatch-rules.md documents caller-side worktree pre-provisioning"
assert_contains "$dispatch_rules" "git worktree add" \
  "dispatch-rules.md shows the git worktree add invocation"

for mode in "${MODES[@]}"; do
  assert_contains "$dispatch_rules" "\"mode\": \"${mode}\"" \
    "dispatch-rules.md shows an args.issues[] payload for ${mode}"
done

# The three distinct worktree shapes must all still be documented.
# The literal WORKTREE_PATH token is the needle, not an expansion.
# shellcheck disable=SC2016
assert_contains "$dispatch_rules" 'git worktree add "$WORKTREE_PATH" -b "do-work/issue-<N>"' \
  "fresh-branch-off-default worktree shape (issue-work / investigate / spike)"
# The literal WORKTREE_PATH token is the needle, not an expansion.
# shellcheck disable=SC2016
assert_contains "$dispatch_rules" 'git worktree add "$WORKTREE_PATH" -B "<headRefName>"' \
  "existing-PR-branch worktree shape (fix-checks-only / fix-rebase)"
# The literal WORKTREE_PATH token is the needle, not an expansion.
# shellcheck disable=SC2016
assert_contains "$dispatch_rules" 'git worktree add "$WORKTREE_PATH" -b "<synthetic-divert-branch>"' \
  "synthetic-divert worktree shape (fix-main-ci / fix-failing-prs-batch)"

# A real builder per mode (not the defensive placeholder).
for builder in buildIssueWorkPrompt buildFixChecksOnlyPrompt buildFixRebasePrompt \
               buildFixMainCiPrompt buildFixFailingPrsBatchPrompt buildInvestigatePrompt \
               buildSpikePrompt; do
  assert_contains "$workflow_js" "function ${builder}(" \
    "workflow script defines ${builder}"
done

# Model resolution must still reach the dispatched worker.
assert_contains "$dispatch_rules" "resolve-dispatch-model.sh" \
  "dispatch-rules.md still resolves the per-mode model"
assert_contains "$pool_fill" "resolve-dispatch-model.sh" \
  "setup/07-pool-fill.md still resolves the per-mode model"

# The structured return must still be translated back for the reconcile, so
# steady-state.md's whole free-text vocabulary keeps working unchanged.
assert_contains "$dispatch_rules" "Translate the structured result back into the existing free-text vocabulary" \
  "dispatch-rules.md still documents the structured-to-free-text translation"
assert_contains "$steady_state" "worker-return.schema.json" \
  "steady-state.md's A.1 still points at the structured-return schema"

# Both dispatch sites (initial pool fill + steady-state step C) must name the
# Workflow tool, or one of them would be left with no dispatch instruction.
assert_contains "$pool_fill" "\`Workflow\` calls" \
  "setup/07-pool-fill.md dispatches via the Workflow tool"
assert_contains "$pool_fill" "worktreePath" \
  "setup/07-pool-fill.md requires the pre-provisioned worktreePath"
assert_contains "$steady_state" "\`Workflow\` tool call" \
  "steady-state.md step C dispatches via the Workflow tool"

# ==========================================================================
echo
echo "== (D) the worktree-isolation guarantee is still MECHANICALLY enforced"
# ==========================================================================
run_hook() {
  printf '%s' "$1" | bash "$hook" >/dev/null 2>&1
  printf '%s' "$?"
}

# A Workflow dispatch of the do-work substrate with NO worktreePath must block.
payload_missing=$(python3 -c "
import json
print(json.dumps({
    'tool_name': 'Workflow',
    'tool_input': {
        'workflow': '/plugins/shipyard/workflows/do-work-dispatch.workflow.js',
        'args': {'repo': 'o/r', 'issues': [{'number': 1, 'mode': 'issue-work'}]},
    },
}))")
assert_eq "$(run_hook "$payload_missing")" "2" \
  "Workflow dispatch with a work unit missing worktreePath is BLOCKED"

# An empty-string worktreePath is just as unpinned — also blocked.
payload_empty=$(python3 -c "
import json
print(json.dumps({
    'tool_name': 'Workflow',
    'tool_input': {
        'workflow': '/plugins/shipyard/workflows/do-work-dispatch.workflow.js',
        'args': {'repo': 'o/r', 'issues': [{'number': 1, 'mode': 'issue-work', 'worktreePath': ''}]},
    },
}))")
assert_eq "$(run_hook "$payload_empty")" "2" \
  "Workflow dispatch with an EMPTY worktreePath is BLOCKED"

# The correct shape passes through, for every mode.
for mode in "${MODES[@]}"; do
  payload_ok=$(python3 -c "
import json
print(json.dumps({
    'tool_name': 'Workflow',
    'tool_input': {
        'workflow': '/plugins/shipyard/workflows/do-work-dispatch.workflow.js',
        'args': {'repo': 'o/r', 'issues': [{'mode': '$mode', 'worktreePath': '/tmp/wt/agent-workflow-1'}]},
    },
}))")
  assert_eq "$(run_hook "$payload_ok")" "0" \
    "Workflow dispatch of ${mode} WITH worktreePath is allowed"
done

# A mixed batch where only one unit is unisolated must still block.
payload_mixed=$(python3 -c "
import json
print(json.dumps({
    'tool_name': 'Workflow',
    'tool_input': {
        'workflow': '/plugins/shipyard/workflows/do-work-dispatch.workflow.js',
        'args': {'issues': [
            {'mode': 'issue-work', 'worktreePath': '/tmp/wt/a'},
            {'mode': 'fix-rebase'},
        ]},
    },
}))")
assert_eq "$(run_hook "$payload_mixed")" "2" \
  "a batch with ONE unisolated unit is blocked (not just an all-or-nothing check)"

# Some OTHER workflow is none of this hook's business.
payload_other=$(python3 -c "
import json
print(json.dumps({
    'tool_name': 'Workflow',
    'tool_input': {'workflow': '/some/other.workflow.js', 'args': {'issues': [{'mode': 'x'}]}},
}))")
assert_eq "$(run_hook "$payload_other")" "0" \
  "an unrelated Workflow call passes through untouched"

# Malformed input fails OPEN — a hook crash would block every dispatch.
assert_eq "$(run_hook 'not-json-at-all')" "0" "malformed payload fails open"
assert_eq "$(run_hook '{"tool_name":"Workflow"}')" "0" "Workflow call with no tool_input fails open"

# The Agent shape is still guarded for the agents that legitimately use it.
payload_verify=$(python3 -c "
import json
print(json.dumps({'tool_name': 'Agent',
                  'tool_input': {'subagent_type': 'shipyard:verify-worker', 'prompt': 'x'}}))")
assert_eq "$(run_hook "$payload_verify")" "2" \
  "Agent dispatch of shipyard:verify-worker without isolation is still BLOCKED"

assert_contains "$hook" "shipyard:verify-worker" \
  "hook still guards shipyard:verify-worker on the Agent shape"
assert_not_contains "$hook" "shipyard:decompose-worker" \
  "hook still refuses to guard shipyard:decompose-worker (must never be isolated)"

# ==========================================================================
echo
echo "== (E) a pre-provisioned worktree is reaped when the dispatch never happens"
# ==========================================================================
# New failure mode introduced by #791: the orchestrator now creates the worktree
# BEFORE the Workflow call, so a classifier-denied dispatch strands a real
# directory + branch with no .in_flight slot — which no other reap path finds.
assert_contains "$dispatch_rules" "Reap the pre-provisioned worktree on a denial" \
  "dispatch-rules.md's denial branch reaps the orphaned worktree"
# The literal WORKTREE_PATH token is the needle, not an expansion.
# shellcheck disable=SC2016
assert_contains "$dispatch_rules" 'git worktree remove --force "$WORKTREE_PATH"' \
  "dispatch-rules.md shows the orphaned-worktree reap command"
assert_contains "$steady_state" "reap the worktree you pre-provisioned" \
  "steady-state.md step C's denial branch reaps the orphaned worktree"
assert_contains "$pool_fill" "reap the worktree you already pre-provisioned" \
  "setup/07-pool-fill.md's denial branch reaps the orphaned worktree"

# ==========================================================================
echo
echo "== (F) worker-preamble re-scoped to the Workflow dispatch shape"
# ==========================================================================
assert_contains "$preamble" "anchor to your worktree before anything else" \
  "worker-preamble leads worktree discipline with the anchor-first rule"
assert_contains "$preamble" "worktreePath" \
  "worker-preamble names the worktreePath the dispatch supplies"
assert_contains "$preamble" "worktree-anchor" \
  "worker-preamble documents the worktree-anchor blocked stage for a missing path"
assert_contains "$preamble" "STRUCTURED result" \
  "worker-preamble's return contract names the structured return shape"
assert_contains "$preamble" "worker-return.schema.json" \
  "worker-preamble's return contract points at the structured-return schema"
# The anchor must not contradict the never-cd rule.
assert_contains "$preamble" "Never \`cd\` outside your worktree** once anchored" \
  "worker-preamble scopes the never-cd rule to AFTER the anchor"

# The workflow script's own guard must agree with the hook.
assert_contains "$workflow_js" "no worktreePath was supplied" \
  "workflow script refuses to run a unit with no worktreePath"
assert_contains "$workflow_js" "worktree-anchor" \
  "workflow script's guard uses the worktree-anchor blocked stage"

# ==========================================================================
echo
echo "== (G) docs + schema no longer advertise the retired path as available"
# ==========================================================================
assert_not_contains "$workflow_readme" "dispatch.substrate agent" \
  "workflows/README.md no longer advertises the instant-revert command"
assert_contains "$workflow_readme" "delete your \`dispatch\` config block" \
  "workflows/README.md tells upgraders to delete the stale config block"
assert_not_contains "$worker_return_schema" 'dispatch.substrate' \
  "worker-return.schema.json's description no longer references the retired knob"

if command -v jq >/dev/null 2>&1; then
  if jq empty "$config_schema" >/dev/null 2>&1 && jq empty "$worker_return_schema" >/dev/null 2>&1; then
    assert_pass "both schemas are still valid JSON after the removal"
  else
    assert_fail "both schemas are still valid JSON after the removal"
  fi
fi

echo
printf 'passed: %d  failed: %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]] || exit 1
