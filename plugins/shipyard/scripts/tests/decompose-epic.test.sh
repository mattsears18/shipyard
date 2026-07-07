#!/usr/bin/env bash
# Test: the /shipyard:decompose-epic command file exists with the auto-shard
# semantics, the epic-decomposition trigger is re-keyed onto
# `needs-human-review` + the `<!-- do-work-needs-decomposition -->` body
# marker (binary-backlog fold, #519), /my-turn surfaces epic handoffs, and
# README / CLAUDE.md register the command.
#
# /decompose-epic (#501) is the automation layer on top of #498's
# epic-handoff surfacing. As of #519 the trigger surface is the
# `needs-human-review` label PLUS the `<!-- do-work-needs-decomposition -->`
# body marker (the former dedicated `needs-decomposition` / `tracking` label
# pair was folded into `needs-human-review` — the body marker is what lets the
# command separate epic handoffs from every other `needs-human-review` issue).
# For the mechanically-decomposable evidence classes (`Multi-PR sequence:` /
# `Missing dependency:`) it auto-shards the epic into dispatch-ready sub-issues
# chained via `Blocked by #<sibling>` so /do-work sequences them; non-mechanical
# classes (`Multi-service coordination:` / `Body cites <artifact>:`) fall
# through to the existing human handoff. A decomposed parent KEEPS
# `needs-human-review` (a human-gated tracking umbrella) and is excluded from
# dispatch; the `<!-- do-work-decompose-agent -->` idempotency comment — not a
# label swap — is what prevents re-processing.
#
# This test is the regression guard: if anyone deletes the command, drops the
# escalate fall-through, removes the sentinel-keyed idempotency, breaks the
# `needs-human-review` + body-marker candidate fetch, or stops surfacing
# epic handoffs in /my-turn, the test fails.
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
# #611 split setup.md into a thin router + step-cluster sub-files under
# do-work/setup/. The step-6 content this test greps now lives in the
# sub-files, so point do_work_setup_path at a concatenation of the router +
# every sub-file (the assert_file_exists below still checks the router exists).
do_work_setup_router="$repo_root/plugins/shipyard/commands/do-work/setup.md"
do_work_setup_dir="$repo_root/plugins/shipyard/commands/do-work/setup"
do_work_setup_path="$(mktemp -t decompose-epic-setup-concat.XXXXXX)"
cat "$do_work_setup_router" "$do_work_setup_dir"/*.md > "$do_work_setup_path" 2>/dev/null
trap 'rm -f "$do_work_setup_path"' EXIT
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

  # Consumes #498's trigger surface, re-keyed onto needs-human-review + the
  # body marker by #519's binary-backlog fold.
  assert_contains "$cmd_path" "needs-human-review" \
    "decompose-epic fetches candidates by the needs-human-review label (#519 re-key)"
  assert_contains "$cmd_path" "<!-- do-work-needs-decomposition -->" \
    "decompose-epic filters candidates by the do-work-needs-decomposition trigger marker (#519)"

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

  # The sharded parent keeps needs-human-review (no more tracking label swap).
  assert_contains "$cmd_path" "Keep \`needs-human-review\` on the parent" \
    "decompose-epic keeps needs-human-review on a sharded parent (no tracking-label swap, #519)"

  # Idempotency sentinel — every comment a worker posts starts with it.
  assert_contains "$cmd_path" "<!-- do-work-decompose-agent -->" \
    "decompose-epic uses the do-work-decompose-agent idempotency sentinel"

  # Untrusted-input discipline (mirrors /refine-issues + issue-worker step 2).
  assert_contains "$cmd_path" "untrusted" \
    "decompose-epic declares the untrusted-input discipline"

  # The auto path is built and default-on for the mechanical classes (#665);
  # gated by the decompose.auto config knob (opt-out).
  assert_contains "$cmd_path" "decompose.auto" \
    "decompose-epic documents the inline auto path config knob (decompose.auto, #665)"

  # Standard shipyard command convention.
  assert_contains "$cmd_path" "Don't" \
    "decompose-epic has a Don't section to scope non-goals"
fi

# (2) do-work/setup.md — step 6's Deferred recording path applies
# needs-human-review + stamps the trigger marker (the #519 re-key), and the
# epic-handoff is excluded from dispatch via needs-human-review.
assert_file_exists "$do_work_setup_router" "commands/do-work/setup.md exists (thin router)"
if [[ -f "$do_work_setup_path" ]]; then
  # Step 6 applies the class-keyed gate label; the confirmed-non-shippable
  # epic handoff routes to needs-human-review via the GATE_LABEL default
  # branch (#608 introduced the operator/decision split — external-dependency
  # → needs-operator, everything else → needs-human-review).
  # shellcheck disable=SC2016  # literal needle — must NOT expand $GATE_LABEL
  assert_contains "$do_work_setup_path" 'gh issue edit <N> --repo <owner/repo> --add-label "$GATE_LABEL"' \
    "do-work/setup.md step 6 applies the class-keyed GATE_LABEL (#608)"
  assert_contains "$do_work_setup_path" 'GATE_LABEL="needs-human-review"' \
    "do-work/setup.md step 6 routes the epic handoff (non-external-dependency) to needs-human-review (#519/#608)"
  # Step 6 stamps the trigger marker on the diagnosis comment.
  assert_contains "$do_work_setup_path" "<!-- do-work-needs-decomposition -->" \
    "do-work/setup.md step 6 stamps the do-work-needs-decomposition trigger marker (#519)"
  # The dispatch-exclusion enumeration drops needs-human-review issues.
  assert_contains "$do_work_setup_path" "\`needs-human-review\`" \
    "do-work/setup.md enumerates needs-human-review in the dispatch-exclusion set"
  # The setup spec references /decompose-epic for the epic-handoff consumer.
  assert_contains "$do_work_setup_path" "decompose-epic" \
    "do-work/setup.md references /decompose-epic for the epic-handoff marker"
  # The former tracking label must be gone (folded into needs-human-review).
  if grep -qF 'tracking --description' "$do_work_setup_path" 2>/dev/null; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" \
      "do-work/setup.md no longer creates the tracking label (#519 folded it into needs-human-review)"; fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" \
      "do-work/setup.md no longer creates the tracking label (#519 folded it into needs-human-review)"; pass=$((pass+1))
  fi
fi

# (3) my-turn.md — surfaces epic handoffs (needs-human-review + trigger marker)
# + names /decompose-epic.
assert_file_exists "$my_turn_path" "commands/my-turn.md exists"
if [[ -f "$my_turn_path" ]]; then
  assert_contains "$my_turn_path" "<!-- do-work-needs-decomposition -->" \
    "my-turn.md surfaces epic handoffs via the needs-human-review + trigger-marker signal (#519)"
  assert_contains "$my_turn_path" "/shipyard:decompose-epic" \
    "my-turn.md points the user at /shipyard:decompose-epic"
fi

# (4) CLAUDE.md — documents the re-keyed epic-decomposition handoff.
assert_file_exists "$claude_md_path" "CLAUDE.md exists"
if [[ -f "$claude_md_path" ]]; then
  assert_contains "$claude_md_path" "Epic-decomposition handoff" \
    "CLAUDE.md documents the epic-decomposition handoff section"
  assert_contains "$claude_md_path" "<!-- do-work-needs-decomposition -->" \
    "CLAUDE.md documents the do-work-needs-decomposition trigger marker (#519)"
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
