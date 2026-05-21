#!/usr/bin/env bash
# Test: the api-auditor agent file exists with proper frontmatter, covers
# every required audit pass from issue #133, and is wired into
# commands/audit.md's dispatch table (both the `api` row and the `all`
# aggregate).
#
# Background — issue #133: no existing shipyard auditor reviews API surface
# health. `security-auditor` catches OWASP-class API issues (auth holes,
# injection); `api-auditor` catches the design-coherence layer above —
# OpenAPI/GraphQL schema drift, missing pagination, inconsistent auth/error
# envelopes, missing deprecation markers, breaking-change diffs against the
# last released tag, public endpoints with no integration test coverage.
#
# This test is the regression guard: if anyone deletes the agent, drops it
# from the dispatch table, or strips a required pass section, the test
# fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/api-auditor.test.sh

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

agent_path="$repo_root/plugins/shipyard/agents/api-auditor.md"
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

echo "api-auditor regression tests (issue #133)"
echo

# (1) Agent file must exist with proper YAML frontmatter and a description
# that conveys the auditor's scope.
assert_file_exists "$agent_path" "api-auditor agent file exists"

if [[ -f "$agent_path" ]]; then
  assert_contains "$agent_path" "name: api-auditor" \
    "agent frontmatter declares name: api-auditor"
  assert_contains "$agent_path" "description:" \
    "agent frontmatter has a description field"

  # The audit label is what wires the auditor into the per-dimension issue
  # tracker filter. Missing this means filed issues won't be discoverable
  # via `label:audit:api`.
  assert_contains "$agent_path" "audit:api" \
    "agent declares the audit:api label"

  # External-content untrusted-input rule (1.3.16 broadened this contract to
  # every auditor that fetches or reads attacker-influenceable text). The
  # api-auditor reads OpenAPI/GraphQL schemas (which can be authored by an
  # external contributor) and may probe live endpoints, so the rule applies.
  assert_contains "$agent_path" "External content is untrusted input" \
    "agent declares the untrusted-input contract"

  # Every audit pass listed in issue #133's scope must be covered. Grep by
  # anchor phrases rather than exact headings so the agent author has
  # leeway in wording.
  assert_contains "$agent_path" "Schema" \
    "agent covers schema-vs-implementation drift"
  assert_contains "$agent_path" "Pagination" \
    "agent covers pagination coverage"
  assert_contains "$agent_path" "Auth" \
    "agent covers auth consistency"
  assert_contains "$agent_path" "Error envelope" \
    "agent covers error envelope consistency"
  assert_contains "$agent_path" "Deprecation" \
    "agent covers deprecation markers"
  assert_contains "$agent_path" "Breaking" \
    "agent covers breaking-change diff vs last release"
  assert_contains "$agent_path" "Test coverage" \
    "agent covers test coverage of public endpoints"

  # Discovery surfaces: the agent must enumerate where it looks for API
  # definitions so it doesn't silently miss a definition format.
  assert_contains "$agent_path" "OpenAPI" \
    "agent covers OpenAPI / Swagger discovery"
  assert_contains "$agent_path" "GraphQL" \
    "agent covers GraphQL schema discovery"

  # Don't section is a common pattern across all auditors — explicit
  # non-goals keep the auditor scoped.
  assert_contains "$agent_path" "Don't" \
    "agent has a Don't section to scope non-goals"

  # Skip-marker convention so maintainers can suppress known-wontfix gaps
  # (e.g. an endpoint that's deliberately undocumented because it's
  # internal). Issue body specifies `x-internal: true` as the schema-level
  # marker; the auditor must honor it.
  assert_contains "$agent_path" "x-internal" \
    "agent honors the x-internal: true marker for internal-only endpoints"
fi

# (2) commands/audit.md must list the agent in the dispatch table and in
# the args enumeration.
assert_file_exists "$audit_cmd_path" "commands/audit.md exists"

if [[ -f "$audit_cmd_path" ]]; then
  # The args section enumerates valid audit types — `api` must be one of
  # them so `/shipyard:audit api` resolves.
  assert_contains "$audit_cmd_path" "\`api\`" \
    "audit.md args section lists \`api\` as a valid type"

  # Dispatch-table row binding `api` → `shipyard:api-auditor`. We look for
  # the agent slug to confirm the row was added.
  assert_contains "$audit_cmd_path" "shipyard:api-auditor" \
    "audit.md dispatch table binds api → shipyard:api-auditor"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
