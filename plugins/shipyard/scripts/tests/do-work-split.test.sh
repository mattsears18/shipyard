#!/usr/bin/env bash
# Test: commands/do-work.md is split into a tight runtime spec + a
# human-readable RATIONALE.md. See issue #100.
#
# Spec runtime guarantees:
#   - both files exist
#   - do-work.md is the tighter file (smaller than RATIONALE? not necessarily —
#     the spec still contains all the procedural detail + load-bearing code
#     blocks. What we DO want to assert: do-work.md ≤ 1700 lines, and the
#     RATIONALE file is at least 200 lines so the prose-rationale content
#     genuinely landed there)
#   - cross-references from do-work.md → RATIONALE.md exist (≥10) so the
#     reader knows where to find the why
#   - the key anchors external files reference still exist in do-work.md
#     (regression guard against accidental anchor renames during the split)
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

assert_count_at_least() {
  local file="$1"
  local needle="$2"
  local min="$3"
  local label="$4"
  local count
  count=$(grep -cF -- "$needle" "$file" 2>/dev/null | head -n 1)
  count=${count:-0}
  if (( count >= min )); then
    printf '  %sPASS%s  %s (found %d, min %d)\n' "$GREEN" "$RESET" "$label" "$count" "$min"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (found %d, min %d)\n' "$RED" "$RESET" "$label" "$count" "$min"
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

echo "do-work spec split regression tests (issue #100)"
echo

# (1) Both files exist.
assert_file_exists "$do_work_path" "commands/do-work.md exists"
assert_file_exists "$rationale_path" "commands/do-work-RATIONALE.md exists"

# (2) RATIONALE has substantive content (≥200 lines) so the prose-rationale
#     actually landed there rather than being silently deleted during the split.
assert_line_count_at_least "$rationale_path" 200 \
  "RATIONALE.md carries substantive prose"

# (3) do-work.md cross-references RATIONALE.md in multiple places so the
#     reader knows where to find the why.
assert_count_at_least "$do_work_path" "do-work-RATIONALE.md" 10 \
  "do-work.md cross-references RATIONALE.md (≥10 places)"

# (4) Key anchors that external files reference still exist in do-work.md.
#     See agents/issue-worker.md and the dispatch-prompt cross-refs.
assert_contains "$do_work_path" "### A. Reconcile the return" \
  "anchor: A. Reconcile the return (referenced by issue-worker.md)"
assert_contains "$do_work_path" "## Dispatch rules (used by step 7 and step C)" \
  "anchor: Dispatch rules (referenced by issue-worker.md)"
assert_contains "$do_work_path" "### 1.7 Resolve trusted-author allowlist" \
  "anchor: 1.7 trusted-author allowlist (referenced by issue-worker.md)"
assert_contains "$do_work_path" "## End-of-session drain" \
  "anchor: End-of-session drain (referenced by issue-worker.md)"

# (5) The Don't section is still present in do-work.md but as a tight rule
#     list — the rules themselves stay, but the long failure-mode rationale
#     paragraphs moved to RATIONALE.md.
assert_contains "$do_work_path" "## Don't" \
  "do-work.md still has a Don't section (the rules)"
assert_contains "$rationale_path" "## Don't — extended rationale" \
  "RATIONALE.md carries the extended Don't rationale"

# (6) Worker-preamble references still ≥5 in do-work.md (overlaps with
#     worker-preamble.test.sh but cheaper to re-assert here than to chase
#     across two test files).
assert_count_at_least "$do_work_path" "shipyard:worker-preamble" 5 \
  "do-work.md still references shipyard:worker-preamble in ≥5 places"

# (7) Both cleanup paths (step 3b at startup, step 3 at shutdown) reference
#     the worktree-reap helper. Regression guard against issue #138 — if
#     either call site reverts to the strict liveness check, the
#     orchestrator's own PID will defer every agent worktree at shutdown.
assert_count_at_least "$do_work_path" "scripts/worktree-reap.sh" 2 \
  "do-work.md references scripts/worktree-reap.sh in ≥2 places (step 3 + 3b)"
assert_contains "$do_work_path" "classify-lock" \
  "do-work.md references the classify-lock subcommand"
assert_contains "$do_work_path" "self-ancestor" \
  "do-work.md mentions the self-ancestor classification (issue #138 fix)"

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
