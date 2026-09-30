#!/usr/bin/env bash
# Test: concurrent workers are told they share the host, so one worker's
# fixed-port test run doesn't silently tear down another's (issue #1594).
#
# Background
# ----------
# At --concurrency >= 2, two workers running emulator-backed gates on a repo
# whose test runner binds FIXED ports (and kills stale listeners first) destroy
# each other's services. The victim sees its own suite fail on its own diff and
# debugs the diff. The target repo already shipped a port-isolation wrapper;
# nothing in the dispatch contract told a worker it was one of N tenants.
#
# The fix has two halves, both asserted here:
#   1. worker-preamble: an always-loaded core rule + the on-demand
#      shared-host-services.md fragment (durable, repo-agnostic).
#   2. dispatch-rules.md: a Concurrent-tenant augmentation that states N in the
#      issue-work prompt when concurrency > 1, mirrored by buildIssueWorkPrompt
#      (the Workflow-substrate builder), which renders it ONLY when > 1.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/concurrent-tenant-1594.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_root="$(cd "$here/../.." && pwd)"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if [[ -f "$file" ]] && grep -qF -- "$needle" "$file"; then ok "$label"; else bad "$label"; printf '    missing: %s\n    in: %s\n' "$needle" "$file"; fi
}

preamble="$plugin_root/skills/worker-preamble/SKILL.md"
fragment="$plugin_root/skills/worker-preamble/shared-host-services.md"
dispatch_rules="$plugin_root/commands/do-work/dispatch-rules.md"
issue_work="$plugin_root/agents/issue-worker/issue-work.md"

ANCHOR='Concurrent tenants on a shared host (orchestrator-supplied, #1594):'

echo "== worker-preamble carries the rule and indexes the fragment"
assert_contains "$preamble" "no default port is yours" "SKILL.md core has the concurrent-tenant section"
assert_contains "$preamble" "(./shared-host-services.md)" "SKILL.md links the fragment"
assert_contains "$fragment" "Before you debug your diff, rule out a peer's teardown" "fragment carries the misattribution check"
assert_contains "$fragment" "Never weaken or delete a correct assertion" "fragment forbids weakening an unattributed assertion"
assert_contains "$fragment" "port-isolation mechanism" "fragment carries the discover-the-wrapper step"
assert_contains "$issue_work" "shared-host-services.md" "issue-work.md §4.6 points emulator-backed runs at the fragment"

echo
echo "== dispatch-rules.md documents the augmentation"
assert_contains "$dispatch_rules" "**Concurrent-tenant augmentation (" "augmentation heading present (parity checker derives it)"
assert_contains "$dispatch_rules" "> **$ANCHOR**" "augmentation blockquote carries the anchor"
assert_contains "$dispatch_rules" "When the session's \`concurrency > 1\`" "augmentation is gated on concurrency > 1"


echo
echo "== $pass passed, $fail failed"
[[ $fail -eq 0 ]]
