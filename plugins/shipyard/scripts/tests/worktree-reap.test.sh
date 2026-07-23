#!/usr/bin/env bash
# Test suite for scripts/worktree-reap.sh.
#
# Covers `classify-lock`, the only subcommand the orchestrator's
# end-of-session cleanup (commands/do-work.md → step 3) drives.
#
# What we're guarding against (issue #138): the end-of-session cleanup's
# liveness check used to defer reaping whenever the lock PID was alive —
# but the harness writes the **orchestrator's** PID into every dispatched
# agent's lock, so the check deferred every worktree. The fix adds a
# `self-ancestor` classification: lock PIDs that are alive AND in our
# own process ancestor chain are NOT peers — they're the orchestrator
# about to retire its own worktree, and reaping is safe.
#
# What we're guarding against (issue #263): the ancestor-walk approach
# from #138 can still mis-classify in the wild. Two failure modes seen:
#   (a) Intermediate harness layer returns empty PPID, causing the walk
#       to break before reaching the orchestrator PID.
#   (b) Subagent invocation (fix-rebase / fix-checks worker calling
#       classify-lock for diagnostic introspection) — the subagent's
#       process tree doesn't actually reach back to the orchestrator,
#       so the ancestor walk correctly reports peer-alive, but the
#       lock IS the orchestrator's. The env var `SHIPYARD_ORCHESTRATOR_PID`
#       (or `--orchestrator-pid <N>` flag) lets the caller declare the
#       authoritative orchestrator PID, short-circuiting the ancestor walk.
#
# Test matrix:
#   1) no lock file        → `no-lock`
#   2) lock with dead PID  → `dead`
#   3) lock with malformed content (no PID)
#                          → `dead` (extraction failed → treat as dead)
#   4) lock with self PID  → `self-ancestor`  (THE bug-fix path)
#   5) lock with parent PID
#                          → `self-ancestor`  (ancestor walk works)
#   6) lock with sibling-process PID
#                          → `peer-alive`     (original behaviour preserved
#                                              for genuine peer agents)
#   7) bad usage           → exit 64
#   8) regression guard: canonical lock format with peer/own PID
#                          → `peer-alive` / `self-ancestor`
#   9) issue #263 — SHIPYARD_ORCHESTRATOR_PID env var matches lock PID
#                          → `self-ancestor` (env-var short-circuit fires)
#  10) issue #263 — SHIPYARD_ORCHESTRATOR_PID env var set but lock PID
#       is a sibling (peer)
#                          → `peer-alive` (env var doesn't override peer
#                                          check; only short-circuits on
#                                          actual match)
#  11) issue #263 — --orchestrator-pid <N> flag matches lock PID
#                          → `self-ancestor` (flag-form works)
#  12) issue #263 — --orchestrator-pid takes precedence over env var
#  13) issue #263 — env-var-declared PID is dead but lock PID alive and
#       matches it — defends against stale-env-var-recycled-PID match
#                          → ancestor walk continues (no false short-circuit)
#  14) issue #263 — bad flag values exit 64
#  15-17) detect-orchestrator-pid match / no-match / exit code
#  18-30) issue #280 — find-orphan-orchestrators subcommand covers:
#         - empty layouts (no worktrees dir, no orchestrator-* entries)
#         - happy-path orphan with missing session file
#         - current session's own worktree never emitted
#         - alive PID session file → not orphan
#         - dead PID / null pid session file → orphan
#         - multiple orphans → multiple lines
#         - bad-usage cases (missing flags, unknown flag, positional arg)
#         - --flag=value form parity with --flag value form
#  58-66) issue #509 — reap-session-worktrees targeted this-session reap
#  67-75) issue #513 — derive-session-id picks the NEWEST orchestrator-*
#         worktree's stash (not the oldest orphan in listing order):
#         - empty layout, single-worktree common case
#         - the repro: live (newest) wins over 5 accumulated older orphans
#         - recency beats lexical name order
#         - candidate without/with empty stash skipped for an older valid one
#         - agent-* worktrees ignored; stash contents whitespace-trimmed
#         - bad-usage cases (missing flag, unknown flag)
#  90-96) issue #836 fix 1 — classify-all bulk classification: empty layout,
#         missing --repo-root, a mixed batch resolving no-lock / dead /
#         self-ancestor / peer-alive in ONE call, oldest-first mtime
#         ordering, peer-alive-stale via --peer-stale-min, bad-usage cases,
#         no .git/worktrees dir at all
#  97-104) issue #836 fix 2 — reap-stale bounded/checkpointed sweep:
#         dry-run, real run + phase-tagged audit lines, --max-per-session
#         cap (oldest-first) leaving the rest in `remaining`,
#         --exclude-agent-id in-flight guard (issue #832) invisible to the
#         summary, peer-alive deferred without eating the cap, two
#         successive capped runs demonstrating forward-progress checkpoint
#         behavior with no separate state file, bad-usage cases,
#         --max-per-session 0
#
# Pure bash + `ps`. Run with:
#   bash plugins/shipyard/scripts/tests/worktree-reap.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../worktree-reap.sh"

if [[ ! -f "$helper" ]]; then
  echo "FAIL: helper not found at $helper" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

tmpdir=$(mktemp -d -t worktree-reap-test.XXXXXX)
# shellcheck disable=SC2064
trap "rm -rf '$tmpdir'; [ -n \"\${sibling_pid:-}\" ] && kill -0 \"\$sibling_pid\" 2>/dev/null && kill \"\$sibling_pid\" 2>/dev/null; true" EXIT

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

assert_exit_code() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (expected exit %s, got %s)\n' "$RED" "$RESET" "$label" "$expected" "$actual"
    fail=$((fail+1))
  fi
}

# Helper to invoke the script and capture stdout + exit code.
run_classify() {
  local lock_path="$1"
  bash "$helper" classify-lock "$lock_path" 2>/dev/null
}

# Helper to invoke classify-lock with explicit extra args (e.g. flags).
# Used by the issue #263 tests that exercise --orchestrator-pid.
run_classify_with_args() {
  local lock_path="$1"
  shift
  bash "$helper" classify-lock "$lock_path" "$@" 2>/dev/null
}

# Helper to invoke classify-lock with SHIPYARD_ORCHESTRATOR_PID env var.
# Used by the issue #263 tests that exercise the env-var path.
run_classify_with_env() {
  local lock_path="$1"
  local orch_pid="$2"
  SHIPYARD_ORCHESTRATOR_PID="$orch_pid" bash "$helper" classify-lock "$lock_path" 2>/dev/null
}

echo "worktree-reap.sh tests (issue #138)"
echo

# --- (1) no lock file: file path doesn't exist ---
result=$(run_classify "$tmpdir/no-such-lock")
assert_equals "$result" "no-lock" \
  "(1) missing lock file → 'no-lock'"

# --- (2) lock with dead PID ---
# Spawn a short-lived process, capture its PID, wait for it to exit, then
# use that (now-reaped) PID. There's a tiny race where the kernel could
# recycle the PID before we run the check; mitigate by picking a PID that
# `ps` confirms is dead at write time.
(true) &
dead_pid=$!
wait "$dead_pid" 2>/dev/null
# Confirm it's actually dead before relying on it.
while ps -p "$dead_pid" -o pid= >/dev/null 2>&1; do
  sleep 0.05
done
lock_dead="$tmpdir/dead.lock"
cat > "$lock_dead" <<EOF
claude agent agent-test-dead (pid $dead_pid)
EOF
result=$(run_classify "$lock_dead")
assert_equals "$result" "dead" \
  "(2) lock with dead PID → 'dead'"

# --- (2a) issue #832 — regression pin: lock present, PID dead, worktree
# metadata directory FRESHLY CREATED. This is the literal shape of a
# just-dispatched worker whose harness-written lock names a PID that is
# already gone (an intermediate spawn-time process, not the long-lived
# agent process) — classify-lock currently has no signal to distinguish
# this from a genuinely stale/abandoned lock, and returns 'dead' (reap-
# eligible) either way, even though the worker may be actively running.
# The #832 repro: session do-work-20260723T102624Z dispatched an
# Agent-tool worker into a brand-new agent-* worktree, and a setup-3b-style
# sweep running concurrently classified that same, seconds-old, live
# worktree as 'dead'.
#
# This fixture pins that CURRENT behavior explicitly — using its own fresh
# subdirectory (rather than only incidentally exercising it via test (2)'s
# shared $tmpdir) so the "directory freshly created" precondition is
# asserted, not assumed. If a future change teaches classify-lock to treat
# a dead PID + fresh directory as 'unknown' instead of 'dead' (issue #832
# suggested fix 2 — NOT implemented here; evaluated and skipped because it
# would flip this same fresh-tmpdir shape in tests (2)/(3)/(13) above/below,
# which is exactly the "destabilizes existing callers/tests" case #832
# says to avoid), this assertion is the one to update.
#
# The load-bearing fix for the underlying danger is NOT a classify-lock
# heuristic — it's orchestrator-side: every sweep-style reap loop now
# checks `.in_flight` membership for the candidate worktree BEFORE ever
# consulting classify-lock, and skips outright on a match (in-flight
# membership is authoritative liveness; the lock file is only a fallback
# for worktrees the session doesn't own). See commands/do-work/dont.md's
# "Don't reap a live-PID worktree" bullet and
# commands/do-work-RATIONALE.md's matching section.
fresh_wt_dir="$tmpdir/fresh-worktree-metadata-dir"
mkdir -p "$fresh_wt_dir"
(true) &
dead_pid_fresh=$!
wait "$dead_pid_fresh" 2>/dev/null
while ps -p "$dead_pid_fresh" -o pid= >/dev/null 2>&1; do
  sleep 0.05
done
lock_fresh="$fresh_wt_dir/locked"
cat > "$lock_fresh" <<EOF
claude agent agent-test-fresh-dead (pid $dead_pid_fresh)
EOF
# Confirm the fixture's own premise: the directory really is fresh (well
# under any plausible staleness floor — #755's default peer-alive-stale
# floor is 60 minutes).
fresh_dir_mtime=$(stat -c %Y "$fresh_wt_dir" 2>/dev/null || stat -f %m "$fresh_wt_dir" 2>/dev/null || echo "")
fresh_now=$(date +%s 2>/dev/null || echo "")
if [ -n "$fresh_dir_mtime" ] && [ -n "$fresh_now" ]; then
  fresh_dir_age_sec=$((fresh_now - fresh_dir_mtime))
else
  fresh_dir_age_sec=0
fi
if [ "$fresh_dir_age_sec" -lt 300 ] 2>/dev/null; then
  result=$(run_classify "$lock_fresh")
  assert_equals "$result" "dead" \
    "(2a) issue #832 regression pin: dead PID + freshly-created worktree dir (age ${fresh_dir_age_sec}s) still classifies 'dead' — reap-eligible from the helper's own view despite the worker having just been dispatched; the in-flight-membership exclusion (not this classifier) is the load-bearing guard against reaping it"
else
  printf '  %sSKIP%s  (2a) fixture directory age (%ss) unexpectedly not fresh — skipping\n' "$GREEN" "$RESET" "$fresh_dir_age_sec"
fi

# --- (3) lock with malformed content (no parseable PID) ---
lock_malformed="$tmpdir/malformed.lock"
cat > "$lock_malformed" <<EOF
some other content with no pid syntax
EOF
result=$(run_classify "$lock_malformed")
assert_equals "$result" "dead" \
  "(3) malformed lock (no PID) → 'dead' (extraction-failed treated as dead)"

# --- (4) lock with self PID — THE bug-fix path ---
# Use $$ (this shell's PID). The orchestrator's PID is the analog in
# production; the ancestor walk should resolve $$ as self-ancestor.
lock_self="$tmpdir/self.lock"
cat > "$lock_self" <<EOF
claude agent agent-test-self (pid $$)
EOF
result=$(run_classify "$lock_self")
assert_equals "$result" "self-ancestor" \
  "(4) lock with our own PID → 'self-ancestor' (issue #138 fix)"

# --- (5) lock with parent PID (PPID) ---
# In production this is the more important case: the harness sits between
# this shell and the orchestrator, so the orchestrator's PID is a
# grandparent (or higher), not direct parent. But PPID is the simplest
# proxy that proves the walk follows the chain at all.
if [ "$PPID" != "1" ] && [ "$PPID" != "0" ]; then
  lock_parent="$tmpdir/parent.lock"
  cat > "$lock_parent" <<EOF
claude agent agent-test-parent (pid $PPID)
EOF
  result=$(run_classify "$lock_parent")
  assert_equals "$result" "self-ancestor" \
    "(5) lock with PPID → 'self-ancestor' (ancestor-walk follows chain)"
else
  printf '  %sSKIP%s  (5) PPID resolves to %s, can'\''t test ancestor chain here\n' \
    "$GREEN" "$RESET" "$PPID"
fi

# --- (6) lock with sibling-process PID (peer-alive) ---
# Spawn a long-running background process. It's a CHILD of our shell, so
# its PID is NOT in our ancestor chain. From the classifier's perspective
# it's indistinguishable from "another live Claude Code instance's
# orchestrator" — which is exactly the peer case we still want to defer
# on.
(sleep 30) &
sibling_pid=$!
# Defensive — make sure the child is actually alive before we lock against it.
sleep 0.05
if ps -p "$sibling_pid" -o pid= >/dev/null 2>&1; then
  lock_peer="$tmpdir/peer.lock"
  cat > "$lock_peer" <<EOF
claude agent agent-test-peer (pid $sibling_pid)
EOF
  result=$(run_classify "$lock_peer")
  assert_equals "$result" "peer-alive" \
    "(6) lock with sibling-process PID → 'peer-alive' (defer-on-peer preserved)"
else
  printf '  %sFAIL%s  (6) couldn'\''t spawn sibling process for peer-alive test\n' \
    "$RED" "$RESET"
  fail=$((fail+1))
fi
# Clean up sibling early so we don't leave a 30s sleep around.
[ -n "${sibling_pid:-}" ] && kill "$sibling_pid" 2>/dev/null
wait "$sibling_pid" 2>/dev/null

# --- (7) bad usage: missing path ---
bash "$helper" classify-lock 2>/dev/null
assert_exit_code "$?" "64" \
  "(7) classify-lock without path → exit 64"

bash "$helper" 2>/dev/null
assert_exit_code "$?" "64" \
  "(7a) no subcommand → exit 64"

bash "$helper" unknown-cmd 2>/dev/null
assert_exit_code "$?" "64" \
  "(7b) unknown subcommand → exit 64"

# --- (8) regression guard: classify-lock with an alive-but-not-self PID
# extracted from a real-looking lock-file content (matches the format the
# Claude Code harness writes). Reuses the sibling-process technique above
# but with the canonical lock format the issue body cited:
#   "claude agent agent-a75f16ae8b3e8379e (pid 53391)"
(sleep 30) &
sibling_pid=$!
sleep 0.05
if ps -p "$sibling_pid" -o pid= >/dev/null 2>&1; then
  lock_canonical="$tmpdir/canonical.lock"
  printf 'claude agent agent-a75f16ae8b3e8379e (pid %d)\n' "$sibling_pid" > "$lock_canonical"
  result=$(run_classify "$lock_canonical")
  assert_equals "$result" "peer-alive" \
    "(8) canonical lock format with peer PID → 'peer-alive'"

  # Now overwrite the same file with OUR PID and the same canonical shape —
  # this is the exact bug from issue #138 (orchestrator PID in agent lock).
  printf 'claude agent agent-a75f16ae8b3e8379e (pid %d)\n' "$$" > "$lock_canonical"
  result=$(run_classify "$lock_canonical")
  assert_equals "$result" "self-ancestor" \
    "(8a) canonical lock format with orchestrator-own PID → 'self-ancestor' (issue #138 repro)"
fi
[ -n "${sibling_pid:-}" ] && kill "$sibling_pid" 2>/dev/null
wait "$sibling_pid" 2>/dev/null

# --- (9) issue #263 — SHIPYARD_ORCHESTRATOR_PID matches lock PID ---
# The core fix scenario: classify-lock is called from a context where the
# ancestor walk WOULD NOT find the orchestrator's PID (sibling-process PID
# stands in for the orchestrator since we can't easily synthesize an
# unreachable ancestor in a test). With the env var set to the same PID
# that's in the lock file, classify-lock should short-circuit to
# `self-ancestor` without consulting the ancestor chain.
(sleep 30) &
sibling_pid=$!
sleep 0.05
if ps -p "$sibling_pid" -o pid= >/dev/null 2>&1; then
  lock_env_match="$tmpdir/env-match.lock"
  printf 'claude agent agent-test-env-match (pid %d)\n' "$sibling_pid" > "$lock_env_match"
  result=$(run_classify_with_env "$lock_env_match" "$sibling_pid")
  assert_equals "$result" "self-ancestor" \
    "(9) SHIPYARD_ORCHESTRATOR_PID matches lock PID → 'self-ancestor' (issue #263 fix)"
fi

# --- (10) SHIPYARD_ORCHESTRATOR_PID set but lock PID is a different peer ---
# The env var only short-circuits on an actual PID match. A lock PID that's
# alive but NOT the declared orchestrator AND NOT in our ancestor chain
# should still classify as peer-alive — the env var doesn't grant blanket
# permission to reap.
if [ -n "${sibling_pid:-}" ] && ps -p "$sibling_pid" -o pid= >/dev/null 2>&1; then
  # Spawn a second sibling — its PID is not the env-declared orchestrator PID
  (sleep 30) &
  sibling2_pid=$!
  sleep 0.05
  if ps -p "$sibling2_pid" -o pid= >/dev/null 2>&1; then
    lock_env_no_match="$tmpdir/env-no-match.lock"
    printf 'claude agent agent-test-env-no-match (pid %d)\n' "$sibling2_pid" > "$lock_env_no_match"
    # env var declares sibling_pid, but lock holds sibling2_pid → still peer
    result=$(run_classify_with_env "$lock_env_no_match" "$sibling_pid")
    assert_equals "$result" "peer-alive" \
      "(10) env var set but lock PID is a different peer → 'peer-alive' (env var doesn't grant blanket reap)"
  fi
  [ -n "${sibling2_pid:-}" ] && kill "$sibling2_pid" 2>/dev/null
  wait "$sibling2_pid" 2>/dev/null
fi
[ -n "${sibling_pid:-}" ] && kill "$sibling_pid" 2>/dev/null
wait "$sibling_pid" 2>/dev/null

# --- (11) --orchestrator-pid <N> flag matches lock PID ---
(sleep 30) &
sibling_pid=$!
sleep 0.05
if ps -p "$sibling_pid" -o pid= >/dev/null 2>&1; then
  lock_flag_match="$tmpdir/flag-match.lock"
  printf 'claude agent agent-test-flag-match (pid %d)\n' "$sibling_pid" > "$lock_flag_match"
  result=$(run_classify_with_args "$lock_flag_match" --orchestrator-pid "$sibling_pid")
  assert_equals "$result" "self-ancestor" \
    "(11) --orchestrator-pid flag matches lock PID → 'self-ancestor'"
fi

# --- (12) --orchestrator-pid flag takes precedence over env var ---
# Set env var to a stale/wrong PID, pass the actual orchestrator PID via flag.
# Result should respect the flag, not the env var.
if [ -n "${sibling_pid:-}" ] && ps -p "$sibling_pid" -o pid= >/dev/null 2>&1; then
  lock_precedence="$tmpdir/precedence.lock"
  printf 'claude agent agent-test-precedence (pid %d)\n' "$sibling_pid" > "$lock_precedence"
  # env var = 1 (init, definitely not the lock PID), flag = sibling_pid (matches lock)
  # The flag must win → self-ancestor.
  result=$(SHIPYARD_ORCHESTRATOR_PID=1 bash "$helper" classify-lock "$lock_precedence" \
    --orchestrator-pid "$sibling_pid" 2>/dev/null)
  assert_equals "$result" "self-ancestor" \
    "(12) --orchestrator-pid flag wins over SHIPYARD_ORCHESTRATOR_PID env var"
fi
[ -n "${sibling_pid:-}" ] && kill "$sibling_pid" 2>/dev/null
wait "$sibling_pid" 2>/dev/null

# --- (13) stale env-var PID — no false self-ancestor on dead orchestrator ---
# The env var declares a PID; the lock holds the same PID. But the declared
# PID is dead. The lock check should classify as 'dead' (the pid_alive gate
# fires first, before the env-var short-circuit) — NOT self-ancestor.
(true) &
dead_pid_for_env=$!
wait "$dead_pid_for_env" 2>/dev/null
while ps -p "$dead_pid_for_env" -o pid= >/dev/null 2>&1; do
  sleep 0.05
done
lock_stale_env="$tmpdir/stale-env.lock"
cat > "$lock_stale_env" <<EOF
claude agent agent-test-stale-env (pid $dead_pid_for_env)
EOF
result=$(run_classify_with_env "$lock_stale_env" "$dead_pid_for_env")
assert_equals "$result" "dead" \
  "(13) env var matches lock PID but PID is dead → 'dead' (pid_alive gate fires first)"

# --- (14) bad flag values exit 64 ---
bash "$helper" classify-lock "$tmpdir/anything.lock" --orchestrator-pid 2>/dev/null
assert_exit_code "$?" "64" \
  "(14) --orchestrator-pid with no value → exit 64"

bash "$helper" classify-lock "$tmpdir/anything.lock" --orchestrator-pid notanumber 2>/dev/null
assert_exit_code "$?" "64" \
  "(14a) --orchestrator-pid with non-numeric value → exit 64"

bash "$helper" classify-lock "$tmpdir/anything.lock" --orchestrator-pid=notanumber 2>/dev/null
assert_exit_code "$?" "64" \
  "(14b) --orchestrator-pid=notanumber → exit 64"

bash "$helper" classify-lock "$tmpdir/anything.lock" --unknown-flag 2>/dev/null
assert_exit_code "$?" "64" \
  "(14c) unknown flag → exit 64"

# Malformed env-var value also surfaces as exit 64 (a config bug we want loud).
SHIPYARD_ORCHESTRATOR_PID=notanumber bash "$helper" classify-lock "$tmpdir/anything.lock" 2>/dev/null
assert_exit_code "$?" "64" \
  "(14d) SHIPYARD_ORCHESTRATOR_PID=notanumber → exit 64"

# Empty env var is treated as unset — same as not passing the env var at all.
# `$tmpdir/anything.lock` doesn't exist → no-lock.
SHIPYARD_ORCHESTRATOR_PID="" bash "$helper" classify-lock "$tmpdir/anything.lock" >/dev/null 2>&1
exit_code=$?
assert_exit_code "$exit_code" "0" \
  "(14e) SHIPYARD_ORCHESTRATOR_PID='' (empty) treated as unset, classify-lock runs normally"

# --- (15) detect-orchestrator-pid — match on this test process's own
# basename. We invoke a fresh bash subprocess to run the helper, so the
# walk will find a process whose `comm` matches the test runner. We pick
# the comm by reading our own `$$`'s comm dynamically — that way the
# test is robust across shells (bash, zsh) and OS conventions for the
# `ps -o comm=` output format.
own_comm=$(basename "$(ps -o comm= -p $$ 2>/dev/null | tr -d ' ')" 2>/dev/null)
if [ -n "$own_comm" ]; then
  # Spawn a child shell of OUR own kind so the detection finds it. The
  # helper walks via PPID, so the child's parent is our test runner. The
  # child sees its own ancestor chain including our PID with our comm.
  # Use process substitution so we don't fork a subshell that changes the
  # process tree shape.
  result=$("$own_comm" "$helper" detect-orchestrator-pid "$own_comm" 2>/dev/null)
  if [ -n "$result" ] && [[ "$result" =~ ^[0-9]+$ ]]; then
    printf '  %sPASS%s  (15) detect-orchestrator-pid with override finds an ancestor PID (own_comm=%s, found=%s)\n' \
      "$GREEN" "$RESET" "$own_comm" "$result"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  (15) detect-orchestrator-pid returned empty / non-numeric: %s (own_comm=%s)\n' \
      "$RED" "$RESET" "$result" "$own_comm"
    fail=$((fail+1))
  fi
else
  printf '  %sSKIP%s  (15) could not determine own comm — skipping detect-orchestrator-pid match test\n' \
    "$GREEN" "$RESET"
fi

# --- (16) detect-orchestrator-pid — non-existent comm name returns empty.
result=$(bash "$helper" detect-orchestrator-pid this-comm-does-not-exist-anywhere 2>/dev/null)
assert_equals "${result:-EMPTY}" "EMPTY" \
  "(16) detect-orchestrator-pid with unknown comm-name returns empty stdout"

# --- (17) detect-orchestrator-pid — exit code 0 whether or not a match.
bash "$helper" detect-orchestrator-pid this-comm-does-not-exist-anywhere >/dev/null 2>&1
assert_exit_code "$?" "0" \
  "(17) detect-orchestrator-pid exits 0 even on no-match (caller decides)"

# --- find-orphan-orchestrators (issue #280) ---
#
# These tests build a synthetic worktrees layout under $tmpdir and a
# synthetic SHIPYARD_HOME so the discovery logic can be exercised
# without touching the real repo or real session files. Each test
# resets the fake layout before running.

echo
echo "find-orphan-orchestrators tests (issue #280)"
echo

# Build a fake repo-root with a worktrees dir.
fake_repo="$tmpdir/fake-repo"
mkdir -p "$fake_repo/.claude/worktrees"

# Build a fake SHIPYARD_HOME with a sessions dir.
fake_shipyard_home="$tmpdir/fake-shipyard"
mkdir -p "$fake_shipyard_home/sessions"

# Helper to invoke find-orphan-orchestrators with our fake SHIPYARD_HOME.
run_find_orphans() {
  SHIPYARD_HOME="$fake_shipyard_home" bash "$helper" find-orphan-orchestrators \
    --repo-root "$fake_repo" \
    --current-session-id "$1" 2>/dev/null
}

# Reset the fake layout to a known-empty state.
reset_fake_layout() {
  rm -rf "$fake_repo/.claude/worktrees"/orchestrator-*
  rm -f "$fake_shipyard_home/sessions"/*.json
}

# --- (18) no worktrees dir at all → empty output, exit 0 ---
no_wt_repo="$tmpdir/no-wt-repo"
mkdir -p "$no_wt_repo"
result=$(SHIPYARD_HOME="$fake_shipyard_home" bash "$helper" find-orphan-orchestrators \
  --repo-root "$no_wt_repo" --current-session-id "current-sess" 2>/dev/null)
exit_code=$?
assert_equals "${result:-EMPTY}" "EMPTY" \
  "(18) no .claude/worktrees dir → empty output"
assert_exit_code "$exit_code" "0" \
  "(18a) no .claude/worktrees dir → exit 0"

# --- (19) worktrees dir present but no orchestrator-* entries → empty ---
reset_fake_layout
mkdir -p "$fake_repo/.claude/worktrees/agent-abc"   # only agent-*, no orchestrator-*
result=$(run_find_orphans "current-sess")
assert_equals "${result:-EMPTY}" "EMPTY" \
  "(19) only agent-* worktrees, no orchestrator-* → empty output"

# --- (20) orphan: orchestrator-<dead> with NO session file → emit ---
# The exact failure mode the issue reports: prior session's cleanup got
# far enough to flush + delete its session file, but crashed before
# reaping its own worktree.
reset_fake_layout
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-dead-session-1"
result=$(run_find_orphans "current-sess")
assert_equals "$result" "$fake_repo/.claude/worktrees/orchestrator-dead-session-1" \
  "(20) orphan with no session file → emitted (the issue #280 repro case)"

# --- (21) current session's own orchestrator worktree → NOT emitted ---
# Even when its session file is missing — the in-flight session may
# have race conditions around its own file, but we must NEVER reap
# the running session's worktree out from under itself.
reset_fake_layout
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-current-sess"
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-dead-session-2"
result=$(run_find_orphans "current-sess")
assert_equals "$result" "$fake_repo/.claude/worktrees/orchestrator-dead-session-2" \
  "(21) current session's own worktree excluded even when own session file is missing"

# --- (22) session file PRESENT with live PID → NOT emitted (peer-alive) ---
# is-active should exit 0, this helper treats that as "active session,
# skip." Use our own $$ as the live PID — same pattern as classify-lock
# tests 4/5.
reset_fake_layout
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-live-session"
cat > "$fake_shipyard_home/sessions/live-session.json" <<EOF
{"session_id":"live-session","pid":$$}
EOF
result=$(run_find_orphans "current-sess")
assert_equals "${result:-EMPTY}" "EMPTY" \
  "(22) session file present + PID alive → not emitted (defer)"

# --- (23) session file PRESENT but PID dead → emitted (orphan) ---
# Spawn-and-reap pattern (matches test 2 in the classify-lock suite).
(true) &
dead_pid_for_orph=$!
wait "$dead_pid_for_orph" 2>/dev/null
while ps -p "$dead_pid_for_orph" -o pid= >/dev/null 2>&1; do
  sleep 0.05
done
reset_fake_layout
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-dead-pid-session"
cat > "$fake_shipyard_home/sessions/dead-pid-session.json" <<EOF
{"session_id":"dead-pid-session","pid":$dead_pid_for_orph}
EOF
result=$(run_find_orphans "current-sess")
assert_equals "$result" "$fake_repo/.claude/worktrees/orchestrator-dead-pid-session" \
  "(23) session file present + PID dead → emitted (is-active exits non-zero)"

# --- (24) session file PRESENT but pid is null → emitted (treated as inactive) ---
# Older session files written before the pid field existed: is-active
# falls through to exit 1 → orphan from this helper's perspective.
reset_fake_layout
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-null-pid-session"
cat > "$fake_shipyard_home/sessions/null-pid-session.json" <<EOF
{"session_id":"null-pid-session","pid":null}
EOF
result=$(run_find_orphans "current-sess")
assert_equals "$result" "$fake_repo/.claude/worktrees/orchestrator-null-pid-session" \
  "(24) session file present + pid null → emitted (is-active treats null as inactive)"

# --- (25) multiple orphans → multiple paths emitted (newline-delimited) ---
reset_fake_layout
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-orphan-a"
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-orphan-b"
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-current-sess"
result=$(run_find_orphans "current-sess" | sort)
expected=$(printf '%s\n%s' \
  "$fake_repo/.claude/worktrees/orchestrator-orphan-a" \
  "$fake_repo/.claude/worktrees/orchestrator-orphan-b" | sort)
assert_equals "$result" "$expected" \
  "(25) multiple orphans → all emitted, current session excluded"

# --- (26) bad usage — missing --repo-root → exit 64 ---
SHIPYARD_HOME="$fake_shipyard_home" bash "$helper" find-orphan-orchestrators \
  --current-session-id foo >/dev/null 2>&1
assert_exit_code "$?" "64" \
  "(26) missing --repo-root → exit 64"

# --- (27) bad usage — missing --current-session-id → exit 64 ---
SHIPYARD_HOME="$fake_shipyard_home" bash "$helper" find-orphan-orchestrators \
  --repo-root "$fake_repo" >/dev/null 2>&1
assert_exit_code "$?" "64" \
  "(27) missing --current-session-id → exit 64"

# --- (28) bad usage — unknown flag → exit 64 ---
SHIPYARD_HOME="$fake_shipyard_home" bash "$helper" find-orphan-orchestrators \
  --repo-root "$fake_repo" --current-session-id foo --unknown 2>/dev/null
assert_exit_code "$?" "64" \
  "(28) unknown flag → exit 64"

# --- (29) bad usage — unexpected positional → exit 64 ---
SHIPYARD_HOME="$fake_shipyard_home" bash "$helper" find-orphan-orchestrators \
  --repo-root "$fake_repo" --current-session-id foo trailing-positional 2>/dev/null
assert_exit_code "$?" "64" \
  "(29) unexpected positional arg → exit 64"

# --- (30) --flag=value form works for --repo-root and --current-session-id ---
reset_fake_layout
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-equals-form-orphan"
result=$(SHIPYARD_HOME="$fake_shipyard_home" bash "$helper" find-orphan-orchestrators \
  --repo-root="$fake_repo" --current-session-id=current-sess 2>/dev/null)
assert_equals "$result" "$fake_repo/.claude/worktrees/orchestrator-equals-form-orphan" \
  "(30) --flag=value form accepted for both flags"

# ============================================================================
# Issue #284 — `reap` subcommand: single source of truth for reap-audit
# writes.
#
# Coverage goals:
#   - Audit-log line appears in $SHIPYARD_HOME/reap-audit.jsonl after every
#     reap call, regardless of whether the actual remove succeeded.
#   - Action-specific line shapes match what the inline printf templates
#     in setup.md / cleanup-summary.md used to emit (so existing tooling
#     reading the log doesn't see a behavior change).
#   - Required-flag validation surfaces as exit 64 with a useful stderr.
#   - SHIPYARD_HOME / $HOME/.shipyard precedence works.
#   - `--skip-remove` path doesn't invoke git.
#   - Orphan-orchestrator raw-rm fallback path emits the -raw-rm action
#     variant when git worktree remove fails (typical for crash-orphaned
#     dirs that were never registered with git).
# ============================================================================

echo
echo "worktree-reap.sh reap subcommand tests (issue #284)"
echo

reap_home="$tmpdir/reap-home"
reap_repo="$tmpdir/reap-repo"

reset_reap_layout() {
  rm -rf "$reap_home" "$reap_repo"
  mkdir -p "$reap_home"
  mkdir -p "$reap_repo"
  # Initialize a real git repo so `git worktree remove` calls don't error
  # at the `not in a git repo` layer and we exercise the actual code path.
  (
    cd "$reap_repo" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    git commit -q --allow-empty -m "init"
  ) >/dev/null 2>&1
}

# Run `reap` with $SHIPYARD_HOME pointed at the test dir, cwd inside the
# test repo. Returns the command's exit code; stderr is captured to a
# file so the caller can inspect on failure.
run_reap() {
  (
    cd "$reap_repo" || exit 99
    SHIPYARD_HOME="$reap_home" bash "$helper" reap "$@" 2>"$tmpdir/reap.stderr"
  )
}

audit_log="$reap_home/reap-audit.jsonl"

# --- (31) reap --action=reaped writes the agent-reap shape ---
reset_reap_layout
run_reap \
  --action reaped \
  --worktree-path "$reap_repo/.git/worktrees/agent-test1" \
  --worktree-name "agent-test1" \
  --session-id "test-session-1" \
  --actor-pid 12345 \
  --classification "self-ancestor" \
  --lock-pid 999999 \
  --skip-remove
exit_code=$?
assert_exit_code "$exit_code" "0" \
  "(31) reap --action=reaped exits 0"

if [ ! -f "$audit_log" ]; then
  printf '  %sFAIL%s  (31a) audit log not created at %s\n' "$RED" "$RESET" "$audit_log"
  fail=$((fail+1))
else
  line=$(cat "$audit_log")
  # The line should contain action, classification, lock_pid (as integer
  # not string), and worktree name. We don't assert exact equality on the
  # ts field — just check each substring is present. Field order is the
  # current emission order (ts, session, actor_pid, worktree, action,
  # classification, lock_pid[, phase]) — assert per-substring rather than
  # whole-pattern so a future cosmetic reordering doesn't break tests.
  shape_ok=1
  case "$line" in *'"worktree":"agent-test1"'*) ;; *) shape_ok=0 ;; esac
  case "$line" in *'"action":"reaped"'*) ;; *) shape_ok=0 ;; esac
  case "$line" in *'"classification":"self-ancestor"'*) ;; *) shape_ok=0 ;; esac
  case "$line" in *'"lock_pid":999999'*) ;; *) shape_ok=0 ;; esac
  case "$line" in *'"session":"test-session-1"'*) ;; *) shape_ok=0 ;; esac
  case "$line" in *'"actor_pid":12345'*) ;; *) shape_ok=0 ;; esac
  if [ "$shape_ok" = "1" ]; then
    printf '  %sPASS%s  (31a) audit log contains expected reaped-action fields\n' "$GREEN" "$RESET"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  (31a) audit-log shape mismatch — line was: %s\n' "$RED" "$RESET" "$line"
    fail=$((fail+1))
  fi
fi

# --- (32) reap --action=reaped includes --phase in audit line when set ---
reset_reap_layout
run_reap \
  --action reaped \
  --worktree-path "$reap_repo/.git/worktrees/agent-test2" \
  --worktree-name "agent-test2" \
  --session-id "test-session-2" \
  --classification "dead" \
  --lock-pid null \
  --phase "setup-3b" \
  --skip-remove
line=$(cat "$audit_log")
shape_ok=1
case "$line" in *'"phase":"setup-3b"'*) ;; *) shape_ok=0 ;; esac
case "$line" in *'"lock_pid":null'*) ;; *) shape_ok=0 ;; esac
case "$line" in *'"classification":"dead"'*) ;; *) shape_ok=0 ;; esac
if [ "$shape_ok" = "1" ]; then
  printf '  %sPASS%s  (32) audit line includes phase=setup-3b and lock_pid=null literal\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (32) audit-log shape mismatch — line was: %s\n' "$RED" "$RESET" "$line"
  fail=$((fail+1))
fi

# --- (33) reap --action=deferred writes the deferred shape ---
reset_reap_layout
run_reap \
  --action deferred \
  --worktree-path "$reap_repo/.git/worktrees/agent-test3" \
  --worktree-name "agent-test3" \
  --session-id "test-session-3" \
  --reason "peer-alive" \
  --lock-pid 88888 \
  --phase "cleanup-3"
exit_code=$?
assert_exit_code "$exit_code" "0" \
  "(33) reap --action=deferred exits 0"

line=$(cat "$audit_log")
shape_ok=1
case "$line" in *'"action":"deferred"'*) ;; *) shape_ok=0 ;; esac
case "$line" in *'"reason":"peer-alive"'*) ;; *) shape_ok=0 ;; esac
case "$line" in *'"lock_pid":88888'*) ;; *) shape_ok=0 ;; esac
case "$line" in *'"phase":"cleanup-3"'*) ;; *) shape_ok=0 ;; esac
if [ "$shape_ok" = "1" ]; then
  printf '  %sPASS%s  (33a) audit log contains expected deferred-action fields\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (33a) audit-log shape mismatch — line was: %s\n' "$RED" "$RESET" "$line"
  fail=$((fail+1))
fi

# --- (34) reap --action=reaped-orphan-orchestrator on a crash-orphan dir ---
# The worktree dir exists on disk but isn't registered with git (typical
# crash-orphan). Since #664 the fast reap's `mv` handles this uniformly with
# the registered case — the dir is renamed aside (instant) and the bulk
# delete is backgrounded — so the plain `reaped-orphan-orchestrator` action
# is recorded. The `-raw-rm` / `-failed` variants are now reserved for the
# genuine last resort where the rename itself fails, so they no longer fire
# on a routine crash-orphan.
reset_reap_layout
orphan_dir="$reap_repo/.claude/worktrees/orchestrator-dead-session-9"
mkdir -p "$orphan_dir"
echo "stale" > "$orphan_dir/leftover.txt"
run_reap \
  --action reaped-orphan-orchestrator \
  --worktree-path "$orphan_dir" \
  --worktree-name "orchestrator-dead-session-9" \
  --session-id "current-session" \
  --reaped-session-id "dead-session-9" \
  --phase "setup-1.6.5"
exit_code=$?
assert_exit_code "$exit_code" "0" \
  "(34) reap --action=reaped-orphan-orchestrator exits 0"

# Dir should be gone from its original path (renamed aside by the fast reap).
if [ ! -d "$orphan_dir" ]; then
  printf '  %sPASS%s  (34a) orphan dir gone from original path (fast reap renamed it aside)\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (34a) orphan dir still present at %s\n' "$RED" "$RESET" "$orphan_dir"
  fail=$((fail+1))
fi

line=$(cat "$audit_log")
shape_ok=1
case "$line" in *'"action":"reaped-orphan-orchestrator"'*) ;; *) shape_ok=0 ;; esac
case "$line" in *'"reaped_session_id":"dead-session-9"'*) ;; *) shape_ok=0 ;; esac
case "$line" in *'"phase":"setup-1.6.5"'*) ;; *) shape_ok=0 ;; esac
if [ "$shape_ok" = "1" ]; then
  printf '  %sPASS%s  (34b) audit line carries reaped-orphan-orchestrator action (fast reap)\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (34b) expected reaped-orphan-orchestrator action; line was: %s\n' "$RED" "$RESET" "$line"
  fail=$((fail+1))
fi

# --- (35) multiple reap calls append, don't overwrite ---
reset_reap_layout
run_reap --action reaped --worktree-path "$reap_repo/a" --worktree-name "a" \
  --session-id "s1" --classification "dead" --lock-pid null --skip-remove
run_reap --action reaped --worktree-path "$reap_repo/b" --worktree-name "b" \
  --session-id "s1" --classification "dead" --lock-pid null --skip-remove
line_count=$(wc -l < "$audit_log" | tr -d ' ')
assert_equals "$line_count" "2" \
  "(35) two reap calls produce two audit-log lines (append-only)"

# --- (36) audit log dir is created when SHIPYARD_HOME doesn't exist ---
# This is the bug from the issue body: $HOME/.shipyard didn't exist on
# first-session machines, so the inline `printf >> $REAP_AUDIT_LOG` silently
# failed (the `|| true` masked it). The helper must mkdir -p before write.
reset_reap_layout
rm -rf "$reap_home"  # confirm it's gone
run_reap --action reaped --worktree-path "$reap_repo/c" --worktree-name "c" \
  --session-id "s1" --classification "dead" --lock-pid null --skip-remove
if [ -f "$audit_log" ]; then
  printf '  %sPASS%s  (36) audit log materialized after first reap on fresh machine (SHIPYARD_HOME did not exist)\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (36) audit log NOT created when SHIPYARD_HOME did not pre-exist — this is the bug #284 was filed for\n' "$RED" "$RESET"
  fail=$((fail+1))
fi

# --- (37) bad usage: --action required → exit 64 ---
run_reap --worktree-path "$reap_repo/x" --worktree-name "x" --session-id s
assert_exit_code "$?" "64" \
  "(37) missing --action → exit 64"

# --- (38) bad usage: --classification required when --action=reaped ---
run_reap --action reaped --worktree-path "$reap_repo/x" --worktree-name "x" \
  --session-id s --lock-pid null --skip-remove
assert_exit_code "$?" "64" \
  "(38) reaped without --classification → exit 64"

# --- (39) bad usage: --reason required when --action=deferred ---
run_reap --action deferred --worktree-path "$reap_repo/x" --worktree-name "x" \
  --session-id s --lock-pid null
assert_exit_code "$?" "64" \
  "(39) deferred without --reason → exit 64"

# --- (40) bad usage: --reaped-session-id required when --action=reaped-orphan-orchestrator ---
run_reap --action reaped-orphan-orchestrator \
  --worktree-path "$reap_repo/x" --worktree-name "x" --session-id s
assert_exit_code "$?" "64" \
  "(40) reaped-orphan-orchestrator without --reaped-session-id → exit 64"

# --- (41) bad usage: unknown --action → exit 64 ---
run_reap --action bogus --worktree-path "$reap_repo/x" --worktree-name "x" \
  --session-id s --skip-remove
assert_exit_code "$?" "64" \
  "(41) unknown --action → exit 64"

# --- (42) bad usage: --lock-pid must be 'null' or non-negative integer ---
run_reap --action reaped --worktree-path "$reap_repo/x" --worktree-name "x" \
  --session-id s --classification "dead" --lock-pid "not-a-pid" --skip-remove
assert_exit_code "$?" "64" \
  "(42) --lock-pid with non-numeric, non-'null' value → exit 64"

# --- (43) bad usage: --actor-pid must be numeric ---
run_reap --action reaped --worktree-path "$reap_repo/x" --worktree-name "x" \
  --session-id s --classification "dead" --lock-pid null --actor-pid "abc" --skip-remove
assert_exit_code "$?" "64" \
  "(43) --actor-pid with non-numeric value → exit 64"

# --- (44) --flag=value form parity for all reap flags ---
reset_reap_layout
run_reap \
  --action=reaped \
  --worktree-path="$reap_repo/.git/worktrees/agent-eq" \
  --worktree-name=agent-eq \
  --session-id=session-eq \
  --actor-pid=42 \
  --classification=no-lock \
  --lock-pid=null \
  --phase=setup-3b \
  --skip-remove
assert_exit_code "$?" "0" \
  "(44) --flag=value form accepted for all reap flags"
line=$(cat "$audit_log")
shape_ok=1
case "$line" in *'"action":"reaped"'*) ;; *) shape_ok=0 ;; esac
case "$line" in *'"classification":"no-lock"'*) ;; *) shape_ok=0 ;; esac
case "$line" in *'"phase":"setup-3b"'*) ;; *) shape_ok=0 ;; esac
case "$line" in *'"actor_pid":42'*) ;; *) shape_ok=0 ;; esac
case "$line" in *'"worktree":"agent-eq"'*) ;; *) shape_ok=0 ;; esac
if [ "$shape_ok" = "1" ]; then
  printf '  %sPASS%s  (44a) --flag=value form produces expected audit line\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (44a) audit-line shape mismatch with --flag=value form — line was: %s\n' "$RED" "$RESET" "$line"
  fail=$((fail+1))
fi

# --- (44b) issue #405 — adversarial field values produce valid single-line
# JSON. A --reason / --worktree-name / --session-id carrying `"`, `\`, or a
# newline must NOT corrupt the ledger or inject extra JSON fields. Before the
# fix these flowed in via raw string interpolation; now they're JSON-escaped.
reset_reap_layout
# Crafted --reason that, unescaped, would close the string early and forge a
# `classification` field — the exact injection the issue calls out.
adv_reason='x","action":"reaped","classification":"forged'
adv_name=$'weird"name\\with\ttab'
adv_session=$'sess\nion"id'
run_reap \
  --action deferred \
  --worktree-path "$reap_repo/.git/worktrees/agent-adv" \
  --worktree-name "$adv_name" \
  --session-id "$adv_session" \
  --actor-pid 7 \
  --reason "$adv_reason" \
  --lock-pid null \
  --skip-remove
assert_exit_code "$?" "0" \
  "(44b) reap with adversarial field values exits 0"

# Exactly one line must have been written (a newline in --session-id must not
# split the record into two lines).
adv_line_count=$(wc -l < "$audit_log" | tr -d ' ')
assert_equals "$adv_line_count" "1" \
  "(44b-1) adversarial values produce a single ledger line"

adv_line=$(cat "$audit_log")
# The crafted reason must NOT have injected a real classification field — a
# `deferred` record has no classification key, so its presence would mean the
# injection landed.
case "$adv_line" in
  *'"classification"'*)
    printf '  %sFAIL%s  (44b-2) injection landed — forged classification key present: %s\n' "$RED" "$RESET" "$adv_line"
    fail=$((fail+1))
    ;;
  *)
    printf '  %sPASS%s  (44b-2) crafted --reason did not inject a forged field\n' "$GREEN" "$RESET"
    pass=$((pass+1))
    ;;
esac

# The whole line must parse as valid JSON. Prefer jq (present in CI); fall
# back to python3; skip-with-pass only if neither is available so the suite
# stays green on a bare machine (the substring guards above still ran).
if command -v jq >/dev/null 2>&1; then
  if printf '%s\n' "$adv_line" | jq -e . >/dev/null 2>&1; then
    printf '  %sPASS%s  (44b-3) adversarial ledger line is valid JSON (jq parse)\n' "$GREEN" "$RESET"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  (44b-3) adversarial ledger line is NOT valid JSON — line was: %s\n' "$RED" "$RESET" "$adv_line"
    fail=$((fail+1))
  fi
elif command -v python3 >/dev/null 2>&1; then
  if printf '%s\n' "$adv_line" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' >/dev/null 2>&1; then
    printf '  %sPASS%s  (44b-3) adversarial ledger line is valid JSON (python parse)\n' "$GREEN" "$RESET"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  (44b-3) adversarial ledger line is NOT valid JSON — line was: %s\n' "$RED" "$RESET" "$adv_line"
    fail=$((fail+1))
  fi
else
  printf '  %sPASS%s  (44b-3) skipped JSON-parse assertion (no jq/python3 available)\n' "$GREEN" "$RESET"
  pass=$((pass+1))
fi

# --- (45) deferred action does NOT invoke git worktree remove (no error
# even when worktree-path is bogus, because we never call git). This is a
# behavioral guard: deferred means "we are reporting the decision to defer";
# the remove must not fire.
reset_reap_layout
run_reap --action deferred \
  --worktree-path "/no/such/path/at/all" \
  --worktree-name "agent-bogus" \
  --session-id "session-d" \
  --reason "peer-alive" \
  --lock-pid 1
assert_exit_code "$?" "0" \
  "(45) deferred action with bogus path doesn't error (no remove invoked)"

# ============================================================================
# Issue #326 — `reap-orphan-branches` subcommand: reap stale worktree-agent-*
# branch refs that have no live worktree referencing them.
#
# Coverage goals:
#   - Orphan branches (no live worktree) are deleted and audit-logged.
#   - Live-worktree branches are skipped (safety gate).
#   - Idempotent — second pass with no orphan branches produces empty output.
#   - Dry-run mode emits reaped-branch: lines without deleting or auditing.
#   - Audit log entry has the expected shape.
#   - Bad-usage cases exit 64.
#   - --repo-root=value and --session-id=value forms accepted.
# ============================================================================

echo
echo "worktree-reap.sh reap-orphan-branches tests (issue #326)"
echo

# Isolated git repo + SHIPYARD_HOME for each test.
rob_repo="$tmpdir/rob-repo"
rob_home="$tmpdir/rob-home"

reset_rob_layout() {
  rm -rf "$rob_repo" "$rob_home"
  mkdir -p "$rob_home"
  # Initialize a real git repo with an initial commit so `git branch` and
  # `git for-each-ref` work correctly.
  mkdir -p "$rob_repo"
  (
    cd "$rob_repo" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    git commit -q --allow-empty -m "init"
  ) >/dev/null 2>&1
}

# Helper to run reap-orphan-branches inside the test repo.
run_rob() {
  SHIPYARD_HOME="$rob_home" bash "$helper" reap-orphan-branches \
    --repo-root "$rob_repo" \
    --session-id "rob-test-session" \
    "$@" 2>/dev/null
}

rob_audit_log="$rob_home/reap-audit.jsonl"

# --- (46) no worktree-agent-* branches → empty output, exit 0 ---
reset_rob_layout
result=$(run_rob)
exit_code=$?
assert_equals "${result:-EMPTY}" "EMPTY" \
  "(46) no worktree-agent-* branches → empty output"
assert_exit_code "$exit_code" "0" \
  "(46a) no worktree-agent-* branches → exit 0"

# --- (47) orphan branch → deleted + reaped-branch: line emitted ---
reset_rob_layout
git -C "$rob_repo" branch worktree-agent-orphan-test HEAD
result=$(run_rob)
exit_code=$?
assert_equals "$result" "reaped-branch: worktree-agent-orphan-test" \
  "(47) orphan branch → 'reaped-branch: worktree-agent-orphan-test' emitted"
assert_exit_code "$exit_code" "0" \
  "(47a) orphan branch → exit 0"
# Branch should be gone.
if git -C "$rob_repo" rev-parse --verify worktree-agent-orphan-test >/dev/null 2>&1; then
  printf '  %sFAIL%s  (47b) orphan branch still exists after sweep\n' "$RED" "$RESET"
  fail=$((fail+1))
else
  printf '  %sPASS%s  (47b) orphan branch deleted by sweep\n' "$GREEN" "$RESET"
  pass=$((pass+1))
fi

# --- (48) audit log entry has expected shape ---
reset_rob_layout
git -C "$rob_repo" branch worktree-agent-audit-shape HEAD
run_rob >/dev/null
if [ ! -f "$rob_audit_log" ]; then
  printf '  %sFAIL%s  (48) audit log not created at %s\n' "$RED" "$RESET" "$rob_audit_log"
  fail=$((fail+1))
else
  line=$(cat "$rob_audit_log")
  shape_ok=1
  case "$line" in *'"action":"reaped-orphan-branch"'*) ;; *) shape_ok=0 ;; esac
  case "$line" in *'"branch":"worktree-agent-audit-shape"'*) ;; *) shape_ok=0 ;; esac
  case "$line" in *'"reason":"no-live-worktree"'*) ;; *) shape_ok=0 ;; esac
  case "$line" in *'"session":"rob-test-session"'*) ;; *) shape_ok=0 ;; esac
  case "$line" in *'"ts":"'*) ;; *) shape_ok=0 ;; esac
  case "$line" in *'"actor_pid":'*) ;; *) shape_ok=0 ;; esac
  if [ "$shape_ok" = "1" ]; then
    printf '  %sPASS%s  (48) audit log has expected reaped-orphan-branch fields\n' "$GREEN" "$RESET"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  (48) audit log shape mismatch — line was: %s\n' "$RED" "$RESET" "$line"
    fail=$((fail+1))
  fi
fi

# --- (49) idempotent — second sweep with no orphans → empty output ---
reset_rob_layout
git -C "$rob_repo" branch worktree-agent-idempotent-test HEAD
run_rob >/dev/null  # first pass: delete
result=$(run_rob)   # second pass: nothing to do
assert_equals "${result:-EMPTY}" "EMPTY" \
  "(49) idempotent — second sweep after deletion → empty output"

# --- (50) dry-run mode — branch survives, no audit log written ---
reset_rob_layout
git -C "$rob_repo" branch worktree-agent-dry-run-test HEAD
result=$(run_rob --dry-run)
assert_equals "$result" "reaped-branch: worktree-agent-dry-run-test" \
  "(50) dry-run emits reaped-branch: line"
# Branch should still exist.
if git -C "$rob_repo" rev-parse --verify worktree-agent-dry-run-test >/dev/null 2>&1; then
  printf '  %sPASS%s  (50a) dry-run did not delete the branch\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (50a) dry-run unexpectedly deleted branch\n' "$RED" "$RESET"
  fail=$((fail+1))
fi
# Audit log must NOT exist.
if [ -f "$rob_audit_log" ]; then
  printf '  %sFAIL%s  (50b) dry-run wrote audit log (should not)\n' "$RED" "$RESET"
  fail=$((fail+1))
else
  printf '  %sPASS%s  (50b) dry-run did not write audit log\n' "$GREEN" "$RESET"
  pass=$((pass+1))
fi

# --- (51) live-worktree branch is NOT deleted (safety gate) ---
# We can't easily register a real worktree in a temp git repo during tests
# (it requires `git worktree add` which needs a real branch). Instead we
# verify the safety logic by checking that the `git worktree list --porcelain`
# parsing is correct: a branch whose name appears in the porcelain output is
# skipped. We achieve this by creating a REAL secondary worktree pointing at
# a worktree-agent-* branch, then running the sweep and asserting the branch
# survives.
reset_rob_layout
git -C "$rob_repo" branch worktree-agent-live-branch HEAD
git -C "$rob_repo" branch worktree-agent-orphan-to-delete HEAD
# Add a real secondary worktree referencing the live-branch.
live_wt="$tmpdir/rob-live-wt"
git -C "$rob_repo" worktree add "$live_wt" worktree-agent-live-branch >/dev/null 2>&1
if [ -d "$live_wt" ]; then
  result=$(run_rob | sort)
  # Only the orphan branch should be deleted, not the live one.
  assert_equals "$result" "reaped-branch: worktree-agent-orphan-to-delete" \
    "(51) live-worktree branch skipped; orphan branch reaped"
  # Live branch must still exist.
  if git -C "$rob_repo" rev-parse --verify worktree-agent-live-branch >/dev/null 2>&1; then
    printf '  %sPASS%s  (51a) live-worktree branch NOT deleted (safety gate works)\n' "$GREEN" "$RESET"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  (51a) live-worktree branch was incorrectly deleted\n' "$RED" "$RESET"
    fail=$((fail+1))
  fi
  # Clean up the secondary worktree.
  git -C "$rob_repo" worktree remove --force "$live_wt" 2>/dev/null || true
else
  printf '  %sSKIP%s  (51) could not create live secondary worktree — skipping safety-gate test\n' \
    "$GREEN" "$RESET"
fi

# --- (52) bad usage — missing --repo-root → exit 64 ---
SHIPYARD_HOME="$rob_home" bash "$helper" reap-orphan-branches \
  --session-id foo >/dev/null 2>&1
assert_exit_code "$?" "64" \
  "(52) missing --repo-root → exit 64"

# --- (53) bad usage — missing --session-id → exit 64 ---
SHIPYARD_HOME="$rob_home" bash "$helper" reap-orphan-branches \
  --repo-root "$rob_repo" >/dev/null 2>&1
assert_exit_code "$?" "64" \
  "(53) missing --session-id → exit 64"

# --- (54) bad usage — unknown flag → exit 64 ---
SHIPYARD_HOME="$rob_home" bash "$helper" reap-orphan-branches \
  --repo-root "$rob_repo" --session-id foo --unknown-flag 2>/dev/null
assert_exit_code "$?" "64" \
  "(54) unknown flag → exit 64"

# --- (55) bad usage — unexpected positional → exit 64 ---
SHIPYARD_HOME="$rob_home" bash "$helper" reap-orphan-branches \
  --repo-root "$rob_repo" --session-id foo trailing 2>/dev/null
assert_exit_code "$?" "64" \
  "(55) unexpected positional arg → exit 64"

# --- (56) --flag=value form accepted ---
reset_rob_layout
git -C "$rob_repo" branch worktree-agent-eq-form-test HEAD
result=$(SHIPYARD_HOME="$rob_home" bash "$helper" reap-orphan-branches \
  --repo-root="$rob_repo" --session-id=eq-session 2>/dev/null)
assert_equals "$result" "reaped-branch: worktree-agent-eq-form-test" \
  "(56) --flag=value form accepted for --repo-root and --session-id"

# --- (57) multiple orphan branches → all reaped, multiple audit lines ---
reset_rob_layout
git -C "$rob_repo" branch worktree-agent-multi-a HEAD
git -C "$rob_repo" branch worktree-agent-multi-b HEAD
result=$(run_rob | sort)
expected=$(printf 'reaped-branch: worktree-agent-multi-a\nreaped-branch: worktree-agent-multi-b')
assert_equals "$result" "$expected" \
  "(57) multiple orphan branches → all reaped"
# Audit log should have two lines.
line_count=$(wc -l < "$rob_audit_log" 2>/dev/null | tr -d ' ')
assert_equals "$line_count" "2" \
  "(57a) two orphan branches → two audit-log lines"

# ============================================================================
# reap-session-worktrees subcommand tests (issue #509)
#
# Covers the targeted this-session reap that runs as the FIRST pass at
# end-of-session cleanup, before the generic .git/worktrees/agent-* sweep,
# so a slow generic sweep on a busy checkout can't strand this session's own
# shipped worktrees (#509 repro: 17 worktrees, ~6 reaped, then the loop
# stalled before reaching this session's own merged-work worktrees).
#
# Matrix:
#   58) dry-run → status lines emitted, worktrees NOT removed, no audit
#   59) real run → safe-classification worktrees removed + audit lines with
#       phase: "cleanup-session-targeted"
#   60) nonexistent agent-id (already reaped by steady-state #282) → no line,
#       no error
#   61) flag + stdin sources unioned
#   62) duplicate agent-id → single status line (dedup)
#   63) peer-alive lock (live non-ancestor PID) → deferred, worktree kept
#   64) SHIPYARD_ORCHESTRATOR_PID short-circuit → self-ancestor → reaped
#   65) bad usage (missing --repo-root / --session-id / unknown flag) → 64
#   66) no agent-ids supplied → empty output, exit 0
# ============================================================================

echo
echo "worktree-reap.sh reap-session-worktrees tests (issue #509)"
echo

rsw_repo="$tmpdir/rsw-repo"
rsw_home="$tmpdir/rsw-home"
rsw_audit_log="$rsw_home/reap-audit.jsonl"

# Build a fresh primary checkout with N agent worktrees. Each agent-<id>
# worktree is a real linked worktree on its own do-work/issue-<n> branch, so
# `git worktree remove` behaves exactly as it does in production.
reset_rsw_layout() {
  rm -rf "$rsw_repo" "$rsw_home"
  mkdir -p "$rsw_home"
  mkdir -p "$rsw_repo"
  (
    cd "$rsw_repo" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test"
    git commit -q --allow-empty -m "init"
  ) >/dev/null 2>&1
}

# Add an agent worktree named agent-<id> on branch do-work/issue-<id>.
rsw_add_worktree() {
  local id="$1"
  git -C "$rsw_repo" worktree add -q \
    ".claude/worktrees/agent-$id" -b "do-work/issue-$id" >/dev/null 2>&1
}

run_rsw() {
  SHIPYARD_HOME="$rsw_home" bash "$helper" reap-session-worktrees \
    --repo-root "$rsw_repo" \
    --session-id "rsw-test-session" \
    "$@" 2>/dev/null
}

# --- (58) dry-run → lines emitted, worktrees kept, no audit log ---
reset_rsw_layout
rsw_add_worktree aaa
rsw_add_worktree bbb
result=$(run_rsw --agent-id aaa --agent-id bbb --dry-run | sort)
expected=$(printf 'reaped: agent-aaa\nreaped: agent-bbb')
assert_equals "$result" "$expected" \
  "(58) dry-run → reaped: lines for both worktrees"
[ -d "$rsw_repo/.claude/worktrees/agent-aaa" ] && dry_kept=yes || dry_kept=no
assert_equals "$dry_kept" "yes" \
  "(58a) dry-run → worktree NOT removed"
[ -f "$rsw_audit_log" ] && dry_audit=present || dry_audit=absent
assert_equals "$dry_audit" "absent" \
  "(58b) dry-run → no audit-log write"

# --- (59) real run → safe worktrees removed + audit lines tagged phase ---
reset_rsw_layout
rsw_add_worktree aaa
rsw_add_worktree bbb
result=$(run_rsw --agent-id aaa --agent-id bbb | sort)
assert_equals "$result" "$expected" \
  "(59) real run → reaped: lines for both worktrees"
[ -d "$rsw_repo/.claude/worktrees/agent-aaa" ] && real_kept=yes || real_kept=no
assert_equals "$real_kept" "no" \
  "(59a) real run → agent-aaa worktree removed"
line_count=$(wc -l < "$rsw_audit_log" 2>/dev/null | tr -d ' ')
assert_equals "$line_count" "2" \
  "(59b) real run → two audit-log lines"
phase_count=$(grep -c '"phase":"cleanup-session-targeted"' "$rsw_audit_log" 2>/dev/null | tr -d ' ')
assert_equals "$phase_count" "2" \
  "(59c) real run → audit lines carry phase cleanup-session-targeted"

# --- (60) nonexistent agent-id (already reaped, #282) → no line, no error ---
reset_rsw_layout
rsw_add_worktree aaa
result=$(run_rsw --agent-id aaa --agent-id ghost)
exit_code=$?
assert_equals "$result" "reaped: agent-aaa" \
  "(60) nonexistent agent-id emits no line (silent skip)"
assert_exit_code "$exit_code" "0" \
  "(60a) nonexistent agent-id → exit 0"

# --- (61) flag + stdin sources unioned ---
reset_rsw_layout
rsw_add_worktree aaa
rsw_add_worktree bbb
result=$(printf 'bbb\n' | SHIPYARD_HOME="$rsw_home" bash "$helper" \
  reap-session-worktrees --repo-root "$rsw_repo" \
  --session-id rsw --agent-id aaa 2>/dev/null | sort)
assert_equals "$result" "$expected" \
  "(61) flag (aaa) + stdin (bbb) unioned → both reaped"

# --- (62) duplicate agent-id → single status line (dedup) ---
reset_rsw_layout
rsw_add_worktree aaa
result=$(run_rsw --agent-id aaa --agent-id aaa --dry-run)
assert_equals "$result" "reaped: agent-aaa" \
  "(62) duplicate agent-id → single line (deduped)"

# --- (63) peer-alive lock (live non-ancestor PID) → deferred, worktree kept ---
reset_rsw_layout
rsw_add_worktree peer
# Spawn a live process that is NOT in our ancestor chain, write its PID into
# the lock in the canonical harness format. Tracked via sibling_pid so the
# EXIT trap kills it.
sleep 300 &
sibling_pid=$!
printf 'claude agent agent-peer (pid %s)\n' "$sibling_pid" \
  > "$rsw_repo/.git/worktrees/agent-peer/locked"
result=$(run_rsw --agent-id peer)
assert_equals "$result" "deferred: agent-peer" \
  "(63) peer-alive lock → deferred line"
[ -d "$rsw_repo/.claude/worktrees/agent-peer" ] && peer_kept=yes || peer_kept=no
assert_equals "$peer_kept" "yes" \
  "(63a) peer-alive → worktree NOT removed"
deferred_audit=$(grep -c '"action":"deferred"' "$rsw_audit_log" 2>/dev/null | tr -d ' ')
assert_equals "$deferred_audit" "1" \
  "(63b) peer-alive → deferred audit line written"
kill "$sibling_pid" 2>/dev/null
wait "$sibling_pid" 2>/dev/null
sibling_pid=""

# --- (64) SHIPYARD_ORCHESTRATOR_PID short-circuit → self-ancestor → reaped ---
# Same live-non-ancestor PID as (63), but declared as the orchestrator PID:
# classify-lock short-circuits to self-ancestor, so this session's own
# worktree is reaped instead of deferred (the load-bearing #138/#263 path
# that makes targeted cleanup actually remove the orchestrator's own locks).
reset_rsw_layout
rsw_add_worktree orch
sleep 300 &
sibling_pid=$!
printf 'claude agent agent-orch (pid %s)\n' "$sibling_pid" \
  > "$rsw_repo/.git/worktrees/agent-orch/locked"
result=$(SHIPYARD_HOME="$rsw_home" SHIPYARD_ORCHESTRATOR_PID="$sibling_pid" \
  bash "$helper" reap-session-worktrees --repo-root "$rsw_repo" \
  --session-id rsw --agent-id orch 2>/dev/null)
assert_equals "$result" "reaped: agent-orch" \
  "(64) declared orchestrator PID → self-ancestor → reaped (not deferred)"
[ -d "$rsw_repo/.claude/worktrees/agent-orch" ] && orch_kept=yes || orch_kept=no
assert_equals "$orch_kept" "no" \
  "(64a) self-ancestor → worktree removed"
kill "$sibling_pid" 2>/dev/null
wait "$sibling_pid" 2>/dev/null
sibling_pid=""

# --- (65) bad usage → exit 64 ---
reset_rsw_layout
SHIPYARD_HOME="$rsw_home" bash "$helper" reap-session-worktrees \
  --session-id x --agent-id a 2>/dev/null
assert_exit_code "$?" "64" \
  "(65) missing --repo-root → exit 64"
SHIPYARD_HOME="$rsw_home" bash "$helper" reap-session-worktrees \
  --repo-root "$rsw_repo" --agent-id a 2>/dev/null
assert_exit_code "$?" "64" \
  "(65a) missing --session-id → exit 64"
SHIPYARD_HOME="$rsw_home" bash "$helper" reap-session-worktrees \
  --repo-root "$rsw_repo" --session-id x --bogus 2>/dev/null
assert_exit_code "$?" "64" \
  "(65b) unknown flag → exit 64"

# --- (66) no agent-ids supplied → empty output, exit 0 ---
reset_rsw_layout
result=$(SHIPYARD_HOME="$rsw_home" bash "$helper" reap-session-worktrees \
  --repo-root "$rsw_repo" --session-id x </dev/null 2>/dev/null)
exit_code=$?
assert_equals "${result:-EMPTY}" "EMPTY" \
  "(66) no agent-ids → empty output"
assert_exit_code "$exit_code" "0" \
  "(66a) no agent-ids → exit 0"

# --- derive-session-id (issue #513) ---
#
# Build a synthetic worktrees layout under $tmpdir and exercise the
# newest-by-mtime selection. The bug: the old `awk '...; exit'` derive
# returned the FIRST orchestrator-* worktree in listing order — the oldest
# orphan when prior crashed sessions accumulate — misattributing every
# session-state write to a dead orphan's session file.

echo
echo "derive-session-id tests (issue #513)"
echo

dsi_repo="$tmpdir/dsi-repo"
mkdir -p "$dsi_repo/.claude/worktrees"

run_derive() {
  bash "$helper" derive-session-id --repo-root "$dsi_repo" 2>/dev/null
}

reset_dsi_layout() {
  rm -rf "$dsi_repo/.claude/worktrees"/orchestrator-* 2>/dev/null
  rm -rf "$dsi_repo/.claude/worktrees"/agent-* 2>/dev/null
}

# Make an orchestrator worktree with a given session id and a controllable
# mtime. `touch -t <YYYYMMDDhhmm>` sets the dir mtime portably (GNU + BSD).
make_orch_wt() {
  local sid="$1" mtime_stamp="$2"
  local dir="$dsi_repo/.claude/worktrees/orchestrator-$sid"
  mkdir -p "$dir"
  printf '%s\n' "$sid" > "$dir/.shipyard-session-id"
  touch -t "$mtime_stamp" "$dir"
}

# --- (67) no worktrees dir → empty output, exit 0 ---
dsi_no_wt="$tmpdir/dsi-no-wt"
mkdir -p "$dsi_no_wt"
result=$(bash "$helper" derive-session-id --repo-root "$dsi_no_wt" 2>/dev/null)
exit_code=$?
assert_equals "${result:-EMPTY}" "EMPTY" \
  "(67) no .claude/worktrees dir → empty output"
assert_exit_code "$exit_code" "0" \
  "(67a) no .claude/worktrees dir → exit 0"

# --- (68) single orchestrator worktree → its id (the common case) ---
reset_dsi_layout
make_orch_wt "do-work-only-session" "202606101200"
result=$(run_derive)
assert_equals "$result" "do-work-only-session" \
  "(68) single orchestrator worktree → its session id"

# --- (69) THE #513 repro: live session is NEWEST, orphans are older ---
# 5 older orphans + 1 live session created "now". The old first-in-listing
# derive returned the oldest orphan; newest-by-mtime must return the live one.
reset_dsi_layout
make_orch_wt "do-work-20260604T210804Z-81232" "202606042108"  # oldest orphan
make_orch_wt "do-work-20260605T100000Z-00001" "202606051000"
make_orch_wt "do-work-20260607T100000Z-00002" "202606071000"
make_orch_wt "do-work-20260608T100000Z-00003" "202606081000"
make_orch_wt "do-work-20260609T100000Z-00004" "202606091000"
make_orch_wt "do-work-20260610T045915Z-99999" "202606100459"  # live (newest)
result=$(run_derive)
assert_equals "$result" "do-work-20260610T045915Z-99999" \
  "(69) newest-by-mtime wins over 5 accumulated older orphans (the #513 repro)"

# --- (70) reverse mtime ordering — recency, not name, decides ---
# A lexically-LATER session id with an OLDER mtime must NOT win.
reset_dsi_layout
make_orch_wt "zzz-lexically-last-but-old" "202606010000"
make_orch_wt "aaa-lexically-first-but-new" "202606100000"
result=$(run_derive)
assert_equals "$result" "aaa-lexically-first-but-new" \
  "(70) newest mtime wins regardless of lexical name order"

# --- (71) candidate without a stash is skipped in favor of an older one
# that has one — correctness (a readable id) beats raw recency. ---
reset_dsi_layout
make_orch_wt "has-stash-but-older" "202606090000"
# A newer worktree with NO stash file (half-set-up or already-cleaned).
mkdir -p "$dsi_repo/.claude/worktrees/orchestrator-newer-no-stash"
touch -t "202606100000" "$dsi_repo/.claude/worktrees/orchestrator-newer-no-stash"
result=$(run_derive)
assert_equals "$result" "has-stash-but-older" \
  "(71) newer worktree without a stash is skipped; older one with a stash wins"

# --- (72) empty stash contents are skipped ---
reset_dsi_layout
make_orch_wt "good-stash" "202606090000"
mkdir -p "$dsi_repo/.claude/worktrees/orchestrator-empty-stash"
: > "$dsi_repo/.claude/worktrees/orchestrator-empty-stash/.shipyard-session-id"
touch -t "202606100000" "$dsi_repo/.claude/worktrees/orchestrator-empty-stash"
result=$(run_derive)
assert_equals "$result" "good-stash" \
  "(72) empty .shipyard-session-id is skipped in favor of a non-empty one"

# --- (73) agent-* worktrees are ignored (only orchestrator-* considered) ---
reset_dsi_layout
make_orch_wt "real-session" "202606090000"
mkdir -p "$dsi_repo/.claude/worktrees/agent-deadbeef"
printf '%s\n' "agent-should-not-win" > "$dsi_repo/.claude/worktrees/agent-deadbeef/.shipyard-session-id"
touch -t "202606100000" "$dsi_repo/.claude/worktrees/agent-deadbeef"
result=$(run_derive)
assert_equals "$result" "real-session" \
  "(73) agent-* worktrees are not candidates (only orchestrator-*)"

# --- (74) stash with surrounding whitespace/newlines is trimmed ---
reset_dsi_layout
mkdir -p "$dsi_repo/.claude/worktrees/orchestrator-padded"
printf '  do-work-padded-session  \n\n' > "$dsi_repo/.claude/worktrees/orchestrator-padded/.shipyard-session-id"
touch -t "202606100000" "$dsi_repo/.claude/worktrees/orchestrator-padded"
result=$(run_derive)
assert_equals "$result" "do-work-padded-session" \
  "(74) stash contents are whitespace-trimmed"

# --- (75) bad usage: missing --repo-root → exit 64 ---
bash "$helper" derive-session-id 2>/dev/null
assert_exit_code "$?" "64" \
  "(75) derive-session-id without --repo-root → exit 64"

# --- (75a) unknown flag → exit 64 ---
bash "$helper" derive-session-id --repo-root "$dsi_repo" --bogus 2>/dev/null
assert_exit_code "$?" "64" \
  "(75a) derive-session-id unknown flag → exit 64"

echo
echo "worktree-reap.sh fast-reap tests (issue #664)"
echo

# The fast reap decouples branch-freeing from bulk deletion: unlock +
# rename-aside + `git worktree prune` frees the branch synchronously, and the
# expensive recursive delete is backgrounded — so a large node_modules/ can't
# hang the remove and block fix-checks retries on the head branch. These tests
# exercise the rename → prune → branch-freed sequence on a REAL registered
# worktree (the `reset_reap_layout` harness above only inits a bare repo).
fast_repo="$tmpdir/fast-reap-repo"
fast_home="$tmpdir/fast-reap-home"

reset_fast_layout() {
  rm -rf "$fast_repo" "$fast_home"
  mkdir -p "$fast_home" "$fast_repo"
  (
    cd "$fast_repo" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    git commit -q --allow-empty -m "init"
  ) >/dev/null 2>&1
}

# Add a real worktree checked out on its own branch, with a node_modules-like
# subtree standing in for the large tree that makes the slow remove hang, and
# a harness-style lock file so the reap path exercises the unlock step.
fast_add_worktree() {
  local name="$1"
  (
    cd "$fast_repo" || exit 1
    git branch "wt-$name" >/dev/null 2>&1
    mkdir -p .claude/worktrees
    git worktree add -q ".claude/worktrees/$name" "wt-$name"
    mkdir -p ".git/worktrees/$name"
    printf 'claude agent %s (pid 99999)\n' "$name" > ".git/worktrees/$name/locked"
    mkdir -p ".claude/worktrees/$name/node_modules/pkg"
    echo "x" > ".claude/worktrees/$name/node_modules/pkg/index.js"
  ) >/dev/null 2>&1
}

# --- (76) fast reap: rename → prune → branch freed on a registered worktree ---
reset_fast_layout
fast_add_worktree wtA
wtA_path="$fast_repo/.claude/worktrees/wtA"
(
  cd "$fast_repo" || exit 99
  SHIPYARD_HOME="$fast_home" bash "$helper" reap \
    --action reaped \
    --worktree-path "$wtA_path" \
    --worktree-name "wtA" \
    --session-id "fast-session" \
    --classification "self-ancestor" \
    --lock-pid 99999 \
    --phase "cleanup-session-targeted"
) >/dev/null 2>&1
assert_exit_code "$?" "0" \
  "(76) fast reap of a registered worktree exits 0"

# Original path is gone synchronously — `mv` renamed it aside before the
# (backgrounded) bulk delete, so the reap returns without waiting on a full
# recursive unlink. This is the observable evidence the delete is decoupled.
if [ ! -e "$wtA_path" ]; then
  printf '  %sPASS%s  (76a) worktree gone from original path (renamed aside)\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (76a) worktree still at original path %s\n' "$RED" "$RESET" "$wtA_path"
  fail=$((fail+1))
fi

# Registration was pruned — git no longer lists the worktree path.
if git -C "$fast_repo" worktree list --porcelain 2>/dev/null | grep -qF "$wtA_path"; then
  printf '  %sFAIL%s  (76b) worktree still registered after reap (prune did not run)\n' "$RED" "$RESET"
  fail=$((fail+1))
else
  printf '  %sPASS%s  (76b) worktree registration pruned\n' "$GREEN" "$RESET"
  pass=$((pass+1))
fi

# Branch freed — the reaped worktree's branch is checkout-able again. Before
# the #664 fast reap the branch stayed locked until the slow remove finished.
if git -C "$fast_repo" worktree add -q "$fast_repo/reattach" "wt-wtA" >/dev/null 2>&1; then
  printf '  %sPASS%s  (76c) branch freed — re-addable in a fresh worktree\n' "$GREEN" "$RESET"
  pass=$((pass+1))
  git -C "$fast_repo" worktree remove --force "$fast_repo/reattach" >/dev/null 2>&1 || true
else
  printf '  %sFAIL%s  (76c) branch still locked after reap (not freed)\n' "$RED" "$RESET"
  fail=$((fail+1))
fi

# The reap-and-audit transaction still writes the reaped audit line.
fast_line=$(cat "$fast_home/reap-audit.jsonl" 2>/dev/null)
shape_ok=1
case "$fast_line" in *'"action":"reaped"'*) ;; *) shape_ok=0 ;; esac
case "$fast_line" in *'"phase":"cleanup-session-targeted"'*) ;; *) shape_ok=0 ;; esac
if [ "$shape_ok" = "1" ]; then
  printf '  %sPASS%s  (76d) fast reap still writes the reaped audit line\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (76d) expected reaped audit line; was: %s\n' "$RED" "$RESET" "$fast_line"
  fail=$((fail+1))
fi

# --- (77) fast reap falls back cleanly when the path is already gone ---
# A worktree already removed by an earlier pass (the #282 steady-state
# immediate-reap common case) must not error — the fast path prunes any
# dangling registration and returns success.
reset_fast_layout
missing_path="$fast_repo/.claude/worktrees/already-gone"
(
  cd "$fast_repo" || exit 99
  SHIPYARD_HOME="$fast_home" bash "$helper" reap \
    --action reaped \
    --worktree-path "$missing_path" \
    --worktree-name "already-gone" \
    --session-id "fast-session" \
    --classification "dead" \
    --lock-pid null
) >/dev/null 2>&1
assert_exit_code "$?" "0" \
  "(77) fast reap of an already-removed path exits 0 (no error)"

# ---------------------------------------------------------------------------
# Issue #712 — the reap must not silently degrade when the removal doesn't
# happen, and `--force` must not be the first move.
#
# Root cause: every reap call site bottomed out in `git worktree remove
# --force` wrapped in `2>/dev/null || true`. In Claude Code's auto permission
# mode the classifier DENIES that command ("[Irreversible Local Destruction]"),
# and because the call was fire-and-forget inside a background subshell, the
# denial was indistinguishable from success — worktrees accumulated forever
# (the repro found five, every one the residue of an already-merged PR, and the
# count only grew).
#
# Two guards, tested here:
#   - `report-unreaped` — an after-the-fact filesystem probe. It is the ONLY
#     mechanism that can catch a classifier denial, because the denial kills
#     the whole Bash tool call and no audit line is ever written.
#   - `reaped-failed` — the audit action emitted in place of `reaped` when the
#     removal did not actually happen, so the failure is recorded rather than
#     swallowed.
# ---------------------------------------------------------------------------

# --- (78) report-unreaped: clean layout → empty stdout, exit 0 ---
reset_fast_layout
mkdir -p "$fast_repo/.claude/worktrees"
unreaped_out=$(bash "$helper" report-unreaped --repo-root "$fast_repo" 2>/dev/null)
unreaped_rc=$?
assert_equals "$unreaped_out" "" \
  "(78) report-unreaped emits nothing when no worktrees are left over"
assert_exit_code "$unreaped_rc" "0" \
  "(78a) report-unreaped exits 0 on a clean layout"

# --- (79) report-unreaped: leftovers listed; own orchestrator + scratch excluded ---
reset_fast_layout
mkdir -p "$fast_repo/.claude/worktrees/agent-leftover1"
mkdir -p "$fast_repo/.claude/worktrees/agent-leftover2"
mkdir -p "$fast_repo/.claude/worktrees/orchestrator-dead-session"
mkdir -p "$fast_repo/.claude/worktrees/orchestrator-live-session"
# #664 rename-aside scratch dir: already pruned + branch freed, background
# unlink in flight. NOT a leftover.
mkdir -p "$fast_repo/.claude/worktrees/agent-zz.reap-dead-1234-99"
unreaped_out=$(bash "$helper" report-unreaped \
  --repo-root "$fast_repo" \
  --current-session-id "live-session" 2>/dev/null)
unreaped_count=$(printf '%s\n' "$unreaped_out" | grep -c . || true)
assert_equals "$unreaped_count" "3" \
  "(79) report-unreaped counts the 3 genuine leftovers"

shape_ok=1
case "$unreaped_out" in *"agent-leftover1"*) ;; *) shape_ok=0 ;; esac
case "$unreaped_out" in *"agent-leftover2"*) ;; *) shape_ok=0 ;; esac
case "$unreaped_out" in *"orchestrator-dead-session"*) ;; *) shape_ok=0 ;; esac
# Own orchestrator worktree is still live (reaped last) — never reported.
case "$unreaped_out" in *"orchestrator-live-session"*) shape_ok=0 ;; esac
# Scratch dir from the fast path — never reported.
case "$unreaped_out" in *"reap-dead"*) shape_ok=0 ;; esac
if [ "$shape_ok" = "1" ]; then
  printf '  %sPASS%s  (79a) report-unreaped excludes own orchestrator + .reap-dead-* scratch\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (79a) unexpected report-unreaped output:\n%s\n' "$RED" "$RESET" "$unreaped_out"
  fail=$((fail+1))
fi

# --- (80) report-unreaped: bad usage ---
bash "$helper" report-unreaped >/dev/null 2>&1
assert_exit_code "$?" "64" "(80) report-unreaped without --repo-root exits 64"
bash "$helper" report-unreaped --repo-root "$fast_repo" --bogus >/dev/null 2>&1
assert_exit_code "$?" "64" "(80a) report-unreaped with an unknown flag exits 64"

# --- (81) a removal that CANNOT happen emits `reaped-failed`, not `reaped` ---
# Simulate the denial/failure case by making the worktree's parent directory
# non-writable: `mv` (the fast path), `git worktree remove`, and `git worktree
# remove --force` all need write permission on the parent to unlink the entry,
# so every rung of the ladder fails and the directory survives. That is exactly
# the end state a classifier denial produces, and the audit line must say so.
# Skipped under root, which bypasses the permission bits entirely.
if [ "$(id -u)" = "0" ]; then
  printf '  %sSKIP%s  (81) reaped-failed audit line (running as root — permission bits are a no-op)\n' "$GREEN" "$RESET"
else
  reset_fast_layout
  fast_add_worktree wtFail
  wtFail_path="$fast_repo/.claude/worktrees/wtFail"
  chmod 0500 "$fast_repo/.claude/worktrees"
  (
    cd "$fast_repo" || exit 99
    SHIPYARD_HOME="$fast_home" bash "$helper" reap \
      --action reaped \
      --worktree-path "$wtFail_path" \
      --worktree-name "wtFail" \
      --session-id "fail-session" \
      --classification "dead" \
      --lock-pid 99999
  ) >/dev/null 2>&1
  reap_rc=$?
  chmod 0700 "$fast_repo/.claude/worktrees"

  assert_exit_code "$reap_rc" "0" \
    "(81) a failed reap still exits 0 (the caller's loop must continue)"

  if [ -d "$wtFail_path" ]; then
    printf '  %sPASS%s  (81a) worktree survived (the failure being recorded is real)\n' "$GREEN" "$RESET"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  (81a) worktree was removed — the failure could not be simulated\n' "$RED" "$RESET"
    fail=$((fail+1))
  fi

  fail_line=$(cat "$fast_home/reap-audit.jsonl" 2>/dev/null)
  shape_ok=1
  case "$fail_line" in *'"action":"reaped-failed"'*) ;; *) shape_ok=0 ;; esac
  # A bare `"action":"reaped"` would be the pre-#712 silent-success lie.
  case "$fail_line" in *'"action":"reaped"'*) shape_ok=0 ;; esac
  case "$fail_line" in *'"reason":'*) ;; *) shape_ok=0 ;; esac
  if [ "$shape_ok" = "1" ]; then
    printf '  %sPASS%s  (81b) failed reap emits reaped-failed + a reason (never a silent "reaped")\n' "$GREEN" "$RESET"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  (81b) expected a reaped-failed audit line with a reason; was: %s\n' "$RED" "$RESET" "$fail_line"
    fail=$((fail+1))
  fi
fi

# --- (82) reap-session-worktrees reports `unreaped:` when the removal fails ---
# The status line must reflect the VERIFIED end state, not the intent. Before
# #712 it printed `reaped:` before the removal even ran, so a failed removal
# still incremented the caller's reaped counter and the leftover went unnoticed.
if [ "$(id -u)" = "0" ]; then
  printf '  %sSKIP%s  (82) unreaped: status line (running as root)\n' "$GREEN" "$RESET"
else
  reset_fast_layout
  fast_add_worktree agent-stuck
  # Drop the lock file so classify-lock returns `no-lock` deterministically —
  # the fixture's placeholder PID could in principle be live on the test host,
  # which would classify as `peer-alive` and defer instead of reaping.
  rm -f "$fast_repo/.git/worktrees/agent-stuck/locked"
  chmod 0500 "$fast_repo/.claude/worktrees"
  session_out=$(printf 'stuck\n' | SHIPYARD_HOME="$fast_home" bash "$helper" \
    reap-session-worktrees \
    --repo-root "$fast_repo" \
    --session-id "fail-session" 2>/dev/null)
  chmod 0700 "$fast_repo/.claude/worktrees"

  # Match whole lines — `unreaped: agent-stuck` *contains* the substring
  # `reaped: agent-stuck`, so a substring test would report a false conflict.
  shape_ok=1
  printf '%s\n' "$session_out" | grep -qx "unreaped: agent-stuck" || shape_ok=0
  printf '%s\n' "$session_out" | grep -qx "reaped: agent-stuck" && shape_ok=0
  if [ "$shape_ok" = "1" ]; then
    printf '  %sPASS%s  (82) reap-session-worktrees prints unreaped: (not reaped:) on a failed removal\n' "$GREEN" "$RESET"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  (82) expected "unreaped: agent-stuck"; was: %s\n' "$RED" "$RESET" "$session_out"
    fail=$((fail+1))
  fi
fi

# --- (83) --force-evidence is accepted and the happy path still reaps ---
# A caller that has already established force-safety (e.g. setup 3c's
# `rev-list --count origin/<default>..HEAD == 0`) passes its evidence through
# rather than making the helper re-derive it.
reset_fast_layout
fast_add_worktree wtEvidence
wtEvidence_path="$fast_repo/.claude/worktrees/wtEvidence"
(
  cd "$fast_repo" || exit 99
  SHIPYARD_HOME="$fast_home" bash "$helper" reap \
    --action reaped \
    --worktree-path "$wtEvidence_path" \
    --worktree-name "wtEvidence" \
    --session-id "evidence-session" \
    --classification "dead" \
    --lock-pid 99999 \
    --force-evidence "no-commits-beyond-base"
) >/dev/null 2>&1
assert_exit_code "$?" "0" "(83) reap accepts --force-evidence"

if [ ! -e "$wtEvidence_path" ]; then
  printf '  %sPASS%s  (83a) worktree still reaped on the --force-evidence path\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (83a) worktree survived the --force-evidence reap\n' "$RED" "$RESET"
  fail=$((fail+1))
fi

# --- (84) `--force` is never the first move ---
# Regression guard on the #712 ladder itself. Count only *executable* force
# invocations — a line whose first token is the command — so the file's own
# comments and its `usage()` heredoc (both of which legitimately name the
# command) don't inflate the count. Assert the helper retains at most one such
# call site and that the `worktree_force_is_safe` evidence gate exists to guard
# it. A future edit that reintroduces an ungated force reddens this.
force_calls=$(sed 's/#.*//' "$helper" \
  | grep -cE '^[[:space:]]*git worktree remove --force' || true)
guarded=$(sed 's/#.*//' "$helper" | grep -c 'worktree_force_is_safe' || true)
if [ "$force_calls" -le 1 ] && [ "$guarded" -ge 2 ]; then
  printf '  %sPASS%s  (84) helper keeps a single evidence-gated --force call site\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (84) expected <=1 force call site guarded by worktree_force_is_safe; found %s force call(s), %s gate reference(s)\n' "$RED" "$RESET" "$force_calls" "$guarded"
  fail=$((fail+1))
fi

# ==========================================================================
# Issue #755 — `peer-alive-stale` second gate on classify-lock's peer-alive
# verdict. PID-liveness alone can't distinguish a genuine live peer from a
# dead prior-session PID the OS has since recycled onto an unrelated live
# process — the production trace was ~25 accumulated agent-* worktrees from
# prior crashed sessions, several classified peer-alive indefinitely and
# never reaped automatically. The fix corroborates with the lock file's own
# mtime: a lock past the staleness floor (default 60 min;
# SHIPYARD_PEER_LOCK_STALE_MIN / --peer-stale-min) is treated as reapable.
# ==========================================================================

# Portable relative backdate: `touch -t <YYYYMMDDhhmm.ss>` accepts both GNU
# and BSD forms once the timestamp string is computed. Deliberately LOCAL
# time (no `-u`) on both branches — `touch -t` always interprets its
# argument as local wall-clock time regardless of platform, so computing
# the stamp in UTC while `touch -t` reads it as local silently shifts the
# result by the host's UTC offset (observed: a UTC-computed "90 minutes
# ago" landed 150 minutes in the FUTURE on a UTC-4 host). Local-to-local
# keeps the two agreeing everywhere.
backdate_minutes() {
  local target="$1" minutes_ago="$2"
  local stamp
  stamp=$(date -v "-${minutes_ago}M" +%Y%m%d%H%M.%S 2>/dev/null \
    || date --date="${minutes_ago} minutes ago" +%Y%m%d%H%M.%S)
  touch -t "$stamp" "$target"
}

# --- (85) fresh peer lock + --peer-stale-min 0 → 'peer-alive-stale' ---
# A staleness floor of 0 makes any lock "stale" regardless of true age —
# the cheapest deterministic way to prove the override activates without
# waiting on wall-clock time.
(sleep 30) &
sibling_pid=$!
sleep 0.05
if ps -p "$sibling_pid" -o pid= >/dev/null 2>&1; then
  lock_stale0="$tmpdir/peer-stale0.lock"
  printf 'claude agent agent-test-stale0 (pid %d)\n' "$sibling_pid" > "$lock_stale0"
  result=$(run_classify_with_args "$lock_stale0" --peer-stale-min 0)
  assert_equals "$result" "peer-alive-stale" \
    "(85) fresh lock + --peer-stale-min 0 -> 'peer-alive-stale' (override activates)"

  # --- (85a) same fresh lock, default floor (no flag) -> still 'peer-alive' ---
  result=$(run_classify "$lock_stale0")
  assert_equals "$result" "peer-alive" \
    "(85a) fresh lock + default 60min floor -> 'peer-alive' (default behavior unchanged)"
else
  printf '  %sFAIL%s  (85) couldn'\''t spawn sibling process for peer-alive-stale test\n' \
    "$RED" "$RESET"
  fail=$((fail+1))
fi
[ -n "${sibling_pid:-}" ] && kill "$sibling_pid" 2>/dev/null
wait "$sibling_pid" 2>/dev/null

# --- (86) lock backdated 90min, default 60min floor -> 'peer-alive-stale' ---
(sleep 30) &
sibling_pid=$!
sleep 0.05
if ps -p "$sibling_pid" -o pid= >/dev/null 2>&1; then
  lock_old="$tmpdir/peer-old.lock"
  printf 'claude agent agent-test-old (pid %d)\n' "$sibling_pid" > "$lock_old"
  backdate_minutes "$lock_old" 90
  result=$(run_classify "$lock_old")
  assert_equals "$result" "peer-alive-stale" \
    "(86) 90min-old lock + default 60min floor -> 'peer-alive-stale' (issue #755 repro)"

  # --- (86a) same 90min-old lock, --peer-stale-min 120 -> still 'peer-alive' ---
  result=$(run_classify_with_args "$lock_old" --peer-stale-min 120)
  assert_equals "$result" "peer-alive" \
    "(86a) 90min-old lock + --peer-stale-min 120 -> 'peer-alive' (not stale vs a higher floor)"

  # --- (87) SHIPYARD_PEER_LOCK_STALE_MIN env var honored ---
  result=$(SHIPYARD_PEER_LOCK_STALE_MIN=120 bash "$helper" classify-lock "$lock_old" 2>/dev/null)
  assert_equals "$result" "peer-alive" \
    "(87) 90min-old lock + SHIPYARD_PEER_LOCK_STALE_MIN=120 env var -> 'peer-alive' (env var raises floor)"

  # --- (87a) --peer-stale-min flag takes precedence over env var ---
  # Mirrors test (12)'s --orchestrator-pid-over-env-var precedence pattern:
  # env var says "not stale" (very high floor), flag says "definitely stale"
  # (floor 0) — the flag should win.
  result=$(SHIPYARD_PEER_LOCK_STALE_MIN=99999 bash "$helper" classify-lock "$lock_old" --peer-stale-min 0 2>/dev/null)
  assert_equals "$result" "peer-alive-stale" \
    "(87a) --peer-stale-min flag takes precedence over SHIPYARD_PEER_LOCK_STALE_MIN env var"
else
  printf '  %sFAIL%s  (86) couldn'\''t spawn sibling process for peer-alive-stale backdate test\n' \
    "$RED" "$RESET"
  fail=$((fail+1))
fi
[ -n "${sibling_pid:-}" ] && kill "$sibling_pid" 2>/dev/null
wait "$sibling_pid" 2>/dev/null

# --- (88) bad usage: --peer-stale-min missing value / non-integer -> exit 64 ---
bash "$helper" classify-lock "$tmpdir/anything.lock" --peer-stale-min 2>/dev/null
assert_exit_code "$?" "64" \
  "(88) --peer-stale-min with no value -> exit 64"

bash "$helper" classify-lock "$tmpdir/anything.lock" --peer-stale-min notanumber 2>/dev/null
assert_exit_code "$?" "64" \
  "(88a) --peer-stale-min notanumber -> exit 64"

bash "$helper" classify-lock "$tmpdir/anything.lock" --peer-stale-min=notanumber 2>/dev/null
assert_exit_code "$?" "64" \
  "(88b) --peer-stale-min=notanumber -> exit 64"

# --- (89) bad env var: SHIPYARD_PEER_LOCK_STALE_MIN non-integer -> exit 64 ---
SHIPYARD_PEER_LOCK_STALE_MIN=notanumber bash "$helper" classify-lock "$tmpdir/anything.lock" 2>/dev/null
assert_exit_code "$?" "64" \
  "(89) SHIPYARD_PEER_LOCK_STALE_MIN=notanumber -> exit 64"

# ============================================================================
# classify-all subcommand tests (issue #836 fix 1)
#
# Bulk classification: reads every agent-* worktree's lock file and resolves
# liveness for the WHOLE batch in O(1) subprocess calls (one `ps` snapshot,
# one self-ancestor walk, one batched `stat`) instead of forking
# classify-lock once per worktree. Same classification vocabulary as
# classify-lock. Output is one line per worktree — `<name> <classification>
# <lock-pid|null>` — sorted oldest-first by worktree-dir mtime.
#
# Matrix:
#   90) no agent-* worktrees at all -> empty output, exit 0
#   91) bad usage — missing --repo-root -> exit 64
#   92) mixed classifications in one batch: no-lock / dead / self-ancestor /
#       peer-alive, matching classify-lock's per-item verdict for each
#   93) output sorted oldest-first by worktree-dir mtime
#   94) peer-alive-stale via backdated lock + --peer-stale-min
#   95) bad usage — unknown flag / malformed --orchestrator-pid /
#       malformed --peer-stale-min -> exit 64
#   96) --repo-root with no .git/worktrees dir at all -> empty output, exit 0
# ============================================================================

echo
echo "worktree-reap.sh classify-all tests (issue #836 fix 1)"
echo

ca_repo="$tmpdir/ca-repo"

reset_ca_layout() {
  rm -rf "$ca_repo"
  mkdir -p "$ca_repo"
  (
    cd "$ca_repo" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test"
    git commit -q --allow-empty -m "init"
  ) >/dev/null 2>&1
}

# Real linked worktree, same as reap-session-worktrees' rsw_add_worktree —
# classify-all reads real `.git/worktrees/agent-<id>/locked` paths.
ca_add_worktree() {
  local id="$1"
  git -C "$ca_repo" worktree add -q \
    ".claude/worktrees/agent-$id" -b "do-work/issue-$id" >/dev/null 2>&1
}

run_classify_all() {
  bash "$helper" classify-all --repo-root "$ca_repo" "$@" 2>/dev/null
}

# --- (90) no agent-* worktrees at all -> empty output, exit 0 ---
reset_ca_layout
result=$(run_classify_all)
exit_code=$?
assert_equals "${result:-EMPTY}" "EMPTY" \
  "(90) no agent-* worktrees -> empty output"
assert_exit_code "$exit_code" "0" \
  "(90a) no agent-* worktrees -> exit 0"

# --- (91) bad usage — missing --repo-root -> exit 64 ---
bash "$helper" classify-all 2>/dev/null
assert_exit_code "$?" "64" \
  "(91) classify-all with no --repo-root -> exit 64"

# --- (92) mixed classifications in one batch ---
reset_ca_layout
ca_add_worktree nolock
ca_add_worktree dead
ca_add_worktree self
ca_add_worktree peer
printf 'claude agent agent-dead (pid 999999)\n' \
  > "$ca_repo/.git/worktrees/agent-dead/locked"
printf 'claude agent agent-self (pid %s)\n' "$$" \
  > "$ca_repo/.git/worktrees/agent-self/locked"
(sleep 300) &
ca_sibling_pid=$!
sleep 0.05
printf 'claude agent agent-peer (pid %s)\n' "$ca_sibling_pid" \
  > "$ca_repo/.git/worktrees/agent-peer/locked"

result=$(run_classify_all --orchestrator-pid "$$" | sort)
expected=$(printf 'agent-dead dead 999999\nagent-nolock no-lock null\nagent-peer peer-alive %s\nagent-self self-ancestor %s' \
  "$ca_sibling_pid" "$$")
assert_equals "$result" "$expected" \
  "(92) classify-all: no-lock / dead / self-ancestor / peer-alive all resolved in one call"

kill "$ca_sibling_pid" 2>/dev/null
wait "$ca_sibling_pid" 2>/dev/null

# --- (93) output sorted oldest-first by worktree-dir mtime ---
reset_ca_layout
ca_add_worktree newer
ca_add_worktree older
backdate_minutes "$ca_repo/.claude/worktrees/agent-older" 120
backdate_minutes "$ca_repo/.claude/worktrees/agent-newer" 5
result=$(run_classify_all | awk '{print $1}')
expected=$(printf 'agent-older\nagent-newer')
assert_equals "$result" "$expected" \
  "(93) classify-all output sorted oldest-first by worktree-dir mtime"

# --- (94) peer-alive-stale via backdated lock + --peer-stale-min ---
reset_ca_layout
ca_add_worktree stale
(sleep 300) &
ca_sibling_pid=$!
sleep 0.05
printf 'claude agent agent-stale (pid %s)\n' "$ca_sibling_pid" \
  > "$ca_repo/.git/worktrees/agent-stale/locked"
backdate_minutes "$ca_repo/.git/worktrees/agent-stale/locked" 90
result=$(run_classify_all)
assert_equals "$result" "agent-stale peer-alive-stale $ca_sibling_pid" \
  "(94) 90min-old peer lock + default 60min floor -> peer-alive-stale"
result=$(run_classify_all --peer-stale-min 120)
assert_equals "$result" "agent-stale peer-alive $ca_sibling_pid" \
  "(94a) same lock + --peer-stale-min 120 -> not stale vs a higher floor"
kill "$ca_sibling_pid" 2>/dev/null
wait "$ca_sibling_pid" 2>/dev/null

# --- (95) bad usage ---
bash "$helper" classify-all --repo-root "$ca_repo" --bogus-flag 2>/dev/null
assert_exit_code "$?" "64" \
  "(95) classify-all unknown flag -> exit 64"
bash "$helper" classify-all --repo-root "$ca_repo" --orchestrator-pid notanumber 2>/dev/null
assert_exit_code "$?" "64" \
  "(95a) classify-all malformed --orchestrator-pid -> exit 64"
bash "$helper" classify-all --repo-root "$ca_repo" --peer-stale-min notanumber 2>/dev/null
assert_exit_code "$?" "64" \
  "(95b) classify-all malformed --peer-stale-min -> exit 64"

# --- (96) --repo-root with no .git/worktrees dir at all -> empty, exit 0 ---
ca_bare="$tmpdir/ca-bare"
rm -rf "$ca_bare"
mkdir -p "$ca_bare"
result=$(bash "$helper" classify-all --repo-root "$ca_bare" 2>/dev/null)
exit_code=$?
assert_equals "${result:-EMPTY}" "EMPTY" \
  "(96) no .git/worktrees dir -> empty output"
assert_exit_code "$exit_code" "0" \
  "(96a) no .git/worktrees dir -> exit 0"

# ============================================================================
# reap-stale subcommand tests (issue #836 fix 2)
#
# Bounded, checkpointed sweep built on classify-all: reaps at most
# --max-per-session reap-eligible worktrees, oldest-first; peer-alive
# worktrees are always deferred (never counted against the cap);
# --exclude-agent-id (the in-flight guard, issue #832) skips a worktree
# entirely before classification is even consulted; anything reap-eligible
# beyond the cap is left untouched on disk — the on-disk backlog itself is
# the checkpoint that lets a later session continue the sweep with no
# separate state file.
#
# Matrix:
#   97)  dry-run -> lines + summary emitted, nothing removed, no audit log
#   98)  real run, no cap pressure -> all eligible reaped, audit lines
#        carry phase "setup-3b"
#   99)  --max-per-session caps removal (oldest-first); the rest survive on
#        disk and are counted into `remaining`
#   100) --exclude-agent-id (in-flight guard) — excluded worktree untouched
#        and NOT counted in the summary at all
#   101) peer-alive worktrees are deferred and do NOT count against the cap
#   102) checkpoint behavior — two successive reap-stale runs with the same
#        low cap between them clear more of the backlog than either run
#        alone (forward progress across "sessions" with no separate state)
#   103) bad usage — missing --repo-root / --session-id / unknown flag ->
#        exit 64
#   104) --max-per-session 0 -> nothing removed, everything eligible lands
#        in `remaining`
# ============================================================================

echo
echo "worktree-reap.sh reap-stale tests (issue #836 fix 2)"
echo

rs_repo="$tmpdir/rs-repo"
rs_home="$tmpdir/rs-home"
rs_audit_log="$rs_home/reap-audit.jsonl"

reset_rs_layout() {
  rm -rf "$rs_repo" "$rs_home"
  mkdir -p "$rs_home"
  mkdir -p "$rs_repo"
  (
    cd "$rs_repo" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test"
    git commit -q --allow-empty -m "init"
  ) >/dev/null 2>&1
}

rs_add_worktree() {
  local id="$1"
  git -C "$rs_repo" worktree add -q \
    ".claude/worktrees/agent-$id" -b "do-work/issue-$id" >/dev/null 2>&1
}

run_rs() {
  SHIPYARD_HOME="$rs_home" bash "$helper" reap-stale \
    --repo-root "$rs_repo" \
    --session-id "rs-test-session" \
    "$@" 2>/dev/null
}

# --- (97) dry-run -> lines + summary, nothing removed, no audit log ---
reset_rs_layout
rs_add_worktree aaa
rs_add_worktree bbb
result=$(run_rs --dry-run)
last_line=$(printf '%s\n' "$result" | tail -1)
assert_equals "$last_line" "summary: reaped=2 deferred=0 unreaped=0 remaining=0" \
  "(97) dry-run summary line"
[ -d "$rs_repo/.claude/worktrees/agent-aaa" ] && dry_kept=yes || dry_kept=no
assert_equals "$dry_kept" "yes" \
  "(97a) dry-run -> worktree NOT removed"
[ -f "$rs_audit_log" ] && dry_audit=present || dry_audit=absent
assert_equals "$dry_audit" "absent" \
  "(97b) dry-run -> no audit-log write"

# --- (98) real run, no cap pressure -> all eligible reaped, phase tagged ---
reset_rs_layout
rs_add_worktree aaa
rs_add_worktree bbb
result=$(run_rs)
last_line=$(printf '%s\n' "$result" | tail -1)
assert_equals "$last_line" "summary: reaped=2 deferred=0 unreaped=0 remaining=0" \
  "(98) real run summary line"
[ -d "$rs_repo/.claude/worktrees/agent-aaa" ] && real_kept=yes || real_kept=no
assert_equals "$real_kept" "no" \
  "(98a) real run -> agent-aaa worktree removed"
line_count=$(wc -l < "$rs_audit_log" 2>/dev/null | tr -d ' ')
assert_equals "$line_count" "2" \
  "(98b) real run -> two audit-log lines"
phase_count=$(grep -c '"phase":"setup-3b"' "$rs_audit_log" 2>/dev/null | tr -d ' ')
assert_equals "$phase_count" "2" \
  "(98c) real run -> audit lines carry phase setup-3b"

# --- (99) --max-per-session caps removal, oldest-first ---
reset_rs_layout
rs_add_worktree older
rs_add_worktree newer
backdate_minutes "$rs_repo/.claude/worktrees/agent-older" 120
backdate_minutes "$rs_repo/.claude/worktrees/agent-newer" 5
result=$(run_rs --max-per-session 1)
last_line=$(printf '%s\n' "$result" | tail -1)
assert_equals "$last_line" "summary: reaped=1 deferred=0 unreaped=0 remaining=1" \
  "(99) cap=1 -> exactly one reaped, one left in remaining"
[ -d "$rs_repo/.claude/worktrees/agent-older" ] && older_kept=yes || older_kept=no
assert_equals "$older_kept" "no" \
  "(99a) the OLDER worktree is the one reaped (oldest-first)"
[ -d "$rs_repo/.claude/worktrees/agent-newer" ] && newer_kept=yes || newer_kept=no
assert_equals "$newer_kept" "yes" \
  "(99b) the newer worktree survives — left for a future session"

# --- (100) --exclude-agent-id (in-flight guard, issue #832) ---
reset_rs_layout
rs_add_worktree aaa
rs_add_worktree inflight
result=$(run_rs --exclude-agent-id inflight)
last_line=$(printf '%s\n' "$result" | tail -1)
assert_equals "$last_line" "summary: reaped=1 deferred=0 unreaped=0 remaining=0" \
  "(100) excluded worktree is invisible to the summary entirely"
[ -d "$rs_repo/.claude/worktrees/agent-inflight" ] && inflight_kept=yes || inflight_kept=no
assert_equals "$inflight_kept" "yes" \
  "(100a) excluded (in-flight) worktree is never touched"
excluded_in_output=$(printf '%s\n' "$result" | grep -c "agent-inflight" || true)
assert_equals "$excluded_in_output" "0" \
  "(100b) excluded worktree produces no reaped:/deferred: line at all"

# --- (101) peer-alive is deferred and does NOT count against the cap ---
reset_rs_layout
rs_add_worktree peer
rs_add_worktree aaa
(sleep 300) &
rs_sibling_pid=$!
sleep 0.05
printf 'claude agent agent-peer (pid %s)\n' "$rs_sibling_pid" \
  > "$rs_repo/.git/worktrees/agent-peer/locked"
result=$(run_rs --max-per-session 1)
last_line=$(printf '%s\n' "$result" | tail -1)
assert_equals "$last_line" "summary: reaped=1 deferred=1 unreaped=0 remaining=0" \
  "(101) peer-alive deferred alongside a cap=1 reap — deferred doesn't eat the cap"
[ -d "$rs_repo/.claude/worktrees/agent-peer" ] && peer_kept=yes || peer_kept=no
assert_equals "$peer_kept" "yes" \
  "(101a) peer-alive worktree is left on disk (deferred, not removed)"
[ -d "$rs_repo/.claude/worktrees/agent-aaa" ] && aaa_kept=yes || aaa_kept=no
assert_equals "$aaa_kept" "no" \
  "(101b) the reap-eligible sibling still gets reaped under the same cap"
kill "$rs_sibling_pid" 2>/dev/null
wait "$rs_sibling_pid" 2>/dev/null

# --- (102) checkpoint behavior — forward progress across successive runs ---
# No separate checkpoint FILE is used (see reap_stale's docstring) — the
# on-disk backlog itself is the checkpoint. Two runs at cap=1 against a
# 3-worktree backlog should together clear 2 of the 3, oldest-first, with
# nothing re-processed or skipped.
reset_rs_layout
rs_add_worktree a
rs_add_worktree b
rs_add_worktree c
backdate_minutes "$rs_repo/.claude/worktrees/agent-a" 180
backdate_minutes "$rs_repo/.claude/worktrees/agent-b" 120
backdate_minutes "$rs_repo/.claude/worktrees/agent-c" 60
run_rs --max-per-session 1 >/dev/null
first_remaining=$(find "$rs_repo/.claude/worktrees" -maxdepth 1 -type d -name 'agent-*' 2>/dev/null | wc -l | tr -d ' ')
assert_equals "$first_remaining" "2" \
  "(102) first session's sweep leaves 2 of 3 (checkpoint = on-disk state)"
run_rs --max-per-session 1 >/dev/null
second_remaining=$(find "$rs_repo/.claude/worktrees" -maxdepth 1 -type d -name 'agent-*' 2>/dev/null | wc -l | tr -d ' ')
assert_equals "$second_remaining" "1" \
  "(102a) second session's sweep continues from where the first left off"
[ -d "$rs_repo/.claude/worktrees/agent-c" ] && c_survives=yes || c_survives=no
assert_equals "$c_survives" "yes" \
  "(102b) the newest worktree (c) is still the one left after two oldest-first passes"

# --- (103) bad usage ---
SHIPYARD_HOME="$rs_home" bash "$helper" reap-stale \
  --session-id "x" 2>/dev/null
assert_exit_code "$?" "64" \
  "(103) reap-stale missing --repo-root -> exit 64"
SHIPYARD_HOME="$rs_home" bash "$helper" reap-stale \
  --repo-root "$rs_repo" 2>/dev/null
assert_exit_code "$?" "64" \
  "(103a) reap-stale missing --session-id -> exit 64"
SHIPYARD_HOME="$rs_home" bash "$helper" reap-stale \
  --repo-root "$rs_repo" --session-id "x" --bogus-flag 2>/dev/null
assert_exit_code "$?" "64" \
  "(103b) reap-stale unknown flag -> exit 64"

# --- (104) --max-per-session 0 -> nothing removed, all land in remaining ---
reset_rs_layout
rs_add_worktree aaa
rs_add_worktree bbb
result=$(run_rs --max-per-session 0)
last_line=$(printf '%s\n' "$result" | tail -1)
assert_equals "$last_line" "summary: reaped=0 deferred=0 unreaped=0 remaining=2" \
  "(104) --max-per-session 0 -> both worktrees land in remaining, untouched"
[ -d "$rs_repo/.claude/worktrees/agent-aaa" ] && zero_cap_kept=yes || zero_cap_kept=no
assert_equals "$zero_cap_kept" "yes" \
  "(104a) --max-per-session 0 -> nothing actually removed"

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
