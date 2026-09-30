#!/usr/bin/env bash
# Test: milestone assignment at issue-filing time (issue #1242) — the
# `milestones.assign_on_file` consumer.
#
# Background — #1242 is the second consumer of the `milestones` config
# block #1239 shipped as inert scaffolding (`shipyard:update-roadmap`,
# #1240, was the first). This wires `assign_on_file` into the two shared
# filing surfaces (`shipyard:filing-github-issues`, `/shipyard:file-issue`)
# and into `/decompose-epic`'s sub-issue creation.
#
# Every one of those three call sites is an LLM agent reading and
# following markdown instructions when it files a `gh issue create` — there
# is no shipyard-owned shell script that decides which milestone a finding
# belongs to. So this suite (like milestones-config.test.sh before it)
# pins the DOCUMENTED CONTRACT via `assert_file_contains`, not runtime
# behavior: the gate check, the BET:-matching rule (never title keywords),
# the never-create / never-fail-a-filing posture, the cache-once-per-run
# rule, the sub-issue inheritance shape, and the `gh api` --method GET fix
# discovered while writing these docs (the milestones endpoint silently
# defaults to POST and 422s whenever a bare -f field is present).
#
# Pure bash + grep, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/milestone-assign-on-file.test.sh

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

filing_skill="$repo_root/plugins/shipyard/skills/filing-github-issues/SKILL.md"
file_issue_cmd="$repo_root/plugins/shipyard/commands/file-issue.md"
decompose_cmd="$repo_root/plugins/shipyard/commands/decompose-epic.md"
dont_md="$repo_root/plugins/shipyard/commands/do-work/dont.md"
schema="$repo_root/plugins/shipyard/schemas/shipyard.config.schema.json"
config_sh="$repo_root/plugins/shipyard/scripts/shipyard-config.sh"
milestone_prohibition="$repo_root/plugins/shipyard/skills/worker-preamble/milestone-prohibition.md"
issue_work_cmd="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"
deferred_slice_cmd="$repo_root/plugins/shipyard/agents/issue-worker/issue-work-deferred-slice-dispatch.md"
drain_cmd="$repo_root/plugins/shipyard/commands/do-work/drain.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_file_contains() {
  local path="$1" needle="$2" label="$3"
  if [[ ! -f "$path" ]]; then
    printf '  %sFAIL%s  %s — file missing: %s\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail+1))
    return
  fi
  if grep -qF -- "$needle" "$path"; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected %s to contain: %s\n' "$path" "$needle"
    fail=$((fail+1))
  fi
}

assert_file_not_contains() {
  local path="$1" needle="$2" label="$3"
  if [[ ! -f "$path" ]]; then
    printf '  %sFAIL%s  %s — file missing: %s\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail+1))
    return
  fi
  if grep -qF -- "$needle" "$path"; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected %s to NOT contain: %s\n' "$path" "$needle"
    fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  fi
}

assert_equals() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (expected %q, got %q)\n' "$RED" "$RESET" "$label" "$expected" "$actual"
    fail=$((fail+1))
  fi
}

# --------------------------------------------------------------------------
echo "== assign_on_file already exists in the config surface (#1239)"

got_assign=$(bash "$config_sh" get milestones.assign_on_file 2>/dev/null)
assert_equals "$got_assign" "true" "get milestones.assign_on_file returns true when block absent (schema default unchanged by this issue)"
assert_file_contains "$schema" '"assign_on_file"' "schema already declares assign_on_file — #1242 is a consumer, not a schema change"

# --------------------------------------------------------------------------
echo
echo "== shipyard:filing-github-issues — the shared path (highest-leverage single change)"

assert_file_contains "$filing_skill" "## Milestone assignment (gated on \`milestones.enabled\` + \`milestones.assign_on_file\`" \
  "documents a dedicated Milestone assignment section"
assert_file_contains "$filing_skill" "MILESTONES_ENABLED" "reads milestones.enabled"
assert_file_contains "$filing_skill" "MILESTONES_ASSIGN" "reads milestones.assign_on_file"
assert_file_contains "$filing_skill" "skip this entire section" "documents the inert-when-off gate (byte-identical filing when off)"
assert_file_contains "$filing_skill" 'never against keywords in the finding'"'"'s own title' \
  "documents matching against BET:, never title keywords"
assert_file_contains "$filing_skill" "A filer must never create a milestone." \
  "documents the filer-never-creates-a-milestone rule"
assert_file_contains "$filing_skill" "Never fail a filing over a milestone." \
  "documents the never-fail-a-filing-over-a-milestone rule"
assert_file_contains "$filing_skill" "reads this once, not 30 times" \
  "documents caching the milestone list once per run"
assert_file_contains "$filing_skill" "gh api repos/<owner>/<repo>/milestones --method GET --paginate -f state=open" \
  "milestone-list fetch uses --method GET explicitly (avoids the silent-POST 422)"
# shellcheck disable=SC2016  # literal text — must NOT expand
assert_file_contains "$filing_skill" '${MILESTONE_TITLE:+--milestone "$MILESTONE_TITLE"}' \
  "gh issue create examples pass --milestone conditionally"
assert_file_contains "$filing_skill" "Don't create a milestone, even the fallback one" \
  "Don't section prohibits filer-side milestone creation"
assert_file_contains "$filing_skill" "Don't re-fetch the milestone list per finding." \
  "Don't section prohibits per-finding re-fetching"

# --------------------------------------------------------------------------
echo
echo "== /shipyard:file-issue — the human-invoked single-issue path"

assert_file_contains "$file_issue_cmd" "### 7.5 Assign a milestone (gated on \`milestones.enabled\` + \`milestones.assign_on_file\`" \
  "documents step 7.5 (milestone assignment)"
assert_file_contains "$file_issue_cmd" "MILESTONES_ENABLED" "reads milestones.enabled"
assert_file_contains "$file_issue_cmd" "gh api repos/<owner>/<repo>/milestones --method GET --paginate -f state=open" \
  "milestone-list fetch uses --method GET explicitly"
# shellcheck disable=SC2016  # literal text — must NOT expand
assert_file_contains "$file_issue_cmd" '${MILESTONE_TITLE:+--milestone "$MILESTONE_TITLE"}' \
  "gh issue create call passes --milestone conditionally"
assert_file_contains "$file_issue_cmd" "Don't create a milestone." \
  "Don't section prohibits filer-side milestone creation"
assert_file_contains "$file_issue_cmd" "Don't fail the filing over a milestone lookup." \
  "Don't section states the never-fail posture"

# --------------------------------------------------------------------------
echo
echo "== /decompose-epic — sub-issue inherits the parent epic's milestone"

assert_file_contains "$decompose_cmd" "PARENT_MILESTONE" \
  "worker prompt template resolves the parent's milestone"
assert_file_contains "$decompose_cmd" ".milestone.title // empty" \
  "reads the parent's milestone title via gh issue view --json milestone"
# shellcheck disable=SC2016  # literal text — must NOT expand
assert_file_contains "$decompose_cmd" '${PARENT_MILESTONE:+--milestone "$PARENT_MILESTONE"}' \
  "each sub-issue's gh issue create passes --milestone conditionally"
assert_file_contains "$decompose_cmd" "Never look up or guess a different milestone for a child than the one the parent already carries" \
  "documents unconditional inheritance — no re-matching against BET: for children"
assert_file_contains "$decompose_cmd" "Inherited milestone (decompose only" \
  "--dry-run per-epic output format shows the inherited milestone"
assert_file_contains "$decompose_cmd" "Don't assign a sub-issue a milestone other than the parent's own" \
  "Don't section prohibits a different or invented milestone for a child"

# --------------------------------------------------------------------------
# --------------------------------------------------------------------------
echo
echo "== dont.md — the filer-never-creates-a-milestone prohibition is worker-readable"

assert_file_contains "$dont_md" "Don't let a filing path" \
  "dont.md carries the filing-path milestone-creation prohibition (#1242)"

# --------------------------------------------------------------------------
echo
echo "== #1421 — worker follow-up filing no longer silently skips milestone assignment"

assert_file_contains "$milestone_prohibition" "Inherit first." \
  "milestone-prohibition.md documents tier 1 (inherit parent's milestone)"
assert_file_contains "$milestone_prohibition" "Fall through when there's nothing to inherit." \
  "milestone-prohibition.md documents tier 2 (BET-match + fallback when parent has none)"
assert_file_contains "$milestone_prohibition" 'shipyard:filing-github-issues' \
  "milestone-prohibition.md points tier 2 at the shared Milestone assignment section"
assert_file_contains "$milestone_prohibition" "must NOT skip tier 2 and file bare" \
  "milestone-prohibition.md prohibits silently degrading to no milestone (#1421)"
assert_file_contains "$milestone_prohibition" "never author a new one" \
  "milestone-prohibition.md still prohibits the worker from creating a milestone in either tier (AC4)"

assert_file_contains "$issue_work_cmd" "milestone-prohibition.md" \
  "issue-work.md's follow-up-filing bullet points at milestone-prohibition.md, not just the provenance-label section (#1421)"
assert_file_contains "$issue_work_cmd" "assign a milestone per \`shipyard:worker-preamble\`'s" \
  "issue-work.md's follow-up-filing bullet instructs milestone assignment"

assert_file_contains "$deferred_slice_cmd" 'MILESTONE_TITLE=""' \
  "issue-work-deferred-slice-dispatch.md resolves a milestone before filing its follow-up issue (#1421)"
# shellcheck disable=SC2016  # literal text — must NOT expand
assert_file_contains "$deferred_slice_cmd" '${MILESTONE_TITLE:+--milestone "$MILESTONE_TITLE"}' \
  "deferred-slice follow-up's gh issue create passes --milestone conditionally"
assert_file_contains "$deferred_slice_cmd" ".milestone.title // empty" \
  "deferred-slice follow-up inherits #<N>'s own milestone (tier 1) before falling through to BET-matching"

assert_file_contains "$drain_cmd" "shipyard:filing-github-issues" \
  "drain.md's friction-issue filing paragraph points orchestrator-filed issues at the shared filing skill (#1421)"
assert_file_contains "$drain_cmd" "never an ad hoc \`gh issue create\` with no provenance label or milestone resolution" \
  "drain.md prohibits ad hoc, milestone-blind gh issue create for orchestrator-filed friction issues"

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
