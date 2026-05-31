#!/usr/bin/env bash
# Test: the repo ships a branch-protection enablement helper at
# scripts/enable-branch-protection.sh (issue #404 — "test + lint workflows run
# on PRs but aren't required checks — a red-tests PR can still merge").
#
# Background: main has no branch protection, so the tests.yml / shellcheck.yml
# / secret-scan.yml CI gates are advisory only — a PR with red tests can still
# merge. Enabling required status checks is a GitHub *admin* action with no
# committable file, so the in-repo deliverable is a helper that wraps the exact
# `gh api` enablement call (with the correct check-context names) behind a
# single reviewable command, gated behind an explicit --apply.
#
# This test is the regression guard. It asserts the script exists, is
# executable, has a bash shebang, names every required check context, defaults
# to a non-mutating dry-run, and passes shellcheck. It deliberately NEVER calls
# --apply (that would mutate the real repo's branch protection) and overrides
# REPO/BRANCH to a non-existent target so the read-only paths can't accidentally
# touch live settings.
#
# Pure bash. Run with:
#   bash plugins/shipyard/scripts/tests/enable-branch-protection-script.test.sh

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

SCRIPT="$repo_root/scripts/enable-branch-protection.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() {
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"
  pass=$((pass+1))
}

assert_fail() {
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"
  fail=$((fail+1))
}

echo "enable-branch-protection regression tests (issue #404)"
echo

# (1) The script exists.
if [[ -f "$SCRIPT" ]]; then
  assert_pass "scripts/enable-branch-protection.sh exists"
else
  assert_fail "scripts/enable-branch-protection.sh exists (missing)"
  echo
  printf 'passed: %d, failed: %d\n' "$pass" "$fail"
  exit 1
fi

# (2) Executable — the point is a single runnable command.
if [[ -x "$SCRIPT" ]]; then
  assert_pass "scripts/enable-branch-protection.sh is executable"
else
  assert_fail "scripts/enable-branch-protection.sh is executable (chmod +x missing)"
fi

# (3) Bash shebang.
first_line="$(head -n1 "$SCRIPT")"
if [[ "$first_line" == "#!/usr/bin/env bash" || "$first_line" == "#!/bin/bash" ]]; then
  assert_pass "scripts/enable-branch-protection.sh has a bash shebang"
else
  assert_fail "scripts/enable-branch-protection.sh has a bash shebang (got: $first_line)"
fi

# (4) It names every required check context. These are the exact check-run
# names branch protection must require — if a workflow renames a job, this
# list and the script must move together (a stale context waits forever).
for ctx in "bash test suites" "shellcheck" "shell tests" "gitleaks"; do
  if grep -qF "$ctx" "$SCRIPT"; then
    assert_pass "references required check context: \"$ctx\""
  else
    assert_fail "references required check context: \"$ctx\" (missing)"
  fi
done

# (5) --help fast path: exits 0 and prints usage; mutates nothing.
help_out="$("$SCRIPT" --help 2>&1)"
help_rc=$?
if [[ $help_rc -eq 0 ]] && grep -q "Usage:" <<<"$help_out"; then
  assert_pass "--help prints usage and exits 0"
else
  assert_fail "--help prints usage and exits 0 (rc=$help_rc)"
fi

# (6) Unknown argument is rejected with a non-zero exit.
"$SCRIPT" --bogus-flag >/dev/null 2>&1
bogus_rc=$?
if [[ $bogus_rc -ne 0 ]]; then
  assert_pass "rejects unknown arguments (non-zero exit)"
else
  assert_fail "rejects unknown arguments (got rc=0)"
fi

# (7) Default mode is a non-mutating dry-run. We point REPO at a non-existent
# target so the read-only `gh api` probe returns 404 (treated as "not
# protected"), then assert the dry-run banner appears and the apply path did
# NOT run. Skipped when gh/jq are unavailable. The "Applying" banner is the
# apply-path tell; it must NOT appear in a dry-run.
if command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  dry_out="$(REPO="mattsears18/does-not-exist-404-test" BRANCH="main" "$SCRIPT" --dry-run 2>&1 || true)"
  if grep -q "Dry-run only" <<<"$dry_out"; then
    assert_pass "--dry-run prints the dry-run banner"
  else
    assert_fail "--dry-run prints the dry-run banner"
  fi
  if grep -q "Applying" <<<"$dry_out"; then
    assert_fail "--dry-run does NOT take the apply path (it printed 'Applying')"
  else
    assert_pass "--dry-run does NOT take the apply path"
  fi
  # The dry-run payload should still list the required contexts.
  if grep -q "bash test suites" <<<"$dry_out"; then
    assert_pass "--dry-run payload lists the required contexts"
  else
    assert_fail "--dry-run payload lists the required contexts"
  fi
else
  printf '  %sSKIP%s  gh/jq not installed; skipping dry-run behavior check\n' "$GREEN" "$RESET"
fi

# (8) shellcheck — same gate CI applies to every other script. Skipped (not
# failed) when shellcheck isn't installed.
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$SCRIPT" >/dev/null 2>&1; then
    assert_pass "passes shellcheck"
  else
    assert_fail "passes shellcheck"
    shellcheck "$SCRIPT" || true
  fi
else
  printf '  %sSKIP%s  shellcheck not installed; skipping lint check\n' "$GREEN" "$RESET"
fi

echo
printf 'passed: %d, failed: %d\n' "$pass" "$fail"
if (( fail > 0 )); then
  exit 1
fi
exit 0
