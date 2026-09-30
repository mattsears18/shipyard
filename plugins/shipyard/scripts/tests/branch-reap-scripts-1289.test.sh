#!/usr/bin/env bash
# Test suite for the four worktree-lock-reap scripts extracted from
# dispatch-rules.md / drain.md / steady-state.md by issue #1289:
#   - concurrent-session-guard.sh   (dispatch-rules.md's concurrent-session guard)
#   - pre-dispatch-branch-reap.sh   (dispatch-rules.md §2d)
#   - drain-pre-dispatch-branch-reap.sh (drain.md's pre-dispatch head-branch reap)
#   - shipped-immediate-branch-reap.sh  (steady-state.md's A.1 shipped-immediate reap)
#
# Covers, per script: usage/arg validation, "no matching worktree" behavior,
# and a real reap/classification against a `dead` lock (a lock file naming a
# PID that cannot possibly be alive) — the one classification every script's
# force-reap logic agrees is always safe, so it doesn't require mocking
# process liveness or the orchestrator-PID ancestor walk.
#
# Uses REAL git worktrees (mirrors worktree-reap.test.sh's fixture
# convention) — no gh/network dependency. Run with:
#   bash plugins/shipyard/scripts/tests/branch-reap-scripts-1289.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts_dir="$(cd "$here/.." && pwd)"

concurrent_guard="${scripts_dir}/concurrent-session-guard.sh"
pre_dispatch_reap="${scripts_dir}/pre-dispatch-branch-reap.sh"
drain_reap="${scripts_dir}/drain-pre-dispatch-branch-reap.sh"
shipped_reap="${scripts_dir}/shipped-immediate-branch-reap.sh"

for s in "$concurrent_guard" "$pre_dispatch_reap" "$drain_reap" "$shipped_reap"; do
  if [[ ! -f "$s" ]]; then
    echo "FAIL: helper not found at $s" >&2
    exit 1
  fi
done

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to contain: %s\n' "$needle"
    printf '    actual: %s\n' "$haystack"
    fail=$((fail+1))
  fi
}

assert_exit() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (exit %s, want %s)\n' "$RED" "$RESET" "$label" "$got" "$want"
    fail=$((fail+1))
  fi
}

TMPDIR_ROOT="$(mktemp -d -t branch-reap-scripts-1289.XXXXXX)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

repo="$TMPDIR_ROOT/repo"
home="$TMPDIR_ROOT/home"

reset_repo() {
  rm -rf "$repo" "$home"
  mkdir -p "$repo" "$home"
  (
    cd "$repo" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test"
    git commit -q --allow-empty -m "init"
  ) >/dev/null 2>&1
}

# A PID astronomically unlikely to be alive on any real system, and never
# our own PID or an ancestor of it — classify-lock reports this as `dead`.
DEAD_PID=999999999

# add_worktree <branch> — registers a real agent-<branch>-suffix worktree
# checked out on <branch>, with a dead-PID lock file.
add_worktree() {
  local branch="$1" name="$2"
  (
    cd "$repo" || exit 1
    git branch "$branch" >/dev/null 2>&1
    git worktree add -q ".claude/worktrees/${name}" "$branch"
    mkdir -p ".git/worktrees/${name}"
    printf 'claude agent %s (pid %s)\n' "$name" "$DEAD_PID" > ".git/worktrees/${name}/locked"
  ) >/dev/null 2>&1
}

# seed_return_record <session-id> <agent-id...> — issue #1237's reconciled-
# return gate refuses `worktree-reap.sh reap --action reaped` on an `agent-*`
# worktree unless this session's persisted state records that agent-id as
# having returned, UNLESS the caller passes `--bypass-return-check`.
#
# shipped-immediate-branch-reap.sh is a genuine "gated, satisfied naturally"
# call site (see do-work-rationale.md): it only ever targets THIS turn's own
# just-completed agent, and steady-state.md's A.1 wrote the return record
# moments earlier in the SAME turn — the fixture below still has to stand
# that write in for its own suite, otherwise that suite would be asserting
# against a reap the gate correctly refuses.
#
# pre-dispatch-branch-reap.sh and drain-pre-dispatch-branch-reap.sh are NOT
# in that category (corrected by issue #1274, which found the two scripts'
# own #1289-era "gated, satisfied naturally" classification rested on a
# false assumption — their target's originating worker is NOT guaranteed to
# be from THIS session; `failed_prs` is an `--author @me` scan spanning
# every session, and setup step 5.7's own "inherited DIRTY PR" seeding is
# the spec's own precedent for that same cross-session-PR fact). Both
# scripts now pass `--bypass-return-check` internally, so their own suites
# below deliberately do NOT seed a return record — proving the reap
# succeeds without one is the regression test for #1274's fix. Their
# `seed_return_record` calls are kept ONLY for the parts of their suites
# that assert unrelated behavior (branch-ref drop, primary-checkout
# restore) where seeding is harmless but not load-bearing.
seed_return_record() {
  local sid="$1"; shift
  # Pin the session id these scripts derive (they read the repo-root stash
  # when session-identity.sh has no orchestrator worktree to resolve).
  printf '%s\n' "$sid" > "$repo/.shipyard-session-id"
  SHIPYARD_HOME="$home" bash "${scripts_dir}/session-state.sh" init \
    --session-id "$sid" --repo "o/r" >/dev/null 2>&1
  local agent
  for agent in "$@"; do
    SHIPYARD_HOME="$home" bash "${scripts_dir}/session-state.sh" update \
      --session-id "$sid" \
      --set ".returned_agent_ids[\"${agent}\"] = \"2026-01-01T00:00:00Z\"" \
      >/dev/null 2>&1
  done
}

echo "branch-reap scripts test suite (issue #1289)"
echo "=============================================="

# ==========================================================================
echo
echo "concurrent-session-guard.sh"
# ==========================================================================
out="$(bash "$concurrent_guard" check 2>&1)"; rc=$?
assert_contains "$out" "required" "check without --issue errors"
assert_exit "$rc" "64" "missing required args exits 64"

reset_repo
(
  cd "$repo" || exit 1
  out="$(SHIPYARD_HOME="$home" bash "$concurrent_guard" check --issue 42 2>&1)"
  echo "$out" > "$TMPDIR_ROOT/guard-noop.out"
)
out="$(cat "$TMPDIR_ROOT/guard-noop.out")"
assert_contains "$out" "peer_locked=false" "no matching do-work/issue-42 worktree -> peer_locked=false"

reset_repo
add_worktree "do-work/issue-42" "agent-guardtest"
(
  cd "$repo" || exit 1
  out="$(SHIPYARD_HOME="$home" bash "$concurrent_guard" check --issue 42 2>&1)"
  echo "$out" > "$TMPDIR_ROOT/guard-dead.out"
)
out="$(cat "$TMPDIR_ROOT/guard-dead.out")"
# A `dead` lock is NOT peer-alive/unknown, so the guard reports the issue as
# unlocked (a dead lock never blocks dispatch — only peer-alive/unknown do).
assert_contains "$out" "peer_locked=false" "a dead-PID lock on the matching branch does not block dispatch"

# ==========================================================================
echo
echo "pre-dispatch-branch-reap.sh"
# ==========================================================================
out="$(bash "$pre_dispatch_reap" reap --head-ref foo 2>&1)"; rc=$?
assert_contains "$out" "required" "reap without --session-id errors"
assert_exit "$rc" "64" "missing required args exits 64"

reset_repo
(
  cd "$repo" || exit 1
  out="$(SHIPYARD_HOME="$home" bash "$pre_dispatch_reap" reap --head-ref do-work/issue-1 --session-id test-session 2>&1)"
  echo "$out" > "$TMPDIR_ROOT/predispatch-noop.out"
)
out="$(tail -1 "$TMPDIR_ROOT/predispatch-noop.out")"
assert_contains "$out" "reaped=false" "no matching worktree -> reaped=false"

reset_repo
add_worktree "do-work/issue-1" "agent-predispatch1"
seed_return_record "test-session" "predispatch1"
wt_path="$repo/.claude/worktrees/agent-predispatch1"
(
  cd "$repo" || exit 1
  out="$(SHIPYARD_HOME="$home" bash "$pre_dispatch_reap" reap --head-ref do-work/issue-1 --session-id test-session 2>&1)"
  echo "$out" > "$TMPDIR_ROOT/predispatch-reap.out"
)
out="$(tail -1 "$TMPDIR_ROOT/predispatch-reap.out")"
assert_contains "$out" "reaped=true" "a dead-PID lock on the matching branch is reaped"
assert_contains "$out" "classification=dead" "dead classification reported (not relabeled — only peer-alive is)"
if [[ ! -e "$wt_path" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "reaped worktree is gone from disk"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "reaped worktree is gone from disk"; fail=$((fail+1))
fi
if (cd "$repo" && git rev-parse --verify "do-work/issue-1" >/dev/null 2>&1); then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "local branch ref is dropped after reap"; fail=$((fail+1))
else
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "local branch ref is dropped after reap"; pass=$((pass+1))
fi

# --- (#1274 regression) NO seeded return record — simulates a worktree
# whose originating worker's PR was inherited from a PRIOR session, whose
# .returned_agent_ids this --session-id can never read. Before the #1274
# fix, the underlying reap was silently refused by the #1237 gate
# ("reap-refused"/"no-recorded-return" in the audit log) while this script
# still claimed reaped=true and left the worktree on disk — reproduced live
# against a real worktree during the #1274 investigation. The fix threads
# --bypass-return-check internally, so this must now actually reap. ---
reset_repo
add_worktree "do-work/issue-2" "agent-predispatch2"
wt_path_inherited="$repo/.claude/worktrees/agent-predispatch2"
(
  cd "$repo" || exit 1
  out="$(SHIPYARD_HOME="$home" bash "$pre_dispatch_reap" reap --head-ref do-work/issue-2 --session-id different-session-never-saw-this-agent 2>&1)"
  echo "$out" > "$TMPDIR_ROOT/predispatch-inherited.out"
)
out="$(tail -1 "$TMPDIR_ROOT/predispatch-inherited.out")"
assert_contains "$out" "reaped=true" "(#1274) an inherited worktree with NO seeded return record still reaches this script's reaped=true report"
if [[ ! -e "$wt_path_inherited" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "(#1274) inherited worktree with no return record is ACTUALLY gone from disk (not just self-reported)"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "(#1274) inherited worktree with no return record is ACTUALLY gone from disk (not just self-reported)"; fail=$((fail+1))
fi
audit_log="$home/reap-audit.jsonl"
if grep -q '"action":"reap-refused"' "$audit_log" 2>/dev/null; then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "(#1274) no reap-refused audit line for the inherited-worktree case"; fail=$((fail+1))
else
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "(#1274) no reap-refused audit line for the inherited-worktree case"; pass=$((pass+1))
fi
if grep -q '"worktree":"agent-predispatch2".*"action":"reaped"' "$audit_log" 2>/dev/null; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "(#1274) audit log records a real reaped action for the inherited worktree"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "(#1274) audit log records a real reaped action for the inherited worktree"; fail=$((fail+1))
fi

# --- (issue #1407 regression, sibling of #1404) the delegated
# `worktree-reap.sh reap --action reaped` call genuinely fails to remove the
# worktree (its parent directory is made read-only so mv / plain remove /
# --force remove all fail, even though the worktree itself is an otherwise
# completely ordinary, clean, dead-lock candidate). Before the #1407 fix,
# this wrapper reported `reaped=true` unconditionally regardless of whether
# the delegated call actually succeeded. The fix re-verifies the filesystem
# before ever reporting success. ---
reset_repo
add_worktree "do-work/issue-9" "agent-predispatch9"
seed_return_record "test-session" "predispatch9"
wt_path6="$repo/.claude/worktrees/agent-predispatch9"
wt_parent6="$repo/.claude/worktrees"
chmod 555 "$wt_parent6"
(
  cd "$repo" || exit 1
  out="$(SHIPYARD_HOME="$home" bash "$pre_dispatch_reap" reap --head-ref do-work/issue-9 --session-id test-session 2>&1)"
  echo "$out" > "$TMPDIR_ROOT/predispatch-reap-fail.out"
)
chmod u+w "$wt_parent6" 2>/dev/null || true
out="$(tail -1 "$TMPDIR_ROOT/predispatch-reap-fail.out")"
if [[ -e "$wt_path6" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "(#1407) fixture sanity check: worktree genuinely survives the blocked removal"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "(#1407) fixture sanity check: worktree genuinely survives the blocked removal"; fail=$((fail+1))
fi
if [[ "$out" == reaped=true* ]]; then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "(#1407) does NOT report reaped=true when the worktree is still present on disk"; fail=$((fail+1))
  printf '    actual: %s\n' "$out"
else
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "(#1407) does NOT report reaped=true when the worktree is still present on disk"; pass=$((pass+1))
fi
assert_contains "$out" "reaped=failed" "(#1407) the failure is reported via a distinguishable reaped=failed token"
# Substring only (not the full $wt_path6) — on macOS /tmp resolves through a
# /private/var symlink, so the script's own git-derived path and this test's
# raw mktemp path can differ by that prefix alone.
assert_contains "$out" ".claude/worktrees/agent-predispatch9" "(#1407) the failure report names the surviving worktree_path"
if (cd "$repo" && git rev-parse --verify "do-work/issue-9" >/dev/null 2>&1); then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "(#1407) local branch ref is NOT dropped when the worktree still holds it checked out"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "(#1407) local branch ref is NOT dropped when the worktree still holds it checked out"; fail=$((fail+1))
fi
audit_log6="$home/reap-audit.jsonl"
if grep -q '"worktree":"agent-predispatch9".*"action":"reaped-failed".*"reason":"delegated-reap-did-not-remove-worktree"' "$audit_log6" 2>/dev/null; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "(#1407) a reaped-failed audit line is written by the wrapper itself for the failed removal"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "(#1407) a reaped-failed audit line is written by the wrapper itself for the failed removal"; fail=$((fail+1))
fi

# ==========================================================================
echo
echo "shipped-immediate-branch-reap.sh"
# ==========================================================================
out="$(bash "$shipped_reap" reap 2>&1)"; rc=$?
assert_contains "$out" "required" "reap without --issue errors"
assert_exit "$rc" "64" "missing required args exits 64"

reset_repo
(
  cd "$repo" || exit 1
  out="$(SHIPYARD_HOME="$home" bash "$shipped_reap" reap --issue 7 2>&1)"
  echo "$out" > "$TMPDIR_ROOT/shipped-noop.out"
)
out="$(tail -1 "$TMPDIR_ROOT/shipped-noop.out")"
assert_contains "$out" "reaped=false" "no matching do-work/issue-7 worktree -> reaped=false"

reset_repo
add_worktree "do-work/issue-7" "agent-shipped7"
seed_return_record "test-session" "shipped7"
wt_path2="$repo/.claude/worktrees/agent-shipped7"
(
  cd "$repo" || exit 1
  out="$(SHIPYARD_HOME="$home" bash "$shipped_reap" reap --issue 7 2>&1)"
  echo "$out" > "$TMPDIR_ROOT/shipped-reap.out"
)
out="$(tail -1 "$TMPDIR_ROOT/shipped-reap.out")"
assert_contains "$out" "reaped=true" "a dead-PID lock on do-work/issue-7 is reaped"
if [[ ! -e "$wt_path2" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "reaped worktree is gone from disk"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "reaped worktree is gone from disk"; fail=$((fail+1))
fi

# --- (issue #1404 regression) the delegated `worktree-reap.sh reap --action
# reaped` call genuinely fails to remove the worktree (its parent directory
# is made read-only so mv / plain remove / --force remove all fail, even
# though the worktree itself is an otherwise completely ordinary, clean,
# dead-lock candidate). Before the #1404 fix, this wrapper reported
# `reaped=true` unconditionally regardless of whether the delegated call
# actually succeeded — reproduced live against a real worktree twice in the
# same session (issue #1404's body + comment). The fix re-verifies the
# filesystem before ever reporting success. ---
reset_repo
add_worktree "do-work/issue-8" "agent-shipped8"
seed_return_record "test-session" "shipped8"
wt_path5="$repo/.claude/worktrees/agent-shipped8"
wt_parent5="$repo/.claude/worktrees"
chmod 555 "$wt_parent5"
(
  cd "$repo" || exit 1
  out="$(SHIPYARD_HOME="$home" bash "$shipped_reap" reap --issue 8 2>&1)"
  echo "$out" > "$TMPDIR_ROOT/shipped-reap-fail.out"
)
chmod u+w "$wt_parent5" 2>/dev/null || true
out="$(tail -1 "$TMPDIR_ROOT/shipped-reap-fail.out")"
if [[ -e "$wt_path5" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "(#1404) fixture sanity check: worktree genuinely survives the blocked removal"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "(#1404) fixture sanity check: worktree genuinely survives the blocked removal"; fail=$((fail+1))
fi
if [[ "$out" == reaped=true* ]]; then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "(#1404) does NOT report reaped=true when the worktree is still present on disk"; fail=$((fail+1))
  printf '    actual: %s\n' "$out"
else
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "(#1404) does NOT report reaped=true when the worktree is still present on disk"; pass=$((pass+1))
fi
assert_contains "$out" "reaped=failed" "(#1404) the failure is reported via a distinguishable reaped=failed token"
# Substring only (not the full $wt_path5) — on macOS /tmp resolves through a
# /private/var symlink, so the script's own git-derived path and this test's
# raw mktemp path can differ by that prefix alone.
assert_contains "$out" ".claude/worktrees/agent-shipped8" "(#1404) the failure report names the surviving worktree_path"
if (cd "$repo" && git rev-parse --verify "do-work/issue-8" >/dev/null 2>&1); then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "(#1404) local branch ref is NOT dropped when the worktree still holds it checked out"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "(#1404) local branch ref is NOT dropped when the worktree still holds it checked out"; fail=$((fail+1))
fi
audit_log5="$home/reap-audit.jsonl"
if grep -q '"worktree":"agent-shipped8".*"action":"reaped-failed".*"reason":"delegated-reap-did-not-remove-worktree"' "$audit_log5" 2>/dev/null; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "(#1404) a reaped-failed audit line is written by the wrapper itself for the failed removal"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "(#1404) a reaped-failed audit line is written by the wrapper itself for the failed removal"; fail=$((fail+1))
fi

# ==========================================================================
echo
echo "drain-pre-dispatch-branch-reap.sh"
# ==========================================================================
out="$(bash "$drain_reap" reap --head-ref foo --repo o/r 2>&1)"; rc=$?
assert_contains "$out" "required" "reap without --session-id errors"
assert_exit "$rc" "64" "missing required args exits 64"

reset_repo
(
  cd "$repo" || exit 1
  out="$(SHIPYARD_HOME="$home" GH="$(command -v true)" bash "$drain_reap" reap \
    --head-ref do-work/issue-3 --repo o/r --session-id test-session 2>&1)"
  echo "$out" > "$TMPDIR_ROOT/drain-noop.out"
)
out="$(cat "$TMPDIR_ROOT/drain-noop.out")"
assert_contains "$out" "reap_outcome=none" "no matching worktree -> reap_outcome=none"
assert_contains "$out" "primary_leak_restored=false" "no primary-checkout leak -> primary_leak_restored=false"

reset_repo
add_worktree "do-work/issue-3" "agent-drain3"
seed_return_record "test-session" "drain3"
wt_path3="$repo/.claude/worktrees/agent-drain3"
(
  cd "$repo" || exit 1
  out="$(SHIPYARD_HOME="$home" GH="$(command -v true)" bash "$drain_reap" reap \
    --head-ref do-work/issue-3 --repo o/r --session-id test-session 2>&1)"
  echo "$out" > "$TMPDIR_ROOT/drain-reap.out"
)
out="$(cat "$TMPDIR_ROOT/drain-reap.out")"
# do-work/issue-* branch pattern -> force-reap applies even before considering
# peer-alive/unknown; a plain `dead` classification is reaped unconditionally.
assert_contains "$out" "reap_outcome=reaped" "a dead-PID lock on a do-work/issue-* branch is reaped"
if [[ ! -e "$wt_path3" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "reaped worktree is gone from disk"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "reaped worktree is gone from disk"; fail=$((fail+1))
fi

# --- (#1274 regression) same inherited-worktree case as
# pre-dispatch-branch-reap.sh above — NO seeded return record, a different
# --session-id than any that ever recorded this agent's return. ---
reset_repo
add_worktree "do-work/issue-4" "agent-drain4"
wt_path4="$repo/.claude/worktrees/agent-drain4"
(
  cd "$repo" || exit 1
  out="$(SHIPYARD_HOME="$home" GH="$(command -v true)" bash "$drain_reap" reap \
    --head-ref do-work/issue-4 --repo o/r --session-id different-session-never-saw-this-agent 2>&1)"
  echo "$out" > "$TMPDIR_ROOT/drain-inherited.out"
)
out="$(cat "$TMPDIR_ROOT/drain-inherited.out")"
assert_contains "$out" "reap_outcome=reaped" "(#1274) an inherited do-work/issue-* worktree with NO seeded return record is still reaped"
if [[ ! -e "$wt_path4" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "(#1274) inherited worktree with no return record is ACTUALLY gone from disk"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "(#1274) inherited worktree with no return record is ACTUALLY gone from disk"; fail=$((fail+1))
fi
if grep -q '"worktree":"agent-drain4".*"action":"reap-refused"' "$home/reap-audit.jsonl" 2>/dev/null; then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "(#1274) no reap-refused audit line for the inherited drain worktree"; fail=$((fail+1))
else
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "(#1274) no reap-refused audit line for the inherited drain worktree"; pass=$((pass+1))
fi

# --- (issue #1407 regression, sibling of #1404) the delegated
# `worktree-reap.sh reap --action reaped` call genuinely fails to remove the
# worktree (its parent directory is made read-only). Before the #1407 fix,
# this wrapper reported `reap_outcome=reaped` unconditionally regardless of
# whether the delegated call actually succeeded. The fix re-verifies the
# filesystem before ever reporting reaped, and does not drop the local
# branch ref in that case. ---
reset_repo
add_worktree "do-work/issue-5" "agent-drain5"
seed_return_record "test-session" "drain5"
wt_path5="$repo/.claude/worktrees/agent-drain5"
wt_parent5="$repo/.claude/worktrees"
chmod 555 "$wt_parent5"
(
  cd "$repo" || exit 1
  out="$(SHIPYARD_HOME="$home" GH="$(command -v true)" bash "$drain_reap" reap \
    --head-ref do-work/issue-5 --repo o/r --session-id test-session 2>&1)"
  echo "$out" > "$TMPDIR_ROOT/drain-reap-fail.out"
)
chmod u+w "$wt_parent5" 2>/dev/null || true
out="$(cat "$TMPDIR_ROOT/drain-reap-fail.out")"
if [[ -e "$wt_path5" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "(#1407) fixture sanity check: worktree genuinely survives the blocked removal"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "(#1407) fixture sanity check: worktree genuinely survives the blocked removal"; fail=$((fail+1))
fi
assert_contains "$out" "reap_outcome=failed" "(#1407) does NOT report reap_outcome=reaped when the worktree is still present on disk"
assert_contains "$out" "reason=delegated-reap-did-not-remove-worktree" "(#1407) the failure is reported via a distinguishable reason"
# Substring only (not the full $wt_path5) — on macOS /tmp resolves through a
# /private/var symlink, so the script's own git-derived path and this test's
# raw mktemp path can differ by that prefix alone.
assert_contains "$out" ".claude/worktrees/agent-drain5" "(#1407) the failure report names the surviving worktree_path"
if (cd "$repo" && git rev-parse --verify "do-work/issue-5" >/dev/null 2>&1); then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "(#1407) local branch ref is NOT dropped when the worktree still holds it checked out"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "(#1407) local branch ref is NOT dropped when the worktree still holds it checked out"; fail=$((fail+1))
fi
audit_log_drain5="$home/reap-audit.jsonl"
if grep -q '"worktree":"agent-drain5".*"action":"reaped-failed".*"reason":"delegated-reap-did-not-remove-worktree"' "$audit_log_drain5" 2>/dev/null; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "(#1407) a reaped-failed audit line is written by the wrapper itself for the failed removal"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "(#1407) a reaped-failed audit line is written by the wrapper itself for the failed removal"; fail=$((fail+1))
fi

echo
printf '  %s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
