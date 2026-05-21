#!/usr/bin/env bash
# Test suite for scripts/status.sh.
#
# Covers the dashboard renderer fed by per-session state files at
# $SHIPYARD_HOME/sessions/*.json:
#
#   render          — default text dashboard
#   render --json   — machine-readable projection
#   render --stale  — show only stale workers
#
# Stale detection uses progress_updated_at (or started_at as a fallback);
# the threshold is configurable via SHIPYARD_STATUS_STALE_S or the
# --stale-seconds flag.
#
# Run with:
#
#   bash plugins/shipyard/scripts/tests/status.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../status.sh"
state_helper="${here}/../session-state.sh"

if [[ ! -f "$helper" ]]; then
  echo "FAIL: helper not found at $helper" >&2
  exit 1
fi
if [[ ! -f "$state_helper" ]]; then
  echo "FAIL: session-state helper not found at $state_helper" >&2
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

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected NOT to contain: %s\n' "$needle"
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

mktmphome() {
  local d
  d=$(mktemp -d)
  echo "$d"
}

# Helper: compute an ISO-8601 UTC timestamp `N` seconds in the past, in a
# portable way (BSD `date -v` for macOS; GNU `date -d` for Linux).
past_ts() {
  local seconds="$1"
  date -u -v-"${seconds}"S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "$seconds seconds ago" +%Y-%m-%dT%H:%M:%SZ
}

# --------------------------------------------------------------------------
echo "== empty (no sessions directory)"
# --------------------------------------------------------------------------
tmphome=$(mktmphome)
out=$(SHIPYARD_HOME="$tmphome" bash "$helper")
assert_contains "$out" "no active sessions" "empty sessions dir reports 'no active sessions'"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== sessions present but no in-flight slots"
# --------------------------------------------------------------------------
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$state_helper" init --session-id "empty-session" --repo "owner/repo" --concurrency 2 >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper")
assert_contains "$out" "0 active worker(s)" "session with empty in_flight reports 0 active workers"
assert_contains "$out" "no in-flight workers" "advisory message printed for empty in_flight"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== single in-flight worker renders in text dashboard"
# --------------------------------------------------------------------------
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$state_helper" init --session-id "s1" --repo "owner/repo" --concurrency 2 >/dev/null

# Use a started_at 30s in the past so ELAPSED renders non-zero.
ts=$(past_ts 30)
SHIPYARD_HOME="$tmphome" bash "$state_helper" update --session-id "s1" \
  --set ".in_flight.slot1 = {kind: \"issue\", target: 142, claimed_paths: {hard: [], soft: []}, agent_id: \"abc\", started_at: \"$ts\"}" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper")
assert_contains "$out" "1 active worker(s)" "single-worker session reports 1 active worker"
assert_contains "$out" "1 session(s)" "single-worker session reports 1 session"
assert_contains "$out" "#142" "target #142 rendered"
assert_contains "$out" "issue" "kind 'issue' rendered"
assert_contains "$out" "owner/repo" "session repo rendered"
assert_contains "$out" "s1" "session id rendered"
# Stale detection: 30s elapsed, default threshold is 5min — should not be stale.
# Use the ⚠ STALE marker (with the warning glyph) to avoid colliding with
# the column header "STALE-AGE".
assert_not_contains "$out" "⚠ STALE" "30s-old worker is not stale under 5min default threshold"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== progress counters render"
# --------------------------------------------------------------------------
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$state_helper" init --session-id "s2" --repo "owner/repo" >/dev/null

ts=$(past_ts 15)
SHIPYARD_HOME="$tmphome" bash "$state_helper" update --session-id "s2" \
  --set ".in_flight.slot1 = {kind: \"refining\", target: \"batch\", claimed_paths: {hard: [], soft: []}, agent_id: \"abc\", started_at: \"$ts\"}" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$state_helper" set-progress --session-id "s2" --slot "slot1" --current 4 --total 7 >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper")
assert_contains "$out" "(4/7)" "progress counter 4/7 renders next to worker kind"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== stale detection (>5min default)"
# --------------------------------------------------------------------------
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$state_helper" init --session-id "s3" --repo "owner/repo" >/dev/null

# 6 minutes in the past -> stale under default 300s threshold.
ts=$(past_ts 360)
SHIPYARD_HOME="$tmphome" bash "$state_helper" update --session-id "s3" \
  --set ".in_flight.slot1 = {kind: \"issue\", target: 200, claimed_paths: {hard: [], soft: []}, agent_id: \"abc\", started_at: \"$ts\"}" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper")
assert_contains "$out" "⚠ STALE" "6-minute-old worker flagged as STALE"

# Override threshold via env var: 600s threshold -> no longer stale.
out=$(SHIPYARD_STATUS_STALE_S=600 SHIPYARD_HOME="$tmphome" bash "$helper")
assert_not_contains "$out" "⚠ STALE" "10-min threshold via env var prevents 6-min worker from being stale"

# --stale flag: filter to ONLY stale workers.
ts2=$(past_ts 5)
SHIPYARD_HOME="$tmphome" bash "$state_helper" update --session-id "s3" \
  --set ".in_flight.slot2 = {kind: \"issue\", target: 201, claimed_paths: {hard: [], soft: []}, agent_id: \"def\", started_at: \"$ts2\"}" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" --stale)
assert_contains "$out" "#200" "--stale shows the stale worker (#200)"
assert_not_contains "$out" "#201" "--stale hides the fresh worker (#201)"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== --json projection"
# --------------------------------------------------------------------------
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$state_helper" init --session-id "s4" --repo "owner/repo" >/dev/null
ts=$(past_ts 60)
SHIPYARD_HOME="$tmphome" bash "$state_helper" update --session-id "s4" \
  --set ".in_flight.slot1 = {kind: \"issue\", target: 142, claimed_paths: {hard: [], soft: []}, agent_id: \"abc\", started_at: \"$ts\"}" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$state_helper" bump-tokens --session-id "s4" \
  --issue 142 --input 1500 --output 250 --mode issue-work --model claude-opus-4-7 >/dev/null
SHIPYARD_HOME="$tmphome" bash "$state_helper" set-progress --session-id "s4" --slot "slot1" --current 2 --total 5 >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" --json)
# Validate JSON is well-formed.
if echo "$out" | jq -e '.' >/dev/null 2>&1; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "--json output is well-formed JSON"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  --json output is not valid JSON\n' "$RED" "$RESET"
  fail=$((fail+1))
fi

# Check key fields are present.
out_sessions=$(echo "$out" | jq -r '. | length')
assert_equals "$out_sessions" "1" "--json emits one session entry"

out_slot_target=$(echo "$out" | jq -r '.[0].in_flight[0].target')
assert_equals "$out_slot_target" "142" "--json carries .in_flight[].target"
out_progress=$(echo "$out" | jq -r '.[0].in_flight[0].progress_current')
assert_equals "$out_progress" "2" "--json carries .in_flight[].progress_current"
out_total=$(echo "$out" | jq -r '.[0].in_flight[0].progress_total')
assert_equals "$out_total" "5" "--json carries .in_flight[].progress_total"
out_input=$(echo "$out" | jq -r '.[0].in_flight[0].tokens.input')
assert_equals "$out_input" "1500" "--json carries per-slot tokens.input from per_issue bucket"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== multiple sessions in the same dashboard"
# --------------------------------------------------------------------------
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$state_helper" init --session-id "sA" --repo "owner/repoA" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$state_helper" init --session-id "sB" --repo "owner/repoB" >/dev/null

ts=$(past_ts 5)
SHIPYARD_HOME="$tmphome" bash "$state_helper" update --session-id "sA" \
  --set ".in_flight.s1 = {kind: \"issue\", target: 10, claimed_paths: {hard: [], soft: []}, agent_id: \"a\", started_at: \"$ts\"}" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$state_helper" update --session-id "sB" \
  --set ".in_flight.s1 = {kind: \"fix-checks\", target: 99, claimed_paths: {hard: [], soft: []}, agent_id: \"b\", started_at: \"$ts\"}" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper")
assert_contains "$out" "2 active worker(s)" "two sessions => 2 active workers"
assert_contains "$out" "2 session(s)" "two sessions => 2 sessions reported"
assert_contains "$out" "sA" "session sA rendered"
assert_contains "$out" "sB" "session sB rendered"
assert_contains "$out" "#10" "session sA issue #10 rendered"
assert_contains "$out" "PR #99" "session sB fix-checks PR #99 rendered"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== usage errors"
# --------------------------------------------------------------------------
out=$(bash "$helper" --bogus-flag 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "unknown flag exits 64"
assert_contains "$out" "Usage" "unknown flag prints usage hint"

out=$(bash "$helper" --stale-seconds "abc" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "non-numeric --stale-seconds exits 64"

# Help.
out=$(bash "$helper" --help 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=0" "--help exits 0"
assert_contains "$out" "Usage" "--help prints usage"

# --------------------------------------------------------------------------
echo "== robustness: malformed JSON in a session file is skipped"
# --------------------------------------------------------------------------
tmphome=$(mktmphome)
# Drop a valid session and a deliberately-malformed one — status.sh
# should render the valid one and skip the broken one without crashing.
SHIPYARD_HOME="$tmphome" bash "$state_helper" init --session-id "good" --repo "owner/repo" >/dev/null
ts=$(past_ts 5)
SHIPYARD_HOME="$tmphome" bash "$state_helper" update --session-id "good" \
  --set ".in_flight.s1 = {kind: \"issue\", target: 42, claimed_paths: {hard: [], soft: []}, agent_id: \"a\", started_at: \"$ts\"}" >/dev/null
echo "this is not json" > "$tmphome/sessions/broken.json"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" 2>/dev/null)
assert_contains "$out" "#42" "valid session still renders alongside a malformed neighbor"
assert_contains "$out" "1 active worker(s)" "malformed neighbor doesn't get counted as an active worker"
rm -rf "$tmphome"

echo
echo "Results: ${GREEN}${pass} passed${RESET}, ${RED}${fail} failed${RESET}"
[[ $fail -eq 0 ]]
