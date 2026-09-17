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

# Isolate every bump-tokens call in this suite from THIS repo's own committed
# shipyard.config.json by default. bump-tokens' mode/model policy-consistency
# check (#978) reads models.<mode> from the merged config, resolving the repo
# layer via `git rev-parse --show-toplevel` from cwd unless SHIPYARD_REPO_ROOT
# overrides it — and this suite runs from inside the shipyard repo's own
# worktree, whose committed shipyard.config.json sets `models.issue_work`.
# Without this default, every pre-existing `--mode issue-work` fixture in this
# file (none of which are testing model policy — they're testing token math,
# degraded-init, the cross-repo guard, etc.) would trip a spurious mismatch
# warning that has nothing to do with what it's actually testing. The
# dedicated "mode/model policy-consistency" section below overrides this
# per-call with its own tmp repo root when it needs a real configured value.
sessionstate_repo_root_isolation=$(mktemp -d)
export SHIPYARD_REPO_ROOT="$sessionstate_repo_root_isolation"
trap 'rm -rf "$sessionstate_repo_root_isolation"' EXIT

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
assert_contains "$content" '"awaiting_external": []' "awaiting_external initialised to empty array (#1390)"
assert_contains "$content" '"session_prs": []' "session_prs initialised to empty array"
assert_contains "$content" '"deferred_issues": []' "deferred_issues initialised to empty array"
assert_contains "$content" '"raw_backlog": []' "raw_backlog initialised to empty array"
# unfiltered_open_count / me_assigned_open / last_fresh_fetch (issue #1246)
# -- the backlog-eligibility-filter divergence-smell invariant-line tokens.
# Asserted directly against the written state file (not prose) so a future
# regression that drops these fields from the init template fails loudly
# here instead of silently reproducing #1246's "never implemented" bug.
assert_contains "$content" '"unfiltered_open_count": 0' "unfiltered_open_count initialised to 0 (#1246)"
assert_contains "$content" '"me_assigned_open": 0' "me_assigned_open initialised to 0 (#1246)"
assert_contains "$content" '"last_fresh_fetch": null' "last_fresh_fetch initialised to null (#1246)"
assert_contains "$content" '"main_ci"' "main_ci block initialised"
assert_contains "$content" '"started_at"' "started_at timestamp present"
# session_end (issue #1252) — null until record-session-end stamps a
# terminal reason. Asserted directly here (not just where it's written)
# so a future regression that drops it from the init template fails at
# the source rather than only where it's later read back.
assert_contains "$content" '"session_end": null' "session_end initialised to null (#1252)"
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
echo "== update — unfiltered_open_count / me_assigned_open / last_fresh_fetch (issue #1246)"
# --------------------------------------------------------------------------
# These three fields are set via the generic `update --set` mechanism --
# there is no dedicated flag -- so this proves the schema slots added to
# the init template round-trip correctly through an ordinary --set write,
# the same call shape drain.md's termination step 4 and steady-state.md
# step C use to stamp them from a fresh backlog-filter.sh summary read.

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "inv1" --repo "o/r" >/dev/null

SHIPYARD_HOME="$tmphome" bash "$helper" update --session-id "inv1" \
  --set '.unfiltered_open_count = 29' \
  --set '.me_assigned_open = 16' \
  --set '.last_fresh_fetch = "14:02:07"' >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "inv1" --path ".unfiltered_open_count")
assert_equals "$out" "29" "update --set persists unfiltered_open_count (#1246)"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "inv1" --path ".me_assigned_open")
assert_equals "$out" "16" "update --set persists me_assigned_open (#1246)"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "inv1" --path ".last_fresh_fetch")
assert_equals "$out" "14:02:07" "update --set persists last_fresh_fetch (#1246)"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== update — atomic_write empty-tempfile guard (issue #357)"
# --------------------------------------------------------------------------
# Regression for the 0-byte truncation bug. Prior to the fix, a jq
# compile error inside `update`'s pipeline would produce no stdout, the
# atomic_write helper would still create an empty tempfile via `cat > tmp`
# and atomically rename it over the target. Result: the session JSON
# was silently truncated to 0 bytes, the caller saw exit 0, and every
# downstream consumer (cost-history flush, read-tokens, /shipyard:status)
# silently saw nothing for the rest of the session. The fix: atomic_write
# refuses to rename a 0-byte tempfile, returning non-zero so the caller's
# existing `if ! jq ... | atomic_write` branch fires.

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "atomic-guard" --repo "o/r" --concurrency 7 >/dev/null
session_file="$tmphome/sessions/atomic-guard.json"

# Capture the pre-bad-update content for a byte-for-byte preservation check.
SHIPYARD_HOME="$tmphome" bash "$helper" update --session-id "atomic-guard" \
  --set '.session_prs = [1, 2, 3]' >/dev/null
pre_size=$(wc -c < "$session_file" | tr -d ' ')
pre_concurrency=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "atomic-guard" --path '.concurrency')
pre_prs=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "atomic-guard" --path '.session_prs')

# Run an update with a deliberately invalid jq expression. jq will compile-
# error and produce no stdout. The atomic_write empty-tempfile guard should
# refuse the rename and the caller should report failure.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" update --session-id "atomic-guard" \
  --set '.in_flight.slot1 = this_is_not_a_valid_jq_identifier' 2>&1; echo "rc=$?")
rc=$(printf '%s\n' "$out" | tail -1)
assert_equals "$rc" "rc=68" "update with bad jq expression exits 68"
assert_contains "$out" "file left unchanged" "update with bad jq surfaces 'file left unchanged' to stderr"

# The session file MUST still be present, non-empty, and carry its prior
# content. Before the fix all three of these checks failed (file was 0
# bytes and unparseable).
assert_file_exists "$session_file" "session file still present after failed update"
post_size=$(wc -c < "$session_file" | tr -d ' ')
assert_equals "$post_size" "$pre_size" "session file size unchanged after failed update (no 0-byte truncation)"

post_concurrency=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "atomic-guard" --path '.concurrency')
assert_equals "$post_concurrency" "$pre_concurrency" "session file's .concurrency preserved through failed update"
post_prs=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "atomic-guard" --path '.session_prs')
assert_equals "$post_prs" "$pre_prs" "session file's .session_prs preserved through failed update"

# A subsequent VALID update must still succeed (the guard doesn't poison
# future writes — only the corrupting write is rejected).
SHIPYARD_HOME="$tmphome" bash "$helper" update --session-id "atomic-guard" \
  --set '.session_prs += [4]' >/dev/null
post_recovery=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "atomic-guard" --path '.session_prs | length')
assert_equals "$post_recovery" "4" "valid update after failed update still lands correctly"

# No leaked tempfiles after the failed write — atomic_write's cleanup
# trap must run in the error path too.
leftover=""
shopt -s nullglob
for f in "$tmphome/sessions/"*; do
  case "$(basename "$f")" in
    atomic-guard.json) ;;
    *) leftover="$leftover $(basename "$f")" ;;
  esac
done
shopt -u nullglob
assert_equals "${leftover# }" "" "failed update does not leak .tmp files"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== update — degraded-init recovery preserves on subsequent failure (issue #357)"
# --------------------------------------------------------------------------
# The original failure mode in #357 was specifically the
# --allow-degraded-init path: when an `update` raced with a sweep and the
# file disappeared, the recovery init created a minimal file and then the
# subsequent jq pipeline could fail, truncating the just-recovered file
# back to 0 bytes. The empty-tempfile guard in atomic_write must hold
# through this path too — the recovered base init should survive a
# failing follow-up update inside the same `update` invocation.

tmphome=$(mktmphome)
session_file="$tmphome/sessions/degraded-guard.json"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" update --session-id "degraded-guard" \
  --allow-degraded-init --degraded-init-repo "owner/recovered" \
  --set '.in_flight.x = invalid_jq_garbage' 2>&1; echo "rc=$?")
rc=$(printf '%s\n' "$out" | tail -1)
assert_equals "$rc" "rc=68" "update --allow-degraded-init with bad jq exits 68 (post-recovery failure surfaced)"
assert_file_exists "$session_file" "degraded-init recovered file is NOT truncated when follow-up update fails"
post_size=$(wc -c < "$session_file" | tr -d ' ')
if [[ "$post_size" -gt 0 ]]; then
  pass=$((pass+1))
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "recovered file is non-empty after failed follow-up update"
else
  fail=$((fail+1))
  printf '  %sFAIL%s  recovered file is non-empty (size: %s)\n' "$RED" "$RESET" "$post_size"
fi
recovered_repo=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "degraded-guard" --path '.repo')
assert_equals "$recovered_repo" "owner/recovered" "recovered .repo persisted from --degraded-init-repo"
recovered_degraded_at=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "degraded-guard" --path '.degraded_recovery_at')
if [[ "$recovered_degraded_at" != "null" ]]; then
  pass=$((pass+1))
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" ".degraded_recovery_at stamped on recovered file"
else
  fail=$((fail+1))
  printf '  %sFAIL%s  .degraded_recovery_at not stamped (got: %s)\n' "$RED" "$RESET" "$recovered_degraded_at"
fi

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== update — setup-timing autoflush failure emits a stderr diagnostic (issue #876)"
# --------------------------------------------------------------------------
# cmd_update opportunistically self-heals a missed `setup-timing.sh flush`
# call whenever a sidecar exists and `.setup` is still null (issue #283).
# That flush is fire-and-forget by design (must never block the caller's
# update) — but before #876 a persistently-failing flush left ZERO trace:
# `2>/dev/null || true` with no diagnostic at all, win or lose. This test
# forces the flush to fail (a malformed sidecar makes setup-timing.sh's own
# jq projection fail, exit 68) and asserts:
#   1. cmd_update still succeeds (fire-and-forget posture preserved).
#   2. A stderr diagnostic identifies the autoflush failure.

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "autoflush-fail" --repo "o/r" >/dev/null
session_file="$tmphome/sessions/autoflush-fail.json"
sidecar="$tmphome/sessions/autoflush-fail.timing.json"

# Malformed sidecar — setup-timing.sh's `jq -c ... "$sidecar"` projection
# fails on this, so `cmd_flush` exits 68 without ever calling back into
# session-state.sh's own `update`.
echo 'not valid json' > "$sidecar"

current_setup=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "autoflush-fail" --path '.setup')
assert_equals "$current_setup" "null" "test setup: .setup starts null so the autoflush path is armed"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" update --session-id "autoflush-fail" \
  --set '.in_flight.x = 1' 2>&1; echo "rc=$?")
rc=$(printf '%s\n' "$out" | tail -1)
assert_equals "$rc" "rc=0" "update succeeds despite a failing setup-timing autoflush (fire-and-forget preserved)"
assert_contains "$out" "setup-timing-autoflush-failed" "failing autoflush emits a stderr diagnostic identifying the failure"
assert_contains "$out" "session=autoflush-fail" "diagnostic names the session id"
assert_contains "$out" "status=68" "diagnostic names the flush's own exit status"

# The caller's own --set expression must still have landed — the diagnostic
# must not change cmd_update's return value or short-circuit the merge.
in_flight_x=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "autoflush-fail" --path '.in_flight.x')
assert_equals "$in_flight_x" "1" "caller's --set expression lands even when the autoflush fails"

# The malformed sidecar is left in place (flush never got far enough to
# remove it) — a subsequent update should surface the SAME diagnostic
# rather than going silent after the first occurrence.
out2=$(SHIPYARD_HOME="$tmphome" bash "$helper" update --session-id "autoflush-fail" \
  --set '.in_flight.y = 2' 2>&1; echo "rc=$?")
assert_contains "$out2" "setup-timing-autoflush-failed" "a persistently-failing autoflush keeps emitting the diagnostic on every update"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== read-tokens — 0-byte session file guard (issue #357)"
# --------------------------------------------------------------------------
# Defense-in-depth: if a legacy 0-byte session file persists on disk (from
# a prior shipyard version's truncation bug, or from external truncation),
# read-tokens MUST NOT silently emit a zero-cost comment. It should surface
# the corruption clearly and exit non-zero so the orchestrator's posting
# branch skips the comment.

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "rt-zero" --repo "o/r" >/dev/null
session_file="$tmphome/sessions/rt-zero.json"
: > "$session_file"  # simulate prior truncation
zero_size=$(wc -c < "$session_file" | tr -d ' ')
assert_equals "$zero_size" "0" "test setup: session file is 0 bytes"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read-tokens --session-id "rt-zero" --format comment --pr 42 2>&1; echo "rc=$?")
rc=$(printf '%s\n' "$out" | tail -1)
assert_equals "$rc" "rc=3" "read-tokens against 0-byte file exits 3"
assert_contains "$out" "session file 0-byte at read-tokens" "read-tokens against 0-byte file surfaces clear log message"
assert_contains "$out" "cost data unrecoverable" "read-tokens against 0-byte file flags data as unrecoverable"

# json format hits the same guard.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read-tokens --session-id "rt-zero" --format json 2>&1; echo "rc=$?")
rc=$(printf '%s\n' "$out" | tail -1)
assert_equals "$rc" "rc=3" "read-tokens --format json against 0-byte file also exits 3"

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
echo "== usage-error tail line names the actual outcome (issue #1039)"
# --------------------------------------------------------------------------
# usage()'s own heredoc unconditionally ends with the exit-code legend, whose
# own last row describes exit 66 (the #365 cross-repo write refusal) — the
# most alarming-sounding entry in the table. A caller that reads a failed
# invocation's stderr through `tail` (a normal thing to do against a chatty
# helper) would misread that legend tail as the actual result: a plain exit
# 64 usage error looking exactly like a cross-repo contamination refusal.
# Assert the LAST stderr line of every usage-error path names the true exit
# 64 outcome instead of the legend, and that it never contains the exit-66
# legend text — the regression this issue's fix (usage_error()) closes.

# Unknown top-level subcommand.
err_last=$(bash "$helper" frobnicate 2>&1 1>/dev/null | tail -1)
assert_equals "$err_last" "session-state.sh: frobnicate: usage error (exit 64)" \
  "unknown subcommand: last stderr line names the usage error, not the exit-code legend"

# Missing required flag on a subcommand (init --session-id).
err_last=$(bash "$helper" init 2>&1 1>/dev/null | tail -1)
assert_equals "$err_last" "session-state.sh: init: usage error (exit 64)" \
  "init without --session-id: last stderr line names the usage error, not the exit-code legend"

# Unknown flag on a subcommand.
err_last=$(bash "$helper" init --bogus 2>&1 1>/dev/null | tail -1)
assert_equals "$err_last" "session-state.sh: init: usage error (exit 64)" \
  "init with unknown flag: last stderr line names the usage error, not the exit-code legend"

# No subcommand at all — no subcommand name is known yet, so the generic form applies.
err_last=$(bash "$helper" 2>&1 1>/dev/null | tail -1)
assert_equals "$err_last" "session-state.sh: usage error (exit 64)" \
  "no subcommand: last stderr line names the usage error, not the exit-code legend"

# The exit-66 legend text must never be the trailing line on any exit-64 path.
err_last=$(bash "$helper" read 2>&1 1>/dev/null | tail -1)
assert_contains "$err_last" "usage error (exit 64)" \
  "read without --session-id: last stderr line names the usage error"
if [[ "$err_last" == *"cross-repo write refused"* ]]; then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "usage-error tail line must never read like the #365 cross-repo refusal"
  fail=$((fail+1))
else
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "usage-error tail line must never read like the #365 cross-repo refusal"
  pass=$((pass+1))
fi

# --help (exit 0, not an error) must NOT gain the new trailing line — the
# fix is scoped to usage-error paths only; --help still exits via the bare
# usage() dump with the legend as the last line, unchanged.
err_last=$(bash "$helper" --help 2>&1 1>/dev/null | tail -1)
assert_contains "$err_last" "cross-repo write refused" \
  "--help is unaffected: still ends on the plain exit-code legend, not usage_error's trailing line"

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
  --mode verify --model claude-opus-4-7 >/dev/null

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
assert_equals "$out" "verify" "per_invocation[0].mode recorded"
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
  --mode verify --model claude-opus-4-7 >/dev/null

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
# math for a known model (Opus tier = $5 input + $25 output per 1M).
#   1_000_000 * $5 / 1_000_000 = $5.00 for 1M input tokens.
# (The pre-#728 table carried a stale $15/$75 Opus rate — the pre-Opus-4.5
# price — which over-reported every Opus dispatch by 3x.)

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "tok-price" --repo "o/r" >/dev/null

SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-price" \
  --input 1000000 --output 0 \
  --model claude-opus-4-7 >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-price" --path ".tokens.totals.estimated_usd")
assert_equals "$out" "5" "opus pricing: 1M input tokens -> \$5.00 USD"

# Unknown model -> tokens still counted, USD unknown. Crucially the USD is
# NOT silently booked as a confident $0: the model is recorded in
# `.tokens.unpriced_models` so every downstream reader can label the total a
# LOWER BOUND (issue #728 — see pricing-coverage.test.sh for the full
# contract).
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-price" \
  --input 1000 \
  --model "unknown-model" 2>/dev/null >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-price" --path ".tokens.totals.input")
assert_equals "$out" "1001000" "unknown model still records token counts"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-price" --path ".tokens.unpriced_models" | jq -r '.[0]')
assert_equals "$out" "unknown-model" "unknown model is flagged, not silently zeroed"

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

# Bare alias `opus` should resolve to the current Opus (claude-opus-5, as of
# #1342 — previously claude-opus-4-8, same $5/Mtok input rate either way).
# Opus-tier input is $5/Mtok → 1M input = $5.00.
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "tok-alias-opus" --repo "o/r" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-alias-opus" \
  --input 1000000 --output 0 \
  --model "opus" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-alias-opus" --path ".tokens.totals.estimated_usd")
assert_equals "$out" "5" "bare alias 'opus' resolves to canonical pricing row"

# Bare alias `sonnet` should resolve to claude-sonnet-5 (as of #1342 —
# previously claude-sonnet-4-6). Sonnet-5's now-permanent standard input
# rate is $2/Mtok (not the $3/Mtok claude-sonnet-4-6 still carries) → 1M
# input = $2.00.
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "tok-alias-sonnet" --repo "o/r" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-alias-sonnet" \
  --input 1000000 --output 0 \
  --model "sonnet" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-alias-sonnet" --path ".tokens.totals.estimated_usd")
assert_equals "$out" "2" "bare alias 'sonnet' resolves to canonical pricing row"

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
echo "== bump-tokens — mode/model policy-consistency warning (#978)"
# --------------------------------------------------------------------------
# bump-tokens has no way to verify which model a dispatch actually ran on —
# the harness self-reports it, and nothing exposes ground truth after the
# fact. What it CAN check is policy consistency: does the billed model's
# family agree with what models.<mode> resolves to for this repo? A
# mismatch here is the exact failure that produced a confidently-wrong
# $4.39 total for a session that actually burned 2.6M+ tokens on Opus (the
# orchestrator self-reported claude-sonnet-5 for dispatches that had really
# run on Opus) — see scripts/session-state.sh's cmd_bump_tokens.

tmphome=$(mktmphome)
tmp_root=$(mktemp -d)
cat > "$tmp_root/shipyard.config.json" <<'JSON'
{ "version": 1, "models": { "issue_work": "claude-sonnet-4-6" } }
JSON

SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "tok-mismatch" --repo "o/r" >/dev/null

# models.issue_work is configured to sonnet; billing this dispatch against
# opus disagrees with policy -> warning on stderr.
err=$(SHIPYARD_REPO_ROOT="$tmp_root" SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-mismatch" \
  --input 1000 \
  --mode "issue-work" --model "claude-opus-4-8" 2>&1 >/dev/null)
assert_contains "$err" "models.issue-work resolves to 'sonnet'" "mode/model mismatch warns when billed family disagrees with the configured override"

# Billing the same dispatch against sonnet agrees with policy -> silent.
err=$(SHIPYARD_REPO_ROOT="$tmp_root" SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-mismatch" \
  --input 1000 \
  --mode "issue-work" --model "claude-sonnet-4-6" 2>&1 >/dev/null)
assert_equals "$err" "" "mode/model consistency check is silent when the billed family matches the configured override"

# `spike` has no models.spike key anywhere (built-in defaults or repo
# config) — it's the one mode that genuinely has no configured override
# (see dispatch-rules.md's "no cheaper pin" note). No override configured
# means nothing to compare against -> silent regardless of billed model.
err=$(SHIPYARD_REPO_ROOT="$tmp_root" SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-mismatch" \
  --input 1000 \
  --mode "spike" --model "claude-opus-4-8" 2>&1 >/dev/null)
assert_equals "$err" "" "mode/model consistency check stays silent when no models.<mode> override is configured for the mode"

# No --mode supplied at all -> the check never engages (nothing to compare
# the billed model's family against).
err=$(SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-mismatch" \
  --input 1000 \
  --model "claude-opus-4-8" 2>&1 >/dev/null)
assert_equals "$err" "" "mode/model consistency check stays silent when --mode is omitted"

rm -f "$tmp_root/shipyard.config.json"
rm -rf "$tmp_root"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== bump-tokens — mode/model policy-consistency: suppress on built-in default (#1185)"
# --------------------------------------------------------------------------
# Every mode has a built-in `models.<mode>` entry, so `expected_family` is
# non-empty even when NO repo/user/local layer configures an override for
# it. Warning on a mismatch in that case makes the check fire on ordinary,
# unconfigured dispatches — the check should only fire when there's a
# genuinely-configured override to disagree with.

tmphome=$(mktmphome)
tmp_root=$(mktemp -d)
# No shipyard.config.json at all — models.fix_checks_only resolves purely
# from the built-in default (haiku).
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "tok-default" --repo "o/r" >/dev/null

err=$(SHIPYARD_REPO_ROOT="$tmp_root" SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-default" \
  --input 1000 \
  --mode "fix-checks-only" --model "claude-opus-4-8" 2>&1 >/dev/null)
assert_equals "$err" "" "mode/model consistency check stays silent when the mismatch is only against the built-in default, not a configured override"

rm -rf "$tmp_root"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== bump-tokens — mode/model policy-consistency: config root pinned from orchestrator worktree (#1185)"
# --------------------------------------------------------------------------
# Reproduces the #1185 repro directly: bump-tokens invoked with cwd inside a
# fresh "orchestrator worktree" (a bare git repo carrying no
# shipyard.config.json of its own, exactly like a fresh origin/<default-branch>
# checkout) and NO SHIPYARD_REPO_ROOT explicitly passed. Without re-deriving
# the pin from the `.shipyard-primary-root` stash, `resolve-dispatch-model.sh`
# would resolve `models.<mode>` against the orchestrator worktree (no config
# at all -> built-in default) instead of the primary checkout's real
# committed override, producing a FALSE mismatch warning.

tmphome=$(mktmphome)
primary_root=$(mktemp -d)
orch_wt=$(mktemp -d)
git -C "$orch_wt" init -q
cat > "$primary_root/shipyard.config.json" <<'JSON'
{ "version": 1, "models": { "issue_work": "claude-sonnet-4-6" } }
JSON
printf '%s\n' "$primary_root" > "$orch_wt/.shipyard-primary-root"

SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "tok-pin" --repo "o/r" >/dev/null

# Billed against sonnet (matches the primary checkout's real override) ->
# must stay silent. SHIPYARD_REPO_ROOT explicitly cleared so the call has to
# fall back to the stash re-derivation, and cwd is the orchestrator worktree
# so an un-pinned resolution would land on ITS (config-less) toplevel.
err=$(cd "$orch_wt" && SHIPYARD_REPO_ROOT="" SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-pin" \
  --input 1000 \
  --mode "issue-work" --model "claude-sonnet-4-6" 2>&1 >/dev/null)
assert_equals "$err" "" "bump-tokens re-derives SHIPYARD_REPO_ROOT from the .shipyard-primary-root stash and correctly matches the primary checkout's override (no false warning)"

# Billed against a genuinely different family (opus) -> the real override
# (sonnet) is still visible after the pin, so the mismatch is REAL and must
# still warn, citing the primary checkout's resolved value.
err=$(cd "$orch_wt" && SHIPYARD_REPO_ROOT="" SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-pin" \
  --input 1000 \
  --mode "issue-work" --model "claude-opus-4-8" 2>&1 >/dev/null)
assert_contains "$err" "models.issue-work resolves to 'sonnet'" "a genuine mismatch against the pinned primary checkout's override still warns"
assert_contains "$err" "$primary_root" "the warning names the config root the mismatch was resolved against (#1185 hardening)"

# An explicitly-passed SHIPYARD_REPO_ROOT must NOT be clobbered by the stash
# — point the stash at $primary_root (sonnet override) but pass an explicit
# SHIPYARD_REPO_ROOT at a THIRD, unconfigured root; the explicit value wins,
# so models.issue_work resolves to the built-in default (sonnet is also the
# built-in default for issue_work, so use a mode whose default differs from
# the primary checkout's override to make the two cases distinguishable).
explicit_root=$(mktemp -d)
cat > "$explicit_root/shipyard.config.json" <<'JSON'
{ "version": 1, "models": { "issue_work": "claude-haiku-4-5" } }
JSON
err=$(cd "$orch_wt" && SHIPYARD_REPO_ROOT="$explicit_root" SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-pin" \
  --input 1000 \
  --mode "issue-work" --model "claude-haiku-4-5" 2>&1 >/dev/null)
assert_equals "$err" "" "an explicitly-passed SHIPYARD_REPO_ROOT is authoritative and is not overridden by the .shipyard-primary-root stash"

err=$(cd "$orch_wt" && SHIPYARD_REPO_ROOT="$explicit_root" SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-pin" \
  --input 1000 \
  --mode "issue-work" --model "claude-sonnet-4-6" 2>&1 >/dev/null)
assert_contains "$err" "models.issue-work resolves to 'haiku'" "the explicit SHIPYARD_REPO_ROOT's own config (haiku), not the stash's (sonnet), governs the mismatch check"

rm -rf "$primary_root" "$orch_wt" "$explicit_root" "$tmphome"

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
  --input 1000 --output 500 --mode verify --model claude-opus-4-7 >/dev/null

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
  --mode verify --model claude-opus-4-7 >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read-tokens --session-id "tok-c" --pr 200 --format comment)
assert_contains "$out" "<!-- do-work-cost-tracking -->" "comment format includes idempotency sentinel"
assert_contains "$out" "PR #200" "comment format names the PR in the heading"
assert_contains "$out" "18203" "comment format includes the input token count"
assert_contains "$out" "4102" "comment format includes the output token count"
assert_contains "$out" "claude-opus-4-7" "comment format includes the model"
assert_contains "$out" "verify" "comment format includes the mode"

# USD formatting contract (issue #277): the Estimated cost (USD) row must
# render as `$X.YZ` — dollar sign prefix + exactly 2 decimal places (cents).
# Raw float output like `0.593` or `3.9216` makes the metric look like a
# unitless ratio rather than a currency amount. This pins the format so a
# future jq refactor can't regress.
#
# 18203 input + 4102 output + 8210 cache_read at Opus-tier pricing
# (5 / 25 / 0.5 USD per 1M tokens — see PRICING_JQ; the pre-#728 table
# carried a stale $15/$75 Opus rate):
#   18203 * 5/1e6 + 4102 * 25/1e6 + 8210 * 0.5/1e6
#     = 0.091015 + 0.10255 + 0.004105 = 0.19767
# rounds to $0.20.
assert_contains "$out" "| Estimated cost (USD) | \$0.20 |" "USD cost rendered as \$X.YZ with dollar prefix + 2 decimals"

# Negative regression check: the unrounded raw-float string (`0.19767`) must
# NOT appear in the comment body. If this fires, the formatter was bypassed.
if [[ "$out" == *"| Estimated cost (USD) | 0.19767 |"* ]]; then
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
# input tokens alone at Opus-tier pricing ($5/Mtok) = 0.091015 -> $0.09.
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "tok-round" --repo "o/r" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-round" --input 18203 \
  --mode verify --model claude-opus-4-7 >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read-tokens --session-id "tok-round" --format comment)
assert_contains "$out" "| Estimated cost (USD) | \$0.09 |" "0.091015 USD rounds to \$0.09"
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
  --session-id "tok-a" --issue 153 --pr 200 --input 1000 --mode verify --model claude-opus-4-7 >/dev/null

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
  --mode verify --model claude-opus-4-7 \
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
  --session-id "recovered" --input 100 --mode verify --model claude-opus-4-7 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=3" "bump-tokens without --allow-degraded-init on missing file still exits 3"

# --allow-degraded-init without --degraded-init-repo falls back to
# "unknown/unknown" (data still lands; better to keep than error out
# on a missing optional metadata field).
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "no-repo" --input 500 --output 200 \
  --mode verify --model claude-opus-4-7 \
  --allow-degraded-init 2>/dev/null
rc=$?
assert_equals "$rc" "0" "bump-tokens --allow-degraded-init without --degraded-init-repo still succeeds"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "no-repo" --path ".repo")
assert_equals "$out" "unknown/unknown" "missing --degraded-init-repo falls back to unknown/unknown sentinel"

# A subsequent bump on a recovered file should NOT re-trigger recovery —
# it should just accumulate normally.
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "no-repo" --input 250 \
  --mode verify --model claude-opus-4-7 \
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
  --mode verify --model claude-opus-4-7 >/dev/null

SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-degraded" \
  --issue 279 --pr 285 \
  --input 86413 \
  --mode verify --model claude-opus-4-7 \
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

# Bucket-level degraded_attribution_count (issue #1218) — the per_pr and
# totals buckets each carry their OWN counter, self-contained on the same
# object as input/output/cache_read/cache_creation, so a reader holding
# only .tokens.per_pr["285"] (or .tokens.totals) can tell "output is
# genuinely 500" apart from "output is undercounted by an unknown amount"
# without also fetching .tokens.degraded_attribution_count or scanning
# per_invocation.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-degraded" --path ".tokens.per_pr[\"285\"].degraded_attribution_count")
assert_equals "$out" "1" "per_pr bucket carries its own degraded_attribution_count (issue #1218)"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-degraded" --path ".tokens.per_pr[\"285\"].output")
assert_equals "$out" "500" "per_pr bucket's real output (500, from the non-degraded bump) is preserved — the degraded bump did not zero or null it out"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-degraded" --path ".tokens.totals.degraded_attribution_count")
assert_equals "$out" "1" "totals bucket carries its own degraded_attribution_count, mirroring the session-level counter (issue #1218)"

# A second degraded bump should bring the counter to 2.
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-degraded" \
  --input 12345 \
  --mode verify --model claude-opus-4-7 \
  --degraded-total-only >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-degraded" --path ".tokens.degraded_attribution_count")
assert_equals "$out" "2" "second degraded bump increments degraded_attribution_count to 2"

# Usage error: --degraded-total-only is mutually exclusive with non-zero
# --output / --cache-read / --cache-creation. Reject with exit 64 rather
# than silently mixing strict + degraded attribution.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-degraded" \
  --input 1000 --output 500 \
  --mode verify --model claude-opus-4-7 \
  --degraded-total-only 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "--degraded-total-only with non-zero --output is rejected (exit 64)"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-degraded" \
  --input 1000 --cache-read 100 \
  --mode verify --model claude-opus-4-7 \
  --degraded-total-only 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "--degraded-total-only with non-zero --cache-read is rejected (exit 64)"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-degraded" \
  --input 1000 --cache-creation 100 \
  --mode verify --model claude-opus-4-7 \
  --degraded-total-only 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "--degraded-total-only with non-zero --cache-creation is rejected (exit 64)"

# Usage error: --degraded-total-only with --input 0 (or --input omitted, which
# defaults to 0) is the orchestrator copy-paste trap from issue #320. A real
# agent completion always has non-zero total_tokens — zero is a programming
# error on the caller side (orchestrator pasted the breakdown-fields default
# into the degraded path). Fail loud at usage time rather than silently
# recording $0 across every dispatch in the session.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-degraded" \
  --input 0 --output 0 --cache-read 0 --cache-creation 0 \
  --mode verify --model claude-opus-4-7 \
  --degraded-total-only 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "--degraded-total-only with --input 0 is rejected (exit 64) — orchestrator copy-paste trap"
# Strip the trailing rc=N marker for the diagnostic-message assertion. Avoid
# `head -n -1` (BSD head — macOS — rejects negative line counts).
msg=$(printf '%s' "$out" | grep -v '^rc=')
assert_contains "$msg" "--degraded-total-only requires --input <total_tokens>" "--input 0 rejection emits diagnostic naming the actual total_tokens requirement"

# --input omitted entirely (default 0) — same failure shape, same exit.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "tok-degraded" \
  --mode verify --model claude-opus-4-7 \
  --degraded-total-only 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "--degraded-total-only with --input omitted (defaults to 0) is rejected (exit 64)"

# The rejection must run BEFORE any state mutation. After rejecting an
# --input 0 call, the session file's tokens.totals + degraded_attribution_count
# must be unchanged from the last successful bump (87413, 2 — set by the two
# prior --degraded-total-only success cases earlier in this block).
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-degraded" --path ".tokens.totals.input")
assert_equals "$out" "99758" "rejected --input 0 bump did not mutate totals.input (still 87413 + 12345 = 99758 from prior successes)"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "tok-degraded" --path ".tokens.degraded_attribution_count")
assert_equals "$out" "2" "rejected --input 0 bump did not increment degraded_attribution_count (still 2)"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== bump-tokens — degraded blended-rate pricing matches a known mix + total (issue #1330)"
# --------------------------------------------------------------------------
# Regression coverage for the blended-mix formula itself (structural
# markers are covered separately below, and were already covered pre-#1330
# for #1327). A --degraded-total-only bump's estimated_usd must equal
# total_tokens * blended_rate / 1e6, where
# blended_rate = sum(mix[bucket] * price[bucket]) across
# DEGRADED_BLEND_MIX_JQ and the billed model's PRICING_JQ row. The mix and
# price table are re-typed here (not sourced from production) against
# claude-sonnet-5 ($2.00/$10.00/$0.20/$2.50 per 1M — corrected in #1342,
# was $3.00/$15.00/$0.30/$3.75) and a known total of 1,000,000 tokens, so a
# regression in either table or the formula's wiring would be caught rather
# than silently agreeing with itself.

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "blend-known" --repo "o/r" >/dev/null

SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "blend-known" \
  --input 1000000 \
  --mode issue-work --model claude-sonnet-5 \
  --degraded-total-only >/dev/null

actual=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "blend-known" --path ".tokens.totals.estimated_usd")
# blended_rate = 0.07*2.00 + 0.04*10.00 + 0.86*0.20 + 0.03*2.50 = 0.787 per
# 1M tokens; expected_usd = 1,000,000 * 0.787 / 1,000,000 = 0.787.
expected=$(jq -n '
  ({"input":0.07,"output":0.04,"cache_read":0.86,"cache_creation":0.03}) as $mix
  | ({"input":2.00,"output":10.00,"cache_read":0.20,"cache_creation":2.50}) as $p
  | (1000000 * (($mix.input*$p.input)+($mix.output*$p.output)+($mix.cache_read*$p.cache_read)+($mix.cache_creation*$p.cache_creation))) / 1000000
')
# Round both sides to 6 decimal places before comparing — the actual and
# expected values are computed via algebraically-equivalent but
# differently-ordered floating-point arithmetic (production's jq pipeline
# vs. this test's independent re-derivation), which can differ by a
# few ULPs even when correct. Rounding removes that noise without masking
# a real formula mismatch, which would differ by far more than one ULP.
actual_rounded=$(jq -n --argjson v "$actual" '($v * 1000000 | round) / 1000000')
expected_rounded=$(jq -n --argjson v "$expected" '($v * 1000000 | round) / 1000000')
assert_equals "$actual_rounded" "$expected_rounded" "degraded blended-rate bump: 1,000,000 tokens @ claude-sonnet-5 mix -> \$0.787 blended rate (issue #1330)"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== bump-tokens — non-degraded (real breakdown) pricing is unaffected by the blended-mix change (issue #1330)"
# --------------------------------------------------------------------------
# #1330 only touches the --degraded-total-only branch of the pricing
# formula (see the `if $degraded == 1 then ... else ... end` split in
# cmd_bump_tokens). This asserts the plain-breakdown path — real --output /
# --cache-read / --cache-creation counts, no --degraded-total-only — still
# prices exactly as the pre-#1330 formula:
# input*p.input + output*p.output + cache_read*p.cache_read +
# cache_creation*p.cache_creation, all over 1e6 — with no dependency on
# DEGRADED_BLEND_MIX_JQ at all. Uses claude-sonnet-5
# ($2.00/$10.00/$0.20/$2.50 per 1M — corrected in #1342, was
# $3.00/$15.00/$0.30/$3.75).

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "clean-unaffected" --repo "o/r" >/dev/null

SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "clean-unaffected" \
  --input 100000 --output 20000 --cache-read 500000 --cache-creation 10000 \
  --mode issue-work --model claude-sonnet-5 >/dev/null

actual=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "clean-unaffected" --path ".tokens.totals.estimated_usd")
expected=$(jq -n '(100000*2.00 + 20000*10.00 + 500000*0.20 + 10000*2.50) / 1000000')
actual_rounded=$(jq -n --argjson v "$actual" '($v * 1000000 | round) / 1000000')
expected_rounded=$(jq -n --argjson v "$expected" '($v * 1000000 | round) / 1000000')
assert_equals "$actual_rounded" "$expected_rounded" "non-degraded bump prices via the plain per-bucket formula, unaffected by DEGRADED_BLEND_MIX_JQ (issue #1330)"
# .tokens.degraded_attribution_count is only ever written by a degraded
# bump (see cmd_bump_tokens's `if $degraded == 1` branch) — a session that
# never took that branch leaves the field entirely absent, which `read
# --path` reports as the literal string "null", not "0". The `// 0`
# normalization lives in every downstream reader (read-tokens,
# cost-history.sh); a bare path read here intentionally observes the raw,
# unnormalized value.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "clean-unaffected" --path ".tokens.degraded_attribution_count // 0")
assert_equals "$out" "0" "non-degraded bump does not increment degraded_attribution_count"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== bump-tokens/read-tokens — per_issue bucket disambiguates real output:0 from degraded-folded output:0 (#1218)"
# --------------------------------------------------------------------------
# Two issues in the same session: #601 gets one real, non-degraded bump
# with an explicit --output 0 (genuinely zero output tokens); #602 gets one
# --degraded-total-only bump (output defaults to 0 because the whole total
# folded into --input). Both buckets end up with .output == 0 — the
# regression is that .degraded_attribution_count, read from the SAME
# bucket object, still tells them apart with no other lookup.

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "distinguish-live" --repo "o/r" >/dev/null

SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "distinguish-live" --issue 601 \
  --input 5000 --output 0 --cache-read 0 --cache-creation 0 \
  --mode issue-work --model claude-sonnet-5 >/dev/null

SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "distinguish-live" --issue 602 \
  --input 7000 --mode issue-work --model claude-sonnet-5 \
  --degraded-total-only >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "distinguish-live" --path '.tokens.per_issue["601"].output')
assert_equals "$out" "0" "issue #601 (genuinely zero output) bucket: .output == 0"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "distinguish-live" --path '.tokens.per_issue["601"].degraded_attribution_count')
assert_equals "$out" "0" "issue #601 bucket: .degraded_attribution_count == 0 — no other lookup needed to know this 0 is real"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "distinguish-live" --path '.tokens.per_issue["602"].output')
assert_equals "$out" "0" "issue #602 (degraded-folded) bucket: .output == 0 (same literal value as #601)"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "distinguish-live" --path '.tokens.per_issue["602"].degraded_attribution_count')
assert_equals "$out" "1" "issue #602 bucket: .degraded_attribution_count == 1 — disambiguates from #601 using only this bucket"

# read-tokens --format json --issue defaults degraded_attribution_count to 0
# for an issue that has never been bumped at all (the //= default object),
# so a never-touched issue reads as unambiguously "0 real, 0 degraded"
# rather than a missing field.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read-tokens --session-id "distinguish-live" --issue 999 --format json | jq -r '.degraded_attribution_count')
assert_equals "$out" "0" "read-tokens --issue for a never-bumped issue defaults degraded_attribution_count to 0, not null/missing"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== read-tokens --format comment — UNRELIABLE advisory appears only in scope with a degraded bump (#1218)"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "comment-deg" --repo "o/r" >/dev/null

SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "comment-deg" --issue 801 --pr 802 \
  --input 3000 --mode issue-work --model claude-sonnet-5 >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "comment-deg" --issue 803 --pr 804 \
  --input 6000 --mode issue-work --model claude-sonnet-5 \
  --degraded-total-only >/dev/null

clean_comment=$(SHIPYARD_HOME="$tmphome" bash "$helper" read-tokens --session-id "comment-deg" --pr 802 --format comment)
if [[ "$clean_comment" == *"UNRELIABLE"* ]]; then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "clean PR's cost-tracking comment does NOT mention UNRELIABLE"
  fail=$((fail+1))
else
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "clean PR's cost-tracking comment does NOT mention UNRELIABLE"
  pass=$((pass+1))
fi

degraded_comment=$(SHIPYARD_HOME="$tmphome" bash "$helper" read-tokens --session-id "comment-deg" --pr 804 --format comment)
assert_contains "$degraded_comment" "UNRELIABLE" "degraded PR's cost-tracking comment surfaces the UNRELIABLE advisory"
assert_contains "$degraded_comment" "1 dispatch(es)" "degraded PR's advisory names the affected dispatch count"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== read-tokens — estimated_usd_degraded / estimated_usd_upper_bound structurally mark a degraded scope (#1327, #1330)"
# --------------------------------------------------------------------------
# Issue #1327: a fully- or partly-degraded scope's estimated_usd read as a
# measured figure with nothing in the VALUE marking it an upper bound (the
# #1218 UNRELIABLE advisory is prose alongside the figure, not a field a
# JSON consumer is forced to notice). This adds two structural fields to
# `read-tokens --format json`'s scope object — estimated_usd_degraded
# (bool) and estimated_usd_upper_bound — and changes the `--format comment`
# cost row itself to carry a distinct marker when degraded. Three scopes:
# PR 901 fully degraded (both its dispatches used --degraded-total-only),
# PR 902 partly degraded (one normal + one degraded dispatch), PR 903
# clean (no degraded dispatches at all — must render byte-identically to
# pre-#1327 behavior).
#
# Issue #1330 changed what estimated_usd_upper_bound MEANS for a degraded
# scope. Under #1327 it mirrored estimated_usd (which was itself computed
# by pricing the whole degraded total at the `input` rate — a defensible
# stand-in for "upper bound" at the time). #1330 replaced that pricing
# with a blended-mix estimate (DEGRADED_BLEND_MIX_JQ) that is no longer
# definitionally a ceiling, so estimated_usd_upper_bound is now computed
# independently as a TRUE ceiling: the scope's total token count times the
# single most expensive per-token rate anywhere in PRICING_JQ (currently
# claude-fable-5's $50.00/1M output rate). The two fields are expected to
# DIVERGE below — that divergence is the point of #1330, not a bug.

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "struct-deg" --repo "o/r" >/dev/null

# PR 901 — fully degraded: two dispatches, both --degraded-total-only.
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "struct-deg" --issue 901 --pr 901 \
  --input 10000 --mode issue-work --model claude-sonnet-5 \
  --degraded-total-only >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "struct-deg" --issue 901 --pr 901 \
  --input 5000 --mode issue-work --model claude-sonnet-5 \
  --degraded-total-only >/dev/null

# PR 902 — partly degraded: one normal, one degraded dispatch.
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "struct-deg" --issue 902 --pr 902 \
  --input 1000 --output 500 --cache-read 200 --cache-creation 100 \
  --mode issue-work --model claude-sonnet-5 >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "struct-deg" --issue 902 --pr 902 \
  --input 8000 --mode issue-work --model claude-sonnet-5 \
  --degraded-total-only >/dev/null

# PR 903 — clean: two normal dispatches, no degraded bump at all.
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "struct-deg" --issue 903 --pr 903 \
  --input 1000 --output 500 --cache-read 200 --cache-creation 100 \
  --mode issue-work --model claude-sonnet-5 >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "struct-deg" --issue 903 --pr 903 \
  --input 2000 --output 300 --cache-read 100 --cache-creation 50 \
  --mode issue-work --model claude-sonnet-5 >/dev/null

# --- JSON: fully degraded scope ---
json_901=$(SHIPYARD_HOME="$tmphome" bash "$helper" read-tokens --session-id "struct-deg" --pr 901 --format json)
out=$(printf '%s' "$json_901" | jq -r '.estimated_usd_degraded')
assert_equals "$out" "true" "PR 901 (fully degraded): estimated_usd_degraded == true"
usd_901=$(printf '%s' "$json_901" | jq -r '.estimated_usd')
upper_901=$(printf '%s' "$json_901" | jq -r '.estimated_usd_upper_bound')
# True-ceiling formula (issue #1330): scope's total token count (every
# bucket summed) times the single most expensive per-token rate anywhere
# in PRICING_JQ — independently re-derived here, not copy-pasted from
# production, so the test would catch a formula regression on either side.
expected_upper_901=$(jq -n --argjson total "$(printf '%s' "$json_901" | jq -r '(.input // 0) + (.output // 0) + (.cache_read // 0) + (.cache_creation // 0)')" '($total * 50.00) / 1000000')
assert_equals "$upper_901" "$expected_upper_901" "PR 901 (fully degraded): estimated_usd_upper_bound == total_tokens * max pricing-table rate (true ceiling, issue #1330)"
if [[ "$upper_901" == "$usd_901" ]]; then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "PR 901 (fully degraded): estimated_usd_upper_bound no longer mirrors estimated_usd (issue #1330 — the blended estimate diverges from the true ceiling)"
  fail=$((fail+1))
else
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "PR 901 (fully degraded): estimated_usd_upper_bound no longer mirrors estimated_usd (issue #1330 — the blended estimate diverges from the true ceiling)"
  pass=$((pass+1))
fi

# --- JSON: partly degraded scope — still marked, same as fully degraded ---
json_902=$(SHIPYARD_HOME="$tmphome" bash "$helper" read-tokens --session-id "struct-deg" --pr 902 --format json)
out=$(printf '%s' "$json_902" | jq -r '.estimated_usd_degraded')
assert_equals "$out" "true" "PR 902 (partly degraded): estimated_usd_degraded == true"
usd_902=$(printf '%s' "$json_902" | jq -r '.estimated_usd')
upper_902=$(printf '%s' "$json_902" | jq -r '.estimated_usd_upper_bound')
expected_upper_902=$(jq -n --argjson total "$(printf '%s' "$json_902" | jq -r '(.input // 0) + (.output // 0) + (.cache_read // 0) + (.cache_creation // 0)')" '($total * 50.00) / 1000000')
assert_equals "$upper_902" "$expected_upper_902" "PR 902 (partly degraded): estimated_usd_upper_bound == total_tokens * max pricing-table rate (true ceiling, issue #1330)"
if [[ "$upper_902" == "$usd_902" ]]; then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "PR 902 (partly degraded): estimated_usd_upper_bound no longer mirrors estimated_usd (issue #1330)"
  fail=$((fail+1))
else
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "PR 902 (partly degraded): estimated_usd_upper_bound no longer mirrors estimated_usd (issue #1330)"
  pass=$((pass+1))
fi

# --- JSON: clean scope — no new caveat, upper_bound is null ---
json_903=$(SHIPYARD_HOME="$tmphome" bash "$helper" read-tokens --session-id "struct-deg" --pr 903 --format json)
out=$(printf '%s' "$json_903" | jq -r '.estimated_usd_degraded')
assert_equals "$out" "false" "PR 903 (clean): estimated_usd_degraded == false"
out=$(printf '%s' "$json_903" | jq -r '.estimated_usd_upper_bound')
assert_equals "$out" "null" "PR 903 (clean): estimated_usd_upper_bound == null"

# --- comment: fully degraded row reads as an explicit blended-rate
# estimate, not an upper bound (issue #1330 — the figure is no longer
# definitionally a ceiling once bump-tokens applies the blended mix).
comment_901=$(SHIPYARD_HOME="$tmphome" bash "$helper" read-tokens --session-id "struct-deg" --pr 901 --format comment)
cost_line_901=$(printf '%s' "$comment_901" | grep "Estimated cost")
assert_contains "$cost_line_901" "~\$" "PR 901 (fully degraded) cost row is prefixed with ~\$, not a bare \$ figure"
assert_contains "$cost_line_901" "blended-rate estimate" "PR 901 (fully degraded) cost row names itself a blended-rate estimate (issue #1330)"
assert_contains "$cost_line_901" "unavailable for 2/2 dispatches" "PR 901 (fully degraded) cost row names both dispatches as degraded"

# --- comment: partly degraded row is marked too, with the correct N/M ---
comment_902=$(SHIPYARD_HOME="$tmphome" bash "$helper" read-tokens --session-id "struct-deg" --pr 902 --format comment)
cost_line_902=$(printf '%s' "$comment_902" | grep "Estimated cost")
assert_contains "$cost_line_902" "~\$" "PR 902 (partly degraded) cost row is prefixed with ~\$"
assert_contains "$cost_line_902" "unavailable for 1/2 dispatches" "PR 902 (partly degraded) cost row names 1 of 2 dispatches as degraded"

# --- comment: clean row renders EXACTLY as it did before #1327 — no tilde,
# no "upper bound" text, plain $X.XX. This is the explicit no-regression
# check the issue's phase-1 slice calls for.
comment_903=$(SHIPYARD_HOME="$tmphome" bash "$helper" read-tokens --session-id "struct-deg" --pr 903 --format comment)
cost_line_903=$(printf '%s' "$comment_903" | grep "Estimated cost")
if [[ "$cost_line_903" == *"~"* ]]; then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "PR 903 (clean) cost row does NOT contain a ~ prefix"
  fail=$((fail+1))
else
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "PR 903 (clean) cost row does NOT contain a ~ prefix"
  pass=$((pass+1))
fi
if [[ "$cost_line_903" == *"upper bound"* ]]; then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "PR 903 (clean) cost row does NOT mention 'upper bound'"
  fail=$((fail+1))
else
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "PR 903 (clean) cost row does NOT mention 'upper bound'"
  pass=$((pass+1))
fi
assert_contains "$cost_line_903" "| Estimated cost (USD) | \$" "PR 903 (clean) cost row keeps the plain \$X.XX shape unchanged"

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
  --mode verify --model claude-opus-4-7 \
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
  --mode verify --model claude-opus-4-7 >/dev/null

# Issue #1252 — seed a live in_flight slot and leave .session_end unset,
# simulating a session that died mid-flight (crashed/interrupted) before
# ever reaching cleanup-summary.md's normal exit path. The reap-audit line
# below must capture BOTH signals (a non-null in-flight count and a null
# session_end) so a reader of ~/.shipyard/reap-audit.jsonl can distinguish
# this abnormal termination from a clean one after the fact.
SHIPYARD_HOME="$tmphome" bash "$helper" update --session-id "victim" \
  --set '.in_flight.slot1 = {kind: "issue", target: 1252, claimed_paths: {hard: [], soft: []}, agent_id: "abc", started_at: "2026-08-10T12:00:00Z"}' >/dev/null

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

# Issue #1252 — the abnormal-exit signature: non-empty in_flight AND a
# still-null session_end at the moment of reap. This is what lets the
# orphan sweep (scripts/sweep-orphan-sessions.sh) tell a session that died
# mid-flight apart from one that reached its own normal exit.
out=$(printf '%s' "$audit_line" | jq -r '.reaped_in_flight_count')
assert_equals "$out" "1" "audit line captures reaped_in_flight_count (#1252)"
out=$(printf '%s' "$audit_line" | jq -c '.reaped_session_end')
assert_equals "$out" "null" "audit line captures reaped_session_end = null for a session that never recorded why it ended (#1252)"

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

# Issue #1252 — the clean-completion counterpart: a session that DID reach
# record-session-end before its file happened to linger (e.g.
# SHIPYARD_KEEP_SESSIONS, or a delayed sweep) is captured with the reason
# it recorded, not null — so a reader can tell "this one finished, the
# file just outlived it" apart from the abnormal case above.
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "tidy" --repo "tidy/repo" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" record-session-end \
  --session-id "tidy" --reason "completed" \
  --detail "drain exited via all PRs settled; session_prs merged=3 blocked:ci=0 rebase-blocked=0 pending=0" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" cleanup \
  --session-id "tidy" \
  --reap-audit --reaper-session-id "reaper-281" 2>/dev/null
tidy_audit_line=$(tail -1 "$audit_log")
out=$(printf '%s' "$tidy_audit_line" | jq -r '.reaped_session_end.reason')
assert_equals "$out" "completed" "audit line captures reaped_session_end.reason for a session that recorded why it ended (#1252)"
out=$(printf '%s' "$tidy_audit_line" | jq -r '.reaped_in_flight_count')
assert_equals "$out" "0" "audit line captures reaped_in_flight_count = 0 for a cleanly-ended session (#1252)"
prev_lines=$(wc -l <"$audit_log" | tr -d ' ')

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

# --------------------------------------------------------------------------
echo "== cross-repo write guard (issue #365)"
# --------------------------------------------------------------------------
#
# Regression test for the cross-session contamination race documented in
# issue #365: when two /shipyard:do-work sessions run concurrently against
# different repos, a session-id stash race can route one session's
# `update` / `bump-tokens` calls to the other session's state file —
# silently cross-wiring token attributions and session_prs. The guard:
# when --expected-repo (or $SHIPYARD_EXPECTED_REPO) is set and the file's
# .repo doesn't match, refuse with exit 66.

# --- update: --expected-repo mismatch → exit 66, file unchanged. -----------
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "xrepo-1" --repo "owner/repo-A" >/dev/null
session_file="$tmphome/sessions/xrepo-1.json"

# Capture baseline content to assert the refused write leaves the file untouched.
before_sha=$(shasum "$session_file" | awk '{print $1}')

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" update \
  --session-id "xrepo-1" \
  --set '.session_prs += [999]' \
  --expected-repo "owner/repo-B" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=66" "update with mismatched --expected-repo exits 66"
assert_contains "$out" "cross-repo write refused" "update prints cross-repo refusal log"
assert_contains "$out" "owner/repo-A" "update log names file's actual .repo"
assert_contains "$out" "owner/repo-B" "update log names expected repo"

after_sha=$(shasum "$session_file" | awk '{print $1}')
assert_equals "$after_sha" "$before_sha" "update refuses to mutate file on mismatch (sha unchanged)"
# Belt to the suspenders: .session_prs should be unchanged too.
prs=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "xrepo-1" --path ".session_prs | length")
assert_equals "$prs" "0" "session_prs unchanged after refused update"
rm -rf "$tmphome"

# --- update: --expected-repo match → write succeeds. -----------------------
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "xrepo-2" --repo "owner/repo-A" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" update \
  --session-id "xrepo-2" \
  --set '.session_prs += [42]' \
  --expected-repo "owner/repo-A" >/dev/null
rc=$?
assert_equals "$rc" "0" "update with matching --expected-repo exits 0"
prs=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "xrepo-2" --path ".session_prs[0]")
assert_equals "$prs" "42" ".session_prs landed after matched update"
rm -rf "$tmphome"

# --- update: no --expected-repo → check is a no-op (back-compat). ----------
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "xrepo-3" --repo "owner/repo-A" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" update \
  --session-id "xrepo-3" \
  --set '.session_prs += [7]' >/dev/null
rc=$?
assert_equals "$rc" "0" "update without --expected-repo exits 0 (back-compat)"
prs=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "xrepo-3" --path ".session_prs[0]")
assert_equals "$prs" "7" ".session_prs landed without --expected-repo (back-compat)"
rm -rf "$tmphome"

# --- update: --skip-repo-check overrides a mismatch. -----------------------
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "xrepo-4" --repo "owner/repo-A" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" update \
  --session-id "xrepo-4" \
  --set '.session_prs += [11]' \
  --expected-repo "owner/repo-B" \
  --skip-repo-check >/dev/null
rc=$?
assert_equals "$rc" "0" "update with --skip-repo-check ignores mismatch"
prs=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "xrepo-4" --path ".session_prs[0]")
assert_equals "$prs" "11" ".session_prs landed when --skip-repo-check overrides"
rm -rf "$tmphome"

# --- update: SHIPYARD_EXPECTED_REPO env var works as fallback. -------------
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "xrepo-5" --repo "owner/repo-A" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" SHIPYARD_EXPECTED_REPO="owner/repo-B" \
  bash "$helper" update \
  --session-id "xrepo-5" \
  --set '.session_prs += [88]' 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=66" "SHIPYARD_EXPECTED_REPO mismatch exits 66"
# Per-call --expected-repo overrides the env (matches → succeeds).
SHIPYARD_HOME="$tmphome" SHIPYARD_EXPECTED_REPO="owner/repo-B" \
  bash "$helper" update \
  --session-id "xrepo-5" \
  --set '.session_prs += [88]' \
  --expected-repo "owner/repo-A" >/dev/null
rc=$?
assert_equals "$rc" "0" "per-call --expected-repo overrides SHIPYARD_EXPECTED_REPO env"
rm -rf "$tmphome"

# --- bump-tokens: --expected-repo mismatch → exit 66, totals unchanged. ----
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "xrepo-6" --repo "owner/repo-A" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "xrepo-6" \
  --issue 153 --pr 200 \
  --input 1000 --output 500 \
  --mode verify --model claude-opus-4-7 \
  --expected-repo "owner/repo-B" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=66" "bump-tokens with mismatched --expected-repo exits 66"
assert_contains "$out" "cross-repo write refused" "bump-tokens prints cross-repo refusal log"
# Totals must NOT have been bumped — this is the cost-ledger contamination
# the guard exists to prevent.
totals_input=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "xrepo-6" --path ".tokens.totals.input")
assert_equals "$totals_input" "0" "bump-tokens refused: .tokens.totals.input unchanged"
per_pr_input=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "xrepo-6" --path ".tokens.per_pr | length")
assert_equals "$per_pr_input" "0" "bump-tokens refused: .tokens.per_pr unchanged"
rm -rf "$tmphome"

# --- bump-tokens: --expected-repo match → bump succeeds. -------------------
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "xrepo-7" --repo "owner/repo-A" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "xrepo-7" \
  --issue 153 --pr 200 \
  --input 1000 --output 500 \
  --mode verify --model claude-opus-4-7 \
  --expected-repo "owner/repo-A" >/dev/null
rc=$?
assert_equals "$rc" "0" "bump-tokens with matching --expected-repo exits 0"
totals_input=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "xrepo-7" --path ".tokens.totals.input")
assert_equals "$totals_input" "1000" "bump-tokens succeeded: .tokens.totals.input bumped"
rm -rf "$tmphome"

# --- empty .repo (legacy file, partial write) → check is a no-op. ----------
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "xrepo-8" --repo "owner/repo-A" >/dev/null
# Synthetic mutation: blank out .repo to simulate a legacy file shape.
jq '.repo = ""' "$tmphome/sessions/xrepo-8.json" > "$tmphome/sessions/xrepo-8.json.tmp"
mv "$tmphome/sessions/xrepo-8.json.tmp" "$tmphome/sessions/xrepo-8.json"
SHIPYARD_HOME="$tmphome" bash "$helper" update \
  --session-id "xrepo-8" \
  --set '.session_prs += [55]' \
  --expected-repo "owner/repo-B" >/dev/null
rc=$?
assert_equals "$rc" "0" "empty .repo treated as no-op (no false positive)"
rm -rf "$tmphome"

# --- missing file + --allow-degraded-init: check is a no-op (recovery sets .repo). ---
tmphome=$(mktmphome)
# Don't init — file is missing.
SHIPYARD_HOME="$tmphome" bash "$helper" update \
  --session-id "xrepo-9" \
  --set '.session_prs += [33]' \
  --allow-degraded-init \
  --degraded-init-repo "owner/repo-A" \
  --expected-repo "owner/repo-A" >/dev/null 2>&1
rc=$?
assert_equals "$rc" "0" "degraded-init + matching --expected-repo: write succeeds"
prs=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "xrepo-9" --path ".session_prs[0]")
assert_equals "$prs" "33" "degraded-recovery wrote .session_prs"
repo=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "xrepo-9" --path ".repo")
assert_equals "$repo" "owner/repo-A" "degraded-recovery init set .repo from --degraded-init-repo"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== record-session-end (issue #1252)"
# --------------------------------------------------------------------------
# Three of six recent /shipyard:do-work sessions terminated with a
# non-empty .in_flight and no record of why — the orchestrator process
# ended before it ever reached cleanup-summary.md's normal exit path. This
# subcommand stamps a terminal .session_end reason on the way out so a
# reader (a human, or the next session's orphan sweep) can tell "finished
# cleanly" from "stopped short" without hand-narrating it fresh.

# init not present at all yet — .session_end must default to null so a
# freshly-started session reads unambiguously as "hasn't ended."
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "end-1" --repo "o/r" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "end-1" --path ".session_end")
assert_equals "$out" "null" "init leaves .session_end null (#1252)"

# --- Clean-completion case ("finished cleanly"). ---------------------------
SHIPYARD_HOME="$tmphome" bash "$helper" record-session-end \
  --session-id "end-1" --reason "completed" \
  --detail "drain exited via all PRs settled; session_prs merged=2 blocked:ci=0 rebase-blocked=0 pending=0; ledger dispatchable=0 unaccounted=0" >/dev/null
rc=$?
assert_equals "$rc" "0" "record-session-end --reason completed exits 0"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "end-1" --path ".session_end.reason")
assert_equals "$out" "completed" "record-session-end writes .session_end.reason = completed"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "end-1" --path ".session_end.detail")
assert_contains "$out" "all PRs settled" ".session_end.detail carries the drain-exit detail"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "end-1" --path ".session_end.recorded_at")
if [[ -n "$out" && "$out" != "null" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" ".session_end.recorded_at is stamped"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s (got: %s)\n' "$RED" "$RESET" ".session_end.recorded_at is stamped" "$out"
  fail=$((fail+1))
fi
rm -rf "$tmphome"

# --- Stopped-short case ("bounded-exit"). -----------------------------------
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "end-2" --repo "o/r" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" record-session-end \
  --session-id "end-2" --reason "bounded-exit" \
  --detail "drain exited via max_drain_hours ceiling (8h); session_prs merged=1 blocked:ci=1 rebase-blocked=0 pending=1" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "end-2" --path ".session_end.reason")
assert_equals "$out" "bounded-exit" "record-session-end writes .session_end.reason = bounded-exit"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "end-2" --path ".session_end.detail")
assert_contains "$out" "max_drain_hours" ".session_end.detail names the bound the session stopped on"

# --- user-stop case. ---------------------------------------------------
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "end-3" --repo "o/r" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" record-session-end \
  --session-id "end-3" --reason "user-stop" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "end-3" --path ".session_end.reason")
assert_equals "$out" "user-stop" "record-session-end writes .session_end.reason = user-stop"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "end-3" --path ".session_end.detail")
assert_equals "$out" "null" "omitted --detail is stored as null, not empty string"
rm -rf "$tmphome"

# --- Input validation. -------------------------------------------------
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "end-4" --repo "o/r" >/dev/null

# Unknown --reason value is rejected rather than silently persisted.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" record-session-end \
  --session-id "end-4" --reason "crashed" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "record-session-end rejects an unrecognized --reason"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "end-4" --path ".session_end")
assert_equals "$out" "null" "rejected --reason leaves .session_end untouched"

# Missing --session-id.
out=$(bash "$helper" record-session-end --reason "completed" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "record-session-end without --session-id exits 64"

# Missing --reason.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" record-session-end --session-id "end-4" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "record-session-end without --reason exits 64"

# Missing session file, no --allow-degraded-init: exit 3, matching update's contract.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" record-session-end \
  --session-id "missing-end" --reason "completed" 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=3" "record-session-end on missing session (no degraded-init) exits 3"

# Missing session file WITH --allow-degraded-init: recovers and writes through,
# same recovery contract `update` already carries (issues #253/#281).
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" record-session-end \
  --session-id "recovered-end" --reason "bounded-exit" \
  --allow-degraded-init --degraded-init-repo "owner/repo" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=0" "record-session-end --allow-degraded-init recovers a missing file"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "recovered-end" --path ".session_end.reason")
assert_equals "$out" "bounded-exit" "degraded-recovered file carries the recorded reason"
rm -rf "$tmphome"

# --- Non-fatal write-through posture: a failed call must not be treated as
# fatal by a caller following the documented `|| echo ... ; continuing`
# pattern (session-state-file.md's "Failure mode" section) — exercised here
# as a direct exit-code check rather than re-deriving the orchestrator's
# prose fallback.
tmphome=$(mktmphome)
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" record-session-end \
  --session-id "no-such-session" --reason "completed" 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=3" "record-session-end failure is a plain non-zero exit a caller can || and continue past"
rm -rf "$tmphome"

echo "== record-stall (issue #1302)"
# --------------------------------------------------------------------------
# Typed alternative to a hand-built `.stalled_dispatches = [...]` jq literal
# through `update` — issue #1302 found that shape gets denied outright by
# Auto Mode's classifier when the payload carries nested JSON, silently
# degrading the session-state mirror for the rest of the session. A single-
# entry typed call keeps the argument small.

# init already seeds .stalled_dispatches to an empty array.
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "stall-1" --repo "o/r" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "stall-1" --path ".stalled_dispatches")
assert_equals "$out" "[]" "init seeds .stalled_dispatches to an empty array (#1302)"

# Happy path — resumed outcome carries a resumed_pr.
SHIPYARD_HOME="$tmphome" bash "$helper" record-stall \
  --session-id "stall-1" --target "#1263" --mode "issue-work" \
  --trigger "non-terminal-return" --outcome "resumed" --resumed-pr 1280 >/dev/null
rc=$?
assert_equals "$rc" "0" "record-stall exits 0 on a valid entry"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "stall-1" --path ".stalled_dispatches[0].target")
assert_equals "$out" "#1263" ".stalled_dispatches[0].target written"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "stall-1" --path ".stalled_dispatches[0].mode")
assert_equals "$out" "issue-work" ".stalled_dispatches[0].mode written"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "stall-1" --path ".stalled_dispatches[0].trigger")
assert_equals "$out" "non-terminal-return" ".stalled_dispatches[0].trigger written"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "stall-1" --path ".stalled_dispatches[0].outcome")
assert_equals "$out" "resumed" ".stalled_dispatches[0].outcome written"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "stall-1" --path ".stalled_dispatches[0].resumed_pr")
assert_equals "$out" "1280" ".stalled_dispatches[0].resumed_pr written"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "stall-1" --path ".stalled_dispatches[0].detected_at")
if [[ -n "$out" && "$out" != "null" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" ".stalled_dispatches[0].detected_at is stamped"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s (got: %s)\n' "$RED" "$RESET" ".stalled_dispatches[0].detected_at is stamped" "$out"
  fail=$((fail+1))
fi

# --resumed-pr omitted defaults to null (dropped-clean has no PR to point at).
SHIPYARD_HOME="$tmphome" bash "$helper" record-stall \
  --session-id "stall-1" --target "#1281" --mode "fix-checks-only" \
  --trigger "harness-failed" --outcome "dropped-clean" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "stall-1" --path ".stalled_dispatches[1].resumed_pr")
assert_equals "$out" "null" "omitted --resumed-pr defaults to null"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "stall-1" --path ".stalled_dispatches")
n=$(printf '%s' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
assert_equals "$n" "2" "second record-stall call appends rather than overwrites"
rm -rf "$tmphome"

# --- Falls back to [] for a pre-#1302 session file missing the field. ------
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "stall-legacy" --repo "o/r" >/dev/null
legacy_file="$tmphome/sessions/stall-legacy.json"
python3 -c "
import json
with open('$legacy_file') as f:
    d = json.load(f)
del d['stalled_dispatches']
with open('$legacy_file', 'w') as f:
    json.dump(d, f)
"
SHIPYARD_HOME="$tmphome" bash "$helper" record-stall \
  --session-id "stall-legacy" --target "#1" --mode "spike" \
  --trigger "non-terminal-return" --outcome "handed-back" >/dev/null
rc=$?
assert_equals "$rc" "0" "record-stall succeeds against a file missing .stalled_dispatches entirely"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "stall-legacy" --path ".stalled_dispatches[0].target")
assert_equals "$out" "#1" "legacy-file record-stall lands the entry via the // [] fallback"
rm -rf "$tmphome"

# --- Input validation. -------------------------------------------------
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "stall-2" --repo "o/r" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" record-stall \
  --session-id "stall-2" --target "#1" --mode "not-a-real-mode" \
  --trigger "non-terminal-return" --outcome "resumed" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "record-stall rejects an unrecognized --mode"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" record-stall \
  --session-id "stall-2" --target "#1" --mode "issue-work" \
  --trigger "bogus-trigger" --outcome "resumed" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "record-stall rejects an unrecognized --trigger"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" record-stall \
  --session-id "stall-2" --target "#1" --mode "issue-work" \
  --trigger "non-terminal-return" --outcome "bogus-outcome" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "record-stall rejects an unrecognized --outcome"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" record-stall \
  --session-id "stall-2" --target "#1" --mode "issue-work" \
  --trigger "non-terminal-return" --outcome "resumed" --resumed-pr "not-a-number" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "record-stall rejects a non-numeric --resumed-pr"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" record-stall \
  --session-id "stall-2" --mode "issue-work" \
  --trigger "non-terminal-return" --outcome "resumed" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "record-stall without --target exits 64"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "stall-2" --path ".stalled_dispatches")
assert_equals "$out" "[]" "every rejected record-stall call above left .stalled_dispatches untouched"

# Missing session file, no --allow-degraded-init: exit 3, matching update's contract.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" record-stall \
  --session-id "stall-missing" --target "#1" --mode "issue-work" \
  --trigger "non-terminal-return" --outcome "resumed" 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=3" "record-stall on missing session (no degraded-init) exits 3"

# Missing session file WITH --allow-degraded-init: recovers and writes through.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" record-stall \
  --session-id "stall-recovered" --target "#2" --mode "issue-work" \
  --trigger "harness-failed" --outcome "handed-back" \
  --allow-degraded-init --degraded-init-repo "owner/repo" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=0" "record-stall --allow-degraded-init recovers a missing file"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "stall-recovered" --path ".stalled_dispatches[0].target")
assert_equals "$out" "#2" "degraded-recovered file carries the recorded stall entry"
rm -rf "$tmphome"

echo "== record-denial (issue #1302)"
# --------------------------------------------------------------------------
# Typed alternative to a hand-built `.dispatch_denials = [...]` jq literal
# through `update`, mirroring record-stall above for the harness permission
# classifier denying a worker dispatch call outright (issue #718).

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "denial-1" --repo "o/r" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "denial-1" --path ".dispatch_denials")
assert_equals "$out" "[]" "init seeds .dispatch_denials to an empty array (#1302)"

SHIPYARD_HOME="$tmphome" bash "$helper" record-denial \
  --session-id "denial-1" --target "#1263" --mode "fix-main-ci" \
  --denial-text "git checkout -B main --force is destructive" \
  --attempt 1 --outcome "reframed" >/dev/null
rc=$?
assert_equals "$rc" "0" "record-denial exits 0 on a valid entry"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "denial-1" --path ".dispatch_denials[0].target")
assert_equals "$out" "#1263" ".dispatch_denials[0].target written"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "denial-1" --path ".dispatch_denials[0].mode")
assert_equals "$out" "fix-main-ci" ".dispatch_denials[0].mode written"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "denial-1" --path ".dispatch_denials[0].denial_text")
assert_contains "$out" "destructive" ".dispatch_denials[0].denial_text written"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "denial-1" --path ".dispatch_denials[0].attempt")
assert_equals "$out" "1" ".dispatch_denials[0].attempt written"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "denial-1" --path ".dispatch_denials[0].outcome")
assert_equals "$out" "reframed" ".dispatch_denials[0].outcome written"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "denial-1" --path ".dispatch_denials[0].denied_at")
if [[ -n "$out" && "$out" != "null" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" ".dispatch_denials[0].denied_at is stamped"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s (got: %s)\n' "$RED" "$RESET" ".dispatch_denials[0].denied_at is stamped" "$out"
  fail=$((fail+1))
fi

# Second denial on the same target appends (never overwrites) — the
# second-denial hand-back case still wants both attempts on record.
SHIPYARD_HOME="$tmphome" bash "$helper" record-denial \
  --session-id "denial-1" --target "#1263" --mode "fix-main-ci" \
  --denial-text "git checkout -B main --force is destructive" \
  --attempt 2 --outcome "handed-back" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "denial-1" --path ".dispatch_denials")
n=$(printf '%s' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
assert_equals "$n" "2" "second record-denial call appends rather than overwrites"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "denial-1" --path ".dispatch_denials[1].attempt")
assert_equals "$out" "2" ".dispatch_denials[1].attempt records the second attempt"
rm -rf "$tmphome"

# --- Falls back to [] for a pre-#1302 session file missing the field. ------
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "denial-legacy" --repo "o/r" >/dev/null
legacy_file="$tmphome/sessions/denial-legacy.json"
python3 -c "
import json
with open('$legacy_file') as f:
    d = json.load(f)
del d['dispatch_denials']
with open('$legacy_file', 'w') as f:
    json.dump(d, f)
"
SHIPYARD_HOME="$tmphome" bash "$helper" record-denial \
  --session-id "denial-legacy" --target "main" --mode "fix-main-ci" \
  --denial-text "denied" --attempt 1 --outcome "reframed" >/dev/null
rc=$?
assert_equals "$rc" "0" "record-denial succeeds against a file missing .dispatch_denials entirely"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "denial-legacy" --path ".dispatch_denials[0].target")
assert_equals "$out" "main" "legacy-file record-denial lands the entry via the // [] fallback"
rm -rf "$tmphome"

# --- Input validation. -------------------------------------------------
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "denial-2" --repo "o/r" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" record-denial \
  --session-id "denial-2" --target "#1" --mode "not-a-real-mode" \
  --denial-text "x" --attempt 1 --outcome "reframed" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "record-denial rejects an unrecognized --mode"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" record-denial \
  --session-id "denial-2" --target "#1" --mode "issue-work" \
  --denial-text "x" --attempt 3 --outcome "reframed" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "record-denial rejects an --attempt outside 1|2"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" record-denial \
  --session-id "denial-2" --target "#1" --mode "issue-work" \
  --denial-text "x" --attempt 1 --outcome "bogus-outcome" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "record-denial rejects an unrecognized --outcome"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" record-denial \
  --session-id "denial-2" --target "#1" --mode "issue-work" \
  --attempt 1 --outcome "reframed" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "record-denial without --denial-text exits 64"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "denial-2" --path ".dispatch_denials")
assert_equals "$out" "[]" "every rejected record-denial call above left .dispatch_denials untouched"

# Missing session file, no --allow-degraded-init: exit 3, matching update's contract.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" record-denial \
  --session-id "denial-missing" --target "#1" --mode "issue-work" \
  --denial-text "x" --attempt 1 --outcome "reframed" 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=3" "record-denial on missing session (no degraded-init) exits 3"

# Missing session file WITH --allow-degraded-init: recovers and writes through.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" record-denial \
  --session-id "denial-recovered" --target "#2" --mode "issue-work" \
  --denial-text "x" --attempt 1 --outcome "reframed" \
  --allow-degraded-init --degraded-init-repo "owner/repo" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=0" "record-denial --allow-degraded-init recovers a missing file"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "denial-recovered" --path ".dispatch_denials[0].target")
assert_equals "$out" "#2" "degraded-recovered file carries the recorded denial entry"
rm -rf "$tmphome"

# --- Cross-repo write guard applies to both new subcommands too (issue #365). ---
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "guard-1" --repo "owner/repo-a" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" record-stall \
  --session-id "guard-1" --target "#1" --mode "issue-work" \
  --trigger "non-terminal-return" --outcome "resumed" \
  --expected-repo "owner/repo-b" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=66" "record-stall refuses a cross-repo write"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" record-denial \
  --session-id "guard-1" --target "#1" --mode "issue-work" \
  --denial-text "x" --attempt 1 --outcome "reframed" \
  --expected-repo "owner/repo-b" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=66" "record-denial refuses a cross-repo write"
rm -rf "$tmphome"

echo "== issue #1561 — flag-shaped hot-path writes (set-slot / release-slot / --set-file)"
# Post-relocation the worktree-isolation guard refuses an `update --set`
# whose value carries a JSON object literal. These three surfaces let every
# hot-path write avoid putting one on the command line.
tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "slot-1561" --repo "owner/repo" >/dev/null

SHIPYARD_HOME="$tmphome" bash "$helper" set-slot --session-id "slot-1561" \
  --slot-id "slot-1" --kind issue --target "#4823" --agent-id "agent-abc" \
  --model opus --started-at "2026-09-14T12:50:00Z" \
  --hard-path "src/a.ts" --hard-path "src/b.ts" --soft-path "CHANGELOG.md" \
  --expected-repo "owner/repo" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "slot-1561" --path '.in_flight["slot-1"].target')
assert_equals "$out" "#4823" "set-slot writes the slot's target"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "slot-1561" --path '.in_flight["slot-1"].claimed_paths.hard | join(",")')
assert_equals "$out" "src/a.ts,src/b.ts" "set-slot records repeated --hard-path values in order"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "slot-1561" --path '.in_flight["slot-1"].claimed_paths.soft | join(",")')
assert_equals "$out" "CHANGELOG.md" "set-slot records --soft-path values"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "slot-1561" --path '.in_flight["slot-1"] | [.agent_id, .model, .started_at, has("version_slot")] | map(tostring) | join(",")')
assert_equals "$out" "agent-abc,opus,2026-09-14T12:50:00Z,false" "set-slot records agent_id/model/started_at and omits an unset version_slot"

# A second slot merges rather than replacing .in_flight wholesale; a value
# containing jq metacharacters is stored literally, never evaluated.
SHIPYARD_HOME="$tmphome" bash "$helper" set-slot --session-id "slot-1561" \
  --slot-id 'slot-"2"' --kind fix-checks --target '#9") | .pwned = ("x' \
  --version-slot "4.55.4" --worktree-path "/tmp/wt-2" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "slot-1561" --path '.in_flight | keys | length')
assert_equals "$out" "2" "set-slot merges a second slot alongside the first"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "slot-1561" --path '.in_flight["slot-\"2\""].target')
assert_equals "$out" '#9") | .pwned = ("x' "set-slot stores a jq-metacharacter value literally"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "slot-1561" --path 'has("pwned")')
assert_equals "$out" "false" "set-slot never evaluates caller-supplied text as jq"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "slot-1561" --path '.in_flight["slot-\"2\""] | [.model, .version_slot, (.agent_id|tostring)] | join(",")')
assert_equals "$out" "default,4.55.4,null" "set-slot defaults model to \"default\", agent_id to null, and records --version-slot"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "slot-1561" --path '.in_flight["slot-\"2\""].worktree_path')
assert_equals "$out" "/tmp/wt-2" "set-slot records --worktree-path"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" set-slot --session-id "slot-1561" \
  --slot-id "slot-3" --kind bogus --target "#1" 2>&1; echo "rc=$?")
assert_equals "$(printf '%s' "$out" | tail -1)" "rc=64" "set-slot rejects an unknown --kind"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" set-slot --session-id "slot-1561" --kind issue --target "#1" 2>&1; echo "rc=$?")
assert_equals "$(printf '%s' "$out" | tail -1)" "rc=64" "set-slot requires --slot-id"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" set-slot --session-id "slot-1561" \
  --slot-id "slot-3" --kind issue --target "#1" --expected-repo "owner/other" 2>&1; echo "rc=$?")
assert_equals "$(printf '%s' "$out" | tail -1)" "rc=66" "set-slot honors the cross-repo write guard"

SHIPYARD_HOME="$tmphome" bash "$helper" release-slot --session-id "slot-1561" --slot-id "slot-1" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "slot-1561" --path '.in_flight | keys | join(",")')
assert_equals "$out" 'slot-"2"' "release-slot removes only the named slot"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" release-slot --session-id "slot-1561" --slot-id "slot-1" 2>&1; echo "rc=$?")
assert_equals "$(printf '%s' "$out" | tail -1)" "rc=0" "release-slot on an absent slot is an idempotent no-op"

# --set-file: a multi-line expression with an object literal, read from disk.
setfile="$tmphome/expr.jq"
cat > "$setfile" <<'EXPR'
.main_ci = {
  status: "green",
  checked_at: "2026-09-14T12:51:00Z"
}
EXPR
SHIPYARD_HOME="$tmphome" bash "$helper" update --session-id "slot-1561" \
  --set '.raw_backlog = [4821]' --set-file "$setfile" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "slot-1561" --path '[.main_ci.status, (.raw_backlog|tostring)] | join(",")')
assert_equals "$out" "green,[4821]" "update --set-file applies a file-sourced expression alongside --set"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" update --session-id "slot-1561" --set-file "$tmphome/nope.jq" 2>&1; echo "rc=$?")
assert_equals "$(printf '%s' "$out" | tail -1)" "rc=64" "update --set-file rejects a missing file"
: > "$tmphome/empty.jq"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" update --session-id "slot-1561" --set-file "$tmphome/empty.jq" 2>&1; echo "rc=$?")
assert_equals "$(printf '%s' "$out" | tail -1)" "rc=64" "update --set-file rejects an empty file"

# Degraded-init passthrough: set-slot recovers a vanished session file.
SHIPYARD_HOME="$tmphome" bash "$helper" set-slot --session-id "slot-gone" \
  --slot-id "slot-1" --kind issue --target "#5" \
  --allow-degraded-init --degraded-init-repo "owner/repo" >/dev/null 2>&1
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "slot-gone" --path '.in_flight["slot-1"].target')
assert_equals "$out" "#5" "set-slot --allow-degraded-init recovers a missing session file"
rm -rf "$tmphome"

echo
echo "Results: ${GREEN}${pass} passed${RESET}, ${RED}${fail} failed${RESET}"
[[ $fail -eq 0 ]]
