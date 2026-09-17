#!/usr/bin/env bash
# Needles below quote literal markdown backticks, not shell expansions.
# shellcheck disable=SC2016
#
# Test: the launcher-git-refusal workaround is documented where isolated
# sessions will find it (issue #1558).
#
# Background — issue #1558: on a host with a global PreToolUse hook that
# rewrites `git …` into `rtk git …` (the RTK token proxy), Claude Code's
# worktree-isolation check refuses plain git commands once a session is
# isolated ("runs rtk with a git command among its operands"). The rewrite is
# selective by subcommand, and `git -C <worktree>` is refused too. Every
# isolated worker, and the orchestrator right after it enters its worktree,
# rediscovered the working form (`/usr/bin/git …`) by trial and error.
#
# Three places must carry the fix, and all three are asserted here:
#   1. The fragment (skills/worker-preamble/launcher-git-refusal.md): the
#      refusal shape, the absolute-path fix, and what not to do.
#   2. The always-loaded worker-preamble core: a short pointer, so a worker
#      sees the fix before its first refusal, plus the fragment index row.
#   3. The orchestrator side (commands/do-work/dont.md, post-relocation
#      section): the same fix for the orchestrator's own post-step-0.5 git
#      calls, kept separate from the compound-shape decomposition rule it
#      would otherwise be confused with.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/launcher-git-refusal-1558.test.sh

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
fragment_path="$plugin_root/skills/worker-preamble/launcher-git-refusal.md"
skill_path="$plugin_root/skills/worker-preamble/SKILL.md"
dont_path="$plugin_root/commands/do-work/dont.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_file_exists() {
  local path="$1" label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (missing: %s)\n' "$RED" "$RESET" "$label" "$path"; fail=$((fail+1))
  fi
}

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"; fail=$((fail+1))
  fi
}

echo "launcher-git-refusal regression tests (issue #1558)"
echo

echo "-- Layer 1: the fragment"
assert_file_exists "$fragment_path" "skills/worker-preamble/launcher-git-refusal.md exists"
if [[ -f "$fragment_path" ]]; then
  assert_contains "$fragment_path" "https://github.com/mattsears18/shipyard/issues/1558" \
    "fragment links to the originating issue #1558"
  # The refusal text is what a worker greps its memory for — keep it quotable.
  assert_contains "$fragment_path" "with a git command among its operands" \
    "fragment quotes the refusal wording so a worker can match it"
  assert_contains "$fragment_path" "/usr/bin/git fetch origin" \
    "fragment gives the absolute-path form as a runnable command"
  assert_contains "$fragment_path" "/usr/bin/git -C " \
    "fragment shows the absolute path combined with -C anchoring"
  assert_contains "$fragment_path" '`-C` does not help' \
    "fragment says bare git -C is still refused"
  assert_contains "$fragment_path" "command -v git" \
    "fragment covers a host where /usr/bin/git does not exist"
  assert_contains "$fragment_path" "Selective by subcommand" \
    "fragment warns that one successful git call proves nothing about the next"
  assert_contains "$fragment_path" "Don't disable, edit, or reconfigure the hook" \
    "fragment forbids touching the user-global hook"
  assert_contains "$fragment_path" "rtk proxy git" \
    "fragment rules out the launcher's own passthrough"
  assert_contains "$fragment_path" "Scripts are not affected" \
    "fragment says helper-script invocations need no change"
  # Item 3 was fixed by #1561 — point there instead of re-documenting it.
  assert_contains "$fragment_path" "--set-file" \
    "fragment points the object-literal refusal at #1561's --set-file form"
fi
echo

echo "-- Layer 2: the always-loaded worker-preamble core"
assert_contains "$skill_path" "(./launcher-git-refusal.md)" \
  "SKILL.md links the fragment"
assert_contains "$skill_path" 'Retry as `/usr/bin/git …`' \
  "SKILL.md states the one-line fix inline, not only behind the link"
assert_contains "$skill_path" "| [\`launcher-git-refusal.md\`](./launcher-git-refusal.md) |" \
  "SKILL.md fragment index has a row for the new fragment"
echo

echo "-- Layer 3: the orchestrator post-relocation section"
assert_contains "$dont_path" "../../skills/worker-preamble/launcher-git-refusal.md" \
  "dont.md links the worker-side fragment"
assert_contains "$dont_path" "has a different cause and a different fix" \
  "dont.md separates this refusal from the compound-shape rule"
assert_contains "$dont_path" '`/usr/bin/git …`' \
  "dont.md gives the orchestrator the absolute-path fix"
echo

if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
