#!/usr/bin/env bash
# Test suite for hooks/refuse-broad-process-kill.sh.
#
# Run with:
#   bash plugins/shipyard/hooks/tests/refuse-broad-process-kill.test.sh
#
# Each test crafts a PreToolUse JSON payload for a Bash tool call, pipes it to
# the hook, and asserts on stderr + exit code. Exit 2 == blocked, exit 0 ==
# allowed (transparent).
#
# The hook blocks pattern-based process kills (pkill, killall, kill fed PIDs
# looked up via pgrep/ps|grep) because a repo's CI may run on self-hosted
# runners on the SAME host the worker is operating on — a pattern kill cannot
# distinguish the worker's own leftover processes from in-flight CI processes.
# See plugins/shipyard/hooks/refuse-broad-process-kill.sh for the decision
# rules and issue #751 for the original repro.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="${here}/../refuse-broad-process-kill.sh"

if [[ ! -f "$hook" ]]; then
  echo "FAIL: hook not found at $hook" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

# Helper — invoke hook with payload on stdin.
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
  local tool="$1" cmd="$2"
  TOOL="$tool" CMD="$cmd" python3 -c '
import json, os
print(json.dumps({
    "tool_name": os.environ["TOOL"],
    "cwd": "/tmp",
    "tool_input": {"command": os.environ["CMD"]},
}))'
}

# -----------------------------------------------------------------------------
echo "== Non-Bash tools pass through transparently"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Edit 'pkill -9 -f playwright')")
assert_exit "$out" "0" "Edit tool with 'pkill' string → not blocked"

out=$(run_hook "$(mkpayload Read 'pkill -9 -f playwright')")
assert_exit "$out" "0" "Read tool → not blocked"

# -----------------------------------------------------------------------------
echo "== pkill is blocked unconditionally"
# -----------------------------------------------------------------------------
# The #751 repro, verbatim.

out=$(run_hook "$(mkpayload Bash 'pkill -9 -f "playwright test"')")
assert_blocked_with "$out" "pkill" "pkill -9 -f 'playwright test' → blocked (the #751 repro)"

out=$(run_hook "$(mkpayload Bash 'pkill node')")
assert_blocked_with "$out" "pkill" "bare pkill node → blocked"

out=$(run_hook "$(mkpayload Bash 'cd /tmp && pkill -f metro')")
assert_blocked_with "$out" "pkill" "chained cd && pkill → blocked"

# -----------------------------------------------------------------------------
echo "== killall is blocked unconditionally"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'killall node')")
assert_blocked_with "$out" "killall" "killall node → blocked"

out=$(run_hook "$(mkpayload Bash 'killall -9 Simulator')")
assert_blocked_with "$out" "killall" "killall -9 Simulator → blocked"

# -----------------------------------------------------------------------------
echo "== kill combined with a pattern lookup is blocked"
# -----------------------------------------------------------------------------
# The pkill-shaped hazard reconstructed via kill + pgrep/ps|grep, without
# calling the pkill binary itself.

# shellcheck disable=SC2016  # literal $(pgrep ...) — a payload fixture, not an expansion
out=$(run_hook "$(mkpayload Bash 'kill -9 $(pgrep -f "playwright test")')")
assert_blocked_with "$out" "kill" "kill \$(pgrep -f ...) → blocked"

out=$(run_hook "$(mkpayload Bash "kill \$(ps aux | grep playwright | awk '{print \$2}')")")
assert_blocked_with "$out" "kill" "kill \$(ps aux | grep ...) → blocked"

# shellcheck disable=SC2016  # literal $(pgrep ...) — a payload fixture, not an expansion
out=$(run_hook "$(mkpayload Bash 'for pid in $(pgrep node); do kill -9 $pid; done')")
assert_blocked_with "$out" "kill" "loop over pgrep output feeding kill → blocked"

# -----------------------------------------------------------------------------
echo "== kill against a literal PID is allowed"
# -----------------------------------------------------------------------------
# This is the SAFE form the hook's own error message tells workers to use:
# track a PID you spawned yourself, kill only that PID.

out=$(run_hook "$(mkpayload Bash 'kill 12345')")
assert_exit "$out" "0" "kill <literal pid> → allowed"

out=$(run_hook "$(mkpayload Bash 'kill -9 12345')")
assert_exit "$out" "0" "kill -9 <literal pid> → allowed"

# shellcheck disable=SC2016  # literal $BGPID — a payload fixture, not an expansion
out=$(run_hook "$(mkpayload Bash 'kill -TERM $BGPID')")
assert_exit "$out" "0" "kill -TERM \$BGPID (a variable holding a tracked PID) → allowed"

# shellcheck disable=SC2016  # literal $! / $MY_PID — a payload fixture, not an expansion
out=$(run_hook "$(mkpayload Bash 'MY_PID=$!; sleep 5 & kill $MY_PID')")
assert_exit "$out" "0" "kill against \$! captured from a backgrounded command → allowed"

# -----------------------------------------------------------------------------
echo "== unrelated commands pass through"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'git status')")
assert_exit "$out" "0" "git status → allowed"

out=$(run_hook "$(mkpayload Bash 'ps aux | grep node')")
assert_exit "$out" "0" "ps | grep with no kill → allowed"

out=$(run_hook "$(mkpayload Bash 'pgrep -f playwright')")
assert_exit "$out" "0" "pgrep with no kill → allowed (inspection only, no termination)"

out=$(run_hook "$(mkpayload Bash 'npm test')")
assert_exit "$out" "0" "npm test → allowed"

# Substring / boundary false-positive checks.
out=$(run_hook "$(mkpayload Bash './scripts/pkill-helper.sh --dry-run')")
assert_blocked_with "$out" "pkill" "path containing pkill as a whole word → blocked (accepted conservative default)"

out=$(run_hook "$(mkpayload Bash 'echo "the process was killed gracefully"')")
assert_exit "$out" "0" "'killed' as a substring of another word → not blocked (token boundary)"

out=$(run_hook "$(mkpayload Bash "grep -r 'pkill' docs/")")
assert_exit "$out" "0" "grep containing 'pkill' as a quoted needle → not blocked"

# -----------------------------------------------------------------------------
echo "== Malformed payloads exit 0 (defensive default)"
# -----------------------------------------------------------------------------

out=$(run_hook "not-json-at-all")
assert_exit "$out" "0" "malformed JSON → allowed"

out=$(run_hook "{}")
assert_exit "$out" "0" "empty object → allowed"

out=$(run_hook '{"tool_name":"Bash"}')
assert_exit "$out" "0" "missing tool_input → allowed"

out=$(run_hook '{"tool_name":"Bash","tool_input":{}}')
assert_exit "$out" "0" "missing command → allowed"

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
