#!/usr/bin/env bash
# PreToolUse hook — refuses any /shipyard:do-work worker dispatch that would run
# outside an isolated git worktree. A worker that lands in the user's primary
# checkout has caused real harm (HEAD jumping mid-session, surprise rebases on
# the wrong branch), so the guarantee is enforced mechanically, not just
# documented. The skill telling the model "always isolate the worker" is
# necessary but not sufficient; this hook makes the omission impossible to ship.
#
# TWO DISPATCH SHAPES ARE GUARDED (issue #791, the final phase of the #782
# Dynamic Workflows epic, retired the legacy `Agent`-tool dispatch path for the
# seven `mode:`-driven worker modes — but "worktree-isolated dispatch" still
# exists in both shapes, for different callers):
#
#   1. `Workflow` tool — the substrate every `mode:`-driven worker now dispatches
#      through (workflows/do-work-dispatch.workflow.js). The Dynamic Workflows
#      `agent()` primitive has NO isolation option of its own, so the ORCHESTRATOR
#      pre-provisions each worker's worktree with `git worktree add` and passes the
#      absolute path in as the work unit's `worktreePath`. A work unit dispatched
#      with no `worktreePath` would run from an unpinned cwd — the exact harm this
#      hook exists to prevent — so it is blocked here. This is the `Workflow`-tool
#      equivalent of the `isolation: "worktree"` parameter.
#
#   2. `Agent` tool — still the dispatch mechanism for the worktree-isolated
#      agents that are NOT `mode:`-driven workers, chiefly `shipyard:verify-worker`
#      (dispatched by the issue-work worker itself, not by the orchestrator's
#      per-mode routing). The seven retired mode shims stay in the guarded set as
#      defense-in-depth: their agent definitions still exist and can still be
#      dispatched by hand, and a hand dispatch needs the same guarantee.
#
# Guarded subagents on the `Agent` shape (closes #293 — the original check only
# matched the `shipyard:issue-worker` name exactly, silently passing through the
# model-pinned shims, which forward to the same per-mode specs under
# agents/issue-worker/ and need the same isolation guarantee):
#
#   shipyard:issue-worker               (mode: issue-work)
#   shipyard:fix-checks-worker          (mode: fix-checks-only — haiku)
#   shipyard:fix-rebase-worker          (mode: fix-rebase — haiku)
#   shipyard:fix-main-ci-worker         (mode: fix-main-ci — sonnet)
#   shipyard:fix-pr-batch-worker        (mode: fix-failing-prs-batch — sonnet)
#   shipyard:investigate-worker         (mode: investigate — sonnet)
#   shipyard:spike-worker               (mode: spike, added #774)
#   shipyard:verify-worker              (mode: verify — opus 4.8, added #783)
#
# Also guards the colon-namespaced form `shipyard:issue-worker:*` as
# defense-in-depth in case a future shim ever uses that scheme.
#
# Deliberately NOT guarded: the decomposition agent (see its own file under
# agents/ for why) — it never touches code and must never be dispatched with
# isolation: "worktree".
#
# Contract: read PreToolUse JSON from stdin, exit 2 + stderr to block.
# Exit 0 for any call we don't care about (different tool, different subagent,
# a `Workflow` call against some other workflow). Malformed input fails OPEN —
# a hook crash would block every dispatch.

set -u

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')

# ---------------------------------------------------------------------------
# Shape 1 — the `Workflow` tool dispatching shipyard's do-work substrate.
# ---------------------------------------------------------------------------
if [[ "$tool_name" == "Workflow" ]]; then
  # Only guard shipyard's own dispatch workflow. The tool's exact input field
  # names aren't part of a stable public contract, so match on the script
  # identifier appearing anywhere in tool_input rather than pinning a key path.
  if ! printf '%s' "$input" \
    | jq -e '((.tool_input // {}) | tostring) | test("do-work-dispatch")' >/dev/null 2>&1; then
    exit 0
  fi

  # Recursively find every work unit — an object carrying a `mode` field inside
  # some `issues` array — and collect the ones dispatched with no worktreePath.
  # Recursive descent (`..`) keeps this robust against the args payload being
  # nested one level deeper than expected.
  unisolated=$(printf '%s' "$input" | jq -r '
    [ (.tool_input // {})
      | .. | objects | select(has("issues"))
      | .issues | arrays | .[]
      | objects | select(has("mode"))
      | select((.worktreePath // "") == "")
      | .mode ]
    | join(", ")
  ' 2>/dev/null) || exit 0

  [[ -z "$unisolated" ]] && exit 0

  cat >&2 <<EOF
BLOCKED by shipyard/hooks/enforce-worktree-isolation.sh.

You invoked the Workflow tool against do-work-dispatch.workflow.js with one or
more work units that carry no "worktreePath": ${unisolated}

The Dynamic Workflows agent() primitive has no isolation option — unlike the
Agent tool's isolation: "worktree", nothing in the workflow runtime provisions
or cwd-pins a worktree for the dispatched worker. The orchestrator MUST do it
itself before the call:

  WORKTREE_ID="agent-workflow-\$(date +%s)-\$\$"
  WORKTREE_PATH="\$(git rev-parse --show-toplevel)/.claude/worktrees/\${WORKTREE_ID}"
  git worktree add "\$WORKTREE_PATH" -b "<branch>" "origin/<default-branch>"

…then pass that absolute path as each work unit's "worktreePath". Without it the
worker runs from an unpinned cwd — in practice the user's PRIMARY checkout —
where \`git switch\`, \`git rebase\`, and \`gh pr checkout\` move the user's
terminal HEAD around mid-session. This has caused real damage.

This rule is documented in plugins/shipyard/commands/do-work/dispatch-rules.md
("Workflow-substrate dispatch for every worker mode", step 1).
EOF

  exit 2
fi

# ---------------------------------------------------------------------------
# Shape 2 — the `Agent` tool dispatching a guarded shipyard worker shim.
# ---------------------------------------------------------------------------
[[ "$tool_name" != "Agent" ]] && exit 0

subagent=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // empty')

# Match any guarded shim. The set is small enough to inline rather than read
# from a separate registry file — the trade-off here is "one place to update
# when a new worker shim is added" vs "no extra file I/O per Agent dispatch."
# When adding a new worktree-isolated Agent-tool worker, add it here too.
case "$subagent" in
  shipyard:issue-worker | \
  shipyard:fix-checks-worker | \
  shipyard:fix-rebase-worker | \
  shipyard:fix-main-ci-worker | \
  shipyard:fix-pr-batch-worker | \
  shipyard:investigate-worker | \
  shipyard:spike-worker | \
  shipyard:verify-worker | \
  shipyard:issue-worker:* )
    ;;
  *)
    exit 0
    ;;
esac

isolation=$(printf '%s' "$input" | jq -r '.tool_input.isolation // empty')
if [[ "$isolation" == "worktree" ]]; then
  exit 0
fi

cat >&2 <<EOF
BLOCKED by shipyard/hooks/enforce-worktree-isolation.sh.

You dispatched subagent_type "${subagent}" without
isolation: "worktree". That would run the agent inside the user's PRIMARY
checkout instead of an isolated git worktree — \`git switch\`, \`git rebase\`,
and \`gh pr checkout\` inside the agent would move the user's terminal HEAD
around mid-session. This has caused real damage; the orchestrator must
never make this mistake.

Re-dispatch with isolation: "worktree" added to the Agent call. The
harness will provision an isolated worktree under .claude/worktrees/agent-<id>/
and run the agent there.

(The seven \`mode:\`-driven worker modes are dispatched through the Workflow
substrate now — see workflows/do-work-dispatch.workflow.js and this hook's
Workflow branch — but their shims remain guarded here for hand dispatches.)

This rule is documented in plugins/shipyard/commands/do-work.md
(Setup §7, Dispatch rules, and the "Don't" list).
EOF

exit 2
