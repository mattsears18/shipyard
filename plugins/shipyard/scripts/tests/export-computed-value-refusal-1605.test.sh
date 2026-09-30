#!/usr/bin/env bash
# Needles below quote literal markdown backticks, not shell expansions.
# shellcheck disable=SC2016
#
# Test: the refused `export VAR=$(cmd)` shape has a worker-facing fragment
# that names a working alternative (issue #1605).
#
# Background — issue #1605: in a worktree-isolated session Claude Code
# refuses `export TOKEN=$(<fetch-credential>)` ("with a value every later
# program inherits"), and the two-call split the refusal suggests cannot work
# because shell variables do not survive across separate Bash calls. The
# orchestrator side already documented the export rule in
# commands/do-work/dont.md (#1607 / #1619), but nothing worker-facing did, so
# every worker authenticating against a third-party API burned turns
# rediscovering the helper-script workaround.
#
# Three places must carry it, and all three are asserted here:
#   1. The fragment (skills/worker-preamble/export-computed-value-refusal.md):
#      the refusal wording, why the split fails, the helper-script form, the
#      inline form, and the no-echo / no-file rules for the credential.
#   2. The always-loaded worker-preamble core: a fragment-index row.
#   3. Cross-links from the sibling nvm-source-refusal fragment and from
#      dont.md's orchestrator-side export rule.
#
# Pure bash, no external dependencies. Run with:
#
#   plugins/shipyard/scripts/tests/export-computed-value-refusal-1605.test.sh

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
fragment_path="$plugin_root/skills/worker-preamble/export-computed-value-refusal.md"
skill_path="$plugin_root/skills/worker-preamble/SKILL.md"
nvm_path="$plugin_root/skills/worker-preamble/nvm-source-refusal.md"
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

assert_not_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    did not expect to find in %s: %s\n' "$file" "$needle"; fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  fi
}

echo "export-computed-value-refusal regression tests (issue #1605)"
echo

echo "-- Layer 1: the fragment"
assert_file_exists "$fragment_path" "skills/worker-preamble/export-computed-value-refusal.md exists"
if [[ -f "$fragment_path" ]]; then
  assert_contains "$fragment_path" "https://github.com/mattsears18/shipyard/issues/1605" \
    "fragment links to the originating issue #1605"
  # The refusal text is what a worker greps its memory for — keep it quotable.
  assert_contains "$fragment_path" "with a value every later program inherits" \
    "fragment quotes the refusal wording so a worker can match it"
  assert_contains "$fragment_path" "The two-call split the message suggests cannot work" \
    "fragment says the suggested decomposition cannot work"
  assert_contains "$fragment_path" "do not survive across separate \`Bash\` calls" \
    "fragment says why the split fails"
  assert_contains "$fragment_path" "The helper script fetches the credential itself" \
    "fragment's first working form is the self-fetching helper script"
  assert_contains "$fragment_path" 'exec "$@"' \
    "fragment's helper exports internally and execs the consuming command"
  assert_contains "$fragment_path" "chmod +x" \
    "fragment sets the exec bit on the helper before running it"
  assert_contains "$fragment_path" "direct-exec" \
    "fragment direct-execs the helper instead of bash <script> (#1566)"
  assert_contains "$fragment_path" 'TOKEN=$(gcloud auth print-access-token); curl -s -H "Authorization: Bearer $TOKEN"' \
    "fragment gives the single-call unexported-assignment form"
  assert_contains "$fragment_path" "Don't echo, print, or log the credential" \
    "fragment forbids echoing the credential"
  assert_contains "$fragment_path" "Don't write the credential to a file" \
    "fragment forbids persisting the credential"
  assert_contains "$fragment_path" "Never do this with a secret" \
    "fragment keeps literal substitution to non-secret values"
  assert_contains "$fragment_path" "commands/do-work/dont.md" \
    "fragment reuses dont.md's measurements rather than re-deriving them"
  assert_contains "$fragment_path" "## The refusal family" \
    "fragment indexes the sibling refused shapes"
  assert_contains "$fragment_path" "(./nvm-source-refusal.md)" \
    "refusal-family table links the source-refusal fragment"
  assert_contains "$fragment_path" "(./launcher-git-refusal.md)" \
    "refusal-family table links the launcher-git fragment"
  # Placeholders only — a real secret name or value must never appear.
  assert_contains "$fragment_path" "<SECRET_NAME>" \
    "fragment uses a placeholder secret name"
  assert_not_contains "$fragment_path" "--secret=SENTRY_AUTH_TOKEN" \
    "fragment does not name a concrete secret-manager entry"
fi
echo

echo "-- Layer 2: the always-loaded worker-preamble core"
assert_contains "$skill_path" "| [\`export-computed-value-refusal.md\`](./export-computed-value-refusal.md) |" \
  "SKILL.md fragment index has a row for the new fragment"
echo

echo "-- Layer 3: cross-links"
assert_contains "$nvm_path" "(./export-computed-value-refusal.md)" \
  "nvm-source-refusal.md points an export refusal at the new fragment"
assert_contains "$dont_path" "../../skills/worker-preamble/export-computed-value-refusal.md" \
  "dont.md's export rule links the worker-side fragment"
echo

if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
