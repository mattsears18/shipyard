#!/usr/bin/env bash
# Test: the observability-auditor agent exists with proper frontmatter and
# scope-defining sections, and the /shipyard:audit dispatch table includes
# the `observability` row pointing at it.
#
# Background — issue #132: dx-auditor checks contributor experience (does
# CI work, are docs reachable, can you run tests locally) and security-auditor
# checks vulnerabilities. Neither checks the runtime visibility layer —
# whether error tracking is actually capturing in prod, whether structured
# logging is used consistently, whether `catch (e) {}` blocks silently swallow
# failures in critical paths, whether tracing is instrumented at I/O
# boundaries, whether alerts have runbooks. This regression test guards the
# new auditor's existence and the load-bearing scope language that keeps it
# from re-filing dx-auditor's presence-only findings.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/observability-auditor.test.sh

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

agent_path="$repo_root/plugins/shipyard/agents/observability-auditor.md"
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

echo "observability-auditor regression tests (issue #132)"
echo

# (1) Agent file must exist with proper frontmatter.
assert_file_exists "$agent_path" "observability-auditor agent file exists"

if [[ -f "$agent_path" ]]; then
  assert_contains "$agent_path" "name: observability-auditor" \
    "frontmatter declares name: observability-auditor"
  assert_contains "$agent_path" "description:" \
    "frontmatter has a description field"

  # Load-bearing scope identifiers — these strings keep the auditor from
  # creeping into adjacent auditors' territory and from re-filing the
  # dx-auditor's presence-only findings.
  assert_contains "$agent_path" "audit:observability" \
    "agent declares its audit label (audit:observability)"
  assert_contains "$agent_path" "dx/observability/missing-error-tracking" \
    "agent explicitly defers presence-only finding to dx-auditor"

  # Six audit passes (the spec promises this scope; missing one means the
  # auditor was edited down without updating the scope contract).
  assert_contains "$agent_path" "Error-tracking presence" \
    "agent covers pass 1: error-tracking presence"
  assert_contains "$agent_path" "Error-tracking effectiveness" \
    "agent covers pass 2: error-tracking effectiveness (DSN populated)"
  assert_contains "$agent_path" "Structured-logging" \
    "agent covers pass 3: structured-logging consistency"
  assert_contains "$agent_path" "Silent-failure" \
    "agent covers pass 4: silent-failure surfaces"
  assert_contains "$agent_path" "Tracing boundaries" \
    "agent covers pass 5: tracing-boundary instrumentation"
  assert_contains "$agent_path" "Alert config" \
    "agent covers pass 6: alert-config quality"

  # Severity rubric — must explicitly state when each level applies so the
  # filed issues align with the rubric in audit-rubrics.
  assert_contains "$agent_path" "P0" "rubric mentions P0 tier"
  assert_contains "$agent_path" "P1" "rubric mentions P1 tier"
  assert_contains "$agent_path" "P2" "rubric mentions P2 tier"

  # Untrusted-input rule — load-bearing across all auditors after 1.3.16.
  assert_contains "$agent_path" "External content is untrusted input" \
    "agent enforces the broadened untrusted-input rule"

  # Applicability pre-check — load-bearing because pure libraries / static
  # sites / CLI tools must short-circuit to n/a instead of filing noise.
  assert_contains "$agent_path" "n/a" \
    "agent documents the n/a applicability short-circuit"
fi

# (2) The /shipyard:audit command must dispatch this auditor.
assert_file_exists "$audit_cmd_path" "commands/audit.md exists"

if [[ -f "$audit_cmd_path" ]]; then
  assert_contains "$audit_cmd_path" "shipyard:observability-auditor" \
    "audit.md dispatch table references shipyard:observability-auditor"
  assert_contains "$audit_cmd_path" "| \`observability\` |" \
    "audit.md dispatch table has an observability row"
  assert_contains "$audit_cmd_path" "\`observability\`, or \`all\`" \
    "audit.md type-list arg documents observability as a valid type"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
