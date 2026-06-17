#!/usr/bin/env bash
# Test: setup.md step 1.3's #465 admin-direct-merge detector normalizes the
# required-status-checks read to a numeric shape, so a 404 ("Branch not
# protected") correctly collapses to "0" and shape-2 of the detector fires.
#
# Background — issue #479: the step-1.3 read is
#
#   required_checks_count=$(gh api \
#     "repos/<owner/repo>/branches/<default-branch>/protection/required_status_checks" \
#     --jq '(.checks // []) | length' 2>/dev/null || echo 0)
#
# `gh api` does NOT apply `--jq` to error responses. On a 404 (no branch
# protection rule — *exactly* the zero-required-checks shape #465 wants to
# warn about) it ignores `--jq`, writes the raw error JSON to STDOUT, and
# exits non-zero. The `|| echo 0` fallback then APPENDS `0` to that body
# instead of replacing it, leaving e.g.
#
#   required_checks_count=[{"message":"Branch not protected",...,"status":"404"}0]
#
# That is not "0", so the shape-2 conditional
#
#   [ "$viewer_admin" = "true" ] && [ "$required_checks_count" = "0" ]
#
# never matches — silently suppressing the #465 warning on precisely the
# repos it exists to warn about (admin + unprotected default branch, which
# is the shipyard repo itself). The `2>/dev/null` only hides the SEPARATE
# stderr line, not the stdout error body.
#
# The fix (issue #479) is a numeric-shape normalize after the read:
#
#   case "$required_checks_count" in
#     ''|*[!0-9]*) required_checks_count=0 ;;
#   esac
#
# Any non-pure-digit value (404 body, empty) collapses to "0" — the correct
# semantic, since a 404 means zero required checks. A genuine numeric count
# (e.g. "2") is preserved untouched.
#
# This test pins two things:
#   (A) the normalize block is present in setup.md step 1.3 (regression guard
#       — if anyone reverts to the bare `[ -z ... ] && ...=0` form, this fails);
#   (B) the normalize logic itself collapses the buggy 404-append string to
#       "0" while leaving genuine counts intact, AND proves the pre-fix
#       behavior was broken (the bare append does NOT yield "0").
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/required-checks-404-normalize.test.sh

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

# #611 split setup.md into a thin router + step-cluster sub-files; step 1.3
# (the #465 admin-direct-merge detector) lives in setup/01-repo-recovery.md.
SETUP_MD="$repo_root/plugins/shipyard/commands/do-work/setup/01-repo-recovery.md"

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

assert_equals() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf '  %sPASS%s  %s (got [%s])\n' "$GREEN" "$RESET" "$label" "$actual"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (expected [%s], got [%s])\n' "$RED" "$RESET" "$label" "$expected" "$actual"
    fail=$((fail+1))
  fi
}

echo "required-checks 404-normalize regression tests (issue #479)"
echo

# ---------------------------------------------------------------------------
# (A) Spec regression guard — the normalize block must be present in setup.md.
# ---------------------------------------------------------------------------
if [[ -f "$SETUP_MD" ]]; then
  assert_pass "setup.md exists"

  # The load-bearing normalize line. Anchored against literal text so a revert
  # to the bare `[ -z ... ] && required_checks_count=0` form trips this test.
  if grep -qF "''|*[!0-9]*) required_checks_count=0 ;;" "$SETUP_MD"; then
    assert_pass "setup.md step 1.3 carries the numeric-shape normalize (#479)"
  else
    assert_fail "setup.md step 1.3 carries the numeric-shape normalize (#479)"
  fi

  # The normalize must come AFTER the required_checks_count read, not before
  # (normalizing before the read is a no-op). Assert ordering by line number.
  read_line=$(grep -n 'required_status_checks' "$SETUP_MD" | head -1 | cut -d: -f1)
  norm_line=$(grep -n "''|\*\[!0-9\]\*) required_checks_count=0 ;;" "$SETUP_MD" | head -1 | cut -d: -f1)
  if [[ -n "$read_line" && -n "$norm_line" && "$norm_line" -gt "$read_line" ]]; then
    assert_pass "normalize block follows the required-checks read (L$norm_line > L$read_line)"
  else
    assert_fail "normalize block follows the required-checks read (read=L${read_line:-?}, norm=L${norm_line:-?})"
  fi
else
  assert_fail "setup.md exists (missing at $SETUP_MD)"
fi

# ---------------------------------------------------------------------------
# (B) Behavioral test — replicate the read+normalize and assert outcomes.
#
# `fake_gh_api` mimics the real `gh api` on a 404: it ignores `--jq`, prints
# the error body to stdout, and exits non-zero. The 404 path is the bug's
# trigger; the success path proves genuine counts survive untouched.
# ---------------------------------------------------------------------------

# Mock: gh api on a 404 — error JSON to stdout, exit 1, --jq ignored.
fake_gh_api_404() {
  echo '{"message":"Branch not protected","documentation_url":"...","status":"404"}'
  return 1
}
# Mock: gh api on success — the --jq projection already reduced to a count.
fake_gh_api_ok() { echo "2"; }
# Mock: gh api on success, zero required checks (empty .checks array).
fake_gh_api_zero() { echo "0"; }

# The normalize is the production fix. Keep it identical to setup.md.
normalize() {
  local v="$1"
  case "$v" in
    ''|*[!0-9]*) v=0 ;;
  esac
  printf '%s' "$v"
}

# --- Pre-fix behavior proof: the bare `|| echo 0` append does NOT yield "0".
buggy=$(fake_gh_api_404 2>/dev/null || echo 0)
if [[ "$buggy" != "0" ]]; then
  assert_pass "pre-fix: bare '|| echo 0' on a 404 does NOT equal '0' (bug reproduced)"
else
  assert_fail "pre-fix: bare '|| echo 0' on a 404 unexpectedly equals '0' (bug not reproduced?)"
fi

# --- Post-fix: 404 body collapses to "0" (detector fires).
got=$(normalize "$(fake_gh_api_404 2>/dev/null || echo 0)")
assert_equals "404 body normalizes to 0 (detector fires)" "0" "$got"

# --- Post-fix: genuine non-zero count is preserved (detector does NOT fire on count>0).
got=$(normalize "$(fake_gh_api_ok 2>/dev/null || echo 0)")
assert_equals "genuine count '2' is preserved" "2" "$got"

# --- Post-fix: genuine zero count stays "0".
got=$(normalize "$(fake_gh_api_zero 2>/dev/null || echo 0)")
assert_equals "genuine zero count stays 0" "0" "$got"

# --- Post-fix: empty string collapses to "0" (transient read failure → warn-on-doubt).
got=$(normalize "")
assert_equals "empty string normalizes to 0 (warn-on-doubt)" "0" "$got"

# --- Detector semantics: after normalize, the shape-2 conditional matches on the
#     404 case (admin + zero required checks). This is the whole point of the fix.
viewer_admin="true"
required_checks_count=$(normalize "$(fake_gh_api_404 2>/dev/null || echo 0)")
if [ "$viewer_admin" = "true" ] && [ "$required_checks_count" = "0" ]; then
  assert_pass "shape-2 (#465) detector fires on admin + 404 (zero required checks)"
else
  assert_fail "shape-2 (#465) detector fires on admin + 404 (got count=[$required_checks_count])"
fi

# --- And does NOT fire when there genuinely are required checks.
required_checks_count=$(normalize "$(fake_gh_api_ok 2>/dev/null || echo 0)")
if [ "$viewer_admin" = "true" ] && [ "$required_checks_count" = "0" ]; then
  assert_fail "shape-2 must NOT fire when count=2 (got fired)"
else
  assert_pass "shape-2 (#465) detector does NOT fire when required checks exist (count=2)"
fi

echo
printf 'passed: %d, failed: %d\n' "$pass" "$fail"
if (( fail > 0 )); then
  exit 1
fi
exit 0
