#!/usr/bin/env bash
# PreToolUse hook — guards ANY session (interactive or orchestrated) against
# editing the repo's PRIMARY checkout instead of a linked git worktree.
#
# Wired into the plugin's own hooks.json (issue #741) under both the
# `Edit|Write|MultiEdit|NotebookEdit` matcher and the `Bash` matcher, so it
# runs unconditionally for every PreToolUse call once the plugin is
# installed — no opt-in required. Prior to #741 this script existed but was
# never registered anywhere in hooks.json, making it dead code; the #482
# real-world repro (a second interactive session switching the shared
# primary checkout's branch mid-task) and the #741 repro (a dispatched
# worker running `git checkout -B` against the primary) both went
# unenforced as a result.
#
# /shipyard:init ALSO offers this same script as an *additional*, separately
# configurable opt-in wiring into the user's `~/.claude/settings.json`
# (global) or `.claude/settings.json` (repo) — a user who has run
# /shipyard:init may end up with the hook registered twice (plugin-level +
# user-level). That's harmless: both copies run the same idempotent
# detection and their exit codes compose (either one blocking is enough),
# and the user-level copy lets a user pin a stricter SHIPYARD_PRIMARY_GUARD
# mode at their own settings layer without editing the plugin.
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
#   block      → prints the guidance and exits 2 (blocks the mutating call)
# /shipyard:init writes the chosen mode into the hook's `env` block in
# settings.json, so the same script serves all three policies.
#
# SCOPE: Edit / Write / MultiEdit / NotebookEdit, and the full write-class git
# surface for Bash — commit, checkout, switch, reset, branch -d/-D/-f
# (deletion only; a bare `git branch <name>` just creates a ref and stays
# out of scope), merge, rebase, cherry-pick, stash, clean (issue #741). Every
# one of these can move the primary's HEAD or dirty its index out from under
# a concurrent session — `git commit` alone (the original, pre-#741 scope)
# was arguably the *least* dangerous of the set, since it never relocates
# HEAD. Read-class git (status, log, show, diff, ls-remote, rev-parse,
# worktree list, fetch) always falls through to exit 0 — the orchestrator and
# workers legitimately run these against the primary checkout and the
# worktree-isolation spec explicitly permits it. Any other tool (Read, Grep,
# a non-write-class Bash command) also falls through to exit 0.
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
    # The full write-class git surface is in scope for Bash — not just `git
    # commit` (issue #741). Match the command string loosely: a write-verb
    # token anywhere in the command, mirroring the issue's `if: "Bash(git
    # commit*)"` gate intent but widened to the full write-class set. Everything
    # else (read-class gits, plain commands) passes through unchanged.
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    write_verbs='commit|checkout|switch|reset|merge|rebase|cherry-pick|stash|clean'
    in_scope=0
    if printf '%s' "$cmd" | grep -Eq "(^|[^[:alnum:]_-])git[[:space:]]+([^|&;]*[[:space:]])?(${write_verbs})([[:space:]]|\$)"; then
      in_scope=1
    elif printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_-])git[[:space:]]+([^|&;]*[[:space:]])?branch([[:space:]]|$)' \
      && printf '%s' "$cmd" | grep -Eq '(^|[[:space:]])-([dDf]+|-delete|-force)([[:space:]=]|$)'; then
      # `git branch` is only in scope with a deletion flag (-d/-D/-f, or the
      # long forms) — a bare `git branch <name>` just creates a ref pointer
      # and doesn't move HEAD, so it stays out of scope.
      in_scope=1
    fi
    [[ "$in_scope" == "0" ]] && exit 0
    ;;
  *)
    exit 0
    ;;
esac

# Resolve the working directory the tool call runs in.
# Fail-open (exit 0) when cwd is absent from the hook payload — we can't
# determine whether we're in the primary checkout, so allow per the
# fail-open contract (issue #482: "fail-open on any uncertainty").
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
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

This guard now runs by default (wired into the shipyard plugin hooks.json). To
change its mode, set the SHIPYARD_PRIMARY_GUARD env (off | warn | block) — via
/shipyard:init for a per-repo or global settings.json override, or directly in
your shell environment.
EOF
)

if [[ "$mode" == "block" ]]; then
  printf '%s\n' "$message" >&2
  exit 2
fi

# warn (default): surface the guidance but don't block.
printf '%s\n' "$message" >&2
exit 0
