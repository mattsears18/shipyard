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

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
