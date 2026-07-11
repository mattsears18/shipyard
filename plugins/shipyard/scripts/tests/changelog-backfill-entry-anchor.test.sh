#!/usr/bin/env bash
# Test: the CHANGELOG 'PR #TBD' backfill in steady-state.md A.1 anchors its sed
# substitution on THIS PR's own entry (the line carrying `closes #<N>`), not the
# first file-global 'PR #TBD' occurrence (#700).
#
# Background — issue #700: the A.1 backfill (#581 / #583) replaced the placeholder
# with a non-global sed:
#
#     updated=$(echo "$changelog_on_main" | sed "s/PR #TBD/PR #<M>/")
#
# Without the `g` flag, sed replaces the FIRST 'PR #TBD' in the file. That is only
# correct when exactly one placeholder is pending. When two or more release PRs
# merge in the same window before their backfills both run, `main` carries
# multiple 'PR #TBD' entries at once (newest-first) — and the backfill for PR #<M>
# then writes #<M> into whichever entry is TOPMOST, which may belong to a
# different PR, leaving the intended entry stranded at 'PR #TBD'.
#
# Concrete repro from the issue: PR #692 (release 2.3.10) merged, then PR #693
# opened to backfill it — but the 2.3.10 entry on `main` STAYED 'PR #TBD' because
# #693's first-occurrence sed resolved a different topmost placeholder.
#
# The fix anchors the substitution on the reconciled issue's entry:
#
#     updated=$(echo "$changelog_on_main" | sed "/closes #<N>[;) ]/ s/PR #TBD/PR #<M>/")
#
# The entry's summary line always carries the token pair `(closes #<N>; PR #TBD)`,
# so `<N>` (known at `shipped` reconcile time) uniquely targets the correct entry.
#
# This test has two layers:
#   1. Spec-coupling: assert steady-state.md actually uses the entry-anchored sed
#      form (so this behavioral replica stays pinned to the shipped spec).
#   2. Behavioral: build a two-entry CHANGELOG fixture with two pending
#      'PR #TBD' placeholders and run the anchored sed for the LOWER entry's PR —
#      assert ONLY that entry is resolved and the sibling's placeholder is intact,
#      then assert idempotency on a re-run.
#
# Pure bash + sed, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/changelog-backfill-entry-anchor.test.sh

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

steady_state_path="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find: %s\n' "$needle"
    fail=$((fail+1))
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    did NOT expect to find: %s\n' "$needle"
    fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  fi
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

echo "CHANGELOG backfill entry-anchor regression tests (issue #700)"
echo

# ── Layer 1: spec-coupling ──────────────────────────────────────────────────
# The behavioral replica below only proves the fix if the shipped spec actually
# uses the entry-anchored sed. Pin that here so the two stay coupled.
assert_file_contains "$steady_state_path" \
  'sed "/closes #<N>[;) ]/ s/PR #TBD/PR #<M>/"' \
  "steady-state.md uses the entry-anchored sed (address /closes #<N>/), not a file-global replace (#700)"

# ── Layer 2: behavioral ─────────────────────────────────────────────────────
# Two-entry CHANGELOG with two pending 'PR #TBD' placeholders, newest-first.
# The TOPMOST entry (closes #701) is a sibling; the LOWER entry (closes #700) is
# the one we reconcile. A file-global first-occurrence sed would wrongly resolve
# the sibling; the anchored sed must resolve ONLY #700.
#
# Build the fixture via a temp-file heredoc rather than `$(cat <<'EOF')` — the
# body contains backticks, and macOS's bash 3.2 mis-parses backticks inside a
# command-substitution heredoc.
fixture_file="$(mktemp -t changelog-anchor-fixture.XXXXXX)"
trap 'rm -f "$fixture_file"' EXIT
cat > "$fixture_file" <<'EOF'
## shipyard

### 2.5.1 — 2026-07-11
**Sibling release entry that is still awaiting its own backfill** (closes #701; PR #TBD). Prose about the sibling change. Files touched:
- `plugins/shipyard/some/sibling.md`

### 2.5.0 — 2026-07-11
**The entry we are reconciling right now** (closes #700; PR #TBD). Prose about the target change. Files touched:
- `plugins/shipyard/commands/do-work/steady-state.md`
EOF
fixture="$(cat "$fixture_file")"

# Replicate the spec's anchored sed with the reconciled values substituted for
# the <N>/<M> template placeholders (issue #700, PR #698 — #698 is the LOWER
# entry's PR).
N=700
M=698
result=$(printf '%s' "$fixture" | sed "/closes #${N}[;) ]/ s/PR #TBD/PR #${M}/")

# The target entry (closes #700) must now carry the real PR number.
assert_contains "$result" \
  '(closes #700; PR #698)' \
  "anchored sed resolves the reconciled entry's placeholder → PR #698 (#700)"

# The sibling entry (closes #701) must STILL carry the untouched placeholder.
assert_contains "$result" \
  '(closes #701; PR #TBD)' \
  "anchored sed leaves the sibling entry's PR #TBD placeholder intact (#700)"

# The sibling entry must NOT have been mis-written with the reconciled PR number.
assert_not_contains "$result" \
  '(closes #701; PR #698)' \
  "anchored sed does NOT mis-write the reconciled PR number into the sibling entry (#700)"

# Sanity / control: the old un-anchored sed corrupts the SIBLING entry. Note the
# real sed semantics — `s/.../.../` WITHOUT `g` replaces the first match *per
# line*, and since each entry's placeholder sits on its own line, the un-anchored
# sed stamps the reconciled PR number onto EVERY pending entry, including the
# sibling that belongs to a different PR. That cross-entry clobber is the exact
# corruption #700 fixes; the anchored sed above touches only the #700 line.
buggy=$(printf '%s' "$fixture" | sed "s/PR #TBD/PR #${M}/")
assert_contains "$buggy" \
  '(closes #701; PR #698)' \
  "control: the old un-anchored sed wrongly stamps #698 onto the sibling entry (#700)"
assert_not_contains "$buggy" \
  '(closes #701; PR #TBD)' \
  "control: the old un-anchored sed does NOT leave the sibling's placeholder intact (#700)"

# Idempotency: re-running the anchored backfill for #700 against the already-
# resolved result is a no-op for #700, and the sibling stays untouched. This
# mirrors the `[ "$updated" != "$changelog_on_main" ]` guard's behavior.
rerun=$(printf '%s' "$result" | sed "/closes #${N}[;) ]/ s/PR #TBD/PR #${M}/")
if [[ "$rerun" == "$result" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" \
    "anchored sed is idempotent — re-running for #700 leaves the resolved file unchanged (#700)"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" \
    "anchored sed is idempotent — re-running for #700 leaves the resolved file unchanged (#700)"
  fail=$((fail+1))
fi

# A backfill run for #700 must not disturb a sibling whose entry has no #700
# match: resolving #700 when only #701 pends is a no-op on #701.
only_sibling=$(printf '%s' "$fixture" | sed "/closes #${N}[;) ]/ s/PR #TBD/PR #${M}/")
assert_contains "$only_sibling" \
  '(closes #701; PR #TBD)' \
  "backfill for #700 never resolves a non-matching sibling entry (#700)"

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
