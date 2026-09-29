#!/usr/bin/env bash
# Test: the read-only sub-dispatch contract is wired into both the
# always-loaded worker-preamble core and the fan-out fragment (issue #1604).
#
# Background — issue #1604: an issue-work worker on lightwork #5189 forked a
# subagent "research-only" with an explicit "do NOT edit files" instruction.
# The fork edited several of the files the parent was actively fixing,
# concurrently. The edits converged by luck. Two gaps: (1) a worker's
# sub-dispatch could write to the worker's own worktree with no rule
# governing it, and (2) "research-only" was prose, not a tool boundary.
#
# The fix: pick an agent type whose tool set excludes Edit/Write for any
# read-only sub-dispatch; a writing sub-dispatch runs under the #1554
# fan-out contract or gets its own worktree; and the parent re-verifies its
# tree after ANY sub-dispatch returns.
#
# Pure bash. Run with:
#   plugins/shipyard/scripts/tests/read-only-sub-dispatch-1604.test.sh

# Needles are literal markdown containing backticks; nothing should expand.
# shellcheck disable=SC2016

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_root="$(cd "$here/../.." && pwd)"
skill_path="$plugin_root/skills/worker-preamble/SKILL.md"
fragment_path="$plugin_root/skills/worker-preamble/fan-out-verification.md"

pass=0
fail=0

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  PASS  %s\n' "$label"; pass=$((pass+1))
  else
    printf '  FAIL  %s\n    expected in %s: %s\n' "$label" "$file" "$needle"; fail=$((fail+1))
  fi
}

echo "read-only sub-dispatch contract regression tests (issue #1604)"
echo

echo "-- core (SKILL.md)"
assert_contains "$skill_path" "https://github.com/mattsears18/shipyard/issues/1604" \
  "core links to #1604"
assert_contains "$skill_path" '"Research-only" is a tool boundary, never a prompt instruction' \
  "core states research-only is a tool boundary"
assert_contains "$skill_path" 'tool set excludes `Edit`/`Write` (`Explore`, `Plan`)' \
  "core names the read-only agent types"
assert_contains "$skill_path" 'own `isolation: "worktree"`' \
  "core gives a writing sub-dispatch its own worktree as an option"
assert_contains "$skill_path" 'After **any** sub-dispatch returns, run `git status`' \
  "core requires re-verifying the tree after any sub-dispatch"

echo
echo "-- fragment (fan-out-verification.md)"
assert_contains "$fragment_path" "## Read-only sub-dispatches — make the scope structural, not advisory" \
  "fragment carries the read-only sub-dispatch section"
assert_contains "$fragment_path" "#5189" \
  "fragment cites the lightwork #5189 repro"
assert_contains "$fragment_path" "is an instruction, not a boundary" \
  "fragment states prose scope is not a boundary"
assert_contains "$fragment_path" "never silently shares your tree" \
  "fragment forbids a writing sub-dispatch silently sharing the tree"
assert_contains "$fragment_path" "After ANY sub-dispatch returns" \
  "fragment requires the post-return tree re-verification"
assert_contains "$fragment_path" "your own \`tool_use\`/\`tool_result\` record is authoritative" \
  "fragment addresses the self-identification inversion"

echo
printf '  %d passed, %d failed\n' "$pass" "$fail"
(( fail > 0 )) && exit 1
exit 0
