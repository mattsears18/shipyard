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
# The session-state schema includes a `.tokens` block for per-session token
# accounting. init MUST seed it to its empty shape so subsequent bump-tokens
# / read-tokens calls never trip on a missing key.

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
# Pricing — dated-suffix and bare-alias resolution (regression for #226).
# The Anthropic API returns dated model ids (`claude-haiku-4-5-20251001`)
# and some legacy dispatch sites pass bare aliases (`opus`); both must
# resolve to the canonical row in the pricing table or every Haiku/Opus
# dispatch costs $0.
# --------------------------------------------------------------------------

tmphome=$(mktmphome)

# Dated suffix: claude-haiku-4-5-20251001 should match claude-haiku-4-5
# (haiku input = $1/Mtok → 1M input = $1.00).
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "tok-dated-haiku" --repo "o/r" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-dated-haiku" \
  --input 1000000 --output 0 \
  --model "claude-haiku-4-5-20251001" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-dated-haiku" --path ".tokens.totals.estimated_usd")
assert_equals "$out" "1" "dated haiku suffix resolves to canonical pricing row"

# Bare alias `opus` should resolve to claude-opus-4-7.
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "tok-alias-opus" --repo "o/r" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-alias-opus" \
  --input 1000000 --output 0 \
  --model "opus" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-alias-opus" --path ".tokens.totals.estimated_usd")
assert_equals "$out" "15" "bare alias 'opus' resolves to canonical pricing row"

# Bare alias `sonnet` should resolve to claude-sonnet-4-6.
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "tok-alias-sonnet" --repo "o/r" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-alias-sonnet" \
  --input 1000000 --output 0 \
  --model "sonnet" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-alias-sonnet" --path ".tokens.totals.estimated_usd")
assert_equals "$out" "3" "bare alias 'sonnet' resolves to canonical pricing row"

# Dated sonnet (future-proofing for when Anthropic rotates the suffix).
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "tok-dated-sonnet" --repo "o/r" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-dated-sonnet" \
  --input 1000000 --output 0 \
  --model "claude-sonnet-4-6-20260601" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-dated-sonnet" --path ".tokens.totals.estimated_usd")
assert_equals "$out" "3" "dated sonnet suffix resolves to canonical pricing row"

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

# USD formatting contract (issue #277): the Estimated cost (USD) row must
# render as `$X.YZ` — dollar sign prefix + exactly 2 decimal places (cents).
# Raw float output like `0.593` or `3.9216` makes the metric look like a
# unitless ratio rather than a currency amount. This pins the format so a
# future jq refactor can't regress.
#
# 18203 input + 4102 output + 8210 cache_read at opus-4-7 pricing
# (15 / 75 / 1.5 USD per 1M tokens):
#   18203 * 15/1e6 + 4102 * 75/1e6 + 8210 * 1.5/1e6 = 0.27305 + 0.30765 + 0.01232 = 0.59302
# rounds to $0.59.
assert_contains "$out" "| Estimated cost (USD) | \$0.59 |" "USD cost rendered as \$X.YZ with dollar prefix + 2 decimals"

# Negative regression check: the unrounded raw-float string (`0.593`) must
# NOT appear in the comment body. If this fires, the formatter was bypassed.
if [[ "$out" == *"| Estimated cost (USD) | 0.593 |"* ]]; then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "USD cost no longer renders as raw float"
  fail=$((fail+1))
else
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "USD cost no longer renders as raw float"
  pass=$((pass+1))
fi

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== read-tokens — USD formatting edge cases (issue #277)"
# --------------------------------------------------------------------------
# Pin the USD-formatting contract against a few rounding and zero edge cases
# so future template changes can't silently regress the format.

# Zero-cost edge case: a fresh session with no bump-tokens calls renders
# `$0.00`, not `$0` or raw `0`.
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "tok-zero" --repo "o/r" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read-tokens --session-id "tok-zero" --format comment)
assert_contains "$out" "| Estimated cost (USD) | \$0.00 |" "zero-token session renders as \$0.00"
rm -rf "$tmphome"

# Rounding edge case: a token count that produces a value with >2 decimal
# places must round to cents (banker's rounding via jq's `round`). 18203
# input tokens alone at opus-4-7 pricing = 0.27305 -> $0.27.
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "tok-round" --repo "o/r" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-round" --input 18203 \
  --mode issue-work --model claude-opus-4-7 >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read-tokens --session-id "tok-round" --format comment)
assert_contains "$out" "| Estimated cost (USD) | \$0.27 |" "0.27305 USD rounds to \$0.27"
rm -rf "$tmphome"

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

# --------------------------------------------------------------------------
echo "== is-active — PID liveness gate (issue #253)"
# --------------------------------------------------------------------------
# The orphan-sweep in commands/do-work/setup.md step 1.6 needs a way to
# skip session files whose owning orchestrator is still alive — the
# 30-min mtime floor alone was insufficient because an orchestrator can
# legitimately go quiet for >30 minutes during long drain phases or CI
# watches. is-active layers a PID-liveness check on top of mtime: exit 0
# if the file exists AND its .pid is alive (kill -0); exit 1 otherwise.

tmphome=$(mktmphome)

# init now stamps a .pid field. Default is $PPID — the bash that invoked
# the script (which in the orchestrator's call chain is the bash hook
# invoked by Claude Code).
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "live" --repo "o/r" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "live" --path ".pid")
# The default-PPID value of `out` depends on the bash that ran the test;
# verify it's a non-zero integer (the load-bearing property — a stamped pid).
if [[ "$out" =~ ^[0-9]+$ ]] && [[ "$out" != "0" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "init stamps .pid as non-zero integer by default"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s (got: %s)\n' "$RED" "$RESET" "init stamps .pid as non-zero integer by default" "$out"
  fail=$((fail+1))
fi

# Explicit --pid overrides the default.
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "live-pid" --repo "o/r" --pid 12345 --force >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "live-pid" --path ".pid")
assert_equals "$out" "12345" "init --pid <N> overrides default"

# --pid 0 means "don't stamp a liveness pid" — the field is 0, which
# is-active treats as "no signal" and exits 1.
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "no-pid" --repo "o/r" --pid 0 --force >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "no-pid" --path ".pid")
assert_equals "$out" "0" "init --pid 0 stamps zero (no liveness signal)"

# --pid rejects non-numeric input.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "bad-pid" --repo "o/r" --pid "abc" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "init --pid rejects non-numeric value"

# is-active against a live pid (our own — guaranteed alive while we run).
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "alive" --repo "o/r" --pid "$$" --force >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" is-active --session-id "alive"
rc=$?
assert_equals "$rc" "0" "is-active exits 0 when .pid is alive"

# is-active against a dead pid. Spawn `sleep 60` in background, capture
# its pid, kill it, wait until it actually exits, then test. We can't
# pick an arbitrary high number (might be reused); we have to deliberately
# create-and-kill a process to guarantee the pid is dead at test time.
sleep 60 &
DEAD_PID=$!
kill -9 "$DEAD_PID" 2>/dev/null
wait "$DEAD_PID" 2>/dev/null || true
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "dead" --repo "o/r" --pid "$DEAD_PID" --force >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" is-active --session-id "dead" 2>/dev/null
rc=$?
assert_equals "$rc" "1" "is-active exits 1 when .pid is dead"

# is-active against a missing file → exit 1 (quiet, no stderr noise).
SHIPYARD_HOME="$tmphome" bash "$helper" is-active --session-id "nonexistent" 2>/dev/null
rc=$?
assert_equals "$rc" "1" "is-active exits 1 when session file is missing"

# is-active against a file with .pid = 0 → exit 1 (no signal).
SHIPYARD_HOME="$tmphome" bash "$helper" is-active --session-id "no-pid" 2>/dev/null
rc=$?
assert_equals "$rc" "1" "is-active exits 1 when .pid is 0"

# is-active against a legacy file with no .pid field (simulate by
# building the file by hand without --pid). Use jq to strip the field
# after init so the file shape mimics a session written by an older
# shipyard version.
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "legacy" --repo "o/r" --force >/dev/null
session_file="$tmphome/sessions/legacy.json"
jq 'del(.pid)' "$session_file" > "$session_file.tmp" && mv "$session_file.tmp" "$session_file"
SHIPYARD_HOME="$tmphome" bash "$helper" is-active --session-id "legacy" 2>/dev/null
rc=$?
assert_equals "$rc" "1" "is-active exits 1 when .pid field is absent (legacy file)"

# is-active against a file with corrupt .pid (string instead of int) → exit 1.
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "corrupt" --repo "o/r" --force >/dev/null
session_file="$tmphome/sessions/corrupt.json"
jq '.pid = "garbage"' "$session_file" > "$session_file.tmp" && mv "$session_file.tmp" "$session_file"
SHIPYARD_HOME="$tmphome" bash "$helper" is-active --session-id "corrupt" 2>/dev/null
rc=$?
assert_equals "$rc" "1" "is-active exits 1 when .pid is non-numeric (corrupt file)"

# Usage error: --session-id required.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" is-active 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "is-active without --session-id exits 64"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== concurrent-sweep race regression (issue #253)"
# --------------------------------------------------------------------------
# The exact bug from #253: concurrent /do-work session B runs the orphan-
# sweep against session A's still-active file. Simulate the sweep loop
# verbatim (mtime check + is-active gate) and assert A's file survives
# regardless of mtime. Without the is-active gate, a file >30 min old
# whose orchestrator is still alive would get reaped; with it, the live
# pid blocks the reap.

tmphome=$(mktmphome)

# Session A: alive (our pid), file mtime artificially aged via `touch`.
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "alive-old" --repo "o/r" --pid "$$" >/dev/null
alive_file="$tmphome/sessions/alive-old.json"
# Force mtime to 2 hours ago — well past the 30-min floor.
# touch -t consumes [[CC]YY]MMDDhhmm in LOCAL time on macOS (BSD touch).
# Use local-time `date` here (no -u) so the resulting mtime is actually
# in the past — the previous version used `date -u` which would set the
# mtime 2H ago in UTC, which on a -0400 host is 2H in the FUTURE local,
# and `find -mmin +30` correctly refused to match it.
touch -t "$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)" "$alive_file" 2>/dev/null

# Session B: dead pid, also aged. This one SHOULD get reaped.
sleep 60 &
DEAD_PID=$!
kill -9 "$DEAD_PID" 2>/dev/null
wait "$DEAD_PID" 2>/dev/null || true
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "dead-old" --repo "o/r" --pid "$DEAD_PID" >/dev/null
dead_file="$tmphome/sessions/dead-old.json"
touch -t "$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)" "$dead_file" 2>/dev/null

# Simulate the step 1.6 sweep verbatim. The PID-liveness gate runs first;
# if it exits 0 (alive), the candidate is skipped regardless of mtime.
# Actions are appended to $tmphome/sweep.log so we can assert on them
# after the (subshell-isolated) while-loop returns.
SESSIONS_DIR="$tmphome/sessions"
find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.json' -mmin +30 2>/dev/null | while read -r orphan; do
  orphan_id=$(basename "$orphan" .json)
  if SHIPYARD_HOME="$tmphome" bash "$helper" is-active --session-id "$orphan_id" 2>/dev/null; then
    echo "skipped:$orphan_id" >> "$tmphome/sweep.log"
    continue
  fi
  echo "reaped:$orphan_id" >> "$tmphome/sweep.log"
  SHIPYARD_HOME="$tmphome" bash "$helper" cleanup --session-id "$orphan_id" 2>/dev/null
done

sweep_log=$(cat "$tmphome/sweep.log" 2>/dev/null || echo "")

# Alive session's file survives.
assert_file_exists "$alive_file" "concurrent sweep does NOT reap an alive session's file (pid liveness gate blocks it)"
assert_contains "$sweep_log" "skipped:alive-old" "sweep records alive-old as skipped (pid alive)"

# Dead session's file is reaped (the sweep still works for genuine
# orphans — the gate only protects live ones).
assert_file_missing "$dead_file" "concurrent sweep reaps a dead session's file (pid liveness fails, mtime old)"
assert_contains "$sweep_log" "reaped:dead-old" "sweep records dead-old as reaped (pid dead)"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== bump-tokens — degraded-init recovery (issue #253 workaround)"
# --------------------------------------------------------------------------
# Cost-tracking workaround for #253: when the session file gets reaped
# mid-session (e.g. by a concurrent sweep that ran before the PID gate
# landed, or by a recycled-pid + recent-mtime edge case), bump-tokens
# with --allow-degraded-init recreates a fresh state file marked with
# .degraded_recovery_at and proceeds with the bump rather than erroring
# exit-3. Cost data from before the disappear is lost, but every bump
# from the disappear forward lands somewhere durable.

tmphome=$(mktmphome)

# Don't init first — simulate the post-reap state where the file is
# already gone. With --allow-degraded-init the bump auto-recreates.
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "recovered" \
  --issue 253 --pr 999 \
  --input 1000 --output 500 --cache-read 200 --cache-creation 100 \
  --mode issue-work --model claude-opus-4-7 \
  --allow-degraded-init --degraded-init-repo "owner/repo" 2>/dev/null
rc=$?
assert_equals "$rc" "0" "bump-tokens with --allow-degraded-init succeeds when file is missing"

# File was auto-created.
recovered_file="$tmphome/sessions/recovered.json"
assert_file_exists "$recovered_file" "bump-tokens --allow-degraded-init creates the session file"

# .degraded_recovery_at is set (load-bearing for audit/metrics filtering).
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "recovered" --path ".degraded_recovery_at")
if [[ -n "$out" ]] && [[ "$out" != "null" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" ".degraded_recovery_at stamped on recovery init"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s (got: %s)\n' "$RED" "$RESET" ".degraded_recovery_at stamped on recovery init" "$out"
  fail=$((fail+1))
fi

# .repo persists from --degraded-init-repo.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "recovered" --path ".repo")
assert_equals "$out" "owner/repo" "--degraded-init-repo persists into .repo"

# The bump actually landed in the recovered file.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "recovered" --path ".tokens.totals.input")
assert_equals "$out" "1000" "bump-tokens lands the input count after degraded-init recovery"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "recovered" --path ".tokens.per_pr[\"999\"].input")
assert_equals "$out" "1000" "bump-tokens lands the per_pr bucket after degraded-init recovery"

# Without --allow-degraded-init, a missing file still exits 3 (unchanged
# behaviour for callers that explicitly want strict semantics).
SHIPYARD_HOME="$tmphome" bash "$helper" cleanup --session-id "recovered" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "recovered" --input 100 --mode issue-work --model claude-opus-4-7 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=3" "bump-tokens without --allow-degraded-init on missing file still exits 3"

# --allow-degraded-init without --degraded-init-repo falls back to
# "unknown/unknown" (data still lands; better to keep than error out
# on a missing optional metadata field).
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "no-repo" --input 500 --output 200 \
  --mode issue-work --model claude-opus-4-7 \
  --allow-degraded-init 2>/dev/null
rc=$?
assert_equals "$rc" "0" "bump-tokens --allow-degraded-init without --degraded-init-repo still succeeds"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "no-repo" --path ".repo")
assert_equals "$out" "unknown/unknown" "missing --degraded-init-repo falls back to unknown/unknown sentinel"

# A subsequent bump on a recovered file should NOT re-trigger recovery —
# it should just accumulate normally.
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "no-repo" --input 250 \
  --mode issue-work --model claude-opus-4-7 \
  --allow-degraded-init 2>/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "no-repo" --path ".tokens.totals.input")
assert_equals "$out" "750" "bump on a recovered file accumulates normally (no double-init)"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== bump-tokens — degraded-total-only fallback (issue #279)"
# --------------------------------------------------------------------------
# Harness-side gap workaround for #279: when the Claude Code sub-agent
# task-notification <usage> block only emits `total_tokens` (no
# input/output/cache breakdown), the orchestrator's A.0 attribution
# can't pass the four required counts. With --degraded-total-only,
# callers pass `--input <total_tokens>`, the bump lands in the input
# bucket, and the per_invocation entry is stamped degraded:true so
# the end-of-session summary can surface a banner. The session-level
# .tokens.degraded_attribution_count increments per degraded bump.

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "tok-degraded" --repo "o/r" >/dev/null

# Mix one normal bump and one degraded bump on the same PR — they
# should accumulate into totals/per_pr just like normal bumps, but
# the degraded counter should only count the degraded ones.
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-degraded" \
  --issue 279 --pr 285 \
  --input 1000 --output 500 \
  --cache-read 200 --cache-creation 100 \
  --mode issue-work --model claude-opus-4-7 >/dev/null

SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-degraded" \
  --issue 279 --pr 285 \
  --input 86413 \
  --mode issue-work --model claude-opus-4-7 \
  --degraded-total-only >/dev/null

# Totals accumulated across both bumps (totals don't care about degraded).
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-degraded" --path ".tokens.totals.input")
assert_equals "$out" "87413" "degraded bump accumulates --input into totals.input alongside normal bumps"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-degraded" --path ".tokens.totals.output")
assert_equals "$out" "500" "degraded bump does NOT touch totals.output (zero contribution)"

# Per_pr also accumulated.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-degraded" --path ".tokens.per_pr[\"285\"].input")
assert_equals "$out" "87413" "degraded bump accumulates --input into per_pr bucket"

# Per_invocation: first entry degraded=false, second degraded=true.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-degraded" --path ".tokens.per_invocation[0].degraded")
assert_equals "$out" "false" "normal bump stamps per_invocation[0].degraded = false"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-degraded" --path ".tokens.per_invocation[1].degraded")
assert_equals "$out" "true" "degraded bump stamps per_invocation[1].degraded = true"

# Session-level degraded counter — only the degraded bump incremented it.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-degraded" --path ".tokens.degraded_attribution_count")
assert_equals "$out" "1" "degraded_attribution_count increments by 1 per degraded bump"

# A second degraded bump should bring the counter to 2.
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-degraded" \
  --input 12345 \
  --mode issue-work --model claude-opus-4-7 \
  --degraded-total-only >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-degraded" --path ".tokens.degraded_attribution_count")
assert_equals "$out" "2" "second degraded bump increments degraded_attribution_count to 2"

# Usage error: --degraded-total-only is mutually exclusive with non-zero
# --output / --cache-read / --cache-creation. Reject with exit 64 rather
# than silently mixing strict + degraded attribution.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-degraded" \
  --input 1000 --output 500 \
  --mode issue-work --model claude-opus-4-7 \
  --degraded-total-only 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "--degraded-total-only with non-zero --output is rejected (exit 64)"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-degraded" \
  --input 1000 --cache-read 100 \
  --mode issue-work --model claude-opus-4-7 \
  --degraded-total-only 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "--degraded-total-only with non-zero --cache-read is rejected (exit 64)"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-degraded" \
  --input 1000 --cache-creation 100 \
  --mode issue-work --model claude-opus-4-7 \
  --degraded-total-only 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "--degraded-total-only with non-zero --cache-creation is rejected (exit 64)"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== bump-tokens — --degraded-total-only composes with --allow-degraded-init"
# --------------------------------------------------------------------------
# The two degraded flags address different failure modes (#253 file-
# disappear vs. #279 harness-side gap) and should compose cleanly when
# both are present. Verify a degraded-total-only bump against a missing
# session file works end-to-end.

tmphome=$(mktmphome)

SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "both-degraded" \
  --issue 279 --pr 285 \
  --input 86413 \
  --mode issue-work --model claude-opus-4-7 \
  --allow-degraded-init --degraded-init-repo "o/r" \
  --degraded-total-only 2>/dev/null
rc=$?
assert_equals "$rc" "0" "--degraded-total-only + --allow-degraded-init compose on missing file"

# .degraded_recovery_at stamped (from --allow-degraded-init path).
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "both-degraded" --path ".degraded_recovery_at")
if [[ -n "$out" ]] && [[ "$out" != "null" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" ".degraded_recovery_at still stamped on file-disappear path"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s (got: %s)\n' "$RED" "$RESET" ".degraded_recovery_at still stamped on file-disappear path" "$out"
  fail=$((fail+1))
fi

# degraded_attribution_count incremented (from --degraded-total-only path).
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "both-degraded" --path ".tokens.degraded_attribution_count")
assert_equals "$out" "1" "degraded_attribution_count still increments on composed path"

# Per_invocation entry stamped degraded=true.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "both-degraded" --path ".tokens.per_invocation[0].degraded")
assert_equals "$out" "true" "per_invocation entry stamped degraded=true on composed path"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== update — degraded-init recovery (issue #281)"
# --------------------------------------------------------------------------
# Issue #281: cmd_update exited 3 with no recovery when the session file
# disappeared mid-session (e.g. a concurrent /do-work session's orphan-
# sweep reaping our file). cmd_bump_tokens had carried --allow-degraded-
# init since #253; this test asserts the same recovery path now exists
# for update. State from before the disappear is lost, but every update
# from the disappear forward lands somewhere durable.

tmphome=$(mktmphome)

# Don't init first — simulate post-reap state. Without --allow-degraded-init
# update exits 3 (preserved default behaviour).
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" update \
  --session-id "281-recovery" --set '.drain.active = true' 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=3" "update without --allow-degraded-init on missing file exits 3 (preserved)"

# With --allow-degraded-init, the file gets recreated and the update applies.
SHIPYARD_HOME="$tmphome" bash "$helper" update \
  --session-id "281-recovery" \
  --set '.drain.active = true' \
  --allow-degraded-init --degraded-init-repo "owner/repo" 2>/dev/null
rc=$?
assert_equals "$rc" "0" "update with --allow-degraded-init succeeds when file is missing"

# File was auto-created.
assert_file_exists "$tmphome/sessions/281-recovery.json" "update --allow-degraded-init creates the session file"

# .degraded_recovery_at is set (audit/metrics signal).
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "281-recovery" --path ".degraded_recovery_at")
if [[ -n "$out" ]] && [[ "$out" != "null" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" ".degraded_recovery_at stamped on update-recovery init"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s (got: %s)\n' "$RED" "$RESET" ".degraded_recovery_at stamped on update-recovery init" "$out"
  fail=$((fail+1))
fi

# .repo persists from --degraded-init-repo.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "281-recovery" --path ".repo")
assert_equals "$out" "owner/repo" "update --degraded-init-repo persists into .repo"

# The --set expression actually landed.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "281-recovery" --path ".drain.active")
assert_equals "$out" "true" "update --set landed after degraded-init recovery"

# Missing --degraded-init-repo falls back to "unknown/unknown" sentinel.
SHIPYARD_HOME="$tmphome" bash "$helper" update \
  --session-id "281-no-repo" \
  --set '.in_flight = {}' \
  --allow-degraded-init 2>/dev/null
rc=$?
assert_equals "$rc" "0" "update --allow-degraded-init without --degraded-init-repo still succeeds"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "281-no-repo" --path ".repo")
assert_equals "$out" "unknown/unknown" "missing --degraded-init-repo falls back to unknown/unknown sentinel"

# Subsequent update on a recovered file should NOT re-trigger init; it just
# updates. Verify by setting a field and checking it persists across writes
# without resetting other fields.
SHIPYARD_HOME="$tmphome" bash "$helper" update \
  --session-id "281-recovery" \
  --set '.drain.polls = 5' \
  --allow-degraded-init 2>/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "281-recovery" --path ".drain.polls")
assert_equals "$out" "5" "second update on recovered file applies normally (no re-init)"
# .drain.active set in first update should still be true (not reset by re-init).
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "281-recovery" --path ".drain.active")
assert_equals "$out" "true" "first-update .drain.active survives second update (no re-init)"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== cleanup --reap-audit (issue #281)"
# --------------------------------------------------------------------------
# Acceptance criterion 2 from #281: 'an audit-log entry exists for every
# reap, with enough information to reconstruct cause.' The setup.md step
# 1.6 orphan-sweep now calls cleanup --reap-audit --reaper-session-id <id>
# so each session-file reap appends one JSONL line to
# ~/.shipyard/reap-audit.jsonl with the reaped session's metadata + the
# reaper's session-id and pid.

tmphome=$(mktmphome)

# Stand up a session to be reaped. Bump some tokens so .tokens.totals
# is non-zero — the audit line should capture them.
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "victim" --repo "victim/repo" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "victim" --input 10000 --output 5000 --cache-read 2000 \
  --mode issue-work --model claude-opus-4-7 >/dev/null

# Reap with --reap-audit. The audit log lands in $SHIPYARD_HOME/reap-audit.jsonl.
SHIPYARD_HOME="$tmphome" bash "$helper" cleanup \
  --session-id "victim" \
  --reap-audit \
  --reaper-session-id "reaper-281" \
  --reaper-pid "12345" \
  --reason "orphan-sweep-step-1.6" \
  --phase "setup-1.6" 2>/dev/null
rc=$?
assert_equals "$rc" "0" "cleanup --reap-audit exits 0"

# Victim file is gone.
if [[ -f "$tmphome/sessions/victim.json" ]]; then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "cleanup --reap-audit removes the reaped session file"
  fail=$((fail+1))
else
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "cleanup --reap-audit removes the reaped session file"
  pass=$((pass+1))
fi

# Audit log was written.
audit_log="$tmphome/reap-audit.jsonl"
assert_file_exists "$audit_log" "cleanup --reap-audit writes the audit-log file"

# One JSONL line written (audit log is append-only).
line_count=$(wc -l <"$audit_log" | tr -d ' ')
assert_equals "$line_count" "1" "exactly one audit-log line written per reap"

# Audit line contains the load-bearing fields. Parse with jq and check
# each one rather than substring-matching the raw line.
audit_line=$(cat "$audit_log")
out=$(printf '%s' "$audit_line" | jq -r '.action')
assert_equals "$out" "reaped-session-file" "audit line action = reaped-session-file"
out=$(printf '%s' "$audit_line" | jq -r '.reaped_session_id')
assert_equals "$out" "victim" "audit line carries reaped_session_id"
out=$(printf '%s' "$audit_line" | jq -r '.reaper_session_id')
assert_equals "$out" "reaper-281" "audit line carries reaper_session_id"
out=$(printf '%s' "$audit_line" | jq -r '.reaper_pid')
assert_equals "$out" "12345" "audit line carries reaper_pid"
out=$(printf '%s' "$audit_line" | jq -r '.reaped_repo')
assert_equals "$out" "victim/repo" "audit line captures the reaped session's repo"
out=$(printf '%s' "$audit_line" | jq -r '.reaped_tokens_totals.input')
assert_equals "$out" "10000" "audit line captures reaped_tokens_totals.input (loss attribution)"
out=$(printf '%s' "$audit_line" | jq -r '.reaped_tokens_totals.output')
assert_equals "$out" "5000" "audit line captures reaped_tokens_totals.output"
out=$(printf '%s' "$audit_line" | jq -r '.reason')
assert_equals "$out" "orphan-sweep-step-1.6" "audit line carries reason"
out=$(printf '%s' "$audit_line" | jq -r '.phase')
assert_equals "$out" "setup-1.6" "audit line carries phase"

# reaped_pid should be a number (the session's PPID at init time), not null.
out=$(printf '%s' "$audit_line" | jq -r '.reaped_pid | type')
assert_equals "$out" "number" "audit line carries reaped_pid as a number"

# Usage error: --reap-audit without --reaper-session-id is rejected.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "victim2" --repo "v/r" >/dev/null 2>&1
SHIPYARD_HOME="$tmphome" bash "$helper" cleanup \
  --session-id "victim2" --reap-audit 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "--reap-audit without --reaper-session-id exits 64"

# Cleanup without --reap-audit does NOT write to the audit log.
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "self-cleanup" --repo "s/r" >/dev/null
prev_lines=$(wc -l <"$audit_log" | tr -d ' ')
SHIPYARD_HOME="$tmphome" bash "$helper" cleanup --session-id "self-cleanup" 2>/dev/null
curr_lines=$(wc -l <"$audit_log" | tr -d ' ')
assert_equals "$curr_lines" "$prev_lines" "cleanup without --reap-audit does not write audit-log line"

# Idempotency: cleaning up an already-gone session with --reap-audit is a no-op
# (no audit line, no error). Matches the existing cleanup contract.
SHIPYARD_HOME="$tmphome" bash "$helper" cleanup \
  --session-id "already-gone" \
  --reap-audit --reaper-session-id "reaper-281" 2>/dev/null
rc=$?
assert_equals "$rc" "0" "cleanup --reap-audit on missing file is idempotent (exit 0)"
final_lines=$(wc -l <"$audit_log" | tr -d ' ')
assert_equals "$final_lines" "$prev_lines" "cleanup --reap-audit on missing file does not write audit line"

rm -rf "$tmphome"

echo
echo "Results: ${GREEN}${pass} passed${RESET}, ${RED}${fail} failed${RESET}"
[[ $fail -eq 0 ]]
