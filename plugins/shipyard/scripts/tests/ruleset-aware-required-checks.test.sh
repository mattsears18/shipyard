#!/usr/bin/env bash
# Test: the ungated admin-direct-merge detector reads RULESET-based branch
# protection, not just CLASSIC branch protection (issue #645).
#
# Background — issue #645: the detector decides whether a PR is on the "ungated
# admin-direct-merge" path (where `gh pr merge --auto` lands the PR before its
# CI completes) by reading the default branch's *required status checks*. Both
# the issue-worker auto-merge fragment (skills/worker-preamble/auto-merge.md
# step 0.5) and the orchestrator-side warning (commands/do-work/setup/
# 01-repo-recovery.md step 1.3) read CLASSIC branch protection:
#
#   repos/{owner}/{repo}/branches/{branch}/protection/required_status_checks[/contexts]
#
# That endpoint returns 0 required checks on a repo whose default branch is
# gated by a repository RULESET (GitHub Rulesets, NOT classic branch
# protection) — a SEPARATE gating mechanism. The detector then reads
# "required_checks == 0" and concludes the branch is ungated/admin-direct: a
# false positive. The branch is in fact gated (the #645 repro: lightwork's
# `main` is ruleset-protected requiring 4 checks, yet the classic probe reports
# 0). The false positive sends the issue-worker into an unnecessary
# --watch-then-merge block and surfaces a misleading orchestrator-side warning.
#
# The fix (issue #645): when the classic required-checks probe returns 0, ALSO
# probe the rulesets endpoint and treat the branch as gated if an active
# ruleset requires status checks OR a PR:
#
#   gh api repos/{owner}/{repo}/rules/branches/{branch} \
#     --jq '[.[].type] | (contains(["required_status_checks"]) or contains(["pull_request"]))'
#
# This mirrors the two-shape ruleset idiom the orchestrator's CHANGELOG-backfill
# write-path probe in steady-state.md already uses.
#
# This test pins:
#   (A) the ruleset fallback is present in auto-merge.md step 0.5 (regression
#       guard — if anyone reverts to the classic-only probe, this fails);
#   (B) the ruleset fallback is present in setup/01-repo-recovery.md step 1.3;
#   (C) the ruleset-gating jq decision itself: a ruleset requiring checks or a
#       PR resolves "gated" (true), while a ruleset with no such rule (or an
#       empty ruleset) resolves "ungated" (false).
#
# Run with:
#   bash plugins/shipyard/scripts/tests/ruleset-aware-required-checks.test.sh

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

AUTO_MERGE_MD="$repo_root/plugins/shipyard/skills/worker-preamble/auto-merge.md"
SETUP_MD="$repo_root/plugins/shipyard/commands/do-work/setup/01-repo-recovery.md"

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

assert_equals() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    assert_pass "$label (got [$actual])"
  else
    assert_fail "$label (expected [$expected], got [$actual])"
  fi
}

echo "ruleset-aware required-checks detector regression tests (issue #645)"
echo

# ---------------------------------------------------------------------------
# (A) auto-merge.md step 0.5 — the issue-worker auto-merge detector.
# ---------------------------------------------------------------------------
if [[ -f "$AUTO_MERGE_MD" ]]; then
  assert_pass "auto-merge.md exists"

  # shellcheck disable=SC2016
  # Single-quoted on purpose: the needle is the LITERAL markdown text, including
  # the un-expanded `${DEFAULT_BRANCH}` shell variable as it appears in the doc.
  assert_contains "$AUTO_MERGE_MD" 'repos/<owner/repo>/rules/branches/${DEFAULT_BRANCH}' \
    "auto-merge.md §0.5 probes the rulesets endpoint when classic checks read 0 (#645)"
  assert_contains "$AUTO_MERGE_MD" 'contains(["required_status_checks"]) or contains(["pull_request"])' \
    "auto-merge.md §0.5 treats a ruleset requiring checks OR a PR as gated (#645)"
  assert_contains "$AUTO_MERGE_MD" "Ruleset-aware fallback (#645)" \
    "auto-merge.md §0.5 carries the #645 ruleset-aware-fallback marker"

  # The ruleset probe must come AFTER the classic contexts read, not before
  # (it only fires as a fallback when the classic count is 0).
  classic_line=$(grep -n 'protection/required_status_checks/contexts' "$AUTO_MERGE_MD" | head -1 | cut -d: -f1)
  # shellcheck disable=SC2016
  # Literal markdown text — `${DEFAULT_BRANCH}` must not expand; we grep the doc for it.
  ruleset_line=$(grep -n 'rules/branches/${DEFAULT_BRANCH}' "$AUTO_MERGE_MD" | head -1 | cut -d: -f1)
  if [[ -n "$classic_line" && -n "$ruleset_line" && "$ruleset_line" -gt "$classic_line" ]]; then
    assert_pass "auto-merge.md ruleset probe follows the classic contexts read (L$ruleset_line > L$classic_line)"
  else
    assert_fail "auto-merge.md ruleset probe follows the classic contexts read (classic=L${classic_line:-?}, ruleset=L${ruleset_line:-?})"
  fi
else
  assert_fail "auto-merge.md exists (missing at $AUTO_MERGE_MD)"
fi

# ---------------------------------------------------------------------------
# (B) setup/01-repo-recovery.md step 1.3 — the orchestrator-side warning.
# ---------------------------------------------------------------------------
if [[ -f "$SETUP_MD" ]]; then
  assert_pass "setup/01-repo-recovery.md exists"

  assert_contains "$SETUP_MD" 'repos/<owner/repo>/rules/branches/<default-branch>' \
    "setup §1.3 probes the rulesets endpoint when classic checks read 0 (#645)"
  assert_contains "$SETUP_MD" 'contains(["required_status_checks"]) or contains(["pull_request"])' \
    "setup §1.3 treats a ruleset requiring checks OR a PR as gated (#645)"
  assert_contains "$SETUP_MD" "Ruleset-aware fallback (#645)" \
    "setup §1.3 carries the #645 ruleset-aware-fallback marker"

  # The #479 numeric-shape normalize must still precede the ruleset fallback
  # (the fallback keys on required_checks_count already being "0").
  norm_line=$(grep -n "''|\*\[!0-9\]\*) required_checks_count=0 ;;" "$SETUP_MD" | head -1 | cut -d: -f1)
  ruleset_line=$(grep -n 'rules/branches/<default-branch>' "$SETUP_MD" | head -1 | cut -d: -f1)
  if [[ -n "$norm_line" && -n "$ruleset_line" && "$ruleset_line" -gt "$norm_line" ]]; then
    assert_pass "setup §1.3 ruleset fallback follows the #479 normalize (L$ruleset_line > L$norm_line)"
  else
    assert_fail "setup §1.3 ruleset fallback follows the #479 normalize (norm=L${norm_line:-?}, ruleset=L${ruleset_line:-?})"
  fi
else
  assert_fail "setup/01-repo-recovery.md exists (missing at $SETUP_MD)"
fi

# ---------------------------------------------------------------------------
# (C) Behavioral test — the ruleset-gating jq decision.
#
# Replicate the exact jq expression both detectors use against sample
# `rules/branches/{branch}` payloads and assert the gated/ungated decision.
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  JQ='[.[].type] | (contains(["required_status_checks"]) or contains(["pull_request"])) | tostring'

  ruleset_decision() { printf '%s' "$1" | jq -r "$JQ" 2>/dev/null || echo "false"; }

  assert_equals "ruleset requiring checks + PR => gated" "true" \
    "$(ruleset_decision '[{"type":"required_status_checks"},{"type":"pull_request"}]')"
  assert_equals "ruleset requiring checks only => gated" "true" \
    "$(ruleset_decision '[{"type":"required_status_checks"}]')"
  assert_equals "ruleset requiring a PR only => gated" "true" \
    "$(ruleset_decision '[{"type":"pull_request"}]')"
  assert_equals "ruleset with no checks/PR rule => ungated" "false" \
    "$(ruleset_decision '[{"type":"creation"},{"type":"deletion"}]')"
  assert_equals "empty ruleset (no rules) => ungated" "false" \
    "$(ruleset_decision '[]')"

  # End-to-end: a ruleset-gated branch flips required_checks_count from 0 to a
  # non-zero sentinel, so shape 2 (admin + zero required checks) does NOT fire.
  required_checks_count=0   # classic probe reported zero (the #645 false positive)
  ruleset_gated=$(ruleset_decision '[{"type":"required_status_checks"}]')
  case "$ruleset_gated" in (true) required_checks_count=1 ;; esac
  viewer_admin="true"
  if [ "$viewer_admin" = "true" ] && [ "$required_checks_count" = "0" ]; then
    assert_fail "shape 2 must NOT fire on a ruleset-gated branch (admin + ruleset checks)"
  else
    assert_pass "shape 2 does NOT fire on a ruleset-gated branch (admin + ruleset checks)"
  fi

  # And a genuinely ungated branch (no classic checks, no gating ruleset) still
  # fires shape 2 — the fix must not over-suppress.
  required_checks_count=0
  ruleset_gated=$(ruleset_decision '[]')
  case "$ruleset_gated" in (true) required_checks_count=1 ;; esac
  if [ "$viewer_admin" = "true" ] && [ "$required_checks_count" = "0" ]; then
    assert_pass "shape 2 still fires on a genuinely ungated branch (admin + no checks, no ruleset)"
  else
    assert_fail "shape 2 still fires on a genuinely ungated branch (admin + no checks, no ruleset)"
  fi
else
  printf '  %sSKIP%s  behavioral jq tests (jq not installed)\n' "$GREEN" "$RESET"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
