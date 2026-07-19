#!/usr/bin/env bash
# Test: the GENERAL per-completion reap (steady-state.md step B) and the
# steady-state fix-checks pre-dispatch reap (dispatch-rules.md 2d) both
# force-reap `peer-alive` locks instead of deferring on them.
#
# Background — issue #771: issue #576 taught two call sites to force-reap
# on `peer-alive` — the A.1 issue-work `shipped`-only immediate-reap, and
# the drain-phase pre-dispatch reap (restricted to `do-work/issue-*`
# branches). It left two OTHER call sites still conservatively deferring
# on `peer-alive` with no override at all:
#
#   1. steady-state.md step B — the general-purpose per-completion reap
#      that actually covers fix-checks (`green`/`blocked`), fix-rebase
#      (`rebased`/`blocked`), the synthetic-divert `shipped` variants, and
#      any mode's `blocked` return. A.1's force-reap only ever applies to
#      the issue-work `shipped` path, so every other mode's completion
#      still deferred here.
#   2. dispatch-rules.md's 2d pre-dispatch reap — the steady-state (not
#      drain) fix-checks-only dispatch site. Unlike drain's #370 reap,
#      this site had NO force-reap override at all.
#
# The result: a re-dispatched fix-checks-only or fix-rebase worker bailed
# with "head branch <head> locked in another worktree" against a PRIOR
# worker's completed-but-still-`peer-alive`-classified worktree — reported
# twice in one session (#2598, #2701) per issue #771's repro, each
# requiring a manual `git worktree remove --force` before the re-dispatch
# would take.
#
# This is the regression guard: if either force-reap is removed or
# reverted to a defer, the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/completion-reap-force-771.test.sh

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
dispatch_rules_path="$repo_root/plugins/shipyard/commands/do-work/dispatch-rules.md"
worktree_reap_path="$repo_root/plugins/shipyard/scripts/worktree-reap.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_file_exists() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (missing: %s)\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail+1))
  fi
}

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s:\n    %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to NOT find in %s:\n    %s\n' "$file" "$needle"
    fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  fi
}

echo ""
echo "Test: step B + steady-state pre-dispatch force-reap on peer-alive (#771 regression guard)"
echo ""

assert_file_exists "$steady_state_path"     "steady-state.md exists"
assert_file_exists "$dispatch_rules_path"   "dispatch-rules.md exists"
assert_file_exists "$worktree_reap_path"    "worktree-reap.sh exists"

echo ""
echo "steady-state.md step B — force-reap on peer-alive"
echo ""

# Step B must reference issue #771 inline.
assert_contains "$steady_state_path" \
  "issues/771" \
  "step B references issue #771"

# The old defensive-defer comment (the exact pre-#771 prose) must be gone.
assert_not_contains "$steady_state_path" \
  "Defensive: peer-alive on our own just-returned agent shouldn't" \
  "step B no longer carries the old defensive-defer comment"

# steady-state.md must not have ANY --action deferred call left at all —
# step B's reap block now issues a single unconditional --action reaped
# call with a classification override, not a branching defer/reap pair.
# (dispatch-rules.md's own 2d block is checked separately below; drain.md's
# non-issue-work conservative defer is intentionally untouched and out of
# scope for this file's assertions.)
assert_not_contains "$steady_state_path" \
  "--action deferred" \
  "steady-state.md has no remaining --action deferred call (step B's was the last one)"

# Step B's reap block must classify-override to peer-alive-force.
# shellcheck disable=SC2016  # literal needles — must NOT expand $classification / $local_classification
assert_contains "$steady_state_path" \
  'local_classification="$classification"' \
  "step B overrides classification via local_classification"

# shellcheck disable=SC2016  # literal needle — must NOT expand $classification
assert_contains "$steady_state_path" \
  '[ "$classification" = "peer-alive" ] && local_classification="peer-alive-force"' \
  "step B's override maps peer-alive -> peer-alive-force"

# Step B's --action reaped call must use the overridden classification
# variable, not the raw classify-lock output.
# shellcheck disable=SC2016  # literal needle — must NOT expand $local_classification
assert_contains "$steady_state_path" \
  '--classification "$local_classification"' \
  "step B's reap call uses the overridden classification variable"

echo ""
echo "dispatch-rules.md 2d pre-dispatch reap — force-reap on peer-alive"
echo ""

# 2d must reference issue #771 inline.
assert_contains "$dispatch_rules_path" \
  "issues/771" \
  "dispatch-rules.md 2d references issue #771"

# The old conservative-defer branch (unique phrasing) must be gone.
assert_not_contains "$dispatch_rules_path" \
  "A genuinely-live non-orchestrator PID holds the lock. Don't yank it." \
  "dispatch-rules.md 2d no longer carries the old conservative-defer branch"

# The prose must no longer claim the peer-alive defer is "intentionally
# conservative" without qualification — the block now force-reaps.
assert_not_contains "$dispatch_rules_path" \
  "The \`peer-alive\` defer is intentionally conservative: it preserves the exact pre-#368 behavior" \
  "dispatch-rules.md 2d no longer describes peer-alive as intentionally-conservative-deferred"

# dispatch-rules.md must not have ANY --action deferred call left either.
assert_not_contains "$dispatch_rules_path" \
  "--action deferred" \
  "dispatch-rules.md has no remaining --action deferred call (2d's was the only one)"

# 2d's reap block must classify-override to peer-alive-force, same idiom
# as step B.
# shellcheck disable=SC2016  # literal needles — must NOT expand $classification / $local_classification
assert_contains "$dispatch_rules_path" \
  'local_classification="$classification"' \
  "dispatch-rules.md 2d overrides classification via local_classification"

# shellcheck disable=SC2016  # literal needle — must NOT expand $classification
assert_contains "$dispatch_rules_path" \
  '[ "$classification" = "peer-alive" ] && local_classification="peer-alive-force"' \
  "dispatch-rules.md 2d's override maps peer-alive -> peer-alive-force"

# 2d's --action reaped call must use the overridden classification variable.
# shellcheck disable=SC2016  # literal needle — must NOT expand $local_classification
assert_contains "$dispatch_rules_path" \
  '--classification "$local_classification"' \
  "dispatch-rules.md 2d's reap call uses the overridden classification variable"

echo ""
echo "Runtime: worktree-reap.sh — peer-alive-force phase support at both new call sites"
echo ""

tmp_shipyard_home=$(mktemp -d)
export SHIPYARD_HOME="$tmp_shipyard_home"

# Exercise the reap subcommand exactly as step B's overridden call would —
# classification=peer-alive-force, phase=steady-state-B-completion.
audit_log="$tmp_shipyard_home/reap-audit.jsonl"
reap_out=$(bash "$worktree_reap_path" reap \
  --action reaped \
  --worktree-path "/tmp/nonexistent-771-test-b" \
  --worktree-name "agent-test-771-b" \
  --session-id "test-session-771-b" \
  --classification "peer-alive-force" \
  --lock-pid 0 \
  --phase "steady-state-B-completion" \
  --skip-remove 2>&1)
reap_rc=$?

if [[ $reap_rc -eq 0 ]]; then
  printf '  %sPASS%s  reap --classification peer-alive-force --phase steady-state-B-completion exits 0\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  reap returned exit %d (output: %s)\n' "$RED" "$RESET" "$reap_rc" "$reap_out"
  fail=$((fail+1))
fi

if [[ -f "$audit_log" ]] && grep -qF '"phase":"steady-state-B-completion"' "$audit_log" \
   && grep -qF '"classification":"peer-alive-force"' "$audit_log"; then
  printf '  %sPASS%s  audit-log entry carries phase=steady-state-B-completion + classification=peer-alive-force\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  audit-log missing expected step-B fields at %s\n' "$RED" "$RESET" "$audit_log"
  [[ -f "$audit_log" ]] && printf '    audit-log content:\n%s\n' "$(cat "$audit_log")"
  fail=$((fail+1))
fi

# Exercise the reap subcommand exactly as dispatch-rules.md 2d's overridden
# call would — classification=peer-alive-force, phase=steady-state-pre-dispatch.
rm -f "$audit_log"
reap_out2=$(bash "$worktree_reap_path" reap \
  --action reaped \
  --worktree-path "/tmp/nonexistent-771-test-2d" \
  --worktree-name "agent-test-771-2d" \
  --session-id "test-session-771-2d" \
  --classification "peer-alive-force" \
  --lock-pid 0 \
  --phase "steady-state-pre-dispatch" \
  --skip-remove 2>&1)
reap_rc2=$?

if [[ $reap_rc2 -eq 0 ]]; then
  printf '  %sPASS%s  reap --classification peer-alive-force --phase steady-state-pre-dispatch exits 0\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  2d reap returned exit %d (output: %s)\n' "$RED" "$RESET" "$reap_rc2" "$reap_out2"
  fail=$((fail+1))
fi

if [[ -f "$audit_log" ]] && grep -qF '"phase":"steady-state-pre-dispatch"' "$audit_log" \
   && grep -qF '"classification":"peer-alive-force"' "$audit_log"; then
  printf '  %sPASS%s  audit-log entry carries phase=steady-state-pre-dispatch + classification=peer-alive-force\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  audit-log missing expected 2d fields at %s\n' "$RED" "$RESET" "$audit_log"
  [[ -f "$audit_log" ]] && printf '    audit-log content:\n%s\n' "$(cat "$audit_log")"
  fail=$((fail+1))
fi

# Cleanup
rm -rf "$tmp_shipyard_home"
unset SHIPYARD_HOME

echo ""
echo "Results: $pass passed, $fail failed"
if (( fail > 0 )); then
  exit 1
fi
exit 0
