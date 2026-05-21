#!/usr/bin/env bash
# Test suite for scripts/report-plugin-error.sh.
#
# Pure bash, no external dependencies beyond python3 (already required by the
# helper itself). Run with:
#
#   bash plugins/shipyard/scripts/tests/report-plugin-error.test.sh
#
# Each test runs the helper with a crafted JSON payload on stdin and asserts on
# the dry-run output (CLAUDE_PLUGINS_AUTOREPORT_DRY=1). Dry-run emits a single
# JSON object describing the would-be filing — no `gh` calls are ever made.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../report-plugin-error.sh"

if [[ ! -f "$helper" ]]; then
  echo "FAIL: helper not found at $helper" >&2
  exit 1
fi

# Counters + colors.
pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to contain: %s\n' "$needle"
    printf '    actual: %s\n' "$haystack" | head -c 400
    printf '\n'
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
    printf '    expected NOT to contain: %s\n' "$needle"
    fail=$((fail+1))
  fi
}

assert_equals() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected: %s\n' "$expected"
    printf '    actual:   %s\n' "$actual"
    fail=$((fail+1))
  fi
}

run_helper() {
  # Args: payload (JSON string). Reads dry-run output back.
  local payload="$1"
  CLAUDE_PLUGINS_AUTOREPORT=1 CLAUDE_PLUGINS_AUTOREPORT_DRY=1 \
    bash "$helper" <<<"$payload" 2>/dev/null || true
}

# --------------------------------------------------------------------------
echo "== Opt-out gate"
# --------------------------------------------------------------------------

out=$(echo '{"tool_name":"Agent","tool_input":{"subagent_type":"shipyard:issue-worker"},"tool_response":{"is_error":true,"error":"boom"}}' \
  | bash "$helper" 2>/dev/null)
assert_equals "$out" "" "no CLAUDE_PLUGINS_AUTOREPORT → silent exit"

# --------------------------------------------------------------------------
echo "== Failure detection"
# --------------------------------------------------------------------------

# Success payload → no filing.
out=$(run_helper '{"tool_name":"Agent","tool_input":{"subagent_type":"shipyard:issue-worker"},"tool_response":{"content":"all good"}}')
assert_equals "$out" "" "success payload → no filing"

# Explicit is_error → file.
out=$(run_helper '{"tool_name":"Agent","tool_input":{"subagent_type":"shipyard:issue-worker","prompt":"work issue 1"},"tool_response":{"is_error":true,"content":"Error: tool crashed"}}')
assert_contains "$out" '"title"' "is_error=true → dry-run emits filing"
assert_contains "$out" 'shipyard:issue-worker' "filing carries the subagent name"

# Error: marker in output → file.
out=$(run_helper '{"tool_name":"Agent","tool_input":{"subagent_type":"shipyard:lighthouse-auditor"},"tool_response":{"content":"running…\nError: timed out fetching report"}}')
assert_contains "$out" "shipyard:lighthouse-auditor" "Error: marker triggers filing"

# blocked: marker.
out=$(run_helper '{"tool_name":"Agent","tool_input":{"subagent_type":"shipyard:web-ux-auditor"},"tool_response":{"content":"blocked: ambiguous acceptance criteria"}}')
assert_contains "$out" "shipyard:web-ux-auditor" "blocked: marker triggers filing"

# --------------------------------------------------------------------------
echo "== Namespace filter"
# --------------------------------------------------------------------------

# Non-shipyard subagent → ignored.
out=$(run_helper '{"tool_name":"Agent","tool_input":{"subagent_type":"some-other-plugin:thing"},"tool_response":{"is_error":true,"error":"nope"}}')
assert_equals "$out" "" "non-shipyard subagent → ignored"

# Unknown name → ignored (no false positives against random tool calls).
out=$(run_helper '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"is_error":true,"error":"boom"}}')
assert_equals "$out" "" "unrelated tool failure → ignored"

# --------------------------------------------------------------------------
echo "== Secret scrubbing"
# --------------------------------------------------------------------------

payload='{"tool_name":"Agent","tool_input":{"subagent_type":"shipyard:issue-worker","prompt":"use token ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ1234567890"},"tool_response":{"is_error":true,"error":"Error: auth failed with key sk-aBcDeFgHiJkLmNoPqRsTuVwXyZ12345 at /Users/secretuser/.config/foo"}}'
out=$(HOME=/Users/secretuser run_helper "$payload")
assert_not_contains "$out" "ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ1234567890" "GH token scrubbed from prompt"
assert_not_contains "$out" "sk-aBcDeFgHiJkLmNoPqRsTuVwXyZ12345" "OpenAI key scrubbed from error"
assert_not_contains "$out" "/Users/secretuser" "\$HOME path scrubbed from error"
assert_contains "$out" "REDACTED" "redaction marker present"

# AWS access key
payload='{"tool_name":"Agent","tool_input":{"subagent_type":"shipyard:security-auditor"},"tool_response":{"is_error":true,"error":"Error: aws auth: AKIAIOSFODNN7EXAMPLE failed"}}'
out=$(run_helper "$payload")
assert_not_contains "$out" "AKIAIOSFODNN7EXAMPLE" "AWS access key scrubbed"

# Bearer token
payload='{"tool_name":"Agent","tool_input":{"subagent_type":"shipyard:security-auditor"},"tool_response":{"is_error":true,"error":"Error: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.sig"}}'
out=$(run_helper "$payload")
assert_not_contains "$out" "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" "Bearer JWT scrubbed"

# --------------------------------------------------------------------------
echo "== Issue body structure"
# --------------------------------------------------------------------------

payload='{"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"subagent_type":"shipyard:issue-worker","prompt":"work issue 22","description":"do work"},"tool_response":{"is_error":true,"error":"Error: gh api 404"}}'
out=$(run_helper "$payload")
# Extract the body field via python.
body=$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("body",""))')

assert_contains "$body" "## What happened" "body has 'What happened' section"
assert_contains "$body" "## Skill/Agent" "body has 'Skill/Agent' section"
assert_contains "$body" "## Reproduction" "body has 'Reproduction' section"
assert_contains "$body" "## Error details" "body has 'Error details' section"
assert_contains "$body" "## Environment" "body has 'Environment' section"
assert_contains "$body" "## Transcript excerpt" "body has 'Transcript excerpt' section"
assert_contains "$body" "## Recommendations for improvement" "body has 'Recommendations' section"
assert_contains "$body" "autoreport-key=shipyard:issue-worker" "body carries de-dup signature"
assert_contains "$body" "gh api N" "error excerpt is normalized in signature (digits → N)"

# Labels.
labels=$(printf '%s' "$out" | python3 -c 'import json,sys; print(",".join(json.loads(sys.stdin.read()).get("labels",[])))')
assert_contains "$labels" "auto-reported" "auto-reported label applied"
assert_contains "$labels" "bug" "bug label applied"

# Title shape.
title=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("title",""))')
assert_contains "$title" "[auto]" "title has [auto] prefix"
assert_contains "$title" "shipyard:issue-worker" "title carries the subagent name"

# --------------------------------------------------------------------------
echo "== Signature stability"
# --------------------------------------------------------------------------

# Same skill + similar error text → same signature, even with different digits.
p1='{"tool_name":"Agent","tool_input":{"subagent_type":"shipyard:lighthouse-auditor"},"tool_response":{"is_error":true,"error":"Error: lighthouse timed out at 30000ms"}}'
p2='{"tool_name":"Agent","tool_input":{"subagent_type":"shipyard:lighthouse-auditor"},"tool_response":{"is_error":true,"error":"Error: lighthouse timed out at 60000ms"}}'

sig1=$(run_helper "$p1" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("signature",""))')
sig2=$(run_helper "$p2" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("signature",""))')
assert_equals "$sig1" "$sig2" "signatures match across runs with same root error (digit normalization)"

# Different skill → different signature.
p3='{"tool_name":"Agent","tool_input":{"subagent_type":"shipyard:web-ux-auditor"},"tool_response":{"is_error":true,"error":"Error: lighthouse timed out at 30000ms"}}'
sig3=$(run_helper "$p3" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("signature",""))')
if [[ "$sig1" != "$sig3" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "different skill → different signature"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "different skill → different signature"
  fail=$((fail+1))
fi

# --------------------------------------------------------------------------
echo "== Truncation"
# --------------------------------------------------------------------------

# Build a giant error string with content that won't be fully scrubbed.
# Use "Error: line 1 / line 2 / ..." with words so the redaction regex
# (which targets long hex blobs, tokens, paths) leaves the bulk intact.
payload=$(python3 -c "
import json
lines = ['Error: failure on step ' + str(i) + ' — could not resolve dependency widget-component-' + str(i) for i in range(300)]
print(json.dumps({
    'tool_name':'Agent',
    'tool_input':{'subagent_type':'shipyard:issue-worker'},
    'tool_response':{'is_error':True,'error':'\n'.join(lines)}
}))
")
out=$(run_helper "$payload")
body=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("body",""))')
assert_contains "$body" "truncated" "long error excerpt is truncated"

# --------------------------------------------------------------------------
echo "== Summary"
# --------------------------------------------------------------------------

total=$((pass+fail))
if (( fail == 0 )); then
  printf '%s%d/%d tests pass.%s\n' "$GREEN" "$pass" "$total" "$RESET"
  exit 0
else
  printf '%s%d/%d tests pass — %d failures.%s\n' "$RED" "$pass" "$total" "$fail" "$RESET"
  exit 1
fi
