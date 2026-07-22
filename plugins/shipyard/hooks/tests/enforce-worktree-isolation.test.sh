#!/usr/bin/env bash
# Test suite for hooks/enforce-worktree-isolation.sh.
#
# Run with:
#   bash plugins/shipyard/hooks/tests/enforce-worktree-isolation.test.sh
#
# Each test crafts a PreToolUse JSON payload, pipes it to the hook, and asserts
# on stderr + exit code. Exit 2 == blocked. Exit 0 == allowed (transparent).
#
# The hook decides whether an Agent dispatch targeting a shipyard issue-worker
# shim should be blocked because the caller forgot to pass isolation: "worktree".
# See plugins/shipyard/hooks/enforce-worktree-isolation.sh for the decision rules
# and the full list of guarded subagent names.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="${here}/../enforce-worktree-isolation.sh"

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

# Payload helpers. Use Python json.dumps to get correct escaping regardless of
# the values in the test (matches the enforce-edit-scope test convention).
mkpayload_isolated() {
  # Args: subagent_type
  local subagent="$1"
  python3 -c "
import json
print(json.dumps({
    'tool_name': 'Agent',
    'tool_input': {
        'subagent_type': '$subagent',
        'isolation': 'worktree',
        'prompt': 'x',
    },
}))"
}

mkpayload_no_isolation() {
  # Args: subagent_type
  local subagent="$1"
  python3 -c "
import json
print(json.dumps({
    'tool_name': 'Agent',
    'tool_input': {
        'subagent_type': '$subagent',
        'prompt': 'x',
    },
}))"
}

mkpayload_wrong_isolation() {
  # Args: subagent_type, isolation_value
  local subagent="$1"
  local iso="$2"
  python3 -c "
import json
print(json.dumps({
    'tool_name': 'Agent',
    'tool_input': {
        'subagent_type': '$subagent',
        'isolation': '$iso',
        'prompt': 'x',
    },
}))"
}

# -----------------------------------------------------------------------------
echo "== Guarded shims dispatched WITHOUT isolation: \"worktree\" are blocked"
# -----------------------------------------------------------------------------
# This is the main bug from #293 — the four model-pinned shims used to pass
# through silently because the hook only matched "shipyard:issue-worker" exactly.

for shim in \
  shipyard:issue-worker \
  shipyard:fix-checks-worker \
  shipyard:fix-rebase-worker \
  shipyard:fix-main-ci-worker \
  shipyard:fix-pr-batch-worker \
  shipyard:spike-worker \
  shipyard:verify-worker
do
  out=$(run_hook "$(mkpayload_no_isolation "$shim")")
  assert_blocked_with "$out" "BLOCKED" "$shim without isolation → blocked"
  # The error message should name the actual subagent so the orchestrator
  # knows which dispatch to fix.
  out=$(run_hook "$(mkpayload_no_isolation "$shim")")
  assert_blocked_with "$out" "$shim" "$shim block message names the subagent"
done

# -----------------------------------------------------------------------------
echo "== Guarded shims dispatched WITH isolation: \"worktree\" pass through"
# -----------------------------------------------------------------------------

for shim in \
  shipyard:issue-worker \
  shipyard:fix-checks-worker \
  shipyard:fix-rebase-worker \
  shipyard:fix-main-ci-worker \
  shipyard:fix-pr-batch-worker \
  shipyard:spike-worker \
  shipyard:verify-worker
do
  out=$(run_hook "$(mkpayload_isolated "$shim")")
  assert_exit "$out" "0" "$shim with isolation=worktree → allowed"
done

# -----------------------------------------------------------------------------
echo "== Wrong isolation value still blocks"
# -----------------------------------------------------------------------------
# Defense in depth — only the literal string "worktree" satisfies the hook.

out=$(run_hook "$(mkpayload_wrong_isolation shipyard:issue-worker "none")")
assert_blocked_with "$out" "BLOCKED" "issue-worker with isolation=none → blocked"

out=$(run_hook "$(mkpayload_wrong_isolation shipyard:fix-checks-worker "process")")
assert_blocked_with "$out" "BLOCKED" "fix-checks-worker with isolation=process → blocked"

# -----------------------------------------------------------------------------
echo "== Colon-namespaced shipyard:issue-worker:* form is also guarded"
# -----------------------------------------------------------------------------
# Defense-in-depth: if a future shim ever uses the colon-suffix scheme
# described in #293's body (e.g. shipyard:issue-worker:fix-checks-only),
# the hook should also catch it.

out=$(run_hook "$(mkpayload_no_isolation shipyard:issue-worker:fix-checks-only)")
assert_blocked_with "$out" "BLOCKED" \
  "shipyard:issue-worker:fix-checks-only without isolation → blocked"

out=$(run_hook "$(mkpayload_no_isolation shipyard:issue-worker:something-future)")
assert_blocked_with "$out" "BLOCKED" \
  "shipyard:issue-worker:<arbitrary> without isolation → blocked"

out=$(run_hook "$(mkpayload_isolated shipyard:issue-worker:fix-checks-only)")
assert_exit "$out" "0" \
  "shipyard:issue-worker:fix-checks-only with isolation → allowed"

# -----------------------------------------------------------------------------
echo "== Unrelated subagent types pass through"
# -----------------------------------------------------------------------------
# The hook only governs shipyard issue-worker shims; auditors and refinement
# workers don't need isolation and shouldn't be touched here.

for other in \
  general-purpose \
  shipyard:dx-auditor \
  shipyard:a11y-auditor \
  shipyard:security-auditor \
  shipyard:decompose-worker \
  some-third-party-agent
do
  out=$(run_hook "$(mkpayload_no_isolation "$other")")
  assert_exit "$out" "0" "$other without isolation → allowed (not guarded)"
done

# Lookalikes that happen to contain "shipyard" but aren't a guarded shim.
out=$(run_hook "$(mkpayload_no_isolation "shipyard:other-thing")")
assert_exit "$out" "0" "shipyard:other-thing → allowed (not in guarded set)"

out=$(run_hook "$(mkpayload_no_isolation "shipyard:issue-worker-fake")")
assert_exit "$out" "0" \
  "shipyard:issue-worker-fake → allowed (not exact match and not colon-suffix)"

# -----------------------------------------------------------------------------
echo "== Non-Agent tools pass through"
# -----------------------------------------------------------------------------

for tool in Bash Read Write Edit Grep Glob WebFetch; do
  payload=$(python3 -c "
import json
print(json.dumps({
    'tool_name': '$tool',
    'tool_input': {'subagent_type': 'shipyard:issue-worker'},
}))")
  out=$(run_hook "$payload")
  assert_exit "$out" "0" "$tool tool → not blocked"
done

# -----------------------------------------------------------------------------
echo "== Malformed payloads exit 0 (don't break the session)"
# -----------------------------------------------------------------------------
# Belt and braces. A hook crash would block every Agent dispatch.

out=$(run_hook "not-json-at-all")
assert_exit "$out" "0" "malformed JSON → allowed (no false block)"

out=$(run_hook "{}")
assert_exit "$out" "0" "empty object → allowed"

out=$(run_hook '{"tool_name":"Agent"}')
assert_exit "$out" "0" "missing tool_input → allowed"

out=$(run_hook '{"tool_name":"Agent","tool_input":{}}')
assert_exit "$out" "0" "missing subagent_type → allowed"

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
