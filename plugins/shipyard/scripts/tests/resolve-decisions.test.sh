#!/usr/bin/env bash
# Test: the /shipyard:resolve-decisions command file exists with proper
# frontmatter and covers the decision-walkthrough + record-and-unblock
# contract from issue #566.
#
# Background — issue #566: when /my-turn's single next action is "answer the N
# blocking decisions on issue #X" (a decision-gated needs-human-review issue),
# the maintainer wanted to interactively walk those decisions one at a time —
# each with context, options, and a concrete recommendation+reasoning — then
# record the answers and clear the gate so /do-work can pick it up. The
# maintainer-author recommended design (a): keep /my-turn read-only and put the
# walkthrough + mutation in a dedicated sibling command (/resolve-decisions),
# rather than carving a mutation exception into /my-turn. This command is that
# sibling.
#
# This test is the regression guard: if anyone deletes the command, drops the
# 5-part per-decision walkthrough, strips the recommendation requirement,
# removes the record-and-unblock mutation, or loses the read-only-/my-turn
# boundary, the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/resolve-decisions.test.sh

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

cmd_path="$repo_root/plugins/shipyard/commands/resolve-decisions.md"
myturn_path="$repo_root/plugins/shipyard/commands/my-turn.md"

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
  if grep -qiF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

echo "resolve-decisions command regression tests (issue #566)"
echo

# (1) Command file must exist with proper YAML frontmatter.
assert_file_exists "$cmd_path" "commands/resolve-decisions.md exists"

if [[ -f "$cmd_path" ]]; then
  # Frontmatter — description + argument-hint so /help and autocomplete work.
  assert_contains "$cmd_path" "description:" \
    "command frontmatter has a description field"
  assert_contains "$cmd_path" "argument-hint:" \
    "command frontmatter has an argument-hint field"
  assert_contains "$cmd_path" "--repo" \
    "command accepts an optional --repo flag"
  assert_contains "$cmd_path" "--issue" \
    "command accepts an optional --issue flag"
  assert_contains "$cmd_path" "--dry-run" \
    "command accepts a --dry-run flag (preview without mutating)"

  # Trigger surface: a decision-gated needs-human-review issue with answerable
  # blocking decisions. Must NOT walk non-decision gates (epic-decomposition,
  # external-dependency, external-author trust).
  assert_contains "$cmd_path" "decision-gated" \
    "command defines the decision-gated trigger surface"
  assert_contains "$cmd_path" "needs-human-review" \
    "command keys off the needs-human-review gate label"
  assert_contains "$cmd_path" "do-work-human-decision-required" \
    "command recognizes the human-decision-required body marker (#536)"
  assert_contains "$cmd_path" "do-work-needs-decomposition" \
    "command refuses epic-decomposition handoffs (not a decision gate)"

  # The 5-part per-decision walkthrough — the load-bearing behavior. Must walk
  # ONE AT A TIME, with a recommendation+reasoning (not a neutral menu), carry
  # locked answers forward, and allow think-through/example detours.
  assert_contains "$cmd_path" "one at a time" \
    "walkthrough goes one decision at a time (carry-forward depends on it)"
  assert_contains "$cmd_path" "Restated question" \
    "per-decision format part 1: restate the question with context"
  assert_contains "$cmd_path" "Concrete options" \
    "per-decision format part 2: concrete options with trade-offs"
  assert_contains "$cmd_path" "recommendation with reasoning" \
    "per-decision format part 3: a recommendation with reasoning"
  assert_contains "$cmd_path" "not** a neutral menu" \
    "recommendation is an opinion, NOT a neutral menu (the load-bearing ask)"
  assert_contains "$cmd_path" "carry-forward" \
    "per-decision format part 4: lock + carry the answer forward as a constraint"
  assert_contains "$cmd_path" "help me think through this one" \
    "per-decision format part 5: room to clarify before locking"
  assert_contains "$cmd_path" "give me a concrete example" \
    "supports the give-me-an-example detour before locking"

  # Record + unblock — the mutation. Post a structured decisions comment with
  # the idempotency sentinel, then remove the gating label.
  assert_contains "$cmd_path" "shipyard-resolve-decisions" \
    "records decisions under the <!-- shipyard-resolve-decisions --> sentinel"
  assert_contains "$cmd_path" "gh issue comment" \
    "mutation posts a structured decisions comment to the issue"
  assert_contains "$cmd_path" "--remove-label needs-human-review" \
    "mutation removes the needs-human-review gating label to unblock dispatch"
  assert_contains "$cmd_path" "implementation outline" \
    "decisions comment includes an additive implementation outline"

  # Partial run safety: a skipped/halted walkthrough records a partial comment
  # and must NOT remove the gate label (issue stays gated until fully answered).
  assert_contains "$cmd_path" "partial" \
    "command handles a partial walkthrough (skip / stop)"
  assert_contains "$cmd_path" "Don't remove the gate label on a partial run" \
    "command refuses to clear the gate on a partial run"

  # Untrusted-input posture — body/comments are not instructions.
  assert_contains "$cmd_path" "untrusted input" \
    "command treats the issue body/comments as untrusted input"

  # No dispatch — resolving decisions is not implementing them.
  assert_contains "$cmd_path" "dispatches no code-modifying work" \
    "command records decisions but dispatches no code-modifying work"

  # Sibling relationship: this is the MUTATING sibling of the read-only
  # /my-turn (design (a) from #566).
  assert_contains "$cmd_path" "my-turn" \
    "command cross-references /my-turn as its read-only sibling"
  assert_contains "$cmd_path" "#566" \
    "command cites issue #566"

  # Don't section — non-goals explicit (shipyard convention).
  assert_contains "$cmd_path" "Don't" \
    "command has a Don't section to scope non-goals"
fi

# (2) The /my-turn side of the contract: /my-turn reuses this command's
# walkthrough for decision-gated items rather than reinventing it. (Originally
# #566 had /my-turn only *offer* a read-only hand-off; #635 changed that to
# reusing the walkthrough inline as part of /my-turn's advancing loop.) Guard
# that /my-turn references this command for its decision walkthroughs.
if [[ -f "$myturn_path" ]]; then
  assert_contains "$myturn_path" "/shipyard:resolve-decisions" \
    "/my-turn reuses /shipyard:resolve-decisions for decision walkthroughs (#566, #635)"
  assert_contains "$myturn_path" "Decision-gated walkthrough" \
    "/my-turn documents its inline decision-gated walkthrough (#635)"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
