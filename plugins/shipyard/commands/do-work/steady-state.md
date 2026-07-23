# /shipyard:do-work — Steady state (event-driven)

The dispatch loop. The orchestrator wakes when an agent completes; each notification is one turn with the shape `reconcile → release → dispatch (or prove idle) → invariant line`. Held up by [setup](./setup.md) at startup; hands off to [drain → termination](./drain.md) when the **dispatch** queues empty out. An empty dispatch pool ends this loop but is **not** session completion ([#662](https://github.com/mattsears18/shipyard/issues/662)): the drain then **drives the tail** — every session PR to **merged** (or a confirmed external dependency the agent cannot perform) — and the session is complete only when the drain's [full-completion assertion](./drain.md#termination-assertion) holds.

The thin entry [`commands/do-work.md`](../do-work.md) owns the [orchestrator-state struct list](../do-work.md#orchestrator-state) and the [session state file schema](../do-work.md#session-state-file); this file owns the actual steady-state-loop semantics and refresh triggers. The dispatch decision tree consulted by step 7 and step C lives in [`dispatch-rules.md`](./dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) — load it on demand when filling a slot. The browser-operator hooks live in [`operate/04-steady-state-hooks.md`](./operate/04-steady-state-hooks.md#operator-layer-hooks-into-the-steady-state-loop) (this file's A.1 / D steps call into them on every run except under the `--no-operate` / `--hands-off` opt-out — the operator layer is default-on since [#661](https://github.com/mattsears18/shipyard/issues/661)).

## Steady state (event-driven)

When an agent completes, the harness notifies you. Each notification is one orchestrator turn. In that turn:

### Turn contract (read this first, every turn)

Every steady-state turn has the shape `reconcile → [mid-session unblock re-eval] → release → dispatch (or prove idle) → invariant line`. The **last** thing you do every turn is exactly one of:

1. **Issue one or more `Workflow` tool calls** to fill freed slots (the dispatch mechanism for every `mode:`-driven worker — see [dispatch-rules.md's substrate section](./dispatch-rules.md#workflow-substrate-dispatch--the-dispatch-mechanism-for-every-worker-mode-791)), then print the invariant line below the tool call(s).
2. **Print the structured idle-proof line** (defined in step E) showing every queue is empty and every slot is in flight or legitimately parked.

Never end the turn with prose. No "Next: …" narration, no status recap, no "I'll watch for returns and refill" promise. That recap sentence IS the bug — it gives the model a graceful exit from a turn whose dispatch obligation hasn't been met.

### A. Reconcile the return

The agent's last line tells you what happened.

#### A.−1. Reconcile-once gate — skip phantom re-fires (MANDATORY — first thing in the turn)

**This gate is the first thing the orchestrator does on a wake — before A.0's token attribution, before A.1's return-string parsing, before anything else.** Closes [#317](https://github.com/mattsears18/shipyard/issues/317).

The Claude Code harness wakes the orchestrator by wrapping each agent chat-completion message in a `<task-notification>` envelope. After an agent emits its real return text (the line step A.1 parses), it can emit one or more wind-down acknowledgments (`"Done."`, `"Acknowledged."`, `"Monitor task completed."`, etc.) that the harness wraps in **additional** `task-notification` events with the same `task-id` — observed for long-running (>5 min) fix-checks-only and fix-rebase workers on `dowork-20260524T190234-73953`. Each phantom carries `tool_uses: 0`, a tiny `duration_ms` (~1–3 s), a small token delta, and `status: completed`. Without a gate, every phantom triggers a full A → E turn against an already-reconciled agent:

- A.0 double-bumps the per-PR cost ledger.
- A.1 attempts to re-handle a `shipped` / `green` / `blocked` return that was already labeled / commented / branch-reaped on the first turn (idempotent for some sites, not all).
- B re-releases an already-released slot.
- C dispatches a "replacement" worker against a slot that wasn't actually empty.
- D fires another refresh.

**The gate.** Extract the incoming `task-notification`'s `task-id` (the same value that lands in `.in_flight.<slot>.agent_id` on dispatch — the harness uses one id end-to-end). Check `reconciled_agent_ids`:

```bash
incoming_task_id="<task-id from the harness notification>"
if [[ -n "${reconciled_agent_ids[$incoming_task_id]:-}" ]]; then
  echo "[phantom-notification] task-id=$incoming_task_id already reconciled; skipping A.0/A.1/B/C/D this turn (#317)"
  # End the turn HERE — no invariant line, no tool call, nothing else.
  # The phantom notification is harness noise; the orchestrator's working
  # memory and the session-state file are both already correct.
  return
fi
```

The skip is **silent at the user-facing layer beyond the one advisory line** — no invariant line, no dispatch tool call, no session-state write-through. Step E's invariant-line requirement does NOT apply to a phantom-skipped turn (the turn is, by definition, a no-op against state). This is the **one documented exception** to the "every turn ends with either a tool call or the invariant line" rule from the turn contract above.

**Write into `reconciled_agent_ids` at the end of A.1.** Once a return has been parsed and A.1's per-mode handling has run (the `shipped` / `green` / `blocked` / `errored` / `reaped` / `noop` branches all converge here), append the just-reconciled agent's id to the set BEFORE proceeding to step B:

```bash
reconciled_agent_ids[<agent-id>]="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

The timestamp value is informational (it lets a debug pass tell when the agent was first reconciled); only the key's presence is load-bearing for the gate above.

**Why a set instead of a dispatch-time bookkeeping check.** The orchestrator can already infer "this task-id isn't in `.in_flight`" — but that check is ambiguous on phantoms: step B removed the slot at the original reconcile, so `.in_flight` is correctly empty whether the incoming notification is a phantom re-fire OR a real fresh completion the orchestrator forgot about. The set distinguishes the two cases unambiguously: presence ⇒ definitely already handled.

**Why monotone growth is fine.** Sessions complete at most a few hundred dispatches, each with a fixed-size string id. The set's footprint is bounded by the session's total dispatch count, capped by the session ceiling — a few KB at the outer limit. Eviction logic would be more complex than the win.

**Set keying — `agent_id` (the harness `task-id`), not the slot id.** The slot id (e.g. `slot1`) is reused as workers come and go; the agent id is unique per dispatch. Use the agent id so the set survives slot reuse across the session.

**Logging discipline — one line per phantom.** The advisory above (`[phantom-notification] task-id=$incoming_task_id ...`) is the only output the gate produces. Don't add to the line per-phantom; if the same task-id phantoms three times, three identical advisory lines is the correct behavior (the operator can grep + count by id to size the harness noise across a session).

**Cost-tracking interaction.** Phantom notifications carry their own small `<usage>` block. By skipping A.0, the gate intentionally drops those phantom-only tokens from the session ledger. The alternative — bumping with `--issue` / `--pr` scope and the small delta — would double-attribute against PRs that are already finished. The phantom tokens are harness-overhead, not work-attributable; dropping them from per-PR / per-issue buckets is correct. The orchestrator-side overhead bump (the `bump-tokens` call without `--issue` / `--pr`) is similarly skipped — adopting the "harness noise is not the session's cost" stance.

**Failure mode — incoming notification has no parseable `task-id`.** If the wake event genuinely lacks an extractable id (the harness changed shape, the payload is malformed), the safe fallback is to **proceed with A.0** as a real reconcile — phantom-mis-recognition (treating a real return as a phantom) is much more damaging than phantom-as-real (one extra bump-tokens + one extra reconcile attempt against a no-op return). Log `[phantom-notification] could not extract task-id from wake event; treating as real reconcile` and continue.

**Variant — a phantom that carries a *different, still-in-flight* sibling's terminal outcome (MANDATORY pre-skip check — [#530](https://github.com/mattsears18/shipyard/issues/530)).** The pure silent-`return` above is correct only for a **genuine wind-down phantom** — one whose body asserts nothing reconcilable (`"Done."`, `"Acknowledged."`) or names only the already-reconciled target. But the harness has been observed to **cross-wire a still-in-flight sibling worker's only completion notification onto a reaped worker's `task-id`**: the phantom's `task-id` is already in `reconciled_agent_ids`, yet its *body* asserts a terminal outcome (`shipped #<N> via PR #<M>`, `green #<M>`, etc.) for a **different** target that maps to a slot still live in `.in_flight`. Pure-skip there would **strand the in-flight sibling** — its real completion arrived only as this phantom, so the slot would hang unreconciled until end-of-session with no other notification ever coming.

Repro ([#530](https://github.com/mattsears18/shipyard/issues/530), session `do-work-20260611T031912Z-98402`): worker `a20c26426fb3f620a` (#522) returned non-terminal and was reconciled + reaped, landing in `reconciled_agent_ids`. Two later notifications re-fired under that **same** reaped id — but their bodies were the retry's outcome (*"shipped #522 via PR #527"*) and the #523 worker's outcome (*"PR #528 for /my-turn deep links"*). Neither the retry nor the #523 worker ever sent its own notification; their results arrived **only** cross-wired onto `a20c…`. A literal pure-skip would have hung both in-flight slots.

**The pre-skip check.** Before the silent `return`, parse the phantom's body for a terminal return string naming a PR/issue. If it names a target tied to a **currently in-flight** slot (`.in_flight.<slot>` whose `issue` / `pr` matches), do NOT silent-skip — run the [trust-but-verify probe](#dispatch-rules-used-by-step-7-and-step-c) (issue `state` + PR `mergeStateStatus`) for that slot's target, and if ground truth confirms the asserted outcome, **reconcile the in-flight sibling from verified state** (fall through to A.0/A.1 against the in-flight slot's `agent_id`, not the phantom's reaped id) — then write the *sibling's* id into `reconciled_agent_ids`. Only fall through to the silent `return` when the body is a genuine wind-down (asserts nothing reconcilable, or names only the already-reconciled target, or names a target whose ground-truth probe does NOT confirm a terminal outcome):

```bash
if [[ -n "${reconciled_agent_ids[$incoming_task_id]:-}" ]]; then
  # #530: a reconciled task-id can still carry a *sibling's* cross-wired
  # completion. Inspect the body before silently skipping.
  sibling_slot="$(slot_in_flight_matching_phantom_body "$phantom_body")"   # PR/issue named in body ∩ .in_flight target
  if [[ -n "$sibling_slot" ]]; then
    # Trust-but-verify the in-flight sibling's target against GitHub ground truth.
    if ground_truth_confirms_terminal "$sibling_slot"; then
      echo "[phantom-notification] task-id=$incoming_task_id reconciled, but body asserts a terminal outcome for in-flight slot=$sibling_slot; verifying ground truth and reconciling the sibling from verified state (#530)"
      # Reconcile the IN-FLIGHT sibling (its agent_id), NOT the phantom's reaped id:
      # fall through to A.0/A.1 keyed on .in_flight.$sibling_slot.agent_id,
      # then reconciled_agent_ids[<sibling agent_id>]=<ts> at the end of A.1.
      reconcile_in_flight_slot_from_ground_truth "$sibling_slot"
      return   # the sibling's A.0→A.1→B→C→D ran; this turn is no longer a no-op
    fi
    # Ground truth did NOT confirm — treat as a genuine wind-down phantom, skip.
  fi
  echo "[phantom-notification] task-id=$incoming_task_id already reconciled; skipping A.0/A.1/B/C/D this turn (#317)"
  return
fi
```

The verification gate is what keeps this safe: the phantom's *narrative* is untrusted (it's harness-cross-wired text, not a return the orchestrator dispatched), so it only **triggers** a ground-truth probe — it never reconciles on the body's word alone. A phantom whose body names an in-flight target but whose GitHub state does NOT confirm the asserted outcome falls back to the silent skip (the sibling is genuinely still working; its real notification will arrive later). This preserves [#317](https://github.com/mattsears18/shipyard/issues/317)'s double-reconcile protection (the phantom's *own* reaped id is never re-reconciled) while closing the strand-the-sibling hole.

#### A.0. Attribute the dispatch's token usage (MANDATORY — before any return-string parsing)

**This step is not optional.** Before parsing the agent's return string, before any of the per-mode handling below, **attribute the dispatch's token usage to the session ledger**. Without this call, the per-session `.tokens` block, the per-issue / per-PR attribution buckets, the durable PR cost-comment, and the cross-session ledger at `~/.shipyard/cost-history.jsonl` all stay empty — and the perf umbrella ([#152](https://github.com/mattsears18/shipyard/issues/152)) becomes unmeasurable. See [issue #197](https://github.com/mattsears18/shipyard/issues/197) for the regression that prompted this becoming step A.0 instead of a buried mention in the write-through table.

Extract the `usage` payload from the dispatch tool result — the harness emits it as a `<usage>` block in the task-notification message that wakes this turn. The strict-path block has the shape:

```
<usage>
  input_tokens: <int>
  output_tokens: <int>
  cache_read_input_tokens: <int>
  cache_creation_input_tokens: <int>
  total_tokens: <int>
  duration_ms: <int>
</usage>
```

#### A.0 required preamble — cwd-independent session-id derive (MANDATORY — closes [#548](https://github.com/mattsears18/shipyard/issues/548))

**Every A.0 bash call MUST be preceded by this preamble in the same Bash tool call.** The reconcile turn is precisely the turn where the #477 cwd-leak fires (the harness relocates the orchestrator's cwd into the just-returned agent's `agent-*` worktree immediately after the agent completes). A bare `cat .shipyard-session-id` at that point reads from the agent worktree, which has no `.shipyard-session-id` file — the `cat` returns empty, every downstream `session-state.sh` call is invoked with an empty `--session-id` and exits 64 (`--session-id is required`), and the turn silently loses token attribution, the `session_prs` append, and the cost comment (the exact blast-radius documented in [#548](https://github.com/mattsears18/shipyard/issues/548)'s repro from session `do-work-20260612T035752Z-44019`).

The A.0.5 and A.1 reap blocks already carry the `STABLE_DIR` cwd-anchor idiom from [#497](https://github.com/mattsears18/shipyard/issues/497) — but those blocks anchor the **filesystem path** to avoid deleting a cwd that's inside the doomed worktree. This preamble solves the **different problem** of reading the session-id file from the correct (orchestrator) worktree regardless of where the Bash cwd currently is. The two defenses compose: the reap blocks need both (cwd anchor so `git worktree remove` doesn't corrupt the shell, and session-id derive so `worktree-reap.sh reap --session-id` gets the right value); A.0's `bump-tokens` calls need only the session-id derive (no worktree removal involved).

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
# Derive the session id from the NEWEST orchestrator-* worktree's stash.
# cwd-independent given the explicit --repo-root (immune to the #477 cwd-leak
# that fires on reconcile turns). See setup.md §0.55 for the full rationale.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
SESSION_ID=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" derive-session-id \
  --repo-root "$REPO_ROOT" 2>/dev/null)
[ -z "$SESSION_ID" ] && SESSION_ID=$(cat "$REPO_ROOT/.shipyard-session-id" 2>/dev/null)
# Loud abort when both derive paths return empty — cascading exit-64s from
# empty --session-id are silently mis-read as success; a loud log line + skip
# makes the cwd-leak immediately visible in the turn transcript (#548).
if [ -z "$SESSION_ID" ]; then
  echo "[session-id-derive] empty — aborting A.0 turn writes; check for #477 cwd-leak (orchestrator cwd may be inside an agent-* worktree)"
  # Leave tokens_attributed=false; set A05_DISPATCH_TOKENS=0 so A.0.5's
  # wasted-dispatch accounting sees 0 tokens rather than an unbound variable.
  A05_DISPATCH_TOKENS=0
fi
```

Run this preamble block **once per Bash tool call** that contains an A.0 `bump-tokens` invocation — Bash tool calls are hermetic (variables from call N do not survive to call N+1), so each call that needs `SESSION_ID` must re-derive it.

#### Strict path — full input/output/cache breakdown (preferred)

**Pass all four token counts through to `bump-tokens` separately** — never collapse them into `--input <total_tokens>`. Output tokens are priced at 5× input on every Anthropic model the pricing table covers, and `cache_read_input_tokens` are priced at 10% of input. Collapsing the breakdown understates real session cost by 20-50% and makes prompt-cache hit-rate invisible. See [#225](https://github.com/mattsears18/shipyard/issues/225) for the regression that prompted this requirement (the previous spec allowed a "`total_tokens` alone is enough for first-pass attribution" fallback that callers took universally, leaving every per-invocation record with `output: 0` and `cache_*: 0`).

Invoke (after the A.0 required preamble above — `SESSION_ID` is already set):

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
# Guard: skip if preamble failed to derive SESSION_ID (loud log already emitted above).
if [ -n "$SESSION_ID" ]; then
"${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" bump-tokens \
  --session-id "$SESSION_ID" \
  --issue <N>            `# present for issue-work and fix-checks-only on issue-anchored PRs` \
  --pr <M>               `# present for fix-checks-only, fix-rebase, fix-main-ci, fix-failing-prs-batch (and issue-work after it shipped)` \
  --input <input_tokens> \
  --output <output_tokens> \
  --cache-read <cache_read_input_tokens> \
  --cache-creation <cache_creation_input_tokens> \
  --mode <mode> --model <model-id> \
  --allow-degraded-init --degraded-init-repo "<owner/repo>"
fi
```

All four `--input` / `--output` / `--cache-read` / `--cache-creation` flags are **required** on the strict path — pass `0` explicitly if the harness reports the field as missing or zero (rare), don't omit the flag. Both `--issue` and `--pr` are optional from the helper's perspective — pass whichever the dispatch surfaced. `bump-tokens` will route the attribution into `.tokens.totals` always, into `.tokens.per_issue[<N>]` if `--issue` is present, and into `.tokens.per_pr[<M>]` if `--pr` is present.

#### Degraded path — total-only fallback (when the harness `<usage>` block lacks the breakdown)

The strict path requires the harness to emit `input_tokens` / `output_tokens` / `cache_read_input_tokens` / `cache_creation_input_tokens` in the sub-agent `<usage>` block. On some Claude Code harness versions (observed on Opus 4.7, 2026-05-23 — see [issue #279](https://github.com/mattsears18/shipyard/issues/279)) the block only emits **three** fields — `total_tokens`, `tool_uses`, `duration_ms` — with no input/output/cache split. The strict path cannot run; without a fallback, A.0 silently skips attribution session-wide, every cost-tracking comment renders `$0`, and the perf-umbrella ([#152](https://github.com/mattsears18/shipyard/issues/152)) becomes unmeasurable.

When the `<usage>` block has `total_tokens` but no breakdown, fall back to the **degraded path** rather than skipping the bump entirely:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
# Guard: skip if preamble failed to derive SESSION_ID (loud log already emitted above).
if [ -n "$SESSION_ID" ]; then
"${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" bump-tokens \
  --session-id "$SESSION_ID" \
  --issue <N> --pr <M> \
  --input <total_tokens>          `# total_tokens lands in --input; other token flags MUST be omitted` \
  --mode <mode> --model <model-id> \
  --allow-degraded-init --degraded-init-repo "<owner/repo>" \
  --degraded-total-only
fi
```

`--degraded-total-only` is mutually exclusive with non-zero `--output` / `--cache-read` / `--cache-creation` — passing those alongside is rejected with exit 64. It also requires `--input <total_tokens>` to be **non-zero** ([#320](https://github.com/mattsears18/shipyard/issues/320)): `--input 0` is the orchestrator copy-paste trap (pasting the breakdown-fields default into the degraded path and silently recording $0 across every dispatch in the session), and the helper rejects it with exit 64. The bump lands in `.tokens.totals.input` (and the per-issue / per-PR buckets if scoped); the per-invocation entry is stamped `degraded: true`, and `.tokens.degraded_attribution_count` increments by 1 so the [end-of-session summary](./cleanup-summary.md#end-of-session-summary) can surface a banner.

The end-of-session banner [branches on the ratio](./cleanup-summary.md#end-of-session-summary) of `degraded_attribution_count` to `per_invocation.length` ([#295](https://github.com/mattsears18/shipyard/issues/295)). On harness versions where the `<usage>` block structurally never emits the breakdown (Opus 4.7 2026-05-23 was the original repro), every dispatch a session runs will be degraded — the all-degraded banner variant frames that as "this harness path is total-tokens-only" rather than "X of X dispatches went wrong." On harness versions that mix strict and degraded paths within one session, the partial-degraded banner surfaces the per-dispatch ratio so the operator can tell how much of the printed cost is precise vs. lower-bound. The orchestrator does NOT need to compute or pass the ratio at A.0 time — the per-invocation counter and the total invocation count are both already in the session state file by the time cleanup-summary renders.

**Tradeoff — degraded vs. skip.** Routing total_tokens through `--input` under-counts cost: output tokens are priced at 5× input and `cache_read` at 10% of input, so a real dispatch with a 60/30/10 input/cached/output split prices at roughly 1.5× what the degraded fallback computes. The alternative — skipping the bump entirely when the breakdown is missing — produces `$0` on every cost-tracking comment, which the operator reads as "no work happened" rather than "attribution data lost." **Some signal is better than zero signal.** The degraded flag is the explicit marker that the number is a lower bound, and the end-of-session banner makes the gap visible session-wide.

Per #225's no-collapse rule still holds for callers that *have* the breakdown — `--degraded-total-only` is reserved for the case where the harness genuinely doesn't expose the four counts.

**One-line warning on first degraded hit per session.** The first time A.0 falls back to the degraded path in a given session, log a single advisory line:

```
[bump-tokens] <usage> block lacks input/output/cache breakdown — falling back to --degraded-total-only (cost will under-count; #279)
```

**Subsequent degraded bumps in the same session must NOT re-log this advisory** — at `--concurrency 2+` it'd produce one line per dispatch, drowning the steady-state turn output. Track the first-hit-per-session state in orchestrator working memory (a boolean flag — same scope as the `tokens_attributed` flag), set it the first time the path is taken, and skip the log on subsequent degraded bumps. The session-level `.tokens.degraded_attribution_count` in the state file is the durable counter; the one-line log is the operator-visible signal.

The `--allow-degraded-init --degraded-init-repo "<owner/repo>"` pair is **required** on every `bump-tokens` call (closes [#253](https://github.com/mattsears18/shipyard/issues/253)'s cost-tracking workaround). It makes the helper resilient to a file-disappear-mid-session event — if a concurrent `/do-work` session's orphan-sweep reaped this session's state file, the helper auto-recreates a fresh state file marked with `.degraded_recovery_at` and proceeds with the bump rather than erroring exit-3. Cost data from before the disappear is lost, but every bump from the disappear forward lands somewhere durable. Without the flag pair, the orchestrator silently loses cost attribution for every subsequent reconcile turn (the failure mode the workaround fixes).

The `--model` value should be the harness-reported model id verbatim — `bump-tokens` resolves dated suffixes (`claude-haiku-4-5-20251001`) and bare aliases (`opus` / `sonnet` / `haiku`) against the pricing table internally (see #226).

**Set the per-turn `tokens_attributed` flag to `true`** the moment `bump-tokens` returns successfully — step E's invariant line surfaces it for compliance auditing. On a turn where `bump-tokens` errors, leave the flag `false`, log `[bump-tokens] attribution failed: <exit code>; continuing`, and proceed with reconcile anyway. The dollar-cost data point is lost but the dispatch loop keeps moving; the flag's purpose is to make the gap visible, not to gate forward progress.

**If the dispatch had no `usage` payload at all** (the entire `<usage>` block is missing — distinct from the #279 case where the block exists but only carries `total_tokens`; a true full-payload-missing event is much rarer), still proceed to A.1; log `[bump-tokens] no usage payload in dispatch result; skipping attribution` and leave `tokens_attributed=false`. Same don't-block-on-observational-data posture as the helper-error path. The degraded-total-only path above handles the more common case where the block exists but lacks the four breakdown fields.

Once A.0 has fired (or its skip has been logged), proceed to A.0.5.

#### A.0.5. Post-return worktree reap for crashed / narrative-non-terminal returns (fires BEFORE A.1's return-string parsing)

Closes [#358](https://github.com/mattsears18/shipyard/issues/358). The reap path in [step B](#b-release-the-slot) (added in [#334](https://github.com/mattsears18/shipyard/issues/334)) covers every clean completion — but on a **crash return** (the worker's `claude` subprocess died with an API socket error, an internal harness error, or any other abnormal termination), two failure modes can let the worktree linger:

1. The agent's `claude` subprocess **remained alive after the harness reported completion** — observed verbatim in `mattsears18/lightwork` dogfooding session `20260525-191841-15e73`'s `a23a91d566bd9304e` (PR #1277, "API Error: The socket connection was closed unexpectedly" after 17 tool uses; subprocess visible via `ps` for several minutes after the `task-notification`'s `status: completed`). When the lock PID is the still-alive agent subprocess (not the orchestrator), `classify-lock` returns `peer-alive`. (Historical: prior to [#771](https://github.com/mattsears18/shipyard/issues/771), step B's per-completion reap deferred conservatively on this classification, leaving the worktree locked until end-of-session; step B now force-reaps `peer-alive` too, same as this step. A.0.5 still matters independently of that fix — it fires *before* A.1, closing the window sooner, and it performs the crash-specific committed-but-unpushed recovery salvage in the section below, which step B's reap never attempts.)
2. The orchestrator may skim past step B's reap block when the return string is unparseable narrative ("API Error: ...", "Routine progress.", "shard 3/3 passes") — treating the whole turn as "errored, record and continue" without exercising the reap. The spec calls step B's reap unconditional, but the in-context "this turn was a crash, the reconcile path is degenerate" signal can easily override the discipline.

Both failure modes leave the worktree path unreusable for the remainder of the session; the next setup-3b pass at session start eventually reaps, but the cost in the interim is one stuck slot per crash. This step is the in-session safety net: a **crash-aware reap that fires before A.1** explicitly because the agent is non-recoverable and the lingering subprocess (if any) is dead weight — `peer-alive` does not justify deferring on a crash return the way it does on a clean completion.

**Detection — what counts as a crash / narrative-non-terminal return.** The agent's last-line return text fails the terminal-prefix check when it does NOT start with any of:

- `shipped` (issue-work, fix-main-ci, fix-failing-prs-batch happy path)
- `green` (fix-checks-only happy path)
- `noop:` (every mode's benign-no-op variant)
- `blocked` (every mode's deterministic-failure variant)
- `rebased` (fix-rebase happy path)
- `reaped:` (the worker's own "my worktree was reaped" escape hatch from `shipyard:worker-preamble`)

When the return text fails the prefix check, treat it as crash-like and proceed with the reap. Common crash-like shapes:

- `API Error: ...` / `Error: ...` — Anthropic API errors, harness-side errors.
- Empty string / single whitespace — the subprocess died before emitting any final message.
- Narrative status updates (`"Routine progress.", "shard 3/3 passes."`, `"Waiting for monitor..."`) — contract violation per [`shipyard:worker-preamble` § Return-contract discipline](../../skills/worker-preamble/SKILL.md#return-contract-discipline), but observationally indistinguishable from a crash for reap purposes.

**Pre-reap recovery check — save committed and uncommitted work before discarding the worktree ([#493](https://github.com/mattsears18/shipyard/issues/493), [#495](https://github.com/mattsears18/shipyard/issues/495)).** Before reaping a crashed worker's worktree, check whether the worker left any work that hasn't reached `origin` yet. Two cases apply: (a) the worker committed locally but hadn't pushed yet, and (b) the worker's working tree is dirty (edits staged or unstaged, never committed). Either way the worker completed expensive work that a full redo would duplicate. The recovery converts a mid-run stall or watchdog kill from "lose N edits + redo from scratch" into "salvage + push + open PR for the work already done."

**Version-coordination bump during recovery ([#575](https://github.com/mattsears18/shipyard/issues/575)).** When `version_coordination.enabled` is true and a `manifest_path` is configured, the crashed worker may not have reached its own release-bump step (the worker crashes mid-implementation, before adding the manifest version bump + CHANGELOG entry). The recovery path checks whether the manifest version row in the worktree is unchanged from `origin/<default>` — if so, the recovery computes `next_available_version` — **bump-type-aware ([#671](https://github.com/mattsears18/shipyard/issues/671))**, inferring major/minor/patch from the recovered issue's Conventional Commits title/body so a breaking-change or feature issue isn't stamped with a semver-wrong patch — and folds the bump + a minimal CHANGELOG stub into the auto-commit (dirty-worktree path) or as an additional commit (committed-but-unpushed path) before pushing. This guarantees the recovered PR carries the release bump the crashed worker never reached. The bump is **best-effort / fire-and-forget**: if the computation fails (manifest read fails, `jq` missing, coordination disabled), the recovery still pushes the PR as-is and logs a loud `[reconcile-A.0.5-recovery] WARNING: recovered PR has no version bump — manual release bump required` advisory so the operator can patch it before merge. **Non-version-coordinated repos are unaffected** — when `version_coordination.enabled` is false or `manifest_path` is empty, the helper is a no-op and the recovery proceeds exactly as before.

**Recovery semantics, in order:**

1. `git -C <worktree_path> rev-list --count origin/<default>..HEAD` — if the count is **> 0**, the worker committed work that hasn't been pushed; jump to step 1.5. If the count is **0**, no commit landed yet — check whether the working tree is dirty (`git -C <worktree_path> status --porcelain` non-empty). If the working tree is dirty and the branch is `do-work/issue-<N>`, run the version-coordination bump check (step 1.5) to inject the bump into the working tree before staging, then auto-commit all changes with `--no-verify` (the pre-commit gate may be exactly what hung the worker; CI is the real gate) and then push normally (step 2). Log the commit SHA and a `[reconcile-A.0.5-recovery] dirty-worktree auto-commit` prefix. If both `rev-list --count == 0` AND `status --porcelain` is empty, there is no work to recover; proceed directly to the reap.

1.5. **Version-coordination bump check** (fires in both the committed-but-unpushed and dirty-worktree recovery paths, before any push): when `version_coordination.enabled` and a `manifest_path` are configured, compare the manifest version in the worktree's HEAD (or working tree, for the dirty path) against `origin/<default>`'s version. If they match (the worker never reached the bump step), compute the next available version and apply the bump: write the new version into the manifest file using `manifest_version_jq`, then prepend a `### <version> — <YYYY-MM-DD>` stub entry to `changelog_path` (when configured) referencing the recovered issue + PR. For the dirty-worktree path, apply these file edits before `git add -A` so they fold into the auto-commit. For the committed-but-unpushed path, apply these file edits and create an additional bump commit on top of the existing commits before pushing. When the bump can't be computed (manifest read fails, jq absent, version_coordination disabled), skip the bump and log the advisory; recovery continues as before.
2. If count **> 0** (or a dirty-worktree auto-commit just landed), the worker committed at least one commit before crashing. Reaching a commit means either pre-commit hooks passed (the commit is hook-validated) or the recovery committed with `--no-verify` (CI is the safety net). Attempt to push the branch to origin:
   ```bash
   git -C "$worktree_path" push origin "do-work/issue-<N>" 2>&1
   ```
   Log success or failure. If the push fails (network still down, permissions issue, the branch is already on origin ahead of this commit), continue to step 3 rather than reaping silently — a failed push still leaves the local commit recoverable by a human inspection of the worktree before it's removed.
3. After a successful push, check whether an open PR already exists for the branch. If no PR exists, create one using the normal issue-work PR template (`Closes #<N>` keyword, `--label shipyard`, `--auto`). If a PR already exists (the worker pushed but crashed before creating the PR), create the PR against the existing branch. If PR creation fails, log it and proceed to the reap anyway — the commit is now on origin and the branch is recoverable via the GitHub UI.
4. Append the recovered PR number to `session_prs` so the cost-tracking, drain, and end-of-session summary paths all see it as a session-opened PR. Then arm auto-merge **behind the ungated-merge pre-check** ([#720](https://github.com/mattsears18/shipyard/issues/720)) — the same [issue-work §6.a](../../agents/issue-worker/issue-work.md#6-enable-auto-merge-gated-on-originating_author_trust) gate, routed through the one executable detector rather than restated: run [`detect-ungated-admin-direct-merge.sh`](../../scripts/detect-ungated-admin-direct-merge.sh); on `gated` call `gh pr merge <M> --repo <owner/repo> --auto --merge --delete-branch`, and on `ungated` **leave the PR OPEN and unarmed** so [drain's deferred-merge lander](./drain.md#deferred-merge-lander-merge-unarmed-green-session-prs--720) merges it on the first poll its checks are green (the `session_prs` append above is what hands it to the lander). Snapshot `state` and `autoMergeRequest` exactly as step 7 of issue-work.md directs; emit a `[reconcile-A.0.5-recovery] #<N> crash-recovered via PR #<M> (auto-merge: <...>, checks: <...>)` log line.

   **Why this site must gate, and why it must not block.** A crash-recovered PR is the **least-validated diff in the system** — the dirty-worktree path auto-commits with `--no-verify` (the pre-commit gate may be exactly what hung the worker), so CI is quite literally the only thing that ever inspects it. Arming `--auto` on an ungated repo lands that unvalidated diff on the default branch immediately, and because every recovery step is fire-and-forget (`2>/dev/null || true`) it does so **silently**. But this runs on the orchestrator's reconcile hot path, so the worker-style blocking `gh pr checks --watch` is not available — a multi-minute block here stalls every in-flight dispatch. Deferring to drain's lander gates the merge on green without blocking anything.
5. Then proceed to the reap. The recovery does not skip the reap — the worktree is still a crashed agent's directory and needs to be cleaned up.

**Scope: recovery applies to issue-work crash returns only.** The issue number `<N>` and the branch name `do-work/issue-<N>` are both in-flight metadata for issue-work dispatches. Synthetic-divert modes (fix-main-ci, fix-failing-prs-batch) and fix-checks-only / fix-rebase dispatches use different branch-naming conventions and don't have a single issue to recover against — don't attempt recovery for them. Check the in-flight slot's `kind` field (per the [in_flight schema](../do-work.md#orchestrator-state)): if it is not `issue` (the value issue-work dispatches carry), skip the recovery check and proceed directly to the reap. The issue number to recover against is the slot's `target` field.

**Fire-and-forget posture for recovery.** Every recovery step (push, PR-create, auto-merge arm, `session_prs` append) suffixes `2>/dev/null || true` or uses a `|| log_advisory; continue` pattern. A failed recovery step is not a reason to abort the reconcile turn — the reap still happens, the slot still gets released. The recovery is best-effort: if network is still down or the branch is force-pushed over by a concurrent session, the commit may be lost, but the reconcile loop continues intact. Log each recovery step's outcome at `[reconcile-A.0.5-recovery]` prefix so the operator can inspect what happened for each crashed worker.

**The reap.** Derive the worktree path from the slot's `agent_id` (still in `.in_flight.<slot-id>.agent_id` at this point — slot release is step B, which runs later). Classify the lock, then:

- `no-lock` / `dead` / `self-ancestor` → reap normally. Same shape as step B but with `--phase reconcile-A.0.5` so the audit log distinguishes the crash-recovery reap from the per-completion sweep.
- `peer-alive` → **still reap.** (Historically the load-bearing difference from step B's behavior — step B now force-reaps `peer-alive` too, per [#771](https://github.com/mattsears18/shipyard/issues/771) — but this step's own force-reap remains independently load-bearing: it fires *before* A.1/step B even run, closing the window sooner on a crash return.) On a crash return the agent is non-recoverable by definition (the API call failed, the harness already declared completion, the return string is not a contract-compliant terminal). Letting a still-alive subprocess hold the lock until step B's later pass runs is the failure mode #358 documented. The reap fires anyway and the audit-log entry records `classification: "peer-alive"` so the operator can see the override happened. The actual `git worktree unlock` + `git worktree remove --force` will succeed regardless of subprocess state (the lockfile is just metadata; the worktree directory removal proceeds even with a process holding open files inside it — those handles become orphans but don't block the dir removal).

**Skip silently on clean terminal returns** — when the prefix check passes (`shipped` / `green` / `noop:` / `blocked` / `rebased` / `reaped:`), do NOT run this step. Step B's per-completion reap is the right path for clean returns; running A.0.5 too would double-call into `classify-lock` for the common case and waste tool calls. The skip is a no-op — proceed directly to A.1.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
# The agent's last-line return text from the harness notification. The
# orchestrator already has this in working memory for A.1's parse below.
return_text="<the agent's last-line return text, trimmed>"

# Terminal-prefix check — case-insensitive match against the six valid
# prefixes from the per-mode return contracts.
is_terminal=false
case "$return_text" in
  shipped*|green*|noop:*|blocked*|rebased*|reaped:*)
    is_terminal=true
    ;;
esac

if [ "$is_terminal" = "false" ]; then
  # Crash / narrative-non-terminal — fire the reap.
  log_prefix=$(printf '%s' "$return_text" | head -c 80)
  echo "[reconcile-A.0.5] crash-like return for slot=<slot-id> agent=<agent-id>: \"$log_prefix\"; firing post-return reap (#358)"

  completed_agent_id="${.in_flight[<slot-id>].agent_id}"
  wt_dir=".git/worktrees/agent-${completed_agent_id}"
  worktree_path="$(git rev-parse --show-toplevel)/.claude/worktrees/agent-${completed_agent_id}"

  if [ -d "$wt_dir" ]; then
    # Bootstrap the orchestrator PID so classify-lock can short-circuit on
    # our own session's locks (issue #263 — same pattern as A.1/B's reaps).
    export SHIPYARD_ORCHESTRATOR_PID=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" detect-orchestrator-pid)

    classification=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" \
      classify-lock "$wt_dir/locked")

    lock_pid=$(grep -oE '[0-9]+\)' "$wt_dir/locked" 2>/dev/null | tr -d ')' | head -1)
    [ -z "$lock_pid" ] && lock_pid="null"

    # Pre-reap recovery check (#493): before reaping, check whether the
    # crashed worker left committed work that hasn't been pushed yet. This
    # only applies to issue-work dispatches (the slot's kind == "issue")
    # since those are the only ones with a named do-work/issue-<N> branch
    # and a linked issue to recover against. The issue number is the slot's
    # `target` field (per the do-work.md in_flight schema).
    slot_kind="${.in_flight[<slot-id>].kind}"
    slot_issue="${.in_flight[<slot-id>].target}"
    if [ "$slot_kind" = "issue" ] && [ -n "$slot_issue" ] && [ -d "$worktree_path" ]; then
      DEFAULT_BRANCH=$(gh repo view <owner/repo> --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo "main")
      # Fetch so origin/<default> ref is current.
      git -C "$worktree_path" fetch origin "$DEFAULT_BRANCH" 2>/dev/null || true
      ahead_count=$(git -C "$worktree_path" rev-list --count "origin/${DEFAULT_BRANCH}..HEAD" 2>/dev/null || echo "0")

      # ── Version-coordination bump helper (#575) ───────────────────────────
      # Shared logic called by both recovery branches below. Applies the manifest
      # version bump + CHANGELOG stub directly into the worktree's working tree
      # (file edits only — does NOT commit). The caller is responsible for staging
      # and committing (dirty-worktree path folds it into the auto-commit;
      # committed-but-unpushed path adds a dedicated bump commit).
      #
      # Usage: call a05_version_bump "$worktree_path" "$DEFAULT_BRANCH" "$slot_issue"
      # Sets: a05_bump_applied=true|false, a05_bump_version (when applied).
      a05_version_bump() {
        local wt="$1" defbr="$2" issue_num="$3"
        a05_bump_applied=false
        a05_bump_version=""

        # Read coordination config. Fire-and-forget: any failure → skip.
        vc_enabled=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get version_coordination.enabled 2>/dev/null || echo "false")
        [ "$vc_enabled" != "true" ] && return 0

        vc_manifest=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get version_coordination.manifest_path 2>/dev/null || echo "")
        [ -z "$vc_manifest" ] && return 0

        vc_version_jq=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get version_coordination.manifest_version_jq 2>/dev/null || echo ".version")
        vc_changelog=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get version_coordination.changelog_path 2>/dev/null || echo "")

        # Read the manifest version from origin/<default> (the floor).
        origin_version=$(gh api "repos/<owner/repo>/contents/${vc_manifest}?ref=${defbr}" \
          --jq '.content' 2>/dev/null | base64 -d 2>/dev/null | jq -r "$vc_version_jq" 2>/dev/null || echo "")
        if [ -z "$origin_version" ]; then
          echo "[reconcile-A.0.5-recovery] WARNING: recovered PR has no version bump — manual release bump required (could not read origin manifest version for ${vc_manifest})"
          return 0
        fi

        # Read the manifest version from the worktree (HEAD for committed path,
        # working tree file for dirty path — reading the file directly covers both).
        wt_version=$(jq -r "$vc_version_jq" "${wt}/${vc_manifest}" 2>/dev/null || echo "")
        if [ -z "$wt_version" ]; then
          echo "[reconcile-A.0.5-recovery] WARNING: recovered PR has no version bump — manual release bump required (could not read worktree manifest version for ${vc_manifest})"
          return 0
        fi

        # Only bump when the worktree version equals the origin version —
        # i.e., the worker never reached its own bump step. If they differ,
        # the worker already bumped (or partially bumped); don't overwrite.
        if [ "$wt_version" != "$origin_version" ]; then
          echo "[reconcile-A.0.5-recovery] version-bump: worktree already at ${wt_version} (origin=${origin_version}); skipping bump"
          return 0
        fi

        # Infer the release bump LEVEL from the recovered issue's Conventional
        # Commits signals (#671) — the same bump-type-awareness as the
        # dispatch-time next-available-version computation in dispatch-rules.md.
        # A patch-only bump stamps a semver-wrong version on a recovered PR whose
        # issue requires a major (breaking) or minor (feature) release. Best-effort:
        # a failed title/body read falls back to the patch default.
        a05_title=$(gh issue view "$issue_num" --repo <owner/repo> --json title -q .title 2>/dev/null || echo "")
        a05_body=$(gh issue view "$issue_num" --repo <owner/repo> --json body -q .body 2>/dev/null || echo "")
        a05_level="patch"
        printf '%s' "$a05_title" | grep -qiE '^[[:space:]]*feat(\([^)]*\))?[[:space:]]*:' && a05_level="minor"
        if printf '%s' "$a05_title" | grep -qiE '^[[:space:]]*[a-z]+(\([^)]*\))?!:' \
           || printf '%s\n%s' "$a05_title" "$a05_body" | grep -qiE 'BREAKING[ -]CHANGE|major version bump|\(X\.0\.0\)'; then
          a05_level="major"
        fi

        # Compute next_ver = origin_version bumped at the inferred level
        # (major → (X+1).0.0, minor → X.(Y+1).0, patch → X.Y.(Z+1)).
        IFS='.' read -r vc_maj vc_min vc_pat <<< "$origin_version"
        case "$a05_level" in
          major)   next_ver="$((vc_maj + 1)).0.0" ;;
          minor)   next_ver="${vc_maj}.$((vc_min + 1)).0" ;;
          patch|*) next_ver="${vc_maj}.${vc_min}.$((vc_pat + 1))" ;;
        esac

        # Apply the version bump to the manifest file in the worktree.
        # Use jq to rewrite the file in-place (temp-file dance for safety).
        jq_script="$(printf '%s = "%s"' "$vc_version_jq" "$next_ver")"
        tmp_manifest="$(mktemp)"
        if jq "$jq_script" "${wt}/${vc_manifest}" > "$tmp_manifest" 2>/dev/null && [ -s "$tmp_manifest" ]; then
          mv "$tmp_manifest" "${wt}/${vc_manifest}" 2>/dev/null || rm -f "$tmp_manifest"
        else
          rm -f "$tmp_manifest"
          echo "[reconcile-A.0.5-recovery] WARNING: recovered PR has no version bump — manual release bump required (jq write failed for ${vc_manifest})"
          return 0
        fi

        # Prepend a minimal CHANGELOG stub (when changelog_path is configured).
        if [ -n "$vc_changelog" ] && [ -f "${wt}/${vc_changelog}" ]; then
          today=$(date -u +%Y-%m-%d)
          stub="### ${next_ver} — ${today}

Crash-recovered by orchestrator A.0.5 (#575). Worker stalled before completing release bump for issue #${issue_num}. Verify acceptance criteria are met.

"
          # Prepend the stub to the CHANGELOG file (tmp-file dance).
          tmp_cl="$(mktemp)"
          { printf '%s' "$stub"; cat "${wt}/${vc_changelog}"; } > "$tmp_cl" 2>/dev/null \
            && mv "$tmp_cl" "${wt}/${vc_changelog}" 2>/dev/null \
            || rm -f "$tmp_cl"
        fi

        a05_bump_applied=true
        a05_bump_version="$next_ver"
        echo "[reconcile-A.0.5-recovery] version-bump: applied ${origin_version} → ${next_ver} to ${vc_manifest}${vc_changelog:+ and ${vc_changelog}}"
      }
      # ─────────────────────────────────────────────────────────────────────

      if [ "$ahead_count" -gt 0 ] 2>/dev/null; then
        echo "[reconcile-A.0.5-recovery] slot=<slot-id> issue=#${slot_issue} has ${ahead_count} committed-but-unpushed commit(s); attempting pre-reap recovery (#493)"

        # Step 1.5: version-coordination bump (#575). The committed work may
        # not include the manifest bump (worker crashed before reaching it).
        # Apply the bump as an additional commit on top of the existing
        # commits, before pushing. Fire-and-forget: failure logs an advisory
        # and we push the PR anyway so the worker's real work isn't lost.
        a05_version_bump "$worktree_path" "$DEFAULT_BRANCH" "$slot_issue"
        if [ "$a05_bump_applied" = "true" ]; then
          git -C "$worktree_path" add "$vc_manifest" ${vc_changelog:+"$vc_changelog"} 2>/dev/null || true
          git -C "$worktree_path" commit --no-verify \
            -m "chore: release bump ${a05_bump_version} for issue #${slot_issue} (orchestrator A.0.5 recovery #575)" \
            2>/dev/null || true
        fi

        # Step 2: push the branch. Pre-commit hooks already passed (the commit
        # succeeded); this is an orchestrator-side recovery push on a dead
        # agent's branch.
        push_out=$(git -C "$worktree_path" push origin "do-work/issue-${slot_issue}" 2>&1) && push_ok=true || push_ok=false
        echo "[reconcile-A.0.5-recovery] push do-work/issue-${slot_issue}: ok=${push_ok} (${push_out:0:120})"

      elif [ -n "$(git -C "$worktree_path" status --porcelain 2>/dev/null)" ]; then
        # Dirty-working-tree recovery (#495): the worker crashed/stalled before
        # committing, but left edits in the working tree. Stage all changes and
        # commit with --no-verify (the pre-commit gate may be exactly what hung
        # the worker; CI is the real gate for an uncommitted-worktree recovery).
        # This mirrors the #493 committed-but-unpushed path: auto-commit first,
        # then fall through to the shared push+PR-create+auto-merge block below.
        echo "[reconcile-A.0.5-recovery] slot=<slot-id> issue=#${slot_issue} has dirty working tree but no commits; attempting dirty-worktree auto-commit recovery (#495)"

        # Step 1.5: version-coordination bump (#575). Apply the bump to the
        # working tree files before staging so it folds into the auto-commit.
        # Fire-and-forget: failure logs an advisory; the auto-commit proceeds
        # with whatever working-tree files the worker left.
        a05_version_bump "$worktree_path" "$DEFAULT_BRANCH" "$slot_issue"

        git -C "$worktree_path" add -A 2>/dev/null || true
        autocommit_out=$(git -C "$worktree_path" commit --no-verify \
          -m "fix: crash-recovery auto-commit for issue #${slot_issue} (orchestrator A.0.5 #495${a05_bump_applied:+, release bump ${a05_bump_version} #575})" \
          2>&1) && autocommit_ok=true || autocommit_ok=false
        autocommit_sha=$(git -C "$worktree_path" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        echo "[reconcile-A.0.5-recovery] dirty-worktree auto-commit: ok=${autocommit_ok} sha=${autocommit_sha} (${autocommit_out:0:120})"

        if [ "$autocommit_ok" = "true" ]; then
          push_out=$(git -C "$worktree_path" push origin "do-work/issue-${slot_issue}" 2>&1) && push_ok=true || push_ok=false
          echo "[reconcile-A.0.5-recovery] push do-work/issue-${slot_issue}: ok=${push_ok} (${push_out:0:120})"
        else
          push_ok=false
        fi
      fi

      # Shared PR-create + auto-merge block for both committed-but-unpushed
      # (#493) and dirty-worktree auto-commit (#495) recovery paths.
      # push_ok is set by whichever branch above ran; if neither ran (no
      # committed work AND clean working tree) push_ok is unset — guard with
      # a default to avoid an unbound-variable error under set -u.
      push_ok="${push_ok:-false}"
      if [ "$push_ok" = "true" ]; then
          # Step 2: check whether an open PR already exists for this branch.
          existing_pr=$(gh pr list --repo <owner/repo> --state open \
            --head "do-work/issue-${slot_issue}" \
            --json number --jq '.[0].number // empty' 2>/dev/null || true)

          if [ -z "$existing_pr" ]; then
            # No PR yet — create one with the standard issue-work template.
            recovered_pr=$(gh pr create \
              --repo <owner/repo> \
              --head "do-work/issue-${slot_issue}" \
              --label shipyard \
              --title "fix: crash-recovered work for issue #${slot_issue}" \
              --body "$(printf 'Closes #%s\n\n## Summary\nCrash-recovered by orchestrator A.0.5 pre-reap recovery (#493/#495). Worker crashed/stalled before or after committing. CI is the safety net for uncommitted-worktree recoveries.\n\n## Test plan\n- [ ] Verify acceptance criteria from #%s are met\n' "$slot_issue" "$slot_issue")" \
              2>/dev/null) && pr_ok=true || pr_ok=false
            echo "[reconcile-A.0.5-recovery] gh pr create: ok=${pr_ok} pr=${recovered_pr}"
          else
            recovered_pr="$existing_pr"
            pr_ok=true
            echo "[reconcile-A.0.5-recovery] PR #${existing_pr} already open for do-work/issue-${slot_issue}; skipping create"
          fi

          if [ "$pr_ok" = "true" ] && [ -n "$recovered_pr" ]; then
            # Step 3: arm auto-merge and snapshot, exactly as step 6-7 of
            # issue-work.md. Fire-and-forget — recovery must not block reap.
            #
            # #720: gate the arm behind the ungated-merge detector. A recovered
            # PR may have been auto-committed with --no-verify from a dirty
            # worktree, so CI is the ONLY thing that ever validates it. On an
            # ungated repo `--auto` is not a queue — it direct-merges that
            # unvalidated diff immediately, and the `2>/dev/null || true` below
            # makes it silent. Fail-safe: an unreadable verdict resolves to
            # `ungated` (defer), never to an immediate merge.
            verdict=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-ungated-admin-direct-merge.sh" \
              <owner/repo> 2>/dev/null || echo ungated)
            if [ "$verdict" = "gated" ]; then
              gh pr merge "$recovered_pr" --repo <owner/repo> --auto --merge --delete-branch 2>/dev/null || true
            else
              # Leave OPEN + unarmed. The session_prs append below hands it to
              # drain's deferred-merge lander, which merges it once CI is green.
              # Do NOT `gh pr checks --watch` here — this is the reconcile hot
              # path and a block would stall every in-flight dispatch.
              echo "[reconcile-A.0.5-recovery] PR #${recovered_pr} left unarmed (ungated repo) — deferred to drain's merge lander (#720)"
            fi
            # Snapshot state for the log line.
            snap=$(gh pr view "$recovered_pr" --repo <owner/repo> \
              --json state,autoMergeRequest \
              --jq '{state, autoMerge: (.autoMergeRequest != null)}' 2>/dev/null || echo '{}')
            echo "[reconcile-A.0.5-recovery] PR #${recovered_pr} snapshot: ${snap}"
            # Add to session_prs so drain/summary see it.
            session_prs+=("$recovered_pr")
          fi
      fi
    fi

    # Anchor cwd to a stable directory BEFORE the reap (issue #497). The
    # harness can leak the orchestrator's Bash-tool cwd into the very
    # `agent-*` worktree we're about to `git worktree remove --force`; once
    # that directory is gone, EVERY subsequent bare git command in this
    # block (the `prune` below, any follow-up `fetch`/`log`) fails with
    # `fatal: Unable to read current working directory`. `git rev-parse
    # --show-toplevel` can't rescue it either — git resolves its own cwd
    # before reading anything, so it fails first. The fix is to `cd` away
    # from the doomed directory while cwd is STILL valid (here, before the
    # remove). Derive the anchor cwd-independently via the #477 porcelain
    # idiom — orchestrator worktree first, primary (first `worktree ` entry)
    # as fallback — so we never re-derive from the leaked cwd. `cd /` is the
    # last-resort floor (any extant dir works; the reap uses absolute paths).
    STABLE_DIR=$(git worktree list --porcelain 2>/dev/null \
      | awk '/^worktree /{p=substr($0,10)} p ~ /\/\.claude\/worktrees\/orchestrator-/{print p; exit}')
    [ -z "$STABLE_DIR" ] && STABLE_DIR=$(git worktree list --porcelain 2>/dev/null \
      | awk '/^worktree /{print substr($0,10); exit}')
    cd "${STABLE_DIR:-/}" 2>/dev/null || cd /
    # Derive the session id cwd-independently after anchoring to STABLE_DIR.
    # The A.0 preamble may not have run yet in this Bash tool call (A.0.5
    # fires before A.1), so derive fresh here rather than assuming SESSION_ID
    # was set earlier. Closes #548: the reap's --session-id must come from the
    # orchestrator worktree stash, not from a bare `cat .shipyard-session-id`
    # that reads from the (possibly leaked-to-agent) cwd.
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
    SESSION_ID=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" derive-session-id \
      --repo-root "$REPO_ROOT" 2>/dev/null)
    [ -z "$SESSION_ID" ] && SESSION_ID=$(cat "$REPO_ROOT/.shipyard-session-id" 2>/dev/null)
    [ -z "$SESSION_ID" ] && echo "[session-id-derive] empty — A.0.5 reap audit-log entry will lack session-id; check for #477 cwd-leak (#548)"

    # Crash-aware reap: A.0.5 reaps on every classification including
    # peer-alive (step B now does too, per #771, but A.0.5 fires earlier —
    # before A.1/step B even run). The agent is non-recoverable by
    # definition (it crashed or violated the return contract); a
    # still-alive subprocess holding the lock is exactly the failure mode
    # #358 documents, not a signal to wait. The audit-log entry records
    # the actual classification so the override is traceable.
    "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" reap \
      --action reaped \
      --worktree-path "$worktree_path" \
      --worktree-name "agent-${completed_agent_id}" \
      --session-id "${SESSION_ID:-unknown}" \
      --classification "$classification" \
      --lock-pid "$lock_pid" \
      --phase "reconcile-A.0.5" 2>/dev/null || true
    git worktree prune 2>/dev/null || true

    # Wasted-dispatch accounting (#529). A crash-like / narrative-non-terminal
    # return that left NO recoverable work (no committed-but-unpushed branch,
    # no dirty working tree → recovered_pr unset) is a fully-wasted dispatch:
    # the worker armed a background waiter / returned a progress narrative and
    # produced zero output, so this reap fully discards it and step C will
    # re-dispatch the issue from scratch. Surface its cost in the end-of-session
    # summary's `Wasted dispatches (#529)` line rather than absorbing it
    # silently. A return that DID leave recoverable work (recovered_pr set above)
    # produced shippable output and is NOT counted. Tokens come from the A.0
    # attribution already computed for this dispatch.
    if [ -z "${recovered_pr:-}" ]; then
      # ${A05_DISPATCH_TOKENS} is the `total_tokens` the A.0 attribution
      # extracted from this dispatch's <usage> block earlier in the turn
      # (0 if the block was absent — the rarer full-payload-missing case).
      wasted_narrative_dispatches=$(( ${wasted_narrative_dispatches:-0} + 1 ))
      wasted_narrative_tokens=$(( ${wasted_narrative_tokens:-0} + ${A05_DISPATCH_TOKENS:-0} ))
      echo "[reconcile-A.0.5] wasted dispatch (#529): non-terminal narrative, no recoverable work; counted (total now ${wasted_narrative_dispatches})"
    fi
  fi
fi
```

**Fire-and-forget discipline.** Every command suffixes `2>/dev/null` and / or `|| true` so a filesystem race (the worktree was already reaped by a concurrent path, the lock file is gone, etc.) cannot abort the reconcile turn. If the reap silently fails, step B's per-completion sweep is the next safety net and end-of-session cleanup is the ultimate one. The same discipline applies to the pre-reap recovery steps — a failed push or PR-create is logged but never blocks the reconcile turn.

**cwd-anchor-before-reap invariant (issue [#497](https://github.com/mattsears18/shipyard/issues/497)).** Every reap block in this file — A.0.5 here, the [A.1 `shipped`-immediate reap (#282)](#a1-parse-the-return-string), [step B's per-completion reap (#334)](#b-release-the-slot), and [step C 2d's pre-dispatch reap (#368)](#c-dispatch-a-replacement-if-work-remains--mandatory-action) — opens with a `cd "${STABLE_DIR:-/}"` that anchors the shell to a stable directory **before** any `git worktree remove --force` / `git worktree prune` runs. The hazard it closes: the harness can leak the orchestrator's Bash-tool cwd into the very `agent-*` worktree the block is about to remove (the same `isolation: "worktree"` cwd-leak class as [#452](https://github.com/mattsears18/shipyard/issues/452) / [#477](https://github.com/mattsears18/shipyard/issues/477)). Once `git worktree remove --force` deletes that directory, **every** subsequent bare git command in the same block — the `prune`, any follow-up `fetch`/`log` — dies with `fatal: Unable to read current working directory`, silently half-failing the reap (and, on the reconcile turn, skipping the post-merge CI watch — exactly the `merged-direct-ungated` path where that watch matters most). The anchor must be derived **cwd-independently** via the #477 porcelain idiom (`git worktree list --porcelain`'s `orchestrator-*` entry, falling back to the first `worktree ` entry = the primary), and it must run **while cwd is still valid** — i.e., before the remove, not after. Note that `git rev-parse --show-toplevel` can NOT be used to recover a block whose cwd is *already* deleted (git resolves its own cwd before reading anything, so it fails first); the `cd` therefore has to pre-empt the deletion rather than react to it. `cd /` is the last-resort floor — any extant directory works, since the reap itself operates on absolute paths.

**Session-id derive in reap blocks (issue [#548](https://github.com/mattsears18/shipyard/issues/548)).** Each reap block additionally derives `SESSION_ID` cwd-independently *after* the `STABLE_DIR` cd anchor. This is a **separate** concern from the filesystem anchor: the cwd anchor prevents `git worktree remove` from corrupting the shell's cwd; the session-id derive prevents the reap's `--session-id` from coming up empty when cwd leaked to an agent worktree (which has no `.shipyard-session-id` stash). The reap blocks pass `--session-id "${SESSION_ID:-unknown}"` so the audit-log entry still lands (with the `unknown` sentinel visible in the log) even when the derive fails, rather than cascading an exit-64 that reads as silent success.

**Interaction with step B.** Step B still fires on every completion path — A.0.5 does NOT replace it. The duplicate-reap is harmless: the `reap` helper's `git worktree remove --force` against a path A.0.5 already removed is a silent no-op. The point of A.0.5 is to take the reap action *earlier in the turn* on crash-like returns — closing the window sooner than waiting for step B's own pass (which, per [#771](https://github.com/mattsears18/shipyard/issues/771), now also force-reaps `peer-alive` rather than deferring it) — not to remove the per-completion sweep.

**Audit-log shape.** Entries this step writes carry `"phase":"reconcile-A.0.5"` so an operator inspecting `~/.shipyard/reap-audit.jsonl` can distinguish crash-recovery reaps from step B's per-completion sweep (`"phase":"steady-state-B-completion"`), the A.1 shipped-immediate reap (`"phase":"steady-state-A1-shipped"`), the setup-3b stale-worktree pass (no `phase`), and the cleanup-summary end-of-session sweep (no `phase`). Recovery log lines carry `[reconcile-A.0.5-recovery]` prefix (stdout, not the audit JSONL) so a session transcript search surfaces them independently of the reap audit.

Once A.0.5 has fired (or its prefix-check skip has been logged), proceed to A.0.6, then A.1 and parse the return string per the per-mode handling below.

#### A.0.6. Primary-checkout branch-leak guard (fires every reconcile turn, BEFORE A.1)

Closes [#387](https://github.com/mattsears18/shipyard/issues/387). The Claude Code harness `isolation: "worktree"` dispatch path — and/or a dispatched agent operating against the shared `.git` — can **leak a `do-work/*` branch checkout into the user's PRIMARY working tree**, even though the orchestrator runs exclusively in its own `.claude/worktrees/orchestrator-<id>` worktree and never issues a `git checkout do-work/*` against the primary. The primary HEAD reflog from the [#387](https://github.com/mattsears18/shipyard/issues/387) repro shows the leak directly (`checkout: moving from main to do-work/issue-378`, etc.) on a session whose orchestrator only ever ran `git -C <primary> worktree …` / `branch -D` / one corrective `checkout main`.

**Why it matters.** A leaked `do-work/*` checkout on the primary holds git's per-branch lock on that head branch. When [drain](./drain.md) later dispatches a `fix-rebase` worker for a DIRTY PR whose head is that branch, the worker's isolated worktree cannot `git switch <head>` (`"already checked out at <primary>"`) and bails `blocked rebase` — defeating drain's whole purpose (landing DIRTY PRs). It is also a [worktree-isolation contract](./dont.md) violation: the primary is strictly read-only for the whole session, and a leaked checkout moves the primary's HEAD off the default branch — lossless only when the primary tree happens to be clean (luck, not safety).

**The guard.** Root cause is harness behavior shipyard can't change, so this is a defensive assert-and-restore. Fire it every reconcile turn (here) AND at [drain entry](./drain.md#end-of-session-drain). It is **read-mostly**: the common case (primary already on the default branch) costs two `git -C` reads and writes nothing.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"

# The primary checkout is the repo root that contains .claude/worktrees/.
# Derive it INDEPENDENT of cwd (issue #452): `git rev-parse --show-toplevel`
# returns whatever worktree the shell's cwd is in, and the harness can
# silently relocate the orchestrator's cwd into a *dispatched agent's*
# `agent-*` worktree on a reconcile turn (same class of harness env-leak as
# #387/#322/#354, but hitting the orchestrator's own cwd). A cwd-derived
# strip that only handles `orchestrator-*` then leaves PRIMARY_CHECKOUT
# pointing at the agent worktree, and this guard mutates the wrong tree
# while emitting a phantom restore line. `git worktree list --porcelain`'s
# FIRST `worktree ` entry is ALWAYS the primary (the main working tree),
# regardless of which linked worktree the cwd happens to be in — all linked
# worktrees share one worktree list. Fall back to the cwd-strip only if the
# porcelain read comes up empty (non-worktree layout). Read-only `git -C`.
PRIMARY_CHECKOUT="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}')"
if [ -z "$PRIMARY_CHECKOUT" ]; then
  PRIMARY_CHECKOUT="$(git rev-parse --show-toplevel)"
  case "$PRIMARY_CHECKOUT" in
    */.claude/worktrees/orchestrator-*) PRIMARY_CHECKOUT="${PRIMARY_CHECKOUT%/.claude/worktrees/orchestrator-*}" ;;
    */.claude/worktrees/agent-*)        PRIMARY_CHECKOUT="${PRIMARY_CHECKOUT%/.claude/worktrees/agent-*}" ;;
  esac
fi

DEFAULT_BRANCH=$(gh repo view <owner/repo> --json defaultBranchRef -q .defaultBranchRef.name)
PRIMARY_BRANCH=$(git -C "$PRIMARY_CHECKOUT" symbolic-ref --short -q HEAD 2>/dev/null || echo "<detached>")

if [ "$PRIMARY_BRANCH" != "$DEFAULT_BRANCH" ]; then
  # The primary leaked off the default branch. Two cases:
  if [ -z "$(git -C "$PRIMARY_CHECKOUT" status --porcelain 2>/dev/null)" ]; then
    # CLEAN tree → lossless restore. Move it back to the default branch and
    # fast-forward. `--ff-only` can't clobber anything (no local edits exist).
    git -C "$PRIMARY_CHECKOUT" checkout "$DEFAULT_BRANCH" 2>/dev/null \
      && git -C "$PRIMARY_CHECKOUT" pull --ff-only 2>/dev/null || true
    echo "[primary-leak] restored primary from $PRIMARY_BRANCH to $DEFAULT_BRANCH (#387)"
    primary_leak_restores=$((primary_leak_restores + 1))
  else
    # DIRTY tree → do NOT auto-restore. Uncommitted edits on the leaked
    # branch might be real user work; a checkout could strand or clobber it.
    # Surface a loud warning and skip — the operator decides.
    echo "[primary-leak] WARNING: primary checkout is on $PRIMARY_BRANCH (not $DEFAULT_BRANCH) AND has uncommitted changes; NOT auto-restoring (possible real edits). Restore manually with: git -C \"$PRIMARY_CHECKOUT\" checkout $DEFAULT_BRANCH (#387)"
    primary_leak_dirty_skips=$((primary_leak_dirty_skips + 1))
  fi
fi
```

**Counters.** Increment `primary_leak_restores` on a clean restore and `primary_leak_dirty_skips` on a dirty skip — both members of the session-local `primary_leak_counters` map (see the [orchestrator-state struct list](../do-work.md#orchestrator-state)). The [end-of-session summary](./cleanup-summary.md#end-of-session-summary) surfaces the combined friction count when either is non-zero (silent on quiet sessions, per the `ci_session_counters` precedent).

**Read-only against the primary — the one sanctioned exception.** [`dont.md`](./dont.md) forbids *writes* to the primary checkout. A `git -C <primary> checkout <default>` is a write to the primary's HEAD — but it is the **corrective** write that undoes a harness-leaked write, restoring the primary to the read-only-from-shipyard's-perspective state the contract assumes. It fires only when the primary is already off the default branch (the contract is already violated) AND the tree is clean (the restore is provably lossless). The dirty path never writes — it warns and defers to the human. This is the narrow carve-out `dont.md` documents; do not generalize it into "shipyard may move the primary's HEAD."

**Fire-and-forget discipline.** Every command suffixes `2>/dev/null` and / or `|| true` so a filesystem race or a primary checkout that isn't where the path-derivation expects (e.g. a non-standard worktree layout) cannot abort the reconcile turn. If the path derivation produces something that isn't a git repo, the `git -C` reads return empty / error and the guard no-ops.

**cwd-independent derivation (issue [#452](https://github.com/mattsears18/shipyard/issues/452)).** The harness can silently relocate the orchestrator's own Bash-tool cwd into a just-returned **agent's** `agent-*` isolation worktree on a reconcile turn (the same `isolation: "worktree"` env-leak class as [#387](https://github.com/mattsears18/shipyard/issues/387) / [#322](https://github.com/mattsears18/shipyard/issues/322) / [#354](https://github.com/mattsears18/shipyard/issues/354), but hitting the orchestrator's cwd rather than the primary's HEAD). The original derivation read `git rev-parse --show-toplevel` and stripped only an `orchestrator-*` suffix — so when cwd was in an `agent-*` worktree, the strip didn't match, `PRIMARY_CHECKOUT` was left pointing at the **agent** worktree, and the guard read that worktree's `do-work/issue-<N>` branch as the "primary branch," ran `checkout <default>` against the *agent* tree, and emitted a **phantom** `[primary-leak] restored primary …` line while never inspecting the real primary. The fix derives the primary from `git worktree list --porcelain`'s first `worktree ` entry — always the main working tree regardless of which linked worktree the cwd is in (all linked worktrees share one worktree list) — with the cwd-strip retained only as a fallback (now covering `agent-*` as well) for a layout where the porcelain read comes up empty.

Once A.0.6 has run, proceed to A.1.

#### A.1. Parse the return string

**Worker returns are translated into free text before reaching this step, not parsed here directly.** Every `mode:`-driven worker is dispatched through the `Workflow` substrate and returns a **structured** result validated against [`schemas/worker-return.schema.json`](../../schemas/worker-return.schema.json). The dispatch step already converted that structured result into the exact free-text terminal string this step's vocabulary is written against, using [dispatch-rules.md's substrate section](./dispatch-rules.md#workflow-substrate-dispatch--the-dispatch-mechanism-for-every-worker-mode-791)'s translation table (one row per mode/outcome combination). By the time control reaches this step there is exactly one return vocabulary — the free-text one every branch below reads. Don't re-parse the structured object here; the translation already happened. (The translation shim was introduced with [#788](https://github.com/mattsears18/shipyard/issues/788) / [#789](https://github.com/mattsears18/shipyard/issues/789) so the whole reconcile could stay substrate-agnostic during the migration; [#791](https://github.com/mattsears18/shipyard/issues/791) retired the other substrate and kept the shim — the free-text vocabulary remains the reconcile's stable interface.)

For **issue work** (`shipped` / `blocked` / `errored`):

- **shipped #<N> via PR #<M>** — checks may be `green`, `pending`, or `failing`. Record. **Append `<M>` to `session_prs`** (the set the [end-of-session drain](./drain.md#end-of-session-drain) watches). Don't act on `pending`/`failing` here — periodic triage (step D) will catch failures next time it runs.

  **Local-only-CI repos: the merge gate fires at drain, not here ([#643](https://github.com/mattsears18/shipyard/issues/643)).** On a repo where the merge-blocking status is posted by a manually-run command (config `merge_gate.command` non-empty — e.g. `npm run ci:report`) rather than by cloud CI that auto-runs on push, a shipped PR's checks stay `pending` until that command runs against the PR's HEAD. Nothing about the `shipped` reconcile changes — `--auto` is armed exactly as on a cloud-CI repo — but the gate command runs **per shipped PR, paced to `merge_gate.max_unmerged_ahead`, in the [end-of-session drain](./drain.md#local-only-ci-merge-gate)**, which is where `--auto` then fires. When `merge_gate.command` is empty (the default), this is moot — cloud-CI behavior is unchanged.

  **Then post a cost-tracking comment on the resulting PR.** The session-state file's `.tokens.per_pr[<M>]` bucket was populated by every `bump-tokens` call made while the worker was in flight (see [Cost-tracking write-through](../do-work.md#cost-tracking-write-through) below). Read it as a Markdown body via the helper and post on the PR with edit-or-create semantics keyed on the `<!-- do-work-cost-tracking -->` sentinel:

  ```bash
  export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
  # Derive the session id cwd-independently (immune to the #477 cwd-leak that
  # fires on reconcile turns — see A.0 required preamble and setup.md §0.55).
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
  SESSION_ID=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" derive-session-id \
    --repo-root "$REPO_ROOT" 2>/dev/null)
  [ -z "$SESSION_ID" ] && SESSION_ID=$(cat "$REPO_ROOT/.shipyard-session-id" 2>/dev/null)
  if [ -z "$SESSION_ID" ]; then
    echo "[session-id-derive] empty — skipping A.1 cost-comment post; check for #477 cwd-leak (#548)"
  else
  # 1. Read the cost summary as a Markdown comment body.
  BODY=$("${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" read-tokens \
    --session-id "$SESSION_ID" --pr <M> --format comment)

  # 2. Look up the existing sentinel comment (if any) so we can edit
  # in-place instead of posting duplicates each time the cost grows
  # (e.g. across a fix-checks-only follow-up dispatch on the same PR).
  # Use the REST listing endpoint, not `gh pr view --json comments` —
  # the latter returns each comment's GraphQL node-id (e.g.
  # `IC_kwDONOH3Js8AAAAB...`), which the PATCH endpoint below does NOT
  # accept; PATCH requires the numeric REST comment id that
  # `/repos/<o/r>/issues/<M>/comments` returns as `.id`. See #264.
  EXISTING=$(gh api "/repos/<owner/repo>/issues/<M>/comments?per_page=100" \
    --jq '[.[] | select(.body | startswith("<!-- do-work-cost-tracking -->"))][0].id // empty')

  if [ -n "$EXISTING" ]; then
    gh api -X PATCH "/repos/<owner/repo>/issues/comments/$EXISTING" \
      -f body="$BODY" >/dev/null
  else
    gh pr comment <M> --repo <owner/repo> --body "$BODY" >/dev/null
  fi
  fi
  ```

  The hook fires on every `shipped` reconcile — issue-work, fix-main-ci, fix-failing-prs-batch. On a synthetic-divert `shipped main-ci-fix` / `shipped pr-batch-fix` return there's no originating issue, but the PR still gets the comment via the same `read-tokens --pr <M>` slice. For `external`-author PRs that are gated on `needs-human-review`, post the comment regardless — the cost is real whether or not the PR auto-merges. The edit-in-place semantics mean a follow-up fix-checks-only dispatch on the same PR will *update* the existing sentinel comment with the cumulative cost, not stack duplicate comments.

  **Don't post a separate cost comment on the originating issue.** GitHub's auto-close mechanism links the issue to the closing PR; readers click through to the PR to see the cost. Posting on both surfaces double-counts in feed scans and creates two places that have to stay consistent across fix-checks follow-ups. The PR is the single source of truth for this session's cost on the artifact.

  If either `gh` call errors (rate limit, permission denied), log `[cost-comment] PR #<M> post failed: <reason>; continuing` and proceed. Cost-tracking is observational — never block dispatch on a comment-post failure.

  **Then reap the agent's worktree immediately — don't wait for end-of-session cleanup.** Closes [#282](https://github.com/mattsears18/shipyard/issues/282): the worker's local branch `do-work/issue-<N>` and worktree directory lingering until end-of-session cleanup is what locks subsequent same-session fix-rebase dispatches out of `git switch <head>` (git enforces one-worktree-per-branch). Reaping immediately on `shipped` frees the PR's head branch right when the merge train might next want to rebase it. The worker has already returned (this is what `shipped` IS), so its worktree is no-longer-live by definition — the classify-lock pass still runs as defensive belt-and-suspenders, but the expected classification is `dead` (process gone) or `self-ancestor` (lock held the orchestrator's PID per the harness convention).

  **Force-reap even on `peer-alive` here.** (Historical note: this paragraph originally documented a difference from step B's general-purpose reap, which deferred on `peer-alive` at the time — that gap was closed in [#771](https://github.com/mattsears18/shipyard/issues/771); step B now force-reaps identically, so this A.1 path and step B's are consistent, not divergent.) A `shipped` return is the worker's terminal contract: the agent subprocess has exited, the PR is on the remote, the worktree has no further purpose. The `peer-alive` classification at this call site means the lock PID is some process that the orchestrator's SHIPYARD_ORCHESTRATOR_PID bootstrap (above) did not short-circuit to `self-ancestor` — most likely a transient harness subprocess that was still alive milliseconds after the agent returned. Deferring on `peer-alive` here causes the very drain-phase `blocked: branch locked in another worktree` failures documented in [#576](https://github.com/mattsears18/shipyard/issues/576): the A.1 defer leaves the worktree locked, the drain's pre-dispatch reap checks the same classification and also defers, and the fix-checks / fix-rebase worker bails. Force-reap closes the window by applying the same posture A.0.5 uses for crash returns (see [§A.0.5](#a05-post-return-worktree-reap-for-crashed--narrative-non-terminal-returns-fires-before-a1)): when the terminal return string is in hand, the agent is non-recoverable by definition, and the `peer-alive` classification does not justify keeping the head branch locked. Audit the reap with `--classification peer-alive-force` so the override is visible in `~/.shipyard/reap-audit.jsonl`.

  ```bash
  export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
  # Anchor cwd to a stable directory BEFORE the reap (issue #497). The
  # harness can leak the orchestrator's cwd into an `agent-*` worktree that
  # this block then `git worktree remove --force`s; once that dir is gone,
  # the `git worktree prune` below (and any follow-up git command) fails
  # with `fatal: Unable to read current working directory`. The old
  # `cd "$(git rev-parse --show-toplevel)"` could NOT rescue it — git
  # resolves its own (deleted) cwd before reading anything, so the
  # rev-parse fails first and the cd is a no-op. Derive the anchor
  # cwd-independently via the #477 porcelain idiom (orchestrator worktree
  # first, primary as fallback) while cwd is still valid here, then cd to
  # it so the remove/prune never run with cwd inside the doomed directory.
  STABLE_DIR=$(git worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{p=substr($0,10)} p ~ /\/\.claude\/worktrees\/orchestrator-/{print p; exit}')
  [ -z "$STABLE_DIR" ] && STABLE_DIR=$(git worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{print substr($0,10); exit}')
  cd "${STABLE_DIR:-/}" 2>/dev/null || cd /
  # Derive the session id cwd-independently while STABLE_DIR is still valid.
  # After `cd "${STABLE_DIR:-/}"` the cwd is either the orchestrator worktree
  # or the primary checkout — both are safe anchors for the derive helper.
  # This closes #548: the reap's --session-id must not read from the (possibly
  # leaked-to-agent) cwd; it must read from the orchestrator worktree stash.
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
  SESSION_ID=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" derive-session-id \
    --repo-root "$REPO_ROOT" 2>/dev/null)
  [ -z "$SESSION_ID" ] && SESSION_ID=$(cat "$REPO_ROOT/.shipyard-session-id" 2>/dev/null)
  [ -z "$SESSION_ID" ] && echo "[session-id-derive] empty — reap audit-log entries will lack session-id; check for #477 cwd-leak (#548)"
  # PRIMARY is the first `worktree ` entry — the .git/worktrees walk below
  # needs the primary's path (linked worktrees share the common .git dir).
  PRIMARY_CHECKOUT=$(git worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{print substr($0,10); exit}')
  # Locate the agent worktree whose branch is do-work/issue-<N>. Walk
  # .git/worktrees/agent-* and match on the HEAD ref. Same idiom as the
  # concurrent-session guard further down in step C.
  # Bootstrap the orchestrator PID so classify-lock can short-circuit
  # on our own session's locks (issue #263).
  export SHIPYARD_ORCHESTRATOR_PID=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" detect-orchestrator-pid)

  for wt_dir in "${PRIMARY_CHECKOUT}/.git/worktrees"/agent-*; do
    [ -d "$wt_dir" ] || continue
    branch_ref=$(cat "$wt_dir/HEAD" 2>/dev/null | sed 's|ref: refs/heads/||')
    [ "$branch_ref" = "do-work/issue-<N>" ] || continue

    name=$(basename "$wt_dir")
    worktree_path=$(git worktree list | awk -v n="$name" '$0 ~ n {print $1; exit}')
    [ -z "$worktree_path" ] && continue

    classification=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" \
      classify-lock "$wt_dir/locked")

    # Extract the lock PID for the audit log (best effort; null literal
    # when the lock file is missing or unparseable). Same pattern as
    # cleanup-summary.md's reap loop.
    lock_pid=$(grep -oE '[0-9]+\)' "$wt_dir/locked" 2>/dev/null | tr -d ')' | head -1)
    [ -z "$lock_pid" ] && lock_pid="null"

    # no-lock / dead / self-ancestor / peer-alive — all safe to reap here.
    # A `shipped` return is the worker's terminal contract; the agent is
    # done by definition. Unlike step B's general-purpose reap (which
    # conservatively defers on peer-alive for unknown return shapes),
    # this call site KNOWS the worker has exited and its worktree has no
    # further purpose. Force-reap on peer-alive mirrors A.0.5's posture
    # for crash returns and closes the #576 drain-phase bail window:
    # a peer-alive defer here leaves the head branch locked, and the
    # drain pre-dispatch reap's own peer-alive defer then also misses it,
    # causing fix-checks/fix-rebase to bail "branch locked in another
    # worktree." Audit with classification "peer-alive-force" so the
    # override is traceable in ~/.shipyard/reap-audit.jsonl. (#576)
    local_classification="$classification"
    [ "$classification" = "peer-alive" ] && local_classification="peer-alive-force"
    # The `reap` helper performs the `git worktree unlock` +
    # `git worktree remove --force` AND writes the audit-log line in
    # one transaction (issue #284).
    "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" reap \
      --action reaped \
      --worktree-path "$worktree_path" \
      --worktree-name "$name" \
      --session-id "${SESSION_ID:-unknown}" \
      --classification "$local_classification" \
      --lock-pid "$lock_pid" \
      --phase "steady-state-A1-shipped" 2>/dev/null || true

    # Drop the local branch ref so a same-session fix-rebase dispatch
    # can recreate `do-work/issue-<N>` cleanly via `git switch` without
    # tripping the "branch already exists in another worktree" check.
    # `-D` (force) rather than `-d` because the branch may have unmerged
    # commits relative to current local main — the canonical record is
    # on origin, not this branch.
    git branch -D "do-work/issue-<N>" 2>/dev/null || true
    break   # at most one match per issue number
  done
  git worktree prune 2>/dev/null || true
  ```

  The reap and local-branch drop are **fire-and-forget** — every command suffixes `2>/dev/null` and / or `|| true` so a filesystem race (the worktree was already reaped by a concurrent path, the lock file is gone, etc.) cannot abort the steady-state loop. If the reap silently fails for any reason, end-of-session cleanup is still the safety net. The end-of-session pass is intentionally NOT removed — it remains the ultimate sweep for any agent worktree that this immediate-reap path missed (blocked / errored returns, etc.).

  **Audit-log shape.** The JSONL entries this step writes carry `"phase":"steady-state-A1-shipped"` so an operator inspecting `~/.shipyard/reap-audit.jsonl` can distinguish steady-state reaps from end-of-session reaps (which omit `phase` — see [`cleanup-summary.md`'s reap loop](./cleanup-summary.md#end-of-session-cleanup)). The `phase` suffix is appended by the `reap` helper natively (issue #284).

- **reaped: my worktree was reaped while I was running** — the worker's worktree was torn down mid-run by the cleanup logic. This is external-infrastructure noise, NOT a logic failure. **Do NOT add `blocked:agent`.** Instead:
  1. Log the event: `[reap-recovery] #<N> worktree reaped mid-run (last push: <hash>); re-enqueuing for fresh dispatch.`
  2. Re-add `<N>` to `raw_backlog` (deduped; if already in `ready_issues` or `in_flight`, skip — the issue is already being handled). The next dispatch cycle will pick it up with a fresh worktree.
  3. Remove the `@me` assignee so the fresh dispatch's self-assign soft-lock works: `gh issue edit <N> --repo <owner/repo> --remove-assignee @me 2>/dev/null || true`
  4. Look for a `<!-- shipyard-worker-progress -->` comment on the issue (the worker may have posted incremental findings before the reap). If found, include its URL in the `[reap-recovery]` log entry so the next dispatch worker can read it at step 2 in issue-work.md.

- **blocked #<N>** — comment on the issue summarizing the blocker, then classify the bail per the table below and route it to the mechanism that fits. Closes [#521](https://github.com/mattsears18/shipyard/issues/521) — eliminates the `blocked:agent-hard` label, splitting its two semantically-distinct populations by the **presence of an open `Blocked by #N` reference in the bail** (the same discriminator `/my-turn`'s [#500](https://github.com/mattsears18/shipyard/issues/500) split uses): a **refuse** (security / scope / prompt-injection / conservative-default, no open blocker ref → no automated path, a human must look) routes to `needs-human-review`; a **dependency-wait** (the bail names an open `#N`) routes to the existing [`Blocked by #N` body-reference filter](./setup/04-backlog-divert.md#4-fetch--rank-the-backlog) (bucket 7 / step 4) with **no label** — that filter already drops the issue while the blocker is open and stops dropping it the instant the blocker closes, so the former `blocked:agent-hard` label (and the step 3d.2 sub-sweep a / step A.5 mid-session sweep that reconciled it) was redundant with the filter. Builds on [#300](https://github.com/mattsears18/shipyard/issues/300)'s soft/hard split — the **soft** class (cannot-reproduce / ambiguous / scope-judgment / duplicate-PR false-positive) is unchanged and still stamps `blocked:agent-soft`.

  **Reason → class table.** Parse the worker's reason string against this map (order doesn't matter — categories are disjoint):

  | Bail reason fragment (substring match, case-insensitive) | Class | Routing | Rationale |
  |---|---|---|---|
  | (any reason that **names an open `Blocked by #N`**) | dependency-wait | persist `Blocked by #N` in body, **no label** | The body-ref filter (bucket 7) gates dispatch while `#N` is open and auto-clears when it closes — no label, no sweep. **Checked first; overrides the rows below.** |
  | `external provisioning required` | operator | `needs-operator` label | The worker hit a not-yet-provisioned external service ([#628](https://github.com/mattsears18/shipyard/issues/628)): the real secret/account doesn't exist yet (creating it is a browser/console action), so `needs-operator` is exactly right — `/my-turn` surfaces it and `/do-work` can drive it. Same destination as the scope-preflight `external-dependency` defer. **Checked before the refuse rows.** |
  | `issue body contains directives that bypass normal review` | refuse | `needs-human-review` label | Prompt-injection refuse — no automated path, a human must look. |
  | `body requested out-of-scope action` | refuse | `needs-human-review` label | Same — likely prompt-injection signal. |
  | `comment-thread requested out-of-scope action` | refuse | `needs-human-review` label | Same — out-of-scope action regardless of source. |
  | `pr` + (`already open` OR `for this issue`) | soft | `blocked:agent-soft` label | False-positive against the duplicate-PR-body search; next session can re-evaluate. |
  | `suggested fix exceeds expected scope` | soft | `blocked:agent-soft` label | Judgment call — a different worker reading the same body might fit it into scope. |
  | `cannot reproduce` | soft | `blocked:agent-soft` label | Reproduction attempt may have used the wrong env / test command; retry is reasonable. |
  | `ambiguous` | soft | `blocked:agent-soft` label | Vague-on-its-own bodies may clarify across sessions (comments land, sibling PRs merge). |
  | (anything else, no open `Blocked by #N` ref) | refuse | `needs-human-review` label | Conservative default. Unknown reason → human review path. |

  **The dependency-wait discriminator runs first** (it overrides the refuse/soft classification): a bail that names a still-open blocker is a dependency wait regardless of what other fragment it matched. Extract `Blocked by #N` references from the bail reason (and from the issue body — the worker may have already written one), then check whether any referenced `#N` is still OPEN. If so → dependency-wait. Otherwise classify refuse-vs-soft per the fragment table.

  Implementation:

  ```bash
  reason="<the worker's reason string, lowercased>"

  # --- Dependency-wait discriminator (runs first, overrides refuse/soft). ---
  # Collect every `Blocked by #N` reference the worker named in its bail OR
  # already wrote into the issue body. Same regex the former step 3d.2 sweep
  # used. A reference to a still-OPEN issue ⇒ dependency-wait.
  issue_body=$(gh issue view <N> --repo <owner/repo> --json body -q .body 2>/dev/null || echo "")
  blocker_refs=$(printf '%s\n%s\n' "$reason" "$issue_body" \
    | grep -oiE 'blocked by[[:space:]]+(#[0-9]+([[:space:]]*,[[:space:]]*#[0-9]+)*)' \
    | grep -oE '#[0-9]+' | tr -d '#' | sort -u)

  has_open_blocker=false
  open_blocker=""
  for b in $blocker_refs; do
    state=$(gh issue view "$b" --repo <owner/repo> --json state -q .state 2>/dev/null \
      || gh pr view "$b" --repo <owner/repo> --json state -q .state 2>/dev/null \
      || echo "")
    case "$state" in
      OPEN) has_open_blocker=true; open_blocker="$b"; break ;;
    esac
  done

  if $has_open_blocker; then
    # --- Dependency-wait subset → NO label; ensure the body persists the ref. ---
    # The bucket-7 / step-4 body-reference filter drops the issue while #N is
    # open and re-admits it automatically when #N closes. The worker normally
    # writes the `Blocked by #N` line itself; guarantee it's in the BODY (not
    # just a comment) so the filter — which reads the body — can see it.
    if ! printf '%s' "$issue_body" | grep -qiE "blocked by[[:space:]]+#${open_blocker}\b"; then
      gh issue edit <N> --repo <owner/repo> \
        --body "Blocked by #${open_blocker}

${issue_body}" 2>/dev/null || true
    fi
    gh issue comment <N> --repo <owner/repo> --body "Worker returned blocked: <reason>. Dependency-wait on #${open_blocker}; no label applied — the \`Blocked by #N\` body-reference filter gates dispatch and auto-clears when #${open_blocker} closes."
  elif printf '%s' "$reason" | grep -qi "external provisioning required"; then
    # --- Operator subset → needs-operator (#628). ---
    # The worker hit a not-yet-provisioned external service: the real
    # secret/account doesn't exist yet, and creating it is a browser/console
    # operator action — not a human *decision* and not auto-recoverable. Route
    # to needs-operator so /my-turn surfaces it and /do-work can
    # drive it (same destination as the scope-preflight external-dependency
    # defer). Ensure-then-label, since step 3a's create is best-effort.
    gh label create needs-operator --repo <owner/repo> \
      --description "Needs a browser/console operator action — a human, or /do-work via the extension" \
      --color 1D76DB 2>/dev/null || true
    gh issue edit <N> --repo <owner/repo> --add-label "needs-operator" 2>/dev/null || true
    gh issue comment <N> --repo <owner/repo> --body "Worker returned blocked: <reason>. Classified as \`needs-operator\` — provisioning an external service is a browser/console operator action. Surfaced by \`/my-turn\`; drainable by \`/do-work\`."
  else
    # --- Refuse vs soft, per the fragment table. ---
    block_class="refuse"  # conservative default
    case "$reason" in
      *"issue body contains directives that bypass normal review"*|\
      *"body requested out-of-scope action"*|\
      *"comment-thread requested out-of-scope action"*)
        block_class="refuse"
        ;;
      *"pr #"*"already open"*|*"pr #"*"for this issue"*|\
      *"suggested fix exceeds expected scope"*|\
      *"cannot reproduce"*|\
      *"ambiguous"*)
        block_class="soft"
        ;;
    esac

    if [ "$block_class" = "soft" ]; then
      label="blocked:agent-soft"
      # In-memory soft-block bookkeeping — gates in-session re-dispatch.
      # session_blocked_soft is a {issue_number → ISO-8601 timestamp} map
      # that step C's lightweight backlog re-check reads to skip issues
      # within blocked_agent.soft_retry_minutes of their last bail (default
      # 30 — see ~/.claude/plugins/cache/shipyard/.../scripts/shipyard-config.sh).
      now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      session_blocked_soft[<N>]="$now"
    else
      # Refuse → needs-human-review. No automated path; a human must look.
      label="needs-human-review"
    fi

    gh issue edit <N> --repo <owner/repo> --add-label "$label" 2>/dev/null || true
    gh issue comment <N> --repo <owner/repo> --body "Worker returned blocked: <reason>. Classified as \`$label\`."
  fi
  ```

  **Why a refuse routes to `needs-human-review` instead of a dedicated block label ([#521](https://github.com/mattsears18/shipyard/issues/521)).** A security / scope / prompt-injection refuse has *no automated recovery path* — it's exactly "Claude gave up; a human must actually look," which is the semantics `needs-human-review` already encodes (and which [`/my-turn`](../my-turn.md) already surfaces as a human-action signal). Folding the refuse class onto `needs-human-review` removes the redundant `blocked:agent-hard` label while preserving the worker's reason in the bail comment so the human sees *why* without opening the diff. This advances the [binary-backlog north star](../../../../CLAUDE.md) (#515): every open issue is either workable-by-`/do-work` (no gate label) or workable-by-human (`needs-human-review`).

  **Why a provisioning bail routes to `needs-operator` ([#628](https://github.com/mattsears18/shipyard/issues/628)).** When a worker bails `external provisioning required`, it stopped *before* committing dead config for a service that isn't set up yet (see [issue-work.md step 4.4](../../agents/issue-worker/issue-work.md#44-external-provisioning-guard--dont-commit-dead-config-for-an-unprovisioned-service-628)). The blocker isn't a *decision* (so not `needs-human-review`) and it isn't auto-recoverable (so not a soft retry or a `Blocked by #N` wait) — it's a concrete browser/console action: create the account, grab the credential, drop it in `*.tfvars` / CI secrets. That's exactly the [`needs-operator`](../../../../CLAUDE.md) semantics (#608) — surfaced by `/my-turn` and drivable by `/do-work`. Routing it here keeps the worker-side backstop and the scope-preflight `external-dependency` defer on the **same** destination, so a provisioning-gated issue lands in the operator queue whether it's caught before dispatch or mid-work. The operator-phase enqueue in [operate/04-steady-state-hooks.md → A.1 reactive enqueue](./operate/04-steady-state-hooks.md#a1-hook--reactive-enqueue) already recognizes this bail as a browser-completable handback (the operator layer runs by default).

  **Why a dependency-wait needs no label.** When the bail names a still-open blocker, the `Blocked by #N` body-reference filter ([setup.md step 4](./setup/04-backlog-divert.md#4-fetch--rank-the-backlog) / bucket 7) is the *complete* mechanism: it drops the issue from the workable queue while `#N` is open and re-admits it the instant `#N` closes, with no per-session sweep. The pre-#521 `blocked:agent-hard` label on a dependency-wait was redundant with that filter — sub-sweep a (and the [#245](https://github.com/mattsears18/shipyard/issues/245) mid-session referential sweep) existed *only* to reconcile the redundant label. Eliminating the label lets both sweeps go away (see [setup.md step 3d.2](./setup/01-repo-recovery.md#3-ensure-label-exists--recover-from-prior-session) and the deleted step A.5).

  **Why soft labels don't bail next session's dispatch.** [setup.md step 4](./setup/04-backlog-divert.md#4-fetch--rank-the-backlog)'s workable filter does NOT exclude `-label:blocked:agent-soft`, AND [setup.md step 3d.2 sub-sweep c](./setup/01-repo-recovery.md#3-ensure-label-exists--recover-from-prior-session) removes the soft label entirely at every session start. So a soft-blocked issue is workable from the next session's perspective without any other intervention — the label exists purely as in-session documentation that "a worker bailed for a subjective reason; the user may want to clarify the body if they want a different outcome."

  **Why soft labels gate in-session re-dispatch.** Once a worker has bailed soft for an issue, immediately re-dispatching another worker against the same issue in the same session would just re-encounter the same ambiguity. The `session_blocked_soft[<N>] = <timestamp>` write blocks step C's lightweight backlog re-check from re-adding `<N>` to `raw_backlog` for `blocked_agent.soft_retry_minutes` minutes (default 30). After the window, step C re-considers the issue — by then the rest of the session may have moved forward (sibling PRs merged, files touched, scope-agent re-dispatched), so the ambiguity may have a different shape.

- **errored** — record in the session log, continue.

For **fix-checks work** (`green` / `noop` / `blocked`):

- **green #<M>** / **noop: already green #<M>** — PR is fine, continue. (PR is already in `session_prs` from whenever it was first opened or first fixed — no re-add needed.) **Refresh the cost-tracking comment** for `<M>` so the cumulative total includes this fix-checks dispatch's tokens (A.0 bumped them into `.tokens.per_pr[<M>]`). Same edit-or-create semantics as the `shipped` hook:

  ```bash
  export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
  # Derive the session id cwd-independently (immune to the #477 cwd-leak that
  # fires on reconcile turns — see A.0 required preamble and setup.md §0.55).
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
  SESSION_ID=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" derive-session-id \
    --repo-root "$REPO_ROOT" 2>/dev/null)
  [ -z "$SESSION_ID" ] && SESSION_ID=$(cat "$REPO_ROOT/.shipyard-session-id" 2>/dev/null)
  if [ -z "$SESSION_ID" ]; then
    echo "[session-id-derive] empty — skipping A.1 cost-comment refresh; check for #477 cwd-leak (#548)"
  else
  # 1. Read the cost summary as a Markdown comment body (now includes the
  # cumulative total across the original ship + every fix-checks follow-up).
  BODY=$("${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" read-tokens \
    --session-id "$SESSION_ID" --pr <M> --format comment)

  # 2. Edit the existing sentinel comment in place if one exists; otherwise
  # create one. The PATCH path is the hot path here — a green return on a
  # PR that was originally shipped this session will always have a
  # sentinel comment to update. Use the REST listing endpoint for the
  # same reason as the shipped hook above: `gh pr view --json comments`
  # returns GraphQL node-ids that the PATCH endpoint rejects with 404,
  # which silently falls through to the create branch and stacks
  # duplicate cost-tracking comments. See #264.
  EXISTING=$(gh api "/repos/<owner/repo>/issues/<M>/comments?per_page=100" \
    --jq '[.[] | select(.body | startswith("<!-- do-work-cost-tracking -->"))][0].id // empty')

  if [ -n "$EXISTING" ]; then
    gh api -X PATCH "/repos/<owner/repo>/issues/comments/$EXISTING" \
      -f body="$BODY" >/dev/null
  else
    gh pr comment <M> --repo <owner/repo> --body "$BODY" >/dev/null
  fi
  fi
  ```

  No-ops on a PR that never had a sentinel comment posted (no existing comment to update, no `shipped` event to anchor a fresh post — `EXISTING` is empty and the create path posts the first comment with just this fix-checks pass's tokens). Same comment-post-error policy as the `shipped` hook: log `[cost-comment] PR #<M> refresh failed: <reason>; continuing` and proceed.

  **Trust-but-verify before accepting `green`.** The agent's `green` claim is load-bearing — downstream code treats green PRs as settled. Spot-check the **latest run per check name** (issue [#333](https://github.com/mattsears18/shipyard/issues/333) — `statusCheckRollup` returns every check run for the head SHA including superseded runs; a stale FAILURE entry that's been re-triggered and now passes would incorrectly downgrade the worker's correct `green` claim to `failing` and re-queue the PR for a pointless second fix-checks dispatch):

  ```bash
  # Latest entry per check name BEFORE the walk.
  latest=$(gh pr view <M> --repo <owner/repo> --json statusCheckRollup,mergeStateStatus --jq '
    {mergeStateStatus: .mergeStateStatus,
     checks: [.statusCheckRollup
              | group_by(.name)
              | map(sort_by(.completedAt // .startedAt // "") | last)
              | .[]]}')
  ```

  Then classify each entry in `latest.checks`:
  - Every entry `conclusion in {SUCCESS, SKIPPED, NEUTRAL}` (or empty rollup) → accept `green`.
  - Any `state in {PENDING, IN_PROGRESS, QUEUED, EXPECTED}` or `conclusion == null` while `status != "completed"` → **downgrade to `pending`**. Do NOT label `blocked:ci`. Do NOT push onto `failed_prs`. Append `<M>` to `session_prs` (if not already there). Log: `[fix-checks-verify] downgraded #<M> green→pending: <n> checks still running (<sample-check-name>); drain will reconcile.`
  - Any `conclusion in {FAILURE, ERROR, TIMED_OUT, CANCELLED, ACTION_REQUIRED}` → **downgrade to `failing`**. Push `<M>` onto `failed_prs` (deduped) for the next dispatch cycle to pick up. Log: `[fix-checks-verify] downgraded #<M> green→failing: <failing-check-name> conclusion=<conclusion>; re-queued for fix-checks.`

  The spot-check fires on the `green #<M>` and `noop: already green #<M>` paths. It's one cheap `gh pr view` call. Never skip as an optimization. The latest-per-name `--jq` projection adds zero round-trips; skipping it re-introduces the false-positive failure mode from #333.

- **flake #<M>: re-ran failed jobs** ([#654](https://github.com/mattsears18/shipyard/issues/654)) — the worker classified the failure as an **infrastructure flake** (cancelled required jobs / dev-server boot timeout / setup-job failure / runner-lost) with local gates passing, and triggered `gh run rerun --failed` instead of a code fix. Do **NOT** label `blocked:ci` — the PR's diff is healthy; CI just needs to re-run on idle infrastructure. Do **NOT** count it against any fix-attempt budget. Do **NOT** push `<M>` onto `failed_prs` — the re-run is in flight, and enqueuing it would race a redundant fix-checks dispatch against a running re-run. Append `<M>` to `session_prs` (if not already there) so the drain phase watches the re-run's outcome, and **refresh the cost-tracking comment** for `<M>` (same edit-or-create semantics as the `green` path above). The next PR-triage tick picks the PR back up when the re-run settles: green → auto-merge fires; still-red → a fresh fix-checks dispatch (which bails `blocked:ci` if the run's attempt count has reached the re-run bound in [fix-checks-only.md's Infra-flake classification](../../agents/issue-worker/fix-checks-only.md#infra-flake-classification-and-re-run-load-bearing)). Log: `[fix-checks-flake] PR #<M> infra-flake re-run triggered (<signature>); watching for re-run outcome.`

- **blocked #<M> at fix-checks** — comment on the PR summarizing the blocker, add the `blocked:ci` label, continue. The label is the drain phase's signal that this PR is "settled — human needs to look." (This is the terminal for a *chronic* infra flake too — the [attempt-count bound](../../agents/issue-worker/fix-checks-only.md#infra-flake-classification-and-re-run-load-bearing) escalates a persistently-starved re-run to this `blocked` return, so a `blocked:ci` label here can mean either a stuck diff or a stuck runner.)

- **Unrecognized return string (narrative status update)** — the agent returned something that doesn't start with `green`, `noop:`, `flake`, or `blocked` (e.g., `"E2E shards typically take 8-15 min."`, `"Routine progress."`, `"Shard 3/3 passes."`). This is a [contract violation](../../agents/issue-worker/fix-checks-only.md#return-contract--read-carefully). Do NOT treat the narrative as authoritative. Probe and synthesize via the same **latest-per-name projection** the trust-but-verify spot-check uses (issue [#333](https://github.com/mattsears18/shipyard/issues/333)):

  ```bash
  latest=$(gh pr view <M> --repo <owner/repo> --json statusCheckRollup,mergeStateStatus,state --jq '
    {state: .state, mergeStateStatus: .mergeStateStatus,
     checks: [.statusCheckRollup
              | group_by(.name)
              | map(sort_by(.completedAt // .startedAt // "") | last)
              | .[]]}')
  ```

  Walk `latest.checks` and synthesize:
  - All `conclusion in {SUCCESS, SKIPPED, NEUTRAL}` (or empty rollup) → treat as `green #<M>`.
  - Any `state in {PENDING, IN_PROGRESS, QUEUED, EXPECTED}` or `conclusion == null` mid-run → treat as `pending`. Append `<M>` to `session_prs`. Do NOT push onto `failed_prs` — that races with the original worker's still-in-progress fix.
  - Any `conclusion in {FAILURE, ERROR, TIMED_OUT, CANCELLED, ACTION_REQUIRED}` → treat as `failing`. Push `<M>` onto `failed_prs` (deduped).

  Log: `[fix-checks-unrecognized] PR #<M> returned narrative status "<first 60 chars>…"; probed rollup, synthesized <outcome>.` Do NOT re-dispatch fix-checks against this PR within the same turn.

- **errored** — record and continue.

For **fix-rebase work** (`rebased` / `noop` / `blocked`) — dispatched only by the [end-of-session drain](./drain.md#end-of-session-drain):

- **rebased #<M>** — the agent force-pushed a rebased branch onto current main. PR is no longer DIRTY; CI will re-run on the new head and auto-merge will fire when green. Record. **Increment `rebase_success_counts[<M>]` by 1** (initialize to 0 if absent) — this is the per-PR rate-limit counter that gates merge-train-race recovery per [drain.md's end-of-session drain](./drain.md#end-of-session-drain). Do NOT add `<M>` to `rebase_blocked_prs` — a successful rebase is a winnable race, not a stuck state. The next drain poll snapshot will reflect the transition out of DIRTY naturally — if a sibling merge re-introduces DIRTY before the rebased branch's CI lands, the drain's `D_dirty` check will re-enter the PR for another fix-rebase dispatch (subject to the 3-cap). (PR is already in `session_prs` from whenever it was first opened — no re-add needed.) **CI-minute bookkeeping ([#323](https://github.com/mattsears18/shipyard/issues/323)):** if `ci.max_drain_rebases` is non-null, increment `ci_session_counters.drain_rebases_dispatched` by 1 here — the cap is enforced against total dispatches, not just successful returns, but the increment lives on the dispatch path (drain.md per-poll action 2) AND mirrors here so the counter survives an out-of-order reconcile.
- **noop: not dirty (<reason>)** — by the time the agent started, the PR was no longer in DIRTY state (auto-merge already landed it, mergeStateStatus settled to CLEAN, or new check failures appeared). Record and continue. If the reason hints at new failures (the agent saw `FAILURE` in the rollup and bailed because rebase is the wrong tool), the drain's normal per-poll red-PR scan will catch it on the next tick and route it through fix-checks instead — no extra action needed.
- **blocked rebase #<M>: <reason>** — non-trivial conflict, head branch moved during the rebase, or some deterministic failure. **Add `<M>` to `rebase_blocked_prs`** (per [drain.md's end-of-session drain](./drain.md#end-of-session-drain) — the deterministic-failure gate that prevents re-dispatch within the session). Add a one-line PR comment: `Drain-phase auto-rebase blocked: <reason>. Needs manual rebase.` Do NOT add `blocked:ci` — the PR isn't stuck on checks, it's stuck on stale base; a human can resolve the rebase and the next session will pick it up if it's still DIRTY. Surface in the end-of-session summary as a still-DIRTY PR. **The `conflict extends beyond coordinated manifest+CHANGELOG rows` reason is the expected soft-collision sub-case** ([#507](https://github.com/mattsears18/shipyard/issues/507)): two+ soft-collision claimers edited the **same section** of the same docs file, so the conflict is real prose content beyond the [§4.6](../../agents/issue-worker/fix-rebase.md#46-version-coordinated-manifest--changelog-re-number-trivial-resolution-issue-466) version-row carve-out. Treat it identically — it is **not a worker failure**, it is the residual cost of the soft tier at `--concurrency ≥ 2`; the still-DIRTY summary entry signals a human should hand-resolve (union the additive bullets, keep both items, CHANGELOG newest-first). See the [Soft-collision](#dispatch-rules-used-by-step-7-and-step-c) rules for the premise boundary.
- **errored** — record and continue.

For **fix-main-ci work** (`shipped` / `noop` / `blocked`):

- **shipped main-ci-fix via PR #<M>** — record. **Append `<M>` to `session_prs`.** The diversion is "resolved" from the orchestrator's perspective the moment the PR is open with auto-merge; the next step-D refresh will detect main going green (and clear the divert flag) once the PR lands. Don't re-enqueue the diversion in the meantime — the in_flight slot is gone but the divert_queue check at step D guards against double-dispatch.

  **Stamp the attempt counter for the flake circuit breaker** ([#589](https://github.com/mattsears18/shipyard/issues/589)). The just-completed slot's in_flight entry carries the `earliest_red_workflow_name` the divert targeted (call it `sig`). On this `shipped` reconcile, **increment** `main_ci_fix_attempts[sig].attempts` (initializing the entry to `{ attempts: 0, last_pr: null, last_sha: null, escalated: false }` if absent), and set `last_pr = <M>`. This records "we have now made N fix attempts against `sig`." The *re-red verification* — confirming the merge-commit went red again on the same `sig` rather than the fix working — is deferred to the next [step-D divert-checks refresh](#d-periodic-refresh): if that refresh finds `sig` green, the green branch of [step 4.5a's enqueue rule](./setup/04-backlog-divert.md#45-divert-checks-main-ci--pr-pileup) deletes the counter (the fix worked, attempts forgotten); if it finds `sig` still/again red, the counter persists and the cap check in the red branch decides whether to re-dispatch or escalate. Incrementing on `shipped` (rather than waiting for the re-red) is what makes the cap converge: a fix that *works* clears the counter at the next green refresh, so only the genuinely-recurring pass-on-PR/fail-on-merge flake accumulates toward the cap.
- **noop: main already green** — main flipped green between divert dispatch and the agent's pre-flight. Record. **Clear any `main_ci_fix_attempts` entry for the slot's `earliest_red_workflow_name`** — main is green on that workflow, so the attempt cycle is done. Step D will repopulate if it goes red again.
- **blocked main-ci-fix: <reason>** — log to the session summary. Do NOT auto-retry — back off and surface in the status line: `main:🔴 (<workflow-summary>, run <id>) · diversion blocked: <reason>` (same `<workflow-summary>` format as the setup.md step 6.5 status-line spec). A human needs to intervene. (Distinct from the [#589](https://github.com/mattsears18/shipyard/issues/589) flake escalation: a `blocked` return is the *worker* declining to fix; the flake escalation is the *orchestrator* capping repeated green-on-PR/red-on-merge fixes that each "succeeded" from the worker's view.)

For **fix-failing-prs-batch work** (`shipped` / `noop` / `blocked`):

- **shipped pr-batch-fix via PR #<M>** — record. **Append `<M>` to `session_prs`.** Same single-shot pattern as fix-main-ci.
- **noop: pileup already cleared** — the count dropped below 10 between dispatch and pre-flight (other PRs got merged or fixed). Record. Step D re-evaluates.
- **blocked pr-batch-fix: <reason>** — log to summary, back off, surface in status line. No auto-retry.

For **investigate work** (`investigated+fixed` / `investigated+needs-human-review` / `investigated+closed-noise` / `investigated+duplicate` / `blocked` / `reaped`):

- **investigated+fixed #<N> via PR #<M>** — the worker diagnosed a real bug and opened a fixing PR. Record. **Append `<M>` to `session_prs`.** Apply the standard `shipped` cost-tracking comment and worktree-reap path (same as issue-work `shipped` — cost comment on PR, immediate worktree reap for `do-work/issue-<N>`). Remove the `needs-triage` label from the issue: `gh issue edit <N> --repo <owner/repo> --remove-label needs-triage 2>/dev/null || true`. The issue auto-closes when PR `<M>` merges (the worker's PR body includes `Closes #<N>`).

- **investigated+needs-human-review #<N> (label applied)** — the worker reviewed the issue and determined it requires human judgment (ambiguous reproducer, architectural decision, security-sensitive, etc.). The worker already applied the `needs-human-review` label. Record. Remove `needs-triage`: `gh issue edit <N> --repo <owner/repo> --remove-label needs-triage 2>/dev/null || true`. No auto-retry — `/my-turn` will surface it. Reap the agent's worktree via step B.

- **investigated+closed-noise #<N>** — the worker determined the issue is noise (spam, test artifact, auto-filed bot issue with no actionable signal). The worker already closed the issue. Record. Log: `[investigate-reconcile] #<N> closed as noise.` Reap the agent's worktree via step B.

- **investigated+duplicate #<N> of #<K>** — the worker determined the issue duplicates `#<K>`. The worker already closed `#<N>` as a duplicate. Record. Log: `[investigate-reconcile] #<N> closed as duplicate of #<K>.` Reap the agent's worktree via step B.

- **reaped:** (from investigate mode) — same handling as issue-work `reaped:` above: re-enqueue `<N>` into `investigate_candidates` (deduped), remove `@me` assignee, log the event. The worker's worktree is already gone; no reap needed.

- **blocked #<N>** (from investigate mode) — apply the same `blocked` classification logic as issue-work above (dependency-wait → no label, body-ref filter; refuse → `needs-human-review`; soft → `blocked:agent-soft`). Additionally remove `needs-triage` only on the refuse path (the issue is no longer a triage candidate once a human-review gate has been applied): `gh issue edit <N> --repo <owner/repo> --remove-label needs-triage --add-label needs-human-review 2>/dev/null || true`. Reap the agent's worktree via step B.

For **spike work** (`spiked+shipped` / `spiked+needs-human-review` / `blocked` / `reaped`) — [#774](https://github.com/mattsears18/shipyard/issues/774), dispatched per [`dispatch-rules.md`'s spike-shape detection](./dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c):

- **spiked+shipped #<N> via PR #<M> (auto-merge: ..., checks: ..., sub-issues: ...)** — the worker concluded the spike (viable / viable-with-caveats / **or** not-viable — all three are `spiked+shipped`, per [spike.md step 11](../../agents/issue-worker/spike.md#11-return)) and opened a PR carrying the committed design doc plus, optionally, a decomposition and/or an implemented slice. Treat this identically to an issue-work `shipped #<N> via PR #<M>` return: **Append `<M>` to `session_prs`.** Run the standard `shipped` cost-tracking comment and immediate worktree reap for `do-work/issue-<N>` (same mechanics as the [issue-work `shipped` handler](#a1-parse-the-return-string) above — auto-merge/checks parsing, cost comment, force-reap-even-on-`peer-alive`). The issue auto-closes when PR `<M>` merges (the worker's PR body includes `Closes #<N>`). Any follow-on sub-issues the worker filed (per spike.md step 6) are fresh `shipyard`-labelled issues with no gate label — they re-enter the normal dispatch loop via the next backlog fetch, exactly like a `/decompose-epic` shard.

- **spiked+needs-human-review #<N> (label applied)** — the investigation surfaced a genuine human-only decision (product/business/legal call, access the worker lacks, or a question no amount of investigation could narrow). The worker already applied `needs-human-review`. Record. No auto-retry — `/my-turn` will surface it. Reap the agent's worktree via step B.

- **reaped:** (from spike mode) — same handling as issue-work `reaped:` above: re-enqueue `<N>` back into the ready pool (deduped), remove `@me` assignee, log the event. The worker's worktree is already gone; no reap needed.

- **blocked #<N>** (from spike mode) — apply the same `blocked` classification logic as issue-work above (dependency-wait → no label, body-ref filter; refuse → `needs-human-review`; soft → `blocked:agent-soft`). Reap the agent's worktree via step B.

`session_prs` is the set of PR numbers this orchestrator session opened (issue-worker shipped, fix-main-ci shipped, fix-failing-prs-batch shipped, spike-worker shipped) plus any pre-existing `@me` PRs that fix-checks touched. It is read by the end-of-session drain to decide what to watch and when to exit. A PR enters `session_prs` exactly once — re-touches don't re-add. Started empty at step 7's initial pool fill.

#### A.5. (removed — [#521](https://github.com/mattsears18/shipyard/issues/521))

The mid-session blocked-issue re-evaluation sweep ([#245](https://github.com/mattsears18/shipyard/issues/245)) was **removed** in [#521](https://github.com/mattsears18/shipyard/issues/521) along with the `blocked:agent-hard` label it reconciled. Its entire job was to auto-clear the redundant `blocked:agent-hard` label mid-session when a shipped PR closed a referenced blocker — but dependency-wait issues no longer carry a label. They are gated purely by the [`Blocked by #N` body-reference filter](./setup/04-backlog-divert.md#4-fetch--rank-the-backlog) (bucket 7 / step 4), which already stops dropping the issue the instant the referenced blocker closes. Step C's [lightweight backlog re-check](#c-dispatch-a-replacement-if-work-remains--mandatory-action) runs that filter on every dispatch, so a blocker that closes mid-session re-admits its dependents on the next dispatch turn with no targeted sweep — the body-ref filter is the complete mechanism. See [setup.md step 3d.2](./setup/01-repo-recovery.md#3-ensure-label-exists--recover-from-prior-session) for the companion removal of session-start sub-sweep a.

### B. Release the slot

Remove the completed entry from `in_flight`. Its `claimed_paths` are now free.

**Then reap the agent's worktree — every completion path, every mode.** Closes [#334](https://github.com/mattsears18/shipyard/issues/334). The A.1 `shipped #<N>` handler already runs an immediate-reap for issue-work `do-work/issue-<N>` worktrees (per [#282](https://github.com/mattsears18/shipyard/issues/282)), but that path does NOT cover the other return shapes:

- **`green #<M>` / `noop: already green #<M>` from fix-checks-only** — head branch is the PR's existing head (typically `do-work/issue-<N>` for shipyard-anchored PRs). When fix-checks completes and the drain phase later dispatches a fix-rebase against the same PR, the fix-rebase worker bails with `blocked rebase #<M>: head branch <head> locked in another worktree` because the fix-checks worktree's lock outlived the worker.
- **`rebased #<M>` from fix-rebase** — head branch is the PR's existing head. Sequential fix-rebase retries (the per-PR 3-attempt cap can hit this) collide on the same branch.
- **`shipped main-ci-fix via PR #<M>` / `shipped pr-batch-fix via PR #<M>` from synthetic-divert workers** — head branches are `do-work/fix-main-ci-<sha>` / `do-work/fix-pr-pileup-<ts>` (not `do-work/issue-<N>`) so the A.1 `shipped #<N>` branch-walk doesn't match and the worktree lingers.
- **`blocked <mode>` from any mode** — the worker bailed without producing a usable artifact; its worktree is no-longer-live and should be reaped same-session so a re-dispatch (after the soft-window, after a human clears `needs-human-review` on a refuse, or after the referenced `Blocked by #N` blocker closes on a dependency-wait) doesn't collide on the head branch.

The single-point reap below covers every one of these. The A.1 `shipped #<N>` path is **not** removed — it remains the load-bearing same-turn reap for the issue-work merge-train coordination case (per #282's rationale), and the duplicate-reap is harmless: the helper's `git worktree remove --force` against a path the A.1 pass already removed is a silent no-op.

**Force-reap even on `peer-alive` here — closes the general-reap gap #576 left open (issue [#771](https://github.com/mattsears18/shipyard/issues/771)).** [#576](https://github.com/mattsears18/shipyard/issues/576) taught the A.1 `shipped`-only path and the drain pre-dispatch reap to force-reap on `peer-alive`, but **this** per-completion reap — the one that actually covers `green`/`rebased`/the synthetic-divert `shipped` variants/`blocked <mode>` — was left deferring conservatively, exactly like the pre-#576 A.1 path. By the time step B runs, step A has already parsed this turn's **terminal** return string (every mode's completion contract: `shipped` / `green` / `noop` / `rebased` / `blocked`), so the agent is done by definition regardless of which mode produced the release — the same reasoning A.1 and drain's #370 already apply. A `peer-alive` classification at this call site means the lock PID is a transient harness subprocess that outlived the agent's own return by milliseconds, not a genuine still-working peer. Deferring on it left the just-completed worker's head branch locked into the exact window a re-dispatched fix-checks-only or fix-rebase worker needs it, producing the `blocked ...: head branch <head> locked in another worktree` bails documented in #771 (repro: PRs #2598 and #2701, each requiring a manual `git worktree remove --force` before the re-dispatch would take — twice in the #2598 case, because the *next* re-dispatch's own worktree hit the same deferred-peer-alive gap on its own completion). Force-reap and audit with classification `peer-alive-force` (same token A.1 uses — the `phase` field, already `steady-state-B-completion`, is what distinguishes the two call sites in `~/.shipyard/reap-audit.jsonl`).

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
# Capture the agent id BEFORE the in-memory slot removal — the path
# derivation needs it. The agent_id is the same task-id the harness uses
# end-to-end (see step A.−1 for the keying convention) and matches the
# `.claude/worktrees/agent-<id>` directory name the harness creates for
# `isolation: "worktree"` dispatches.
completed_agent_id="${.in_flight[<slot-id>].agent_id}"
# Anchor cwd to a stable directory BEFORE deriving paths or reaping (issue
# #497). The harness can leak the orchestrator's cwd into the very
# `agent-${completed_agent_id}` worktree this block removes; once it's gone,
# the `git worktree prune` below and the `$(git rev-parse --show-toplevel)`
# path derivation both fail with `fatal: Unable to read current working
# directory` (git resolves its own cwd before doing anything). Derive a
# stable anchor cwd-independently via the #477 porcelain idiom (orchestrator
# worktree first, primary as fallback) and cd to it first, then derive the
# primary/worktree paths from porcelain rather than the leaked cwd.
STABLE_DIR=$(git worktree list --porcelain 2>/dev/null \
  | awk '/^worktree /{p=substr($0,10)} p ~ /\/\.claude\/worktrees\/orchestrator-/{print p; exit}')
[ -z "$STABLE_DIR" ] && STABLE_DIR=$(git worktree list --porcelain 2>/dev/null \
  | awk '/^worktree /{print substr($0,10); exit}')
cd "${STABLE_DIR:-/}" 2>/dev/null || cd /
PRIMARY_CHECKOUT=$(git worktree list --porcelain 2>/dev/null \
  | awk '/^worktree /{print substr($0,10); exit}')
wt_dir="${PRIMARY_CHECKOUT}/.git/worktrees/agent-${completed_agent_id}"
worktree_path="${PRIMARY_CHECKOUT}/.claude/worktrees/agent-${completed_agent_id}"

if [ -d "$wt_dir" ]; then
  # Bootstrap the orchestrator PID so classify-lock can short-circuit on
  # our own session's locks (issue #263 — same pattern as A.1's reap).
  export SHIPYARD_ORCHESTRATOR_PID=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" detect-orchestrator-pid)

  classification=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" \
    classify-lock "$wt_dir/locked")

  # Extract the lock PID for the audit log (best effort; null literal
  # when the lock file is missing or unparseable).
  lock_pid=$(grep -oE '[0-9]+\)' "$wt_dir/locked" 2>/dev/null | tr -d ')' | head -1)
  [ -z "$lock_pid" ] && lock_pid="null"

  # no-lock / dead / self-ancestor / peer-alive — all safe to reap here.
  # Step A has already parsed THIS dispatch's terminal return string by the
  # time step B runs (shipped / green / noop / rebased / blocked — every
  # mode's completion contract), so the agent is done by definition. Unlike
  # the pre-#771 posture (which deferred on peer-alive as a blanket
  # defensive measure), a peer-alive classification here is treated the
  # same way A.1's shipped-path and drain's #370 pre-dispatch reap already
  # treat it: the lock PID is a transient harness subprocess outliving the
  # agent's own return, not a genuine still-working peer. Force-reap closes
  # the general-reap gap #576 left open — that fix only covered the A.1
  # issue-work `shipped` special case, leaving every other return shape
  # (fix-checks `green`, fix-rebase `rebased`, the synthetic-divert
  # `shipped` variants, any mode's `blocked`) still deferring here and
  # producing the "branch locked in another worktree" re-dispatch bails
  # documented in issue #771. Audit with classification "peer-alive-force"
  # so the override stays traceable in ~/.shipyard/reap-audit.jsonl.
  local_classification="$classification"
  [ "$classification" = "peer-alive" ] && local_classification="peer-alive-force"
  "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" reap \
    --action reaped \
    --worktree-path "$worktree_path" \
    --worktree-name "agent-${completed_agent_id}" \
    --session-id "<session-id>" \
    --classification "$local_classification" \
    --lock-pid "$lock_pid" \
    --phase "steady-state-B-completion" 2>/dev/null || true
  git worktree prune 2>/dev/null || true
fi
```

**Fire-and-forget discipline.** Every command suffixes `2>/dev/null` and/or `|| true` so a filesystem race (the worktree was already reaped by the A.1 path, the helper script is missing, the lock file is gone, etc.) cannot abort the steady-state loop. If the reap silently fails for any reason, end-of-session cleanup is still the safety net (intentionally NOT removed — it remains the ultimate sweep).

**Audit-log shape.** The JSONL entries this step writes carry `"phase":"steady-state-B-completion"` so an operator inspecting `~/.shipyard/reap-audit.jsonl` can distinguish per-completion reaps from the A.1 same-turn reap (`"phase":"steady-state-A1-shipped"`), the setup-3b stale-worktree pass (no `phase`), and the cleanup-summary end-of-session sweep (no `phase`). The `phase` suffix is appended by the `reap` helper natively (issue #284).

**Why identify the worktree by `agent_id` instead of walking branches.** The A.1 `shipped #<N>` path walks `.git/worktrees/agent-*` and matches on the HEAD ref because the orchestrator's working memory at that point already knows `<N>` but not which agent ran it. Step B runs against a slot that still has `agent_id` in working memory at the moment of release — so we can derive `.claude/worktrees/agent-<agent-id>` directly without scanning. This is faster (no `for` loop, no `git worktree list` parse) and more precise (no risk of matching the wrong worktree on a branch-name collision).

### C. Dispatch a replacement (if work remains) — MANDATORY ACTION

**This step is non-optional and non-deferrable.** Whenever step B frees a slot, step C MUST resolve in the same turn — either a `Workflow` tool call or an explicit, structured idle-proof (step E). No third option.

**Drain guard:** if `draining = true`, skip dispatch entirely. The slot stays empty until in-flight empties and the loop terminates. Step E still prints with `draining=true` noted.

**Lightweight backlog re-check (every dispatch).** Before consulting `ready_issues` or `raw_backlog`, run the step-4 backlog fetch — a single `gh issue list` with the same **wide-fetch shape** that [setup.md step 4](./setup/04-backlog-divert.md#4-fetch--rank-the-backlog) uses (`--state open` server-side only, plus any `--label` qualifiers passed at invocation; the previous `-linked:pr` + `-label:...` server-side qualifiers were removed in [#332](https://github.com/mattsears18/shipyard/issues/332) — they silently excluded resumable-work issues). Apply the same client-side filter step 4 applies — trusted-author check, dispatch-gate labels (`blocked:ci`, `wontfix`, `needs-triage`, `discussion`, `needs-human-review` — `blocked:agent-hard` and the legacy `blocked:agent` were eliminated per [#521](https://github.com/mattsears18/shipyard/issues/521): refuses now carry `needs-human-review` and dependency-waits carry no label (gated by the `Blocked by #N` body-ref filter), so neither appears here; `needs-design` was folded into `needs-human-review` per [#515](https://github.com/mattsears18/shipyard/issues/515), the `needs-decomposition` / `tracking` epic-decomposition pair per [#519](https://github.com/mattsears18/shipyard/issues/519), and `needs-refinement` was eliminated entirely per [#520](https://github.com/mattsears18/shipyard/issues/520) — refinement is now a pre-dispatch source-signal scan, leaving no persisted gate state to exclude here), assignee≠@me, `Blocked by #N` still-open, closed-by-@me-authored-healthy-PR — and only then diff against the union of `in_flight` + `ready_issues` + `raw_backlog` + issues previously closed this session. Append net-new issue numbers to `raw_backlog` in priority order (same ranking rules as step 4); the trusted-author drop is non-negotiable here — `raw_backlog` is the dispatch-feeder queue and a stranger's mid-session issue must never reach it. Skip auto-triage label-stamping and full scope pre-flight here — those run on step D's periodic refresh; the cheap pass just appends raw issue numbers (lazy scope at rule 5 of the dispatch rules). On transient `gh` errors, proceed with the queues as-is — never block dispatch on a refill failure.

**Soft-blocked in-window filter (per [#300](https://github.com/mattsears18/shipyard/issues/300)).** Step 4's workable filter does NOT exclude `blocked:agent-soft` — by design, so the label doesn't leak across sessions — but within a session, immediately re-dispatching a worker against an issue another worker just bailed soft on would just re-encounter the same ambiguity. The in-memory `session_blocked_soft` map (populated by step A.1's `blocked` handler — `{issue_number → ISO-8601 timestamp of the bail}`) gates this. Before appending any net-new issue to `raw_backlog`, check:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
# blocked_agent.soft_retry_minutes — default 30 — from shipyard-config.sh.
soft_retry_minutes=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" \
  get blocked_agent.soft_retry_minutes 2>/dev/null || echo "30")
now_epoch=$(date -u +%s)
for n in "${net_new_issues[@]}"; do
  bail_iso="${session_blocked_soft[$n]:-}"
  if [ -n "$bail_iso" ]; then
    bail_epoch=$(date -u -d "$bail_iso" +%s 2>/dev/null || \
                 date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$bail_iso" +%s 2>/dev/null || echo 0)
    elapsed_min=$(( (now_epoch - bail_epoch) / 60 ))
    if [ "$elapsed_min" -lt "$soft_retry_minutes" ]; then
      # In-window — skip re-add; will retry on the next dispatch after window expiry.
      continue
    fi
    # Window expired — clear the bookkeeping entry so the issue is treated as fresh.
    unset 'session_blocked_soft[$n]'
  fi
  raw_backlog+=("$n")
done
```

Filter applies to net-new issues from the lightweight re-check ONLY — issues already in `raw_backlog` / `ready_issues` from earlier in the session are NOT re-checked here (they were validated at their own dispatch attempt, and a worker that bailed soft on them already added them to `session_blocked_soft`). When `blocked_agent.soft_retry_minutes` is `0`, the filter is a no-op — every soft-bailed issue is re-considered on every dispatch (useful for debugging; not recommended in normal operation).

**Cache the backlog re-check via `gh-cached.sh`.** This is a hot path — it fires on every dispatch turn — and the backlog doesn't change meaningfully over a 60-second window. Wrap the `gh issue list` call through [`gh-cached.sh`](./setup/00-config-worktree.md#09-gh-cachedsh-wrapper-opt-in-per-call-site) with `--ttl 60`. Invalidate the cache (`gh-cached.sh invalidate --session-id "<session-id>"`) right after any state-changing call shipyard itself makes (issue close, label edit, etc.) so the next dispatch turn picks up the post-write view. Caller picks the trade-off: skip the wrapper to always re-fetch live, or accept up to 60s of staleness in exchange for not re-hitting the API every dispatch.

Apply the **dispatch rules** to pick the next job:

- **Job found** → pre-provision the worker's worktree, then issue the `Workflow` tool call **in this turn** (both per [dispatch-rules.md's substrate section](./dispatch-rules.md#workflow-substrate-dispatch--the-dispatch-mechanism-for-every-worker-mode-791)). Multiple slots freed by step B fill with parallel `Workflow` calls in the same message.
- **No compatible job** → record *why* the slot stays empty. The reason feeds into step E's invariant line. Examples: `parked (all ready_issues collide with in_flight paths)`, `parked (all ready_issues collide with in_flight lockfile sections: overrides×1, dependencies×1)`, `parked (all ready_issues blocked by soft-cap on CLAUDE.md, ×3 active)`, `parked (all queues empty after backlog re-check)`.
- **Dispatch call refused by the harness permission classifier** → the dispatch never happened: no agent ran, **no completion notification coming**. Follow [dispatch-rules.md § "Dispatch denied by the harness permission classifier"](./dispatch-rules.md#dispatch-denied-by-the-harness-permission-classifier-718) ([#718](https://github.com/mattsears18/shipyard/issues/718)) — record it in `dispatch_denials`, **reap the worktree you pre-provisioned for the refused dispatch** (it is orphaned: no worker, no `.in_flight` slot, and no other reap path will find it), take **at most one** *accuracy-correcting* re-dispatch (never a wording retry against the classifier), hand back to the human on a second denial, and fill the slot with the next candidate in the same turn. Do **not** run step A against a denial and do **not** write an `.in_flight` slot for it.

**Per-slot dispatch metadata write-through.** When a new slot lands in `.in_flight`, the orchestrator's write-through call MUST include the slot's `started_at` ISO-8601 UTC timestamp alongside `kind` / `target` / `claimed_paths` / the dispatch id / the pre-provisioned `worktree_path`. **The write-through runs only AFTER the `Workflow` call is accepted** — the dispatch id doesn't exist until it returns, and a speculative pre-write would leave a phantom slot behind on the classifier-denial path ([#718](https://github.com/mattsears18/shipyard/issues/718)). The timestamp powers [`/shipyard:status`](../status.md)'s `ELAPSED` column and the stale-worker detection — without it, every worker would render as "elapsed 0s, stale" the moment a new orchestrator instance reads the file. Per-slot `progress_current` / `progress_total` start as `null` and are managed by the worker via `session-state.sh set-progress --slot <id>` if the worker is doing batch work (the typical issue-work / fix-checks-only worker doesn't bother — the kind alone is enough). Example shape — see [the schema doc](../do-work.md#schema) for the canonical fields:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
# --allow-degraded-init survives the mid-session file-disappear race
# (issue #281). Without it, a concurrent /do-work session's orphan-sweep
# reaping this file mid-session would surface as exit 3 on the next
# update call, leaving working memory out of sync with the file.
"${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" update \
  --session-id "<session-id>" \
  --allow-degraded-init --degraded-init-repo "<owner/repo>" \
  --set ".in_flight.<slot-id> = {
    kind: \"issue\", target: <N>,
    claimed_paths: { hard: [...], soft: [...] },
    agent_id: \"<agent-uuid>\",
    started_at: \"<iso-8601 UTC now>\",
    progress_current: null,
    progress_total: null,
    progress_updated_at: null
  }"
```

### D. Periodic refresh

**Drain guard:** skip during drain — refresh is pointless when no new work will be dispatched.

Otherwise, the refresh is **event-driven with adaptive backoff** (see [refresh trigger rules](#refresh-trigger-rules) below). When a refresh fires, it runs three sub-steps (plus, on a merge-completion trigger, the [own-the-tail sweeps](#d-tail-own-the-tail-merge-completion-sweeps-phase-c-663) in D-tail):

1. **Divert-checks refresh** — re-run step 4.5 (main CI + all-authors failing PR count). Update `main_ci` and the `failing_pr_count_all` cache. Enqueue or clear `divert_queue` entries per the rules in step 4.5. This is the only place outside setup where diversions are evaluated. **`--fast` skip:** when `--fast` was set at session startup, skip this sub-step every time step D runs — leave `main_ci.status` and `failing_pr_count_all` as `"unknown"` / `0` for the session. The divert-checks cost is the mechanism `--fast` traded away; re-enabling them mid-session would undercut the savings.
2. **Failed-PR scan (@me)** — re-run the step-5 query. Append any newly-red PRs to `failed_prs` (deduped against entries already in `in_flight` or `failed_prs`). **Also run [setup step 5.7's inherited-DIRTY snapshot](./setup/04-backlog-divert.md#57-seed-inherited-dirty-prs-into-session_prs-cross-session-drain-hand-off)** here — it's the same `@me` open-PR list, projected for `mergeStateStatus == "DIRTY"` + healthy checks instead of for failing checks. Append the resulting numbers to `session_prs` (deduped) so the end-of-session drain owns them. At C=1, where the setup-time 5.7 snapshot is deferred (per its lazy-load carve-out), this is where the seeding actually happens; at C≥2 it's a cheap idempotent re-confirm (the dedup makes a re-seed a no-op if setup already ran it). This catches PRs that go DIRTY *mid-session* too — a sibling merge can DIRTY an inherited PR after setup ran, and without re-snapshotting here it would fall back into the blackhole until drain.
3. **Scope refill + auto-triage pass (background)** — gated on `ready_issues` size `< --concurrency`. Fire the next `2 × concurrency` from `raw_backlog` as background scoping agents (`run_in_background: true`) — do NOT wait for them to return before proceeding to step C's dispatch. As each background scope agent completes, apply the same per-entry handling as the [initial scope pre-flight](./setup/06-scope-preflight.md#6-initial-scope-pre-flight) (ready entries → `ready_issues` immediately; deferred entries → run the per-class `evidence_pointer` validator ([#302](https://github.com/mattsears18/shipyard/issues/302)) — valid defers get the comment + `deferred_issues` recording path, malformed defers get the rejection path that pushes the issue back to `raw_backlog`). The periodic auto-triage label-stamping (P0/P1/P2) also runs here (synchronously, before firing the background scope burst). Sub-steps 1 and 2 run regardless of queue depth — they check external state.

**Why background refill matters.** Under the previous synchronous model, every step-C `ready_issues empty but raw_backlog non-empty` case (dispatch rule 5) required blocking ~30 s for a full scope-refill burst before the freed slot could be filled. With background refill, the slot fill-decision uses whatever is already in `ready_issues`: if at least one pre-scoped entry is there, dispatch it immediately; the background refill tops up the queue while the new worker runs. The net effect is that the ~30 s scope-wait at step C never blocks a slot again after the initial batch (started at step 6) has seeded at least one entry into `ready_issues`.

The refresh runs in the same turn as the completion handler and does **not** delay step C's dispatch. If `main_ci.status`, `divert_queue` membership, or the 10-threshold for `failing_pr_count_all` changed, also print the status line (see step 6.5).

#### Refresh trigger rules

The orchestrator maintains a small refresh tracker — three fields, all session-scoped — alongside the twelve [orchestrator state](../do-work.md#orchestrator-state) structs:

- **`refresh_last_at`**: timestamp of the most recent refresh that actually ran. Initialized to the moment step 4.5 completes at setup.
- **`refresh_last_snapshot`**: cached `{ main_ci_status, failing_pr_count_all, failed_prs_size }` from the most recent refresh — used to compute deltas.
- **`refresh_zero_delta_streak`**: integer count of consecutive refreshes that produced **no change** vs `refresh_last_snapshot`. Initialized to `0`. Incremented when a refresh produces zero delta; reset to `0` the moment any refresh produces a change.

A refresh fires on a given turn when **any** of the following triggers is true:

1. **Just-reconciled `shipped` return** — step A reconciled a `shipped #<N> via PR #<M>`, `shipped main-ci-fix via PR #<M>`, or `shipped pr-batch-fix via PR #<M>` return this turn. A new PR landed in the world, so `failed_prs` (the new PR's CI may flip red between dispatch and check completion) and `divert_queue` (a newly-opened PR can resolve a main-CI divert) both want a refresh. Fires unless the adaptive-skip carve-out in rule 4 applies.

   **`merged-direct-ungated` sub-case (issue [#457](https://github.com/mattsears18/shipyard/issues/457)) — fires unconditionally.** When the reconciled `shipped` return carries the `auto-merge: merged-direct-ungated` suffix, the PR already landed on the default branch *before* its CI completed (gh admin-direct-merged on a repo with no required status checks — see [worker-preamble § "Auto-merge + snapshot-and-return pattern" step 1.5](../../skills/worker-preamble/auto-merge.md#auto-merge--snapshot-and-return-pattern)). The merge commit's build is still in flight and may flip `main` red with no PR-level gate having caught it. Treat this exactly like trigger 3 (the time-based fallback): the refresh **fires unconditionally**, exempt from the rule-4 adaptive-skip carve-out, so a `refresh_zero_delta_streak >= 3` cannot defer the very refresh that would catch the ungated-merge fallout. The refresh re-runs the [step 4.5a main-CI divert check](./setup/04-backlog-divert.md#45-divert-checks-main-ci--pr-pileup) against the default branch; if the post-merge build has gone red, the divert enqueues a `fix-main-ci` worker as usual. No new state field is needed — the existing main-CI divert machinery is the watch; this rule just guarantees the refresh that drives it isn't skipped.
2. **Just-reconciled `green #<M>` / `noop: already green #<M>` / `flake #<M>: re-ran failed jobs` from fix-checks** — step A reconciled a fix-checks-only return that resolved or re-ran a previously-red PR. The all-authors failing-PR count and the `failed_prs` queue just dropped (the PR is green, or its failed jobs are re-running rather than concluded-red); refresh to recompute the divert-checks and pick up any newly-red PRs that need attention. Fires unless the adaptive-skip carve-out in rule 4 applies.
3. **5-minute time-based fallback** — if `now - refresh_last_at >= 5 minutes` AND no other trigger has fired in that window, run a refresh anyway. Covers the case where the orchestrator is idle waiting on long-running CI and external state may have drifted (a human pushed to main; another author opened/closed PRs; new issues got filed). **Fires unconditionally** — the adaptive-skip carve-out in rule 4 does *not* defer this trigger.
4. **Adaptive-skip carve-out (applies to triggers 1 and 2 only).** When trigger 1 or 2 would otherwise fire but `refresh_zero_delta_streak >= 3`, downgrade the event-driven trigger to a deferral — skip this refresh and let trigger 3 (the 5-min fallback) pick it up. The streak indicates external state isn't changing meaningfully relative to completion cadence; saving the `gh` calls until the time-based check is the win. The streak resets the moment any refresh (event-driven or time-based) produces a change. **Trigger 3 is exempt from this carve-out** — the time-based fallback is the unconditional safety net and runs regardless of the streak. **The trigger-1 `merged-direct-ungated` sub-case is also exempt** (issue [#457](https://github.com/mattsears18/shipyard/issues/457)) — a PR that landed on the default branch before its CI completed is precisely the kind of state change a quiet streak would otherwise mask, so its refresh fires regardless of `refresh_zero_delta_streak`.

Triggers that explicitly do NOT fire a refresh: `blocked` / `errored` / non-resolving `noop` returns; `rebased` returns from drain-phase fix-rebase. See [RATIONALE → Refresh non-triggers](../do-work-RATIONALE.md#step-d--refresh-trigger-rules-worked-example) for the per-return discussion.

**Delta computation (drives the backoff streak).** After each refresh that actually ran, compare the new snapshot against `refresh_last_snapshot`:

- `main_ci.status` changed (e.g., `green → red`, `red → pending`, `unknown → green`, etc.) → **change**.
- `failing_pr_count_all` crossed the 10 threshold in either direction (e.g., `8 → 11` or `12 → 9`) → **change**. Movement within a side of the threshold (e.g., `12 → 15`) is not a change for backoff purposes — the divert decision doesn't flip.
- `failed_prs` gained any new entries during this refresh's failed-PR scan → **change**. Decrements aren't a change here — entries leave `failed_prs` via step B's slot release / step C's dispatch, not via the refresh.

If any of the three is a change → set `refresh_zero_delta_streak = 0`, update `refresh_last_snapshot`, update `refresh_last_at`. Otherwise → increment `refresh_zero_delta_streak`, still update `refresh_last_at`, leave `refresh_last_snapshot` unchanged.

See [RATIONALE → Refresh trigger worked example](../do-work-RATIONALE.md#step-d--refresh-trigger-rules-worked-example) for a step-by-step trace of the adaptive backoff on a quiet 30-completion session.

#### D-tail. Own-the-tail merge-completion sweeps (phase c — [#663](https://github.com/mattsears18/shipyard/issues/663))

Phase c of the [#659](https://github.com/mattsears18/shipyard/issues/659) own-the-tail epic adds three behaviors so `/do-work` drives its own PRs to merged **without** a human nudging a stalled tail. All three are **best-effort sweeps** (fire-and-forget; a failed sweep step never aborts the reconcile turn) and run **only on a refresh turn that a `shipped` / `green` / `flake` reconcile triggered** (triggers 1 and 2 in the [refresh trigger rules](#refresh-trigger-rules) above) — i.e. exactly when a PR just landed or a red PR just cleared, which is when a tail can newly stall. They do NOT run on the 5-min time-based fallback (nothing merged, so no dependent went stale) and are **skipped entirely during drain** (drain owns its own merge-train sweeps).

**1. CI auto-heal recap (flake classification + rerun discipline).** The single-PR half of CI auto-heal already lives in the `fix-checks-only` worker's [Infra-flake classification and re-run](../../agents/issue-worker/fix-checks-only.md#infra-flake-classification-and-re-run-load-bearing) ([#654](https://github.com/mattsears18/shipyard/issues/654)) and the orchestrator's [A.1 `flake #<M>` reconcile](#a1-parse-the-return-string). Nothing new is needed here for the *single-PR* flake — the worker classifies (four-signal infra gate + local-gate pass + no deterministic code error), re-runs the failed jobs, and returns `flake #<M>`; the orchestrator watches the re-run's outcome via the next PR-triage tick. This is the **classification-gated, non-speculative** rerun path — it is deliberately NOT gated by `ci.skip_speculative_rerun` (which governs only *blind*, undiagnosed reruns the orchestrator never issues); see [dispatch-rules.md §2c](./dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) for the full reconciliation. Sub-sweep 3 below extends flake/auto-repair thinking from one PR to a **cross-PR recurring signature**.

**2. Cross-PR dependency-update sweep (`gh pr update-branch`).** When a session PR merges, it advances the default branch — and any *other* open session PR whose branch is now merely **behind** that base (a stale base, no conflict) may sit unmergeable until something updates it. On a repo whose base-branch protection is **non-strict** (`strict_required_status_checks_policy == false`), GitHub does **not** auto-update behind PRs, so a shared-file fix that unblocks several dependents leaves them all stranded `BEHIND` with no push to re-trigger their merge. The sweep updates them directly — far cheaper than a full `fix-rebase` worker dispatch (no worktree, no agent, no Haiku spend), and correct precisely because a *behind-but-not-conflicted* PR needs only a base merge, not a conflict resolution.

For each open `@me` PR in `session_prs` (excluding any already in `in_flight` / `failed_prs` / `rebase_blocked_prs`), snapshot `mergeStateStatus` + the latest-per-name rollup, then:

```bash
# One batched projection over the session PRs (reuse the drain-phase gh-batch.sh
# pr-status shape). For each PR classify: BEHIND + healthy → update-branch;
# DIRTY → leave for drain's fix-rebase; anything else → no-op this sweep.
gh pr view <M> --repo <owner/repo> \
  --json mergeStateStatus,statusCheckRollup,headRefName \
  --jq '{merge: .mergeStateStatus,
         fails: ([.statusCheckRollup | group_by(.name)
                  | map(sort_by(.completedAt // .startedAt // "") | last) | .[]
                  | select((.conclusion // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))] | length)}'
```

- `merge == "BEHIND"` AND `fails == 0` → run `gh pr update-branch <M> --repo <owner/repo>` (merges the base into the head; GitHub re-triggers the PR's checks on the fresh head). This is the shared-fix-unblocks-dependents case. Log `[dep-update] PR #<M> was BEHIND after a sibling merge; ran gh pr update-branch (#663)`.
- `merge == "DIRTY"` → do **NOT** `update-branch` (it would fail on the conflict). Leave it — the [drain phase's `D_dirty` → fix-rebase path](./drain.md#drain-protocol) owns genuine conflicts; a mid-session DIRTY PR is already re-seeded into `session_prs` by [step D sub-step 2's inherited-DIRTY snapshot](#d-periodic-refresh).
- Any other `mergeStateStatus` (`CLEAN` / `BLOCKED` / `UNKNOWN` / `HAS_HOOKS`) → no-op this sweep.

**Bound the CI-minute cost.** Each `update-branch` re-triggers a full CI run on the updated head, so treat it like any other check-triggering action: skip the update when `ci.skip_drain_rebase == true` (the same "don't burn CI to un-stale a base" stance applies to `update-branch`, which is a cheaper rebase) and count each update against a per-poll ceiling so a large fan-out doesn't fire N simultaneous CI runs. `gh pr update-branch` is fire-and-forget — on any error (conflict raced in, permission denied, PR merged between snapshot and update) log `[dep-update] PR #<M> update-branch failed: <reason>; leaving for drain` and continue. This sweep never dispatches a worker and never blocks the turn.

**3. Recurring-failure-signature auto-repair.** A *single* red PR is handled by the [failed-PR scan → fix-checks dispatch](#d-periodic-refresh) path. But when the **same failure signature** reddens **multiple** PRs, that's a shared root cause (a common dependency bump broke every PR's typecheck; a shared helper regressed; a new lint rule fires repo-wide) — fixing it once on a canonical PR unblocks the whole cohort, and treating each red PR as an independent fix-checks target wastes a dispatch per PR re-solving the same defect. This sub-sweep detects the recurrence and dispatches **one** targeted fix-checks against the canonical PR, surfacing the pattern so the operator sees a systemic cause rather than a scatter of unrelated reds.

Maintain a **session-local** working-memory map (not mirrored to the session-state file, same posture as `main_ci_fix_attempts`):

```
recurring_failure_signatures = { <signature> → { prs: [<#M>...], canonical_pr: <#M|null>, dispatched: <bool> } }
```

- **Signature** is the stable cross-PR key: `<workflow-name>|<job-name>|<normalized-first-deterministic-error-line>`, where the error line is the first `error TS####` / lint-rule id / assertion message / compile error from the failing job's log, stripped of PR-specific paths and line numbers so the *same* defect on two PRs produces the *same* key. An **infra-flake signature** (cancelled-required-jobs / webserver-boot-timeout / setup-job-failure / runner-lost — the [#654](https://github.com/mattsears18/shipyard/issues/654) classes) is **excluded** from this map: those are per-PR runner starvation, already handled by the worker's flake rerun + the chronic-flake attempt bound, and are NOT a shared *code* root cause. Only **deterministic code errors** are keyed here.
- **Recording.** On each failed-PR scan (step D sub-step 2), for every red PR compute its signature from the latest-per-name failing job's log and append `<#M>` to `recurring_failure_signatures[<signature>].prs` (deduped).
- **Detection + auto-repair.** When a signature's `prs` set reaches **≥ 2 distinct PRs** AND `dispatched == false`, it's a recurring class. Set `canonical_pr` to the lowest-numbered affected PR, dispatch **one** `fix-checks-only` worker against it (via the normal step-C fix-checks dispatch, respecting the `--concurrency` cap and the `ci.*` pre-dispatch gates), set `dispatched = true`, and log `[recurring-failure] signature <sig> hit <N> PRs (<list>); dispatching canonical fix-checks against #<canonical_pr> (#663)`. Do **not** dispatch fix-checks against the *other* affected PRs this turn — the canonical fix, once merged, advances the base; sub-sweep 2's dependency-update sweep then un-stales the siblings and their re-run picks up the shared fix. If the siblings are still red after the canonical fix merges (the fix didn't cover them), the next failed-PR scan re-keys them under a *new* signature (the error moved) or they fall through to normal per-PR fix-checks.
- **Thrash guard.** `dispatched: true` is one-shot per signature — the map never re-dispatches the same signature, so a canonical fix that doesn't fully resolve the cohort can't loop. Reset a signature's entry (drop it from the map) only when its `prs` all go green (the class cleared). This mirrors `main_ci_fix_attempts`'s converge-on-green discipline: a working fix clears the counter; a genuinely-stuck shared cause surfaces in the [end-of-session summary](./cleanup-summary.md#end-of-session-summary) as a recurring-signature cohort for the next session (or a human) rather than re-dispatching forever.

### E. Invariant line (end of every steady-state turn)

After A → B → C → D, the **last thing emitted in the turn** is a single-line invariant check. Whenever you end a turn without one, you have skipped step C — go back and fix it. The `state=<state>` token also makes the per-turn write-through to the [session state file](../do-work.md#session-state-file) visible in-line. The `tokens_attributed=<bool>` token surfaces whether [step A.0](#a0-attribute-the-dispatchs-token-usage-mandatory--before-any-return-string-parsing)'s `bump-tokens` call actually fired on a reconcile turn — making spec-skipping visible the same way the `state=` token does for the session-state write-through. The `last_fresh_fetch=<HH:MM:SS|"never">` token surfaces the most recent backlog re-fetch (step C's lightweight re-check, step D's periodic refresh, or [drain.md's termination-assertion step 4](./drain.md#termination-assertion)) — making the [#195 regression](https://github.com/mattsears18/shipyard/issues/195) (terminating without a fresh fetch) visible as a stale timestamp on the invariant line that's about to declare idle. The `unfiltered_open_count=<N>` token (added in [#332](https://github.com/mattsears18/shipyard/issues/332)) surfaces the count of open issues the wide-fetch returned BEFORE the client-side eligibility filter ran — making a regression in the client-side filter itself ("raw_backlog=0 but unfiltered_open_count=29 — half the universe was dropped silently") visible to the user and to the next session's orchestrator without anyone having to manually re-run `gh issue list` to spot it.

**Steady-state format** (after a normal dispatch turn):

```
[invariant] in_flight=<n>/<concurrency> · ready_issues=<r> · scope_bg=<s> · failed_prs=<f> · divert_queue=<dq> · raw_backlog=<b> · unfiltered_open_count=<u> · dispatched_this_turn=<k> · defers_this_turn=<dt> · state=<state> · tokens_attributed=<true|false> · last_fresh_fetch=<HH:MM:SS|"never">
```

**Idle-proof format** (used ONLY when step C produced no dispatch AND `in_flight < concurrency`):

```
[invariant] in_flight=<n>/<concurrency> · ready_issues=<r> · scope_bg=<s> · failed_prs=<f> · divert_queue=<dq> · raw_backlog=<b> · unfiltered_open_count=<u> · dispatched_this_turn=0 · defers_this_turn=<dt> · state=<state> · tokens_attributed=<true|false> · last_fresh_fetch=<HH:MM:SS|"never"> · idle_reason="<reason>"
```

`scope_bg=<s>` is the count of background scoping agents currently in flight (fired by step 6 or step D's scope-refill). When `<s> > 0`, results are arriving asynchronously into `ready_issues` — a `parked (scope refill in flight)` idle_reason is valid and expected. When `<s> == 0` and `ready_issues == 0` and `raw_backlog > 0`, that is a gap: no scoping is in progress and no scoped candidates are ready — fire a background scope-refill burst this turn before ending it.

`<state>` is one of:
- `written` — the turn's `session-state.sh update` call succeeded.
- `noop` — no state mutation happened this turn (rare; mostly drain-poll turns where nothing moved).
- `degraded` — an `update` call failed and the orchestrator logged the `[session-state] update failed: …` advisory.
- `disabled` — step 1.5's `init` failed and the session is running without the file mirror.

A missing `state=` token is the same contract violation as a missing invariant line — re-run the write-through then re-emit.

`tokens_attributed=<true|false>` is the per-turn evidence flag for step A.0's MANDATORY attribution call:

- **`true`** — step A.0's `bump-tokens` call fired and returned successfully this turn. Required outcome on every **reconcile turn** (a turn where step A actually parsed an agent's return).
- **`false`** — step A.0 didn't fire this turn. Valid ONLY on **dispatch-only turns** (turns with no agent completion to reconcile — the initial pool fill at step 7, drain-poll turns where nothing returned, refresh-only turns triggered by the 5-min fallback).

`tokens_attributed=false` on a reconcile turn is a **contract violation** — the same severity as a missing invariant line or a missing `state=` token. If you find yourself emitting it that way, you skipped A.0. Go back, fire the `bump-tokens` call against the dispatch's usage payload, then re-emit the invariant. The one exception is the **logged-skip case**: if A.0 ran but the dispatch result had no `<usage>` block (or the helper call errored), the orchestrator must have already emitted the corresponding `[bump-tokens] …` advisory line earlier in the turn; in that case `tokens_attributed=false` is honest about the gap rather than a silent skip. A missing `tokens_attributed=` token entirely is a contract violation regardless — re-run A.0's compliance check and re-emit.

`last_fresh_fetch=<HH:MM:SS|"never">` is the per-turn evidence flag for whether the backlog has been re-fetched against the live tracker recently. It is set (UTC time-of-day) any time step C's lightweight backlog re-check fires, any time step D's periodic refresh fires, or any time [drain.md's termination-assertion step 4](./drain.md#termination-assertion) fires. Initial value is `"never"` until the first re-check runs in step 7's initial pool fill.

- **Staleness guard on the terminating idle-proof.** When the idle-proof's `idle_reason="all queues empty (terminating after in_flight drains)"` (the path that triggers handoff to drain), the `last_fresh_fetch` timestamp MUST be **within the last 60 seconds** of `now`. Note the semantics ([#662](https://github.com/mattsears18/shipyard/issues/662)): this idle_reason terminates the **dispatch loop** and hands off to the drain — it is NOT a session-complete signal. Session completion is the stronger [full-completion assertion](./drain.md#termination-assertion) the drain evaluates at exit (every session PR merged or confirmed external-blocked); an empty dispatch pool is only the drain-entry gate, so emitting this idle_reason means "stop dispatching, start driving the tail," never "session done." If it's older — or `"never"` — the invariant line is INVALID: the orchestrator is about to declare termination without verifying the live backlog. Don't emit the line; instead, run the [drain.md termination-assertion step 4](./drain.md#termination-assertion) fetch now, stamp `last_fresh_fetch` with the result, append any net-new issues to `raw_backlog`, retry dispatch from step C, and re-emit the invariant line with the fresh timestamp. This is the mechanical guard against the [#195 failure mode](https://github.com/mattsears18/shipyard/issues/195) — "I'm about to terminate but my last fresh fetch was 2 hours ago" is a contract violation, not a valid terminating idle-proof.
- The 60-second window matches step C's `gh-cached.sh --ttl 60` cache band — if the cache is still fresh, the orchestrator's about-to-terminate fetch hits the cache for ~0 token cost; if it's expired, the fetch goes live and the cost is one `gh` call.
- A missing `last_fresh_fetch=` token entirely is a contract violation regardless — re-run a backlog re-fetch and re-emit.

`unfiltered_open_count=<u>` is the per-turn evidence flag for the size of the wide-fetch universe BEFORE the client-side eligibility filter ran. It is set whenever step C's lightweight backlog re-check fires, whenever step D's periodic refresh fires, or whenever [drain.md's termination-assertion step 4](./drain.md#termination-assertion) fires — the same three call-sites that stamp `last_fresh_fetch`. Initial value is `0` until the first re-check runs in step 7's initial pool fill.

- **Divergence smell.** When `raw_backlog` is `0` but `unfiltered_open_count > 0` (in particular, when the gap is large — `raw_backlog=0` against `unfiltered_open_count=29`), that's a load-bearing signal the client-side filter dropped every issue. This is exactly the failure mode [#332](https://github.com/mattsears18/shipyard/issues/332) documented: a regression in the filter pass produces a false-empty backlog and the orchestrator drains while workable issues sit invisible. The user (and the next session's orchestrator) can spot the smell from the invariant line alone without needing to manually re-run `gh issue list`. This is purely an observability token — the orchestrator does NOT auto-retry on divergence; the gap is surfaced as a diagnostic for human (or future automated) investigation.
- A missing `unfiltered_open_count=` token entirely is a contract violation — re-run a backlog re-fetch (which sets both `last_fresh_fetch` AND `unfiltered_open_count` in one pass) and re-emit. The token defaulting to `0` on the initial pool-fill turn is acceptable; the violation is the token's complete absence from a turn that already fetched the backlog.

The `idle_reason` MUST be one of: `all queues empty (terminating after in_flight drains)`, `draining=true`, `all ready_issues collide with in_flight paths`, `all ready_issues blocked by soft-cap on <path> (×<N> active)`, `all ready_issues collide with in_flight lockfile sections (<section>×<N>, ...)`, or a concrete diagnostic string. Vague reasons ("waiting for completions", "merge train draining", "nothing to do right now") are NOT acceptable. The first value (`all queues empty (terminating after in_flight drains)`) marks **dispatch-loop** termination + drain handoff, **not** session completion ([#662](https://github.com/mattsears18/shipyard/issues/662)) — the drain then drives the tail and asserts the [full-completion condition](./drain.md#termination-assertion) (every session PR merged or confirmed external-blocked) before the session actually ends.

`defers_this_turn=<d>` is the count of issues added to `deferred_issues` during this turn. It is incremented each time a scope-agent returns a deferred shape (or an orchestrator-side mid-session defer is logged). Initial value per turn: `0`. A turn where `defers_this_turn > 0` is always visible in the invariant line regardless of whether `dispatched_this_turn > 0`.

**Self-check before ending the turn:** Run BOTH self-checks:

1. **Under-dispatch check.** If `in_flight < concurrency` AND `ready_issues + failed_prs + divert_queue + raw_backlog > 0` AND `dispatched_this_turn == 0`, that is a programming error in your own turn — re-run step C, find what was skipped, dispatch, and re-emit the invariant line. See [RATIONALE → Invariant line](../do-work-RATIONALE.md#step-e--why-the-invariant-line-is-load-bearing) for common causes.

2. **Over-defer check (the premature-drain-prevention check).** If `defers_this_turn > 0` AND `dispatched_this_turn == 0` AND `in_flight < concurrency`, that is the **over-deferring while idle** pattern — the exact condition that produces premature drain by constructing an empty-queue state via self-defers. **Do not end the turn.** Instead:
   - Re-examine each `deferred_issues` entry added this turn: does the defer reason name a specific blocker issue or PR? If yes, look up its current state (`gh issue view <blocker> --json state` or `gh pr view <blocker> --json state`). If the blocker is already CLOSED or MERGED, the defer reason is stale — remove the entry from `deferred_issues`, move the issue back to `raw_backlog`, and re-run step C.
   - If no stale defers were found, verify the turn had a legitimate reason for zero dispatches. A scope-agent batch in flight (`scope_bg > 0`) is a valid reason. All `ready_issues` colliding with `in_flight` paths is a valid reason. Empty `in_flight` + empty queues + all issues deferred is **not** a valid reason — that means the orchestrator is about to declare termination driven entirely by self-defers, which is the failure mode issue [#246](https://github.com/mattsears18/shipyard/issues/246) documented. In this case, add `idle_reason="defers_this_turn=<d> with no dispatches and open slots — verify defer reasons before proceeding to drain"` to the invariant line and do NOT proceed to drain; instead fire a fresh termination-assertion step 4 fetch to surface any issues the defers may have hidden.
   See [RATIONALE → Over-defer self-check](../do-work-RATIONALE.md#step-e--over-defer-self-check-rationale) for the failure mode this prevents.

