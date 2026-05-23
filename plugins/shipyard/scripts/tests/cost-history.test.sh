#!/usr/bin/env bash
# Test suite for scripts/cost-history.sh.
#
# Covers the five subcommands the orchestrator and the /shipyard:cost
# command drive:
#
#   flush   — read a session-state.sh session file and append to
#             $SHIPYARD_HOME/cost-history.jsonl plus one record per
#             touched issue to cost-history-issues.jsonl. Idempotent.
#   report  — aggregate the ledgers and project markdown / csv / json.
#   reset   — destructively move ledger files to .bak.<ts>.
#   export  — bundle ledger files into a tarball.
#   read    — emit raw jsonl on stdout (for tests + downstream tools).
#
# Pure bash + jq. Run with:
#
#   bash plugins/shipyard/scripts/tests/cost-history.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../cost-history.sh"
session_helper="${here}/../session-state.sh"

if [[ ! -f "$helper" ]]; then
  echo "FAIL: helper not found at $helper" >&2
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

# Each test gets a private SHIPYARD_HOME so the suite never touches the
# real ~/.shipyard.
mktmphome() {
  mktemp -d
}

# Helper: seed a session file with realistic per-issue / per-mode tokens.
# Returns the SHIPYARD_HOME path on stdout.
seed_session() {
  local home="$1"
  local session_id="$2"
  local repo="${3:-owner/repo}"

  SHIPYARD_HOME="$home" bash "$session_helper" init \
    --session-id "$session_id" --repo "$repo" >/dev/null
  SHIPYARD_HOME="$home" bash "$session_helper" bump-tokens \
    --session-id "$session_id" \
    --issue 142 --pr 200 \
    --input 10000 --output 2000 --cache-read 5000 \
    --mode issue-work --model claude-opus-4-7 >/dev/null
  SHIPYARD_HOME="$home" bash "$session_helper" bump-tokens \
    --session-id "$session_id" \
    --issue 143 \
    --input 5000 --output 1000 \
    --mode fix-checks-only --model claude-haiku-4-5 >/dev/null
}

# --------------------------------------------------------------------------
echo "== flush — append session + issue records"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "s1"

SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "s1" >/dev/null

assert_file_exists "$tmphome/cost-history.jsonl" \
  "flush creates cost-history.jsonl"
assert_file_exists "$tmphome/cost-history-issues.jsonl" \
  "flush creates cost-history-issues.jsonl"

# One session line.
lines=$(wc -l < "$tmphome/cost-history.jsonl" | tr -d ' ')
assert_equals "$lines" "1" "flush writes exactly one session record"

# Two issue lines (issues 142 and 143).
lines=$(wc -l < "$tmphome/cost-history-issues.jsonl" | tr -d ' ')
assert_equals "$lines" "2" "flush writes one issue record per touched issue"

# Session record carries the expected fields.
content=$(cat "$tmphome/cost-history.jsonl")
assert_contains "$content" '"session_id":"s1"' \
  "session record carries session_id"
assert_contains "$content" '"repo":"owner/repo"' \
  "session record carries repo"
assert_contains "$content" '"issues_worked":[142,143]' \
  "session record carries issues_worked (sorted)"
assert_contains "$content" '"prs_created":[200]' \
  "session record carries prs_created"
assert_contains "$content" '"by_model"' \
  "session record carries by_model rollup"
assert_contains "$content" '"by_mode"' \
  "session record carries by_mode rollup"

# Issue record carries the expected fields.
content=$(cat "$tmphome/cost-history-issues.jsonl")
assert_contains "$content" '"issue_number":142' \
  "issue ledger carries issue 142"
assert_contains "$content" '"issue_number":143' \
  "issue ledger carries issue 143"
assert_contains "$content" '"pr":200' \
  "issue ledger carries linked PR for issue 142"
assert_contains "$content" '"modes_used":["issue-work"]' \
  "issue ledger carries modes_used"
assert_contains "$content" '"models_used":["claude-opus-4-7"]' \
  "issue ledger carries models_used"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== flush — idempotent (same session id is not double-appended)"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "idem"

SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "idem" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "idem" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "idem" >/dev/null

lines=$(wc -l < "$tmphome/cost-history.jsonl" | tr -d ' ')
assert_equals "$lines" "1" "re-flushing the same session id is idempotent"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== flush — missing session file is a no-op (exit 0)"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "missing" >/dev/null
rc=$?
assert_equals "$rc" "0" "flush of missing session exits 0 (no-op)"
assert_file_missing "$tmphome/cost-history.jsonl" \
  "flush of missing session does not create the ledger"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== flush --dry-run prints records but does not append"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "dry"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "dry" --dry-run)

assert_contains "$out" '"session_id":"dry"' \
  "--dry-run emits the session record on stdout"
assert_contains "$out" '"issue_number":142' \
  "--dry-run emits the issue records on stdout"
assert_file_missing "$tmphome/cost-history.jsonl" \
  "--dry-run does not create cost-history.jsonl"
assert_file_missing "$tmphome/cost-history-issues.jsonl" \
  "--dry-run does not create cost-history-issues.jsonl"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== flush — multiple sessions accumulate"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "ma" "owner/repo-a"
seed_session "$tmphome" "mb" "owner/repo-b"

SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "ma" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "mb" >/dev/null

lines=$(wc -l < "$tmphome/cost-history.jsonl" | tr -d ' ')
assert_equals "$lines" "2" "two distinct sessions = two ledger lines"

lines=$(wc -l < "$tmphome/cost-history-issues.jsonl" | tr -d ' ')
assert_equals "$lines" "4" "two sessions with 2 issues each = 4 issue lines"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== report — empty ledger short-circuits gracefully"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" report)
assert_contains "$out" "No shipyard sessions recorded" \
  "empty-ledger report prints the empty-state helper line"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" report --format csv)
assert_contains "$out" "session_id,repo,started_at" \
  "empty-ledger csv emits the header row"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" report --format json)
assert_contains "$out" '"sessions": []' \
  "empty-ledger json emits an empty sessions array"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== report — markdown TOTALS"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "rpt1"
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "rpt1" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" report --last all)

assert_contains "$out" "Shipyard cost" \
  "report markdown header present"
assert_contains "$out" "TOTALS" \
  "report markdown TOTALS section present"
assert_contains "$out" "Sessions:        1" \
  "TOTALS shows 1 session"
assert_contains "$out" "Issues worked:   2" \
  "TOTALS shows 2 issues worked"
assert_contains "$out" "PRs created:     1" \
  "TOTALS shows 1 PR created"
assert_contains "$out" "Want more detail" \
  "report footer hint present"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== report — by-model + by-mode + by-issue + trend"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "rpt2"
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "rpt2" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" report \
  --last all --by-model --by-mode --by-issue --trend --top 5)

assert_contains "$out" "BY MODEL" \
  "--by-model emits BY MODEL section"
assert_contains "$out" "claude-opus-4-7" \
  "BY MODEL shows opus rollup"
assert_contains "$out" "BY MODE" \
  "--by-mode emits BY MODE section"
assert_contains "$out" "issue-work" \
  "BY MODE shows issue-work bucket"
assert_contains "$out" "TOP 5 MOST EXPENSIVE ISSUES" \
  "--top emits TOP N MOST EXPENSIVE ISSUES section"
assert_contains "$out" "#142" \
  "TOP N section lists issue 142"
assert_contains "$out" "TREND (weekly)" \
  "--trend emits TREND section"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== report — --repo filters"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "rf-a" "owner/repo-a"
seed_session "$tmphome" "rf-b" "owner/repo-b"
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "rf-a" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "rf-b" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" report --last all --repo "owner/repo-a" --format json)
sessions=$(printf '%s' "$out" | jq -r '.rollup.sessions')
assert_equals "$sessions" "1" "--repo filter narrows to one session"

repos_in_out=$(printf '%s' "$out" | jq -r '.sessions[].repo' | sort | uniq | tr '\n' ',')
assert_equals "$repos_in_out" "owner/repo-a," "--repo filter excludes other repos"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== report — --format csv"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "csv1"
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "csv1" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" report --last all --format csv)

assert_contains "$out" "session_id,repo,started_at,ended_at,duration_seconds,total_tokens,estimated_usd" \
  "csv emits the header row"
assert_contains "$out" '"csv1"' \
  "csv body contains the session id"
assert_contains "$out" '"owner/repo"' \
  "csv body contains the repo"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== report — --format json"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "j1"
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "j1" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" report --last all --format json)

# Valid JSON.
echo "$out" | jq empty 2>/dev/null
rc=$?
assert_equals "$rc" "0" "json report is valid JSON"

# Shape checks.
range=$(echo "$out" | jq -r '.range.last')
assert_equals "$range" "all" "json carries range.last"

sessions=$(echo "$out" | jq -r '.rollup.sessions')
assert_equals "$sessions" "1" "json rollup.sessions = 1"

estimated_usd=$(echo "$out" | jq -r '.rollup.estimated_usd > 0')
assert_equals "$estimated_usd" "true" "json rollup.estimated_usd > 0"

issues=$(echo "$out" | jq -r '.issues | length')
assert_equals "$issues" "2" "json issues array has 2 entries"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== report — --last cutoff filters old sessions"
# --------------------------------------------------------------------------
# Construct a ledger with one old session (1970 timestamp) and one fresh
# session; verify --last 30d drops the old one and --last all keeps both.

tmphome=$(mktmphome)
mkdir -p "$tmphome"
# Hand-write a fake old session line (the flush path always uses `now`
# for ended_at; for this test we need a controllable started_at).
cat > "$tmphome/cost-history.jsonl" <<'EOF'
{"session_id":"old-1970","repo":"owner/old","started_at":"1970-06-01T00:00:00Z","ended_at":"1970-06-01T00:01:00Z","duration_seconds":60,"issues_worked":[1],"prs_created":[],"tokens":{"input":100,"output":50,"cache_read":0,"cache_creation":0},"estimated_usd":0.001,"by_model":{},"by_mode":{}}
EOF
seed_session "$tmphome" "fresh"
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "fresh" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" report --last 30d --format json)
n=$(echo "$out" | jq -r '.rollup.sessions')
assert_equals "$n" "1" "--last 30d filters out 1970 sessions"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" report --last all --format json)
n=$(echo "$out" | jq -r '.rollup.sessions')
assert_equals "$n" "2" "--last all keeps both sessions"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== read — emit raw jsonl"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "rd"
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "rd" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read)
assert_contains "$out" '"session_id":"rd"' "read --ledger sessions (default) emits jsonl"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --ledger issues)
assert_contains "$out" '"issue_number":142' "read --ledger issues emits issues jsonl"

# Missing ledger → exit 3.
rm "$tmphome/cost-history.jsonl"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=3" "read of missing ledger exits 3"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== reset — moves files to .bak.<ts>"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "rst"
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "rst" >/dev/null

SHIPYARD_HOME="$tmphome" bash "$helper" reset --yes 2>/dev/null

assert_file_missing "$tmphome/cost-history.jsonl" \
  "reset removes cost-history.jsonl"
assert_file_missing "$tmphome/cost-history-issues.jsonl" \
  "reset removes cost-history-issues.jsonl"

# .bak.<ts> files exist.
bak_count=0
shopt -s nullglob
# shellcheck disable=SC2034
# rationale: `f` is the loop variable; only the count of iterations
# matters here, not the value. The `# shellcheck` comment is the
# documented suppression for SC2034 in this idiom.
for f in "$tmphome/"cost-history*.bak.*; do
  bak_count=$((bak_count + 1))
done
shopt -u nullglob
assert_equals "$bak_count" "2" "reset moves both files to .bak.<ts>"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== reset — without --yes prompts (decline = exit 70)"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "noyes"
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "noyes" >/dev/null

# Pipe "n" to reject the prompt.
out=$(printf 'n\n' | SHIPYARD_HOME="$tmphome" bash "$helper" reset 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=70" "reset declined at prompt exits 70"
assert_file_exists "$tmphome/cost-history.jsonl" \
  "reset declined leaves cost-history.jsonl in place"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== export — tarball both ledger files"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "ex"
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "ex" >/dev/null

target="$tmphome/backup.tar.gz"
SHIPYARD_HOME="$tmphome" bash "$helper" export --to "$target" 2>/dev/null

assert_file_exists "$target" "export writes the tarball"

# Inspect the tarball — both ledger files inside.
contents=$(tar -tzf "$target" | sort | tr '\n' ',')
assert_equals "$contents" "cost-history-issues.jsonl,cost-history.jsonl," \
  "tarball contains both ledger files"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== flush — auto-flushes pending setup-timing sidecar (issue #283)"
# --------------------------------------------------------------------------
# Regression test for the bug described in #283: the orchestrator records
# per-phase timing data into a sidecar (`<session>.timing.json`) but the
# explicit `setup-timing.sh flush` at step 6.8 is structurally easy to
# skip (long-step embedding, fire-and-forget posture, C=1 skip-list
# misread). When skipped, the session-state file's `.setup` block stays
# null and the cross-session ledger record we write here loses the data.
# The fix: `cost-history.sh flush` opportunistically calls
# `setup-timing.sh flush` BEFORE reading `.setup`, so a pending sidecar
# is always materialized before the ledger record snapshots it.

tmphome=$(mktemp -d)
sid="autoflush-${BASHPID:-$$}"

# 1. Init session, record phase timing into the sidecar, but DELIBERATELY
#    do NOT call `setup-timing.sh flush` — this is the bug scenario.
SHIPYARD_HOME="$tmphome" bash "$session_helper" init \
  --session-id "$sid" --repo "test/repo" >/dev/null

setup_timing_helper="${here}/../setup-timing.sh"
SHIPYARD_HOME="$tmphome" bash "$setup_timing_helper" start \
  --session-id "$sid" --phase step_0_5_worktree 2>/dev/null
sleep 1
SHIPYARD_HOME="$tmphome" bash "$setup_timing_helper" end \
  --session-id "$sid" --phase step_0_5_worktree 2>/dev/null

# Pre-flush sanity: the sidecar exists, but .setup is still null.
sidecar="${tmphome}/sessions/${sid}.timing.json"
assert_file_exists "$sidecar" "autoflush: sidecar present before cost-history flush"

pre_setup=$(SHIPYARD_HOME="$tmphome" bash "$session_helper" read \
  --session-id "$sid" --path '.setup')
assert_equals "$pre_setup" "null" \
  "autoflush: .setup is null in session state before cost-history flush"

# 2. Run cost-history flush. Auto-flush hook should materialize .setup.
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "$sid"
assert_equals "$?" "0" "autoflush: cost-history flush exits 0"

# 3. The ledger record must carry the per-phase setup data — NOT null.
ledger="${tmphome}/cost-history.jsonl"
assert_file_exists "$ledger" "autoflush: ledger file written"

setup_in_record=$(jq -c '.setup' "$ledger")
if [[ "$setup_in_record" != "null" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" \
    "autoflush: ledger record .setup is NOT null after cost-history flush"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" \
    "autoflush: ledger record .setup is NOT null after cost-history flush"
  printf '    actual: %s\n' "$setup_in_record"
  fail=$((fail+1))
fi

# Must carry the phase we recorded.
phase_seconds=$(jq -r '.setup.phases.step_0_5_worktree' "$ledger")
if [[ "$phase_seconds" =~ ^[0-9]+$ ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" \
    "autoflush: ledger record carries step_0_5_worktree phase duration"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" \
    "autoflush: ledger record carries step_0_5_worktree phase duration"
  printf '    actual: %s\n' "$phase_seconds"
  fail=$((fail+1))
fi

# 4. Sidecar should be cleaned up by the auto-flush.
if [[ ! -e "$sidecar" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" \
    "autoflush: sidecar cleaned up after cost-history flush"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" \
    "autoflush: sidecar cleaned up after cost-history flush"
  fail=$((fail+1))
fi

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== flush — no sidecar present is still a clean no-op"
# --------------------------------------------------------------------------
# Make sure the auto-flush hook doesn't error when there's nothing to
# flush. Normal sessions where the explicit flush DID run reach
# cost-history flush with no sidecar present — the auto-flush call must
# be a clean no-op in that case.

tmphome=$(mktemp -d)
sid="autoflush-nosidecar-${BASHPID:-$$}"

SHIPYARD_HOME="$tmphome" bash "$session_helper" init \
  --session-id "$sid" --repo "test/repo" >/dev/null

# Run cost-history flush with no sidecar — should succeed cleanly.
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "$sid"
assert_equals "$?" "0" \
  "autoflush: cost-history flush exits 0 when no sidecar present"

# Ledger record should still be written (with .setup as null since
# nothing was ever recorded).
ledger="${tmphome}/cost-history.jsonl"
assert_file_exists "$ledger" \
  "autoflush: ledger record written even with no sidecar"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== usage — unknown subcommand / missing args"
# --------------------------------------------------------------------------

out=$(bash "$helper" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "no subcommand exits 64"

out=$(bash "$helper" frobnicate 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "unknown subcommand exits 64"

out=$(bash "$helper" flush 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "flush without --session-id exits 64"

out=$(bash "$helper" export 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "export without --to exits 64"

out=$(bash "$helper" report --format yaml 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "report with unsupported format exits 64"

out=$(bash "$helper" report --last 5x 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "report --last with bad value exits 64"

# --------------------------------------------------------------------------
echo
echo "== Summary"
echo "  $pass passed, $fail failed"

if [[ $fail -gt 0 ]]; then
  exit 1
fi
exit 0
