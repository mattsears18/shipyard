#!/usr/bin/env bash
# SessionEnd hook — backstop worktree reap (#638).
#
# Thin shim: the logic lives in scripts/session-end-reap.sh so it can be
# unit-tested independently of Claude Code's hook runtime (same split as
# report-plugin-error.sh).
#
# Runs the helper SYNCHRONOUSLY but bounded (SessionEnd is the last thing that
# fires — a backgrounded+disowned child could be killed as the session tears
# down, so we run it inline and cap it so it can't hang exit). The orphan-ref
# reap is sub-second in practice; the cap is a safety rail.
#
# Failure handling: this hook MUST NOT propagate a non-zero exit code — a
# cleanup failure breaking the user's session exit would be worse than the
# stale worktree it failed to reap.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../scripts/session-end-reap.sh"

# Always consume stdin so upstream never gets SIGPIPE.
payload="$(cat 2>/dev/null || true)"

if [[ ! -f "$helper" ]]; then
  exit 0
fi

# The helper resolves worktree-reap.sh under CLAUDE_PLUGIN_ROOT; in the hook
# runtime that's already set, but fall back to this script's plugin root.
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "${here}/.." && pwd)}"

if command -v timeout >/dev/null 2>&1; then
  printf '%s' "$payload" | timeout 30 bash "$helper" >/dev/null 2>&1 || true
else
  printf '%s' "$payload" | bash "$helper" >/dev/null 2>&1 || true
fi

exit 0
