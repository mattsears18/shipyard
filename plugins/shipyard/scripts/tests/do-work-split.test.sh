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

# setup-fragment-content-scan: allow-file
# This suite's whole purpose is asserting the router table's split structure
# itself — which fragment lives where and in what order — so naming
# fragment files directly is the point, not the anti-pattern issue #1453
# guards against.
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
# The setup phase was split into a thin router + step-cluster sub-files under
# do-work/setup/ (issue #611 — the monolithic setup.md crossed the 256KB
# single-file Read limit). `setup_router_path` is the thin entry; `setup_path`
# is a concatenation of the router + every sub-file, so the many
# `assert_contains "$setup_path" …` content assertions below keep finding the
# step content regardless of which sub-file it now lives in. A dedicated
# `*.size.test.sh` (added by #611) enforces the per-file size cap; this test
# only cares that the setup-phase *content* survived the split.
setup_router_path="$repo_root/plugins/shipyard/commands/do-work/setup.md"
setup_dir="$repo_root/plugins/shipyard/commands/do-work/setup"
setup_path="$(mktemp -t do-work-setup-concat.XXXXXX)"
cat "$setup_router_path" "$setup_dir"/*.md > "$setup_path" 2>/dev/null
trap 'rm -f "$setup_path"' EXIT
# steady-state.md was itself split into a thin hot-path file + on-demand
# reference sub-files (issue #616 — the consulted-not-executed Dispatch rules
# block moved to do-work/dispatch-rules.md, and the operator-layer operator
# hooks folded into do-work/operate.md, keeping the steady-state hot path under
# the 256KB single-file Read limit). `steady_state_router_path` is the hot-path
# file itself; `steady_state_path` is a concatenation of the hot path + the
# dispatch-rules reference + operate.md (+ its own on-demand bodies), so the
# many `assert_contains "$steady_state_path" …` content assertions below keep
# finding the loop/dispatch/operator content regardless of which file it now
# lives in.
# The do-work-phase-file-size.test.sh guard (added by #611) enforces the
# per-file size cap; this test only cares that the content survived the split.
#
# operate.md was itself split into a thin router (browser-backend selection +
# preflight, which run every session) + on-demand bodies under operate/
# (issue #808 — the operator layer's queue/authorization/playbook/error-
# handling/safety machinery only fires when operator_queue is non-empty, so it
# moved out of the always-loaded surface). `operate_router_path` is the thin
# router alone; `operate_path` is a concatenation of the router + every
# operate/*.md sub-file (mirroring the setup_path pattern above), so the many
# `assert_contains "$operate_path" …` content assertions below keep finding
# operator-phase content regardless of which operate/ sub-file it now lives in.
steady_state_router_path="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
dispatch_rules_path="$repo_root/plugins/shipyard/commands/do-work/dispatch-rules.md"
# disk_space_guard_path (issue #1261): steady-state.md's own phase-file size
# was already within ~150 bytes of the #611 cap on main, so the disk-space
# backpressure check's full mechanism (bash + the #832/#836-safety
# explanation) lives in this sibling fragment instead — steady-state.md
# itself keeps only a short pointer paragraph. Folded into the same
# concatenation as dispatch_rules_path/operate_path so content assertions
# below keep finding it regardless of which physical file it lives in.
disk_space_guard_path="$repo_root/plugins/shipyard/commands/do-work/disk-space-guard.md"
# version-release.md — step B.0's release-on-non-claim hook, split out of
# steady-state.md by #1420 for the same #611 size-cap reason as the two above.
version_release_path="$repo_root/plugins/shipyard/commands/do-work/version-release.md"
# invariant_line_path (issue #1261): the step-E per-token "what it means /
# when it's set / divergence smells" narrative (tokens_attributed,
# last_fresh_fetch, unfiltered_open_count, me_assigned_open, operator_q/
# operator, peers, and now disk_free_mb) moved to this sibling file for the
# same #611 size-cap reason as disk_space_guard_path above — steady-state.md
# itself keeps only the format templates, the state= definition, the
# idle_reason enum, and the mandatory self-checks inline. Folded into the
# same concatenation so the many pre-existing `assert_contains
# "$steady_state_path" …` assertions below (added for #1193/#1194, written
# when this content still lived inline) keep finding it regardless of which
# physical file it now lives in.
invariant_line_path="$repo_root/plugins/shipyard/commands/do-work/invariant-line.md"
operate_router_path="$repo_root/plugins/shipyard/commands/do-work/operate.md"
operate_dir="$repo_root/plugins/shipyard/commands/do-work/operate"
operate_path="$(mktemp -t do-work-operate-concat.XXXXXX)"
cat "$operate_router_path" "$operate_dir"/*.md > "$operate_path" 2>/dev/null
# Several lock-reaping / bail-classification / version-computation blocks
# that used to live inline in steady-state.md / dispatch-rules.md were
# extracted to standalone scripts (issue #1289, the follow-up to
# #1277/#1288's post-relocation compound-Bash-block decomposition) — fold
# them into the same concatenation so the many pre-existing
# `assert_contains "$steady_state_path" …` assertions below keep finding
# their logic regardless of which file/script it now lives in.
# primary-leak-guard.sh (issue #1323) is the newest addition to this list:
# A.0.6's primary-checkout branch-leak guard — including the #452
# cwd-independent PRIMARY_CHECKOUT derivation and its agent-* fallback
# strip — moved from an inline steady-state.md block to this script, for
# the same "orchestrator's own Bash tool call can't `git -C` another
# worktree directly" reason #1289's scripts were extracted.
extracted_reap_scripts_path="$repo_root/plugins/shipyard/scripts/pre-dispatch-branch-reap.sh $repo_root/plugins/shipyard/scripts/concurrent-session-guard.sh $repo_root/plugins/shipyard/scripts/shipped-immediate-branch-reap.sh $repo_root/plugins/shipyard/scripts/classify-blocked-bail.sh $repo_root/plugins/shipyard/scripts/stale-failure-check.sh $repo_root/plugins/shipyard/scripts/next-available-version.sh $repo_root/plugins/shipyard/scripts/primary-leak-guard.sh"
steady_state_path="$(mktemp -t do-work-steady-concat.XXXXXX)"
# shellcheck disable=SC2086  # intentional word-splitting: space-separated path list
cat "$steady_state_router_path" "$dispatch_rules_path" "$disk_space_guard_path" "$version_release_path" "$invariant_line_path" "$operate_path" $extracted_reap_scripts_path > "$steady_state_path" 2>/dev/null
trap 'rm -f "$setup_path" "$operate_path" "$steady_state_path"' EXIT
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
assert_file_exists "$setup_router_path" "commands/do-work/setup.md exists (thin router)"
assert_file_exists "$steady_state_router_path" "commands/do-work/steady-state.md exists (hot-path file)"
assert_file_exists "$dispatch_rules_path" "commands/do-work/dispatch-rules.md exists (#616 reference split)"
assert_file_exists "$disk_space_guard_path" "commands/do-work/disk-space-guard.md exists (#1261 sibling-split)"
assert_file_exists "$invariant_line_path" "commands/do-work/invariant-line.md exists (#1261 sibling-split)"
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
#    - (Superseded by #966 below) fix-rebase.md used to carry a defensive
#      bail clause for the residual case where the head branch was still
#      locked (peer-alive defer, transient failure of the immediate-reap
#      path) — see the #966 block further down for what replaced it.
assert_contains "$steady_state_path" \
  '--phase "steady-state-A1-shipped"' \
  "steady-state.md immediate-reap uses the steady-state-A1-shipped phase tag (#282)"
# shipped-immediate-branch-reap.sh (issue #1289) parameterizes the branch
# name via --issue rather than the literal "<N>" template placeholder the
# pre-extraction inline block used — assert the script's own variable form.
# shellcheck disable=SC2016  # literal grep needle — matched verbatim in the script, not expanded
assert_contains "$steady_state_path" \
  'git branch -D "$head_ref"' \
  "steady-state.md immediate-reap drops the local branch ref so fix-rebase can resolve via origin (#282)"
assert_count_at_least_across 'worktree-reap.sh" reap' 2 \
  "steady-state.md routes immediate-reap calls through worktree-reap.sh reap (≥2: reaped + deferred branches) (#282)" \
  "$steady_state_path"
assert_contains "$cleanup_path" \
  'Relationship to the immediate-reap in steady-state.md' \
  "cleanup-summary.md documents the relationship to the steady-state immediate-reap (#282)"

# (Issue #966) fix-checks-only.md and fix-rebase.md land on the PR's head
# commit via `git checkout --detach`, not `git switch <branch>`. A named-
# branch checkout is exclusive per worktree (git enforces one-worktree-
# per-branch), which made the #282 lock scenario above the *normal* case
# for a same-session PR — the originating issue-work worker deliberately
# keeps its branch checked out until end-of-session cleanup, so `git
# switch` bailed on essentially every same-session fix-checks/fix-rebase
# dispatch, and the old bail text ("needs end-of-session reap") pointed at
# a reap-to-unblock remedy `dont.md` forbids (neither branch name nor lock
# PID can distinguish a live peer worktree from an abandoned one).
# Detached HEAD sidesteps the exclusivity rule entirely — only a *branch*
# checkout is exclusive — so the old "locked in another worktree" bail
# clause this test used to require is gone by design, replaced by a
# residual bail for a genuine checkout error (network failure, deleted
# branch), which is a different, much rarer case.
fix_rebase_path="$repo_root/plugins/shipyard/agents/issue-worker/fix-rebase.md"
fix_checks_path966="$repo_root/plugins/shipyard/agents/issue-worker/fix-checks-only.md"
# The $HEAD_REF token below is a literal substring of the markdown spec (a
# documented shell-variable reference inside the spec's code block), meant
# to be matched verbatim — single quotes are correct and SC2016's "did you
# mean to expand" does not apply.
# shellcheck disable=SC2016
assert_contains "$fix_rebase_path" \
  'git checkout --detach "origin/$HEAD_REF"' \
  "fix-rebase.md lands on the PR head via detached HEAD, not git switch (#966)"
assert_not_contains "$fix_rebase_path" \
  'locked in another worktree' \
  "fix-rebase.md no longer bails on a branch-lock — detached HEAD sidesteps it (#966)"
# shellcheck disable=SC2016
assert_contains "$fix_checks_path966" \
  'git checkout --detach "origin/$HEAD_REF"' \
  "fix-checks-only.md lands on the PR head via detached HEAD, not git switch (#966)"
assert_not_contains "$fix_checks_path966" \
  'needs end-of-session reap' \
  "fix-checks-only.md no longer points a bail at the reap-to-unblock remedy dont.md forbids (#966)"

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
#   - The opening sentence reflects the struct count. Historically a single
#     word count ("nineteen" post-#746's `operator_denials`; was "eighteen"
#     post-#718, "sixteen" post-#589, "fifteen" post-#437) tracking the
#     TOTAL bullet count in do-work.md's own "## Orchestrator state" section.
#     Issue #808 split that section into a hot subset (twelve structs, still
#     inline in do-work.md — read/written most turns) and a cold long-tail
#     (eight structs, incl. `reconciled_agent_ids`, moved to
#     do-work/orchestrator-state-reference.md — each consumed by exactly one
#     other phase file). do-work.md's opening sentence now reads "twelve
#     **hot** mental data structures" for the subset it still carries inline;
#     `reconciled_agent_ids` itself is still *named* in do-work.md's pointer
#     prose (so the struct-list assertion below still passes unchanged) even
#     though its full definition lives in the split-out file. The
#     struct-derived line cap in check (2) is computed from do-work.md's own
#     (now-twelve) bullets, unaffected by the split.
#     Issue #1402 added a 13th hot struct (`paused_on_environment`) — the
#     opening sentence now reads "thirteen **hot** mental data structures";
#     the struct-derived line cap in check (2) auto-adjusts (it's derived
#     from the live bullet count, not a hardcoded number).
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
  'thirteen **hot** mental data structures' \
  "do-work.md opening sentence reflects post-#1402 hot-struct count (thirteen hot)"
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
# Issue #617 split: the Auto-merge + snapshot-and-return pattern moved out of
# SKILL.md into the auto-merge.md fragment. The group_by(.name) projection now
# lives there.
worker_preamble_path333="$repo_root/plugins/shipyard/skills/worker-preamble/auto-merge.md"

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

# (18.5) Head-SHA citation in the fix-checks-only green/noop return shape
# (issue #1211 — the deferred half of #1205).
#
# #1205 landed two API-free pre-checks that force a live spot-check on a
# fabrication tell, but deliberately deferred the harder, vocabulary-
# changing half: requiring the head SHA the rollup was observed at in the
# `green #<M>` / `noop: already green #<M>` return shape, so the
# orchestrator can mechanically reject a citation against a SHA that isn't
# the PR's current head via a plain string comparison — rather than only by
# re-running the rollup query the worker itself ran. #1211's own body names
# (at minimum) four files that must land the vocabulary change together:
# fix-checks-only.md's return contract, dispatch-rules.md's prompt
# template, steady-state.md's reconcile parsing, and dont.md's verification
# bullet — plus the workflow-substrate's buildFixChecksOnlyPrompt builder
# and the worker-return.schema.json structured-return schema (and its
# hand-copied .js mirror), both covered by their own required-CI parity
# checks (check-dispatch-prompt-parity.mjs / check-worker-return-schema-
# parity.mjs).
#
# These assertions pin that every lockstep site actually carries the new
# `@<head-SHA>` token (or the schema's `head_sha` field), and that the
# reconcile documents BOTH halves of the design decision the issue asked
# for explicitly: a cited-but-mismatched SHA is treated like a fabrication
# tell, and a SHA-less (older-shape) return is NOT a hard parse failure —
# it forces the same live verification, never less.
fix_checks_path1211="$repo_root/plugins/shipyard/agents/issue-worker/fix-checks-only.md"
schema_path1211="$repo_root/plugins/shipyard/schemas/worker-return.schema.json"
core_js_path1211="$repo_root/plugins/shipyard/workflows/do-work-dispatch.core.js"
workflow_js_path1211="$repo_root/plugins/shipyard/workflows/do-work-dispatch.workflow.js"
prompt_template_path1211="$repo_root/plugins/shipyard/workflows/prompt-templates/fix-checks-only.mjs"

assert_contains "$fix_checks_path1211" \
  'green #<M> @<head-SHA> (rollup verified' \
  "fix-checks-only.md return contract requires the @<head-SHA> citation on green (#1211)"
assert_contains "$fix_checks_path1211" \
  'noop: already green #<M> @<head-SHA> (rollup verified' \
  "fix-checks-only.md return contract requires the @<head-SHA> citation on noop (#1211)"
assert_contains "$fix_checks_path1211" \
  'issues/1211' \
  "fix-checks-only.md cites issue #1211"
assert_contains "$dispatch_rules_path" \
  'green #<M> @<head-SHA> (rollup verified' \
  "dispatch-rules.md's fix-checks-only prompt template return-values list carries @<head-SHA> (#1211)"
assert_contains "$dispatch_rules_path" \
  'head_sha:"<40-char SHA>"' \
  "dispatch-rules.md's structured-return translation table carries the head_sha field (#1211)"
assert_contains "$steady_state_path" \
  'Head-SHA citation check' \
  "steady-state.md reconcile documents the head-SHA citation check (#1211)"
assert_contains "$steady_state_path" \
  'fix-checks-sha-mismatch' \
  "steady-state.md logs a distinct advisory on a SHA mismatch, treated like a fabrication tell (#1211)"
assert_contains "$steady_state_path" \
  'fix-checks-sha-missing' \
  "steady-state.md documents a SHA-less return as forcing verification, not a hard parse failure (#1211)"
assert_contains "$dont_path" \
  "Don't accept a \`green\`/\`noop\` citation whose head SHA doesn't match the PR's live head" \
  "dont.md pins the SHA-mismatch / SHA-less handling (#1211)"
assert_contains "$schema_path1211" \
  '"head_sha"' \
  "worker-return.schema.json declares the head_sha field (#1211)"
assert_contains "$core_js_path1211" \
  "head_sha: { type: ['string', 'null'] }" \
  "do-work-dispatch.core.js's workerReturnSchema literal mirrors head_sha (#1211)"
assert_contains "$workflow_js_path1211" \
  "head_sha: { type: ['string', 'null'] }" \
  "do-work-dispatch.workflow.js (generated) mirrors head_sha (#1211)"
assert_contains "$prompt_template_path1211" \
  '"head_sha"' \
  "fix-checks-only.mjs's structured-return examples include head_sha (#1211)"
assert_contains "$workflow_js_path1211" \
  '"head_sha"' \
  "do-work-dispatch.workflow.js (generated) mirrors the head_sha structured-return example (#1211)"

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
# Issue #1389 split this into TWO clauses. The pre-#1389 needle pinned the
# single "@me AND healthy" gate, which conflated two different questions:
# health decides the PR's routing (failed_prs / fix-checks); coverage decides
# the ISSUE's eligibility, and is health-independent. Both clauses are pinned
# below, plus the #332 guarantee that neither drops on a CLOSED PR.
assert_contains "$setup_path" \
  'is this PR healthy?' \
  "setup.md step 4 keeps the healthy-PR clause and states the question it answers (#332/#1389)"
assert_contains "$setup_path" \
  'is this ISSUE already covered?' \
  "setup.md step 4 documents the health-independent covered-by-open-pr clause (#1389)"
assert_contains "$setup_path" \
  'covered-by-open-pr' \
  "setup.md step 4 names the distinct covered-by-open-pr verdict (#1389)"
# shellcheck disable=SC2016
# Backticks here are literal characters in the markdown needle, not a command substitution.
assert_contains "$setup_path" \
  'both query `--state open` only' \
  "setup.md step 4 states that NEITHER PR-coverage clause locks an issue behind a closed/abandoned PR (#332)"
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
#
#       As of #720 step 1.3 no longer RE-IMPLEMENTS that rule inline — it used
#       to carry a ~55-line bash copy (its own `required_checks_count` variable,
#       its own #479 normalize, its own #645 ruleset fallback), which was a THIRD
#       copy of the condition alongside the worker-preamble fragment and
#       issue-work.md. That is exactly the drift hazard #716 was filed for. The
#       rule now lives in ONE executable script and step 1.3 calls it.
#
#       So the assertion is now on DELEGATION, not on re-derivation. Asserting
#       `required_checks_count` here would actively pin the duplicated-logic
#       architecture that #720 removed (and would contradict section (H) of
#       ungated-merge-gate-reachability.test.sh, which asserts that variable is
#       ABSENT from this file).
assert_contains "$setup_path" \
  'required_status_checks' \
  "setup.md step 1.3 still names required_status_checks (#465 shape) in its prose"
assert_contains "$setup_path" \
  'detect-ungated-admin-direct-merge.sh' \
  "setup.md step 1.3 DELEGATES the two-shape rule to the one detector script (#720)"
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
# replaced the bare glob with a `find` substitution that exits 0 on no
# matches, so the loop body simply doesn't iterate and execution
# proceeds to 3c.
#
# RE-POINTED, not deleted (issue #1355). setup.md's 3b/1.6.5 sweeps used
# to carry the find-based loop (and the #335 citation) inline, in TWO
# copies — the bg-cleanup-group loop and the standalone "3b. Reap stale
# agent worktrees" documentation block. #1355 replaced BOTH inline copies
# with single-call invocations of `worktree-reap.sh` subcommands, and the
# harness-convergence Tier-2 cut then deleted those subcommands outright,
# so the loop text — and the
# #335 citation that explained it — legitimately no longer appears in
# setup_path. The zsh-nomatch-safety PROPERTY moved with the loop into
# `worktree-reap.sh`'s internals; asserting for it in setup_path after the
# move would be asserting for dead text, not for the property. The checks
# below assert it in its new home instead: the `find`-based idiom (not a
# bare glob) still backs every agent-* enumeration inside worktree-reap.sh,
# the #335 citation is still attached to it there, and setup_path itself
# never regresses back to inlining the bare-glob hazard.
# The agent-* enumeration itself is GONE as of the harness-convergence Tier-2
# cut: every sweeping subcommand that walked `.git/worktrees/agent-*`
# (classify-all / reap-stale / sweep-stale-agents / reap-orphan-orchestrators /
# reap-session-worktrees) was deleted, because Claude Code's own periodic sweep
# now removes subagent and background-session worktrees and releases the locks
# of exited sessions. With no enumeration left anywhere in worktree-reap.sh,
# there is no zsh-nomatch hazard to guard THERE — so the textual assertions on
# that file are retired. The setup.md guard below survives and still matters:
# it stops the bare-glob loop from being re-inlined into the spec.
# The bare-glob form must never reappear in setup.md's own text — the
# regression guard against re-introducing the zsh hazard inline, even
# though the loop itself now lives one layer down in worktree-reap.sh.
assert_not_contains "$setup_path" \
  'for wt_dir in .git/worktrees/agent-*' \
  "setup.md no longer uses the bare agent-* glob in any for-loop (zsh nomatch hazard, #335)"
# The hardened find-based idiom (never a bare glob) must still back every
# agent-* worktree enumeration inside worktree-reap.sh itself — at least
# the sweep-stale-agents path (issue #1529-area) and the warn-threshold /
# reclaimable-size probes (#836) all count toward this floor. See
# worktree-reap.test.sh's (90)/(127) "no agent-* worktrees -> exit 0,
# empty output" cases for the FUNCTIONAL half of this same property —
# this assertion is the textual half (the idiom itself never regresses to
# a bare glob).

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
# Issue #617 split: the #340 post-call categorization rule moved into auto-merge.md.
worker_preamble_path340="$repo_root/plugins/shipyard/skills/worker-preamble/auto-merge.md"
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
setup_path348="$setup_path"  # concat of router + setup/ sub-files (#611)
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

# (23b) Detector 2 extension — config-driven path set, .claude/hooks/ coverage,
#       deliverable-vs-mention false-positive guard (issue #591).
#
# #591 extended Detector 2 along three axes after a mksolutionsky.com session
# burned two ~100k-token dispatches (#69/#70) on agent-config deliverables:
#   - The matched path set became config-driven via scope.self_modification_paths
#     (default includes .claude/hooks/, the gap #591 closed for hook-script files).
#   - A deliverable-vs-mention guard prevents false-positives on meta-issues that
#     merely discuss these paths in prose (issue #591 itself is the canonical case).
#   - The class stays human-decision-required, deliberately declining #591's
#     suggested confirmed-non-shippable-as-single-PR (single-PR config edit blocked
#     by a policy, not an un-decomposable epic).
setup_path591="$setup_path"  # concat of router + setup/ sub-files (#611)
drain_path591="$repo_root/plugins/shipyard/commands/do-work/drain.md"
rationale_path591="$repo_root/plugins/shipyard/commands/do-work-RATIONALE.md"
config_sh591="$repo_root/plugins/shipyard/scripts/shipyard-config.sh"
schema591="$repo_root/plugins/shipyard/schemas/shipyard.config.schema.json"

assert_contains "$setup_path591" \
  'scope.self_modification_paths' \
  "setup.md Detector 2 is config-driven via scope.self_modification_paths (#591)"
assert_contains "$setup_path591" \
  '.claude/hooks/' \
  "setup.md Detector 2 covers .claude/hooks/ (#591)"
assert_contains "$setup_path591" \
  'Deliverable-vs-mention guard' \
  "setup.md Detector 2 has the deliverable-vs-mention false-positive guard (#591)"
assert_contains "$setup_path591" \
  'declining the issue'"'"'s suggested class' \
  "setup.md Detector 2 documents declining the suggested confirmed-non-shippable class (#591)"
assert_contains "$setup_path591" \
  'confirmed-non-shippable-as-single-PR' \
  "setup.md Detector 2 names confirmed-non-shippable-as-single-PR as the declined class (#591)"
assert_contains "$setup_path591" \
  'Proposes .claude/hooks/' \
  "setup.md validator's human-decision-required rule accepts Proposes .claude/hooks/ prefix (#591)"
assert_contains "$setup_path591" \
  'issues/591' \
  "setup.md cites issue #591 as the source of the Detector 2 extension"
assert_contains "$drain_path591" \
  '.claude/hooks/' \
  "drain.md re-validation cross-reference mentions .claude/hooks/ (#591)"
assert_contains "$rationale_path591" \
  'config-driven paths' \
  "RATIONALE has a Detector 2 extension section (#591)"
assert_contains "$rationale_path591" \
  'issues/591' \
  "RATIONALE cites issue #591 as the source of the Detector 2 extension"
# Config default + schema carry the new knob
assert_contains "$config_sh591" \
  'self_modification_paths' \
  "shipyard-config.sh default config carries scope.self_modification_paths (#591)"
assert_contains "$schema591" \
  'self_modification_paths' \
  "schema defines scope.self_modification_paths (#591)"

# (23c) Pre-scope Detector 3 — orchestrator-only skill/command invocation
#       proposal (issue #1294).
#
# Dispatch can't recognize an issue whose own acceptance criteria call for
# invoking an orchestrator-only skill/command (e.g. `shipyard:update-roadmap`,
# which `milestone-prohibition.md` and the skill's own SKILL.md forbid a
# dispatched worker from ever invoking). #1294's repro: issue #1244 dispatched
# as mode: issue-work with steps that instructed the worker to run
# `shipyard:update-roadmap` cold; the worker correctly refused, shipped a safe
# config-only slice, and filed #1294. Detector 3 catches the whole-issue case
# at scope pre-flight before a worker burns a dispatch discovering the same
# prohibition.
#
# Surfaces:
#   - setup.md step 6 grows a `Detector 3 — Orchestrator-only skill/command
#     invocation proposal` block under "Pre-scope orchestrator-side
#     detectors".
#   - The matched skill/command set is config-driven via
#     scope.orchestrator_only_skills (mirrors Detector 2's
#     scope.self_modification_paths).
#   - The evidence_pointer validator's human-decision-required rule accepts
#     the new structured prefix `Proposes invoking orchestrator-only
#     skill/command`.
#   - The per-class shape table example gains the orchestrator-only-skill
#     example.
#   - RATIONALE gains a "Step 6 — Detector 3" section documenting the
#     failure mode and why it stays a whole-issue defer (not an
#     auto-sliced residual).
#   - shipyard-config.sh default config + schema carry the new knob.
setup_path1294="$setup_path"  # concat of router + setup/ sub-files (#611)
rationale_path1294="$repo_root/plugins/shipyard/commands/do-work-RATIONALE.md"
config_sh1294="$repo_root/plugins/shipyard/scripts/shipyard-config.sh"
schema1294="$repo_root/plugins/shipyard/schemas/shipyard.config.schema.json"

assert_contains "$setup_path1294" \
  'Detector 3 — Orchestrator-only skill/command invocation proposal' \
  "setup.md step 6 names Detector 3 explicitly (#1294)"
assert_contains "$setup_path1294" \
  'scope.orchestrator_only_skills' \
  "setup.md Detector 3 is config-driven via scope.orchestrator_only_skills (#1294)"
assert_contains "$setup_path1294" \
  'shipyard:update-roadmap' \
  "setup.md Detector 3 default set names shipyard:update-roadmap (#1294)"
assert_contains "$setup_path1294" \
  'milestone-prohibition.md' \
  "setup.md Detector 3 cites milestone-prohibition.md as the worker-side boundary (#1294)"
assert_contains "$setup_path1294" \
  'Deliverable-vs-mention guard' \
  "setup.md Detector 3 reuses the deliverable-vs-mention guard (#1294)"
assert_contains "$setup_path1294" \
  'Proposes invoking orchestrator-only skill/command' \
  "setup.md validator's human-decision-required rule accepts the orchestrator-only-skill prefix (#1294)"
assert_contains "$setup_path1294" \
  'Whole-issue defer, not a slice' \
  "setup.md Detector 3 documents staying a whole-issue defer rather than auto-slicing (#1294)"
assert_contains "$setup_path1294" \
  'issues/1294' \
  "setup.md cites issue #1294 as the source of Detector 3"
assert_contains "$rationale_path1294" \
  'Detector 3: orchestrator-only skill/command invocation proposal (issue #1294)' \
  "RATIONALE has a Step 6 — Detector 3 section (#1294)"
assert_contains "$rationale_path1294" \
  'issues/1294' \
  "RATIONALE cites issue #1294 as the source of Detector 3"
assert_contains "$config_sh1294" \
  'orchestrator_only_skills' \
  "shipyard-config.sh default config carries scope.orchestrator_only_skills (#1294)"
assert_contains "$schema1294" \
  'orchestrator_only_skills' \
  "schema defines scope.orchestrator_only_skills (#1294)"

# (23d) Detector 1 narrowed — the blanket `.github/workflows/` defer was built
#       on a false premise (issue #1481).
#
# #346 shipped Detector 1 as an UNCONDITIONAL match: any issue body containing
# the literal fragment `.github/workflows/` was deferred whole, on the stated
# ground that workers' hard rules "all forbid .github/workflows/
# modifications". That premise is false — the three rules it cited are (a) a
# suggested-fix scope-creep guard, (b) an untrusted-comment out-of-scope gate,
# and (c) an anti-CI-gaming rule conditioned on "to make a check pass". A whole
# worker mode (fix-main-ci) edits workflow files routinely, and #812/#818's
# workflow-scope machinery only exists because workers DO open workflow-touching
# PRs.
#
# Field evidence (mattsears18/lightwork session 8079ffb9-a428-4906-9619-
# 14944e0881c3, 2026-08-19): 6 of 19 dispatchable issues matched the string
# test; the operator overrode the detector and 8 of 8 workflow-touching issues
# shipped and merged, with zero worker hard-rule bails and zero classifier
# denials on workflow grounds.
#
# The fix is #1481's option 3 — a four-way framing test copying Detector 2's
# deliverable-vs-mention guard shape (#591) but INVERTING its in-doubt tiebreak.
# Options 1 (consult the step-1.35 workflow-scope signal) and 2 (a
# scope.workflow_edits_allowed knob defaulting false) were declined for reasons
# the RATIONALE records.
#
# This block pins BOTH DIRECTIONS with the issue's own repro shapes as
# fixtures, plus the removal of the false-premise sentence so it cannot regress.
setup_path1481="$setup_path"   # concat of router + setup/ sub-files (#611)
rationale_path1481="$rationale_path"

# --- Fixtures: the two repro shapes from #1481 -------------------------------
# A. The deliverable shape (lightwork #4302 / #4307). Must NOT fire.
FIXTURE_DELIVERABLE_1481='fix(ci): rewrite the on: triggers across the six workflow files

## Acceptance criteria
- Every file under .github/workflows/ uses the same on: pull_request shape.
- Both .github/workflows/metadata-push-ios.yml and metadata-push-android.yml are updated.'

# B. The incidental scope-creep shape (issue-work.md step 2 guard). Must fire.
FIXTURE_INCIDENTAL_1481='fix(api): null-deref in the session refresh handler

## Suggested fix
Guard the null in src/session.ts, and while you are in there add a new
.github/workflows/lint.yml job so this class of bug gets caught in CI.'

# Both fixtures satisfy the ENTRY condition — i.e. the pre-#1481 unconditional
# match would have deferred both. This is what makes them a both-direction pair.
for fixture_var_1481 in FIXTURE_DELIVERABLE_1481 FIXTURE_INCIDENTAL_1481; do
  if printf '%s' "${!fixture_var_1481}" | grep -qF '.github/workflows/'; then
    pass=$((pass+1))
    printf '  %sPASS%s  #1481 %s satisfies Detector 1 entry condition (pre-#1481 match would have fired)\n' \
      "$GREEN" "$RESET" "$fixture_var_1481"
  else
    fail=$((fail+1))
    printf '  %sFAIL%s  #1481 %s does not contain .github/workflows/ — it is not a valid Detector 1 fixture\n' \
      "$RED" "$RESET" "$fixture_var_1481"
  fi
done

# Direction A (must NOT fire): the deliverable fixture carries neither firing
# case's mechanical signal — no CI-gating purpose (case 1), no suggested-fix
# scope-creep framing (case 2).
if printf '%s' "$FIXTURE_DELIVERABLE_1481" \
    | grep -qiE 'suggested (fix|approach)|make the check pass|skip the|disable the|bypass|relax the gate'; then
  fail=$((fail+1))
  printf '  %sFAIL%s  #1481 deliverable fixture matches a Detector 1 firing signal — it must not fire\n' "$RED" "$RESET"
else
  pass=$((pass+1))
  printf '  %sPASS%s  #1481 deliverable fixture matches no Detector 1 firing signal (must not fire)\n' "$GREEN" "$RESET"
fi

# Direction B (must still fire): the incidental fixture carries case 2's
# suggested-fix scope-creep framing.
if printf '%s' "$FIXTURE_INCIDENTAL_1481" | grep -qiE 'suggested (fix|approach)'; then
  pass=$((pass+1))
  printf '  %sPASS%s  #1481 incidental fixture matches Detector 1 case-2 scope-creep framing (must still fire)\n' "$GREEN" "$RESET"
else
  fail=$((fail+1))
  printf '  %sFAIL%s  #1481 incidental fixture no longer matches case-2 scope-creep framing\n' "$RED" "$RESET"
fi

# --- Spec surface: the four-way framing test ---------------------------------
assert_contains "$setup_path1481" \
  'CI-gating framing (FIRE)' \
  "setup.md Detector 1 documents case 1 CI-gating framing as FIRE (#1481)"
assert_contains "$setup_path1481" \
  'Incidental scope-creep framing (FIRE)' \
  "setup.md Detector 1 documents case 2 incidental scope-creep as FIRE (#1481)"
assert_contains "$setup_path1481" \
  'Deliverable framing (DO NOT FIRE)' \
  "setup.md Detector 1 documents case 3 deliverable framing as DO NOT FIRE (#1481)"
assert_contains "$setup_path1481" \
  'Pure meta-mention (DO NOT FIRE)' \
  "setup.md Detector 1 documents case 4 pure meta-mention as DO NOT FIRE (#1481)"
assert_contains "$setup_path1481" \
  'entry condition, not its firing condition' \
  "setup.md Detector 1 separates entry condition from firing condition (#1481)"
assert_contains "$setup_path1481" \
  'When in doubt, do NOT fire' \
  "setup.md Detector 1 inverts Detector 2's in-doubt asymmetry (#1481)"

# --- Spec surface: the two explicit non-reasons ------------------------------
assert_contains "$setup_path1481" \
  'it is the wrong lever, not a missing one' \
  "setup.md Detector 1 declines option 1 and forbids adding a workflow-scope probe (#1481)"
assert_contains "$setup_path1481" \
  'The harness auto-mode classifier' \
  "setup.md Detector 1 names the classifier as an explicit non-reason to fire (#1481)"

# --- The false premise must be gone and must not come back -------------------
assert_not_contains "$setup_path1481" \
  'a worker dispatched against such an issue produces a branch' \
  "setup.md no longer claims a workflow-touching worker cannot open a PR (#1481)"

assert_contains "$setup_path1481" \
  'issues/1481' \
  "setup.md cites issue #1481 as the source of the Detector 1 narrowing"
assert_contains "$rationale_path1481" \
  'Detector 1 narrowed' \
  "RATIONALE has a Detector 1 narrowing section (#1481)"
assert_contains "$rationale_path1481" \
  'issues/1481' \
  "RATIONALE cites issue #1481 as the source of the Detector 1 narrowing"
assert_contains "$rationale_path1481" \
  '8 of 8 workflow-touching issues shipped and merged' \
  "RATIONALE records the measured field evidence behind the narrowing (#1481)"

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
#
# Post-#808: `version_cursor` is one of the eight cold structs split out of
# do-work.md into do-work/orchestrator-state-reference.md (each consumed by
# exactly one other phase file — version_cursor's is dispatch-rules.md's
# next-available-version computation). do-work.md still *names*
# `version_cursor` in its hot/cold pointer prose (so the struct-list
# assertion below is unchanged), but the full bullet — including the #437
# issue citation — now lives in the split-out file; check there instead.
orch_state_ref_path808="$repo_root/plugins/shipyard/commands/do-work/orchestrator-state-reference.md"
assert_contains "$do_work_path" \
  'version_cursor' \
  "do-work.md struct list names version_cursor (#437)"
assert_contains "$orch_state_ref_path808" \
  'issues/437' \
  "orchestrator-state-reference.md cites issue #437 as the source of version_cursor (#808 split)"
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
# drain.md's own per-PR primary-checkout-leak section was extracted to
# drain-pre-dispatch-branch-reap.sh (issue #1289) — drain.md itself now only
# points at steady-state.md's A.0.6 guard for the drain-ENTRY case (line
# "Run the exact guard from steady-state.md step A.0.6"), so the fallback-
# strip literal for the per-PR case lives in the script now. Concatenate
# drain.md with the script so this assertion keeps finding it regardless of
# which file it lives in.
drain_pre_dispatch_reap_script="$repo_root/plugins/shipyard/scripts/drain-pre-dispatch-branch-reap.sh"
drain_family_path="$(mktemp -t do-work-drain-concat.XXXXXX)"
cat "$drain_path" "$drain_pre_dispatch_reap_script" > "$drain_family_path" 2>/dev/null
trap 'rm -f "$setup_path" "$operate_path" "$steady_state_path" "$drain_family_path"' EXIT
for f in "$steady_state_path" "$drain_family_path"; do
  fname=$(basename "$f")
  [[ "$f" == "$drain_family_path" ]] && fname="drain.md"
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
# Issue #617 split: the #457 merged-direct-ungated refinement moved into auto-merge.md.
worker_preamble_path457="$repo_root/plugins/shipyard/skills/worker-preamble/auto-merge.md"
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
# shellcheck disable=SC2016  # literal needle — must NOT expand $GATE_LABEL
assert_contains "$setup_path" \
  'WARNING: #<N> $GATE_LABEL apply did not land' \
  "setup.md step 6 reads back .labels and warns loudly on a silent no-op (#508/#519/#608)"
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
  'match none of the seven' \
  "dont.md ties the invalid defer rationalizations to the seven defer_reason_class values (#531, #1165, #1426)"
assert_contains "$rationale_path" \
  'Self-filed follow-ups re-enter the backlog like any other issue' \
  "RATIONALE.md states self-filed follow-ups re-enter the backlog (#531)"
assert_contains "$rationale_path" \
  'soft cap on the per-session count of issues filed by this session' \
  "RATIONALE.md documents the bounded-regress soft-cap guard, not blanket refusal (#531)"
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
assert_contains "$rationale_path" \
  'defers accumulated 5+ identical diagnosis comments per issue across sessions' \
  "RATIONALE.md documents the failure mode needs-human-review closes for external-dependency / human-decision-required defers (#536)"
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

# ----------------------------------------------------------------------
# (N+4) Concurrent-session guard survives zsh's nomatch option when no
#        agent-* worktrees exist (issue #546).
#
# The concurrent-session guard (step C, per-dispatch before self-assign)
# historically used a bare glob:
#   for wt_dir in "$(git rev-parse --show-toplevel)/.git/worktrees"/agent-*; do
# Under zsh's default `nomatch` option, a glob that matches no entries
# raises a fatal error — aborting the entire bash block with exit 1.
# In the observed repro (session do-work-20260611T231002Z-91471,
# mattsears18/lightwork, ~23:25Z 2026-06-11) this silently dropped the
# self-assign (`gh issue edit <N> --add-assignee @me`) that followed the
# guard in the same block.
#
# Same class as #335 (which fixed setup.md's 3b loop); the fix replaces
# the bare glob with the #335 `find` idiom that exits 0 on no matches
# so the loop body simply doesn't iterate. The `[ -d "$wt_dir" ] || continue`
# guard that accompanied the old glob is no longer needed (find only emits
# matching directories by construction) and was removed.
assert_contains "$steady_state_path" \
  'issues/546' \
  "steady-state.md cites issue #546 as the source of the concurrent-session-guard zsh-nomatch fix"
# The bare-glob form must be gone from the concurrent-session-guard block.
# The exact shape that tripped the nomatch abort — note the distinctive
# $(git rev-parse --show-toplevel) prefix that identifies the guard vs
# the A.1 shipped-path (which uses ${PRIMARY_CHECKOUT}).
assert_not_contains "$steady_state_path" \
  'rev-parse --show-toplevel)/.git/worktrees"/agent-*' \
  "steady-state.md concurrent-session guard no longer uses the bare agent-* glob (zsh nomatch hazard, #546)"
# The hardened find-based replacement must be present in the concurrent-
# session guard.
assert_contains "$steady_state_path" \
  "find \"\$(git rev-parse --show-toplevel)/.git/worktrees\" -maxdepth 1 -type d -name 'agent-*' 2>/dev/null" \
  "steady-state.md concurrent-session guard uses the find-based loop to avoid zsh nomatch (#546)"

# (N+5) Invalid defer_reason_class tokens are normalized before recording
#        (issue #547).
#
# Observed in session do-work-20260611T231002Z-91471: 3 of 7 scope agents
# returned a defer_reason_class outside the five-value enum despite the
# dispatch prompt enumerating the enum verbatim ("media_production",
# "external_console_dependency", "Umbrella / Epic requiring human discretion").
# The recording path only handled the *missing* case (default to
# confirmed-non-shippable-as-single-PR); it said nothing about a
# *present-but-invalid* class, so the orchestrator had to improvise on each
# occurrence — risking inconsistent deferred_issues records.
#
# The fix adds:
# 1. An explicit normalization branch in setup.md step 6's recording path
#    (step 3): missing → default; present-but-invalid → infer from
#    evidence_pointer shape; valid → use as-is.
# 2. A tightened scope-agent prompt instruction demanding the EXACT LITERAL
#    TOKEN with the five valid values named, concrete bad examples cited,
#    and a statement that invalid tokens cost an extra reshaping pass.

# The issue citation must be present in setup.md.
assert_contains "$setup_path" \
  'issues/547' \
  "setup.md cites issue #547 as the source of the invalid-class normalization branch"

# The normalization heading must be present.
assert_contains "$setup_path" \
  "Normalize \`defer_reason_class\` before recording" \
  "setup.md step 6 recording path carries the invalid-class normalization heading (#547)"

# The three-branch enumeration must be present (missing / present-but-invalid / valid).
assert_contains "$setup_path" \
  'Present but not one of the seven valid tokens' \
  "setup.md recording path enumerates the present-but-invalid branch (#547, #1165, #1426)"

# The inference rules must cite the evidence_pointer shape for normalization.
assert_contains "$setup_path" \
  'evidence_pointer shape match' \
  "setup.md normalization log line references evidence_pointer shape match (#547)"

# The scope-agent prompt instruction must demand the literal token.
assert_contains "$setup_path" \
  'EXACT LITERAL TOKEN' \
  "setup.md scope-agent prompt instruction demands the EXACT LITERAL TOKEN for defer_reason_class (#547)"

# The prompt instruction must enumerate the five valid tokens inline.
assert_contains "$setup_path" \
  'confirmed-blocker-still-open' \
  "setup.md scope-agent prompt instruction names confirmed-blocker-still-open as a valid token (#547)"

# The prompt instruction must cite the concrete bad examples from the repro session.
assert_contains "$setup_path" \
  'media_production' \
  "setup.md scope-agent prompt instruction cites media_production as an invalid example (#547)"

# (N+6) A.0/A.1 reconcile-turn templates must derive SESSION_ID
#       cwd-independently to prevent silent token attribution loss (#548).
#
# The reconcile turn is where the #477 cwd-leak fires (harness relocates
# orchestrator cwd into the just-returned agent's `agent-*` worktree).
# A bare `cat .shipyard-session-id` at that point reads from the agent
# worktree (no stash there) and returns empty, making every downstream
# `session-state.sh` call exit 64 silently.
#
# Repro: session do-work-20260612T035752Z-44019 — 169k tokens unattributed,
# PR #1925 missing from session_prs, cost comment failed with
# "Body cannot be blank", agent worktree not immediately reaped.
#
# Fix: steady-state.md A.0 gains a new "A.0 required preamble" subsection
# documenting the mandatory derive-session-id block; A.0 strict/degraded
# and A.1 shipped/green cost-comment bash blocks use "$SESSION_ID" with
# the preamble's guard; all reap blocks derive SESSION_ID after STABLE_DIR
# and pass "${SESSION_ID:-unknown}"; the spec emits a loud
# "[session-id-derive] empty" advisory when both derive paths fail.
assert_contains "$steady_state_path" \
  'issues/548' \
  "steady-state.md cites issue #548 for the A.0 required session-id derive preamble"
assert_contains "$steady_state_path" \
  'A.0 required preamble' \
  "steady-state.md A.0 has the required preamble subsection for cwd-independent session-id derive (#548)"
assert_contains "$steady_state_path" \
  'derive-session-id' \
  "steady-state.md A.0 preamble uses session-identity.sh derive-session-id (#548, moved from worktree-reap.sh by #941)"
assert_contains "$steady_state_path" \
  '[session-id-derive] empty' \
  "steady-state.md A.0/A.1 blocks emit a loud advisory when session-id derive returns empty (#548)"
assert_contains "$steady_state_path" \
  'SESSION_ID:-unknown' \
  "steady-state.md reap blocks pass \${SESSION_ID:-unknown} to worktree-reap.sh reap (#548)"

# (N+7) Scoping agents under-claim shared regression-test files for fix-class
#        issues — worker edits outside claimed_paths defeat collision tracking
#        and cause drain-phase rebase bails (issue #554).
#
# Repro (session do-work-20260612T115814Z-28614, C=2):
#   - Scope agent for #548 returned files: [steady-state.md, plugin.json,
#     CHANGELOG.md] — did NOT claim do-work-split.test.sh.
#   - The #548 issue-worker (PR #551) edited do-work-split.test.sh anyway
#     (repo convention: every fix adds a block to the shared suite).
#   - Scope agent for #546 (PR #550) DID claim that file; its PR merged first.
#   - The drain-phase fix-rebase for PR #551 bailed:
#     "blocked rebase #551: merge conflict extends beyond coordinated
#     manifest+CHANGELOG rows (plugins/shipyard/scripts/tests/do-work-split.test.sh)"
#   - Manual rebase required (highest-cost outcome short of lost work).
#
# Phase-1 fix (this PR): add an instruction to the scoping-agent prompt in
# setup.md step 6 requiring that for fix-class issues in repos with a shared
# regression-test accumulator file, the agent MUST include that file in
# `files` even when the issue body does not name it. This mirrors the
# coordination-managed-paths mechanism (plugin.json + CHANGELOG.md) and
# converts the unclaimed-edit drain-phase conflict into a dispatch-time park.
#
# Phase-2 fix (deferred): config-driven always_claimed_paths surface
# (scope_preflight.always_claimed_paths or similar) that the orchestrator
# unions into every ready entry's claimed_paths before the collision check,
# providing a config-driven guarantee rather than relying on agent judgment.

# The issue citation must be present in setup.md.
assert_contains "$setup_path" \
  'issues/554' \
  "setup.md step 6 cites issue #554 as the source of the shared-regression-test inclusion rule"

# The augmentation paragraph heading must be present.
# Note: use double-quotes with escaped backtick to avoid SC2016.
assert_contains "$setup_path" \
  "shared regression-test suite inclusion" \
  "setup.md step 6 carries the shared-regression-test files augmentation paragraph (#554)"

# The rule must identify fix-class issues by label.
assert_contains "$setup_path" \
  'fix-class issues' \
  "setup.md step 6 files augmentation uses the fix-class terminology (#554)"

# The rule must name the do-work-split.test.sh file as the concrete repro example.
assert_contains "$setup_path" \
  'do-work-split.test.sh' \
  "setup.md step 6 files augmentation cites do-work-split.test.sh as the concrete repro example (#554)"

# The rule must explain the failure mode (drain-phase rebase bail, not dispatch-time park).
assert_contains "$setup_path" \
  'dispatch-time park' \
  "setup.md step 6 files augmentation explains the park-vs-rebase-bail tradeoff (#554)"

# ── Regression: scope-preflight re-gates human-cleared issues (#569) ──────────
#
# Fix 1: freshness check must honor a human gate-clear (label timeline) and a
#   <!-- do-work-decision-resolved --> sentinel as skip signals.
# Fix 2: scope-agent prompt must instruct the agent to read the comment thread
#   and recognize maintainer decision comments before judging actionability.

# Fix 1a — gate-clear check must be present as a numbered step in the
#   freshness check sequence and reference issue #569.
assert_contains "$setup_path" \
  'human gate-clear' \
  "setup.md freshness check documents the human gate-clear skip signal (#569)"

assert_contains "$setup_path" \
  '#569' \
  "setup.md freshness check references issue #569"

# Fix 1a — the timeline-event API call must be documented.
assert_contains "$setup_path" \
  'unlabeled' \
  "setup.md freshness check documents the unlabeled timeline event check (#569)"

assert_contains "$setup_path" \
  'needs-human-review' \
  "setup.md freshness check names needs-human-review as the label to watch (#569)"

# Fix 1b — the decision-resolved sentinel must appear as Signal B in the
#   freshness check.
assert_contains "$setup_path" \
  '<!-- do-work-decision-resolved -->' \
  "setup.md freshness check documents the do-work-decision-resolved sentinel (#569)"

assert_contains "$setup_path" \
  'Signal B' \
  "setup.md freshness check names the sentinel check as Signal B (#569)"

# The when-not-to-apply list must include both new skip triggers.
assert_contains "$setup_path" \
  'Signal A' \
  "setup.md when-not-to-apply list mentions Signal A (label removal) (#569)"

# Fix 2 — scope-agent prompt must instruct the agent to read the comment
#   thread before judging actionability.
assert_contains "$setup_path" \
  'read the issue' \
  "setup.md scope-agent prompt instructs agent to read comment thread (#569)"

assert_contains "$setup_path" \
  'do-work-decision-resolved' \
  "setup.md scope-agent prompt mentions do-work-decision-resolved sentinel (#569)"

# CLAUDE.md must document the decision-resolved sentinel convention so
#   /my-turn and human maintainers know to stamp it.
claude_md_path="$repo_root/CLAUDE.md"
assert_contains "$claude_md_path" \
  '<!-- do-work-decision-resolved -->' \
  "CLAUDE.md documents the do-work-decision-resolved sentinel convention (#569)"

assert_contains "$claude_md_path" \
  'Decision-resolved sentinel' \
  "CLAUDE.md has a 'Decision-resolved sentinel' heading entry (#569)"

# (issue #691) CHANGELOG-backfill machinery removed.
#
# Option 3 of #691 dropped the per-entry PR number from the CHANGELOG
# convention: entries now cite `closes #N` (the issue) only, with no PR number
# and no `PR #TBD` placeholder. With no placeholder to fill, the entire A.1
# `shipped`-reconcile backfill block (#581/#583, hardened by #700/#704) was
# deleted — both write paths (direct Contents API commit + the auto-merged
# `do-work/changelog-backfill-<M>` PR fallback), the `PR #TBD` grep/sed, and
# the Scope-and-conditions docs. Guard that no residual backfill logic or
# placeholder mandate remains in the do-work spec.
assert_not_contains "$steady_state_path" \
  'PR #TBD' \
  "steady-state.md no longer carries any PR #TBD backfill machinery (#691)"
assert_not_contains "$steady_state_path" \
  'changelog-backfill' \
  "steady-state.md no longer carries the [changelog-backfill] backfill step (#691)"

# (N) Denied-`Agent`-dispatch recovery branch (issue #718).
#
# The orchestrator's own `Agent` dispatch can be REFUSED by the Claude Code
# auto-mode permission classifier — the tool call never happens, so there is
# no worker, no worktree, no agent_id, and no completion notification. Before
# #718 the spec enumerated a dispatch's outcomes as shipped/blocked/noop/errored
# and had no branch at all for "the dispatch was refused," leaving the recovery
# to improvisation. The dangerous default under a denial is to keep rewording
# the prompt until it gets through — which is precisely the bypass the
# classifier exists to prevent.
#
# The load-bearing half of the spec is therefore the GUARDRAIL, not the
# plumbing. These assertions guard, in order:
#   - the branch exists in dispatch-rules.md (the file both dispatch sites
#     consult) and is reachable from steady-state step C AND setup step 7;
#   - the one-reframe-only rule, and that the reframe is a CORRECTION (more
#     accurate) rather than a softening (more permissive-sounding);
#   - the explicit prohibitions: no wording iteration, no retry when the work
#     genuinely needs the denied capability, no routing around via a different
#     subagent_type / split dispatch / inline execution;
#   - second denial => hand back, never a third attempt;
#   - the denial is RECORDED (dispatch_denials struct) and SURFACED
#     (`Dispatch denied:` in the end-of-session summary) rather than silently
#     costing a dispatch slot;
#   - the in_flight write-through is post-dispatch, so a denial leaves no
#     phantom slot;
#   - the content-integrity boundary: the classifier's reasoning never reaches
#     a public GitHub artifact (matches worker-preamble's #341 rule).
dispatch_rules_path718="$dispatch_rules_path"
steady_router_path718="$steady_state_router_path"
pool_fill_path718="$repo_root/plugins/shipyard/commands/do-work/setup/07-pool-fill.md"

assert_contains "$dispatch_rules_path718" \
  'Dispatch denied by the harness permission classifier' \
  "dispatch-rules.md carries the denied-dispatch branch (#718)"
assert_contains "$dispatch_rules_path718" \
  'Permission for this action was denied by the Claude Code auto mode classifier' \
  "dispatch-rules.md quotes the verbatim harness denial so it is recognizable (#718)"
assert_contains "$dispatch_rules_path718" \
  'no completion notification is coming' \
  "dispatch-rules.md states a denied dispatch produces no completion notification (#718)"

# The guardrail — one reframe, and only as a correction.
assert_contains "$dispatch_rules_path718" \
  'Exactly ONE re-dispatch is permitted' \
  "dispatch-rules.md caps re-dispatch at exactly one (#718)"
assert_contains "$dispatch_rules_path718" \
  'overstated the work' \
  "dispatch-rules.md gates the reframe on the prompt having overstated the blast radius (#718)"
assert_contains "$dispatch_rules_path718" \
  'never merely more permissive-sounding' \
  "dispatch-rules.md requires the reframe be more ACCURATE, not more permissive-sounding (#718)"
assert_contains "$dispatch_rules_path718" \
  'Do NOT iterate prompt wording against the classifier' \
  "dispatch-rules.md forbids iterating prompt wording against the classifier (#718)"
assert_contains "$dispatch_rules_path718" \
  'Do NOT re-dispatch when the work genuinely requires the denied capability' \
  "dispatch-rules.md forbids retrying when the work really does need the denied capability (#718)"
assert_contains "$dispatch_rules_path718" \
  'Do NOT route around the denial' \
  "dispatch-rules.md forbids routing around the deny via another tool/agent/split (#718)"
assert_contains "$dispatch_rules_path718" \
  'Never a third attempt' \
  "dispatch-rules.md caps attempts at two — never a third (#718)"
assert_contains "$dispatch_rules_path718" \
  'needs-human-review' \
  "dispatch-rules.md hands a twice-denied issue target back via needs-human-review (#718)"

# Content-integrity boundary — the classifier's reasoning stays local.
assert_contains "$dispatch_rules_path718" \
  'must NOT quote, paraphrase, explain, or theorize about the classifier' \
  "dispatch-rules.md keeps the classifier's reasoning out of public GitHub artifacts (#718/#341)"

# Recorded + surfaced, not silently costing a slot.
assert_contains "$do_work_path" \
  'dispatch_denials' \
  "do-work.md documents the dispatch_denials orchestrator-state struct (#718)"
assert_contains "$cleanup_path" \
  'Dispatch denied (#718)' \
  "cleanup-summary.md surfaces a Dispatch denied line in the end-of-session summary (#718)"
assert_contains "$cleanup_path" \
  'silently costs a dispatch slot' \
  "cleanup-summary.md names the silent-slot-cost this line exists to prevent (#718)"

# Reachable from BOTH dispatch sites, and the phantom-slot ordering rule.
assert_contains "$steady_router_path718" \
  'refused by the harness permission classifier' \
  "steady-state.md step C routes a refused Agent call to the denied-dispatch branch (#718)"
assert_contains "$pool_fill_path718" \
  'If the harness permission classifier refuses an' \
  "setup step 7 (initial pool fill) routes a refused Agent call to the denied-dispatch branch (#718)"
assert_contains "$steady_router_path718" \
  'The write-through runs only AFTER the' \
  "steady-state.md writes the in_flight slot only post-dispatch, so a denial leaves no phantom slot (#718)"

# The Don't list carries the guardrail too — it is the surface a drifting
# orchestrator is most likely to re-read mid-session.
assert_contains "$dont_path" \
  "Don't iterate prompt wording against the permission classifier" \
  "dont.md forbids iterating prompt wording against the classifier (#718)"
assert_contains "$dont_path" \
  "Don't let a denied dispatch silently cost a slot" \
  "dont.md forbids letting a denied dispatch silently cost a slot (#718)"

# ----------------------------------------------------------------------
# (Issue #746) The operator layer's "standing authorization" claim over-sold
# what the Claude Code auto-mode classifier actually grants: a `merge-pr` /
# `close-pr` item against an inherited third-party PR (one this session
# never opened or touched — the common case being a Dependabot PR) gets
# denied by the classifier BY NAME, regardless of the operator layer's
# default-on posture. #746 mirrors #718's dispatch-denial contract for
# operator actions:
#   - the scope correction: standing authorization reliably covers only
#     session-owned artifacts; inherited third-party merge-pr/close-pr
#     items need a batched (one-per-session, not one-per-item)
#     AskUserQuestion confirmation first;
#   - a denied operator action is RECORDED (operator_denials struct) and
#     SURFACED (`Operator denied:` in the end-of-session summary) rather
#     than silently costing a queue item;
#   - at most one re-attempt, and only to cite an explicit confirmation
#     already on record — never to iterate wording against the classifier;
#   - a second denial (or no confirmation to cite) degrades to a
#     agent-console hand-back, never a silent drop;
#   - the content-integrity boundary: the classifier's reasoning never
#     reaches a public GitHub artifact (matches #718/#341).
assert_contains "$do_work_path" \
  'operator_denials' \
  "do-work.md documents the operator_denials orchestrator-state struct (#746)"
assert_contains "$do_work_path" \
  'session-owned artifacts' \
  "do-work.md Args section scopes standing authorization to session-owned artifacts (#746)"

# The scope correction — session-owned vs inherited third-party PRs, and
# the batched (not per-item) confirmation.
assert_contains "$operate_path" \
  'Scope of standing authorization' \
  "operate.md carries the session-owned vs inherited-third-party-PR scope section (#746)"
assert_contains "$operate_path" \
  'Permission for this action was denied by the Claude Code auto mode classifier' \
  "operate.md quotes the verbatim harness denial so it is recognizable (#746)"
# shellcheck disable=SC2016  # literal needle — must NOT expand `session_prs`
assert_contains "$operate_path" \
  'Any PR in `session_prs`' \
  "operate.md defines session-owned artifacts concretely (#746)"
assert_contains "$operate_path" \
  'Proceed with all' \
  "operate.md's batched AskUserQuestion offers a single proceed-with-all option (#746)"
assert_contains "$operate_path" \
  'one-shot, session-scoped ask' \
  "operate.md caps the inherited-PR confirmation at one ask per session, not per item (#746)"

# The denial branch — record, one re-attempt (only to cite an existing
# confirmation), second denial hands back.
assert_contains "$operate_path" \
  'Operator action denied by the harness permission classifier' \
  "operate.md carries the denied-operator-action branch (#746)"
assert_contains "$operate_path" \
  'At most ONE re-attempt' \
  "operate.md caps operator-action re-attempts at exactly one (#746)"
assert_contains "$operate_path" \
  'Do NOT iterate wording against the classifier' \
  "operate.md forbids iterating operator-action wording against the classifier (#746)"
assert_contains "$operate_path" \
  'Do NOT route around the denial' \
  "operate.md forbids routing an operator denial around via a different mechanism (#746)"
assert_contains "$operate_path" \
  'degrade to a hand-back' \
  "operate.md degrades a twice-denied operator item to a hand-back rather than dropping it (#746)"
assert_contains "$operate_path" \
  'to any public GitHub artifact' \
  "operate.md keeps the classifier's reasoning out of public GitHub artifacts for operator denials (#746)"

# Recorded + surfaced, not silently costing a queue item.
assert_contains "$cleanup_path" \
  'Operator denied (#746)' \
  "cleanup-summary.md surfaces an Operator denied line in the end-of-session summary (#746)"
assert_contains "$cleanup_path" \
  'silently costs a queue item' \
  "cleanup-summary.md names the silent-queue-item-cost this line exists to prevent (#746)"

# operate.md's own Don't list carries the guardrail too.
assert_contains "$operate_path" \
  "Don't iterate operator-action wording against the permission classifier" \
  "operate.md forbids iterating operator-action wording against the classifier (#746)"
assert_contains "$operate_path" \
  "Don't assume standing authorization covers a" \
  "operate.md forbids assuming standing authorization covers an inherited-PR merge-pr/close-pr item (#746)"

# (Issue #729) The orchestrator's own worktree is always dirty at
# end-of-session (step 0.55 stashes `.shipyard-session-id`, an untracked
# file, into it for the session's lifetime), so #712's non-force-first
# `git worktree remove` ALWAYS refused and fell through to the raw
# `--force` fallback on every single session — defeating #712's mitigation
# for the one worktree guaranteed to need reaping every run. The fix
# deletes the stash before attempting the remove (it has no value past
# this point) and routes the `--force` escalation, if still needed for some
# other reason, through worktree-reap.sh's evidence-gated `reap` action
# instead of a raw ungated `--force` call.
# shellcheck disable=SC2016  # literal needle — must NOT expand $ORCH_WT_ABS
assert_contains "$cleanup_path" \
  'rm -f "$ORCH_WT_ABS/.shipyard-session-id"' \
  "cleanup-summary.md deletes the .shipyard-session-id stash before reaping the orchestrator worktree (#729)"
assert_contains "$cleanup_path" \
  '--classification "self-orchestrator"' \
  "cleanup-summary.md routes the orchestrator-worktree reap through worktree-reap.sh's evidence-gated helper (#729)"
# shellcheck disable=SC2016  # literal needle — must NOT expand $ORCH_WT_ABS
assert_not_contains "$cleanup_path" \
  'git worktree remove --force "$ORCH_WT_ABS"' \
  "cleanup-summary.md no longer calls a raw, ungated --force on the orchestrator worktree (#729)"

# Ordering matters: the stash MUST be deleted before the reap call runs, not
# after — a delete that races in after a failed remove doesn't help.
# shellcheck disable=SC2016  # literal needle — must NOT expand $ORCH_WT_ABS
rm_stash_line=$(grep -n 'rm -f "\$ORCH_WT_ABS/\.shipyard-session-id"' "$cleanup_path" | head -1 | cut -d: -f1)
self_orch_reap_line=$(grep -n 'classification "self-orchestrator"' "$cleanup_path" | head -1 | cut -d: -f1)
if [[ -n "$rm_stash_line" && -n "$self_orch_reap_line" && "$rm_stash_line" -lt "$self_orch_reap_line" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "cleanup-summary.md deletes the session-id stash BEFORE the orchestrator-worktree reap call, not after (#729)"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "cleanup-summary.md deletes the session-id stash BEFORE the orchestrator-worktree reap call, not after (#729)"
  printf '    rm_stash_line=%s self_orch_reap_line=%s (rm must come first)\n' "${rm_stash_line:-missing}" "${self_orch_reap_line:-missing}"
  fail=$((fail+1))
fi

# (Issue #736) Collision-aware branch step — git enforces one-worktree-per-
# branch, so a re-dispatched worker's `git checkout -B do-work/issue-<N>`
# hard-fails when a prior (usually reaped) dispatch for the same issue left
# its worktree on disk still holding that branch name. The spec previously
# had no defined recovery, leaving the worker to improvise at exactly the
# moment it's most likely to do something destructive (removing another
# worktree, force-deleting a branch that might hold unpushed work). The fix
# adds a local-name/remote-name split to issue-work.md §3: on the
# `already used by worktree` failure, check out a collision-free LOCAL
# branch instead, but still push to and open the PR against the canonical
# `do-work/issue-<N>` REMOTE branch so orphan triage can still find it.
issue_work_path736="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"

assert_contains "$issue_work_path736" \
  'issues/736' \
  "issue-work.md cites issue #736 as the source of the collision-aware branch step"
assert_contains "$issue_work_path736" \
  'already used by worktree' \
  "issue-work.md §3 detects the worktree-name-collision failure mode (#736)"
# #736's invariant is that REMOTE_BRANCH is the DETERMINISTIC name the push,
# the PR head, and orphan triage all resolve to — not that it is literally
# `do-work/issue-<N>`. Since #1562 a split dispatch is branched
# `do-work/slice-<N>` instead (a branch literally named `do-work/issue-<N>`
# auto-links the issue such a PR must not close, #893), so §3 takes the
# dispatch prompt's `Branch:` value verbatim. Both names are still
# derivable from <N> alone, which is what #736 actually depends on.
assert_contains "$issue_work_path736" \
  "REMOTE_BRANCH=\"<the dispatch prompt's Branch: line, verbatim>\"" \
  "issue-work.md §3 pins REMOTE_BRANCH to the dispatched branch name (#736, #1562)"
assert_contains "$issue_work_path736" \
  'do-work/slice-<N>' \
  "issue-work.md recognizes the split dispatch's neutral branch shape (#1562)"
assert_contains "$issue_work_path736" \
  'Do NOT touch the other worktree' \
  "issue-work.md §3 forbids touching the colliding worktree on fallback (#736)"
# shellcheck disable=SC2016
# Literal needle — must NOT expand $COLLISION_STAMP; this is markdown prose
# text. The timestamp suffix is now hoisted to its own assignment line rather
# than interpolated inline — #1314 swept every argument-position/prefixed-RHS
# command substitution out of the spec tree, so assert on the resulting shape.
assert_contains "$issue_work_path736" \
  'LOCAL_BRANCH="do-work/issue-<N>-$COLLISION_STAMP"' \
  "issue-work.md §3 falls back to a collision-free LOCAL branch name (#736)"
# shellcheck disable=SC2016
# Backticks/single-quotes are literal markdown punctuation in the needle.
assert_contains "$issue_work_path736" \
  'git push -u origin "HEAD:refs/heads/${REMOTE_BRANCH:-do-work/issue-<N>}"' \
  "issue-work.md §5 pushes to the canonical REMOTE_BRANCH regardless of the local checkout name (#736)"
# shellcheck disable=SC2016
# Literal needle — must NOT expand ${REMOTE_BRANCH}; this is markdown prose text.
assert_contains "$issue_work_path736" \
  '--head "${REMOTE_BRANCH:-do-work/issue-<N>}"' \
  "issue-work.md §5 opens the PR with an explicit --head against REMOTE_BRANCH (#736)"
assert_contains "$issue_work_path736" \
  "Don't touch another worktree when" \
  "issue-work.md Don't list carries the collision guardrail (#736)"

# (Issue #739) Orphan triage's step-3c sweep must recognize #736's collision-
# fallback LOCAL branch name (`do-work/issue-<N>-<timestamp>`) — a bare
# `sed 's|do-work/issue-||'` extraction and an exact-match branch check both
# treat the suffix as part of the issue number / branch name, so the sweep
# never finds the canonical remote push and either pushes a spurious second
# remote branch + opens a duplicate PR, or fails to recognize an alive
# suffixed worktree as "already handled" in the stale-assign row.
#
# As of #1202 (PR moving the step-0.45 pre-relocation sweeps out of the
# background group), step 3c's executable form lived in
# 01c-label-recovery-refine.md, not 00b-parallelization-cache.md — 00b's
# background group narrowed to steps 1.6 + 3a only, and 3c's own section in
# 01c gained the executable bash it previously lacked entirely (per PR
# #1209's body: "Step 3c had no executable bash anywhere outside 00b's
# background group ... Added the executable form to its own section").
#
# As of #1365 (follow-up to #1355), step 3c's ENTIRE state machine — this
# permissive extraction included — moved out of 01c-label-recovery-refine.md
# and into worktree-reap.sh's `triage_orphan_branches` function, callable as
# a single `triage-orphan-branches` subcommand (01c now documents the table
# as spec + a single-call invocation, not the executable bash itself). The
# property this guard protects didn't go away — it moved. Re-point the
# needles at their new home rather than deleting the guard (see
# `shipyard:worker-preamble`'s do-work-split.test.sh guidance: "if your
# change legitimately removes something a structural guard counts, re-point
# the guard at the property's new home").
setup_worktree_path739="$repo_root/plugins/shipyard/scripts/worktree-reap.sh"

assert_contains "$setup_worktree_path739" \
  "sed -E 's|^do-work/issue-([0-9]+).*|\\1|'" \
  "worktree-reap.sh triage_orphan_branches extracts the issue number permissively, tolerating a collision-fallback suffix (#739, moved from 01c §3c by #1365)"
# shellcheck disable=SC2016
# Literal needle — must NOT expand $n; this is shell script text.
assert_contains "$setup_worktree_path739" \
  'canonical_branch="do-work/issue-$n"' \
  "worktree-reap.sh triage_orphan_branches derives the canonical remote branch name independent of the local worktree branch (#739, moved from 01c §3c by #1365)"
# shellcheck disable=SC2016
# Literal needle — must NOT expand $canonical_branch; this is shell script text.
assert_contains "$setup_worktree_path739" \
  'pushed=$(git ls-remote --heads origin "$canonical_branch" 2>/dev/null)' \
  "worktree-reap.sh triage_orphan_branches checks the remote for the canonical branch, not the local (possibly suffixed) branch (#739, moved from 01c §3c by #1365)"
# shellcheck disable=SC2016
# Literal needle — must NOT expand $path/$canonical_branch; this is shell script text.
assert_contains "$setup_worktree_path739" \
  'git -C "$path" push -u origin "HEAD:refs/heads/$canonical_branch"' \
  "worktree-reap.sh triage_orphan_branches pushes the local worktree's commits under the canonical remote branch name (#739, moved from 01c §3c by #1365)"
# shellcheck disable=SC2016
# Literal needle — must NOT expand $canonical_branch; this is shell script text.
assert_contains "$setup_worktree_path739" \
  'open_pr=$("$GH" pr list --repo "$repo" --head "$canonical_branch"' \
  "worktree-reap.sh triage_orphan_branches looks up the open PR by the canonical branch name, not the local branch (#739, moved from 01c §3c by #1365)"
# shellcheck disable=SC2016
# Literal needle — must NOT expand $canonical_branch; this is shell script text.
assert_contains "$setup_worktree_path739" \
  '"$GH" pr create --repo "$repo" --head "$canonical_branch" --fill --label shipyard' \
  "worktree-reap.sh triage_orphan_branches opens the fallback PR with an explicit --head against the canonical branch (#739, moved from 01c §3c by #1365)"
assert_contains "$setup_worktree_path739" \
  "sed -E 's|^refs/heads/do-work/issue-([0-9]+).*|\\1|' | grep -qx \"\$n2\"" \
  "worktree-reap.sh triage_orphan_branches row-5 stale-assign check recognizes a collision-fallback worktree as already-handled (#739, moved from 01c §3c by #1365)"

# ── Regression: scope-preflight re-gates issues already resolved via
#    /resolve-decisions (#962) ──────────────────────────────────────────────
#
# Repro (lightwork#3054, lightwork#3051, 2026-07-25): /my-turn posted a
# <!-- shipyard-resolve-decisions --> comment and cleared needs-human-review;
# hours later, with no new information, /do-work's scope-preflight re-applied
# needs-human-review citing the SAME already-answered policy question. The
# #569 fix taught the freshness check + scope-agent prompt to recognize
# <!-- do-work-decision-resolved --> (a hand-written maintainer sentinel) as
# a gate-clear signal, but never taught either to recognize
# <!-- shipyard-resolve-decisions --> (the sentinel /resolve-decisions and
# /my-turn's reused walkthrough post automatically) — so a resolve-decisions
# clearance was invisible to both the freshness check and the scope agent.
#
# This closes the gap two ways: (1) both call sites now recognize BOTH
# sentinels identically, and (2) a new mechanical Recording-path guard
# (step 3.5) refuses to silently re-apply needs-human-review when a
# resolution comment postdates the last time the label was removed, unless
# the fresh defer names what changed since that resolution.

# Fix (1a) — freshness check's Signal B must recognize the resolve-decisions
#   sentinel alongside the decision-resolved sentinel.
assert_contains "$setup_path" \
  '<!-- shipyard-resolve-decisions -->' \
  "setup.md freshness check documents the shipyard-resolve-decisions sentinel (#962)"

assert_contains "$setup_path" \
  '#962' \
  "setup.md references issue #962"

# Fix (1a) — the when-not-to-apply list must also mention the new sentinel.
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$setup_path" \
  'do-work-decision-resolved -->` or `<!-- shipyard-resolve-decisions -->` sentinel comment was posted' \
  "setup.md when-not-to-apply list recognizes shipyard-resolve-decisions as a Signal B trigger (#962)"

# Fix (1b) — the scope-agent prompt instruction must also recognize the
#   resolve-decisions sentinel, not just do-work-decision-resolved.
# shellcheck disable=SC2016
# Backticks/apostrophes are literal markdown punctuation in the needle.
assert_contains "$setup_path" \
  'the marker `/shipyard:resolve-decisions` and `/my-turn`'"'"'s reused decision-gated walkthrough post automatically once every blocking decision has been answered' \
  "setup.md scope-agent prompt recognizes the shipyard-resolve-decisions sentinel (#962)"

# Fix (2) — the new mechanical re-gate guard must exist as its own numbered
#   Recording-path sub-step, distinct from step 4's label application.
assert_contains "$setup_path" \
  '3.5. **Re-gate guard' \
  "setup.md Recording path carries the 3.5 re-gate guard sub-step (#962)"

assert_contains "$setup_path" \
  'a resolved decision cannot be silently re-applied' \
  "setup.md re-gate guard names the failure mode it prevents (#962)"

# The guard must compare the resolution comment's timestamp against the
# last needs-human-review label APPLICATION, using the timeline API.
#
# #1557: the original anchor was the last `unlabeled` event, which made the
# guard structurally unable to fire — /resolve-decisions posts the decisions
# comment BEFORE removing the gate, so a genuine resolution is always a few
# seconds OLDER than the unlabel event it caused, and the
# `RESOLUTION_AT > LAST_UNGATE_AT` test could never be true on that flow.
# shellcheck disable=SC2016
# Literal needle — must NOT expand $(gh api ...); this is markdown prose text.
assert_contains "$setup_path" \
  'LAST_GATE_AT=$(gh api "repos/<owner>/<repo>/issues/<N>/timeline"' \
  "setup.md re-gate guard fetches the last needs-human-review label event (#962, anchor corrected by #1557)"

assert_contains "$setup_path" \
  'select(.event == "labeled" and .label.name == "needs-human-review")' \
  "setup.md re-gate guard anchors on the labeled event, not unlabeled (#1557)"

# The inert-anchor regression itself: the guard must no longer carry the old
# LAST_UNGATE_AT variable at all.
assert_not_contains "$setup_path" \
  'LAST_UNGATE_AT' \
  "setup.md re-gate guard no longer anchors on the unlabel event (#1557)"

# A PARTIAL /resolve-decisions run carries the same sentinel but deliberately
# leaves the gate on — it must not be read as a resolution.
assert_contains "$setup_path" \
  'contains("## Decisions resolved (partial")' \
  "setup.md re-gate guard excludes a partial resolve-decisions comment from RESOLUTION_AT (#1557)"

assert_contains "$setup_path" \
  'Only a PARTIAL resolution comment exists' \
  "setup.md re-gate guard carries a partial-resolution branch (#1557)"

# The guard must require the fresh defer to name what changed, else reject
# rather than silently re-gate.
assert_contains "$setup_path" \
  'MUST explicitly name what changed since that resolution' \
  "setup.md re-gate guard requires naming what changed since the resolution (#962)"

assert_contains "$setup_path" \
  're-gate guard #962' \
  "setup.md re-gate guard's rejection log line cites issue #962"

# The guard must scope itself to the two needs-human-review-gating classes,
# not external-dependency (which gates agent-console instead), and not
# time-gated / blocked-by-in-flight-pr (which gate with no label at all).
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$setup_path" \
  'external-dependency` gates with `agent-console` instead, and `time-gated` / `blocked-by-in-flight-pr` gate with no label at all' \
  "setup.md re-gate guard scopes itself to human-decision-required / confirmed-non-shippable-as-single-PR (#962, #1165, #1426)"

# ── Issue #997 — worker must re-read issue state before posting a decision;
#    /my-turn can resolve the same issue mid-dispatch ──────────────────────
#
# A long-running issue-work dispatch can outlive a concurrent session (a
# /shipyard:my-turn walkthrough, a maintainer's own comment) that resolves
# the same issue while the worker is still implementing. Nothing between
# step 0 and the decision-comment write (§5.5) / auto-merge arm (§6)
# re-reads the issue, so the worker had no way to notice a human already
# made the call the dispatch prompt told it to make autonomously — in the
# opposite direction. Closed by adding a §5.3 terminal-state re-read
# (state/labels/decision-sentinel-comments) immediately before §5.5, and by
# teaching step 2's comment classification that a `<!-- shipyard-resolve-
# decisions -->` / `<!-- do-work-decision-resolved -->` comment is a
# recorded human decision that outranks the dispatch prompt's own override
# instruction.
issue_work_path997="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"

assert_contains "$issue_work_path997" \
  '### 5.3 Terminal-state re-read — guard against a concurrent session dispositioning the issue mid-dispatch' \
  "issue-work.md carries the §5.3 terminal-state re-read heading (#997)"

assert_contains "$issue_work_path997" \
  'https://github.com/mattsears18/shipyard/issues/997' \
  "issue-work.md §5.3 links to issue #997"

# The guard must be positioned before §5.5's decision-comment write.
issue_work_997_53_offset=$(grep -n '### 5.3 Terminal-state re-read' "$issue_work_path997" | head -1 | cut -d: -f1)
issue_work_997_55_offset=$(grep -n '### 5.5 Record decision context' "$issue_work_path997" | head -1 | cut -d: -f1)
if [[ -n "$issue_work_997_53_offset" && -n "$issue_work_997_55_offset" \
      && "$issue_work_997_53_offset" -lt "$issue_work_997_55_offset" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "issue-work.md §5.3 is positioned before §5.5's decision-comment write (#997)"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "issue-work.md §5.3 is positioned before §5.5's decision-comment write (#997)"
  fail=$((fail+1))
fi

# The re-read must cover state, labels, AND comments — all three trip signals.
assert_contains "$issue_work_path997" \
  '--json state,labels,comments' \
  "issue-work.md §5.3 re-reads state, labels, and comments (#997)"

# Trip condition 1: issue closed mid-dispatch.
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$issue_work_path997" \
  '**`state` flipped to `CLOSED`.**' \
  "issue-work.md §5.3 trips on the issue closing mid-dispatch (#997)"

# Trip condition 2: a new disposition-signal label appeared.
assert_contains "$issue_work_path997" \
  'disposition-signal labels' \
  "issue-work.md §5.3 trips on a new disposition-signal label (#997)"

# Trip condition 3: a new decision-resolved sentinel comment landed.
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$issue_work_path997" \
  'whose body starts with `<!-- shipyard-resolve-decisions -->` or `<!-- do-work-decision-resolved -->`' \
  "issue-work.md §5.3 trips on a new decision-resolved sentinel comment (#997)"

# On trip: convert the PR to draft, label it, and do NOT post the §5.5 comment.
assert_contains "$issue_work_path997" \
  'gh pr ready <pr-num> --repo <owner/repo> --undo' \
  "issue-work.md §5.3 converts the PR to draft on trip (#997)"

assert_contains "$issue_work_path997" \
  'Do **not** post the §5.5 decision comment' \
  "issue-work.md §5.3 explicitly skips the §5.5 decision-comment write on trip (#997)"

# The distinct blocked-stage return string.
assert_contains "$issue_work_path997" \
  'blocked #<N> at terminal-state-recheck: issue dispositioned mid-dispatch by a concurrent session' \
  "issue-work.md §5.3 returns the terminal-state-recheck blocked string (#997)"

# Step 2's comment classification treats the decision-resolved sentinel as
# authoritative over the dispatch prompt itself, not just over the body/other
# trusted-author comments.
assert_contains "$issue_work_path997" \
  'RECORDED HUMAN DECISION, and it outranks everything else in this list, including your own dispatch prompt' \
  "issue-work.md step 2 recognizes the decision-resolved sentinel as authoritative over the dispatch prompt (#997)"

# Don't-section bullets.
assert_contains "$issue_work_path997" \
  "Don't treat a \`<!-- shipyard-resolve-decisions -->\` / \`<!-- do-work-decision-resolved -->\` comment as just another trusted-author comment." \
  "issue-work.md Don't section warns against under-weighting the decision-resolved sentinel (#997)"

assert_contains "$issue_work_path997" \
  "Don't skip [§5.3](#53-terminal-state-re-read--guard-against-a-concurrent-session-dispositioning-the-issue-mid-dispatch-997)'s terminal-state re-read" \
  "issue-work.md Don't section warns against skipping §5.3 (#997)"

# steady-state.md documents the reason→class routing for this bail reason.
assert_contains "$steady_state_path" \
  'issue dispositioned mid-dispatch by a concurrent session' \
  "steady-state.md reason→class table documents the #997 bail reason"

assert_contains "$steady_state_path" \
  'https://github.com/mattsears18/shipyard/issues/997' \
  "steady-state.md reason→class table links to issue #997"

# ── Issue #986 — a dispatch-level, session-scoped file-ownership constraint
#    (not issue-scope, not an operator action) has no documented return shape
#    ────────────────────────────────────────────────────────────────────────
#
# A worker discovers mid-implementation that a dispatch prompt's Context
# block named a session-scoped file off-limits ("another worker owns it this
# session"), so part of the issue's acceptance criteria can't be shipped in
# this PR. The deferred remainder needs no human/operator judgment — it's
# ordinary follow-up code, blocked only by this session's transient
# constraint. §6.5's operator-residual shape doesn't fit (it always gates the
# residual behind a human/operator label); §6.6's verification shape doesn't
# fit either (no PR at all). Closed by adding a new §6.7 fragment
# (issue-work-deferred-slice-dispatch.md) that hands the residual to a fresh,
# UNGATED follow-up issue instead of a gate label, mirroring PR #1028's
# design choice not to add a new schema `outcome` value — this still rides
# the existing `shipped` outcome, documented only in prose.
issue_work_path986="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"
deferred_slice_path986="$repo_root/plugins/shipyard/agents/issue-worker/issue-work-deferred-slice-dispatch.md"

assert_file_exists "$deferred_slice_path986" \
  "issue-work-deferred-slice-dispatch.md fragment exists (#986)"

assert_contains "$issue_work_path986" \
  '### 6.7 Deferred-slice disposition: hand back an autonomously-workable residual to a new issue, keep the issue open' \
  "issue-work.md carries the §6.7 deferred-slice disposition heading (#986)"

assert_contains "$issue_work_path986" \
  'https://github.com/mattsears18/shipyard/issues/986' \
  "issue-work.md §6.7 links to issue #986"

# The trigger must be worker-recognized, not a Context paragraph scope-preflight sets.
assert_contains "$issue_work_path986" \
  'Nothing sets a Context paragraph for this ahead of time' \
  "issue-work.md §6.7 documents that nothing sets this Context paragraph proactively (#986)"

# §6.7 must point at the new fragment file.
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$issue_work_path986" \
  '[`issue-work-deferred-slice-dispatch.md`](./issue-work-deferred-slice-dispatch.md)' \
  "issue-work.md §6.7 references the deferred-slice-dispatch fragment (#986)"

# The fragment's three-condition trigger.
assert_contains "$deferred_slice_path986" \
  'The deferred remainder is **autonomously workable**' \
  "issue-work-deferred-slice-dispatch.md states the autonomously-workable trigger condition (#986)"

# The distinguishing property vs §6.5: no gate label, a new issue instead.
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$deferred_slice_path986" \
  'Do NOT apply any gate label to `#<N>` or to `#<FOLLOWUP>`' \
  "issue-work-deferred-slice-dispatch.md forbids gate labels on both issues (#986)"

# The follow-up issue must carry the shipyard stamp but no gate label.
assert_contains "$deferred_slice_path986" \
  'apply **no gate label**' \
  "issue-work-deferred-slice-dispatch.md forbids a gate label on the follow-up issue (#986)"

# The step-8 return shape.
assert_contains "$issue_work_path986" \
  'shipped #<N> partial via PR #<M> (deferred to #<F>' \
  "issue-work.md documents the deferred-to-#<F> partial return string (#986)"

# Design note: no new schema outcome value — reuses the existing shipped outcome.
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$issue_work_path986" \
  'no new schema `outcome` value was added for this case' \
  "issue-work.md step 8 documents the no-new-schema-value design decision (#986)"

# §5's exception — bare-URL reference for #<N>, no closing keyword, folded
# into the same paragraph as the #851 operator-slice exception.
assert_contains "$issue_work_path986" \
  'a worker-recognized deferred-slice split' \
  "issue-work.md §5 carries the non-closing exception for #986"

# §5.85 gains a fifth trigger shape.
assert_contains "$issue_work_path986" \
  'Five shapes trigger it' \
  "issue-work.md §5.85 documents five trigger shapes, including #986's (#986)"

assert_contains "$repo_root/plugins/shipyard/agents/issue-worker/issue-work-parent-epic-leak.md" \
  'Five shapes trigger it' \
  "issue-work-parent-epic-leak.md documents five trigger shapes, including #986's (#986)"

# Don't-section bullet.
assert_contains "$issue_work_path986" \
  "Don't apply \`agent-console\`/\`needs-human-review\` to a deferred-slice residual that needs no human" \
  "issue-work.md Don't section warns against over-gating a deferred-slice residual (#986)"

# ── Issue #1060 — a PR that is both DIRTY and red deadlocks fix-checks-only
#    and fix-rebase, each bailing to the other; the drain settles it as
#    "done" the whole time via rebase_blocked_prs membership
#    ────────────────────────────────────────────────────────────────────────
#
# fix-rebase.md's own hard-failure bail didn't distinguish DIRTY from
# non-DIRTY, and drain.md's #577-era D_dirty_red set routed a DIRTY-and-red
# PR to fix-checks — which, after #1015's DIRTY short-circuit, could only
# bail straight back with `dirty #<M>` without attempting anything. Neither
# mode could make progress. #1060 inverts both ends of the #577 rule in one
# PR: fix-rebase's bail is gated on mergeStateStatus != DIRTY, and drain's
# D_dirty_red becomes an informational subset of D_dirty (still routed to
# fix-rebase, never fix-checks). It also adds a deadlock-signature tracker
# (dirty_fix_checks_prs / deadlocked_prs) so a PR that DID return both
# `dirty` and `blocked rebase` this session is surfaced distinctly in the
# end-of-session summary rather than folded into an undifferentiated
# rebase_blocked_prs entry. See scripts/tests/drain-dirty-red-routing.test.sh
# for the dedicated D_dirty_red routing regression guard — the assertions
# here cover the surrounding session-state plumbing (steady-state.md's
# reconcile, drain.md's initial snapshot, cleanup-summary.md's summary line)
# that guard doesn't touch.
fix_rebase_path1060="$repo_root/plugins/shipyard/agents/issue-worker/fix-rebase.md"

assert_contains "$fix_rebase_path1060" \
  '#1060' \
  "fix-rebase.md references issue #1060"

# drain.md's initial snapshot must declare the two new deadlock-tracking
# structures alongside the existing three.
assert_contains "$drain_path" \
  'dirty_fix_checks_prs = {}' \
  "drain.md initializes dirty_fix_checks_prs (#1060)"

assert_contains "$drain_path" \
  'deadlocked_prs = {}' \
  "drain.md initializes deadlocked_prs (#1060)"

# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$drain_path" \
  'deadlocked_prs` is a **subset** of `rebase_blocked_prs`' \
  "drain.md documents deadlocked_prs as a subset of rebase_blocked_prs, not a disjoint gate (#1060)"

# steady-state.md's fix-checks reconcile must write dirty_fix_checks_prs on
# every path that produces a `dirty` disposition (explicit return, narrative
# synthesis, and the green→dirty trust-but-verify downgrade).
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$steady_state_path" \
  'Add `<M>` to `dirty_fix_checks_prs`' \
  "steady-state.md fix-checks reconcile writes dirty_fix_checks_prs (#1060)"

# steady-state.md's blocked-rebase reconcile must check dirty_fix_checks_prs
# membership and write deadlocked_prs when the deadlock signature fires.
assert_contains "$steady_state_path" \
  'Deadlock-signature check' \
  "steady-state.md blocked-rebase reconcile runs the deadlock-signature check (#1060)"

# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$steady_state_path" \
  'also add it to `deadlocked_prs`' \
  "steady-state.md blocked-rebase reconcile writes deadlocked_prs on the deadlock signature (#1060)"

# cleanup-summary.md must surface deadlocked_prs distinctly in the
# Drain-phase rebases summary line, not folded into the generic blocked count.
assert_contains "$cleanup_path" \
  'deadlocked' \
  "cleanup-summary.md Drain-phase rebases line names a distinct deadlocked bucket (#1060)"

# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$cleanup_path" \
  'not double-counted into the generic `blocked` bucket' \
  "cleanup-summary.md documents deadlocked PRs are not double-counted into the blocked bucket (#1060)"

# dont.md must carry the inverted routing rule, explicitly superseding #577.
assert_contains "$dont_path" \
  'supersedes' \
  "dont.md fix-rebase-vs-DIRTY+red rule cites #1060 superseding #577"

# RATIONALE.md must carry the full history of the #577 → #1060 inversion.
assert_contains "$rationale_path" \
  '#1060 supersedes #577' \
  "do-work-RATIONALE.md carries the #1060 supersedes #577 section"

# (P) Genuine within-budget-exhaustion bail classifies as soft, not the
# conservative refuse default (issue #1135, follow-up to #1115). Before this
# row existed, a worker that bailed `blocked: verification did not complete
# within budget` (the auto-backgrounded-verification case worker-preamble's
# SKILL.md already sanctioned) fell through the Reason → class table's own
# default to `refuse` → needs-human-review — the same human-decision bucket
# as a security refusal, for what is actually an environmental/transient
# condition much closer in spirit to `cannot reproduce` / `ambiguous`.
worker_preamble_skill_path="$repo_root/plugins/shipyard/skills/worker-preamble/SKILL.md"

assert_contains "$worker_preamble_skill_path" \
  'blocked: verification did not complete within budget' \
  "worker-preamble SKILL.md names the canonical within-budget-exhaustion bail phrase (#1135)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$steady_state_path" \
  'did not complete within budget` | soft | `blocked:agent-soft`' \
  "steady-state.md Reason → class table classifies the within-budget-exhaustion fragment as soft (#1135)"
assert_contains "$steady_state_path" \
  '*"did not complete within budget"*)' \
  "steady-state.md bail-handler case statement matches the within-budget-exhaustion fragment into the soft branch (#1135)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$rationale_path" \
  'Why a within-budget-exhaustion bail routes to `soft`' \
  "do-work-RATIONALE.md cross-references the within-budget-exhaustion soft-routing decision (#1135)"

# (Q) A sixth `defer_reason_class`, `time-gated`, lets scope pre-flight
# PRODUCE the `<!-- do-work-blocked-until: YYYY-MM-DD -->` body marker
# instead of a human hand-writing it (issue #1165, follow-up to #1161 which
# shipped only the client-side dispatch-filter half of the mechanism).
#
# A time-gated defer must NOT get needs-human-review or agent-console — the
# whole point of the class is that no human review is needed once the date
# elapses, matching #1161's own point that this class needs no human at all.

# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$setup_path" \
  '`time-gated` (' \
  "setup.md defer_reason_class enum documents the time-gated class (#1165)"
assert_contains "$setup_path" \
  'Time-gate: <YYYY-MM-DD> — <citation>' \
  "setup.md/06b-scope-carveouts.md per-class evidence shape table documents the Time-gate: shape (#1165)"
assert_contains "$setup_path" \
  'do-work-time-gated' \
  "setup.md recording-path marker table stamps <!-- do-work-time-gated --> as the comment dedupe sentinel (#1165)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$setup_path" \
  'write the self-clearing `<!-- do-work-blocked-until: YYYY-MM-DD -->` body marker instead of a label' \
  "setup.md step 4a writes the do-work-blocked-until body marker for time-gated defers, not a label (#1165)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$setup_path" \
  'No label is applied — not `needs-human-review`, not `agent-console`' \
  "setup.md step 4a explicitly applies no gate label for time-gated defers (#1165)"
assert_contains "$drain_path" \
  'time-gated' \
  "drain.md 5.b per-class re-validation and pre-drain audit banner cover the time-gated class (#1165)"
assert_contains "$do_work_path" \
  '"confirmed-non-shippable-as-single-PR" | "time-gated"' \
  "do-work.md canonical deferred_issues struct includes time-gated in the defer_reason_class enum (#1165)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$cleanup_path" \
  'confirmed-non-shippable-as-single-PR` / `time-gated`' \
  "cleanup-summary.md Deferred: line bracket enumeration includes time-gated (#1165)"
assert_contains "$dont_path" \
  'match none of the seven' \
  "dont.md dispatch-loop rule updated to the seven-value defer_reason_class enum (#1165, #1426)"

# (R) The step-4 do-work-blocked-until extraction must disambiguate a LIVE
# marker from the same literal string merely quoted in prose — e.g. a doc
# issue describing the mechanism itself (#1165, #1168). Without a position
# rule, "extract the first marker found anywhere in the body" would silently
# drop such an issue from the workable queue the moment it cites a
# well-formed future date as a worked example, with no diagnostic (#1168).
assert_contains "$setup_path" \
  "FIRST LINE is a" \
  "setup.md step 4 do-work-blocked-until filter requires the marker to be the body's first line, not merely present anywhere (#1168)"
assert_contains "$setup_path" \
  'Position discipline, line 1 only' \
  "setup.md step 4 documents the position-discipline disambiguation rule (#1168)"
assert_contains "$setup_path" \
  'a marker anywhere else (mid-paragraph, backticked, fenced, or quoted) is NOT live and MUST NOT gate dispatch' \
  "setup.md step 4 explicitly excludes mid-body / backticked / fenced / quoted occurrences from gating dispatch (#1168)"
assert_not_contains "$setup_path" \
  'Extract the first marker found in the body; a marker present but' \
  "setup.md step 4 no longer uses the ambiguous 'first marker found anywhere in the body' extraction (#1168, superseded)"

# (S) The step-E invariant line has no operator_queue token, so a silently-
# skipped operator layer is undetectable (issue #1193). An orchestrator that
# never loads operate.md at all — never fires the preflight, never enqueues,
# never drains — previously emitted a well-formed invariant line every turn
# with no signal distinguishing "operator queue empty because it was drained"
# from "operator layer was silently skipped for the entire session." Fix:
# add `operator_q=<N>` (current operator_queue length) and
# `operator=<active|skipped|unreachable>` (whether the preflight actually
# ran and found a backend) to both invariant-line formats, mirroring the
# unfiltered_open_count precedent from #332.
assert_contains "$steady_state_path" \
  'issues/1193' \
  "steady-state.md cites issue #1193 as the source of the operator invariant-line tokens"
assert_contains "$steady_state_path" \
  'operator_q=<oq> · operator=<active|skipped|unreachable> · peers=<p> · disk_free_mb=<N|"unknown"> · ci_backpressure=<n/a|skipped-hosted|checked|held> · paused_env=<none|active> · version_cursor=<X.Y.Z|"unset"|n/a> · version_release=<n/a|none|released|skipped> · spec_drift=<N|"unknown"|n/a> · dispatched_this_turn=<k>' \
  "steady-state.md step E invariant line (steady-state format) includes the operator_q / operator tokens (#1193)"
assert_contains "$steady_state_path" \
  'operator_q=<oq> · operator=<active|skipped|unreachable> · peers=<p> · disk_free_mb=<N|"unknown"> · ci_backpressure=<n/a|skipped-hosted|checked|held> · paused_env=<none|active> · version_cursor=<X.Y.Z|"unset"|n/a> · version_release=<n/a|none|released|skipped> · spec_drift=<N|"unknown"|n/a> · dispatched_this_turn=0' \
  "steady-state.md step E invariant line (idle-proof format) includes the operator_q / operator tokens (#1193)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$steady_state_path" \
  'are the per-turn evidence tokens for the [operator layer]' \
  "steady-state.md documents what operator_q / operator mean (#1193)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$steady_state_path" \
  '`skipped`' \
  "steady-state.md documents the operator=skipped value for --no-operate / --hands-off (#1193)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$steady_state_path" \
  '`unreachable`' \
  "steady-state.md documents the operator=unreachable value for the no-backend-reachable degradation (#1193)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$steady_state_path" \
  'A missing `operator=` token entirely is the exact contract violation' \
  "steady-state.md treats a missing operator= token as a contract violation on par with a missing state= or tokens_attributed= token (#1193)"
assert_contains "$operate_path" \
  'operator=unreachable' \
  "operate.md's Degradation section cross-references the operator=unreachable invariant-line value (#1193)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle; the embedded
# '"'"' sequence splices a literal apostrophe into the single-quoted needle.
assert_contains "$operate_path" \
  'source of the invariant line'"'"'s `operator=` token' \
  "operate.md documents that the preflight's outcome feeds the invariant-line operator= token (#1193)"

# (T) The mid-session re-fetch call sites (steady-state step C, drain
# termination-assertion step 4) already restated the client-side filter in
# prose (#332), but a real session still hand-rolled an ad-hoc
# `select((.assignees|length)==0)` query outside both documented procedures
# and silently dropped every self-assigned issue — reporting a 10-issue
# backlog as empty (issue #1194). Two-part fix: (a) a `me_assigned_open=<N>`
# invariant-line token narrows the existing unfiltered_open_count smell to
# the exact bucket a wrong assignee filter erases; (b) a third mandatory
# self-check (token-presence) turns the existing "missing token = contract
# violation" prose into an actual pre-return check, mirroring the
# under-dispatch / over-defer self-checks. A dont.md rule and both re-fetch
# sites also gain an explicit "never hand-roll a shorthand" caution.
assert_contains "$steady_state_path" \
  'issues/1194' \
  "steady-state.md cites issue #1194 as the source of the me_assigned_open invariant-line token"
assert_contains "$steady_state_path" \
  'unfiltered_open_count=<u> · me_assigned_open=<m> · operator_q=<oq> · operator=<active|skipped|unreachable> · peers=<p> · disk_free_mb=<N|"unknown"> · ci_backpressure=<n/a|skipped-hosted|checked|held> · paused_env=<none|active> · version_cursor=<X.Y.Z|"unset"|n/a> · version_release=<n/a|none|released|skipped> · spec_drift=<N|"unknown"|n/a> · dispatched_this_turn=<k>' \
  "steady-state.md step E invariant line (steady-state format) includes the me_assigned_open token (#1194)"
assert_contains "$steady_state_path" \
  'unfiltered_open_count=<u> · me_assigned_open=<m> · operator_q=<oq> · operator=<active|skipped|unreachable> · peers=<p> · disk_free_mb=<N|"unknown"> · ci_backpressure=<n/a|skipped-hosted|checked|held> · paused_env=<none|active> · version_cursor=<X.Y.Z|"unset"|n/a> · version_release=<n/a|none|released|skipped> · spec_drift=<N|"unknown"|n/a> · dispatched_this_turn=0' \
  "steady-state.md step E invariant line (idle-proof format) includes the me_assigned_open token (#1194)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$steady_state_path" \
  'is the per-turn evidence flag naming the specific bucket a wrong client-side filter is most likely to erase' \
  "steady-state.md documents what me_assigned_open means (#1194)"
assert_contains "$steady_state_path" \
  'Divergence smell, self-assign class' \
  "steady-state.md documents the me_assigned_open divergence-smell rule (#1194)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$steady_state_path" \
  'A missing `me_assigned_open=` token entirely is a contract violation' \
  "steady-state.md treats a missing me_assigned_open= token as a contract violation (#1194)"
assert_contains "$steady_state_path" \
  'Run ALL THREE self-checks' \
  "steady-state.md's self-check section now runs three self-checks, not two (#1194)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$steady_state_path" \
  '3. **Token-presence check' \
  "steady-state.md adds the token-presence self-check as the enforcement companion to the per-token 'missing = violation' prose (#1194)"
assert_contains "$steady_state_path" \
  'never re-derive it here or hand-roll a shorthand substitute' \
  "steady-state.md step C's lightweight backlog re-check warns against a hand-rolled shorthand filter (#1194)"
# shellcheck disable=SC2016
# Dollar-sign variable refs here are literal characters inside a fenced bash
# code block quoted in the markdown, not something this test script expands.
# Issue #1479 narrowed this needle: the `--me` VALUE is now a substituted
# literal, not `"$ME_LOGIN"` (a bare whole-word expansion the
# worktree-isolation guard refuses — do-work/dont.md's #1474 corrected rule).
# What #1246 actually guards is that the executable `summary` subcommand is
# invoked at all, which the shortened needle still pins; the companion
# assertion below pins the #1479 shape so the refused spelling can't return.
assert_contains "$steady_state_path" \
  '"$CLAUDE_PLUGIN_ROOT/scripts/backlog-filter.sh" summary --me ' \
  "steady-state.md step C stamps the invariant-line tokens via the executable backlog-filter.sh summary subcommand, not prose alone (#1246)"
# shellcheck disable=SC2016
assert_not_contains "$steady_state_path" \
  'summary --me "$ME_LOGIN"' \
  "steady-state.md step C does not reintroduce the refused bare --me \"\$ME_LOGIN\" expansion (#1479)"
assert_contains "$steady_state_path" \
  '< .shipyard-fetched-issues.json' \
  "steady-state.md step C feeds the summary payload by file redirection, not a herestring (#1479)"
assert_contains "$steady_state_path" \
  'issues/1246' \
  "steady-state.md step C cites issue #1246 as the source of the mechanical stamping code"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$drain_path" \
  'narrows that same wide-fetch payload to the count of issues assigned to the gh-authenticated user' \
  "drain.md termination-assertion step 4 stamps me_assigned_open (#1194)"
# shellcheck disable=SC2016
# Dollar-sign variable refs here are literal characters inside a fenced bash
# code block quoted in the markdown, not something this test script expands.
# Needle narrowed by #1479 for the same reason as the steady-state.md pair
# above — see that comment.
assert_contains "$drain_path" \
  '"$CLAUDE_PLUGIN_ROOT/scripts/backlog-filter.sh" summary --me ' \
  "drain.md termination-assertion step 4 stamps the invariant-line tokens via the executable backlog-filter.sh summary subcommand, not prose alone (#1246)"
# shellcheck disable=SC2016
assert_not_contains "$drain_path" \
  'summary --me "$ME_LOGIN"' \
  "drain.md termination-assertion step 4 does not reintroduce the refused bare --me \"\$ME_LOGIN\" expansion (#1479)"
assert_contains "$drain_path" \
  '< .shipyard-fetched-issues.json' \
  "drain.md termination-assertion step 4 feeds the summary payload by file redirection, not a herestring (#1479)"
assert_contains "$drain_path" \
  'issues/1246' \
  "drain.md termination-assertion step 4 cites issue #1246 as the source of the mechanical stamping code"
assert_contains "$drain_path" \
  'recurred client-side in a mid-drain ad-hoc query as recently as' \
  "drain.md's never-re-derive caution cross-references the #1194 ad-hoc-query regression"
assert_contains "$dont_path" \
  "Don't hand-roll an ad-hoc \`gh issue list\` query mid-session" \
  "dont.md prohibits ad-hoc backlog queries that bypass the canonical wide-fetch + client-side filter (#1194)"

# (U) A long session accumulates one agent-* worktree per dispatch; the
# per-completion reap points (A.0.5/A.1/step B/dispatch-rules.md 2d) are
# each individually correct, but a real session still accumulated ~20
# worktrees over ~20 dispatches and drove a shared host to ENOSPC,
# taking its self-hosted CI runner pool down with it (issue #1261). Fix:
# a mid-session disk-space backpressure check at step C, before every
# dispatch decision, that runs a bounded reap-stale sweep whenever free
# space drops below worktree_reap.disk_free_floor_mb — reusing reap-stale
# unmodified so the #832 in-flight guard and the #836 never-infer-from-
# branch-name guard are enforced by construction, never re-derived here.
assert_contains "$steady_state_path" \
  'issues/1261' \
  "steady-state.md cites issue #1261 as the source of the disk-space backpressure check"
assert_contains "$steady_state_path" \
  'Disk-space backpressure check' \
  "steady-state.md step C documents the disk-space backpressure check"
# shellcheck disable=SC2016
# Dollar-sign variable refs here are literal characters inside a fenced
# bash code block quoted in the markdown, not something this test script
# expands.
assert_contains "$steady_state_path" \
  '"$CLAUDE_PLUGIN_ROOT/scripts/worktree-reap.sh" disk-check' \
  "steady-state.md step C probes free space via the worktree-reap.sh disk-check subcommand"
assert_contains "$steady_state_path" \
  'worktree_reap.disk_free_floor_mb' \
  "steady-state.md step C reads the disk_free_floor_mb config knob"
assert_contains "$steady_state_path" \
  'must never weaken' \
  "steady-state.md's disk-space check explicitly disclaims weakening #832/#836 to achieve its goal"
assert_contains "$steady_state_path" \
  'never blocks or delays dispatch itself' \
  "steady-state.md's disk-space check is advisory-and-reclaim, never a dispatch-blocking hold (#1261)"
assert_contains "$steady_state_path" \
  'disk_free_mb=<N|"unknown">' \
  "steady-state.md step E invariant line documents the disk_free_mb token shape (#1261)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$steady_state_path" \
  'A missing `disk_free_mb=` token entirely is a contract violation' \
  "steady-state.md treats a missing disk_free_mb= token as a contract violation (#1261)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$steady_state_path" \
  '`operator_q=`, `operator=`, `peers=`, `disk_free_mb=`, `ci_backpressure=`' \
  "steady-state.md's token-presence self-check enumerates disk_free_mb= among the mandatory tokens (#1261)"

# (W) The step-C queue-depth backpressure hold (#1156) and the CI-cheap bias
# (#1157) are prose the orchestrating model is expected to execute every
# turn, with nothing distinguishing "no self-hosted pool, correct no-op"
# from "this session is silently skipping a load-bearing check" — a real
# 14-hour session against a saturated 4-runner self-hosted pool never ran
# the hold (11 PRs opened, 1 merged) though the recorded queue-depth samples
# would have tripped it on every one (issue #1399). Fix: a
# `ci_backpressure=<n/a|skipped-hosted|checked|held>` invariant-line token,
# set inside the same backpressure-check block, mirroring the
# tokens_attributed precedent for step A.0.
assert_contains "$steady_state_path" \
  'issues/1399' \
  "steady-state.md cites issue #1399 as the source of the ci_backpressure invariant-line token"
assert_contains "$steady_state_path" \
  'ci_backpressure="held"' \
  "steady-state.md's backpressure-check block sets ci_backpressure=held on a hold verdict (#1399)"
assert_contains "$steady_state_path" \
  'ci_backpressure="checked"' \
  "steady-state.md's backpressure-check block sets ci_backpressure=checked on a dispatch verdict (#1399)"
assert_contains "$steady_state_path" \
  'ci_backpressure="skipped-hosted"' \
  "steady-state.md's backpressure-check block sets ci_backpressure=skipped-hosted when the self-hosted+pool_total guard is false (#1399)"
assert_contains "$steady_state_path" \
  'ci_backpressure=<n/a|skipped-hosted|checked|held>' \
  "steady-state.md step E invariant line documents the ci_backpressure token shape (#1399)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$invariant_line_path" \
  'A missing `ci_backpressure=` token entirely is a contract violation' \
  "invariant-line.md treats a missing ci_backpressure= token as a contract violation (#1399)"

# (V) Orchestrator-side prohibition on instructing a worker to route around
# its own worker-internal classifier denial (issue #1278). A live session
# showed the existing #718 rule (orchestrator's OWN dispatch call denied)
# and #341's worker-side rule (worker's own tool call denied) left a gap:
# nothing stopped the orchestrator from RESUMING a worker — after that
# worker correctly returned `blocked: classifier denied ...` — with an
# instruction to try an effect-equivalent substitute. The repro: a denied
# `git checkout -B` produced a correct `blocked` return; the orchestrator
# resumed via SendMessage with a refspec-push substitute; the push
# succeeded; a second denial (force-push) followed; the worker then
# unpromptedly substituted a merge commit against an explicit "stop at
# two" instruction; the harness's own [Auto Mode Bypass] flag caught the
# return, but auto-merge had already armed and PR #1275 merged to `main`
# first. The fix extends `dont.md`'s #718 bullet family with a new
# orchestrator-side prohibition (naming the tempting substitutions
# explicitly), a companion bullet recording the decided-against auto-merge-
# suppression judgment call, and a matching RATIONALE section anchored to
# the effects-not-tool-names principle #718 already established.
#
# Nine assertions pin the post-#1278 contract:
assert_contains "$dont_path" \
  "Don't instruct a worker to route around its own worker-internal classifier denial" \
  "dont.md carries the new worker-internal classifier-denial prohibition (#1278)"
assert_contains "$dont_path" \
  "resuming the same live agent via \`SendMessage\`" \
  "dont.md's new bullet treats a SendMessage resume as equivalent to a re-dispatch (#1278)"
assert_contains "$dont_path" \
  "a refspec push (\`git push origin HEAD:refs/heads/<branch>\`) in place of a denied local branch-create" \
  "dont.md's new bullet names the refspec-push substitution explicitly (#1278)"
assert_contains "$dont_path" \
  "a merge commit in place of a denied force-push" \
  "dont.md's new bullet names the merge-commit substitution explicitly (#1278)"
assert_contains "$dont_path" \
  "\`git update-ref\`, \`git branch\`, or \`git format-patch\` standing in for either" \
  "dont.md's new bullet names the update-ref/branch/format-patch substitutions explicitly (#1278)"
assert_contains "$dont_path" \
  "does not get a separate auto-merge-suppression mechanism" \
  "dont.md records the decided-against auto-merge-suppression judgment call (#1278)"
assert_count_at_least_across "issues/1278" 2 \
  "dont.md cites issue #1278 at least twice (the new bullet + the auto-merge-suppression bullet)" \
  "$dont_path"
assert_contains "$rationale_path" \
  "### Don't instruct a worker to route around its own classifier denial (issue #1278)" \
  "RATIONALE.md carries the #1278 section heading"
assert_contains "$rationale_path" \
  "The orchestrator applied that principle to its own dispatches and failed to apply it to its instructions to a worker" \
  "RATIONALE.md names the precise shape of the #1278 gap"
assert_contains "$rationale_path" \
  "Auto-merge suppression — considered and decided against, as a deliberate proportionality call, not an oversight" \
  "RATIONALE.md records the auto-merge-suppression reasoning, not just the decision (#1278)"
assert_contains "$rationale_path" \
  "did the classifier's stated reason name the *operation* as unauthorized, or did it name the *call shape* as unverifiable" \
  "RATIONALE.md draws the testable boundary against the legitimate compound-command-decomposition case (#1278)"

# (Q) A worker return carrying two mutually-exclusive terminal disposition
# lines is reconciled by whichever the parser matches first, unless the
# contract explicitly forbids multiple terminal lines and the reconcile
# scans for all of them before trusting any one (issue #1335).
#
# Repro: session do-work-20260813T125705Z-71435, mode: fix-checks-only
# against PR #1328. The worker's raw return was:
#
#   green #1328 @0ac30ab (rollup verified 2026-08-13T10:15:00Z: 0 passed,
#   0 pending, 0 failing)
#
#   Actually, wait - the PR is DIRTY, so I cannot return green. Let me
#   return the correct DIRTY disposition:
#
#   dirty #1328: PR conflicts with main; no merge ref, so no checks will run
#
# Ground truth at reconcile time was DIRTY — the trailing `dirty` line was
# correct and the `green` line was fabricated. A first-match parser would
# reconcile the fabricated `green` and never see the correction. The
# fabricated line happened to trip both existing #1205 tells (an empty
# 0/0/0 rollup, and a cited verification timestamp of 10:15:00Z against a
# dispatch that started at ~13:47Z — a *past*-dated citation, the mirror
# image of #1205's future-dated check) — but a self-correcting return whose
# discarded first line carried only *plausible* evidence would have slipped
# through untouched.
#
# Four assertions pin the fix:
#   1. fix-checks-only.md's return contract explicitly requires exactly one
#      terminal disposition line per return.
#   2. worker-preamble's shared return-contract prose states the same rule
#      generically, across every mode's own terminal-prefix vocabulary.
#   3. steady-state.md's A.1 fabrication pre-check gained a third,
#      multi-terminal-line trigger (reusing the existing #1205 live-verify
#      branch rather than inventing a parallel one), and its timestamp
#      check now fires in both directions instead of future-only.
#   4. dont.md and do-work-RATIONALE.md were updated in lockstep so the
#      pinned "don't" list and the historical narrative both describe the
#      four-check (not two-check) pre-check.
fix_checks_path1335="$repo_root/plugins/shipyard/agents/issue-worker/fix-checks-only.md"
worker_preamble_path1335="$repo_root/plugins/shipyard/skills/worker-preamble/SKILL.md"

assert_contains "$fix_checks_path1335" \
  'Your entire return must carry exactly one terminal disposition line' \
  "fix-checks-only.md return contract requires exactly one terminal disposition line (#1335)"
assert_contains "$fix_checks_path1335" \
  'issues/1335' \
  "fix-checks-only.md cites issue #1335"
assert_contains "$worker_preamble_path1335" \
  'Exactly one terminal disposition line per return' \
  "worker-preamble SKILL.md states the exactly-one-terminal-line rule generically across modes (#1335)"
assert_contains "$worker_preamble_path1335" \
  'issues/1335' \
  "worker-preamble SKILL.md cites issue #1335"
assert_contains "$steady_state_path" \
  'Timestamp check — both directions' \
  "steady-state.md's fabrication pre-check extends the timestamp tell to both directions (#1335)"
assert_contains "$steady_state_path" \
  'Past bound (issue' \
  "steady-state.md documents the past-dated-citation bound, the mirror of the pre-existing future bound (#1335)"
assert_contains "$steady_state_path" \
  '.in_flight[<slot-id>].started_at' \
  "steady-state.md's past-bound check anchors against the dispatch's own recorded start time (#1335)"
assert_contains "$steady_state_path" \
  'Multi-terminal-line check (issue' \
  "steady-state.md's fabrication pre-check gained a multi-terminal-line trigger (#1335)"
assert_contains "$steady_state_path" \
  '<future-timestamp|past-timestamp|self-contradiction|multi-terminal-line>' \
  "steady-state.md's fabrication-tell advisory log names all four trigger tags (#1335)"
assert_contains "$steady_state_path" \
  'do not resolve a multiplicity trip by picking the first or the last matching line' \
  "steady-state.md explicitly refuses both first-match and last-match guessing on a multi-terminal-line return (#1335)"
assert_contains "$dont_path" \
  'extended by [#1335]' \
  "dont.md's fabrication-citation bullet is updated in lockstep with the steady-state.md pre-check (#1335)"
assert_contains "$dont_path" \
  'Never resolve a multi-terminal-line return by picking the first match or the last match' \
  "dont.md pins the multi-terminal-line non-guessing rule (#1335)"
assert_contains "$rationale_path" \
  'Two residual gaps the original #1205 pre-check left open, both closed by' \
  "RATIONALE.md records the #1335 extension of the #1205 fabrication pre-check"
assert_contains "$rationale_path" \
  'issues/1335' \
  "RATIONALE.md cites issue #1335"

# (X) version_cursor self-heal + observability (issue #1417). The cursor
# advances on what next-available-version.sh compute COMPUTED, not on what
# a worker actually CLAIMED — a worker legitimately taking a different
# bump level than the orchestrator inferred (#671's "the level is yours to
# raise") leaves a phantom claimed slot in the cursor forever, which
# compounds with every later compute call in the session. Fix: a new
# `reseed-if-idle` subcommand, called once per dispatch-decision round
# (never inside a batch's own sequential per-slot loop, which would
# reintroduce #437's collision), discards the persisted cursor whenever
# session_prs has no OPEN member — plus a `version_cursor=` invariant-line
# token so residual drift is visible without eyeballing a version number.
pool_fill_path1417="$repo_root/plugins/shipyard/commands/do-work/setup/07-pool-fill.md"
orchestrator_state_reference_path1417="$repo_root/plugins/shipyard/commands/do-work/orchestrator-state-reference.md"

# next-available-version.sh: the new subcommand exists and compute() is
# explicitly documented as unchanged.
assert_contains "$steady_state_path" \
  'reseed-if-idle)' \
  "next-available-version.sh implements the reseed-if-idle subcommand (#1417)"
assert_contains "$steady_state_path" \
  'reseed=<reset|skipped-open-pr-found|noop-no-cursor>' \
  "next-available-version.sh documents reseed-if-idle's three output states (#1417)"
assert_contains "$steady_state_path" \
  "compute\` itself is UNCHANGED by issue #1417" \
  "next-available-version.sh documents compute() as unchanged by the #1417 fix"

# dispatch-rules.md: reseed-if-idle is called once per round, before compute.
assert_contains "$dispatch_rules_path" \
  'reseed-if-idle' \
  "dispatch-rules.md's next-available-version section calls reseed-if-idle (#1417)"
assert_contains "$dispatch_rules_path" \
  'Never call it from inside a batch loop' \
  "dispatch-rules.md warns against calling reseed-if-idle inside a batch loop (#1417)"
assert_contains "$dispatch_rules_path" \
  'issues/1417' \
  "dispatch-rules.md cites issue #1417"

# setup/07-pool-fill.md: the batch loop calls reseed-if-idle ONCE, before
# the loop, never per-slot.
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$pool_fill_path1417" \
  'Run `reseed-if-idle` ONCE, before this batch loop starts' \
  "07-pool-fill.md documents reseed-if-idle as a once-per-round call, not per-slot (#1417)"
assert_contains "$pool_fill_path1417" \
  'issues/1417' \
  "07-pool-fill.md cites issue #1417"

# invariant-line.md + steady-state.md: the version_cursor token.
assert_contains "$invariant_line_path" \
  'version_cursor=<X.Y.Z|"unset"|n/a>' \
  "invariant-line.md documents the version_cursor token shape (#1417)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$invariant_line_path" \
  'A missing `version_cursor=` token entirely is a contract violation' \
  "invariant-line.md treats a missing version_cursor= token as a contract violation (#1417)"
assert_contains "$steady_state_path" \
  'version_cursor=<X.Y.Z|"unset"|n/a> · version_release=<n/a|none|released|skipped> · spec_drift=<N|"unknown"|n/a> · dispatched_this_turn=<k>' \
  "steady-state.md step E invariant line documents the version_cursor token in the dispatch format (#1417)"
assert_contains "$steady_state_path" \
  'version_cursor=<X.Y.Z|"unset"|n/a> · version_release=<n/a|none|released|skipped> · spec_drift=<N|"unknown"|n/a> · dispatched_this_turn=0' \
  "steady-state.md step E invariant line documents the version_cursor token in the idle-proof format (#1417)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$steady_state_path" \
  '`paused_env=`, `version_cursor=`' \
  "steady-state.md's token-presence self-check enumerates version_cursor= among the mandatory tokens (#1417)"

# orchestrator-state-reference.md: the version_cursor struct entry documents
# the self-heal and the invariant-line surfacing.
assert_contains "$orchestrator_state_reference_path1417" \
  'Self-healed mid-session, not just at session boundaries' \
  "orchestrator-state-reference.md's version_cursor entry documents the mid-session self-heal (#1417)"
assert_contains "$orchestrator_state_reference_path1417" \
  'Surfaced on the invariant line' \
  "orchestrator-state-reference.md's version_cursor entry documents the invariant-line token (#1417)"

# RATIONALE.md: the design writeup exists and names the batch-monotonicity
# hazard a naive session_prs-only self-heal would reintroduce.
assert_contains "$rationale_path" \
  'version_cursor` self-heal' \
  "RATIONALE.md carries the #1417 version_cursor self-heal writeup"
assert_contains "$rationale_path" \
  'issues/1417' \
  "RATIONALE.md cites issue #1417"
assert_contains "$rationale_path" \
  'reintroducing the exact N−1-PRs-go-DIRTY collision #437 exists to prevent' \
  "RATIONALE.md explains why a naive session_prs-gated compute() fold-in would break batch monotonicity (#1417)"

# (S) A seventh `defer_reason_class`, `blocked-by-in-flight-pr`, distinguishes
# an in-flight-PR file/content collision from a genuine issue-level
# dependency, and defer_reason_class validation warns rather than silently
# absorbing an unrecognized value (issue #1426).
#
# Repro: /shipyard:do-work --concurrency 4 against mattsears18/lightwork
# returned 0 READY / 5 DEFERRED from a five-issue scope batch; three of the
# five were file-collision-only, and one scope agent invented an unvalidated
# "file-collision" defer_reason_class that passed silently. A second
# collision (lightwork#4101) got bundled into confirmed-blocker-still-open
# alongside a genuine issue-level blocker, making the two indistinguishable
# in the deferred_issues ledger.
#
# This slice ships the class + its validation + its own summary line
# (points 1, 3, 4 of #1426's acceptance criteria). Point 2 — automatically
# re-queuing the issue once every blocking_prs entry merges, reusing the
# cached scope instead of paying for a second scope-agent dispatch — is
# deliberately NOT wired here; see the tracking follow-up filed alongside
# this PR.

assert_contains "$setup_path" \
  'issues/1426' \
  "setup.md cites issue #1426 as the source of the blocked-by-in-flight-pr class"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$setup_path" \
  '`blocked-by-in-flight-pr` (' \
  "setup.md defer_reason_class enum documents the blocked-by-in-flight-pr class (#1426)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$setup_path" \
  'blocking_prs: [N, ...]' \
  "setup.md documents the required blocking_prs companion field (#1426)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$setup_path" \
  'MUST start with `Blocked by in-flight PR:`' \
  "setup.md documents the Blocked by in-flight PR: evidence_pointer shape (#1426)"
assert_contains "$setup_path" \
  'when the collision is semantic rather than merely textual' \
  "setup.md carve-out captures the #4148 semantic-collision case, not just a textual file-path citation (#1426)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$setup_path" \
  'Not the right class for a PR that merely holds the files this issue needs to edit' \
  "setup.md cross-references confirmed-blocker-still-open away from pure PR/file collisions (#1426)"

# defer_reason_class validation must warn on an unrecognized value rather than
# silently absorbing it (point 3 of #1426).
assert_contains "$setup_path" \
  'WARNING:' \
  "setup.md recording-path normalization explicitly warns on an unrecognized defer_reason_class value (#1426)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$setup_path" \
  'This check runs BEFORE the `confirmed-blocker-still-open` check below' \
  "setup.md orders the blocked-by-in-flight-pr shape check ahead of the bare #<digits> confirmed-blocker-still-open check, so a PR-collision pointer can't silently mis-normalize (#1426)"
assert_contains "$setup_path" \
  'the seven valid tokens' \
  "setup.md's normalized-token enumeration has grown to seven (#1426)"

# The gate-label logic must apply NO label to this class — it's a
# self-clearing wait on a merge, not a human decision.
assert_contains "$setup_path" \
  'blocked-by-in-flight-pr)  GATE_LABEL="" ;;' \
  "setup.md gate-label case statement applies no label to blocked-by-in-flight-pr (#1426)"

# drain.md must re-validate blocking_prs entries the same way it re-validates
# confirmed-blocker-still-open's #N references.
assert_contains "$drain_path" \
  'blocked-by-in-flight-pr' \
  "drain.md 5.b per-class re-validation and pre-drain audit banner cover the blocked-by-in-flight-pr class (#1426)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$drain_path" \
  'for every PR in `blocking_prs`; all must still be `OPEN`' \
  "drain.md 5.b re-runs gh pr view against every blocking_prs entry (#1426)"

# do-work.md canonical struct must carry the new class + companion field.
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$do_work_path" \
  '"time-gated" | "blocked-by-in-flight-pr"' \
  "do-work.md canonical deferred_issues struct includes blocked-by-in-flight-pr in the defer_reason_class enum (#1426)"
assert_contains "$do_work_path" \
  'blocking_prs?: [N, ...]' \
  "do-work.md canonical deferred_issues struct includes the blocking_prs companion field (#1426)"

# cleanup-summary.md must report blocked-by-in-flight-pr entries on their own
# line, excluded from the plain Deferred: count (point 4 of #1426).
assert_contains "$cleanup_path" \
  'Queued behind in-flight PRs (#1426):' \
  "cleanup-summary.md renders a dedicated Queued behind in-flight PRs: template line (#1426)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$cleanup_path" \
  'after excluding every `blocked-by-in-flight-pr` entry' \
  "cleanup-summary.md's Deferred: line explicitly excludes blocked-by-in-flight-pr entries (#1426)"
assert_contains "$cleanup_path" \
  'not folded into it' \
  "cleanup-summary.md explains why the queued-behind-PRs count is reported separately from Deferred: (#1426)"

# (T) blocked-by-in-flight-pr becomes a REQUEUE signal, not just a diagnosis
# (issue #1429, point 2 of #1426's own acceptance criteria). A self-clearing
# `do-work-blocked-by-prs` body marker (step 4e) plus backlog-filter.sh
# classify's --pr-collision-verdicts map (populated by eval-pr-collision, an
# unconditional precompute wired into classify-backlog.sh) drop the issue
# from the workable set while any blocking_prs entry is OPEN and re-admit it
# to a FRESH scope-agent pass the instant every entry resolves -- without
# waiting for pre-drain re-validation or a fresh session. Cache-reuse (skip
# the fresh scope-agent dispatch entirely) plus the semantic premise
# re-validation that reuse would require is deliberately NOT shipped here --
# tracked as its own follow-up (#1448) per #1429's own instruction to ship a
# coherent slice rather than half-wire the unsafe optimization.

assert_contains "$setup_path" \
  'do-work-blocked-by-prs: N,M -->' \
  "setup.md documents the do-work-blocked-by-prs self-clearing marker for blocked-by-in-flight-pr (#1429)"
assert_contains "$setup_path" \
  'issues/1429' \
  "setup.md cites issue #1429 as the source of the pr-collision requeue marker"
assert_contains "$setup_path" \
  'issues/1448' \
  "setup.md cites the #1448 follow-up for the still-unwired cache-reuse + semantic re-validation optimization"

# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$setup_path" \
  '4e. **`blocked-by-in-flight-pr` only' \
  "06c-scope-handling-ui.md's step 4e writes the self-clearing marker for blocked-by-in-flight-pr, mirroring step 4a's time-gated marker (#1429)"
assert_contains "$setup_path" \
  'never appended or inserted elsewhere' \
  "step 4e enforces the same line-1-only position discipline as do-work-blocked-until, not do-work-recheck's any-line convention (#1429)"

# The gate-label case statement must still apply NO label to this class --
# the marker gates dispatch eligibility now, not a label.
assert_contains "$setup_path" \
  'blocked-by-in-flight-pr)  GATE_LABEL="" ;;' \
  "setup.md gate-label case statement still applies no label to blocked-by-in-flight-pr after #1429"

# do-work.md canonical deferred_issues prose must document the marker and
# the still-open cache-reuse follow-up.
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$do_work_path" \
  '`<!-- do-work-blocked-by-prs: N,M -->` body marker' \
  "do-work.md deferred_issues prose documents the blocked-by-in-flight-pr self-clearing marker (#1429)"
assert_contains "$do_work_path" \
  'CAN become dispatch-eligible without waiting for pre-drain re-validation or a fresh session' \
  "do-work.md documents that the marker changes dispatch eligibility on its own, unlike the pre-#1429 behavior"
assert_contains "$do_work_path" \
  'issues/1448' \
  "do-work.md cross-references the #1448 cache-reuse follow-up"

# drain.md 5.b must now describe itself as a backstop, not the primary
# trigger, now that the marker gates at every ordinary backlog fetch.
assert_contains "$drain_path" \
  'This 5.b check is now a backstop, not the primary trigger' \
  "drain.md 5.b documents that the self-clearing marker (not pre-drain re-validation) is now the primary blocked-by-in-flight-pr requeue trigger (#1429)"
assert_contains "$drain_path" \
  'PR-COLLISION-gated' \
  "drain.md's mechanical-filter enumeration (step 4/termination-assertion) includes the new PR-collision gate reason (#1429)"

# (U) blocked-by-in-flight-pr cache-reuse + semantic premise re-validation
# (issue #1448, the deliberately-deferred second half of #1429). A
# blocked-by-in-flight-pr deferred return can now optionally carry a cached
# would_be_ready_scope; re-admission reuses it ONLY after a mandatory
# semantic-premise re-validation against the merged PR's actual diff — never
# on merge state alone, closing the exact stale-premise bug #1426 diagnosed.

# AC1: the deferred-shape scope-agent return shape carries the optional
# cached field, validated the same way a ready return's files/phase_1_scope
# are.
assert_contains "$setup_path" \
  'would_be_ready_scope' \
  "setup.md's Deferred shape docs carry the optional would_be_ready_scope field (#1448)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$setup_path" \
  'Validated the same way a ready return'"'"'s `files`/`phase_1_scope` are' \
  "setup.md documents would_be_ready_scope is validated identically to a plain ready return's files/phase_1_scope (#1448)"

# The new deep-link fragment exists and carries the full mechanism.
pr_collision_fragment_path="$setup_dir/06f-pr-collision-cache-reuse.md"
if [[ -f "$pr_collision_fragment_path" ]]; then
  pass=$((pass+1))
  printf '%sPASS%s  06f-pr-collision-cache-reuse.md fragment exists (#1448)\n' "$GREEN" "$RESET"
else
  fail=$((fail+1))
  printf '%sFAIL%s  06f-pr-collision-cache-reuse.md fragment does not exist (#1448)\n' "$RED" "$RESET"
fi

# setup.md's routing table carries a row for the new fragment.
assert_contains "$setup_router_path" \
  '06f-pr-collision-cache-reuse.md' \
  "setup.md's routing table has a row for the new 06f fragment (#1448)"

# Persistence: the write side (step 4f) posts a dedicated comment marker
# distinct from the step-4e body marker, so the cache survives across
# sessions the way cached-diagnosis comments do for every other class.
assert_contains "$setup_path" \
  'do-work-blocked-by-prs-scope' \
  "06c-scope-handling-ui.md step 4f persists would_be_ready_scope as a dedicated comment marker (#1448)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$setup_path" \
  '4f. **`blocked-by-in-flight-pr` only, and only when the deferred return also carried `would_be_ready_scope`' \
  "06c-scope-handling-ui.md's step 4f is gated on would_be_ready_scope being present, mirroring step 4e's own class gate (#1448)"

# AC2/AC3 (cache-reuse-skips-scope-dispatch / premise-invalidated-falls-
# through-to-fresh-scope): the fragment documents BOTH outcomes of the
# semantic-premise re-validation, not just the merge-state check #1429 left
# in place.
assert_contains "$setup_path" \
  'premise the deferred issue'"'"'s fix depended on' \
  "06f documents that a confirmed semantic deletion invalidates the premise and falls through to a fresh scope-agent dispatch (#1448, premise-invalidated-falls-through-to-fresh-scope)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$setup_path" \
  'Promote the candidate directly to `ready_issues`' \
  "06f documents that a validated cache promotes straight to ready_issues without a fresh scope-agent dispatch (#1448, cache-reuse-skips-scope-dispatch)"
assert_contains "$setup_path" \
  'fail-safe to NOT reuse' \
  "06f documents the fail-safe-to-gated posture for an ambiguous/inconclusive premise read (#1448)"

# The scope-agent prompt instruction tells the agent when to supply the
# cached field, and how it feeds the reuse optimization.
assert_contains "$setup_path" \
  'ALSO supply `would_be_ready_scope' \
  "06b-scope-carveouts.md's scoping-agent prompt instructs the agent to optionally supply would_be_ready_scope (#1448)"

# AC4: drain.md 5.b no longer describes the optimization as unwired — it now
# points at the shared cache-reuse procedure instead of always falling
# through to a fresh dispatch on a resolved collision.
assert_contains "$drain_path" \
  'PR-collision cache-reuse procedure' \
  "drain.md 5.b now runs the cache-reuse procedure before falling through to a fresh scope-agent dispatch (#1448)"
if grep -q 'the point-2 "reuse the cached scope without paying for a second dispatch" optimization is deliberately not wired here' "$drain_path"; then
  fail=$((fail+1))
  printf '%sFAIL%s  drain.md still describes the cache-reuse optimization as deliberately unwired (#1448 should have replaced this language)\n' "$RED" "$RESET"
else
  pass=$((pass+1))
  printf '%sPASS%s  drain.md no longer describes the cache-reuse optimization as deliberately unwired (#1448)\n' "$GREEN" "$RESET"
fi

# do-work.md's deferred_issues prose documents the shipped cache-reuse path
# rather than pointing at #1448 as a still-open follow-up.
assert_contains "$do_work_path" \
  'mandatory semantic-premise re-validation against the merged PR' \
  "do-work.md documents the mandatory premise re-validation gate on cache reuse (#1448)"
if grep -q 'is deliberately \*\*not\*\* wired here; see \[#1448\]' "$do_work_path"; then
  fail=$((fail+1))
  printf '%sFAIL%s  do-work.md still describes #1448 as an unwired follow-up\n' "$RED" "$RESET"
else
  pass=$((pass+1))
  printf '%sPASS%s  do-work.md no longer describes #1448 as an unwired follow-up\n' "$GREEN" "$RESET"
fi

# ---------------------------------------------------------------------------
# Issue #1486 — orchestrator spec-drift signal.
#
# A long dogfooding session executes the spec copy frozen into its
# orchestrator worktree at setup step 0.5, which can drift arbitrarily far
# behind origin/<default-branch> while the session itself ships releases
# into those very files. #1486 ships a SIGNAL for that drift and explicitly
# keeps the pin: nothing may refresh, reset, or re-read the worktree
# mid-session. These assertions guard both halves — that the signal exists
# on every surface (step D measurement, step E token, end-of-session line),
# and that the prohibition against auto-refreshing is stated.
# ---------------------------------------------------------------------------

# steady-state.md: step D's measurement sub-step.
assert_contains "$steady_state_path" \
  'Orchestrator spec-drift measurement' \
  "steady-state.md step D carries the spec-drift measurement sub-step (#1486)"
assert_contains "$steady_state_path" \
  'issues/1486' \
  "steady-state.md cites issue #1486 as the source of the spec-drift measurement"
assert_contains "$steady_state_path" \
  'it runs six sub-steps' \
  "steady-state.md step D's sub-step count reflects the added spec-drift (#1486) and config-staleness (#1493) sub-steps"
assert_contains "$steady_state_path" \
  'MUST NOT refresh, re-read, or reset the worktree' \
  "steady-state.md's spec-drift sub-step forbids refreshing the orchestrator worktree (#1486)"
assert_contains "$steady_state_path" \
  'not a refresh trigger' \
  "steady-state.md states the spec-drift check is not itself a refresh trigger (#1486)"
assert_contains "$steady_state_path" \
  'refresh_zero_delta_streak' \
  "steady-state.md's spec-drift sub-step names the streak it must not feed (#1486)"

# invariant-line.md + steady-state.md: the spec_drift token.
assert_contains "$invariant_line_path" \
  'spec_drift=<N|"unknown"|n/a>' \
  "invariant-line.md documents the spec_drift token shape (#1486)"
assert_contains "$invariant_line_path" \
  'issues/1486' \
  "invariant-line.md cites issue #1486 as the source of the spec_drift token"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$invariant_line_path" \
  'A missing `spec_drift=` token entirely is a contract violation' \
  "invariant-line.md treats a missing spec_drift= token as a contract violation (#1486)"
assert_contains "$steady_state_path" \
  'spec_drift=<N|"unknown"|n/a> · dispatched_this_turn=<k>' \
  "steady-state.md step E invariant line documents the spec_drift token in the dispatch format (#1486)"
assert_contains "$steady_state_path" \
  'spec_drift=<N|"unknown"|n/a> · dispatched_this_turn=0' \
  "steady-state.md step E invariant line documents the spec_drift token in the idle-proof format (#1486)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$steady_state_path" \
  '`version_cursor=`, `version_release=`, `spec_drift=`' \
  "steady-state.md's token-presence self-check enumerates spec_drift= among the mandatory tokens (#1486)"

# setup/00-config-worktree.md: step 0.5 seeds the cache from #1167's count.
assert_contains "$setup_path" \
  'SHIPYARD_SPEC_DRIFT' \
  "00-config-worktree.md registers the SHIPYARD_SPEC_DRIFT session-local variable (#1486)"
assert_contains "$setup_path" \
  'issues/1486' \
  "00-config-worktree.md cites issue #1486 for the spec-drift seed"

# cleanup-summary.md: the end-of-session advisory line.
assert_contains "$cleanup_path" \
  'Spec drift (#1486):' \
  "cleanup-summary.md renders a Spec drift advisory line (#1486)"
assert_contains "$cleanup_path" \
  'SPEC_DRIFT_END' \
  "cleanup-summary.md's step 8.7 captures the re-measured end-of-session drift (#1486)"
assert_contains "$cleanup_path" \
  'shipped by THIS session, and did not apply to it' \
  "cleanup-summary.md names the session's own spec-touching PRs in the drift line (#1486)"

# dont.md: the prohibition against a drift-triggered mid-session refresh.
assert_contains "$dont_path" \
  'measure the drift and report it' \
  "dont.md forbids a mid-session refresh/reset/re-read of the orchestrator worktree (#1486)"
assert_contains "$dont_path" \
  'issues/1486' \
  "dont.md cites issue #1486 for the no-mid-session-refresh rule"

# RATIONALE.md: the design writeup, including the declined third item.
assert_contains "$rationale_path" \
  'orchestrator spec-drift' \
  "RATIONALE.md carries the #1486 spec-drift writeup"
assert_contains "$rationale_path" \
  'declined as vacuous' \
  "RATIONALE.md records why the CLAUDE_PLUGIN_ROOT consistency assertion was declined (#1486)"
assert_contains "$rationale_path" \
  'issues/1486' \
  "RATIONALE.md cites issue #1486"

# ── Issue #1490 — a peer's claimed_paths must be communicated to a concurrent
#    worker at the granularity it was actually claimed, not widened to a dir
#    ────────────────────────────────────────────────────────────────────────
#
# Repro: the orchestrator recorded a worker's claimed_paths.hard as a script
# file plus a `__tests__/helpers/` subdirectory, then described that claim to
# a CONCURRENT worker as the parent directory `apps/lightwork/__tests__/` —
# ~400 uncontended sibling test files. The receiving worker honoured the line
# and dropped a planned source-assertion test for a collision that did not
# exist. Nothing in the spec said at what granularity a peer's claim should be
# described, and the widened phrasing is both easier to write and strictly
# broader than the truth. Distinct from the #781/#1062 state-assertion rules:
# those govern claims the worker can re-verify; a claimed-paths line silently
# REMOVES work from scope with nothing for the worker to check it against.
issue_work_path1490="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"

# dispatch-rules.md, site 1: the rule at the claimed_paths definition.
assert_contains "$dispatch_rules_path" \
  'reproduce it at the granularity it was actually claimed' \
  "dispatch-rules.md states the claimed-paths granularity rule where claimed_paths is defined (#1490)"

assert_contains "$dispatch_rules_path" \
  'Never roll a set of file claims up into their common parent directory' \
  "dispatch-rules.md forbids rolling file claims up to a parent directory (#1490)"

# Both phrasings the rule requires: partial-directory and whole-directory.
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$dispatch_rules_path" \
  'other files in `<dir>` are yours' \
  "dispatch-rules.md gives the file-level-claim-inside-a-shared-directory phrasing (#1490)"

# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$dispatch_rules_path" \
  'a peer holds the whole of `<dir>` this session' \
  "dispatch-rules.md gives the genuine whole-directory-claim phrasing (#1490)"

# The prefix-matching carve-out — correct for dispatch decisions, not for prose.
assert_contains "$dispatch_rules_path" \
  'It is **not** a license to re-describe that claim' \
  "dispatch-rules.md distinguishes prefix-matching-for-dispatch from prose widening (#1490)"

# dispatch-rules.md, site 2: the prompt-composition rule beside #781/#1062.
assert_contains "$dispatch_rules_path" \
  'A claimed-paths line is a third category of prompt assertion' \
  "dispatch-rules.md restates the granularity rule in the prompt-composition rules (#1490)"

assert_contains "$dispatch_rules_path" \
  'silently **removes work from scope**' \
  "dispatch-rules.md names why a claimed-paths line differs from a state assertion (#1490)"

assert_contains "$dispatch_rules_path" \
  'omit the line rather than guess wide' \
  "dispatch-rules.md says to omit rather than widen when granularity is unknown (#1490)"

assert_contains "$dispatch_rules_path" \
  'issues/1490' \
  "dispatch-rules.md cites issue #1490"

# dont.md: the orchestrator-side one-liner.
assert_contains "$dont_path" \
  "Don't widen a peer's \`claimed_paths\` to a directory" \
  "dont.md carries the no-widening prohibition (#1490)"

assert_contains "$dont_path" \
  'issues/1490' \
  "dont.md cites issue #1490"

# issue-work.md: the worker-side divergence-reporting rule.
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$issue_work_path1490" \
  'You narrowed your own scope to honor an `Off-limits: <path>` line' \
  "issue-work.md §5.5 adds the scope-narrowing decision-comment trigger (#1490)"

assert_contains "$issue_work_path1490" \
  '**Honor it as written**' \
  "issue-work.md tells the worker to honor the restriction rather than work around it (#1490)"

assert_contains "$issue_work_path1490" \
  'never inspect the peer'\''s worktree' \
  "issue-work.md forbids probing the peer's worktree to test the collision (#1490)"

assert_contains "$issue_work_path1490" \
  '**name the narrowing**' \
  "issue-work.md requires the narrowing be reported as a divergence (#1490)"

assert_contains "$issue_work_path1490" \
  'Scope narrowed to honor a claimed-paths / off-limits line' \
  "issue-work.md §5.5 routing table routes the narrowing to both PR and issue (#1490)"

# The (1)-(N) back-reference must have grown with the new trigger.
assert_contains "$issue_work_path1490" \
  'If none of (1)–(5) apply' \
  "issue-work.md §5.5's post-nothing default counts the new fifth trigger (#1490)"

assert_contains "$issue_work_path1490" \
  'issues/1490' \
  "issue-work.md cites issue #1490"
# --------------------------------------------------------------------------
echo
echo "(64) Release-on-non-claim: a version slot handed to a dispatch that never"
echo "     opens a PR is released at reconcile (#1420)"
# --------------------------------------------------------------------------
# `compute` advances the version_cursor the instant it hands a slot out, so a
# dispatch that terminates WITHOUT opening a PR (a `blocked` return, a
# permission-classifier denial, a crash, an explicit worker decline) strands
# that value and every later `compute` floors above the phantom. #1417's
# `reseed-if-idle` structurally cannot reach this variant — it fires only when
# `session_prs` has no OPEN member, while this leak happens with siblings still
# open (the repro: cursor 4.40.0 against a true highest claim of 4.38.0).
#
# The fix is a release hook at step B, NOT a cursor rollback: a released slot
# may not be the highest one outstanding, so decrementing would hand a later
# batch member's already-promised value back out and reintroduce #437. The
# released version is recorded as a hole and reclaimed by the next `compute`.
orch_state_ref_path1420="$repo_root/plugins/shipyard/commands/do-work/orchestrator-state-reference.md"

# The script gains the `release` subcommand and a reclaim-aware `compute`.
assert_contains "$repo_root/plugins/shipyard/scripts/next-available-version.sh" \
  'release --version <v>' \
  "next-available-version.sh documents the release subcommand (#1420)"
assert_contains "$repo_root/plugins/shipyard/scripts/next-available-version.sh" \
  'reclaimed_slot=<semver-or-empty>' \
  "next-available-version.sh compute emits the reclaimed_slot line (#1420)"
assert_contains "$repo_root/plugins/shipyard/scripts/next-available-version.sh" \
  'A release is NOT a cursor rollback' \
  "next-available-version.sh states that release never lowers the cursor (#1420)"
assert_contains "$repo_root/plugins/shipyard/scripts/next-available-version.sh" \
  'claimed_floor' \
  "next-available-version.sh bounds hole reuse on the ground-truth claimed floor (#1420)"

# steady-state.md step B owns the single reconcile call site.
assert_contains "$steady_state_path" \
  'B.0. Release the version slot when this dispatch claimed no PR' \
  "steady-state.md step B carries the release-on-non-claim hook (#1420)"
assert_contains "$steady_state_path" \
  'next-available-version.sh" release' \
  "steady-state.md step B.0 calls next-available-version.sh release (#1420)"
assert_contains "$steady_state_path" \
  'single funnel' \
  "steady-state.md explains why the release lives at step B, not per-mode in A.1 (#1420)"
assert_file_exists "$version_release_path" \
  "do-work/version-release.md exists (step B.0's hook, split out per #611's size cap) (#1420)"
assert_contains "$steady_state_path" \
  'degrades to the status quo' \
  "steady-state.md records that a skipped release degrades to a leak, never a collision (#1420)"
assert_contains "$steady_state_path" \
  'issues/1420' \
  "steady-state.md cites issue #1420"

# The classifier-denial path is the one non-claiming shape that never reaches
# step B (no in_flight slot is ever written for it), so it releases its own.
assert_contains "$dispatch_rules_path" \
  'Release the version slot too, when the denied dispatch had one' \
  "dispatch-rules.md releases the slot on a permission-classifier denial (#1420)"
assert_contains "$dispatch_rules_path" \
  'version_slot' \
  "dispatch-rules.md records the handed-out slot on the in_flight entry (#1420)"
assert_contains "$dispatch_rules_path" \
  'reclaimed_slot' \
  "dispatch-rules.md parses compute's fourth output line (#1420)"

# The invariant-line token — the ci_backpressure-family evidence flag that
# makes a SKIPPED release visible rather than silent.
assert_contains "$invariant_line_path" \
  'version_release=<n/a|none|released|skipped>' \
  "invariant-line.md documents the version_release token (#1420)"
# shellcheck disable=SC2016
# Backticks are literal markdown punctuation in the needle.
assert_contains "$invariant_line_path" \
  'a direct application of the `ci_backpressure` pattern' \
  "invariant-line.md places version_release in the ci_backpressure family (#1420)"
assert_contains "$invariant_line_path" \
  'This is the value the token exists to make visible' \
  "invariant-line.md names skipped as the divergence smell (#1420)"

# in_flight grows the version_slot field that carries the promise to reconcile.
assert_contains "$do_work_path" \
  'version_slot?' \
  "do-work.md's in_flight struct carries version_slot (#1420)"
assert_contains "$do_work_path" \
  'issues/1420' \
  "do-work.md cites issue #1420 for version_slot"

# The cold version_cursor struct documents the release as its second self-heal.
assert_contains "$orch_state_ref_path1420" \
  'Released at reconcile when a dispatch never claims its slot' \
  "orchestrator-state-reference.md documents the release half of the cursor self-heal (#1420)"

# RATIONALE.md: why a hole rather than a rollback, and why no ledger is needed.
assert_contains "$rationale_path" \
  'Release-on-non-claim' \
  "RATIONALE.md carries the #1420 release-on-non-claim writeup"
assert_contains "$rationale_path" \
  'per-slot promise ledger' \
  "RATIONALE.md records why the per-slot promise ledger stays unbuilt (#1420)"
assert_contains "$rationale_path" \
  'issues/1420' \
  "RATIONALE.md cites issue #1420"

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
