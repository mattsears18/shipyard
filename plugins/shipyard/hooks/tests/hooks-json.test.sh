#!/usr/bin/env bash
# Test suite for plugins/shipyard/hooks/hooks.json (the hook *registration*).
#
# Run with:
#   bash plugins/shipyard/hooks/tests/hooks-json.test.sh
#
# Each hook *script* (enforce-worktree-isolation.sh, enforce-edit-scope.sh,
# refuse-escape-symlink-commit.sh, report-plugin-error.sh) has its own unit
# test under this directory. This suite tests the *wiring* in hooks.json that
# actually arms those scripts — closing the ghost-coverage gap from #406: the
# hook scripts can be green while a typo'd `command` path, a dropped entry, or
# a malformed JSON edit silently neuters a safety hook with zero failing test.
#
# What this asserts:
#   1. hooks.json is valid, parseable JSON.
#   2. Every `command` string references a script that exists on disk and is
#      non-empty (after resolving the ${CLAUDE_PLUGIN_ROOT} prefix to the
#      plugin root).
#   3. The three load-bearing safety hooks each appear registered:
#        - enforce-worktree-isolation
#        - enforce-edit-scope
#        - refuse-escape-symlink-commit

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# tests/ -> hooks/ -> <plugin-root>. ${CLAUDE_PLUGIN_ROOT} in hooks.json
# resolves to the plugin root, so a command path of
# "${CLAUDE_PLUGIN_ROOT}/hooks/foo.sh" maps to "$plugin_root/hooks/foo.sh".
plugin_root="$(cd "${here}/../.." && pwd)"
hooks_json="${plugin_root}/hooks/hooks.json"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok() {
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"
  pass=$((pass+1))
}
no() {
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"
  fail=$((fail+1))
}

# -----------------------------------------------------------------------------
echo "== hooks.json exists and is valid JSON"
# -----------------------------------------------------------------------------

if [[ -f "$hooks_json" ]]; then
  ok "hooks.json exists at $hooks_json"
else
  no "hooks.json not found at $hooks_json"
  # Nothing else can run without the file.
  printf '%s%d/%d tests pass — %d failures.%s\n' "$RED" "$pass" "$((pass+fail))" "$fail" "$RESET"
  exit 1
fi

if jq -e . "$hooks_json" >/dev/null 2>&1; then
  ok "hooks.json parses as valid JSON"
else
  no "hooks.json is NOT valid JSON (jq parse failed)"
  # A malformed JSON file makes every downstream extraction meaningless.
  printf '%s%d/%d tests pass — %d failures.%s\n' "$RED" "$pass" "$((pass+fail))" "$fail" "$RESET"
  exit 1
fi

# -----------------------------------------------------------------------------
echo "== Every registered command path resolves to a non-empty script"
# -----------------------------------------------------------------------------
# Extract each hook's `command` string, then pull the script path out of it.
# The command form is: bash "${CLAUDE_PLUGIN_ROOT}/hooks/<script>.sh"
# Map ${CLAUDE_PLUGIN_ROOT} -> $plugin_root and assert the file exists + is
# non-empty.

commands=$(jq -r '
  [ .hooks // {} | to_entries[]
    | .value[]            # each matcher group
    | .hooks[]            # each hook entry
    | .command            # the command string
  ] | .[]' "$hooks_json")

if [[ -z "$commands" ]]; then
  no "no command strings found in hooks.json (expected at least the four safety/report hooks)"
else
  ok "extracted command strings from hooks.json"
fi

resolved_any=0
while IFS= read -r cmd; do
  [[ -z "$cmd" ]] && continue
  resolved_any=1
  # Pull the path token out of the command. Strip a leading `bash ` and any
  # surrounding quotes, then substitute the plugin-root placeholder.
  raw="${cmd#bash }"
  raw="${raw%\"}"
  raw="${raw#\"}"
  script_path="${raw/\$\{CLAUDE_PLUGIN_ROOT\}/$plugin_root}"

  # shellcheck disable=SC2016  # the literal ${CLAUDE_PLUGIN_ROOT} is intended — we
  # are checking the substitution above actually happened, not expanding it here.
  if [[ "$script_path" == *'${CLAUDE_PLUGIN_ROOT}'* ]]; then
    no "command did not resolve \${CLAUDE_PLUGIN_ROOT}: $cmd"
    continue
  fi

  if [[ -f "$script_path" && -s "$script_path" ]]; then
    ok "command path exists and is non-empty: ${script_path#"$plugin_root"/}"
  else
    no "command path missing or empty: $script_path (from: $cmd)"
  fi
done <<< "$commands"

if [[ "$resolved_any" == "0" ]]; then
  no "no command paths were resolved — nothing checked"
fi

# -----------------------------------------------------------------------------
echo "== The three load-bearing safety hooks are each registered"
# -----------------------------------------------------------------------------
# A dropped entry for any of these silently disables a worker-safety gate.

for safety in enforce-worktree-isolation enforce-edit-scope refuse-escape-symlink-commit; do
  if printf '%s\n' "$commands" | grep -q "/${safety}\.sh\""; then
    ok "safety hook registered: ${safety}.sh"
  else
    no "safety hook NOT registered in hooks.json: ${safety}.sh"
  fi
done

# -----------------------------------------------------------------------------
echo "== guard-primary-checkout.sh is registered under BOTH mutating matchers (#741)"
# -----------------------------------------------------------------------------
# A hook that exists on disk but isn't wired into hooks.json is indistinguishable
# from no hook at all (#741's own root cause). Assert per-matcher registration
# rather than the loose "registered somewhere" check above, since a hook wired
# to only one of its two intended matchers is a silent half-guard.

for matcher in "Bash" "Edit|Write|MultiEdit|NotebookEdit"; do
  matcher_commands=$(jq -r --arg m "$matcher" '
    [ .hooks.PreToolUse[]? | select(.matcher == $m) | .hooks[].command ] | .[]
  ' "$hooks_json")
  if printf '%s\n' "$matcher_commands" | grep -q '/guard-primary-checkout\.sh"'; then
    ok "guard-primary-checkout.sh registered under matcher: $matcher"
  else
    no "guard-primary-checkout.sh NOT registered under matcher: $matcher"
  fi
done

# The Bash matcher already carried refuse-escape-symlink-commit.sh — assert
# it's still there alongside the new hook (hooks compose; the fix must
# append, not replace).
bash_commands=$(jq -r '
  [ .hooks.PreToolUse[]? | select(.matcher == "Bash") | .hooks[].command ] | .[]
' "$hooks_json")
if printf '%s\n' "$bash_commands" | grep -q '/refuse-escape-symlink-commit\.sh"' \
  && printf '%s\n' "$bash_commands" | grep -q '/guard-primary-checkout\.sh"'; then
  ok "Bash matcher composes refuse-escape-symlink-commit.sh AND guard-primary-checkout.sh (appended, not replaced)"
else
  no "Bash matcher lost an existing hook when guard-primary-checkout.sh was wired in"
fi

# -----------------------------------------------------------------------------
echo "== Summary"
# -----------------------------------------------------------------------------

total=$((pass+fail))
if (( fail == 0 )); then
  printf '%s%d/%d tests pass.%s\n' "$GREEN" "$pass" "$total" "$RESET"
  exit 0
else
  printf '%s%d/%d tests pass — %d failures.%s\n' "$RED" "$pass" "$total" "$fail" "$RESET"
  exit 1
fi
