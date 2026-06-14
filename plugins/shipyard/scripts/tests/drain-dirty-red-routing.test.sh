#!/usr/bin/env bash
# Test: DIRTY-AND-red PRs are routed to fix-checks, not fix-rebase, during drain.
#
# Background — issue #577: the end-of-session drain dispatched fix-rebase on any
# PR whose mergeStateStatus == DIRTY, without checking the rollup. A DIRTY PR
# with a hard-failing check would cause fix-rebase to bail immediately
# ("blocked rebase: PR has failing checks — needs fix-checks, not rebase"),
# wasting a Haiku dispatch plus an extra orchestrator round-trip before the
# correct fix-checks routing fired.
#
# The fix introduces an explicit D_dirty_red set (DIRTY + hard-failure rollup)
# that is routed to fix-checks in per-poll action 1, and adds explicit
# "never classify from mergeStateStatus alone" guards to D_dirty and the
# open-PR query description.
#
# This regression guard asserts that:
#   1. D_dirty_red is defined in drain.md and references #577.
#   2. D_dirty explicitly excludes D_dirty_red members.
#   3. Per-poll action 1 routes D_dirty_red to fix-checks.
#   4. The drain log emits a visible routing decision for D_dirty_red.
#   5. The "never classify from mergeStateStatus alone" prohibition exists.
#   6. The drain status line includes the dirty_red= token.
#   7. The latest-per-name semantics section covers D_dirty_red.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/drain-dirty-red-routing.test.sh

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

drain_path="$repo_root/plugins/shipyard/commands/do-work/drain.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_file_exists() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (missing: %s)\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail+1))
  fi
}

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s:\n    %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to NOT find in %s:\n    %s\n' "$file" "$needle"
    fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  fi
}

echo ""
echo "Test: drain DIRTY-AND-red routing to fix-checks (#577 regression guard)"
echo ""

assert_file_exists "$drain_path" "drain.md exists"

echo ""
echo "D_dirty_red set — defined and referenced"
echo ""

# D_dirty_red must be defined in the per-poll bookkeeping section.
assert_contains "$drain_path" \
  "D_dirty_red" \
  "drain.md defines D_dirty_red set"

# D_dirty_red must reference the issue that introduced it.
assert_contains "$drain_path" \
  "#577" \
  "drain.md D_dirty_red definition references issue #577"

# D_dirty_red definition must describe DIRTY + hard-failure as the population.
assert_contains "$drain_path" \
  "DIRTY" \
  "drain.md D_dirty_red description mentions DIRTY"

# D_dirty_red must say fix-checks is the correct route (not fix-rebase).
assert_contains "$drain_path" \
  "fix-checks" \
  "drain.md D_dirty_red routes to fix-checks"

echo ""
echo "D_dirty set — explicitly excludes D_dirty_red and prohibits mergeStateStatus-only classification"
echo ""

# D_dirty must explicitly guard against D_dirty_red membership.
assert_contains "$drain_path" \
  "NOT in \`D_dirty_red\`" \
  "drain.md D_dirty excludes D_dirty_red members"

# D_dirty (or the accompanying note) must prohibit classifying based on mergeStateStatus alone.
assert_contains "$drain_path" \
  "never classify a PR as fix-rebase-eligible based on" \
  "drain.md D_dirty prohibits mergeStateStatus-alone classification"

# The prohibition must name mergeStateStatus as the forbidden shortcut.
assert_contains "$drain_path" \
  "\`mergeStateStatus\` alone" \
  "drain.md prohibition names mergeStateStatus alone as the forbidden shortcut"

echo ""
echo "Per-poll action 1 — routes D_dirty_red to fix-checks alongside R_new"
echo ""

# Per-poll action 1 must mention D_dirty_red alongside R_new.
assert_contains "$drain_path" \
  "D_dirty_red" \
  "drain.md per-poll action 1 references D_dirty_red"

# Action 1 must say DIRTY-AND-red PRs are routed to fix-checks, not fix-rebase.
assert_contains "$drain_path" \
  "DIRTY-AND-red" \
  "drain.md action 1 names the DIRTY-AND-red population"

# Action 1 must explain WHY fix-rebase would be wrong (guaranteed-bail reason).
assert_contains "$drain_path" \
  "wasted" \
  "drain.md action 1 explains the wasted-dispatch cost of routing to fix-rebase"

echo ""
echo "Drain log — routing decision is surfaced"
echo ""

# A log line must be emitted for each D_dirty_red routing decision.
assert_contains "$drain_path" \
  "DIRTY+failing" \
  "drain.md emits a log line naming the DIRTY+failing classification"

# The log line must identify the routing direction.
assert_contains "$drain_path" \
  "fix-checks (not fix-rebase)" \
  "drain.md log line clarifies the routing direction"

echo ""
echo "Drain status line — dirty_red= token"
echo ""

# The status line template must include the dirty_red= counter.
assert_contains "$drain_path" \
  "dirty_red=<D_dirty_red>" \
  "drain.md status line includes dirty_red= token"

echo ""
echo "Latest-per-name section — updated to cover D_dirty_red"
echo ""

# The latest-per-name semantics section heading must mention D_dirty_red.
assert_contains "$drain_path" \
  "D_dirty_red" \
  "drain.md latest-per-name section covers D_dirty_red (already verified above, sanity check)"

# The bash snippet comment must mention D_dirty_red.
assert_contains "$drain_path" \
  "D_dirty_red (>0 AND DIRTY" \
  "drain.md bash snippet comment explains D_dirty_red classification"

echo ""
echo "Negative assertions — old single-classification language removed / updated"
echo ""

# The old open-PR query note said "mergeStateStatus == DIRTY is the signal
# that a PR is stale relative to current main but otherwise healthy". That
# phrasing is dangerously incomplete — the fix should have updated it to
# require the rollup split. Assert the old "but otherwise healthy" shortcut
# wording is gone.
assert_not_contains "$drain_path" \
  "but otherwise healthy" \
  "drain.md open-PR query note no longer calls DIRTY 'otherwise healthy' without a rollup check"

echo ""
echo "Results: $pass passed, $fail failed"
if (( fail > 0 )); then
  exit 1
fi
exit 0
