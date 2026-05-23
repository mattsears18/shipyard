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
#   7) bad usage           → exit 2
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
#  14) issue #263 — bad flag values exit 2
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
assert_exit_code "$?" "2" \
  "(7) classify-lock without path → exit 2"

bash "$helper" 2>/dev/null
assert_exit_code "$?" "2" \
  "(7a) no subcommand → exit 2"

bash "$helper" unknown-cmd 2>/dev/null
assert_exit_code "$?" "2" \
  "(7b) unknown subcommand → exit 2"

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

# --- (14) bad flag values exit 2 ---
bash "$helper" classify-lock "$tmpdir/anything.lock" --orchestrator-pid 2>/dev/null
assert_exit_code "$?" "2" \
  "(14) --orchestrator-pid with no value → exit 2"

bash "$helper" classify-lock "$tmpdir/anything.lock" --orchestrator-pid notanumber 2>/dev/null
assert_exit_code "$?" "2" \
  "(14a) --orchestrator-pid with non-numeric value → exit 2"

bash "$helper" classify-lock "$tmpdir/anything.lock" --orchestrator-pid=notanumber 2>/dev/null
assert_exit_code "$?" "2" \
  "(14b) --orchestrator-pid=notanumber → exit 2"

bash "$helper" classify-lock "$tmpdir/anything.lock" --unknown-flag 2>/dev/null
assert_exit_code "$?" "2" \
  "(14c) unknown flag → exit 2"

# Malformed env-var value also surfaces as exit 2 (a config bug we want loud).
SHIPYARD_ORCHESTRATOR_PID=notanumber bash "$helper" classify-lock "$tmpdir/anything.lock" 2>/dev/null
assert_exit_code "$?" "2" \
  "(14d) SHIPYARD_ORCHESTRATOR_PID=notanumber → exit 2"

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

# --- (26) bad usage — missing --repo-root → exit 2 ---
SHIPYARD_HOME="$fake_shipyard_home" bash "$helper" find-orphan-orchestrators \
  --current-session-id foo >/dev/null 2>&1
assert_exit_code "$?" "2" \
  "(26) missing --repo-root → exit 2"

# --- (27) bad usage — missing --current-session-id → exit 2 ---
SHIPYARD_HOME="$fake_shipyard_home" bash "$helper" find-orphan-orchestrators \
  --repo-root "$fake_repo" >/dev/null 2>&1
assert_exit_code "$?" "2" \
  "(27) missing --current-session-id → exit 2"

# --- (28) bad usage — unknown flag → exit 2 ---
SHIPYARD_HOME="$fake_shipyard_home" bash "$helper" find-orphan-orchestrators \
  --repo-root "$fake_repo" --current-session-id foo --unknown 2>/dev/null
assert_exit_code "$?" "2" \
  "(28) unknown flag → exit 2"

# --- (29) bad usage — unexpected positional → exit 2 ---
SHIPYARD_HOME="$fake_shipyard_home" bash "$helper" find-orphan-orchestrators \
  --repo-root "$fake_repo" --current-session-id foo trailing-positional 2>/dev/null
assert_exit_code "$?" "2" \
  "(29) unexpected positional arg → exit 2"

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
#   - Required-flag validation surfaces as exit 2 with a useful stderr.
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

# --- (34) reap --action=reaped-orphan-orchestrator with rm-fallback path ---
# The worktree dir exists on disk but isn't registered with git (typical
# crash-orphan). git worktree remove will fail; the helper should fall
# back to rm -rf and emit the -raw-rm action variant.
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

# Dir should have been removed (rm -rf fallback fired).
if [ ! -d "$orphan_dir" ]; then
  printf '  %sPASS%s  (34a) orphan dir removed via rm -rf fallback\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (34a) orphan dir still present at %s\n' "$RED" "$RESET" "$orphan_dir"
  fail=$((fail+1))
fi

line=$(cat "$audit_log")
shape_ok=1
case "$line" in *'"action":"reaped-orphan-orchestrator-raw-rm"'*) ;; *) shape_ok=0 ;; esac
case "$line" in *'"reaped_session_id":"dead-session-9"'*) ;; *) shape_ok=0 ;; esac
case "$line" in *'"phase":"setup-1.6.5"'*) ;; *) shape_ok=0 ;; esac
if [ "$shape_ok" = "1" ]; then
  printf '  %sPASS%s  (34b) audit line carries -raw-rm action variant\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (34b) expected -raw-rm action variant; line was: %s\n' "$RED" "$RESET" "$line"
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

# --- (37) bad usage: --action required → exit 2 ---
run_reap --worktree-path "$reap_repo/x" --worktree-name "x" --session-id s
assert_exit_code "$?" "2" \
  "(37) missing --action → exit 2"

# --- (38) bad usage: --classification required when --action=reaped ---
run_reap --action reaped --worktree-path "$reap_repo/x" --worktree-name "x" \
  --session-id s --lock-pid null --skip-remove
assert_exit_code "$?" "2" \
  "(38) reaped without --classification → exit 2"

# --- (39) bad usage: --reason required when --action=deferred ---
run_reap --action deferred --worktree-path "$reap_repo/x" --worktree-name "x" \
  --session-id s --lock-pid null
assert_exit_code "$?" "2" \
  "(39) deferred without --reason → exit 2"

# --- (40) bad usage: --reaped-session-id required when --action=reaped-orphan-orchestrator ---
run_reap --action reaped-orphan-orchestrator \
  --worktree-path "$reap_repo/x" --worktree-name "x" --session-id s
assert_exit_code "$?" "2" \
  "(40) reaped-orphan-orchestrator without --reaped-session-id → exit 2"

# --- (41) bad usage: unknown --action → exit 2 ---
run_reap --action bogus --worktree-path "$reap_repo/x" --worktree-name "x" \
  --session-id s --skip-remove
assert_exit_code "$?" "2" \
  "(41) unknown --action → exit 2"

# --- (42) bad usage: --lock-pid must be 'null' or non-negative integer ---
run_reap --action reaped --worktree-path "$reap_repo/x" --worktree-name "x" \
  --session-id s --classification "dead" --lock-pid "not-a-pid" --skip-remove
assert_exit_code "$?" "2" \
  "(42) --lock-pid with non-numeric, non-'null' value → exit 2"

# --- (43) bad usage: --actor-pid must be numeric ---
run_reap --action reaped --worktree-path "$reap_repo/x" --worktree-name "x" \
  --session-id s --classification "dead" --lock-pid null --actor-pid "abc" --skip-remove
assert_exit_code "$?" "2" \
  "(43) --actor-pid with non-numeric value → exit 2"

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

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
