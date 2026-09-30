#!/usr/bin/env bash
#
# gate-threshold-measurement-1603.test.sh
#
# Pins issue #1603: a worker that sets or moves a number a CI step enforces
# (a coverage floor, a size budget, a warning cap) must measure it with the
# exact command that CI step runs - not the repo's headline test script,
# which is usually broader than the gate and so overstates what the gate
# will see. The lightwork repro: coverage floors measured over
# web+native+meta, enforced over web+native only, failed three CI runs.
#
# Sites carrying the fix, each asserted here:
#   1. the worker-preamble ci-pitfalls fragment - the rule itself (find the
#      invoking step, measure with it, record the command beside the figure,
#      and the broader-is-unsafe asymmetry);
#   2. the worker's always-loaded spec (issue-work.md section 4) - a pointer
#      so the rule fires on every dispatch;
#   3. the worker-preamble SKILL.md fragment index row, so the section stays
#      discoverable.
#
# Run:
#   plugins/shipyard/scripts/tests/gate-threshold-measurement-1603.test.sh

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

plugin_root="$repo_root/plugins/shipyard"
section_title='A threshold measured by a run broader than the gate is always wrong in the unsafe direction'

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

record_pass() {
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"
  pass=$((pass + 1))
}

record_fail() {
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"
  fail=$((fail + 1))
}

assert_contains() {
  local path="$1" needle="$2" label="$3"
  if [[ ! -f "$path" ]]; then
    record_fail "$label (file missing: $path)"
    return
  fi
  if grep -qF -- "$needle" "$path"; then
    record_pass "$label"
  else
    record_fail "$label (missing: $needle)"
  fi
}

echo "== #1603: CI gate thresholds are measured with the gating command"

fragment="$plugin_root/skills/worker-preamble/ci-pitfalls.md"
assert_contains "$fragment" "## $section_title" \
  "ci-pitfalls.md carries the gate-threshold section"
assert_contains "$fragment" "Find the invoking step from the workflow" \
  "ci-pitfalls.md rule 1: locate the step that consumes the constant"
assert_contains "$fragment" "Measure with that exact command" \
  "ci-pitfalls.md rule 2: measure with the gating command"
assert_contains "$fragment" "Record the command alongside the number" \
  "ci-pitfalls.md rule 3: record the command beside the figure"
assert_contains "$fragment" "A broader run can only *add* coverage" \
  "ci-pitfalls.md states the broader-is-unsafe asymmetry"
assert_contains "$fragment" "issues/1603" \
  "ci-pitfalls.md cites #1603"

assert_contains "$plugin_root/skills/worker-preamble/SKILL.md" \
  "A threshold measured by a run broader than the gate" \
  "worker-preamble SKILL.md indexes the new ci-pitfalls section"

issue_work="$plugin_root/agents/issue-worker/issue-work.md"
assert_contains "$issue_work" "$section_title" \
  "issue-work.md section 4 points at the gate-threshold rule"
assert_contains "$issue_work" "issues/1603" \
  "issue-work.md cites #1603"

echo
echo "Results: ${GREEN}${pass} passed${RESET}, ${RED}${fail} failed${RESET}"
[[ $fail -eq 0 ]]
