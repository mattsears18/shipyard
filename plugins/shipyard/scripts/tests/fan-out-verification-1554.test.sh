#!/usr/bin/env bash
# Test: the fan-out verification contract is wired at both layers it needs
# to be wired at (issue #1554).
#
# Background — issue #1554: `shipyard:worker-preamble` and the per-mode
# worker specs were silent on a worker FANNING OUT to its own subagents
# inside its single worktree. Nothing forbade it, and for a genuinely wide
# mechanical change it is the right move — but when several subagents edit
# one worktree concurrently, each one's verification step observes the
# others' half-finished edits, and no rule told them how to tell that apart
# from a real failure in their own work.
#
# The repro (lightwork #4666 -> PR #4670, 2026-08-28) produced three bad
# outcomes from that one cause: cross-contaminated lint reports, a shared
# lint-cache clear performed on a peer's evidence, and — the dangerous one —
# a subagent that ran a full emulator-backed suite with no emulator, got
# 1,231 failures, and reported them as "pre-existing environmental noise…
# my report from before stands as final." The parent's own correctly-run
# suite had 1 real failure: a source-pinning test the change genuinely
# broke. Trusting that subagent's verdict would have shipped a regression.
#
# The asymmetry that makes this its own rule: a false RED is loud and merely
# costs turns. A false GREEN — or its usual dress, "those failures aren't
# mine" — is silent, and it is the first reasoning a subagent reaches for
# when a suite fails in files it does not recognise.
#
# The fix has two load-bearing layers, both asserted here:
#   1. The always-loaded core (skills/worker-preamble/SKILL.md): a short
#      section plus the fragment's index row. It has to be in the core,
#      not fragment-only, because the trigger is a DECISION the worker
#      makes rather than an error it hits — a worker that has decided to
#      fan out has no reason to go looking for a fragment about fan-out.
#   2. The fragment (skills/worker-preamble/fan-out-verification.md): the
#      repro, the implements-but-doesn't-gate contract, the shared-state
#      prohibitions, the external-services carve-out, the dispatch-prompt
#      template, and the when-not-to-fan-out guidance.
#
# Regression guard: if either layer regresses, a fanned-out subagent's
# whole-tree verdict silently becomes trustworthy again.
#
# Pure bash, no external dependencies. Run with:
#
#   plugins/shipyard/scripts/tests/fan-out-verification-1554.test.sh

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
fragment_path="$plugin_root/skills/worker-preamble/fan-out-verification.md"
skill_path="$plugin_root/skills/worker-preamble/SKILL.md"

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

echo "fan-out verification contract regression tests (issue #1554)"
echo

# ---------------------------------------------------------------------------
echo "-- Layer 1: the always-loaded core (SKILL.md)"
# ---------------------------------------------------------------------------
assert_file_exists "$skill_path" "skills/worker-preamble/SKILL.md exists"
if [[ -f "$skill_path" ]]; then
  assert_contains "$skill_path" "## Fan-out into your own worktree — verification does not delegate" \
    "core carries the fan-out section heading"
  assert_contains "$skill_path" "https://github.com/mattsears18/shipyard/issues/1554" \
    "core section links to the originating issue #1554"

  # The contract's one-sentence form. If this phrasing is lost, the rule has
  # been diluted into "be careful" — which is what #1554 found insufficient.
  assert_contains "$skill_path" "implements and reports; it does not gate" \
    "core states the implements-but-doesn't-gate contract"

  # The parent — not any subagent — owns the gates and the push decision.
  assert_contains "$skill_path" "run the authoritative gates once after every subagent returns" \
    "core assigns the authoritative gates to the parent, after fan-in"

  # Fan-out is explicitly NOT forbidden; a regression that turned this into a
  # blanket prohibition would be the wrong fix (the repro's fan-out was sound
  # and materially faster than serial).
  assert_contains "$skill_path" "is allowed, and right for a wide mechanical change" \
    "core preserves fan-out as allowed, not prohibited"

  # Discoverability: the fragment must be reachable BEFORE the prompts are
  # written, since the rules only bind subagents that were told them.
  assert_contains "$skill_path" "](./fan-out-verification.md)" \
    "core points at the fan-out-verification.md fragment"
  assert_contains "$skill_path" "**before** writing their prompts" \
    "core says to load the fragment before writing the dispatch prompts"

  # The fragment index table must carry a row, so a worker scanning the
  # index (rather than the prose) still finds it.
  assert_contains "$skill_path" "| [\`fan-out-verification.md\`](./fan-out-verification.md) |" \
    "on-demand fragment index has a fan-out-verification.md row"
fi

echo

# ---------------------------------------------------------------------------
echo "-- Layer 2: the fragment"
# ---------------------------------------------------------------------------
assert_file_exists "$fragment_path" "skills/worker-preamble/fan-out-verification.md exists"
if [[ -f "$fragment_path" ]]; then
  assert_contains "$fragment_path" "https://github.com/mattsears18/shipyard/issues/1554" \
    "fragment links to the originating issue #1554"

  # The mechanism: the preamble's peer-isolation rules assume ONE writer, and
  # fan-out breaks that assumption from the inside.
  assert_contains "$fragment_path" "exactly one writer" \
    "fragment names the one-writer assumption fan-out breaks"
  assert_contains "$fragment_path" "The verification does not partition" \
    "fragment states that verification does not partition even when files do"

  # The asymmetry is the reason this is a rule rather than a suggestion.
  assert_contains "$fragment_path" "asymmetric" \
    "fragment names the false-red/false-green asymmetry"
  assert_contains "$fragment_path" "those failures aren't mine" \
    "fragment names the specific unfalsifiable claim to refuse"

  # The repro must stay citable — #1554's evidence is a near-miss, not a
  # hypothetical, and the session id is what makes it auditable.
  assert_contains "$fragment_path" "session_01Hhpf4cMkHFRhbKhzjv9tF5" \
    "fragment cites the lightwork repro session id"
  assert_contains "$fragment_path" "1,231 failures" \
    "fragment keeps the confidently-wrong full-suite verdict (case 3)"

  # The seven-point contract's load-bearing clauses.
  assert_contains "$fragment_path" "implements and reports. It never gates" \
    "fragment states the implements-but-doesn't-gate rule"
  assert_contains "$fragment_path" "targeted* check scoped to its own files" \
    "fragment permits targeted self-scoped checks"
  assert_contains "$fragment_path" "must never report such a result as final" \
    "fragment forbids reporting a whole-tree result as final"
  assert_contains "$fragment_path" "The parent owns the git index" \
    "fragment assigns the shared git index to the parent"
  assert_contains "$fragment_path" "destructive shared-state actions on evidence it cannot attribute to itself" \
    "fragment forbids blind destructive shared-state actions"
  assert_contains "$fragment_path" "needs external services is not a check a fanned-out subagent should run at all" \
    "fragment carves out external-service-backed suites entirely"

  # A subagent's green must not be mistaken for the parent's §4.6 gate.
  assert_contains "$fragment_path" "never a substitute for §4.6" \
    "fragment states a subagent's green does not satisfy the pre-push unit gate"

  # The rules only bind subagents that were told them, so the fragment has to
  # hand the worker something to paste.
  assert_contains "$fragment_path" "## Put it in the dispatch prompt" \
    "fragment supplies a dispatch-prompt template section"

  # Fan-out stays available — the fragment governs conclusions, not existence.
  assert_contains "$fragment_path" "Fan-out is **not** forbidden" \
    "fragment preserves fan-out as a legitimate technique"
  assert_contains "$fragment_path" "## When NOT to fan out" \
    "fragment gives the when-not-to-fan-out guidance"
fi

echo
echo "-- results"
printf '  %d passed, %d failed\n' "$pass" "$fail"

if (( fail > 0 )); then
  exit 1
fi
exit 0
