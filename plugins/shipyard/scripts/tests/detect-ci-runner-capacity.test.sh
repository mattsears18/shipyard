#!/usr/bin/env bash
# Test: the CI-runner-capacity detector — read a repo's self-hosted CI runner
# pool shape (issue #1141).
#
# Background — issue #1141
# -------------------------
# `--concurrency N` bounds worker count, not CI-run count. On a repo whose CI
# runs on a small, fixed self-hosted runner pool, worker throughput and
# CI-landing throughput can decouple: `/shipyard:do-work` dispatches happily
# while the queue behind the runners grows without bound (the repro: a
# 4-runner self-hosted pool against a session that opened 13 PRs, reaching a
# 20+-run queue). `scripts/detect-ci-runner-capacity.sh` is the single
# executable read of that pool's shape, consumed by setup step 1.36 (clamp a
# config-sourced concurrency toward the pool) and the end-of-session summary
# (surface a "queue depth far exceeds pool capacity" banner).
#
# This test pins:
#   (A) the detector script's decision truth table (pure `--decide` mode);
#   (B) the live-path usage/error handling (missing args, --decide arg count);
#   (C) setup step 1.36 exists, calls the detector, and clamps only a
#       config-sourced EFFECTIVE_CONCURRENCY (never an explicit --concurrency);
#   (D) the `ci_capacity` write-through is wired into step 1.5, right after
#       `init`;
#   (E) the session-state schema documents the `ci_capacity` field;
#   (F) cleanup-summary.md documents the `CI executor capacity` banner,
#       gated on shape == self-hosted, a fresh re-query, and F > 0.
#
# Follow-up — issue #1156 (dispatch-time queue-depth backpressure)
# -------------------------------------------------------------------
# #1141 shipped a one-time, session-start pool-capacity read + an
# end-of-session advisory banner. It deliberately did NOT do anything about
# a queue that grows *during* a long session as the dispatch loop keeps
# filling freed worker slots regardless of CI backlog depth. #1156 closes
# that gap: steady-state.md step C now re-reads the LIVE queued-run count
# before filling a freed slot and holds it (mirroring the existing
# "leave the slot empty for now" path) when the queue is too deep relative
# to the pool, with an escape valve so backpressure can never fully stall
# the session. This file additionally pins:
#   (G) the `--decide-backpressure` pure decision truth table;
#   (H) `--decide-backpressure` argument-count usage handling;
#   (I) steady-state.md step C wires the live backpressure check in (reads
#       .ci_capacity via session-state.sh, calls the detector script, uses
#       gh-cached.sh, documents the escape valve);
#   (J) the `ci.backpressure_multiplier` / `ci.backpressure_min_in_flight`
#       config knobs exist in both the schema and the built-in defaults.
#
# Follow-up — issue #1402 (session-wide environmental pause + resume)
# -------------------------------------------------------------------
# #1156's hold retries forever in the ordinary case — a held slot just waits
# for the next agent completion. But if a hold fires and NO worker remains
# in flight (only reachable when an operator has set
# `ci.backpressure_min_in_flight: 0`), there is no future completion to wake
# the loop and a transient, self-clearing condition silently strands the
# session. #1402 closes that gap with a session-wide `paused_on_environment`
# pause + a bounded `Monitor`-armed resume watch
# (`scripts/watch-resume-probe.sh`). This file additionally pins:
#   (K) the `--decide-resume` pure resume-decision truth table;
#   (L) `--decide-resume` argument-count usage handling;
#   (M) steady-state.md carries a pointer to the split-out mechanism;
#   (M2) environmental-pause.md's full mechanism (the trigger condition, the
#       Monitor arm, the resume handling) — split out of steady-state.md
#       under the #611 phase-file size cap;
#   (N) the `paused_on_environment.*` config knobs exist in both the schema
#       and the built-in defaults;
#   (O) drain.md's termination-registry row for `paused_on_environment`.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/detect-ci-runner-capacity.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$here"
while [[ "$repo_root" != "/" ]]; do
  if [[ -d "$repo_root/.git" || -f "$repo_root/CHANGELOG.md" ]]; then
    break
  fi
  repo_root="$(dirname "$repo_root")"
done

if [[ "$repo_root" == "/" ]]; then
  echo "FAIL: could not locate repo root from $here" >&2
  exit 1
fi

DETECTOR="$repo_root/plugins/shipyard/scripts/detect-ci-runner-capacity.sh"
SETUP_MD="$repo_root/plugins/shipyard/commands/do-work/setup/01-repo-recovery.md"
CLEANUP_MD="$repo_root/plugins/shipyard/commands/do-work/cleanup-summary.md"
SESSION_STATE_MD="$repo_root/plugins/shipyard/commands/do-work/session-state-file.md"
STEADY_STATE_MD="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
ENV_PAUSE_MD="$repo_root/plugins/shipyard/commands/do-work/environmental-pause.md"
CONFIG_SCHEMA="$repo_root/plugins/shipyard/schemas/shipyard.config.schema.json"
CONFIG_SH="$repo_root/plugins/shipyard/scripts/shipyard-config.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
  fi
}

# Scans across every setup/*.md fragment rather than one hardcoded file — a
# router/fragment split can silently relocate a step's content out of
# $SETUP_MD without warning (issue #1453; mirrors the fix in
# shipyard-repo-root-preamble.test.sh check (4)).
SETUP_DIR="$repo_root/plugins/shipyard/commands/do-work/setup"
assert_contains_in_setup() {
  local needle="$1" label="$2"
  if grep -qFl -- "$needle" "$SETUP_DIR"/*.md 2>/dev/null; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    expected to find (in any setup/*.md fragment): %s\n' "$needle"
  fi
}

assert_equals() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    assert_pass "$label (got [$actual])"
  else
    assert_fail "$label (expected [$expected], got [$actual])"
  fi
}

echo "CI-runner-capacity detector regression tests (issue #1141)"
echo

# ---------------------------------------------------------------------------
# (A) decide() — pure decision truth table.
# ---------------------------------------------------------------------------
echo "(A) detector script — decision truth table"
if [[ -f "$DETECTOR" ]]; then
  assert_pass "detect-ci-runner-capacity.sh exists"

  # decide <runner_count> <online_count> <busy_count> <expected> <label>
  assert_verdict() {
    local got
    got="$(bash "$DETECTOR" --decide "$1" "$2" "$3" 2>/dev/null)"
    assert_equals "$5" "$4" "$got"
  }

  assert_verdict 0 0 0 "hosted" "zero registered runners is hosted (elastic, no fixed pool)"
  assert_verdict 4 4 3 "self-hosted pool_total=4 pool_idle=1" "4 online, 3 busy -> pool_total=4 pool_idle=1"
  assert_verdict 6 4 4 "self-hosted pool_total=4 pool_idle=0" "6 registered but only 4 online, all busy -> pool_idle=0"
  assert_verdict 4 4 0 "self-hosted pool_total=4 pool_idle=4" "4 online, none busy -> pool_idle=4 (fully idle pool)"
  # A pathological busy_count > online_count (stale/racy API read) must never
  # produce a negative idle count.
  assert_verdict 4 2 5 "self-hosted pool_total=2 pool_idle=0" "busy_count exceeding online_count clamps idle at 0, never negative"

  # Non-numeric inputs degrade to 0 for that signal rather than crashing.
  got="$(bash "$DETECTOR" --decide "" "" "" 2>/dev/null)"
  assert_equals "empty inputs degrade to hosted (0 runners)" "hosted" "$got"
else
  assert_fail "detect-ci-runner-capacity.sh exists (missing at $DETECTOR)"
fi
echo

# ---------------------------------------------------------------------------
# (B) Live-path usage/error handling — no network calls, just argument shape.
# ---------------------------------------------------------------------------
echo "(B) live-path usage handling"
if [[ -f "$DETECTOR" ]]; then
  bash "$DETECTOR" >/dev/null 2>/tmp/detect-ci-runner-capacity-usage.$$
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    assert_pass "no-args invocation exits non-zero with a usage message"
  else
    assert_fail "no-args invocation exits non-zero with a usage message (got exit 0)"
  fi
  assert_contains /tmp/detect-ci-runner-capacity-usage.$$ "usage:" "usage message printed to stderr on missing <owner/repo>"
  assert_equals "no-args invocation exits with EX_USAGE (64)" "64" "$rc"
  rm -f /tmp/detect-ci-runner-capacity-usage.$$

  bash "$DETECTOR" --decide 1 2 >/dev/null 2>/tmp/detect-ci-runner-capacity-decide-usage.$$
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    assert_pass "--decide with wrong arg count exits non-zero"
  else
    assert_fail "--decide with wrong arg count exits non-zero (got exit 0)"
  fi
  rm -f /tmp/detect-ci-runner-capacity-decide-usage.$$

  # --- Issue #1454 (1): reject an unknown leading token instead of silently
  #     treating it as the repo. This is the exact repro from the issue: a
  #     caller invoked the script in the `--repo`-flag style used by every
  #     sibling helper (`classify-backlog.sh run --repo <owner/repo>`), but
  #     this script takes a bare positional -- the leading token "run" used
  #     to be silently accepted as the repo, `--repo` and its value ignored
  #     entirely, and the script still printed a confident, well-formed
  #     `hosted` verdict at exit 0.
  rc=0
  bash "$DETECTOR" run --repo mattsears18/shipyard >/tmp/detect-ci-runner-capacity-badinvoke.$$ 2>&1 || rc=$?
  assert_equals "issue #1454 repro ('run --repo owner/repo') now exits EX_USAGE (64), not 0" "64" "$rc"
  if grep -qF "hosted" /tmp/detect-ci-runner-capacity-badinvoke.$$; then
    assert_fail "issue #1454 repro must NOT print a 'hosted' verdict for the bogus token"
  else
    assert_pass "issue #1454 repro must NOT print a 'hosted' verdict for the bogus token"
  fi
  assert_contains /tmp/detect-ci-runner-capacity-badinvoke.$$ "usage:" \
    "issue #1454 repro prints the usage block instead of a fabricated verdict"
  rm -f /tmp/detect-ci-runner-capacity-badinvoke.$$

  # --- Issue #1454 (1), continued: any extra positional after a well-formed
  #     <owner/repo> is rejected too, not just the flag-shaped case above.
  bash "$DETECTOR" mattsears18/shipyard extra-token >/dev/null 2>/tmp/detect-ci-runner-capacity-extra.$$
  rc=$?
  assert_equals "an extra positional after <owner/repo> exits EX_USAGE (64)" "64" "$rc"
  rm -f /tmp/detect-ci-runner-capacity-extra.$$

  # --- Issue #1454 (1), continued: an unrecognized flag-shaped leading token
  #     (not one of --decide/--decide-backpressure/--decide-resume/--repo)
  #     is rejected rather than silently treated as a positional.
  bash "$DETECTOR" --bogus-flag >/dev/null 2>/tmp/detect-ci-runner-capacity-badflag.$$
  rc=$?
  assert_equals "an unrecognized leading flag exits EX_USAGE (64)" "64" "$rc"
  rm -f /tmp/detect-ci-runner-capacity-badflag.$$

  # --- Issue #1454 (2): validate the positional's <owner/repo> SHAPE before
  #     ever using it -- a bare token with no '/' cannot be a real repo.
  for bad_repo in notarepo "a/b/c" "a/" "/b"; do
    bash "$DETECTOR" "$bad_repo" >/dev/null 2>/tmp/detect-ci-runner-capacity-shape.$$
    rc=$?
    assert_equals "malformed <owner/repo> shape '$bad_repo' exits EX_USAGE (64)" "64" "$rc"
    rm -f /tmp/detect-ci-runner-capacity-shape.$$
  done

  # --- Issue #1454 (optional): the --repo <owner/repo> alias. --repo with no
  #     value is a usage error; the positional form must keep working
  #     unchanged (call sites depend on it -- setup/01-repo-recovery.md's
  #     step 1.36 passes a bare positional, never --repo).
  bash "$DETECTOR" --repo >/dev/null 2>/tmp/detect-ci-runner-capacity-repo-noval.$$
  rc=$?
  assert_equals "--repo with no value exits EX_USAGE (64)" "64" "$rc"
  rm -f /tmp/detect-ci-runner-capacity-repo-noval.$$
else
  assert_fail "live-path usage handling (detector missing)"
fi
echo

# ---------------------------------------------------------------------------
# (P) Issue #1454 (3) — distinguish "no self-hosted runners" (hosted) from
#     "could not query runners" (unknown). `gh api` writes a well-formed JSON
#     error envelope to STDOUT on a non-2xx response and exits non-zero; the
#     pre-#1454 code never checked the exit status, and jq's `.runners |
#     length` on a body with no such key silently evaluates to 0 (`null |
#     length` is 0) -- indistinguishable from a genuine, successful
#     zero-runner read. A `gh` stub reproduces exactly that response shape
#     (verified against the real `gh api repos/<bogus>/actions/runners`
#     output during this fix) without requiring live network access or a
#     real repo.
# ---------------------------------------------------------------------------
echo "(P) live-path — API error body must yield 'unknown', never a spurious 'hosted'"
if [[ -f "$DETECTOR" ]]; then
  mock_dir="$(mktemp -d)"

  # (P.1) gh api exits non-zero with a non-empty 404-shaped JSON error body
  # on stdout -- the exact shape `gh api` itself produces.
  cat > "$mock_dir/gh" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" ]]; then
  printf '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
  exit 1
fi
exit 1
MOCKEOF
  chmod +x "$mock_dir/gh"

  got="$(PATH="$mock_dir:$PATH" bash "$DETECTOR" someowner/somerepo 2>/tmp/detect-ci-runner-capacity-404.$$)"
  rc=$?
  assert_equals "a 404-shaped gh api error body yields 'unknown', never 'hosted'" "unknown" "$got"
  if [[ "$rc" -eq 0 ]]; then
    assert_pass "the 'unknown' verdict for an API error still exits 0 (advisory read, not a hard failure)"
  else
    assert_fail "the 'unknown' verdict for an API error still exits 0 (advisory read, not a hard failure) (got exit $rc)"
  fi
  assert_contains /tmp/detect-ci-runner-capacity-404.$$ "treating as unknown" \
    "diagnostic explains why a 404-shaped body was treated as unknown"
  rm -f /tmp/detect-ci-runner-capacity-404.$$

  # (P.2) Defense in depth: gh api exits 0 but the body has no '.runners'
  # array at all (an unexpected response shape). Must still be 'unknown',
  # not silently parsed as zero runners.
  cat > "$mock_dir/gh" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" ]]; then
  printf '{"unexpected":"shape"}'
  exit 0
fi
exit 1
MOCKEOF
  chmod +x "$mock_dir/gh"

  got="$(PATH="$mock_dir:$PATH" bash "$DETECTOR" someowner/somerepo 2>/dev/null)"
  assert_equals "a 200 response with no '.runners' array yields 'unknown', never 'hosted'" "unknown" "$got"

  # (P.3) The genuinely-empty-body case (e.g. a network failure) still
  # degrades to 'unknown' as before this fix.
  cat > "$mock_dir/gh" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" ]]; then
  exit 1
fi
exit 1
MOCKEOF
  chmod +x "$mock_dir/gh"

  got="$(PATH="$mock_dir:$PATH" bash "$DETECTOR" someowner/somerepo 2>/dev/null)"
  assert_equals "a genuinely empty gh api response still yields 'unknown'" "unknown" "$got"

  # (P.4) The success path is untouched: a real '.runners' array is still
  # parsed and decided normally through this same code path.
  cat > "$mock_dir/gh" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" ]]; then
  printf '{"total_count":0,"runners":[]}'
  exit 0
fi
if [[ "${1:-}" == "run" ]]; then
  printf '[]'
  exit 0
fi
exit 1
MOCKEOF
  chmod +x "$mock_dir/gh"

  got="$(PATH="$mock_dir:$PATH" bash "$DETECTOR" someowner/somerepo 2>/dev/null)"
  assert_equals "a genuine empty '.runners' array still correctly yields 'hosted'" "hosted" "$got"

  # (P.5) The --repo alias reaches the identical live-detection code path as
  # the positional form (same mocked backend, same verdict).
  got="$(PATH="$mock_dir:$PATH" bash "$DETECTOR" --repo someowner/somerepo 2>/dev/null)"
  assert_equals "--repo <owner/repo> alias reaches the same live-detection path as the positional form" "hosted" "$got"

  rm -rf "$mock_dir"
else
  assert_fail "API-error-yields-unknown regression test (detector missing)"
fi
echo

# ---------------------------------------------------------------------------
# (C) setup step 1.36 — exists, calls the detector, clamps only a
#     config-sourced EFFECTIVE_CONCURRENCY (never an explicit --concurrency).
# ---------------------------------------------------------------------------
echo "(C) setup step 1.36 — detector wiring + narrow clamp"
if [[ -f "$SETUP_MD" ]]; then
  assert_pass "01-repo-recovery.md exists"
  assert_contains_in_setup "### 1.36 Detect CI executor pool capacity and clamp toward it" \
    "step 1.36 heading present"
  assert_contains_in_setup "detect-ci-runner-capacity.sh" \
    "step 1.36 invokes the detector script"
  assert_contains_in_setup 'issues/1141' \
    "step 1.36 cites issue #1141"
  assert_contains_in_setup '-z "<--concurrency CLI value, if passed>"' \
    "the pool clamp only fires when no explicit --concurrency was passed (mirrors #733)"
  assert_contains_in_setup 'CI_POOL_TOTAL' \
    "step 1.36 resolves a pool-total variable"
else
  assert_fail "01-repo-recovery.md exists (missing at $SETUP_MD)"
fi
echo

# ---------------------------------------------------------------------------
# (D) ci_capacity write-through wired into step 1.5, right after `init`.
# ---------------------------------------------------------------------------
echo "(D) ci_capacity write-through"
if [[ -f "$SETUP_MD" ]]; then
  assert_contains_in_setup '.ci_capacity = { shape:' \
    "step 1.5 writes .ci_capacity through via session-state.sh update"
  assert_contains_in_setup 'queued_at_start' \
    "ci_capacity write-through carries queued_at_start"
else
  assert_fail "ci_capacity write-through (setup doc missing)"
fi
echo

# ---------------------------------------------------------------------------
# (E) session-state-file.md schema documents ci_capacity.
# ---------------------------------------------------------------------------
echo "(E) session-state-file.md — schema"
if [[ -f "$SESSION_STATE_MD" ]]; then
  assert_pass "session-state-file.md exists"
  assert_contains "$SESSION_STATE_MD" '"ci_capacity"' \
    "schema block includes ci_capacity"
  assert_contains "$SESSION_STATE_MD" 'self-hosted' \
    "schema prose documents the self-hosted shape"
else
  assert_fail "session-state-file.md exists (missing at $SESSION_STATE_MD)"
fi
echo

# ---------------------------------------------------------------------------
# (F) cleanup-summary.md — CI executor capacity banner gating.
# ---------------------------------------------------------------------------
echo "(F) cleanup-summary.md — banner"
if [[ -f "$CLEANUP_MD" ]]; then
  assert_pass "cleanup-summary.md exists"
  assert_contains "$CLEANUP_MD" 'CI executor capacity (#1141)' \
    "banner line present in the full summary shape"
  assert_contains "$CLEANUP_MD" '.ci_capacity.shape == "self-hosted"' \
    "banner gate documents the self-hosted-shape precondition"
  assert_contains "$CLEANUP_MD" 'is at least **3×**' \
    "banner gate documents the 3x queue-depth-vs-pool threshold"
  assert_contains "$CLEANUP_MD" "\`F\` (the \`In flight at exit\`" \
    "banner gate requires F (still-open PRs) > 0"
else
  assert_fail "cleanup-summary.md exists (missing at $CLEANUP_MD)"
fi
echo


# ---------------------------------------------------------------------------
# (G) decide_backpressure() — pure decision truth table (issue #1156).
# ---------------------------------------------------------------------------
echo "(G) detector script — dispatch-time backpressure decision truth table"
if [[ -f "$DETECTOR" ]]; then
  # decide-backpressure <pool_total> <queued> <in_flight> <multiplier> <min_in_flight> <expected> <label>
  assert_backpressure() {
    local got
    got="$(bash "$DETECTOR" --decide-backpressure "$1" "$2" "$3" "$4" "$5" 2>/dev/null)"
    assert_equals "$7" "$6" "$got"
  }

  assert_backpressure 4 10 2 5 1 "dispatch" "queued (10) under threshold (4x5=20) -> dispatch"
  assert_backpressure 4 20 2 5 1 "dispatch" "queued exactly at threshold (20) -> dispatch (strictly greater-than gate)"
  assert_backpressure 4 21 2 5 1 "hold" "queued (21) over threshold (20) -> hold"
  assert_backpressure 4 100 0 5 1 "dispatch" "in_flight (0) below min_in_flight (1) -> escape valve dispatches regardless of queue depth"
  assert_backpressure 0 100 2 5 1 "dispatch" "pool_total 0 (unreadable/hosted) -> always dispatch, never hold on an unread signal"
  assert_backpressure 4 26 5 5 5 "hold" "in_flight (5) not below min_in_flight (5) -> escape valve does NOT fire; falls through to threshold check (queued 26 > threshold 20 -> hold)"
  assert_backpressure 4 26 5 5 6 "dispatch" "in_flight (5) below min_in_flight (6) -> escape valve fires"

  # Non-numeric inputs degrade to safe defaults rather than crashing.
  got="$(bash "$DETECTOR" --decide-backpressure "" "" "" "" "" 2>/dev/null)"
  assert_equals "empty inputs degrade to dispatch (pool_total defaults to 0)" "dispatch" "$got"
else
  assert_fail "detect-ci-runner-capacity.sh exists (missing at $DETECTOR)"
fi
echo

# ---------------------------------------------------------------------------
# (H) --decide-backpressure argument-count usage handling.
# ---------------------------------------------------------------------------
echo "(H) --decide-backpressure usage handling"
if [[ -f "$DETECTOR" ]]; then
  bash "$DETECTOR" --decide-backpressure 4 10 2 5 >/dev/null 2>/tmp/detect-ci-runner-capacity-bp-usage.$$
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    assert_pass "--decide-backpressure with wrong arg count exits non-zero"
  else
    assert_fail "--decide-backpressure with wrong arg count exits non-zero (got exit 0)"
  fi
  rm -f /tmp/detect-ci-runner-capacity-bp-usage.$$

  # Issue #1597: the natural wrong guess is a single <owner/repo> (the
  # no-flag form's shape). It must still fail, print nothing on stdout, and
  # name the five positional inputs plus where the call site lives.
  bp_repo_out="$(bash "$DETECTOR" --decide-backpressure owner/repo 2>/dev/null)"
  bp_repo_rc=$?
  bp_repo_err="$(bash "$DETECTOR" --decide-backpressure owner/repo 2>&1 >/dev/null)"
  if [[ "$bp_repo_rc" -ne 0 && -z "$bp_repo_out" ]]; then
    assert_pass "--decide-backpressure <owner/repo> exits non-zero with empty stdout"
  else
    assert_fail "--decide-backpressure <owner/repo> exits non-zero with empty stdout (rc=$bp_repo_rc stdout='$bp_repo_out')"
  fi
  if [[ "$bp_repo_err" == *"looks like <owner/repo>"* && "$bp_repo_err" == *"ci.backpressure_min_in_flight"* && "$bp_repo_err" == *"steady-state.md step C"* ]]; then
    assert_pass "--decide-backpressure <owner/repo> names the five inputs and the step C call site"
  else
    assert_fail "--decide-backpressure <owner/repo> names the five inputs and the step C call site (stderr: $bp_repo_err)"
  fi
  bp_num_err="$(bash "$DETECTOR" --decide-backpressure 4 10 2 5 2>&1 >/dev/null)"
  if [[ "$bp_num_err" != *"looks like <owner/repo>"* ]]; then
    assert_pass "--decide-backpressure wrong numeric arity does not emit the owner/repo hint"
  else
    assert_fail "--decide-backpressure wrong numeric arity does not emit the owner/repo hint"
  fi
else
  assert_fail "--decide-backpressure usage handling (detector missing)"
fi
echo

# ---------------------------------------------------------------------------
# (I) steady-state.md step C — live backpressure check wiring (issue #1156).
# ---------------------------------------------------------------------------
echo "(I) steady-state.md step C — dispatch-time backpressure check wiring"
if [[ -f "$STEADY_STATE_MD" ]]; then
  assert_pass "steady-state.md exists"
  assert_contains "$STEADY_STATE_MD" "Queue-depth backpressure check" \
    "step C documents the queue-depth backpressure check"
  assert_contains "$STEADY_STATE_MD" 'issues/1156' \
    "step C cites issue #1156"
  assert_contains "$STEADY_STATE_MD" '.ci_capacity.shape == "self-hosted"' \
    "backpressure check is gated on the self-hosted shape"
  assert_contains "$STEADY_STATE_MD" '--decide-backpressure' \
    "step C calls the detector's --decide-backpressure pure decision"
  assert_contains "$STEADY_STATE_MD" 'gh-cached.sh' \
    "live queue re-read composes with the gh-cached.sh wrapper (short TTL)"
  assert_contains "$STEADY_STATE_MD" 'run list --repo "<owner/repo>" --status queued' \
    "live re-read uses the same gh run list --status queued shape as the end-of-session banner"
  assert_contains "$STEADY_STATE_MD" 'ci.backpressure_multiplier' \
    "step C reads the ci.backpressure_multiplier config knob"
  assert_contains "$STEADY_STATE_MD" 'ci.backpressure_min_in_flight' \
    "step C reads the ci.backpressure_min_in_flight config knob (escape valve)"
  assert_contains "$STEADY_STATE_MD" 'parked (CI queue backpressure:' \
    "held slot uses the existing parked (...) idle_reason convention"
  assert_contains "$STEADY_STATE_MD" 'escape valve' \
    "step C documents the escape valve — at least one worker always stays in flight"
else
  assert_fail "steady-state.md exists (missing at $STEADY_STATE_MD)"
fi
echo

# ---------------------------------------------------------------------------
# (J) ci.backpressure_multiplier / ci.backpressure_min_in_flight config knobs
#     — schema + built-in defaults (issue #1156).
# ---------------------------------------------------------------------------
echo "(J) backpressure config knobs — schema + built-in defaults"
if [[ -f "$CONFIG_SCHEMA" ]]; then
  assert_pass "shipyard.config.schema.json exists"
  assert_contains "$CONFIG_SCHEMA" '"backpressure_multiplier"' \
    "schema declares ci.backpressure_multiplier"
  assert_contains "$CONFIG_SCHEMA" '"backpressure_min_in_flight"' \
    "schema declares ci.backpressure_min_in_flight"
  if command -v jq >/dev/null 2>&1; then
    if jq empty "$CONFIG_SCHEMA" >/dev/null 2>&1; then
      assert_pass "shipyard.config.schema.json is valid JSON after the backpressure additions"
    else
      assert_fail "shipyard.config.schema.json is valid JSON after the backpressure additions"
    fi
  fi
else
  assert_fail "shipyard.config.schema.json exists (missing at $CONFIG_SCHEMA)"
fi

if [[ -f "$CONFIG_SH" ]]; then
  assert_contains "$CONFIG_SH" '"backpressure_multiplier": 5' \
    "built-in defaults set ci.backpressure_multiplier to 5"
  assert_contains "$CONFIG_SH" '"backpressure_min_in_flight": 1' \
    "built-in defaults set ci.backpressure_min_in_flight to 1"

  got="$(bash "$CONFIG_SH" get ci.backpressure_multiplier 2>/dev/null)"
  assert_equals "shipyard-config.sh get ci.backpressure_multiplier resolves to the built-in default" "5" "$got"
  got="$(bash "$CONFIG_SH" get ci.backpressure_min_in_flight 2>/dev/null)"
  assert_equals "shipyard-config.sh get ci.backpressure_min_in_flight resolves to the built-in default" "1" "$got"
else
  assert_fail "shipyard-config.sh exists (missing at $CONFIG_SH)"
fi
echo

# ---------------------------------------------------------------------------
# (K) decide_resume() — pure resume-decision truth table (issue #1402).
# ---------------------------------------------------------------------------
echo "(K) detector script — paused_on_environment resume decision truth table"
if [[ -f "$DETECTOR" ]]; then
  # decide-resume <pool_total> <queued> <multiplier> <expected> <label>
  assert_resume() {
    local got
    got="$(bash "$DETECTOR" --decide-resume "$1" "$2" "$3" 2>/dev/null)"
    assert_equals "$5" "$4" "$got"
  }

  assert_resume 4 10 5 "resume" "queued (10) under threshold (4x5=20) -> resume"
  assert_resume 4 20 5 "resume" "queued exactly at threshold (20) -> resume (strictly greater-than gate, same as decide_backpressure)"
  assert_resume 4 21 5 "held" "queued (21) over threshold (20) -> still held"
  assert_resume 0 100 5 "resume" "pool_total 0 (unreadable) -> always resume, never hold on an unread signal"
  assert_resume 19 90 5 "resume" "the #1402 repro's own numbers, before recovery (pool_total=19, threshold=95) -> resume"
  assert_resume 19 100 5 "held" "the #1402 repro's own numbers, still saturated (queued=100 > threshold=95) -> held"

  # No escape valve — decide_resume takes no in_flight argument at all, unlike
  # decide_backpressure. A high queue always holds regardless of any notion
  # of "workers already running", because by construction none are.
  assert_resume 4 21 1 "held" "no escape valve: a low multiplier (tighter threshold) still holds on a queue over it"

  # Non-numeric inputs degrade to safe defaults rather than crashing.
  got="$(bash "$DETECTOR" --decide-resume "" "" "" 2>/dev/null)"
  assert_equals "empty inputs degrade to resume (pool_total defaults to 0)" "resume" "$got"
else
  assert_fail "detect-ci-runner-capacity.sh exists (missing at $DETECTOR)"
fi
echo

# ---------------------------------------------------------------------------
# (L) --decide-resume argument-count usage handling.
# ---------------------------------------------------------------------------
echo "(L) --decide-resume usage handling"
if [[ -f "$DETECTOR" ]]; then
  bash "$DETECTOR" --decide-resume 4 10 >/dev/null 2>/tmp/detect-ci-runner-capacity-resume-usage.$$
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    assert_pass "--decide-resume with wrong arg count exits non-zero"
  else
    assert_fail "--decide-resume with wrong arg count exits non-zero (got exit 0)"
  fi
  rm -f /tmp/detect-ci-runner-capacity-resume-usage.$$
else
  assert_fail "--decide-resume usage handling (detector missing)"
fi
echo

# ---------------------------------------------------------------------------
# (M) steady-state.md — session-wide environmental pause wiring (issue #1402).
# ---------------------------------------------------------------------------
echo "(M) steady-state.md — session-wide environmental pause wiring"
if [[ -f "$STEADY_STATE_MD" ]]; then
  # steady-state.md itself carries only a pointer (the full mechanism was
  # split into environmental-pause.md to stay under the phase-file size cap
  # — issue #611 / do-work-phase-file-size.test.sh) — verify the pointer
  # exists and correctly cross-references the split file.
  assert_contains "$STEADY_STATE_MD" 'Session-wide environmental pause' \
    "step C carries a pointer to the session-wide environmental pause mechanism"
  assert_contains "$STEADY_STATE_MD" 'issues/1402' \
    "pointer cites issue #1402"
  assert_contains "$STEADY_STATE_MD" 'environmental-pause.md' \
    "pointer cross-references the split-out environmental-pause.md file"
  assert_contains "$STEADY_STATE_MD" 'watch-resume-probe.sh' \
    "pointer names the committed watch-resume-probe.sh script"
  assert_contains "$STEADY_STATE_MD" 'paused_env=<none|active>' \
    "invariant line documents the paused_env token"
else
  assert_fail "steady-state.md exists (missing at $STEADY_STATE_MD)"
fi
echo

# ---------------------------------------------------------------------------
# (M2) environmental-pause.md — the full session-wide pause mechanism
#      (split out of steady-state.md under the #611 phase-file size cap;
#      issue #1402).
# ---------------------------------------------------------------------------
echo "(M2) environmental-pause.md — full mechanism"
if [[ -f "$ENV_PAUSE_MD" ]]; then
  assert_contains "$ENV_PAUSE_MD" 'issues/1402' \
    "file cites issue #1402"
  assert_contains "$ENV_PAUSE_MD" 'Loaded from' \
    "file documents its own load site, mirroring disk-space-guard.md's split convention"
  assert_contains "$ENV_PAUSE_MD" '--decide-resume' \
    "resume decision calls the detector's --decide-resume pure decision"
  assert_contains "$ENV_PAUSE_MD" 'paused_on_environment.pause_when_in_flight_at_or_below' \
    "trigger reads the pause_when_in_flight_at_or_below config knob"
  assert_contains "$ENV_PAUSE_MD" 'watch-resume-probe.sh' \
    "arm step invokes the committed watch-resume-probe.sh script"
  assert_contains "$ENV_PAUSE_MD" 'persistent: true' \
    "Monitor call is armed persistent (needed whenever max_hours exceeds the 1h timeout_ms cap)"
  assert_contains "$ENV_PAUSE_MD" 'never a fresh' \
    "--max-wait is documented as the REMAINING time to deadline_at, never a fresh max_hours window"
  assert_contains "$ENV_PAUSE_MD" 'canonical fresh backlog fetch' \
    "resume handling re-runs the canonical fresh backlog fetch before resuming dispatch"
  assert_contains "$ENV_PAUSE_MD" 'paused_env=<none|active>' \
    "file documents the paused_env invariant-line token it feeds"
else
  assert_fail "environmental-pause.md exists (missing at $ENV_PAUSE_MD)"
fi
echo

# ---------------------------------------------------------------------------
# (N) paused_on_environment.* config knobs — schema + built-in defaults
#     (issue #1402).
# ---------------------------------------------------------------------------
echo "(N) paused_on_environment config knobs — schema + built-in defaults"
if [[ -f "$CONFIG_SCHEMA" ]]; then
  assert_contains "$CONFIG_SCHEMA" '"paused_on_environment"' \
    "schema declares the paused_on_environment block"
  assert_contains "$CONFIG_SCHEMA" '"pause_when_in_flight_at_or_below"' \
    "schema declares paused_on_environment.pause_when_in_flight_at_or_below"
  if command -v jq >/dev/null 2>&1; then
    if jq empty "$CONFIG_SCHEMA" >/dev/null 2>&1; then
      assert_pass "shipyard.config.schema.json is valid JSON after the paused_on_environment additions"
    else
      assert_fail "shipyard.config.schema.json is valid JSON after the paused_on_environment additions"
    fi
  fi
else
  assert_fail "shipyard.config.schema.json exists (missing at $CONFIG_SCHEMA)"
fi

if [[ -f "$CONFIG_SH" ]]; then
  assert_contains "$CONFIG_SH" '"paused_on_environment"' \
    "built-in defaults declare paused_on_environment"

  got="$(bash "$CONFIG_SH" get paused_on_environment.enabled 2>/dev/null)"
  assert_equals "shipyard-config.sh get paused_on_environment.enabled resolves to the built-in default" "true" "$got"
  got="$(bash "$CONFIG_SH" get paused_on_environment.max_hours 2>/dev/null)"
  assert_equals "shipyard-config.sh get paused_on_environment.max_hours resolves to the built-in default" "4" "$got"
  got="$(bash "$CONFIG_SH" get paused_on_environment.pause_when_in_flight_at_or_below 2>/dev/null)"
  assert_equals "shipyard-config.sh get paused_on_environment.pause_when_in_flight_at_or_below resolves to the built-in default" "0" "$got"
else
  assert_fail "shipyard-config.sh exists (missing at $CONFIG_SH)"
fi
echo

# ---------------------------------------------------------------------------
# (O) drain.md — termination-registry row for paused_on_environment.
# ---------------------------------------------------------------------------
echo "(O) drain.md — paused_on_environment termination-registry row"
DRAIN_MD_PATH="$repo_root/plugins/shipyard/commands/do-work/drain.md"
if [[ -f "$DRAIN_MD_PATH" ]]; then
  # shellcheck disable=SC2016  # literal markdown needle, deliberately unexpanded
  assert_contains "$DRAIN_MD_PATH" '`paused_on_environment`' \
    "termination registry includes a paused_on_environment row"
  assert_contains "$DRAIN_MD_PATH" 'watch-resume-probe.sh' \
    "registry row cross-references the resume-watch script"
else
  assert_fail "drain.md exists (missing at $DRAIN_MD_PATH)"
fi
echo

printf 'passed: %d, failed: %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
