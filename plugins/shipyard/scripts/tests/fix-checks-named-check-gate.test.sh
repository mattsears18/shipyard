#!/usr/bin/env bash
# Test: the fix-checks-only worker contract documents a named-failing-check
# re-verification gate that must pass before the worker may return `green`.
#
# Background — issue #416: two `shipyard:fix-checks-worker` (Haiku)
# dispatches against lightwork PRs #1444 / #1447 (session
# do-work-20260531T113301Z-98771) returned the terminal string `green #<pr>`
# while the required 🧪 Unit Tests check was STILL FAILING on CI. The real
# failure was an i18n-parity test (`__tests__/i18n.test.ts`) — the PR added
# `Strings.*` keys without mirroring them into `locales/en.json`. Both
# workers MISDIAGNOSED: they concluded the failure was the repo's
# `jest.config.js` `testPathIgnorePatterns: ['/.claude/worktrees/']`
# "No tests found" artifact (a real-but-unrelated worktree gotcha),
# "fixed" THAT, and returned `green` — one even admitted CI "hadn't re-run"
# yet. Only the orchestrator's trust-but-verify rollup spot-check caught it;
# without it two red PRs would have auto-merged.
#
# The fix adds a named-failing-check re-verification gate to
# `agents/issue-worker/fix-checks-only.md`: before returning `green`, the
# worker MUST re-fetch the specific check(s) that were failing at dispatch
# and confirm each one's latest run on the current head SHA concluded
# SUCCESS — never infer `green` from a local run, from `--watch`'s exit
# code alone, or from "I fixed what I thought was wrong." It also asserts
# the rollup head SHA matches the pushed SHA (no stale pre-push rollup) and
# names the i18n-parity signature as a distinct pattern.
#
# This test is the regression guard: if the gate or its load-bearing
# semantics regress, the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/fix-checks-named-check-gate.test.sh

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

fix_checks_path="$repo_root/plugins/shipyard/agents/issue-worker/fix-checks-only.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_file_exists() {
  local path="$1"; local label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (missing: %s)\n' "$RED" "$RESET" "$label" "$path"; fail=$((fail+1))
  fi
}

assert_contains() {
  local file="$1"; local needle="$2"; local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"; fail=$((fail+1))
  fi
}

assert_section_before() {
  local file="$1"; local before="$2"; local after="$3"; local label="$4"
  local before_line after_line
  before_line=$(grep -nF -- "$before" "$file" | head -1 | cut -d: -f1)
  after_line=$(grep -nF -- "$after" "$file" | head -1 | cut -d: -f1)
  if [[ -z "$before_line" ]]; then
    printf '  %sFAIL%s  %s (could not find before-marker: %s)\n' "$RED" "$RESET" "$label" "$before"; fail=$((fail+1)); return
  fi
  if [[ -z "$after_line" ]]; then
    printf '  %sFAIL%s  %s (could not find after-marker: %s)\n' "$RED" "$RESET" "$label" "$after"; fail=$((fail+1)); return
  fi
  if (( before_line < after_line )); then
    printf '  %sPASS%s  %s (before @ %d, after @ %d)\n' "$GREEN" "$RESET" "$label" "$before_line" "$after_line"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (before @ %d NOT < after @ %d)\n' "$RED" "$RESET" "$label" "$before_line" "$after_line"; fail=$((fail+1))
  fi
}

echo "fix-checks-only named-failing-check re-verification gate (issue #416)"
echo

assert_file_exists "$fix_checks_path" "fix-checks-only.md exists"

# The gate section itself, with the heading that the in-doc anchor links target.
assert_contains "$fix_checks_path" \
  "## Named-failing-check re-verification gate (load-bearing)" \
  "gate section heading present"

# The in-doc anchors point at the load-bearing heading slug.
assert_contains "$fix_checks_path" \
  "#named-failing-check-re-verification-gate-load-bearing" \
  "anchor slug referenced (cross-links resolve to the gate section)"

# References issue #416 so provenance is traceable.
assert_contains "$fix_checks_path" \
  "github.com/mattsears18/shipyard/issues/416" \
  "links issue #416 for provenance"

# Core contract: re-confirm the SPECIFIC check(s) failing at dispatch
# flipped to SUCCESS on the post-push SHA.
assert_contains "$fix_checks_path" \
  "re-confirming the specific check(s) that were failing at dispatch flipped to SUCCESS on the post-push SHA" \
  "green definition requires re-confirming the named failing check"

# The two failure modes the gate closes: misdiagnosis + premature return.
assert_contains "$fix_checks_path" \
  "Misdiagnosis." \
  "names the misdiagnosis failure mode"
assert_contains "$fix_checks_path" \
  "Premature return." \
  "names the premature-return failure mode"

# The gate must assert the rollup head SHA matches the pushed SHA (no stale
# pre-push rollup) — this is what distinguishes it from a bare `--watch`.
assert_contains "$fix_checks_path" \
  "head_matches_pushed" \
  "gate asserts rollup head SHA matches the pushed SHA"
assert_contains "$fix_checks_path" \
  "headRefOid" \
  "gate queries headRefOid to compare against the pushed SHA"

# Never infer green from a local run / watch exit code / hypothesis.
assert_contains "$fix_checks_path" \
  "Never infer the named check passed from a local test run, from \`--watch\`'s exit code alone" \
  "gate forbids inferring green from local run / watch exit code"

# Misdiagnosis-specific instruction: a still-FAILURE named check means
# loop, do NOT fix a different check and declare victory.
assert_contains "$fix_checks_path" \
  "Do NOT \"fix\" a *different* check and declare victory" \
  "gate forbids fixing a different check and declaring victory"

# The i18n-parity signature is named as a distinct, common pattern.
assert_contains "$fix_checks_path" \
  "i18n-parity signature" \
  "names the i18n-parity signature as a distinct pattern"
assert_contains "$fix_checks_path" \
  "locales/en.json" \
  "references the locales/en.json missing-keys signature"

# The jest worktree-ignore misdiagnosis trap is documented as the wrong call.
assert_contains "$fix_checks_path" \
  "testPathIgnorePatterns" \
  "documents the jest worktree-ignore artifact as the misdiagnosis trap"

# The Don't section carries a corresponding entry.
assert_contains "$fix_checks_path" \
  "Don't return \`green #<M>\` without re-verifying the NAMED failing check flipped to SUCCESS" \
  "Don't section forbids green without named-check re-verification"

# fix-loop step 1 instructs recording the failing check name(s).
assert_contains "$fix_checks_path" \
  "Record the failing check name(s)" \
  "fix-loop step 1 records the failing check name(s) for the gate"

# Ordering: the gate section appears after the watch-loop block and before
# the fix-loop (so a worker reads the gate as part of the return contract).
assert_section_before "$fix_checks_path" \
  "## Named-failing-check re-verification gate (load-bearing)" \
  "## Fix-loop" \
  "gate section precedes the Fix-loop section"

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
