#!/usr/bin/env bash
# Test: the pre-reap recovery checks in A.0.5 are documented in
# commands/do-work/steady-state.md with the correct semantics:
#
#   - issue #493: before reaping a crashed worker's worktree, check for
#     committed-but-unpushed work and recover it via push + PR-create.
#   - issue #495: extend the recovery to also salvage UNCOMMITTED
#     working-tree edits via an auto-commit with --no-verify before pushing.
#
# Background — issue #493: a worker that crashes AFTER committing locally
# but BEFORE pushing has already done the expensive work (pre-commit hooks
# passed). The previous spec discarded this work unconditionally (reap +
# re-enqueue from scratch). The fix adds a pre-reap recovery check:
# `git rev-list --count origin/<default>..HEAD > 0` → push the branch →
# open a PR (if none exists) → arm auto-merge → then reap.
#
# Background — issue #495: a worker that crashes/stalls BEFORE committing
# (watchdog kill, pre-commit hook hang) leaves edits in the working tree
# that rev-list --count == 0 cannot detect. This extends the recovery to:
# dirty working tree → `git add -A` + `git commit --no-verify` → then fall
# through to the existing #493 push+PR-create+auto-merge path.
#
# This test is the regression guard for both: if either recovery check is
# removed, the issue-work-only scope guard is lost, the rev-list/status
# signal is dropped, or the fire-and-forget posture is broken, the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/crash-recovery-A05.test.sh

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

echo ""
echo "Test: pre-reap crash-recovery in A.0.5 — issue #493 + #495 regression guard"
echo ""

# 1) The spec file exists.
assert_file_exists "$steady_state_path" "steady-state.md exists"

# 2) The A.0.5 section still exists (regression guard for the parent feature).
assert_contains "$steady_state_path" \
  "#### A.0.5. Post-return worktree reap for crashed / narrative-non-terminal returns" \
  "A.0.5 header present"

# 3) The issue is referenced inline — traceability requirement.
assert_contains "$steady_state_path" \
  "[#493]" \
  "A.0.5 names issue #493 inline"

# 4) The recovery section header is present.
assert_contains "$steady_state_path" \
  "Pre-reap recovery check" \
  "A.0.5 contains Pre-reap recovery check section"

# 5) The rev-list signal is documented — this is the load-bearing "does the
#    worker have committed-but-unpushed work?" check.
assert_contains "$steady_state_path" \
  "rev-list --count" \
  "A.0.5 recovery uses rev-list --count to detect committed work"
assert_contains "$steady_state_path" \
  "origin/\${DEFAULT_BRANCH}..HEAD" \
  "A.0.5 recovery compares origin/<default>..HEAD"

# 6) The scope guard is documented — recovery only applies to issue-work
#    dispatches (slot kind == "issue"), not synthetic diverts or fix-* modes.
assert_contains "$steady_state_path" \
  "slot_kind" \
  "A.0.5 recovery checks slot kind"
# shellcheck disable=SC2016
# Literal grep needle — the $slot_kind is matched verbatim in the spec, not expanded.
assert_contains "$steady_state_path" \
  '[ "$slot_kind" = "issue" ]' \
  "A.0.5 recovery is gated on slot kind == issue"

# 7) The push step is documented.
# shellcheck disable=SC2016
# Literal grep needle — ${slot_issue} is matched verbatim in the spec, not expanded.
assert_contains "$steady_state_path" \
  'push origin "do-work/issue-${slot_issue}"' \
  "A.0.5 recovery pushes the branch to origin"

# 8) The PR-create step is documented, including the existing-PR check that
#    handles the case where the worker pushed but crashed before PR creation.
assert_contains "$steady_state_path" \
  "existing_pr" \
  "A.0.5 recovery checks for an existing open PR"
assert_contains "$steady_state_path" \
  "gh pr create" \
  "A.0.5 recovery calls gh pr create"
assert_contains "$steady_state_path" \
  "Closes #" \
  "A.0.5 recovery PR body includes Closes keyword"
assert_contains "$steady_state_path" \
  "--label shipyard" \
  "A.0.5 recovery PR carries --label shipyard"

# 9) Auto-merge is armed after recovery — the recovery PR enters the normal
#    merge train rather than sitting as a stale open PR.
assert_contains "$steady_state_path" \
  "gh pr merge" \
  "A.0.5 recovery arms auto-merge on the recovered PR"
assert_contains "$steady_state_path" \
  "--auto --merge --delete-branch" \
  "A.0.5 recovery uses --auto --merge --delete-branch"

# 10) The recovered PR is appended to session_prs so drain/summary see it.
# shellcheck disable=SC2016
# Literal grep needle — $recovered_pr is matched verbatim in the spec, not expanded.
assert_contains "$steady_state_path" \
  'session_prs+=("$recovered_pr")' \
  "A.0.5 recovery appends recovered PR to session_prs"

# 11) The recovery log prefix is documented — operators can grep for it.
assert_contains "$steady_state_path" \
  "[reconcile-A.0.5-recovery]" \
  "A.0.5 recovery uses [reconcile-A.0.5-recovery] log prefix"

# 12) Fire-and-forget posture is explicitly stated for recovery steps —
#     a failed push/PR-create must not abort the reconcile turn.
assert_contains "$steady_state_path" \
  "A failed recovery step is not a reason to abort" \
  "A.0.5 recovery explicitly states fire-and-forget posture"

# 13) The recovery check runs BEFORE the actual reap call — ordering is
#     load-bearing (can't recover from a reaped worktree).
#
# Anchor text updated for issue #771: step B now force-reaps `peer-alive`
# too (it no longer defers), so the "Crash-aware reap:" comment above the
# reap call was reworded to stop claiming a "step B defers" contrast that
# no longer holds. The ordering invariant this test guards — recovery
# before reap — is unchanged; only the marker string moved with the prose.
assert_section_ordering "$steady_state_path" \
  "Pre-reap recovery check" \
  "Crash-aware reap: A.0.5 reaps on every classification" \
  "recovery check precedes reap call in document order"

# 14) The zero-commits-ahead case is handled — when count == 0, the spec
#     now checks for a dirty working tree before skipping to the reap.
assert_contains "$steady_state_path" \
  '"0"' \
  "A.0.5 recovery references count==0 case"

# ── New assertions for issue #495 (dirty-worktree recovery) ──────────────

echo ""
echo "Test: dirty-worktree uncommitted-edits recovery (#495 extension)"
echo ""

# 15) Issue #495 is referenced inline — traceability requirement.
assert_contains "$steady_state_path" \
  "[#495]" \
  "A.0.5 names issue #495 inline"

# 16) The dirty-worktree detection signal is present — git status --porcelain
#     is the load-bearing "does the worker have uncommitted edits?" check.
assert_contains "$steady_state_path" \
  "status --porcelain" \
  "A.0.5 recovery uses git status --porcelain to detect dirty working tree"

# 17) The auto-commit step uses --no-verify (the pre-commit gate may be what
#     hung the worker; CI is the safety net).
assert_contains "$steady_state_path" \
  "commit --no-verify" \
  "A.0.5 dirty-worktree recovery commits with --no-verify"

# 18) The dirty-worktree path stages all changes before committing.
assert_contains "$steady_state_path" \
  "add -A" \
  "A.0.5 dirty-worktree recovery stages all changes with git add -A"

# 19) The dirty-worktree log line uses the same [reconcile-A.0.5-recovery]
#     prefix so operators can grep for it alongside the committed-work path.
assert_contains "$steady_state_path" \
  "dirty-worktree auto-commit" \
  "A.0.5 dirty-worktree recovery uses dirty-worktree auto-commit log marker"

# 20) The dirty-worktree recovery falls through to the same push path as
#     the committed-but-unpushed recovery — the push is present in the
#     elif branch, not duplicated at a separate level.
assert_section_ordering "$steady_state_path" \
  "dirty working tree but no commits" \
  "Shared PR-create + auto-merge block" \
  "dirty-worktree branch precedes shared PR-create block"

# 21) The shared PR-create block follows the if/elif so both paths use it —
#     the guard that defaults push_ok must be present to avoid set -u errors
#     when neither branch ran (clean worktree, no committed work).
# shellcheck disable=SC2016
# Literal grep needle — ${push_ok:-false} is matched verbatim in the spec, not expanded.
assert_contains "$steady_state_path" \
  'push_ok="${push_ok:-false}"' \
  "A.0.5 shared block guards push_ok with a default to handle clean-worktree case"

# 22) The scope guard (kind == "issue") also covers the dirty-worktree path —
#     the entire if/elif block lives inside the slot_kind == "issue" gate.
#     The code-level marker for the dirty-worktree branch is the elif line;
#     it must appear AFTER the slot_kind gate, not before it.
# shellcheck disable=SC2016
# Literal grep needle — $slot_kind is matched verbatim in the spec, not expanded.
assert_section_ordering "$steady_state_path" \
  '[ "$slot_kind" = "issue" ]' \
  "dirty working tree but no commits; attempting dirty-worktree" \
  "dirty-worktree recovery is inside the slot_kind==issue scope guard"

# 23) The auto-commit recovery is called out in the fire-and-forget posture
#     paragraph — the existing text covers recovery steps generically, but
#     the prose update for #495 must extend it.
assert_contains "$steady_state_path" \
  "#495" \
  "A.0.5 fire-and-forget or recovery prose references #495"

# ── New assertions for issue #575 (version-coordination bump during recovery) ──

echo ""
echo "Test: version-coordination bump during A.0.5 recovery (#575)"
echo ""

# 24) Issue #575 is referenced inline — traceability requirement.
assert_contains "$steady_state_path" \
  "[#575]" \
  "A.0.5 names issue #575 inline"

# 25) The version-coordination bump section header is present.
assert_contains "$steady_state_path" \
  "Version-coordination bump during recovery" \
  "A.0.5 contains version-coordination bump section header"

# 26) The version-coordination bump is gated on version_coordination.enabled —
#     non-coordinated repos must be unaffected.
assert_contains "$steady_state_path" \
  "version_coordination.enabled" \
  "A.0.5 version-bump gated on version_coordination.enabled config key"
assert_contains "$steady_state_path" \
  "version_coordination.manifest_path" \
  "A.0.5 version-bump reads version_coordination.manifest_path config key"

# 27) The bump compares the worktree manifest version against origin/<default>
#     to detect whether the worker never reached its bump step.
assert_contains "$steady_state_path" \
  "wt_version" \
  "A.0.5 version-bump reads worktree manifest version"
assert_contains "$steady_state_path" \
  "origin_version" \
  "A.0.5 version-bump reads origin manifest version"
# shellcheck disable=SC2016
# Literal grep needle — $wt_version and $origin_version are matched verbatim in the spec.
assert_contains "$steady_state_path" \
  '"$wt_version" != "$origin_version"' \
  "A.0.5 version-bump skips when worktree version differs from origin (worker already bumped)"

# 28) The bump applies to both the dirty-worktree and committed-but-unpushed
#     recovery paths — the helper function is called in both branches.
assert_contains "$steady_state_path" \
  "a05_version_bump" \
  "A.0.5 defines a05_version_bump helper function"

# 29) The committed-but-unpushed path adds the bump as a dedicated commit
#     before the push, not after.
assert_section_ordering "$steady_state_path" \
  "Step 1.5: version-coordination bump (#575). The committed work may" \
  "Step 2: push the branch. Pre-commit hooks already passed" \
  "committed-path version-bump fires before push"

# 30) The dirty-worktree path applies the bump BEFORE git add -A so it folds
#     into the auto-commit (not as a separate commit).
assert_section_ordering "$steady_state_path" \
  "Step 1.5: version-coordination bump (#575). Apply the bump to the" \
  "git -C \"\$worktree_path\" add -A" \
  "dirty-worktree version-bump fires before git add -A"

# 31) The WARNING log message is present for the can't-compute case.
assert_contains "$steady_state_path" \
  "WARNING: recovered PR has no version bump — manual release bump required" \
  "A.0.5 version-bump logs loud WARNING when bump can't be computed"

# 32) The CHANGELOG stub is prepended when changelog_path is configured.
assert_contains "$steady_state_path" \
  "vc_changelog" \
  "A.0.5 version-bump reads version_coordination.changelog_path"
assert_contains "$steady_state_path" \
  "Crash-recovered by orchestrator A.0.5" \
  "A.0.5 CHANGELOG stub includes crash-recovered marker"

# 33) The bump is fire-and-forget — a failed bump must not abort the push.
#     The prose explicitly states this per the issue acceptance criteria.
assert_contains "$steady_state_path" \
  "Fire-and-forget: failure logs an advisory" \
  "A.0.5 version-bump is explicitly fire-and-forget in prose"

# 34) The non-coordinated-repo path is called out — repos without
#     version_coordination configured must be unaffected.
assert_contains "$steady_state_path" \
  "Non-version-coordinated repos are unaffected" \
  "A.0.5 version-bump documents that non-coordinated repos are unaffected"

echo ""
echo "Results: $pass passed, $fail failed"
if (( fail > 0 )); then
  exit 1
fi
exit 0
