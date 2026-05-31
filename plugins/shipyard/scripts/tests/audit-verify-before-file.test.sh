#!/usr/bin/env bash
# Test: the verify-before-file contract for audit agents (issue #434).
#
# Background — issue #434: during a full `/shipyard:audit all` run against
# `mattsears18/mattsears18.com` (2026-05-31), 13 of 44 filed issues were
# fabricated false positives that had to be retracted. Four auditors ran
# reconnaissance reads in the SAME parallel tool-call batch as `gh issue
# create`, acting on unverified (sometimes empty/garbled) command output —
# e.g. "tailwind.config.ts doesn't exist" against a repo where it does, and
# "remove unused @tailwindcss/typography" against a package that isn't a
# dependency at all. The agents self-corrected and retracted AFTER filing.
#
# The fix is structural and three-sided:
#   1. The shared `filing-github-issues` skill adds a hard verify-before-file
#      gate: every finding must cite a freshly-read evidence artifact captured
#      in a step that COMPLETED BEFORE the `gh issue create` call — never in
#      the same speculative parallel batch — plus a self-review re-read pass
#      and a documented retraction path for false positives that slip through.
#   2. The `audit-rubrics` skill's Evidence bar requires the evidence be freshly
#      observed (not assumed) and observed before the create, cross-referencing
#      the filing-skill gate.
#   3. `commands/audit.md`'s agent prompt template carries the verify-before-file
#      instruction, and the reconciliation step closes any issue an agent
#      flagged as filed in error.
#
# This test is the regression guard: if anyone strips the verify-before-file
# gate, the self-review pass, the retraction path, or the audit.md prompt
# instruction, the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/audit-verify-before-file.test.sh

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

filing_skill="$repo_root/plugins/shipyard/skills/filing-github-issues/SKILL.md"
rubrics_skill="$repo_root/plugins/shipyard/skills/audit-rubrics/SKILL.md"
audit_cmd="$repo_root/plugins/shipyard/commands/audit.md"

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

echo "audit verify-before-file contract tests (issue #434)"
echo

# (1) The filing skill must carry the hard verify-before-file gate.
assert_file_exists "$filing_skill" "filing-github-issues SKILL.md exists"

if [[ -f "$filing_skill" ]]; then
  assert_contains "$filing_skill" "Verify before you file" \
    "filing skill has the verify-before-file section"
  assert_contains "$filing_skill" "completed before" \
    "filing skill requires evidence captured before the create call"
  assert_contains "$filing_skill" "same speculative parallel batch" \
    "filing skill forbids batching the create with its own recon"
  assert_contains "$filing_skill" "Self-review pass" \
    "filing skill mandates a self-review re-read pass before the create"
  assert_contains "$filing_skill" "retraction path" \
    "filing skill documents the false-positive retraction path"
  assert_contains "$filing_skill" "Filed in error (needs retraction)" \
    "filing skill names the in-summary retraction fallback line"
  assert_contains "$filing_skill" "#434" \
    "filing skill references issue #434 for provenance"
fi

# (2) The rubrics skill's Evidence bar must require freshly-observed,
# observed-before-file evidence and cross-reference the filing gate.
assert_file_exists "$rubrics_skill" "audit-rubrics SKILL.md exists"

if [[ -f "$rubrics_skill" ]]; then
  assert_contains "$rubrics_skill" "freshly observed this session, not assumed" \
    "rubrics Evidence bar requires freshly-observed (not assumed) evidence"
  assert_contains "$rubrics_skill" "Verify before you file" \
    "rubrics Evidence bar cross-references the filing-skill gate"
  assert_contains "$rubrics_skill" "#434" \
    "rubrics skill references issue #434 for provenance"
fi

# (3) The audit command's agent prompt template must carry the instruction,
# and the reconciliation step must close agent-flagged false positives.
assert_file_exists "$audit_cmd" "commands/audit.md exists"

if [[ -f "$audit_cmd" ]]; then
  assert_contains "$audit_cmd" "Verify every finding against ground truth before you file" \
    "audit.md agent prompt requires verify-before-file"
  assert_contains "$audit_cmd" "Filed in error (needs retraction)" \
    "audit.md prompt asks agents to surface filed-in-error issues"
  assert_contains "$audit_cmd" "Close any issue an agent flagged as filed in error" \
    "audit.md reconciliation closes agent-flagged false positives"
  assert_contains "$audit_cmd" "#434" \
    "audit.md references issue #434 for provenance"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
