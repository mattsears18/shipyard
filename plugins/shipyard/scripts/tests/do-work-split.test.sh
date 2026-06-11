#!/usr/bin/env bash
# Test: commands/do-work.md is split into a thin entry router + per-phase
# files + RATIONALE.md. See issues #100 (entry + RATIONALE split) and #154
# (further split by phase).
#
# Spec runtime guarantees:
#   - thin entry + RATIONALE + every phase file exists
#   - thin entry stays under a STRUCT-DERIVED line cap (the routing-only
#     contract from #154). #394 replaced the old hardcoded magic number
#     (200 → 220 → 222 → 223, manually re-baselined on every struct-add)
#     with a cap derived from the documented orchestrator-state struct
#     count, so adding a struct updates the expectation mechanically.
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

# (2) The thin entry stays under a STRUCT-DERIVED line cap. Acceptance
#     criterion from #154 — the entry is allowed to grow if a new
#     orchestrator-state struct lands, but if it grows past the cap the
#     split is over-engineered and we'd rather know.
#
#     Issue #394: the cap used to be a hardcoded magic number that had to
#     be manually re-baselined on every struct-addition PR (200 → 220 → 222
#     → 223 across #195/#233/#246/#323/#387). Every bump was one forgotten
#     edit away from reddening main: a struct-addition PR grows do-work.md
#     by ~1 line, the stale cap fails the assertion, and if that PR merges
#     anyway `main` goes red and a `fix-main-ci` divert burns a recovery
#     cycle re-baselining the number.
#
#     The fix derives the cap mechanically from the count of documented
#     orchestrator-state struct bullets in do-work.md's "## Orchestrator
#     state" section (the top-level `- **`name`**` entries — exactly the
#     thing that grows the file when a struct is added). The budget is
#     `STRUCT_BASE + STRUCT_PER_BUDGET * <struct_count>`:
#       - STRUCT_PER_BUDGET (2) is the per-struct line allowance. Each
#         struct is a single (long) bullet line plus occasional follow-up
#         sub-paragraphs (e.g. `deferred_issues`), so 2 lines/struct tracks
#         real growth with ~1 line of headroom per struct. Adding a 15th
#         struct raises the cap by 2 automatically — no manual edit, no
#         red-main tripwire.
#       - STRUCT_BASE (197) is the fixed budget for everything that is NOT
#         a struct bullet: the section prose, the JSON schema block, the
#         helper-subcommand table, the routing table, and the file's
#         headers. It does NOT grow with struct count, so the #154 intent
#         is preserved: if the thin entry balloons with non-struct prose
#         (the "split is over-engineered, we'd rather know" tripwire), the
#         struct count is unchanged, the derived cap doesn't move, and the
#         assertion still fails loudly.
#     Current state: 14 structs → cap 225, actual 223 (2 lines headroom).
#
#     The struct-count pattern matches a top-level bold-backtick bullet
#     (`- **`<name>`**`) anchored to the "## Orchestrator state" section so
#     nested sub-bullets (the indented `**…**` paragraphs under
#     `deferred_issues`) and bold spans elsewhere in the file don't inflate
#     the count.
STRUCT_BASE=197
STRUCT_PER_BUDGET=2
# shellcheck disable=SC2016
# The backticks in the grep pattern are literal markdown characters matching
# the struct-bullet syntax (`- **`name`**`), not a command substitution.
struct_count=$(
  awk '/^## Orchestrator state$/{f=1; next} /^## /{if (f) exit} f' "$do_work_path" \
    | grep -cE '^- \*\*`[a-z0-9_]+`\*\*'
)
struct_count=${struct_count:-0}
derived_cap=$(( STRUCT_BASE + STRUCT_PER_BUDGET * struct_count ))
assert_line_count_at_most "$do_work_path" "$derived_cap" \
  "thin entry stays <= ${derived_cap} lines (#154/#394: ${STRUCT_BASE} base + ${STRUCT_PER_BUDGET}/struct × ${struct_count} structs)"

# (2b) The struct-count derivation actually found the documented structs.
#      A regression that renamed the "## Orchestrator state" heading or
#      changed the struct-bullet format would silently drop struct_count to
#      0, collapsing the derived cap back to STRUCT_BASE and re-introducing
#      a de-facto magic number. Pin a sane floor so the derivation can't
#      silently degrade (#394).
if (( struct_count >= 10 )); then
  printf '  %sPASS%s  %s (found %d structs, min 10)\n' "$GREEN" "$RESET" \
    "struct-count derivation found the orchestrator-state bullets (#394)" "$struct_count"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s (found %d structs, min 10)\n' "$RED" "$RESET" \
    "struct-count derivation found the orchestrator-state bullets (#394)" "$struct_count"
  fail=$((fail+1))
fi

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
  'fifteen mental data structures' \
  "do-work.md opening sentence reflects post-#437 struct count (fifteen)"
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

# (16.5) Progress-based drain termination replaces the wall-clock ceiling (issue #374).
#   - drain.md tracks per-PR head_unchanged_since and exits on settled_minutes.
#   - drain.md's ultimate ceiling is max_drain_hours, NOT the old hardcoded 120 min.
#   - the old "120-min" / "120 min" wall-clock ceiling string is gone from drain.md.
assert_contains "$drain_path" \
  'head_unchanged_since' \
  "drain.md tracks per-PR head_unchanged_since for progress-based settle (#374)"
assert_contains "$drain_path" \
  'max_drain_hours' \
  "drain.md's ultimate ceiling is max_drain_hours, not 120 min (#374)"
assert_contains "$drain_path" \
  'settled_minutes' \
  "drain.md settle threshold is the configurable settled_minutes (#374)"
assert_not_contains "$drain_path" \
  'Hard ceiling: 120 min' \
  "drain.md no longer carries the 'Hard ceiling: 120 min' behavioral rule (#374; a historical-reference mention is fine)"

# (17) Per-completion worktree reap at step B (issue #334).
#
# The A.1 `shipped #<N>` reap (#282) only fires on issue-work-mode `shipped`
# returns where the worker's head branch is `do-work/issue-<N>`. The other
# return shapes (fix-checks-only `green`/`noop`, fix-rebase `rebased`,
# synthetic-divert `shipped main-ci-fix`/`shipped pr-batch-fix`, `blocked`
# from any mode) leave the worktree stranded until end-of-session cleanup
# — locking subsequent same-session fix-rebase dispatches against the same
# head branch out of `git switch` (git enforces one-worktree-per-branch).
# Repro: session c6afe19d-a6a6-40e4-9eb8-de409d046a49 — three fix-checks
# workers returned cleanly but their worktrees persisted; drain-phase
# fix-rebase workers for the same branches bailed within 25s on the lock
# collision. The fix adds a per-completion reap at step B (Release the
# slot) that runs against the just-released slot's agent-id-derived
# worktree path, covering every return-handler path.
#
# Five assertions pin the post-#334 contract:
#   - Step B carries the new phase tag `steady-state-B-completion` in its
#     audit-log call so an operator can distinguish per-completion reaps
#     from the A.1 same-turn reap (`steady-state-A1-shipped`) and the
#     end-of-session sweep (no phase).
#   - Step B derives the worktree path from `completed_agent_id`
#     (different shape than A.1's branch-walk) so a future reader knows
#     the two reap sites intentionally use different identification
#     strategies.
#   - Step B routes through `worktree-reap.sh reap` (issue #284's
#     single-source-of-truth for audit-log writes).
#   - Step B explicitly enumerates the return shapes the A.1 path misses
#     (`green #<M>` from fix-checks-only, `rebased #<M>` from fix-rebase,
#     synthetic-divert returns) so the rationale survives the next
#     re-organization.
#   - The A.1 `shipped` reap is NOT removed — both paths must coexist
#     (A.1 stays for the merge-train coordination case from #282; step
#     B is the universal sweep). The duplicate-reap is harmless because
#     `git worktree remove --force` against a missing path is a silent
#     no-op.
assert_contains "$steady_state_path" \
  '--phase "steady-state-B-completion"' \
  "steady-state.md per-completion reap uses the steady-state-B-completion phase tag (#334)"
assert_contains "$steady_state_path" \
  'completed_agent_id' \
  "steady-state.md step B derives the worktree path from completed_agent_id (#334)"
assert_contains "$steady_state_path" \
  'green #<M>' \
  "steady-state.md step B enumerates fix-checks green return as a missed-by-A.1 case (#334)"
assert_contains "$steady_state_path" \
  'rebased #<M>' \
  "steady-state.md step B enumerates fix-rebase rebased return as a missed-by-A.1 case (#334)"
assert_contains "$steady_state_path" \
  'steady-state-A1-shipped' \
  "steady-state.md retains the A.1 shipped-reap path (regression guard — #282 must coexist with #334)"

# (18) Latest-per-name `statusCheckRollup` projection (issue #333).
#
# `gh pr view --json statusCheckRollup` returns the union of every check run
# for the PR's head SHA — including superseded runs from earlier triggers.
# A check that ran, failed, was re-triggered, and passed appears twice
# (one FAILURE entry + one SUCCESS entry). A naïve walk like
# `.statusCheckRollup[] | select(.conclusion == "FAILURE")` false-positives
# on every such PR, causing two distinct failure modes:
#
#   - fix-rebase bails ("PR has failing checks — needs fix-checks") on a
#     PR that's actually green, leaving DIRTY PRs unrebased indefinitely.
#   - fix-checks workers and the orchestrator's trust-but-verify spot-check
#     keep re-queueing the PR into `failed_prs`, where each dispatch
#     returns `noop: already green`. Wastes a dispatch slot + ~50k tokens
#     per affected PR.
#
# Both observed in lightwork session c6afe19d-a6a6-40e4-9eb8-de409d046a49
# against PRs #1193 and #1211 — ~270k tokens lost across 3 dispatch slots.
#
# The fix is a `group_by(.name) | map(sort_by(.completedAt // .startedAt //
# "") | last)` jq reduction applied at every rollup walk: in fix-rebase
# step 2, fix-checks-only return contract, fix-failing-prs-batch
# pre-flight, setup.md steps 3c/4.5b/5, steady-state.md trust-but-verify
# + unrecognized-return-string + 2a stale-failure paths, and drain.md's
# R_new/D_dirty bookkeeping. The worker-preamble snapshot+return pattern
# carries the same projection so every worker mode's check categorization
# is consistent with the orchestrator's reconcile path.
#
# Twelve assertions pin the post-#333 contract:
fix_rebase_path333="$repo_root/plugins/shipyard/agents/issue-worker/fix-rebase.md"
fix_checks_path333="$repo_root/plugins/shipyard/agents/issue-worker/fix-checks-only.md"
fix_batch_path333="$repo_root/plugins/shipyard/agents/issue-worker/fix-failing-prs-batch.md"
issue_work_path333="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"
worker_preamble_path333="$repo_root/plugins/shipyard/skills/worker-preamble/SKILL.md"

assert_contains "$fix_rebase_path333" \
  'group_by(.name)' \
  "fix-rebase.md step 2 uses group_by(.name) latest-per-name projection (#333)"
assert_contains "$fix_rebase_path333" \
  'issues/333' \
  "fix-rebase.md cites issue #333 as the source of the latest-per-name rule"
assert_contains "$fix_checks_path333" \
  'group_by(.name)' \
  "fix-checks-only.md return-contract uses group_by(.name) latest-per-name projection (#333)"
assert_contains "$fix_checks_path333" \
  'issues/333' \
  "fix-checks-only.md cites issue #333 as the source of the latest-per-name rule"
assert_contains "$fix_batch_path333" \
  'group_by(.name)' \
  "fix-failing-prs-batch.md pre-flight uses group_by(.name) latest-per-name projection (#333)"
assert_contains "$fix_batch_path333" \
  'issues/333' \
  "fix-failing-prs-batch.md cites issue #333 as the source of the latest-per-name rule"
assert_contains "$setup_path" \
  'group_by(.name)' \
  "setup.md steps 3c/4.5b/5 use group_by(.name) latest-per-name projection (#333)"
assert_contains "$setup_path" \
  'issues/333' \
  "setup.md cites issue #333 as the source of the latest-per-name rule"
assert_contains "$drain_path" \
  'group_by(.name)' \
  "drain.md R_new/D_dirty bookkeeping uses group_by(.name) latest-per-name projection (#333)"
assert_contains "$drain_path" \
  'stale-rollup-detected' \
  "drain.md emits [stale-rollup-detected] advisory when stale FAILURE entries are filtered (#333)"
assert_contains "$steady_state_path" \
  'group_by(.name)' \
  "steady-state.md trust-but-verify / unrecognized-return / 2a stale-failure paths use group_by(.name) projection (#333)"
assert_contains "$worker_preamble_path333" \
  'group_by(.name)' \
  "worker-preamble's snapshot+return pattern uses group_by(.name) projection (#333)"
assert_contains "$issue_work_path333" \
  'group_by(.name)' \
  "issue-work.md step 7 snapshot uses group_by(.name) projection (#333)"

# (19) Wide-fetch + client-side filter for the backlog (issue #332).
#
# The previous backlog-fetch shape used a server-side
# `--search 'is:issue is:open -linked:pr -label:blocked:agent ...'`
# qualifier to do the eligibility filter on GitHub's side. That shape
# silently dropped resumable-work issues — a `lightwork` session at
# 2026-05-25 exposed 14 issues from a backlog of 29 open ones (~50% miss
# rate) and confidently entered drain while 15 workable issues sat
# invisible to the dispatch queue. Root cause: `-linked:pr` excludes
# issues that ever had a linked PR opened, even when that PR has since
# been closed/abandoned/superseded; the resumable-work case (prior
# session opened a PR that got closed before merge, issue still self-
# assigned to @me) is exactly the bucket the filter was supposed to NOT
# exclude.
#
# The fix lands in three call-sites that MUST stay in lockstep:
#   - setup.md step 4 (the canonical backlog fetch + client-side filter)
#   - drain.md termination-assertion step 4 (the fresh-fetch verification)
#   - steady-state.md step C lightweight backlog re-check (every-dispatch refill)
#
# Server-side: only `--state open` plus any `--label <L>` qualifiers passed
# at invocation. All other eligibility checks — author trust, dispatch-gate
# labels, assignee≠@me, `Blocked by #N` still-open, closed-by-@me-authored-
# healthy-PR — move to client-side. Defense in depth: a new
# `unfiltered_open_count=<u>` token on the step-E invariant line surfaces
# the wide-fetch universe size BEFORE the client-side filter ran, so a
# regression in the filter pass produces a visible `raw_backlog=0 against
# unfiltered_open_count=29` smell instead of a silent false-empty.
#
# These assertions pin the post-#332 contract:
assert_contains "$setup_path" \
  'issues/332' \
  "setup.md cites issue #332 as the source of the wide-fetch rework"
assert_contains "$setup_path" \
  'Wide fetch — server-side filter is ONLY' \
  "setup.md step 4 documents the wide-fetch shape (server-side only --state open)"
assert_contains "$setup_path" \
  'Why the server-side filter is intentionally wide' \
  "setup.md step 4 explains why the server-side filter was widened (#332)"
# shellcheck disable=SC2016
# Backticks here are literal characters in the markdown needle, not a command substitution.
assert_contains "$setup_path" \
  'have an open linked PR authored by `@me` AND that PR is healthy' \
  "setup.md step 4 documents the @me + healthy gate for closed-by-open-pr (#332)"
assert_contains "$setup_path" \
  'closed_by_open_healthy_pr' \
  "setup.md step 4 ships the healthy-PR jq shape variable name"

# The narrower server-side qualifier must be GONE from setup.md's canonical
# step-4 fetch block — its presence in prose is OK as a historical reference,
# but the code-block fetch must not invoke it anymore. Use a stricter form
# to verify: the previous fetch's exact `--search` string can't be present
# in a fenced code block. (We assert via the absence of the full literal
# previous-form string from the file, accepting that the historical-context
# paragraph may quote a *backticked inline* form. The previous full literal
# was the line with all 8 label exclusions; that exact contiguous string is
# only ever emitted by an invocation, not by descriptive prose.)
assert_not_contains "$setup_path" \
  "is:issue is:open -linked:pr -label:blocked:agent -label:blocked:agent-hard -label:wontfix -label:needs-design -label:needs-triage -label:discussion -label:needs-refinement -label:needs-human-review" \
  "setup.md step 4 no longer invokes the pre-#332 narrow server-side search qualifier"

assert_contains "$drain_path" \
  'issues/332' \
  "drain.md cites issue #332 as the source of the wide-fetch rework"
assert_contains "$drain_path" \
  'Wide fetch — server-side filter is purely --state open' \
  "drain.md termination-assertion step 4 documents the wide-fetch shape"
assert_contains "$drain_path" \
  'unfiltered_open_count' \
  "drain.md termination-assertion step 4 stamps unfiltered_open_count (#332)"

# The narrower previous search qualifier must be gone from drain.md too —
# this was the second of the three call-sites the issue listed as needing
# the fix.
assert_not_contains "$drain_path" \
  "is:issue is:open -linked:pr -label:blocked:agent -label:blocked:agent-hard -label:wontfix -label:needs-design -label:needs-triage -label:discussion -label:needs-refinement -label:needs-human-review" \
  "drain.md termination-assertion step 4 no longer invokes the pre-#332 narrow server-side search qualifier"

assert_contains "$steady_state_path" \
  'issues/332' \
  "steady-state.md cites issue #332 as the source of the wide-fetch rework"
assert_contains "$steady_state_path" \
  'wide-fetch shape' \
  "steady-state.md step C lightweight backlog re-check references the wide-fetch shape (#332)"
assert_contains "$steady_state_path" \
  'unfiltered_open_count=<u>' \
  "steady-state.md step E invariant line includes the unfiltered_open_count token (#332)"
assert_contains "$steady_state_path" \
  'unfiltered_open_count=<u>` is the per-turn evidence flag' \
  "steady-state.md documents what unfiltered_open_count means (#332)"
assert_contains "$steady_state_path" \
  'Divergence smell' \
  "steady-state.md documents the raw_backlog=0 against unfiltered_open_count>0 divergence-smell rule (#332)"

# The lightweight backlog re-check in steady-state.md previously documented
# the filter shape as `-linked:pr, the standard label exclusions` — the
# post-#332 rewrite removes that phrasing in favor of pointing at setup.md's
# wide-fetch + client-side filter as the canonical shape. Pin the removal
# so a future rewrite doesn't accidentally re-introduce the broken framing.
assert_not_contains "$steady_state_path" \
  "the same filter (\`--state open\`, \`-linked:pr\`, the standard label exclusions" \
  "steady-state.md step C lightweight re-check no longer describes the pre-#332 filter shape inline"

# (20) Orchestrator-side next-available-version computation for in-flight
#      session_prs (issue #339).
#
# On repos where every PR cuts a release by bumping a shared manifest row
# (e.g. plugins/shipyard/.claude-plugin/plugin.json .version), sequential
# dispatch at C=1 is not enough to prevent version-row collisions: the
# second worker is dispatched against origin/main while the first PR is
# still in flight (auto-merge armed, checks pending — typical 2-5 min
# window), both naïvely read the same pre-merge version, and the drain-
# phase fix-rebase pays the disambiguation tax on every collision.
#
# The fix lands in three coordinated surfaces:
#   - steady-state.md step C issue-work dispatch — computes
#     next_available_version from session_prs before composing the prompt,
#     gated on `version_coordination.enabled` config key
#   - issue-work.md step 4 — worker MUST honor any next_available_version
#     paragraph in its dispatch prompt rather than computing from
#     origin/main HEAD (defense-in-depth doc change so the contract is
#     load-bearing on the worker side too)
#   - shipyard.config.schema.json + scripts/shipyard-config.sh defaults
#     — new `version_coordination` config block with four keys (enabled,
#     manifest_path, manifest_version_jq, changelog_path)
#
# These assertions pin the post-#339 contract:
issue_work_path339="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"
schema_path339="$repo_root/plugins/shipyard/schemas/shipyard.config.schema.json"
config_sh_path339="$repo_root/plugins/shipyard/scripts/shipyard-config.sh"

assert_contains "$steady_state_path" \
  'issues/339' \
  "steady-state.md cites issue #339 as the source of the next-available-version rework"
assert_contains "$steady_state_path" \
  'Next-available-version computation' \
  "steady-state.md step C documents the next-available-version computation (#339)"
assert_contains "$steady_state_path" \
  'version_coordination.enabled' \
  "steady-state.md step C reads the version_coordination.enabled config key (#339)"
assert_contains "$steady_state_path" \
  'version_coordination.manifest_path' \
  "steady-state.md step C reads the version_coordination.manifest_path config key (#339)"
assert_contains "$steady_state_path" \
  'max_inflight_version' \
  "steady-state.md step C walks session_prs to compute max in-flight version (#339)"
assert_contains "$steady_state_path" \
  'next_available_version' \
  "steady-state.md step C produces next_available_version variable for the prompt (#339)"
# The injected dispatch-prompt paragraph must be present so a reader can
# see the exact shape the orchestrator emits — and so the worker spec's
# "If you see this paragraph" rule has a referent.
assert_contains "$steady_state_path" \
  'Next-available version (orchestrator-supplied)' \
  "steady-state.md step C ships the dispatch-prompt paragraph for next-available-version (#339)"

assert_contains "$issue_work_path339" \
  'issues/339' \
  "issue-work.md cites issue #339 as the source of the coordination contract"
assert_contains "$issue_work_path339" \
  'Coordination-managed paths' \
  "issue-work.md step 4 documents coordination-managed paths (#339)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle, not a command substitution.
assert_contains "$issue_work_path339" \
  'honor `next_available_version` when provided' \
  "issue-work.md step 4 establishes the honor-the-orchestrator-value contract (#339)"
assert_contains "$issue_work_path339" \
  'Do NOT compute your own version by reading' \
  "issue-work.md step 4 forbids the bump-from-origin/main path when the paragraph is present (#339)"

# Schema must register the new config block — four keys.
assert_contains "$schema_path339" \
  '"version_coordination"' \
  "shipyard.config.schema.json registers the version_coordination block (#339)"
assert_contains "$schema_path339" \
  '"manifest_path"' \
  "schema's version_coordination block names manifest_path (#339)"
assert_contains "$schema_path339" \
  '"manifest_version_jq"' \
  "schema's version_coordination block names manifest_version_jq (#339)"
assert_contains "$schema_path339" \
  '"changelog_path"' \
  "schema's version_coordination block names changelog_path (#339)"

# Defaults must include the new block so consumers reading via
# shipyard-config.sh get... never trip a key-not-present error.
assert_contains "$config_sh_path339" \
  '"version_coordination"' \
  "shipyard-config.sh defaults include the version_coordination block (#339)"
assert_contains "$config_sh_path339" \
  '"manifest_version_jq": ".version"' \
  "shipyard-config.sh defaults set manifest_version_jq to .version (#339)"

# (20.5) CHANGELOG-serialization gate + silent-direct-merge warning (#438).
#
# On a version-coordinated repo (version_coordination.enabled + a non-empty
# changelog_path) where every PR appends a top-of-file CHANGELOG entry,
# parallel drain rebases cannot converge — each merge moves the CHANGELOG
# insert point, re-DIRTYing every sibling that just rebased. The fix lands
# in four coordinated surfaces:
#   - schema + config defaults — new `serialize_drain_rebase` boolean key in
#     the version_coordination block (default true)
#   - drain.md per-poll action 2 — a serialization gate that caps effective
#     drain-rebase concurrency to 1 when the gate is engaged
#   - setup.md step 1.3 — a setup-time warning when allow_auto_merge=false +
#     admin (the silent-direct-merge shape that breaks C>=2 coordination)
schema_path438="$repo_root/plugins/shipyard/schemas/shipyard.config.schema.json"
config_sh_path438="$repo_root/plugins/shipyard/scripts/shipyard-config.sh"

assert_contains "$schema_path438" \
  '"serialize_drain_rebase"' \
  "shipyard.config.schema.json registers version_coordination.serialize_drain_rebase (#438)"
assert_contains "$config_sh_path438" \
  '"serialize_drain_rebase": true' \
  "shipyard-config.sh defaults set version_coordination.serialize_drain_rebase to true (#438)"

assert_contains "$drain_path" \
  'issues/438' \
  "drain.md cites issue #438 as the source of the CHANGELOG-serialization gate"
assert_contains "$drain_path" \
  'serialize_drain_rebase' \
  "drain.md per-poll action 2 reads version_coordination.serialize_drain_rebase (#438)"
assert_contains "$drain_path" \
  'CHANGELOG-serialization gate' \
  "drain.md documents the CHANGELOG-serialization gate (#438)"

assert_contains "$setup_path" \
  'silent-direct-merge' \
  "setup.md step 1.3 detects the silent-direct-merge repo shape (#438)"
assert_contains "$setup_path" \
  'allow_auto_merge' \
  "setup.md step 1.3 reads allow_auto_merge to warn about the direct-merge shape (#438)"

# (20b) Step 1.3 detector broadened to ALSO fire on admin + zero required
#       status checks, independent of allow_auto_merge (#465). The original
#       #438 gate only checked allow_auto_merge==false; on a repo with
#       allow_auto_merge=true but no required checks, an admin's --auto still
#       direct-merges immediately and version coordination breaks silently.
assert_contains "$setup_path" \
  'required_status_checks' \
  "setup.md step 1.3 reads the default branch's required_status_checks (#465)"
assert_contains "$setup_path" \
  'required_checks_count' \
  "setup.md step 1.3 gates on the required-checks count for the #465 case"
assert_contains "$setup_path" \
  'issues/465' \
  "setup.md step 1.3 cites issue #465 as the source of the broadened gate"

# (21) Step 0.7 bg cleanup group survives zsh's nomatch option when no
#      agent-* worktrees exist (issue #335).
#
# The bg subshell runs five cleanup sub-steps in sequence: 1.6 orphan
# session-file sweep → 1.6.5 orphan orchestrator-worktree sweep → 3a
# label create → 3b agent-worktree reap → 3c orphan-branch triage. Step
# 3b's loop was historically a bare `for wt_dir in .git/worktrees/agent-*`
# glob — under zsh's default `nomatch` option, an unmatched glob raises
# a fatal error and aborts the entire bg subshell, taking out the
# remaining sub-steps (3c orphan-branch triage in particular). The fix
# replaces the bare glob with a `find` substitution that exits 0 on no
# matches, so the loop body simply doesn't iterate and execution
# proceeds to 3c.
#
# The same hardening lands in two surfaces (the canonical bg group and
# the standalone "3b. Reap stale agent worktrees" documentation block)
# so a reader of either copy sees the same pattern.
assert_contains "$setup_path" \
  'issues/335' \
  "setup.md cites issue #335 as the source of the bg-cleanup-group zsh-nomatch fix"
# The bare-glob form must be gone from any `for wt_dir in ...` line.
# We assert the literal `for wt_dir in .git/worktrees/agent-*; do` form
# is absent — the regression guard against re-introducing the zsh hazard.
assert_not_contains "$setup_path" \
  'for wt_dir in .git/worktrees/agent-*' \
  "setup.md no longer uses the bare agent-* glob in any for-loop (zsh nomatch hazard, #335)"
# The hardened replacement must be present in at least one place — the
# bg cleanup group's 3b loop AND the standalone canonical implementation
# both got the same find-based rewrite, so the substring should appear
# twice. Use `assert_count_at_least_across` (single file, min 2).
assert_count_at_least_across \
  "find .git/worktrees -maxdepth 1 -type d -name 'agent-*'" \
  2 \
  "setup.md's hardened find-based loop appears in both the bg group and the standalone block (#335)" \
  "$setup_path"

# (22) Auto-merge outcome categorization handles silent direct-merge case
#      (issue #340).
#
# `gh pr merge --auto --merge --delete-branch` does NOT always error when
# `allow_auto_merge: false` is set at the repo level. When the dispatching
# user has admin permissions, gh silently falls through to a direct merge:
# the PR lands immediately (if CI is green) or queues for merge (if
# pending). The call returns exit 0, `autoMergeRequest` is null, and a
# worker that decides the outcome from the call's exit status alone returns
# `auto-merge: unavailable — needs manual merge` even when the PR is
# already `state: MERGED`. Repro: 5 PRs in a 26-PR session against
# `mattsears18/mattsears18.com` (`allow_auto_merge: false`) all returned
# `unavailable` despite landing as MERGED.
#
# The fix requires three surfaces to read the post-call PR state (not just
# the merge call's exit status) to decide which of three auto-merge
# outcomes applies — `enabled`, `merged-direct`, or genuinely-`unavailable`:
#   - worker-preamble's "Auto-merge + snapshot-and-return pattern" gains a
#     step 1.5 categorization block keyed on `(state, autoMergeRequest)`.
#   - issue-work.md step 7 walks the same post-call snapshot before
#     emitting the return string.
#   - issue-work.md step 8 adds the new `auto-merge: merged-direct` return
#     suffix alongside the existing `enabled` / `unavailable` / `gated`
#     options.
# inline-trivial.md (step E) references the worker-preamble categorization
# by link to keep the inline path consistent with the worker path.
worker_preamble_path340="$repo_root/plugins/shipyard/skills/worker-preamble/SKILL.md"
issue_work_path340="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"
inline_trivial_path340="$repo_root/plugins/shipyard/commands/do-work/inline-trivial.md"

assert_contains "$worker_preamble_path340" \
  'issues/340' \
  "worker-preamble cites issue #340 as the source of the post-call categorization rule"
assert_contains "$worker_preamble_path340" \
  'merged-direct' \
  "worker-preamble names the merged-direct outcome explicitly (#340)"
assert_contains "$worker_preamble_path340" \
  'autoMergeRequest' \
  "worker-preamble's step 1.5 reads autoMergeRequest from the post-call snapshot (#340)"
assert_contains "$worker_preamble_path340" \
  'allow_auto_merge: false' \
  "worker-preamble explains the silent-direct-merge condition (allow_auto_merge:false + admin perms, #340)"
assert_contains "$issue_work_path340" \
  'issues/340' \
  "issue-work.md cites issue #340 as the source of the post-call categorization rule"
assert_contains "$issue_work_path340" \
  'merged-direct' \
  "issue-work.md step 8 includes the auto-merge: merged-direct return suffix (#340)"
assert_contains "$issue_work_path340" \
  'autoMergeRequest' \
  "issue-work.md step 7 reads autoMergeRequest from the post-call snapshot (#340)"
assert_contains "$inline_trivial_path340" \
  'issues/340' \
  "inline-trivial.md cites issue #340 for the post-call categorization rule"
assert_contains "$inline_trivial_path340" \
  'merged-direct' \
  "inline-trivial.md names merged-direct as one of the three outcomes (#340)"

# (23) Pre-scope Detector 2 — Claude-Code self-modification target proposals
#      (issue #348).
#
# Parallel to Detector 1 (#346)'s `.github/workflows/` defer, Detector 2
# catches issue bodies that propose changes to `.claude/settings.json`,
# `.claude/settings.local.json`, or `.mcp.json` at the repo root — Claude
# Code's auto-mode classifier treats edits to these paths as
# Self-Modification and applies a HARD BLOCK not cleared by user intent,
# so worker dispatch always fails at the Edit step. The detector synthesizes
# a `human-decision-required` defer before the scope-agent dispatch.
#
# Surfaces:
#   - setup.md step 6 grows a `Detector 2 — Claude-Code self-modification
#     target proposal` block under "Pre-scope orchestrator-side detectors".
#   - The `evidence_pointer` validator's `human-decision-required` rule
#     accepts the new structured prefixes `Proposes .claude/settings.json`,
#     `Proposes .claude/settings.local.json`, `Proposes .mcp.json`.
#   - The per-class shape table example gains the Claude-Code self-mod
#     example to make the new accepted shape discoverable.
#   - drain.md 5.a/5.b's re-validation cross-references mention the Claude-
#     Code path family so a re-validation that re-detects one of those
#     paths synthesizes the defer again rather than promoting to backlog.
#   - RATIONALE gains a "Step 6 — Detector 2" section documenting the
#     failure mode, the narrow-path-set rationale (excluding CLAUDE.md),
#     and the why-same-class rationale.
setup_path348="$repo_root/plugins/shipyard/commands/do-work/setup.md"
drain_path348="$repo_root/plugins/shipyard/commands/do-work/drain.md"
rationale_path348="$repo_root/plugins/shipyard/commands/do-work-RATIONALE.md"

assert_contains "$setup_path348" \
  'Detector 2 — Claude-Code self-modification target proposal' \
  "setup.md step 6 names Detector 2 explicitly (#348)"
assert_contains "$setup_path348" \
  '.claude/settings.json' \
  "setup.md Detector 2 matches .claude/settings.json (#348)"
assert_contains "$setup_path348" \
  '.claude/settings.local.json' \
  "setup.md Detector 2 matches .claude/settings.local.json (#348)"
assert_contains "$setup_path348" \
  '.mcp.json' \
  "setup.md Detector 2 matches .mcp.json (#348)"
assert_contains "$setup_path348" \
  'Claude-Code self-modification HARD BLOCK requires human application' \
  "setup.md Detector 2's evidence_pointer shape is the self-mod HARD BLOCK prefix (#348)"
assert_contains "$setup_path348" \
  'Proposes .claude/settings.json' \
  "setup.md validator's human-decision-required rule accepts Proposes .claude/settings.json prefix (#348)"
assert_contains "$setup_path348" \
  'Proposes .mcp.json' \
  "setup.md validator's human-decision-required rule accepts Proposes .mcp.json prefix (#348)"
assert_contains "$setup_path348" \
  'issues/348' \
  "setup.md cites issue #348 as the source of Detector 2"
assert_contains "$drain_path348" \
  '.claude/settings.json' \
  "drain.md 5.a/5.b re-validation cross-reference mentions the Claude-Code self-mod path family (#348)"
assert_contains "$rationale_path348" \
  'Detector 2: Claude-Code self-modification target proposals (issue #348)' \
  "RATIONALE has a Step 6 — Detector 2 section (#348)"
assert_contains "$rationale_path348" \
  'issues/348' \
  "RATIONALE cites issue #348 as the source of Detector 2"

# (24) Batch-dispatch version pre-allocation via a session-local version_cursor
#      (issue #437).
#
# The #339 next-available-version computation walks `session_prs` for OPEN PRs
# to find the highest claimed manifest version. At the initial pool fill
# (setup.md step 7) and any simultaneous multi-dispatch (steady-state.md step C
# multi-fill), the sibling workers' PRs are NOT open yet, so every worker in
# the batch reads the same floor (main's version) and the per-dispatch walk
# computes the same next_available_version for all of them. Result: the first
# C>=2 batch all claim main+1 and N-1 of them go DIRTY on the version row,
# eating a drain-rebase storm. Repro: session do-work-20260531T172554Z-8676,
# --concurrency 4 — the first batch all picked 1.8.2; 3 of 4 went DIRTY.
#
# The fix introduces a session-local `version_cursor` high-water mark that
# tracks the highest version slot CLAIMED BY DISPATCH (not just by open PRs).
# The next-available-version computation seeds from `max(version_cursor,
# session_prs-walk)` and advances the cursor to the value it hands out, so
# sibling workers dispatched in the same batch (before any PR is open) still
# receive distinct monotonic slots (main+1, main+2, ... main+N).
#
# Surfaces:
#   - do-work.md struct list grows a 15th entry `version_cursor` (session-local).
#   - do-work.md opening sentence count word advances (thirteen -> fifteen,
#     pinned by the "fifteen mental data structures" assertion above).
#   - steady-state.md step C's next-available-version computation seeds from
#     and advances version_cursor.
#   - setup.md step 7 (initial pool fill) pre-allocates monotonic versions
#     across the batch via the cursor before firing the parallel Agent burst.
assert_contains "$do_work_path" \
  'version_cursor' \
  "do-work.md struct list names version_cursor (#437)"
assert_contains "$do_work_path" \
  'issues/437' \
  "do-work.md cites issue #437 as the source of version_cursor"
assert_contains "$steady_state_path" \
  'issues/437' \
  "steady-state.md cites issue #437 as the source of the batch pre-allocation fix"
assert_contains "$steady_state_path" \
  'version_cursor' \
  "steady-state.md step C seeds/advances version_cursor in the version computation (#437)"
assert_contains "$setup_path" \
  'issues/437' \
  "setup.md cites issue #437 as the source of the batch pre-allocation fix"
assert_contains "$setup_path" \
  'version_cursor' \
  "setup.md step 7 pre-allocates monotonic versions across the batch via version_cursor (#437)"

# (25) Pre-push verification runs a superset of CI's required checks, not a
#      hand-picked subset (#453).
#
# An issue-work worker that verifies an ad-hoc subset of the repo's test
# suites can ship a change that passes its subset and reds a CI gate it
# skipped. On a repo where PRs direct-merge (admin on an
# `allow_auto_merge: false` repo), that surfaces as broken `main` rather
# than a held-back red PR. Repro: PR #441 direct-merged green-locally yet
# reddened main because the worker ran do-work-split / config / init-config
# / shellcheck but NOT claude-plugin-root-preamble.test.sh — the suite
# guarding the file it edited. The fix lands in issue-work.md step 4:
# make the local gate a superset of CI's required checks, and discover the
# suites the way CI discovers them (glob/find) rather than from memory.
issue_work_path453="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"

assert_contains "$issue_work_path453" \
  'issues/453' \
  "issue-work.md cites issue #453 as the source of the superset-of-CI verification contract"
assert_contains "$issue_work_path453" \
  'superset of CI' \
  "issue-work.md step 4 establishes the local-gate-is-a-superset-of-CI contract (#453)"
assert_contains "$issue_work_path453" \
  'Discover the suites the way CI discovers them' \
  "issue-work.md step 4 tells the worker to mirror CI's discovery command, not enumerate from memory (#453)"
# shellcheck disable=SC2016
# Backticks/single-quotes are literal markdown punctuation in the needle.
assert_contains "$issue_work_path453" \
  'guarded paths intersect your PR' \
  "issue-work.md step 4 requires running every discovered suite whose guarded paths intersect the changed files (#453)"

# (N) Primary-leak guard derives PRIMARY_CHECKOUT independent of cwd (#452).
#
# The harness can silently relocate the orchestrator's own Bash-tool cwd
# into a just-returned dispatched agent's `agent-*` isolation worktree on a
# reconcile turn. The original A.0.6 / drain-entry derivation read
# `git rev-parse --show-toplevel` and stripped only an `orchestrator-*`
# suffix — so when cwd had leaked into an `agent-*` worktree, the strip
# didn't match, PRIMARY_CHECKOUT pointed at the AGENT worktree, and the
# guard read that worktree's `do-work/issue-<N>` branch as the "primary
# branch", ran `checkout <default>` against the wrong tree, and emitted a
# phantom `[primary-leak] restored primary …` line while never inspecting
# the real primary.
#
# The fix derives the primary from `git worktree list --porcelain`'s first
# `worktree ` entry (always the main working tree, regardless of cwd), with
# the cwd-strip retained only as a fallback — now covering `agent-*` too.
# Both surfaces (steady-state.md A.0.6 + drain.md drain-entry guard) get the
# same derivation.
for f in "$steady_state_path" "$drain_path"; do
  fname=$(basename "$f")
  # The cwd-independent porcelain derivation must be present.
  assert_contains "$f" \
    'git worktree list --porcelain' \
    "$fname primary-leak guard derives PRIMARY_CHECKOUT from worktree list, not cwd (#452)"
  # The fallback strip must now ALSO cover agent-* (the leaked-cwd case),
  # not just orchestrator-*.
  assert_contains "$f" \
    '*/.claude/worktrees/agent-*)' \
    "$fname fallback cwd-strip covers the agent-* leak case (#452)"
  assert_contains "$f" \
    'issue #452' \
    "$fname cites issue #452 as the source of the cwd-independent derivation"
done

# (26) Per-PR release rule — worker bumps in its own PR, never defers (#460).
#
# Repos that carry a release-process rule in CLAUDE.md (e.g. this repo's
# "ALWAYS cut a release when a PR merges") require every merged PR to bump
# the manifest version + add a CHANGELOG entry IN THE SAME PR. The
# issue-work spec previously gave no deterministic contract for this, so
# sibling workers in one session diverged: one deferred the bump (its PR
# merged-direct leaving main undocumented, forcing a separate catch-up
# release PR that nearly collided on the version row), the other included
# it. The fix lands in issue-work.md step 4: when a per-PR release rule is
# present, including the bump is mandatory and deferral is forbidden.
issue_work_path460="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"

assert_contains "$issue_work_path460" \
  'issues/460' \
  "issue-work.md cites issue #460 as the source of the per-PR-release-rule contract"
assert_contains "$issue_work_path460" \
  'bump in your own PR, never defer' \
  "issue-work.md step 4 establishes the bump-in-PR-never-defer contract (#460)"
assert_contains "$issue_work_path460" \
  'including the bump in your own PR is mandatory, not optional' \
  "issue-work.md step 4 makes the in-PR bump mandatory when a per-PR release rule is present (#460)"
assert_contains "$issue_work_path460" \
  'composes with' \
  "issue-work.md step 4 documents how the release rule composes with the next_available_version coordination contract (#460)"

# (27) merged-direct → merged-direct-ungated refinement (issue #457).
#
# On a repo where the dispatching user has admin AND no required status
# checks are configured, the issue-work step-6 `gh pr merge --auto` silently
# falls through to an immediate admin direct-merge — landing the PR while
# its CI is still IN_PROGRESS. The "auto-merge waits for green" guarantee
# does not hold, and a post-merge build failure reddens main with no
# PR-level gate having caught it. The fix splits the existing `merged-direct`
# outcome (#340) by the check-rollup snapshot: a direct-merge that landed
# green stays `merged-direct`; a direct-merge that landed while checks were
# pending/failing becomes `merged-direct-ungated`, which the orchestrator
# treats as an unconditional main-CI refresh trigger so a fix-main-ci divert
# catches the fallout.
#   - worker-preamble step 1.5 documents the split + the admin/no-required-
#     checks precondition.
#   - issue-work.md step 7 refines the suffix off the rollup; step 8 adds
#     the `auto-merge: merged-direct-ungated` return shape.
#   - inline-trivial.md mirrors the refinement on the inline path.
#   - steady-state.md step D trigger 1 fires unconditionally for the
#     merged-direct-ungated sub-case (exempt from the adaptive-skip carve-out).
worker_preamble_path457="$repo_root/plugins/shipyard/skills/worker-preamble/SKILL.md"
issue_work_path457="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"
inline_trivial_path457="$repo_root/plugins/shipyard/commands/do-work/inline-trivial.md"

assert_contains "$worker_preamble_path457" \
  'merged-direct-ungated' \
  "worker-preamble names the merged-direct-ungated refinement (#457)"
assert_contains "$worker_preamble_path457" \
  'no required status checks' \
  "worker-preamble documents the admin + no-required-checks precondition (#457)"
assert_contains "$worker_preamble_path457" \
  'issues/457' \
  "worker-preamble cites issue #457 as the source of the ungated-merge refinement"
assert_contains "$issue_work_path457" \
  'merged-direct-ungated' \
  "issue-work.md step 8 includes the auto-merge: merged-direct-ungated return suffix (#457)"
assert_contains "$issue_work_path457" \
  'issues/457' \
  "issue-work.md cites issue #457 for the ungated-merge refinement"
assert_contains "$inline_trivial_path457" \
  'merged-direct-ungated' \
  "inline-trivial.md mirrors the merged-direct-ungated refinement on the inline path (#457)"
assert_contains "$steady_state_path" \
  'merged-direct-ungated' \
  "steady-state.md step D fires an unconditional refresh for merged-direct-ungated (#457)"

# (28) Defer-labeling ensures-then-labels-then-verifies the epic-handoff
#      surfacing label, never a bare --add-label that silently no-ops (issue
#      #508). As of #519's binary-backlog fold the label is needs-human-review
#      (re-keyed from the former dedicated needs-decomposition label).
#
# `gh issue edit … --add-label needs-human-review` is atomic: if the label
# does not exist in the repo (step 3a's backgrounded `gh label create … &`
# group was skipped, raced, or its subshell errored under `2>/dev/null ||
# true`), the WHOLE edit exits non-zero and the apply silently no-ops — and
# on a repo where the same defer path also clears the @me self-assign in one
# combined edit, the --remove-assignee is dropped too. Net effect: the
# confirmed-non-shippable epic is re-scoped every future session (the waste
# the surfacing label exists to prevent) and the issue may be left assigned.
# Repro: lightwork session do-work-20260609T034015Z-47977 — #1673 and #1769
# both failed the atomic edit; #1673 also kept its @me assignment.
#
# The fix hardens setup.md step 6's Deferred recording path:
#   - ensure-then-label: an idempotent `gh label create needs-human-review`
#     immediately before the --add-label, so the apply never depends on 3a.
#   - split the mutations: any --remove-assignee runs as its own gh edit, so
#     a label failure can't drop the unassign.
#   - verify: read back .labels and warn loudly if the label isn't present.
assert_contains "$setup_path" \
  'issues/508' \
  "setup.md cites issue #508 as the source of the ensure-then-label-then-verify hardening"
assert_contains "$setup_path" \
  'gh label create needs-human-review --repo <owner/repo>' \
  "setup.md step 6 ensures the needs-human-review label exists before --add-label (#508/#519)"
assert_contains "$setup_path" \
  'ensure-then-label-then-verify' \
  "setup.md step 6 names the ensure-then-label-then-verify discipline (#508)"
assert_contains "$setup_path" \
  'WARNING: #<N> needs-human-review apply did not land' \
  "setup.md step 6 reads back .labels and warns loudly on a silent no-op (#508/#519)"
assert_contains "$setup_path" \
  'Split the mutations' \
  "setup.md step 6 requires --remove-assignee as its own gh edit, not combined with --add-label (#508)"

# (29) Soft-collision same-section content conflicts are documented as
#      expected, with a named orchestrator drain branch (issue #507).
#
# The soft-collision tier lets up to --soft-collision-concurrency workers
# claim the same additive-docs path on the premise that PR-land conflicts
# are trivially resolvable (version-coordination's fix-rebase.md §4.6 carve-
# out resolves the manifest .version row + CHANGELOG top-of-file insert).
# That premise breaks when two+ siblings edit the SAME SECTION of the same
# soft-collision file: the conflict is real prose content, not a coordinated
# row, so §4.6 does NOT apply, fix-rebase correctly bails `blocked rebase:
# conflict extends beyond coordinated manifest+CHANGELOG rows`, and there was
# no documented orchestrator recovery — the DIRTY PR stranded ad hoc.
# Repro: session do-work-20260609T025704Z-59825 — issues #499/#500/#501 all
# edited the same my-turn.md Pass-B section; #504 and #506 went DIRTY and had
# to be hand-resolved.
#
# The fix (Option 1 — document + accept) makes the limitation explicit:
#   - steady-state.md soft-collision rules state a same-section conflict is
#     EXPECTED (not a worker failure) and §4.6 does not cover it.
#   - the blocked-rebase reconcile path names the soft-collision sub-case so
#     the still-DIRTY → manual-resolution outcome is a documented drain
#     branch, not ad hoc.
#   - the RATIONALE and dont.md soft-collision sections record the premise
#     boundary.
assert_contains "$steady_state_path" \
  'issues/507' \
  "steady-state.md cites issue #507 for the same-section soft-collision conflict boundary"
assert_contains "$steady_state_path" \
  'conflict extends beyond coordinated manifest+CHANGELOG rows' \
  "steady-state.md documents the expected fix-rebase bail string on a same-section soft-collision conflict (#507)"
assert_contains "$steady_state_path" \
  'same section' \
  "steady-state.md names the same-section case that escapes the §4.6 carve-out (#507)"
assert_contains "$rationale_path" \
  'issues/507' \
  "RATIONALE cites issue #507 for the soft-collision same-section premise boundary"
assert_contains "$rationale_path" \
  'same section' \
  "RATIONALE records that same-section soft-collision edits produce content conflicts §4.6 does not resolve (#507)"
assert_contains "$dont_path" \
  'issues/507' \
  "dont.md cites issue #507 where it notes a same-section soft-collision conflict is expected, not a worker failure"

# ---------------------------------------------------------------------------
# (N) blocked:agent-hard elimination (issue #521).
#
# #521 eliminates the blocked:agent-hard label, splitting its two populations:
#   - refuse (no open `Blocked by #N` ref) → needs-human-review label
#   - dependency-wait (bail names an open `#N`) → NO label; gated by the
#     `Blocked by #N` body-reference filter (bucket 7 / step 4)
# and deletes the now-redundant referential sweeps:
#   - setup.md step 3d.2 sub-sweep a (the blocked:agent-hard referential clear)
#   - steady-state.md step A.5 (the #245 mid-session referential sweep)
# The legacy `blocked:agent` migration (sub-sweep b) is re-pointed to the same
# refuse/dependency discriminator; sub-sweep c (blocked:agent-soft) is kept.
# The GitHub label objects are NOT deleted — they're just no longer applied.
my_turn_path="$repo_root/plugins/shipyard/commands/my-turn.md"

# Bail handler routes refuses to needs-human-review and dependency-waits to no
# label. The case-label table must list both routings.
assert_contains "$steady_state_path" \
  'issues/521' \
  "steady-state.md cites issue #521 for the blocked:agent-hard elimination"
assert_contains "$steady_state_path" \
  'no label applied — the' \
  "steady-state.md bail handler applies NO label for a dependency-wait (#521)"
assert_contains "$steady_state_path" \
  'label="needs-human-review"' \
  "steady-state.md bail handler applies needs-human-review for a refuse (#521)"

# The blocked:agent-hard label is never APPLIED in any orchestrator-state file —
# it was eliminated in #521. However, setup.md step 3d.2 sub-sweep f (#537)
# legitimately REMOVES the legacy label for migration purposes (same pattern as
# sub-sweep b for `blocked:agent`), so --remove-label is allowed in setup.md only.
# steady-state.md still must not add or remove it at all.
assert_not_contains "$steady_state_path" \
  '--add-label blocked:agent-hard' \
  "steady-state.md no longer applies the blocked:agent-hard label (#521)"
assert_not_contains "$steady_state_path" \
  '--remove-label blocked:agent-hard' \
  "steady-state.md no longer sweeps the blocked:agent-hard label (#521)"
assert_not_contains "$setup_path" \
  '--add-label blocked:agent-hard' \
  "setup.md no longer migrates the legacy label to blocked:agent-hard (#521)"
# sub-sweep f (added in #537) does use --remove-label blocked:agent-hard for
# migration purposes; assert it is present and paired with --add-label needs-human-review
# (i.e., the migration sweep exists and routes refuses correctly).
assert_contains "$setup_path" \
  '--remove-label blocked:agent-hard' \
  "setup.md step 3d.2 sub-sweep f removes legacy blocked:agent-hard for migration (#537)"

# The step A.5 mid-session referential sweep is removed (its active heading is
# replaced by a removal note).
assert_not_contains "$steady_state_path" \
  'A.5. Mid-session blocked-issue re-evaluation (fires on' \
  "steady-state.md step A.5 mid-session referential sweep is removed (#521)"
assert_contains "$steady_state_path" \
  'A.5. (removed' \
  "steady-state.md records the step A.5 removal note (#521)"

# Sub-sweep b is re-pointed: it now applies needs-human-review (not -hard) on
# the no-open-blocker branch.
assert_contains "$setup_path" \
  'migration (re-pointed per' \
  "setup.md step 3d.2 sub-sweep b is re-pointed per #521"
assert_contains "$setup_path" \
  '--add-label needs-human-review' \
  "setup.md sub-sweep b routes an unclassifiable legacy refuse to needs-human-review (#521)"

# Dispatch-exclusion enumerations (step 4 + step-C re-check + drain fetch) must
# drop blocked:agent-hard / legacy blocked:agent. We can't whole-file
# assert_not_contains (prose still names the eliminated labels), so assert the
# replacement enumeration shape instead: the step-4 dispatch-gate bullet now
# leads with blocked:ci, not blocked:agent.
assert_contains "$setup_path" \
  'were dropped from this set' \
  "setup.md step 4 documents dropping blocked:agent-hard / legacy blocked:agent from the dispatch-gate set (#521)"
assert_contains "$drain_path" \
  'were eliminated per' \
  "drain.md termination fetch documents dropping blocked:agent-hard / legacy blocked:agent (#521)"

# /my-turn no longer keys on blocked:agent-hard — refuses surface via
# needs-human-review.
assert_contains "$my_turn_path" \
  'issues/521' \
  "my-turn.md cites issue #521 for the refuse → needs-human-review re-routing"

# (N) Never hand a workable issue to the human — attempt-then-escalate (#531).
#
# The orchestrator drained with workable, dispatchable self-filed follow-up
# issues (#529, #530) still open and surfaced them to the human ("left for a
# fresh run" / "say the word and I'll work them") instead of dispatching
# workers — forcing the maintainer to manually re-instruct it. Root cause:
# the termination assertion subtracted judgment-excluded candidates from the
# "workable" net-new set, so the loop terminated while the MECHANICAL step-4
# filter still had candidates. The fix lands in two coordinated surfaces:
#   - dont.md gains a dispatch-loop rule forbidding the hand-off of a
#     mechanically-workable issue to the human, naming the four invalid
#     defer rationalizations and tying the legitimate defer set to the five
#     defer_reason_class values.
#   - drain.md termination-assertion step 4 specifies the workable count is
#     MECHANICAL (step-4 client-side filter only, no judgment-exclusion);
#     mechanical count > 0 forbids termination and requires dispatch.
assert_contains "$dont_path" \
  'issues/531' \
  "dont.md cites issue #531 for the never-hand-workable-issue-to-human rule"
assert_contains "$dont_path" \
  "Don't hand a workable issue to the human" \
  "dont.md carries the attempt-then-escalate dispatch-loop rule (#531)"
assert_contains "$dont_path" \
  'match none of the five' \
  "dont.md ties the invalid defer rationalizations to the five defer_reason_class values (#531)"
assert_contains "$dont_path" \
  'Self-filed follow-ups re-enter the backlog like any other issue' \
  "dont.md states self-filed follow-ups re-enter the backlog (#531)"
assert_contains "$dont_path" \
  'soft cap on the per-session count of issues filed by this session' \
  "dont.md documents the bounded-regress soft-cap guard, not blanket refusal (#531)"
assert_contains "$drain_path" \
  'issues/531' \
  "drain.md termination assertion cites issue #531"
assert_contains "$drain_path" \
  'The workable count is MECHANICAL, never discretionary' \
  "drain.md step 4 specifies the workable count is mechanical, not discretionary (#531)"
assert_contains "$drain_path" \
  'MAY NOT judgment-exclude a candidate from this list' \
  "drain.md step 4 forbids judgment-exclusion from the workable list (#531)"
assert_contains "$drain_path" \
  'the loop MUST NOT terminate' \
  "drain.md step 4: mechanical count > 0 forbids termination and requires dispatch (#531)"

# ----------------------------------------------------------------------
# (N+1) Phantom-refire sibling-strand variant (issue #530).
#
# #317's reconcile-once gate silently skips any task-notification whose
# task-id is already in reconciled_agent_ids. #530 documents a variant the
# pure silent-skip mishandles: the harness can cross-wire a still-in-flight
# *sibling* worker's only completion notification onto a reaped worker's
# task-id. The phantom's task-id is reconciled, but its body asserts a
# terminal outcome (shipped/green) for a DIFFERENT target tied to a live
# .in_flight slot. A pure skip strands that in-flight sibling.
#
# The fix: before the silent return, parse the phantom body; if it names an
# in-flight slot's target, run the trust-but-verify probe and reconcile the
# in-flight sibling from ground truth (keyed on the sibling's agent_id, not
# the reaped phantom id). The silent skip is preserved for genuine wind-down
# phantoms (body asserts nothing reconcilable / names only the reconciled
# target / ground truth doesn't confirm).
assert_contains "$steady_state_path" \
  'issues/530' \
  "steady-state.md cites issue #530 for the phantom sibling-strand variant"
assert_contains "$steady_state_path" \
  'still-in-flight* sibling' \
  "steady-state.md A.−1 documents the still-in-flight sibling cross-wire variant (#530)"
assert_contains "$steady_state_path" \
  'pre-skip check' \
  "steady-state.md A.−1 documents the pre-skip body-inspection check before the silent return (#530)"
assert_contains "$steady_state_path" \
  'reconcile the in-flight sibling from verified state' \
  "steady-state.md A.−1 reconciles the in-flight sibling from ground-truth-verified state (#530)"
assert_contains "$steady_state_path" \
  'genuine wind-down' \
  "steady-state.md A.−1 preserves the silent-skip for genuine wind-down phantoms (#530)"
assert_contains "$dont_path" \
  'still-in-flight* target' \
  "dont.md carries the sibling-strand variant bullet forbidding a pure silent-skip (#530)"

# ----------------------------------------------------------------------
# (N+2) external-dependency and human-decision-required defers now apply
#        needs-human-review and stamp distinct body markers (#536).
#
# Before #536, only confirmed-non-shippable-as-single-PR defers applied
# needs-human-review, so external-dependency and human-decision-required
# defers re-entered the dispatch queue every session, burned a redundant
# scope agent, re-derived the same conclusion, and posted an identical
# diagnosis comment. Repro: lightwork#1557 accumulated 5+ consecutive
# identical comments; session do-work-20260611T114039Z-43655 burned ~190k
# tokens re-deriving 7 known defers.
#
# The fix extends the recording path in setup.md step 6 to:
#   (a) apply needs-human-review for external-dependency and
#       human-decision-required (same ensure-then-label-then-verify
#       pattern as #508/#519);
#   (b) stamp distinct body markers (<!-- do-work-external-dependency -->
#       and <!-- do-work-human-decision-required -->) so the classes are
#       distinguishable within the shared needs-human-review pool;
#   (c) enforce comment dedupe before posting (skip post if an existing
#       comment with the same class marker and matching conclusion exists).
#
# CLAUDE.md label-conventions docs are updated to document all three.
assert_contains "$setup_path" \
  'issues/536' \
  "setup.md step 6 cites issue #536 for the external-dependency / human-decision-required defer labelling"
assert_contains "$setup_path" \
  'do-work-external-dependency' \
  "setup.md step 6 recording path stamps <!-- do-work-external-dependency --> on external-dependency defers (#536)"
assert_contains "$setup_path" \
  'do-work-human-decision-required' \
  "setup.md step 6 recording path stamps <!-- do-work-human-decision-required --> on human-decision-required defers (#536)"
assert_contains "$setup_path" \
  'defers accumulated 5+ consecutive identical diagnosis comments across sessions because no label was applied to gate re-dispatch' \
  "setup.md step 6 applies needs-human-review to external-dependency and human-decision-required defers (#536)"
assert_contains "$setup_path" \
  'Comment dedupe check' \
  "setup.md step 6 recording path includes a comment dedupe check before posting (#536)"
assert_contains "$setup_path" \
  'skipping duplicate diagnosis comment' \
  "setup.md step 6 logs a skip message when a duplicate diagnosis comment is detected (#536)"

# ----------------------------------------------------------------------
# (N+3) Follow-up PRs in the same dispatch must also cut a release (#544).
#
# The per-PR release rule (bump manifest + add CHANGELOG entry in the same
# PR) was documented in issue-work.md step 4 for the *primary* PR only.
# When a worker opens a second PR in the same dispatch (e.g. a post-merge
# CI hotfix after the primary PR landed as merged-direct-ungated), that
# follow-up PR also merged with no version bump and no CHANGELOG entry,
# making the fix invisible in the release record.
#
# Repro: session do-work-20260611T220126Z-96473 — primary PR #541
# (release 1.9.7) shipped #537; follow-up PR #542 (test-only CI fix)
# merged in the same dispatch with no version bump and no CHANGELOG mention.
#
# Fix: issue-work.md step 4 gains a new paragraph (cross-ref #544) that
# extends the per-PR release rule to any additional PR the worker opens in
# the same dispatch, and specifies that the follow-up must compute its own
# version slot by reading origin/<default-branch> after the primary bump
# has landed (the orchestrator-supplied version covers only the primary PR).
issue_work_path544="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"

assert_contains "$issue_work_path544" \
  'issues/544' \
  "issue-work.md step 4 cites issue #544 for the follow-up-PR release rule"
assert_contains "$issue_work_path544" \
  'Follow-up PRs within the same dispatch must also cut a release' \
  "issue-work.md step 4 establishes the follow-up-PR release rule heading (#544)"
assert_contains "$issue_work_path544" \
  'covers **only the primary PR** for that dispatch' \
  "issue-work.md step 4 notes the orchestrator-supplied version covers only the primary PR (#544)"
assert_contains "$issue_work_path544" \
  'compute the next free version slot by reading the current manifest from' \
  "issue-work.md step 4 specifies follow-up version computation from origin/<default-branch> (#544)"

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
