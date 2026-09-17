#!/usr/bin/env bash
# Test: the fix-rebase worker contract documents a post-rebase line-survival
# guard that bails (instead of force-pushing) when git's own "clean" auto-merge
# silently drops or alters lines the PR's commit added — even though no
# conflict marker survived, no CHANGELOG heading was deleted, and the
# whole-PR diff is non-empty.
#
# Background — issue #983: a `shipyard:fix-rebase-worker` dispatched against
# a lightwork PR rebased `.github/workflows/ci.yml` onto main. `git rebase`
# reported "Auto-merging .github/workflows/ci.yml" — a CLEAN 3-way merge,
# zero conflict markers. But the file has high internal repetition (many
# structurally-identical `uses: actions/cache@v6` / `id:` / `with:` step
# blocks across jobs), and a large line-offset shift from two prior PRs
# restructuring the same file meant git's diff3 matching mismatched context
# anchors and silently spliced content from the wrong block: a deliberate,
# load-bearing per-job split (one job saves the cache, three jobs only
# restore it) was silently collapsed to one variant across three jobs, with
# their original explanatory comments replaced by mismatched, plausible-
# looking text. The corresponding pinned regression test was ALSO silently
# corrupted in the same auto-merge pass (a regex weakened, an entire test
# case deleted) even though main never touched that test file at all. None
# of the existing guards (§5.5 conflict-marker grep, §5.6 CHANGELOG
# monotonicity, §5.7 whole-PR empty-diff check) would have caught this —
# they all key off unresolved markers, deleted CHANGELOG headings, or the
# *whole-PR* diff going empty; none of them assert that lines THIS PR added
# actually survived the merge, verbatim, in every file it touched.
#
# The fix adds a §5.8 post-rebase line-survival guard: for every file the
# PR's own commit(s) touched (relative to the pre-rebase merge-base), assert
# every line the PR added is still present verbatim somewhere in that file
# after the rebase. The guard is deliberately generic and mechanical — it
# never inspects which file or what the content means, only that added
# content survived intact — so it needs no domain knowledge of any specific
# file to catch this class of silent corruption.
#
# This test is the regression guard: if the guard is removed, its
# load-bearing semantics (the bail string, the merge-base-relative added-line
# extraction, the exact-line survival check, the before-force-push
# placement) regress, or its "no per-file hard-coding" guarantee is
# violated, the test fails.
#
# Issue #1175 follow-up: the exact-line survival check itself was extracted
# out of this file's inline `grep -vFxf` snippet into a standalone,
# behaviorally-tested script (verify-added-lines-survived.sh) after that
# inline snippet was found to silently false-negative under a shadowed
# `grep`. This file's assertions were updated accordingly — see
# verify-added-lines-survived.test.sh for the script's own behavioral tests
# (clean/corrupted/deleted/bad-ref/self-check/shadowed-grep-independence).
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/fix-rebase-line-survival-guard.test.sh

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

fix_rebase_path="$repo_root/plugins/shipyard/agents/issue-worker/fix-rebase.md"
verify_script_path="$repo_root/plugins/shipyard/scripts/verify-added-lines-survived.sh"

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

assert_not_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    did NOT expect to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
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

echo "fix-rebase line-survival guard regression tests (issue #983)"
echo

# (0) The fix-rebase spec must exist.
assert_file_exists "$fix_rebase_path" "agents/issue-worker/fix-rebase.md exists"

# The needles below are literal substrings of the markdown spec; the
# `$MERGE_BASE` / `$HEAD_REF` / `$DEFAULT_BRANCH` tokens are meant to be
# matched verbatim (documented shell-variable references inside the spec's
# code blocks), so single quotes are correct and SC2016's "did you mean to
# expand" does not apply.
# shellcheck disable=SC2016
if [[ -f "$fix_rebase_path" ]]; then
  # (1) §5.8 post-rebase line-survival guard — the root fix.
  assert_contains "$fix_rebase_path" "5.8. **Assert every line the PR's own commit added is still present verbatim" \
    "fix-rebase.md adds a §5.8 line-survival guard (issue #983)"
  assert_contains "$fix_rebase_path" "https://github.com/mattsears18/shipyard/issues/983" \
    "fix-rebase.md links to the originating issue #983"
  assert_contains "$fix_rebase_path" "line-survival check did not pass" \
    "fix-rebase.md documents the canonical corruption bail string"
  assert_contains "$fix_rebase_path" "blocked rebase #<M>:" \
    "fix-rebase.md uses the blocked rebase #<M>: return format"

  # (2) The guard must be merge-base-relative (stable across which
  # conflict-resolution path was taken) and use the pre-rebase HEAD_REF ref,
  # untouched until the §6 force-push.
  assert_contains "$fix_rebase_path" 'MERGE_BASE=$(git merge-base "origin/$HEAD_REF" "origin/$DEFAULT_BRANCH")' \
    "fix-rebase.md computes the merge-base between the pre-rebase head and the rebase target"

  # (3) The core mechanism: fix-rebase.md delegates the exact verbatim
  # line-survival comparison to the extracted, standalone script rather than
  # re-inlining it (issue #1175) — this is what keeps the check testable and
  # independent of the calling shell's own `grep` semantics.
  assert_file_exists "$verify_script_path" \
    "scripts/verify-added-lines-survived.sh exists"
  assert_contains "$fix_rebase_path" 'scripts/verify-added-lines-survived.sh' \
    "fix-rebase.md invokes verify-added-lines-survived.sh rather than an inline comparison"
  # Direct exec, NOT `bash "$CLAUDE_PLUGIN_ROOT/..."` — the launcher form is
  # refused by the isolation guard (issue #1566).
  assert_contains "$fix_rebase_path" '"$CLAUDE_PLUGIN_ROOT/scripts/verify-added-lines-survived.sh" "$MERGE_BASE" "origin/$HEAD_REF"' \
    "fix-rebase.md's invocation passes MERGE_BASE and the pre-rebase head ref"
  assert_contains "$fix_rebase_path" "it never inspects *which* file or *what* the content means" \
    "fix-rebase.md states the guard is content-agnostic (no per-file hard-coding)"
  assert_contains "$fix_rebase_path" "https://github.com/mattsears18/shipyard/issues/1175" \
    "fix-rebase.md links to the extraction issue #1175"

  # A regression to watch for: the original inline snippet's per-file
  # enumeration loop must not be re-inlined into the spec's own code block —
  # it now lives solely inside verify-added-lines-survived.sh. (The exact
  # `grep -vFxf "$f" <<<"$ADDED_LINES"` invocation is fine to keep appearing
  # in prose describing the historical bug — checked via single-line needles
  # below, since assert_not_contains's grep -F match is line-scoped.)
  assert_not_contains "$fix_rebase_path" 'PR_TOUCHED_FILES=$(git diff --name-only "$MERGE_BASE" "origin/$HEAD_REF")' \
    "fix-rebase.md does not re-inline the old PR_TOUCHED_FILES enumeration loop"
  assert_not_contains "$fix_rebase_path" 'MISSING=$(grep -vFxf "$f" <<<"$ADDED_LINES" || true)' \
    "fix-rebase.md does not re-inline the shadowing-prone grep -vFxf comparison line"

  # A regression to watch for: a future edit narrowing the guard to a
  # specific filename or extension would defeat its generality. Assert the
  # guard's code block does not special-case any concrete file path.
  assert_not_contains "$fix_rebase_path" 'if [ "$f" = "ci.yml" ]' \
    "fix-rebase.md's guard does not hard-code a specific filename"

  # (4) The guard MUST be placed AFTER §5.7 (empty-diff check) and BEFORE §6
  # (the force-push). Placing it after the push would defeat it entirely —
  # the corrupted content would already be force-pushed and live on the PR.
  assert_section_ordering "$fix_rebase_path" \
    "5.7. **Post-rebase empty-diff guard" \
    "5.8. **Assert every line the PR's own commit added is still present verbatim" \
    "§5.8 lands after §5.7 empty-diff guard"
  assert_section_ordering "$fix_rebase_path" \
    "5.8. **Assert every line the PR's own commit added is still present verbatim" \
    "6. **Push the rebased branch.**" \
    "§5.8 lands before §6 (the force-push)"

  # (5) Issue #1215: §5.8's invocation must pass the §4.6-recorded
  # known-rewrites file when present, so the version-coordination carve-out's
  # sanctioned renumbering doesn't perpetually trip this guard — but the
  # unconditional two-arg call must still be the literal call site (preserved
  # via optional-argument expansion, not replaced) so a dispatch where §4.6
  # never fired runs byte-for-byte the original check.
  assert_contains "$fix_rebase_path" 'CANDIDATE_KNOWN_REWRITES="$WORKTREE_PATH/.shipyard-scratch/vc-known-rewrites.tsv"' \
    "fix-rebase.md's §5.8 invocation looks for the §4.6-recorded known-rewrites file"
  assert_contains "$fix_rebase_path" '${KNOWN_REWRITES:+"$KNOWN_REWRITES"}' \
    "fix-rebase.md's §5.8 invocation passes the known-rewrites file only when it exists"
  assert_contains "$fix_rebase_path" 'byte-for-byte the pre-#1215 unconditional check' \
    "fix-rebase.md documents that the no-known-rewrites-file path is unchanged from before #1215"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
