#!/usr/bin/env bash
# Test: the `awaiting-external` terminal worker return, the orchestrator-owned
# `awaiting_external` park queue, and the bound on the wait — issue #1390.
#
# Background
# ----------
# A worker whose task legitimately cannot finish until a long external job it
# already started (a dispatched CI run, a self-hosted E2E suite, an EAS/store
# build, a deploy) reaches a terminal state had NO terminal return that fit.
# `blocked:` means "a human must look" everywhere else in the spec — it routes
# to `needs-human-review`, counts toward the `blocked:ci` cap, and surfaces via
# `/my-turn` — none of which is true for "the answer isn't available yet." So
# the #1390 repro's worker did the only other thing available: it armed a
# `Monitor`, stopped, and got re-invoked, producing four consecutive narrative
# non-terminal returns, each burning an orchestrator reconcile turn and holding
# a dispatch slot, and kept re-arming even after an explicit orchestrator
# SendMessage told it to stand down. It had to be TaskStopped and reaped
# despite being healthy and correct.
#
# The refusal to return `blocked:` was NARROWLY CORRECT — which is what makes
# this a spec gap rather than a one-off model miss. The fix is a new terminal
# shape modelled on fix-checks-only's `pending #<M>` return (#985/#987), the
# closest existing precedent: explicitly honest, terminal, and NOT counted
# against any cap.
#
# The four parts of the fix, and where each is asserted below:
#
#   1. The terminal return shape, in the shared worker vocabulary and the
#      structured schema                                   -> sections (1), (2)
#   2. The orchestrator-owned `awaiting_external` queue (a subagent's Monitor
#      dies with it — the orchestrator is the long-lived process)
#                                                          -> sections (3), (4)
#   3. A bound on the wait, degrading to a genuine `blocked:` hand-back on
#      expiry so a wedged runner pool can't strand a session
#                                                          -> sections (5), (6)
#   4. SendMessage-resume of the original agent preferred over a cold
#      re-dispatch, to keep its context                    -> section (4)
#
# Plus the security property the design requires but the issue didn't name:
# the orchestrator EXECUTES a worker-supplied probe string, and a worker's
# context legitimately contains untrusted issue bodies. Section (7) exercises
# scripts/validate-awaiting-external-probe.sh as live behavior (not a content
# assertion) since it is the executable source of truth for that allowlist.
#
# Mixed spec-content assertions + real script execution. Run with:
#   bash plugins/shipyard/scripts/tests/awaiting-external-1390.test.sh
#
# File-level SC2016 waiver: nearly every needle below is a LITERAL markdown or
# shell fragment (backticked spans, `$(...)` probe strings the validator must
# reject) that has to reach grep/the validator unexpanded. Single quotes are
# correct here, not a mistake.
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
skill_path="$plugin_root/skills/worker-preamble/SKILL.md"
fragment_path="$plugin_root/skills/worker-preamble/awaiting-external.md"
schema_path="$plugin_root/schemas/worker-return.schema.json"
steady_path="$plugin_root/commands/do-work/steady-state.md"
drain_path="$plugin_root/commands/do-work/drain.md"
dont_path="$plugin_root/commands/do-work/dont.md"
dispatch_path="$plugin_root/commands/do-work/dispatch-rules.md"
state_file_path="$plugin_root/commands/do-work/session-state-file.md"
invariant_path="$plugin_root/commands/do-work/invariant-line.md"
do_work_path="$plugin_root/commands/do-work.md"
config_defaults_path="$plugin_root/scripts/shipyard-config.sh"
config_schema_path="$plugin_root/schemas/shipyard.config.schema.json"
session_state_path="$plugin_root/scripts/session-state.sh"
classify_path="$plugin_root/scripts/classify-blocked-bail.sh"
validator="$plugin_root/scripts/validate-awaiting-external-probe.sh"
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

assert_not_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    forbidden string still present in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  fi
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected: %s\n    actual:   %s\n' "$expected" "$actual"
    fail=$((fail+1))
  fi
}

# probe_verdict <command> -> prints "ok" or the leading token of the rejection
probe_verdict() {
  bash "$validator" "$1" 2>/dev/null | head -1
}

# probe_exit <command> -> prints the validator's exit status
probe_exit() {
  bash "$validator" "$1" >/dev/null 2>&1
  echo "$?"
}

echo "awaiting-external park contract (issue #1390)"
echo

# ---------------------------------------------------------------------------
# (1) Part 1 — the terminal return shape exists in the SHARED worker
#     vocabulary, not bolted onto one mode. The #1390 repro was issue-work,
#     but the same gap exists in every mode that can dispatch an external job
#     (fix-main-ci re-running a workflow, spike waiting on a build), so the
#     rule lives in worker-preamble with a full on-demand fragment.
# ---------------------------------------------------------------------------
echo "-- (1) shared worker return vocabulary"
assert_contains "$skill_path" 'awaiting-external #<N>: <what> (<probe-command>, eta <duration>)' \
  "SKILL.md documents the free-text awaiting-external return shape"
assert_contains "$skill_path" "NOT a human hand-back the way \`blocked:\` is" \
  "SKILL.md states awaiting-external is not a blocked-style human hand-back"
assert_contains "$skill_path" "#1390" \
  "SKILL.md's awaiting-external bullet cites the originating issue"
assert_contains "$skill_path" '[`awaiting-external.md`](./awaiting-external.md)' \
  "SKILL.md's core bullet points at the on-demand fragment"

# The fragment is where a worker that actually needs the token goes, so it
# carries the load-bearing detail: the preconditions, the misuse table (the
# guard against using this to dodge the return contract), and resume rules.
assert_contains "$fragment_path" "The four preconditions — all must hold" \
  "fragment states the preconditions as a hard gate, not guidance"
assert_contains "$fragment_path" "commit-before-yield invariant" \
  "fragment requires committed+pushed work before parking (#1054 invariant)"
assert_contains "$fragment_path" "No background process is left armed" \
  "fragment forbids parking while a Monitor/background watcher is still armed"
assert_contains "$fragment_path" "When you may NOT use it" \
  "fragment carries an explicit misuse table"
assert_contains "$fragment_path" "verification did not complete within budget" \
  "fragment routes a long LOCAL suite to the #1135 blocked phrase, not to a park"
assert_contains "$fragment_path" "that IS the human hand-back" \
  "fragment routes a genuine human-decision blocker back to blocked:"
assert_contains "$fragment_path" "Do not park again on the same job" \
  "fragment forbids re-parking on the same job (the spin this return replaces)"

# ---------------------------------------------------------------------------
# (2) The structured (Workflow-substrate) half of the same vocabulary. The
#     schema and its hand-maintained JS mirror must agree — that parity is
#     enforced separately by check-worker-return-schema-parity.mjs, but the
#     token's PRESENCE in both, and the conditional-required rule that stops a
#     park arriving without a probe, are this issue's contract.
# ---------------------------------------------------------------------------
echo
echo "-- (2) structured return schema"
assert_contains "$schema_path" '"awaiting-external"' \
  "worker-return.schema.json's outcome enum carries awaiting-external"
assert_contains "$schema_path" '"awaiting_what"' \
  "schema declares awaiting_what"
assert_contains "$schema_path" '"awaiting_probe"' \
  "schema declares awaiting_probe"
assert_contains "$schema_path" '"awaiting_eta"' \
  "schema declares awaiting_eta"
assert_contains "$schema_path" '"then": { "required": ["awaiting_what", "awaiting_probe"] }' \
  "schema REQUIRES what+probe on an awaiting-external outcome (a park with no probe is unpollable)"


assert_contains "$fragment_path" 'pending #<M>: <n> check(s) still running' \
  "fragment names fix-checks-only's pending return as the precedent it models"

# ---------------------------------------------------------------------------
# (3) Part 2 — the queue is ORCHESTRATOR-owned. This is the root-cause fix:
#     a subagent's Monitor dies with the subagent, which is why the repro's
#     worker kept re-arming one. The reconcile branch must park the entry,
#     release the slot, and — the non-obvious part — RETAIN the worktree, since
#     reaping it would make the part-4 resume impossible.
# ---------------------------------------------------------------------------
echo
echo "-- (3) orchestrator-owned queue + reconcile branch"
assert_contains "$steady_path" "awaiting-external #<N>" \
  "steady-state.md A.1 has an awaiting-external reconcile branch"
assert_contains "$steady_path" "do **NOT** apply \`needs-human-review\`" \
  "the reconcile branch forbids the needs-human-review hand-back"
assert_contains "$steady_path" "do **NOT** count it toward the \`blocked:ci\` cap" \
  "the reconcile branch forbids charging the blocked:ci cap"
assert_contains "$steady_path" "**Do NOT re-enqueue \`#<N>\` anywhere.**" \
  "the reconcile branch keeps the parked issue out of the dispatchable queues"
assert_contains "$steady_path" "but do NOT reap the worktree" \
  "the reconcile branch retains the worktree so the agent can be resumed in place"
assert_contains "$steady_path" "[awaiting-external]" \
  "the reconcile branch emits a greppable log token"

# A.0.5's whole framing is "crashed or narrating". A deliberately parked worker
# looks superficially identical (a live worktree, no further progress coming)
# and the reap is irreversible — so the distinction is called out explicitly,
# which is #1390's last acceptance criterion.
assert_contains "$steady_path" "A deliberately parked worker is not a crashed one" \
  "A.0.5 distinguishes a deliberate park from a crash (#1390 acceptance criterion)"
assert_contains "$steady_path" '- `awaiting-external` (every mode except fix-checks-only' \
  "A.0.5's terminal-prefix list recognizes awaiting-external"

# The queue is real, mirrored session state — not orchestrator working memory —
# because the termination assertion has to be able to see it.
assert_contains "$session_state_path" "awaiting_external: []," \
  "session-state.sh init creates the awaiting_external queue"
assert_contains "$state_file_path" '"awaiting_external"' \
  "session-state-file.md documents the queue in the canonical JSON shape"
assert_contains "$state_file_path" "deliberately NOT reaped while its entry is live" \
  "session-state-file.md records why a parked worker's worktree is retained"
assert_contains "$do_work_path" "**\`awaiting_external\`**" \
  "do-work.md's orchestrator-state roster registers the queue"

# Termination: a parked worker has NOT finished its issue, so a session must
# not declare itself done around one. #1253 made this a one-row change.
assert_contains "$drain_path" '| 7 | `awaiting_external` |' \
  "drain.md's termination-queue registry has an awaiting_external row"
assert_contains "$drain_path" "awaiting_external\` / \`operator_queue\`) is left as-is" \
  "drain-mode collapse names the queue among the skipped rows"

# Visibility: without an invariant-line token a parked worker is invisible on
# every surface an operator watches — which is how the repro's worker got
# killed as if it had hung.
assert_contains "$steady_path" "awaiting_ext=<ae>" \
  "the step-E invariant line carries an awaiting_ext token"
assert_contains "$steady_path" '`awaiting_ext=`' \
  "awaiting_ext is in the step-E mandatory-token presence check"
assert_contains "$invariant_path" '`awaiting_ext=<ae>`' \
  "invariant-line.md documents the awaiting_ext token"
assert_contains "$invariant_path" "Deliberately **excluded** from the" \
  "invariant-line.md excludes parked entries from the under-dispatch queue sum"

# ---------------------------------------------------------------------------
# (4) Parts 2+4 — the poll runs on the orchestrator's EXISTING refresh tick as
#     a one-shot foreground read (never a Monitor — that would recreate the
#     #529/#813 trap one layer up), and a terminal probe prefers resuming the
#     SAME agent over a cold re-dispatch, to keep its context.
# ---------------------------------------------------------------------------
echo
echo "-- (4) step-D sweep + SendMessage-resume preference"
# shellcheck disable=SC2016  # literal markdown needle, deliberately unexpanded
assert_contains "$steady_path" '**`awaiting_external` sweep**' \
  "step D has an awaiting_external sweep sub-step"
assert_contains "$steady_path" "one foreground read, never a background wait" \
  "the sweep is a one-shot foreground poll, not a background wait"
assert_contains "$steady_path" "never open a \`Monitor\`" \
  "the sweep explicitly forbids a Monitor (the failure being fixed, one layer up)"
assert_contains "$steady_path" "preferring \`SendMessage\` to the entry's \`agent_id\` over a cold re-dispatch" \
  "the sweep prefers SendMessage-resume of the original agent (#1390 part 4)"
assert_contains "$steady_path" "MUST carry the probe's terminal output verbatim" \
  "the resume message carries the probe result so the worker does not re-probe"
assert_contains "$steady_path" "Fall back to a cold re-dispatch" \
  "the sweep degrades to a cold re-dispatch when resume is impossible"
assert_contains "$steady_path" "[awaiting-external-resume]" \
  "the resume path emits a greppable log token"

# ---------------------------------------------------------------------------
# (5) Part 3 — THE BOUND. This is a safety property, not a nicety: without it a
#     wedged self-hosted runner pool holds a session open forever. Two details
#     are load-bearing and are asserted individually because either one alone
#     leaves the hole open:
#       - the deadline is checked BEFORE the probe (a wedged job's probe
#         answers "in_progress" forever, so a probe-first order never reaches
#         the expiry branch); and
#       - the deadline is anchored at the FIRST park (otherwise a worker that
#         re-parks on every resume rolls the window forward indefinitely).
# ---------------------------------------------------------------------------
echo
echo "-- (5) the bound on the wait"
assert_contains "$config_defaults_path" '"max_hours": 2' \
  "shipyard-config.sh ships a default bound of 2 hours"
assert_contains "$config_defaults_path" '"awaiting_external": {' \
  "shipyard-config.sh declares the awaiting_external config block"
assert_contains "$config_schema_path" '"awaiting_external": {' \
  "the config schema declares the block (additionalProperties:false makes this mandatory)"
assert_contains "$config_schema_path" '"default": 2,' \
  "the config schema pins the 2-hour default"
assert_contains "$config_schema_path" "never extended by a re-park" \
  "the config schema documents the first-park anchoring"

assert_contains "$steady_path" "**Deadline first.**" \
  "the sweep checks the deadline BEFORE polling"
assert_contains "$steady_path" "**do not poll**" \
  "an expired entry is expired without a further poll"
assert_contains "$steady_path" "a probe-first order would never reach the expiry branch" \
  "the sweep records WHY deadline-before-probe is load-bearing"
assert_contains "$steady_path" "carry the **original** \`deadline_at\` forward unchanged" \
  "a re-park reuses the original deadline rather than recomputing it"
assert_contains "$steady_path" "anchored at the first park precisely so a worker cannot roll the window forward" \
  "the reconcile branch records WHY the deadline is first-park-anchored"
assert_contains "$fragment_path" "anchored at your **first** park and never extended by a re-park" \
  "the worker-facing fragment states the bound and its anchoring"

# ---------------------------------------------------------------------------
# (6) Part 3 (cont.) — expiry degrades to a GENUINE blocked: hand-back. This is
#     the one path by which a park ever reaches a human, and it must classify
#     as `refuse` (needs-human-review): a job that outran the bound means a
#     wedged/starved runner pool, which a retry will not fix. Asserted as live
#     behavior against the classifier, not as prose.
# ---------------------------------------------------------------------------
echo
echo "-- (6) expiry degrades to a real blocked: hand-back"
assert_contains "$steady_path" "**Expired → degrade to a genuine \`blocked:\` hand-back.**" \
  "the sweep degrades an expired entry to blocked:"
assert_contains "$steady_path" "did not reach a terminal state within" \
  "the expiry bail names the still-unfinished job"
assert_contains "$steady_path" "[awaiting-external-expired]" \
  "the expiry path emits a greppable log token"
assert_contains "$classify_path" '*"did not reach a terminal state within"*' \
  "classify-blocked-bail.sh pins the expiry bail as refuse (not soft)"
assert_contains "$classify_path" '*"external wait could not be parked"*' \
  "classify-blocked-bail.sh pins the refused-park bail as refuse"

# The expiry bail must NOT collide with the #1135 soft row ("did not complete
# within budget"), which is a worker running out of ITS OWN budget — transient,
# retryable. An external job that did not move for hours is not.
assert_contains "$classify_path" "did not complete within budget" \
  "the #1135 soft row still exists (the two phrasings must stay distinct)"
assert_not_contains "$steady_path" "awaiting-external: <what> did not complete within budget" \
  "the expiry bail does not borrow the #1135 soft phrasing"

# The disable path: with the feature off, a park is refused rather than
# silently accepted-and-never-polled.
assert_contains "$config_schema_path" "immediately degraded to a \`blocked:\` hand-back" \
  "disabling the feature degrades a park rather than dropping it"
assert_contains "$steady_path" "**Feature gate.**" \
  "the reconcile branch reads the enabled knob before parking"

# ---------------------------------------------------------------------------
# (7) The security property the design requires: the orchestrator EXECUTES a
#     worker-supplied string, repeatedly. A worker's context legitimately holds
#     untrusted issue bodies and comment threads, so the probe is re-validated
#     at the trust boundary against an executable allowlist. Live behavior.
# ---------------------------------------------------------------------------
echo
echo "-- (7) probe validation (live)"
assert_eq "$(probe_verdict 'gh run view 31859829802 --json status,conclusion')" "ok" \
  "accepts the canonical gh run view probe from the #1390 repro"
assert_eq "$(probe_exit 'gh run view 31859829802 --json status,conclusion')" "0" \
  "an accepted probe exits 0"
assert_eq "$(probe_verdict 'gh pr checks 42')" "ok" "accepts gh pr checks"
assert_eq "$(probe_verdict 'eas build:view abc-123')" "ok" "accepts eas build:view"
assert_eq "$(probe_verdict 'vercel inspect https://x.vercel.app')" "ok" "accepts vercel inspect"
assert_eq "$(probe_verdict 'gh api repos/o/r/actions/runs/1')" "ok" "accepts a bare (GET) gh api read"
assert_eq "$(probe_verdict 'gh   run   view   99 --json status')" "ok" \
  "tolerates collapsed interior whitespace"

# Every rejection below is a shape a crafted issue body could plausibly try to
# smuggle through a worker acting as a confused deputy.
assert_eq "$(probe_exit 'gh run view 1; rm -rf /tmp/x')" "1" "rejects command chaining with ;"
assert_eq "$(probe_exit 'gh run view 1 && curl http://evil')" "1" "rejects && chaining"
assert_eq "$(probe_exit 'gh run view 1 | sh')" "1" "rejects a pipe into a shell"
# shellcheck disable=SC2016  # literal needle: the probe must NOT be expanded here
assert_eq "$(probe_exit 'gh run view $(whoami)')" "1" "rejects command substitution"
# shellcheck disable=SC2016  # literal needle: the probe must NOT be expanded here
assert_eq "$(probe_exit 'gh run view `whoami`')" "1" "rejects backtick substitution"
# shellcheck disable=SC2016  # literal needle: the probe must NOT be expanded here
assert_eq "$(probe_exit 'gh run view $HOME')" "1" "rejects variable expansion"
assert_eq "$(probe_exit 'gh run view 1 > /tmp/x')" "1" "rejects output redirection"
assert_eq "$(probe_exit 'gh run view 1 &')" "1" "rejects backgrounding"
assert_eq "$(probe_exit 'curl https://evil.example')" "1" "rejects curl (an exfiltration primitive is not a probe)"
assert_eq "$(probe_exit 'ssh host uptime')" "1" "rejects an unlisted tool"
assert_eq "$(probe_exit 'gh run rerun 1')" "1" "rejects a gh MUTATION dressed as a probe"
assert_eq "$(probe_exit 'gh pr merge 42 --squash')" "1" "rejects gh pr merge"
assert_eq "$(probe_exit 'gh api -X POST repos/o/r/issues')" "1" "rejects a non-GET gh api method"
assert_eq "$(probe_exit 'gh api --method DELETE repos/o/r/x')" "1" "rejects --method DELETE"
assert_eq "$(probe_exit 'gh api repos/o/r -f body=x')" "1" "rejects a gh api request-body field flag"
assert_eq "$(probe_exit 'eas build:cancel abc')" "1" "rejects an eas mutation"
assert_eq "$(probe_exit '')" "1" "rejects an empty probe"
assert_eq "$(probe_exit "$(printf 'gh run view 1\nrm -rf /tmp/x')")" "1" \
  "rejects a multi-line probe"
assert_eq "$(probe_exit 'gh api repos/o/r --method GET')" "0" \
  "an explicit --method GET is still accepted"

# Both sides of the trust boundary must validate — the worker before it hands
# the string over, and the orchestrator before it ever runs it. "The worker
# said it validated" is not evidence.
assert_contains "$fragment_path" "validate-awaiting-external-probe.sh" \
  "the fragment tells the worker to validate its probe before returning it"
assert_contains "$steady_path" "the worker's own validation is not evidence" \
  "the orchestrator re-validates at the trust boundary"
assert_contains "$steady_path" "never edit a rejected probe into an accepted shape on the worker's behalf" \
  "the orchestrator must not launder a rejected probe"
assert_contains "$dont_path" "Don't treat an \`awaiting-external\` return as a crash" \
  "dont.md carries the awaiting-external anti-pattern bullet"

# ---------------------------------------------------------------------------
# (8) Return-vocabulary mirror sites. The vocabulary is duplicated across the
#     dispatch-rules translation table and the per-mode Return-values lines;
#     a token present in the schema but absent from the translation table is a
#     return the reconcile can never see under the Workflow substrate.
# ---------------------------------------------------------------------------
echo
echo "-- (8) mirror sites"
assert_contains "$dispatch_path" '`{outcome:"awaiting-external"' \
  "dispatch-rules.md's structured->free-text translation table has an awaiting-external row"
assert_contains "$dispatch_path" 'awaiting-external main-ci:' \
  "fix-main-ci's Return values line offers the token (synthetic-divert form)"
assert_contains "$dispatch_path" 'awaiting-external pr-pileup:' \
  "fix-failing-prs-batch's Return values line offers the token"
# shellcheck disable=SC2016  # literal markdown needle, deliberately unexpanded
assert_contains "$dont_path" '`reaped`, `awaiting-external`' \
  "dont.md's documented-terminal-prefix list includes awaiting-external"

# The decision record. #1115 declined a superficially-similar `verifying`
# token; without an explicit reconciliation the two decisions read as
# contradictory, and a future reader could "correct" one of them.
assert_contains "$rationale_path" "Why \`awaiting-external\` is safe where \`verifying\` was not" \
  "RATIONALE reconciles this design with #1115's declined verifying token"
assert_contains "$rationale_path" "it is being *sampled*" \
  "RATIONALE names sampling-vs-waiting as the distinction that makes this safe"

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d assertion(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d assertion(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi
