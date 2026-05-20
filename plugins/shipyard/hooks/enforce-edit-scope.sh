#!/usr/bin/env bash
# PreToolUse hook — blocks Edit/Write/MultiEdit/NotebookEdit calls where the
# agent is running inside an isolated worktree (.claude/worktrees/agent-<id>/)
# but the target file_path points OUTSIDE that worktree.
#
# The companion hook (enforce-worktree-isolation.sh) guards the dispatch side:
# it refuses any shipyard:issue-worker dispatch missing isolation: "worktree".
# That ensures every issue-worker gets a worktree. THIS hook guards the file
# side: even with a worktree, the agent can still type a path that escapes it
# — and has, in practice (issue #60). Editing the user's primary checkout from
# within an agent session can cause:
#
#   - Phantom dirty-tree state in the user's primary checkout — a `git status`
#     in their terminal shows changes they didn't make.
#   - Silent loss if the user runs `git add -A && git commit` from their
#     primary terminal without inspecting the diff.
#   - Mid-session HEAD jumps if the agent then runs git commands against the
#     primary checkout's git directory (separate failure mode covered by
#     issue-worker.md's "Don't `cd` outside your worktree" rule).
#
# Decision rules (all must hold to BLOCK):
#
#   1. Tool name is Edit, Write, MultiEdit, or NotebookEdit.
#   2. Hook's `cwd` is inside `.claude/worktrees/agent-<id>/` — i.e. we are
#      inside an isolated worker's worktree. Orchestrator worktrees
#      (`.claude/worktrees/orchestrator-<...>`) and bare primary-checkout
#      sessions fall through transparently — the orchestrator is allowed to
#      edit anywhere; user sessions are out of scope for this hook.
#   3. The file_path (absolute, or resolved against cwd if relative) is NOT
#      inside the worktree directory.
#
# When all three hold, exit 2 with a clear stderr explaining the rule and the
# fix (use the worktree-relative path, or stop trying to edit the primary).
# Anything else exits 0 transparently.
#
# Defensive defaults: malformed JSON, missing fields, exotic OS paths — all
# fall through to exit 0 rather than block. A buggy hook that blocks every
# edit would be far worse than one that occasionally misses an out-of-scope
# write.
#
# Contract: read PreToolUse JSON from stdin, exit 2 + stderr to block, exit 0
# otherwise. Never propagate other errors.

set -u

# Belt-and-braces — any internal error falls through to "allowed".
trap 'exit 0' ERR

input=$(cat 2>/dev/null || true)

# Bail early on empty or non-JSON input.
if [[ -z "$input" ]]; then
  exit 0
fi

# Use python3 for JSON parsing — already required by the companion
# scripts/report-plugin-error.sh, so we don't widen the dependency surface.
# Single source of decision logic to avoid jq/python skew across hooks.
#
# The python program reads the JSON payload from stdin. We pass `$input` via
# a process substitution so the heredoc delimits the python source while
# stdin remains the payload (the bash <<'PY' / heredoc trick).
PY_DECIDE=$(cat <<'PY'
import json, os, sys

raw = sys.stdin.read() or ""
try:
    d = json.loads(raw)
except Exception:
    # Malformed JSON — allow.
    print("ALLOW")
    sys.exit(0)

tool = d.get("tool_name") or ""
if tool not in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
    print("ALLOW")
    sys.exit(0)

tool_input = d.get("tool_input") or {}
file_path = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
cwd = d.get("cwd") or os.environ.get("PWD") or ""

if not file_path or not cwd:
    print("ALLOW")
    sys.exit(0)

# Identify the agent's worktree by walking up from cwd until we find a
# component matching `.claude/worktrees/agent-<id>`. Anything else (no match,
# orchestrator-* segment, primary checkout) → allow.
#
# normpath collapses any trailing slash / double slash without resolving
# symlinks — we don't want resolve() flipping the path into a different mount.
norm_cwd = os.path.normpath(cwd)
parts = norm_cwd.split(os.sep)

worktree_root = None
for i in range(len(parts) - 1):
    # Need a `.claude/worktrees/agent-<...>` triplet — the .claude and
    # worktrees segments adjacent, followed by an agent-prefixed component.
    if (parts[i] == ".claude" and i + 2 < len(parts)
            and parts[i + 1] == "worktrees"
            and parts[i + 2].startswith("agent-")):
        worktree_root = os.sep.join(parts[: i + 3])
        break

if worktree_root is None:
    print("ALLOW")
    sys.exit(0)

# Resolve file_path relative to cwd (matches how Edit/Write tools themselves
# resolve relative paths) and normalize. Don't follow symlinks — same
# rationale as above.
if not os.path.isabs(file_path):
    file_path = os.path.join(cwd, file_path)
norm_file = os.path.normpath(file_path)

# Inside the worktree? Use commonpath to avoid prefix-substring traps
# (a worktree at /a/b shouldn't accept /a/bb/file).
try:
    common = os.path.commonpath([norm_file, worktree_root])
except ValueError:
    # Different drives (Windows) — treat as outside.
    common = ""

if common == worktree_root:
    print("ALLOW")
    sys.exit(0)

# Out of scope. Print BLOCK with the resolved paths so the stderr message
# can show what the agent tried.
print(f"BLOCK\t{worktree_root}\t{norm_file}")
PY
)

result=$(printf '%s' "$input" | python3 -c "$PY_DECIDE" 2>/dev/null || true)

# Parse python output. Default to ALLOW on any oddity.
case "${result%%$'\t'*}" in
  BLOCK)
    rest="${result#*$'\t'}"
    worktree="${rest%%$'\t'*}"
    target="${rest#*$'\t'}"
    cat >&2 <<EOF
BLOCKED by shipyard/hooks/enforce-edit-scope.sh.

You attempted to edit a file OUTSIDE your isolated worktree:

  worktree:  ${worktree}
  target:    ${target}

Workers dispatched with isolation: "worktree" must confine all file
modifications to their worktree path. Editing the user's primary checkout (or
another agent's worktree) from inside an agent session causes phantom dirty
state in the primary, can leak into the user's next manual commit, and is the
exact failure mode this hook exists to prevent (issue #60).

Fix: re-issue the Edit/Write/MultiEdit/NotebookEdit call with a path under
your worktree root. If you genuinely need to inspect a file outside the
worktree, use Read (which is allowed) — but do not write to it.

If you think this block is wrong (e.g. your worktree path doesn't match the
\`.claude/worktrees/agent-<id>/\` convention), return blocked with the
worktree path so the orchestrator can investigate.
EOF
    exit 2
    ;;
  *)
    exit 0
    ;;
esac
