#!/usr/bin/env bash
# Test suite: pricing-table coverage (issue #728).
#
# The cost ledger's pricing table (`PRICING_JQ` in scripts/session-state.sh)
# is hand-maintained, so it goes stale every time Anthropic ships a model.
# Before #728 a stale table failed *silently*: an unknown model resolved to a
# zero pricing row and every dispatch on it was booked at a confident $0.00,
# indistinguishable from a genuinely free one. The session ledger under-
# reported by ~6x for a whole session before anyone noticed.
#
# This suite is the guard that keeps that from recurring. It asserts:
#
#   1. COVERAGE — every model id shipped *in this repo* (the `models.*`
#      config defaults + every agent shim's `model:` frontmatter) resolves to
#      a real pricing row. A new model can't ship into a $0 hole without
#      turning this suite red first.
#
#   2. LOUDNESS — an unknown model is reported, not silently zeroed: it warns
#      on stderr, lands in `.tokens.unpriced_models`, and stamps
#      `unpriced: true` on its per_invocation entry. $0.00 is a legitimate
#      value and must never double as the "I don't know what to charge"
#      sentinel.
#
#   3. NON-REGRESSION — a *known* model is NOT flagged as unpriced (the guard
#      must not cry wolf on the happy path).
#
# Coverage is asserted behaviorally — through the same `bump-tokens` path the
# orchestrator actually calls — rather than by grepping PRICING_JQ, so alias
# resolution (`opus`) and dated suffixes (`claude-haiku-4-5-20251001`) are
# covered by construction.
#
# Run with:
#
#   bash plugins/shipyard/scripts/tests/pricing-coverage.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../session-state.sh"
config_helper="${here}/../shipyard-config.sh"
agents_dir="${here}/../../agents"

for required in "$helper" "$config_helper"; do
  if [[ ! -f "$required" ]]; then
    echo "FAIL: required file not found at $required" >&2
    exit 1
  fi
done

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required" >&2
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
    printf '    expected: %s\n' "$expected"
    printf '    actual:   %s\n' "$actual"
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
    printf '    expected to contain: %s\n' "$needle"
    printf '    actual: %s\n' "$haystack"
    fail=$((fail+1))
  fi
}

mktmphome() { mktemp -d "${TMPDIR:-/tmp}/shipyard-pricing-test.XXXXXX"; }

# is_priced <model-id> — 0 when the model resolves to a pricing row, 1 when
# it doesn't. Drives the model through the real `bump-tokens` path and asks
# whether it landed in the session's unpriced set. Using the live path (not a
# PRICING_JQ grep) means the alias map and prefix matching are exercised too.
is_priced() {
  local model="$1"
  local home
  home=$(mktmphome)
  SHIPYARD_HOME="$home" bash "$helper" init --session-id "probe" --repo "o/r" >/dev/null 2>&1
  SHIPYARD_HOME="$home" bash "$helper" bump-tokens \
    --session-id "probe" --input 1000000 --model "$model" >/dev/null 2>&1
  local unpriced
  unpriced=$(SHIPYARD_HOME="$home" bash "$helper" read \
    --session-id "probe" --path ".tokens.unpriced_models" 2>/dev/null | jq -r 'length')
  rm -rf "$home"
  [[ "$unpriced" == "0" ]]
}

# --------------------------------------------------------------------------
echo "== coverage — every models.* config model resolves to a pricing row"
# --------------------------------------------------------------------------
# These are the ids the orchestrator hands to `--model` on every dispatch. A
# model that isn't in the pricing table books that whole mode at $0.
#
# Two sources, unioned — they are NOT the same set and both matter:
#
#   * the BUILT-IN defaults hardcoded in shipyard-config.sh — what every repo
#     that hasn't overridden `models.*` actually dispatches with. A $0-hole
#     here ships to every install.
#   * this repo's EFFECTIVE config — the built-ins after `shipyard.config.json`
#     is merged over them. shipyard's own config overrides `models.issue_work`,
#     so reading only the effective config would leave the built-in default
#     unguarded (and vice-versa).

builtin_models=$(grep -oE '"claude-[a-zA-Z0-9.-]+"' "$config_helper" | tr -d '"')
effective_models=$(bash "$config_helper" load 2>/dev/null \
  | jq -r '.models // {} | to_entries[] | .value')
config_models=$(printf '%s\n%s\n' "$builtin_models" "$effective_models" | sed '/^$/d' | sort -u)

if [[ -z "$config_models" ]]; then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "could not read any models.* ids from shipyard-config.sh"
  fail=$((fail+1))
else
  while IFS= read -r model; do
    [[ -z "$model" ]] && continue
    if is_priced "$model"; then
      printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "config model '${model}' is priced"
      pass=$((pass+1))
    else
      printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "config model '${model}' is NOT in the pricing table"
      printf '    every dispatch on this model would be booked at 0.00 USD\n'
      printf '    fix: add a row for it to PRICING_JQ in scripts/session-state.sh\n'
      fail=$((fail+1))
    fi
  done <<< "$config_models"
fi

# --------------------------------------------------------------------------
echo "== coverage — every agent-shim frontmatter model resolves to a pricing row"
# --------------------------------------------------------------------------
# The model-pinned worker shims declare a bare alias (`sonnet` / `haiku`) in
# their frontmatter. Those aliases reach bump-tokens verbatim, so the alias
# map in session-state.sh has to know each one.

shim_models=$(grep -rh '^model:' "$agents_dir" 2>/dev/null \
  | sed 's/^model:[[:space:]]*//' | tr -d '\r' | sort -u)

if [[ -z "$shim_models" ]]; then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "no agent-shim 'model:' frontmatter found under ${agents_dir}"
  fail=$((fail+1))
else
  while IFS= read -r model; do
    [[ -z "$model" ]] && continue
    if is_priced "$model"; then
      printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "agent-shim model '${model}' is priced"
      pass=$((pass+1))
    else
      printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "agent-shim model '${model}' is NOT in the pricing table"
      printf '    fix: add the id to PRICING_JQ, or the alias to ALIASES_JQ, in scripts/session-state.sh\n'
      fail=$((fail+1))
    fi
  done <<< "$shim_models"
fi

# --------------------------------------------------------------------------
echo "== coverage — the current default session model is priced"
# --------------------------------------------------------------------------
# The session model is inherited from the harness, not declared in config, so
# it has no other guard. This is the exact id whose absence caused #728.

if is_priced "claude-opus-4-8"; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "default session model 'claude-opus-4-8' is priced"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "default session model 'claude-opus-4-8' is NOT priced (this is #728)"
  fail=$((fail+1))
fi

# A dated suffix on the current model must resolve too — the API hands back
# dated ids, so exact-match-only would reopen the $0 hole from a new angle.
if is_priced "claude-opus-4-8-20260115"; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "dated 'claude-opus-4-8-20260115' resolves via prefix match"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "dated 'claude-opus-4-8-20260115' failed to resolve"
  fail=$((fail+1))
fi

# --------------------------------------------------------------------------
echo "== loudness — an unknown model is flagged, not silently zeroed"
# --------------------------------------------------------------------------
# The core #728 contract. A model the table has never heard of must be
# *distinguishable* from a genuinely-free one.

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "unk" --repo "o/r" >/dev/null

# stderr carries a loud warning — and the bump still SUCCEEDS (the call is
# fire-and-forget from the orchestrator, so it must not fail the dispatch).
stderr=$(SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "unk" --issue 42 --pr 99 \
  --input 1000000 --output 500000 \
  --mode issue-work --model "claude-notreal-9-9" 2>&1 >/dev/null)
rc=$?
assert_equals "$rc" "0" "unknown model does not fail the bump (fire-and-forget)"
assert_contains "$stderr" "not in the pricing table" "unknown model warns on stderr"
assert_contains "$stderr" "LOWER BOUND" "warning states the USD total is a lower bound"
assert_contains "$stderr" "claude-notreal-9-9" "warning names the offending model id"

# The token counts are still recorded — no data is lost, only the price.
tokens=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --session-id "unk" --path ".tokens.totals.input")
assert_equals "$tokens" "1000000" "token counts are still recorded for an unpriced model"

# The model lands in the session-level unpriced set.
unpriced=$(SHIPYARD_HOME="$tmphome" bash "$helper" read \
  --session-id "unk" --path ".tokens.unpriced_models" | jq -r '.[0]')
assert_equals "$unpriced" "claude-notreal-9-9" "unknown model recorded in .tokens.unpriced_models"

# ...and the per_invocation entry is stamped.
stamped=$(SHIPYARD_HOME="$tmphome" bash "$helper" read \
  --session-id "unk" --path ".tokens.per_invocation[0].unpriced")
assert_equals "$stamped" "true" "per_invocation entry stamped unpriced: true"

# read-tokens --format json surfaces the set so JSON consumers can tell
# "cost $0" from "cost unknown".
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read-tokens --session-id "unk" --format json | jq -r '.unpriced_models[0]')
assert_equals "$out" "claude-notreal-9-9" "read-tokens --format json exposes unpriced_models"

# ...and the human-facing comment says so in words.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read-tokens --session-id "unk" --pr 99 --format comment)
assert_contains "$out" "LOWER BOUND" "cost comment labels the USD figure a LOWER BOUND"
assert_contains "$out" "claude-notreal-9-9" "cost comment names the unpriced model"

# Dedupe: bumping the same unknown model twice records it once.
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "unk" --input 10 --model "claude-notreal-9-9" 2>/dev/null >/dev/null
count=$(SHIPYARD_HOME="$tmphome" bash "$helper" read \
  --session-id "unk" --path ".tokens.unpriced_models" | jq -r 'length')
assert_equals "$count" "1" "unpriced_models is a set (repeat bumps don't duplicate)"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== non-regression — a known model is NOT flagged"
# --------------------------------------------------------------------------
# The guard must not cry wolf: a priced model stays clean, keeps a non-zero
# USD estimate, and stamps unpriced: false.

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" init --session-id "known" --repo "o/r" >/dev/null

stderr=$(SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "known" --input 1000000 --model "claude-opus-4-8" 2>&1 >/dev/null)
assert_equals "$stderr" "" "known model produces no warning on stderr"

count=$(SHIPYARD_HOME="$tmphome" bash "$helper" read \
  --session-id "known" --path ".tokens.unpriced_models" | jq -r 'length')
assert_equals "$count" "0" "known model leaves unpriced_models empty"

stamped=$(SHIPYARD_HOME="$tmphome" bash "$helper" read \
  --session-id "known" --path ".tokens.per_invocation[0].unpriced")
assert_equals "$stamped" "false" "known model stamps unpriced: false"

# 1M input tokens at Opus-tier pricing ($5/Mtok) = $5.00 exactly.
usd=$(SHIPYARD_HOME="$tmphome" bash "$helper" read \
  --session-id "known" --path ".tokens.totals.estimated_usd")
assert_equals "$usd" "5" "claude-opus-4-8 prices 1M input tokens at \$5.00"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read-tokens --session-id "known" --format comment)
if [[ "$out" == *"LOWER BOUND"* ]]; then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "known-model comment must NOT carry the lower-bound warning"
  fail=$((fail+1))
else
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "known-model comment carries no lower-bound warning"
  pass=$((pass+1))
fi

# An omitted --model is "unattributed", not "unpriced" — per_invocation.model
# is already null, which is self-describing. Flagging it would spam the
# warning on every legitimately model-less bump.
SHIPYARD_HOME="$tmphome" bash "$helper" bump-tokens \
  --session-id "known" --input 100 >/dev/null 2>&1
count=$(SHIPYARD_HOME="$tmphome" bash "$helper" read \
  --session-id "known" --path ".tokens.unpriced_models" | jq -r 'length')
assert_equals "$count" "0" "an omitted --model is not flagged as unpriced"

rm -rf "$tmphome"

echo
echo "Results: ${GREEN}${pass} passed${RESET}, ${RED}${fail} failed${RESET}"
[[ $fail -eq 0 ]]
