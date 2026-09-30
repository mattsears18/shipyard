#!/usr/bin/env bash
# Test: the mode-shim-preamble skill exists and every /shipyard:do-work
# mode-shim agent (shipyard:issue-worker plus its six per-mode siblings)
# references it instead of re-inlining the same worktree-isolation-contract
# and mode-to-model-mapping boilerplate, while each agent keeps its own
# dispatchable identity (frontmatter name/model) and mode-specific content.
#
# Background — issue #879: the 7 per-mode worker shim agents
# (agents/issue-worker.md, agents/{fix-checks,fix-rebase,fix-main-ci,
# fix-pr-batch,investigate,spike}-worker.md) each re-inlined the same
# ~15-20 lines of "Worktree isolation contract" and "Why a separate shim
# file" boilerplate verbatim. This test is the regression guard: if anyone
# deletes the mode-shim-preamble skill, drops a shim's reference to it,
# re-duplicates the generic dispatch-shape paragraph, or accidentally strips
# a shim's frontmatter identity while doing so, the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/mode-shim-preamble.test.sh

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

skill_path="$repo_root/plugins/shipyard/skills/mode-shim-preamble/SKILL.md"
agents_dir="$repo_root/plugins/shipyard/agents"

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
    printf '    expected to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

assert_not_contains() {
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

echo "mode-shim-preamble regression tests (issue #879)"
echo

# --- The 7 mode-shim agent files this refactor touches. ---
# Format: "<file>:<expected frontmatter name>:<expected model, or empty for none>"
shims=(
  "issue-worker.md:issue-worker:opus"
  "fix-checks-worker.md:fix-checks-worker:opus"
  "fix-main-ci-worker.md:fix-main-ci-worker:opus"
  "fix-pr-batch-worker.md:fix-pr-batch-worker:opus"
  "fix-rebase-worker.md:fix-rebase-worker:opus"
  "investigate-worker.md:investigate-worker:opus"
  "spike-worker.md:spike-worker:opus"
)

# (1) The skill file itself exists with proper frontmatter and documents the
# scaffold it owns.
assert_file_exists "$skill_path" "mode-shim-preamble skill file exists"

if [[ -f "$skill_path" ]]; then
  assert_contains "$skill_path" "name: mode-shim-preamble" \
    "skill frontmatter declares name: mode-shim-preamble"
  assert_contains "$skill_path" "description:" \
    "skill frontmatter has a description field"
  assert_contains "$skill_path" "Worktree isolation — declared, not policed" \
    "skill documents that isolation comes from agent frontmatter"
  assert_contains "$skill_path" "Shared worker-preamble bullets" \
    "skill documents the shared worker-preamble bullet list"
  assert_contains "$skill_path" "Mode → shim mapping" \
    "skill documents the mode-to-shim mapping table"
  assert_contains "$skill_path" "shipyard:worker-preamble" \
    "skill cross-references worker-preamble"
  # Frontmatter identity is explicitly out of scope for this skill — it must
  # never be the thing consolidated, since each shim is a dispatchable
  # subagent_type keyed on its own frontmatter.
  assert_contains "$skill_path" "Never move this into a skill" \
    "skill explicitly disclaims owning agent frontmatter identity"
  # Every shim's model should appear in the mapping table so the table can't
  # silently drift from the frontmatter it's meant to summarize.
  for entry in "${shims[@]}"; do
    IFS=':' read -r file expected_name expected_model <<< "$entry"
    assert_contains "$skill_path" "shipyard:$expected_name" \
      "skill's mapping table references shipyard:$expected_name"
  done
fi

echo

# (2) Every mode-shim agent file references the shared skill by name, keeps
# its own frontmatter identity (name + model where expected), and no longer
# re-duplicates the generic two-dispatch-shape paragraph this refactor
# extracted.
for entry in "${shims[@]}"; do
  IFS=':' read -r file expected_name expected_model <<< "$entry"
  path="$agents_dir/$file"

  assert_file_exists "$path" "$file exists"
  [[ -f "$path" ]] || continue

  assert_contains "$path" "shipyard:mode-shim-preamble" \
    "$file references the shipyard:mode-shim-preamble skill"
  assert_contains "$path" "name: $expected_name" \
    "$file keeps its own frontmatter name: $expected_name"
  assert_contains "$path" "description:" \
    "$file keeps its own frontmatter description"

  if [[ -n "$expected_model" ]]; then
    assert_contains "$path" "model: $expected_model" \
      "$file keeps its own frontmatter model: $expected_model pin"
  else
    if grep -qE '^model:' "$path" 2>/dev/null; then
      printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$file carries no model: frontmatter (inherits session default)"
      fail=$((fail+1))
    else
      printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$file carries no model: frontmatter (inherits session default)"
      pass=$((pass+1))
    fi
  fi

  # Regression guard: the fully-duplicated dispatch-shape sentence this
  # refactor extracted into the skill must not be re-inlined verbatim.
  assert_not_contains "$path" "this shim was briefly not a dispatch target" \
    "$file does not re-duplicate the generic dispatch-shape history paragraph"

  # Each shim still names its own subagent_type explicitly somewhere in the
  # Worktree isolation contract section (the one piece of that section that
  # IS genuinely per-file, so the skill's generic paragraph doesn't erase
  # which shim is which).
  assert_contains "$path" "shipyard:$expected_name" \
    "$file names its own subagent_type shipyard:$expected_name"
done

echo

# (2.5) The router's mode-routing table and each shim's per-mode-spec pointer
# are untouched by this refactor — these are genuinely load-bearing,
# mode-specific content, not boilerplate.
router_path="$agents_dir/issue-worker.md"
assert_contains "$router_path" "## Mode routing" \
  "issue-worker.md keeps its Mode routing table"
assert_contains "$router_path" "issue-worker/spike.md" \
  "issue-worker.md's routing table still references issue-worker/spike.md"

echo

# (3) Every shim declares isolation: worktree in its own frontmatter. Claude
# Code reads that field and provisions, cwd-pins, and contains the subagent
# itself — this replaced the former enforce-worktree-isolation.sh PreToolUse
# hook, whose whole premise (agent frontmatter has no isolation field, so the
# caller must pass it) stopped being true.
for entry in "${shims[@]}"; do
  IFS=':' read -r file expected_name expected_model <<< "$entry"
  assert_contains "$agents_dir/$file" "isolation: worktree" \
    "$file declares isolation: worktree in frontmatter"
done

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
