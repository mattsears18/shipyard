#!/usr/bin/env bash
# Test: both non-scanner conflict-marker safety nets shell out to the
# authoritative scanner instead of re-implementing its pattern (issue #1462).
#
# Background — issue #1462: two call sites asserted "no conflict markers
# survived" with a raw, whole-tree `git grep -nE '^(<{7}|={7}|>{7})( |$)' --
# .` instead of calling the repo's own `conflict-marker-scan.sh`. On
# `mattsears18/shipyard` that raw pattern ALWAYS matched, even on a
# completely clean tree with no rebase in progress, because the repo ships
# `plugins/shipyard/scripts/tests/conflict-marker-scan.test.sh` as a
# permanent fixture containing intentional marker-shaped test strings. The
# raw grep has no notion of the scanner's `conflict-marker-scan: allow`
# opt-out directive, so it false-positived deterministically:
#
#   - scripts/resolve-manifest-only-dirty.sh line ~427 — the #1377/#1380
#     in-process DIRTY-PR resolver could never return `resolved` on this
#     repo; every run deferred with "conflict-markers-remain" even after a
#     correct resolution.
#   - agents/issue-worker/fix-rebase.md step 5.5 — every fix-rebase worker
#     had to reason PAST a spec step explicitly labeled "non-negotiable" to
#     avoid bailing `blocked rebase` on a perfectly good resolution.
#
# The defining characteristic of this bug is that it fires on a CLEAN tree
# of THIS repo — a synthetic, throwaway fixture would never reproduce it,
# because the false positive depends on the real fixture file's real
# content and real path actually being present in the tree being scanned.
# This test therefore exercises the fix against a real worktree checked out
# from this repository's own HEAD (which carries the real fixture), not a
# constructed temp repo.
#
# This test pins two layers:
#   (A) Spec/source assertions — both call sites now invoke
#       conflict-marker-scan.sh rather than only the raw pattern.
#   (B) Behavioral — using the exact call shape each site uses (a `cd`/`-C`
#       into an ephemeral nested `git worktree add --detach` checkout of
#       this repo, then a no-args scanner invocation), assert the check
#       reports CLEAN on this repo's real tree, and still correctly FAILS
#       when a genuine, non-fixture conflict marker is present (preserving
#       the #436 safety property — this fix must never turn the assertion
#       into a no-op).
#
# Pure bash + git. Run with:
#
#   bash plugins/shipyard/scripts/tests/conflict-marker-callsite-regression.test.sh
#
# This file injects a genuine marker into a throwaway file inside a nested
# worktree (never a tracked file in the real repo) to exercise the
# "still fatal" behavioral check, so it carries the scanner's own opt-out
# directive on the next line — otherwise the gate would flag this file's
# own heredoc as a real conflict.
#   conflict-marker-scan: allow

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

scanner="$repo_root/plugins/shipyard/scripts/conflict-marker-scan.sh"
resolver="$repo_root/plugins/shipyard/scripts/resolve-manifest-only-dirty.sh"
fix_rebase="$repo_root/plugins/shipyard/agents/issue-worker/fix-rebase.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()   { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad()  { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_file_exists() {
  if [[ -f "$1" ]]; then ok "$2"; else bad "$2 (missing: $1)"; fi
}

assert_contains() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (expected in $1: $2)"; fi
}

assert_not_contains() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$3 (unexpectedly still present in $1: $2)"; else ok "$3"; fi
}

echo "conflict-marker call-site regression tests (issue #1462)"
echo

# (1) All three artifacts exist.
assert_file_exists "$scanner" "scripts/conflict-marker-scan.sh exists"
assert_file_exists "$resolver" "scripts/resolve-manifest-only-dirty.sh exists"
assert_file_exists "$fix_rebase" "agents/issue-worker/fix-rebase.md exists"

# (2) resolve-manifest-only-dirty.sh shells out to the scanner rather than
# relying solely on the raw whole-tree grep as its primary check.
if [[ -f "$resolver" ]]; then
  # shellcheck disable=SC2016  # literal needle — must NOT expand $here/$CONFLICT_SCANNER
  assert_contains "$resolver" 'CONFLICT_SCANNER="$here/conflict-marker-scan.sh"' \
    "resolve-manifest-only-dirty.sh resolves a path to the scanner script"
  # shellcheck disable=SC2016  # literal needle — must NOT expand $WT_DIR/$CONFLICT_SCANNER
  assert_contains "$resolver" 'cd "$WT_DIR" && bash "$CONFLICT_SCANNER"' \
    "resolve-manifest-only-dirty.sh invokes the scanner inside the ephemeral worktree"
  assert_contains "$resolver" 'Issue #1462' \
    "resolve-manifest-only-dirty.sh references originating issue #1462"
fi

# (3) fix-rebase.md step 5.5 shells out to the scanner rather than only the
# raw whole-tree grep.
if [[ -f "$fix_rebase" ]]; then
  # shellcheck disable=SC2016  # literal needle — must NOT expand $CLAUDE_PLUGIN_ROOT
  assert_contains "$fix_rebase" 'conflict_scanner="$CLAUDE_PLUGIN_ROOT/scripts/conflict-marker-scan.sh"' \
    "fix-rebase.md step 5.5 resolves a path to the scanner script"
  # Direct exec, NOT `bash "$conflict_scanner"` — prefixing a launcher onto a
  # script path the isolation guard can't statically resolve is refused
  # (issue #1566; see commands/do-work/dont.md § "The launcher rule").
  # shellcheck disable=SC2016  # literal needle — must NOT expand $conflict_scanner
  assert_contains "$fix_rebase" '"$conflict_scanner"' \
    "fix-rebase.md step 5.5 invokes the scanner"
  assert_contains "$fix_rebase" 'https://github.com/mattsears18/shipyard/issues/1462' \
    "fix-rebase.md links to originating issue #1462"
  # The prior version's prose described the mechanism as a bare "git grep"
  # for surviving markers; that specific framing should be gone from the
  # 4.6 cross-reference now that the mechanism is the scanner (the raw grep
  # itself is still allowed to survive as the missing-scanner fallback).
  assert_not_contains "$fix_rebase" "Step 5.5's \`git grep\` for surviving markers" \
    "fix-rebase.md's 4.6 cross-reference no longer describes step 5.5 as a bare git grep"
fi

# (4) Behavioral, real-repo regression: build an ephemeral nested worktree
# from THIS repo's own HEAD (carries the real conflict-marker-scan.test.sh
# fixture, exactly like the resolver's own $WT_DIR and a fix-rebase
# worker's own checkout). Confirm the scanner — invoked exactly the way
# both call sites now invoke it (cd into the worktree, no args) — reports
# CLEAN. This is the assertion that would have caught #1462: a purely
# synthetic fixture repo would never reproduce the false positive, because
# it depends on this repo's own real fixture file being present.
work="$(mktemp -d)"
nested_wt="$work/nested-worktree"
cleanup() {
  if [[ -d "$nested_wt" ]]; then
    git -C "$repo_root" worktree remove "$nested_wt" --force >/dev/null 2>&1 || true
  fi
  git -C "$repo_root" worktree prune >/dev/null 2>&1 || true
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT

if git -C "$repo_root" worktree add --detach "$nested_wt" HEAD --quiet >/dev/null 2>&1; then
  ok "created ephemeral nested worktree from this repo's HEAD"

  if ( cd "$nested_wt" && bash "$scanner" >/dev/null 2>&1 ); then
    ok "scanner (call shape both sites use) reports CLEAN on a real nested worktree of this repo"
  else
    bad "scanner reported markers on a real nested worktree of this repo's clean HEAD — the #1462 false positive has regressed"
  fi

  # (5) Sanity check: the OLD raw pattern genuinely trips on this repo's
  # fixture, so this test is actually exercising the bug's precondition
  # and not vacuously passing. This mirrors the exact pattern both call
  # sites used to run inline, applied read-only, purely to demonstrate the
  # false positive still exists in the naive form — it is not re-added to
  # any production code path by this test.
  if ( cd "$nested_wt" && git grep -qnE '^(<{7}|={7}|>{7})( |$)' -- . 2>/dev/null ); then
    ok "confirms the raw whole-tree grep still false-positives on this repo's own fixture (why the fix was needed)"
  else
    bad "the raw whole-tree grep no longer matches this repo's fixture — this test's premise is stale, investigate before trusting check (4)"
  fi

  # (6) Preserve the safety property: a GENUINE marker in a real (non-
  # fixture) tracked file inside the nested worktree must still be caught
  # by the scanner, using the same call shape as (4). This proves the fix
  # did not weaken the #436 assertion into a no-op.
  genuine_conflict="$nested_wt/.shipyard-test-genuine-conflict.txt"
  {
    printf 'line before\n'
    printf '%s\n' '<<<<<<< HEAD'
    printf 'ours\n'
    printf '%s\n' '======='
    printf 'theirs\n'
    printf '%s\n' '>>>>>>> 0ff725a'
    printf 'line after\n'
  } > "$genuine_conflict"
  ( cd "$nested_wt" && git add "$genuine_conflict" >/dev/null 2>&1 )

  if ( cd "$nested_wt" && bash "$scanner" >/dev/null 2>&1 ); then
    bad "scanner FAILED to catch a genuine marker in a real nested worktree of this repo (safety net weakened)"
  else
    ok "scanner still catches a genuine marker in a real nested worktree of this repo (#436 safety property preserved)"
  fi
else
  bad "could not create an ephemeral nested worktree from this repo's HEAD (git worktree add failed) — cannot run the behavioral regression"
fi

echo
echo "  ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
