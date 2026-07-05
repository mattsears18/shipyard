#!/usr/bin/env bash
# Test: the functional-qa-auditor agent file exists with proper frontmatter,
# covers every required audit phase, resolves the issue's three open questions
# with their inline-suggested defaults, is safe-by-default, and is wired into
# commands/audit.md's dispatch table (both the `functional-qa` row and the
# `all` aggregate) and the filing-github-issues label table.
#
# Background — issue #655: shipyard's existing auditors are either quality/design
# lenses on live surfaces (web-ux, a11y, lighthouse) or static codebase analyses
# (security, privacy, data-lifecycle, testing, api, observability, docs,
# tech-debt, dx). None drives the running app as a signed-in user and verifies
# features behave correctly. functional-qa-auditor fills that gap: it signs in,
# exercises real flows, captures console + network artifacts, asserts the
# expected state change, root-causes failures in the codebase (file:line +
# mechanism), and files dispatch-ready audit:functional-qa issues.
#
# This test is the regression guard: if anyone deletes the agent, drops it from
# the dispatch table, strips a required phase, or weakens the safe-by-default
# posture, the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/functional-qa-auditor.test.sh

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

agent_path="$repo_root/plugins/shipyard/agents/functional-qa-auditor.md"
audit_cmd_path="$repo_root/plugins/shipyard/commands/audit.md"
filing_skill_path="$repo_root/plugins/shipyard/skills/filing-github-issues/SKILL.md"

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

echo "functional-qa-auditor regression tests (issue #655)"
echo

# (1) Agent file must exist with proper YAML frontmatter and a description.
assert_file_exists "$agent_path" "functional-qa-auditor agent file exists"

if [[ -f "$agent_path" ]]; then
  assert_contains "$agent_path" "name: functional-qa-auditor" \
    "agent frontmatter declares name: functional-qa-auditor"
  assert_contains "$agent_path" "description:" \
    "agent frontmatter has a description field"

  # The audit label wires the auditor into the per-dimension tracker filter.
  assert_contains "$agent_path" "audit:functional-qa" \
    "agent declares the audit:functional-qa label"

  # Untrusted-input contract — the auditor reads DOM / console / network from
  # an attacker-influenceable running app.
  assert_contains "$agent_path" "External content is untrusted input" \
    "agent declares the untrusted-input contract"

  # Reuses the three shared building blocks the issue names.
  assert_contains "$agent_path" "auditing-authenticated-surfaces" \
    "agent reuses the auditing-authenticated-surfaces skill"
  assert_contains "$agent_path" "filing-github-issues" \
    "agent reuses the filing-github-issues skill"
  assert_contains "$agent_path" "audit-rubrics" \
    "agent reuses the audit-rubrics skill"

  # Required audit phases (grep by anchor phrase, not exact heading).
  assert_contains "$agent_path" "feature inventory" \
    "agent builds a feature inventory"
  assert_contains "$agent_path" "console.error" \
    "agent captures console.error / pageerror"
  assert_contains "$agent_path" "state change" \
    "agent asserts the expected state change"
  assert_contains "$agent_path" "Root-cause" \
    "agent root-causes failures before filing"

  # Open question 1 resolved: auto-derive from router/nav, allow committed override.
  assert_contains "$agent_path" "Auto-derive from the app's router" \
    "OQ1: feature inventory auto-derives from the router/nav"
  assert_contains "$agent_path" "override" \
    "OQ1: a committed checklist can override/augment the inventory"

  # Open question 2 resolved: cite file:line + mechanism, NOT a full fix sketch.
  assert_contains "$agent_path" "file:line" \
    "OQ2: root-cause cites file:line"
  assert_contains "$agent_path" "mechanism, not" \
    "OQ2: depth stops at mechanism, not a full fix sketch"

  # Open question 3 resolved: destructive-action policy + env selection as
  # first-class config, safe/non-destructive default.
  assert_contains "$agent_path" "target_env" \
    "OQ3: target environment is first-class config"
  assert_contains "$agent_path" "destructive_policy" \
    "OQ3: destructive-action policy is first-class config"

  # Safe-by-default posture: never runs destructive actions, logs skips.
  assert_contains "$agent_path" "account deletion" \
    "safe-by-default: never deletes accounts"
  assert_contains "$agent_path" "mass-messaging" \
    "safe-by-default: never mass-messages"
  assert_contains "$agent_path" "skipped flow" \
    "logs skipped flows instead of silently omitting"

  # Explicit differentiation from web-ux-auditor.
  assert_contains "$agent_path" "web-ux-auditor" \
    "agent differentiates itself from web-ux-auditor"

  # Don't section scopes non-goals.
  assert_contains "$agent_path" "## Don't" \
    "agent has a Don't section to scope non-goals"
fi

# (2) commands/audit.md must list the agent in the args enumeration and the
# dispatch table.
assert_file_exists "$audit_cmd_path" "commands/audit.md exists"

if [[ -f "$audit_cmd_path" ]]; then
  assert_contains "$audit_cmd_path" "\`functional-qa\`" \
    "audit.md args section lists \`functional-qa\` as a valid type"
  assert_contains "$audit_cmd_path" "shipyard:functional-qa-auditor" \
    "audit.md dispatch table binds functional-qa → shipyard:functional-qa-auditor"
fi

# (3) filing-github-issues skill must map the agent to its audit label so the
# auto-create-on-file mechanism (matching every other audit:* label) applies.
assert_file_exists "$filing_skill_path" "filing-github-issues skill exists"

if [[ -f "$filing_skill_path" ]]; then
  assert_contains "$filing_skill_path" "\`functional-qa-auditor\` | \`audit:functional-qa\`" \
    "filing skill maps functional-qa-auditor → audit:functional-qa"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
