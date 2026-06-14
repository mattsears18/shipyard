#!/usr/bin/env bash
# Test: every shipyard creation path stamps the `shipyard` provenance label and
# uses the ensure-then-label pattern (#573).
#
# Background — issue #573: the `shipyard` label was applied inconsistently.
# `/do-work` stamped its PRs but `/shipyard:file-issue` explicitly *declined*
# to stamp issues (its "Don't apply the `shipyard` label" rule), and auditors
# had no guarantee the label existed before they filed. The fix: every creation
# path — orchestrator PRs, worker follow-up issues, `/shipyard:file-issue`, all
# `audit:*` auditors, `/refine-issues`, `/decompose-epic` — must apply
# `shipyard` and first ensure the label exists (idempotent create).
#
# This test is the regression guard. It asserts:
# 1. filing-github-issues SKILL.md has the "shipyard provenance label" section
#    with the ensure-then-label pattern (idempotent create + --label shipyard).
# 2. The SKILL.md filing command examples include `--label shipyard`.
# 3. file-issue.md no longer carries the "Don't apply the `shipyard` label" rule
#    and instead carries the affirmative stamping rule.
# 4. decompose-epic.md ensures the label before creating sub-issues and passes
#    `--label shipyard` on each sub-issue create.
# 5. issue-work.md instructs workers to use `--label shipyard` on follow-up issues.
# 6. CLAUDE.md's Session-stamp label section says the stamp applies to every
#    issue AND PR, and names the ensure pattern.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/shipyard-label-always-stamped.test.sh

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
file_issue_cmd="$repo_root/plugins/shipyard/commands/file-issue.md"
decompose_cmd="$repo_root/plugins/shipyard/commands/decompose-epic.md"
issue_work="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"
claude_md="$repo_root/CLAUDE.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s:\n      %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if ! grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected NOT to find in %s:\n      %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

echo "shipyard-label-always-stamped regression tests (issue #573)"
echo

# ── 1. filing-github-issues SKILL.md ──────────────────────────────────────────
echo "1. filing-github-issues SKILL.md"

assert_contains "$filing_skill" \
  "shipyard provenance label" \
  "SKILL.md has '## \`shipyard\` provenance label' section"

assert_contains "$filing_skill" \
  "gh label create shipyard" \
  "SKILL.md contains the idempotent label-create command"

assert_contains "$filing_skill" \
  "--description \"Worked on by /shipyard:do-work\" --color 5319E7 2>/dev/null || true" \
  "SKILL.md ensure step uses correct description, color, and 2>/dev/null || true"

assert_contains "$filing_skill" \
  "--label shipyard" \
  "SKILL.md filing commands include --label shipyard"

assert_contains "$filing_skill" \
  "the provenance stamp" \
  "SKILL.md explains shipyard is the provenance stamp for all creation paths"

# Verify step mentioned
assert_contains "$filing_skill" \
  "index(\"shipyard\") != null" \
  "SKILL.md includes the verify-it-landed read-back step"

# ── 2. file-issue.md ──────────────────────────────────────────────────────────
echo
echo "2. file-issue.md"

# The old rule must be gone
assert_not_contains "$file_issue_cmd" \
  "Don't apply the \`shipyard\` label" \
  "file-issue.md no longer has 'Don't apply the shipyard label' rule"

# The new affirmative rule must be present
assert_contains "$file_issue_cmd" \
  "Do apply the \`shipyard\` label" \
  "file-issue.md has affirmative 'Do apply the shipyard label' rule"

# The ensure-then-label pattern in the filing step
assert_contains "$file_issue_cmd" \
  "gh label create shipyard" \
  "file-issue.md step 6 contains idempotent label-create"

assert_contains "$file_issue_cmd" \
  "--label shipyard" \
  "file-issue.md step 6 passes --label shipyard on gh issue create"

# ── 3. decompose-epic.md ──────────────────────────────────────────────────────
echo
echo "3. decompose-epic.md"

assert_contains "$decompose_cmd" \
  "gh label create shipyard --repo <owner/repo> --description \"Worked on by /shipyard:do-work\" --color 5319E7 2>/dev/null || true" \
  "decompose-epic.md ensures shipyard label before creating sub-issues"

assert_contains "$decompose_cmd" \
  "gh issue create --repo <owner/repo> --label shipyard" \
  "decompose-epic.md passes --label shipyard on sub-issue create"

# ── 4. issue-work.md ──────────────────────────────────────────────────────────
echo
echo "4. issue-work.md (worker follow-up issues)"

assert_contains "$issue_work" \
  "--label shipyard" \
  "issue-work.md instructs workers to pass --label shipyard on follow-up issues"

assert_contains "$issue_work" \
  "ensure-then-label pattern" \
  "issue-work.md references the ensure-then-label pattern for follow-up issues"

# ── 5. CLAUDE.md session-stamp label section ───────────────────────────────────
echo
echo "5. CLAUDE.md session-stamp label section"

assert_contains "$claude_md" \
  "every issue AND PR" \
  "CLAUDE.md session-stamp label section says stamp applies to every issue AND PR"

assert_contains "$claude_md" \
  "all creation paths" \
  "CLAUDE.md names all creation paths for the stamp"

assert_contains "$claude_md" \
  "/shipyard:file-issue" \
  "CLAUDE.md lists /shipyard:file-issue as a stamped creation path"

assert_contains "$claude_md" \
  "audit:*" \
  "CLAUDE.md lists audit:* auditors as stamped creation paths"

assert_contains "$claude_md" \
  "/decompose-epic" \
  "CLAUDE.md lists /decompose-epic as a stamped creation path"

assert_contains "$claude_md" \
  "ensure the label exists first" \
  "CLAUDE.md prescribes ensuring the label exists first"

assert_contains "$claude_md" \
  "2>/dev/null || true" \
  "CLAUDE.md's ensure command uses 2>/dev/null || true (idempotent)"

# The old narrow scope must be gone
assert_not_contains "$claude_md" \
  "the orchestrator session stamp on every PR it produces" \
  "CLAUDE.md no longer scopes the stamp to PRs only"

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
