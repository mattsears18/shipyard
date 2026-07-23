#!/usr/bin/env bash
# Test: the `dispatch.substrate` config knob stays RETIRED, and the `Workflow`-
# substrate script stays self-sufficient as a documented dispatch shape — issue
# #791, phase 5 of 5 (the final phase) of the #782 Dynamic Workflows epic.
#
# AMENDED BY #825 — Agent-tool dispatch is no longer retired.
# ------------------------------------------------------------
# #791's original premise was that the `Workflow` substrate was THE ONLY dispatch
# mechanism for every `mode:`-driven worker, with the `Agent`-tool path fully
# removed. Issue #825 found that a `Workflow`-substrate-dispatched worker could
# not perform a single file write (the harness refused every Edit/Write call
# with a "parent bg session hasn't isolated" error, reproduced with the parent
# orchestrator isolated and unisolated alike) and restored the `Agent`-tool
# dispatch shape — `subagent_type` + `isolation: "worktree"` — as the DEFAULT for
# all seven modes, WITHOUT reintroducing the `dispatch.substrate` knob. This
# suite now pins the surviving, still-true invariants from #791 (the knob stays
# gone; the `Workflow` substrate stays self-sufficient as the documented
# alternate shape) plus new section (H), which pins the #825 restoration itself.
#
# Background — issue #791
# -----------------------
# #787 committed workflows/do-work-dispatch.workflow.js as inert scaffolding.
# #788 wired `issue-work` to it. #789 wired the remaining six modes. #790 flipped
# the built-in `dispatch.substrate` default from "agent" to "workflow" (the 3.0.0
# major bump) while RETAINING the hand-rolled `Agent`-tool orchestrator for one
# release as an instant-revert override. #791 removed that legacy path and the
# `dispatch.substrate` knob — #825 restored the `Agent`-tool dispatch SHAPE as
# the default (see above) but did NOT restore the knob; there is still no config
# flag choosing between shapes.
#
# THE CORRECTNESS BAR THIS SUITE ENFORCES
# ---------------------------------------
# The `Workflow`-substrate instructions must stay COMPLETE and SELF-SUFFICIENT as
# a documented alternate shape: an orchestrator choosing to dispatch through it
# must be able to run every one of the seven worker modes end-to-end, AND the
# worktree-isolation guarantee must still be enforced by a concrete mechanism
# under BOTH shapes. That is what sections (A)-(H) below pin:
#
#   (A) the knob is gone from the built-in defaults and the schema, and a stale
#       config carrying it is REJECTED rather than silently ignored;
#   (B) dispatch-rules.md's `Workflow`-substrate section is unconditional (no
#       flag read, no two-branch fork) and still documents all five call-site
#       steps, as the documented alternate shape;
#   (C) SELF-SUFFICIENCY — every one of the seven modes has both a worktree
#       pre-provisioning shape and an args.issues[] example, and the workflow
#       script has a real prompt builder for each;
#   (D) the worktree-isolation guarantee is still MECHANICALLY enforced: the
#       PreToolUse hook blocks a `Workflow` dispatch whose work unit carries no
#       worktreePath, and still guards the `Agent` shape for every guarded
#       `subagent_type` (all seven mode shims plus shipyard:verify-worker);
#   (E) the orphaned-worktree cleanup #791 introduces for the `Workflow`-
#       substrate alternate — because the orchestrator creates the worktree
#       BEFORE that shape's dispatch call, a classifier-denied dispatch strands
#       one that no other reap path would find;
#   (F) worker-preamble documents both shapes: anchor-first (Rule 0) worktree
#       discipline for the `Workflow` alternate, and the structured-return
#       contract that alternate shape's translation relies on;
#   (G) docs + schema no longer advertise the retired `dispatch.substrate` knob
#       as available;
#   (H) #825 — the `Agent`-tool shape is documented as the DEFAULT: the routing
#       table names a `subagent_type` per mode again, the six sibling shims
#       (plus the issue-worker router) say they're dispatched by name again, and
#       the config knob is still absent (spec-level default, not configurable).
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
echo "== (B) dispatch-rules.md — the Workflow-substrate section is unconditional, no config-read fork"
# ==========================================================================
assert_not_contains "$dispatch_rules" 'dispatch_substrate == "agent"' \
  "dispatch-rules.md has no config-read Agent-tool substrate branch"
assert_not_contains "$dispatch_rules" 'dispatch_substrate == "workflow"' \
  "dispatch-rules.md has no config-read workflow substrate branch either (nothing to branch on)"
assert_not_contains "$dispatch_rules" 'get dispatch.substrate' \
  "dispatch-rules.md no longer reads the retired config knob"
assert_contains "$dispatch_rules" "Both shapes run the **identical** per-mode prompt template" \
  "dispatch-rules.md states both dispatch shapes cover all seven modes identically"
assert_contains "$dispatch_rules" "Migration — the retired \`dispatch.substrate\` knob" \
  "dispatch-rules.md carries a migration note for repos that set the retired knob"

# ...and the Agent tool is NOT globally banned: decompose-worker still uses it
# (unconditionally, on both shapes — it isn't governed by either one).
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

# ==========================================================================
echo
echo "== (H) #825 — Agent-tool dispatch is documented as the DEFAULT again"
# ==========================================================================
issue_worker_agent="$repo_root/plugins/shipyard/agents/issue-worker.md"

# The routing table names a subagent_type per mode again. Parallel arrays
# (not `declare -A`) — associative arrays are a bash-4+ feature and this suite
# must also run under macOS's bundled bash 3.2.
mode_shim_pairs=(
  "issue-work:shipyard:issue-worker"
  "fix-checks-only:shipyard:fix-checks-worker"
  "fix-rebase:shipyard:fix-rebase-worker"
  "fix-main-ci:shipyard:fix-main-ci-worker"
  "fix-failing-prs-batch:shipyard:fix-pr-batch-worker"
  "investigate:shipyard:investigate-worker"
  "spike:shipyard:spike-worker"
)
for pair in "${mode_shim_pairs[@]}"; do
  mode="${pair%%:*}"
  shim="${pair#*:}"
  assert_contains "$dispatch_rules" "\`${shim}\`" \
    "dispatch-rules.md's routing table names ${shim} for mode: ${mode}"
done

assert_contains "$dispatch_rules" "Agent-tool dispatch — the default dispatch shape" \
  "dispatch-rules.md has a dedicated Agent-tool-dispatch section documenting the default"
assert_contains "$dispatch_rules" "Workflow-substrate dispatch — an alternate dispatch shape" \
  "dispatch-rules.md demotes the Workflow substrate to a documented alternate"

# The knob stays gone even though the shape it used to select is restored.
assert_not_contains "$config_schema" '"substrate"' \
  "the routing restoration did not resurrect dispatch.substrate in the schema"
assert_contains "$dispatch_rules" 'not reinstated by #825' \
  "dispatch-rules.md's Migration note explicitly says the knob was NOT reinstated"

# Every sibling shim (and the issue-worker router) says it's dispatched by name
# again, not merely retained as a hand-dispatch target.
for shim_file in fix-main-ci-worker fix-pr-batch-worker fix-checks-worker \
                 fix-rebase-worker investigate-worker spike-worker; do
  f="$repo_root/plugins/shipyard/agents/${shim_file}.md"
  assert_contains "$f" "dispatches this shim by name again" \
    "${shim_file}.md documents itself as dispatched by name again (#825)"
  assert_not_contains "$f" "no longer dispatches this shim by name" \
    "${shim_file}.md no longer claims it's not dispatched by name"
done

assert_contains "$issue_worker_agent" "Agent\` tool (how \`/shipyard:do-work\` dispatches every one of the 7 modes by default" \
  "issue-worker.md's worktree-isolation contract leads with the Agent-tool default"

echo
printf 'passed: %d  failed: %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]] || exit 1
