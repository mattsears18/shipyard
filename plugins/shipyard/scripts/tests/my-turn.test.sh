#!/usr/bin/env bash
# Test: the /shipyard:my-turn command file exists with proper frontmatter and
# covers every required survey dimension from issue #142.
#
# Background — issue #142: `/shipyard:do-work` handles agent-driven work; the
# user needed a human-driven counterpart that scans open PRs + issues +
# comments and prints a prioritized list of items genuinely blocked on the
# user (not on Claude). Before this command, the user discovered those items
# by manually browsing — `/shipyard:my-turn` collapses that into one
# read-only command.
#
# This test is the regression guard: if anyone deletes the command, removes
# the priority tiers, drops a required input source, or strips the
# advisory-only contract (v1 must not mutate state), the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/my-turn.test.sh

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

cmd_path="$repo_root/plugins/shipyard/commands/my-turn.md"

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
  # Case-insensitive: spec headings often capitalize at sentence start ("Draft
  # PRs stale >7 days"), but the regression invariant is presence of the
  # concept, not exact case.
  if grep -qiF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

echo "my-turn command regression tests (issue #142)"
echo

# (1) Command file must exist with proper YAML frontmatter.
assert_file_exists "$cmd_path" "commands/my-turn.md exists"

if [[ -f "$cmd_path" ]]; then
  # Frontmatter must declare a description so /help can surface the command.
  assert_contains "$cmd_path" "description:" \
    "command frontmatter has a description field"

  # argument-hint documents the optional --repo flag for autocomplete.
  assert_contains "$cmd_path" "argument-hint:" \
    "command frontmatter has an argument-hint field"

  # Optional --repo flag follows the convention from /do-work and /audit.
  assert_contains "$cmd_path" "--repo" \
    "command accepts an optional --repo flag"

  # The three priority tiers from issue #142 must be enumerated. These are
  # the contract that drives the ranked output the user reads.
  assert_contains "$cmd_path" "P0" \
    "command defines a P0 tier (blocking other work)"
  assert_contains "$cmd_path" "P1" \
    "command defines a P1 tier (decisions)"
  assert_contains "$cmd_path" "P2" \
    "command defines a P2 tier (housekeeping)"

  # Input sources from issue #142's "Inputs the command pulls from" section.
  # Grep by anchor phrases so the author has wording leeway.
  assert_contains "$cmd_path" "gh pr list" \
    "command pulls open PRs via gh pr list"
  assert_contains "$cmd_path" "gh issue list" \
    "command pulls open issues via gh issue list"
  assert_contains "$cmd_path" "review" \
    "command covers PR review state"
  assert_contains "$cmd_path" "blocked:ci" \
    "command surfaces blocked:ci PRs"
  assert_contains "$cmd_path" "needs-human-review" \
    "command surfaces needs-human-review-labeled issues"
  assert_contains "$cmd_path" "needs-refinement" \
    "command surfaces needs-refinement-labeled issues"
  assert_contains "$cmd_path" "draft" \
    "command surfaces stale draft PRs"

  # Advisory-only contract (v1). This is the load-bearing distinction from
  # /do-work — the new command MUST NOT mutate state. Forbid the obvious
  # mutation commands in the spec body.
  assert_contains "$cmd_path" "advisory" \
    "command declares advisory-only contract"
  assert_contains "$cmd_path" "read-only" \
    "command declares read-only contract"

  # Don't section is a common convention across shipyard commands — keeps
  # non-goals explicit.
  assert_contains "$cmd_path" "Don't" \
    "command has a Don't section to scope non-goals"

  # Cross-reference to /shipyard:do-work as the agent-driven counterpart.
  # The pairing is the whole point of placing this in the shipyard plugin.
  assert_contains "$cmd_path" "do-work" \
    "command cross-references /shipyard:do-work"

  # Output must include URLs (so the items are clickable) and ages (so the
  # user can see what's been waiting longest).
  assert_contains "$cmd_path" "URL" \
    "command output includes per-item URLs"
  assert_contains "$cmd_path" "age" \
    "command output includes per-item age"

  # Single-action default (issue #391): the command must lead with the single
  # next action, not a full ranked list. The default render is the #1-ranked
  # item as a "→ Next:" directive; the full list is opt-in via --all.
  assert_contains "$cmd_path" "→ Next:" \
    "command renders the top item as a → Next: directive (single-action mode)"
  assert_contains "$cmd_path" "--all" \
    "command accepts an --all flag to render the full ranked list"
  assert_contains "$cmd_path" "single-action mode" \
    "command documents the single-action default render mode"
  assert_contains "$cmd_path" "list mode" \
    "command documents the opt-in list render mode"
  # The empty-state one-liner is explicitly unchanged by the single-action
  # refinement — it's identical across modes.
  assert_contains "$cmd_path" "Nothing on your plate" \
    "command keeps the unchanged empty-state one-liner"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
