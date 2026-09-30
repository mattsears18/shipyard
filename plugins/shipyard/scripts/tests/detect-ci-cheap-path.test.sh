#!/usr/bin/env bash
# Test: the CI-cheap-path detector — decide whether a repo's CI has a
# path-gated cheap lane, and whether a candidate issue's referenced file
# paths fall entirely inside it (issue #1157, follow-up to #1141/#1156).
#
# Background — issue #1157
# --------------------------
# #1141 (session-start pool capacity) and #1156 (dispatch-time backpressure
# hold) both treat every candidate issue as equally CI-expensive. On a repo
# whose CI is path-gated (a `pull_request`-triggered workflow declares
# `paths-ignore: ['docs/**', ...]`), a docs-only PR never triggers the heavy
# job at all — it costs the saturated runner pool nothing. This detector:
#   1. Scans a repo's workflow files for `paths-ignore:` glob lists (the
#      only invertible shape — an INCLUDE-only `paths:` allowlist is NOT
#      treated as cheap-path evidence, since its complement isn't safely
#      derivable without knowing every other path in the repo).
#   2. Decides whether a candidate's referenced file paths ALL fall inside
#      that glob list — the CI-cheap classification steady-state.md step C
#      uses to bias candidate selection under a backpressure hold instead of
#      just parking the slot.
#
# This file pins:
#   (A) --extract-paths — pure file-path extraction from free text;
#   (B) --match — pure glob-match decision truth table (including the
#       "**/ " / "/**" gitignore-style optional-directory-segment cases);
#   (C) live repo-shape discovery against fixture workflow files (block-style
#       and flow-style `paths-ignore:` lists, both extracted and unioned);
#   (D) usage/argument-count handling for all three modes;
#   (E) setup step 1.37 exists, calls the detector, and writes
#       `.ci_capacity.cheap_ci_globs` through in the same step-1.5 call
#       step 1.36's fields ride;
#   (F) session-state-file.md documents `cheap_ci_globs`;
#   (G) steady-state.md step C wires the CI-cheap bias in as a pool filter
#       under a backpressure hold, gated on the `ci.prefer_cheap_under_backpressure`
#       config knob and a non-empty `.ci_capacity.cheap_ci_globs`;
#   (H) the `ci.prefer_cheap_under_backpressure` config knob exists in both
#       the schema and the built-in defaults, default `true`.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/detect-ci-cheap-path.test.sh

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

DETECTOR="$repo_root/plugins/shipyard/scripts/detect-ci-cheap-path.sh"
SETUP_MD="$repo_root/plugins/shipyard/commands/do-work/setup/01-repo-recovery.md"
SESSION_STATE_MD="$repo_root/plugins/shipyard/commands/do-work/session-state-file.md"
STEADY_STATE_MD="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
CONFIG_SCHEMA="$repo_root/plugins/shipyard/schemas/shipyard.config.schema.json"
CONFIG_SH="$repo_root/plugins/shipyard/scripts/shipyard-config.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
  fi
}

# Scans across every setup/*.md fragment rather than one hardcoded file — a
# router/fragment split can silently relocate a step's content out of
# $SETUP_MD without warning (issue #1453; mirrors the fix in
# shipyard-repo-root-preamble.test.sh check (4)).
SETUP_DIR="$repo_root/plugins/shipyard/commands/do-work/setup"
assert_contains_in_setup() {
  local needle="$1" label="$2"
  if grep -qFl -- "$needle" "$SETUP_DIR"/*.md 2>/dev/null; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    expected to find (in any setup/*.md fragment): %s\n' "$needle"
  fi
}

assert_equals() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    assert_pass "$label (got [$actual])"
  else
    assert_fail "$label (expected [$expected], got [$actual])"
  fi
}

echo "CI-cheap-path detector regression tests (issue #1157)"
echo

# ---------------------------------------------------------------------------
# (A) --extract-paths — pure file-path extraction.
# ---------------------------------------------------------------------------
echo "(A) --extract-paths — file-path extraction from free text"
if [[ -f "$DETECTOR" ]]; then
  assert_pass "detect-ci-cheap-path.sh exists"

  got="$(bash "$DETECTOR" --extract-paths "fix link in docs/setup.md and also README.md, see auth.ts" 2>/dev/null)"
  assert_equals "extracts every file-shaped token, de-duplicated" \
    "docs/setup.md,README.md,auth.ts" "$got"

  got="$(bash "$DETECTOR" --extract-paths "no file paths mentioned here at all" 2>/dev/null)"
  assert_equals "no file-shaped token -> empty output" "" "$got"

  got="$(bash "$DETECTOR" --extract-paths "touches docs/a.md twice: docs/a.md" 2>/dev/null)"
  assert_equals "duplicate mentions collapse to one" "docs/a.md" "$got"
else
  assert_fail "detect-ci-cheap-path.sh exists (missing at $DETECTOR)"
fi
echo

# ---------------------------------------------------------------------------
# (B) --match — pure glob-match decision truth table.
# ---------------------------------------------------------------------------
echo "(B) --match — glob-match decision truth table"
if [[ -f "$DETECTOR" ]]; then
  assert_match() {
    local got
    got="$(bash "$DETECTOR" --match "$1" "$2" 2>/dev/null)"
    assert_equals "$4" "$3" "$got"
  }

  assert_match "docs/setup.md,README.md" "docs/**,**/*.md" "match" \
    "every candidate path covered by at least one glob -> match"
  assert_match "docs/setup.md,src/auth.ts" "docs/**,**/*.md" "no-match" \
    "one candidate path uncovered -> no-match"
  assert_match "" "docs/**" "no-match" \
    "empty candidate-paths list -> no-match (never bias on zero evidence)"
  assert_match "docs/setup.md" "" "no-match" \
    "empty globs list -> no-match (never bias on zero evidence)"
  assert_match "README.md" "**/*.md" "match" \
    "gitignore-style **/ optionally matches a root-level file, not just a nested one"
  assert_match "docs/nested/setup.md" "docs/**" "match" \
    "trailing /** matches any depth under the prefix"
  assert_match "src/index.ts" "docs/**,**/*.md" "no-match" \
    "a source file never matches a docs-only glob set"
else
  assert_fail "--match decision truth table (detector missing)"
fi
echo

# ---------------------------------------------------------------------------
# (C) Live repo-shape discovery against fixture workflow files.
# ---------------------------------------------------------------------------
echo "(C) live repo-shape discovery — fixture workflow files"
if [[ -f "$DETECTOR" ]]; then
  fixture_dir="$(mktemp -d)"
  trap 'rm -rf "$fixture_dir"' EXIT

  cat > "$fixture_dir/tests.yml" <<'YAML'
name: tests
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
    paths-ignore:
      - 'docs/**'
      - '**/*.md'
YAML

  cat > "$fixture_dir/flow.yml" <<'YAML'
on:
  pull_request:
    paths-ignore: ['LICENSE', 'CHANGELOG.md']
YAML

  # Two workflows with DISJOINT ignore lists share no cheap lane: a docs-only
  # diff still runs flow.yml, a LICENSE-only diff still runs tests.yml
  # (#1600 — cross-file sets intersect; the old union over-claimed).
  got="$(bash "$DETECTOR" "$fixture_dir" 2>/dev/null)"
  assert_equals "disjoint paths-ignore lists across two workflows -> no-cheap-path (intersection, not union)" \
    "no-cheap-path" "$got"

  # Overlapping lists: only the shared glob survives. Block + flow style
  # are both parsed (the shared glob comes from each style once).
  cat > "$fixture_dir/flow.yml" <<'YAML'
on:
  pull_request:
    paths-ignore: ['LICENSE', 'docs/**']
YAML
  got="$(bash "$DETECTOR" "$fixture_dir" 2>/dev/null)"
  assert_equals "block-style + flow-style lists intersect to the shared glob" \
    "cheap-path-available globs=docs/**" "$got"

  single_dir="$(mktemp -d)"
  cp "$fixture_dir/tests.yml" "$single_dir/tests.yml"
  got="$(bash "$DETECTOR" "$single_dir" 2>/dev/null)"
  assert_equals "a single filtered workflow reports its own full list" \
    "cheap-path-available globs=docs/**,**/*.md" "$got"
  rm -rf "$single_dir"

  empty_dir="$(mktemp -d)"
  cat > "$empty_dir/no-filter.yml" <<'YAML'
on:
  pull_request:
    branches: [main]
YAML
  got="$(bash "$DETECTOR" "$empty_dir" 2>/dev/null)"
  assert_equals "a repo with no paths-ignore anywhere reports no-cheap-path honestly" \
    "no-cheap-path" "$got"
  rm -rf "$empty_dir"

  got="$(bash "$DETECTOR" "/nonexistent/dir/$$" 2>/dev/null)"
  assert_equals "a missing workflows dir degrades to no-cheap-path, never an error" \
    "no-cheap-path" "$got"
else
  assert_fail "live repo-shape discovery (detector missing)"
fi
echo

# ---------------------------------------------------------------------------
# (C2) dorny/paths-filter negation lanes (issue #1600).
# ---------------------------------------------------------------------------
echo "(C2) dorny/paths-filter negation lanes (#1600)"
if [[ -f "$DETECTOR" ]]; then
  dorny_dir="$(mktemp -d)"

  # The recognized shape: '**' + negations under predicate-quantifier: every,
  # with one negation re-admitted by a sibling filter's identical positive.
  cat > "$dorny_dir/ci.yml" <<'YAML'
on:
  pull_request:
jobs:
  detect-paths:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dorny/paths-filter@v4 # pinned
        id: filter
        with:
          # comment lines inside the step are ignored
          predicate-quantifier: every
          filters: |
            code:
              - '**'
              - '!**/*.md'
              - '!docs/**'   # trailing comment
              - "!data/onboarding/**"
            onboarding:
              - 'data/onboarding/**'
      - name: next step
        run: echo hi
  other:
    steps:
      - name: unrelated
        with:
          filters: |
            x:
              - '**'
              - '!src/**'
YAML
  got="$(bash "$DETECTOR" "$dorny_dir" 2>/dev/null)"
  assert_equals "negations of a '**' filter under 'every' become cheap globs; a re-admitted negation is dropped; a non-dorny 'filters:' is ignored" \
    "cheap-path-available globs=**/*.md,docs/**" "$got"

  # `- name:` then `uses:` on its own line is the same step.
  cat > "$dorny_dir/ci.yml" <<'YAML'
jobs:
  d:
    steps:
      - name: Detect
        uses: 'dorny/paths-filter@abc123'
        with:
          predicate-quantifier: 'every'
          filters: |
            code:
              - '**'
              - '!LICENSE'
YAML
  got="$(bash "$DETECTOR" "$dorny_dir" 2>/dev/null)"
  assert_equals "'- name:' + separate 'uses:' line is parsed as one dorny step" \
    "cheap-path-available globs=LICENSE" "$got"

  # Default quantifier (`some`): '**' alone satisfies the filter for every
  # file, so the negations exclude nothing — no cheap lane.
  cat > "$dorny_dir/ci.yml" <<'YAML'
jobs:
  d:
    steps:
      - uses: dorny/paths-filter@v4
        with:
          filters: |
            code:
              - '**'
              - '!docs/**'
YAML
  got="$(bash "$DETECTOR" "$dorny_dir" 2>/dev/null)"
  assert_equals "without predicate-quantifier: every, negations exclude nothing -> no-cheap-path" \
    "no-cheap-path" "$got"

  # An include-only filter (no '**' catch-all) is not an exclude list.
  cat > "$dorny_dir/ci.yml" <<'YAML'
jobs:
  d:
    steps:
      - uses: dorny/paths-filter@v4
        with:
          predicate-quantifier: every
          filters: |
            web:
              - 'apps/web/**'
              - '!apps/web/docs/**'
YAML
  got="$(bash "$DETECTOR" "$dorny_dir" 2>/dev/null)"
  assert_equals "a filter without the '**' catch-all is not treated as a cheap lane" \
    "no-cheap-path" "$got"

  # dorny lane intersected with another workflow's paths-ignore.
  cat > "$dorny_dir/ci.yml" <<'YAML'
jobs:
  d:
    steps:
      - uses: dorny/paths-filter@v4
        with:
          predicate-quantifier: every
          filters: |
            code:
              - '**'
              - '!**/*.md'
              - '!docs/**'
              - '!.github/**'
YAML
  cat > "$dorny_dir/bundle.yml" <<'YAML'
on:
  pull_request:
    paths-ignore:
      - '**/*.md'
      - '.github/**'
      - 'scripts/**'
YAML
  got="$(bash "$DETECTOR" "$dorny_dir" 2>/dev/null)"
  assert_equals "dorny lane and a paths-ignore workflow intersect to their shared globs" \
    "cheap-path-available globs=**/*.md,.github/**" "$got"

  # The issue's trap: a path under a non-negated dir is never cheap.
  got="$(bash "$DETECTOR" --match "scripts/lib/foo.ts" "**/*.md,docs/**" 2>/dev/null)"
  assert_equals "a docs-labeled issue whose path sits outside the lane is not cheap" \
    "no-match" "$got"

  rm -rf "$dorny_dir"
else
  assert_fail "dorny/paths-filter lanes (detector missing)"
fi
echo

# ---------------------------------------------------------------------------
# (D) Usage/argument-count handling across all three modes.
# ---------------------------------------------------------------------------
echo "(D) usage handling"
if [[ -f "$DETECTOR" ]]; then
  bash "$DETECTOR" >/dev/null 2>/tmp/detect-ci-cheap-path-usage.$$
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    assert_pass "no-args invocation exits non-zero"
  else
    assert_fail "no-args invocation exits non-zero (got exit 0)"
  fi
  assert_contains /tmp/detect-ci-cheap-path-usage.$$ "usage:" "usage message printed on missing <workflows-dir>"
  rm -f /tmp/detect-ci-cheap-path-usage.$$

  bash "$DETECTOR" --match onlyonearg >/dev/null 2>/tmp/detect-ci-cheap-path-match-usage.$$
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    assert_pass "--match with wrong arg count exits non-zero"
  else
    assert_fail "--match with wrong arg count exits non-zero (got exit 0)"
  fi
  rm -f /tmp/detect-ci-cheap-path-match-usage.$$

  bash "$DETECTOR" --extract-paths >/dev/null 2>/tmp/detect-ci-cheap-path-extract-usage.$$
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    assert_pass "--extract-paths with wrong arg count exits non-zero"
  else
    assert_fail "--extract-paths with wrong arg count exits non-zero (got exit 0)"
  fi
  rm -f /tmp/detect-ci-cheap-path-extract-usage.$$
else
  assert_fail "usage handling (detector missing)"
fi
echo

# ---------------------------------------------------------------------------
# (E) setup step 1.37 — detector wiring + write-through.
# ---------------------------------------------------------------------------
echo "(E) setup step 1.37 — detector wiring + write-through"
if [[ -f "$SETUP_MD" ]]; then
  assert_pass "01-repo-recovery.md exists"
  assert_contains_in_setup "### 1.37 Detect CI-cheap-path availability" \
    "step 1.37 heading present"
  assert_contains_in_setup "detect-ci-cheap-path.sh" \
    "step 1.37 invokes the detector script"
  assert_contains_in_setup "issues/1157" \
    "step 1.37 cites issue #1157"
  assert_contains_in_setup "CI_CHEAP_GLOBS" \
    "step 1.37 resolves a cheap-globs variable"
  # shellcheck disable=SC2016 # this is a literal-string needle for grep, not a shell expansion
  assert_contains_in_setup 'cheap_ci_globs: \"${CI_CHEAP_GLOBS' \
    "step 1.5 write-through carries cheap_ci_globs alongside ci_capacity"
else
  assert_fail "01-repo-recovery.md exists (missing at $SETUP_MD)"
fi
echo

# ---------------------------------------------------------------------------
# (F) session-state-file.md documents cheap_ci_globs.
# ---------------------------------------------------------------------------
echo "(F) session-state-file.md — schema"
if [[ -f "$SESSION_STATE_MD" ]]; then
  assert_pass "session-state-file.md exists"
  assert_contains "$SESSION_STATE_MD" '"cheap_ci_globs"' \
    "schema block includes cheap_ci_globs"
  assert_contains "$SESSION_STATE_MD" "issues/1157" \
    "prose cites issue #1157"
else
  assert_fail "session-state-file.md exists (missing at $SESSION_STATE_MD)"
fi
echo

# ---------------------------------------------------------------------------
# (G) steady-state.md step C — CI-cheap bias wiring.
# ---------------------------------------------------------------------------
echo "(G) steady-state.md step C — CI-cheap bias wiring"
if [[ -f "$STEADY_STATE_MD" ]]; then
  assert_pass "steady-state.md exists"
  assert_contains "$STEADY_STATE_MD" "CI-cheap candidate bias under a backpressure hold" \
    "step C documents the CI-cheap bias"
  assert_contains "$STEADY_STATE_MD" "issues/1157" \
    "step C cites issue #1157"
  assert_contains "$STEADY_STATE_MD" "ci.prefer_cheap_under_backpressure" \
    "bias is gated on the ci.prefer_cheap_under_backpressure config knob"
  assert_contains "$STEADY_STATE_MD" ".ci_capacity.cheap_ci_globs" \
    "bias reads .ci_capacity.cheap_ci_globs from session state"
  assert_contains "$STEADY_STATE_MD" "pool FILTER at the moment of a hold, not a rank override" \
    "precedence vs. existing priority scoring is documented explicitly"
  assert_contains "$STEADY_STATE_MD" "detect-ci-cheap-path.sh" \
    "step C invokes the detector script"
  assert_contains "$STEADY_STATE_MD" "--extract-paths" \
    "step C extracts candidate paths via the detector's pure mode"
  assert_contains "$STEADY_STATE_MD" "Never bias on zero evidence" \
    "step C documents the zero-evidence guard"
  assert_contains "$STEADY_STATE_MD" "No CI-cheap candidate found among" \
    "step C documents the fallback-to-hold path when no candidate matches"
  assert_contains "$STEADY_STATE_MD" "The escape valve prefers the cheap lane too" \
    "step C routes an escape-valve dispatch over a saturated queue through the cheap scan (#1600)"
  assert_contains "$STEADY_STATE_MD" '"<multiplier>" 0' \
    "valve detection re-asks --decide-backpressure with MIN_IN_FLIGHT=0 rather than re-deriving the threshold"
  assert_contains "$STEADY_STATE_MD" "otherwise dispatch the normal top candidate anyway" \
    "a valve dispatch with no cheap candidate still dispatches (never re-introduces the deadlock)"
  assert_contains "$STEADY_STATE_MD" "states the lane and ONE escape hatch" \
    "a cheap-lane dispatch prompt names a single precedence for leaving the lane (#1600)"
  assert_contains "$STEADY_STATE_MD" 'CI lane: left — <paths>' \
    "step C names the PR-body flag for an out-of-lane fix"
  ISSUE_WORK_MD="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"
  assert_contains "$ISSUE_WORK_MD" 'CI lane: left — <paths>' \
    "issue-work.md tells the worker the same single escape hatch"
else
  assert_fail "steady-state.md exists (missing at $STEADY_STATE_MD)"
fi
echo

# ---------------------------------------------------------------------------
# (H) ci.prefer_cheap_under_backpressure config knob — schema + defaults.
# ---------------------------------------------------------------------------
echo "(H) ci.prefer_cheap_under_backpressure — schema + built-in defaults"
if [[ -f "$CONFIG_SCHEMA" ]]; then
  assert_pass "shipyard.config.schema.json exists"
  assert_contains "$CONFIG_SCHEMA" '"prefer_cheap_under_backpressure"' \
    "schema declares ci.prefer_cheap_under_backpressure"
  if command -v jq >/dev/null 2>&1; then
    if jq empty "$CONFIG_SCHEMA" >/dev/null 2>&1; then
      assert_pass "shipyard.config.schema.json is valid JSON after the addition"
    else
      assert_fail "shipyard.config.schema.json is valid JSON after the addition"
    fi
  fi
else
  assert_fail "shipyard.config.schema.json exists (missing at $CONFIG_SCHEMA)"
fi

if [[ -f "$CONFIG_SH" ]]; then
  assert_contains "$CONFIG_SH" '"prefer_cheap_under_backpressure": true' \
    "built-in defaults set ci.prefer_cheap_under_backpressure to true"

  got="$(bash "$CONFIG_SH" get ci.prefer_cheap_under_backpressure 2>/dev/null)"
  assert_equals "shipyard-config.sh get ci.prefer_cheap_under_backpressure resolves to the built-in default" \
    "true" "$got"
else
  assert_fail "shipyard-config.sh exists (missing at $CONFIG_SH)"
fi
echo

printf 'passed: %d, failed: %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
