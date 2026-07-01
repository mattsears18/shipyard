#!/usr/bin/env bash
# Test: the data-lifecycle-auditor agent exists with proper frontmatter and
# scope-defining sections, and the /shipyard:audit dispatch table includes
# the `data-lifecycle` row pointing at it.
#
# Background — issue #652: shipyard had 15 auditors, none owning the data-model
# mutation lifecycle / referential-integrity / cascade-completeness surface —
# i.e. when a document is created, updated, or deleted, does the right thing
# happen to everything that references it? privacy-auditor reviews the
# account-deletion flow through a GDPR-erasure lens (not correctness),
# security-auditor owns authz (who may write, not whether cascades are
# complete), api-auditor owns API-contract coherence, testing-auditor finds
# missing tests. This regression test guards the new auditor's existence and
# the load-bearing deferral language that keeps it from re-filing those four
# adjacent auditors' findings.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/data-lifecycle-auditor.test.sh

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

agent_path="$repo_root/plugins/shipyard/agents/data-lifecycle-auditor.md"
audit_cmd_path="$repo_root/plugins/shipyard/commands/audit.md"
readme_path="$repo_root/README.md"

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

echo "data-lifecycle-auditor regression tests (issue #652)"
echo

# (1) Agent file must exist with proper frontmatter.
assert_file_exists "$agent_path" "data-lifecycle-auditor agent file exists"

if [[ -f "$agent_path" ]]; then
  assert_contains "$agent_path" "name: data-lifecycle-auditor" \
    "frontmatter declares name: data-lifecycle-auditor"
  assert_contains "$agent_path" "description:" \
    "frontmatter has a description field"

  # Audit label — applied to every filed issue.
  assert_contains "$agent_path" "audit:data-lifecycle" \
    "agent declares its audit label (audit:data-lifecycle)"

  # Deferral boundaries — load-bearing; these keep the auditor from re-filing
  # the four adjacent auditors' findings.
  assert_contains "$agent_path" "audit:privacy" \
    "agent defers PII-erasure findings to privacy-auditor"
  assert_contains "$agent_path" "audit:security" \
    "agent defers rules/authz findings to security-auditor"
  assert_contains "$agent_path" "audit:testing" \
    "agent defers missing-test findings to testing-auditor"
  assert_contains "$agent_path" "audit:api" \
    "agent defers API schema-drift findings to api-auditor"

  # Six process passes (0-5) — the spec promises this scope; a missing one
  # means the auditor was edited down without updating the scope contract.
  assert_contains "$agent_path" "build the reference graph" \
    "agent covers pass 0: discover data model + reference graph"
  assert_contains "$agent_path" "Delete cascades" \
    "agent covers pass 1: delete cascades"
  assert_contains "$agent_path" "denormalization" \
    "agent covers pass 2: update / denormalization drift"
  assert_contains "$agent_path" "Create-time side-effects" \
    "agent covers pass 3: create-time side-effects"
  assert_contains "$agent_path" "GC / TTL" \
    "agent covers pass 4: GC / TTL on ephemeral collections"
  assert_contains "$agent_path" "Storage / external side-effects" \
    "agent covers pass 5: storage / external side-effects"

  # Skip marker — honored like the other auditors' skip markers.
  assert_contains "$agent_path" "data-lifecycle-audit:skip" \
    "agent honors the data-lifecycle-audit:skip marker"

  # Severity rubric — must explicitly state when each level applies.
  assert_contains "$agent_path" "P0" "rubric mentions P0 tier"
  assert_contains "$agent_path" "P1" "rubric mentions P1 tier"
  assert_contains "$agent_path" "P2" "rubric mentions P2 tier"

  # Untrusted-input rule — load-bearing across all auditors.
  assert_contains "$agent_path" "External content is untrusted input" \
    "agent enforces the untrusted-input rule"

  # Applicability pre-check — pure libraries / static sites / stateless CLIs
  # with no datastore must short-circuit to n/a instead of filing noise.
  assert_contains "$agent_path" "n/a" \
    "agent documents the n/a applicability short-circuit"
fi

# (2) The /shipyard:audit command must dispatch this auditor.
assert_file_exists "$audit_cmd_path" "commands/audit.md exists"

if [[ -f "$audit_cmd_path" ]]; then
  assert_contains "$audit_cmd_path" "shipyard:data-lifecycle-auditor" \
    "audit.md dispatch table references shipyard:data-lifecycle-auditor"
  assert_contains "$audit_cmd_path" "| \`data-lifecycle\` |" \
    "audit.md dispatch table has a data-lifecycle row"
  assert_contains "$audit_cmd_path" "\`data-lifecycle\`" \
    "audit.md type-list arg documents data-lifecycle as a valid type"
fi

# (3) README documents the new audit dimension.
assert_file_exists "$readme_path" "README.md exists"

if [[ -f "$readme_path" ]]; then
  assert_contains "$readme_path" "/audit data-lifecycle" \
    "README lists the /audit data-lifecycle command"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
