#!/usr/bin/env bash
#
# test-file-collection-1599.test.sh
#
# Pins issue #1599: a new test file's extension is a property of the repo's
# test-runner configuration, not of the source file under test. A scope pass
# that suggested `web-push-card.test.tsx` on a repo whose Jest projects only
# collect `.test.ts` would have produced a test that runs nowhere while
# looking like coverage - and a negative control against it passes
# vacuously in both directions.
#
# Three sites carry the fix, and each is asserted here:
#   1. the scope agent's prompt (06b-scope-carveouts.md) - suggest location
#      and subject, never an extension copied from the source file;
#   2. the worker's always-loaded spec (issue-work.md section 4) - a pointer
#      to the collection check, so the rule fires on every dispatch;
#   3. the worker-preamble ci-pitfalls fragment - the collection check
#      itself, with a per-runner command table;
# plus the orchestrator Don't bullet and the fragment index row, so the
# fragment stays discoverable.
#
# Run:
#   bash plugins/shipyard/scripts/tests/test-file-collection-1599.test.sh

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
section_title='A test file the runner never collects is not a passing test'

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

echo "== #1599: new test files are named from the runner config and proven collected"

fragment="$plugin_root/skills/worker-preamble/ci-pitfalls.md"
assert_contains "$fragment" "## $section_title" \
  "ci-pitfalls.md carries the collection-check section"
assert_contains "$fragment" "npx jest --listTests" \
  "ci-pitfalls.md names Jest's collection-list command"
assert_contains "$fragment" "pytest --collect-only" \
  "ci-pitfalls.md names pytest's collection-list command"
assert_contains "$fragment" "negative control" \
  "ci-pitfalls.md covers the vacuous negative-control case"

assert_contains "$plugin_root/skills/worker-preamble/SKILL.md" "$section_title" \
  "worker-preamble SKILL.md indexes the new ci-pitfalls section"

issue_work="$plugin_root/agents/issue-worker/issue-work.md"
assert_contains "$issue_work" "$section_title" \
  "issue-work.md section 4 points at the collection check"
assert_contains "$issue_work" "issues/1599" \
  "issue-work.md cites #1599"

# The scope-agent prompt lives in one of setup/*.md's fragments; scan across
# all of them rather than hardcoding a fragment path (a router/fragment split
# must not silently break this assertion - #1453).
assert_in_setup() {
  local needle="$1" label="$2"
  if grep -qF -- "$needle" "$plugin_root"/commands/do-work/setup/*.md; then
    record_pass "$label"
  else
    record_fail "$label (missing across setup/*.md: $needle)"
  fi
}
assert_in_setup "Scoping-agent test-file naming" \
  "scope-agent prompt carries the test-file naming rule"
assert_in_setup "Never default to the source file's extension" \
  "scope-agent rule forbids copying the source file's extension"

assert_contains "$plugin_root/commands/do-work/dont.md" \
  "A test that was never collected is indistinguishable from a test that passed" \
  "dont.md carries the orchestrator-side bullet"

echo
echo "Results: ${GREEN}${pass} passed${RESET}, ${RED}${fail} failed${RESET}"
[[ $fail -eq 0 ]]
