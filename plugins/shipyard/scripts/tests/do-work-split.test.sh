#!/usr/bin/env bash
# Test: commands/do-work.md is split into a thin entry router + per-phase
# files + RATIONALE.md. See issues #100 (entry + RATIONALE split) and #154
# (further split by phase).
#
# Spec runtime guarantees:
#   - thin entry + RATIONALE + every phase file exists
#   - thin entry stays < 220 lines (the routing-only contract from #154,
#     re-baselined after #195/#233/#246 added new orchestrator-state structs)
#   - RATIONALE has ≥200 lines so the prose-rationale content genuinely
#     landed there during #100's original split
#   - the key anchors external files reference still exist (now in the
#     per-phase files; regression guard against accidental anchor renames
#     during the #154 split)
#   - the Don't section landed in `do-work/dont.md`, not the entry
#   - worker-preamble references survive across the per-phase files
#   - the worktree-reap helper reference (#138's fix) survives in the
#     cleanup-summary phase file
#
# Pure bash, no external dependencies.

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

do_work_path="$repo_root/plugins/shipyard/commands/do-work.md"
rationale_path="$repo_root/plugins/shipyard/commands/do-work-RATIONALE.md"
setup_path="$repo_root/plugins/shipyard/commands/do-work/setup.md"
steady_state_path="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
drain_path="$repo_root/plugins/shipyard/commands/do-work/drain.md"
cleanup_path="$repo_root/plugins/shipyard/commands/do-work/cleanup-summary.md"
dont_path="$repo_root/plugins/shipyard/commands/do-work/dont.md"

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

assert_line_count_at_least() {
  local path="$1"
  local min="$2"
  local label="$3"
  if [[ ! -f "$path" ]]; then
    printf '  %sFAIL%s  %s (file missing: %s)\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail+1))
    return
  fi
  local lines
  lines=$(wc -l < "$path" | tr -d ' ')
  if (( lines >= min )); then
    printf '  %sPASS%s  %s (%d lines, min %d)\n' "$GREEN" "$RESET" "$label" "$lines" "$min"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (%d lines, min %d)\n' "$RED" "$RESET" "$label" "$lines" "$min"
    fail=$((fail+1))
  fi
}

assert_line_count_at_most() {
  local path="$1"
  local max="$2"
  local label="$3"
  if [[ ! -f "$path" ]]; then
    printf '  %sFAIL%s  %s (file missing: %s)\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail+1))
    return
  fi
  local lines
  lines=$(wc -l < "$path" | tr -d ' ')
  if (( lines <= max )); then
    printf '  %sPASS%s  %s (%d lines, max %d)\n' "$GREEN" "$RESET" "$label" "$lines" "$max"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (%d lines, max %d)\n' "$RED" "$RESET" "$label" "$lines" "$max"
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
    printf '    forbidden string still present in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  fi
}

# Sum a fixed-string count across multiple files; useful for assertions
# like "worker-preamble appears ≥5 times across all phase files combined."
assert_count_at_least_across() {
  local needle="$1"
  local min="$2"
  local label="$3"
  shift 3
  local total=0
  for file in "$@"; do
    local count
    count=$(grep -cF -- "$needle" "$file" 2>/dev/null | head -n 1)
    count=${count:-0}
    total=$((total + count))
  done
  if (( total >= min )); then
    printf '  %sPASS%s  %s (found %d total, min %d)\n' "$GREEN" "$RESET" "$label" "$total" "$min"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (found %d total, min %d)\n' "$RED" "$RESET" "$label" "$total" "$min"
    fail=$((fail+1))
  fi
}

echo "do-work spec split regression tests (issues #100 + #154)"
echo

# (1) Every spec file exists — entry + RATIONALE + 5 per-phase files.
assert_file_exists "$do_work_path" "commands/do-work.md exists (thin entry)"
assert_file_exists "$rationale_path" "commands/do-work-RATIONALE.md exists"
assert_file_exists "$setup_path" "commands/do-work/setup.md exists"
assert_file_exists "$steady_state_path" "commands/do-work/steady-state.md exists"
assert_file_exists "$drain_path" "commands/do-work/drain.md exists"
assert_file_exists "$cleanup_path" "commands/do-work/cleanup-summary.md exists"
assert_file_exists "$dont_path" "commands/do-work/dont.md exists"

# (2) The thin entry stays under 222 lines. Acceptance criterion from
#     #154 — the entry is allowed to grow if a new orchestrator-state
#     struct lands, but if it grows past the cap the split is over-engineered
#     and we'd rather know. Re-baselined from 200 → 220 after #195
#     (`last_fresh_fetch`), #233 (`scope_bg_count`), and #246 (refresh
#     tracker + `deferred_issues` provenance), then 220 → 222 after #323
#     (`ci_session_counters`) added the 13th orchestrator-state struct
#     for CI-minute discipline.
assert_line_count_at_most "$do_work_path" 222 \
  "thin entry stays <= 222 lines (#154 acceptance criterion)"

# (3) RATIONALE has substantive content (≥200 lines) so the prose-rationale
#     genuinely landed there during the #100 split.
assert_line_count_at_least "$rationale_path" 200 \
  "RATIONALE.md carries substantive prose"

# (4) Phase routing — the thin entry lists every phase file by relative
#     path so a reader of the entry can navigate to any phase.
assert_contains "$do_work_path" "do-work/setup.md" \
  "entry routes to setup.md"
assert_contains "$do_work_path" "do-work/steady-state.md" \
  "entry routes to steady-state.md"
assert_contains "$do_work_path" "do-work/drain.md" \
  "entry routes to drain.md"
assert_contains "$do_work_path" "do-work/cleanup-summary.md" \
  "entry routes to cleanup-summary.md"
assert_contains "$do_work_path" "do-work/dont.md" \
  "entry routes to dont.md"

# (5) Key anchors that external files reference (agents/issue-worker/*.md,
#     commands/cost.md, commands/do-work-RATIONALE.md) — verify the
#     section headers still exist somewhere in the per-phase files.
assert_contains "$steady_state_path" "### A. Reconcile the return" \
  "anchor in steady-state.md: A. Reconcile the return (referenced by issue-worker/*.md)"
assert_contains "$steady_state_path" "## Dispatch rules (used by step 7 and step C)" \
  "anchor in steady-state.md: Dispatch rules (referenced by issue-worker/issue-work.md)"
assert_contains "$setup_path" "### 1.7 Resolve trusted-author allowlist" \
  "anchor in setup.md: 1.7 trusted-author allowlist (referenced by issue-worker/issue-work.md)"
assert_contains "$drain_path" "## End-of-session drain" \
  "anchor in drain.md: End-of-session drain (referenced by issue-worker/fix-rebase.md)"
assert_contains "$cleanup_path" "## End-of-session cleanup" \
  "anchor in cleanup-summary.md: End-of-session cleanup (referenced by commands/cost.md)"

# (6) The Don't list lives in `do-work/dont.md`. The thin entry still has
#     a Don't section header pointing at it (so the rules surface is
#     discoverable from the entry's table of contents), but the
#     load-bearing rule bullets land in the per-phase Don't file.
assert_contains "$do_work_path" "## Don't" \
  "entry has a Don't pointer section"
assert_contains "$dont_path" "Dispatch-loop discipline" \
  "do-work/dont.md carries the dispatch-loop rules"
assert_contains "$dont_path" "Dispatch hygiene" \
  "do-work/dont.md carries the dispatch-hygiene rules"
assert_contains "$dont_path" "Failure-handling discipline" \
  "do-work/dont.md carries the failure-handling rules"
assert_contains "$dont_path" "Worktree + filesystem discipline" \
  "do-work/dont.md carries the worktree + filesystem rules"
assert_contains "$rationale_path" "## Don't — extended rationale" \
  "RATIONALE.md carries the extended Don't rationale"

# (7) Worker-preamble references survive — counted across the entry +
#     all per-phase files (≥5 total). Originally a do-work.md-only
#     assertion; the per-phase split means the references are spread
#     across files but the total survives.
assert_count_at_least_across "shipyard:worker-preamble" 5 \
  "worker-preamble referenced in ≥5 places (entry + per-phase files combined)" \
  "$do_work_path" "$setup_path" "$steady_state_path" "$drain_path" "$cleanup_path" "$dont_path"

# (8) Worktree-reap helper references survive in cleanup-summary.md (the
#     phase that owns end-of-session cleanup) + setup.md (step 3b, the
#     prior-session reap). Regression guard against issue #138 — if either
#     call site reverts to the strict liveness check, the orchestrator's
#     own PID will defer every agent worktree at shutdown.
assert_count_at_least_across "scripts/worktree-reap.sh" 2 \
  "worktree-reap.sh referenced in ≥2 places across setup + cleanup-summary (step 3 + 3b)" \
  "$setup_path" "$cleanup_path"
assert_count_at_least_across "classify-lock" 1 \
  "classify-lock subcommand referenced (#138 fix)" \
  "$setup_path" "$cleanup_path"
assert_count_at_least_across "self-ancestor" 1 \
  "self-ancestor classification referenced (#138 fix)" \
  "$setup_path" "$cleanup_path"

# (9) RATIONALE cross-references survive — counted across the entry +
#     all per-phase files (≥10 total). Originally a do-work.md-only
#     assertion; the per-phase split spreads the references across files.
assert_count_at_least_across "do-work-RATIONALE.md" 10 \
  "RATIONALE cross-referenced ≥10 times across entry + per-phase files" \
  "$do_work_path" "$setup_path" "$steady_state_path" "$drain_path" "$cleanup_path" "$dont_path"

# (10) Cost-comment refresh uses the REST listing endpoint for comment IDs
#      (issue #264). `gh pr view --json comments` returns GraphQL node-ids
#      (e.g. `IC_kwDO...`) for each comment, which the REST PATCH endpoint
#      `/repos/<o/r>/issues/comments/<id>` does not accept — the PATCH
#      404s and the else branch posts a fresh comment, stacking duplicates.
#      Both `shipped` and `green/noop` reconcile paths in steady-state.md
#      must use the REST `/issues/<M>/comments` listing (returns numeric
#      ids), not `gh pr view --json comments`. The buggy fingerprint is
#      tight — the `--json comments --jq` pair scoping for the
#      `do-work-cost-tracking` sentinel only ever appears in the cost-
#      refresh hook, so this assertion has no false positives.
assert_not_contains "$steady_state_path" \
  '--json comments --jq' \
  "steady-state.md does not use gh pr view --json comments for sentinel lookup (#264)"
# The fix uses the REST `/issues/<M>/comments` listing endpoint, which
# returns numeric REST ids compatible with the PATCH endpoint. Both call
# sites (shipped and green/noop reconcile branches) must reference it.
assert_count_at_least_across "issues/<M>/comments?per_page" 2 \
  "steady-state.md uses REST /issues/<M>/comments listing for sentinel lookup ≥2 times (#264)" \
  "$steady_state_path"

# 9) Issue #282 — steady-state's `shipped #<N> via PR #<M>` reconcile must
#    reap the issue-work agent worktree immediately (not defer to end-of-
#    session). The fix-rebase drain-phase worker can't `git switch
#    do-work/issue-<N>` if a stale issue-work worktree is still holding
#    that branch (git enforces one-worktree-per-branch). The immediate-
#    reap is what frees the branch ref. Three assertions pin this:
#    - The reap call goes through worktree-reap.sh's `reap` subcommand
#      (issue #284's single source of truth — every audit-log write must
#      route through the helper).
#    - The reap uses the `steady-state-A1-shipped` phase tag in the
#      audit-log line so the source of the reap is traceable.
#    - The local branch ref is dropped (`git branch -D do-work/issue-<N>`)
#      so a same-session fix-rebase dispatch resolves `git switch` via
#      origin's ref instead of the stale local ref.
#    - cleanup-summary.md documents the relationship to the immediate-
#      reap path so a future reader doesn't think end-of-session is the
#      only reap site.
#    - fix-rebase.md carries a defensive bail clause for the residual
#      case where the head branch is still locked (peer-alive defer,
#      transient failure of the immediate-reap path).
assert_contains "$steady_state_path" \
  '--phase "steady-state-A1-shipped"' \
  "steady-state.md immediate-reap uses the steady-state-A1-shipped phase tag (#282)"
assert_contains "$steady_state_path" \
  'git branch -D "do-work/issue-<N>"' \
  "steady-state.md immediate-reap drops the local branch ref so fix-rebase can resolve via origin (#282)"
assert_count_at_least_across 'worktree-reap.sh" reap' 2 \
  "steady-state.md routes immediate-reap calls through worktree-reap.sh reap (≥2: reaped + deferred branches) (#282)" \
  "$steady_state_path"
assert_contains "$cleanup_path" \
  'Relationship to the immediate-reap in steady-state.md' \
  "cleanup-summary.md documents the relationship to the steady-state immediate-reap (#282)"
fix_rebase_path="$repo_root/plugins/shipyard/agents/issue-worker/fix-rebase.md"
assert_contains "$fix_rebase_path" \
  'locked in another worktree' \
  "fix-rebase.md carries the defensive bail clause for the head-branch-locked residual case (#282)"

# (Issue #295) Cost-attribution banner branches on the all-vs-partial
# degraded ratio.
#
# Pre-#295 cleanup-summary.md had a single banner that read
# "<degraded_attribution_count> of <total_invocations> dispatch(es)
# used --degraded-total-only" — fine in the mixed case, but on
# always-degraded harness paths (Opus 4.7 2026-05-23 repro from #279)
# every dispatch is degraded, so "4 of 4 degraded" reads as
# session-wide failure instead of a structural harness shape.
#
# Three assertions pin the post-#295 contract:
#   - The all-degraded banner variant exists (and is distinct from the
#     partial-degraded one — different leading phrase).
#   - The per-line rule documents the branch on the ratio.
#   - steady-state.md A.0 cross-references the banner split so a reader
#     of the spec at attribution time understands the rendering split
#     that fires at cleanup time.
assert_contains "$cleanup_path" \
  'all <total_invocations> dispatch(es) this session ran on the total-tokens-only path' \
  "cleanup-summary.md carries the all-degraded banner variant (#295)"
assert_contains "$cleanup_path" \
  'branch on the ratio' \
  "cleanup-summary.md per-line rule documents the ratio branch (#295)"
assert_contains "$cleanup_path" \
  'degraded_attribution_count == total_invocations' \
  "cleanup-summary.md per-line rule names the all-degraded condition exactly (#295)"
assert_contains "$steady_state_path" \
  'branches on the ratio' \
  "steady-state.md A.0 cross-references the banner ratio branch (#295)"

# (Issue #317) Reconcile-once gate against phantom task-notification re-fires.
#
# The Claude Code harness wraps each agent chat-completion message in a
# <task-notification> envelope; wind-down messages after the agent's real
# return text get wrapped in additional notifications with the same
# task-id. Without a gate, every phantom triggers a full A → E orchestrator
# turn against an already-reconciled agent (double-bumps cost ledger,
# re-handles return, re-releases slot, etc.). See #317 for the repro and
# the harness-side-vs-orchestrator-side fix tradeoff.
#
# Five assertions pin the post-#317 contract:
#   - The struct list grew a 12th entry `reconciled_agent_ids` (named in
#     do-work.md alongside the #317 cross-ref).
#   - The opening sentence reflects the new struct count ("thirteen" post-#323, was "twelve" post-#317).
#   - steady-state.md gained the new A.−1 step (the gate body lives there).
#   - The advisory log line shape is documented exactly (so a future
#     regression that drops the gate without renaming everything else
#     breaks the test).
#   - dont.md carries the dispatch-loop bullet that forbids running
#     A.0/A.1/B/C/D on a phantom.
assert_contains "$do_work_path" \
  'reconciled_agent_ids' \
  "do-work.md struct list names reconciled_agent_ids (#317)"
assert_contains "$do_work_path" \
  'thirteen mental data structures' \
  "do-work.md opening sentence reflects post-#323 struct count (thirteen)"
assert_contains "$steady_state_path" \
  'A.−1. Reconcile-once gate' \
  "steady-state.md carries the A.−1 reconcile-once gate (#317)"
assert_contains "$steady_state_path" \
  'already reconciled; skipping A.0/A.1/B/C/D this turn' \
  "steady-state.md documents the phantom-notification advisory log line (#317)"
assert_contains "$dont_path" \
  'phantom re-fire' \
  "dont.md carries the dispatch-loop bullet forbidding A.0/A.1/B/C/D on phantoms (#317)"

# ----------------------------------------------------------------------
# (16) CI-minute discipline contract (issue #323).
#
# Five assertions pin the post-#323 contract:
#   - do-work.md struct list grew a 13th entry `ci_session_counters`.
#   - steady-state.md dispatch rule 2 carries the verify_check_failing_on_head_before_dispatch gate.
#   - drain.md per-poll action 2 carries the skip_drain_rebase / max_drain_rebases gate.
#   - cleanup-summary.md surfaces the "CI cost (#323)" block.
#   - RATIONALE.md has the "CI-minute discipline (issue #323)" worked-example section.
assert_contains "$do_work_path" \
  'ci_session_counters' \
  "do-work.md struct list names ci_session_counters (#323)"
assert_contains "$steady_state_path" \
  'verify_check_failing_on_head_before_dispatch' \
  "steady-state.md carries the stale-failure pre-dispatch gate (#323)"
assert_contains "$drain_path" \
  'skip_drain_rebase' \
  "drain.md per-poll action 2 honors ci.skip_drain_rebase (#323)"
assert_contains "$cleanup_path" \
  'CI cost (#323)' \
  "cleanup-summary.md surfaces the CI cost block (#323)"
assert_contains "$rationale_path" \
  'CI-minute discipline (issue #323)' \
  "RATIONALE.md carries the worked-example section (#323)"

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
