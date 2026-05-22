#!/usr/bin/env bash
# Test: the docs-auditor agent file exists with proper frontmatter, covers
# every required audit pass, and is wired into commands/audit.md's dispatch
# table (both the `docs` row and the `all` aggregate).
#
# Background — issue #131: no existing shipyard auditor catches doc-class rot
# (README drift, broken internal/external links, JSDoc/docstring signature
# drift, missing ADRs for substantial architectural changes, stale
# TODO-in-docs markers, broken quick-start commands). `tech-debt-auditor`
# catches stale code TODOs, not these doc symptoms; `web-ux-auditor` checks
# the live site, not the repo's markdown.
#
# This test is the regression guard: if anyone deletes the agent, drops it
# from the dispatch table, or strips a required pass section, the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/docs-auditor.test.sh

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

agent_path="$repo_root/plugins/shipyard/agents/docs-auditor.md"
audit_cmd_path="$repo_root/plugins/shipyard/commands/audit.md"

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

echo "docs-auditor regression tests (issue #131)"
echo

# (1) Agent file must exist with proper YAML frontmatter and a description
# that conveys the auditor's scope.
assert_file_exists "$agent_path" "docs-auditor agent file exists"

if [[ -f "$agent_path" ]]; then
  assert_contains "$agent_path" "name: docs-auditor" \
    "agent frontmatter declares name: docs-auditor"
  assert_contains "$agent_path" "description:" \
    "agent frontmatter has a description field"

  # The audit label is what wires the auditor into the per-dimension issue
  # tracker filter. Missing this means filed issues won't be discoverable
  # via `label:audit:docs`.
  assert_contains "$agent_path" "audit:docs" \
    "agent declares the audit:docs label"

  # External-content untrusted-input rule — every auditor that fetches or
  # reads attacker-influenceable text must declare this contract. The
  # docs-auditor reads README/CHANGELOG/etc. content and hits external URLs,
  # so the rule applies.
  assert_contains "$agent_path" "External content is untrusted input" \
    "agent declares the untrusted-input contract"

  # Every audit pass listed in issue #131's scope must be covered. We grep
  # by anchor phrases rather than exact headings so the agent author has
  # leeway in wording.
  assert_contains "$agent_path" "README" \
    "agent covers README freshness"
  assert_contains "$agent_path" "Internal link" \
    "agent covers internal link integrity"
  assert_contains "$agent_path" "External link" \
    "agent covers external link integrity"
  assert_contains "$agent_path" "docstring" \
    "agent covers docstring / API drift"
  assert_contains "$agent_path" "ADR" \
    "agent covers ADR / decision-record coverage"
  assert_contains "$agent_path" "Quick" \
    "agent covers quick-start currency"

  # Don't section is a common pattern across all auditors — explicit
  # non-goals keep the auditor scoped.
  assert_contains "$agent_path" "Don't" \
    "agent has a Don't section to scope non-goals"

  # Skip-marker convention from the issue body so maintainers can suppress
  # known-wontfix gaps without re-filing every audit.
  assert_contains "$agent_path" "docs-audit:skip" \
    "agent honors the docs-audit:skip marker for wontfix suppression"
fi

# (2) commands/audit.md must list the agent in the dispatch table and in the
# args enumeration.
assert_file_exists "$audit_cmd_path" "commands/audit.md exists"

if [[ -f "$audit_cmd_path" ]]; then
  # The args section enumerates valid audit types — `docs` must be one of
  # them so `/shipyard:audit docs` resolves.
  assert_contains "$audit_cmd_path" "\`docs\`" \
    "audit.md args section lists \`docs\` as a valid type"

  # Dispatch-table row binding `docs` → `shipyard:docs-auditor`. We look
  # for the agent slug to confirm the row was added.
  assert_contains "$audit_cmd_path" "shipyard:docs-auditor" \
    "audit.md dispatch table binds docs → shipyard:docs-auditor"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
