#!/usr/bin/env bash
# Test: the /shipyard:decompose-epic command file exists with the auto-shard
# semantics, the `tracking` parent-epic marker is wired into /do-work's
# dispatch-exclusion set and label-create blocks, /my-turn surfaces
# needs-decomposition epics, and README / CLAUDE.md register the command.
#
# /decompose-epic (#501) is the automation layer on top of #498's
# needs-decomposition surfacing label. It consumes that label, and for the
# mechanically-decomposable evidence classes (`Multi-PR sequence:` /
# `Missing dependency:`) auto-shards the epic into dispatch-ready sub-issues
# chained via `Blocked by #<sibling>` so /do-work sequences them; non-mechanical
# classes (`Multi-service coordination:` / `Body cites <artifact>:`) fall
# through to the existing human handoff. A decomposed parent gets the
# `tracking` label (swapped in for `needs-decomposition`) and is excluded
# from dispatch.
#
# This test is the regression guard: if anyone deletes the command, drops the
# escalate fall-through, removes the sentinel-keyed idempotency, backs the
# `tracking` label out of the dispatch-exclusion set, or stops surfacing
# needs-decomposition epics in /my-turn, the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/decompose-epic.test.sh

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

cmd_path="$repo_root/plugins/shipyard/commands/decompose-epic.md"
do_work_setup_path="$repo_root/plugins/shipyard/commands/do-work/setup.md"
my_turn_path="$repo_root/plugins/shipyard/commands/my-turn.md"
claude_md_path="$repo_root/CLAUDE.md"
readme_path="$repo_root/README.md"

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

echo "decompose-epic regression tests"
echo

# (1) Command file exists with proper frontmatter + args.
assert_file_exists "$cmd_path" "commands/decompose-epic.md exists"

if [[ -f "$cmd_path" ]]; then
  assert_contains "$cmd_path" "description:" \
    "decompose-epic frontmatter has a description field"
  assert_contains "$cmd_path" "argument-hint:" \
    "decompose-epic frontmatter has an argument-hint field"
  assert_contains "$cmd_path" "--repo" \
    "decompose-epic accepts --repo (matches /do-work convention)"
  assert_contains "$cmd_path" "--issue" \
    "decompose-epic accepts --issue (repeatable, scope to specific epics)"
  assert_contains "$cmd_path" "--max-subissues" \
    "decompose-epic accepts --max-subissues (guardrail cap)"
  assert_contains "$cmd_path" "--dry-run" \
    "decompose-epic accepts --dry-run"

  # Consumes #498's trigger surface.
  assert_contains "$cmd_path" "needs-decomposition" \
    "decompose-epic consumes the needs-decomposition trigger label (#498)"

  # The two decomposable evidence classes + the two escalate classes.
  assert_contains "$cmd_path" "Multi-PR sequence:" \
    "decompose-epic handles the Multi-PR sequence: evidence class (decompose)"
  assert_contains "$cmd_path" "Missing dependency:" \
    "decompose-epic handles the Missing dependency: evidence class (decompose)"
  assert_contains "$cmd_path" "Multi-service coordination:" \
    "decompose-epic escalates the Multi-service coordination: class"
  assert_contains "$cmd_path" "Body cites" \
    "decompose-epic escalates the Body cites <artifact>: class"

  # The escalate / human-handoff fall-through (couldn't auto-decompose).
  assert_contains "$cmd_path" "couldn't auto-decompose" \
    "decompose-epic falls through to human handoff when not confidently shardable"

  # Sequencing mechanism — Blocked by chain so /do-work bucket-7 gating orders them.
  assert_contains "$cmd_path" "Blocked by #" \
    "decompose-epic chains sub-issues with Blocked by #<sibling> for sequencing"
  assert_contains "$cmd_path" "Part of #" \
    "decompose-epic links sub-issues back to the parent via Part of #<N>"

  # Native GitHub sub-issue link via GraphQL.
  assert_contains "$cmd_path" "addSubIssue" \
    "decompose-epic establishes native GitHub sub-issue links via addSubIssue"

  # The tracking parent-marker swap.
  assert_contains "$cmd_path" "tracking" \
    "decompose-epic applies the tracking parent-epic marker"

  # Idempotency sentinel — every comment a worker posts starts with it.
  assert_contains "$cmd_path" "<!-- do-work-decompose-agent -->" \
    "decompose-epic uses the do-work-decompose-agent idempotency sentinel"

  # Untrusted-input discipline (mirrors /refine-issues + issue-worker step 2).
  assert_contains "$cmd_path" "untrusted" \
    "decompose-epic declares the untrusted-input discipline"

  # Explicit-command-only for v1; the auto path is deferred.
  assert_contains "$cmd_path" "decompose.enabled" \
    "decompose-epic documents the deferred opt-in auto path (decompose.enabled)"

  # Standard shipyard command convention.
  assert_contains "$cmd_path" "Don't" \
    "decompose-epic has a Don't section to scope non-goals"
fi

# (2) do-work/setup.md — the tracking label is wired into the
# dispatch-exclusion set and the label-create blocks.
assert_file_exists "$do_work_setup_path" "commands/do-work/setup.md exists"
if [[ -f "$do_work_setup_path" ]]; then
  # The step-3a idempotent label-create batch ensures the tracking label.
  assert_contains "$do_work_setup_path" "tracking --description" \
    "do-work/setup.md ensures the tracking label in the step-3a create batch"
  # The dispatch-exclusion enumeration drops tracking-labelled parents.
  assert_contains "$do_work_setup_path" "\`tracking\`" \
    "do-work/setup.md enumerates tracking in the dispatch-exclusion set"
  # The setup spec references /decompose-epic for the tracking marker provenance.
  assert_contains "$do_work_setup_path" "decompose-epic" \
    "do-work/setup.md references /decompose-epic for the tracking marker"
fi

# (3) my-turn.md — surfaces needs-decomposition epics + names /decompose-epic.
assert_file_exists "$my_turn_path" "commands/my-turn.md exists"
if [[ -f "$my_turn_path" ]]; then
  assert_contains "$my_turn_path" "needs-decomposition" \
    "my-turn.md surfaces needs-decomposition epics as human-blocked"
  assert_contains "$my_turn_path" "/shipyard:decompose-epic" \
    "my-turn.md points the user at /shipyard:decompose-epic"
fi

# (4) CLAUDE.md — documents the decomposition label pair.
assert_file_exists "$claude_md_path" "CLAUDE.md exists"
if [[ -f "$claude_md_path" ]]; then
  assert_contains "$claude_md_path" "Epic-decomposition labels" \
    "CLAUDE.md documents the epic-decomposition label pair"
  assert_contains "$claude_md_path" "tracking" \
    "CLAUDE.md documents the tracking parent-epic marker"
fi

# (5) README.md — slash-command list + repo layout register the command.
assert_file_exists "$readme_path" "README.md exists"
if [[ -f "$readme_path" ]]; then
  assert_contains "$readme_path" "/decompose-epic" \
    "README.md slash-command list mentions /decompose-epic"
  assert_contains "$readme_path" "decompose-epic.md" \
    "README.md repo layout lists decompose-epic.md"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
