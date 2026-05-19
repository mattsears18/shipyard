#!/usr/bin/env bash
# PreToolUse hook — refuses any Agent dispatch of shipyard:issue-worker that
# isn't passed isolation: "worktree". The orchestrator (/do-work) is instructed
# to set this on every dispatch, but a forgotten parameter silently runs the
# agent inside the user's primary checkout — which has caused real harm
# (HEAD jumping mid-session, surprise rebases on the wrong branch).
#
# This is the load-bearing safety net. The skill telling the model "always pass
# isolation: worktree" is necessary but not sufficient; this hook makes the
# omission impossible to ship.
#
# Contract: read PreToolUse JSON from stdin, exit 2 + stderr to block.
# Exit 0 for any call we don't care about (different tool, different subagent).

set -u

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
[[ "$tool_name" != "Agent" ]] && exit 0

subagent=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // empty')
[[ "$subagent" != "shipyard:issue-worker" ]] && exit 0

isolation=$(printf '%s' "$input" | jq -r '.tool_input.isolation // empty')
if [[ "$isolation" == "worktree" ]]; then
  exit 0
fi

cat >&2 <<'EOF'
BLOCKED by shipyard/hooks/enforce-worktree-isolation.sh.

You dispatched subagent_type "shipyard:issue-worker" without
isolation: "worktree". That would run the agent inside the user's PRIMARY
checkout instead of an isolated git worktree — `git switch`, `git rebase`,
and `gh pr checkout` inside the agent would move the user's terminal HEAD
around mid-session. This has caused real damage; the orchestrator must
never make this mistake.

Re-dispatch with isolation: "worktree" added to the Agent call. The
harness will provision an isolated worktree under .claude/worktrees/agent-<id>/
and run the agent there.

This rule is documented in plugins/shipyard/commands/do-work.md
(Setup §7, Dispatch rules, and the "Don't" list).
EOF

exit 2
