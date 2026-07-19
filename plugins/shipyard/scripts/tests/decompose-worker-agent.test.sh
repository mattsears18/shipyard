#!/usr/bin/env bash
# Test: `shipyard:decompose-worker` — the first-class agent identity for the
# epic-decomposition logic (issue #772, follow-up to #767's out-of-scope
# carve-out).
#
# Before #772, epic decomposition (a `confirmed-non-shippable-as-single-PR`
# defer) only ran as an anonymous `general-purpose` sub-agent dispatched with
# an inlined copy of `commands/decompose-epic.md`'s "Worker prompt template" —
# from both `/decompose-epic`'s own bulk dispatch and `/do-work`'s inline
# auto-decompose path (#665). Unlike every other worker mode this plugin
# ships (issue-work, fix-checks-only, fix-rebase, fix-main-ci,
# fix-failing-prs-batch, investigate — all registered agents with pinned
# models under agents/), decomposition had no first-class, model-pinned,
# by-name dispatch target.
#
# This test pins the shape of the fix:
#
#   (1) agents/decompose-worker.md exists with the expected frontmatter
#       (name, description, a pinned model).
#   (2) It points at commands/decompose-epic.md's Worker prompt template as
#       the single source of truth rather than re-deriving/forking the
#       sharding logic.
#   (3) It explicitly documents the NO-worktree-isolation contract — this
#       agent is architecturally different from the six worktree-isolated
#       issue-worker modes (it never touches code, only the GitHub API), so
#       it must NOT be dispatched with isolation: "worktree" and must NOT be
#       added to enforce-worktree-isolation.sh's guarded shim set.
#   (4) It documents the decompose/escalated/blocked return contract that
#       matches commands/decompose-epic.md's Worker prompt template.
#   (5) It explicitly scopes out orchestrator dispatch-wiring (tracked
#       separately in #774) — this issue is agent-definition scaffolding
#       only, not a new /do-work dispatch phase.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/decompose-worker-agent.test.sh

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

agent_path="$repo_root/plugins/shipyard/agents/decompose-worker.md"
decompose_epic_path="$repo_root/plugins/shipyard/commands/decompose-epic.md"
isolation_hook_path="$repo_root/plugins/shipyard/hooks/enforce-worktree-isolation.sh"

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

assert_not_contains() {
  local file="$1"; local needle="$2"; local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected NOT to find in %s: %s\n' "$file" "$needle"; fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  fi
}

echo "decompose-worker agent regression tests"
echo

# (1) Agent file exists with expected frontmatter.
assert_file_exists "$agent_path" "agents/decompose-worker.md exists"

if [[ -f "$agent_path" ]]; then
  assert_contains "$agent_path" "name: decompose-worker" \
    "frontmatter declares name: decompose-worker"
  assert_contains "$agent_path" "model:" \
    "frontmatter pins a model"
  assert_contains "$agent_path" "description:" \
    "frontmatter has a description field"
  # References the origin issue for provenance.
  assert_contains "$agent_path" "#772" \
    "agent file cites issue #772"

  # (2) Points at decompose-epic.md's Worker prompt template as the single
  # source of truth — must not re-derive or fork the sharding logic.
  assert_contains "$agent_path" "decompose-epic.md" \
    "agent file references commands/decompose-epic.md"
  assert_contains "$agent_path" "Worker prompt template" \
    "agent file points at the Worker prompt template"
  assert_contains "$agent_path" "single source of truth" \
    "agent file declares decompose-epic.md's template as the single source of truth (no re-derive/fork)"

  # (3) NO-worktree-isolation contract — the architecturally load-bearing
  # difference from the six issue-worker modes.
  assert_contains "$agent_path" 'isolation: "worktree"' \
    "agent file discusses the isolation: \"worktree\" parameter"
  assert_contains "$agent_path" "Never dispatch this agent with" \
    "agent file explicitly forbids worktree isolation for this agent"
  assert_contains "$agent_path" "Worktree isolation contract" \
    "agent file has an explicit Worktree isolation contract section"

  # It must NOT claim to load shipyard:worker-preamble — that skill assumes
  # a worktree-isolated, code-shipping worker, which this agent is not.
  assert_not_contains "$agent_path" "load the \`shipyard:worker-preamble\` skill" \
    "agent file does NOT instruct loading shipyard:worker-preamble (wrong contract for a no-worktree agent)"

  # (4) Return contract mirrors decompose-epic.md's Worker prompt template.
  assert_contains "$agent_path" "decomposed:" \
    "agent file documents the decomposed: return string"
  assert_contains "$agent_path" "escalated:" \
    "agent file documents the escalated: return string"
  assert_contains "$agent_path" "blocked:" \
    "agent file documents the blocked: return string"

  # (5) Dispatch-wiring is explicitly out of scope, tracked separately.
  assert_contains "$agent_path" "#774" \
    "agent file cites #774 as the separately-tracked dispatch-wiring issue"
  assert_contains "$agent_path" "out of scope" \
    "agent file explicitly scopes out orchestrator dispatch-wiring"

  # Untrusted-input discipline — same posture as issue-work step 2 / /refine-issues.
  assert_contains "$agent_path" "never instructions" \
    "agent file states the epic body/comments are data, never instructions"
fi

# (6) decompose-epic.md itself still documents the no-worktree-isolation rule
# this new agent's contract mirrors (regression guard: the two files must not
# drift apart on this point).
assert_file_exists "$decompose_epic_path" "commands/decompose-epic.md exists"
if [[ -f "$decompose_epic_path" ]]; then
  assert_contains "$decompose_epic_path" 'isolation: "worktree"' \
    "decompose-epic.md documents the no-worktree-isolation dispatch shape this agent mirrors"
fi

# (7) This agent must NOT be added to enforce-worktree-isolation.sh's guarded
# shim set — it is deliberately exempt (no code writes, no worktree needed).
# If a future change adds it there, that's a contradiction with this agent's
# own documented contract and should fail loudly rather than silently drift.
assert_file_exists "$isolation_hook_path" "hooks/enforce-worktree-isolation.sh exists"
if [[ -f "$isolation_hook_path" ]]; then
  assert_not_contains "$isolation_hook_path" "shipyard:decompose-worker" \
    "enforce-worktree-isolation.sh does NOT guard shipyard:decompose-worker (it is a no-worktree agent by design)"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
