#!/usr/bin/env bash
# Test: the /shipyard:refine-issues command file detects refinement
# candidates by a live source-signal scan (no persisted needs-refinement
# label) with the three-branch source-branched refiner semantics, and
# do-work.md / setup.md / CLAUDE.md / README.md / my-turn.md all reference
# the post-#520 elimination consistently.
#
# Binary-backlog phase 2 (#520) eliminated the `needs-refinement` label.
# `/refine-issues` now scans every open issue for a source signal
# (`user-feedback` label / `## Open questions` heading / bot author) and
# branches: classify+rewrite (user-feedback), resolve-defaults (open
# questions), fall-through (no recognizable pattern → needs-human-review).
# The intake-refinement-gate.yml workflow was retired. The fall-through
# home is needs-human-review (interim), NOT needs-triage.
#
# This test is the regression guard: if anyone re-introduces the
# needs-refinement label, restores the intake gate workflow, drops a branch
# from the source-branched refiner, or routes the fall-through back to
# needs-triage, the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/refine-issues.test.sh

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

cmd_path="$repo_root/plugins/shipyard/commands/refine-issues.md"
intake_workflow_path="$repo_root/.github/workflows/intake-refinement-gate.yml"
external_gate_path="$repo_root/.github/workflows/external-author-gate.yml"
do_work_path="$repo_root/plugins/shipyard/commands/do-work.md"
# After the issue #154 split, the do-work spec lives across an entry-router
# + 5 per-phase files. Refinement-related content (step 2 bucketing, step 3a
# label setup, step 3.5 refine invocation) lives in the setup phase file.
# #611 split setup.md into a thin router + step-cluster sub-files under
# do-work/setup/, so the step-3/3.5/4 content this test greps now lives in
# the sub-files. Point do_work_setup_path at a concatenation of the router +
# every sub-file (the assert_file_exists below still checks the router).
do_work_setup_router="$repo_root/plugins/shipyard/commands/do-work/setup.md"
do_work_setup_dir="$repo_root/plugins/shipyard/commands/do-work/setup"
do_work_setup_path="$(mktemp -t refine-issues-setup-concat.XXXXXX)"
cat "$do_work_setup_router" "$do_work_setup_dir"/*.md > "$do_work_setup_path" 2>/dev/null
trap 'rm -f "$do_work_setup_path"' EXIT
my_turn_path="$repo_root/plugins/shipyard/commands/my-turn.md"
claude_md_path="$repo_root/CLAUDE.md"
readme_path="$repo_root/README.md"

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

assert_file_absent() {
  local path="$1"
  local label="$2"
  if [[ ! -e "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (still present: %s)\n' "$RED" "$RESET" "$label" "$path"
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
    printf '    expected to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if ! grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    forbidden but found in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

echo "refine-issues / signal-scan regression tests (#520)"
echo

# (1) Command file exists with proper frontmatter.
assert_file_exists "$cmd_path" "commands/refine-issues.md exists"

if [[ -f "$cmd_path" ]]; then
  assert_contains "$cmd_path" "description:" \
    "refine-issues frontmatter has a description field"
  assert_contains "$cmd_path" "argument-hint:" \
    "refine-issues frontmatter has an argument-hint field"
  assert_contains "$cmd_path" "--repo" \
    "refine-issues accepts the --repo flag (matches /do-work convention)"
  assert_contains "$cmd_path" "--dry-run" \
    "refine-issues accepts the --dry-run flag"

  # The three source-branched paths. Every branch must be present, named
  # consistently with the spec.
  assert_contains "$cmd_path" "classify+rewrite" \
    "refine-issues declares the classify+rewrite branch (user-feedback)"
  assert_contains "$cmd_path" "resolve-defaults" \
    "refine-issues declares the resolve-defaults branch (open questions)"
  assert_contains "$cmd_path" "fall-through" \
    "refine-issues declares the fall-through branch (no recognizable pattern)"

  # #520: candidate detection is by LIVE SOURCE-SIGNAL SCAN, not a label
  # fetch. The candidate query must NOT issue a `gh issue list ... --label
  # needs-refinement` fetch. (Negation prose like "no --label
  # needs-refinement filter" is fine — we check the actual command shape:
  # a gh issue list invocation that filters on the eliminated label.)
  assert_contains "$cmd_path" "source signal" \
    "refine-issues detects candidates by source signal (#520)"
  if grep -E 'gh issue list' "$cmd_path" | grep -q -- '--label needs-refinement'; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" \
      "refine-issues no longer fetches candidates via gh issue list --label needs-refinement (#520)"
    fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" \
      "refine-issues no longer fetches candidates via gh issue list --label needs-refinement (#520)"
    pass=$((pass+1))
  fi

  # The scan keys on the three live signals.
  assert_contains "$cmd_path" "Open [qQ]uestions" \
    "refine-issues scan detects the '## Open questions' heading signal"
  assert_contains "$cmd_path" "user-feedback" \
    "refine-issues scan keys on the user-feedback label signal"
  assert_contains "$cmd_path" 'Bot' \
    "refine-issues scan keys on the bot-author signal"

  # #520: the fall-through home is needs-human-review, NOT needs-triage.
  assert_contains "$cmd_path" "needs-human-review" \
    "fall-through branch lands the no-pattern subset on needs-human-review (#520)"
  assert_contains "$cmd_path" "escalated-to-human-review" \
    "fall-through return string is refined: escalated-to-human-review (#520)"
  # The interim-fall-through reasoning must be present (only the
  # no-automated-path subset goes to the human queue, never auto-processable
  # work).
  assert_contains "$cmd_path" "no-automated-path" \
    "refine-issues documents that only the no-automated-path subset escalates (#520)"

  # Resolve-defaults must NOT apply needs-human-review (the decoupling
  # invariant). Search for the spec line that explicitly forbids it.
  assert_contains "$cmd_path" "Do NOT apply" \
    "refine-issues forbids applying needs-human-review from resolve-defaults"

  # Sentinel discipline — every branch's comments must start with the
  # idempotency sentinel (now the primary re-processing guard with no label
  # to remove).
  assert_contains "$cmd_path" "<!-- do-work-refinement-agent -->" \
    "refine-issues preserves the sentinel comment for idempotency"

  # Untrusted-input discipline applies to ALL three branches.
  assert_contains "$cmd_path" "untrusted" \
    "refine-issues declares the untrusted-input discipline"

  # Don't section is the standard shipyard command convention.
  assert_contains "$cmd_path" "Don't" \
    "refine-issues has a Don't section to scope non-goals"

  # The elimination must be documented with the #520 reference.
  assert_contains "$cmd_path" "520" \
    "refine-issues cites #520 as the source of the needs-refinement elimination"

  # The candidate-selection must not create or apply the needs-refinement
  # label (a historical MENTION of the retired gate is fine).
  assert_not_contains "$cmd_path" "gh label create needs-refinement" \
    "refine-issues no longer creates the needs-refinement label (#520)"
  assert_not_contains "$cmd_path" "--remove-label needs-refinement" \
    "refine-issues no longer removes the needs-refinement label (no label to remove) (#520)"
fi

# (2) The intake-refinement-gate.yml workflow must be GONE (#520).
assert_file_absent "$intake_workflow_path" \
  ".github/workflows/intake-refinement-gate.yml retired (#520)"

# The separate security gate stays untouched.
assert_file_exists "$external_gate_path" \
  ".github/workflows/external-author-gate.yml still present (separate security gate)"

# (3) do-work spec — the entry exists, and the setup phase carries the
# refinement-related steps (step 2 bucketing, step 3a label setup, step 3.5
# refine invocation). These steps live in commands/do-work/setup.md rather
# than in the thin entry.
assert_file_exists "$do_work_path" "commands/do-work.md exists (thin entry)"
assert_file_exists "$do_work_setup_router" "commands/do-work/setup.md exists (thin router)"
if [[ -f "$do_work_setup_path" ]]; then
  # Step 3.5 must still invoke /refine-issues.
  assert_contains "$do_work_setup_path" "/refine-issues" \
    "do-work/setup.md step 3.5 invokes /refine-issues"

  # #520: the step-4 client-side dispatch-gate filter line must no longer
  # ENUMERATE needs-refinement as an active backtick-quoted gate label. The
  # line may still MENTION the elimination in prose ("needs-refinement was
  # eliminated entirely"), so we check the active enumeration form
  # specifically: the backtick-comma sequence `needs-refinement`, that only
  # appears inside the comma-separated active label list, never in prose.
  # shellcheck disable=SC2016  # literal backticks in the grep pattern are intentional (matching markdown)
  if grep -E 'Drop issues carrying any of the dispatch-gate labels' "$do_work_setup_path" \
       | grep -qF '`needs-refinement`,'; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" \
      "do-work/setup.md step 4 dispatch-gate list no longer enumerates needs-refinement (#520)"
    fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" \
      "do-work/setup.md step 4 dispatch-gate list no longer enumerates needs-refinement (#520)"
    pass=$((pass+1))
  fi

  # The setup label-create block must no longer create needs-refinement.
  assert_not_contains "$do_work_setup_path" "gh label create needs-refinement" \
    "do-work/setup.md no longer creates the needs-refinement label (#520)"

  # Step 3.5 prose must reflect the signal-scan, not a label fetch.
  assert_contains "$do_work_setup_path" "source signal" \
    "do-work/setup.md step 3.5 describes the source-signal scan (#520)"

  # needs-human-review label-create must still be in the setup block.
  assert_contains "$do_work_setup_path" "gh label create needs-human-review" \
    "do-work/setup.md still creates the needs-human-review label"
fi

# (4) my-turn.md — still references /shipyard:refine-issues, and reframes a
# stale needs-refinement label as a housekeeping nudge (the label object is
# left for manual cleanup).
assert_file_exists "$my_turn_path" "commands/my-turn.md exists"
if [[ -f "$my_turn_path" ]]; then
  assert_contains "$my_turn_path" "/shipyard:refine-issues" \
    "my-turn.md references /shipyard:refine-issues"
  assert_contains "$my_turn_path" "520" \
    "my-turn.md reframes the needs-refinement signal as a stale-label nudge (#520)"
fi

# (5) CLAUDE.md — documents the needs-refinement elimination.
assert_file_exists "$claude_md_path" "CLAUDE.md exists"
if [[ -f "$claude_md_path" ]]; then
  assert_contains "$claude_md_path" "eliminated" \
    "CLAUDE.md documents the needs-refinement elimination"
  assert_contains "$claude_md_path" "source-signal scan" \
    "CLAUDE.md documents the source-signal scan replacement"
  assert_contains "$claude_md_path" "520" \
    "CLAUDE.md cites #520 for the elimination"
fi

# (6) README.md — slash command list mentions /refine-issues, and no longer
# references an intake gate workflow applying needs-refinement.
assert_file_exists "$readme_path" "README.md exists"
if [[ -f "$readme_path" ]]; then
  assert_contains "$readme_path" "/refine-issues" \
    "README.md slash-command list mentions /refine-issues"
  assert_contains "$readme_path" "refine-issues.md" \
    "README.md repo layout lists refine-issues.md"
  assert_not_contains "$readme_path" "intake-refinement-gate.yml" \
    "README.md no longer references the retired intake-refinement-gate.yml (#520)"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
