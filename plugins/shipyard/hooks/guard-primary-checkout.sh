#!/usr/bin/env bash
# PreToolUse hook — guards a user's INTERACTIVE session against editing the
# repo's PRIMARY checkout instead of a linked git worktree.
#
# This is the reference hook offered (opt-in, default off) by /shipyard:init
# (issue #482). It is NOT registered in the plugin's own hooks.json — it is
# wired into the user's `~/.claude/settings.json` (global) or `.claude/
# settings.json` (repo) by /shipyard:init, so users who don't opt in never run
# it. The plugin ships the script so init can reference it via
# ${CLAUDE_PLUGIN_ROOT}/hooks/guard-primary-checkout.sh.
#
# THE PROBLEM IT SOLVES
# ---------------------
# /shipyard:do-work isolates *background* workers in `.claude/worktrees/agent-*`,
# and the native `worktree.bgIsolation: "worktree"` setting isolates background
# sessions — but nothing protects a user's *interactive* sessions from
# colliding in the primary checkout. Two interactive sessions sharing one
# working tree can switch the branch / dirty the index out from under each
# other (issue #482's real-world repro: a second session switched the shared
# primary checkout to a feature branch mid-task while the first believed it was
# on a clean `main`). This hook forces each editing session into its own
# worktree.
#
# DETECTION (git's own truth, robust — issue #482)
# ------------------------------------------------
# In a linked worktree the per-worktree git dir differs from the common dir; in
# the primary checkout they are equal:
#
#   git_dir = git rev-parse --absolute-git-dir   # /repo/.git  (primary)
#                                                 # /repo/.git/worktrees/<n> (worktree)
#   common  = git rev-parse --git-common-dir      # /repo/.git  (both)
#   git_dir == common  →  PRIMARY checkout  →  guard fires
#   git_dir != common  →  linked worktree   →  allow
#
# Both sides are realpath-normalized before comparison so a `/tmp` vs
# `/private/tmp` (macOS) symlink divergence doesn't produce a false "different".
#
# MODE (read from the SHIPYARD_PRIMARY_GUARD env var; default warn)
# ----------------------------------------------------------------
#   off        → never fires (a no-op; lets the user disable without unwiring)
#   warn       → prints the guidance to stderr but exits 0 (does NOT block)
#   block      → prints the guidance and exits 2 (blocks the Edit/Write/commit)
# /shipyard:init writes the chosen mode into the hook's `env` block in
# settings.json, so the same script serves all three policies.
#
# SCOPE: only Edit / Write / MultiEdit / NotebookEdit, and `git commit` Bash
# invocations — the three mutating surfaces issue #482 names. Every other tool
# (Read, Grep, plain Bash, a non-commit git command) falls through to exit 0.
#
# FAIL-OPEN: not a repo / detection error / malformed input → allow. A guard
# that blocks every edit on a hiccup is far worse than one that occasionally
# misses. See issue #482's "Fail-open on any uncertainty" requirement.
#
# Contract: read PreToolUse JSON from stdin; exit 2 + stderr to block (block
# mode); exit 0 otherwise.

set -u

# Belt-and-braces — any internal error falls through to "allowed".
trap 'exit 0' ERR

mode="${SHIPYARD_PRIMARY_GUARD:-warn}"
[[ "$mode" == "off" ]] && exit 0

input=$(cat 2>/dev/null || true)
[[ -z "$input" ]] && exit 0

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)
[[ -z "$tool_name" ]] && exit 0

# Decide whether this tool call is a mutating surface we care about.
case "$tool_name" in
  Edit | Write | MultiEdit | NotebookEdit)
    : # always in scope
    ;;
  Bash)
    # Only `git commit` invocations are in scope for Bash. Everything else
    # (Read-equivalent gits, plain commands) passes through. Match the command
    # string loosely: a `git commit` token anywhere in the command. This
    # mirrors the issue's `if: "Bash(git commit*)"` gate intent.
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    if ! printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_-])git[[:space:]]+([^|&;]*[[:space:]])?commit([[:space:]]|$)'; then
      exit 0
    fi
    ;;
  *)
    exit 0
    ;;
esac

# Resolve the working directory the tool call runs in.
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -z "$cwd" ]] && cwd="${PWD:-}"
[[ -z "$cwd" ]] && exit 0
[[ -d "$cwd" ]] || exit 0

# Is this a git repo at all? If not, fail-open (allow).
git_dir=$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null || true)
[[ -z "$git_dir" ]] && exit 0
common=$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null || true)
[[ -z "$common" ]] && exit 0

# --git-common-dir can be relative (".git") — resolve it against cwd, then
# realpath-normalize both sides so symlinked-tmp paths compare equal.
case "$common" in
  /*) : ;;
  *) common="$cwd/$common" ;;
esac
git_dir_real=$( (cd "$git_dir" 2>/dev/null && pwd -P) || true )
common_real=$( (cd "$common" 2>/dev/null && pwd -P) || true )
[[ -z "$git_dir_real" || -z "$common_real" ]] && exit 0

# Linked worktree (git_dir != common) → allow. This is the compliant path.
[[ "$git_dir_real" != "$common_real" ]] && exit 0

# --- We are in the PRIMARY checkout. Warn or block per mode. ---

message=$(cat <<'EOF'
shipyard primary-checkout guard: you are editing the repo's PRIMARY checkout,
not an isolated git worktree.

Running multiple interactive Claude sessions in one shared checkout lets them
switch the branch / dirty the index out from under each other. Move this
session into its own worktree first:

  1. Preferred — call the EnterWorktree tool. It switches THIS session's working
     directory into a new worktree under .claude/worktrees/, reloads CLAUDE.md
     for the new location, and handles cleanup on exit.
  2. Fallback — `git worktree add ../<repo>-task <branch>` then cd into it.

This guard was installed opt-in by /shipyard:init. To change or remove it, edit
the SHIPYARD_PRIMARY_GUARD env (off | warn | block) on the hook entry in your
settings.json, or re-run /shipyard:init.
EOF
)

if [[ "$mode" == "block" ]]; then
  printf '%s\n' "$message" >&2
  exit 2
fi

# warn (default): surface the guidance but don't block.
printf '%s\n' "$message" >&2
exit 0
