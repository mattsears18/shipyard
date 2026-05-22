#!/usr/bin/env bash
# Test: the /shipyard:refine-issues command file exists with the three-branch
# source-branched refiner semantics, the intake-refinement-gate.yml workflow
# encodes the four trigger conditions, and do-work.md / CLAUDE.md / README.md
# all reference it with the decoupled needs-human-review semantics.
#
# `needs-refinement` is a generic pipeline gate ("this issue isn't ready for
# /do-work dispatch — a refiner needs to process it first"). The refiner has
# three source-branched paths: classify+rewrite (user-feedback),
# resolve-defaults (open questions), and escalate-to-triage (fall-through).
# `needs-human-review` is decoupled — only the classify+rewrite branch
# applies it.
#
# This test is the regression guard: if anyone deletes the command, drops a
# branch from the source-branched refiner, removes the intake gate workflow,
# or backs out the needs-human-review decoupling, the test fails.
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
workflow_path="$repo_root/.github/workflows/intake-refinement-gate.yml"
do_work_path="$repo_root/plugins/shipyard/commands/do-work.md"
# After the issue #154 split, the do-work spec lives across an entry-router
# + 5 per-phase files. Refinement-related content (step 2 bucketing, step 3a
# label setup, step 3.5 refine invocation) lives in the setup phase file.
do_work_setup_path="$repo_root/plugins/shipyard/commands/do-work/setup.md"
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

echo "refine-issues / intake-refinement-gate regression tests"
echo

# (1) Renamed command file exists with proper frontmatter.
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
  assert_contains "$cmd_path" "escalate-to-triage" \
    "refine-issues declares the escalate-to-triage branch (fall-through)"

  # Resolve-defaults must NOT apply needs-human-review (the decoupling
  # invariant from the issue body). Search for the spec line that
  # explicitly forbids it.
  assert_contains "$cmd_path" "Do NOT apply" \
    "refine-issues forbids applying needs-human-review from resolve-defaults"

  # Escalate-to-triage must add needs-triage, not invent a new label.
  assert_contains "$cmd_path" "needs-triage" \
    "escalate-to-triage branch uses the existing needs-triage label"

  # Sentinel discipline — every branch's comments must start with the
  # idempotency sentinel.
  assert_contains "$cmd_path" "<!-- do-work-refinement-agent -->" \
    "refine-issues preserves the sentinel comment for idempotency"

  # Untrusted-input discipline applies to ALL three branches.
  assert_contains "$cmd_path" "untrusted" \
    "refine-issues declares the untrusted-input discipline"

  # Don't section is the standard shipyard command convention.
  assert_contains "$cmd_path" "Don't" \
    "refine-issues has a Don't section to scope non-goals"

  # The needs-refinement description must reflect the generic pipeline
  # gate semantics (not the legacy 'raw user feedback' phrasing).
  assert_contains "$cmd_path" "Pipeline gate" \
    "refine-issues describes needs-refinement as a pipeline gate"
fi

# (2) Intake-refinement-gate.yml workflow.
assert_file_exists "$workflow_path" ".github/workflows/intake-refinement-gate.yml exists"

if [[ -f "$workflow_path" ]]; then
  # Triggers — opened (and reopened, so re-opening a closed issue re-
  # evaluates the gate).
  assert_contains "$workflow_path" "issues:" \
    "intake gate triggers on issues events"
  assert_contains "$workflow_path" "opened" \
    "intake gate subscribes to opened event type"
  assert_contains "$workflow_path" "reopened" \
    "intake gate subscribes to reopened event type"

  # Permissions — issues: write (to apply the label), contents: read
  # (to read trusted-authors.txt).
  assert_contains "$workflow_path" "issues: write" \
    "intake gate has issues: write permission"
  assert_contains "$workflow_path" "contents: read" \
    "intake gate has contents: read permission"

  # Trusted-author allowlist resolution mirrors do-work.md step 1.7 and
  # label-event-audit.yml — file first, then API, then owner fallback.
  assert_contains "$workflow_path" ".shipyard/trusted-authors.txt" \
    "intake gate reads .shipyard/trusted-authors.txt"
  assert_contains "$workflow_path" "collaborators" \
    "intake gate falls back to collaborators API"
  assert_contains "$workflow_path" "tr 'A-Z' 'a-z'" \
    "intake gate lowercase-normalizes author login"

  # All four trigger conditions must be encoded.
  assert_contains "$workflow_path" "Open [qQ]uestions" \
    "intake gate detects '## Open questions' heading (condition 2)"
  assert_contains "$workflow_path" "Bot" \
    "intake gate handles bot-authored issues (condition 4)"
  assert_contains "$workflow_path" "200" \
    "intake gate's one-liner length heuristic threshold"
  assert_contains "$workflow_path" "no headings" \
    "intake gate's one-liner heuristic mentions the no-headings condition"

  # The label that gets applied — needs-refinement is the gate.
  assert_contains "$workflow_path" "needs-refinement" \
    "intake gate applies the needs-refinement label"
  # And the workflow creates the label idempotently first (matches
  # do-work.md step 3a + refine-issues.md step 2 convention).
  assert_contains "$workflow_path" "gh label create needs-refinement" \
    "intake gate creates needs-refinement label idempotently before applying"

  # Security-injection guards — every event-supplied value must go
  # through env vars, never interpolated into run: blocks directly.
  # Mirrors external-author-gate.yml + label-event-audit.yml.
  assert_contains "$workflow_path" "AUTHOR: \${{ github.event.issue.user.login }}" \
    "intake gate passes author login through env (not run: interpolation)"
  assert_contains "$workflow_path" "BODY: \${{ github.event.issue.body }}" \
    "intake gate passes body through env (not run: interpolation)"
  assert_contains "$workflow_path" "ISSUE: \${{ github.event.issue.number }}" \
    "intake gate passes issue number through env"

  # Actions pinned by full SHA (repo convention).
  if grep -E 'actions/checkout@[0-9a-f]{40}' "$workflow_path" >/dev/null 2>&1; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" \
      "actions/checkout is pinned by full SHA (40 chars)"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" \
      "actions/checkout is NOT pinned by full SHA"
    fail=$((fail+1))
  fi

  # Workflow-injection forbidden patterns — must not echo the body /
  # title / author directly in run: blocks.
  assert_not_contains "$workflow_path" "echo \"\${{ github.event.issue.body }}\"" \
    "intake gate does not echo body directly into run: (injection-safe)"
fi

# (3) do-work spec — the entry exists, and the setup phase carries the
# refinement-related steps (step 2 bucketing, step 3a label setup, step 3.5
# refine invocation). These steps live in commands/do-work/setup.md rather
# than in the thin entry.
assert_file_exists "$do_work_path" "commands/do-work.md exists (thin entry)"
assert_file_exists "$do_work_setup_path" "commands/do-work/setup.md exists (setup phase)"
if [[ -f "$do_work_setup_path" ]]; then
  # Step 3.5 must invoke /refine-issues.
  assert_contains "$do_work_setup_path" "/refine-issues" \
    "do-work/setup.md step 3.5 invokes /refine-issues"

  # needs-triage label-create must be in step 3a (the escalate-to-triage
  # branch depends on it existing).
  assert_contains "$do_work_setup_path" "gh label create needs-triage" \
    "do-work/setup.md step 3a creates the needs-triage label idempotently"

  # The bucket-5.4 description must reflect the generic-gate semantics.
  assert_contains "$do_work_setup_path" "generic pipeline gate" \
    "do-work/setup.md step 2 describes needs-refinement as a generic gate"
fi

# (4) my-turn.md — the needs-refinement bucket references /shipyard:refine-issues.
assert_file_exists "$my_turn_path" "commands/my-turn.md exists"
if [[ -f "$my_turn_path" ]]; then
  assert_contains "$my_turn_path" "/shipyard:refine-issues" \
    "my-turn.md references /shipyard:refine-issues"
fi

# (5) CLAUDE.md — describes the generic-gate label semantics.
assert_file_exists "$claude_md_path" "CLAUDE.md exists"
if [[ -f "$claude_md_path" ]]; then
  assert_contains "$claude_md_path" "generic pipeline gate" \
    "CLAUDE.md describes needs-refinement as a generic pipeline gate"
  assert_contains "$claude_md_path" "decoupled" \
    "CLAUDE.md documents the needs-human-review decoupling"
fi

# (6) README.md — slash command list mentions /refine-issues.
assert_file_exists "$readme_path" "README.md exists"
if [[ -f "$readme_path" ]]; then
  assert_contains "$readme_path" "/refine-issues" \
    "README.md slash-command list mentions /refine-issues"
  assert_contains "$readme_path" "refine-issues.md" \
    "README.md repo layout lists refine-issues.md"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
