#!/usr/bin/env bash
# Test: the repo ships a canonical setup entry point at scripts/setup.sh
# (issue #399 — "chore(dx): add setup script or devcontainer").
#
# Background: the dx audit flagged that this repo had no setup script /
# devcontainer / Makefile / Justfile, so every new contributor had to
# reconstruct the install + test sequence from the README by hand. The fix
# is a thin scripts/setup.sh that (1) checks the documented prerequisites
# and (2) runs the bash test suite — one command brings a fresh checkout to
# a verified-runnable state.
#
# This test is the regression guard: it asserts the script exists, is
# executable, has a bash shebang, documents the prerequisites it checks,
# and that its --check / --help fast paths behave (exit 0, no test run).
# It deliberately does NOT invoke the no-arg path (that would recursively
# run the whole suite from inside the suite); --check exercises everything
# up to the test-run boundary.
#
# Pure bash, no external dependencies beyond the prerequisites the script
# itself checks for. Run with:
#
#   bash plugins/shipyard/scripts/tests/setup-script.test.sh

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

SETUP="$repo_root/scripts/setup.sh"

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

echo "setup-script regression tests (issue #399)"
echo

# (1) The script exists.
if [[ -f "$SETUP" ]]; then
  assert_pass "scripts/setup.sh exists"
else
  assert_fail "scripts/setup.sh exists (missing)"
  echo
  printf 'passed: %d, failed: %d\n' "$pass" "$fail"
  exit 1
fi

# (2) The script is executable — the whole point is "one command", which
# implies a directly-runnable ./scripts/setup.sh.
if [[ -x "$SETUP" ]]; then
  assert_pass "scripts/setup.sh is executable"
else
  assert_fail "scripts/setup.sh is executable (chmod +x missing)"
fi

# (3) Bash shebang.
first_line="$(head -n1 "$SETUP")"
if [[ "$first_line" == "#!/usr/bin/env bash" || "$first_line" == "#!/bin/bash" ]]; then
  assert_pass "scripts/setup.sh has a bash shebang"
else
  assert_fail "scripts/setup.sh has a bash shebang (got: $first_line)"
fi

# (4) It documents the prerequisites it checks. These mirror
# CONTRIBUTING.md → Getting started; if the prereq set drifts, the docs and
# this list should move together.
for tool in bash git gh shellcheck jq; do
  if grep -qE "\b$tool\b" "$SETUP"; then
    assert_pass "scripts/setup.sh references prerequisite: $tool"
  else
    assert_fail "scripts/setup.sh references prerequisite: $tool"
  fi
done

# (5) --check fast path: exits 0 and does NOT run the test suite. Running
# the no-arg path here would recursively invoke the whole suite from inside
# the suite, so --check is the boundary we exercise. We assert exit 0 and
# that the "Running test suite" banner does NOT appear in the output.
check_out="$("$SETUP" --check 2>&1)"
check_rc=$?
if [[ $check_rc -eq 0 ]]; then
  assert_pass "scripts/setup.sh --check exits 0"
else
  assert_fail "scripts/setup.sh --check exits 0 (got rc=$check_rc)"
fi
if grep -q "Running test suite" <<<"$check_out"; then
  assert_fail "scripts/setup.sh --check skips the test suite (it ran the suite)"
else
  assert_pass "scripts/setup.sh --check skips the test suite"
fi

# (6) --help fast path: exits 0 and prints usage; never runs prerequisites
# or tests.
help_out="$("$SETUP" --help 2>&1)"
help_rc=$?
if [[ $help_rc -eq 0 ]] && grep -q "Usage:" <<<"$help_out"; then
  assert_pass "scripts/setup.sh --help prints usage and exits 0"
else
  assert_fail "scripts/setup.sh --help prints usage and exits 0 (rc=$help_rc)"
fi

# (7) Unknown argument is rejected with a non-zero exit — guards against a
# silent fall-through that would run the suite on a typo'd flag.
"$SETUP" --bogus-flag >/dev/null 2>&1
bogus_rc=$?
if [[ $bogus_rc -ne 0 ]]; then
  assert_pass "scripts/setup.sh rejects unknown arguments (non-zero exit)"
else
  assert_fail "scripts/setup.sh rejects unknown arguments (got rc=0)"
fi

# (8) The script passes shellcheck — same gate CI applies to every other
# script in the repo. Skipped (not failed) when shellcheck isn't installed.
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$SETUP" >/dev/null 2>&1; then
    assert_pass "scripts/setup.sh passes shellcheck"
  else
    assert_fail "scripts/setup.sh passes shellcheck"
    shellcheck "$SETUP" || true
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
