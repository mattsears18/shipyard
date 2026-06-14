#!/usr/bin/env bash
# Test: completed issue-work agent worktrees are force-reaped during drain
# even when the lock classifies as peer-alive.
#
# Background — issue #576: during the end-of-session drain, dispatching a
# fix-checks-only or fix-rebase worker against a `do-work/issue-<N>` PR
# branch repeatedly failed because the original issue-work agent's worktree
# was still checked out on that branch. The drain's pre-dispatch head-branch
# reap conservatively deferred on `peer-alive` locks — but a completed
# issue-work worktree is logically done (the worker returned `shipped`) and
# should be force-reaped, not deferred. The same gap existed in steady-
# state.md's A.1 `shipped` immediate-reap path.
#
# This is the regression guard: if either the A.1 `shipped` path or the
# drain pre-dispatch reap loses its force-reap-on-peer-alive semantics for
# completed issue-work worktrees, the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/drain-completed-worktree-reap.test.sh

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
drain_path="$repo_root/plugins/shipyard/commands/do-work/drain.md"
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
echo "Test: drain + A.1 shipped force-reap on peer-alive (#576 regression guard)"
echo ""

# --- File existence ---
assert_file_exists "$steady_state_path" "steady-state.md exists"
assert_file_exists "$drain_path"        "drain.md exists"
assert_file_exists "$worktree_reap_path" "worktree-reap.sh exists"

echo ""
echo "steady-state.md A.1 shipped path — force-reap on peer-alive"
echo ""

# A.1 shipped path must document the peer-alive-force override and reference #576.
assert_contains "$steady_state_path" \
  "peer-alive-force" \
  "A.1 shipped path documents peer-alive-force classification"

assert_contains "$steady_state_path" \
  "#576" \
  "A.1 shipped path references issue #576"

# The A.1 shipped path must NOT still contain the old defer-on-peer-alive
# commentary (the "If we see it anyway, defer" guard was removed in #576).
assert_not_contains "$steady_state_path" \
  "If we see it anyway, defer — end-of-session" \
  "A.1 shipped path no longer defers on peer-alive (old commentary removed)"

# The old --action deferred block for peer-alive inside the shipped reap loop
# must be gone (it was replaced with force-reap).
# We check for the specific audit-log reason string that the old defer wrote.
assert_not_contains "$steady_state_path" \
  '"reason "peer-alive"' \
  "A.1 shipped path no longer writes peer-alive reason to audit log (old defer removed)"

# The force-reap rationale must explain the drain context so a reader
# understands why peer-alive is safe to override here.
assert_contains "$steady_state_path" \
  "drain-phase" \
  "A.1 shipped path explains drain-phase motivation for force-reap"

# The peer-alive-force classification must be audited so it's traceable.
assert_contains "$steady_state_path" \
  "peer-alive-force" \
  "A.1 shipped path uses peer-alive-force classification for audit log"

echo ""
echo "drain.md pre-dispatch reap — force-reap for completed issue-work worktrees"
echo ""

# drain.md pre-dispatch reap must reference #576.
assert_contains "$drain_path" \
  "#576" \
  "drain.md pre-dispatch reap references issue #576"

# drain.md must document the do-work/issue-* branch-pattern check that
# distinguishes completed issue-work worktrees from live fix-checks workers.
assert_contains "$drain_path" \
  "do-work/issue-*" \
  "drain.md pre-dispatch reap checks for do-work/issue-* branch pattern"

# drain.md must use the peer-alive-force-drain classification to distinguish
# the force-reap path from the conservative defer path.
assert_contains "$drain_path" \
  "peer-alive-force-drain" \
  "drain.md pre-dispatch reap uses peer-alive-force-drain classification"

# drain.md must preserve the conservative defer for non-issue-work branches
# (live fix-checks / fix-rebase workers must not be yanked).
assert_contains "$drain_path" \
  "peer-alive" \
  "drain.md pre-dispatch reap still preserves peer-alive conservative defer"

# drain.md's closing commentary must acknowledge both classification values
# so an operator reading reap-audit.jsonl can interpret the entries.
assert_contains "$drain_path" \
  '"peer-alive-force-drain"' \
  "drain.md closing commentary names peer-alive-force-drain for audit log"

# drain.md's failure-mode prose must be updated to remove the erroneous
# claim that A.1 'shipped' deferred on peer-alive (it now force-reaps).
assert_not_contains "$drain_path" \
  "A.1 immediate-reap (#282) deferred on \`peer-alive\`" \
  "drain.md failure-mode prose updated (no longer blames A.1 peer-alive defer)"

echo ""
echo "drain.md force-reap rationale — why it's safe"
echo ""

# drain.md must explain why force-reap is safe for completed issue-work
# worktrees at drain time (workers have returned their terminal strings).
assert_contains "$drain_path" \
  "already returned their terminal strings" \
  "drain.md explains force-reap safety: workers have already returned"

# drain.md must reference A.0.5's posture as the precedent for
# force-reaping on peer-alive (the same rationale applies).
assert_contains "$drain_path" \
  "A.0.5" \
  "drain.md cites A.0.5 as precedent for force-reap-on-peer-alive"

echo ""
echo "Runtime: worktree-reap.sh — peer-alive-force-drain phase support"
echo ""

# Exercise the reap subcommand with classification=peer-alive-force-drain
# and phase=drain-pre-dispatch. We use --skip-remove so no actual worktree
# removal runs; we only validate that the subcommand exits 0 and writes
# the audit log entry with the expected classification and phase.
tmp_shipyard_home=$(mktemp -d)
export SHIPYARD_HOME="$tmp_shipyard_home"

reap_out=$(bash "$worktree_reap_path" reap \
  --action reaped \
  --worktree-path "/tmp/nonexistent-576-test" \
  --worktree-name "agent-test-576" \
  --session-id "test-session-576" \
  --classification "peer-alive-force-drain" \
  --lock-pid 0 \
  --phase "drain-pre-dispatch" \
  --skip-remove 2>&1)
reap_rc=$?

if [[ $reap_rc -eq 0 ]]; then
  printf '  %sPASS%s  reap --classification peer-alive-force-drain --phase drain-pre-dispatch exits 0\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  reap returned exit %d (output: %s)\n' "$RED" "$RESET" "$reap_rc" "$reap_out"
  fail=$((fail+1))
fi

audit_log="$tmp_shipyard_home/reap-audit.jsonl"
if [[ -f "$audit_log" ]] && grep -qF '"phase":"drain-pre-dispatch"' "$audit_log"; then
  printf '  %sPASS%s  audit-log entry carries "phase":"drain-pre-dispatch"\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  audit-log missing drain-pre-dispatch phase at %s\n' "$RED" "$RESET" "$audit_log"
  [[ -f "$audit_log" ]] && printf '    audit-log content:\n%s\n' "$(cat "$audit_log")"
  fail=$((fail+1))
fi

if [[ -f "$audit_log" ]] && grep -qF '"classification":"peer-alive-force-drain"' "$audit_log"; then
  printf '  %sPASS%s  audit-log entry carries "classification":"peer-alive-force-drain"\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  audit-log missing peer-alive-force-drain classification at %s\n' "$RED" "$RESET" "$audit_log"
  [[ -f "$audit_log" ]] && printf '    audit-log content:\n%s\n' "$(cat "$audit_log")"
  fail=$((fail+1))
fi

# Also exercise the peer-alive-force classification used by the A.1 path.
rm -f "$audit_log"
reap_out2=$(bash "$worktree_reap_path" reap \
  --action reaped \
  --worktree-path "/tmp/nonexistent-576-test-a1" \
  --worktree-name "agent-test-576-a1" \
  --session-id "test-session-576-a1" \
  --classification "peer-alive-force" \
  --lock-pid 0 \
  --phase "steady-state-A1-shipped" \
  --skip-remove 2>&1)
reap_rc2=$?

if [[ $reap_rc2 -eq 0 ]]; then
  printf '  %sPASS%s  reap --classification peer-alive-force --phase steady-state-A1-shipped exits 0\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  A.1 reap returned exit %d (output: %s)\n' "$RED" "$RESET" "$reap_rc2" "$reap_out2"
  fail=$((fail+1))
fi

if [[ -f "$audit_log" ]] && grep -qF '"classification":"peer-alive-force"' "$audit_log"; then
  printf '  %sPASS%s  A.1 audit-log entry carries "classification":"peer-alive-force"\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  A.1 audit-log missing peer-alive-force classification at %s\n' "$RED" "$RESET" "$audit_log"
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
