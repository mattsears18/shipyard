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
#                          → `unknown` (issue #1206 — fail CLOSED, not
#                                       `dead`; extraction failure must not
#                                       default to the destructive verdict)
#   4) lock with self PID  → `self-ancestor`  (THE bug-fix path)
#   5) lock with parent PID
#                          → `self-ancestor`  (ancestor walk works)
#   6) lock with sibling-process PID
#                          → `peer-alive`     (original behaviour preserved
#                                              for genuine peer agents)
#   7) bad usage           → exit 64
#   8) regression guard: canonical lock format with peer/own PID
#                          → `peer-alive` / `self-ancestor`
#   8b-8d) issue #1206 — REAL harness lock shape `(pid <N> start <ctime>)`
#                          (not the idealized `(pid <N>)` every test above
#                          uses): live peer PID → `peer-alive` (the exact
#                          repro — this used to misparse as `dead`), own PID
#                          → `self-ancestor`, genuinely-dead PID → `dead`
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
#  58-66) issue #509 — reap-session-worktrees targeted this-session reap
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
# 110-112) issue #1482 — reap-stale's stray-tombstone pass is bounded by
#         --max-per-session (it was the one unbounded step in a
#         "bounded and checkpointed" sweep) and reports into the summary
#         line + exit code (a failed removal used to print a line and then
#         vanish). Includes the assertions that FALSIFY the issue's filed
#         "a stale tombstone wedges subsequent passes" diagnosis: a failure
#         aborts nothing, siblings in the same pass are still swept, and a
#         later pass drains the backlog completely.
#
# Issue #941 — the detect-orchestrator-pid / derive-session-id /
# find-orphan-orchestrators subcommands (and their test coverage, tests
# 15-17, 18-30, 67-75a in prior revisions of this file) moved to a
# dedicated sibling script + test suite: scripts/session-identity.sh and
# scripts/tests/session-identity.test.sh. Nothing in that coverage was
# dropped — see that test file's own header for the full matrix.
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

# Issue #1207 — format an epoch as a `ps -o lstart`-shaped ctime string
# ("Mon Aug 10 12:58:36 2026") in the given zone ("utc" or "local"). Used
# ONLY to fabricate lock fixtures with a KNOWN, deterministic relationship
# to a live sibling's actual start time — the inverse of worktree-reap.sh's
# own `parse_ctime_epoch()`, same GNU-then-BSD dual-path portability
# strategy every other date helper in this repo already uses (e.g.
# session-state.test.sh's `date -v-2H ... || date -d '2 hours ago' ...`).
epoch_to_ctime() {
  local epoch="$1"
  local zone="$2"
  local out=""
  if [ "$zone" = "utc" ]; then
    out=$(date -u -r "$epoch" +"%a %b %e %T %Y" 2>/dev/null)
    [ -z "$out" ] && out=$(date -u -d "@$epoch" +"%a %b %e %T %Y" 2>/dev/null)
  else
    out=$(date -r "$epoch" +"%a %b %e %T %Y" 2>/dev/null)
    [ -z "$out" ] && out=$(date -d "@$epoch" +"%a %b %e %T %Y" 2>/dev/null)
  fi
  printf '%s' "$out"
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
# Issue #1206: this used to assert 'dead' (extraction-failed treated as
# dead) — a fail-OPEN default for a destructive operation. An unparseable
# lock might belong to a live peer whose lock simply doesn't match the
# expected shape, so classify-lock must fail CLOSED instead: 'unknown',
# treated identically to 'peer-alive' by every caller that gates a defer
# decision on the classification.
lock_malformed="$tmpdir/malformed.lock"
cat > "$lock_malformed" <<EOF
some other content with no pid syntax
EOF
result=$(run_classify "$lock_malformed")
assert_equals "$result" "unknown" \
  "(3) malformed lock (no PID) → 'unknown' (fail closed, issue #1206 — NOT 'dead')"

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

# --- (8b)-(8d) issue #1206 — REAL harness lock shape regression guard ---
# Every test above (and the pre-#1206 production code) used the IDEALIZED
# `(pid <N>)` shape from the doc comment. The actual Claude Code harness
# writes an additional `start <ctime>` field between the PID and the
# closing paren:
#   claude session orchestrator-do-work-20260810T221957Z-35757 (pid 52469 start Mon Aug 10 12:58:36 2026)
# The pre-#1206 extraction regex, `grep -oE '[0-9]+\)'`, matched the FIRST
# digit-run immediately followed by `)` — for this shape that's the ctime's
# trailing 4-digit YEAR, not the PID. Every one of these fixtures uses the
# real shape verbatim (with a synthetic PID substituted in) so a regression
# back to the old regex fails loudly here instead of only in production.
real_shape_lock="$tmpdir/real-shape.lock"

# (8b) REAL shape + a live sibling PID → 'peer-alive', NOT 'dead'. This is
# the exact #1206 repro: a live peer session misclassified as dead because
# the extraction grabbed the ctime's year (always a low-numbered, almost
# certainly-dead "PID" like 2026) instead of the real PID.
#
# The lock's `start` field is set to the sibling's OWN actual spawn epoch
# (captured right after spawn), not a hardcoded date — issue #1207 added a
# cross-check between this field and `ps -o lstart` for the same pid, and a
# hardcoded/unrelated date would now (correctly) trip that check and
# reclassify this as 'peer-alive-stale' instead. Using the real spawn time
# keeps this fixture's PID-EXTRACTION concern (issue #1206) decoupled from
# the newer START-TIME-CORROBORATION concern (issue #1207, covered by its
# own dedicated (8e)-(8h) tests below).
(sleep 30) &
sibling_pid=$!
sleep 0.05
if ps -p "$sibling_pid" -o pid= >/dev/null 2>&1; then
  spawn_epoch=$(date +%s)
  printf 'claude session orchestrator-do-work-20260810T221957Z-35757 (pid %d start %s)\n' \
    "$sibling_pid" "$(epoch_to_ctime "$spawn_epoch" local)" > "$real_shape_lock"
  result=$(run_classify "$real_shape_lock")
  assert_equals "$result" "peer-alive" \
    "(8b) issue #1206 repro: REAL lock shape '(pid N start ctime)' with a LIVE peer PID → 'peer-alive' (NOT 'dead' — the ctime-year misparse this issue reports)"
fi
[ -n "${sibling_pid:-}" ] && kill "$sibling_pid" 2>/dev/null
wait "$sibling_pid" 2>/dev/null

# (8c) REAL shape + our own PID → 'self-ancestor', not 'peer-alive' and not
# 'dead'. Confirms the anchored regex still correctly extracts a PID that
# happens to be reapable via the ancestor walk, not just a peer.
printf 'claude session orchestrator-test (pid %d start Mon Aug 10 12:58:36 2026)\n' "$$" \
  > "$real_shape_lock"
result=$(run_classify "$real_shape_lock")
assert_equals "$result" "self-ancestor" \
  "(8c) REAL lock shape with our OWN pid → 'self-ancestor' (anchored regex still finds the true PID, not the ctime year)"

# (8d) REAL shape + a genuinely-dead PID → 'dead'. Confirms the fix doesn't
# overcorrect into deferring on every real-shape lock regardless of
# liveness — a real-shape lock naming a truly-dead PID must still reap.
(true) &
dead_pid_real_shape=$!
wait "$dead_pid_real_shape" 2>/dev/null
while ps -p "$dead_pid_real_shape" -o pid= >/dev/null 2>&1; do
  sleep 0.05
done
printf 'claude session orchestrator-test (pid %d start Mon Aug 10 12:58:36 2026)\n' \
  "$dead_pid_real_shape" > "$real_shape_lock"
result=$(run_classify "$real_shape_lock")
assert_equals "$result" "dead" \
  "(8d) REAL lock shape with a genuinely-DEAD pid → 'dead' (still reap-eligible — the fix doesn't over-defer)"

# --- (8e)-(8h) issue #1207 — start-time cross-check (PID-reuse
# defense-in-depth) ---
#
# #755's mtime gate corroborates peer-liveness with a PROXY signal (is the
# lock file still being touched). This gate corroborates it DIRECTLY: the
# lock's own recorded `start <ctime>` field against `ps -o lstart` for the
# same still-alive pid. The catch, confirmed live during #1207's
# investigation against a real production lock: the SAME still-live
# process's lock-recorded start time and `ps -o lstart`'s reading of it can
# disagree by exactly the host's local UTC offset (lock `12:58:36` vs `ps`
# `08:58:36`, four hours apart, EDT is UTC-4 — same instant, different
# clock-face reading). These fixtures pin exactly that shape rather than
# relying on incidental host timezone: (8f) constructs the lock's `start`
# field by formatting the sibling's REAL epoch in UTC (`epoch_to_ctime ...
# utc`) while `ps -o lstart` reports it in local time — on a non-UTC host
# this reproduces the exact cross-zone disagreement from the issue; on a
# UTC host the two strings happen to coincide, which still exercises the
# same code path (the "zero offset" acceptance branch) and still must pass.
real_shape_lock2="$tmpdir/real-shape-1207.lock"

# (8e) accurate LOCAL-zone start time (matches what `ps -o lstart` itself
# renders) → 'peer-alive'. The zero-offset acceptance branch.
(sleep 30) &
sibling_pid=$!
sleep 0.05
if ps -p "$sibling_pid" -o pid= >/dev/null 2>&1; then
  spawn_epoch=$(date +%s)
  printf 'claude session orchestrator-test (pid %d start %s)\n' \
    "$sibling_pid" "$(epoch_to_ctime "$spawn_epoch" local)" > "$real_shape_lock2"
  result=$(run_classify "$real_shape_lock2")
  assert_equals "$result" "peer-alive" \
    "(8e) issue #1207: lock start recorded in LOCAL zone, matches ps -o lstart exactly → 'peer-alive'"
fi
[ -n "${sibling_pid:-}" ] && kill "$sibling_pid" 2>/dev/null
wait "$sibling_pid" 2>/dev/null

# (8f) THE hazard case: lock start recorded in UTC while `ps -o lstart`
# reports local time — same instant, different clock-face reading. MUST
# classify 'peer-alive', never 'peer-alive-stale' — misclassifying a live
# lock as stale enables reaping a running session's worktree.
(sleep 30) &
sibling_pid=$!
sleep 0.05
if ps -p "$sibling_pid" -o pid= >/dev/null 2>&1; then
  spawn_epoch=$(date +%s)
  printf 'claude session orchestrator-do-work-20260810T221957Z-35757 (pid %d start %s)\n' \
    "$sibling_pid" "$(epoch_to_ctime "$spawn_epoch" utc)" > "$real_shape_lock2"
  result=$(run_classify "$real_shape_lock2")
  assert_equals "$result" "peer-alive" \
    "(8f) issue #1207 REPRO: lock start recorded in UTC, ps -o lstart reads local (same instant, host-UTC-offset apart) → 'peer-alive' (NOT 'peer-alive-stale' — the destructive misclassification this issue exists to prevent)"
fi
[ -n "${sibling_pid:-}" ] && kill "$sibling_pid" 2>/dev/null
wait "$sibling_pid" 2>/dev/null

# (8g) genuine mismatch (suspected PID reuse): lock records a start time 20
# hours away from the live pid's actual start — outside any real-world UTC
# offset (max is ±14h) in EITHER zone interpretation, so this can't
# coincidentally pass on any host regardless of its local timezone. Direct
# evidence the PID was recycled → 'peer-alive-stale' (reap-eligible),
# regardless of the lock FILE's own mtime freshness (it's freshly written
# in this fixture, so the #755 mtime gate alone would say 'peer-alive' —
# this gate must override that).
(sleep 30) &
sibling_pid=$!
sleep 0.05
if ps -p "$sibling_pid" -o pid= >/dev/null 2>&1; then
  spawn_epoch=$(date +%s)
  mismatched_epoch=$(( spawn_epoch - 20 * 3600 ))
  printf 'claude session orchestrator-test (pid %d start %s)\n' \
    "$sibling_pid" "$(epoch_to_ctime "$mismatched_epoch" utc)" > "$real_shape_lock2"
  result=$(run_classify "$real_shape_lock2")
  assert_equals "$result" "peer-alive-stale" \
    "(8g) issue #1207: lock start 20h off the live pid's actual start (outside any real UTC offset) → 'peer-alive-stale' (PID reuse suspected, overrides a fresh lock mtime)"
fi
[ -n "${sibling_pid:-}" ] && kill "$sibling_pid" 2>/dev/null
wait "$sibling_pid" 2>/dev/null

# (8h) fail-safe regression guard: a lock with NO `start` field at all (the
# common `claude agent <agent-id> (pid <N>)` shape — the majority of
# real-world agent-* worktree locks) must skip this gate entirely, not
# treat "no start field" as a mismatch. Reuses test (6)'s exact fixture
# shape to prove the new gate is a true no-op on it.
(sleep 30) &
sibling_pid=$!
sleep 0.05
if ps -p "$sibling_pid" -o pid= >/dev/null 2>&1; then
  lock_no_start="$tmpdir/no-start.lock"
  printf 'claude agent agent-test-1207-nostart (pid %d)\n' "$sibling_pid" > "$lock_no_start"
  result=$(run_classify "$lock_no_start")
  assert_equals "$result" "peer-alive" \
    "(8h) issue #1207: lock with NO start field → 'peer-alive' unaffected (gate is a no-op absent a start field)"
fi
[ -n "${sibling_pid:-}" ] && kill "$sibling_pid" 2>/dev/null
wait "$sibling_pid" 2>/dev/null

# (8i) SHIPYARD_LOCK_START_TOLERANCE_SEC override: a 90-second-off start
# time is within the default 120s tolerance (→ 'peer-alive'), but outside a
# tightened 10s tolerance (→ 'peer-alive-stale'). Confirms the knob wires
# through end-to-end.
(sleep 30) &
sibling_pid=$!
sleep 0.05
if ps -p "$sibling_pid" -o pid= >/dev/null 2>&1; then
  spawn_epoch=$(date +%s)
  near_epoch=$(( spawn_epoch - 90 ))
  printf 'claude session orchestrator-test (pid %d start %s)\n' \
    "$sibling_pid" "$(epoch_to_ctime "$near_epoch" local)" > "$real_shape_lock2"
  result=$(run_classify "$real_shape_lock2")
  assert_equals "$result" "peer-alive" \
    "(8i) issue #1207: 90s-off start time within default 120s tolerance → 'peer-alive'"
  result=$(SHIPYARD_LOCK_START_TOLERANCE_SEC=10 run_classify "$real_shape_lock2")
  assert_equals "$result" "peer-alive-stale" \
    "(8i-a) issue #1207: same 90s-off start time, SHIPYARD_LOCK_START_TOLERANCE_SEC=10 → 'peer-alive-stale' (tighter tolerance activates)"
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
# --bypass-return-check: this test is about the audit-line SHAPE, not the
# issue #1237 return-check gate (covered separately below, tests 46-49) —
# no session-state fixture exists for "test-session-1" here.
reset_reap_layout
run_reap \
  --action reaped \
  --worktree-path "$reap_repo/.git/worktrees/agent-test1" \
  --worktree-name "agent-test1" \
  --session-id "test-session-1" \
  --actor-pid 12345 \
  --classification "self-ancestor" \
  --lock-pid 999999 \
  --bypass-return-check "test fixture (#1237 gate covered separately)" \
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
  --bypass-return-check "test fixture (#1237 gate covered separately)" \
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

# --- (41a) issue #1305 — an unrecognized flag on the `reap` subcommand must
# exit non-zero (EX_USAGE, 64), never silently exit 0. The reported repro
# used `--repo-root` (the flag every OTHER subcommand in this script takes,
# making it an easy mistake to carry over to `reap`, which does not accept
# it) alongside `--worktree`, neither of which `reap` recognizes. A caller
# that only checks the exit code must not record a successful reap that
# never happened. ---
run_reap --repo-root "$reap_repo" --worktree "$reap_repo/x"
assert_exit_code "$?" "64" \
  "(41a) unrecognized --repo-root flag on reap → exit 64, not 0"
if grep -q "unknown flag: --repo-root" "$tmpdir/reap.stderr" 2>/dev/null; then
  printf '  %sPASS%s  (41a-msg) stderr names the offending flag\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (41a-msg) stderr did not name --repo-root as the unknown flag — was: %s\n' \
    "$RED" "$RESET" "$(cat "$tmpdir/reap.stderr" 2>/dev/null)"
  fail=$((fail+1))
fi

# --- (41b) a second, differently-shaped unrecognized flag on `reap` also
# exits 64 — confirms the guard isn't special-cased to --repo-root alone. ---
run_reap --action reaped --worktree-path "$reap_repo/x" --worktree-name "x" \
  --session-id s --classification "dead" --lock-pid null --skip-remove \
  --some-bogus-flag value
assert_exit_code "$?" "64" \
  "(41b) unrecognized trailing flag on an otherwise well-formed reap call → exit 64"

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
  --bypass-return-check="test fixture (#1237 gate covered separately)" \
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
# Issue #1237 — reconciled-return gate on `reap --action reaped`. A reap
# targeting an `agent-*` worktree must fail closed unless this session's
# persisted state already records that agent-id as returned
# (.returned_agent_ids["<agent-id>"]), OR the caller passes an explicit
# --bypass-return-check <reason>. Pins BOTH directions: refusal when there
# is no proof, and success once proof exists (or is explicitly bypassed).
# ============================================================================

session_state_helper="${here}/../session-state.sh"

# --- (46) no .returned_agent_ids record, no --bypass-return-check → refused ---
reset_reap_layout
run_reap \
  --action reaped \
  --worktree-path "$reap_repo/.git/worktrees/agent-unreturned" \
  --worktree-name "agent-unreturned" \
  --session-id "no-such-session-1237" \
  --classification "dead" \
  --lock-pid null \
  --skip-remove
reap_refused_rc=$?
assert_exit_code "$reap_refused_rc" "1" \
  "(46) reap --action reaped refuses an agent-* worktree with no recorded return"

refused_line=$(cat "$audit_log" 2>/dev/null)
case "$refused_line" in
  *'"action":"reap-refused"'*) refused_shape_ok=1 ;;
  *) refused_shape_ok=0 ;;
esac
assert_equals "$refused_shape_ok" "1" \
  "(46a) the refusal writes a reap-refused audit-log line, not reaped"

# --- (47) same target, --bypass-return-check supplied → succeeds ---
reset_reap_layout
run_reap \
  --action reaped \
  --worktree-path "$reap_repo/.git/worktrees/agent-unreturned2" \
  --worktree-name "agent-unreturned2" \
  --session-id "no-such-session-1237" \
  --classification "dead" \
  --lock-pid null \
  --skip-remove \
  --bypass-return-check "test: crash-recovery equivalent"
assert_exit_code "$?" "0" \
  "(47) --bypass-return-check overrides the refusal for a documented exception"

bypass_line=$(cat "$audit_log" 2>/dev/null)
case "$bypass_line" in
  *'"action":"reaped"'*) bypass_shape_ok=1 ;;
  *) bypass_shape_ok=0 ;;
esac
assert_equals "$bypass_shape_ok" "1" \
  "(47a) the bypassed reap writes a normal reaped audit-log line"

# --- (48) agent-id IS recorded as returned in session-state → succeeds with
# no bypass flag at all — this is the normal, common-case path every
# same-turn (A.1 shipped / step B) and later-turn (pre-dispatch) reap takes.
returned_session="reap-gate-returned-session"
tmp_session_home=$(mktemp -d)
SHIPYARD_HOME="$tmp_session_home" bash "$session_state_helper" init \
  --session-id "$returned_session" --repo "owner/repo" --pid 0 >/dev/null 2>&1
SHIPYARD_HOME="$tmp_session_home" bash "$session_state_helper" update \
  --session-id "$returned_session" \
  --set '.returned_agent_ids["gated-ok"] = "2026-01-01T00:00:00Z"' >/dev/null 2>&1

reset_reap_layout
(
  cd "$reap_repo" || exit 99
  SHIPYARD_HOME="$tmp_session_home" bash "$helper" reap \
    --action reaped \
    --worktree-path "$reap_repo/.git/worktrees/agent-gated-ok" \
    --worktree-name "agent-gated-ok" \
    --session-id "$returned_session" \
    --classification "dead" \
    --lock-pid null \
    --skip-remove
)
assert_exit_code "$?" "0" \
  "(48) a recorded .returned_agent_ids entry satisfies the gate with no bypass flag"

# A sibling agent-id NOT in the same session's .returned_agent_ids is still
# refused — confirms the gate checks the SPECIFIC agent-id, not merely
# "this session has a state file at all."
(
  cd "$reap_repo" || exit 99
  SHIPYARD_HOME="$tmp_session_home" bash "$helper" reap \
    --action reaped \
    --worktree-path "$reap_repo/.git/worktrees/agent-gated-sibling" \
    --worktree-name "agent-gated-sibling" \
    --session-id "$returned_session" \
    --classification "dead" \
    --lock-pid null \
    --skip-remove
)
assert_exit_code "$?" "1" \
  "(48a) a DIFFERENT agent-id in the same (existing) session is still refused"
rm -rf "$tmp_session_home"

# --- (49) a non-agent-* worktree name (the orchestrator reaping its own
# worktree) is out of scope for the gate entirely — no bypass needed, no
# session-state lookup even attempted, because there is no "did an agent
# return" question to ask about the orchestrator's own worktree.
reset_reap_layout
run_reap \
  --action reaped \
  --worktree-path "$reap_repo/.git/worktrees/orchestrator-some-session" \
  --worktree-name "orchestrator-some-session" \
  --session-id "no-such-session-1237" \
  --classification "self-orchestrator" \
  --lock-pid null \
  --skip-remove
assert_exit_code "$?" "0" \
  "(49) a non-agent-* worktree name is exempt from the return-check gate"

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
#   - A `git branch -D` failure emits `reaped-branch-failed` + a reason, NOT
#     a false `reaped-orphan-branch`, and no stdout `reaped-branch:` line
#     (issue #874).
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

# --- (57b)/(57c) a `git branch -D` failure does NOT log a false success ---
# Issue #874 — the exit status used to be discarded (`|| true`) and the audit
# line was written unconditionally, so a branch whose delete failed (unmerged
# commit, permission error, concurrent-delete race) was indistinguishable
# from a real reap. Force a deterministic failure by making `.git/refs/heads`
# non-writable: `git branch -D` needs to create a `*.lock` file there to
# unlink the ref, so every branch delete in the sweep fails and the ref
# survives — mirroring the (81) `reaped-failed` permission-denial fixture
# above for `reap_action`. Skipped under root, which bypasses permission bits.
if [ "$(id -u)" = "0" ]; then
  printf '  %sSKIP%s  (57b) reaped-branch-failed audit line (running as root — permission bits are a no-op)\n' "$GREEN" "$RESET"
else
  reset_rob_layout
  git -C "$rob_repo" branch worktree-agent-perm-fail-test HEAD
  chmod 0500 "$rob_repo/.git/refs/heads"
  result=$(run_rob)
  rob_rc=$?
  chmod 0700 "$rob_repo/.git/refs/heads"

  assert_equals "${result:-EMPTY}" "EMPTY" \
    "(57b) failed git branch -D emits NO 'reaped-branch:' stdout line"
  assert_exit_code "$rob_rc" "0" \
    "(57b1) a failed branch delete still exits 0 (the sweep must continue)"

  if git -C "$rob_repo" rev-parse --verify worktree-agent-perm-fail-test >/dev/null 2>&1; then
    printf '  %sPASS%s  (57b2) branch survived (the failure being recorded is real)\n' "$GREEN" "$RESET"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  (57b2) branch was deleted — the failure could not be simulated\n' "$RED" "$RESET"
    fail=$((fail+1))
  fi

  fail_line=$(cat "$rob_audit_log" 2>/dev/null)
  shape_ok=1
  case "$fail_line" in *'"action":"reaped-branch-failed"'*) ;; *) shape_ok=0 ;; esac
  case "$fail_line" in *'"branch":"worktree-agent-perm-fail-test"'*) ;; *) shape_ok=0 ;; esac
  case "$fail_line" in *'"reason":"branch-delete-failed"'*) ;; *) shape_ok=0 ;; esac
  case "$fail_line" in *'"session":"rob-test-session"'*) ;; *) shape_ok=0 ;; esac
  # A `"action":"reaped-orphan-branch"` line here would be the pre-#874
  # silent-success lie the issue reported.
  case "$fail_line" in *'"action":"reaped-orphan-branch"'*) shape_ok=0 ;; esac
  if [ "$shape_ok" = "1" ]; then
    printf '  %sPASS%s  (57c) failed delete emits reaped-branch-failed + reason (never a silent reaped-orphan-branch)\n' "$GREEN" "$RESET"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  (57c) expected a reaped-branch-failed audit line with a reason; was: %s\n' "$RED" "$RESET" "$fail_line"
    fail=$((fail+1))
  fi
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
# This is the functional half of issue #335's zsh-nomatch-safety property:
# classify-all's own agent-* enumeration is `find`-based (never a bare
# `for wt_dir in .git/worktrees/agent-*` glob), so an empty match set is a
# clean no-op instead of a fatal `nomatch` abort under zsh. #335 originally
# guarded this inline in setup.md's step 3b loop; #1355 moved the loop
# itself into this script (do-work-split.test.sh's check (21) now asserts
# the textual half — the find-idiom + #335 citation — against this file
# instead of against setup.md's now-deleted inline copy).
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

# agent-nolock backdated past the default 60min floor so it lands on the
# pre-#1147 verdict (no-lock) this parity matrix was written against —
# no-lock-recent has its own dedicated tests below (94b-94e). Leaving
# agent-peer's lock fresh (un-backdated) keeps it classifying peer-alive,
# not peer-alive-stale.
backdate_minutes "$ca_repo/.claude/worktrees/agent-nolock" 90

result=$(run_classify_all --orchestrator-pid "$$" | sort)
expected=$(printf 'agent-dead dead 999999\nagent-nolock no-lock null\nagent-peer peer-alive %s\nagent-self self-ancestor %s' \
  "$ca_sibling_pid" "$$")
assert_equals "$result" "$expected" \
  "(92) classify-all: no-lock / dead / self-ancestor / peer-alive all resolved in one call"

kill "$ca_sibling_pid" 2>/dev/null
wait "$ca_sibling_pid" 2>/dev/null

# --- (92a) issue #1206 — classify_all has its OWN independent PID-parsing
# regex (a pure-bash `[[ =~ ]]` match, not `extract_lock_pid`, for the
# batching reasons documented in Pass 1's comment) — it carried the SAME
# anchor-on-close-paren bug as classify-lock's `extract_lock_pid`, but
# manifested differently: `\(pid[[:space:]]+([0-9]+)\)` REQUIRED the digits
# to be immediately followed by `)`, so a REAL `(pid <N> start <ctime>)`
# lock never matched at all (pid stayed empty) rather than misparsing to
# the ctime year. This exercises both: a real-shape lock naming a live PID
# resolves to peer-alive (not the pre-#1206 `dead`), and a lock with no
# parseable pid at all resolves to `unknown` (not `dead`).
#
# The lock's `start` field is the sibling's OWN actual spawn epoch (captured
# right after spawn), not a hardcoded date — issue #1207 added a start-time
# cross-check between this field and `ps -o lstart` for the same pid (see
# the dedicated (94f)-(94h) tests below), and a hardcoded/unrelated date
# would now (correctly) trip that check, decoupling THIS fixture's
# PID-EXTRACTION concern from that newer concern.
reset_ca_layout
ca_add_worktree realpeer
ca_add_worktree malformed
(sleep 300) &
ca_sibling_pid=$!
sleep 0.05
ca_spawn_epoch=$(date +%s)
printf 'claude session orchestrator-do-work-20260810T221957Z-35757 (pid %s start %s)\n' \
  "$ca_sibling_pid" "$(epoch_to_ctime "$ca_spawn_epoch" local)" > "$ca_repo/.git/worktrees/agent-realpeer/locked"
printf 'some other content with no pid syntax\n' \
  > "$ca_repo/.git/worktrees/agent-malformed/locked"
result=$(run_classify_all | sort)
expected=$(printf 'agent-malformed unknown null\nagent-realpeer peer-alive %s' "$ca_sibling_pid")
assert_equals "$result" "$expected" \
  "(92a) issue #1206: classify-all with REAL '(pid N start ctime)' lock shape -> peer-alive (not dead); unparseable lock -> unknown (not dead)"
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

# --- (94f)-(94h) issue #1207 — classify-all's own start-time cross-check ---
# Same corroboration gate as classify-lock's (8e)-(8i), exercised through
# the batch `classify-all` path (its own independent Pass 1 extraction +
# Pass 5 branch — see worktree-reap.sh's comments on why this needed its
# own wiring rather than delegating to classify-lock's).

# (94f) THE hazard case: lock start recorded in UTC, ps -o lstart reads
# local (same instant, host-UTC-offset apart) -> 'peer-alive', never
# 'peer-alive-stale'. Fresh lock (no backdating), so if this gate wrongly
# fired we'd know it's THIS gate and not the #755 mtime gate.
reset_ca_layout
ca_add_worktree utcmatch
(sleep 300) &
ca_sibling_pid=$!
sleep 0.05
ca_spawn_epoch=$(date +%s)
printf 'claude session orchestrator-do-work-test (pid %s start %s)\n' \
  "$ca_sibling_pid" "$(epoch_to_ctime "$ca_spawn_epoch" utc)" \
  > "$ca_repo/.git/worktrees/agent-utcmatch/locked"
result=$(run_classify_all)
assert_equals "$result" "agent-utcmatch peer-alive $ca_sibling_pid" \
  "(94f) issue #1207 REPRO via classify-all: lock start in UTC, ps -o lstart local (host-UTC-offset apart) -> 'peer-alive' (NOT 'peer-alive-stale')"
kill "$ca_sibling_pid" 2>/dev/null
wait "$ca_sibling_pid" 2>/dev/null

# (94g) genuine mismatch (suspected PID reuse): lock start 20h off the live
# pid's actual start -> 'peer-alive-stale', overriding a FRESH lock mtime
# (the #755 gate alone would say 'peer-alive' here — this gate must win).
reset_ca_layout
ca_add_worktree reused
(sleep 300) &
ca_sibling_pid=$!
sleep 0.05
ca_spawn_epoch=$(date +%s)
ca_mismatched_epoch=$(( ca_spawn_epoch - 20 * 3600 ))
printf 'claude session orchestrator-do-work-test (pid %s start %s)\n' \
  "$ca_sibling_pid" "$(epoch_to_ctime "$ca_mismatched_epoch" utc)" \
  > "$ca_repo/.git/worktrees/agent-reused/locked"
result=$(run_classify_all)
assert_equals "$result" "agent-reused peer-alive-stale $ca_sibling_pid" \
  "(94g) issue #1207 via classify-all: lock start 20h off actual pid start -> 'peer-alive-stale' (PID reuse suspected, overrides fresh mtime)"
kill "$ca_sibling_pid" 2>/dev/null
wait "$ca_sibling_pid" 2>/dev/null

# (94h) fail-safe regression guard: a lock with NO start field (the common
# `claude agent <agent-id> (pid <N>)` shape) must skip this gate entirely —
# classify-all's own no-start-field mixed-batch coverage (test 92) already
# proves this stays 'peer-alive'; this test additionally proves it survives
# alongside a SIBLING worktree in the same batch that DOES mismatch, i.e.
# one lock's mismatch doesn't leak into another lock's classification.
reset_ca_layout
ca_add_worktree nostart
ca_add_worktree reused2
(sleep 300) &
ca_sibling_pid=$!
sleep 0.05
(sleep 300) &
ca_sibling2_pid=$!
sleep 0.05
printf 'claude agent agent-nostart (pid %s)\n' "$ca_sibling_pid" \
  > "$ca_repo/.git/worktrees/agent-nostart/locked"
ca_spawn_epoch=$(date +%s)
ca_mismatched_epoch=$(( ca_spawn_epoch - 20 * 3600 ))
printf 'claude session orchestrator-do-work-test (pid %s start %s)\n' \
  "$ca_sibling2_pid" "$(epoch_to_ctime "$ca_mismatched_epoch" utc)" \
  > "$ca_repo/.git/worktrees/agent-reused2/locked"
result=$(run_classify_all | sort)
expected=$(printf 'agent-nostart peer-alive %s\nagent-reused2 peer-alive-stale %s' \
  "$ca_sibling_pid" "$ca_sibling2_pid")
assert_equals "$result" "$expected" \
  "(94h) issue #1207 via classify-all: a no-start-field lock stays 'peer-alive' alongside a sibling lock that genuinely mismatches (per-lock isolation)"
kill "$ca_sibling_pid" "$ca_sibling2_pid" 2>/dev/null
wait "$ca_sibling_pid" 2>/dev/null
wait "$ca_sibling2_pid" 2>/dev/null

# --- (94b)-(94e) issue #1147 — no-lock-recent defense-in-depth ---
#
# A harness-provisioned isolation:"worktree" dispatch (the default
# Agent-tool shape since #830) never writes a shipyard lock file, so a
# currently-running worker's worktree classifies identically to a
# genuinely-abandoned one under plain PID-liveness (`no-lock`). classify-all
# now additionally consults the worktree DIRECTORY's own mtime for every
# no-lock candidate: fresh (within --peer-stale-min) -> no-lock-recent
# (presumed live, defer); older than the floor -> no-lock (unchanged,
# reap-eligible).
reset_ca_layout
ca_add_worktree freshnolock
result=$(run_classify_all)
assert_equals "$result" "agent-freshnolock no-lock-recent null" \
  "(94b) freshly-created no-lock worktree -> 'no-lock-recent' (issue #1147 repro)"

# --- (94c) same worktree, --peer-stale-min 0 -> back to 'no-lock' ---
# A staleness floor of 0 makes any no-lock worktree "stale" regardless of
# true age — mirrors test (85)'s override-activates pattern for peer-alive.
result=$(run_classify_all --peer-stale-min 0)
assert_equals "$result" "agent-freshnolock no-lock null" \
  "(94c) fresh no-lock worktree + --peer-stale-min 0 -> 'no-lock' (override activates)"

# --- (94d) no-lock worktree backdated past the floor -> 'no-lock' (unchanged) ---
reset_ca_layout
ca_add_worktree oldnolock
backdate_minutes "$ca_repo/.claude/worktrees/agent-oldnolock" 90
result=$(run_classify_all)
assert_equals "$result" "agent-oldnolock no-lock null" \
  "(94d) 90min-old no-lock worktree + default 60min floor -> 'no-lock' (reap-eligible, regression check)"

# --- (94e) same backdated worktree, --peer-stale-min 120 -> still 'no-lock-recent' ---
result=$(run_classify_all --peer-stale-min 120)
assert_equals "$result" "agent-oldnolock no-lock-recent null" \
  "(94e) 90min-old no-lock worktree + --peer-stale-min 120 -> 'no-lock-recent' (not stale vs a higher floor)"

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

# Issue #1147 — classify-all now defers a freshly-created no-lock worktree
# as no-lock-recent (same --peer-stale-min floor as peer-alive-stale, so a
# blanket override here would also flip the fresh peer-alive fixtures below
# into peer-alive-stale). Backdate a plain reap-eligible no-lock fixture
# past the default 60min floor so it lands on the pre-#1147 verdict
# (`no-lock`) these existing tests were written against — realistic besides:
# a genuinely stale worktree from a prior session really would be old.
rs_backdate_nolock() {
  local id="$1"
  backdate_minutes "$rs_repo/.claude/worktrees/agent-$id" 90
}

# --- (97) dry-run -> lines + summary, nothing removed, no audit log ---
reset_rs_layout
rs_add_worktree aaa
rs_add_worktree bbb
rs_backdate_nolock aaa
rs_backdate_nolock bbb
result=$(run_rs --dry-run)
last_line=$(printf '%s\n' "$result" | tail -1)
assert_equals "$last_line" "summary: reaped=2 deferred=0 unreaped=0 remaining=0 tombstones_swept=0 tombstones_failed=0 tombstones_remaining=0" \
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
rs_backdate_nolock aaa
rs_backdate_nolock bbb
result=$(run_rs)
last_line=$(printf '%s\n' "$result" | tail -1)
assert_equals "$last_line" "summary: reaped=2 deferred=0 unreaped=0 remaining=0 tombstones_swept=0 tombstones_failed=0 tombstones_remaining=0" \
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
# Both backdated past the default 60min no-lock-recent floor (issue #1147)
# so both classify plain `no-lock` (reap-eligible) — this test is about the
# CAP mechanism, not the freshness gate; a genuinely-fresh "newer" would
# classify no-lock-recent and get deferred instead of landing in
# `remaining`, which is a different (also correct, separately tested above)
# code path.
reset_rs_layout
rs_add_worktree older
rs_add_worktree newer
backdate_minutes "$rs_repo/.claude/worktrees/agent-older" 120
backdate_minutes "$rs_repo/.claude/worktrees/agent-newer" 70
result=$(run_rs --max-per-session 1)
last_line=$(printf '%s\n' "$result" | tail -1)
assert_equals "$last_line" "summary: reaped=1 deferred=0 unreaped=0 remaining=1 tombstones_swept=0 tombstones_failed=0 tombstones_remaining=0" \
  "(99) cap=1 -> exactly one reaped, one left in remaining"
[ -d "$rs_repo/.claude/worktrees/agent-older" ] && older_kept=yes || older_kept=no
assert_equals "$older_kept" "no" \
  "(99a) the OLDER worktree is the one reaped (oldest-first)"
[ -d "$rs_repo/.claude/worktrees/agent-newer" ] && newer_kept=yes || newer_kept=no
assert_equals "$newer_kept" "yes" \
  "(99b) the newer worktree survives — left for a future session"

# --- (100) --exclude-agent-id (in-flight guard, issue #832) ---
# agent-inflight is deliberately left FRESH (no backdate) — it's excluded
# BEFORE classification is ever consulted (issue #832), so its own
# no-lock/no-lock-recent verdict is irrelevant either way. agent-aaa is
# backdated so it lands on the pre-#1147 no-lock (reap-eligible) verdict —
# this test is about exclusion, not freshness.
reset_rs_layout
rs_add_worktree aaa
rs_add_worktree inflight
rs_backdate_nolock aaa
result=$(run_rs --exclude-agent-id inflight)
last_line=$(printf '%s\n' "$result" | tail -1)
assert_equals "$last_line" "summary: reaped=1 deferred=0 unreaped=0 remaining=0 tombstones_swept=0 tombstones_failed=0 tombstones_remaining=0" \
  "(100) excluded worktree is invisible to the summary entirely"
[ -d "$rs_repo/.claude/worktrees/agent-inflight" ] && inflight_kept=yes || inflight_kept=no
assert_equals "$inflight_kept" "yes" \
  "(100a) excluded (in-flight) worktree is never touched"
excluded_in_output=$(printf '%s\n' "$result" | grep -c "agent-inflight" || true)
assert_equals "$excluded_in_output" "0" \
  "(100b) excluded worktree produces no reaped:/deferred: line at all"

# --- (101) peer-alive is deferred and does NOT count against the cap ---
# agent-peer's lock stays fresh (un-backdated) so it classifies peer-alive,
# not peer-alive-stale. agent-aaa is backdated so it lands on the plain
# no-lock (reap-eligible) verdict this test's cap assertion depends on.
reset_rs_layout
rs_add_worktree peer
rs_add_worktree aaa
rs_backdate_nolock aaa
(sleep 300) &
rs_sibling_pid=$!
sleep 0.05
printf 'claude agent agent-peer (pid %s)\n' "$rs_sibling_pid" \
  > "$rs_repo/.git/worktrees/agent-peer/locked"
result=$(run_rs --max-per-session 1)
last_line=$(printf '%s\n' "$result" | tail -1)
assert_equals "$last_line" "summary: reaped=1 deferred=1 unreaped=0 remaining=0 tombstones_swept=0 tombstones_failed=0 tombstones_remaining=0" \
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
# Backdated past the no-lock-recent floor so both classify plain no-lock
# (reap-eligible-but-capped -> remaining), not no-lock-recent (deferred) —
# this test is about the cap, not freshness.
reset_rs_layout
rs_add_worktree aaa
rs_add_worktree bbb
rs_backdate_nolock aaa
rs_backdate_nolock bbb
result=$(run_rs --max-per-session 0)
last_line=$(printf '%s\n' "$result" | tail -1)
assert_equals "$last_line" "summary: reaped=0 deferred=0 unreaped=0 remaining=2 tombstones_swept=0 tombstones_failed=0 tombstones_remaining=0" \
  "(104) --max-per-session 0 -> both worktrees land in remaining, untouched"
[ -d "$rs_repo/.claude/worktrees/agent-aaa" ] && zero_cap_kept=yes || zero_cap_kept=no
assert_equals "$zero_cap_kept" "yes" \
  "(104a) --max-per-session 0 -> nothing actually removed"

# ============================================================================
# Issue #1147 — no-lock-recent defer path + mandatory in-flight cross-check
#
# Matrix:
#   105) freshly-created no-lock worktree under reap-stale (default floor,
#        no --exclude-agent-id) -> DEFERRED, not reaped (the core repro fix)
#   106) same worktree, --peer-stale-min 0 -> reaped (override still works
#        end-to-end through reap-stale, not just classify-all)
#   107) mandatory in-flight cross-check: an agent-id present in the
#        session-state file's .in_flight is excluded automatically, with
#        NO --exclude-agent-id passed at all
#   108) the auto-derived in-flight exclusion is ADDITIVE with an explicit
#        --exclude-agent-id for a different id — both apply
#   109) missing session-state file -> best-effort no-op, sweep still
#        succeeds (falls through to the no-lock-recent mtime backstop)
# ============================================================================

# --- (105) fresh no-lock worktree -> deferred, not reaped (default floor) ---
reset_rs_layout
rs_add_worktree fresh
result=$(run_rs)
last_line=$(printf '%s\n' "$result" | tail -1)
assert_equals "$last_line" "summary: reaped=0 deferred=1 unreaped=0 remaining=0 tombstones_swept=0 tombstones_failed=0 tombstones_remaining=0" \
  "(105) freshly-created no-lock worktree -> deferred (issue #1147 core repro)"
[ -d "$rs_repo/.claude/worktrees/agent-fresh" ] && fresh_kept=yes || fresh_kept=no
assert_equals "$fresh_kept" "yes" \
  "(105a) the fresh worktree is NOT removed"

# --- (106) same fixture, --peer-stale-min 0 -> reaped ---
reset_rs_layout
rs_add_worktree fresh
result=$(run_rs --peer-stale-min 0)
last_line=$(printf '%s\n' "$result" | tail -1)
assert_equals "$last_line" "summary: reaped=1 deferred=0 unreaped=0 remaining=0 tombstones_swept=0 tombstones_failed=0 tombstones_remaining=0" \
  "(106) fresh no-lock worktree + --peer-stale-min 0 -> reaped (override reaches reap-stale end-to-end)"

# --- (107) mandatory in-flight cross-check, NO --exclude-agent-id passed ---
reset_rs_layout
rs_add_worktree aaa
rs_add_worktree livepeer
rs_backdate_nolock aaa
mkdir -p "$rs_home/sessions"
cat > "$rs_home/sessions/rs-test-session.json" <<'JSON'
{"in_flight": {"slot-1": {"agent_id": "livepeer"}}}
JSON
result=$(run_rs)
last_line=$(printf '%s\n' "$result" | tail -1)
assert_equals "$last_line" "summary: reaped=1 deferred=0 unreaped=0 remaining=0 tombstones_swept=0 tombstones_failed=0 tombstones_remaining=0" \
  "(107) in_flight agent-id excluded automatically with no --exclude-agent-id passed"
[ -d "$rs_repo/.claude/worktrees/agent-livepeer" ] && livepeer_kept=yes || livepeer_kept=no
assert_equals "$livepeer_kept" "yes" \
  "(107a) the in_flight worktree is never touched"
livepeer_in_output=$(printf '%s\n' "$result" | grep -c "agent-livepeer" || true)
assert_equals "$livepeer_in_output" "0" \
  "(107b) the in_flight worktree produces no reaped:/deferred: line at all"

# --- (108) auto-derived in_flight exclusion is additive with --exclude-agent-id ---
reset_rs_layout
rs_add_worktree aaa
rs_add_worktree livepeer
rs_add_worktree manualexclude
rs_backdate_nolock aaa
mkdir -p "$rs_home/sessions"
cat > "$rs_home/sessions/rs-test-session.json" <<'JSON'
{"in_flight": {"slot-1": {"agent_id": "livepeer"}}}
JSON
result=$(run_rs --exclude-agent-id manualexclude)
last_line=$(printf '%s\n' "$result" | tail -1)
assert_equals "$last_line" "summary: reaped=1 deferred=0 unreaped=0 remaining=0 tombstones_swept=0 tombstones_failed=0 tombstones_remaining=0" \
  "(108) both the explicit --exclude-agent-id and the auto-derived in_flight id are excluded"
[ -d "$rs_repo/.claude/worktrees/agent-livepeer" ] && both_livepeer_kept=yes || both_livepeer_kept=no
[ -d "$rs_repo/.claude/worktrees/agent-manualexclude" ] && both_manual_kept=yes || both_manual_kept=no
assert_equals "$both_livepeer_kept" "yes" \
  "(108a) the in_flight worktree survives"
assert_equals "$both_manual_kept" "yes" \
  "(108b) the explicitly-excluded worktree survives"

# --- (109) missing session-state file -> best-effort no-op, sweep still works ---
reset_rs_layout
rs_add_worktree aaa
rs_backdate_nolock aaa
# rs_home has no sessions/ dir at all for this session-id — the auto-derive
# step must not error the whole sweep.
result=$(run_rs)
last_line=$(printf '%s\n' "$result" | tail -1)
assert_equals "$last_line" "summary: reaped=1 deferred=0 unreaped=0 remaining=0 tombstones_swept=0 tombstones_failed=0 tombstones_remaining=0" \
  "(109) missing session-state file -> auto-derive is a silent no-op, sweep still succeeds"

# ============================================================================
# Issue #1482 — the stray-tombstone pass is BOUNDED and REPORTED.
#
# Two independent defects, both live before this issue:
#
#   * Unbounded. The tombstone pass runs BEFORE classification and had no
#     cap, inside a function whose whole contract is "bounded and
#     checkpointed." A large tombstone backlog could burn the caller's
#     entire time budget without a single worktree ever being classified;
#     because a killed `rm -rf` leaves a partially-deleted tombstone, the
#     next pass restarted the same unbounded traversal — each timed-out
#     pass leaving at least as much work as it found.
#   * Unreported. A failed removal printed `tombstone-sweep-failed:` and
#     then vanished — sweep_stray_tombstones returned 0 unconditionally,
#     reap_stale ignored the return, and the `summary:` line carried no
#     tombstone field. disk-space-guard.md reads that summary via `tail -1`
#     and echoes it, so the disk guard reported total success over bytes it
#     had not reclaimed.
#
# Note what these tests deliberately establish is NOT true: a failing
# tombstone does not wedge the pass (110c/111b). #1482's filed diagnosis
# guessed that it did; the loop `continue`s past each failure and every
# subsequent directory is still attempted. The real mechanism is the two
# defects above.
#
# Matrix:
#   110) cap bounds the pass; the remainder is checkpointed, not lost, and
#        a later pass makes forward progress from it
#   111) a removal failure lands in the summary line AND yields exit 3,
#        while every other tombstone in the same pass is still swept
#   112) a clean pass exits 0; --dry-run reports without touching anything
# ============================================================================

echo
echo "worktree-reap.sh tombstone-pass bounding + reporting (issue #1482)"
echo

# Tombstones are plain directories matching *.reap-dead-* — already renamed
# aside by fast_worktree_remove, branch freed, registration pruned. They are
# never registered worktrees, which is why the pass needs no liveness check.
rs_add_tombstone() {
  mkdir -p "$rs_repo/.claude/worktrees/agent-$1.reap-dead-9999-$2"
}

# run_rs discards the exit status (it substitutes stdout); this variant
# keeps it, which is the whole point of test 111.
run_rs_status() {
  SHIPYARD_HOME="$rs_home" bash "$helper" reap-stale \
    --repo-root "$rs_repo" \
    --session-id "rs-test-session" \
    "$@" >/dev/null 2>&1
  printf '%s\n' "$?"
}

# --- (110) cap bounds the tombstone pass; the rest is a checkpoint ---
reset_rs_layout
rs_add_tombstone t1 1
rs_add_tombstone t2 2
rs_add_tombstone t3 3
result=$(run_rs --max-per-session 2)
last_line=$(printf '%s\n' "$result" | tail -1)
assert_equals "$last_line" "summary: reaped=0 deferred=0 unreaped=0 remaining=0 tombstones_swept=2 tombstones_failed=0 tombstones_remaining=1" \
  "(110) --max-per-session bounds the tombstone pass and reports the remainder"
tomb_left=$(find "$rs_repo/.claude/worktrees" -maxdepth 1 -type d -name '*.reap-dead-*' 2>/dev/null | wc -l | tr -d ' ')
assert_equals "$tomb_left" "1" \
  "(110a) the capped-out tombstone is left on disk, untouched"
# Forward progress: the SAME backlog drains on a later pass, with no
# separate state file — identical checkpoint semantics to the reap loop's
# own `remaining` (test 102).
result=$(run_rs --max-per-session 10)
last_line=$(printf '%s\n' "$result" | tail -1)
assert_equals "$last_line" "summary: reaped=0 deferred=0 unreaped=0 remaining=0 tombstones_swept=1 tombstones_failed=0 tombstones_remaining=0" \
  "(110b) a later pass continues the tombstone backlog from where the cap left it"
tomb_left=$(find "$rs_repo/.claude/worktrees" -maxdepth 1 -type d -name '*.reap-dead-*' 2>/dev/null | wc -l | tr -d ' ')
assert_equals "$tomb_left" "0" \
  "(110c) the backlog drains completely — a tombstone never wedges a later pass"

# --- (111) a failed removal is reported in the summary AND in the exit code ---
# Fixture: a tombstone whose parent is read-only, so the recursive delete
# cannot unlink the child and the directory survives. Skipped when running
# as root, for which no directory mode is unwritable.
reset_rs_layout
if [ "$(id -u)" != "0" ]; then
  rs_add_tombstone stuck 4
  mkdir -p "$rs_repo/.claude/worktrees/agent-stuck.reap-dead-9999-4/child"
  chmod 500 "$rs_repo/.claude/worktrees/agent-stuck.reap-dead-9999-4"
  rs_add_tombstone ok 5
  result=$(run_rs)
  last_line=$(printf '%s\n' "$result" | tail -1)
  assert_equals "$last_line" "summary: reaped=0 deferred=0 unreaped=0 remaining=0 tombstones_swept=1 tombstones_failed=1 tombstones_remaining=0" \
    "(111) a failed tombstone removal is counted in the summary line, not silently dropped"
  # The failure must not abort the pass — the sibling tombstone in the same
  # run is still swept. This is the assertion that falsifies #1482's filed
  # "stale tombstone wedges the sweep" diagnosis.
  [ -d "$rs_repo/.claude/worktrees/agent-ok.reap-dead-9999-5" ] && sibling_kept=yes || sibling_kept=no
  assert_equals "$sibling_kept" "no" \
    "(111b) a failed tombstone does NOT abort the pass — siblings are still swept"
  status=$(run_rs_status --max-per-session 10)
  assert_equals "$status" "3" \
    "(111c) a partial pass exits 3, not 0 — the caller can see the degrade"
  chmod 700 "$rs_repo/.claude/worktrees/agent-stuck.reap-dead-9999-4"
else
  echo "  (111) skipped — running as root, no directory mode blocks unlink"
fi

# --- (112) clean pass exits 0; --dry-run reports without removing ---
reset_rs_layout
rs_add_tombstone clean 6
status=$(run_rs_status --max-per-session 10)
assert_equals "$status" "0" \
  "(112) a pass with nothing left unreclaimed exits 0"
reset_rs_layout
rs_add_tombstone dry 7
result=$(run_rs --dry-run)
last_line=$(printf '%s\n' "$result" | tail -1)
assert_equals "$last_line" "summary: reaped=0 deferred=0 unreaped=0 remaining=0 tombstones_swept=1 tombstones_failed=0 tombstones_remaining=0" \
  "(112a) --dry-run reports what it would sweep"
[ -d "$rs_repo/.claude/worktrees/agent-dry.reap-dead-9999-7" ] && dry_tomb_kept=yes || dry_tomb_kept=no
assert_equals "$dry_tomb_kept" "yes" \
  "(112b) --dry-run removes no tombstone"

# ============================================================================
# Issue #1261 — `disk-check` subcommand. Mid-session disk-space
# backpressure probe steady-state.md's step C consults before every
# dispatch decision, to trigger a reclaiming reap-stale sweep before the
# disk actually fills — a backstop for whatever gap lets the ordinary
# per-completion reap points (A.0.5/A.1/step B/dispatch-rules.md 2d) fall
# behind. Deliberately fails OPEN on an unreadable df result (never a
# reason to withhold dispatch), unlike the destructive-action gates
# elsewhere in this file.
# ============================================================================

run_disk_check() {
  bash "$helper" disk-check "$@"
}

# --- (113) --path is required ---
result=$(run_disk_check --floor-mb 100 2>&1)
rc=$?
assert_exit_code "$rc" "64" \
  "(113) disk-check without --path exits 64"

# --- (114) --floor-mb must be a non-negative integer ---
result=$(run_disk_check --path "$tmpdir" --floor-mb notanumber 2>&1)
rc=$?
assert_exit_code "$rc" "64" \
  "(114) disk-check --floor-mb rejects a non-numeric value"

# --- (115) unknown flag rejected ---
result=$(run_disk_check --path "$tmpdir" --bogus-flag 2>&1)
rc=$?
assert_exit_code "$rc" "64" \
  "(115) disk-check rejects an unknown flag"

# --- (116) valid path, no --floor-mb (default 0) -> low is always false ---
result=$(run_disk_check --path "$tmpdir")
rc=$?
assert_exit_code "$rc" "0" \
  "(116) disk-check on a real path with no floor exits 0"
case "$result" in
  *"low=false"*) low_default_ok=1 ;;
  *) low_default_ok=0 ;;
esac
assert_equals "$low_default_ok" "1" \
  "(116a) disk-check defaults --floor-mb to 0, which never trips low=true"
case "$result" in
  free_mb=*' floor_mb=0 low=false') shape_ok=1 ;;
  *) shape_ok=0 ;;
esac
assert_equals "$shape_ok" "1" \
  "(116b) disk-check output shape is 'free_mb=<N> floor_mb=<F> low=<bool>'"

# --- (117) an absurdly high floor trips low=true on a real, finite disk ---
result=$(run_disk_check --path "$tmpdir" --floor-mb 999999999999)
assert_exit_code "$?" "0" \
  "(117) disk-check with a huge floor still exits 0 (advisory, never a usage error)"
case "$result" in
  *"low=true"*) low_true_ok=1 ;;
  *) low_true_ok=0 ;;
esac
assert_equals "$low_true_ok" "1" \
  "(117a) disk-check reports low=true once free space is below the floor"

# --- (118) --floor-mb 0 explicitly -> never trips low=true regardless ---
result=$(run_disk_check --path "$tmpdir" --floor-mb 0)
case "$result" in
  *"low=false"*) explicit_zero_ok=1 ;;
  *) explicit_zero_ok=0 ;;
esac
assert_equals "$explicit_zero_ok" "1" \
  "(118) disk-check --floor-mb 0 explicitly disables the low=true trip"

# --- (119) an unreadable path fails OPEN: free_mb=unknown, low=false, exit 0 ---
result=$(run_disk_check --path "/nonexistent-path-issue-1261-$$" --floor-mb 100)
rc=$?
assert_exit_code "$rc" "0" \
  "(119) disk-check on an unreadable path still exits 0 (fails open)"
assert_equals "$result" "free_mb=unknown floor_mb=100 low=false" \
  "(119a) disk-check on an unreadable path reports free_mb=unknown, low=false — never a reason to withhold dispatch"

# --- (120) --path=<val> / --floor-mb=<val> equals-form accepted ---
result=$(run_disk_check --path="$tmpdir" --floor-mb=0)
assert_exit_code "$?" "0" \
  "(120) disk-check accepts the --flag=value form"
case "$result" in
  *"low=false"*) equals_form_ok=1 ;;
  *) equals_form_ok=0 ;;
esac
assert_equals "$equals_form_ok" "1" \
  "(120a) --flag=value form produces the same shape as the two-arg form"

# ============================================================================
# Issue #1365 (follow-up to #1355) — `triage-orphan-branches` subcommand:
# single-call replacement for setup-3c's own discover-then-triage loop (the
# issue #303 stale self-assign sweep included), so it's reachable at any
# point in setup, not just pre-relocation.
#
# Coverage goals:
#   - No do-work/* worktrees at all -> summary: salvaged=0 abandoned=0
#     stale_assigns=0.
#   - No commits beyond base -> worktree removed, branch deleted, @me
#     assignment cleared -> abandoned=1.
#   - Commits ahead, unpushed, no PR yet, gated repo -> pushed, PR created,
#     auto-merge armed (gh pr merge --auto called) -> salvaged=1.
#   - Same, but ungated repo -> PR created, auto-merge NOT armed, the
#     literal `[setup-3c] PR #<N> left unarmed (ungated repo) ...` line
#     survives byte-for-byte (issue #1365's explicit ask).
#   - Same, but the merge-arm call fails on the missing-workflow-scope
#     signature -> the literal `[setup-3c] PR #<N> auto-merge arm blocked
#     ...` line survives byte-for-byte.
#   - Commits ahead, already pushed, PR already open, red rollup ->
#     `failed-pr: <N>` line, salvaged=1, no duplicate PR create.
#   - Commits ahead, already pushed, PR already open, clean rollup -> no
#     failed-pr line, salvaged=1.
#   - Row 5 (backlog.self_assign=true): a stale @me-assigned issue with no
#     worktree/PR/branch -> `stale-assign: <N>` line, gh issue edit called.
#   - Row 5 gated off (backlog.self_assign=false, the default) -> the `gh
#     issue list --assignee @me` query is never made at all.
#   - Bad usage (missing --repo-root / --repo / --default-branch) -> exit 64.
# ============================================================================

echo
echo "worktree-reap.sh triage-orphan-branches tests (issue #1365)"
echo

tob_repo="$tmpdir/tob-repo"
tob_origin="$tmpdir/tob-origin.git"
tob_gh="$tmpdir/tob-gh"
tob_gh_log="$tmpdir/tob-gh.log"
tob_state="$tmpdir/tob-state"

reset_tob_layout() {
  # NOTE: $tob_gh (the mock gh binary) is intentionally NOT removed here —
  # it's written once, below, after this function is defined. Its content
  # only depends on $TOB_STATE / $TOB_GH_LOG, both supplied fresh per call
  # by run_tob, so it doesn't need re-writing per test.
  rm -rf "$tob_repo" "$tob_origin" "$tob_gh_log" "$tob_state"
  mkdir -p "$tob_state"
  git init -q --bare "$tob_origin" >/dev/null 2>&1
  mkdir -p "$tob_repo"
  (
    cd "$tob_repo" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test"
    git remote add origin "$tob_origin"
    git commit -q --allow-empty -m "init"
    git push -q -u origin main
  ) >/dev/null 2>&1
  : > "$tob_gh_log"
}

# tob_add_worktree <issue-n> — worktree with NO commits beyond base
# (ahead == 0 case).
tob_add_worktree() {
  local n="$1"
  git -C "$tob_repo" worktree add -q \
    ".claude/worktrees/agent-$n" -b "do-work/issue-$n" >/dev/null 2>&1
}

# tob_add_worktree_ahead <issue-n> [--push] — worktree with one commit
# beyond base carrying REAL content, optionally pushed to origin.
#
# The commit must not be `--allow-empty` (issue #1517). A branch whose tree
# is byte-identical to the default branch's is now classified as
# already-landed and its PR is suppressed — correctly, since that is exactly
# the squash-merge leftover shape the guard exists to catch. An empty commit
# produces precisely that tree, so an `--allow-empty` fixture would no longer
# exercise the salvage path at all. Writing a distinct file per issue keeps
# `ahead > 0` AND makes the effective diff genuinely non-empty.
tob_add_worktree_ahead() {
  local n="$1"
  local push="${2:-}"
  local path="$tob_repo/.claude/worktrees/agent-$n"
  tob_add_worktree "$n"
  printf 'unlanded work for issue %s\n' "$n" > "$path/work-$n.txt"
  git -C "$path" add "work-$n.txt" >/dev/null 2>&1
  git -C "$path" commit -q -m "wip $n" >/dev/null 2>&1
  if [ "$push" = "--push" ]; then
    git -C "$path" push -q -u origin "do-work/issue-$n" >/dev/null 2>&1
  fi
}

# tob_add_worktree_landed <issue-n> — worktree whose commit is AHEAD by sha
# but whose CONTENT is already on the default branch: the squash-merge
# leftover shape from issue #1517. Built by committing content on the
# branch, then landing byte-identical content on main under a different sha,
# so `rev-list --count origin/main..HEAD` stays > 0 while
# `git diff origin/main HEAD` is empty.
tob_add_worktree_landed() {
  local n="$1"
  local path="$tob_repo/.claude/worktrees/agent-$n"
  tob_add_worktree "$n"
  printf 'landed content for issue %s\n' "$n" > "$path/landed-$n.txt"
  git -C "$path" add "landed-$n.txt" >/dev/null 2>&1
  git -C "$path" commit -q -m "branch-side commit $n" >/dev/null 2>&1
  # Same content, different sha, on main -> squash-merge equivalence.
  printf 'landed content for issue %s\n' "$n" > "$tob_repo/landed-$n.txt"
  git -C "$tob_repo" add "landed-$n.txt" >/dev/null 2>&1
  git -C "$tob_repo" commit -q -m "squash-landed $n" >/dev/null 2>&1
  git -C "$tob_repo" push -q origin main >/dev/null 2>&1
  git -C "$tob_repo" fetch -q origin >/dev/null 2>&1
}

# Mock `gh` — dispatches on `$1 $2`, reads/writes per-scenario fixtures out
# of $tob_state so each test controls exactly what a given call returns,
# mirroring draft-pr-recovery.test.sh's own make_gh precedent (issue #1069).
cat > "$tob_gh" <<'MOCKEOF'
#!/usr/bin/env bash
echo "GH-CALL: $*" >> "$TOB_GH_LOG"
case "$1 $2" in
  "issue edit")
    exit 0
    ;;
  "pr list")
    # --head <branch> is somewhere in "$@"; look up its assigned PR number.
    # --state merged marks issue #1565's check-2b probe, which reads a
    # SEPARATE fixture: seeding an open PR for a branch must never double as
    # evidence that the branch's PR already merged, and vice versa.
    branch=""
    state=""
    prev=""
    for a in "$@"; do
      [ "$prev" = "--head" ] && branch="$a"
      [ "$prev" = "--state" ] && state="$a"
      prev="$a"
    done
    if [ "$state" = "merged" ]; then
      cat "$TOB_STATE/merged-pr-for-${branch//\//_}" 2>/dev/null
    else
      cat "$TOB_STATE/pr-for-${branch//\//_}" 2>/dev/null
    fi
    ;;
  "pr create")
    branch=""
    prev=""
    for a in "$@"; do
      [ "$prev" = "--head" ] && branch="$a"
      prev="$a"
    done
    n=$(cat "$TOB_STATE/next-pr-number" 2>/dev/null || echo 900)
    printf '%s' "$n" > "$TOB_STATE/pr-for-${branch//\//_}"
    exit 0
    ;;
  "pr merge")
    n="$3"
    if [ -f "$TOB_STATE/merge-stderr-$n" ]; then
      cat "$TOB_STATE/merge-stderr-$n" >&2
      exit 1
    fi
    exit 0
    ;;
  "pr view")
    n="$3"
    cat "$TOB_STATE/rollup-$n" 2>/dev/null || printf '0'
    ;;
  "issue list")
    cat "$TOB_STATE/self-assign-list" 2>/dev/null
    ;;
  "issue view")
    # Issue #1517's check-2 probe. The real call passes a --jq expression
    # that collapses the response to `<STATE>|<closing-PR-number>`, so the
    # fixture stores that already-collapsed string. NO fixture -> empty
    # stdout, which is the unreadable-signal case the guard must treat as
    # "not stale".
    cat "$TOB_STATE/issue-probe-$3" 2>/dev/null
    ;;
  *) : ;;
esac
MOCKEOF
chmod +x "$tob_gh"

run_tob() {
  TOB_GH_LOG="$tob_gh_log" TOB_STATE="$tob_state" \
    GH="$tob_gh" WORKTREE_REAP_VERDICT_OVERRIDE="${TOB_VERDICT:-gated}" \
    bash "$helper" triage-orphan-branches \
    --repo-root "$tob_repo" --repo "o/r" --default-branch "main" "$@" 2>/dev/null
}

# --- (130) no do-work/* worktrees at all -> zeroed summary ---
reset_tob_layout
result=$(run_tob)
assert_equals "$result" "$(printf 'candidates: 0\nsummary: salvaged=0 abandoned=0 stale_assigns=0 already_landed=0')" \
  "(130) no do-work/* worktrees -> candidates header + zeroed summary line"

# --- (131) no commits beyond base -> removed + branch deleted + assignee cleared ---
reset_tob_layout
tob_add_worktree 501
result=$(run_tob)
assert_equals "$result" "$(printf 'candidates: 1\n[1/1] abandon do-work/issue-501 — no commits beyond main\nsummary: salvaged=0 abandoned=1 stale_assigns=0 already_landed=0')" \
  "(131) no-commits-beyond-base worktree -> abandoned=1, with a pre-write progress line (#1518)"
if [ -d "$tob_repo/.claude/worktrees/agent-501" ]; then
  printf '  %sFAIL%s  (131a) abandoned worktree directory still exists\n' "$RED" "$RESET"
  fail=$((fail+1))
else
  printf '  %sPASS%s  (131a) abandoned worktree directory removed\n' "$GREEN" "$RESET"
  pass=$((pass+1))
fi
case "$(cat "$tob_gh_log")" in
  *"GH-CALL: issue edit 501 --repo o/r --remove-assignee @me"*) assignee_cleared=1 ;;
  *) assignee_cleared=0 ;;
esac
assert_equals "$assignee_cleared" "1" \
  "(131b) abandoned worktree's issue @me assignment was cleared"

# --- (132) commits ahead, unpushed, no PR yet -> pushed + DRAFT PR created, NOT armed (#1518 default) ---
reset_tob_layout
tob_add_worktree_ahead 502
printf '600' > "$tob_state/next-pr-number"
result=$(TOB_VERDICT=gated run_tob)
assert_equals "$result" "$(printf 'candidates: 1\n[1/1] salvage do-work/issue-502 — push + open PR (draft, auto-merge NOT armed)\n[setup-3c] PR #600 opened as a DRAFT, auto-merge NOT armed (#1518) — a human marks it ready after auditing the salvaged branch\nsummary: salvaged=1 abandoned=0 stale_assigns=0 already_landed=0')" \
  "(132) unpushed commits-ahead worktree, no PR yet -> salvaged=1, draft-posture output shape (#1518)"
case "$(cat "$tob_gh_log")" in
  *"GH-CALL: pr create --repo o/r --head do-work/issue-502 --draft --fill --label shipyard"*) pr_created=1 ;;
  *) pr_created=0 ;;
esac
assert_equals "$pr_created" "1" \
  "(132a) #1518 default -> PR created via gh pr create --draft --fill --label shipyard"
case "$(cat "$tob_gh_log")" in
  *"pr merge"*) merge_called=1 ;;
  *) merge_called=0 ;;
esac
assert_equals "$merge_called" "0" \
  "(132b) #1518 default -> gh pr merge is never called; a draft PR cannot auto-merge"
pushed_ref=$(git -C "$tob_origin" show-ref --verify --quiet refs/heads/do-work/issue-502 && echo yes || echo no)
assert_equals "$pushed_ref" "yes" \
  "(132c) unpushed branch was pushed to origin under its canonical name"

# --- (132d) --arm-auto-merge opt-in restores the pre-#1518 posture: ready PR + armed ---
reset_tob_layout
tob_add_worktree_ahead 512
printf '610' > "$tob_state/next-pr-number"
result=$(TOB_VERDICT=gated run_tob --arm-auto-merge)
case "$(cat "$tob_gh_log")" in
  *"GH-CALL: pr create --repo o/r --head do-work/issue-512 --fill --label shipyard"*) pr_created=1 ;;
  *) pr_created=0 ;;
esac
assert_equals "$pr_created" "1" \
  "(132d) --arm-auto-merge -> PR created WITHOUT --draft"
case "$(cat "$tob_gh_log")" in
  *"GH-CALL: pr merge 610 --repo o/r --auto --squash --delete-branch"*) merge_armed=1 ;;
  *) merge_armed=0 ;;
esac
assert_equals "$merge_armed" "1" \
  "(132e) --arm-auto-merge on a gated repo -> auto-merge armed via gh pr merge --auto"

# --- (133) --arm-auto-merge on an ungated repo -> PR created, NOT armed, literal [setup-3c] line survives ---
reset_tob_layout
tob_add_worktree_ahead 503
printf '601' > "$tob_state/next-pr-number"
result=$(TOB_VERDICT=ungated run_tob --arm-auto-merge)
case "$result" in
  *"[setup-3c] PR #601 left unarmed (ungated repo) — deferred to drain's merge lander (#720)"*) ungated_line_ok=1 ;;
  *) ungated_line_ok=0 ;;
esac
assert_equals "$ungated_line_ok" "1" \
  "(133) --arm-auto-merge + ungated repo -> the literal setup-3c unarmed-PR line survives byte-for-byte"
case "$(cat "$tob_gh_log")" in
  *"pr merge"*) merge_called=1 ;;
  *) merge_called=0 ;;
esac
assert_equals "$merge_called" "0" \
  "(133a) --arm-auto-merge + ungated repo -> gh pr merge is never called"

# --- (134) merge-arm call hits the missing-workflow-scope signature -> literal blocked line survives ---
reset_tob_layout
tob_add_worktree_ahead 504
printf '602' > "$tob_state/next-pr-number"
# shellcheck disable=SC2016
# Backticks below are LITERAL — single-quoting is deliberate to keep them
# from expanding as command substitution. This fixture mirrors the real
# GraphQL error signature auto-merge.md documents verbatim (issue #812),
# which is what triage_orphan_branches's own `grep -qi "without .workflow.
# scope"` check matches against.
printf 'GraphQL: refusing to allow an OAuth App to update .github/workflows/ci.yml without `workflow` scope (enablePullRequestAutoMerge)' \
  > "$tob_state/merge-stderr-602"
result=$(TOB_VERDICT=gated run_tob --arm-auto-merge)
case "$result" in
  *"[setup-3c] PR #602 auto-merge arm blocked — gh token lacks workflow scope (#850); left OPEN unarmed"*) blocked_line_ok=1 ;;
  *) blocked_line_ok=0 ;;
esac
assert_equals "$blocked_line_ok" "1" \
  "(134) workflow-scope-blocked merge arm -> the literal setup-3c blocked line survives byte-for-byte"

# --- (135) commits ahead, already pushed, PR already open, red rollup -> failed-pr line ---
reset_tob_layout
tob_add_worktree_ahead 505 --push
printf '700' > "$tob_state/pr-for-do-work_issue-505"
printf '1' > "$tob_state/rollup-700"
result=$(run_tob)
case "$result" in
  *"failed-pr: 700"*) failed_pr_ok=1 ;;
  *) failed_pr_ok=0 ;;
esac
assert_equals "$failed_pr_ok" "1" \
  "(135) already-open PR with a red rollup -> 'failed-pr: 700' line"
assert_equals "$result" "$(printf 'candidates: 1\n[1/1] existing-pr do-work/issue-505 — PR #700 already open, reading its status rollup\nfailed-pr: 700\nsummary: salvaged=1 abandoned=0 stale_assigns=0 already_landed=0')" \
  "(135a) full output shape matches exactly"
case "$(cat "$tob_gh_log")" in
  *"pr create"*) dup_pr_created=1 ;;
  *) dup_pr_created=0 ;;
esac
assert_equals "$dup_pr_created" "0" \
  "(135b) an already-open PR is never re-created"

# --- (136) commits ahead, already pushed, PR already open, clean rollup -> no failed-pr line ---
reset_tob_layout
tob_add_worktree_ahead 506 --push
printf '701' > "$tob_state/pr-for-do-work_issue-506"
printf '0' > "$tob_state/rollup-701"
result=$(run_tob)
assert_equals "$result" "$(printf 'candidates: 1\n[1/1] existing-pr do-work/issue-506 — PR #701 already open, reading its status rollup\nsummary: salvaged=1 abandoned=0 stale_assigns=0 already_landed=0')" \
  "(136) already-open PR with a clean rollup -> no failed-pr line, salvaged=1"

# --- (137) row 5: backlog.self_assign=true, stale @me issue with no worktree/PR/branch -> stale-assign line ---
reset_tob_layout
printf '{"version":1,"backlog":{"self_assign":true}}' > "$tob_repo/shipyard.config.json"
printf '808\n' > "$tob_state/self-assign-list"
result=$(run_tob)
case "$result" in
  *"stale-assign: 808"*) stale_assign_ok=1 ;;
  *) stale_assign_ok=0 ;;
esac
assert_equals "$stale_assign_ok" "1" \
  "(137) backlog.self_assign=true, orphaned @me issue -> 'stale-assign: 808' line"
assert_equals "$result" "$(printf 'candidates: 0\n[row5] clear-stale-assign #808\nstale-assign: 808\nsummary: salvaged=0 abandoned=0 stale_assigns=1 already_landed=0')" \
  "(137a) full output shape matches exactly"
case "$(cat "$tob_gh_log")" in
  *"GH-CALL: issue edit 808 --repo o/r --remove-assignee @me"*) row5_cleared=1 ;;
  *) row5_cleared=0 ;;
esac
assert_equals "$row5_cleared" "1" \
  "(137b) row 5 cleared the stale @me assignment"

# --- (138) row 5 gated off by default -> gh issue list is never called ---
reset_tob_layout
printf '809\n' > "$tob_state/self-assign-list"
result=$(run_tob)
assert_equals "$result" "$(printf 'candidates: 0\nsummary: salvaged=0 abandoned=0 stale_assigns=0 already_landed=0')" \
  "(138) backlog.self_assign unset (default false) -> stale_assigns=0"
case "$(cat "$tob_gh_log")" in
  *"issue list"*) row5_queried=1 ;;
  *) row5_queried=0 ;;
esac
assert_equals "$row5_queried" "0" \
  "(138a) backlog.self_assign=false (default) -> the gh issue list query is never made"

# --- (139) bad usage: missing --repo-root / --repo / --default-branch -> exit 64 ---
bash "$helper" triage-orphan-branches --repo "o/r" --default-branch "main" >/dev/null 2>&1
assert_exit_code "$?" "64" \
  "(139) triage-orphan-branches missing --repo-root -> exit 64"
bash "$helper" triage-orphan-branches --repo-root "$tob_repo" --default-branch "main" >/dev/null 2>&1
assert_exit_code "$?" "64" \
  "(139a) triage-orphan-branches missing --repo -> exit 64"
bash "$helper" triage-orphan-branches --repo-root "$tob_repo" --repo "o/r" >/dev/null 2>&1
assert_exit_code "$?" "64" \
  "(139b) triage-orphan-branches missing --default-branch -> exit 64"

# ============================================================================
# Issue #1518 — blast-radius bounds: the --max-prs cap, --dry-run, and the
# pre-write progress output. Three sessions in three days had this sweep open
# 7 / 13 / 14 auto-merge-armed PRs in one uninterrupted unattended pass, one
# of which auto-merged into `main` before setup had finished. The tests below
# pin each of the four properties that bound it.
# ============================================================================

echo
echo "worktree-reap.sh triage-orphan-branches blast-radius bounds (issue #1518)"
echo

# --- (140) --max-prs caps PR creation and reports the un-actioned remainder ---
reset_tob_layout
tob_add_worktree_ahead 520
tob_add_worktree_ahead 521
tob_add_worktree_ahead 522
printf '800' > "$tob_state/next-pr-number"
result=$(run_tob --max-prs 1)
created=$(grep -c "GH-CALL: pr create" "$tob_gh_log" || true)
assert_equals "$created" "1" \
  "(140) --max-prs 1 with 3 salvage candidates -> exactly 1 PR created"
case "$result" in
  *"cap-reached: 2 candidate(s) remaining, not actioned; re-run or raise --max-prs (current: 1)"*) cap_line_ok=1 ;;
  *) cap_line_ok=0 ;;
esac
assert_equals "$cap_line_ok" "1" \
  "(140a) cap reached -> the cap-reached remediation line is emitted"
deferred_lines=$(printf '%s\n' "$result" | grep -c '^deferred: ' || true)
assert_equals "$deferred_lines" "2" \
  "(140b) cap reached -> one 'deferred: <branch>' line per un-actioned candidate"
case "$result" in
  *"--max-prs cap (1) reached, no writes"*) deferred_progress_ok=1 ;;
  *) deferred_progress_ok=0 ;;
esac
assert_equals "$deferred_progress_ok" "1" \
  "(140c) a deferred candidate gets a progress line naming the cap as the reason"
# The deferred candidates must be left completely untouched — no branch on
# origin, so a later re-run picks them up from exactly where they were.
pushed_count=0
for tob_n in 520 521 522; do
  git -C "$tob_origin" show-ref --verify --quiet "refs/heads/do-work/issue-$tob_n" \
    && pushed_count=$((pushed_count + 1))
done
assert_equals "$pushed_count" "1" \
  "(140d) cap reached -> only the actioned candidate's branch was pushed"

# --- (141) --max-prs 0 means unlimited (explicit opt-in) ---
reset_tob_layout
tob_add_worktree_ahead 530
tob_add_worktree_ahead 531
tob_add_worktree_ahead 532
tob_add_worktree_ahead 533
printf '810' > "$tob_state/next-pr-number"
result=$(run_tob --max-prs 0)
created=$(grep -c "GH-CALL: pr create" "$tob_gh_log" || true)
assert_equals "$created" "4" \
  "(141) --max-prs 0 -> unlimited; all 4 candidates actioned"
case "$result" in
  *"cap-reached:"*) cap_line_present=1 ;;
  *) cap_line_present=0 ;;
esac
assert_equals "$cap_line_present" "0" \
  "(141a) --max-prs 0 -> no cap-reached line"

# --- (141b) the default cap is 3, not unlimited ---
reset_tob_layout
tob_add_worktree_ahead 540
tob_add_worktree_ahead 541
tob_add_worktree_ahead 542
tob_add_worktree_ahead 543
tob_add_worktree_ahead 544
printf '820' > "$tob_state/next-pr-number"
result=$(run_tob)
created=$(grep -c "GH-CALL: pr create" "$tob_gh_log" || true)
assert_equals "$created" "3" \
  "(141b) no --max-prs flag -> the default cap of 3 applies"

# --- (142) --dry-run performs no writes at all ---
reset_tob_layout
tob_add_worktree 550           # abandon candidate
tob_add_worktree_ahead 551     # salvage candidate
printf '830' > "$tob_state/next-pr-number"
result=$(run_tob --dry-run)
case "$result" in
  *"dry-run: no writes will be performed"*) dry_marker_ok=1 ;;
  *) dry_marker_ok=0 ;;
esac
assert_equals "$dry_marker_ok" "1" \
  "(142) --dry-run announces itself before the per-candidate plan"
if [ -d "$tob_repo/.claude/worktrees/agent-550" ]; then
  printf '  %sPASS%s  (142a) --dry-run left the abandon candidate'"'"'s worktree on disk\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (142a) --dry-run removed a worktree\n' "$RED" "$RESET"
  fail=$((fail+1))
fi
case "$(cat "$tob_gh_log")" in
  *"pr create"*) dry_pr_created=1 ;;
  *) dry_pr_created=0 ;;
esac
assert_equals "$dry_pr_created" "0" \
  "(142b) --dry-run never calls gh pr create"
case "$(cat "$tob_gh_log")" in
  *"issue edit"*) dry_issue_edited=1 ;;
  *) dry_issue_edited=0 ;;
esac
assert_equals "$dry_issue_edited" "0" \
  "(142c) --dry-run never clears an @me assignment"
dry_pushed=$(git -C "$tob_origin" show-ref --verify --quiet refs/heads/do-work/issue-551 && echo yes || echo no)
assert_equals "$dry_pushed" "no" \
  "(142d) --dry-run never pushes a salvage candidate's branch"
# The counters still report what WOULD happen — that's the point of the plan.
assert_equals "$(printf '%s\n' "$result" | tail -n 1)" \
  "summary: salvaged=1 abandoned=1 stale_assigns=0 already_landed=0" \
  "(142e) --dry-run still reports the counters it would have produced"

# --- (142f) --dry-run suppresses the row-5 stale-assign write but still reports it ---
reset_tob_layout
printf '{"version":1,"backlog":{"self_assign":true}}' > "$tob_repo/shipyard.config.json"
printf '888\n' > "$tob_state/self-assign-list"
result=$(run_tob --dry-run)
case "$result" in
  *"stale-assign: 888"*) dry_row5_reported=1 ;;
  *) dry_row5_reported=0 ;;
esac
assert_equals "$dry_row5_reported" "1" \
  "(142f) --dry-run still reports the row-5 stale assignment it would clear"
case "$(cat "$tob_gh_log")" in
  *"issue edit"*) dry_row5_wrote=1 ;;
  *) dry_row5_wrote=0 ;;
esac
assert_equals "$dry_row5_wrote" "0" \
  "(142g) --dry-run does not actually clear the row-5 stale assignment"

# --- (143) the candidates: header precedes every write ---
reset_tob_layout
tob_add_worktree_ahead 560
tob_add_worktree_ahead 561
printf '840' > "$tob_state/next-pr-number"
result=$(run_tob)
assert_equals "$(printf '%s\n' "$result" | head -n 1)" "candidates: 2" \
  "(143) the blast radius is announced as the FIRST line, before any write"

# ============================================================================
# Issue #1517 — already-landed pre-checks. #1518 (above) bounded how many PRs
# one misfiring pass can open; this block pins the predicate itself. The
# `ahead` test compares commits by SHA identity, so on a squash-merge repo it
# is permanently > 0 for every branch ever landed — which made the sweep
# regenerate a duplicate PR for the same branch once per session, for three
# consecutive sessions, on a candidate set that could never drain.
#
# Coverage goals:
#   - Check 1 (empty effective diff): ahead > 0 by sha but content identical
#     to main -> no PR, worktree AND branch removed, already_landed=1.
#   - Check 2 (issue CLOSED by a merged PR): non-empty diff -> no PR,
#     worktree removed, branch KEPT (weaker evidence).
#   - Conservative fall-through: unreadable issue probe, OPEN issue, and
#     CLOSED-with-no-merged-PR all still salvage exactly as before.
#   - --dry-run renders the classification without performing any write.
#   - Suppression happens before the --max-prs cap, so leftovers don't eat
#     the budget genuinely-stranded work needs.
# ============================================================================

echo
echo "worktree-reap.sh triage-orphan-branches already-landed pre-checks (issue #1517)"
echo

# --- (145) check 1: content already upstream -> no PR, worktree + branch gone ---
reset_tob_layout
tob_add_worktree_landed 530
printf '850' > "$tob_state/next-pr-number"
result=$(run_tob)
case "$result" in
  *"[1/1] already-landed do-work/issue-530 — content already upstream (empty diff vs main); no PR opened, removing worktree + branch"*) landed_line_ok=1 ;;
  *) landed_line_ok=0 ;;
esac
assert_equals "$landed_line_ok" "1" \
  "(145) squash-merge leftover (ahead>0 by sha, empty diff) -> already-landed progress line"
case "$(cat "$tob_gh_log")" in
  *"pr create"*) landed_pr_created=1 ;;
  *) landed_pr_created=0 ;;
esac
assert_equals "$landed_pr_created" "0" \
  "(145a) check 1 fired -> gh pr create is never called"
assert_equals "$(printf '%s\n' "$result" | tail -n 1)" \
  "summary: salvaged=0 abandoned=0 stale_assigns=0 already_landed=1" \
  "(145b) check 1 counts as already_landed, not salvaged"
if [ -d "$tob_repo/.claude/worktrees/agent-530" ]; then
  printf '  %sFAIL%s  (145c) already-landed worktree still on disk — the candidate set never drains\n' "$RED" "$RESET"
  fail=$((fail+1))
else
  printf '  %sPASS%s  (145c) already-landed worktree removed — the candidate set drains\n' "$GREEN" "$RESET"
  pass=$((pass+1))
fi
if git -C "$tob_repo" show-ref --verify --quiet "refs/heads/do-work/issue-530"; then
  printf '  %sFAIL%s  (145d) empty-diff branch ref still present\n' "$RED" "$RESET"
  fail=$((fail+1))
else
  printf '  %sPASS%s  (145d) empty-diff branch ref deleted (nothing unique in it)\n' "$GREEN" "$RESET"
  pass=$((pass+1))
fi
case "$(cat "$tob_gh_log")" in
  *"GH-CALL: issue view"*) check2_queried=1 ;;
  *) check2_queried=0 ;;
esac
assert_equals "$check2_queried" "0" \
  "(145e) check 1 short-circuits check 2 — no gh read is made when local git already answered"

# --- (146) check 2: issue CLOSED by a merged PR -> no PR, worktree gone, branch KEPT ---
reset_tob_layout
tob_add_worktree_ahead 531
printf 'CLOSED|1234' > "$tob_state/issue-probe-531"
printf '851' > "$tob_state/next-pr-number"
result=$(run_tob)
case "$result" in
  *"[1/1] already-landed do-work/issue-531 — issue #531 CLOSED, work merged as PR #1234; no PR opened, removing worktree (branch kept)"*) closed_line_ok=1 ;;
  *) closed_line_ok=0 ;;
esac
assert_equals "$closed_line_ok" "1" \
  "(146) closed issue with a merged PR -> already-landed progress line naming the merged PR"
case "$(cat "$tob_gh_log")" in
  *"pr create"*) closed_pr_created=1 ;;
  *) closed_pr_created=0 ;;
esac
assert_equals "$closed_pr_created" "0" \
  "(146a) check 2 fired -> gh pr create is never called"
if [ -d "$tob_repo/.claude/worktrees/agent-531" ]; then
  printf '  %sFAIL%s  (146b) already-landed worktree still on disk\n' "$RED" "$RESET"
  fail=$((fail+1))
else
  printf '  %sPASS%s  (146b) already-landed worktree removed\n' "$GREEN" "$RESET"
  pass=$((pass+1))
fi
if git -C "$tob_repo" show-ref --verify --quiet "refs/heads/do-work/issue-531"; then
  printf '  %sPASS%s  (146c) check-2 branch ref KEPT as a safety net (diff is non-empty)\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (146c) check-2 branch ref was deleted — evidence is too weak for that\n' "$RED" "$RESET"
  fail=$((fail+1))
fi
case "$result" in
  *"already-landed: do-work/issue-531 — issue #531 CLOSED, work merged as PR #1234"*) landed_summary_ok=1 ;;
  *) landed_summary_ok=0 ;;
esac
assert_equals "$landed_summary_ok" "1" \
  "(146d) a per-branch 'already-landed: <branch> — <why>' summary line is emitted"

# --- (147) conservative fall-through: unreadable / OPEN / closed-without-PR all salvage ---
reset_tob_layout
tob_add_worktree_ahead 532
printf '860' > "$tob_state/next-pr-number"
result=$(run_tob)
case "$result" in
  *"salvage do-work/issue-532"*) unreadable_salvaged=1 ;;
  *) unreadable_salvaged=0 ;;
esac
assert_equals "$unreadable_salvaged" "1" \
  "(147) unreadable issue probe -> salvaged as before (conservative in the ambiguous direction)"

reset_tob_layout
tob_add_worktree_ahead 533
printf 'OPEN|' > "$tob_state/issue-probe-533"
printf '861' > "$tob_state/next-pr-number"
result=$(run_tob)
case "$result" in
  *"salvage do-work/issue-533"*) open_salvaged=1 ;;
  *) open_salvaged=0 ;;
esac
assert_equals "$open_salvaged" "1" \
  "(147a) OPEN originating issue -> salvaged as before"

reset_tob_layout
tob_add_worktree_ahead 534
# CLOSED but with no merged PR linked — e.g. a `not planned` close. The
# branch's work may genuinely never have landed, so this must NOT suppress.
printf 'CLOSED|' > "$tob_state/issue-probe-534"
printf '862' > "$tob_state/next-pr-number"
result=$(run_tob)
case "$result" in
  *"salvage do-work/issue-534"*) closed_nopr_salvaged=1 ;;
  *) closed_nopr_salvaged=0 ;;
esac
assert_equals "$closed_nopr_salvaged" "1" \
  "(147b) CLOSED issue with no merged PR linked -> salvaged (both halves of check 2 are required)"

# --- (148) --dry-run renders the classification and performs no write ---
reset_tob_layout
tob_add_worktree_landed 535
result=$(run_tob --dry-run)
case "$result" in
  *"already-landed do-work/issue-535 — content already upstream (empty diff vs main)"*) dry_landed_ok=1 ;;
  *) dry_landed_ok=0 ;;
esac
assert_equals "$dry_landed_ok" "1" \
  "(148) --dry-run plan classifies each candidate, so a human can audit the verdict before the real sweep"
if [ -d "$tob_repo/.claude/worktrees/agent-535" ]; then
  printf '  %sPASS%s  (148a) --dry-run left the already-landed worktree on disk\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (148a) --dry-run removed an already-landed worktree\n' "$RED" "$RESET"
  fail=$((fail+1))
fi
if git -C "$tob_repo" show-ref --verify --quiet "refs/heads/do-work/issue-535"; then
  printf '  %sPASS%s  (148b) --dry-run left the already-landed branch ref alone\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (148b) --dry-run deleted a branch ref\n' "$RED" "$RESET"
  fail=$((fail+1))
fi

# --- (149) suppression precedes the --max-prs cap, so leftovers don't eat the budget ---
reset_tob_layout
tob_add_worktree_landed 540
tob_add_worktree_ahead 541
printf '870' > "$tob_state/next-pr-number"
result=$(run_tob --max-prs 1)
created=$(grep -c "GH-CALL: pr create" "$tob_gh_log" || true)
assert_equals "$created" "1" \
  "(149) an already-landed candidate does not consume the --max-prs budget"
case "$result" in
  *"cap-reached"*) cap_hit=1 ;;
  *) cap_hit=0 ;;
esac
assert_equals "$cap_hit" "0" \
  "(149a) with one leftover suppressed, the genuine salvage still fits under --max-prs 1"
assert_equals "$(printf '%s\n' "$result" | tail -n 1)" \
  "summary: salvaged=1 abandoned=0 stale_assigns=0 already_landed=1" \
  "(149b) counters split the leftover from the genuine salvage"

# ============================================================================
# Issue #1541 — check 3, the SUPERSEDED-DRAFT pre-check.
#
# Checks 1 and 2 (#1517, above) suppressed 18 of 21 candidates on a real
# --dry-run of this repo at 001415f. Two of the three survivors were branches
# whose work had demonstrably landed — do-work/issue-1412 (as PR #1508) and
# do-work/issue-1511 (as PR #1515) — but whose ORIGINATING ISSUES were still
# OPEN, because the landing PR carried `refs #N` rather than `closes #N`.
# Check 2 keys on issue state, so it correctly declined; check 1 saw a
# non-empty diff, so it correctly declined too. Check 3 is the only one that
# reaches that shape.
#
# The predicate is path EXISTENCE, never a size comparison: every path the
# branch ADDS relative to its merge-base already exists on the default
# branch. Coverage goals:
#   - Fires on the superseded-draft shape (a different implementation of the
#     same work landed at the same new path) -> no PR, worktree removed,
#     branch ref KEPT (weak evidence, same action as check 2).
#   - DECLINES on the negative control #1541 names explicitly: a branch that
#     deletes more lines than it adds, touching only files the default branch
#     has also grown. A line-count proxy for "main is ahead" would suppress
#     this and silently discard real work.
#   - DECLINES on a partial collision (some invented paths landed upstream,
#     some not) — the quantifier is ALL, not ANY.
#   - DECLINES when the branch invents a path the default branch has never
#     had, and when it invents no new path at all (emptiness is not evidence).
#   - Runs only after checks 1 and 2 have both declined.
#   - Reads NUL-delimited paths, so a path containing a space is probed
#     intact rather than core.quotePath-escaped into a false decline.
#   - --dry-run renders the verdict and performs no write.
# ============================================================================

echo
echo "worktree-reap.sh triage-orphan-branches superseded-draft pre-check (issue #1541)"
echo

# tob_add_worktree_superseded <issue-n> [path-basename] — the check-3 shape.
# The branch invents a brand-new path; the default branch independently lands
# a DIFFERENT implementation at that same path. Both earlier checks must
# decline on it by construction: the effective diff is non-empty (check 1),
# and the caller leaves the originating issue OPEN (check 2).
tob_add_worktree_superseded() {
  local n="$1"
  local base="${2:-feature-$1.sh}"
  local path="$tob_repo/.claude/worktrees/agent-$n"
  tob_add_worktree "$n"
  printf 'draft implementation for issue %s\n' "$n" > "$path/$base"
  git -C "$path" add "$path/$base" >/dev/null 2>&1
  git -C "$path" commit -q -m "draft $n" >/dev/null 2>&1
  # A textually different implementation of the same work lands upstream at
  # the same path — the do-work/issue-1412 -> PR #1508 shape.
  printf 'landed implementation for issue %s, rewritten\n' "$n" > "$tob_repo/$base"
  git -C "$tob_repo" add "$tob_repo/$base" >/dev/null 2>&1
  git -C "$tob_repo" commit -q -m "landed $n" >/dev/null 2>&1
  git -C "$tob_repo" push -q origin main >/dev/null 2>&1
  git -C "$tob_repo" fetch -q origin >/dev/null 2>&1
}

# tob_add_worktree_shrinking <issue-n> — genuinely UNLANDED work whose diff
# DELETES more lines than it adds, on a file the default branch has since
# grown. This is the negative control #1541 calls out by name: under a
# line-count reading of "main is ahead", main has strictly more of this file
# than the branch does, so the PR would be suppressed and real work
# discarded. The branch invents no new path, so check 3 must decline.
tob_add_worktree_shrinking() {
  local n="$1"
  local path="$tob_repo/.claude/worktrees/agent-$n"
  printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n' > "$tob_repo/shared-$n.txt"
  git -C "$tob_repo" add "$tob_repo/shared-$n.txt" >/dev/null 2>&1
  git -C "$tob_repo" commit -q -m "seed shared $n" >/dev/null 2>&1
  git -C "$tob_repo" push -q origin main >/dev/null 2>&1
  tob_add_worktree "$n"
  # The branch refactors it down to two lines — a large net deletion, but
  # real work that exists nowhere else.
  printf 'refactored\nkept\n' > "$path/shared-$n.txt"
  git -C "$path" add "$path/shared-$n.txt" >/dev/null 2>&1
  git -C "$path" commit -q -m "refactor $n" >/dev/null 2>&1
  # Meanwhile the default branch grows the same file further.
  printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\n' > "$tob_repo/shared-$n.txt"
  git -C "$tob_repo" add "$tob_repo/shared-$n.txt" >/dev/null 2>&1
  git -C "$tob_repo" commit -q -m "extend shared $n" >/dev/null 2>&1
  git -C "$tob_repo" push -q origin main >/dev/null 2>&1
  git -C "$tob_repo" fetch -q origin >/dev/null 2>&1
}

# tob_add_worktree_partial <issue-n> — the branch invents TWO new paths and
# the default branch independently landed only ONE of them.
tob_add_worktree_partial() {
  local n="$1"
  local path="$tob_repo/.claude/worktrees/agent-$n"
  tob_add_worktree "$n"
  printf 'draft a %s\n' "$n" > "$path/feature-a-$n.sh"
  printf 'draft b %s\n' "$n" > "$path/feature-b-$n.sh"
  git -C "$path" add "$path/feature-a-$n.sh" "$path/feature-b-$n.sh" >/dev/null 2>&1
  git -C "$path" commit -q -m "draft $n" >/dev/null 2>&1
  printf 'landed a %s\n' "$n" > "$tob_repo/feature-a-$n.sh"
  git -C "$tob_repo" add "$tob_repo/feature-a-$n.sh" >/dev/null 2>&1
  git -C "$tob_repo" commit -q -m "landed a $n" >/dev/null 2>&1
  git -C "$tob_repo" push -q origin main >/dev/null 2>&1
  git -C "$tob_repo" fetch -q origin >/dev/null 2>&1
}

# --- (150) check 3 fires: superseded draft, OPEN issue -> no PR, branch KEPT ---
reset_tob_layout
tob_add_worktree_superseded 560
# OPEN issue: exactly the do-work/issue-1412 / do-work/issue-1511 shape, and
# the reason check 2 cannot see this class.
printf 'OPEN|' > "$tob_state/issue-probe-560"
printf '880' > "$tob_state/next-pr-number"
result=$(run_tob)
case "$result" in
  *"[1/1] already-landed do-work/issue-560 — superseded draft: all 1 new path(s) this branch adds already exist on main (e.g. feature-560.sh); no PR opened, removing worktree (branch kept)"*) superseded_line_ok=1 ;;
  *) superseded_line_ok=0 ;;
esac
assert_equals "$superseded_line_ok" "1" \
  "(150) superseded draft with an OPEN originating issue -> already-landed progress line naming the collided path"
case "$(cat "$tob_gh_log")" in
  *"pr create"*) superseded_pr_created=1 ;;
  *) superseded_pr_created=0 ;;
esac
assert_equals "$superseded_pr_created" "0" \
  "(150a) check 3 fired -> gh pr create is never called (no duplicate of the landed work)"
assert_equals "$(printf '%s\n' "$result" | tail -n 1)" \
  "summary: salvaged=0 abandoned=0 stale_assigns=0 already_landed=1" \
  "(150b) check 3 counts as already_landed, not salvaged"
if [ -d "$tob_repo/.claude/worktrees/agent-560" ]; then
  printf '  %sFAIL%s  (150c) superseded worktree still on disk — the candidate set never drains\n' "$RED" "$RESET"
  fail=$((fail+1))
else
  printf '  %sPASS%s  (150c) superseded worktree removed — the candidate set drains\n' "$GREEN" "$RESET"
  pass=$((pass+1))
fi
if git -C "$tob_repo" show-ref --verify --quiet "refs/heads/do-work/issue-560"; then
  printf '  %sPASS%s  (150d) check-3 branch ref KEPT as a safety net (evidence is circumstantial)\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (150e) check-3 branch ref was deleted — evidence is too weak for that\n' "$RED" "$RESET"
  fail=$((fail+1))
fi
case "$result" in
  *"already-landed: do-work/issue-560 — superseded draft:"*) superseded_summary_ok=1 ;;
  *) superseded_summary_ok=0 ;;
esac
assert_equals "$superseded_summary_ok" "1" \
  "(150f) a per-branch 'already-landed: <branch> — <why>' summary line names the superseded-draft verdict"

# --- (151) THE negative control: deletes more than it adds, still unlanded ---
reset_tob_layout
tob_add_worktree_shrinking 561
printf 'OPEN|' > "$tob_state/issue-probe-561"
printf '881' > "$tob_state/next-pr-number"
result=$(run_tob)
case "$result" in
  *"salvage do-work/issue-561"*) shrinking_salvaged=1 ;;
  *) shrinking_salvaged=0 ;;
esac
assert_equals "$shrinking_salvaged" "1" \
  "(151) a branch that DELETES more than it adds, on a file main has grown, still salvages — check 3 compares no line counts"
case "$result" in
  *"already-landed do-work/issue-561"*) shrinking_suppressed=1 ;;
  *) shrinking_suppressed=0 ;;
esac
assert_equals "$shrinking_suppressed" "0" \
  "(151a) the shrinking branch is never classified already-landed"
assert_equals "$(printf '%s\n' "$result" | tail -n 1)" \
  "summary: salvaged=1 abandoned=0 stale_assigns=0 already_landed=0" \
  "(151b) counters record the shrinking branch as a genuine salvage"
if git -C "$tob_repo" show-ref --verify --quiet "refs/heads/do-work/issue-561"; then
  printf '  %sPASS%s  (151c) the shrinking branch ref survives untouched\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (151c) the shrinking branch ref was deleted\n' "$RED" "$RESET"
  fail=$((fail+1))
fi

# --- (152) partial collision -> declines; the quantifier is ALL, not ANY ---
reset_tob_layout
tob_add_worktree_partial 562
printf 'OPEN|' > "$tob_state/issue-probe-562"
printf '882' > "$tob_state/next-pr-number"
result=$(run_tob)
case "$result" in
  *"salvage do-work/issue-562"*) partial_salvaged=1 ;;
  *) partial_salvaged=0 ;;
esac
assert_equals "$partial_salvaged" "1" \
  "(152) one invented path still missing upstream -> salvaged (check 3 requires ALL of them, not ANY)"

# --- (153) a wholly new path the default branch has never had -> declines ---
reset_tob_layout
tob_add_worktree_ahead 563
printf 'OPEN|' > "$tob_state/issue-probe-563"
printf '883' > "$tob_state/next-pr-number"
result=$(run_tob)
case "$result" in
  *"salvage do-work/issue-563"*) novel_salvaged=1 ;;
  *) novel_salvaged=0 ;;
esac
assert_equals "$novel_salvaged" "1" \
  "(153) a branch inventing a path main has never had -> salvaged (the ordinary unlanded case)"

# --- (154) check 3 runs only after checks 1 and 2 have both declined ---
reset_tob_layout
tob_add_worktree_superseded 564
# Same superseded shape, but the originating issue IS closed by a merged PR,
# so check 2 answers first and its (stronger, differently-worded) reason wins.
printf 'CLOSED|1234' > "$tob_state/issue-probe-564"
printf '884' > "$tob_state/next-pr-number"
result=$(run_tob)
case "$result" in
  *"already-landed do-work/issue-564 — issue #564 CLOSED, work merged as PR #1234"*) order_ok=1 ;;
  *) order_ok=0 ;;
esac
assert_equals "$order_ok" "1" \
  "(154) check 2 answers before check 3 — the stronger evidence is the reported reason"

reset_tob_layout
# A landed (empty-diff) branch that ALSO invents nothing: check 1 answers
# first, and its stronger action (branch ref deleted too) must not be
# downgraded to check 3's keep-the-branch action.
tob_add_worktree_landed 565
printf '885' > "$tob_state/next-pr-number"
result=$(run_tob)
case "$result" in
  *"already-landed do-work/issue-565 — content already upstream (empty diff vs main); no PR opened, removing worktree + branch"*) order1_ok=1 ;;
  *) order1_ok=0 ;;
esac
assert_equals "$order1_ok" "1" \
  "(154a) check 1 answers before check 3 — the empty-diff branch ref is still deleted"

# --- (155) NUL-delimited path reading: an invented path containing a space ---
reset_tob_layout
tob_add_worktree_superseded 566 "feature with space.sh"
printf 'OPEN|' > "$tob_state/issue-probe-566"
printf '886' > "$tob_state/next-pr-number"
result=$(run_tob)
case "$result" in
  *"already-landed do-work/issue-566 — superseded draft: all 1 new path(s) this branch adds already exist on main (e.g. feature with space.sh)"*) spaced_ok=1 ;;
  *) spaced_ok=0 ;;
esac
assert_equals "$spaced_ok" "1" \
  "(155) an invented path containing a space is probed intact (NUL-delimited diff, not core.quotePath-escaped)"

# --- (156) --dry-run renders the check-3 verdict and performs no write ---
reset_tob_layout
tob_add_worktree_superseded 567
printf 'OPEN|' > "$tob_state/issue-probe-567"
result=$(run_tob --dry-run)
case "$result" in
  *"already-landed do-work/issue-567 — superseded draft:"*) dry_superseded_ok=1 ;;
  *) dry_superseded_ok=0 ;;
esac
assert_equals "$dry_superseded_ok" "1" \
  "(156) --dry-run renders the superseded-draft verdict so a human can audit it before the real sweep"
if [ -d "$tob_repo/.claude/worktrees/agent-567" ]; then
  printf '  %sPASS%s  (156a) --dry-run left the superseded worktree on disk\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (156a) --dry-run removed a superseded worktree\n' "$RED" "$RESET"
  fail=$((fail+1))
fi

# --- (157) suppression precedes the --max-prs cap for check 3 too ---
reset_tob_layout
tob_add_worktree_superseded 568
printf 'OPEN|' > "$tob_state/issue-probe-568"
tob_add_worktree_ahead 569
printf 'OPEN|' > "$tob_state/issue-probe-569"
printf '887' > "$tob_state/next-pr-number"
result=$(run_tob --max-prs 1)
created=$(grep -c "GH-CALL: pr create" "$tob_gh_log" || true)
assert_equals "$created" "1" \
  "(157) a superseded-draft candidate does not consume the --max-prs budget"
assert_equals "$(printf '%s\n' "$result" | tail -n 1)" \
  "summary: salvaged=1 abandoned=0 stale_assigns=0 already_landed=1" \
  "(157a) counters split the superseded draft from the genuine salvage"

# ============================================================================
# Issue #1565 — check 2b, the BRANCH'S-OWN-PR-MERGED pre-check.
#
# Check 2 (#1517) needs the ISSUE's closedByPullRequestsReferences to be
# populated, and GitHub populates it only when a merged PR carried a closing
# keyword its linker resolved. An issue closed BY HAND after its PR landed
# reads CLOSED/COMPLETED with that array EMPTY, so check 2's second half
# fails and it declines — while the branch's own PR sits there MERGED.
# Observed live on mattsears18/lightwork (session
# do-work-20260915T205245Z-95644): do-work/issue-4738 and do-work/issue-4823
# were both planned for `salvage` with PRs #4740 and #4826 already merged.
# Check 1 declined (main had moved on since the squash) and check 3 declined
# (neither branch adds a new path), so nothing consulted the one signal that
# settles it.
#
# Coverage goals:
#   - Fires on the #1565 shape (CLOSED issue, EMPTY closing refs, branch's
#     own PR MERGED) -> no PR, worktree removed, branch ref KEPT.
#   - DECLINES when no merged PR exists for the head, and when the probe
#     returns something that is not a bare PR number.
#   - An OPEN PR on the head is NEVER read as a merged one — that candidate
#     still takes the existing-pr path.
#   - Runs only after checks 1 and 2 decline, and BEFORE check 3.
#   - --dry-run renders the verdict and performs no write.
#   - Suppression precedes the --max-prs cap.
# ============================================================================

echo
echo "worktree-reap.sh triage-orphan-branches branch's-own-PR-merged pre-check (issue #1565)"
echo

# --- (158) check 2b fires: hand-closed issue, branch's PR merged -> branch KEPT ---
reset_tob_layout
tob_add_worktree_ahead 570
# The #1565 shape exactly: CLOSED, but closedByPullRequestsReferences empty,
# so check 2 declines on its second half.
printf 'CLOSED|' > "$tob_state/issue-probe-570"
printf '4740' > "$tob_state/merged-pr-for-do-work_issue-570"
printf '890' > "$tob_state/next-pr-number"
result=$(run_tob)
case "$result" in
  *"[1/1] already-landed do-work/issue-570 — branch's own PR #4740 already MERGED; no PR opened, removing worktree (branch kept)"*) merged_line_ok=1 ;;
  *) merged_line_ok=0 ;;
esac
assert_equals "$merged_line_ok" "1" \
  "(158) CLOSED issue with EMPTY closing refs but a MERGED PR on the branch -> already-landed progress line naming that PR"
case "$(cat "$tob_gh_log")" in
  *"pr create"*) merged_pr_created=1 ;;
  *) merged_pr_created=0 ;;
esac
assert_equals "$merged_pr_created" "0" \
  "(158a) check 2b fired -> gh pr create is never called (no duplicate draft for landed work)"
assert_equals "$(printf '%s\n' "$result" | tail -n 1)" \
  "summary: salvaged=0 abandoned=0 stale_assigns=0 already_landed=1" \
  "(158b) check 2b counts as already_landed, not salvaged"
if [ -d "$tob_repo/.claude/worktrees/agent-570" ]; then
  printf '  %sFAIL%s  (158c) check-2b worktree still on disk — the candidate set never drains\n' "$RED" "$RESET"
  fail=$((fail+1))
else
  printf '  %sPASS%s  (158c) check-2b worktree removed — the candidate set drains\n' "$GREEN" "$RESET"
  pass=$((pass+1))
fi
if git -C "$tob_repo" show-ref --verify --quiet "refs/heads/do-work/issue-570"; then
  printf '  %sPASS%s  (158d) check-2b branch ref KEPT as a safety net (squash merge leaves its commits unreachable)\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (158e) check-2b branch ref was deleted — evidence is too weak for that\n' "$RED" "$RESET"
  fail=$((fail+1))
fi
case "$result" in
  *"already-landed: do-work/issue-570 — branch's own PR #4740 already MERGED"*) merged_summary_ok=1 ;;
  *) merged_summary_ok=0 ;;
esac
assert_equals "$merged_summary_ok" "1" \
  "(158f) a per-branch 'already-landed: <branch> — <why>' summary line names the merged PR"

# --- (159) conservative fall-through: no merged PR for the head -> salvage ---
reset_tob_layout
tob_add_worktree_ahead 571
printf 'CLOSED|' > "$tob_state/issue-probe-571"
printf '891' > "$tob_state/next-pr-number"
result=$(run_tob)
case "$result" in
  *"salvage do-work/issue-571"*) no_merged_salvaged=1 ;;
  *) no_merged_salvaged=0 ;;
esac
assert_equals "$no_merged_salvaged" "1" \
  "(159) no merged PR on the head -> salvaged as before (absence of a signal is never evidence)"

reset_tob_layout
tob_add_worktree_ahead 572
printf 'CLOSED|' > "$tob_state/issue-probe-572"
# Not a bare PR number — e.g. a gh warning leaking onto stdout.
printf 'could not resolve to a Repository' > "$tob_state/merged-pr-for-do-work_issue-572"
printf '892' > "$tob_state/next-pr-number"
result=$(run_tob)
case "$result" in
  *"salvage do-work/issue-572"*) garbage_salvaged=1 ;;
  *) garbage_salvaged=0 ;;
esac
assert_equals "$garbage_salvaged" "1" \
  "(159a) a non-numeric check-2b probe result -> salvaged (unreadable signal is not staleness)"

# --- (160) an OPEN PR on the head is never read as a merged one ---
reset_tob_layout
tob_add_worktree_ahead 573
printf 'CLOSED|' > "$tob_state/issue-probe-573"
printf '705' > "$tob_state/pr-for-do-work_issue-573"
result=$(run_tob)
case "$result" in
  *"existing-pr do-work/issue-573 — PR #705 already open"*) open_not_merged_ok=1 ;;
  *) open_not_merged_ok=0 ;;
esac
assert_equals "$open_not_merged_ok" "1" \
  "(160) an OPEN PR on the head takes the existing-pr path — check 2b asserts a MERGED PR, not any PR"
case "$result" in
  *"already-landed do-work/issue-573"*) open_misread=1 ;;
  *) open_misread=0 ;;
esac
assert_equals "$open_misread" "0" \
  "(160a) the open-PR candidate is never classified already-landed"

# --- (161) ordering: checks 1 and 2 answer before 2b; 2b answers before 3 ---
reset_tob_layout
tob_add_worktree_ahead 574
printf 'CLOSED|1234' > "$tob_state/issue-probe-574"
printf '4740' > "$tob_state/merged-pr-for-do-work_issue-574"
result=$(run_tob)
case "$result" in
  *"already-landed do-work/issue-574 — issue #574 CLOSED, work merged as PR #1234"*) order2_ok=1 ;;
  *) order2_ok=0 ;;
esac
assert_equals "$order2_ok" "1" \
  "(161) check 2 answers before check 2b — the already-paid read's reason wins"

reset_tob_layout
tob_add_worktree_landed 575
printf '4740' > "$tob_state/merged-pr-for-do-work_issue-575"
result=$(run_tob)
case "$(cat "$tob_gh_log")" in
  *"--state merged"*) merged_probed=1 ;;
  *) merged_probed=0 ;;
esac
assert_equals "$merged_probed" "0" \
  "(161a) check 1 short-circuits check 2b — no gh read is made when local git already answered"
case "$result" in
  *"already-landed do-work/issue-575 — content already upstream (empty diff vs main); no PR opened, removing worktree + branch"*) order3_ok=1 ;;
  *) order3_ok=0 ;;
esac
assert_equals "$order3_ok" "1" \
  "(161b) check 1's stronger action (branch ref deleted too) is not downgraded by check 2b"

reset_tob_layout
tob_add_worktree_superseded 576
printf 'OPEN|' > "$tob_state/issue-probe-576"
printf '4826' > "$tob_state/merged-pr-for-do-work_issue-576"
result=$(run_tob)
case "$result" in
  *"already-landed do-work/issue-576 — branch's own PR #4826 already MERGED"*) order4_ok=1 ;;
  *) order4_ok=0 ;;
esac
assert_equals "$order4_ok" "1" \
  "(161c) check 2b answers before check 3 — a merged PR is stronger evidence than a path collision"

# --- (162) --dry-run renders the check-2b verdict and performs no write ---
reset_tob_layout
tob_add_worktree_ahead 577
printf 'CLOSED|' > "$tob_state/issue-probe-577"
printf '4740' > "$tob_state/merged-pr-for-do-work_issue-577"
result=$(run_tob --dry-run)
case "$result" in
  *"already-landed do-work/issue-577 — branch's own PR #4740 already MERGED"*) dry_merged_ok=1 ;;
  *) dry_merged_ok=0 ;;
esac
assert_equals "$dry_merged_ok" "1" \
  "(162) --dry-run renders the check-2b verdict so a human can audit it before the real sweep"
if [ -d "$tob_repo/.claude/worktrees/agent-577" ]; then
  printf '  %sPASS%s  (162a) --dry-run left the check-2b worktree on disk\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (162a) --dry-run removed a check-2b worktree\n' "$RED" "$RESET"
  fail=$((fail+1))
fi

# --- (163) suppression precedes the --max-prs cap for check 2b too ---
reset_tob_layout
tob_add_worktree_ahead 578
printf 'CLOSED|' > "$tob_state/issue-probe-578"
printf '4740' > "$tob_state/merged-pr-for-do-work_issue-578"
tob_add_worktree_ahead 579
printf 'OPEN|' > "$tob_state/issue-probe-579"
printf '893' > "$tob_state/next-pr-number"
result=$(run_tob --max-prs 1)
created=$(grep -c "GH-CALL: pr create" "$tob_gh_log" || true)
assert_equals "$created" "1" \
  "(163) a check-2b candidate does not consume the --max-prs budget"
assert_equals "$(printf '%s\n' "$result" | tail -n 1)" \
  "summary: salvaged=1 abandoned=0 stale_assigns=0 already_landed=1" \
  "(163a) counters split the merged-PR leftover from the genuine salvage"

# --- (144) --max-prs must be a non-negative integer ---
bash "$helper" triage-orphan-branches --repo-root "$tob_repo" --repo "o/r" \
  --default-branch "main" --max-prs "lots" >/dev/null 2>&1
assert_exit_code "$?" "64" \
  "(144) triage-orphan-branches --max-prs <non-integer> -> exit 64"
bash "$helper" triage-orphan-branches --repo-root "$tob_repo" --repo "o/r" \
  --default-branch "main" --max-prs "-1" >/dev/null 2>&1
assert_exit_code "$?" "64" \
  "(144a) triage-orphan-branches --max-prs -1 -> exit 64"

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
