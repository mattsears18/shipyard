#!/usr/bin/env bash
# Test: orchestrator-direct `gh pr merge --auto` call sites detect and report
# the missing-`workflow`-OAuth-scope block, not just discard it (issue #850).
#
# Background
# ----------
# Issue #812 (landed) taught workers to detect this GraphQL block, name it
# distinctly, and feed a session-local `workflow_scope_blocked_prs` list that
# the end-of-session summary reports once, session-wide.
#
# But #812's detection lives in the WORKER-side fragment
# (skills/worker-preamble/auto-merge.md step 1.1) and the worker per-mode
# specs — it was never wired into the orchestrator's OWN direct-arm call
# sites. Four places arm `--auto` directly on the orchestrator's turn rather
# than delegating to a dispatched worker:
#
#   - inline-trivial.md §E        (fast-path PRs, skipped worker dispatch)
#   - steady-state.md A.0.5       (crash-recovery re-arm)
#   - setup/01c-label-recovery-refine.md §3c (orphan-recovery re-arm; moved from 00b by #1202)
#   - drain.md release-train sweep (release-please PR auto-arming)
#
# Before #850 all four discarded the merge-arm call's stderr unconditionally
# (`2>/dev/null || true`, or — inline-trivial's gated branch — didn't capture
# it at all), so an orchestrator-armed PR that hit the workflow-scope block
# surfaced NO signal whatsoever, even though the identical worker-armed case
# was already fully reported. The #850 repro: lightwork PR #2900/#2863 sat
# unmerged with a swallowed error while a worker-armed sibling PR (#2999)
# succeeded in the same session.
#
# This suite pins:
#
#   (A) Each of the four call sites captures the merge-arm call's stderr
#       (rather than `2>/dev/null`) and matches it against the SAME GraphQL
#       signature the worker-side fragment uses — no re-derived / drifted
#       copy of the condition.
#   (B) Each site logs a distinctly-tagged line on a match, instead of
#       silently leaving the PR unarmed with no trace.
#   (C) do-work.md's `workflow_scope_blocked_prs` orchestrator-state
#       description documents that these four sites populate the list too,
#       not just the worker-return path (#812's original mechanism).
#   (D) drain.md's canonical "four orchestrator-turn call sites" paragraph
#       cross-references the #850 wiring, so a future editor of that list
#       updates the workflow-scope detection in lockstep.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/workflow-scope-orchestrator-arm-850.test.sh

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

assert_not_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    assert_fail "$label"
    printf '    did NOT expect to find in %s: %s\n' "$file" "$needle"
  else
    assert_pass "$label"
  fi
}

echo "orchestrator-direct workflow-scope detection regression tests (issue #850)"
echo

INLINE_TRIVIAL="$repo_root/plugins/shipyard/commands/do-work/inline-trivial.md"
STEADY_STATE="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
SETUP_WORKTREE="$repo_root/plugins/shipyard/commands/do-work/setup/01c-label-recovery-refine.md"
DRAIN="$repo_root/plugins/shipyard/commands/do-work/drain.md"
DO_WORK="$repo_root/plugins/shipyard/commands/do-work.md"
RATIONALE="$repo_root/docs/design/do-work-rationale.md"
# A.0.5's merge-arm call moved from steady-state.md's inline prose into
# scripts/crash-recovery-reap.sh with issue #1291's extraction — the
# call-site assertions below target the script now, not the .md.
CRASH_RECOVERY_REAP="$repo_root/plugins/shipyard/scripts/crash-recovery-reap.sh"
# setup/01c §3c's ENTIRE state machine — including the workflow-scope
# detection this suite pins — moved out of 01c-label-recovery-refine.md and
# into worktree-reap.sh's `triage_orphan_branches` function with issue #1365
# (same move #739's collision-fallback guards in do-work-split.test.sh
# already re-pointed at). 01c now documents the two `[setup-3c] PR #<N> ...`
# log lines as spec only; the executable form — and the property this suite
# checks — lives in worktree-reap.sh now.
WORKTREE_REAP="$repo_root/plugins/shipyard/scripts/worktree-reap.sh"

# ---------------------------------------------------------------------------
# (A) + (B) Each of the four call sites: captures stderr, matches the shared
#     GraphQL signature, logs a distinctly-tagged line on match.
# ---------------------------------------------------------------------------
echo "(A+B) per-call-site detection + distinct log line"

if [[ -f "$INLINE_TRIVIAL" ]]; then
  assert_contains "$INLINE_TRIVIAL" 'without .workflow. scope' \
    "inline-trivial.md §E matches the shared GraphQL 'without \`workflow\` scope' signature"
  assert_contains "$INLINE_TRIVIAL" '[inline-trivial] PR #<pr-num> auto-merge arm blocked' \
    "inline-trivial.md §E logs a distinctly-tagged line on match"
  # shellcheck disable=SC2016
  assert_contains "$INLINE_TRIVIAL" 'MERGE_ARM_ERR=$(gh pr merge <pr-num>' \
    "inline-trivial.md §E captures the merge-arm call's stderr into a variable"
else
  assert_fail "inline-trivial.md exists (missing at $INLINE_TRIVIAL)"
fi

if [[ -f "$CRASH_RECOVERY_REAP" ]]; then
  assert_contains "$CRASH_RECOVERY_REAP" 'without .workflow. scope' \
    "crash-recovery-reap.sh (A.0.5) matches the shared GraphQL 'without \`workflow\` scope' signature"
  # shellcheck disable=SC2016
  assert_contains "$CRASH_RECOVERY_REAP" '[reconcile-A.0.5-recovery] PR #${recovered_pr} auto-merge arm blocked' \
    "crash-recovery-reap.sh (A.0.5) logs a distinctly-tagged line on match"
  # shellcheck disable=SC2016
  # $GH (not a literal `gh`) — every gh invocation in the extracted script
  # goes through the testable wrapper (see the script's own header).
  assert_contains "$CRASH_RECOVERY_REAP" 'merge_arm_err=$("$GH" pr merge "$recovered_pr"' \
    "crash-recovery-reap.sh (A.0.5) captures the merge-arm call's stderr into a variable"
else
  assert_fail "scripts/crash-recovery-reap.sh exists (missing at $CRASH_RECOVERY_REAP)"
fi

if [[ -f "$WORKTREE_REAP" ]]; then
  assert_contains "$WORKTREE_REAP" 'without .workflow. scope' \
    "worktree-reap.sh triage_orphan_branches (§3c) matches the shared GraphQL 'without \`workflow\` scope' signature (moved from 01c §3c by #1365)"
  # shellcheck disable=SC2016
  assert_contains "$WORKTREE_REAP" '[setup-3c] PR #$pr_num auto-merge arm blocked' \
    "worktree-reap.sh triage_orphan_branches (§3c) logs a distinctly-tagged line on match (moved from 01c §3c by #1365)"
  # shellcheck disable=SC2016
  # $GH (not a literal `gh`) — every gh invocation in the extracted script
  # goes through the testable wrapper (see the script's own header).
  assert_contains "$WORKTREE_REAP" 'merge_arm_err=$("$GH" pr merge "$pr_num"' \
    "worktree-reap.sh triage_orphan_branches (§3c) captures the merge-arm call's stderr into a variable (moved from 01c §3c by #1365)"
else
  assert_fail "scripts/worktree-reap.sh exists (missing at $WORKTREE_REAP)"
fi

if [[ -f "$DRAIN" ]]; then
  assert_contains "$DRAIN" 'without .workflow. scope' \
    "drain.md release-train sweep matches the shared GraphQL 'without \`workflow\` scope' signature"
  assert_contains "$DRAIN" '[release-train] PR #<M> auto-merge arm blocked' \
    "drain.md release-train sweep logs a distinctly-tagged line on match"
  # shellcheck disable=SC2016
  assert_contains "$DRAIN" 'merge_arm_err=$(gh pr merge <M>' \
    "drain.md release-train sweep captures the merge-arm call's stderr into a variable"
else
  assert_fail "drain.md exists (missing at $DRAIN)"
fi
echo

# ---------------------------------------------------------------------------
# (C) do-work.md's workflow_scope_blocked_prs description documents the
#     orchestrator-direct population path, not just the worker-return path.
# ---------------------------------------------------------------------------
echo "(C) do-work.md orchestrator-state documents the extended population path"
if [[ -f "$DO_WORK" ]]; then
  assert_contains "$DO_WORK" 'extended by [#850]' \
    "do-work.md's workflow_scope_blocked_prs entry cites #850 as an extension of #812"
  assert_contains "$DO_WORK" 'four orchestrator-turn direct-arm call sites' \
    "do-work.md documents the four orchestrator-direct call sites also populate the list"
else
  assert_fail "do-work.md exists (missing at $DO_WORK)"
fi
echo

# ---------------------------------------------------------------------------
# (D) drain.md's canonical four-call-site paragraph cross-references #850,
#     so a future editor who adds/renames a call site there is pointed at
#     the workflow-scope detection that must move in lockstep.
# ---------------------------------------------------------------------------
echo "(D) drain.md's canonical call-site list cross-references #850"
if [[ -f "$DRAIN" ]]; then
  # shellcheck disable=SC2016
  assert_contains "$DRAIN" 'The same four call sites also detect the missing-`workflow`-OAuth-scope block' \
    "drain.md's four-call-site paragraph documents the #850 workflow-scope wiring"
  assert_contains "$DRAIN" 'This closes the *visibility* gap #850 reported' \
    "drain.md's #850 cross-reference paragraph names what the fix closes"
else
  assert_fail "drain.md exists (missing at $DRAIN)"
fi
echo

# ---------------------------------------------------------------------------
# (E) RATIONALE records why #850's "delegate the arm to a worker" suggestion
#     was NOT adopted — a worker shares the orchestrator's own `gh` token on
#     this host, so delegating would not actually route around the block.
# ---------------------------------------------------------------------------
echo "(E) do-work-rationale.md documents why delegation-to-worker was rejected"
if [[ -f "$RATIONALE" ]]; then
  assert_contains "$RATIONALE" '#850 — why not delegate the arm to a worker' \
    "do-work-rationale.md has a dedicated #850 section"
  assert_contains "$RATIONALE" 'same host, as the same user' \
    "do-work-rationale.md explains a dispatched worker shares the orchestrator's own gh token"
else
  assert_fail "do-work-rationale.md exists (missing at $RATIONALE)"
fi
echo

# ---------------------------------------------------------------------------
# (F) None of the four sites' gated-branch merge-arm call still uses a bare
#     `2>/dev/null || true` with no stderr capture — that's the exact
#     pre-#850 shape that swallowed the signature unread.
# ---------------------------------------------------------------------------
echo "(F) no remaining silent-discard on the gated-branch merge-arm call"
if [[ -f "$STEADY_STATE" ]]; then
  # shellcheck disable=SC2016
  assert_not_contains "$STEADY_STATE" 'gh pr merge "$recovered_pr" --repo <owner/repo> --auto --merge --delete-branch 2>/dev/null || true' \
    "steady-state.md A.0.5 no longer discards the merge-arm call's stderr unconditionally"
fi
if [[ -f "$CRASH_RECOVERY_REAP" ]]; then
  # shellcheck disable=SC2016
  assert_not_contains "$CRASH_RECOVERY_REAP" '"$GH" pr merge "$recovered_pr" --repo "$repo" --auto --"${auto_merge_method}" --delete-branch 2>/dev/null || true' \
    "crash-recovery-reap.sh (A.0.5) no longer discards the merge-arm call's stderr unconditionally"
fi
if [[ -f "$SETUP_WORKTREE" ]]; then
  # shellcheck disable=SC2016
  assert_not_contains "$SETUP_WORKTREE" 'gh pr merge "$pr_num" --repo <owner/repo> --auto --merge --delete-branch 2>/dev/null || true' \
    "setup/01c-label-recovery-refine.md §3c no longer discards the merge-arm call's stderr unconditionally"
fi
echo

printf 'passed: %d, failed: %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
