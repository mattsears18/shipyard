#!/usr/bin/env bash
# Needles below quote literal markdown backticks, not shell expansions.
# shellcheck disable=SC2016
#
# Test: two worker-facing doc gaps from issue #1612 stay closed.
#
# 1. nvm-source-refusal.md tells a worker to compare `node -v` with `.nvmrc`
#    before any workaround, and to derive the interpreter directory from
#    `.nvmrc` at call time instead of hardcoding a versioned path
#    (`~/.nvm/versions/node/v24.15.0/bin/node`), which pins Node a second
#    time and, for npm, silently runs children on the ambient Node.
# 2. shared-host-services.md tells a worker that a session-level browser MCP
#    writes into the ORCHESTRATOR's worktree, and to report every file on a
#    `Stray artifacts:` line; steady-state.md's A.0.7 reaps exactly those
#    paths; the always-loaded SKILL.md core points at both.
#
# Pure bash, no external dependencies. Run with:
#
#   plugins/shipyard/scripts/tests/nvm-pin-and-mcp-artifacts-1612.test.sh

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
nvm_path="$plugin_root/skills/worker-preamble/nvm-source-refusal.md"
hosts_path="$plugin_root/skills/worker-preamble/shared-host-services.md"
skill_path="$plugin_root/skills/worker-preamble/SKILL.md"
steady_path="$plugin_root/commands/do-work/steady-state.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"; fail=$((fail+1))
  fi
}

assert_not_matches() {
  local file="$1" regex="$2" label="$3"
  if grep -qE -- "$regex" "$file" 2>/dev/null; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    did not expect a match in %s for: %s\n' "$file" "$regex"
    grep -nE -- "$regex" "$file" | sed 's/^/      /'
    fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  fi
}

echo "nvm pin + browser-MCP artifact regression tests (issue #1612)"
echo

echo "-- Part 1: nvm-source-refusal.md"
assert_contains "$nvm_path" "## Check first — you may need none of this" \
  "fragment opens remediation with a node -v vs .nvmrc check"
assert_contains "$nvm_path" "If they match, stop here." \
  "fragment says a match needs no workaround"
assert_contains "$nvm_path" "## Never hardcode the versioned interpreter path" \
  "fragment has the no-hardcoded-path section"
assert_contains "$nvm_path" 'NVMRC=$(cat .nvmrc); PATH="$HOME/.nvm/versions/node/$NVMRC/bin:$PATH" npm ci' \
  "fragment gives the .nvmrc-derived PATH-prefix form"
assert_contains "$nvm_path" "It is wrong for \`npm\`/\`npx\` even when the version matches." \
  "fragment explains why a by-path npm still runs children on ambient Node"
assert_contains "$nvm_path" "https://github.com/mattsears18/shipyard/issues/1612" \
  "fragment cites #1612"
# A versioned path may appear in prose (quoted as the anti-pattern), never in
# a fenced bash block a worker would copy.
fenced_bash="$(awk '/^```bash$/{f=1;next} /^```$/{f=0} f' "$nvm_path")"
fenced_tmp="$(mktemp)"
printf '%s\n' "$fenced_bash" > "$fenced_tmp"
assert_not_matches "$fenced_tmp" 'versions/node/v[0-9]+\.[0-9]+\.[0-9]+' \
  "no fenced bash block in the fragment hardcodes a versioned Node path"
rm -f "$fenced_tmp"

echo
echo "-- Part 2: browser-MCP artifacts"
assert_contains "$hosts_path" "## Browser-MCP artifacts land in the orchestrator's worktree, not yours" \
  "shared-host-services.md has the browser-MCP section"
assert_contains "$hosts_path" "is outside allowed roots" \
  "section quotes the MCP's own refusal of an out-of-root filename"
assert_contains "$hosts_path" "Stray artifacts:" \
  "section names the return line the orchestrator keys on"
assert_contains "$hosts_path" "before using a browser MCP such as Playwright" \
  "fragment's load trigger covers browser-MCP use"
assert_contains "$steady_path" "#### A.0.7. Reap browser-MCP artifacts a worker reported" \
  "steady-state.md has the orchestrator-side reap step"
assert_contains "$steady_path" "Once A.0.6 has run, proceed to A.0.7." \
  "A.0.6 hands off to A.0.7"
assert_contains "$steady_path" "Stray artifacts:" \
  "A.0.7 keys on the same line the worker emits"
assert_contains "$skill_path" "A browser MCP writes into the orchestrator's worktree: report each file." \
  "always-loaded SKILL.md core points at the browser-MCP rule"
assert_contains "$skill_path" "or you'd hardcode a Node path" \
  "SKILL.md index row routes a hardcoded-path temptation to nvm-source-refusal.md"

echo
echo "Results: ${GREEN}${pass} passed${RESET}, ${RED}${fail} failed${RESET}"
[[ $fail -eq 0 ]]
