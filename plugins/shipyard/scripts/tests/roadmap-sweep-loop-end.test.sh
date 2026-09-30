#!/usr/bin/env bash
# Test: the end-of-loop milestone roadmap sweep (issue #1243) — wires
# `shipyard:update-roadmap`'s Procedure steps 1-6 into /do-work's own
# end-of-session cleanup, gated on `milestones.enabled` AND
# `milestones.sweep_on_loop_end`, non-fatal, folded into the existing
# end-of-session summary instead of a second report, and skipped cleanly
# when the loop shipped and filed nothing.
#
# This is a structural/content regression suite, not a live-`gh` behavioral
# one — cleanup-summary.md / audit.md / dont.md / do-work-rationale.md are
# agent-executed prose+procedure (like update-roadmap.test.sh's own target),
# not deterministic scripts, so there is no binary to exercise. Same
# grep-based-assertion pattern as update-roadmap.test.sh and
# milestones-config.test.sh.
#
# Covers:
#   - cleanup-summary.md's step 8.5: gates on BOTH milestones.enabled and
#     milestones.sweep_on_loop_end, skips cleanly on shipped_count +
#     filed_count == 0, runs non-fatally, runs skill steps 1-6 and
#     explicitly skips the skill's own step 7 (no second report), and is
#     scoped to the orchestrator's own turn (never a dispatched worker).
#   - The end-of-session summary template + per-line rule carry a
#     `Roadmap sweep (#1243):` line that is omitted when the sweep didn't
#     run, and reports a failure without changing any other counter.
#   - audit.md records an explicit decision (not silence) about NOT
#     auto-wiring the same sweep, per the issue's final paragraph.
#   - do-work/dont.md carries the non-fatal / skip-on-noop prohibition
#     bullet for this feature.
#   - do-work-rationale.md carries the #1243 design-decision writeup.
#   - CLAUDE.md and README.md cross-reference the new consumer.
#   - The `milestones.sweep_on_loop_end` schema/config knob this step reads
#     already exists (regression guard — #1239 shipped it as scaffolding;
#     this suite fails loudly if a future change silently drops it out from
#     under this consumer).
#
# Pure bash + grep — no network, no `gh`, no real repo.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/roadmap-sweep-loop-end.test.sh

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

cleanup_summary_path="$repo_root/plugins/shipyard/commands/do-work/cleanup-summary.md"
audit_path="$repo_root/plugins/shipyard/commands/audit.md"
dont_path="$repo_root/plugins/shipyard/commands/do-work/dont.md"
rationale_path="$repo_root/docs/design/do-work-rationale.md"
claude_md_path="$repo_root/CLAUDE.md"
readme_path="$repo_root/README.md"
schema_path="$repo_root/plugins/shipyard/schemas/shipyard.config.schema.json"
config_sh_path="$repo_root/plugins/shipyard/scripts/shipyard-config.sh"

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
  if [[ ! -f "$file" ]]; then
    printf '  %sFAIL%s  %s — file missing: %s\n' "$RED" "$RESET" "$label" "$file"; fail=$((fail+1)); return
  fi
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

echo "End-of-loop milestone roadmap sweep regression tests (issue #1243)"
echo

# --------------------------------------------------------------------------
echo "== cleanup-summary.md step 8.5 exists and gates on BOTH keys"
# --------------------------------------------------------------------------

assert_file_exists "$cleanup_summary_path" "cleanup-summary.md exists"
assert_contains "$cleanup_summary_path" "Milestone roadmap sweep" "cleanup-summary.md has a milestone roadmap sweep step"
assert_contains "$cleanup_summary_path" "get milestones.enabled" "step reads milestones.enabled"
assert_contains "$cleanup_summary_path" "get milestones.sweep_on_loop_end" "step reads milestones.sweep_on_loop_end (not just enabled)"

echo
echo "== Skip-cleanly-on-no-op-loop condition"

assert_contains "$cleanup_summary_path" "shipped_count + filed_count == 0" "step skips when shipped_count + filed_count == 0"

echo
echo "== Non-fatal — never gates the loop or the summary"

assert_contains "$cleanup_summary_path" "Non-fatal" "step documents the non-fatal contract"
assert_contains "$cleanup_summary_path" "roadmap_sweep_error" "step tracks a roadmap_sweep_error variable for the catch-and-report path"
assert_contains "$cleanup_summary_path" "must NOT change the loop's exit status" "step states a sweep failure must not change the loop's exit status"

echo
echo "== Runs skill steps 1-6, explicitly skips the skill's own step 7 (no second report)"

assert_contains "$cleanup_summary_path" "skills/update-roadmap/SKILL.md" "step links to the shipyard:update-roadmap skill"
assert_contains "$cleanup_summary_path" "Skip the skill's own step 7" "step explicitly skips the skill's own step 7 (Report)"
assert_contains "$cleanup_summary_path" "second report" "step states the reason: avoid a second report describing the same run"

echo
echo "== Orchestrator-only, never a dispatched worker"

assert_contains "$cleanup_summary_path" "milestone-prohibition.md" "step cross-references the worker-side milestone prohibition"
assert_contains "$cleanup_summary_path" "orchestrator's own turn" "step states this runs in the orchestrator's own turn"

echo
echo "== End-of-session summary carries the Roadmap sweep line + per-line rule"

assert_contains "$cleanup_summary_path" "Roadmap sweep (#1243):" "summary template has a Roadmap sweep (#1243): line"
assert_contains "$cleanup_summary_path" "roadmap_sweep_ran == false" "per-line rule omits the line when roadmap_sweep_ran == false"
assert_contains "$cleanup_summary_path" "failed — <roadmap_sweep_error>" "per-line rule reports a sweep failure without hiding it"
assert_contains "$cleanup_summary_path" "never changes" "per-line rule states a failure never changes other counters"

# --------------------------------------------------------------------------
echo
echo "== audit.md records an explicit decision (not silence) per the issue's final paragraph"
# --------------------------------------------------------------------------

assert_file_exists "$audit_path" "audit.md exists"
assert_contains "$audit_path" "does NOT run the milestone roadmap sweep" "audit.md states it does not auto-run the sweep"
assert_contains "$audit_path" "operator" "audit.md assigns the follow-up sweep to the operator"
assert_contains "$audit_path" "#1243" "audit.md cites issue #1243"

# --------------------------------------------------------------------------
echo
echo "== commands/do-work/dont.md prohibition bullet"
# --------------------------------------------------------------------------

assert_file_exists "$dont_path" "do-work/dont.md exists"
assert_contains "$dont_path" "Don't let the end-of-loop roadmap sweep" "dont.md carries the non-fatal / skip-on-noop bullet"
assert_contains "$dont_path" "shipped_count + filed_count == 0" "dont.md bullet states the skip-on-noop condition"

# --------------------------------------------------------------------------
echo
echo "== do-work-rationale.md design-decision writeup"
# --------------------------------------------------------------------------

assert_file_exists "$rationale_path" "do-work-rationale.md exists"
assert_contains "$rationale_path" "End-of-loop milestone roadmap sweep" "RATIONALE has an end-of-loop milestone roadmap sweep section"
assert_contains "$rationale_path" "issue #1243" "RATIONALE section cites issue #1243"
assert_contains "$rationale_path" "start-of-session sweep" "RATIONALE explains why the start-of-session pass is out of scope here"
assert_contains "$rationale_path" "does NOT get the same auto-wired sweep" "RATIONALE explains the audit.md decision"

# --------------------------------------------------------------------------
echo
echo "== CLAUDE.md and README.md cross-reference the new consumer"
# --------------------------------------------------------------------------

assert_file_exists "$claude_md_path" "CLAUDE.md exists"
assert_contains "$claude_md_path" "sweep_on_loop_end\` (issue [#1243]" "CLAUDE.md documents sweep_on_loop_end as a consumer"
assert_contains "$claude_md_path" "cleanup-summary.md" "CLAUDE.md links to cleanup-summary.md"

assert_file_exists "$readme_path" "README.md exists"
assert_contains "$readme_path" "sweep_on_loop_end\` (issue #1243)" "README.md documents sweep_on_loop_end as a consumer"

# --------------------------------------------------------------------------
echo
echo "== Regression guard: the config knob this step reads already exists"
# --------------------------------------------------------------------------

assert_file_exists "$schema_path" "shipyard.config.schema.json exists"
assert_contains "$schema_path" "\"sweep_on_loop_end\"" "schema declares milestones.sweep_on_loop_end"

assert_file_exists "$config_sh_path" "shipyard-config.sh exists"
assert_contains "$config_sh_path" "\"sweep_on_loop_end\": true" "shipyard-config.sh built-in defaults include sweep_on_loop_end: true"

# --------------------------------------------------------------------------
echo
total=$((pass + fail))
if [[ $fail -eq 0 ]]; then
  printf '%sPASS%s  %d/%d assertions passed\n' "$GREEN" "$RESET" "$pass" "$total"
  exit 0
else
  printf '%sFAIL%s  %d/%d assertions failed\n' "$RED" "$RESET" "$fail" "$total"
  exit 1
fi
