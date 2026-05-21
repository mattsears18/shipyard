#!/usr/bin/env bash
# Test: commands/do-work.md is split into a thin entry router + per-phase
# files + RATIONALE.md. See issues #100 (entry + RATIONALE split) and #154
# (further split by phase).
#
# Spec runtime guarantees:
#   - thin entry + RATIONALE + every phase file exists
#   - thin entry stays < 200 lines (the routing-only contract from #154)
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

# (2) The thin entry stays under 200 lines. Acceptance criterion from
#     #154 — the entry is allowed to grow if a new orchestrator-state
#     struct lands, but if it grows past 200 the split is over-engineered
#     and we'd rather know.
assert_line_count_at_most "$do_work_path" 200 \
  "thin entry stays <= 200 lines (#154 acceptance criterion)"

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

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
