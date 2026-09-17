# /shipyard:do-work — Setup phase · backlog fetch + rank + divert checks

**Setup sub-phase (cluster 3 of 5, part 1 of 2 — [#1446](https://github.com/mattsears18/shipyard/issues/1446)).** Owns steps **4 → 4.5**: fetch + rank the backlog, and the main-CI / PR-pileup divert checks. Steps **5 → 5.8** (failing-PR snapshot, seeding inherited DIRTY PRs into `session_prs` for cross-session drain hand-off, seeding inherited draft PRs, flake-registry enforcement) moved to [`04j-failing-pr-snapshot.md`](./04j-failing-pr-snapshot.md) when this file crossed the token-budget warn band ([#1446](https://github.com/mattsears18/shipyard/issues/1446); PR #1437 had already once red-lined CI on this same file at 60,184 bytes) — same router/fragment precedent as [#611](https://github.com/mattsears18/shipyard/issues/611) / [#994](https://github.com/mattsears18/shipyard/issues/994) / [#1233](https://github.com/mattsears18/shipyard/issues/1233) / [#1431](https://github.com/mattsears18/shipyard/issues/1431). Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md). Prev: [`01-repo-recovery.md`](./01-repo-recovery.md). Next: [`04j-failing-pr-snapshot.md`](./04j-failing-pr-snapshot.md) (same cluster, part 2).

### 4. Fetch + rank the backlog

**Timing instrumentation (issue #238).** Bracket this step including the auto-triage label-apply loop and client-side filter pass:

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
"$CLAUDE_PLUGIN_ROOT/scripts/setup-timing.sh" start \
  --session-id "<session-id>" --phase step_4_backlog_fetch_and_rank 2>/dev/null || true
# ... run step 4 ...
"$CLAUDE_PLUGIN_ROOT/scripts/setup-timing.sh" end \
  --session-id "<session-id>" --phase step_4_backlog_fetch_and_rank 2>/dev/null || true
```

```bash
# Wide fetch — server-side filter is ONLY `--state open` (plus any
# `--label <L>` qualifiers passed at invocation). All eligibility checks
# move to the client-side filter pass below. See issue #332 for the
# regression this shape exists to prevent.
gh issue list --repo <owner/repo> --state open --limit 200 \
  --json number,title,labels,assignees,body,author,createdAt,updatedAt,milestone \
  --jq '[.[] | {number, title, body, labels: [.labels[].name], assignees: [.assignees[].login], author: {login: .author.login}, createdAt, updatedAt, milestone: (.milestone.title // null)}]'
```

**Copy that `--jq` projection verbatim — three fields flatten, `author` deliberately does NOT ([#1555](https://github.com/mattsears18/shipyard/issues/1555)).** `labels`, `assignees` and `milestone` each collapse to a scalar (name / login / title string); `author` stays the object `{login}`, because that is the shape [step 7's `originating_author_trust` computation](../dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) reads downstream. Re-deriving the projection from prose reliably gets this asymmetry wrong in one of two directions — leaving `milestone` as gh's `{number,title,...}` object, or "consistently" flattening `author` to a string too — and both used to surface only as a *positional* `jq` error from inside `classify` naming no field at all. They no longer do: the shape is checked up front by [`backlog-filter.sh validate-issues`](../../../scripts/backlog-filter.sh) (run automatically by both `classify` and the `classify-backlog.sh run` call below), which exits 64 naming the offending field, its issue number, and the flattening expression that fixes it. Treat a `validate-issues` failure as "my projection drifted from the literal above," not as a classifier bug.

The `milestone` field (issue #1241) flattens gh's `{number, title, ...}` milestone object down to just the title string (or `null` when unmilestoned) — the shape `backlog-filter.sh classify`'s milestone-ranking tier parses the `N · Title` sequence prefix from. Same flattening pattern as `labels`/`assignees` above.

The `--jq` projection mirrors step 2's: flatten `labels` / `assignees` to the consumed shapes (names, logins) and preserve `author.login` as the canonical shape downstream filters and step 7's `originating_author_trust` computation reference. Body stays full because the client-side filter walks it for `Blocked by #N` references. Worker-preamble §"`gh` JSON discipline" covers the convention.

Pass `--label <L>` qualifiers through as `--label <L>` (NOT `--search 'label:<L>'`) for any `--label` args supplied at invocation — the `--label` flag composes cleanly with the wide fetch above and is the canonical way to scope the universe down to a project subset.

**Why the server-side filter is intentionally wide (issue [#332](https://github.com/mattsears18/shipyard/issues/332)).** Server-side fetch is purely `--state open` + optional `--label <L>` qualifiers (when the caller scopes to a label-bounded project subset). Every other eligibility check — author trust, assignee≠@me, blocking labels, `Blocked by #N` references, `closed-by-open-pr` membership — moves to the client-side filter pass below. An earlier `--search`-qualifier shape silently dropped resumable-work issues (`-linked:pr` excludes issues with any prior linked PR, even a closed/abandoned one) and couldn't encode "@me-assigned is OK, anyone-else-assigned is not" server-side. See [RATIONALE → Step 4 wide server-side filter](../../do-work-RATIONALE.md#step-4--why-the-server-side-filter-is-intentionally-wide-issue-332) for the full repro and the two failure classes this fixed. The same fix lands in [drain.md's termination-assertion step 4](../drain.md#termination-assertion) and [steady-state.md step C's lightweight backlog re-check](../steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action) so all three call-sites read the same universe and never disagree on what's workable.

The `author` field has two uses: (1) step 4's client-side trusted-author filter (the search-qualifier syntax has no `-author:` exclusion form, so this is necessarily client-side); (2) step 7's `originating_author_trust` dispatch-time gate (the third defense-in-depth layer). See [RATIONALE → Step 4 author field](../../do-work-RATIONALE.md#step-4--why-the-author-field-is-fetched).

**Auto-triage priority labels.** Before ranking, ensure every fetched issue carries exactly one of `P0`/`P1`/`P2`. For each issue whose `labels` array contains **none** of those three, judge severity from the title, body, and existing labels (`bug`, `security`, `a11y`, `perf`, `chore`, …) using the [audit-rubrics severity buckets](../../../skills/audit-rubrics/SKILL.md):

- `P0` — broken or unusable: runtime errors on the golden path, exposed secrets, RCE vectors, contrast failures on primary actions
- `P1` — significant friction or risk: confusing affordances, missing security headers, a11y failures on common flows, CVEs without patches
- `P2` — polish or moderate risk: spacing nits, copy improvements, low-severity CVEs with patches available, plus anything that doesn't fit P0/P1 but still merits work

When torn between two tiers, pick the lower-severity one. Apply exactly one label per issue:

```bash
gh issue edit <N> --repo <owner/repo> --add-label <Px>
```

Skip any issue that already carries one or more `P0`/`P1`/`P2` labels — preserve the human judgment that set them. Don't remove existing priority labels, and don't add a second one. Legacy `P3` labels are treated as unlabeled. See [RATIONALE → Auto-triage priority](../../do-work-RATIONALE.md#step-4--auto-triage-priority-rationale).

**The eligibility filter is executable — [`scripts/backlog-filter.sh`](../../../scripts/backlog-filter.sh)'s `classify` subcommand is the normative definition of what `/do-work` dispatches** ([#1247](https://github.com/mattsears18/shipyard/issues/1247), superseding the former prose-only normative claim from [#1076](https://github.com/mattsears18/shipyard/issues/1076)). Before this script existed, the same six-clause predicate was re-derived from prose at three independent call-sites — this file's step 4, [`steady-state.md` step C](../steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action), and [`drain.md`'s termination-assertion step 4](../drain.md#termination-assertion) — and drifted twice as a result: [#332](https://github.com/mattsears18/shipyard/issues/332) (a hand-rolled assignee shorthand erased every self-assigned resumable-work issue) and [#1194](https://github.com/mattsears18/shipyard/issues/1194) (the identical regression, one layer down, in a mid-drain ad-hoc re-derivation). A third divergence was found already committed to the spec text, never yet regressed in production: `needs-triage` (a label since retired in [#1120](https://github.com/mattsears18/shipyard/issues/1120)) was explicitly excluded from the drop-label enumeration here but listed *inside* the equivalent enumeration at the other two call-sites. All three call-sites now invoke the same script; they cannot disagree because there is only one implementation to disagree with. [`01b-backlog-overview.md`](./01b-backlog-overview.md#2-backlog-overview)'s bucket table and [`backlog-ownership.md`](./backlog-ownership.md)'s bucket→owner table are both renderings of the script's routing decision, not independently-authored descriptions of it.

**The bulleted description below this line is retained documentation of intent — background and rationale for onboarding, not something re-derived by hand at dispatch time.** If this prose and the script ever disagree, the script is right and the prose is stale; file a doc-fix issue rather than trusting the prose over `backlog-filter.sh classify`'s actual behavior. The routing decisions it makes, in order:

- **Drop issues whose `author.login` (lowercased) is NOT in `trusted_authors`** — the dispatch-time security gate (see [step 1.7](01-repo-recovery.md#17-resolve-trusted-author-allowlist) for how the set is populated). Belt-and-suspenders with the step-2 bucket pass: step 2 surfaces the count to the user; step 4 enforces the actual drop.

  **Bucket-0.5 handoff — label + comment newly-dropped issues so a human sees them, bounded + idempotent ([#1079](https://github.com/mattsears18/shipyard/issues/1079)).** The gate above is unchanged — this is a surfacing side effect only, and is NOT part of the script (it mutates GitHub state; the classifier is a pure function). Read [`04b-untrusted-author-handoff.md`](./04b-untrusted-author-handoff.md) now and run it in full immediately after the drop above: it applies `needs-human-review` + a one-line vouch-path comment to each issue this run's drop just excluded, bounded to issues newer than a persisted cross-session high-water mark (never a full-history sweep) and idempotent via a label-presence check. Runs every session — unlike [step 4.5a/4.5b](#4-fetch--rank-the-backlog), it is NOT `--fast`-skipped.

- **Drop issues carrying any of the dispatch-gate labels** — `blocked:ci`, `wontfix`, `discussion`, `needs-human-review`, `tracking` (the script's `gate_labels` array — the single enumeration all three call-sites now share). `blocked:agent-hard` and the legacy `blocked:agent` were dropped from this set entirely ([#521](https://github.com/mattsears18/shipyard/issues/521)) — a refuse now carries `needs-human-review` (already enumerated) and a dependency-wait carries no label (gated separately by the `Blocked by #N` rule below), so neither needs its own entry. `agent-console` is deliberately absent from this enumeration too, for a different reason: it is a *route*, classified by its own clause below, never dropped by label alone. **`blocked:agent-soft` is intentionally NOT in this set either** (soft-blocked issues auto-clear at next-session backlog fetch — that's the entire point of the soft/hard split per #300; the in-session [soft-bail filter](../steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action) handles the same-session retry-window case). See [RATIONALE](../../do-work-RATIONALE.md#needs-decomposition--tracking--needs-human-review--body-marker-issue-519) for the rest of the fold/elimination history behind this label set (`needs-design` folded into `needs-human-review` per #515, `needs-decomposition`/`tracking` pair per #519, `needs-refinement` eliminated per #520).

  **`tracking` alone is a PROVISIONAL member of this set, and a provisional gate may not fire on label presence alone ([#1364](https://github.com/mattsears18/shipyard/issues/1364)).** Unlike the other four labels above (settled gates with a permanent owner), `tracking` requires a recognized human-owned signal before the script drops the issue on that basis — the issue's **GitHub sub-issue graph** (structured state, read by the `sub-issues` producer subcommand and passed in as `classify --sub-issues`; [#1556](https://github.com/mattsears18/shipyard/issues/1556)) or one of four body-prose signals. Read [`04i-tracking-provisional-gate.md`](./04i-tracking-provisional-gate.md) for the full justification requirement, the precedence-ordered `has_tracking_justification()` signal list, and the `tracking` / `tracking-unjustified` verdict split.
- **Route `agent-console` issues to `operator_queue`, not the drop pile** ([#608](https://github.com/mattsears18/shipyard/issues/608); modeled explicitly as a route by [#1251](https://github.com/mattsears18/shipyard/issues/1251)). Removed from the code-worker candidate set, same mechanical effect as a drop — but **dispatchable**, by the operator phase. Renamed from `needs-operator` in [#995](https://github.com/mattsears18/shipyard/issues/995) — legacy-name back-compat window is closed (#1082), so the script matches only the current name. Read [`04g-operator-routing.md`](./04g-operator-routing.md) for the full rationale: states the rule once, names the queue, covers the `--no-operate` fallback. No separate enqueue call is needed here — the label itself (left in place) is what the operator phase's proactive sweep scans for.
- **Route investigate-mode candidates to `investigate_candidates`** (gated on `triage.investigate_dispatch`, passed to the script as `--investigate-dispatch`). Trusted-author issues matching either of two signals — bot-shaped author, or symptom-shaped body — route to `investigate_candidates` instead of `raw_backlog`; when the config gate is off, a matched issue is dropped instead of routed. Read [`04d-investigate-routing.md`](./04d-investigate-routing.md) for the full rationale behind the two signals and the retired-label history; the `SYMPTOM_REGEX` documented there is mirrored verbatim in the script.

  `investigate_candidates` is a separate ordered list (FIFO, priority order within the list: `P0` > `P1` > `P2` > unlabeled, then staleness — no prioritized-label or type tier). It is populated here and consumed by the steady-state decision tree's step 1.5. Like `raw_backlog`, it starts empty at the top of step 4 and is finalized before step 4.5.
- **Drop peer-claimed issues/PRs** ([#1204](https://github.com/mattsears18/shipyard/issues/1204), passed to the script as `--peer-claimed`). See [`04e-peer-session-drop.md`](./04e-peer-session-drop.md): drop candidates in `.peer_sessions.claimed_targets` (step 1.65).
- **Drop issues assigned to a user other than the gh-authenticated user — gated on `backlog.respect_assignees` (config default `false`), issue [#1248](https://github.com/mattsears18/shipyard/issues/1248).** `@me`-assigned issues (alone or alongside other assignees) PASS regardless of this setting — that's the resumable-work case (a prior session self-assigned the issue but didn't ship it), and the entire point of [#332](https://github.com/mattsears18/shipyard/issues/332)'s rework is to keep that case visible to the dispatch queue. When `backlog.respect_assignees` is `false` (the default — the common single-contributor-repo shape this marketplace mostly serves), this clause doesn't run at all: an issue assigned to anyone, or no one, is equally eligible. The clause's only genuine upside is on a multi-contributor repo where "assigned to someone else" is a meaningful "not mine" signal — set `backlog.respect_assignees: true` to restore that. See [`scripts/backlog-filter.sh`](../../../scripts/backlog-filter.sh)'s `--respect-assignees` flag.
- Drop issues whose body contains `Blocked by #N` where #N is present in this same wide-fetch payload (i.e. still open — the payload IS the complete open-issue universe, so no separate per-reference `gh issue view` call is needed).
- **Drop issues whose body's FIRST LINE is a `<!-- do-work-blocked-until: YYYY-MM-DD -->` marker whose date is still in the future ([#1161](https://github.com/mattsears18/shipyard/issues/1161))** — the **time-gate**, compared against `--today` (defaults to `date -u +%F`). Self-clearing: no label, no sweep, the issue re-enters the workable queue the instant the date elapses on the next fetch. **Position discipline, line 1 only ([#1168](https://github.com/mattsears18/shipyard/issues/1168))** — a marker anywhere else (mid-paragraph, backticked, fenced, or quoted) is NOT live and MUST NOT gate dispatch; it's always written on line 1, never mid-body. An unparseable date on line 1 fails open (not blocked).

  **This marker is no longer `time-gated`-exclusive ([#1195](https://github.com/mattsears18/shipyard/issues/1195)).** An `external-dependency` defer also writes this same marker (in addition to its `agent-console` label — see [step 4b](06c-scope-handling-ui.md#handling-each-returned-entry-fires-as-each-background-agent-completes)), naming an orchestrator-computed recheck date rather than a human-authored gate. This drop rule is unaffected either way — an `agent-console`-labeled issue is already routed away by the label-route clause above regardless of this marker.

  **A companion `<!-- do-work-recheck: <verb> <args...> == <expected> -->` marker turns this into an EVENT gate instead ([#1356](https://github.com/mattsears18/shipyard/issues/1356)).** `do-work-blocked-until` ALONE (the common case, described above) is a pure TIME gate — the date is the constraint, full stop. When the body ALSO carries a `do-work-recheck` marker (any line — unlike `do-work-blocked-until`, this second marker has no position-discipline requirement, matching `eval-recheck-probe.sh`'s own extract logic), the calendar date stops deciding eligibility on its own: the script's `eval-probes` subcommand (below) live-evaluates the probe for every such issue, and the verdict — not the date — governs. `changed` admits the issue immediately, even if the date is still in the future; `unchanged`/`unknown` keeps dropping it as `event-gated`, even after the date has elapsed, and no fresh date is ever invented to re-park it. This is the fix for the churn loop #1356 documents: an event-gated issue that's re-diagnosed as still-blocked no longer silently re-enters the workable queue just because a placeholder date passed.
- **Two PR-coverage clauses, two different questions — [`scripts/backlog-filter.sh`](../../../scripts/backlog-filter.sh)'s `closed-by-healthy-pr` + `closed-by-open-pr` subcommands** (both live-network, kept out of the pure, fixture-testable `classify`; both read `closingIssuesReferences`, never a PR-body substring search — [#301](https://github.com/mattsears18/shipyard/issues/301)). Full reasoning: the script's header + [RATIONALE](../../do-work-RATIONALE.md). The summary:
  - `--closed-by-healthy-pr` → **is this PR healthy?** Its answer routes the PR to [`failed_prs` / fix-checks](../dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) or not. "Healthy" is the latest-per-name check-rollup projection ([#333](https://github.com/mattsears18/shipyard/issues/333)) reporting zero failures, plus `mergeStateStatus != DIRTY` (that state belongs to fix-rebase) — never a `{CLEAN, HAS_HOOKS, UNSTABLE}` allowlist, which misreads merely-*queued* required checks (`BLOCKED` on a ruleset-protected branch) as unhealthy ([#1262](https://github.com/mattsears18/shipyard/issues/1262)).
  - `--closed-by-open-pr` → **is this ISSUE already covered?** ([#1389](https://github.com/mattsears18/shipyard/issues/1389)) The wider set, and the reason the clause above must *not* be reused here: health is irrelevant to this question. An issue whose open `@me` PR names it in `closingIssuesReferences` is covered whether that PR is green, red, or `DIRTY` — red ⇒ fix-checks *on the PR*, `DIRTY` ⇒ fix-rebase *on the PR* — so an issue-worker dispatched at it can only bail at `issue-work.md` step 0, after a full worker has read the issue. Emits its own greppable verdict, `reason: "covered-by-open-pr"` plus an `evidence_pointer` naming the covering PR, so [`04f`](./04f-completion-ledger.md#the-bucket-taxonomy) buckets it as *covered, not dropped*.
  - **Neither clause locks an issue behind a closed/abandoned PR** — both query `--state open` only, so [#332](https://github.com/mattsears18/shipyard/issues/332)'s resumable-work case holds by construction.

**Invocation — one plain command ([#1398](https://github.com/mattsears18/shipyard/issues/1398)).** [`scripts/classify-backlog.sh`](../../../scripts/classify-backlog.sh)'s `run` subcommand absorbs the whole input-gathering + classify sequence — the seven config reads (including `backlog.someday_milestone` and `backlog.someday_recheck_days`, issues [#1406](https://github.com/mattsears18/shipyard/issues/1406)/[#1422](https://github.com/mattsears18/shipyard/issues/1422)), both live-network precomputed sets, the conditional probe-verdicts call, and the someday-recheck marker write (below) — so the orchestrator's own call is just script-invocation plus the handful of inputs only the caller can supply (the plugin-root/primary-root pins, the `gh` login, and the repo-scoped CSVs from earlier steps — all substituted as **literals**, per [#1471](https://github.com/mattsears18/shipyard/issues/1471); passing them as shell variables is what left this block refused after #1398's extraction landed). See [RATIONALE → Step 4 invocation extraction](../../do-work-RATIONALE.md#step-4--invocation-extraction-issue-1398) for why this is a script call rather than an inline block; the script's own header is the normative contract (`--repo`/`--me`/`--trusted-authors`/`--issues-file` required, `--peer-claimed`/`--prioritize-label`/`--out` optional).

**Someday-recheck marker write (issue [#1422](https://github.com/mattsears18/shipyard/issues/1422), follow-up to #1406) rides inside this same call.** After `classify-backlog.sh run` produces the NDJSON, it pipes that NDJSON into `backlog-filter.sh someday-recheck-write` (best-effort, never fails the whole call) — for every `drop:someday-milestone` line tagged `someday_recheck_action: "first-park"` or `"cheap-reset"`, this writes or refreshes a `<!-- do-work-someday-recheck: YYYY-MM-DD -->` body marker dated `today + backlog.someday_recheck_days` days. A `someday_recheck_action`-free `eligible` line is the ESCALATE case: the issue is NOT dropped this pass — it's a plain candidate in `raw_backlog` for exactly ONE real scope-agent pass, handled by the ordinary [scope pre-flight](06-scope-preflight.md) machinery, with [`06c-scope-handling-ui.md` step 4d](06c-scope-handling-ui.md#handling-each-returned-entry-fires-as-each-background-agent-completes) resetting the someday-recheck clock once that pass's defer conclusion lands. See [RATIONALE → Step 4 someday-recheck marker mechanics](../../do-work-RATIONALE.md#step-4--someday-recheck-marker-mechanics-issue-1422-follow-up-to-1406) for the full four-state contract and why this reuses `do-work-blocked-until`'s marker shape under a distinct name.

`$fetched_issues_json` is the wide-fetch array from the top of this step — **produced by that step's literal `gh issue list` command, not by a projection re-derived here** ([#1555](https://github.com/mattsears18/shipyard/issues/1555); `classify-backlog.sh run` validates the shape before it spends a single network call, so a drifted projection fails fast with the field named rather than after the input-gathering work). Materialize it with the `Write` tool (never a `printf`/heredoc piped into the next command — see [`shipyard:worker-preamble`'s body-file convention](../../../skills/worker-preamble/body-file-convention.md)) to `.shipyard-fetched-issues.json` in the orchestrator worktree root, BEFORE the command sequence below. `Write` and `Bash` are different tools, so there's no variable-survival concern between them.

Then classify — redirecting the classify NDJSON straight to a scratch file via `--out`, so neither this call nor the extractions after it need a pipe.

**Substitute every value as a LITERAL — do not reference a shell variable here ([#1471](https://github.com/mattsears18/shipyard/issues/1471)).** This block used to open with a five-statement preamble that resolved `$CLAUDE_PLUGIN_ROOT` / `$SHIPYARD_REPO_ROOT` / `$ME_LOGIN` and then passed them through on the command line. That shape is **refused verbatim** by the worktree-isolation guard — measured, reproducibly, in an isolated worktree (see [`dont.md`'s post-relocation section](../dont.md) for the controlled experiment). The trigger, as [#1474](https://github.com/mattsears18/shipyard/issues/1474) later measured it, is a **word whose entire content is a single unresolvable expansion** — here `--me "$ME_LOGIN"`. (#1471 attributed it to the *network* command substitution `ME_LOGIN=$(gh api user --jq '.login')` on the assignment side; that is measurably wrong — `$(pwd)` and `$(cat …)` behave identically, and the assignment was never the problem. See [`dont.md`'s corrected rule](../dont.md#the-corrected-rule-1474-never-let-an-unresolvable-expansion-be-the-whole-word).) Holding everything else byte-identical and replacing only `--me "$ME_LOGIN"` with the literal login flips the identical block from refused to running. You already hold all three literals by this point — the plugin root from [step 0.5's stash](./00-config-worktree.md), the primary root from step 0.56, and the login from the plain call below — so substitute them and the block runs as one plain command.

First, read the login as its own plain call (its output is the literal you substitute for `<me-login>` below):

```bash
gh api user --jq '.login'
```

Then classify. `SHIPYARD_REPO_ROOT` is passed as a **per-command environment prefix**, not an `export` in a preceding statement — `classify-backlog.sh`'s own internal `shipyard-config.sh` calls read it from the environment (`shipyard-config.sh` § `SHIPYARD_REPO_ROOT`), and a command-prefix assignment exports it to the child process just as the old two-statement `export` did. It must be the **step-0.56 primary-root stash literal**, never `git rev-parse --show-toplevel` (issues #1059/#1064) — the latter resolves to the orchestrator worktree post-relocation, not the primary checkout `shipyard-config.sh` needs to read repo-level config from:

```bash
SHIPYARD_REPO_ROOT=<primary-root literal> bash <plugin-root literal>/scripts/classify-backlog.sh run \
  --repo <owner/repo> \
  --me <me-login literal, from the call above> \
  --trusted-authors "<trusted_authors (step 1.7), comma-joined, lowercased>" \
  --issues-file .shipyard-fetched-issues.json \
  --peer-claimed "<.peer_sessions.claimed_targets (step 1.65), comma-joined>" \
  --prioritize-label "<--prioritize-label CLI arg value, or empty string if not passed>" \
  --out .shipyard-classified.ndjson
```

The backslash continuations are fine — line structure is **not** what the guard reacts to (the same block collapsed onto one line is refused identically when it carries an unresolvable variable, and runs identically when it doesn't).

Then extract the two ranked lists. `jq` accepts the NDJSON file directly as a positional argument (a literal filename, not a variable — so this is safe as its own call), so neither extraction needs a pipe either:

```bash
raw_backlog=$(jq -r 'select(.verdict == "eligible") | .number' .shipyard-classified.ndjson)
investigate_candidates=$(jq -r 'select(.verdict == "route" and .reason == "investigate") | .number' .shipyard-classified.ndjson)
```

route:operator entries need no further action here (the agent-console
label, already on the issue, is what the operator phase's own sweep
reads); gate:*/drop:* entries need no further action either — each is
already excluded from raw_backlog by construction. Log
`.shipyard-classified.ndjson` (or at least each gate:*/drop:* line's reason) so the
unfiltered_open_count invariant token stays auditable. The two scratch files are untracked, ephemeral orchestrator-worktree artifacts — safe to leave (next pass overwrites them) or `rm -f`.

Both `raw_backlog` and `investigate_candidates` arrive from the script **already in rank order** — no separate sort pass is needed. **This description, like the routing bullets above, is non-normative — `backlog-filter.sh classify`'s `_sort_key` is the actual definition; read it there if this prose and the script ever disagree.**

`raw_backlog`'s default ranking (a repo with `milestones.enabled:false`, or no `milestones` block at all — the common case, and byte-identical to every pre-#1241 release): prioritized-label tier (only when `--prioritize-label` was passed), then priority label (`P0` > `P1` > `P2` > unlabeled), then type (`bug` > `fix(...)` titles > `feat(...)` titles > `chore(...)` titles > everything else), then staleness (oldest `updatedAt` first).

**When `milestones.enabled` AND `milestones.prioritize_dispatch` are both `true`** (issue [#1241](https://github.com/mattsears18/shipyard/issues/1241)), `raw_backlog` ranks milestone-aware instead:

1. **`P0`** — global, wins in ANY milestone. An emergency escape that exists precisely to violate the plan, not part of the sequencing itself.
2. **`--prioritize-label`** — an explicit per-run operator override, ranked below `P0` but above every other tier (a behavior *change* from the default order above, where the prioritized-label tier is outermost and can rank above a `P0`).
3. **Milestone**, ascending by the sequence number parsed from the issue's milestone title's `N · ` prefix — i.e. the earliest phase with dispatchable work. This falls out of sorting *eligible* issues alone: a phase with zero eligible issues never appears in the list, so ascending-`N` naturally skips it without any separate "does this phase have work" computation. An unmilestoned issue, or one whose milestone title doesn't parse, sorts to the tail rather than being dropped — **tied with the fallback milestone** (`milestones.fallback`) rather than strictly behind it, so tier 4 below decides between the two ([#1499](https://github.com/mattsears18/shipyard/issues/1499)). That tie matters because the fallback phase is the catch-all for work with no phase — semantically the same state as unmilestoned — so ranking one strictly ahead of the other wasn't a tiebreak but a wholesale severity override: a fallback-milestoned `P2` outranked an unmilestoned `P1`. The tie is scoped to the fallback phase alone; an unmilestoned issue is never promoted past a genuine earlier phase, and when no open issue carries the fallback milestone there is nothing to tie with, so unmilestoned issues sort last exactly as before.
4. **`P1` > `P2` > unlabeled**, then **type**, then **staleness** — the same tiebreakers as the default order, now operating *within* a milestone rather than across the whole backlog. Deliberately low-stakes: under parallel dispatch, within-milestone order barely changes outcomes, so don't over-invest in tuning these or add more tiers.

`investigate_candidates` ranks by priority label then staleness only (no prioritized-label, type, or milestone tier — milestone ranking is scoped to `raw_backlog`; see [`04d-investigate-routing.md`](./04d-investigate-routing.md)) — unaffected either way.

This ordered `raw_backlog` list is the initial backlog. If empty AND no failing PRs exist (next step), build [`04f-completion-ledger.md`](./04f-completion-ledger.md) before reporting "backlog empty" — stop only once every open issue is bucketed, 0 unaccounted (#1250). `investigate_candidates` non-empty ≠ raw_backlog non-empty — loop continues when raw_backlog is empty but investigate_candidates has entries (step 1.5 handles those).

### 4.5 Divert checks (main CI + PR pileup)

> **`--fast` skip:** When `--fast` is set, skip both 4.5a and 4.5b. Leave `main_ci.status = "unknown"` and `failing_pr_count_all = 0`. `divert_queue` stays empty. The user accepts the risk of dispatching into a red `main` or a ≥10-PR pileup — this is the documented tradeoff in the `--fast` arg description. The step-D periodic refresh does NOT run divert checks either when `--fast` was set (to preserve the latency savings for the full session). Note the skip in the end-of-session `--fast was used` advisory block.

Two repo-health conditions can preempt all normal work. Run these checks at setup, repopulate `divert_queue`, then continue. The same checks re-run during the periodic refresh (step D).

Both reads (4.5a and 4.5b) are part of the [setup parallelization batch](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch) — fire them in parallel with steps 1 / 2 / 3d.1 / 3d.2 / 5. The aggregation logic (per-workflow grouping in 4.5a, rollup filtering in 4.5b) runs locally on the JSON returned from each call; no further network I/O is needed.

**4.5a — Main CI status.** Determine whether main is currently healthy by looking at *each workflow's* most-recent COMPLETED run on `<default-branch>`. Main is green only when every workflow's last completed run was a success. Evaluate at **per-workflow** granularity — never aggregate across workflows on a single commit, and never filter `--status completed` in the `gh run list` call (it hides in-progress workflows). See [RATIONALE → Step 4.5a CI aggregation](../../do-work-RATIONALE.md#step-45a--why-per-workflow-ci-aggregation-matters) for the failure modes this prevents.

```bash
# Most recent 60 runs on the default branch (any status — DO NOT filter --status completed)
gh run list --repo <owner/repo> --branch <default-branch> \
  --limit 60 \
  --json databaseId,conclusion,status,displayTitle,headSha,url,createdAt,workflowName

# Branch protection — used to scope the red-gating set to required workflows only.
# 404 is the expected response on repos without branch protection (open-source forks,
# personal repos that never configured it); fall through to "all workflows gate".
gh api "repos/<owner/repo>/branches/<default-branch>/protection/required_status_checks" \
  --jq '.checks // [] | map(.context)' 2>/dev/null
```

Compute per-workflow status, then aggregate:

1. Group runs by `workflowName`. Within each group, keep `gh`'s newest-first `createdAt` order.
2. For each workflow, find its most recent run whose `status == "completed"` AND whose `conclusion != "cancelled"`. That's the workflow's current health:
   - `conclusion in {success, skipped, neutral}` → workflow is **green**
   - `conclusion in {failure, timed_out, startup_failure, action_required}` → workflow is **red**
   - no qualifying completed run in the window (only `in_progress` / `queued` / `waiting` / `requested`, or every completed run in the window was `cancelled`) → workflow is **pending**

   `cancelled` runs are skipped over rather than treated as a verdict — the common cause is normal supersession traffic (a newer commit auto-cancels the prior run), not a CI failure, so the next non-cancelled run on a newer SHA carries the actual verdict; see [RATIONALE → per-workflow CI aggregation, third trap](../../do-work-RATIONALE.md#step-45a--why-per-workflow-ci-aggregation-matters) for the full reasoning and a worked repro. If every completed run for a workflow in the 60-run window is `cancelled`, the workflow's status falls through to **pending** and step-D's next refresh re-evaluates once a non-cancelled run completes. Closes [#261](https://github.com/mattsears18/shipyard/issues/261).

2b. **A `success` conclusion is provisional until the run is confirmed to have actually executed ([#1495](https://github.com/mattsears18/shipyard/issues/1495)).** For every workflow that resolved **green** in step 2, read the deciding run's `jobs[].steps[]` — not its `jobs[].conclusion` — and check whether the run did any real work:

   ```bash
   gh run view <deciding-run-id> --repo <owner/repo> --json jobs --jq '.jobs'
   ```

   A job is **vacuous** when, among its user-authored steps (excluding the runner-injected `Set up job` / `Complete job` / `Set up runner*` / `Post *`), at least one step was `skipped` AND either the skipped steps outnumber the steps that ran, or a checkout-shaped step was skipped. A **run** is vacuous when at least one of its jobs is vacuous **and no non-vacuous sibling job executed substantively** — i.e. ran at least as many user-authored steps as the largest vacuous job has ([#1564](https://github.com/mattsears18/shipyard/issues/1564)). Both halves are load-bearing: in #1495's repro the `detect-paths` job ran a few steps while the required test job skipped everything, so the run stays vacuous; but a single-workflow repo with one legitimately path-scoped sibling (e.g. a `Lint (marketing)` job skipping on every non-marketing commit while Unit Tests / E2E ran in full) must not read as vacuous, or every run in the walk-back window trips, `main_ci` pins to `unknown`, and the `fix-main-ci` divert silently stops firing. A job-level `if:` skip (conclusion `skipped`, no step detail) is **not** vacuity: it never claimed to have run.

   - Deciding run **executed** → the workflow stays **green**. No change.
   - Deciding run **vacuous** → the workflow is **not** green. Walk back through that workflow's older completed non-`cancelled` runs, newest first, fetching each one's jobs until one **executed**; that run's `conclusion` becomes the workflow's status (green, or **red** — and if red, it is *that* run's `databaseId` / `headSha` / `url` that feed `earliest_red_*`, not the vacuous newest one). Bound the walk at 5 lookbacks.
   - No executed run within the walk → the workflow is **unproven**: a fourth per-workflow state alongside green / red / pending. It is NOT green.
   - The `gh run view` call itself fails (rate limit, token can't see job detail) → the workflow **keeps its run-level green** and the failure is surfaced as an advisory. Unlike the empty-set case, a real completed run *was* observed, so there is genuine (if weaker) evidence in hand; degrading every green to unproven on an API hiccup would be a worse failure than the one it prevents.

   **Do not re-derive any of this by hand — [`scripts/assert-ci-green.sh`](../../../scripts/assert-ci-green.sh) is the single executable source of truth** for the whole of steps 2 and 2b; exit `0` green / `1` red / `2` unknown / `3` pending / `4` unproven, and its stderr names the last run that actually executed and that run's conclusion. Call it like this:

   ```bash
   <plugin-root>/scripts/assert-ci-green.sh <owner/repo> --branch <default-branch>
   # The repo is POSITIONAL — there is no --repo flag (#1502).
   ```

   Why this matters: a required job that a `paths`/`paths-ignore` filter short-circuited reports `conclusion: success` having run **zero** tests, so a plain conclusion read is green-when-red — under the highest-priority divert in the loop, with the resulting stale red inherited by every PR opened afterwards. See `shipyard:worker-preamble` § "The second vacuous shape" — fragment [`ci-pitfalls.md`](../../../skills/worker-preamble/ci-pitfalls.md).
3. Resolve the **required-workflows set** that gates red aggregation. Closes [#262](https://github.com/mattsears18/shipyard/issues/262) — non-required workflows (post-release recovery helpers, infrastructure-state probes, scheduled cleanup jobs) commonly fail for reasons unrelated to code health and shouldn't trigger a `fix-main-ci` divert; see [RATIONALE → per-workflow CI aggregation, fourth trap](../../do-work-RATIONALE.md#step-45a--why-per-workflow-ci-aggregation-matters) for a worked repro. Resolution order (first match wins; later layers override the same field per the standard config merge):
   - **Config: explicit list.** If `main_ci.required_workflows` is set to a non-empty array in the effective merged config, that list IS the required set. Match against each workflow's `workflowName` exactly (case-sensitive).
   - **Config: `all-workflows` mode.** If `main_ci.aggregation_mode == "all-workflows"`, every workflow gates (the pre-#262 behavior). Skip the branch-protection probe.
   - **Branch protection (default behavior, `main_ci.aggregation_mode == "branch-protection"`).** Read `repos/<owner/repo>/branches/<default-branch>/protection/required_status_checks.checks[].context` (the `.context` field is the check-run name GitHub matches against, which equals the workflow name when the workflow has a single job — the common case). The returned list IS the required set. If the API returns 404 (no branch protection rule), an empty list, or any error, fall through to **all-workflows** (the safety default — when there's no signal that any workflow is non-required, gate on everything, matching pre-#262 behavior). When the rule does exist but the protected branch isn't the default branch in this repo (rare), the 404 fall-through still applies.

   Match each workflow's status to the required set. The required set splits workflows into two buckets:
   - **Gating bucket** — workflows whose name is in the required set. These are the only workflows that contribute to `main_ci.status` red.
   - **Informational bucket** — workflows NOT in the required set. Their per-workflow status (green/red/pending) is still computed and surfaced (see `non_required_red_workflow_names` below) so the user retains visibility into infra-health failures, but they do NOT cause a `fix-main-ci` divert.

4. Aggregate to a single `main_ci.status` using the **gating bucket only**. Precedence: **red > unproven > pending > green**.
   - any **gating** workflow is **red** → `main_ci.status = "red"`. Use the *most recent* red run across all red gating workflows as `earliest_red_run_*` (most actionable for the fix-main-ci dispatch). Collect **all** red gating-workflow names into `red_workflow_names` (sorted alphabetically).
   - else any **gating** workflow is **unproven** ([#1495](https://github.com/mattsears18/shipyard/issues/1495)) → `main_ci.status = "unknown"`, and record the workflow names in `unproven_workflow_names`. **`unproven` does not get its own `main_ci.status` value** — it maps onto the existing `unknown`, which already means exactly "not verified" and already carries the correct downstream behaviour everywhere (don't enqueue a divert, don't clear the attempt counters, don't claim main is healthy). Adding a fifth status value would have required touching every consumer to teach it a state whose handling is byte-for-byte identical to one it already has. What `unproven` adds over a plain `unknown` is *why*, and that lives in `unproven_workflow_names` + the status-line advisory below.
   - else any **gating** workflow is **pending** → `main_ci.status = "pending"`
   - else every **gating** workflow is **green** → `main_ci.status = "green"`
   - else (no gating runs at all in the window, or the gating set is empty) → `main_ci.status = "unknown"`

   `unproven` outranks `pending` because a pending workflow resolves itself on the next step-D refresh, whereas an unproven one will keep reporting a vacuous `success` on every subsequent path-filtered commit — it does not self-heal, so it must not be masked by a sibling that will.

Cache `{ status, earliest_red_run_id, earliest_red_run_url, earliest_red_sha, earliest_red_workflow_name, red_workflow_names, red_workflow_count, unproven_workflow_names, last_executed_run_id, required_workflow_names, required_workflow_source, non_required_red_workflow_names, non_required_red_workflow_count, checked_at: now }` in `main_ci`.

- `earliest_red_workflow_name` — the `workflowName` of the most recent red gating run (the same run whose `databaseId` is `earliest_red_run_id`). Used by the status line to show a single name in the compact format.
- `red_workflow_names` — sorted list of all red gating workflow names. Used by the banner to show the full list.
- `red_workflow_count` — `red_workflow_names.length`. Used by the status line truncation logic.
- `required_workflow_names` — sorted list of the resolved required set. Empty array when the source was `all-workflows` (no filter applied). Used by the end-of-session debug surfaces and `/shipyard:status`.
- `required_workflow_source` — one of `config-list`, `config-all-workflows`, `branch-protection`, `branch-protection-fallback-all-workflows`. Tells the maintainer where the gating set came from. The last value means a branch-protection probe was attempted but produced no usable list (404, empty, or error) — useful for diagnosing "why is `red_workflow_names` showing infra workflows?" on a repo that DOES have branch protection (e.g. wrong default branch, missing token scope).
- `non_required_red_workflow_names` — sorted list of red workflow names that are NOT in the required set. Surfaced in the status line and banner so the user still sees infra failures even though they don't divert. Empty when the source was `all-workflows`.
- `non_required_red_workflow_count` — `non_required_red_workflow_names.length`.
- `unproven_workflow_names` ([#1495](https://github.com/mattsears18/shipyard/issues/1495)) — sorted list of gating workflows whose newest completed run reported success but skipped every substantive step, and for which no run in the lookback window actually executed. Empty on the normal path. When non-empty, append `· unproven: <names>` to the status line's `main:` segment — a green-looking `main` that nothing has actually verified is precisely the state that must not pass silently, and this list is the only place it is visible.
- `last_executed_run_id` ([#1495](https://github.com/mattsears18/shipyard/issues/1495)) — when the walk-back resolved a vacuous deciding run to an older run that really executed, that run's `databaseId`; `null` otherwise. On a `red` resolved this way it is the same run as `earliest_red_run_id`, and it is the run whose logs the `fix-main-ci` worker should read — the newest run's logs contain nothing but skips.

- If `main_ci.status == "green"` → clear any `fix-main-ci` entry from `divert_queue`. **Also reset the attempt counter** ([#589](https://github.com/mattsears18/shipyard/issues/589)): for every signature in `main_ci_fix_attempts` whose workflow is *not* currently in `red_workflow_names`, delete the entry (the fix worked — main is green on that workflow, so the next time it reds it starts a fresh attempt cycle). A signature still in `red_workflow_names` keeps its counter.
- If `main_ci.status == "red"` → **before enqueueing, check the per-signature attempt cap** ([#589](https://github.com/mattsears18/shipyard/issues/589)). Read `main_ci.max_fix_attempts` from the merged config (default 3). Let `sig = earliest_red_workflow_name` and `att = main_ci_fix_attempts[sig].attempts // 0`:
  - If `att >= max_fix_attempts` (or `main_ci_fix_attempts[sig].escalated == true`) → **do NOT enqueue a `fix-main-ci` divert** for this signature. Set `main_ci_fix_attempts[sig].escalated = true`. This is the circuit breaker: the same workflow has been "fixed" `max_fix_attempts` times and each fix passed on its own PR run but left main's merge-commit red — the strong signal of a flaky CI-only test (a deterministic regression would fail the PR run too). Fire the **flake-escalation banner** (see [scope-preflight.md step 6.5's banner spec](06e-scope-ui-timing.md#state-change-banners--make-divert-events-impossible-to-miss)) once per signature on the transition into `escalated`, and surface `main:🔴 (<workflow-summary>, run <id>) · flake-escalated: <sig> (<att> fix attempts, each green-on-PR/red-on-merge)` in the status line. The escalation recommends quarantine (`test.fixme` / skip) + a tracking issue, or human CI-side investigation. Do NOT auto-retry — a human must intervene (same posture as a `blocked main-ci-fix` return).
  - Else (`att < max_fix_attempts`) → enqueue `{ kind: "fix-main-ci", target: "main", earliest_red_run_id, earliest_red_run_url, earliest_red_sha, earliest_red_workflow_name, red_workflow_names, red_workflow_count }` into `divert_queue` — unless an entry is already in `divert_queue` OR an `in_flight` slot is already working `kind: "fix-main-ci"` (don't double-dispatch the diversion).
- If `main_ci.status == "pending"` → don't enqueue; the next step-D refresh re-evaluates once a run completes.
- If `main_ci.status == "unknown"` → don't enqueue.

**Never** report `main_ci.status = "green"` on the basis of a single successful workflow run. The status line must derive from the per-workflow aggregate above. **And never on the basis of a run that reported success without executing anything** — a `conclusion: success` whose steps were all skipped by a path filter is not evidence, and step 2b is what converts it into one of `green` (via walk-back) / `red` (via walk-back) / `unknown` + `unproven_workflow_names` ([#1495](https://github.com/mattsears18/shipyard/issues/1495)).

The post-main-CI-fix branch-refresh that fires on a genuine transition into `main_ci.status == "green"` — un-sticking session PRs that carry a stale failing required check ([#993](https://github.com/mattsears18/shipyard/issues/993)) — lives in [`04h-post-main-ci-branch-refresh.md`](./04h-post-main-ci-branch-refresh.md#post-main-ci-fix-branch-refresh--un-stick-session-prs-carrying-a-stale-failing-required-check-993). Deep-link there when that transition fires.

**4.5b — Failing-PR pileup.** Count open PRs across **all authors** whose check rollup contains a hard failure:

```bash
gh pr list --repo <owner/repo> --state open --limit 200 \
  --json number,title,author,headRefName,statusCheckRollup
```

Filter to PRs where the **latest run per check name** has `conclusion in {FAILURE, ERROR, TIMED_OUT, CANCELLED, ACTION_REQUIRED}` (or `state` for legacy check-runs). Count distinct PR numbers → `failing_pr_count_all`. Cache the count and the matching PR numbers (`failing_prs_all_authors`).

**Use the latest-per-name projection, not a naïve rollup walk** (issue [#333](https://github.com/mattsears18/shipyard/issues/333)). `statusCheckRollup` returns the union of every check run for the PR's head SHA, including superseded runs — a check that ran, failed, was re-triggered, and passed appears twice (one FAILURE + one SUCCESS). A naïve `.statusCheckRollup[] | select(.conclusion=="FAILURE")` walk false-positives on every such PR, silently inflating `failing_pr_count_all` past the divert-threshold (`>= 10`) and triggering an unnecessary `fix-failing-prs-batch` divert against a pileup that has already cleared. De-duplicate by `name` and take the most recent entry per check (by `completedAt`, fallback `startedAt`) before checking for hard failures:

```bash
failing_pr_numbers=$(gh pr list --repo <owner/repo> --state open --limit 200 \
  --json number,title,author,headRefName,statusCheckRollup \
  --jq '[.[] | select(
    [.statusCheckRollup
     | group_by(.name)
     | map(sort_by(.completedAt // .startedAt // "") | last)
     | .[]
     | select((.conclusion // .state // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))]
    | length > 0) | .number]')
failing_pr_count_all=$(jq 'length' <<< "$failing_pr_numbers")
# A herestring (`<<<`), not `echo ... | jq` — the latter is a shell pipe
# spanning a tool boundary, exactly the shape the worktree-isolation guard
# refuses post-relocation (issue #1277). A herestring is input redirection
# into a single command, not a pipe between two.
```

- If `failing_pr_count_all >= 10` → enqueue `{ kind: "fix-failing-prs-batch", target: "pr-pileup", failing_pr_numbers: [...] }` into `divert_queue` — unless one is already enqueued OR `in_flight`.
- If `failing_pr_count_all < 10` → clear any `fix-failing-prs-batch` entry from `divert_queue`.

Both checks are cheap (two `gh` calls) and the cached results power the status line in step 5.5. Don't re-run them per dispatch — only at setup and at step D's periodic refresh.
