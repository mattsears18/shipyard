#!/usr/bin/env bash
# Test: the post-return worktree reap step (A.0.5) is documented in
# commands/do-work/steady-state.md with the crash-detection contract,
# the worktree-reap.sh helper references, and the load-bearing
# `peer-alive → still reap` override that distinguishes it from step B.
#
# Background — issue #358: when an agent crashes mid-flight (API socket
# error, harness phantom re-fire per #317, etc.), step B's per-completion
# reap defers on `peer-alive` classifications — leaving the worktree
# locked until end-of-session because the agent's `claude` subprocess
# remained alive past the harness's `task-notification`. The fix adds a
# crash-aware A.0.5 sub-step that fires BEFORE A.1's return-string
# parsing and reaps on every classification including peer-alive,
# closing the worktree-leak window step B's defensive defer leaves open.
#
# This test is the regression guard: if the A.0.5 step is removed,
# renamed, or loses its load-bearing semantics (the peer-alive override,
# the crash-prefix detection, the worktree-reap.sh helper calls), the
# test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/post-return-reap-A05.test.sh

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
    printf '    expected to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

assert_section_ordering() {
  local file="$1"
  local before="$2"
  local after="$3"
  local label="$4"
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

# Run reap helper subcommand with a tempfile and check classification (used
# below to assert the helper still supports the subcommand shapes A.0.5
# depends on, in case the helper itself drifts).
run_classify_lock() {
  local lock_content="$1"
  local tmp
  tmp=$(mktemp)
  printf '%s' "$lock_content" > "$tmp"
  bash "$worktree_reap_path" classify-lock "$tmp" 2>/dev/null
  local rc=$?
  rm -f "$tmp"
  return $rc
}

echo ""
echo "Test: post-return worktree reap (A.0.5) — issue #358 regression guard"
echo ""

# 1) The spec files we depend on exist.
assert_file_exists "$steady_state_path" "steady-state.md exists"
assert_file_exists "$worktree_reap_path" "worktree-reap.sh exists"

# 2) The A.0.5 step is documented by name with the canonical header.
assert_contains "$steady_state_path" \
  "#### A.0.5. Post-return worktree reap for crashed / narrative-non-terminal returns" \
  "A.0.5 header present"

# 3) The issue is referenced inline so a reader can trace the rationale.
assert_contains "$steady_state_path" \
  "Closes [#358]" \
  "A.0.5 names issue #358 inline"

# 4) The crash-detection contract is documented — the six valid terminal prefixes
#    must all appear in the prefix-check guidance.
assert_contains "$steady_state_path" \
  "shipped*|green*|noop:*|blocked*|rebased*|reaped:*" \
  "A.0.5 prefix check enumerates all six terminal prefixes"

# 5) The crash-like shapes the user might encounter are named (API Error,
#    empty, narrative). These are documentation contract — the prose tells
#    the orchestrator what to recognize.
assert_contains "$steady_state_path" \
  "API Error:" \
  "A.0.5 names \"API Error:\" as a crash-like shape"
assert_contains "$steady_state_path" \
  "narrative" \
  "A.0.5 names narrative status updates as crash-like"

# 6) The worktree-reap.sh helper is invoked via the two canonical subcommands
#    the orchestrator's other reap paths use.
assert_contains "$steady_state_path" \
  "scripts/worktree-reap.sh\" \\" \
  "A.0.5 invokes worktree-reap.sh (line-continuation form)"
assert_contains "$steady_state_path" \
  "classify-lock" \
  "A.0.5 calls classify-lock"
assert_contains "$steady_state_path" \
  '--phase "reconcile-A.0.5"' \
  "A.0.5 reap call carries --phase reconcile-A.0.5"

# 7) The load-bearing peer-alive override is documented — this is the key
#    difference from step B (which defers on peer-alive). Removing it
#    re-introduces the #358 failure mode.
assert_contains "$steady_state_path" \
  "peer-alive" \
  "A.0.5 names peer-alive classification"
assert_contains "$steady_state_path" \
  "still reap" \
  "A.0.5 documents the still-reap override on crash returns"

# 8) The SHIPYARD_ORCHESTRATOR_PID bootstrap is preserved (same idiom as
#    step B / step A.1's shipped path) — without it, classify-lock can
#    mis-classify the lock as peer-alive in subagent-invocation cases.
assert_contains "$steady_state_path" \
  "SHIPYARD_ORCHESTRATOR_PID" \
  "A.0.5 bootstraps SHIPYARD_ORCHESTRATOR_PID"
assert_contains "$steady_state_path" \
  "detect-orchestrator-pid" \
  "A.0.5 uses detect-orchestrator-pid to bootstrap the env var"

# 9) Step ordering — A.0.5 must come AFTER A.0 (token attribution) and
#    BEFORE A.1 (return-string parsing). The dispatch prompt makes this
#    explicit and the orchestrator's working memory depends on `agent_id`
#    still being in `.in_flight.<slot>` (slot release is step B).
assert_section_ordering "$steady_state_path" \
  "#### A.0. Attribute the dispatch's token usage" \
  "#### A.0.5. Post-return worktree reap for crashed / narrative-non-terminal returns" \
  "A.0.5 follows A.0 in document order"
assert_section_ordering "$steady_state_path" \
  "#### A.0.5. Post-return worktree reap for crashed / narrative-non-terminal returns" \
  "#### A.1. Parse the return string" \
  "A.0.5 precedes A.1 in document order"

# 10) Interaction with step B is documented — A.0.5 does NOT replace step B;
#     it fires earlier on crash returns. The duplicate-reap is intentionally
#     harmless.
assert_contains "$steady_state_path" \
  "step B" \
  "A.0.5 names step B in the interaction discussion"
assert_contains "$steady_state_path" \
  "duplicate-reap is harmless" \
  "A.0.5 documents the duplicate-reap-is-harmless invariant"

# 11) Audit-log phase contract — the new phase string must be documented
#     so the reap-audit.jsonl consumer (operator or future tooling) can
#     filter on it.
assert_contains "$steady_state_path" \
  '"phase":"reconcile-A.0.5"' \
  "A.0.5 documents the reap-audit.jsonl phase value"

# 12) Helper-runtime sanity gate — the classify-lock subcommand the spec
#     calls is still implemented in worktree-reap.sh. If the helper drifts
#     (e.g., subcommand rename), this test catches it independently of the
#     spec assertions above.
echo ""
echo "Runtime: worktree-reap.sh subcommand sanity"
echo ""

# A non-existent lock file → no-lock (the path A.0.5 hits when the
# worktree's already been reaped by a concurrent path).
nolock_out=$(bash "$worktree_reap_path" classify-lock /tmp/this-file-does-not-exist-358 2>/dev/null)
if [[ "$nolock_out" == "no-lock" ]]; then
  printf '  %sPASS%s  classify-lock returns no-lock for missing lock file\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  classify-lock for missing file: expected "no-lock", got "%s"\n' "$RED" "$RESET" "$nolock_out"
  fail=$((fail+1))
fi

# Dead-PID lock (PID 0 is unkillable but ps -p 0 returns non-zero) →
# `dead`. This is the canonical safe-to-reap path. We use PID 0 because
# it's stable and predictable across CI runs; macOS and Linux both report
# it as not-alive via ps -p.
dead_classification=$(run_classify_lock "claude agent test-agent-id (pid 0)")
if [[ "$dead_classification" == "dead" ]]; then
  printf '  %sPASS%s  classify-lock returns dead for PID 0\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  classify-lock with PID 0: expected "dead", got "%s"\n' "$RED" "$RESET" "$dead_classification"
  fail=$((fail+1))
fi

# detect-orchestrator-pid subcommand exists and is callable. We don't
# assert the output — the result depends on the test runner's process
# tree — only that the subcommand is recognized (exit 0).
if bash "$worktree_reap_path" detect-orchestrator-pid >/dev/null 2>&1; then
  printf '  %sPASS%s  detect-orchestrator-pid subcommand is callable\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  detect-orchestrator-pid subcommand failed\n' "$RED" "$RESET"
  fail=$((fail+1))
fi

# reap subcommand recognizes the --phase reconcile-A.0.5 form (we exercise
# with --action reaped, --skip-remove so no actual worktree manipulation
# happens). Use a temp SHIPYARD_HOME so the audit log lands in /tmp and
# doesn't pollute the user's real audit log.
tmp_shipyard_home=$(mktemp -d)
export SHIPYARD_HOME="$tmp_shipyard_home"
reap_out=$(bash "$worktree_reap_path" reap \
  --action reaped \
  --worktree-path "/tmp/nonexistent-358-test" \
  --worktree-name "agent-test-358" \
  --session-id "test-session-358" \
  --classification "self-ancestor" \
  --lock-pid 0 \
  --phase "reconcile-A.0.5" \
  --skip-remove 2>&1)
reap_rc=$?
if [[ $reap_rc -eq 0 ]]; then
  printf '  %sPASS%s  reap --phase reconcile-A.0.5 subcommand returns exit 0\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  reap --phase reconcile-A.0.5: expected exit 0, got %d (output: %s)\n' "$RED" "$RESET" "$reap_rc" "$reap_out"
  fail=$((fail+1))
fi

# Audit-log line for the reap above contains the phase field.
audit_log="$tmp_shipyard_home/reap-audit.jsonl"
if [[ -f "$audit_log" ]] && grep -qF '"phase":"reconcile-A.0.5"' "$audit_log"; then
  printf '  %sPASS%s  reap audit-log line carries "phase":"reconcile-A.0.5"\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  reap audit-log missing phase field at %s\n' "$RED" "$RESET" "$audit_log"
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
