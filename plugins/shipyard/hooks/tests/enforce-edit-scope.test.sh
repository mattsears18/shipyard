#!/usr/bin/env bash
# Test suite for hooks/enforce-edit-scope.sh.
#
# Run with:
#   bash plugins/shipyard/hooks/tests/enforce-edit-scope.test.sh
#
# Each test crafts a PreToolUse JSON payload, pipes it to the hook, and asserts
# on stderr + exit code. Exit 2 == blocked. Exit 0 == allowed (transparent).
#
# The hook decides whether an Edit/Write/MultiEdit/NotebookEdit call should be
# blocked because the agent (running inside `.claude/worktrees/agent-<id>/`)
# is trying to edit a file outside its worktree — typically inside the user's
# primary checkout. See plugins/shipyard/hooks/enforce-edit-scope.sh for the
# decision rules.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="${here}/../enforce-edit-scope.sh"

if [[ ! -f "$hook" ]]; then
  echo "FAIL: hook not found at $hook" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

# Build an isolated workspace tree that mirrors the real layout:
#
#   $TMP/primary/                  ← user's primary checkout
#   $TMP/primary/.claude/worktrees/agent-deadbeef/   ← agent's worktree
#
# Hook is invoked with cwd = the worktree path (matching how the harness runs
# the agent), and file_path points to either an in-worktree file or an out-of-
# worktree file (in the primary checkout).
TMP=$(mktemp -d -t shipyard-edit-scope-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

PRIMARY="$TMP/primary"
WT="$PRIMARY/.claude/worktrees/agent-deadbeef"
OTHER_WT="$PRIMARY/.claude/worktrees/agent-cafef00d"
SIBLING_CHECKOUT="$TMP/other-repo"

mkdir -p "$WT/sub" "$OTHER_WT/sub" "$PRIMARY/src" "$SIBLING_CHECKOUT/src"
: >"$WT/file.txt"
: >"$WT/sub/deep.txt"
: >"$PRIMARY/CLAUDE.md"
: >"$PRIMARY/src/code.ts"
: >"$OTHER_WT/file.txt"
: >"$SIBLING_CHECKOUT/src/code.ts"

# Helper — invoke hook with payload on stdin and a manual cwd field.
# Returns: "<exit_code>::<stderr>"
run_hook() {
  local payload="$1"
  local stderr exit_code
  stderr=$(printf '%s' "$payload" | bash "$hook" 2>&1 >/dev/null)
  exit_code=$?
  printf '%s::%s' "$exit_code" "$stderr"
}

assert_exit() {
  local result="$1"
  local want="$2"
  local label="$3"
  local got="${result%%::*}"
  if [[ "$got" == "$want" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (want exit %s, got %s)\n' "$RED" "$RESET" "$label" "$want" "$got"
    printf '    stderr: %s\n' "${result#*::}"
    fail=$((fail+1))
  fi
}

assert_blocked_with() {
  local result="$1"
  local needle="$2"
  local label="$3"
  local got="${result%%::*}"
  local stderr="${result#*::}"
  if [[ "$got" == "2" && "$stderr" == *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    want exit 2 and stderr containing %q\n' "$needle"
    printf '    got exit %s, stderr: %s\n' "$got" "$stderr"
    fail=$((fail+1))
  fi
}

mkpayload() {
  # Args: tool_name, file_path, cwd
  local tool="$1" fp="$2" cwd="$3"
  python3 -c "
import json
print(json.dumps({
    'tool_name': '$tool',
    'cwd': '$cwd',
    'tool_input': {'file_path': '$fp'},
}))"
}

# -----------------------------------------------------------------------------
echo "== Non-edit tools pass through"
# -----------------------------------------------------------------------------

# Bash with a file argument — hook should not block (only the Edit/Write tools).
out=$(run_hook "$(mkpayload Bash "$PRIMARY/CLAUDE.md" "$WT")")
assert_exit "$out" "0" "Bash tool → not blocked"

out=$(run_hook "$(mkpayload Read "$PRIMARY/CLAUDE.md" "$WT")")
assert_exit "$out" "0" "Read tool → not blocked"

out=$(run_hook "$(mkpayload Grep "$PRIMARY/CLAUDE.md" "$WT")")
assert_exit "$out" "0" "Grep tool → not blocked"

# -----------------------------------------------------------------------------
echo "== Edits inside the agent's worktree pass"
# -----------------------------------------------------------------------------

for tool in Edit Write MultiEdit NotebookEdit; do
  out=$(run_hook "$(mkpayload "$tool" "$WT/file.txt" "$WT")")
  assert_exit "$out" "0" "$tool inside worktree (root file) → allowed"

  out=$(run_hook "$(mkpayload "$tool" "$WT/sub/deep.txt" "$WT")")
  assert_exit "$out" "0" "$tool inside worktree (nested file) → allowed"
done

# -----------------------------------------------------------------------------
echo "== Edits in the primary checkout are blocked"
# -----------------------------------------------------------------------------

for tool in Edit Write MultiEdit NotebookEdit; do
  out=$(run_hook "$(mkpayload "$tool" "$PRIMARY/CLAUDE.md" "$WT")")
  assert_blocked_with "$out" "OUTSIDE your isolated worktree" \
    "$tool on primary checkout → blocked"

  out=$(run_hook "$(mkpayload "$tool" "$PRIMARY/src/code.ts" "$WT")")
  assert_blocked_with "$out" "OUTSIDE your isolated worktree" \
    "$tool on nested primary file → blocked"
done

# -----------------------------------------------------------------------------
echo "== Edits in a sibling worktree are blocked"
# -----------------------------------------------------------------------------
# Another agent's worktree under the same primary checkout. Still off-limits.

out=$(run_hook "$(mkpayload Edit "$OTHER_WT/file.txt" "$WT")")
assert_blocked_with "$out" "OUTSIDE your isolated worktree" \
  "Edit on a sibling agent worktree → blocked"

# -----------------------------------------------------------------------------
echo "== Edits in an unrelated checkout outside the primary are blocked"
# -----------------------------------------------------------------------------
# Defense in depth: if the agent decides to edit a totally different repo it
# happens to know about, also block.

out=$(run_hook "$(mkpayload Edit "$SIBLING_CHECKOUT/src/code.ts" "$WT")")
assert_blocked_with "$out" "OUTSIDE your isolated worktree" \
  "Edit on a different repo checkout → blocked"

# -----------------------------------------------------------------------------
echo "== Hook is a no-op when not running inside a worktree"
# -----------------------------------------------------------------------------
# If the agent's cwd isn't `.claude/worktrees/agent-<id>/<...>` we have no
# basis for restricting edits — could be the user's interactive session, a
# top-level command from /do-work running in the orchestrator's own worktree,
# etc. Fall through transparently.

out=$(run_hook "$(mkpayload Edit "$PRIMARY/CLAUDE.md" "$PRIMARY")")
assert_exit "$out" "0" "cwd is primary checkout (no agent worktree) → allowed"

# Orchestrator's own worktree — different naming convention.
ORCH="$PRIMARY/.claude/worktrees/orchestrator-20260520-061027"
mkdir -p "$ORCH"
out=$(run_hook "$(mkpayload Edit "$PRIMARY/CLAUDE.md" "$ORCH")")
assert_exit "$out" "0" "cwd is orchestrator worktree → allowed (orchestrator may edit anywhere)"

# -----------------------------------------------------------------------------
echo "== Relative file_path is resolved against cwd"
# -----------------------------------------------------------------------------
# Models occasionally send relative paths. The hook should resolve them.

out=$(run_hook "$(mkpayload Edit "file.txt" "$WT")")
assert_exit "$out" "0" "relative file.txt in worktree → allowed"

# Pointing back into the primary via ../../../ ... etc.
out=$(run_hook "$(mkpayload Edit "../../../CLAUDE.md" "$WT")")
assert_blocked_with "$out" "OUTSIDE your isolated worktree" \
  "relative path escaping worktree → blocked"

# -----------------------------------------------------------------------------
echo "== Malformed payloads exit 0 (don't break the session)"
# -----------------------------------------------------------------------------
# Belt and braces. A hook crash would block every tool call.

out=$(run_hook "not-json-at-all")
assert_exit "$out" "0" "malformed JSON → allowed (no false block)"

out=$(run_hook "{}")
assert_exit "$out" "0" "empty object → allowed"

out=$(run_hook '{"tool_name":"Edit"}')
assert_exit "$out" "0" "missing tool_input → allowed"

out=$(run_hook '{"tool_name":"Edit","tool_input":{}}')
assert_exit "$out" "0" "missing file_path → allowed"

# -----------------------------------------------------------------------------
echo "== Summary"
# -----------------------------------------------------------------------------

total=$((pass+fail))
if (( fail == 0 )); then
  printf '%s%d/%d tests pass.%s\n' "$GREEN" "$pass" "$total" "$RESET"
  exit 0
else
  printf '%s%d/%d tests pass — %d failures.%s\n' "$RED" "$pass" "$total" "$fail" "$RESET"
  exit 1
fi
