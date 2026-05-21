# /do-work — RATIONALE

Human-readable companion to [`commands/do-work.md`](./do-work.md). The runtime spec is the procedural reference the orchestrator executes; this file carries the *why* — design rationale, failure modes, motivating sessions, worked examples, and the long-form discussion that would otherwise bloat the spec. The orchestrator never needs to read this file; humans reviewing or evolving the spec do.

Section anchors mirror the spec's structure, so a maintainer who wants the rationale for a given spec section can navigate by name.

## Session state file — why a file at all

Three failure modes the prose-narrated state was prone to:

1. **Token-expensive.** Every turn paid the cost of re-emitting the eight-or-nine-struct state in prose (the invariant line + status line + state-change banners). On a 200-turn session that's ~20–30K wasted tokens.
2. **Drift-prone.** The LLM could mis-remember which slot held which issue, which soft-cap counters needed decrementing on a release, or which fields had stale values. Mirroring to a structured file with explicit field names makes drift visible to anyone reading the file.
3. **Inspectable.** A separate dashboard (browser, Slack notifier, CI status webhook) had no machine-readable source. The JSON file is the source. External readers do not have to parse orchestrator transcripts to know what's in flight.

The JSON file is **not** working memory for dispatch decisions. The LLM still has to hold the model in its head to walk the dispatch tree. The file is the artifact, not the algorithm.

### Atomic-write contract — why through a helper

Every write goes through `plugins/shipyard/scripts/session-state.sh`, which writes to `<target>.tmp.<pid>` and atomically renames into place. POSIX `rename(2)` is atomic on the same filesystem (the tmp-in-same-dir pattern guarantees this), so a partial-write crash leaves the previous file intact — never a half-written JSON document that downstream readers would choke on. The helper also drops any leftover `.tmp.<pid>` files on cleanup, so a crashed update doesn't accumulate cruft.

The helper is the **only** way the orchestrator writes to the session file — never edit the JSON directly with `Edit` / `Write` / `jq` / a shell heredoc, because none of those preserve the atomic-rename contract.

### Write-through cadence — why batched per turn

The granularity is "after the LLM has updated its working-memory copy of the struct, write through" — not "between every line of orchestrator narration." A single turn that reconciles a completion, releases a slot, and dispatches a replacement does **one** `update` call with multiple `--set` flags (or a small handful of chained calls) at the end of the turn, not a flurry of one-field-at-a-time writes.

### Failure mode — write-through breakage

If a `session-state.sh update` call fails (exit code != 0), the LLM's working memory has already advanced but the file has not. The orchestrator:

1. Logs a single `[session-state] update failed: <exit code> — session file out of sync with working memory; continuing` advisory in the transcript.
2. Continues the turn — does **not** stall dispatch waiting for the file to come back. The working memory is authoritative for dispatch decisions; the file is the mirror.
3. Re-attempts the write on the next turn's natural update cycle. A persistent failure (e.g., disk full, permission lost) will surface as repeated advisories and the user can intervene.

Read-through failures (exit code 3 — session file does not exist on a `read` call mid-session) indicate the file was removed under the orchestrator (manual `rm`, disk failure, end-of-session cleanup that fired too early). Treat as a deferred failure: log the advisory, continue from working memory, and the next `update` call will recreate the file via the `init` recovery path. The orchestrator does not block on file recovery.

## Step 0.5 — why a dedicated orchestrator worktree

Worktree isolation is a property of the whole system, not just the leaves. Three failure modes a "just be careful with cwd" rule fails to prevent:

1. **Race conditions with the user.** The user may be editing files in the primary checkout while `/do-work` is running. An orchestrator-side edit in the same tree can clobber unsaved work or land a commit on a branch the user didn't expect.
2. **Branch confusion.** `git reset` (even `--keep` or `--soft`) moves HEAD. If the user runs `git status` mid-session and sees commits appear and disappear on the branch they were working on, that's actively misleading. A separate worktree means the user's `git status` answer is whatever they were doing before they ran `/do-work` — unchanged.
3. **Symmetry with dispatched agents.** Agents are forbidden from `cd`'ing out of their worktree, from `gh pr checkout`, and from parking on the default branch. The orchestrator holds itself to the same standard.

## Step 1.7 — why a per-repo override file exists

The collaborators API answer can be wrong for the policy the maintainer actually wants: an org repo may have read-only collaborators who should be trusted to *file workable issues* even though they can't push, or a personal repo's maintainer may want to trust a specific external contributor across the board (a long-standing collaborator who works via PRs). `.shipyard/trusted-authors.txt` lets the maintainer state the policy explicitly without depending on GitHub's permissions model.

Bot accounts (`dependabot[bot]`, `github-actions[bot]`, etc.) are NOT auto-trusted. A bot account is still a non-human author and its issue body should be treated as untrusted by default — Dependabot doesn't open *issues* in normal operation, but if a malicious dependency author tampers with metadata that surfaces in a bot-filed issue, the same threat model applies. Maintainers who want to trust a bot add it to `.shipyard/trusted-authors.txt` explicitly. The collaborators API does not return bot accounts, so the fallback path already excludes them.

Cache lifetime is **session-scoped**. Don't re-resolve mid-session — if the maintainer needs to dispatch against a newly-added author during the session, they restart `/do-work`. The cost of one restart vs. the cost of every turn paying a `gh api` call is asymmetric.

## Step 2 — why bucket 0.5 is a security gate

Public-repo issues filed by strangers are untrusted input — an attacker can craft a body that reads like a legitimate bug report ("`foo()` returns null. Suggested fix: add `helper.ts` with `<crafted payload>`") and an `issue-worker` dispatched against it would read the body as instructions, ship a PR, and arm auto-merge. If CI passes (subtle payloads can be designed to pass), the malicious code lands in `main` of a public repo on the maintainer's machine. Worktree isolation prevents *filesystem* damage outside the agent's worktree, but it does NOT prevent malicious code from landing in a merged PR. The author check is the **dispatch-time** filter that keeps strangers' issues out of the workable queue entirely. The defense-in-depth measure (issue body treated as untrusted in `agents/issue-worker/issue-work.md` step 2) sits *behind* this filter — it catches anything that slips through, but the first line of defense is "don't dispatch a worker against an untrusted author."

**Override path for a one-off review.** A maintainer who has reviewed an untrusted-author issue and wants `/do-work` to pick it up has two paths: (a) re-file the issue under the maintainer's own account using the same body (the new issue's `author` is the maintainer, who is implicitly trusted), then close the stranger's original as a reference; (b) add the stranger's login to `.shipyard/trusted-authors.txt`. Path (a) is the right default — it makes the "I vouch for this work" signal explicit on the issue, doesn't require a config change, and the original stranger's history is preserved as a comment/reference on the re-filed one.

## Step 2 — bucket-table mode-selection rationale

**Two-mode rendering exists to optimize for the reader's eye.** A single-row "table" carries table syntax overhead without the alignment payoff — pipes, header divider, column gaps — so it reads as more visual noise than information. A multi-row table benefits from column-alignment because the eye can scan counts in a column instead of bouncing through indented bullets. So the rule: count non-zero buckets; `≥2` → fixed-width aligned text table; `1` → single-line summary; `0` → empty-backlog one-liner.

The **`Workable`-row-always-prints-in-table-mode** rule has a subtle wrinkle worth calling out: when counting rows to pick the *mode*, `<W> == 0` does NOT count as a non-zero bucket — otherwise a session where everything is blocked would render a two-row "table" with a zero-count `Workable` row, which is back to the degenerate shape this rule is trying to avoid. The single-line one-bucket shape (`Workable: 0. Skipped: <N> issues in <bucket> (...)`) is the right surface when there's exactly one real bucket.

Action-recommendation sub-rows (`⚠ likely-clearable` / `⚠ likely-triageable`) do NOT count as their own bucket for mode selection — they're structurally a sub-row under their parent bucket; the parent's non-zero count is what flips the mode.

## Step 2 — inline action-recommendation rationale

Beyond the per-issue unblock recommendation list at the bottom, the orchestrator surfaces **per-bucket candidate counts** under each Skipped-bucket. The intent is to make the "this bucket has N issues you could probably act on right now" signal visible at the bucket itself, not just in a flat recommendation list at the bottom. The orchestrator does NOT auto-act on these — it only surfaces them; the user decides.

The bias is deliberately toward **surfacing too many** candidates rather than too few. A false-positive costs the user one glance, but a false-negative leaves work invisible.

The bucket-5 candidate computation is a pure regex scan over already-fetched issue bodies — cheap, no extra network calls. The bucket-6 candidate computation is O(blocked-issues × referenced-blockers) `gh issue view --json state` lookups, but the `blocker_state` cache (default-on) ensures any reference resolved here is reused by step 3d.2 — no double-paying. Bucket-6 / bucket-7 / step 3d.2 all read and write the same map. Combined extra cost on a backlog of ~50 open issues is well under 1 second wall-clock when parallelized.

## Step 3d — why the `blocked:ci` / `blocked:agent` sweeps have different shapes

The asymmetry between the two sweeps is deliberate: `blocked:ci`'s premise is mechanical ("no new commits since the label was applied"), so the timestamp comparison is the right tool. `blocked:agent`'s premise is referential ("a specific other issue must close first"), so a body-reference scan is the right tool. Same shape, different signal.

**Why the `blocked:ci` sweep holds rather than clears on ambiguous signals.** A PR whose `blocked:ci` label was applied AFTER the head-branch commit (i.e. nothing has moved since shipyard gave up) MUST stay labeled. The `commit_ts > label_ts` comparison enforces this — if the commit timestamp is older than the label timestamp, the PR is genuinely stuck and the original "3 attempts, then give up" semantics still apply. Auto-clear fires only when a new commit has landed since the label was applied.

Failure modes that fall back to "held": the PR's head branch was deleted (rare but possible if the author force-pushed away or deleted the branch from underneath the PR — `gh api .../commits/$head_oid` errors); the `labeled` event aged out of the events API's pagination window (~90 days); a network blip on `gh api`. Any of these means the auto-clear can't make a confident judgment, so the safe default is to preserve the block.

**Why the `blocked:agent` sweep holds when there's no body reference.** The label is set but the body doesn't say what's blocking. Could be a human-applied label with the rationale in a comment thread, could be a free-form "waiting on Apple to ship X" gate. Either way, no mechanical signal to act on — hold.

**Secondary gates past the `Blocked by` line.** The body might say "Blocked by #881. Also don't start until Phase B has shipped AND there's a calendar month of organic-traffic data." This sweep only looks at the `Blocked by` reference; the secondary gate is a soft condition that's hard to detect mechanically. False-positives here are recoverable — the human re-adds `blocked:agent`, or the issue worker returns `blocked` after scoping. The cost of occasionally surfacing a still-soft-gated issue is far lower than the cost of leaving truly-unblocked issues invisible.

## Step 4 — why the `author` field is fetched

The `author` field on the `gh issue list` payload has two uses, both downstream of this fetch:

1. **Step 4's client-side filter** enforces the trusted-author allowlist — without it, the post-fetch filter can't distinguish an issue filed by `<owner>` from one filed by `@stranger123`, and the security gate fails open. The search-qualifier syntax has no `-author:` form that can filter for "anyone except this list," so the filter is necessarily client-side.
2. **Step 7's author-trust computation** uses it (carried through into `ready_issues`) to decide `originating_author_trust ∈ {trusted, external}` at dispatch time — the third defense-in-depth layer. In normal operation the step 4 filter already dropped any external-author issue, so step 7 only ever sees `trusted` candidates. But if the filter regresses, the dispatch-time gate still fires.

## Step 4 — auto-triage priority rationale

When torn between two tiers, pick the lower-severity one — over-labeling `P0` poisons the priority signal for the rest of the session. Anything that would have been "taste / would-be-nice" doesn't get a priority label at all (and falls to the unlabeled tier at ranking time).

Skip any issue that already carries one or more `P0`/`P1`/`P2` labels — preserve the human judgment that set them, even if you'd have picked a different tier. Don't remove existing priority labels, and don't add a second one. If multiple priority labels somehow coexist on the same issue, leave them alone (a human can clean up); ranking will use the highest one. Legacy `P3` labels from older sessions are treated as unlabeled — re-triage them to a P0/P1/P2 tier if you'd file them, otherwise leave them be.

## Step 4.5a — why per-workflow CI aggregation matters

Every commit on `<default-branch>` typically has *multiple* workflow runs (e.g. `ci`, `release`, `claude-review`). They run independently. A single `success` entry in `gh run list` proves only that ONE workflow passed — a sibling workflow on the same SHA, or the latest run of the *same* workflow, can still be red. So the wrong question is "is the newest run green?" — the right question is "for each workflow, is its most recent completed run green?" Evaluate at the **per-workflow** granularity.

Two specific traps to avoid:

- **Don't filter `--status completed` in the `gh run list` call.** Doing so hides in-progress workflows entirely. If `CI` is still running on the newest commit but `Release Please` already finished green, filtering completed-only leaves only the Release Please success visible — and the aggregator falsely concludes "main is green." Fetch all statuses and treat each one according to its `status` field.
- **Don't aggregate across workflows on a single commit.** Workflow A finishing green on commit X tells you nothing about workflow B's status — they're independent. If you aggregate per-commit, a newly-pushed commit with `CI: in_progress` + `Release Please: success` looks "pending or green," which masks the prior `CI: failure` that's still the most recent known CI result.

## Step 5 — why the `-label:blocked:ci` filter is still correct

[Step 3d's auto-clear sweep](./do-work.md#3-ensure-label-exists--recover-from-prior-session) already ran by the time the step-5 query fires — it stripped `blocked:ci` from every PR whose head-commit timestamp is newer than the label-application timestamp. So the PRs that still carry the label at this point are the genuinely-stuck ones (no new commits since shipyard gave up), and they should keep being skipped per the original "human needs to look" rule. The filter doesn't hide refreshed PRs anymore — those are unlabeled by step 3d and flow through normally.

## Step 6 — why scope pre-flight has a deferred shape

Scope pre-flight has two return shapes — ready and deferred. The deferred shape exists because some issues read clearly but aren't ship-able by a single worker: multi-PR migrations, SDK upgrades, external decisions (legal/design), infrastructure provisioning. Dispatching an `issue-worker` against one of these just burns agent time before it returns `blocked` mid-implementation. The scoping agent reads the issue + codebase and decides up front whether a worker can finish it.

The bias is deliberately *ready-by-default*: deferred is for clear multi-PR / external-input cases, not "this might be hard." A worker that returns `blocked` after scoping costs more than a deferred issue that turns out to have been doable — but a worker that lands a half-done multi-PR migration is worse than either.

**Why post a comment on the issue rather than label it.** Deferral is a *diagnosis*, not a *triage decision*. The orchestrator's diagnosis ("this is a multi-PR migration") may be wrong; the human reading the comment can override by re-filing the issue with a different scope, or by accepting the diagnosis and escalating. Labels would be premature — they'd commit the orchestrator to a categorization the user hadn't reviewed.

## Step D — refresh trigger rules: worked example

With `--concurrency 2` on a session with 30 completions, the old fixed cadence ran 15 refreshes. Under event-driven + adaptive backoff:

- Completions 1, 2, 3 are all `shipped` returns; trigger 1 fires each turn. Suppose all three refreshes produce zero delta (main is green, all-authors PRs are below threshold, no new failed `@me` PRs). After completion 3, `refresh_zero_delta_streak = 3`.
- Completion 4 is another `shipped` return; trigger 1 would fire, but rule 4's adaptive-skip kicks in (`streak >= 3`) → defer. No refresh this turn.
- Completion 5 is a `blocked` return → no event-driven trigger. If `now - refresh_last_at < 5 min`, no time-based fire either. Skip.
- Completion 6 is a `green` from fix-checks → trigger 2 would fire, but `streak >= 3` → defer.
- Eventually the 5-min fallback (trigger 3) fires — say between completions 7 and 8 — and that refresh runs unconditionally. If it produces a change (a PR went red while we were skipping), the streak resets to 0 and event-driven trigger 1/2 fires resume normally on the next completion. If it still produces zero delta, the streak ticks to 4 and the next time-based check is another 5 min away.

Net: on a quiet session the refresh count drops well below the old fixed `completions / concurrency` rate. On a busy session where external state IS changing (a main-CI red flares, a PR pileup grows past 10), the streak resets the moment a change appears and refreshes resume at full event-driven cadence. The combination keeps refresh cost low on quiet sessions while staying responsive on busy ones.

**Triggers that explicitly do NOT fire a refresh:**

- A `blocked` / `blocked #<N> at fix-checks` / `blocked rebase #<M>` / `blocked main-ci-fix` / `blocked pr-batch-fix` return. No PR state changed (or the PR is stuck for human attention).
- An `errored` return. Same reasoning — no PR state changed.
- A `noop: not dirty (<reason>)` / `noop: main already green` / `noop: pileup already cleared` return that did not produce or resolve a PR. State may have drifted externally, but the agent's no-op signal alone doesn't justify a refresh; the 5-min fallback (trigger 3) picks it up.
- A `rebased #<M>` return from drain-phase fix-rebase. Drain-phase refreshes are disabled anyway (the drain guard at the top of step D).

## Step E — why the invariant line is load-bearing

The invariant line is the single source of truth for "did this turn do its job?" Whenever you find yourself ending a turn without one, you have skipped step C — the dispatch is unresolved. The `state=<state>` token also makes the per-turn write-through to the session state file visible in the same line: a transcript-only reader can confirm the file got the turn's state-mutation write (or surfaced a documented degradation) without inspecting `$SHIPYARD_HOME/sessions/<session-id>.json` directly.

The `idle_reason` constraints exist because vague reasons ("waiting for completions", "merge train draining", "nothing to do right now") are the recap pattern in disguise. If you can't name the queue-level reason the slot is empty, you haven't actually checked the queues.

Common causes of an incomplete turn that the self-check catches: (a) drafted a recap sentence and ended the turn before issuing the `Agent` tool call; (b) reconciled the completion but forgot the freed slot needs filling; (c) mistakenly believed "auto-merge will handle it" justifies skipping new dispatches.

## Dispatch rules — why soft-collision tiering exists

The soft-collision tier exists because the meta-bottleneck on a docs-heavy backlog is that every issue touches the same few additive-style files (`CHANGELOG.md`, `CLAUDE.md`, `README.md`, and on the shipyard plugin repo itself, `commands/do-work.md`). Under the original all-hard regime, three workers all wanting to append a CHANGELOG entry would serialize down to one in flight at a time — `--concurrency 4` collapsed to 1 in practice. The soft tier caps simultaneous claimers per distinct path at `--soft-collision-concurrency` (default 3), trading "no merge conflicts ever" for "parallelism on additive paths, with trivial PR-land conflicts the orchestrator handles via fix-rebase."

**Soft caps are per-path, not per-claimer.** A worker claiming `CLAUDE.md` AND `CHANGELOG.md` consumes one slot in each path's counter, not one combined slot. Two workers both claiming `CLAUDE.md` plus a third workers claiming only `CLAUDE.md` puts all three in flight (3/3 on that path's counter); a fourth claiming `CLAUDE.md` parks.

**Soft paths never collide with hard paths of the same file** — they are evaluated against the soft cap, not the hard-collision rule. In practice nothing in the default soft set is also in the hard set, because the soft set is exhaustively additive-docs paths. If a user's `--soft-collision-path` extension somehow overlaps a hard-natured path, the soft tier wins for that path — that's the user's stated intent. Pick globs carefully.

**Cross-worker conflict resolution belongs to the orchestrator.** Agents have no visibility into each other's worktrees — they can't pre-resolve. When two soft-collision PRs both touch `CLAUDE.md`, the second one to land hits a DIRTY mergeStateStatus; the orchestrator dispatches a fix-rebase worker against it. The fix-rebase trivial-conflict-or-bail policy handles additive CHANGELOG/CLAUDE.md/docs conflicts cleanly in 95%+ of cases. If it bails, the PR surfaces in the end-of-session summary as still-DIRTY with a "soft-collision conflict on `<path>` — needs manual merge" note.

## Dispatch rules — section-aware lockfile collision

The section-aware rule replaces an older boolean `touches_lockfile` flag. The boolean was too coarse: any two lockfile-touchers would serialize even if one was editing `overrides` and the other was editing `scripts`. Sections-as-claims lets disjoint sections co-run, which dramatically improves throughput on Dependabot-heavy or polyglot backlogs.

`package-lock.json` / `pnpm-lock.yaml` / `go.sum` / `Cargo.lock` (the generated artifacts) are never claimed as sections — they're regenerated additively post-merge by the package manager, and the merge-train's auto-rebase already handles their textual conflicts via the fix-rebase worker's regenerate-the-lockfile policy.

## Author-trust computation — defense in depth

In normal operation step 2's bucket 0.5 and step 4's client-side filter have already dropped every external-author issue before it reaches `ready_issues`, so the candidate's trust is virtually always `trusted` at the dispatch point. The per-dispatch computation is **defense in depth** — the dispatch-side companion to the intake-side `external-author-gate` GitHub Action and the dispatch-time allowlist filter. If both principal gates somehow regress simultaneously (the GitHub Action is disabled, the orchestrator's bucket-0.5 / step-4 filter is bypassed), step 6 of the worker still refuses to arm auto-merge for an external-origin PR — labeling it `needs-human-review` instead.

## Soft drain — why it's safe to let agents finish

Agents commit at logical milestones (TDD test → commit, implementation → commit) and PRs are opened with `--auto`. Letting an in-flight agent finish naturally never loses work. Killing it mid-edit could.

Substring matching on the trigger phrases is deliberately avoided. Phrases like "don't stop yet" or "I'll drain it later" do not trigger drain mode — only a trimmed body exactly matching `stop` / `drain` / `/do-work stop` does.

## Termination — why the merge train continuing isn't a stop signal

Two independent processes are running: (1) the dispatch loop that fills `--concurrency` slots from the backlog, and (2) the merge train that lands open PRs as their checks turn green. The merge train continues without you. The dispatch loop dies if you stop dispatching. Treat them as orthogonal — never use "the train will drain on its own" or "auto-merge handles it from here" as a justification to stop dispatching new work.

**Don't ever ask the user "should I keep working, summarize, park, or stop?"** Termination is mechanical. As long as ANY of `in_flight` / `failed_prs` / `ready_issues` / `raw_backlog` / `divert_queue` is non-empty, you keep dispatching. Drafting a question about whether to continue, summarize, or idle is itself the bug.

## End-of-session drain — why it exists past the dispatch loop's end

Once the dispatch loop's queues go empty, some PRs the orchestrator opened may still be `pending` CI or waiting for auto-merge. **Don't terminate while the merge train is still draining.** Two independent processes are running: the dispatch loop (now empty) and the merge train. The merge train runs without dispatching anything, but it can still go red mid-flight — a flaky test surfaces, a sibling merge causes base drift on a queued PR, a dependency update breaks at minute 18. If you stop monitoring at minute 15, those failures sit unfixed until the next `/do-work` session.

The drain phase keeps the orchestrator alive past the dispatch loop's end, watching the merge train and dispatching fix-checks workers against newly-red PRs, until either every session-opened PR has settled OR the train has clearly stalled.

**Why the drain handles DIRTY PRs via fix-rebase.** Long sequences of merges advance main faster than open PRs can rebase onto it, leaving PRs in `mergeStateStatus: DIRTY` with no failing checks — just stale base. Auto-merge won't fire on a DIRTY PR. A drain-phase fix-rebase dispatch rebases onto current main and force-pushes; the rebased branch re-enters the merge train naturally.

**Why each fix-rebase is one-shot per PR per session.** A `blocked rebase` outcome means a human (or the next session, after main advances further) needs to handle it; re-dispatching within the same session would just produce the same conflict. The `rebase_blocked_prs` set is the membership check; it also counts toward the drain's "settled" definition so a stuck PR doesn't keep the drain alive indefinitely.

**Why fix-rebase is drain-only.** The mode exists to keep the merge train flowing past base-drift hiccups while the orchestrator is winding down. Steady-state dispatch never produces a DIRTY PR (a freshly-shipped PR is always on a fresh branch). The only place DIRTY PRs accumulate is during the drain. Dispatching fix-rebase mid-session would either (a) churn branches that auto-merge was about to rebase anyway, or (b) interfere with a fix-checks worker that is mid-flight on the same branch.

**Hard ceiling: 120 min.** As a safety net against degenerate cases (a 90-minute test suite, a runaway CI loop), drain forcibly exits at the 120-min mark even if forward progress is still observable. The 120-min number is deliberately generous — for normal sessions (10–20 PRs draining over 30–60 min wall-clock) the no-progress rule fires first and the ceiling never triggers.

## End-of-session cleanup — why the orchestrator worktree is reaped last

The orchestrator worktree itself is still around because the orchestrator was running inside it. After the user-facing summary has printed — and only then; you can't remove the worktree you're still cwd'd into — the cwd jumps back to the user's primary checkout (read-only at this point — we're not writing, we're just being somewhere `git worktree remove` can succeed from), then removes the orchestrator worktree.

This is a read-only-effect operation on the primary checkout — `git worktree remove` modifies `.git/worktrees/` (shared metadata), not the primary's working tree or HEAD. The primary's HEAD never moves.

**Why liveness-check the lock-holding PID at shutdown too.** End-of-session cleanup step 3 (this session's agents) ALSO classifies the lock-holding PID, because termination logic can fire early — a still-running agent whose worktree gets reaped loses any unpushed work and ends up trying to operate in the primary checkout or a foreign worktree. The reaped-but-still-running agent path is also covered defensively from the worker side (the issue-worker template's "detect-my-worktree-was-reaped" escape hatch), but the orchestrator's job is to not put workers in that position in the first place.

**Why `self-ancestor` is a distinct classification (issue #138).** A naïve "lock PID alive = defer" check has a load-bearing edge case: the Claude Code harness writes the **orchestrator's** PID into every dispatched agent's lock file (lock content is literally `claude agent <agent-id> (pid <orchestrator-pid>)`). At end-of-session cleanup the orchestrator is by definition still alive — it's the process running cleanup — so a strict liveness check defers EVERY worktree the orchestrator itself owns. The reporter saw 2 agent worktrees stuck across a session because every lock PID resolved to PID 53391, the orchestrator's own. The fix lives in [`scripts/worktree-reap.sh`](../scripts/worktree-reap.sh): walk our own process ancestor chain (self, parent, grandparent, ...) and if the lock PID appears anywhere in it, classify as `self-ancestor` — alive but not a peer, safe to reap because it's the orchestrator about to retire its own worktree. Peer agents in other Claude Code instances are NOT in our ancestor chain (they're at best siblings via a shared init), so `peer-alive` still correctly defers genuine concurrent work.

## Don't — extended rationale for the load-bearing rules

The spec's `Don't` section enumerates the rules tightly. This section carries the *why* behind the rules that have caused real damage in past sessions — so anyone considering loosening one can see what the rule prevents.

### Don't go idle while queues hold work

When in-flight workers all return but the queues still hold work, the merge train auto-draining prior PRs is irrelevant to your loop. Your job is to dispatch new workers into the freed slots, not to wait for auto-merge to land prior PRs. Pool drained + backlog non-empty = you are failing to do your job. Refill the pool on the same turn the last completion notification arrives.

### Don't conflate "pool drained" with "session complete"

The merge train continues without you. The dispatch loop dies if you stop dispatching. The pool draining is NOT the termination signal — when all in-flight workers return but `raw_backlog` / `ready_issues` / `failed_prs` / `divert_queue` still have entries, the correct next action is to dispatch up to `--concurrency` new workers on the very next turn — not to summarize, not to wrap up, not to ask "want me to keep working or park?", not to idle.

### Don't exit the drain while forward progress continues

The dispatch loop's queues going empty is the signal to enter the end-of-session drain, not to terminate. Exiting earlier — at a hard 15-min mark, or because "looks quiet enough," or because "the user can re-run later" — strands any PR that goes red after the cap with no orchestrator watching to dispatch fix-checks. The realistic case is a 30–40 PR session whose merge train takes 45–90 min wall-clock; don't cut that off prematurely.

### Don't emit recap / "Next: …" narration in lieu of dispatching

The orchestrator's failure mode is to summarize the situation in prose ("Currently 2 workers in flight; a dozen PRs are awaiting CI auto-merge. Next: watch returns and refill the pool from the remaining backlog issues.") and then end the turn without issuing the `Agent` tool call that would actually refill the pool. The recap *sentence itself* is the bug — it gives the model a graceful exit from a turn whose dispatch obligation hasn't been met. Forbidden phrasings include: "Next, I'll watch for …", "Waiting for completions to refill …", "The merge train will drain on its own …", "Will refill the pool from the backlog as agents return …". Every one of these is a description of behavior the harness already provides (notifications on completion); narrating it is pure overhead AND it tricks the model into thinking the turn is done.

The correct shape of a turn that frees a slot is: tool call → invariant line. The correct shape of a turn that legitimately can't dispatch is: structured `[invariant] ... idle_reason="..."` line, nothing else. No prose between them, no prose after them, no "Next:" sentence anywhere.

Contrasting example — DO NOT do this:

```
Slot 3 freed by #769 shipping. Pool: 2/8 in flight.
Goal: drain the lightwork backlog via /do-work with 8 parallel agents.
Next: watch returns and refill the pool from the remaining backlog issues.
```

DO this instead:

```
[Agent tool call dispatching slot 3 with next ready_issue]
[Agent tool call dispatching slots 4-8 with next ready_issues (if also free)]
[invariant] in_flight=8/8 · ready_issues=27 · failed_prs=1 · divert_queue=0 · raw_backlog=12 · dispatched_this_turn=6
```

Or, if every queue really is empty and `in_flight` is also empty:

```
[invariant] in_flight=0/8 · ready_issues=0 · failed_prs=0 · divert_queue=0 · raw_backlog=0 · dispatched_this_turn=0 · idle_reason="all queues empty (terminating after in_flight drains)"
```

### Don't accept a `green` return without verifying the rollup

The agent's `green` claim is supposed to mean "a full CI run completed and passed after my fix" — but ad-hoc dispatch prompts (or a worker that drifted from the canonical template) can return `green` after merely pushing and queueing the rebuild. Trusting that silently leaves a red PR in `session_prs` looking settled, and the drain phase will skip it because it's not in `failed_prs` either. The fix is the trust-but-verify spot-check in step A's fix-checks reconcile — one cheap `gh pr view <M> --json statusCheckRollup` call, then downgrade to `pending` (any rollup state still `PENDING` / `IN_PROGRESS`) or `failing` (any rollup state hard-failed). Never skip the spot-check as an optimization.

### Don't treat a narrative status string as authoritative

If the agent's last line doesn't start with `green`, `noop:`, or `blocked`, the worker violated the return contract — it returned something like `"Waiting for monitor."` / `"Shard 2 still running."` / `"Routine progress, awaiting E2E."` instead of blocking its own turn on `gh pr checks <M> --watch` until checks resolved. The harness delivered that narrative string to the orchestrator as a completion notification, but the underlying CI work is still in flight. Do NOT label the PR `blocked:ci`. Do NOT push onto `failed_prs` based on the narrative alone (which might race with a fix the original worker is still pushing). The defense is the dedicated `Unrecognized return string` branch in step A's fix-checks reconcile: query `gh pr view <M> --json statusCheckRollup` once, synthesize the real outcome from the rollup, log a `[fix-checks-unrecognized]` advisory, and continue. This filter is what stops a single misbehaving worker from burning six orchestrator turns on stale re-notifications.

### Don't write to the user's primary checkout

After step 0.5, the orchestrator works exclusively in `.claude/worktrees/orchestrator-<session-id>`. The primary checkout is strictly read-only — read-only ops like `git status`, `gh issue list`, `find`, `grep`, `git worktree list` are fine in either cwd, but every write (`Edit`, `Write`, `git add`, `git commit`, `git branch <new>`, `git push`, `git reset`, `git checkout -B`, label/README/CHANGELOG/`plugin.json` edits, etc.) MUST land in the orchestrator worktree. If a write-class command ends up modifying the primary checkout's HEAD, working tree, or any tracked file in it, that's the exact failure mode step 0.5 was added to prevent — back up, switch to the orchestrator worktree, and retry.

### Don't reap a peer-alive worktree — at startup OR at shutdown

Step 3b's lock-PID classification prevents you from yanking a worktree out from under another active Claude Code instance running its own `/do-work`. End-of-session cleanup step 3 (this session's agents) ALSO classifies, because termination logic can fire early — a still-running agent whose worktree gets reaped loses any unpushed work and ends up trying to operate in the primary checkout or a foreign worktree. Always run [`scripts/worktree-reap.sh classify-lock`](../scripts/worktree-reap.sh) before unlocking / removing. Skip `peer-alive` worktrees in both paths; reap `no-lock` / `dead` / `self-ancestor`. The `self-ancestor` case is a non-obvious safe-to-reap: the harness writes the orchestrator's own PID into agent lock files, so at shutdown every agent's lock points to a process that's alive but isn't a peer — it's the orchestrator about to retire its own worktree (see [issue #138](https://github.com/mattsears18/claude-plugins/issues/138) for the bug a strict liveness check would re-introduce).

### Don't dispatch a worker against an untrusted-author issue

This is the security boundary established by step 1.7 and enforced by step 2's bucket 0.5 + step 4's client-side filter + step C's lightweight backlog re-check. The threat model: a stranger opens a public-repo issue with a body that reads like a legit bug report ("Suggested fix: add `helper.ts` with `<crafted payload>`"), an `issue-worker` dispatched against it reads the body as instructions, ships a PR, arms auto-merge, and (if CI passes) the malicious code lands in `main` of a public repo on the maintainer's machine. Worktree isolation prevents *filesystem* damage outside the agent's worktree but does NOT prevent malicious code from landing in a merged PR. The dispatch-time filter is the first line of defense; never bypass it ("just this one issue, the body looks fine") because the entire point of the filter is that the body has already been compromised when you're judging it. Maintainer override: add the login to `.shipyard/trusted-authors.txt` or re-file the issue under the maintainer's own account.

### Don't omit the `shipyard:worker-preamble` skill reference

Every dispatch prompt opens by directing the worker to load `shipyard:worker-preamble`, which carries the shared worktree-isolation rules, the `--label shipyard` requirement, the auto-merge + snapshot + return pattern, the worktree-reaped escape hatch, and the no-`--no-verify` rule. If you author a new dispatch prompt template, reference the skill the same way. Skipping it lets the agent silently corrupt the user's primary checkout (via `gh pr checkout` resolving the wrong cwd), park a worktree on `[main]` (which blocks the user's `git switch main` until the worktree is reaped), or ship a PR without the `shipyard` label (which makes it invisible to the orchestrator's own state machine).

### Don't expect agents to resolve cross-worker merge conflicts on soft-collision paths

When two or more in-flight workers both edit, say, `CLAUDE.md` (one of the default soft-collision paths), their PRs will likely conflict at merge time because GitHub's merge queue applies the second PR's changes onto a `CLAUDE.md` the first PR already modified. The agents have no visibility into each other's worktrees — they can't pre-resolve. The orchestrator is the only actor that knows both claims existed. Before clicking merge (or letting auto-merge land) on the **second** soft-collision PR for a given path, the orchestrator MUST inspect `mergeStateStatus` — if it's `DIRTY` or has a `UNSTABLE` merge conflict on a soft-collision file, dispatch a fix-rebase worker for it (drain-style) which will rebase onto the just-landed main and force-push. **Do NOT** ask agents to coordinate with each other (they can't) and do NOT serialize all soft-collision dispatches (that defeats the whole point of the tier).
