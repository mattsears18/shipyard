#!/usr/bin/env bash
# Test: the pre-reap recovery checks in A.0.5 are documented in
# commands/do-work/steady-state.md (prose) and implemented in
# scripts/crash-recovery-reap.sh (code) with the correct semantics:
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
# Extraction — issue #1291: the ~420-line A.0.5 crash-recovery reap block
# was extracted from steady-state.md's fenced ```bash prose into
# scripts/crash-recovery-reap.sh (mirroring the #1289 precedent for the
# other 17 compound blocks). This test was updated the same way #1289 had
# to update several pre-existing content-assertion tests when logic moved
# out of the .md prose into scripts — assertions whose target text moved
# now point at crash-recovery-reap.sh instead of steady-state.md; assertions
# whose target text is still-surviving prose stay pointed at steady-state.md.
#
# This test is the regression guard for both #493 and #495: if either
# recovery check is removed, the issue-work-only scope guard is lost, the
# rev-list/status signal is dropped, or the fire-and-forget posture is
# broken, the test fails — regardless of which file (spec prose or script)
# currently carries the logic.
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
crash_recovery_reap_path="$repo_root/plugins/shipyard/scripts/crash-recovery-reap.sh"
# Issue #1316 — the surviving prose's own inline rev-list comparison moved
# out of steady-state.md and into worktree-reap.sh's inspect-unpushed
# subcommand (the mechanical check can no longer inline a direct `git -C`
# against another worktree from the orchestrator's own, worktree-isolated
# Bash calls). See assertion 5 below.
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

# 1) The spec files we depend on exist.
assert_file_exists "$steady_state_path" "steady-state.md exists"
assert_file_exists "$crash_recovery_reap_path" "scripts/crash-recovery-reap.sh exists (#1291 extraction)"

# 2) The A.0.5 section still exists (regression guard for the parent feature).
assert_contains "$steady_state_path" \
  "#### A.0.5. Post-return worktree reap for crashed / narrative-non-terminal returns" \
  "A.0.5 header present"

# 3) The issue is referenced inline — traceability requirement. Still
#    surviving prose (the "Pre-reap recovery check" paragraph was not moved).
assert_contains "$steady_state_path" \
  "[#493]" \
  "A.0.5 names issue #493 inline"

# 4) The recovery section header is present (surviving prose).
assert_contains "$steady_state_path" \
  "Pre-reap recovery check" \
  "A.0.5 contains Pre-reap recovery check section"

# 5) The rev-list signal is documented — this is the load-bearing "does the
#    worker have committed-but-unpushed work?" check. Present in the
#    "Recovery semantics" prose (still describing crash-recovery-reap.sh's
#    own internals — an already-extracted, #1291 call site untouched by
#    #1316), in the script itself, AND — as of #1316 — in worktree-
#    reap.sh's inspect-unpushed subcommand, which is what the surviving
#    prose's OWN mechanical resume-worthy check now delegates to instead of
#    inlining a direct `git -C <other-worktree>` (refused by the
#    orchestrator's worktree-isolation guard once it has isolated itself
#    per setup step 0.5).
assert_contains "$steady_state_path" \
  "rev-list --count" \
  "A.0.5 prose documents rev-list --count to detect committed work"
assert_contains "$crash_recovery_reap_path" \
  "rev-list --count" \
  "crash-recovery-reap.sh uses rev-list --count to detect committed work"
assert_file_exists "$worktree_reap_path" "worktree-reap.sh exists (#1316)"
assert_contains "$worktree_reap_path" \
  "rev-list --count" \
  "worktree-reap.sh's inspect-unpushed uses rev-list --count (#1316)"
assert_contains "$steady_state_path" \
  "inspect-unpushed" \
  "A.0.5's mechanical check delegates the origin/<default>..HEAD comparison to inspect-unpushed (#1316)"

# 6) The scope guard is documented — recovery only applies to issue-work
#    dispatches (slot kind == "issue"), not synthetic diverts or fix-* modes.
#    This code-level detail moved into the script with the #1291 extraction.
assert_contains "$crash_recovery_reap_path" \
  "slot_kind" \
  "crash-recovery-reap.sh recovery checks slot kind"
# shellcheck disable=SC2016
# Literal grep needle — the $slot_kind is matched verbatim in the script, not expanded.
assert_contains "$crash_recovery_reap_path" \
  '[ "$slot_kind" = "issue" ]' \
  "crash-recovery-reap.sh recovery is gated on slot kind == issue"

# 7) The push step is documented (moved into the script). The recovery push
#    targets the branch the crashed worktree ACTUALLY holds, via an explicit
#    `HEAD:refs/heads/<name>` refspec rather than a hardcoded
#    `do-work/issue-<N>` local refname (issue #1562) — a split dispatch is
#    branched `do-work/slice-<N>`, and issue-work.md §3's worktree-collision
#    fallback checks out `do-work/issue-<N>-<epoch>` locally, so a bare push
#    of the canonical name fails "src refspec does not match any" for both.
# shellcheck disable=SC2016
# Literal grep needle — ${recovery_branch} is matched verbatim in the script, not expanded.
assert_contains "$crash_recovery_reap_path" \
  'push origin "HEAD:refs/heads/${recovery_branch}"' \
  "crash-recovery-reap.sh recovery pushes the worktree's own branch to origin"
# shellcheck disable=SC2016
assert_contains "$crash_recovery_reap_path" \
  'recovery_branch=$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD' \
  "crash-recovery-reap.sh derives the recovery branch from the worktree's HEAD (#1562)"
# shellcheck disable=SC2016
assert_contains "$crash_recovery_reap_path" \
  'recovery_branch="do-work/issue-${slot_issue}"' \
  "crash-recovery-reap.sh falls back to the canonical branch name when HEAD is unreadable"
assert_contains "$crash_recovery_reap_path" \
  'do-work/slice-*)' \
  "crash-recovery-reap.sh recognizes a split dispatch's neutral branch (#1562)"
# A recovered split-dispatch PR must NOT close the issue the split deliberately
# left open — no closing keyword, and no bare #<N> token that #624's
# auto-promotion could turn into one.
assert_contains "$crash_recovery_reap_path" \
  'recovery_is_slice' \
  "crash-recovery-reap.sh branches its PR body on whether the branch is a slice (#1562)"
assert_contains "$crash_recovery_reap_path" \
  'Ships a partial slice of https://github.com/%s/issues/%s' \
  "crash-recovery-reap.sh uses a bare-URL, non-closing reference for a recovered slice PR (#1562)"

# 8) The PR-create step is documented, including the existing-PR check that
#    handles the case where the worker pushed but crashed before PR
#    creation (moved into the script). `"$GH" pr create` replaces a bare
#    `gh pr create` literal — every gh invocation in the extracted script
#    goes through the testable $GH wrapper (see the script's own header).
assert_contains "$crash_recovery_reap_path" \
  "existing_pr" \
  "crash-recovery-reap.sh recovery checks for an existing open PR"
# shellcheck disable=SC2016
assert_contains "$crash_recovery_reap_path" \
  '"$GH" pr create' \
  "crash-recovery-reap.sh recovery calls gh pr create (via the testable \$GH wrapper)"
assert_contains "$crash_recovery_reap_path" \
  "Closes #" \
  "crash-recovery-reap.sh recovery PR body includes Closes keyword"
assert_contains "$crash_recovery_reap_path" \
  "--label shipyard" \
  "crash-recovery-reap.sh recovery PR carries --label shipyard"

# 9) Auto-merge is armed after recovery — the recovery PR enters the normal
#    merge train rather than sitting as a stale open PR (moved into the
#    script).
# shellcheck disable=SC2016
assert_contains "$crash_recovery_reap_path" \
  '"$GH" pr merge' \
  "crash-recovery-reap.sh recovery arms auto-merge on the recovered PR (via \$GH)"
# shellcheck disable=SC2016
# Literal grep needle — ${auto_merge_method} is matched verbatim, not expanded.
assert_contains "$crash_recovery_reap_path" \
  '--auto --"${auto_merge_method}"' \
  "crash-recovery-reap.sh arms with the config-resolved merge method, not a hardcoded --merge (#989)"

# 10) The recovered PR is handed back to the orchestrator's session_prs —
#     since the extraction, the script itself has no session_prs array to
#     append to (that's orchestrator in-session working memory, not
#     something a stateless script invocation can own); the .md prose now
#     documents the caller-side append instead of embedding the literal
#     bash line.
assert_contains "$steady_state_path" \
  "append it to \`session_prs\`" \
  "A.0.5 prose documents appending the recovered PR to session_prs"

# 11) The recovery log prefix is documented — operators can grep for it.
#     Still surviving prose (the fire-and-forget posture paragraph).
assert_contains "$steady_state_path" \
  "[reconcile-A.0.5-recovery]" \
  "A.0.5 prose references [reconcile-A.0.5-recovery] log prefix"
assert_contains "$crash_recovery_reap_path" \
  "[reconcile-A.0.5-recovery]" \
  "crash-recovery-reap.sh recovery uses [reconcile-A.0.5-recovery] log prefix"

# 12) Fire-and-forget posture is explicitly stated for recovery steps —
#     a failed push/PR-create must not abort the reconcile turn. Still
#     surviving prose.
assert_contains "$steady_state_path" \
  "A failed recovery step is not a reason to abort" \
  "A.0.5 recovery explicitly states fire-and-forget posture"

# 13) The recovery check runs BEFORE the actual reap call — ordering is
#     load-bearing (can't recover from a reaped worktree). This ordering
#     invariant now lives entirely inside the extracted script, so the
#     assertion moved with it.
assert_section_ordering "$crash_recovery_reap_path" \
  "Pre-reap recovery check (#493)" \
  "Crash-aware reap: reaps on every classification" \
  "recovery check precedes reap call in crash-recovery-reap.sh"

# 14) The zero-commits-ahead case is handled — when count == 0, the script
#     falls through to a dirty-working-tree check before skipping to the
#     reap (moved into the script — this is the literal `|| echo "0"`
#     default in the ahead_count read).
assert_contains "$crash_recovery_reap_path" \
  '"0"' \
  "crash-recovery-reap.sh references count==0 case"

# ── New assertions for issue #495 (dirty-worktree recovery) ──────────────

echo ""
echo "Test: dirty-worktree uncommitted-edits recovery (#495 extension)"
echo ""

# 15) Issue #495 is referenced inline — traceability requirement. Still
#     surviving prose.
assert_contains "$steady_state_path" \
  "[#495]" \
  "A.0.5 names issue #495 inline"

# 16) The dirty-worktree detection signal is present — git status --porcelain
#     is the load-bearing "does the worker have uncommitted edits?" check.
#     Present in BOTH the surviving prose and the script.
assert_contains "$steady_state_path" \
  "status --porcelain" \
  "A.0.5 prose documents git status --porcelain to detect dirty working tree"
assert_contains "$crash_recovery_reap_path" \
  "status --porcelain" \
  "crash-recovery-reap.sh uses git status --porcelain to detect dirty working tree"

# 17) The auto-commit step uses --no-verify (the pre-commit gate may be what
#     hung the worker; CI is the safety net) — moved into the script.
assert_contains "$crash_recovery_reap_path" \
  "commit --no-verify" \
  "crash-recovery-reap.sh dirty-worktree recovery commits with --no-verify"

# 18) The dirty-worktree path stages all changes before committing — moved
#     into the script.
assert_contains "$crash_recovery_reap_path" \
  "add -A" \
  "crash-recovery-reap.sh dirty-worktree recovery stages all changes with git add -A"

# 19) The dirty-worktree log line uses the same [reconcile-A.0.5-recovery]
#     prefix so operators can grep for it alongside the committed-work path
#     — moved into the script.
assert_contains "$crash_recovery_reap_path" \
  "dirty-worktree auto-commit" \
  "crash-recovery-reap.sh dirty-worktree recovery uses dirty-worktree auto-commit log marker"

# 20) The dirty-worktree recovery falls through to the same push path as
#     the committed-but-unpushed recovery — the push is present in the
#     elif branch, not duplicated at a separate level. Moved into the
#     script.
assert_section_ordering "$crash_recovery_reap_path" \
  "dirty working tree but no commits" \
  "Shared PR-create + auto-merge block" \
  "dirty-worktree branch precedes shared PR-create block in crash-recovery-reap.sh"

# 21) The shared PR-create block follows the if/elif so both paths use it —
#     the guard that defaults push_ok must be present to avoid set -u errors
#     when neither branch ran (clean worktree, no committed work). Moved
#     into the script.
# shellcheck disable=SC2016
# Literal grep needle — ${push_ok:-false} is matched verbatim, not expanded.
assert_contains "$crash_recovery_reap_path" \
  'push_ok="${push_ok:-false}"' \
  "crash-recovery-reap.sh guards push_ok with a default to handle clean-worktree case"

# 22) The scope guard (kind == "issue") also covers the dirty-worktree path —
#     the entire if/elif block lives inside the slot_kind == "issue" gate.
#     The code-level marker for the dirty-worktree branch is the elif
#     comment; it must appear AFTER the slot_kind gate, not before it.
#     Moved into the script.
# shellcheck disable=SC2016
# Literal grep needle — $slot_kind is matched verbatim, not expanded.
assert_section_ordering "$crash_recovery_reap_path" \
  '[ "$slot_kind" = "issue" ]' \
  "dirty working tree but no commits; attempting dirty-worktree" \
  "dirty-worktree recovery is inside the slot_kind==issue scope guard"

# 23) The auto-commit recovery is called out in the fire-and-forget posture
#     prose — the existing text covers recovery steps generically, and the
#     #495 issue number is still referenced in the surviving prose.
assert_contains "$steady_state_path" \
  "#495" \
  "A.0.5 fire-and-forget or recovery prose references #495"

# ── New assertions for issue #575 (version-coordination bump during recovery) ──

echo ""
echo "Test: version-coordination bump during A.0.5 recovery (#575)"
echo ""

# 24) Issue #575 is referenced inline — traceability requirement. Still
#     surviving prose.
assert_contains "$steady_state_path" \
  "[#575]" \
  "A.0.5 names issue #575 inline"

# 25) The version-coordination bump section header is present. Still
#     surviving prose.
assert_contains "$steady_state_path" \
  "Version-coordination bump during recovery" \
  "A.0.5 contains version-coordination bump section header"

# 26) The version-coordination bump is gated on version_coordination.enabled —
#     non-coordinated repos must be unaffected. The config-key NAME is still
#     documented in the surviving prose; the manifest_path key read is a
#     code-level detail that moved into the script.
assert_contains "$steady_state_path" \
  "version_coordination.enabled" \
  "A.0.5 prose documents version-bump gated on version_coordination.enabled config key"
assert_contains "$crash_recovery_reap_path" \
  "version_coordination.manifest_path" \
  "crash-recovery-reap.sh reads version_coordination.manifest_path config key"

# 27) The bump compares the worktree manifest version against origin/<default>
#     to detect whether the worker never reached its bump step. Moved into
#     the script.
assert_contains "$crash_recovery_reap_path" \
  "wt_version" \
  "crash-recovery-reap.sh reads worktree manifest version"
assert_contains "$crash_recovery_reap_path" \
  "origin_version" \
  "crash-recovery-reap.sh reads origin manifest version"
# shellcheck disable=SC2016
# Literal grep needle — $wt_version and $origin_version are matched verbatim.
assert_contains "$crash_recovery_reap_path" \
  '"$wt_version" != "$origin_version"' \
  "crash-recovery-reap.sh skips bump when worktree version differs from origin (worker already bumped)"

# 28) The bump applies to both the dirty-worktree and committed-but-unpushed
#     recovery paths — the helper function is called in both branches.
#     Moved into the script.
assert_contains "$crash_recovery_reap_path" \
  "a05_version_bump" \
  "crash-recovery-reap.sh defines a05_version_bump helper function"

# 29) The committed-but-unpushed path adds the bump as a dedicated commit
#     before the push, not after. Moved into the script.
assert_section_ordering "$crash_recovery_reap_path" \
  "Step 1.5: version-coordination bump (#575). The committed work may" \
  "Step 2: push the branch. Pre-commit hooks already passed" \
  "committed-path version-bump fires before push in crash-recovery-reap.sh"

# 30) The dirty-worktree path applies the bump BEFORE git add -A so it folds
#     into the auto-commit (not as a separate commit). Moved into the
#     script.
# shellcheck disable=SC2016
# Literal grep needle — $worktree_path is matched verbatim, not expanded.
assert_section_ordering "$crash_recovery_reap_path" \
  "Step 1.5: version-coordination bump (#575). Apply the bump to the" \
  'git -C "$worktree_path" add -A' \
  "dirty-worktree version-bump fires before git add -A in crash-recovery-reap.sh"

# 31) The WARNING log message is present for the can't-compute case. Moved
#     into the script.
assert_contains "$crash_recovery_reap_path" \
  "WARNING: recovered PR has no version bump — manual release bump required" \
  "crash-recovery-reap.sh logs loud WARNING when bump can't be computed"

# 32) The CHANGELOG stub is prepended when changelog_path is configured.
#     Moved into the script.
assert_contains "$crash_recovery_reap_path" \
  "vc_changelog" \
  "crash-recovery-reap.sh reads version_coordination.changelog_path"
assert_contains "$crash_recovery_reap_path" \
  "Crash-recovered by orchestrator A.0.5" \
  "crash-recovery-reap.sh CHANGELOG stub includes crash-recovered marker"

# 33) The bump is fire-and-forget — a failed bump must not abort the push.
#     The comment explicitly states this per the issue acceptance criteria.
#     Moved into the script (the wording is now split across the function's
#     own comment lines — check for the surviving substring on its own
#     line rather than the exact multi-line join).
assert_contains "$crash_recovery_reap_path" \
  "Fire-and-forget: failure logs an" \
  "crash-recovery-reap.sh version-bump is explicitly fire-and-forget in comments"

# 34) The non-coordinated-repo path is called out — repos without
#     version_coordination configured must be unaffected. Still surviving
#     prose.
assert_contains "$steady_state_path" \
  "Non-version-coordinated repos are unaffected" \
  "A.0.5 prose documents that non-coordinated repos are unaffected"

echo ""
echo "Results: $pass passed, $fail failed"
if (( fail > 0 )); then
  exit 1
fi
exit 0
