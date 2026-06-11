#!/usr/bin/env bash
# PreToolUse hook — refuses any Agent dispatch of a shipyard issue-worker
# shim that isn't passed isolation: "worktree". The orchestrator (/do-work)
# is instructed to set this on every dispatch, but a forgotten parameter
# silently runs the agent inside the user's primary checkout — which has
# caused real harm (HEAD jumping mid-session, surprise rebases on the
# wrong branch).
#
# This is the load-bearing safety net. The skill telling the model "always pass
# isolation: worktree" is necessary but not sufficient; this hook makes the
# omission impossible to ship.
#
# Guarded subagents (closes #293 — the original check only matched the
# `shipyard:issue-worker` name exactly, silently passing through the
# model-pinned shims `shipyard:fix-checks-worker`, `shipyard:fix-rebase-worker`,
# `shipyard:fix-main-ci-worker`, `shipyard:fix-pr-batch-worker`,
# `shipyard:investigate-worker`, which forward to the same per-mode specs
# under agents/issue-worker/ and need the same isolation guarantee):
#
#   shipyard:issue-worker               (mode: issue-work — opus)
#   shipyard:fix-checks-worker          (mode: fix-checks-only — haiku)
#   shipyard:fix-rebase-worker          (mode: fix-rebase — haiku)
#   shipyard:fix-main-ci-worker         (mode: fix-main-ci — sonnet)
#   shipyard:fix-pr-batch-worker        (mode: fix-failing-prs-batch — sonnet)
#   shipyard:investigate-worker         (mode: investigate — sonnet)
#
# Also guards the colon-namespaced form `shipyard:issue-worker:*` as
# defense-in-depth in case a future shim ever uses that scheme.
#
# Contract: read PreToolUse JSON from stdin, exit 2 + stderr to block.
# Exit 0 for any call we don't care about (different tool, different subagent).

set -u

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
[[ "$tool_name" != "Agent" ]] && exit 0

subagent=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // empty')

# Match any guarded shim. The set is small enough to inline rather than read
# from a separate registry file — the trade-off here is "one place to update
# when a new worker shim is added" vs "no extra file I/O per Agent dispatch."
# When adding a new shim, also add it here AND to the dispatch routing table
# in commands/do-work/steady-state.md.
case "$subagent" in
  shipyard:issue-worker | \
  shipyard:fix-checks-worker | \
  shipyard:fix-rebase-worker | \
  shipyard:fix-main-ci-worker | \
  shipyard:fix-pr-batch-worker | \
  shipyard:investigate-worker | \
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

This rule is documented in plugins/shipyard/commands/do-work.md
(Setup §7, Dispatch rules, and the "Don't" list).
EOF

exit 2
