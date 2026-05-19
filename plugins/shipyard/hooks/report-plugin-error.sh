#!/usr/bin/env bash
# PostToolUse / SubagentStop hook — forwards the hook payload to the
# report-plugin-error.sh helper script, which decides whether to file an
# auto-report against mattsears18/claude-plugins.
#
# Kept as a one-line shim on purpose. All logic lives in
# scripts/report-plugin-error.sh so it can be unit-tested independently of
# Claude Code's hook runtime.
#
# Behavior:
#   • Reads the hook JSON payload from stdin.
#   • If CLAUDE_PLUGINS_AUTOREPORT != 1, the helper exits 0 with no action,
#     so we don't even need to gate here — but we do, to avoid the spawn cost.
#   • Otherwise the helper runs in the background so the hook returns
#     immediately (auto-reports are best-effort, never blocking).
#
# Failure handling: this hook MUST NOT propagate a non-zero exit code. Auto-
# reporting is a best-effort feature; breaking the user's session because we
# couldn't file a bug would be worse than the bug itself.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../scripts/report-plugin-error.sh"

# Fast opt-out — skip the spawn entirely when not enabled.
if [[ "${CLAUDE_PLUGINS_AUTOREPORT:-}" != "1" ]]; then
  # Still consume stdin so upstream doesn't get SIGPIPE.
  cat >/dev/null 2>&1 || true
  exit 0
fi

if [[ ! -x "$helper" && ! -f "$helper" ]]; then
  cat >/dev/null 2>&1 || true
  exit 0
fi

# Buffer stdin to a temp file, then run the helper in the background reading
# from that buffer. This decouples helper lifetime from the hook's stdin,
# letting the hook return immediately while the report-or-file pipeline
# completes asynchronously.
buffer=$(mktemp -t shipyard-autoreport.XXXXXX 2>/dev/null) || { cat >/dev/null; exit 0; }
cat >"$buffer" 2>/dev/null || true

(
  bash "$helper" <"$buffer" >/dev/null 2>&1
  rm -f "$buffer"
) &
disown 2>/dev/null || true

exit 0
