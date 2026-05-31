#!/usr/bin/env bash
# Test: the parallel-auditor issue-number reconciliation contract (issue #435).
#
# Background — issue #435: when `/shipyard:audit` dispatches many auditors in
# parallel (the `all` path), each agent files via `gh issue create`
# concurrently. GitHub assigns issue numbers sequentially across the concurrent
# creates, so an agent that *predicts* its number or reads it back with a
# separate post-filing `gh issue list` can report a colliding or stale number —
# and a genuine finding can be silently lost when nobody holds its real number.
# A 15-auditor mattsears18.com run had two auditors both report #150/#152 and
# one real finding was never traced to its actual number.
#
# The fix is two-sided:
#   1. The shared `filing-github-issues` skill requires every auditor to capture
#      the real issue URL from `gh issue create`'s stdout and report THAT —
#      never a guessed/predicted number, never a separate read-back. It also
#      defines a per-run `audit-run=<run-id>` body marker for attribution.
#   2. `commands/audit.md` generates the run id, injects it into every agent
#      prompt, and reconciles the agents' reported URLs against a run-id-scoped
#      enumeration before writing the end-of-run summary.
#
# This test is the regression guard: if anyone strips the capture-from-stdout
# requirement, the run-id marker, or the orchestrator's reconciliation step,
# the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/audit-issue-number-reconciliation.test.sh

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

skill_path="$repo_root/plugins/shipyard/skills/filing-github-issues/SKILL.md"
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

echo "audit issue-number reconciliation tests (issue #435)"
echo

# (1) The filing skill must mandate capturing the real issue URL from
# gh issue create's stdout, and forbid guessed / read-back numbers.
assert_file_exists "$skill_path" "filing-github-issues SKILL.md exists"

if [[ -f "$skill_path" ]]; then
  assert_contains "$skill_path" "Capture the real issue number" \
    "skill has the capture-from-stdout section"
  # The captured-URL idiom: gh issue create assigned to a shell var.
  # shellcheck disable=SC2016  # literal needle — must NOT expand $(...)
  assert_contains "$skill_path" 'issue_url=$(gh issue create' \
    "skill shows capturing gh issue create stdout into a variable"
  assert_contains "$skill_path" "Never report a predicted number" \
    "skill forbids reporting a predicted number"
  assert_contains "$skill_path" "read back" \
    "skill forbids reporting a number read back from a separate gh issue list"
  # The per-run attribution marker that makes reconciliation definitive.
  assert_contains "$skill_path" "audit-run=" \
    "skill defines the audit-run per-run attribution marker"
  assert_contains "$skill_path" "Per-run attribution marker" \
    "skill has the per-run attribution marker section"
  # The marker is volatile, NOT for dedup (unlike audit-key).
  assert_contains "$skill_path" "do NOT use it for deduplication" \
    "skill warns audit-run is not for dedup"
  # The return-summary must report captured URLs.
  assert_contains "$skill_path" "Return summary — report captured URLs" \
    "skill's return-summary section requires reporting captured URLs"
  # Provenance: reference the originating issue.
  assert_contains "$skill_path" "#435" \
    "skill references issue #435 for provenance"
fi

# (2) commands/audit.md must generate the run id, inject it into agent
# prompts, and reconcile reported URLs against the run-id enumeration.
assert_file_exists "$audit_cmd_path" "commands/audit.md exists"

if [[ -f "$audit_cmd_path" ]]; then
  assert_contains "$audit_cmd_path" "AUDIT_RUN_ID" \
    "audit.md generates an audit run id"
  assert_contains "$audit_cmd_path" "audit-run=" \
    "audit.md instructs agents to stamp the audit-run marker"
  # The agent prompt template must carry the capture-from-stdout instruction.
  assert_contains "$audit_cmd_path" "Capture the real issue URL" \
    "audit.md agent prompt requires capturing the real issue URL"
  # The orchestrator-side reconciliation step.
  assert_contains "$audit_cmd_path" "Reconcile filed issues" \
    "audit.md has the reconciliation section"
  # shellcheck disable=SC2016  # literal needle — must NOT expand $AUDIT_RUN_ID
  assert_contains "$audit_cmd_path" 'audit-run=$AUDIT_RUN_ID' \
    "audit.md reconciles via a run-id-scoped issue search"
  assert_contains "$audit_cmd_path" "Process notes" \
    "audit.md surfaces reconciliation mismatches in Process notes"
  assert_contains "$audit_cmd_path" "#435" \
    "audit.md references issue #435 for provenance"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
