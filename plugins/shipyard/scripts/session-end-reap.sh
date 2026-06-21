#!/usr/bin/env bash
# SessionEnd backstop reap (#638).
#
# Every other reap in shipyard runs as best-effort bash *inside the
# orchestrator's own turn* — if the session crashes / is interrupted / the
# turn ends before end-of-session cleanup, stale state orphans (the recurring
# failure behind #637, patched piecemeal by #280/#509/#529/#326). This helper
# is the trigger that runs INDEPENDENT of the orchestrator's turn: a SessionEnd
# hook (hooks/reap-on-session-end.sh) invokes it on every session exit.
#
# v1 scope — the single clearest unbounded leak, and the only reap that is
# provably safe with no session-liveness reasoning: stale `worktree-agent-*`
# branch refs (#326 — refs whose worktree dir was already reaped but whose ref
# was left behind; "119 observed" in the wild). Deleting them touches no live
# work — `worktree-reap.sh reap-orphan-branches` only deletes refs that have NO
# live worktree referencing them. Followed by `git worktree prune` (removes
# only already-gone worktree admin entries). Reaping this-session worktrees and
# dead-session orchestrator dirs stays with the orchestrator's in-loop reaps +
# the next-session startup sweep (#280/#509); extending this hook to those is a
# documented follow-up under #638.
#
# Contract: best-effort, bounded, NEVER errors — a cleanup failure must not
# break session exit. Reads the SessionEnd hook JSON from stdin (for `cwd` +
# `session_id`). Test overrides: SESSION_END_REAP_CWD,
# SESSION_END_REAP_PLUGIN_ROOT, SESSION_END_REAP_TIMEOUT.
set -u

budget="${SESSION_END_REAP_TIMEOUT:-25}"
payload="$(cat 2>/dev/null || true)"

# Minimal stdin-JSON field extractor (avoids a hard jq dependency in the
# session-exit path). Returns the first string value for the given key.
extract() {
  printf '%s' "$payload" |
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" |
    head -1
}

cwd="${SESSION_END_REAP_CWD:-}"
[ -z "$cwd" ] && cwd="$(extract cwd)"
[ -z "$cwd" ] && cwd="$PWD"

repo_root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$repo_root" ] && exit 0 # not a git repo — nothing to reap

plugin_root="${SESSION_END_REAP_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"
reap="${plugin_root%/}/scripts/worktree-reap.sh"
[ -f "$reap" ] || exit 0

# session_id is used only for the reap-audit ledger line, not for deciding
# which refs to delete — so any stable label is fine.
session_id="$(extract session_id)"
[ -z "$session_id" ] && session_id="session-end"

run() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$budget" "$@"
  else
    "$@"
  fi
}

run bash "$reap" reap-orphan-branches \
  --repo-root "$repo_root" \
  --session-id "$session_id" >/dev/null 2>&1 || true

git -C "$repo_root" worktree prune >/dev/null 2>&1 || true

exit 0
