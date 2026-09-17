#!/usr/bin/env bash
# Test: a split dispatch gets a neutral `do-work/slice-<N>` branch, and every
# mechanism that re-derives a dispatch's branch from the issue number
# recognizes it (issue #1562).
#
# Background
# ----------
# `dispatch-rules.md`'s `mode: issue-work` template used to hand every
# dispatch the branch name `do-work/issue-<N>` unconditionally — including a
# dispatch the orchestrator already knew would end in a SPLIT, whose PR must
# reference #<N> without closing it (an operator residual, §6.5/#851; a
# verification slice, §6.6/#852). A branch literally named
# `do-work/issue-<N>` is an independent auto-link vector: #893's repro found
# it registering #<E> in `closingIssuesReferences` on its own, surviving a
# body rewrite, a commit-message rewrite, and even a close+reopen, clearing
# only once the PR was abandoned for a neutrally-named branch. So the
# dispatch template handed the worker exactly the name its own
# leak-verification fragment warns against.
#
# Two deliberate deviations from the issue's own "Suggested fix", both
# asserted below so a future edit can't silently undo the reasoning:
#
#   1. The neutral name is a bare `do-work/slice-<N>`, NOT the suggested
#      `do-work/slice-<N>-<short>`. The remote branch name must stay
#      deterministically derivable from <N> alone — issue-work.md §3 makes
#      that the whole point of the canonical name, and four orchestrator-side
#      mechanisms re-derive it from <N> without being told (the concurrency
#      guard, the shipped-immediate reap, the drain pre-dispatch reap, and
#      A.0.5's crash-recovery push). A free-text slug would make the branch
#      un-re-derivable and cost a split dispatch its concurrency guard and
#      its crashed-worker recovery.
#
#   2. `phase_1_scope` is NOT in the trigger set, though the issue named it.
#      A plain phase-1 slice DOES resolve #<N> — its own augmentation says
#      out-of-scope items get "filed as follow-up issues", and neither
#      issue-work.md §5's two documented non-closing exceptions nor §5.85's
#      five leak-verification trigger shapes list it. Triggering on it would
#      strip the canonical name from the common sliced case for no benefit.
#
# CHECK 3 of check-dispatch-prompt-parity.mjs already enforces that the
# Context paragraph reaches `buildIssueWorkPrompt` (its augmentation set is
# derived from dispatch-rules.md's own headings, #918) — this suite covers
# what parity cannot: the trigger set, the name shape, and the four
# branch-derivation sites.
#
# Pure bash + grep, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/split-dispatch-branch-name-1562.test.sh

# Every assertion needle below is a LITERAL grep pattern matched verbatim
# against a source file — `$foo` / `${foo}` inside one is text to find, never
# something to expand here.
# shellcheck disable=SC2016

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

dispatch_rules="$repo_root/plugins/shipyard/commands/do-work/dispatch-rules.md"
issue_work="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"
leak_fragment="$repo_root/plugins/shipyard/agents/issue-worker/issue-work-parent-epic-leak.md"
builder_src="$repo_root/plugins/shipyard/workflows/prompt-templates/issue-work.mjs"
generated="$repo_root/plugins/shipyard/workflows/do-work-dispatch.workflow.js"
guard="$repo_root/plugins/shipyard/scripts/concurrent-session-guard.sh"
shipped_reap="$repo_root/plugins/shipyard/scripts/shipped-immediate-branch-reap.sh"
drain_reap="$repo_root/plugins/shipyard/scripts/drain-pre-dispatch-branch-reap.sh"
crash_reap="$repo_root/plugins/shipyard/scripts/crash-recovery-reap.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_contains() {
  local path="$1" needle="$2" label="$3"
  if [[ ! -f "$path" ]]; then
    printf '  %sFAIL%s  %s (file missing: %s)\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail + 1))
    return
  fi
  if grep -qF -- "$needle" "$path" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass + 1))
  else
    printf '  %sFAIL%s  %s (did not find %q in %s)\n' "$RED" "$RESET" "$label" "$needle" "$path"
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local path="$1" needle="$2" label="$3"
  if [[ ! -f "$path" ]]; then
    printf '  %sFAIL%s  %s (file missing: %s)\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail + 1))
    return
  fi
  if grep -qF -- "$needle" "$path" 2>/dev/null; then
    printf '  %sFAIL%s  %s (unexpectedly found %q in %s)\n' "$RED" "$RESET" "$label" "$needle" "$path"
    fail=$((fail + 1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass + 1))
  fi
}

echo "== split-dispatch-branch-name-1562.test.sh =="
echo
echo "Test: dispatch-rules.md documents the augmentation and its trigger set"

assert_contains "$dispatch_rules" "Split-dispatch branch-name augmentation" \
  "dispatch-rules.md carries a **...augmentation** heading (so parity CHECK 3 derives it)"
assert_contains "$dispatch_rules" "Neutral branch name (split dispatch, #1562):" \
  "dispatch-rules.md's Context blockquote carries the anchor phrase"
assert_contains "$dispatch_rules" 'an `operator_residual` **or** a `verification_slice` field' \
  "the trigger set is operator_residual OR verification_slice"
assert_contains "$dispatch_rules" 'Why `phase_1_scope` is NOT in the trigger set' \
  "dispatch-rules.md records WHY phase_1_scope is excluded (deviation from the issue's suggestion)"
assert_contains "$dispatch_rules" "Why a bare \`do-work/slice-<N>\`, and not the \`do-work/slice-<N>-<short>\`" \
  "dispatch-rules.md records WHY the name carries no free-text slug"
assert_contains "$dispatch_rules" 'Branch: `<dispatch_branch>`' \
  "the issue-work template's Branch: line is the computed <dispatch_branch>, not a hardcoded name"
assert_contains "$dispatch_rules" '"splitDispatch":' \
  "the Workflow-substrate issue-work payload documents the splitDispatch field"

# The neutral name must never carry a free-text slug — that would break every
# re-derivation site below. Guard the shape itself, not just the prose.
assert_not_contains "$dispatch_rules" 'do-work/slice-<N>-<short>-' \
  "dispatch-rules.md never prescribes a slugged slice branch as the actual name"

echo
echo "Test: the builder renders the paragraph (parity CHECK 3's other half)"

assert_contains "$builder_src" "unit.splitDispatch" \
  "buildIssueWorkPrompt gates the paragraph on unit.splitDispatch"
assert_contains "$builder_src" "Neutral branch name (split dispatch, #1562):" \
  "buildIssueWorkPrompt renders the anchor phrase verbatim"
assert_contains "$generated" "Neutral branch name (split dispatch, #1562):" \
  "the generated workflow.js carries the paragraph (generator was re-run)"

echo
echo "Test: the worker spec takes the dispatched branch name verbatim"

assert_contains "$issue_work" "REMOTE_BRANCH=\"<the dispatch prompt's Branch: line, verbatim>\"" \
  "issue-work.md §3 sets REMOTE_BRANCH from the dispatch prompt, not a hardcoded literal"
assert_not_contains "$issue_work" 'REMOTE_BRANCH="do-work/issue-<N>"' \
  "issue-work.md §3 no longer hardcodes the canonical name (it would contradict a slice dispatch)"
assert_contains "$issue_work" 'never "correct" it (#1562)' \
  "issue-work.md §3 forbids renaming the dispatched branch"
assert_contains "$issue_work" 'or .headRefName ==' \
  "issue-work.md §0's duplicate-PR cross-check also matches the slice branch"
assert_contains "$leak_fragment" "do-work/slice-<N>" \
  "the leak fragment notes the orchestrator now supplies the neutral name up front"

echo
echo "Test: every branch-re-derivation site recognizes do-work/slice-<N>"

assert_contains "$guard" 'slice_ref="do-work/slice-${issue}"' \
  "concurrent-session-guard.sh matches the slice branch (same issue, same race)"
assert_contains "$guard" '[ "$branch_ref" != "$slice_ref" ]' \
  "concurrent-session-guard.sh's worktree filter accepts either exact name"

assert_contains "$shipped_reap" 'slice_ref="do-work/slice-${issue}"' \
  "shipped-immediate-branch-reap.sh matches the slice branch"
assert_contains "$shipped_reap" 'git branch -D "$branch_ref"' \
  "shipped-immediate-branch-reap.sh drops the ref the worktree actually held"

assert_contains "$drain_reap" 'do-work/issue-*|do-work/slice-*)' \
  "drain-pre-dispatch-branch-reap.sh force-reaps a completed slice worktree too"

assert_contains "$crash_reap" 'do-work/slice-*)' \
  "crash-recovery-reap.sh recognizes a slice branch"
assert_contains "$crash_reap" 'push origin "HEAD:refs/heads/${recovery_branch}"' \
  "crash-recovery-reap.sh pushes an explicit refspec, not a hardcoded local refname"
assert_contains "$crash_reap" 'recovery_is_slice="true"' \
  "crash-recovery-reap.sh flags a slice recovery"
assert_contains "$crash_reap" 'Ships a partial slice of https://github.com/%s/issues/%s' \
  "a recovered slice PR references the issue by bare URL, with no closing keyword"

# The recovered-slice PR body/title must carry no bare `#<N>` token either —
# #624's auto-promotion hazard turns one into a closing reference with no
# keyword present at all. `%s` interpolation of slot_issue is only safe when
# it is not preceded by a `#`.
slice_body_line=$(grep -n 'Ships a partial slice' "$crash_reap" | head -1 | cut -d: -f1)
slice_title_line=$(grep -n 'crash-recovered partial slice for issue' "$crash_reap" | head -1 | cut -d: -f1)
if [[ -z "$slice_body_line" || -z "$slice_title_line" ]]; then
  printf '  %sFAIL%s  could not locate the recovered-slice PR title/body to check for a bare #<N> token\n' "$RED" "$RESET"
  fail=$((fail + 1))
elif sed -n "${slice_body_line}p;${slice_title_line}p" "$crash_reap" | grep -qE '#(%s|\$\{?slot_issue)'; then
  printf '  %sFAIL%s  recovered slice PR title/body contains a bare #<N> token (#624 auto-promotion hazard)\n' "$RED" "$RESET"
  fail=$((fail + 1))
else
  printf '  %sPASS%s  recovered slice PR title/body contains no bare #<N> token (#624)\n' "$GREEN" "$RESET"
  pass=$((pass + 1))
fi

echo
echo "Results: ${GREEN}${pass} passed${RESET}, ${RED}${fail} failed${RESET}"
[[ $fail -eq 0 ]]
