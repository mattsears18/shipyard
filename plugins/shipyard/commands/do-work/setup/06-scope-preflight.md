# /shipyard:do-work — Setup phase · scope pre-flight orchestrator-side checks

**Setup sub-phase (cluster 4 of 5, part 1 of 5 — [#994](https://github.com/mattsears18/shipyard/issues/994), re-split by [#1446](https://github.com/mattsears18/shipyard/issues/1446)).** Owns the start of step **6**: the initial scope pre-flight's execution model, the pre-scope synthetic-defer detectors, the scope-result freshness check, and the PR-collision cache-reuse check pointer — the three orchestrator-side checks that can each skip a scope-agent dispatch entirely. The [staleness probe](06g-scope-staleness-probe.md#staleness-probe--has-this-already-landed-on-origindefault-branch-992) and the scope agent's Ready/Deferred/Already-landed return-shape contracts moved to [`06g-scope-staleness-probe.md`](./06g-scope-staleness-probe.md) when this file crossed the token-budget warn band ([#1446](https://github.com/mattsears18/shipyard/issues/1446)) — same router/fragment precedent as [#611](https://github.com/mattsears18/shipyard/issues/611) / [#994](https://github.com/mattsears18/shipyard/issues/994) / [#1233](https://github.com/mattsears18/shipyard/issues/1233) / [#1431](https://github.com/mattsears18/shipyard/issues/1431). The rest of step 6 (design/arch/epic/spike carve-out, operator-slice + QA-verification carve-outs, per-class evidence shapes) continues in **[`06b-scope-carveouts.md`](./06b-scope-carveouts.md)**; per-returned-entry handling plus steps 6.5 → 6.8 (status-line + state-change-banner UI, setup-timing flush) continue in **[`06c-scope-handling-ui.md`](./06c-scope-handling-ui.md)** / **[`06e-scope-ui-timing.md`](./06e-scope-ui-timing.md)**. Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md). Prev: [`04j-failing-pr-snapshot.md`](./04j-failing-pr-snapshot.md). Next: [`06g-scope-staleness-probe.md`](./06g-scope-staleness-probe.md) (same cluster, part 2 of 5).

### 6. Initial scope pre-flight

> **Just-in-time when `concurrency == 1`.** At C=1 pre-flighting `2 × concurrency` (i.e., 2) candidates at setup is wasted token spend: by the time the single slot returns, rankings may have shifted (new comments, refined issues, closed blockers) and the pre-flighted decisions are stale. Instead, pre-flight **only the top candidate** immediately before each dispatch (inline with step 7 and step C). This converts the upfront batch-scope call into a single just-in-time call per dispatch. The rest of step 6's mechanics — ready/deferred shapes, `claimed_paths` partitioning, `deferred_issues` list, the comment-and-drop for deferred entries — are unchanged; only the timing (upfront vs per-dispatch) and the batch size (2 vs 1) change. Set `ready_issues = []` at startup; populate lazily.

**At C=1, the top candidate still gets the comment thread and a merged-PR check before the dispatch prompt is composed — "inline" is a statement about *who* runs this decision, not license to skip the checks it depends on ([#1162](https://github.com/mattsears18/shipyard/issues/1162)).** "Inline with step 7 and step C" above means the orchestrator can make the ready/deferred call itself, in its own turn, without spinning up a separate scoping `Agent` call for a single candidate — that's the cheap path this note exists to enable, and taking it is fine. It is NOT license to shortcut to an ad hoc, body-only read instead of mechanically running the checks "the rest of step 6's mechanics" already require. Concretely, before composing the dispatch prompt for the top candidate:

- **Read its comment thread** — `gh issue view <N> --repo <owner/repo> --json comments` (reuse an already-fetched projection when one exists; otherwise one cheap call). This is the same read [dispatch-rules.md's comment-thread-grounding rule](../dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) already requires before asserting any confidence/status claim in the prompt — a prior-session disposition comment, a maintainer's revision of the approach, or a recorded decision all live here and are invisible to a body-only read.
- **Run the [staleness probe](06g-scope-staleness-probe.md#staleness-probe--has-this-already-landed-on-origindefault-branch-992)'s merged-PR check** — `gh pr list --repo <owner/repo> --state merged --search "<N> in:body" --limit 5 --json number,mergedAt,title`. The step-4 backlog filter only joins against **open** PRs, so a merged PR that advanced the issue without a closing keyword leaves no other trace anywhere in the dispatch path — this is the only place that catches it at C=1.

Neither check licenses an automatic defer on a hit. Per [#1148](https://github.com/mattsears18/shipyard/issues/1148)/[#1154](https://github.com/mattsears18/shipyard/issues/1154)'s posture, a comment or a merged PR is **a reason to look, never an automatic defer** — a false defer silently drops real work, which costs more than a wasted dispatch. Read what turns up and either narrow the dispatch prompt to what's still actually true (the staleness probe's outcome-2 partial-landing shape) or proceed unaffected when nothing material surfaces — but never compose a "this is shippable now" framing that the comment thread or a merged PR would have contradicted.

**Rolling pre-flight (C≥2) — dispatch on the first result, don't wait for all.** The rolling model fires the `2 × concurrency` scoping-agent batch in the background and dispatches as soon as ONE entry lands in `ready_issues`, hiding the remainder of the scope latency behind real worker execution. See [RATIONALE → Rolling pre-flight dispatches on the first result (#233)](../../do-work-RATIONALE.md#step-6--rolling-pre-flight-dispatches-on-the-first-result-issue-233) for the latency this replaced.

**Execution model for C≥2:**

```
step 6 opens timing window
  └── fire 2N scoping Agent calls with run_in_background: true
        ↓ first result arrives → push to ready_issues → step 7 dispatches immediately
        ↓ subsequent results arrive → push to ready_issues (queue fills while workers run)
  timing window stays open until all background scope agents complete
  record-scope-preflight fires after the last background agent returns
```

**Timing instrumentation (issue #238).** Open the timing window before firing the batch; close it after the last background scoping agent returns. The `record-scope-preflight` call is also deferred to that point so `ready-count` and `deferred-count` reflect the full batch.

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
SCOPE_START_EPOCH=$(date -u +%s)
"$CLAUDE_PLUGIN_ROOT/scripts/setup-timing.sh" start \
  --session-id "<session-id>" --phase step_6_scope_preflight 2>/dev/null || true

# ... fire all 2N scoping agents with run_in_background: true ...
# ... step 7 dispatches the moment the first result lands in ready_issues ...
# ... remaining scope results arrive asynchronously and push to ready_issues ...
# ... after the LAST background scope agent completes: ...

SCOPE_END_EPOCH=$(date -u +%s)
SCOPE_ELAPSED=$(( SCOPE_END_EPOCH - SCOPE_START_EPOCH ))

"$CLAUDE_PLUGIN_ROOT/scripts/setup-timing.sh" end \
  --session-id "<session-id>" --phase step_6_scope_preflight 2>/dev/null || true

# Record the per-candidate metrics for reporting.
"$CLAUDE_PLUGIN_ROOT/scripts/setup-timing.sh" record-scope-preflight \
  --session-id "<session-id>" \
  --candidates-scoped "$candidates_dispatched" \
  --ready-count "${#ready_issues[@]}" \
  --deferred-count "$deferred_count" \
  --elapsed-seconds "$SCOPE_ELAPSED" 2>/dev/null || true
```

#### Pre-scope orchestrator-side detectors (synthetic defers)

**Before dispatching a scope agent against each candidate, run a small set of mechanical detectors on the issue body.** When a detector fires, the orchestrator synthesizes a deferred entry directly and **skips the scope-agent dispatch** for that candidate — the detector's evidence is already conclusive. See [RATIONALE → Pre-scope orchestrator-side detectors (#346)](../../do-work-RATIONALE.md#step-6--pre-scope-orchestrator-side-detectors-issue-346) for why this defense-in-depth layer exists and the failure mode it prevents.

The detector batch runs once per candidate, synchronously, immediately before the per-candidate scope-agent dispatch. Each detector starts from a cheap string-match against the issue body — no network calls, no `gh` round-trips — and then applies a framing test to decide whether the match is actually the shape the detector guards. A candidate that trips any detector never reaches the scope-agent dispatch step.

**Detector 1 — a `.github/workflows/` edit a worker is actually forbidden to make ([#346](https://github.com/mattsears18/shipyard/issues/346), narrowed by [#1481](https://github.com/mattsears18/shipyard/issues/1481)).** The path fragment `.github/workflows/` appearing in the issue body (case-sensitive; prose mentions like *"add `.github/workflows/security.yml`"* and code-fence headers like ```` ```yaml .github/workflows/ci.yml ```` both count) is the detector's **entry condition, not its firing condition**. Apply the four-way framing test below across every occurrence in the body; fire only on cases 1 and 2.

1. **CI-gating framing (FIRE).** The workflow — or branch-protection — edit's stated purpose is to make a failing check pass, skip / disable / remove a required check, relax a gate, or otherwise bypass CI. This is the one flat, unscopeable prohibition: [`issue-work.md`'s Don't list](../../../agents/issue-worker/issue-work.md) and [`fix-checks-only.md`'s Don't list](../../../agents/issue-worker/fix-checks-only.md) both read *"Don't edit `.github/workflows/` or branch protection **to make a check pass**"*, so a worker dispatched here can only refuse. Signals: a workflow path alongside *"make the check pass"*, *"skip"*, *"disable"*, *"drop the required check"*, *"bypass"*, *"loosen"*, *"relax the gate"*.
2. **Incidental scope-creep framing (FIRE).** The workflow edit is **not** the issue's stated deliverable — it rides along inside a *"Suggested fix"* / *"Suggested approach"* block that reaches beyond the reported problem's surface area. This is [`issue-work.md` step 2's](../../../agents/issue-worker/issue-work.md) scope-creep guard, which tells the worker **not** to follow the suggestion, to implement the smallest fix that addresses the symptom, and to bail `blocked: suggested fix exceeds expected scope — needs human review` when the smallest fix doesn't. Deferring puts that scoping call in front of the maintainer who can actually make it, instead of spending a dispatch to reach a coin-flip.
3. **Deliverable framing (DO NOT FIRE).** The workflow change **is** the issue's explicitly-scoped deliverable — the title and/or acceptance criteria name it (*"rewrite the `on:` triggers across the six workflow files"*, *"add the missing concurrency group to both `metadata-push-*.yml`"*). No worker rule forbids this; the candidate proceeds to a normal scope-agent dispatch.
4. **Pure meta-mention (DO NOT FIRE).** Every occurrence is incidental meta-discussion — an issue *about* this detector or the dispatch loop, a retro narrating a prior session, a spec quotation. Identical in shape to Detector 2's incidental case ([#591](https://github.com/mattsears18/shipyard/issues/591)); [#1481](https://github.com/mattsears18/shipyard/issues/1481) itself is the canonical fixture, naming `.github/workflows/` a dozen times while requesting no workflow edit at all.

**When in doubt, do NOT fire — deliberately the opposite of Detector 2's asymmetry ([#1481](https://github.com/mattsears18/shipyard/issues/1481)).** Detector 2 guards a harness-level **HARD BLOCK** that no dispatch can ever clear, so its false-pass cost is a guaranteed full wasted dispatch and its in-doubt bias is *fire*. Detector 1 guards nothing of the kind: a false pass here costs at most a **partial** dispatch that a documented backstop already catches (the auto-mode classifier's [two-denial hand-back](../dispatch-rules.md#3-on-a-second-denial-stop-hand-back-to-the-human-never-a-third-attempt)), while a false **defer** costs a whole issue — stamped `needs-human-review`, removed from `raw_backlog`, and thereby dropped out of the re-scope loop, invisible unless a human questions it. The one measurement anyone has taken inverts the asymmetry outright: on `mattsears18/lightwork` (session `8079ffb9-a428-4906-9619-14944e0881c3`, 2026-08-19) the pre-#1481 unconditional match selected roughly a third of the dispatchable backlog; all 8 issues dispatched over the detector's objection shipped and merged, and **none** hit a worker hard rule or a classifier denial on workflow grounds.

**The pre-#1481 premise was false and must not be restored.** The detector previously asserted that *"workers' hard rules … all forbid `.github/workflows/` modifications"*, and concluded from that a dispatched worker could only strand a branch with no PR. Every clause of that is wrong against the specs it cited: the two Don't-list rules are the narrow anti-CI-gaming rule quoted in case 1; the two step-2 rules are the suggested-fix scope-creep guard (case 2) and the untrusted-comment out-of-scope-action gate, neither of which is a blanket prohibition. Worse, this codebase contains a whole worker mode — [`fix-main-ci`](../../../agents/issue-worker/fix-main-ci.md) — whose job routinely *is* editing workflow files, plus an entire machinery for shipping workflow-touching PRs ([#812](https://github.com/mattsears18/shipyard/issues/812)'s worker-side report, [step 1.35](01-repo-recovery.md#135-preflight-warn-on-missing-gh-workflow-oauth-scope-818)'s proactive warning, `cleanup-summary.md`'s `workflow_scope_blocked_prs` banner) that would be dead code if the premise held. See [RATIONALE → Detector 1 narrowed (#1481)](../../do-work-RATIONALE.md#step-6--detector-1-narrowed-the-blanket-workflows-defer-was-built-on-a-false-premise-issue-1481) for the full evidence, the measured error rate, and why the issue's higher-ranked options 1 and 2 were declined.

**Two things that are explicitly NOT reasons to fire.**

- **The `gh` token's `workflow` OAuth scope.** A token missing `workflow` does not stop a worker from opening a workflow-touching PR — it blocks only `enablePullRequestAutoMerge`, and that outcome is already handled end-to-end (worker returns `auto-merge: unavailable — gh token lacks workflow scope`, the PR stays open and hand-mergeable, and the session banner names the one-time `gh auth refresh` fix). Note also that [step 1.35](01-repo-recovery.md#135-preflight-warn-on-missing-gh-workflow-oauth-scope-818)'s verdict **cannot** answer "does this token carry `workflow`?" even if you wanted it to: [`detect-missing-workflow-scope.sh`](../../../scripts/detect-missing-workflow-scope.sh) emits `warn`/`silent`, and `silent` conflates *has the scope* with *lacks it but no session signal*. Do not consult it here, and do not add a probe for it — it is the wrong lever, not a missing one.
- **The harness auto-mode classifier.** It *may* deny a workflow write on a given dispatch, but that is a per-dispatch, late-catchable condition with an existing backstop, not a deterministic pre-dispatch fact — which is exactly why [`dispatch-rules.md`](../dispatch-rules.md#3-on-a-second-denial-stop-hand-back-to-the-human-never-a-third-attempt) treats "the worker really will modify `.github/workflows/`" as a *hand-back after denial*, not a reason to never dispatch.

When case 1 or case 2 fires, synthesize a deferred entry:

```
{
  issue: N,
  reason: "<case-specific reason — see the two variants below>",
  defer_reason_class: "human-decision-required",
  evidence_pointer: "Proposes .github/workflows/<filename-or-path-fragment> change <case-specific tail>",
  provenance: "orchestrator-judgment",
  deferred_at: "<current ISO-8601 UTC>"
}
```

- **Case 1 (CI-gating).** `reason`: *"Issue asks for a `.github/workflows/` or branch-protection edit whose purpose is to make a check pass / relax a CI gate — every worker mode's Don't list forbids this outright, so no dispatch can ship it. Needs a maintainer to decide whether the gate itself should change."* `evidence_pointer` tail: `to make a check pass or relax a CI gate — worker anti-CI-gaming hard rule forbids it`.
- **Case 2 (incidental scope-creep).** `reason`: *"The `.github/workflows/` edit in this issue is incidental to its stated deliverable — it rides in a suggested-fix block that reaches beyond the reported problem's surface area, which issue-work.md step 2 tells the worker not to follow. Needs a maintainer to decide whether the CI change is in scope, or to split it into its own issue."* `evidence_pointer` tail: `incidental to the issue's stated deliverable — CI scope-creep beyond the reported problem's surface area needs maintainer scoping`.

Both tails preserve the structured prefix `Proposes .github/workflows/` that the [per-class evidence-shape validator](06b-scope-carveouts.md#per-class-evidence-shapes--what-evidence_pointer-must-look-like) and [`06c`'s accepted-prefix list](06c-scope-handling-ui.md) key on — the prefix is the contract, the tail is human-readable detail.

`<filename-or-path-fragment>` is extracted by reading the first `.github/workflows/<token>` substring in the body, taking the token up to the first whitespace, backtick, or newline. If extraction fails (e.g., the body just mentions `.github/workflows/` without naming a file), use the literal token `<unspecified>`. The point is the evidence_pointer's structured prefix `Proposes .github/workflows/`, not the file's exact name — the validator (next section) keys on the prefix.

`provenance: "orchestrator-judgment"` is correct here: the orchestrator (not a scope agent) made this defer. Per [`do-work.md`'s `deferred_issues` entry](../../do-work.md#orchestrator-state), `orchestrator-judgment` provenance entries get re-validated by [drain.md 5.a](../drain.md#5a--re-validate-orchestrator-judgment-entries) before drain — that re-validation dispatches a fresh scope agent, which (per the cross-reference at the end of this section) ALSO re-runs the pre-scope detector batch first. The synthetic defer stays valid across re-validation as long as the body still satisfies case 1 or case 2 — a body that merely still *names* a workflow path is no longer sufficient.

**Detector 2 — Claude-Code self-modification target proposal.** The matched path set is **config-driven** via `scope.self_modification_paths` (issue [#591](https://github.com/mattsears18/shipyard/issues/591)) — default `[".claude/settings.json", ".claude/settings.local.json", ".mcp.json", ".claude/hooks/"]`. Resolve the effective array from the merged config at session start (it lives alongside `scope.diagnosis_reuse_hours`); a trailing-slash entry (e.g. `.claude/hooks/`) matches **any path under that directory** (so `.claude/hooks/stop-after-edit.sh` and a bare `.claude/hooks/` both fire). When an issue's **deliverable** is editing one of these paths, the body is proposing a Claude-Code self-modification change. Claude Code's auto-mode classifier treats edits to these paths as **Self-Modification** and applies a HARD BLOCK that is **not cleared by user intent** — even explicit "make this edit" instructions are rejected, so the Edit / Write / Bash-heredoc paths are all blocked at the harness level. A worker dispatched against such an issue burns tokens producing the proposed diff before hitting that wall. The structurally correct outcome is the same as Detector 1: skip the dispatch, defer for human review. See issue [#348](https://github.com/mattsears18/shipyard/issues/348) for the original repro, [RATIONALE → Detector 2 (#348)](../../do-work-RATIONALE.md#step-6--detector-2-claude-code-self-modification-target-proposals-issue-348), and [RATIONALE → Detector 2 extension (#591)](../../do-work-RATIONALE.md#step-6--detector-2-extension-config-driven-paths-claudehooks-deliverable-vs-mention-guard-issue-591) for the failure-mode detail.

**Deliverable-vs-mention guard (avoid false-positives on meta-issues — [#591](https://github.com/mattsears18/shipyard/issues/591)).** A naïve "body contains the path fragment anywhere" match false-positives on **meta-issues that merely _discuss_ these paths in prose** rather than proposing to edit them — most notably issue #591 itself, whose body names all four paths while describing the *detector*, not requesting a config edit. The detector fires only when a configured path appears in a **deliverable context** — i.e. the path is what the issue asks the worker to create or modify — not when it is mentioned incidentally. Apply this two-part test against each configured path fragment found in the body:

1. **Deliverable context (fire).** The path appears in an acceptance-criteria / suggested-fix / "create" / "add" / "edit" / "wire" framing — e.g. *"add a Stop hook to `.claude/settings.json`"*, *"wire MCP servers via `.mcp.json`"*, a code-fence header naming the path as the file to write (```` ```json .claude/settings.json ````), or an acceptance-criteria bullet whose object is the path. This is the case the detector exists for.
2. **Incidental mention (do NOT fire).** Every body occurrence of the path is inside meta-discussion *about* shipyard/do-work machinery — the issue is about the detector, the classifier, the dispatch loop, scope pre-flight, or a config knob, and the path is named as an *example of what the machinery handles* rather than as the file the worker must touch. Signals: the path appears next to words like *"detector"*, *"pre-defer"*, *"scope pre-flight"*, *"Auto-Mode-denied set"*, *"classifier"*, *"denied"*, or appears only inside a `## Repro` / `## Summary` paragraph narrating a prior session. When **every** occurrence is incidental, the detector does NOT fire and the candidate proceeds to a normal scope-agent dispatch.

When in doubt between (1) and (2) — i.e. the body has both a deliverable framing AND meta-discussion — **prefer firing** (defer). A false-defer costs a human one glance at an issue that was actually shippable; a false-pass costs a full ~100k-token wasted worker dispatch, which is the exact failure mode this detector exists to prevent. The asymmetry favors deferring. The one place to NOT fire is when *every* occurrence is unambiguously meta (the #591-about-the-detector shape).

When the detector fires, synthesize a deferred entry:

```
{
  issue: N,
  reason: "Issue deliverable is a Claude-Code self-modification target change (.claude/settings.json, .claude/settings.local.json, .mcp.json, or a .claude/hooks/ file) — the auto-mode classifier applies a HARD BLOCK on edits to these paths that is not cleared by user intent, so no worker can ship the change. Needs a maintainer to apply the proposed diff manually (or, if not running under Auto Mode, to clear scope.self_modification_paths so the worker can ship it).",
  defer_reason_class: "human-decision-required",
  evidence_pointer: "Proposes <self-modification-path> change — Claude-Code self-modification HARD BLOCK requires human application (auto-mode classifier blocks worker dispatch)",
  provenance: "orchestrator-judgment",
  deferred_at: "<current ISO-8601 UTC>"
}
```

`<self-modification-path>` is the first matching configured path fragment found in a deliverable context (checked in `scope.self_modification_paths` order; longer-prefix wins so `.claude/settings.local.json` is reported correctly when both prefixes would technically match, and a `.claude/hooks/<file>` match reports the directory prefix `.claude/hooks/`). If multiple paths are mentioned, report only the first match; the maintainer reading the issue will see the full body. The point — same as Detector 1 — is the evidence_pointer's structured prefix `Proposes .claude/` or `Proposes .mcp.json`, not the exact file. The validator (next section) keys on the prefix family, not the specific path.

**Class: `human-decision-required`, not `confirmed-non-shippable-as-single-PR`.** The deliverable here IS shippable as a single PR — it's one config-file edit blocked by a policy decision (the Auto-Mode classifier's hard block), not by anything multi-phase or dependency-gated. `confirmed-non-shippable-as-single-PR` would mislabel it and hand it to `/decompose-epic`, which would try to shard a one-file edit — nonsensical. See [RATIONALE → Detector 2 extension (#591)](../../do-work-RATIONALE.md#step-6--detector-2-extension-config-driven-paths-claudehooks-deliverable-vs-mention-guard-issue-591) for the full reasoning behind declining the issue's suggested class.

`provenance: "orchestrator-judgment"` is correct here, and the handling steps and cross-references in the Detector 1 section apply unchanged — both detectors share the same recording path (skip the per-class validator; post the standard `Scope-preflight diagnosis (not auto-fixable as a single worker): <reason>` comment with the `<!-- do-work-human-decision-required -->` marker; append to `deferred_issues`; apply `needs-human-review`; remove from `raw_backlog`; increment `defers_this_turn`; do NOT dispatch a scope agent).

**`CLAUDE.md` is intentionally excluded from the matched path set.** Only a narrow subset of `CLAUDE.md` edits (behavior-rule changes) hits the HARD BLOCK; most ship cleanly through workers, so a blanket match would defer substantial shippable work. See [RATIONALE → Detector 2 (#348)](../../do-work-RATIONALE.md#step-6--detector-2-claude-code-self-modification-target-proposals-issue-348) for the full reasoning.

**Detector 3 — Orchestrator-only skill/command invocation proposal ([#1294](https://github.com/mattsears18/shipyard/issues/1294)).** The matched skill/command name set is **config-driven** via `scope.orchestrator_only_skills` — default `["shipyard:update-roadmap", "update-roadmap"]` — resolved the same way as `scope.self_modification_paths` above, at session start. When an issue's acceptance criteria, in a **deliverable context**, explicitly instruct a worker to invoke one of these tokens (e.g. *"run the `shipyard:update-roadmap` skill cold"*, *"step 2: invoke `/shipyard:update-roadmap`"*), the body is asking for something a dispatched `mode: issue-work` worker is structurally forbidden from ever doing: both `shipyard:worker-preamble`'s [`milestone-prohibition.md`](../../../skills/worker-preamble/milestone-prohibition.md) fragment and the named skill's own frontmatter/"Who runs this" section state the orchestrator-only boundary unambiguously. A worker dispatched against such an issue reads the target skill before invoking it (per its own [step 4](../../../agents/issue-worker/issue-work.md#4-implement) instruction), discovers the conflict, and can only return `blocked` — a full dispatch spent to arrive at a foregone conclusion. This is the exact repro [#1294](https://github.com/mattsears18/shipyard/issues/1294) documents (found via `#1244`'s own dispatch). Synthesize a deferred entry:

```
{
  issue: N,
  reason: "Issue acceptance criteria call for invoking an orchestrator-only skill/command (`<name>`) that a dispatched issue-work worker is spec-prohibited from ever invoking (see skills/worker-preamble/milestone-prohibition.md and <name>'s own orchestrator-only boundary) — no worker dispatch can complete this AC as written. Needs a human to run the orchestrator-only skill/command directly (from the orchestrator's own turn, or a maintainer's own session), or to re-scope the issue to the portion that doesn't require it.",
  defer_reason_class: "human-decision-required",
  evidence_pointer: "Proposes invoking orchestrator-only skill/command `<name>` — a dispatched worker cannot invoke it (milestone-prohibition.md / the skill's own orchestrator-only boundary blocks worker dispatch)",
  provenance: "orchestrator-judgment",
  deferred_at: "<current ISO-8601 UTC>"
}
```

`<name>` is the first matching configured token found in a deliverable context (checked in `scope.orchestrator_only_skills` order). If multiple tokens are mentioned, report only the first match.

**Deliverable-vs-mention guard — apply the identical two-part test Detector 2 uses above.** Fire only when a configured token appears in a deliverable/acceptance-criteria framing ("run", "invoke", a numbered AC step whose action is the skill itself) — not when every occurrence is incidental meta-discussion (an issue *about* the orchestrator-only boundary, a retrospective narrating a prior session's `blocked` return, this detector's own spec prose). This guard is what keeps the detector from firing on #1294 itself, which discusses `shipyard:update-roadmap` at length without ever instructing a worker to invoke it. When in doubt between deliverable and incidental, prefer firing — same asymmetry as Detector 2: a false defer costs one human glance, a false pass costs a full wasted dispatch that can only rediscover the same prohibition.

**Whole-issue defer, not a slice.** Unlike Detector 2 (which guards an absolute harness-level classifier block with zero possible partial credit — and unlike Detector 1, which since [#1481](https://github.com/mattsears18/shipyard/issues/1481) guards only the two narrow shapes a worker genuinely cannot ship), the orchestrator-only boundary is a spec-level prohibition — an issue like this can still have an independently-shippable code portion (exactly what happened when the worker dispatched against #1244 shipped the `milestones` config block while declining to run `shipyard:update-roadmap` itself). This detector defers the issue as originally worded rather than attempting to auto-slice it; a maintainer who wants the safe portion shipped immediately can file a narrower follow-up issue scoped to just that slice, or clear the gate and let a fresh scope pass find the phase-1 slice on its own (scope-preflight's normal phase-slicing bias — see [Design/architecture/epic/spike decisions are in-scope by default](06b-scope-carveouts.md#designarchitectureepicspike-decisions-are-in-scope-by-default-not-a-defer-reason-767) — already applies once a human has cleared the orchestrator-only step or the issue is re-scoped to drop it).

`provenance: "orchestrator-judgment"` and the handling steps from Detector 1 apply unchanged (skip the per-class validator; post the standard `Scope-preflight diagnosis (not auto-fixable as a single worker): <reason>` comment with the `<!-- do-work-human-decision-required -->` marker; append to `deferred_issues`; apply `needs-human-review`; remove from `raw_backlog`; increment `defers_this_turn`; do NOT dispatch a scope agent).

**Handling the synthetic deferred entry.** Apply the same recording path as a scope-agent-returned defer (per [Handling each returned entry → Deferred entries → Recording path](06c-scope-handling-ui.md#handling-each-returned-entry-fires-as-each-background-agent-completes)):

1. **Skip the per-class validator.** The orchestrator constructed this entry; its `evidence_pointer` already matches the per-class shape table (`human-decision-required` accepts the `Proposes .github/workflows/` structured prefix — see the [Per-class evidence shapes](06b-scope-carveouts.md#per-class-evidence-shapes--what-evidence_pointer-must-look-like) table below). Running the validator against the orchestrator's own synthesis would be redundant.
2. **Post the comment.** Apply the comment dedupe check (recording-path step 1) and post with the class-specific body marker (`<!-- do-work-human-decision-required -->` for `human-decision-required` defers) per the recording-path step 2 marker table. The maintainer reading the issue sees a clear explanation of why the workflow proposal is gated.
3. **Append to `deferred_issues`** with the synthesized entry exactly as shown above.
4. **Remove the issue from `raw_backlog`** as part of the standard "remove every processed issue number" sweep (line below the per-entry handler).
5. **Increment `defers_this_turn`** by 1 (same as scope-agent defers — feeds step E's invariant line and the pre-drain audit).
6. **Do NOT dispatch a scope agent for this candidate.** The detector's evidence is conclusive; spending a scope-agent's ~30 s + tokens on a defer the orchestrator already knows it will produce is waste.

**This detection lives at the orchestrator, not in the scope-agent prompt** — a prompt instruction isn't a contract and wouldn't survive a stale agent version. See [RATIONALE → Pre-scope orchestrator-side detectors (#346)](../../do-work-RATIONALE.md#step-6--pre-scope-orchestrator-side-detectors-issue-346) for the full argument.

**Future detectors.** The detector batch is intentionally extensible — when a new "worker hard rule conflicts with a recurring body shape" failure mode shows up, file an issue documenting the pattern and add a new detector here. Detectors share the same shape: a pure body string-match → a synthesized deferred entry with `provenance: "orchestrator-judgment"` and a structured `evidence_pointer` that matches the validator's per-class shape. See [RATIONALE → Pre-scope orchestrator-side detectors (#346)](../../do-work-RATIONALE.md#step-6--pre-scope-orchestrator-side-detectors-issue-346) for the extensibility rationale.

**Cross-references for re-validation paths.** [Drain.md 5.a's re-validation](../drain.md#5a--re-validate-orchestrator-judgment-entries) dispatches a fresh scope agent for `orchestrator-judgment` defers and [5.b's re-validation](../drain.md#5b--re-validate-scope-agent-and-cached-diagnosis-entries) does the same for `scope-agent` defers. Both paths re-run the **same per-candidate pre-scope detector batch** documented in this section before firing the scope agent — a re-detected trigger synthesizes the defer again without dispatching the agent. See [RATIONALE → Pre-scope orchestrator-side detectors (#346)](../../do-work-RATIONALE.md#step-6--pre-scope-orchestrator-side-detectors-issue-346) for why this matters.

#### Self-declared agent-limitation re-validation — never trust an issue's own "out of scope for an agent" claim ([#1491](https://github.com/mattsears18/shipyard/issues/1491))

**Runs immediately after the detector batch, on every candidate that survived it.** This check is the *inverse* of a detector: a detector concludes the orchestrator should skip a dispatch; this one concludes the orchestrator should stop believing a reason to narrow one. An issue body is a snapshot of what was true when it was filed, and capability grants — token scopes, new tooling, a lifted policy — move independently of it. Scope pre-flight validates that an issue is *shippable*; nothing anywhere in the loop asks whether an issue's **self-declared limitation on the agent** is still true. This is the same class the `evidence_pointer` re-validation machinery exists for, applied to a claim about the agent rather than a claim about a blocker.

Real repro ([#1491](https://github.com/mattsears18/shipyard/issues/1491), session `do-work-20260820T024447Z-51928` against `mattsears18/lightwork`): two issues declared, in their own bodies, that the `.github/workflows/` half of their work was *"out of scope for an autonomous `/shipyard:do-work` worker in this repo"* and handed it to a human. Both premises were **false at dispatch time** — the dispatching `gh` token carried the `workflow` scope, so both shipped the full deliverable once the stale premise was corrected in the prompt. Four more issues in the same backlog were shaped by the same assumption. Taken at face value, each would have shipped half a feature and filed a spurious `agent-console` hand-back for work the agent could do itself — and because a hand-back looks like a legitimate outcome in every summary, the loss is invisible unless a human questions it.

Run the check. It is a **script, not a rule for you to re-derive**:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
gh issue view <N> --repo <owner/repo> --json body --jq '.body' > .shipyard-scratch/issue-<N>-body.md
"$CLAUDE_PLUGIN_ROOT/scripts/detect-stale-agent-limitation.sh" .shipyard-scratch/issue-<N>-body.md
```

It prints one line — `verdict=<v> class=<c> capability=<s> phrase=<p>` — and always exits 0:

| `verdict` | What it means | What the orchestrator does |
|---|---|---|
| `no-claim` | the body declares no agent limitation this check can probe (the common case) | nothing — no-op |
| `stale` | the body claims the agent can't; live session state says it can | (a) never let that claim feed a defer, and (b) render the [stale-agent-limitation augmentation](../dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) into the dispatch prompt |
| `upheld` | the body's claim about the capability still holds | nothing — no-op (see the boundary note below) |
| `indeterminate` | the capability could not be established | nothing — treat exactly like `no-claim`; never synthesize a correction from an unresolvable probe |

**A `stale` verdict promotes and demotes nothing by itself.** It gates no dispatch, produces no defer, and reorders no ranking — its entire effect is (a) a standing prohibition on the body's self-declared limitation being accepted as evidence for a defer (see [`06b`'s rejected `evidence_pointer` shapes](06b-scope-carveouts.md#per-class-evidence-shapes--what-evidence_pointer-must-look-like)) and (b) one correction paragraph in the dispatch prompt. (b) is load-bearing rather than decorative: a worker reading the body will otherwise re-derive the same wrong conclusion the body states. The phrasing that worked on the live repro was *"one premise in the issue body is stale and you should not act on it … Do the workflow edit."*

**Deliberately narrow, and deliberately allowed to over-fire.** The scan fires only when one paragraph of the body BOTH declares an agent limitation (*"out of scope for … worker"*, *"handed back"*, *"requires a human"*, *"an agent cannot"*) AND names a capability the script can mechanically probe — today exactly one class, `workflow-scope`, anchored on the literal path fragment `.github/workflows`. It is **not** a general-purpose "second-guess the issue author" heuristic and must not grow into one: a new class earns its place only when it ships with a real probe of live session state, never with a judgment call. Because the only action is advisory, the asymmetry is the **opposite** of [Detector 2's](#pre-scope-orchestrator-side-detectors-synthetic-defers) — a false correction costs one advisory sentence, a missed one costs a wrongly-narrowed dispatch — so a meta-issue that merely *quotes* the shape is a tolerated over-fire, not a bug to guard against. [#1491](https://github.com/mattsears18/shipyard/issues/1491)'s own body is the canonical such fixture.

**`upheld` is a no-op, not a defer — and that is this check's deliberate boundary.** A token that genuinely lacks `workflow` still does not stop a worker from opening a workflow-touching PR; it blocks only `enablePullRequestAutoMerge`, which [#812](https://github.com/mattsears18/shipyard/issues/812) / [#818](https://github.com/mattsears18/shipyard/issues/818) already handle end-to-end. So on an `upheld` verdict the body's *conclusion* ("hand it to a human") is still wrong — but re-litigating a conclusion whose stated premise holds is beyond re-validating the premise, and this check does not attempt it. The [two-things-that-are-explicitly-NOT-reasons-to-fire note](#pre-scope-orchestrator-side-detectors-synthetic-defers) above already forbids deferring on a missing `workflow` scope; nothing here changes that.

**Do NOT substitute [`detect-missing-workflow-scope.sh`](../../../scripts/detect-missing-workflow-scope.sh) for this probe.** Its verdict vocabulary is `warn`/`silent`, and `silent` conflates *has the scope* with *lacks it but no session signal* — it structurally cannot answer "does this token carry `workflow`?", which is exactly why Detector 1's note above forbids consulting it for this purpose. [`detect-stale-agent-limitation.sh`](../../../scripts/detect-stale-agent-limitation.sh)`--probe workflow-scope` is the probe that can: it reads `gh auth status`'s `Token scopes:` line directly and reports tri-state `has` / `lacks` / `unknown`, keeping "can't tell" (a fine-grained PAT, a `GITHUB_TOKEN`, no line at all) distinct from "lacks".

#### Scope-result freshness check (skip dispatch when a fresh diagnosis comment exists)

**After the pre-scope detector batch, before dispatching a scope agent, check whether a reusable fresh diagnosis already exists on the issue.** This avoids re-dispatching scope agents whose conclusions are already documented as marker-tagged comments on the issue. See [RATIONALE → Scope-result freshness check (#563)](../../do-work-RATIONALE.md#step-6--scope-result-freshness-check-issue-563) for the repro that motivated this.

**The freshness window** is `scope.diagnosis_reuse_hours` (config knob, default 72h). Set to `0` to disable the cache entirely and always dispatch a fresh scope agent.

**Check applies to each candidate** after the detector batch (which runs first — a detector match short-circuits into an `orchestrator-judgment` defer regardless of any cached comment):

1. **Fetch the issue's recent comments.** Use the `comments` field from the step 0 issue-view projection (already in context), or re-fetch with `gh issue view <N> --repo <owner/repo> --json comments`. Look for the **newest comment** whose body opens with one of the class-specific body markers listed in the [Deferred entries → Recording path](06c-scope-handling-ui.md#handling-each-returned-entry-fires-as-each-background-agent-completes) table (`<!-- do-work-needs-decomposition -->`, `<!-- do-work-external-dependency -->`, `<!-- do-work-human-decision-required -->`, `<!-- do-work-classifier-undispatchable -->`, `<!-- do-work-time-gated -->`). The `<!-- do-work-needs-decomposition -->` marker maps to `confirmed-non-shippable-as-single-PR`; `<!-- do-work-external-dependency -->` maps to `external-dependency`; both `<!-- do-work-human-decision-required -->` and `<!-- do-work-classifier-undispatchable -->` map to `human-decision-required` — the latter is a **distinct marker for a distinct sub-case** ([#953](https://github.com/mattsears18/shipyard/issues/953)): it is never returned by a scope agent, only synthesized by [`dispatch-rules.md`'s two-denial hand-back](../dispatch-rules.md#3-on-a-second-denial-stop-hand-back-to-the-human-never-a-third-attempt) when the harness permission classifier denies dispatch itself (no worker ever ran), as opposed to a scope agent's own read of the issue's content. Both markers share the `human-decision-required` class because both situations resolve the same way — a human either does the work by hand or makes a policy call — but the distinct marker keeps the two provenances distinguishable for `/shipyard:my-turn` and for a human skimming the comment thread. `<!-- do-work-time-gated -->` maps to `time-gated` ([#1165](https://github.com/mattsears18/shipyard/issues/1165)) — a **comment** marker, distinct from the separate `<!-- do-work-blocked-until: YYYY-MM-DD -->` **body** marker the recording path also writes for this class; the comment marker is this freshness check's dedupe/reuse sentinel, while the body marker is what the step-4 dispatch filter actually reads.

   Comments without a recognized marker (plain text, `<!-- shipyard-worker-progress -->`, or other markers) are skipped — they are not scope-preflight diagnosis records.

   If **no** marker-tagged diagnosis comment exists → no cache hit; fall through to normal scope-agent dispatch.

2. **Check freshness: is the newest marker-tagged comment within the reuse window?** Compute `now_utc - comment.createdAt` in hours. If the result is ≥ `scope.diagnosis_reuse_hours` (or if `diagnosis_reuse_hours == 0`) → stale; fall through to normal scope-agent dispatch. Log: `[scope-preflight] #<N> freshness check skipped — newest diagnosis comment is <age>h old (window: <window>h)`.

3. **Check that the issue body hasn't changed since the comment.** Fetch `gh issue view <N> --repo <owner/repo> --json updatedAt -q .updatedAt`. If `updatedAt > comment.createdAt` → the body was amended after the comment was posted; the diagnosis may be stale; fall through to normal scope-agent dispatch. Log: `[scope-preflight] #<N> freshness check skipped — issue body updated at <updatedAt> after diagnosis comment at <comment.createdAt>`.

4. **Check whether a human gate-clear has been signalled since the diagnosis comment ([#569](https://github.com/mattsears18/shipyard/issues/569)).** A human clearing the `needs-human-review` label — or posting a `<!-- do-work-decision-resolved -->` or `<!-- shipyard-resolve-decisions -->` sentinel comment — after the diagnosis comment was posted is an explicit signal that the gate reason no longer holds. Two parallel checks, either of which trips the skip:

   **Signal A — label-timeline check.** Fetch the issue's timeline events:

   ```bash
   gh api repos/<owner>/<repo>/issues/<N>/timeline \
     --paginate --jq '[.[] | select(.event == "unlabeled" and .label.name == "needs-human-review")]
     | sort_by(.created_at) | last'
   ```

   If the most recent `unlabeled` event for `needs-human-review` has a `created_at` **after** the diagnosis comment's `createdAt` AND the actor is a non-bot (actor `type` is not `"Bot"`, or actor `login` does not end in `[bot]`) → a human has explicitly cleared the gate after the diagnosis was posted. Fall through to normal scope-agent dispatch. Log: `[scope-preflight] #<N> freshness check skipped — needs-human-review was removed by <actor.login> at <created_at>, after the diagnosis comment at <comment.createdAt> (human gate-clear overrides cached diagnosis)`.

   **Signal B — decision-resolved sentinel check.** Scan the comments already fetched in step 1 for any comment whose body begins with the `<!-- do-work-decision-resolved -->` sentinel **or** the `<!-- shipyard-resolve-decisions -->` sentinel, and whose `createdAt` is **after** the diagnosis comment's `createdAt`. `<!-- do-work-decision-resolved -->` is the recommended first line of a hand-written maintainer comment that records a decision and clears the gate (see CLAUDE.md § "Decision-resolved sentinel"); `<!-- shipyard-resolve-decisions -->` is the marker `/shipyard:resolve-decisions` (and `/my-turn`'s reused decision-gated walkthrough) posts automatically after interactively walking the maintainer through the same blocking decisions (see [`resolve-decisions.md`'s Record + unblock](../../resolve-decisions.md#record--unblock)). Both sentinels record the identical fact — a human answered the blocking questions — through two different call paths, and must be treated identically here ([#962](https://github.com/mattsears18/shipyard/issues/962)). If a comment carrying either sentinel exists → fall through to normal scope-agent dispatch. Log: `[scope-preflight] #<N> freshness check skipped — decision-resolved sentinel found in comment at <sentinelComment.createdAt>, after the diagnosis comment at <comment.createdAt> (maintainer decision comment overrides cached diagnosis)`.

   If neither signal fires (no post-diagnosis label removal by a non-bot human, and no post-diagnosis `<!-- do-work-decision-resolved -->` / `<!-- shipyard-resolve-decisions -->` comment) → the gate-clear did not post-date the diagnosis; continue to step 5.

5. **Re-validate the cached evidence mechanically.** Parse the `defer_reason_class` from the marker (see step 1's marker-to-class mapping). Extract the `evidence_pointer` from the comment body — the line immediately following the marker line starts with `Scope-preflight diagnosis ...` and the evidence pointer was embedded in the original comment per the recording-path template. For `confirmed-blocker-still-open` entries, re-run the blocker-state probe (all `#N` references must still be OPEN). For `time-gated` entries, re-run the date probe: today's UTC calendar date (`date -u +%F`) must still be strictly before the cited `YYYY-MM-DD` — if the date has elapsed, the cached diagnosis is stale (the issue may now be genuinely ready). For other classes, run the per-class shape check only. If re-validation fails → fall through to normal scope-agent dispatch. Log: `[scope-preflight] #<N> freshness check — cached evidence re-validation failed (<reason>); dispatching scope agent`.

6. **Record a `cached-diagnosis` defer.** All five checks passed — the existing comment accurately documents the defer and re-dispatching a scope agent would produce the same result at cost. Synthesize the defer entry directly:

   ```
   {
     issue: N,
     reason: "<first non-marker paragraph of the cached comment, verbatim>",
     defer_reason_class: "<class inferred from the marker>",
     evidence_pointer: "<re-extracted from the cached comment>",
     provenance: "cached-diagnosis",
     deferred_at: "<current ISO-8601 UTC timestamp>",
     would_be_dispatchable_as_phase_1_if?: "<from the cached comment if present>"
   }
   ```

   Apply the same recording steps as a regular deferred entry (comment dedupe check, `needs-human-review` label application for the three labelled classes) — but **skip posting a new comment** (the existing comment is the record; posting again adds noise). Log: `[scope-preflight] #<N> freshness check hit — reusing diagnosis comment from <comment.createdAt> (class=<defer_reason_class>, evidence=<evidence_pointer>); scope-agent dispatch skipped`.

   **Do NOT dispatch a scope agent for this candidate.** Increment `defers_this_turn` by 1 (same as a scope-agent defer — feeds the step E invariant line and the pre-drain audit). Remove the issue from `raw_backlog`.

**When NOT to apply the freshness check.** The check is skipped when:
- `scope.diagnosis_reuse_hours == 0` (disabled by config).
- No marker-tagged comment exists on the issue.
- The comment is older than the window.
- The issue body was amended after the comment.
- A non-bot human removed `needs-human-review` after the diagnosis comment was posted (Signal A — see step 4 above).
- A `<!-- do-work-decision-resolved -->` or `<!-- shipyard-resolve-decisions -->` sentinel comment was posted after the diagnosis comment (Signal B — see step 4 above).
- The cached evidence fails mechanical re-validation.

In all skip cases, fall through to normal scope-agent dispatch. The check is purely additive — it never promotes a cached defer to `ready`; that path is the scope agent's exclusive domain.

#### PR-collision cache-reuse check ([#1448](https://github.com/mattsears18/shipyard/issues/1448))

**Runs before scope-agent dispatch, for a `raw_backlog` candidate whose body's first line still carries a `<!-- do-work-blocked-by-prs: N,M -->` marker (issue #1429) with every listed PR now `MERGED`/`CLOSED`** — i.e. it was just re-admitted by `classify`'s pr-collision-gated→eligible transition. This is a distinct check from the freshness check above (that one reuses a cached *defer*; this one conditionally reuses a cached **ready** scope) and never promotes to `ready` without a mandatory semantic-premise re-validation against the merged PR's actual diff. See [`06f-pr-collision-cache-reuse.md`](06f-pr-collision-cache-reuse.md) for the full procedure (deep-link only — not part of the ordered per-session walk). Absent a cached `would_be_ready_scope`, or when the re-validation fails/is ambiguous, this check is a no-op and the candidate proceeds to normal scope-agent dispatch unchanged.
