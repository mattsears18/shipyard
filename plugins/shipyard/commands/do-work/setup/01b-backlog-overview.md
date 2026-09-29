# /shipyard:do-work — Setup phase · backlog overview

**Setup sub-phase (cluster 2 of 5, part 2 of 3 — [#994](https://github.com/mattsears18/shipyard/issues/994)).** Owns step **2**: fetch the open-issue universe, bucket every issue for the upfront backlog-overview report, and print the two-mode status table. Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md). Prev: [`01-repo-recovery.md`](./01-repo-recovery.md) (same cluster, part 1). Next: [`01c-label-recovery-refine.md`](./01c-label-recovery-refine.md) (same cluster, part 3).

### 2. Backlog overview

> **`--fast` skip:** When `--fast` is set, skip the full universe fetch and the UI table. Instead, run three cheap counts for advisory reporting in the end-of-session `--fast was used` block:
>
> ```bash
> # These five run in parallel as part of the parallelization batch even under --fast.
> # Refinement-candidate count is by source-signal scan (no needs-refinement label since #520):
> # user-feedback label AND a body that still looks like raw feedback (the raw-feedback fenced
> # block — #1055, since the label alone is permanent origin provenance, not a live refinement
> # flag), OR an "## Open questions" heading, OR a bot author; minus issues already in the human
> # queue (needs-human-review).
> gh issue list --repo <owner/repo> --state open --limit 200 --json number,labels,body,author \
>   --jq '[ .[]
>           | select([.labels[].name] | any(. == "needs-human-review") | not)
>           | select(((.labels | any(.name == "user-feedback")) and ((.body // "") | test("(?m)^```user-feedback")))
>                    or ((.body // "") | test("(?m)^## Open [qQ]uestions[[:space:]]*$"))
>                    or ((.author.type // "") == "Bot")) ] | length'
> gh pr list --repo <owner/repo> --state open --label blocked:ci --json number --jq 'length'
> gh issue list --repo <owner/repo> --state open --label blocked:agent-soft --json number --jq 'length'
> gh issue list --repo <owner/repo> --state open --label blocked:agent --json number --jq 'length'  # legacy (pre-#300, migrated by 3d.2 sub-sweep b)
> gh issue list --repo <owner/repo> --state open --label needs-design --json number --jq 'length'  # legacy pre-#515, migrated by 3d.2 sub-sweep d
> gh issue list --repo <owner/repo> --state open --label needs-decomposition --json number --jq 'length'  # legacy pre-#519, migrated by 3d.2 sub-sweep e
> gh issue list --repo <owner/repo> --state open --label tracking --json number --jq 'length'  # legacy pre-#519, migrated by 3d.2 sub-sweep e
> gh issue list --repo <owner/repo> --state open --label blocked:agent-hard --json number --jq 'length'  # legacy pre-#521, migrated by 3d.2 sub-sweep f
> ```
>
> Save the counts as `fast_skip_needs_refinement` (refinement candidates deferred), `fast_skip_blocked_ci`, `fast_skip_blocked_agent_soft`, `fast_skip_blocked_agent_legacy`, `fast_skip_legacy_needs_design`, `fast_skip_legacy_needs_decomposition`, `fast_skip_legacy_tracking`, and `fast_skip_legacy_blocked_agent_hard`. Proceed immediately to step 3.

Before any other setup, fetch every open issue and print an upfront summary of what will be worked on, what will be skipped, and why. The user reads this once at the start of the session and uses it to (a) calibrate expectations for how many issues this run will close, and (b) start unblocking the blocked work in parallel while the orchestrator runs. The summary is **informational only** — print it, then continue with step 3. No confirmation needed.

Fetch the universe of open issues and the linked-PR subset. Both calls are part of the [setup parallelization batch](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch) — fire them in parallel with steps 1 / 3d.1 / 3d.2 / 4.5a / 4.5b / 5:

```bash
gh issue list --repo <owner/repo> --state open --limit 200 \
  --json number,title,labels,assignees,body,author \
  --jq '[.[] | {number, title, body, labels: [.labels[].name], assignees: [.assignees[].login], author: {login: .author.login}}]'

gh issue list --repo <owner/repo> --state open --limit 200 \
  --json number \
  --search 'is:issue is:open linked:pr' \
  --jq '[.[].number]'
```

The `--jq` projection flattens `labels` / `assignees` to the only shapes the bucket routing consumes (label names, assignee logins) and preserves the canonical `author.login` shape so the bucket-0.5 untrusted-author check (`author.login NOT in trusted_authors`) reads identically. Body stays full because bucket 6 / bucket 7 parse `Blocked by #N` and `do-work-blocked-until` references out of it via regex. Worker-preamble §"`gh` JSON discipline" covers the convention.

Bucket each issue into exactly one category. Apply in order — first match wins so an issue lands in its most specific bucket. **This table is a rendering of [`04-backlog-divert.md`](./04-backlog-divert.md#4-fetch--rank-the-backlog)'s client-side filter — the filter is the normative definition of what `/do-work` dispatches; this table's job is to describe it for the upfront UI, not to define it independently.** The Owner column below (who acts on a skipped bucket) is sourced from [`backlog-ownership.md`](./backlog-ownership.md), the shared bucket→owner artifact both this table and `04`'s filter are checked against — see that file for the reasoning behind each owner assignment, and [`scripts/tests/backlog-ownership-coverage.test.sh`](../../../scripts/tests/backlog-ownership-coverage.test.sh) for the mechanical check that this table and the ownership doc stay in sync.

| # | Bucket | Criteria | Owner |
|---|---|---|---|
| 0.5 | **Untrusted author** | `author.login` is NOT in `trusted_authors` (see [step 1.7](01-repo-recovery.md#17-resolve-trusted-author-allowlist)). **Applied first** — strangers' issues never reach the dispatch queue, even if otherwise unlabeled. | `/my-turn` — the drop applies `needs-human-review` + a bounded, idempotent handoff comment (see [`04`'s bucket-0.5 handoff](./04-backlog-divert.md#4-fetch--rank-the-backlog), [#1079](https://github.com/mattsears18/shipyard/issues/1079)) |
| 1 | **Assigned to others** | `assignees` contains a user other than `@me` — **only when `backlog.respect_assignees == true`** (config default `false`, issue [#1248](https://github.com/mattsears18/shipyard/issues/1248); when `false`, an issue's assignees never affect its bucket and this row never matches) | `/my-turn` — P2 housekeeping when the assignee is inactive >30d |
| 1.5 | **Peer-claimed** | issue/PR number is in `.peer_sessions.claimed_targets` — a live peer `/shipyard:do-work` session on this repo already has it `in_flight` (see [step 1.65](./01-repo-recovery.md#165-detect-live-peer-sessions-on-this-repo-1204), [#1204](https://github.com/mattsears18/shipyard/issues/1204)) | `/do-work` (self-clearing — retried once the peer's claim ages out or resolves) |
| 2 | **In flight** | issue number appears in the `linked:pr` set above | `/do-work` |
| 3 | **Won't fix** | carries `wontfix` | nobody (by design) — no path forward |
| 4 | **Discussion** | carries `discussion` | nobody (by design) — a maintainer is engaged in the thread by hand |
| 5 | **Needs triage** | matches a **live detection scan** — bot-shaped trusted author or symptom-shaped body — see [`04d`'s two signals](./04d-investigate-routing.md#the-two-signals-ord--either-one-is-sufficient) ([#1090](https://github.com/mattsears18/shipyard/issues/1090), generalizing [#556](https://github.com/mattsears18/shipyard/issues/556)'s label-only routing; the `needs-triage` label was retired outright in [#1120](https://github.com/mattsears18/shipyard/issues/1120)). **By default (`triage.investigate_dispatch: true`), a trusted-author issue matching any signal is NOT skipped** — it's routed to `investigate_candidates` and dispatched via investigate mode; only the **untrusted-author** subset is dropped, by bucket 0.5's author-login gate, before it ever reaches this bucket. Setting `triage.investigate_dispatch: false` drops a matched issue entirely regardless of which signal matched — that config value is the **only** condition under which a matched issue becomes a human item (see [`backlog-ownership.md`](./backlog-ownership.md#ownership-table)). **Design-gated issues** (formerly `needs-design`) and **epic-decomposition handoffs** (formerly `needs-decomposition` / `tracking`) now carry `needs-human-review` and land in bucket 5.5 — [#515](https://github.com/mattsears18/shipyard/issues/515) folded `needs-design` into `needs-human-review`, and [#519](https://github.com/mattsears18/shipyard/issues/519) folded the `needs-decomposition` / `tracking` epic-decomposition pair into `needs-human-review` (the epic handoff is distinguished by the `<!-- do-work-needs-decomposition -->` body marker that [`/decompose-epic`](../../decompose-epic.md) consumes — see [#498](https://github.com/mattsears18/shipyard/issues/498) / [#501](https://github.com/mattsears18/shipyard/issues/501)). | `/do-work` (default: dispatched via investigate mode) |
| 5.4 | **Awaiting refinement** | matches a refinement **source signal** and NOT `needs-human-review` — `user-feedback` label **AND** a body that still looks like raw feedback (the raw-feedback fenced block; the label alone is permanent origin provenance, not a live refinement flag — [#1055](https://github.com/mattsears18/shipyard/issues/1055)), OR an `## Open questions` heading, OR a bot author. No persisted `needs-refinement` label anymore ([#520](https://github.com/mattsears18/shipyard/issues/520)); `/refine-issues` recomputes candidacy live and branches by signal (user-feedback classify+rewrite, open-questions resolve-defaults, no-pattern fall-through). | `/do-work` (via `/refine-issues`) |
| 5.5 | **Awaiting human review** | carries `needs-human-review`. Subsumes the former `needs-design` design-gate ([#515](https://github.com/mattsears18/shipyard/issues/515)) and the former `needs-decomposition` / `tracking` epic-decomposition handoffs ([#519](https://github.com/mattsears18/shipyard/issues/519) — an epic handoff additionally carries the `<!-- do-work-needs-decomposition -->` body marker so `/decompose-epic` can find it). As of [#520](https://github.com/mattsears18/shipyard/issues/520) it's also the fall-through home for refinement candidates with no automated path. **A bare `tracking` label (not yet migrated) is ALSO dropped directly by step 4's filter, as a defensive gate against the label object never being deleted** ([#1081](https://github.com/mattsears18/shipyard/issues/1081)) — such an issue isn't in this bucket yet (it has no `needs-human-review` label to be surfaced by), but [step 3d.2 sub-sweep e](01c-label-recovery-refine.md#3-ensure-label-exists--recover-from-prior-session) migrates it here on the next session. **This gate is provisional and requires a content-sourced justification, not label presence alone** ([#1364](https://github.com/mattsears18/shipyard/issues/1364)) — see [`backlog-ownership.md`'s bucket 5.5 row](backlog-ownership.md#ownership-table) for the `tracking` vs `tracking-unjustified` split. | `/my-turn` |
| 5.6 | **Agent-console (operator action)** | carries `agent-console` (renamed from `needs-operator` in [#995](https://github.com/mattsears18/shipyard/issues/995); legacy-name recognition closed [#1082](https://github.com/mattsears18/shipyard/issues/1082)) — a browser/console operator action, not a code-worker task. | `/do-work` (operator phase — **default only; not guaranteed under `--no-operate` / `--hands-off`**, [#1093](https://github.com/mattsears18/shipyard/issues/1093)) — `/my-turn` surfaces a single pointer line only when it assumes the operator phase is enabled (`my_turn.assume_operator_enabled`, default `true`); otherwise it walks the item directly — see [`backlog-ownership.md`](./backlog-ownership.md#ownership-table) |
| 6 | **Blocked (soft label)** | carries `blocked:agent-soft` ([#300](https://github.com/mattsears18/shipyard/issues/300)) — auto-cleared at next session, so the bucket exists for visibility only; the soft-blocked issue is **NOT excluded** from step 4's workable fetch. Surfaces here so the user sees that a prior worker bailed for a subjective reason (cannot-reproduce / ambiguous / scope-judgment) and may want to clarify the issue before re-dispatch picks it up. (The former bucket 6a "Blocked (hard label)" was removed in [#521](https://github.com/mattsears18/shipyard/issues/521) — `blocked:agent-hard` was eliminated: refuses now carry `needs-human-review` and land in bucket 5.5; dependency-waits carry no label and land in bucket 7.) | `/do-work` |
| 7 | **Blocked (body reference / time-gate)** | body matches `Blocked by #(\d+)` where that issue is still open (`gh issue view <N> --json state -q .state` returns `OPEN`), OR body carries a `<!-- do-work-blocked-until: YYYY-MM-DD -->` marker whose date is still in the future ([#1161](https://github.com/mattsears18/shipyard/issues/1161)) | `/do-work` |
| 8 | **Workable** | everything else — these are what /do-work will dispatch | `/do-work` (implements) + `/my-turn` (surfaces a narrow "never claimed by `/do-work`" P2 nudge — resolved by [#1078](https://github.com/mattsears18/shipyard/issues/1078) to require no `shipyard` label, no self-assignment, and staleness past `my_turn.stale_undispatched_days`, so it no longer matches the whole bucket) |

**Full ownership reasoning — including the `nobody (by design)` rationale and the three open-gap tracking issues — lives in [`backlog-ownership.md`](./backlog-ownership.md), not duplicated here.** This table's Owner column is a terse pointer; that file is the source of truth.

**Bucket 0.5 is a security gate, not a triage hint** — the dispatch-time filter that keeps strangers' issues out of the workable queue entirely. The defense-in-depth measure (issue body treated as untrusted in [`agents/issue-worker/issue-work.md` step 2](../../../agents/issue-worker/issue-work.md#2-read-the-issue-carefully)) sits behind this filter. Override path for a maintainer-vouched issue: re-file under the maintainer's own account, or add the author to `.shipyard/trusted-authors.txt`. See [RATIONALE → Bucket 0.5 security gate](../../do-work-RATIONALE.md#step-2--why-bucket-05-is-a-security-gate) for the threat model and override-path discussion.

**The gate itself is unchanged, but the drop no longer reaches nobody ([#1079](https://github.com/mattsears18/shipyard/issues/1079)).** Step 4's client-side filter — the normative enforcement point, since bucket 0.5 here is a rendering of it — now applies `needs-human-review` plus a one-line comment naming the vouch path to each issue it drops for this reason, bounded to issues newer than a persisted cross-session high-water mark so an unauthenticated stranger can't force a full-history label sweep just by filing. See [`04`'s bucket-0.5 handoff](./04-backlog-divert.md#4-fetch--rank-the-backlog) for the mechanism; this file only renders the resulting bucket, it doesn't duplicate the write logic.

Buckets 5.4 and 5.5 are part of the refinement pipeline (see `/refine-issues`). 5.4 issues (matched by source signal, not a label) will be processed automatically by step 3.5 *this* session — the refiner branches on source signal (user-feedback vs open-questions vs fall-through). 5.5 issues are waiting on a human to sign off (refined user-feedback awaiting review, design-gated, epic-decomposition handoffs, or the no-automated-path refinement fall-through per [#520](https://github.com/mattsears18/shipyard/issues/520)); the resolve-defaults branch does NOT apply `needs-human-review`, so a resolve-defaults issue becomes dispatch-eligible immediately rather than landing in 5.5. Both render in the "Skipped" block with counts and issue numbers. **Bucket 5.6 is a different pipeline** — it isn't refinement work at all, it's a browser/console action the operator phase drives (or `/my-turn` points at); see [`backlog-ownership.md`](./backlog-ownership.md#ownership-table).

For each issue in bucket 6 or 7, generate a one-line **unblock recommendation** describing what the human could do to unblock it. Use the issue body, labels, and (for body references) the blocker's title and state — but skim, don't deep-dive. One sentence per blocked issue is plenty. Examples:

- Blocked by another open issue: `"#<N> blocked by #<M> (\"<M's title>\") — <action, e.g. 'land #M first', 'close #M as obsolete', or 'review the proposal in the latest comment'>"`
- Time-gated (`do-work-blocked-until`): `"#<N>: time-gated until <YYYY-MM-DD> — re-enters the workable queue automatically once the date elapses; no action needed unless the gate should be lifted early"`
- Blocked by an external dependency (SDK release, vendor input, design decision): describe the concrete action the user could take
- `blocked:agent-soft` label set: `"#<N>: soft block — will auto-retry at next session (cleared automatically); clarify the body if you want a different outcome on retry"`
- Awaiting refinement (bucket 5.4): `"#<N>: refinement runs automatically at /do-work startup, or run /refine-issues manually"`
- Awaiting human review (bucket 5.5): `"#<N>: review the refined feedback, set a priority label, remove \`needs-human-review\` (or close)"`

The point is to give the user something **actionable** so they can start clearing blockers in parallel.

**Inline action-recommendation candidates per skipped bucket.** The orchestrator surfaces per-bucket candidate counts under each Skipped-bucket so the "this bucket has N issues you could probably act on right now" signal is visible at the bucket itself. Apply only to buckets where a mechanical signal distinguishes "likely-actionable" from "genuinely stuck" residue. The orchestrator does NOT auto-act on these. See [RATIONALE → Inline action recommendations](../../do-work-RATIONALE.md#step-2--inline-action-recommendation-rationale) for the cost discussion.

Compute candidates for the following buckets:

- **Bucket 6 (soft label) does NOT compute candidates** — every soft-label issue is auto-cleared at next-session backlog fetch and is already counted as workable in step 4, so there's nothing the user could pre-empt. (The former bucket 6a `likely-clearable` candidate computation was removed along with `blocked:agent-hard` — see [RATIONALE → blocked:agent-hard elimination](../../do-work-RATIONALE.md#blockedagent-hard-elimination-issue-521).)

- **Bucket 5 (Needs triage / decomposition) — `likely-triageable` candidates, computed only when `triage.investigate_dispatch == "false"`.** Under the default (`true`), every trusted-author bucket-5 issue is already routed to `investigate_candidates` and dispatched via investigate mode this session — no human review step exists for it, so recommending "review and triage this by hand" would be actively wrong (an investigate worker is already taking it). **Read the config value once** (same call the client-side filter in [`04`](./04-backlog-divert.md#4-fetch--rank-the-backlog) already makes — reuse its result rather than re-querying):

  ```bash
  export CLAUDE_PLUGIN_ROOT="<plugin-root literal>"
  # Re-derive the SHIPYARD_REPO_ROOT pin (issue #1059/#1064) — this step runs
  # post-relocation (setup sub-phase 01b, after step 0.5/0.56), so a bare
  # shipyard-config.sh call here would silently read the orchestrator
  # worktree's config instead of the primary checkout's.
  SHIPYARD_REPO_ROOT=$(cat .shipyard-primary-root 2>/dev/null || pwd)
  export SHIPYARD_REPO_ROOT
  investigate_dispatch=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get triage.investigate_dispatch 2>/dev/null || echo "true")
  ```

  When `investigate_dispatch == "true"` → **skip this scoring entirely.** The bucket-5 row still prints its raw count in the table; omit the `⚠ likely-triageable` sub-row and its recommendation.

  When `investigate_dispatch == "false"` → score each issue by the presence of mechanical triage signals in its labels and body:
  - `+1` if labels contain any of `P0` / `P1` / `P2` (priority already set).
  - `+1` if labels contain any of `bug` / `enhancement` / `fix` / `feat` (issue type already declared).
  - `+1` if body contains `## Acceptance` or `## Acceptance criteria` (criteria section present).
  - `+1` if body contains `## Repro` / `## Reproduction` / `## Steps to reproduce` (repro section present).
  - `+1` if labels do NOT contain `needs-human-review` (no co-gate; `needs-human-review` now subsumes the former `needs-design` design-gate per [#515](https://github.com/mattsears18/shipyard/issues/515)).

  Score `>= 3` → `likely-triageable` candidate. The recommendation is "review and triage by hand" — the orchestrator changes no labels itself. Score `< 3` → "genuinely fuzzy" residue; not a candidate. This scoring — and its meaning, "mechanically easy to triage," not "most urgent" — is advisory only; it never runs against an issue that's actually being autonomously dispatched.

Print the summary using **two-mode rendering**, picked by row count:

- **Two or more non-zero buckets** → fixed-width aligned text table (not markdown table; spaces-aligned columns, `─` U+2500 header divider).
- **Exactly one non-zero bucket** → single-line summary, no table.
- **Zero buckets total** → empty-backlog one-liner.

The full shape, **two-or-more-rows mode**:

```
/do-work backlog overview — <owner/repo>

By priority: P0=<n>  P1=<n>  P2=<n>  unlabeled=<n>
Top workable items: #<a>, #<b>, #<c>, ...

Bucket                                       Count   Issues
───────────────────────────────────────────  ─────   ──────────────────────────────────────────────
Workable (will be worked this session)           6   #<a>, #<b>, #<c>, +<K> more
⛔ Untrusted author                              2   #U → @stranger, #V → @stranger2
blocked:agent-soft label                         2   #S1, #S2 — auto-cleared at next-session backlog fetch (no exclusion)
Blocked (body reference)                         1   #D
needs triage / decomposition                     2   #E, #F
  ⚠ likely-triageable                            1   #E — review and triage by hand
Awaiting refinement                              1   #R
Awaiting human review                            1   #H
Agent-console (operator action)                  1   #Z
Discussion                                       1   #G
Won't fix                                        1   #X
In flight (open PR)                              2   #I → PR #J, #K → PR #L
Peer-claimed                                     1   #P → peer session <id>
Assigned to others                               1   #M → @user

Total open: <W + S>  (workable: <W>, skipped: <S>)

Auto-cleared this session:
  blocked:agent-soft → workable: <cleared_blocked_soft> issue(s)  (#S1, #S2, ...)  (next-session sweep — no held bucket)
  legacy blocked:agent → needs-human-review: <migrated_legacy_review> issue(s)  (#L1, ...)  (no open Blocked-by ref)
  legacy blocked:agent → no label (dependency-wait): <migrated_legacy_dep> issue(s)  (#L2, ...)  (open Blocked-by ref; body-ref filter gates)
  legacy needs-design → needs-human-review: <migrated_needs_design> issue(s)  (#D1, ...)  (pre-#515 fold)
  legacy needs-decomposition/tracking → needs-human-review + decomposition marker: <migrated_needs_decomp> issue(s)  (#E1, ...)  (pre-#519 fold)
  legacy blocked:agent-hard → needs-human-review: <migrated_hard_review> issue(s)  (#F1, ...)  (no open Blocked-by ref)
  legacy blocked:agent-hard → no label (dependency-wait): <migrated_hard_dep> issue(s)  (#F2, ...)  (open Blocked-by ref; body-ref filter gates)

PR-side state:
  blocked:ci PRs: <c> total
    will be re-evaluated this session: <k>  (#J, #K, ...)
    held (no new commits since label applied): <h>  (#L, #M, ...)

Unblock recommendations (work these in parallel while /do-work runs):
  - #A: <recommendation>
  - #C: <recommendation>
  ...
```

**One-row mode** (the table is skipped; replace the bucket block with a single-line summary). When the lone bucket is `Workable`: `Workable: 6 issues (#90, #91, #92, #93, #94, #89). Nothing skipped.` When the lone bucket is a skip: `Workable: 0. Skipped: 2 issues in 'blocked:agent-soft' label (#S1, #S2).`

**Zero-row mode** (empty universe): replace everything below the header with `Backlog is empty — nothing to work on this session.`

**Bucket-table rules:**

- **Row count picks the mode.** Count non-zero buckets. `0` → empty-backlog one-liner. `1` → single-line summary. `≥2` → fixed-width aligned text table. The `Workable` row counts only when `<W> > 0`; action-recommendation sub-rows (`⚠ likely-clearable` / `⚠ likely-triageable`) don't count as their own bucket. See [RATIONALE → Bucket-table mode selection](../../do-work-RATIONALE.md#step-2--bucket-table-mode-selection-rationale).
- **Workable-row-always-prints is a table-mode rule, not a row-counting rule.** When the table renders (`≥2` non-zero buckets), the `Workable` row prints even with `<W> == 0`.
- **Column widths in two-or-more-rows mode.** Computed at print time:
  - **Bucket** column: width = max(label length across rendered rows), clamped to a minimum of 30 and a maximum of 60 characters. Sub-row labels include their 2-space indent in the length.
  - **Count** column: right-aligned, width = max(digit count across rows), clamped to a minimum of 5.
  - **Issues** column: width = max(content length across rendered rows), clamped to a minimum of 30 and a maximum of 80 characters. Content wider than the cap is NOT line-wrapped — the per-row truncation rule below handles overflow.
  - Column separator: **3 spaces** (visible gap without looking like a tab). Header divider: one `─` (U+2500) per character of the header label, separated by the same 3-space gaps.
- **Row order**: `Workable` first, then `Untrusted author` (security-relevant skip, surfaced near top), `Blocked (label)`, `Blocked (body reference)`, `Needs-triage/design`, `Awaiting refinement`, `Awaiting human review`, `Agent-console (operator action)`, `Discussion`, `Won't fix`, `In flight`, `Peer-claimed`, `Assigned to others`.
- **Issues column content.** Comma-separated issue numbers (with arrow-targets like `#G → PR #H` or `#I → @user`). Truncate after **10 numbers** with `, +<K> more`.
- **`Total open` line** stays below the table; **`By priority` and `Top workable items`** stay above.

The **PR-side state** block prints whenever `<c> > 0`. Numbers come from `cleared_ciblocked` / `held_ciblocked` recorded by [step 3d.1](01c-label-recovery-refine.md#3-ensure-label-exists--recover-from-prior-session).

The **Auto-cleared this session** block prints when `cleared_blocked_soft > 0` or `migrated_legacy > 0` (= `migrated_legacy_dep + migrated_legacy_review`) or any of the new legacy-migration counters `migrated_needs_design`, `migrated_needs_decomp`, `migrated_hard_review`, `migrated_hard_dep` is `> 0`. Numbers come from step 3d.2. Omit rows with a zero count. (The former `blocked:agent-hard` cleared/held counters were removed in [#521](https://github.com/mattsears18/shipyard/issues/521) with sub-sweep a; sub-sweeps d/e/f ([#537](https://github.com/mattsears18/shipyard/issues/537)) add migration lines for the #515/#519/#521 legacy labels.)

Edge cases:

- **`W == 0`** — print the summary anyway, then continue with setup. Step 4's filtered fetch will return empty and the loop will terminate cleanly.
- **No blocked issues** — omit the "Unblock recommendations" section entirely.
- **Priority labels not yet triaged** — the breakdown reflects current label state; step 4's auto-triage pass labels the unlabeled survivors before dispatch.
- **Buckets with zero count** — in table mode, omit those rows (except `Workable`, which always prints in table mode). Action-recommendation sub-rows with zero candidates are also omitted.
- **Very large backlogs** — per-row Issues column truncates after ~10 numbers with `, +<K> more`.
- **`likely-triageable` candidates are advisory only** — surfaced in the step-2 overview for visibility; the orchestrator does not auto-act on them. (The former `likely-clearable` candidate / step-3d.2-sub-sweep-a overlap note was removed in [#521](https://github.com/mattsears18/shipyard/issues/521) — `blocked:agent-hard` and its referential sweep no longer exist.)
- **Cost** — all blocker lookups read through the [`blocker_state` cache](00b-parallelization-cache.md#08-blocker_state-cache-default-on) and fire as a parallel burst. Combined extra cost on a ~50-issue backlog is well under 1s wall-clock.

Then proceed immediately to step 3.

