#!/usr/bin/env bash
# Test: the issue-work + fix-checks-only specs make the repo's UNIT-test suite a
# hard pre-push gate — with the same standing as typecheck and lint — rather than
# an optional "CI will tell you" step.
#
# Background — issue #658: issue-worker (and fix-checks-worker) pushed after local
# typecheck + lint but did NOT run the repo's full unit-test suite, so repo-specific
# test failures (e.g. a jest i18n-parity test asserting `locales/en.json` <-> `lib/
# strings.ts` parity) surfaced only in CI. Three issue-worker PRs in one lightwork
# session (#2275, #2284, #2290) added `Strings.*` leaves without the paired en.json
# key: each passed typecheck + lint locally, pushed, then failed the required Unit
# Tests gate — costing an orchestrator diagnosis + a separate fix-checks dispatch per
# occurrence. The soft "If nothing exists, skip — CI will tell you" framing in the
# Implement step read as permission to skip the suite entirely.
#
# The fix is a spec change at two layers, both asserted here:
#   1. issue-work.md §4.6 — a named, non-skippable pre-push unit-test gate: detect the
#      unit-test command (npm test / test:unit / jest|vitest|pytest config), run it,
#      treat a failure as a pre-push blocker (`blocked ... at pre-push`), skip ONLY
#      when the repo has no suite at all. Ordered after §4.5 (diff sanity) and before
#      §5 (commit + push).
#   2. fix-checks-only.md fix-loop step 4.5 — the same pre-push unit-test run before
#      pushing a fix, plus a Don't bullet.
#
# This test is the regression guard: if either layer regresses, workers silently
# revert to "typecheck+lint then push" and the #658 wasted-fix-checks-dispatch loop
# returns.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/pre-push-unit-test-gate.test.sh

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

issue_work_path="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"
fix_checks_path="$repo_root/plugins/shipyard/agents/issue-worker/fix-checks-only.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_file_exists() {
  local path="$1" label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (missing: %s)\n' "$RED" "$RESET" "$label" "$path"; fail=$((fail+1))
  fi
}

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"; fail=$((fail+1))
  fi
}

assert_section_ordering() {
  local file="$1" before="$2" after="$3" label="$4"
  local before_line after_line
  before_line=$(grep -nF -- "$before" "$file" | head -1 | cut -d: -f1)
  after_line=$(grep -nF -- "$after" "$file" | head -1 | cut -d: -f1)
  if [[ -z "$before_line" ]]; then
    printf '  %sFAIL%s  %s (could not find before-marker: %s)\n' "$RED" "$RESET" "$label" "$before"; fail=$((fail+1)); return
  fi
  if [[ -z "$after_line" ]]; then
    printf '  %sFAIL%s  %s (could not find after-marker: %s)\n' "$RED" "$RESET" "$label" "$after"; fail=$((fail+1)); return
  fi
  if (( before_line < after_line )); then
    printf '  %sPASS%s  %s (before @ %d, after @ %d)\n' "$GREEN" "$RESET" "$label" "$before_line" "$after_line"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (expected before-marker first; got before @ %d, after @ %d)\n' "$RED" "$RESET" "$label" "$before_line" "$after_line"; fail=$((fail+1))
  fi
}

echo "pre-push unit-test gate regression tests (issue #658)"
echo

# --- Layer 1: issue-work.md §4.6 pre-push unit-test gate ---
assert_file_exists "$issue_work_path" "agents/issue-worker/issue-work.md exists"
if [[ -f "$issue_work_path" ]]; then
  assert_contains "$issue_work_path" "### 4.6 Pre-push local unit-test gate" \
    "issue-work.md adds §4.6 Pre-push local unit-test gate"
  assert_contains "$issue_work_path" "https://github.com/mattsears18/shipyard/issues/658" \
    "issue-work.md links to originating issue #658"
  # The gate names unit-test detection across the common runners.
  assert_contains "$issue_work_path" 'scripts["test:unit"]' \
    "issue-work.md detects the test:unit / test npm script"
  assert_contains "$issue_work_path" "jest/vitest config" \
    "issue-work.md detects jest/vitest config"
  # A failure is a pre-push BLOCKER with a canonical bail string.
  assert_contains "$issue_work_path" "pre-push blocker" \
    "issue-work.md frames a unit-test failure as a pre-push blocker"
  assert_contains "$issue_work_path" "blocked #<N> at pre-push: local unit suite failing" \
    "issue-work.md defines the canonical pre-push bail string"
  # Narrowness: skip ONLY when there is no suite; slow / unrelated are NOT skip reasons.
  assert_contains "$issue_work_path" "no** unit-test suite at all" \
    "issue-work.md scopes the skip to a genuinely absent suite"
  assert_contains "$issue_work_path" "are NOT skip reasons" \
    "issue-work.md forbids skipping for slow / unrelated-looking failures"
  # Don't-over-run: this is the unit suite, not the full E2E matrix.
  assert_contains "$issue_work_path" "not the full E2E / integration / browser matrix" \
    "issue-work.md scopes the gate to the unit suite, not E2E"
  # The soft "CI will tell you" framing must be gone from the Implement step.
  if grep -qF "If nothing exists, skip — CI will tell you" "$issue_work_path"; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" \
      "issue-work.md still carries the soft 'skip — CI will tell you' framing"; fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" \
      "issue-work.md removed the soft 'skip — CI will tell you' framing"; pass=$((pass+1))
  fi
  # Ordering: §4.5 (diff sanity) before §4.6 (test gate) before §5 (commit + push).
  assert_section_ordering "$issue_work_path" \
    "### 4.5 Pre-PR-create diff sanity check" \
    "### 4.6 Pre-push local unit-test gate" \
    "§4.6 lands after §4.5 diff-sanity guard"
  assert_section_ordering "$issue_work_path" \
    "### 4.6 Pre-push local unit-test gate" \
    "### 5. Commit + push + PR" \
    "§4.6 lands before §5 commit + push"
fi

# --- Layer 2: fix-checks-only.md fix-loop pre-push unit run ---
assert_file_exists "$fix_checks_path" "agents/issue-worker/fix-checks-only.md exists"
if [[ -f "$fix_checks_path" ]]; then
  assert_contains "$fix_checks_path" "Run the repo's unit-test suite locally before pushing the fix" \
    "fix-checks-only.md adds a pre-push unit-test run to the fix-loop"
  assert_contains "$fix_checks_path" "https://github.com/mattsears18/shipyard/issues/658" \
    "fix-checks-only.md links to originating issue #658"
  # It must precede the push step (4.5 before 5).
  assert_section_ordering "$fix_checks_path" \
    "Run the repo's unit-test suite locally before pushing the fix" \
    "\`git commit\` + \`git push\` to the same branch" \
    "fix-loop unit-test run precedes the git push step"
  # The i18n-parity signature is called out as the load-bearing case.
  assert_contains "$fix_checks_path" "i18n-parity signature" \
    "fix-checks-only.md ties the gate to the i18n-parity signature"
  # A Don't bullet reinforces the gate.
  assert_contains "$fix_checks_path" "Don't push a fix without running the repo's unit suite locally first" \
    "fix-checks-only.md adds a Don't bullet forbidding a push without a local unit run"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
