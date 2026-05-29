#!/usr/bin/env bash
# Test suite for scripts/flake-registry.sh (issue #378).
#
# Covers the data-layer subcommands:
#   record   — append a flake event (with/without optional fields, dry-run,
#              arg validation).
#   report   — windowed per-(workflow,job,test) aggregation.
#   crossed  — threshold evaluation (rerun + distinct-PRs), action echo.
#   read     — raw jsonl passthrough, missing-file exit 3.
#   prune    — drop out-of-window events.
#   reset    — move file aside to .bak.
#
# Pure bash + jq. Run with:
#
#   bash plugins/shipyard/scripts/tests/flake-registry.test.sh

# shellcheck disable=SC2162
# SC2162 (read without -r) fires on `run read` invocations below — but `read`
# there is the helper's subcommand name passed to the `run` wrapper, NOT the
# bash `read` builtin. shellcheck can't distinguish the two; the disable is
# file-scoped because the pattern recurs across several assertions.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../flake-registry.sh"

if [[ ! -f "$helper" ]]; then
  echo "FAIL: helper not found at $helper" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to contain: %s\n' "$needle"
    printf '    actual: %s\n' "$haystack" | head -c 400; printf '\n'
    fail=$((fail+1))
  fi
}

assert_equals() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected: %s\n' "$expected"
    printf '    actual:   %s\n' "$actual"
    fail=$((fail+1))
  fi
}

assert_exit() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (exit %s, expected %s)\n' "$RED" "$RESET" "$label" "$actual" "$expected"
    fail=$((fail+1))
  fi
}

# Isolated SHIPYARD_HOME per run.
TMPHOME="$(mktemp -d)"
export SHIPYARD_HOME="$TMPHOME"
trap 'rm -rf "$TMPHOME"' EXIT

run() { bash "$helper" "$@"; }

# A timestamp N days in the past (UTC). Mirrors the helper's cutoff math so
# tests can plant in-window and out-of-window events deterministically.
days_ago() {
  date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

echo "== record =="

# Missing required args -> usage error 64.
run record --repo o/r --pr 1 >/dev/null 2>&1; assert_exit 64 "$?" "record without --workflow/--job exits 64"
run record --repo o/r --pr notanum --workflow CI --job J >/dev/null 2>&1; assert_exit 64 "$?" "record with non-numeric --pr exits 64"

# Dry-run emits the line, doesn't write.
line=$(run record --repo o/r --pr 1377 --workflow CI --job "Web E2E (2/3)" --test AUTH-CORE-19 --dry-run)
assert_contains "$line" '"pr":1377' "dry-run line carries numeric pr"
assert_contains "$line" '"test":"AUTH-CORE-19"' "dry-run line carries test"
assert_contains "$line" '"action":"rerun-failed"' "dry-run line defaults action"
assert_exit 3 "$(run read >/dev/null 2>&1; echo $?)" "registry still missing after dry-run (read exits 3)"

# Optional fields omitted when empty.
line=$(run record --repo o/r --pr 5 --workflow CI --job J --dry-run)
testpresent=$(printf '%s' "$line" | jq 'has("test")')
assert_equals "$testpresent" "false" "test field omitted when not provided"

# Real append.
run record --repo o/r --pr 1 --workflow CI --job "Web E2E" --test T1
run read >/dev/null 2>&1; assert_exit 0 "$?" "read exits 0 after first append"
count=$(run read | wc -l | tr -d ' ')
assert_equals "$count" "1" "one line after one append"

echo "== report =="

rm -f "$TMPHOME/flake-registry.jsonl"
# Plant: T1 flakes on PR1, PR2, PR3 (3 events, 3 PRs); T2 once on PR9.
for pr in 1 2 3; do
  run record --repo o/r --pr "$pr" --workflow CI --job "Web E2E" --test T1 --at "$(days_ago 1)"
done
run record --repo o/r --pr 9 --workflow CI --job "Web E2E" --test T2 --at "$(days_ago 1)"

rep=$(run report --repo o/r --window-days 7)
t1_events=$(printf '%s' "$rep" | jq '.[] | select(.test=="T1") | .events')
t1_prs=$(printf '%s' "$rep" | jq '.[] | select(.test=="T1") | .distinct_prs')
assert_equals "$t1_events" "3" "T1 aggregates to 3 events"
assert_equals "$t1_prs" "3" "T1 spans 3 distinct PRs"
t2_events=$(printf '%s' "$rep" | jq '.[] | select(.test=="T2") | .events')
assert_equals "$t2_events" "1" "T2 aggregates to 1 event"

# Out-of-window events excluded.
run record --repo o/r --pr 100 --workflow CI --job "Web E2E" --test T1 --at "$(days_ago 30)"
t1_events_7d=$(run report --repo o/r --window-days 7 | jq '.[] | select(.test=="T1") | .events')
assert_equals "$t1_events_7d" "3" "30-day-old event excluded from 7-day window"
t1_events_60d=$(run report --repo o/r --window-days 60 | jq '.[] | select(.test=="T1") | .events')
assert_equals "$t1_events_60d" "4" "30-day-old event included in 60-day window"

# Repo filter isolates.
run record --repo other/repo --pr 1 --workflow CI --job J --test X --at "$(days_ago 1)"
rows_or=$(run report --repo o/r --window-days 7 | jq 'length')
assert_equals "$rows_or" "2" "repo filter keeps only o/r rows (T1,T2)"

echo "== crossed =="

# Defaults: rerun>=3 AND distinct-prs>=2. T1 (3 events / 3 PRs) crosses; T2 doesn't.
cr=$(run crossed --repo o/r --window-days 7)
crossed_tests=$(printf '%s' "$cr" | jq -r '[.[].test] | sort | join(",")')
assert_equals "$crossed_tests" "T1" "only T1 crosses default threshold"
actions=$(printf '%s' "$cr" | jq -r '.[0].actions | join(",")')
assert_equals "$actions" "file-tracking-issue,stop-auto-rerunning,apply-blocked-ci" "crossed row echoes default actions"

# distinct-PRs guard: a single PR flaking many times shouldn't cross with default distinct=2.
rm -f "$TMPHOME/flake-registry.jsonl"
for _ in 1 2 3 4 5; do
  run record --repo o/r --pr 7 --workflow CI --job J --test SOLO --at "$(days_ago 1)"
done
cr_solo=$(run crossed --repo o/r --window-days 7)
assert_equals "$(printf '%s' "$cr_solo" | jq 'length')" "0" "5 events on 1 PR does NOT cross (distinct-prs guard)"
# Lowering distinct threshold to 1 makes it cross.
cr_solo1=$(run crossed --repo o/r --window-days 7 --distinct-prs-threshold 1)
assert_equals "$(printf '%s' "$cr_solo1" | jq '.[0].events')" "5" "SOLO crosses when distinct-prs-threshold=1"

# Custom actions list echoes through.
cr_custom=$(run crossed --repo o/r --window-days 7 --distinct-prs-threshold 1 --actions "file-tracking-issue")
assert_equals "$(printf '%s' "$cr_custom" | jq -r '.[0].actions | join(",")')" "file-tracking-issue" "custom --actions echoes"

echo "== prune =="

rm -f "$TMPHOME/flake-registry.jsonl"
run record --repo o/r --pr 1 --workflow CI --job J --test KEEP --at "$(days_ago 1)"
run record --repo o/r --pr 2 --workflow CI --job J --test DROP --at "$(days_ago 200)"
run prune --window-days 90
remaining=$(run read)
assert_contains "$remaining" "KEEP" "prune keeps in-window event"
assert_equals "$(printf '%s' "$remaining" | grep -c DROP)" "0" "prune drops out-of-window event"

echo "== reset =="

run reset --yes
assert_exit 3 "$(run read >/dev/null 2>&1; echo $?)" "read exits 3 after reset"
bak_count=$(find "$TMPHOME" -name 'flake-registry.jsonl.bak.*' | wc -l | tr -d ' ')
assert_equals "$bak_count" "1" "reset moves file to a .bak (recoverable)"

echo
echo "flake-registry.test.sh: ${pass} passed, ${fail} failed"
[[ $fail -eq 0 ]]
