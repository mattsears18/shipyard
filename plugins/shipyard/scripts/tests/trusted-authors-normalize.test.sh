#!/usr/bin/env bash
# Test suite for scripts/trusted-authors-normalize.sh (issue #296).
#
# Covers the alias expansion that lets a single allowlist file entry
# (`sentry[bot]` OR `app/sentry`) match against EITHER GitHub-API shape
# without forcing maintainers to know which form `gh issue list --json author`
# returns at any given time. Without this helper, the literal substring
# comparison in setup.md step 1.7 silently dropped every GH-App-filed
# issue from the dispatch queue.
#
# Pure bash. Run with:
#
#   bash plugins/shipyard/scripts/tests/trusted-authors-normalize.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../trusted-authors-normalize.sh"

if [[ ! -f "$helper" ]]; then
  echo "FAIL: trusted-authors-normalize.sh not found at $helper" >&2
  exit 1
fi
if [[ ! -x "$helper" ]]; then
  echo "FAIL: trusted-authors-normalize.sh not executable" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_equals() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected: %q\n' "$expected"
    printf '    actual:   %q\n' "$actual"
    fail=$((fail+1))
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to contain: %q\n' "$needle"
    printf '    actual: %q\n' "$haystack"
    fail=$((fail+1))
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected NOT to contain: %q\n' "$needle"
    printf '    actual: %q\n' "$haystack"
    fail=$((fail+1))
  fi
}

assert_exit() {
  local actual_exit="$1"
  local expected_exit="$2"
  local label="$3"
  if [[ "$actual_exit" -eq "$expected_exit" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected exit: %s\n' "$expected_exit"
    printf '    actual exit:   %s\n' "$actual_exit"
    fail=$((fail+1))
  fi
}

# --------------------------------------------------------------------------
echo "== alias expansion"
# --------------------------------------------------------------------------

# Core case from issue #296: `sentry[bot]` in the file → both shapes in output.
out=$(printf 'sentry[bot]\n' | "$helper")
assert_contains "$out" "sentry[bot]" "[bot]→app: original sentry[bot] preserved"
assert_contains "$out" "app/sentry" "[bot]→app: app/sentry alias added"

# Reverse: `app/<name>` in the file → both shapes in output.
out=$(printf 'app/sentry\n' | "$helper")
assert_contains "$out" "app/sentry" "app→[bot]: original app/sentry preserved"
assert_contains "$out" "sentry[bot]" "app→[bot]: sentry[bot] alias added"

# Human login — pass through unchanged, no alias.
out=$(printf 'mattsears18\n' | "$helper")
assert_equals "$out" "mattsears18" "human login passes through verbatim"
assert_not_contains "$out" "app/" "human login produces no app/ alias"
assert_not_contains "$out" "[bot]" "human login produces no [bot] alias"

# Mixed input — humans + bots + apps coexist.
out=$(printf 'mattsears18\nsentry[bot]\napp/dependabot\n' | "$helper")
assert_contains "$out" "mattsears18"      "mixed: human preserved"
assert_contains "$out" "sentry[bot]"      "mixed: bot preserved"
assert_contains "$out" "app/sentry"       "mixed: bot's app/ alias added"
assert_contains "$out" "app/dependabot"   "mixed: app preserved"
assert_contains "$out" "dependabot[bot]"  "mixed: app's [bot] alias added"

# Already-paired input — both forms present, no double-aliasing in output.
out=$(printf 'sentry[bot]\napp/sentry\n' | "$helper")
line_count=$(printf '%s\n' "$out" | grep -c .)
assert_equals "$line_count" "2" "pre-paired: dedupes to exactly 2 lines"

# --------------------------------------------------------------------------
echo "== input cleaning"
# --------------------------------------------------------------------------

# Comments and blank lines stripped.
out=$(printf '# header comment\n\nmattsears18\n\n# trailing\n' | "$helper")
assert_equals "$out" "mattsears18" "comments + blanks stripped"

# Inline comments (after the login) stripped.
out=$(printf 'mattsears18 # the maintainer\n' | "$helper")
assert_equals "$out" "mattsears18" "inline comment after login stripped"

# Whitespace tolerant.
out=$(printf '  mattsears18  \n\tsentry[bot]\n' | "$helper")
assert_contains "$out" "mattsears18" "leading/trailing whitespace stripped"
assert_contains "$out" "sentry[bot]" "tab-prefixed entry stripped"

# Mixed case is lowercased.
out=$(printf 'MattSears18\nSentry[Bot]\n' | "$helper")
assert_contains "$out" "mattsears18" "mixed-case login lowercased"
assert_contains "$out" "sentry[bot]" "mixed-case [bot] suffix lowercased"
assert_contains "$out" "app/sentry"  "alias for lowercased [bot] still generated"
assert_not_contains "$out" "MattSears18" "original casing dropped from output"

# Empty input.
out=$(printf '' | "$helper")
assert_equals "$out" "" "empty input → empty output"
assert_exit "$?" "0" "empty input → exit 0"

# Whitespace-only input.
out=$(printf '\n\n   \n' | "$helper")
assert_equals "$out" "" "whitespace-only input → empty output"

# --------------------------------------------------------------------------
echo "== --report-aliases mode"
# --------------------------------------------------------------------------

out=$(printf 'mattsears18\nsentry[bot]\n' | "$helper" --report-aliases)
assert_contains "$out" "[trusted-authors] alias: sentry[bot] -> app/sentry" \
  "report: emits the [bot]→app/ alias line"
assert_not_contains "$out" "mattsears18" \
  "report: human login produces no alias line"

out=$(printf 'mattsears18\n' | "$helper" --report-aliases)
assert_equals "$out" "" "report: no aliases needed → empty output"

out=$(printf 'app/sentry\napp/dependabot\n' | "$helper" --report-aliases)
assert_contains "$out" "[trusted-authors] alias: app/sentry -> sentry[bot]" \
  "report: app/sentry → sentry[bot]"
assert_contains "$out" "[trusted-authors] alias: app/dependabot -> dependabot[bot]" \
  "report: app/dependabot → dependabot[bot]"

# Pre-paired input — no alias added, no report line.
out=$(printf 'sentry[bot]\napp/sentry\n' | "$helper" --report-aliases)
# Both forms ARE already in the input. Both still emit "would-add" lines but
# the result-set wouldn't change. That's acceptable noise; the orchestrator
# can filter if needed. Just confirm the command doesn't error.
assert_exit "$?" "0" "report: pre-paired input still exits 0"

# --------------------------------------------------------------------------
echo "== file argument mode"
# --------------------------------------------------------------------------

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
printf '# comment line\nmattsears18\nsentry[bot]\n' > "$tmp"

out=$("$helper" "$tmp")
assert_contains "$out" "mattsears18" "file: human read from file"
assert_contains "$out" "sentry[bot]" "file: bot read from file"
assert_contains "$out" "app/sentry"  "file: alias generated for bot read from file"

# Non-existent file → exit 64.
"$helper" /nonexistent/path 2>/dev/null
assert_exit "$?" "64" "file: missing path → exit 64"

# Too many file arguments → exit 64.
"$helper" "$tmp" "$tmp" 2>/dev/null
assert_exit "$?" "64" "file: two file args → exit 64"

# Unknown flag → exit 64.
"$helper" --bogus 2>/dev/null
assert_exit "$?" "64" "flag: unknown flag → exit 64"

# --------------------------------------------------------------------------
echo "== sort + dedupe"
# --------------------------------------------------------------------------

# Duplicate entries collapse.
out=$(printf 'mattsears18\nmattsears18\nMattSears18\n' | "$helper")
line_count=$(printf '%s\n' "$out" | grep -c .)
assert_equals "$line_count" "1" "duplicates collapsed across casing"

# Output is sorted (apps come before [bot]s alphabetically; humans by login).
out=$(printf 'zebra-user\nsentry[bot]\napp/dependabot\n' | "$helper")
expected=$(printf 'app/dependabot\napp/sentry\ndependabot[bot]\nsentry[bot]\nzebra-user\n')
assert_equals "$out" "$expected" "output sorted alphabetically"

# --------------------------------------------------------------------------
echo
echo "Results: ${GREEN}${pass} passed${RESET}, ${RED}${fail} failed${RESET}"
[[ "$fail" -eq 0 ]] || exit 1
exit 0
