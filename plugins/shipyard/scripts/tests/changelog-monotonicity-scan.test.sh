#!/usr/bin/env bash
# Test: CHANGELOG monotonicity gate (issue #555).
#
# Background — issue #555: during a high-concurrency /shipyard:do-work
# session, sibling-PR merge conflict resolutions silently deleted released
# CHANGELOG entries from `main`. PR #552 and PR #553 merged via the
# admin-direct path; their merge-time conflict resolutions dropped main's
# `### 1.9.10` entry and the `### 1.9.9` heading + summary paragraph from
# `main` with no CI gate firing. The existing conflict-marker gate (#436)
# only catches *unresolved* markers — a resolved-wrong merge that silently
# deletes whole heading blocks is invisible to it.
#
# This test pins three artifacts:
#
#   1. The script itself (changelog-monotonicity-scan.sh) — behavioral tests
#      covering the clean-pass, deletion-detected, opt-out directive, and
#      false-positive (PR's own new entry) cases.
#   2. The worker-side assertions in agents/issue-worker/fix-rebase.md and
#      agents/issue-worker/issue-work.md.
#   3. The working-tree scan — the script must report clean against the
#      actual CHANGELOG.md on the current branch (mirrors the #436 test's
#      "exits 0 on the current (clean) repo" check).
#
# If any of the above regresses, this test fails.
#
# Pure bash + git. Run with:
#
#   bash plugins/shipyard/scripts/tests/changelog-monotonicity-scan.test.sh
#
# This file constructs synthetic CHANGELOG fixtures (not the real file) for
# the behavioral unit tests. The test DOES run the scanner against the real
# CHANGELOG.md on the current branch for the live-repo check. No fixture
# here contains a bare `### <version>` heading that could confuse the real
# scanner, so no opt-out directive is needed on this file.
#   changelog-monotonicity-scan: allow

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

scanner="$repo_root/plugins/shipyard/scripts/changelog-monotonicity-scan.sh"
fix_rebase="$repo_root/plugins/shipyard/agents/issue-worker/fix-rebase.md"
issue_work="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_file_exists() {
  if [[ -f "$1" ]]; then ok "$2"; else bad "$2 (missing: $1)"; fi
}

assert_contains() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (expected in $1: $2)"; fi
}

echo "CHANGELOG monotonicity gate regression tests (issue #555)"
echo

# ── (1) Artifacts exist ───────────────────────────────────────────────────────
assert_file_exists "$scanner"    "scripts/changelog-monotonicity-scan.sh exists"
assert_file_exists "$fix_rebase" "agents/issue-worker/fix-rebase.md exists"
assert_file_exists "$issue_work" "agents/issue-worker/issue-work.md exists"

# ── (2) The scanner is executable (or at least a regular file) ───────────────
if [[ -f "$scanner" ]]; then
  ok "scanner file exists and is readable"
else
  bad "scanner file missing"
fi

# ── (3) Live-repo check: scanner exits 0 on the current working tree ─────────
# This mirrors the #436 test's "exits 0 on the current (clean) repo" check.
# It runs the scanner against origin/HEAD (or origin/main) as the merge-base —
# the same comparison CI performs on a PR against main.
if [[ -f "$scanner" ]]; then
  __diag_out="$(bash "$scanner" 2>&1)"
  __diag_rc=$?
  if [[ $__diag_rc -eq 0 ]]; then
    ok "scanner exits 0 on the current working-tree CHANGELOG.md"
  else
    bad "scanner exited non-zero on the current working tree — was a heading deleted?"
    echo "DIAG rc=$__diag_rc" >&2
    echo "DIAG output: $__diag_out" >&2
    echo "DIAG pwd: $(pwd)" >&2
    echo "DIAG git rev-parse --show-toplevel: $(git rev-parse --show-toplevel 2>&1)" >&2
    echo "DIAG git rev-parse --verify origin/HEAD: $(git rev-parse --verify origin/HEAD 2>&1)" >&2
    echo "DIAG git rev-parse --verify origin/main: $(git rev-parse --verify origin/main 2>&1)" >&2
    echo "DIAG git rev-parse HEAD: $(git rev-parse HEAD 2>&1)" >&2
    echo "DIAG git merge-base HEAD origin/main: $(git merge-base HEAD origin/main 2>&1)" >&2
  fi
fi

# ── (4) Behavioral unit tests using synthetic git fixture repos ──────────────
# Every fixture is constructed in a temp dir so it's isolated and uses
# `git init -b main` to pin the default branch (per worker-preamble
# § "Pin the default branch in git-using test fixtures" — CI's Ubuntu runner
# uses init.defaultBranch=master, so a bare `git init` without -b would
# produce a 'master' branch and any `main` reference would error).
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Helper: create a minimal git repo with a base commit whose CHANGELOG.md
# contains the given content, then create a head commit with different content.
# Usage: make_fixture <dir> <base-changelog> <head-changelog>
make_fixture() {
  local dir="$1" base_content="$2" head_content="$3"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test"
  printf '%s' "$base_content" > "$dir/CHANGELOG.md"
  git -C "$dir" add CHANGELOG.md
  git -C "$dir" commit -q -m "base"
  printf '%s' "$head_content" > "$dir/CHANGELOG.md"
  git -C "$dir" add CHANGELOG.md
  git -C "$dir" commit -q -m "head"
}

# (4a) CLEAN: head adds a new entry, keeps all base entries ──────────────────
fix_a="$work/clean"
make_fixture "$fix_a" \
'# Changelog

## shipyard

### 1.0.1 — 2026-01-02

Patch release.

### 1.0.0 — 2026-01-01

Initial release.
' \
'# Changelog

## shipyard

### 1.0.2 — 2026-01-03

New entry (own PR, not on base).

### 1.0.1 — 2026-01-02

Patch release.

### 1.0.0 — 2026-01-01

Initial release.
'
if (cd "$fix_a" && CHANGELOG_PATH="CHANGELOG.md" bash "$scanner" "HEAD~1" >/dev/null 2>&1); then
  ok "(4a) clean: head adds new entry + keeps all base headings → exits 0"
else
  bad "(4a) clean: scanner false-positived on a clean add-only head"
fi

# (4b) DELETION DETECTED: head drops a released heading ──────────────────────
fix_b="$work/deletion"
make_fixture "$fix_b" \
'# Changelog

## shipyard

### 1.0.2 — 2026-01-03

Release b.

### 1.0.1 — 2026-01-02

Release a.

### 1.0.0 — 2026-01-01

Initial.
' \
'# Changelog

## shipyard

### 1.0.3 — 2026-01-04

New entry.

### 1.0.2 — 2026-01-03

Release b.

### 1.0.0 — 2026-01-01

Initial.
'
# 1.0.1 was present on base but absent from head — must fail.
# Capture the exit code directly (not via `$?` inside `if !`, which captures
# the negation's result, not the subshell's exit code).
(cd "$fix_b" && CHANGELOG_PATH="CHANGELOG.md" bash "$scanner" "HEAD~1" >/dev/null 2>&1); rc_4b=$?
if [[ "$rc_4b" -eq 1 ]]; then
  ok "(4b) deletion: scanner exits 1 when a released heading is missing"
elif [[ "$rc_4b" -eq 0 ]]; then
  bad "(4b) deletion: scanner FAILED to detect a deleted released heading (exited 0)"
else
  bad "(4b) deletion: scanner exited $rc_4b (expected 1) on a deleted heading"
fi

# Verify the error output names the missing heading.
err_output=$(cd "$fix_b" && CHANGELOG_PATH="CHANGELOG.md" bash "$scanner" "HEAD~1" 2>&1) || true
if echo "$err_output" | grep -qF "1.0.1"; then
  ok "(4b) deletion: error output names the missing heading"
else
  bad "(4b) deletion: error output does not name the missing heading"
fi

# (4c) FALSE-POSITIVE GUARD: PR re-numbers its OWN unmerged entry ─────────────
# The base has no entry for 1.0.5; the head has 1.0.5 (not 1.0.4 — it was
# re-numbered). Since 1.0.4 was never on the base, the scanner must NOT
# complain about its absence.
fix_c="$work/renumber"
make_fixture "$fix_c" \
'# Changelog

## shipyard

### 1.0.3 — 2026-01-04

Released.
' \
'# Changelog

## shipyard

### 1.0.5 — 2026-01-06

Re-numbered own entry (1.0.4 → 1.0.5 due to sibling PR).

### 1.0.3 — 2026-01-04

Released.
'
# 1.0.4 was never on base, 1.0.5 is the PR's own entry — no false positive.
if (cd "$fix_c" && CHANGELOG_PATH="CHANGELOG.md" bash "$scanner" "HEAD~1" >/dev/null 2>&1); then
  ok "(4c) renumber: PR re-numbers own unmerged entry → no false positive (exits 0)"
else
  bad "(4c) renumber: scanner false-positived on a re-numbered own entry"
fi

# (4d) OPT-OUT DIRECTIVE: head CHANGELOG carries the allow directive ──────────
fix_d="$work/optout"
make_fixture "$fix_d" \
'# Changelog

## shipyard

### 1.0.0 — 2026-01-01

Initial.
' \
'# Changelog
   changelog-monotonicity-scan: allow

## shipyard

### 1.0.1 — 2026-01-02

New entry only — 1.0.0 deleted (but allow directive present).
'
# Head deleted 1.0.0 AND carries the allow directive — scanner should skip.
if (cd "$fix_d" && CHANGELOG_PATH="CHANGELOG.md" bash "$scanner" "HEAD~1" >/dev/null 2>&1); then
  ok "(4d) opt-out: allow directive suppresses the deletion check (exits 0)"
else
  bad "(4d) opt-out: scanner did NOT honor the allow directive"
fi

# (4e) MULTIPLE DELETIONS reported at once ────────────────────────────────────
fix_e="$work/multi"
make_fixture "$fix_e" \
'# Changelog

## shipyard

### 1.0.3 — 2026-01-04

C.

### 1.0.2 — 2026-01-03

B.

### 1.0.1 — 2026-01-02

A.

### 1.0.0 — 2026-01-01

Init.
' \
'# Changelog

## shipyard

### 1.0.4 — 2026-01-05

New.

### 1.0.3 — 2026-01-04

C kept.
'
# 1.0.0, 1.0.1, 1.0.2 were all deleted.
# Redirect stderr to stdout to capture the error output.
err_multi=$(cd "$fix_e" && CHANGELOG_PATH="CHANGELOG.md" bash "$scanner" "HEAD~1" 2>&1) || true
missing_count=$(echo "$err_multi" | grep -c "^  ### " || true)
if [[ "$missing_count" -eq 3 ]]; then
  ok "(4e) multi-deletion: all three missing headings reported"
else
  bad "(4e) multi-deletion: expected 3 missing headings in output, got $missing_count"
fi

# (4f) NO BASE CHANGELOG: scan is a no-op when CHANGELOG is brand-new ─────────
fix_f="$work/nobase"
mkdir -p "$fix_f"
git -C "$fix_f" init -q -b main
git -C "$fix_f" config user.email "test@example.com"
git -C "$fix_f" config user.name "Test"
# Base commit has NO CHANGELOG.md
touch "$fix_f/README.md"
git -C "$fix_f" add README.md
git -C "$fix_f" commit -q -m "base no changelog"
# Head adds CHANGELOG.md fresh.
printf '### 1.0.0 — 2026-01-01\n\nNew.\n' > "$fix_f/CHANGELOG.md"
git -C "$fix_f" add CHANGELOG.md
git -C "$fix_f" commit -q -m "add changelog"
if (cd "$fix_f" && CHANGELOG_PATH="CHANGELOG.md" bash "$scanner" "HEAD~1" >/dev/null 2>&1); then
  ok "(4f) no-base: CHANGELOG brand-new (not on base) → exits 0 (no entries to protect)"
else
  bad "(4f) no-base: scanner errored on a brand-new CHANGELOG"
fi

# ── (5) Worker-side assertions exist in fix-rebase.md ────────────────────────
if [[ -f "$fix_rebase" ]]; then
  assert_contains "$fix_rebase" "changelog-monotonicity-scan" \
    "fix-rebase.md references changelog-monotonicity-scan"
  assert_contains "$fix_rebase" "github.com/mattsears18/shipyard/issues/555" \
    "fix-rebase.md links to originating issue #555"
  assert_contains "$fix_rebase" "deleted released CHANGELOG" \
    "fix-rebase.md documents the deletion-bail substring"
fi

# ── (6) Worker-side assertions exist in issue-work.md ────────────────────────
if [[ -f "$issue_work" ]]; then
  assert_contains "$issue_work" "changelog-monotonicity-scan" \
    "issue-work.md references changelog-monotonicity-scan"
  assert_contains "$issue_work" "github.com/mattsears18/shipyard/issues/555" \
    "issue-work.md links to originating issue #555"
  assert_contains "$issue_work" "deleted released CHANGELOG" \
    "issue-work.md documents the deletion-bail substring"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "  ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
