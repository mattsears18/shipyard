#!/usr/bin/env bash
# Test suite for scripts/setup-timing.sh.
#
# Covers the five subcommands the orchestrator uses to instrument
# setup-phase wall-clock timing (issue #238):
#
#   start                  — record phase start timestamp in sidecar
#   end                    — record phase end + compute duration
#   record-scope-preflight — store scope_preflight sub-block
#   flush                  — merge sidecar into session-state `setup` block
#   read                   — emit current timing state
#
# Pure bash + jq. Run with:
#
#   bash plugins/shipyard/scripts/tests/setup-timing.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../setup-timing.sh"
session_helper="${here}/../session-state.sh"

if [[ ! -f "$helper" ]]; then
  echo "FAIL: setup-timing.sh not found at $helper" >&2
  exit 1
fi
if [[ ! -f "$session_helper" ]]; then
  echo "FAIL: session-state.sh not found at $session_helper" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to contain: %s\n' "$needle"
    printf '    actual: %s\n' "$haystack" | head -c 400
    printf '\n'
    fail=$((fail+1))
  fi
}

assert_equals() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected: %s\n' "$expected"
    printf '    actual:   %s\n' "$actual"
    fail=$((fail+1))
  fi
}

assert_exit() {
  local actual_exit="$1"
  local expected_exit="$2"
  local label="$3"
  if [[ "$actual_exit" -eq "$expected_exit" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected exit: %s\n' "$expected_exit"
    printf '    actual exit:   %s\n' "$actual_exit"
    fail=$((fail+1))
  fi
}

assert_file_exists() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    file not found: %s\n' "$path"
    fail=$((fail+1))
  fi
}

assert_file_missing() {
  local path="$1"
  local label="$2"
  if [[ ! -e "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    file still present: %s\n' "$path"
    fail=$((fail+1))
  fi
}

mktmphome() {
  mktemp -d
}

# Helper: init a session state file so flush tests can target it.
init_session() {
  local home="$1"
  local session_id="$2"
  SHIPYARD_HOME="$home" "$session_helper" init \
    --session-id "$session_id" --repo "test/repo" >/dev/null
}

# --------------------------------------------------------------------------
echo "== start"
# --------------------------------------------------------------------------

home=$(mktmphome)
sid="test-start-$$"

out=$(SHIPYARD_HOME="$home" "$helper" start --session-id "$sid" --phase step_0_5_worktree 2>&1)
assert_exit "$?" "0" "start: exit 0 on success"

sidecar="${home}/sessions/${sid}.timing.json"
assert_file_exists "$sidecar" "start: creates sidecar file"

content=$(cat "$sidecar")
assert_contains "$content" '"step_0_5_worktree"' "start: phase key present in sidecar"
assert_contains "$content" '"started_at"' "start: started_at field present"
assert_contains "$content" '"setup_started_at"' "start: setup_started_at set on first start"

# Second phase should not overwrite setup_started_at.
SHIPYARD_HOME="$home" "$helper" start --session-id "$sid" --phase step_1_7_trusted_authors >/dev/null 2>&1
content2=$(cat "$sidecar")
first_started=$(printf '%s' "$content" | jq -r '.setup_started_at')
second_started=$(printf '%s' "$content2" | jq -r '.setup_started_at')
assert_equals "$first_started" "$second_started" "start: setup_started_at not overwritten by second start"
assert_contains "$content2" '"step_1_7_trusted_authors"' "start: second phase key added"

rm -rf "$home"

# --------------------------------------------------------------------------
echo "== start — usage errors"
# --------------------------------------------------------------------------

home=$(mktmphome)
sid="test-start-err-$$"

SHIPYARD_HOME="$home" "$helper" start --session-id "$sid" 2>/dev/null
assert_exit "$?" "64" "start: exit 64 when --phase missing"

SHIPYARD_HOME="$home" "$helper" start --phase step_0_5_worktree 2>/dev/null
assert_exit "$?" "64" "start: exit 64 when --session-id missing"

SHIPYARD_HOME="$home" "$helper" start --session-id "$sid" --phase "bad phase" 2>/dev/null
assert_exit "$?" "64" "start: exit 64 when phase name contains spaces"

rm -rf "$home"

# --------------------------------------------------------------------------
echo "== end"
# --------------------------------------------------------------------------

home=$(mktmphome)
sid="test-end-$$"

# Start then immediately end — duration should be >= 0 and < 5s.
SHIPYARD_HOME="$home" "$helper" start --session-id "$sid" --phase step_0_5_worktree >/dev/null 2>&1
SHIPYARD_HOME="$home" "$helper" end   --session-id "$sid" --phase step_0_5_worktree >/dev/null 2>&1
assert_exit "$?" "0" "end: exit 0 on success"

sidecar="${home}/sessions/${sid}.timing.json"
content=$(cat "$sidecar")
assert_contains "$content" '"ended_at"' "end: ended_at field present"
assert_contains "$content" '"duration_seconds"' "end: duration_seconds field present"

duration=$(printf '%s' "$content" | jq '.phases.step_0_5_worktree.duration_seconds')
# Duration should be a non-negative number.
ok=$(printf '%s' "$duration" | jq '. >= 0')
assert_equals "$ok" "true" "end: duration_seconds >= 0"

# setup_ended_at should be set.
assert_contains "$content" '"setup_ended_at"' "end: setup_ended_at set"

rm -rf "$home"

# --------------------------------------------------------------------------
echo "== end — warning when no start"
# --------------------------------------------------------------------------

home=$(mktmphome)
sid="test-end-nostart-$$"

# end without start should exit 0 but emit a warning on stderr.
stderr_out=$(SHIPYARD_HOME="$home" "$helper" end --session-id "$sid" --phase orphan_phase 2>&1 >/dev/null)
assert_exit "$?" "0" "end: exit 0 even with no matching start"
assert_contains "$stderr_out" "warning" "end: warning emitted on stderr when no start found"

# duration should be 0 when no start.
sidecar="${home}/sessions/${sid}.timing.json"
dur=$(jq '.phases.orphan_phase.duration_seconds' "$sidecar")
assert_equals "$dur" "0" "end: duration_seconds is 0 when no start"

rm -rf "$home"

# --------------------------------------------------------------------------
echo "== record-scope-preflight"
# --------------------------------------------------------------------------

home=$(mktmphome)
sid="test-scopepf-$$"

SHIPYARD_HOME="$home" "$helper" record-scope-preflight \
  --session-id "$sid" \
  --candidates-scoped 4 \
  --ready-count 3 \
  --deferred-count 1 \
  --elapsed-seconds 24 >/dev/null 2>&1
assert_exit "$?" "0" "record-scope-preflight: exit 0"

sidecar="${home}/sessions/${sid}.timing.json"
assert_file_exists "$sidecar" "record-scope-preflight: creates sidecar"

content=$(cat "$sidecar")
assert_contains "$content" '"scope_preflight"' "record-scope-preflight: scope_preflight key present"
assert_contains "$content" '"candidates"' "record-scope-preflight: candidates key present"
assert_contains "$content" '"ready"' "record-scope-preflight: ready key present"
assert_contains "$content" '"deferred"' "record-scope-preflight: deferred key present"
assert_contains "$content" '"avg_seconds_per_candidate"' "record-scope-preflight: avg_seconds_per_candidate present"

ready=$(printf '%s' "$content" | jq '.scope_preflight.ready')
assert_equals "$ready" "3" "record-scope-preflight: ready count correct"

avg=$(printf '%s' "$content" | jq '.scope_preflight.avg_seconds_per_candidate')
assert_equals "$avg" "6" "record-scope-preflight: avg_seconds_per_candidate = 24/4 = 6"

# Record with zero candidates — should not produce div-by-zero.
SHIPYARD_HOME="$home" "$helper" record-scope-preflight \
  --session-id "${sid}-zero" \
  --candidates-scoped 0 \
  --ready-count 0 \
  --deferred-count 0 \
  --elapsed-seconds 0 >/dev/null 2>&1
assert_exit "$?" "0" "record-scope-preflight: exit 0 with zero candidates"

rm -rf "$home"

# --------------------------------------------------------------------------
echo "== flush"
# --------------------------------------------------------------------------

home=$(mktmphome)
sid="test-flush-$$"
init_session "$home" "$sid"

# Populate sidecar with two phases.
SHIPYARD_HOME="$home" "$helper" start --session-id "$sid" --phase step_0_5_worktree >/dev/null 2>&1
SHIPYARD_HOME="$home" "$helper" end   --session-id "$sid" --phase step_0_5_worktree >/dev/null 2>&1
SHIPYARD_HOME="$home" "$helper" start --session-id "$sid" --phase step_6_scope_preflight >/dev/null 2>&1
SHIPYARD_HOME="$home" "$helper" end   --session-id "$sid" --phase step_6_scope_preflight >/dev/null 2>&1

sidecar="${home}/sessions/${sid}.timing.json"
assert_file_exists "$sidecar" "flush: sidecar present before flush"

SHIPYARD_HOME="$home" "$helper" flush --session-id "$sid" >/dev/null 2>&1
assert_exit "$?" "0" "flush: exit 0 on success"

assert_file_missing "$sidecar" "flush: sidecar removed after flush"

# Session state should now have a .setup block.
setup_block=$(SHIPYARD_HOME="$home" "$session_helper" read --session-id "$sid" --path '.setup')
assert_contains "$setup_block" '"wall_clock_seconds"' "flush: setup.wall_clock_seconds in session state"
assert_contains "$setup_block" '"step_0_5_worktree"' "flush: step_0_5_worktree phase in session state"
assert_contains "$setup_block" '"step_6_scope_preflight"' "flush: step_6_scope_preflight phase in session state"

# Wall clock should be >= 0.
wall=$(printf '%s' "$setup_block" | jq '.wall_clock_seconds')
ok=$(printf '%s' "$wall" | jq '. >= 0')
assert_equals "$ok" "true" "flush: wall_clock_seconds >= 0"

rm -rf "$home"

# --------------------------------------------------------------------------
echo "== flush — idempotent when sidecar gone"
# --------------------------------------------------------------------------

home=$(mktmphome)
sid="test-flush-idem-$$"
init_session "$home" "$sid"

# Flush with no sidecar — should exit 0 silently.
SHIPYARD_HOME="$home" "$helper" flush --session-id "$sid" >/dev/null 2>&1
assert_exit "$?" "0" "flush: exit 0 when sidecar missing (idempotent)"

rm -rf "$home"

# --------------------------------------------------------------------------
echo "== flush — missing session file returns exit 3"
# --------------------------------------------------------------------------

home=$(mktmphome)
sid="test-flush-nosess-$$"

# Write a sidecar but no session state.
mkdir -p "${home}/sessions"
printf '{"phases":{}}' > "${home}/sessions/${sid}.timing.json"

SHIPYARD_HOME="$home" "$helper" flush --session-id "$sid" >/dev/null 2>&1
assert_exit "$?" "3" "flush: exit 3 when session file missing"

rm -rf "$home"

# --------------------------------------------------------------------------
echo "== read — sidecar present"
# --------------------------------------------------------------------------

home=$(mktmphome)
sid="test-read-sidecar-$$"

SHIPYARD_HOME="$home" "$helper" start --session-id "$sid" --phase step_0_5_worktree >/dev/null 2>&1
out=$(SHIPYARD_HOME="$home" "$helper" read --session-id "$sid" --format json 2>/dev/null)
assert_exit "$?" "0" "read: exit 0 when sidecar present"
assert_contains "$out" '"step_0_5_worktree"' "read: sidecar data returned"

rm -rf "$home"

# --------------------------------------------------------------------------
echo "== read — session state after flush"
# --------------------------------------------------------------------------

home=$(mktmphome)
sid="test-read-sess-$$"
init_session "$home" "$sid"

SHIPYARD_HOME="$home" "$helper" start --session-id "$sid" --phase step_0_5_worktree >/dev/null 2>&1
SHIPYARD_HOME="$home" "$helper" end   --session-id "$sid" --phase step_0_5_worktree >/dev/null 2>&1
SHIPYARD_HOME="$home" "$helper" flush --session-id "$sid" >/dev/null 2>&1

out=$(SHIPYARD_HOME="$home" "$helper" read --session-id "$sid" --format json 2>/dev/null)
assert_exit "$?" "0" "read: exit 0 reading from session state"
assert_contains "$out" '"wall_clock_seconds"' "read: session state setup block returned after flush"

rm -rf "$home"

# --------------------------------------------------------------------------
echo "== read — empty state (no sidecar, no session)"
# --------------------------------------------------------------------------

home=$(mktmphome)
sid="test-read-empty-$$"

out=$(SHIPYARD_HOME="$home" "$helper" read --session-id "$sid" --format json 2>/dev/null)
assert_exit "$?" "0" "read: exit 0 when nothing exists"
assert_equals "$out" "{}" "read: returns empty object when nothing exists"

rm -rf "$home"

# --------------------------------------------------------------------------
echo "== integration: start → end → record-scope-preflight → flush → session state"
# --------------------------------------------------------------------------

home=$(mktmphome)
sid="test-integration-$$"
init_session "$home" "$sid"

SHIPYARD_HOME="$home" "$helper" start --session-id "$sid" --phase step_0_5_worktree       >/dev/null 2>&1
SHIPYARD_HOME="$home" "$helper" end   --session-id "$sid" --phase step_0_5_worktree       >/dev/null 2>&1
SHIPYARD_HOME="$home" "$helper" start --session-id "$sid" --phase step_1_7_trusted_authors >/dev/null 2>&1
SHIPYARD_HOME="$home" "$helper" end   --session-id "$sid" --phase step_1_7_trusted_authors >/dev/null 2>&1
SHIPYARD_HOME="$home" "$helper" start --session-id "$sid" --phase step_3_5_refine_issues   >/dev/null 2>&1
SHIPYARD_HOME="$home" "$helper" end   --session-id "$sid" --phase step_3_5_refine_issues   >/dev/null 2>&1
SHIPYARD_HOME="$home" "$helper" start --session-id "$sid" --phase step_6_scope_preflight   >/dev/null 2>&1
SHIPYARD_HOME="$home" "$helper" end   --session-id "$sid" --phase step_6_scope_preflight   >/dev/null 2>&1
SHIPYARD_HOME="$home" "$helper" record-scope-preflight \
  --session-id "$sid" \
  --candidates-scoped 4 \
  --ready-count 3 \
  --deferred-count 1 \
  --elapsed-seconds 20 >/dev/null 2>&1
SHIPYARD_HOME="$home" "$helper" flush --session-id "$sid" >/dev/null 2>&1

setup=$(SHIPYARD_HOME="$home" "$session_helper" read --session-id "$sid" --path '.setup')
assert_contains "$setup" '"step_0_5_worktree"'        "integration: step_0_5_worktree in setup.phases"
assert_contains "$setup" '"step_1_7_trusted_authors"' "integration: step_1_7_trusted_authors in setup.phases"
assert_contains "$setup" '"step_3_5_refine_issues"'   "integration: step_3_5_refine_issues in setup.phases"
assert_contains "$setup" '"step_6_scope_preflight"'   "integration: step_6_scope_preflight in setup.phases"
assert_contains "$setup" '"scope_preflight"'           "integration: scope_preflight block in setup"

ready=$(printf '%s' "$setup" | jq '.scope_preflight.ready')
assert_equals "$ready" "3" "integration: scope_preflight.ready correct"

rm -rf "$home"

# --------------------------------------------------------------------------
printf '\n%sPASS%s: %d  %sFAIL%s: %d\n' \
  "$GREEN" "$RESET" "$pass" "$RED" "$RESET" "$fail"

if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
