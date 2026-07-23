#!/usr/bin/env bash
# Test: steady-state.md documents a `stalled` (non-terminal-return) branch,
# distinct from `blocked`, with a worktree-state check that distinguishes
# resume-worthy from genuinely-failed, a bounded resume path (foreground
# re-run, no re-arming the background wait, retry cap), and
# `shipyard:worker-preamble` forbids a worker from suspending itself
# awaiting a Monitor/background notification for a result it needs to finish.
#
# Background — issue #813: a dispatched worker backgrounded a test suite,
# went idle awaiting a Monitor notification, and its task ended — so the
# notification it was waiting on could never arrive. It returned a
# numbered, future-tense plan ("I'm now waiting for the Monitor task…
# Once it reports green, I'll proceed to: 1. … 2. … 3. … 4. …") with ZERO
# commits but a complete, correct working tree, one `git commit` away from
# shipping. steady-state.md's A.1 return vocabulary had no branch for this
# shape — a literal reading falls through to `blocked`, stranding
# near-complete work. The fix adds a `stalled` outcome, detected and
# resolved at A.0.5 (before A.1 ever runs), that resumes the SAME worker
# in place (bounded by a retry cap) rather than mislabeling it `blocked`.
#
# Extended by issues #838 / #833: the same underlying gap — a worker stops
# without a terminal return and the orchestrator's completion handling reaps
# its worktree, destroying the only copy of the work — recurred via two more
# triggers (a `status: completed` return with unrecognized free text, and a
# harness-reported `status: failed` stall-watchdog kill). The fix folds both
# into this same A.0.5 flow: `status: failed` routes through unconditionally
# regardless of return text, the resume mechanism prefers `SendMessage` to
# the stalled agent's own `agent_id` (carrying the orchestrator's own
# verified git reading rather than the worker's self-report), the retry cap
# tightens from 2 to 1, and every occurrence is recorded in a new
# `stalled_dispatches` ledger surfaced in the end-of-session summary.
#
# This test is the regression guard: if the `stalled` branch, its
# worktree-state check, its resume mechanics, its retry cap, its
# `stalled_dispatches` ledger, its `harness_status: failed` trigger, or the
# worker-preamble's self-suspension prohibition are removed or lose their
# load-bearing semantics, the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/stalled-worker-resume-813.test.sh

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

steady_state_path="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
skill_path="$repo_root/plugins/shipyard/skills/worker-preamble/SKILL.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_file_exists() {
  local path="$1" label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (missing: %s)\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail+1))
  fi
}

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

assert_section_ordering() {
  local file="$1" before="$2" after="$3" label="$4"
  local before_line after_line
  before_line=$(grep -nF -- "$before" "$file" | head -1 | cut -d: -f1)
  after_line=$(grep -nF -- "$after" "$file" | head -1 | cut -d: -f1)
  if [[ -z "$before_line" ]]; then
    printf '  %sFAIL%s  %s (could not find before-marker: %s)\n' "$RED" "$RESET" "$label" "$before"
    fail=$((fail+1))
    return
  fi
  if [[ -z "$after_line" ]]; then
    printf '  %sFAIL%s  %s (could not find after-marker: %s)\n' "$RED" "$RESET" "$label" "$after"
    fail=$((fail+1))
    return
  fi
  if (( before_line < after_line )); then
    printf '  %sPASS%s  %s (before @ line %d, after @ line %d)\n' "$GREEN" "$RESET" "$label" "$before_line" "$after_line"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (expected before-marker before after-marker; got before @ %d, after @ %d)\n' "$RED" "$RESET" "$label" "$before_line" "$after_line"
    fail=$((fail+1))
  fi
}

echo ""
echo "Test: stalled-worker detection + resume (A.0.5 / A.1) — issue #813 regression guard"
echo ""

assert_file_exists "$steady_state_path" "steady-state.md exists"
assert_file_exists "$skill_path" "worker-preamble SKILL.md exists"

# 1) The `stalled` outcome is named and distinguished from `blocked` in A.1's
#    return-vocabulary discussion.
assert_contains "$steady_state_path" \
  "A \`stalled\` return is not classified here" \
  "A.1 documents the stalled outcome"
assert_contains "$steady_state_path" \
  "it is never \`blocked\`" \
  "A.1 states a stalled return is never blocked"
assert_contains "$steady_state_path" \
  "\`stalled\` must never fall through to the \`blocked #<N>\` branch below" \
  "A.1 explicitly forbids stalled falling through to blocked"

# 2) The A.0.5 stalled-worker check is documented with its own name/heading.
assert_contains "$steady_state_path" \
  "Stalled-worker detection and resume — the FIRST check inside this step" \
  "A.0.5 documents the stalled-worker check as the first check in the step"
assert_contains "$steady_state_path" \
  "This is a distinct, non-terminal outcome — call it \`stalled\`" \
  "A.0.5 names the stalled outcome explicitly"

# 3) The worktree-state check that distinguishes resume-worthy from
#    genuinely-failed is documented (the mechanical grounding for the
#    pending-intent judgment call).
assert_contains "$steady_state_path" \
  "The mechanical check that grounds the judgment call" \
  "A.0.5 documents the mechanical worktree-state check"
assert_contains "$steady_state_path" \
  "resume-worthy" \
  "A.0.5 names the resume-worthy classification"
assert_contains "$steady_state_path" \
  "not resume-worthy" \
  "A.0.5 names the not-resume-worthy classification"

# 4) Pending-intent detection is described as judgment, not a keyword list —
#    per the design note in #813 ("don't make the detector a brittle
#    keyword list").
assert_contains "$steady_state_path" \
  "not a keyword list" \
  "A.0.5 frames pending-intent detection as judgment, not a keyword list"
assert_contains "$steady_state_path" \
  "pending intent" \
  "A.0.5 names the pending-intent detection signal"

# 5) The resume path — re-run in the foreground, never re-arm the background
#    wait, and prefer resuming the SAME agent (SendMessage) over a fresh
#    dispatch when one is live and addressable (#838/#833).
assert_contains "$steady_state_path" \
  "never re-arm the same background wait" \
  "A.0.5 documents the resume path's never-re-arm-the-background-wait contract"
assert_contains "$steady_state_path" \
  "re-run the blocking command (the test suite, the long-running check) synchronously in the foreground" \
  "A.0.5 documents the resume message's foreground-rerun instruction"
assert_contains "$steady_state_path" \
  "re-enter the SAME worktree with a fresh call" \
  "A.0.5 documents resuming into the same worktree (not a fresh one)"
assert_contains "$steady_state_path" \
  "do not \`git worktree add\` again and do not create a new branch" \
  "A.0.5 documents that resume reuses the existing worktree and branch"
assert_contains "$steady_state_path" \
  "send a follow-up message to that exact agent via \`SendMessage\` targeting its \`agent_id\`" \
  "A.0.5 documents SendMessage-based resume for a live Agent-tool subagent (#838/#833)"
assert_contains "$steady_state_path" \
  "the orchestrator's own verified reading from step 2" \
  "A.0.5 documents the resume message carrying the orchestrator's own git reading, not the worker's self-report"

# 6) The resume path is bounded by a retry cap of 1 (tightened from 2 by
#    #838/#833) — a second stall hands back rather than looping.
assert_contains "$steady_state_path" \
  "Bound it first — retry cap 1 per target per session" \
  "A.0.5 documents the retry cap"
assert_contains "$steady_state_path" \
  "stalled_resume_counts" \
  "A.0.5 documents the per-target resume counter"
assert_contains "$steady_state_path" \
  "Hand it back" \
  "A.0.5 documents handing back once the cap is exhausted, rather than looping"
assert_contains "$steady_state_path" \
  "falling through to the crash-recovery path below" \
  "A.0.5 documents falling through to crash-recovery once the cap is exhausted"

# 7) Every occurrence — resumed, handed-back, or dropped-clean — is recorded
#    in the session-local stalled_dispatches ledger (#838/#833), mirroring
#    dispatch_denials (#718) / operator_denials (#746).
assert_contains "$steady_state_path" \
  "stalled_dispatches" \
  "A.0.5 documents the stalled_dispatches ledger"
assert_contains "$steady_state_path" \
  "outcome: \"resumed\"" \
  "A.0.5 documents the resumed outcome"
assert_contains "$steady_state_path" \
  "outcome: \"handed-back\"" \
  "A.0.5 documents the handed-back outcome"
assert_contains "$steady_state_path" \
  "\"dropped-clean\"" \
  "A.0.5 documents the dropped-clean outcome"
orchestrator_state_ref_path="$repo_root/plugins/shipyard/commands/do-work/orchestrator-state-reference.md"
assert_file_exists "$orchestrator_state_ref_path" "orchestrator-state-reference.md exists"
assert_contains "$orchestrator_state_ref_path" \
  "\`stalled_dispatches\`" \
  "orchestrator-state-reference.md documents the stalled_dispatches struct (#838/#833)"
cleanup_summary_path="$repo_root/plugins/shipyard/commands/do-work/cleanup-summary.md"
assert_contains "$cleanup_summary_path" \
  "Stalled dispatches (#838/#833)" \
  "cleanup-summary.md surfaces a Stalled dispatches line in the end-of-session summary"
dont_path="$repo_root/plugins/shipyard/commands/do-work/dont.md"
assert_contains "$dont_path" \
  "Don't reap a worker's worktree on a non-terminal or \`failed\` stop without first inspecting it for unpushed work" \
  "dont.md forbids reaping on a non-terminal or failed stop without first inspecting (#838/#833)"

# 8) A harness-reported status: failed (the #833 stall-watchdog trigger)
#    routes through the same inspect-before-reap flow UNCONDITIONALLY,
#    regardless of what the accompanying return text says.
assert_contains "$steady_state_path" \
  "harness_status" \
  "A.0.5 documents the harness_status signal"
assert_contains "$steady_state_path" \
  "the harness status is \`failed\`" \
  "A.0.5's detection prose names status: failed as an independent non-terminal trigger"

# 7) Cross-reference from A.1 to A.0.5 is present and correctly ordered:
#    A.0.5's stalled check must precede A.1 in document order (it must run
#    first, every reconcile turn).
assert_section_ordering "$steady_state_path" \
  "Stalled-worker detection and resume — the FIRST check inside this step" \
  "#### A.1. Parse the return string" \
  "A.0.5's stalled-worker check precedes A.1 in document order"
assert_section_ordering "$steady_state_path" \
  "#### A.1. Parse the return string" \
  "A \`stalled\` return is not classified here" \
  "A.1's stalled cross-reference appears within the A.1 section"

# 8) worker-preamble forbids self-suspension on a Monitor/background
#    notification for a result the worker needs to finish.
assert_contains "$skill_path" \
  "You are forbidden from suspending yourself awaiting a \`Monitor\` / background-process notification" \
  "worker-preamble forbids self-suspension awaiting a Monitor/background notification"
assert_contains "$skill_path" \
  "Backgrounding is for work you will not wait on" \
  "worker-preamble states backgrounding is only for work you won't wait on"
assert_contains "$skill_path" \
  "#813" \
  "worker-preamble cites #813 inline"

echo ""
echo "Runtime: pending-intent vs. terminal classification (issue #813 AC — a narrative"
echo "non-terminal return must NOT classify as blocked)"
echo ""

# A minimal reference implementation of the documented classification, for
# test purposes only — mirrors steady-state.md's terminal-prefix check plus
# the pending-intent judgment call described above. Not the production
# classifier (that's a live LLM reading the text per A.0.5's prose), but a
# deterministic stand-in so this test can assert the *shape* of the
# classification without an LLM in the loop: an unrecognized/narrative
# return must resolve to "stalled" or "crash" — never "blocked".
classify_return() {
  local text="$1"
  case "$text" in
    shipped*|green*|noop:*|rebased*|reaped:*)
      echo "terminal-non-blocked"
      return
      ;;
    blocked*)
      echo "blocked"
      return
      ;;
  esac
  # Non-terminal: pending-intent heuristic (future tense / "waiting for" /
  # numbered plan) vs. crash-like (empty / API Error / no such markers).
  case "$text" in
    *"waiting for"*|*"I'll proceed"*|*"I'm now"*|*"once it"*|*"Once it"*)
      echo "stalled"
      return
      ;;
  esac
  if [[ -z "$text" ]]; then
    echo "crash"
    return
  fi
  case "$text" in
    "API Error:"*|"Error:"*)
      echo "crash"
      return
      ;;
  esac
  echo "crash"
}

assert_classification() {
  local text="$1" expected="$2" label="$3"
  local got
  got=$(classify_return "$text")
  if [[ "$got" == "$expected" ]]; then
    printf '  %sPASS%s  %s (classified: %s)\n' "$GREEN" "$RESET" "$label" "$got"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (expected: %s, got: %s)\n' "$RED" "$RESET" "$label" "$expected" "$got"
    fail=$((fail+1))
  fi
}

# The exact repro shape from #813's live session.
repro_text="I've completed all the work possible without the test results. I'm now waiting for the Monitor task to notify me that the full test suite (background PID 18501) has completed. Once it reports green, I'll proceed to: 1. Remove the scratch file 2. Stage and commit 3. Push 4. Open a PR"
assert_classification "$repro_text" "stalled" \
  "the #813 repro's narrative future-tense return classifies as stalled, NOT blocked"

assert_classification "blocked #813: ambiguous scope" "blocked" \
  "a genuine deliberate blocked return still classifies as blocked"

assert_classification "shipped #813 via PR #900" "terminal-non-blocked" \
  "a genuine shipped return still classifies as terminal-non-blocked"

assert_classification "" "crash" \
  "an empty return (subprocess died) classifies as crash, NOT blocked"

assert_classification "API Error: The socket connection was closed unexpectedly" "crash" \
  "an API Error return classifies as crash, NOT blocked"

echo ""
echo "Results: $pass passed, $fail failed"
if (( fail > 0 )); then
  exit 1
fi
exit 0
