#!/usr/bin/env bash
# Test: the shipyard:spike-worker agent mode exists — a thin shim agent
# (agents/spike-worker.md) plus a canonical per-mode spec
# (agents/issue-worker/spike.md) — mirroring the existing per-mode
# shim + spec convention used by the five other /do-work worker modes.
#
# Background — issue #773
# ------------------------
# #767 (phase-1 taxonomy slice) made spike/design/feasibility issues
# dispatchable via the standard issue-work mode instead of being deferred to
# a human by default, and named a dedicated shipyard:spike-worker agent mode
# as an explicit out-of-scope follow-up: a spike's shape (investigate ->
# decide -> design doc -> decompose -> optional implement) is distinct
# enough from a normal bug/feature issue to deserve its own per-mode spec
# rather than a branch inside issue-work.
#
# #773 itself was a **plugin-source-only** slice — creating the agent mode.
# It deliberately did NOT wire orchestrator dispatch-site routing (spike
# detection heuristics, commands/do-work/dispatch-rules.md / steady-state.md
# dispatch branches, agents/issue-worker.md's mode-routing table) — that was
# tracked separately as #774. #774 has since landed and wired that routing;
# section (K) below now asserts the wiring is present (updated from its
# original "must NOT reference" assertions, which pinned #773's boundary
# before #774 existed).
#
# This test is the regression guard: if anyone deletes the shim, deletes the
# per-mode spec, breaks the shim -> spec cross-reference, drops the
# design-doc / decomposition / sub-issue-leak-verification guards from the
# spec, or the #774 dispatch-site wiring, the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/spike-worker.test.sh

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

shim_path="$repo_root/plugins/shipyard/agents/spike-worker.md"
spec_path="$repo_root/plugins/shipyard/agents/issue-worker/spike.md"
dispatch_rules_path="$repo_root/plugins/shipyard/commands/do-work/dispatch-rules.md"
steady_state_path="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
hook_path="$repo_root/plugins/shipyard/hooks/enforce-worktree-isolation.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_file_exists() {
  local path="$1" label="$2"
  if [[ -f "$path" ]]; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    missing: %s\n' "$path"
  fi
}

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    expected to find in %s:\n    %s\n' "$file" "$needle"
  fi
}

assert_not_contains() {
  local file="$1" needle="$2" label="$3"
  if [[ ! -f "$file" ]] || ! grep -qF -- "$needle" "$file" 2>/dev/null; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    did NOT expect to find in %s:\n    %s\n' "$file" "$needle"
  fi
}

echo "== (A) the shim agent and per-mode spec both exist"

assert_file_exists "$shim_path" "agents/spike-worker.md (shim) exists"
assert_file_exists "$spec_path" "agents/issue-worker/spike.md (per-mode spec) exists"

if [[ ! -f "$shim_path" || ! -f "$spec_path" ]]; then
  echo "  cannot continue without both files" >&2
  exit 1
fi

echo
echo "== (B) shim frontmatter + shape"

assert_contains "$shim_path" "name: spike-worker" \
  "shim declares name: spike-worker"
assert_contains "$shim_path" "mode: spike" \
  "shim names mode: spike explicitly"
# No model: pin — spike work needs full reasoning tier, same rationale as
# the unpinned issue-worker.md entry (not the five cost-optimized shims).
if grep -q '^model:' "$shim_path"; then
  assert_fail "shim carries no model: pin (inherits session model, matching issue-work's tier)"
else
  assert_pass "shim carries no model: pin (inherits session model, matching issue-work's tier)"
fi

echo
echo "== (C) shim -> per-mode spec cross-reference + shared-rules pointer"

assert_contains "$shim_path" "shipyard:worker-preamble" \
  "shim loads the shipyard:worker-preamble skill first"
assert_contains "$shim_path" "issue-worker/spike.md" \
  "shim references agents/issue-worker/spike.md as the canonical spec"
assert_contains "$shim_path" "isolation: \"worktree\"" \
  "shim documents the mandatory isolation: \"worktree\" dispatch contract"
assert_contains "$shim_path" "wrong shim" \
  "shim documents the wrong-mode fail-safe return"

echo
echo "== (D) per-mode spec — shared-rules pointer + inputs"

assert_contains "$spec_path" "shipyard:worker-preamble" \
  "spec references the shipyard:worker-preamble skill"
assert_contains "$spec_path" "originating_author_trust" \
  "spec documents the originating_author_trust auto-merge gate input"
assert_contains "$spec_path" "decompose.max_subissues" \
  "spec documents the decompose.max_subissues fan-out cap input"

echo
echo "== (E) per-mode spec — the distinguishing spike lifecycle: investigate -> design doc -> decompose -> optional implement"

assert_contains "$spec_path" "feasibility investigation" \
  "spec has a feasibility-investigation step"
assert_contains "$spec_path" "Viable" \
  "spec enumerates the viable conclusion"
assert_contains "$spec_path" "Not viable" \
  "spec enumerates the not-viable conclusion"
assert_contains "$spec_path" "design doc" \
  "spec requires a committed design doc"
assert_contains "$spec_path" "docs/adr" \
  "spec checks for an existing ADR/decision-record convention before defaulting a design-doc path"
assert_contains "$spec_path" "Decompose into follow-on sub-issues" \
  "spec has a decomposition-into-sub-issues step"
assert_contains "$spec_path" "Implement the directly-committable slice" \
  "spec has an optional directly-committable-slice implementation step"

echo
echo "== (F) per-mode spec — a design-doc-only diff is a valid PR (not a phantom merge)"

assert_contains "$spec_path" "the design doc counts as the required non-empty diff" \
  "spec explicitly overrides issue-work's phantom-merge guard for a design-doc-only diff"

echo
echo "== (G) per-mode spec — follow-on sub-issue closing-reference leak guard (#624 inverse)"

assert_contains "$spec_path" "bare URL" \
  "spec requires bare-URL references to follow-on sub-issues (not bare #<child> tokens)"
assert_contains "$spec_path" "closingIssuesReferences" \
  "spec verifies GitHub's closingIssuesReferences for leaked sub-issue closes"
assert_contains "$spec_path" "gh issue reopen" \
  "spec reopens a follow-on sub-issue if it leaked into a closing reference and got closed"

echo
echo "== (H) per-mode spec — fan-out cap + over-cap escalation"

assert_contains "$spec_path" "fan-out cap" \
  "spec documents the sub-issue fan-out cap"
assert_contains "$spec_path" "needs-human-review" \
  "spec routes an over-cap decomposition (and a genuinely undecidable spike) to needs-human-review"

echo
echo "== (I) per-mode spec — return-string vocabulary"

assert_contains "$spec_path" "spiked+shipped" \
  "spec defines the spiked+shipped terminal return string"
assert_contains "$spec_path" "spiked+needs-human-review" \
  "spec defines the spiked+needs-human-review terminal return string"
assert_contains "$spec_path" "reaped:" \
  "spec documents the reaped: retryable escape hatch"
assert_contains "$spec_path" "blocked #<N> at <stage>: <reason>" \
  "spec documents the blocked: universal escape hatch"
assert_contains "$spec_path" "not viable\" conclusion is still" \
  "spec explicitly states a not-viable conclusion is still a shipped (not blocked) disposition"

echo
echo "== (J) reuse, not duplication — the spec cross-references issue-work's shared mechanics rather than re-deriving them"

assert_contains "$spec_path" "issue-work" \
  "spec cross-references issue-work.md for shared mechanics (sync+branch, auto-merge gating, etc.)"
assert_contains "$spec_path" "624" \
  "spec cites issue #624 (the closing-reference-leak mechanism) for the sub-issue leak guard"
assert_contains "$spec_path" "481" \
  "spec cites issue #481 (the stuck-open closing-keyword hazard) for the dispatched issue's own Closes #<N>"

echo
echo "== (K) DISPATCH-SITE WIRING — #774 routes spike-shaped issues to this mode"

# #773 (this test's original scope) deliberately left orchestrator dispatch-site
# routing unwired. #774 is the follow-up that wires it — this section now
# asserts the wiring actually landed, rather than asserting its absence.
assert_contains "$spec_path" "774" \
  "spec cites #774 as the dispatch-integration follow-up"
assert_contains "$shim_path" "774" \
  "shim cites #774 as the dispatch-integration follow-up"

# The orchestrator's dispatch-routing files must now reference this mode —
# the whole point of #774 is that spike-shaped issues get routed here instead
# of parked or dispatched as a plain issue-work candidate.
# #791 retired the Agent-tool `subagent_type` routing (the Workflow substrate
# takes no subagent_type), so the routing signal in dispatch-rules.md is the
# mode name plus its per-mode spec, not the shim name.
assert_contains "$dispatch_rules_path" "issue-worker/spike.md" \
  "dispatch-rules.md routes mode: spike to the spike per-mode spec (#774, #791)"
assert_contains "$dispatch_rules_path" "mode: spike" \
  "dispatch-rules.md's spike prompt template names mode: spike (#774)"
assert_contains "$dispatch_rules_path" "Spike-shape detection" \
  "dispatch-rules.md documents the spike-shape detection check (#774)"
assert_contains "$steady_state_path" "spiked+shipped" \
  "steady-state.md's A.1 reconcile handles the spiked+shipped return (#774)"
assert_contains "$steady_state_path" "spiked+needs-human-review" \
  "steady-state.md's A.1 reconcile handles the spiked+needs-human-review return (#774)"
assert_contains "$hook_path" "shipyard:spike-worker" \
  "enforce-worktree-isolation.sh's guarded-set includes shipyard:spike-worker (#774)"

echo
printf 'passed: %d  failed: %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]] || exit 1
