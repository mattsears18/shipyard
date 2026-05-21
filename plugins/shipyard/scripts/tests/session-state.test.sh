#!/usr/bin/env bash
# Test suite for scripts/session-state.sh.
#
# Covers the four subcommands the orchestrator drives:
#
#   init     — create a fresh session state file at a deterministic path
#   update   — merge a JSON snippet into the file atomically (temp + rename)
#   read     — emit the current state JSON on stdout (whole-file or jq path)
#   cleanup  — remove the session file (end-of-session housekeeping)
#
# Atomicity is the load-bearing property: every update writes to
# <path>.tmp.<pid> and renames into place. A partial-write crash leaves the
# previous file intact rather than corrupting the source of truth.
#
# Pure bash + python3 (already required elsewhere in shipyard's script set).
# Run with:
#
#   bash plugins/shipyard/scripts/tests/session-state.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../session-state.sh"

if [[ ! -f "$helper" ]]; then
  echo "FAIL: helper not found at $helper" >&2
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

# Each test gets a private SHIPYARD_HOME under a fresh tmpdir so the suite
# never touches the real ~/.shipyard.
mktmphome() {
  local d
  d=$(mktemp -d)
  echo "$d"
}

# --------------------------------------------------------------------------
echo "== init"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init \
  --session-id "abc-123" \
  --repo "owner/repo" \
  --concurrency 4 \
  --soft-collision-concurrency 3 \
  >/dev/null

session_file="$tmphome/sessions/abc-123.json"
assert_file_exists "$session_file" "init creates session file at \$SHIPYARD_HOME/sessions/<id>.json"

content=$(cat "$session_file")
assert_contains "$content" '"session_id": "abc-123"' "session_id persisted"
assert_contains "$content" '"repo": "owner/repo"' "repo persisted"
assert_contains "$content" '"concurrency": 4' "concurrency persisted"
assert_contains "$content" '"soft_collision_concurrency": 3' "soft_collision_concurrency persisted"
assert_contains "$content" '"in_flight": {}' "in_flight initialised to empty object"
assert_contains "$content" '"ready_issues": []' "ready_issues initialised to empty array"
assert_contains "$content" '"failed_prs": []' "failed_prs initialised to empty array"
assert_contains "$content" '"divert_queue": []' "divert_queue initialised to empty array"
assert_contains "$content" '"session_prs": []' "session_prs initialised to empty array"
assert_contains "$content" '"deferred_issues": []' "deferred_issues initialised to empty array"
assert_contains "$content" '"raw_backlog": []' "raw_backlog initialised to empty array"
assert_contains "$content" '"main_ci"' "main_ci block initialised"
assert_contains "$content" '"started_at"' "started_at timestamp present"
rm -rf "$tmphome"

# init refuses to clobber an existing session file unless --force.
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "s1" --repo "o/r" >/dev/null
# Mutate the file to prove it isn't being overwritten.
echo '{"sentinel":"untouched"}' > "$tmphome/sessions/s1.json"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "s1" --repo "o/r" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=2" "init without --force on existing file exits 2"
assert_contains "$(cat "$tmphome/sessions/s1.json")" '"sentinel"' "init without --force does not clobber existing file"

SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "s1" --repo "o/r" --force >/dev/null
assert_contains "$(cat "$tmphome/sessions/s1.json")" '"session_id": "s1"' "init --force overwrites existing file"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== read"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "r1" --repo "o/r" --concurrency 2 >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "r1")
assert_contains "$out" '"session_id": "r1"' "read with no path emits whole state"

# Read a specific jq path.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "r1" --path ".concurrency")
assert_equals "$out" "2" "read --path .concurrency returns the concurrency value"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "r1" --path ".repo")
assert_equals "$out" "o/r" "read --path .repo returns the repo string"

# Missing session file → exit 3, empty stdout.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "missing" 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=3" "read of missing session exits 3"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== update"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "u1" --repo "o/r" --concurrency 2 >/dev/null

# Update a top-level field via --set.
SHIPYARD_HOME="$tmphome" bash "$helper" update --session-id "u1" \
  --set '.session_prs = [96, 98]' \
  --set '.main_ci.status = "green"' >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "u1" --path ".session_prs")
assert_contains "$out" "96" "update --set persists session_prs first entry"
assert_contains "$out" "98" "update --set persists session_prs second entry"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "u1" --path ".main_ci.status")
assert_equals "$out" "green" "update --set persists nested main_ci.status"

# Update preserves unrelated fields.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "u1" --path ".concurrency")
assert_equals "$out" "2" "update does not perturb unrelated fields"

# Append-to-array semantics via --set with jq's `+=` shape.
SHIPYARD_HOME="$tmphome" bash "$helper" update --session-id "u1" \
  --set '.session_prs += [100]' >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "u1" --path ".session_prs | length")
assert_equals "$out" "3" "update --set with += appends to array"

# Atomic write: temp file must not linger after a successful update.
# Use a glob rather than `ls | grep` (shellcheck SC2010) to enumerate any
# files other than the canonical u1.json in the sessions dir.
leftover=""
shopt -s nullglob
for f in "$tmphome/sessions/"*; do
  case "$(basename "$f")" in
    u1.json) ;;
    *) leftover="$leftover $(basename "$f")" ;;
  esac
done
shopt -u nullglob
assert_equals "${leftover# }" "" "update does not leave .tmp files behind after successful write"

# Update of a missing session file → exit 3, no file created.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" update --session-id "missing" \
  --set '.foo = "bar"' 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=3" "update of missing session exits 3"
assert_file_missing "$tmphome/sessions/missing.json" "update of missing session does not create the file"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== cleanup"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "c1" --repo "o/r" >/dev/null
session_file="$tmphome/sessions/c1.json"
assert_file_exists "$session_file" "session file exists before cleanup"

SHIPYARD_HOME="$tmphome" bash "$helper" cleanup --session-id "c1" >/dev/null
assert_file_missing "$session_file" "cleanup removes the session file"

# Cleanup of a missing session is a no-op (exit 0) — re-runs must be safe.
SHIPYARD_HOME="$tmphome" bash "$helper" cleanup --session-id "c1"
rc=$?
assert_equals "$rc" "0" "cleanup of missing session is idempotent (exit 0)"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== unknown subcommand"
# --------------------------------------------------------------------------

out=$(bash "$helper" frobnicate 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "unknown subcommand exits 64 (EX_USAGE)"
assert_contains "$out" "Usage" "unknown subcommand prints usage hint"

# --------------------------------------------------------------------------
echo "== missing args"
# --------------------------------------------------------------------------

out=$(bash "$helper" init 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "init without --session-id exits 64"
assert_contains "$out" "session-id" "init without --session-id mentions the missing arg"

out=$(bash "$helper" read 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "read without --session-id exits 64"

out=$(bash "$helper" update --session-id x 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "update without --set exits 64"

# --------------------------------------------------------------------------
echo "== init writes the tokens field"
# --------------------------------------------------------------------------
# The session-state schema grew a `.tokens` block in 1.3.30 (issue #153) for
# per-session token accounting. init MUST seed it to its empty shape so
# subsequent bump-tokens / read-tokens calls never trip on a missing key.

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "tok-init" --repo "o/r" >/dev/null
session_file="$tmphome/sessions/tok-init.json"
content=$(cat "$session_file")
assert_contains "$content" '"tokens"' "init seeds .tokens block"
assert_contains "$content" '"totals"' ".tokens.totals present"
assert_contains "$content" '"per_issue": {}' ".tokens.per_issue is empty object"
assert_contains "$content" '"per_pr": {}' ".tokens.per_pr is empty object"
assert_contains "$content" '"per_invocation": []' ".tokens.per_invocation is empty array"
assert_contains "$content" '"estimated_usd": 0' ".tokens.totals.estimated_usd seeded to 0"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== bump-tokens — basic accumulation"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "tok-bump" --repo "o/r" >/dev/null

# First bump — issue + pr cross-link, opus pricing path.
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-bump" \
  --issue 153 --pr 200 \
  --input 1000 --output 500 \
  --cache-read 200 --cache-creation 100 \
  --mode issue-work --model claude-opus-4-7 >/dev/null

# Totals updated.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-bump" --path ".tokens.totals.input")
assert_equals "$out" "1000" "bump-tokens updates totals.input"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-bump" --path ".tokens.totals.output")
assert_equals "$out" "500" "bump-tokens updates totals.output"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-bump" --path ".tokens.totals.cache_read")
assert_equals "$out" "200" "bump-tokens updates totals.cache_read"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-bump" --path ".tokens.totals.cache_creation")
assert_equals "$out" "100" "bump-tokens updates totals.cache_creation"

# Per-issue + per-pr buckets created.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-bump" --path ".tokens.per_issue[\"153\"].input")
assert_equals "$out" "1000" "bump-tokens creates per_issue bucket and updates input"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-bump" --path ".tokens.per_pr[\"200\"].input")
assert_equals "$out" "1000" "bump-tokens creates per_pr bucket and updates input"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-bump" --path ".tokens.per_pr[\"200\"].issue")
assert_equals "$out" "153" "bump-tokens cross-links per_pr.issue when --issue+--pr both supplied"

# Per-invocation ring buffer recorded.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-bump" --path ".tokens.per_invocation | length")
assert_equals "$out" "1" "bump-tokens appends one entry to per_invocation"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-bump" --path ".tokens.per_invocation[0].mode")
assert_equals "$out" "issue-work" "per_invocation[0].mode recorded"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-bump" --path ".tokens.per_invocation[0].model")
assert_equals "$out" "claude-opus-4-7" "per_invocation[0].model recorded"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-bump" --path ".tokens.per_invocation[0].issue")
assert_equals "$out" "153" "per_invocation[0].issue recorded as number"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-bump" --path ".tokens.per_invocation[0].pr")
assert_equals "$out" "200" "per_invocation[0].pr recorded as number"

# Second bump — accumulator semantics (sum, not replace).
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-bump" \
  --issue 153 --pr 200 \
  --input 500 --output 100 \
  --mode fix-checks-only --model claude-opus-4-7 >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-bump" --path ".tokens.totals.input")
assert_equals "$out" "1500" "second bump accumulates totals.input (sum, not replace)"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-bump" --path ".tokens.per_pr[\"200\"].input")
assert_equals "$out" "1500" "second bump accumulates per_pr.input"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-bump" --path ".tokens.per_invocation | length")
assert_equals "$out" "2" "second bump appends a second per_invocation entry"

# Orchestrator-overhead path — no --issue, no --pr, only totals get bumped.
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-bump" \
  --input 300 --output 50 \
  --mode orchestrator --model claude-opus-4-7 >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-bump" --path ".tokens.totals.input")
assert_equals "$out" "1800" "orchestrator-overhead bump updates totals.input"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-bump" --path ".tokens.per_pr[\"200\"].input")
assert_equals "$out" "1500" "orchestrator-overhead bump does NOT touch per_pr buckets"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-bump" --path ".tokens.per_invocation[2].issue")
assert_equals "$out" "null" "per_invocation entry for orchestrator-overhead has null issue"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-bump" --path ".tokens.per_invocation[2].pr")
assert_equals "$out" "null" "per_invocation entry for orchestrator-overhead has null pr"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== bump-tokens — USD pricing"
# --------------------------------------------------------------------------
# Pricing table is embedded in the script (per 1M tokens). Verify the
# math for a known model (opus = $15 input + $75 output per 1M).
#   1_000_000 * $15 / 1_000_000 = $15.00 for 1M input tokens.

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "tok-price" --repo "o/r" >/dev/null

SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-price" \
  --input 1000000 --output 0 \
  --model claude-opus-4-7 >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-price" --path ".tokens.totals.estimated_usd")
assert_equals "$out" "15" "opus pricing: 1M input tokens -> \$15.00 USD"

# Unknown model -> zero USD; tokens still counted.
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-price" \
  --input 1000 \
  --model "unknown-model" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-price" --path ".tokens.totals.input")
assert_equals "$out" "1001000" "unknown model still records token counts"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== bump-tokens — input validation"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "tok-v" --repo "o/r" >/dev/null

# Negative token count -> usage error.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-v" --input "-5" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "bump-tokens rejects negative input count"

# Non-numeric issue -> usage error.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-v" --issue "abc" --input 100 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "bump-tokens rejects non-numeric --issue"

# Missing session file -> exit 3.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "missing" --input 100 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=3" "bump-tokens on missing session exits 3"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== read-tokens — json format"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "tok-r" --repo "o/r" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-r" --issue 153 --pr 200 \
  --input 1000 --output 500 --mode issue-work --model claude-opus-4-7 >/dev/null

# Session-wide totals (no --issue / --pr).
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read-tokens --session-id "tok-r" --format json)
assert_contains "$out" '"input": 1000' "read-tokens (session) returns totals.input"
assert_contains "$out" '"output": 500' "read-tokens (session) returns totals.output"

# Per-PR scope.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read-tokens --session-id "tok-r" --pr 200 --format json)
assert_contains "$out" '"input": 1000' "read-tokens --pr returns per_pr.input"
assert_contains "$out" '"issue": 153' "read-tokens --pr returns the cross-linked issue number"

# Per-issue scope.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read-tokens --session-id "tok-r" --issue 153 --format json)
assert_contains "$out" '"input": 1000' "read-tokens --issue returns per_issue.input"

# Unknown issue/PR -> zero-shape fallback (no exit-3, no error).
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read-tokens --session-id "tok-r" --pr 9999 --format json)
assert_contains "$out" '"input": 0' "read-tokens of unknown PR returns zero-shape default"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== read-tokens — comment format"
# --------------------------------------------------------------------------
# The comment format is the load-bearing output for the cost-tracking hook
# in commands/do-work.md step A. It must include the sentinel for
# idempotency and a Markdown table.

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "tok-c" --repo "owner/repo" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-c" --issue 153 --pr 200 \
  --input 18203 --output 4102 --cache-read 8210 \
  --mode issue-work --model claude-opus-4-7 >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read-tokens --session-id "tok-c" --pr 200 --format comment)
assert_contains "$out" "<!-- do-work-cost-tracking -->" "comment format includes idempotency sentinel"
assert_contains "$out" "PR #200" "comment format names the PR in the heading"
assert_contains "$out" "18203" "comment format includes the input token count"
assert_contains "$out" "4102" "comment format includes the output token count"
assert_contains "$out" "claude-opus-4-7" "comment format includes the model"
assert_contains "$out" "issue-work" "comment format includes the mode"

# Bad --format value -> usage error.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read-tokens \
  --session-id "tok-c" --pr 200 --format invalid 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "read-tokens rejects unknown --format"

# Missing session -> exit 3.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read-tokens \
  --session-id "missing" 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=3" "read-tokens on missing session exits 3"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== bump-tokens — atomicity (no .tmp files left behind)"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "tok-a" --repo "o/r" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-a" --issue 153 --pr 200 --input 1000 --mode issue-work --model claude-opus-4-7 >/dev/null

leftover=""
shopt -s nullglob
for f in "$tmphome/sessions/"*; do
  case "$(basename "$f")" in
    tok-a.json) ;;
    *) leftover="$leftover $(basename "$f")" ;;
  esac
done
shopt -u nullglob
assert_equals "${leftover# }" "" "bump-tokens leaves no .tmp files behind after successful write"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
# --------------------------------------------------------------------------
echo "== set-progress — basic update + clearing"
# --------------------------------------------------------------------------
# The set-progress subcommand (issue #167) writes batch-style progress
# counters into the per-slot `in_flight` record. Used by /shipyard:status
# to render `4/7`-style progress on batch workers.

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "prog" --repo "o/r" >/dev/null

# Seed an in_flight slot before set-progress can target it. set-progress
# is "modify an existing slot," not "create a slot" — refusing the call
# when the slot is missing surfaces the race where a worker returned and
# the slot got released before the progress write landed.
SHIPYARD_HOME="$tmphome" bash "$helper" update --session-id "prog" \
  --set '.in_flight.slot1 = {kind: "issue", target: 167, claimed_paths: {hard: [], soft: []}, agent_id: "abc", started_at: "2026-05-21T14:00:00Z"}' >/dev/null

# Set both fields.
SHIPYARD_HOME="$tmphome" bash "$helper" set-progress --session-id "prog" \
  --slot "slot1" --current 3 --total 7 >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "prog" --path ".in_flight.slot1.progress_current")
assert_equals "$out" "3" "set-progress writes progress_current"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "prog" --path ".in_flight.slot1.progress_total")
assert_equals "$out" "7" "set-progress writes progress_total"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "prog" --path ".in_flight.slot1.progress_updated_at")
# Just check it's non-null / non-empty — the timestamp value itself depends on the clock.
if [[ -n "$out" && "$out" != "null" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "set-progress stamps progress_updated_at"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s (got: %s)\n' "$RED" "$RESET" "set-progress stamps progress_updated_at" "$out"
  fail=$((fail+1))
fi

# Advance current without touching total — preserves the denominator.
SHIPYARD_HOME="$tmphome" bash "$helper" set-progress --session-id "prog" \
  --slot "slot1" --current 4 >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "prog" --path ".in_flight.slot1.progress_current")
assert_equals "$out" "4" "set-progress --current alone advances counter"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "prog" --path ".in_flight.slot1.progress_total")
assert_equals "$out" "7" "set-progress --current alone preserves total"

# Clear via literal `null`.
SHIPYARD_HOME="$tmphome" bash "$helper" set-progress --session-id "prog" \
  --slot "slot1" --current null --total null >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "prog" --path ".in_flight.slot1.progress_current")
assert_equals "$out" "null" "set-progress --current null clears progress_current"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "prog" --path ".in_flight.slot1.progress_total")
assert_equals "$out" "null" "set-progress --total null clears progress_total"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== set-progress — input validation"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "prog-v" --repo "o/r" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" update --session-id "prog-v" \
  --set '.in_flight.s1 = {kind: "issue", target: 167, claimed_paths: {hard: [], soft: []}, agent_id: "abc"}' >/dev/null

# Missing --session-id.
out=$(bash "$helper" set-progress --slot "s1" --current 3 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "set-progress without --session-id exits 64"

# Missing --slot.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" set-progress --session-id "prog-v" --current 3 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "set-progress without --slot exits 64"

# Non-numeric --current.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" set-progress --session-id "prog-v" --slot "s1" --current "abc" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "set-progress rejects non-numeric --current"

# Negative --current.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" set-progress --session-id "prog-v" --slot "s1" --current "-1" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "set-progress rejects negative --current"

# Unknown slot — the slot isn't in .in_flight, so refuse.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" set-progress --session-id "prog-v" --slot "nonexistent" --current 3 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "set-progress on unknown slot exits 64"

# Missing session file.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" set-progress --session-id "missing" --slot "s1" --current 3 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=3" "set-progress on missing session exits 3"

# Neither flag set → no-op success (defensive caller-friendliness).
SHIPYARD_HOME="$tmphome" bash "$helper" set-progress --session-id "prog-v" --slot "s1" >/dev/null
rc=$?
assert_equals "$rc" "0" "set-progress with neither --current nor --total is a no-op success"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== set-progress — atomicity (no .tmp files left behind)"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "prog-a" --repo "o/r" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" update --session-id "prog-a" \
  --set '.in_flight.s1 = {kind: "issue", target: 167, claimed_paths: {hard: [], soft: []}, agent_id: "abc"}' >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" set-progress --session-id "prog-a" --slot "s1" --current 2 --total 5 >/dev/null

leftover=""
shopt -s nullglob
for f in "$tmphome/sessions/"*; do
  case "$(basename "$f")" in
    prog-a.json) ;;
    *) leftover="$leftover $(basename "$f")" ;;
  esac
done
shopt -u nullglob
assert_equals "${leftover# }" "" "set-progress leaves no .tmp files behind after successful write"
rm -rf "$tmphome"

echo
echo "Results: ${GREEN}${pass} passed${RESET}, ${RED}${fail} failed${RESET}"
[[ $fail -eq 0 ]]
