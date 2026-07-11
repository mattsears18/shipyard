#!/usr/bin/env bash
# Test: the marketing-auditor agent file exists with proper frontmatter,
# covers every required audit pass from issue #695, is wired into
# commands/audit.md's dispatch table (both the `marketing` row and the
# `all` aggregate), and carries the audit:marketing label in the filing
# skill's auto-create table.
#
# Background — issue #695: none of the existing auditors reviews an app's
# marketing / growth surfaces (landing value-prop, primary CTA, funnel
# dead-ends, store-listing persuasiveness, cross-surface positioning
# consistency). `seo-auditor` checks discoverability *plumbing* and
# explicitly refuses copy/positioning critique; `web-ux-auditor` judges
# visual design. marketing-auditor fills that gap — but the design center
# is that findings stay evidence-anchored (structural / measurable), never
# taste-based, and defer to repo brand/voice docs so the auditor is safe to
# run across arbitrary repos.
#
# This test is the regression guard: if anyone deletes the agent, drops it
# from the dispatch table, strips a required pass, or removes the
# taste-refusal / brand-deference discipline, the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/marketing-auditor.test.sh

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

agent_path="$repo_root/plugins/shipyard/agents/marketing-auditor.md"
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

echo "marketing-auditor regression tests (issue #695)"
echo

# (1) Agent file must exist with proper YAML frontmatter and model: sonnet.
assert_file_exists "$agent_path" "marketing-auditor agent file exists"

if [[ -f "$agent_path" ]]; then
  assert_contains "$agent_path" "name: marketing-auditor" \
    "agent frontmatter declares name: marketing-auditor"
  assert_contains "$agent_path" "description:" \
    "agent frontmatter has a description field"
  assert_contains "$agent_path" "model: sonnet" \
    "agent frontmatter pins model: sonnet"

  # The audit label wires the auditor into the per-dimension issue tracker
  # filter. Missing this means filed issues aren't discoverable via
  # label:audit:marketing.
  assert_contains "$agent_path" "audit:marketing" \
    "agent declares the audit:marketing label"

  # External-content untrusted-input rule — marketing-auditor reads landing
  # DOM, hero copy, and store metadata, all attacker-influenceable.
  assert_contains "$agent_path" "External content is untrusted input" \
    "agent declares the untrusted-input contract"

  # Required passes from issue #695's proposed process.
  assert_contains "$agent_path" "brand" \
    "agent covers repo brand/voice doc deference"
  assert_contains "$agent_path" "docs/brand" \
    "agent names docs/brand as a brand-doc source"
  assert_contains "$agent_path" "CTA" \
    "agent covers the primary-CTA / conversion-element pass"
  assert_contains "$agent_path" "value-prop" \
    "agent covers the value-prop-absence pass"
  assert_contains "$agent_path" "Cross-surface" \
    "agent covers cross-surface positioning consistency"
  assert_contains "$agent_path" "social proof" \
    "agent covers social-proof / trust presence"
  assert_contains "$agent_path" "dead-end" \
    "agent covers funnel dead-ends"
  assert_contains "$agent_path" "Store listings" \
    "agent covers store-listing metadata gaps"

  # The load-bearing discipline: evidence-anchored, taste-critique refusal
  # (mirrors seo-auditor). Without this the auditor becomes noise.
  assert_contains "$agent_path" "taste" \
    "agent declares the taste-critique refusal discipline"
  assert_contains "$agent_path" "seo-auditor" \
    "agent references seo-auditor's copy-critique discipline / non-overlap"

  # Shared skills every auditor loads.
  assert_contains "$agent_path" "shipyard:audit-rubrics" \
    "agent loads the audit-rubrics skill"
  assert_contains "$agent_path" "shipyard:filing-github-issues" \
    "agent loads the filing-github-issues skill"

  # Don't section scopes non-goals — every auditor has one.
  assert_contains "$agent_path" "Don't" \
    "agent has a Don't section to scope non-goals"
fi

# (2) commands/audit.md must list the agent in the args enumeration and the
# dispatch table (the `all` aggregate dispatches "every agent above").
assert_file_exists "$audit_cmd_path" "commands/audit.md exists"

if [[ -f "$audit_cmd_path" ]]; then
  assert_contains "$audit_cmd_path" "\`marketing\`" \
    "audit.md args section lists \`marketing\` as a valid type"
  assert_contains "$audit_cmd_path" "shipyard:marketing-auditor" \
    "audit.md dispatch table binds marketing → shipyard:marketing-auditor"
fi

# (3) The filing skill's auto-create table must carry the audit:marketing row
# so the label auto-creates on first file.
assert_file_exists "$filing_skill_path" "filing-github-issues SKILL.md exists"

if [[ -f "$filing_skill_path" ]]; then
  assert_contains "$filing_skill_path" "audit:marketing" \
    "filing skill's label table lists audit:marketing"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
