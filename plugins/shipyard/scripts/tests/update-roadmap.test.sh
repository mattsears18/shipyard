#!/usr/bin/env bash
# Test: the shipyard:update-roadmap skill (issue #1240) — a port of
# mattsears18/lightwork's repo-local update-roadmap skill, generalized with
# the GitHub Projects v2 half dropped and dependency detection added.
#
# This is a structural/content regression suite, not a live-`gh` behavioral
# one — the skill is agent-executed prose+procedure (like dx-catalog,
# audit-rubrics, filing-github-issues), not a deterministic script, so there
# is no binary to exercise. It follows the same pattern as
# auditor-preamble.test.sh and milestones-config.test.sh: grep-based
# assertions that the skill file, its command wrapper, the worker-side
# prohibition fragment, the dont.md bullet, and the cross-referencing docs
# all exist and say what they're supposed to say.
#
# Covers:
#   - SKILL.md exists with frontmatter and every load-bearing section from
#     the issue body (gate, autonomy boundary, milestone-creation authority,
#     cold start, honesty checks, anti-WIP-limit, dependency detection,
#     no-roadmap-file, numbering contract, provenance note).
#   - The thin command wrapper exists, references the skill, documents
#     --dry-run and the milestones.enabled gate, and states the
#     orchestrator-only boundary.
#   - The worker-preamble milestone-prohibition fragment exists, is wired
#     into SKILL.md's on-demand fragments table, and states the filed-issue
#     inherited-milestone carve-out.
#   - commands/do-work/dont.md carries the worker-side prohibition bullet.
#   - CLAUDE.md and README.md cross-reference the new skill/command.
#   - do-work-rationale.md carries the #1240 design-decision writeup.
#
# Pure bash + grep — no network, no `gh`, no real repo.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/update-roadmap.test.sh

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

skill_path="$repo_root/plugins/shipyard/skills/update-roadmap/SKILL.md"
command_path="$repo_root/plugins/shipyard/commands/update-roadmap.md"
fragment_path="$repo_root/plugins/shipyard/skills/worker-preamble/milestone-prohibition.md"
preamble_skill_path="$repo_root/plugins/shipyard/skills/worker-preamble/SKILL.md"
dont_path="$repo_root/plugins/shipyard/commands/do-work/dont.md"
claude_md_path="$repo_root/CLAUDE.md"
readme_path="$repo_root/README.md"
rationale_path="$repo_root/docs/design/do-work-rationale.md"

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

assert_not_contains() {
  local file="$1" needle="$2" label="$3"
  if [[ ! -f "$file" ]]; then
    printf '  %sFAIL%s  %s — file missing: %s\n' "$RED" "$RESET" "$label" "$file"; fail=$((fail+1)); return
  fi
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    did NOT expect to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  fi
}

echo "shipyard:update-roadmap regression tests (issue #1240)"
echo

# --------------------------------------------------------------------------
echo "== SKILL.md exists with frontmatter"
# --------------------------------------------------------------------------

assert_file_exists "$skill_path" "skill file exists at plugins/shipyard/skills/update-roadmap/SKILL.md"
assert_contains "$skill_path" "name: update-roadmap" "skill frontmatter declares name: update-roadmap"
assert_contains "$skill_path" "description:" "skill frontmatter has a description field"

echo
echo "== Gate on milestones.enabled"

assert_contains "$skill_path" "milestones.enabled" "skill gates on milestones.enabled"
assert_contains "$skill_path" "milestones.fallback" "skill reads milestones.fallback"
# The skill must NOT read the other three consuming keys via
# shipyard-config.sh get — those belong to #1241 (prioritize_dispatch) /
# #1242 (assign_on_file) / #1243 (sweep_on_loop_end), which #1240 explicitly
# does not implement. A bare descriptive mention (e.g. noting that
# prioritize_dispatch is a future consumer of the milestones this skill
# assigns) is fine; an actual config read is not.
assert_not_contains "$skill_path" "get milestones.prioritize_dispatch" "skill does not read milestones.prioritize_dispatch (that's #1241's scope)"
assert_not_contains "$skill_path" "get milestones.assign_on_file" "skill does not read milestones.assign_on_file (that's #1242's scope)"
assert_not_contains "$skill_path" "get milestones.sweep_on_loop_end" "skill does not read milestones.sweep_on_loop_end (that's #1243's scope)"

echo
echo "== Load-bearing content sections from the issue body"

assert_contains "$skill_path" "## The autonomy boundary" "skill documents the autonomy boundary"
assert_contains "$skill_path" "Moving an issue that **already has** a milestone" "autonomy table names the propose-only already-milestoned case"
assert_contains "$skill_path" "## Milestone-creation authority" "skill documents the milestone-creation authority split"
assert_contains "$skill_path" "Cold start" "milestone-creation authority table names cold start"
assert_contains "$skill_path" "## Cold start" "skill documents the cold-start procedure"
assert_contains "$skill_path" "## Honesty checks" "skill documents the honesty checks"
assert_contains "$skill_path" "## The anti-WIP-limit rule" "skill documents the anti-WIP-limit rule"
assert_contains "$skill_path" "A phase full of P1s is the current phase" "anti-WIP-limit rule quotes the lightwork rationale"
assert_contains "$skill_path" "## Dependency detection" "skill documents dependency detection (issue #1240's added scope)"
assert_contains "$skill_path" "Blocked by #N" "dependency detection names the Blocked by #N hard gate"
assert_contains "$skill_path" "## No roadmap file, ever" "skill documents the no-roadmap-file rule"
assert_contains "$skill_path" "## Prove a check can fail before trusting it" "skill preserves the cautionary prove-a-check-can-fail note"
assert_contains "$skill_path" "## Who runs this" "skill documents who runs it (orchestrator-only)"
assert_contains "$skill_path" "Orchestrator-only" "skill states the orchestrator-only boundary"
assert_contains "$skill_path" "## Provenance note" "skill documents its provenance / source-unreachable fallback"

echo
echo "== Numbering contract matches the schema's fixed separator"

# U+00B7 MIDDLE DOT, one space each side — must match the schema's contract
# verbatim, not a lookalike character (e.g. a bullet '•' or hyphen '-').
assert_contains "$skill_path" "N · Title" "skill uses the schema's exact N · Title numbering convention"

echo
echo "== Cross-references the worker-side prohibition, not just states it locally"

assert_contains "$skill_path" "milestone-prohibition.md" "skill cross-references the worker-preamble milestone-prohibition fragment"

# --------------------------------------------------------------------------
echo
echo "== Command wrapper"
# --------------------------------------------------------------------------

assert_file_exists "$command_path" "command wrapper exists at plugins/shipyard/commands/update-roadmap.md"
assert_contains "$command_path" "shipyard:update-roadmap" "command references the skill by name"
assert_contains "$command_path" "skills/update-roadmap/SKILL.md" "command links to the skill file"
assert_contains "$command_path" "--dry-run" "command documents --dry-run"
assert_contains "$command_path" "milestones.enabled" "command gates on milestones.enabled"
assert_contains "$command_path" "Orchestrator-only" "command states the orchestrator-only boundary"
assert_contains "$command_path" "argument-hint:" "command has an argument-hint frontmatter field"

# --------------------------------------------------------------------------
echo
echo "== Worker-side prohibition fragment"
# --------------------------------------------------------------------------

assert_file_exists "$fragment_path" "milestone-prohibition.md fragment exists"
assert_contains "$fragment_path" "orchestrator-only" "fragment states the skill is orchestrator-only"
assert_contains "$fragment_path" "shipyard:update-roadmap" "fragment names the skill it protects"
assert_contains "$fragment_path" "parent issue's own existing milestone" "fragment documents the filed-issue inherited-milestone carve-out"
assert_contains "$fragment_path" "## Don't" "fragment has a Don't section"

echo
echo "== Fragment is wired into worker-preamble's on-demand fragments table"

assert_file_exists "$preamble_skill_path" "worker-preamble SKILL.md exists"
assert_contains "$preamble_skill_path" "milestone-prohibition.md" "worker-preamble's fragments table references milestone-prohibition.md"
assert_contains "$preamble_skill_path" "[#1240]" "worker-preamble's fragment row cites issue #1240"

# --------------------------------------------------------------------------
echo
echo "== commands/do-work/dont.md worker-side bullet"
# --------------------------------------------------------------------------

assert_file_exists "$dont_path" "do-work/dont.md exists"
assert_contains "$dont_path" "Don't touch a milestone from inside a dispatched worker's turn" "dont.md carries the worker-side milestone prohibition bullet"
assert_contains "$dont_path" "milestone-prohibition.md" "dont.md bullet links to the worker-preamble fragment"

# --------------------------------------------------------------------------
echo
echo "== CLAUDE.md and README.md cross-reference the new surface"
# --------------------------------------------------------------------------

assert_file_exists "$claude_md_path" "CLAUDE.md exists"
assert_contains "$claude_md_path" "/shipyard:update-roadmap" "CLAUDE.md mentions /shipyard:update-roadmap"
assert_contains "$claude_md_path" "milestone-prohibition.md" "CLAUDE.md cross-references the worker-side prohibition fragment"

assert_file_exists "$readme_path" "README.md exists"
assert_contains "$readme_path" "shipyard:update-roadmap" "README.md documents the /shipyard:update-roadmap command"
assert_contains "$readme_path" "commands/update-roadmap.md" "README.md links to the command file"

# --------------------------------------------------------------------------
echo
echo "== do-work-rationale.md design-decision writeup"
# --------------------------------------------------------------------------

assert_file_exists "$rationale_path" "do-work-rationale.md exists"
assert_contains "$rationale_path" "shipyard:update-roadmap\` skill" "RATIONALE has a shipyard:update-roadmap skill section"
assert_contains "$rationale_path" "issue #1240" "RATIONALE section cites issue #1240"
assert_contains "$rationale_path" "Source-unreachable fallback" "RATIONALE documents the source-unreachable fallback decision"

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
