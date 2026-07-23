#!/usr/bin/env bash
# Test: the missing-`workflow`-scope PROACTIVE preflight warning (issue #818).
#
# Background
# ----------
# Issue #812 (landed) taught the REACTIVE half of this problem: a worker
# discovers a `gh` token missing the `workflow` OAuth scope only at the first
# FAILED `gh pr merge --auto` call on a workflow-touching PR, and reports the
# `auto-merge: unavailable — gh token lacks workflow scope` outcome.
#
# #818 is the PROACTIVE half — a one-time session-start warning, printed
# BEFORE the first workflow-touching PR is ever opened, when the session
# shape suggests one is likely (an open issue/PR references
# `.github/workflows/`, or main's most recent CI run failed).
#
# This suite pins two things:
#
#   (A) The DECISION LOGIC in detect-missing-workflow-scope.sh — its
#       `--decide <has_workflow_scope> <workflow_signal>` truth table. This is
#       pure (no network I/O), so it's driven directly, the same shape as
#       ungated-merge-gate-reachability.test.sh drives
#       detect-ungated-admin-direct-merge.sh --decide.
#
#   (B) DOC CONTRACT — commands/do-work/setup/01-repo-recovery.md actually
#       invokes the script, prints the exact remediation command
#       (`gh auth refresh -h github.com -s workflow`), reuses #812's exact
#       failure token verbatim (so the proactive and reactive halves don't
#       diverge into two vocabularies for the same condition), and documents
#       the silent-by-default / one-time-per-session / never-touch-auth-itself
#       constraints from the issue's acceptance criteria.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/workflow-scope-preflight-818.test.sh

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

DETECTOR="$repo_root/plugins/shipyard/scripts/detect-missing-workflow-scope.sh"
SETUP_REPO_MD="$repo_root/plugins/shipyard/commands/do-work/setup/01-repo-recovery.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
  fi
}

# decide <has_workflow_scope> <workflow_signal> <expected> <label>
assert_decide() {
  local got
  got="$(bash "$DETECTOR" --decide "$1" "$2" 2>/dev/null)"
  if [[ "$got" == "$3" ]]; then
    assert_pass "$4 (has_scope=$1 signal=$2 => $got)"
  else
    assert_fail "$4 (has_scope=$1 signal=$2 => expected [$3], got [$got])"
  fi
}

echo "workflow-scope preflight regression tests (issue #818)"
echo

# ---------------------------------------------------------------------------
# (A) The decision-logic truth table. Silent by default is the load-bearing
#     property: the acceptance criteria explicitly forbid noise on the common
#     case (token already has the scope, or nothing suggests workflow-
#     touching work).
# ---------------------------------------------------------------------------
echo "(A) detect-missing-workflow-scope.sh — decision truth table"
if [[ -f "$DETECTOR" ]]; then
  assert_pass "detect-missing-workflow-scope.sh exists"
  if [[ -x "$DETECTOR" ]]; then
    assert_pass "detect-missing-workflow-scope.sh is executable"
  else
    assert_fail "detect-missing-workflow-scope.sh is executable"
  fi

  # The only combination that should ever warn: scope missing AND a signal.
  assert_decide 0 1 warn \
    "missing scope + workflow-touching signal => warn"

  # Common case 1: token already has the scope — silent regardless of signal.
  assert_decide 1 1 silent \
    "token already has workflow scope => silent even with a signal present"
  assert_decide 1 0 silent \
    "token already has workflow scope, no signal => silent"

  # Common case 2: scope missing but nothing suggests workflow-touching work.
  assert_decide 0 0 silent \
    "missing scope but no workflow-touching signal => silent (no noise on common case)"
else
  assert_fail "detect-missing-workflow-scope.sh exists (missing at $DETECTOR)"
fi
echo

# ---------------------------------------------------------------------------
# (A2) Live-mode argument handling: no repo => silent, never a hard failure.
#      This is the fail-toward-silent posture the acceptance criteria and the
#      script's own header both call out.
# ---------------------------------------------------------------------------
echo "(A2) live-mode fail-safe — no repo argument resolves to silent, not an error"
if [[ -f "$DETECTOR" ]]; then
  got="$(bash "$DETECTOR" 2>/dev/null)"
  rc=$?
  if [[ "$rc" -eq 0 && "$got" == "silent" ]]; then
    assert_pass "no <owner/repo> argument => exits 0 with 'silent' (fail-safe, not a hard error)"
  else
    assert_fail "no <owner/repo> argument => exits 0 with 'silent' (got rc=$rc, output=[$got])"
  fi
fi
echo

# ---------------------------------------------------------------------------
# (B) Doc contract — commands/do-work/setup/01-repo-recovery.md.
# ---------------------------------------------------------------------------
echo "(B) setup/01-repo-recovery.md — doc contract"
if [[ -f "$SETUP_REPO_MD" ]]; then
  assert_pass "01-repo-recovery.md exists"

  assert_contains "$SETUP_REPO_MD" 'detect-missing-workflow-scope.sh' \
    "01-repo-recovery.md invokes the detector script (#818)"

  assert_contains "$SETUP_REPO_MD" 'gh auth refresh -h github.com -s workflow' \
    "01-repo-recovery.md names the exact remediation command from the issue's acceptance criteria"

  # The proactive warning must reuse #812's exact LANDED reactive-path token
  # verbatim (no backticks around "workflow" — read from origin/main's landed
  # auto-merge.md, not guessed from the issue body's illustrative prose) so
  # the two halves of the same problem don't diverge into two vocabularies.
  assert_contains "$SETUP_REPO_MD" 'auto-merge: unavailable — gh token lacks workflow scope' \
    "01-repo-recovery.md reuses #812's exact landed failure token verbatim (#818 coordination requirement)"

  assert_contains "$SETUP_REPO_MD" '#812' \
    "01-repo-recovery.md cites #812 as the reactive counterpart"

  assert_contains "$SETUP_REPO_MD" 'Silent by default' \
    "01-repo-recovery.md documents the silent-by-default posture"

  assert_contains "$SETUP_REPO_MD" 'One-time' \
    "01-repo-recovery.md documents the one-time-per-session posture"

  # Never attempt to refresh/escalate/modify scopes on the worker's own
  # authority — surfacing the remediation command is the only sanctioned act.
  assert_contains "$SETUP_REPO_MD" 'Never attempt to refresh, escalate, or modify the token' \
    "01-repo-recovery.md explicitly forbids self-driving gh auth refresh"

  # Single source of truth — the two-signal condition must not be
  # re-implemented as prose here (the #716 drift hazard this repo has
  # already been bitten by once for a structurally similar condition).
  if grep -qE '^\s*(HAS_SCOPE|WORKFLOW_SIGNAL)=' "$SETUP_REPO_MD"; then
    assert_fail "01-repo-recovery.md must NOT re-derive the two-signal condition inline — call the script"
  else
    assert_pass "01-repo-recovery.md does not re-derive the two-signal condition inline"
  fi
else
  assert_fail "01-repo-recovery.md exists (missing at $SETUP_REPO_MD)"
fi
echo

printf 'passed: %d, failed: %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
