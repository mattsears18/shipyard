#!/usr/bin/env bash
# Test: the fix-checks-only worker contract requires the PR's FULL check
# rollup to be green before returning `green` / `noop: already green` — not
# just the single check the worker was dispatched/assigned to fix, and never
# a local test pass as a substitute for reading CI's actual rollup.
#
# Background — issue #754: session do-work-20260714T211058Z-84652,
# mattsears18/lightwork PR #2489. Two `fix-checks-only` dispatches both
# returned success while the PR's REQUIRED check rollup was still red:
#   - One worker fixed `Lint & Typecheck`, saw the required `Unit Tests`
#     check still FAILURE, reasoned "the originally-specified failing check
#     is now passing" and treated Unit Tests/E2E as "pre-existing/
#     unrelated," then returned `green #2489` anyway.
#   - Another worker ran the unit suite LOCALLY three times (all green) and
#     returned `noop: already green #2489` while the PR's CI `Unit Tests`
#     check was still FAILURE — conflating "passes on my machine" with "CI
#     is green."
#
# The pre-existing #416 named-failing-check re-verification gate already had
# a bullet requiring "the overall rollup is all-green," but its parenthetical
# — "no *other* check regressed" — was ambiguous enough to read as "a
# pre-existing failure that predates my dispatch doesn't count against me
# because it didn't regress." That reading is exactly what both #754 workers
# used to justify ignoring a still-red required check.
#
# The fix rewrites that bullet to be unambiguous (the ENTIRE rollup must be
# green, regardless of whether a red check predates the dispatch or was
# assigned to this worker), adds an explicit up-front definition of `green`/
# `noop: already green` as "full rollup, not my assigned check, not my local
# run," and adds a corresponding `Don't` bullet.
#
# This test is the regression guard: if the full-rollup requirement or its
# local-run-is-not-a-substitute clarification regress, the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/fix-checks-full-rollup-required.test.sh

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

fix_checks_path="$repo_root/plugins/shipyard/agents/issue-worker/fix-checks-only.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_file_exists() {
  local path="$1"; local label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (missing: %s)\n' "$RED" "$RESET" "$label" "$path"; fail=$((fail+1))
  fi
}

assert_contains() {
  local file="$1"; local needle="$2"; local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"; fail=$((fail+1))
  fi
}

echo "fix-checks-only full-rollup-required for green / noop (issue #754)"
echo

assert_file_exists "$fix_checks_path" "fix-checks-only.md exists"

# Provenance: the fix cites #754.
assert_contains "$fix_checks_path" \
  "github.com/mattsears18/shipyard/issues/754" \
  "links issue #754 for provenance"

# Up-front definition: green/noop mean the FULL rollup, not the assigned
# check, and never a local pass.
assert_contains "$fix_checks_path" \
  "mean the PR's FULL check rollup is green on the pushed head SHA" \
  "return-contract intro defines green/noop as the full rollup"

assert_contains "$fix_checks_path" \
  "never \"the check I was dispatched/assigned to fix is now green\"" \
  "return-contract intro forbids scoping green to the assigned check only"

# The ambiguous #416-era parenthetical ("no *other* check regressed") must
# be gone or superseded — the rewritten bullet must explicitly reject the
# "didn't regress" reading that let both #754 workers ignore a red required
# check.
assert_contains "$fix_checks_path" \
  "it does not say \"no *other* check regressed\"" \
  "gate explicitly disclaims the ambiguous regressed-only reading"

assert_contains "$fix_checks_path" \
  "it says the **entire rollup** must be green, full stop" \
  "gate states the entire rollup must be green, full stop"

assert_contains "$fix_checks_path" \
  "A required check that was **already red before your dispatch started**" \
  "gate covers pre-existing (not just newly-regressed) red checks"

assert_contains "$fix_checks_path" \
  "\"It's pre-existing\" and \"it's unrelated to the check I was assigned\" are diagnosis notes, not exemptions" \
  "gate rejects the pre-existing/unrelated exemption reasoning from the #754 repro"

# noop: path must explicitly forbid deriving the claim from a local run.
assert_contains "$fix_checks_path" \
  "A local test run — however many times you ran it, however clean the result — is never sufficient grounds for this return." \
  "noop bullet forbids deriving already-green from a local test run"

# Don't section carries a corresponding entry citing #754 and both repro
# workers' reasoning.
assert_contains "$fix_checks_path" \
  "Don't return \`green\` / \`noop: already green\` from your assigned check passing alone" \
  "Don't section forbids assigned-check-only / pre-existing / local-pass green claims"

assert_contains "$fix_checks_path" \
  "PR #2489" \
  "Don't section cites the #754 repro PR"

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
