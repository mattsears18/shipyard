#!/usr/bin/env bash
# Test: the CHANGELOG 'PR #TBD' backfill in steady-state.md A.1 anchors its sed
# substitution on the EXACT placeholder substring `closes #<N>; PR #TBD` — not a
# line-anchored first-'PR #TBD'-on-the-line match (#704), and not the first
# file-global 'PR #TBD' occurrence (#700).
#
# Background — three generations of the backfill sed:
#
#   1. #581 / #583 (file-global first occurrence):
#        updated=$(echo "$changelog_on_main" | sed "s/PR #TBD/PR #<M>/")
#      Without `g`, sed replaces the FIRST 'PR #TBD' per line. When two or more
#      release PRs merge in the same window, `main` carries multiple pending
#      'PR #TBD' entries at once (newest-first) — and the backfill for PR #<M>
#      stamps #<M> onto whichever entry is TOPMOST, which may belong to a
#      different PR, leaving the intended entry stranded at 'PR #TBD'.
#      (#700 repro: PR #692's 2.3.10 entry STAYED 'PR #TBD' because #693's
#      first-occurrence sed resolved a different topmost placeholder.)
#
#   2. #700 (line-anchored):
#        updated=$(echo "$changelog_on_main" | sed "/closes #<N>[;) ]/ s/PR #TBD/PR #<M>/")
#      Restricts the substitution to lines matching `closes #<N>`, fixing the
#      cross-entry mis-target. But sed still replaces the FIRST 'PR #TBD' on the
#      matched line — wrong when the entry's OWN summary prose mentions
#      'PR #TBD' BEFORE its '(closes #<N>; PR #TBD)' placeholder.
#      (#704 repro: release 2.5.1's entry is ABOUT the backfill bug, so its
#      title prose contained 'PR #TBD'; the line-anchored sed resolved that
#      prose mention and left the real placeholder unfilled — it took a second
#      corrective PR to actually resolve it.)
#
#   3. #704 (exact-substring — current):
#        updated=$(echo "$changelog_on_main" | sed "s/closes #<N>; PR #TBD/closes #<N>; PR #<M>/")
#      Matches the WHOLE placeholder substring `closes #<N>; PR #TBD`, so it
#      resolves only the placeholder, ignores every prose 'PR #TBD' on the same
#      line, targets the correct entry regardless of sibling placeholders, and
#      stays idempotent via the existing `updated != changelog_on_main` guard.
#      Both `<N>` and `<M>` are known at `shipped` reconcile time.
#
# This test has three layers:
#   1. Spec-coupling: assert steady-state.md actually uses the exact-substring
#      sed form (so this behavioral replica stays pinned to the shipped spec).
#   2. Behavioral (sibling case, #700): two pending 'PR #TBD' placeholders; run
#      the backfill for the LOWER entry's PR — assert ONLY that entry resolves.
#   3. Behavioral (meta-entry case, #704): an entry whose summary prose mentions
#      'PR #TBD' BEFORE its own '(closes #<N>; PR #TBD)' placeholder — assert the
#      exact-substring sed resolves ONLY the placeholder and leaves the prose
#      mention untouched, and that the old line-anchored sed mis-targets it.
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

assert_file_not_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    did NOT expect to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  fi
}

echo "CHANGELOG backfill exact-substring-anchor regression tests (issues #700, #704)"
echo

# ── Layer 1: spec-coupling ──────────────────────────────────────────────────
# The behavioral replicas below only prove the fix if the shipped spec actually
# uses the exact-substring-anchored sed. Pin that here so the two stay coupled.
assert_file_contains "$steady_state_path" \
  'sed "s/closes #<N>; PR #TBD/closes #<N>; PR #<M>/"' \
  "steady-state.md uses the exact-substring-anchored sed (closes #<N>; PR #TBD), not a line-anchored or file-global replace (#704)"

# The superseded line-anchored form must be gone from the executable sed (the
# only remaining mentions are historical narrative describing what it fixed).
# Anchor the needle on the `| sed` pipe so it matches ONLY the executable line,
# not the prose/comment references (which cite the sed inside backticks).
assert_file_not_contains "$steady_state_path" \
  '| sed "/closes #<N>[;) ]/ s/PR #TBD/PR #<M>/"' \
  "steady-state.md no longer runs the superseded line-anchored sed (#704)"

# ── Layer 2: behavioral (sibling case, #700) ────────────────────────────────
# Two-entry CHANGELOG with two pending 'PR #TBD' placeholders, newest-first.
# The TOPMOST entry (closes #701) is a sibling; the LOWER entry (closes #700) is
# the one we reconcile. A file-global first-occurrence sed would wrongly resolve
# the sibling; the exact-substring sed must resolve ONLY #700.
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

# Replicate the spec's exact-substring sed with the reconciled values substituted
# for the <N>/<M> template placeholders (issue #700, PR #698 — #698 is the LOWER
# entry's PR).
N=700
M=698
result=$(printf '%s' "$fixture" | sed "s/closes #${N}; PR #TBD/closes #${N}; PR #${M}/")

# The target entry (closes #700) must now carry the real PR number.
assert_contains "$result" \
  '(closes #700; PR #698)' \
  "exact-substring sed resolves the reconciled entry's placeholder → PR #698 (#700)"

# The sibling entry (closes #701) must STILL carry the untouched placeholder.
assert_contains "$result" \
  '(closes #701; PR #TBD)' \
  "exact-substring sed leaves the sibling entry's PR #TBD placeholder intact (#700)"

# The sibling entry must NOT have been mis-written with the reconciled PR number.
assert_not_contains "$result" \
  '(closes #701; PR #698)' \
  "exact-substring sed does NOT mis-write the reconciled PR number into the sibling entry (#700)"

# Sanity / control: the old un-anchored file-global sed corrupts the SIBLING
# entry. `s/.../.../` WITHOUT `g` replaces the first match *per line*, and since
# each entry's placeholder sits on its own line, the un-anchored sed stamps the
# reconciled PR number onto EVERY pending entry, including the sibling that
# belongs to a different PR. That cross-entry clobber is the exact corruption
# #700 fixed.
buggy=$(printf '%s' "$fixture" | sed "s/PR #TBD/PR #${M}/")
assert_contains "$buggy" \
  '(closes #701; PR #698)' \
  "control: the old file-global sed wrongly stamps #698 onto the sibling entry (#700)"
assert_not_contains "$buggy" \
  '(closes #701; PR #TBD)' \
  "control: the old file-global sed does NOT leave the sibling's placeholder intact (#700)"

# Idempotency: re-running the exact-substring backfill for #700 against the
# already-resolved result is a no-op. This mirrors the
# `[ "$updated" != "$changelog_on_main" ]` guard's behavior.
rerun=$(printf '%s' "$result" | sed "s/closes #${N}; PR #TBD/closes #${N}; PR #${M}/")
if [[ "$rerun" == "$result" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" \
    "exact-substring sed is idempotent — re-running for #700 leaves the resolved file unchanged (#700)"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" \
    "exact-substring sed is idempotent — re-running for #700 leaves the resolved file unchanged (#700)"
  fail=$((fail+1))
fi

# ── Layer 3: behavioral (meta-entry case, #704) ─────────────────────────────
# The regression this PR closes: an entry whose OWN summary prose mentions
# 'PR #TBD' BEFORE its '(closes #<N>; PR #TBD)' placeholder. This is the shape of
# a CHANGELOG entry that is itself ABOUT the backfill machinery (the #704 repro
# was release 2.5.1's entry describing the #700 fix).
#
# The prose mention sits to the LEFT of the placeholder on the same line, so the
# superseded line-anchored sed replaces the PROSE 'PR #TBD' (first on the line)
# and leaves the real placeholder unfilled. The exact-substring sed must resolve
# ONLY the placeholder and leave every prose mention intact.
meta_fixture_file="$(mktemp -t changelog-meta-fixture.XXXXXX)"
trap 'rm -f "$fixture_file" "$meta_fixture_file"' EXIT
cat > "$meta_fixture_file" <<'EOF'
## shipyard

### 2.5.2 — 2026-07-11
**Harden the A.1 CHANGELOG PR #TBD backfill to an exact-substring anchor** (closes #704; PR #TBD). The line-anchored sed still resolved the first PR #TBD on the line — a prose mention — instead of the placeholder. Files touched:
- `plugins/shipyard/commands/do-work/steady-state.md`
EOF
meta_fixture="$(cat "$meta_fixture_file")"

MN=704
MM=705

# The exact-substring sed for #704.
meta_result=$(printf '%s' "$meta_fixture" | sed "s/closes #${MN}; PR #TBD/closes #${MN}; PR #${MM}/")

# The placeholder resolves to the real PR number.
assert_contains "$meta_result" \
  '(closes #704; PR #705)' \
  "exact-substring sed resolves the meta-entry's OWN placeholder → PR #705 (#704)"

# The prose 'PR #TBD' mention BEFORE the placeholder is left untouched.
assert_contains "$meta_result" \
  'Harden the A.1 CHANGELOG PR #TBD backfill' \
  "exact-substring sed leaves the meta-entry's prose PR #TBD mention untouched (#704)"

# No stray 'PR #TBD' placeholder remains where the real placeholder was.
assert_not_contains "$meta_result" \
  '(closes #704; PR #TBD)' \
  "exact-substring sed leaves NO unresolved placeholder on the meta-entry (#704)"

# Control: the superseded line-anchored sed MIS-TARGETS the meta-entry — it
# resolves the PROSE mention (first PR #TBD on the line) and strands the real
# placeholder. This is precisely the #704 bug.
meta_buggy=$(printf '%s' "$meta_fixture" | sed "/closes #${MN}[;) ]/ s/PR #TBD/PR #${MM}/")
assert_contains "$meta_buggy" \
  'Harden the A.1 CHANGELOG PR #705 backfill' \
  "control: the old line-anchored sed wrongly resolves the meta-entry's PROSE mention (#704)"
assert_contains "$meta_buggy" \
  '(closes #704; PR #TBD)' \
  "control: the old line-anchored sed strands the meta-entry's real placeholder at PR #TBD (#704)"

# Idempotency on the meta-entry: a second exact-substring run is a no-op.
meta_rerun=$(printf '%s' "$meta_result" | sed "s/closes #${MN}; PR #TBD/closes #${MN}; PR #${MM}/")
if [[ "$meta_rerun" == "$meta_result" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" \
    "exact-substring sed is idempotent on the meta-entry — re-running for #704 is a no-op (#704)"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" \
    "exact-substring sed is idempotent on the meta-entry — re-running for #704 is a no-op (#704)"
  fail=$((fail+1))
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
