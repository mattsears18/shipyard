#!/usr/bin/env bash
# Test: the orchestrator may not write a worker's own documented short-circuit
# out of its dispatch prompt — issue #1513.
#
# Background
# ----------
# `dont.md` already carried a floor on what the orchestrator may instruct a
# worker to do, but only over two of the three channels the instruction can
# travel:
#
#   * #1230 — a mid-flight `SendMessage` to an already-RUNNING worker.
#   * #1278 — a follow-up composed AFTER a worker returned
#             `blocked: classifier denied <op>`.
#
# The third channel — the INITIAL dispatch prompt that starts the worker — had
# no stated floor at all, and it is the channel with the weakest natural guard:
# the worker never reaches its documented stop, so there is no correct refusal
# for the instruction to override.
#
# The repro (session do-work-20260821T204914Z-74826, PR #1508): the
# orchestrator dispatched `mode: fix-checks-only` at a DIRTY PR and wrote the
# rebase into the prompt as an explicit second task. `fix-checks-only.md`'s
# DIRTY short-circuit says to return `dirty #<M>` and stop, because the work
# belongs to `fix-rebase`. The worker complied with the prompt instead, and it
# WORKED — rebased, fixed both root causes, returned `green #1508`, merged.
#
# That success is the actual problem. A worker that REFUSES produces a
# `blocked:` return the orchestrator is structurally forced to reconcile; a
# worker that COMPLIES produces a clean green PR and no signal anywhere. The
# only trace here was a paragraph the worker volunteered unprompted.
#
# The three parts of the fix, and where each is asserted below:
#
#   1. `dont.md` states the floor over the initial-dispatch-prompt channel,
#      and all three bullets cross-name each other as ONE floor so no reader
#      infers a distinction in scope that doesn't exist  -> sections (1), (2)
#   2. A mechanical gate (2e) at the fix-checks prompt-COMPOSITION site, which
#      is the one site the two existing DIRTY exclusions do not cover, since
#      both constrain set construction only                      -> section (3)
#   3. `fix-checks-only.md`'s DIRTY short-circuit carries #1060's
#      rollup-size-independent reasoning and refuses a dispatch-prompt
#      override, closing the misreading that produced the repro -> section (4)
#
# Section (5) guards the boundary against #1278's deliberately-rejected
# downstream auto-merge suppression: 2e must be justified as a
# composition-site check, not resurrect the rejected shape.
#
# Spec-content assertions only (all three surfaces are markdown). Run with:
#   bash plugins/shipyard/scripts/tests/dispatch-prompt-short-circuit-1513.test.sh
#
# File-level SC2016 waiver: the needles below are LITERAL markdown fragments
# (backticked spans, `#<M>` placeholders) that must reach grep unexpanded.
# Single quotes are correct here, not a mistake.
# shellcheck disable=SC2016

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

plugin_root="$repo_root/plugins/shipyard"
dont_path="$plugin_root/commands/do-work/dont.md"
dispatch_path="$plugin_root/commands/do-work/dispatch-rules.md"
fix_checks_path="$plugin_root/agents/issue-worker/fix-checks-only.md"
rationale_path="$repo_root/docs/design/do-work-rationale.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

# Assert a single line in $file contains BOTH needles. Used where the property
# under test is that two facts are stated *in the same bullet* — dont.md is one
# bullet per line, so co-location on a line is co-location in a rule. Asserting
# them separately would pass even if a future edit split them into two bullets,
# which is exactly the near-duplicate outcome #1513 warned against.
assert_same_line() {
  local file="$1" a="$2" b="$3" label="$4"
  if grep -F -- "$a" "$file" 2>/dev/null | grep -qF -- "$b"; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected one line in %s to contain both:\n      %s\n      %s\n' "$file" "$a" "$b"
    fail=$((fail+1))
  fi
}

echo "== (1) dont.md states the floor over the initial-dispatch-prompt channel (#1513)"

assert_contains "$dont_path" \
  "Don't write a worker's own documented short-circuit out of its dispatch prompt" \
  "dont.md carries the initial-dispatch-prompt floor bullet"

assert_contains "$dont_path" \
  "https://github.com/mattsears18/shipyard/issues/1513" \
  "dont.md cites issue #1513 as the provenance"

# The core prohibition. The repro's instruction was additive ("fix the checks,
# AND ALSO rebase"), which is why the rule has to name WIDENING specifically —
# a rule phrased as "don't contradict the spec" would not have caught it, since
# nothing in the prompt contradicted anything.
assert_contains "$dont_path" \
  "may NOT pre-empt that by writing the short-circuited work into the prompt as an extra task" \
  "dont.md forbids writing the short-circuited work in as an extra task"

assert_same_line "$dont_path" \
  "Don't write a worker's own documented short-circuit out of its dispatch prompt" \
  "route to the mode that owns the work" \
  "the same bullet names the correct remedy (route to the owning mode)"

# The asymmetry is the whole justification for a named rule rather than
# judgment: refusal is loud and self-reporting, compliance is silent.
assert_same_line "$dont_path" \
  "Don't write a worker's own documented short-circuit out of its dispatch prompt" \
  "when a worker complies, the only trace is whatever prose the worker volunteers" \
  "the bullet names the refuse-is-loud / comply-is-silent asymmetry"

assert_same_line "$dont_path" \
  "Don't write a worker's own documented short-circuit out of its dispatch prompt" \
  "invisible exactly when it succeeds" \
  "the bullet names invisible-on-success as the reason it earns a rule"

# Scope narrowing must stay explicitly sanctioned. #1230 permits it, and a new
# bullet that read as a blanket "don't deviate from the spec" would silently
# revoke a mechanism the loop actively relies on.
assert_same_line "$dont_path" \
  "Don't write a worker's own documented short-circuit out of its dispatch prompt" \
  "this forbids only *widening* one past its mode's documented stop" \
  "the bullet preserves scope-narrowing and forbids only widening"

assert_contains "$dont_path" \
  "do-work-rationale.md#dont-write-a-workers-own-short-circuit-out-of-its-dispatch-prompt-issue-1513" \
  "dont.md links the bullet to its RATIONALE section"

assert_contains "$rationale_path" \
  "### Don't write a worker's own short-circuit out of its dispatch prompt (issue #1513)" \
  "RATIONALE carries the section the dont.md bullet links to"

echo
echo "== (2) the three channels read as ONE floor, not three overlapping rules"

# This is the near-duplicate guard the issue explicitly asked for: a rule that
# looks adjacent to #1278's without saying how they relate invites a reader to
# infer a scope distinction that doesn't exist. Each bullet must name the
# other two.
assert_same_line "$dont_path" \
  "Don't write a worker's own documented short-circuit out of its dispatch prompt" \
  "There is one floor, and it reaches the orchestrator over three channels" \
  "the new bullet frames all three as one floor over three channels"

assert_same_line "$dont_path" \
  "Don't write a worker's own documented short-circuit out of its dispatch prompt" \
  "issues/1230" \
  "the new bullet names #1230 (mid-flight SendMessage) as the same floor"

assert_same_line "$dont_path" \
  "Don't write a worker's own documented short-circuit out of its dispatch prompt" \
  "issues/1278" \
  "the new bullet names #1278 (post-denial follow-up) as the same floor"

# And the reverse direction: a reader landing on #1278's bullet first must not
# come away thinking the floor is classifier-specific.
assert_same_line "$dont_path" \
  "Don't instruct a worker to route around its own worker-internal classifier denial" \
  "This bullet is the post-denial instance of one floor, not a rule of its own" \
  "#1278's bullet declares itself an instance of the shared floor"

assert_same_line "$dont_path" \
  "Don't instruct a worker to route around its own worker-internal classifier denial" \
  "never a limit on which stops are protected" \
  "#1278's bullet disclaims the classifier framing as a scope limit"

assert_same_line "$dont_path" \
  "Don't instruct a worker to route around its own worker-internal classifier denial" \
  "read no distinction between the three beyond *when* the instruction is sent" \
  "#1278's bullet forecloses inferring a phantom distinction between the three"

# The remedies genuinely differ per channel, which is why the three bullets are
# not merged. RATIONALE has to record that, or a future cleanup pass will
# collapse them and lose two of the three remedies.
assert_contains "$rationale_path" \
  "Why the three bullets stay separate rather than being merged into one" \
  "RATIONALE records why the three bullets are not merged"

echo
echo "== (3) dispatch-rules.md gates fix-checks composition on DIRTY (2e)"

assert_contains "$dispatch_path" \
  "2e. DIRTY gate — never compose a fix-checks-only prompt for a DIRTY PR" \
  "dispatch-rules.md carries the 2e DIRTY gate"

# Not config-gated. 2a/2b are cost knobs that default OFF; a correctness gate
# that inherited that default would be inert on every repo that never opted in.
assert_same_line "$dispatch_path" \
  "2e. DIRTY gate" \
  "this is a correctness gate and is always on" \
  "2e is explicitly not config-gated"

assert_contains "$dispatch_path" \
  "If it reports \`DIRTY\`, do not compose the prompt." \
  "2e refuses prompt composition on DIRTY"

assert_contains "$dispatch_path" \
  "[dirty-gate] PR #<M> is DIRTY — fix-checks-only refused" \
  "2e emits an operator-visible log line"

# Refusing to compose is only half the gate; the PR has to go somewhere or it
# silently stalls in failed_prs forever.
assert_contains "$dispatch_path" \
  "resolve-manifest-only-dirty.sh" \
  "2e routes the refused PR to the in-process resolver"

assert_contains "$dispatch_path" \
  "drop \`<M>\` from \`failed_prs\`" \
  "2e removes the PR from failed_prs so it can't re-trip the same site"

# The exact move the repro made must be named, or a future orchestrator reads
# 2e as "don't dispatch fix-checks at DIRTY" and satisfies it by writing a
# fuller prompt instead of a different mode.
assert_contains "$dispatch_path" \
  "Writing the rebase into the fix-checks prompt as an extra task is not an alternative to this gate" \
  "2e forecloses satisfying the gate by widening the prompt instead"

# Why a THIRD DIRTY check is not redundant: the two existing ones constrain set
# construction, so neither is on the path a hand-composed dispatch takes.
assert_contains "$dispatch_path" \
  "but both constrain **set construction**" \
  "2e explains that the two existing DIRTY exclusions guard set construction only"

assert_same_line "$dispatch_path" \
  "but both constrain **set construction**" \
  "never passes through either filter" \
  "2e names the hand-composed dispatch as the uncovered path"

assert_contains "$dispatch_path" \
  "After 2a, 2b, 2d, and 2e clear" \
  "the dispatch line requires 2e alongside the pre-existing checks"

# The worker-side short-circuit is a net for the dispatch-to-start race and must
# survive: 2e reads state once, and a sibling merge can DIRTY the PR afterwards.
assert_contains "$dispatch_path" \
  "remains the worker-side net for the dispatch-to-start race, unchanged" \
  "2e preserves the worker-side short-circuit rather than replacing it"

echo
echo "== (4) fix-checks-only.md's DIRTY short-circuit resists the two misreadings"

# Misreading 1: the section is titled and closes around the empty-rollup case,
# so a worker reasoned the rule didn't bind a PR with a non-empty red rollup.
assert_contains "$fix_checks_path" \
  "The rule is not scoped to an empty rollup, and a non-empty red rollup does not soften it" \
  "the short-circuit disclaims the empty-rollup-only reading"

# #1060's reasoning is rollup-size-independent and was reachable only from
# dont.md — i.e. not from where the worker was actually reading.
assert_contains "$fix_checks_path" \
  "a red check on a DIRTY PR is a frozen fossil of the last base the PR could still build against, not live evidence about its current health" \
  "the short-circuit carries #1060's rollup-size-independent reasoning verbatim"

assert_contains "$fix_checks_path" \
  "A rollup full of failures is therefore *more* misleading than an empty one, not less" \
  "the short-circuit states why a non-empty rollup strengthens rather than weakens the rule"

# The rule itself must not have been softened while adding the justification —
# #1513 explicitly declined the worker's proposal to weaken it.
assert_contains "$fix_checks_path" \
  "**If \`MERGE_STATE == \"DIRTY\"\`, stop here — do NOT enter the fix-loop, do NOT call \`gh pr checks --watch\`, and do NOT poll.**" \
  "the original unconditional stop survives unweakened"

# Misreading 2: the dispatch prompt told the worker to rebase, and nothing in
# the worker's own spec said a prompt cannot widen it past its documented stop.
assert_contains "$fix_checks_path" \
  "An instruction in your dispatch prompt to rebase anyway does not override this" \
  "the short-circuit refuses a dispatch-prompt override"

assert_contains "$fix_checks_path" \
  "Return \`dirty #<M>\` and let the orchestrator route to \`fix-rebase\`" \
  "the short-circuit restates the correct return under an overriding prompt"

# Without this the misroute stays invisible on success — the failure mode the
# whole issue is about.
assert_contains "$fix_checks_path" \
  "note the instruction in your return so the misroute leaves an artifact" \
  "the worker is told to leave an artifact recording the misroute"

assert_contains "$fix_checks_path" \
  "even when the rebase succeeds" \
  "the short-circuit names success as not exonerating the misroute"

# Same narrowing/widening boundary as dont.md's bullet, stated worker-side so a
# worker doesn't refuse a legitimate scope trim.
assert_contains "$fix_checks_path" \
  "This is a widening, not a scope narrowing" \
  "the worker-side rule preserves legitimate scope narrowing"

echo
echo "== (5) 2e is not a revival of #1278's rejected downstream suppression"

# #1278 considered and rejected gating auto-merge on "did an earlier classifier
# denial happen this dispatch" — a check downstream of two rules that would both
# have had to fail first. That rejection stands, and 2e must be distinguishable
# from it or a future reader treats one of the two as an error.
assert_contains "$dont_path" \
  "A worker-internal classifier denial does not get a separate auto-merge-suppression mechanism" \
  "#1278's rejection of the downstream suppression check is still recorded"

assert_contains "$dispatch_path" \
  "that would have fired only after two upstream rules had both failed; this fires where the misroute is authored" \
  "2e distinguishes itself from the rejected downstream-suppression shape"

assert_contains "$rationale_path" \
  "whereas 2e sits at the exact site where the misroute is authored" \
  "RATIONALE reconciles 2e with #1278's rejection"

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d assertion(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d assertion(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
