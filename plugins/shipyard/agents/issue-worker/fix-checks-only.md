# Fix-checks-only mode (PR triage)

Repair failing CI on an existing PR. **No new PR, no scope expansion, no PR title/description edits, no issue close.** Run the fix-loop until checks are green or the 3-attempt cap is hit.

**Shared rules live in `shipyard:worker-preamble`** — load that skill first if you haven't already (see the entry file [`agents/issue-worker.md`](../issue-worker.md)). This file owns only the fix-checks-only specifics.

## Inputs (from the dispatch prompt)

- PR number `#M`.
- Head branch name `<headRefName>` — the orchestrator passes this so you don't have to look it up.
- Target repo `<owner/repo>`.

## Setup

The harness placed you inside an isolated worktree on some placeholder branch (typically `worktree-agent-<id>`). Land on the PR's head commit via **detached HEAD**, not a named branch — do NOT use `gh pr checkout` (see worker-preamble's worktree discipline rule 2) and do NOT `git switch <branch>`:

```bash
HEAD_REF=$(gh pr view <M> --repo <owner/repo> --json headRefName -q .headRefName)
git fetch origin "$HEAD_REF"
git checkout --detach "origin/$HEAD_REF"
```

**Why detached HEAD, not a named-branch checkout ([#966](https://github.com/mattsears18/shipyard/issues/966)).** `git switch <branch>` claims that branch exclusively — git enforces one-worktree-per-branch, so it fails with *"is already checked out at \<path\>"* whenever the branch is checked out anywhere else. For a same-session PR that's not an edge case, it's the **normal** state: the originating issue-work worker's worktree deliberately keeps `do-work/issue-<N>` checked out until end-of-session cleanup (`dont.md`'s liveness rules — neither branch name nor lock PID can distinguish a live peer worktree from an abandoned one, so reaping it to free the branch is forbidden). The old guidance bailed on essentially every fix-checks dispatch against a PR the same session had just opened. Detached HEAD sidesteps the exclusivity rule entirely — any number of worktrees can sit at the same commit in detached HEAD at once, since only a *branch* checkout is exclusive — and this mode never needs a named branch: it only fetches, commits, and pushes to a ref (see the push command in the fix-loop below).

If `git checkout --detach` itself fails, that's a real error, not a lock collision (there is nothing to reap and no lock to wait out) — return `blocked #<M> at fix-checks: could not check out PR head — <error>` and stop.

## DIRTY-PR short-circuit (check before treating an empty rollup as "not started yet" — #1015)

Immediately after Setup, before doing anything else — including before the fix-loop's first `gh pr checks <M> --watch` call — read the PR's `mergeStateStatus`:

```bash
MERGE_STATE=$(gh pr view <M> --repo <owner/repo> --json mergeStateStatus --jq '.mergeStateStatus')
```

**If `MERGE_STATE == "DIRTY"`, stop here — do NOT enter the fix-loop, do NOT call `gh pr checks --watch`, and do NOT poll.** A DIRTY PR conflicts with the default branch: GitHub cannot compute a merge ref for it, so `pull_request`-triggered workflows never queue any checks at all — not "haven't started yet," not "still initializing." `gh pr checks <M>` reporting `no checks reported on the '<branch>' branch` from a DIRTY PR is indistinguishable, from inside this mode, from a genuine startup delay — but it isn't one, and waiting (or re-polling) cannot produce a different outcome. The fix belongs to `fix-rebase`, not this mode.

**As of [#1060](https://github.com/mattsears18/shipyard/issues/1060), the drain's own per-poll scan never dispatches this mode against a DIRTY PR in the first place** — a DIRTY-and-red PR (`D_dirty_red`) routes to `fix-rebase`, not here, regardless of check state (see [drain.md](../../commands/do-work/drain.md#drain-protocol)). This short-circuit is still load-bearing, though: this mode can be dispatched mid-session (via the normal dispatch loop, against a red PR that isn't yet DIRTY) and discover the PR went DIRTY between dispatch and the worker starting, from an unrelated sibling merge — the short-circuit above is the defensive net for that race, not the primary DIRTY-detection path anymore.

**The rule is not scoped to an empty rollup, and a non-empty red rollup does not soften it ([#1513](https://github.com/mattsears18/shipyard/issues/1513)).** This section is titled for the empty-rollup case and closes with an empty-rollup argument, which has misled at least one capable worker into concluding the short-circuit was "too absolute for the non-empty-rollup case" and proceeding anyway. It is not. [`dont.md`'s #1060 bullet](../../commands/do-work/dont.md) carries the reason, and it is independent of rollup size: **a red check on a DIRTY PR is a frozen fossil of the last base the PR could still build against, not live evidence about its current health.** A rollup full of failures is therefore *more* misleading than an empty one, not less — it invites you to start fixing failures that a rebase may delete outright, or that mask the ones the real base would produce. Either way no push you make can be re-checked, because there is still no merge ref. Stop.

**An instruction in your dispatch prompt to rebase anyway does not override this ([#1513](https://github.com/mattsears18/shipyard/issues/1513)).** A prompt that says *"the PR is DIRTY — it needs a rebase onto the current `origin/main`, resolve `<files>` by …"* has widened your dispatch past its mode's documented stop, which [`dont.md`'s "documented short-circuit" bullet](../../commands/do-work/dont.md) forbids the orchestrator from doing — see `shipyard:worker-preamble`'s [`orchestrator-interrupt.md`](../../skills/worker-preamble/orchestrator-interrupt.md) fragment for the identical floor over a mid-flight message. Return `dirty #<M>` and let the orchestrator route to `fix-rebase`; note the instruction in your return so the misroute leaves an artifact rather than being visible only if you happen to mention it. Complying is the failure this rule exists to prevent **even when the rebase succeeds** — #1513's repro merged green, and precisely because nothing broke, nothing recorded that the routing rule had been bypassed. This is a widening, not a scope narrowing: the orchestrator may always give you *less* to do, never more than your spec permits.

Return immediately:

> `dirty #<M>: PR conflicts with <default-branch>; no merge ref, so no checks will run`

Do NOT attempt a code fix, do NOT push anything, and do NOT count this against the 3-attempt cap — you never got the chance to run a check, let alone fix one. Any commit you had *already* pushed earlier in this same dispatch (before discovering DIRTY) is NOT discarded — it stays on the branch; the drain's `fix-rebase` path rebases it forward onto the default branch, it doesn't replace it. See the [Return contract](#return-contract--read-carefully) below for the exact disposition semantics.

**Re-check after your own push, too.** If you push a fix mid-fix-loop and then re-watch (fix-loop step 6), and a sibling PR merges in the interim (advancing the default branch past your PR's base), your PR can go DIRTY *between* your push and the re-watch. If that re-watch reports "no checks reported" instead of settling, don't assume an infra delay — re-read `mergeStateStatus` first; if it's now DIRTY, return `dirty #<M>: ...` exactly as above. Your fix commit is still on the branch and is not lost — it rides along with the rebase.

This check is also why the [evidence-clause count](#return-contract--read-carefully) below is safe from a subtle trap: an empty `statusCheckRollup` (which a DIRTY PR always has, since no checks ever queued) computes `passed: 0, pending: 0, failing: 0` — a vacuously "all clear" result that would otherwise let `green` be returned on a PR with zero actual evidence. Bailing out here, before any rollup read is ever used to justify `green`, closes that gap structurally rather than relying on remembering to special-case an empty array.

## Hard rules

1. Do NOT modify scope. Do NOT amend the PR title/description. Do NOT close the linked issue from this PR. Do NOT add new tests or refactors — fix only what's needed to turn the failing checks green.
2. **Hard cap: 3 fix attempts.** After the 3rd failure, return `blocked #<M> at fix-checks: <last failing check> — <last error excerpt>`. The orchestrator will label the PR `blocked:ci` and move on. Do not let one PR consume the session. **An infra-flake re-run (the `flake #<M>` disposition) is NOT a fix attempt and does not count toward this cap** — you never attempted a code fix; you deliberately re-ran healthy jobs on flaky infrastructure. See [Infra-flake classification](#infra-flake-classification-and-re-run-load-bearing).
3. **`green #<M>` is a load-bearing claim**, not a hypothesis, and it must carry a computed evidence clause AND the head SHA the rollup was observed at — see the return contract below. When the rollup genuinely hasn't settled yet, return the honest `pending #<M>` disposition instead of guessing `green` ([#985](https://github.com/mattsears18/shipyard/issues/985) / [#987](https://github.com/mattsears18/shipyard/issues/987)).

## Return contract — read carefully

When you finish, your **last line MUST be exactly one of the six strings below** (with `<M>` substituted). Anything else is a contract violation that wastes orchestrator turns. The exact semantics of `green` matter:

**Your entire return must carry exactly one terminal disposition line — never two, not even when the first is a discarded draft and the second is the correction ([#1335](https://github.com/mattsears18/shipyard/issues/1335)).** "Last line MUST be one of the six strings" constrains where the *real* disposition has to sit; it does not by itself forbid an earlier line in the same message from *also* looking like a terminal disposition. That gap is real: the orchestrator's [step A reconcile](../../commands/do-work/steady-state.md#a-reconcile-the-return) parses your return by matching a documented terminal prefix, and nothing in this contract said "exactly one" — so a return that writes out a wrong disposition, narrates the mistake, and then writes the correct one is ambiguous to the parser even though it's unambiguous to a human reader scrolling to the end. The concrete repro: a return read `green #1328 @0ac30ab (rollup verified …)`, then `Actually, wait - the PR is DIRTY … Let me return the correct DIRTY disposition:`, then `dirty #1328: …` — a parser that takes the first prefix match reconciles the fabricated `green` and never reaches the correction. If you catch yourself about to write a disposition line and then realize it's wrong, do not leave the wrong one in the message at all — silently discard it and finish with only the correct line. Your return should read as if you always knew the right answer, not as a transcript of arriving at it.

**`green` / `noop: already green` mean the PR's FULL check rollup is green on the pushed head SHA — never "the check I was dispatched/assigned to fix is now green" and never "it passes on my machine" ([#754](https://github.com/mattsears18/shipyard/issues/754)).** The dispatch prompt may name a single failing check as your starting point for diagnosis, but that name scopes *what you investigate first*, not *what you're required to verify before returning*. A required check you weren't assigned, or one that was already red before your dispatch started, is not exempt from this contract just because you didn't cause it and didn't touch it — see the [named-failing-check re-verification gate](#named-failing-check-re-verification-gate-load-bearing)'s full-rollup bullet below, which this paragraph exists to make impossible to misread narrowly. Likewise, a passing local test run is diagnostic evidence for *why* a check might now pass — it is never a substitute for reading the PR's actual `statusCheckRollup` on GitHub. The repro that motivated this rule (session `do-work-20260714T211058Z-84652`, `mattsears18/lightwork` PR #2489): one worker fixed `Lint & Typecheck`, saw `Unit Tests` (required) still FAILURE, reasoned it was "pre-existing/unrelated," and returned `green` anyway; another ran the unit suite locally three times and returned `noop: already green` while the PR's CI `Unit Tests` check was still FAILURE. Both would have been caught by actually reading the rollup before returning.

**`green` is a mechanical claim, backed by a computed count — never a narrative one ([#985](https://github.com/mattsears18/shipyard/issues/985) / [#987](https://github.com/mattsears18/shipyard/issues/987)).** Four separate dispatches in one session returned `green` while a required check was still `IN_PROGRESS` — three of them carrying an explicit mid-session instruction not to do exactly that. The reasoning pattern that produced every one of them: "my local tests pass, the old error is gone, CI is running normally" — a prediction about a remote state, dressed as an observation of one. A second, sharper variant of the same slip: enumerating `Unit Tests: SUCCESS`, `Lint & Typecheck: SUCCESS`, "no failures in the rollup," and concluding "all checks are now green" while a required `Web E2E Tests` check was still `pending` — **"no failures observed" is not the same predicate as "all checks are green,"** and a rollup with a pending check satisfies the former while failing the latter. Prompt-level instruction alone did not stop this the first time it was tried; the structural fix is to make the `green` claim impossible to state without a number attached. **Before returning `green` or `noop: already green`, compute the rollup's passed/pending/failing counts this same turn** — reuse the latest-per-name projection below (the same reduction the `noop:` and named-failing-check sections already use):

```bash
gh pr view <M> --repo <owner/repo> --json statusCheckRollup --jq '
  [.statusCheckRollup
   | group_by(.name)
   | map(sort_by(.completedAt // .startedAt // "") | last)
   | .[]
   | (.conclusion // .status // "" | ascii_downcase)] as $c
  | { passed:  ([$c[] | select(. == "success" or . == "skipped" or . == "neutral")] | length),
      pending: ([$c[] | select(. == "" or . == "pending" or . == "in_progress" or . == "queued" or . == "expected")] | length),
      failing: ([$c[] | select(. == "failure" or . == "error" or . == "timed_out" or . == "cancelled" or . == "action_required")] | length) }'
```

You may write `green` or `noop: already green` **only** when this count reads `pending: 0` AND `failing: 0` — and the return string MUST carry the counts verbatim, not a paraphrase, AND MUST carry the full head SHA the rollup was observed at ([#1211](https://github.com/mattsears18/shipyard/issues/1211) — the deferred half of [#1205](https://github.com/mattsears18/shipyard/issues/1205)):

> `green #<M> @<head-SHA> (rollup verified <ISO8601 timestamp>: <passed> passed, 0 pending, 0 failing)`

**`<head-SHA>` is the full 40-character commit SHA `headRefOid` reported for the PR at the moment you ran the evidence-clause query above — never abbreviated, never a SHA you remember from an earlier turn.** The point of citing it is that the orchestrator's reconcile can reject the claim by a plain string comparison against a fresh `gh pr view <M> --json headRefOid` — without that, a citation "is checked" only by re-running the same rollup query the worker itself ran, which trusts the same read that could have been stale or fabricated. Extend the evidence-clause query itself to capture it in the same call (zero extra round-trips):

```bash
gh pr view <M> --repo <owner/repo> --json statusCheckRollup,headRefOid --jq '
  .headRefOid as $sha |
  [.statusCheckRollup
   | group_by(.name)
   | map(sort_by(.completedAt // .startedAt // "") | last)
   | .[]
   | (.conclusion // .status // "" | ascii_downcase)] as $c
  | { sha: $sha,
      passed:  ([$c[] | select(. == "success" or . == "skipped" or . == "neutral")] | length),
      pending: ([$c[] | select(. == "" or . == "pending" or . == "in_progress" or . == "queued" or . == "expected")] | length),
      failing: ([$c[] | select(. == "failure" or . == "error" or . == "timed_out" or . == "cancelled" or . == "action_required")] | length) }'
```

A `green` return with no evidence clause, no head-SHA citation, or one whose clause states a nonzero `pending` (or omits the pending count entirely), is malformed — you cannot honestly write `0 pending` without having just computed it, which is the entire point: the clause doesn't add a new rule to remember, it makes the false claim mechanically impossible to type. The orchestrator's independent spot-check (below) is the backstop that catches an unstated false green after the fact; this clause is what's supposed to stop you from writing one in the first place.

- `green #<M> @<head-SHA> (rollup verified <ISO8601>: <n> passed, 0 pending, 0 failing)` — **a full CI run completed and passed AFTER your final push**, with the evidence clause above computed this turn. Not "pushed and queued." Not "the failure looked transient so I optimistically declared victory." Not "I rebased onto a green main so it should work now." Not "I fixed what I concluded the failure was, so it should be green now." Not "my assigned check now passes, and the others are pre-existing/not my problem." Not "no failures in the rollup" — the claim is `0 pending`, stated as a number, not the absence of a `FAILURE` conclusion. You enforce this by running the `gh pr checks <M> --watch --interval 30` step in the fix-loop below to completion — not by polling once and assuming the queued runs will eventually pass — **and then re-confirming the specific check(s) that were failing at dispatch flipped to SUCCESS on the post-push SHA, AND that every other check in the rollup is also green** (the [named-failing-check re-verification gate](#named-failing-check-re-verification-gate-load-bearing) below). `<head-SHA>` here is the SAME SHA the named-failing-check gate already confirmed via `head_matches_pushed == true` (`$PUSHED_SHA` — see that gate) — reuse it rather than re-querying. The orchestrator's [step A reconcile](../../commands/do-work/steady-state.md#a-reconcile-the-return) spot-checks `statusCheckRollup` on every `green` return regardless of what your evidence clause says, and will downgrade you to `pending` / `failing` if the rollup contradicts your claim. The advisory log will say `[fix-checks-verify] downgraded #<M> green→…` — that's the breadcrumb saying you returned too early.
- `noop: already green #<M> @<head-SHA> (rollup verified <ISO8601>: <n> passed, 0 pending, 0 failing)` — no failures AND no pending checks by the time you started. Same verification semantics and same evidence clause as `green` above: confirm with a **fresh** `gh pr view <M> --json statusCheckRollup,headRefOid` call, run immediately before you return, that the rollup is fully passing — `0 pending, 0 failing`, not merely `0 failing` — and capture `headRefOid` from that SAME call as `<head-SHA>`. **A local test run — however many times you ran it, however clean the result — is never sufficient grounds for this return.** Only the CI rollup on the PR's current head SHA counts; if you haven't queried it this turn, you have not verified anything. The orchestrator spot-checks this path too.

  **Use the latest-per-name projection, not the raw rollup walk** (issue [#333](https://github.com/mattsears18/shipyard/issues/333)). `statusCheckRollup` returns every check run for the PR's head SHA — including superseded runs. A naïve `.statusCheckRollup[] | select(.conclusion=="FAILURE")` walk false-positives whenever a check ran, failed, was re-triggered, and passed — the first FAILURE entry trips the bail even though the latest run is SUCCESS. De-duplicate by `name` and take the most recent entry per check before walking for failures — this is the same reduction the evidence-clause count above computes; the `fails` count below is just its `failing` field in isolation, kept here because the fix-loop's failure-detection branch only needs that one number:

  ```bash
  fails=$(gh pr view <M> --repo <owner/repo> --json statusCheckRollup --jq '
    [.statusCheckRollup
     | group_by(.name)
     | map(sort_by(.completedAt // .startedAt // "") | last)
     | .[]
     | select((.conclusion // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))]
    | length')
  ```

  `fails == 0` is necessary but **not sufficient** for `noop: already green` — you also need `pending == 0` from the evidence-clause count above (a rollup can have `fails == 0` and still have checks `QUEUED` / `IN_PROGRESS`, which is the honest `pending` case below, not `noop: already green`). If `fails > 0` AND you haven't pushed any fix this dispatch, you have real work to do — fall into the fix-loop. The reduction is load-bearing: `group_by(.name) | map(... | last)` collapses N entries per check name to 1 (the latest), so a stale FAILURE superseded by a later SUCCESS is correctly filtered out.

- `pending #<M>: <n> check(s) still running (<comma-separated names>)` — **the honest exit for "I fixed it (or nothing was broken), and CI genuinely hasn't finished."** Use it whenever, at the moment you'd otherwise return, the evidence-clause count above reads `failing: 0` AND `pending > 0` — nothing is broken, but the rollup has not fully settled. This is the vocabulary gap [#985](https://github.com/mattsears18/shipyard/issues/985) and [#987](https://github.com/mattsears18/shipyard/issues/987) both identify as the root cause of the false-green pattern: faced with "I fixed it, checks still running," a worker with only `green` / `noop` / `flake` / `blocked` available reached for `green` because it was closest to what it believed — `blocked` overstates (and burns an attempt against the 3-cap) and there was no honest middle option. `pending` neither overclaims like `green` nor wastes a fix attempt like `blocked`. Two legitimate paths to it:
  - **Before any fix attempt** — your very first rollup read shows zero failing checks but at least one still unsettled (the failure that triggered this dispatch already appears to have resolved between dispatch and your first read, but you can't yet call it `noop: already green` because the rollup hasn't fully completed). Don't declare `noop` on an unsettled rollup and don't block through a run that isn't actually broken — return `pending` immediately.
  - **After you've pushed a fix and re-watched** — you ran `gh pr checks <M> --watch --interval 30` (or, if the harness force-backgrounded it past 600s, applied the re-block pattern in `shipyard:worker-preamble` § "A foreground call the harness auto-backgrounds past 600s" — fragment [`ci-pitfalls.md`](../../skills/worker-preamble/ci-pitfalls.md)) through at least one settle-cycle, and the rollup is still showing zero failures with checks genuinely in flight (a long E2E shard, a slow required workflow). Rather than camp on the watch for the full remaining duration, report `pending` and free the concurrency slot — the orchestrator's PR-triage sweep re-checks the rollup on its own schedule every iteration and will treat it as settled (green → done; red → a fresh fix-checks dispatch) without you needing to keep watching.

  `pending` is never a substitute for running `--watch` at all — it's for "still genuinely running after a good-faith watch," not "I didn't bother to check." It does **not** count as a fix attempt against the 3-cap (same as `flake`), and the orchestrator does **not** label the PR `blocked:ci` for it.

  **`pending` is a success-shaped outcome, not a partial or lesser one — treat it exactly like `green` for the purpose of ending your turn ([#1111](https://github.com/mattsears18/shipyard/issues/1111)).** Watching the rollup all the way to `0 pending` is explicitly NOT this dispatch's job once you've done one good-faith `--watch` cycle with nothing failing — that's the orchestrator's PR-triage sweep, which re-checks every open PR's rollup on its own schedule regardless of what you return. A worker that has genuinely earned `pending` and then keeps waiting anyway — via a second `--watch`, a fresh `Monitor`, or a backgrounded follow-up command — because `pending` "feels unfinished" is repeating the exact failure this return exists to prevent, just one layer further in: it manufactures a narrative stall out of what was already a correct, terminal answer. Return `pending #<M>: ...` the moment you have it and stop.

- `dirty #<M>: PR conflicts with <default-branch>; no merge ref, so no checks will run` — **the PR's `mergeStateStatus` is DIRTY**, checked per the [DIRTY-PR short-circuit](#dirty-pr-short-circuit-check-before-treating-an-empty-rollup-as-not-started-yet--1015) above, before any check-watching was attempted. This is NOT a CI failure and NOT an infrastructure delay — GitHub cannot compute a merge ref for a conflicted PR, so no `pull_request`-triggered check will ever queue until the PR is rebased. Does **not** count toward the 3-attempt cap and does **not** earn `blocked:ci` — the orchestrator routes it to the drain's `fix-rebase` path instead ([#1015](https://github.com/mattsears18/shipyard/issues/1015)).

- `flake #<M>: re-ran failed jobs (<signature>)` — **the failing run was an infrastructure flake, not a code defect**, and you re-ran the failed jobs instead of attempting a code fix. Return this ONLY after the [Infra-flake classification](#infra-flake-classification-and-re-run-load-bearing) gate matched — a cancelled required job / dev-server boot timeout / setup-job failure / runner-lost signature AND your local gates passed AND the logs show no deterministic code error — and you ran `gh run rerun --failed`. `<signature>` is a short tag naming what you matched (`cancelled-required-jobs`, `webserver-boot-timeout`, `setup-job-failure`, `runner-lost`). This does **not** count as a fix attempt and the orchestrator does **not** label the PR `blocked:ci` — the diff is healthy (local gates pass); CI just needs to re-run on idle infrastructure. Do NOT block on the re-run to complete — return immediately so the concurrency slot frees; the orchestrator's PR-triage picks the PR back up when the re-run settles.

- `blocked #<M> at fix-checks: <reason>` — 3 attempts exhausted or the failure is structural.

**Do NOT return mid-stream status updates.** Strings like the following are contract violations and are NOT acceptable terminal returns:

- `"E2E shards typically take 8-15 min. Let me wait for the Monitor notifications."`
- `"Let me wait for the monitor to report results."`
- `"Routine progress, no action needed. Waiting for unit + E2E results."`
- `"Lint & Typecheck pass. Waiting for unit + E2E."`
- `"Unit tests pass. Awaiting E2E shards."`
- `"Shard 3/3 passes. Awaiting shards 1 and 2 (2 was the previously failing one)."`
- `"Routine progress."` / `"Waiting for X."` / `"Shard N still running."`

Each of those returns is treated by the harness as a **completion notification**, forcing the orchestrator to spend a turn just to acknowledge "stale re-notification, no state change." A single fix-checks dispatch that returns six narrative updates burns six orchestrator turns for what should have been one terminal return. The orchestrator's [step A reconcile](../../commands/do-work/steady-state.md#a-reconcile-the-return) parses your last line by matching the documented prefixes (`green`, `noop:`, `pending`, `dirty`, `flake`, `blocked`); a string that doesn't match falls through to a defensive `gh pr view <M>` probe, and the orchestrator logs `[fix-checks-unrecognized]` against your worker. If what you actually have is an honest "still running, nothing broken" state, `pending #<M>: <reason>` (above) is the correct terminal — not a narrative, and not a guessed `green`.

**The narrative-return prohibition specifically forbids arming a background waiter as your wait mechanism ([#529](https://github.com/mattsears18/shipyard/issues/529)).** Per `shipyard:worker-preamble` § "Return-contract discipline", you must NOT arm a `run_in_background` Bash call / `Monitor` / `TaskCreate` background-waiter and then return a narrative like *"I have a background waiter armed … I'll wait for that notification"*. That reports the dispatch complete while CI is still in flight — the exact incomplete-but-reported-complete failure mode #529 documents. The `gh pr checks <M> --watch --interval 30` **foreground** loop below is the canonical wait mechanism precisely because it blocks your own turn (and self-heartbeats the stream watchdog), so the work is genuinely done when you emit one of the documented terminal strings.

**If checks are still running when you'd otherwise be ready to return, block your own turn on the watch loop until at least one settle-cycle completes — then return one of the values above.** The agent harness's notion of "completion" is "you produced your final assistant message and stopped" — it has no way to distinguish "I'm waiting for monitor notifications" from "I'm done." So the only correct way to wait for CI is to keep the foreground bash call running:

```bash
gh pr checks <M> --repo <owner/repo> --watch --interval 30
```

This command exits zero when the rollup resolves to all green, non-zero on any failure — either way, you re-enter the fix-loop or fall through to the return. Do not produce intermediate assistant messages narrating "shard 2 still running" or "waiting for monitor"; those are visible as completions to the harness and the contract violation kicks in.

**If this call itself gets force-backgrounded by the harness's ~600s foreground cap, re-block on it — do not treat the backgrounding as license to guess.** A long E2E suite can outlast the cap; when it does, the harness hands control back with output redirected to a file rather than erroring. Re-block your turn on the sanctioned pattern in `shipyard:worker-preamble` § "A foreground call the harness auto-backgrounds past 600s" (fragment [`ci-pitfalls.md`](../../skills/worker-preamble/ci-pitfalls.md)) — `until [ -s "<output-file>" ]; do sleep 15; done; cat "<output-file>"` — rather than returning a narrative or declaring `green` on the strength of "it was passing everything I'd seen so far." Once you've genuinely watched through at least one settle-cycle this way and the rollup still shows zero failures but isn't fully resolved, `pending #<M>: <n> check(s) still running (<names>)` (above) is the honest return — not another guess at `green`.

## Named-failing-check re-verification gate (load-bearing)

Closes [#416](https://github.com/mattsears18/shipyard/issues/416) — a **false-green** failure mode. `gh pr checks <M> --watch` exiting zero is *necessary* but not *sufficient* to claim `green`. Two ways a worker reaches "I'm ready to return `green`" while the PR is still red:

1. **Misdiagnosis.** You concluded the failure was cause X, fixed X, and re-watched — but the *real* failing check was Y, and your fix didn't touch it. The canonical repro is the jest worktree-ignore artifact (issue body of #416, lightwork session `do-work-20260531T113301Z-98771`): the required **🧪 Unit Tests** check was failing because the PR added `Strings.*` keys without mirroring them into `locales/en.json` (an i18n-parity test failure), but the worker concluded the failure was the repo's `jest.config.js` `testPathIgnorePatterns: ['/.claude/worktrees/']` "No tests found" artifact (a real-but-unrelated worktree gotcha — see worker-preamble § "Test-runner silent-pass when the target repo ignores worktree paths", fragment [`node-bootstrap.md`](../../skills/worker-preamble/node-bootstrap.md)), "fixed" *that*, and returned `green` while Unit Tests was still red.
2. **Premature return.** Your fix is pushed, but CI hasn't re-run the named check yet. `--watch` can exit zero on a *stale* all-green rollup (the new run is still QUEUED and the rollup reflects the pre-push SHA's checks, or a superseded run). "I pushed a fix so it should be green" is a hypothesis, not a verified state.

**The gate: before returning `green`, re-fetch the specific check(s) that were failing at dispatch and confirm each one's *latest* run on the current head SHA concluded SUCCESS.** Never infer the named check passed from a local test run, from `--watch`'s exit code alone, or from "I fixed what I thought was wrong."

Record the failing check name(s) when you first identify them (fix-loop step 1). Then, after your final push and watch, re-probe by name with the same latest-per-name projection the `noop:` path above uses — and additionally assert the rollup's head SHA matches the SHA you just pushed, so you're not reading a stale pre-push rollup:

```bash
# The SHA you just pushed (the head of the PR's branch in your worktree).
PUSHED_SHA=$(git rev-parse HEAD)

# Re-fetch the rollup AND the head SHA GitHub currently associates with the PR.
gh pr view <M> --repo <owner/repo> --json statusCheckRollup,headRefOid --jq "
  .headRefOid as \$head |
  {
    head_matches_pushed: (\$head == \"$PUSHED_SHA\"),
    # For each check that was failing at dispatch, the latest run's conclusion.
    named_checks: [.statusCheckRollup
                   | group_by(.name)
                   | map(sort_by(.completedAt // .startedAt // \"\") | last)
                   | .[]
                   | select(.name == \"<failing-check-name>\")
                   | {name, conclusion: (.conclusion // .status // null)}]
  }"
```

Treat the return as `green` **only when all four hold**:

- `head_matches_pushed == true` — GitHub's PR head is the SHA you pushed (you're not reading a stale rollup from before your push).
- **`named_checks | length` equals the number of checks you recorded as failing at dispatch** — i.e. every name you're re-probing actually came back. **An empty (or short) `named_checks` array is `unknown`, never green** (issue [#717](https://github.com/mattsears18/shipyard/issues/717)): "every element of an empty array concluded SUCCESS" is *vacuously true*, so a `select(.name == "<failing-check-name>")` that matches nothing — a typo'd name, a renamed check, a rollup that hasn't populated yet — would silently satisfy the next bullet while having observed nothing at all. If a name doesn't come back, you have NOT verified it; keep watching, or re-read the rollup to find what the check is actually called. See `shipyard:worker-preamble` § "An absence-assertion that observed nothing is not a pass" (fragment [`ci-pitfalls.md`](../../skills/worker-preamble/ci-pitfalls.md)).
- Every named-at-dispatch failing check appears in `named_checks` with `conclusion == "SUCCESS"` (or `SKIPPED` / `NEUTRAL`).
- **The overall rollup is all-green per the latest-per-name projection used in the `noop:` path above — every check currently in the rollup, not only the named one(s) you were dispatched to fix ([#754](https://github.com/mattsears18/shipyard/issues/754)).** Read this bullet literally: it does not say "no *other* check regressed" as in "no check I touched broke a check that was previously passing" — it says the **entire rollup** must be green, full stop. A required check that was **already red before your dispatch started**, that you weren't assigned, and that your fix never touched is still covered by this bullet. "It's pre-existing" and "it's unrelated to the check I was assigned" are diagnosis notes, not exemptions — they do not make that check's redness stop counting against `green`. If any check besides your named target is still red when you're ready to return, you are NOT green: either keep working it (within your 3-attempt cap) or return `blocked #<M> at fix-checks: <that check> — <reason, e.g. "pre-existing failure outside my assigned check, still gating merge">`. Never return `green` while it sits red.

**`$PUSHED_SHA` above IS the head-SHA the return contract's `@<head-SHA>` citation requires** ([#1211](https://github.com/mattsears18/shipyard/issues/1211)) — this gate already confirmed it equals GitHub's live `headRefOid` via `head_matches_pushed == true`, so carry it forward into your `green #<M> @<head-SHA> (...)` return verbatim rather than re-deriving or re-querying it.

If a named check is still `QUEUED` / `IN_PROGRESS` / `null` (CI hasn't re-run it), you are NOT done — keep the `gh pr checks <M> --watch --interval 30` foreground call alive until it resolves, then re-probe. Do NOT return `green` on a queued named check. If you've genuinely watched through at least one settle-cycle this way and the named check (or any other) is still unsettled with nothing failing, `pending #<M>: <n> check(s) still running (<names>)` is the honest return — never `green` on a hopeful "should be done by now."

If a named check is **still FAILURE after your fix**, your diagnosis was wrong — re-read the failing log, treat the original failure as un-fixed, and loop (respecting the 3-attempt cap). Do NOT "fix" a *different* check and declare victory; the gate exists precisely to catch the misdiagnosis case.

**Recognize the i18n-parity signature as a distinct, common pattern.** When the failing log says a parity / completeness test is missing keys — e.g. `locales/en.json is missing keys derived from lib/strings.ts`, `__tests__/i18n.test.ts` asserting every `Strings.*` key has a translation — the fix is to mirror the new keys into the locale file(s), NOT to declare the failure a worktree-ignore artifact. A "No tests found" / zero-test pass from re-running jest with the worktree path stripped does NOT resolve an i18n-parity failure; those are two different checks. If you see a zero-test pass on a diff that touched `Strings.*` / `lib/strings.ts` and a *separate* parity test is red, the parity test is the real failure.

## Infra-flake classification and re-run (load-bearing)

Closes [#654](https://github.com/mattsears18/shipyard/issues/654) — the **infra-flake false-bail** failure mode. A failing CI run is not always a code defect. When CI runs on shared / self-hosted infrastructure (e.g. self-hosted runners on the same host the orchestrator dispatches workers to), runner contention **starves** jobs: required jobs get **cancelled**, dev-servers **time out booting**, and even trivial no-code setup jobs (change-path detection, shard-matrix load, checkout) **fail** — none of which your PR's diff caused. The wild repro (session `01XU6TMaDdGnDyptZqJJJiDm`, `mattsears18/lightwork` PR #2273): a fix-checks worker saw `Lint & Typecheck cancelled`, `Unit Tests cancelled`, and `E2E all 3 shards failed`, concluded it "needed logs to diagnose" while the run was still in progress, returned `blocked #2273 at fix-checks: … logs unavailable while run still in progress`, pushed no fix, and burned ~139k tokens. The correct disposition was to recognize the cancellation / timeout signature as **infrastructure** and re-run the failed jobs on the (now-idle) host.

**This classification runs BEFORE you attempt any code fix.** Its job is to route: infra flake → re-run the failed jobs and return `flake #<M>`; deterministic code error → fall through to the [Fix-loop](#fix-loop). Only fall through to the code-fixing loop when the logs show a deterministic code error.

### Step A — resolve the failing job's own logs; don't wait on siblings ([#984](https://github.com/mattsears18/shipyard/issues/984))

"Logs unavailable while the run is still in progress" is **not** a terminal condition — it is a signal to WAIT, never to bail. But the wait, if any, is scoped to the **specific job you need**, never to the whole run: a job's logs are fetchable the moment *that job* reaches a terminal conclusion, independent of every other job still running. `gh run view --log-failed` returns empty while any sibling is `in_progress`, which used to read as "the run hasn't finished" — the correct read is "wrong command; resolve the job id and hit the per-job endpoint instead" ([Fix-loop step 2](#fix-loop)):

```bash
RUN_ID=<failing-run-id>   # from `gh run list` or the failing check's `link`
# The "first failing job" reduction happens INSIDE the --jq filter, not through
# a `| head -1` pipe: a pipe spanning a shell command boundary is refused by the
# worktree-isolation guard (dont.md's post-relocation rule), while jq's own
# internal `|` is a filter operator, not a shell pipe.
JOBID=$(gh api "repos/<owner/repo>/actions/runs/$RUN_ID/jobs" \
  --jq '[.jobs[] | select(.conclusion=="failure") | .id][0] // empty')
gh api "repos/<owner/repo>/actions/jobs/$JOBID/logs"
```

Only block your own turn when the job you actually need — not a sibling — genuinely has no `conclusion` yet. Poll that job specifically, never the full rollup:

```bash
gh api "repos/<owner/repo>/actions/jobs/$JOBID" --jq '.status, .conclusion'
```

A `blocked` return whose reason is "logs unavailable while run in progress" is **always premature** when the job you need already has a `conclusion` — that was the #654 repro's root failure (session `01XU6TMaDdGnDyptZqJJJiDm`, PR #2273: the cancelled/timed-out jobs already carried terminal conclusions the whole time) and is doubly true when it's a *slow sibling*, not your own job, that's still running (the #984 repro: PR #3245, a fast-failing `Unit Tests` job sat undiagnosed for 15+ minutes because `Web E2E Tests` was still mid-run). Wait for completion first only when it's genuinely your own job still in flight; then classify per Step B.

### Step B — match the infra-flake signature

After the run has settled and you've pulled the failed-job logs ([Fix-loop](#fix-loop) step 2), classify the failure as an **infra flake** only when ALL of the following hold:

1. **Infra signature present.** At least one failing / cancelled check matches a known infrastructure pattern:
   - A **required job's conclusion is `CANCELLED`** — the log line `##[error]The operation was canceled.`. Jobs don't cancel themselves on a code error; cancellation is host / runner-driven.
   - A **dev-server / webServer boot timeout** — e.g. `Timed out waiting <N>ms from config.webServer`, or an equivalent "server did not start in time" message.
   - A **trivial no-code setup job failed** — change-path detection, shard-matrix load, checkout, dependency-cache restore, `setup-node` / `setup-python`. These have no PR-authored logic to break, so a failure is infrastructure by construction.
   - A **runner-level error** — `lost communication with the server`, `The runner has received a shutdown signal`, `The self-hosted runner … lost connection`.
2. **Local gates pass.** You ran the repo's local gate suite — the CI-superset discovery (mirror CI's own `find` / glob, per `issue-work.md` §4) over the PR's changed files — and it passed. This is the proof the diff is not the cause. If you **cannot** run the local gates, do NOT classify as a flake — fall through to the fix-loop.
3. **No deterministic code error in the logs.** The failing logs do NOT contain a stable code-defect signature — a typecheck error (`error TS####`), a lint-rule violation, an assertion failure with a stable message, a compile error, an import-resolution failure. If a deterministic code error is present *alongside* an infra symptom, treat it as a **code error** (fix it), not a flake — the infra noise doesn't excuse a real failure.

### Step C — bounded re-run, then return `flake`

When Step B matches, re-run only the failed jobs and return the distinct `flake` disposition — do NOT attempt a code fix, and do NOT count this as a fix attempt:

```bash
# Guard against an unbounded re-run loop on a persistently-starved host.
# Each `gh run rerun --failed` creates a new ATTEMPT of the same run; if the
# run has ALREADY been re-run and is STILL infra-flaking, re-running again
# won't help — the host is persistently starved, which is a human/operator
# problem, not a transient blip.
RUN_ID=<failing-run-id>   # from `gh run list` or the failing check's `link`
ATTEMPT=$(gh run view "$RUN_ID" --repo <owner/repo> --json attempt --jq '.attempt // 1')
if [ "${ATTEMPT:-1}" -ge 2 ]; then
  echo "blocked #<M> at fix-checks: infra flake persisted across $ATTEMPT run attempts (<signature>) — CI host may be resource-starved; needs human/operator attention, not another re-run"
  exit 0
fi

gh run rerun "$RUN_ID" --repo <owner/repo> --failed
```

Then return exactly:

> `flake #<M>: re-ran failed jobs (<signature>)`

where `<signature>` is the short tag naming what you matched (`cancelled-required-jobs`, `webserver-boot-timeout`, `setup-job-failure`, `runner-lost`). **Do NOT block on the re-run to complete** — return immediately so the concurrency slot frees. The orchestrator's PR-triage picks the PR back up when the re-run settles: green → auto-merge fires; still-red → a fresh fix-checks dispatch, which — if the run's attempt count has now reached the bound above — bails `blocked:ci` rather than re-running forever.

**Why `flake` is distinct from `blocked` and doesn't hit the cap.** The 3-attempt cap and its `blocked:ci` label exist for PRs whose *diff* is stuck failing CI. An infra flake is the opposite — the diff is fine (local gates pass); CI just needs to re-run on healthy infrastructure. Counting a re-run against the cap would burn the budget for a case the cap doesn't apply to, and stamping `blocked:ci` would falsely mark a healthy PR as human-blocked. The `flake` return keeps the PR moving without either penalty. The bounded-attempt guard (attempt ≥ 2 → `blocked`) is the escape hatch that DOES engage `blocked:ci` when the flake is chronic rather than transient — at that point a human/operator genuinely needs to look (e.g. drain the runner queue, reduce concurrency).

**This is distinct from the chronic per-test flake registry** ([Fix-loop step 1.5](#fix-loop) and the flake-registry recording below). That registry tracks a *specific test* flaking across many PRs over time; this section handles a *whole-run infrastructure* failure within a single dispatch. They can co-occur but are separate mechanisms — don't record an infra-flake whole-run re-run in the per-test registry (it has no test id to key on).

## Fix-loop

In this mode — and only this mode — you do block on CI, because resolving a known-failing PR is the agent's entire job. (Only once the [DIRTY-PR short-circuit](#dirty-pr-short-circuit-check-before-treating-an-empty-rollup-as-not-started-yet--1015) above has confirmed the PR is NOT DIRTY — a DIRTY PR has no merge ref and will never queue a check to watch.)

```bash
gh pr checks <M> --repo <owner/repo> --watch --interval 30
```

On failure:

1. Identify the failing check:
   ```bash
   gh pr checks <M> --repo <owner/repo> --json name,state,link
   ```
   **Record the failing check name(s)** — you need them for the [named-failing-check re-verification gate](#named-failing-check-re-verification-gate-load-bearing) before you can return `green`. The gate re-probes these exact names on the post-push SHA; fixing a *different* check and declaring victory is the misdiagnosis failure mode #416 documents.
1.5. **Pre-rerun flake-suspects check (the `stop-auto-rerunning` consumer side — issue #385).** Before you re-run / re-watch a failing check, ask whether it's a *known chronic flake* that a prior session escalated. Phase 2 of the flake registry writes crossed flakes to a per-repo `.shipyard/flake-suspects.txt`; the contract is that `fix-checks-only` **refuses to keep auto-rerunning** a listed flake until a human signs off (deletes the line). This is the enforcement that turns the registry from a passive ledger into the "fix the root cause instead of re-running forever" rule. **Gate the check on `flake_registry.enabled == true`** (same gate as the recording side below) — when disabled, skip this step entirely (pre-#378 behavior).

   **`--repo-root` MUST resolve to the PRIMARY checkout, never `$(git rev-parse --show-toplevel)` ([#1065](https://github.com/mattsears18/shipyard/issues/1065)).** `.shipyard/flake-suspects.txt` is gitignored, and the orchestrator's setup-time `enforce` pass ([#1059](https://github.com/mattsears18/shipyard/issues/1059)) writes it to the **primary checkout** via its own `SHIPYARD_REPO_ROOT` pin. But *this* worker runs in its **own**, separately-provisioned `agent-*` worktree — a fresh checkout of the PR's head commit that, like every worktree, contains no gitignored files of its own. `$(git rev-parse --show-toplevel)` resolves to *this worktree*, not the primary checkout, so a naive read is **silently vacuous**: `flake-enforce.sh is-suspect` treats a missing file as "not a suspect" (see `cmd_is_suspect`'s `[[ -f "$path" ]] || return 1`), so this check can never see a suspects entry the orchestrator wrote — it would report "not a suspect" for every key, every time, regardless of what's actually on the list. **Do NOT propagate `SHIPYARD_REPO_ROOT` here** — that pin is deliberately scoped to the orchestrator's own session per #1059's phase-1 fix and must never reach a dispatched worker (a worker's config/behavior should stay coherent with its own checkout). Instead, resolve the primary checkout locally via `git worktree list --porcelain`, which — unlike `git rev-parse --show-toplevel` — is **not** scoped to the current working tree: it reads the shared, common `.git` administrative data every worktree of this repo points at, so it always returns the full worktree list, including the primary checkout, no matter which worktree you run it from. Git guarantees the **first** `worktree` entry is always the main/primary checkout:

   ```bash
   git worktree list --porcelain
   ```

   **Read the primary checkout off that output yourself — don't script it.** A `git worktree list --porcelain | awk …` pipe spans a shell command boundary and is refused by the worktree-isolation guard ([`dont.md` § "Post-relocation Bash blocks must be plain, single-purpose commands"](../../commands/do-work/dont.md#post-relocation-bash-blocks-must-be-plain-single-purpose-commands-1277)), and a shell variable holding the result wouldn't survive to the next `Bash` call anyway — nor could you reference it bare, since a whole-word `"$PRIMARY_CHECKOUT"` expansion is itself refused under the [same file's corrected rule](../../commands/do-work/dont.md#the-corrected-rule-1474-never-let-an-unresolvable-expansion-be-the-whole-word). The **first** line of the output is `worktree <path>`, and git guarantees that path is the main/primary checkout; take it as a literal and substitute it verbatim into the `--repo-root` argument below.

   If `git worktree list --porcelain` produced no output at all (not a worktree checkout — shouldn't happen under `/do-work`, but keeps this step from hard-erroring in that case), fall back to `git rev-parse --show-toplevel`'s output as the literal instead. That fallback does NOT mask the bug above: when worktrees genuinely exist, the first `worktree` entry always wins. Reading `.shipyard/flake-suspects.txt` at that absolute path is a narrow, read-only reference into the primary checkout's local state file — the same "invocation fallback" posture already established for `$CLAUDE_PLUGIN_ROOT/scripts/*.sh` — never a `cd` there and never a write.

   Build the suspect key from the failing check's `(workflow, job, test)` — the same pipe-joined shape `stop-auto-rerunning` wrote (`<workflow>|<job>|<test>`, test component empty when you can't pin it) — and probe the list:
   ```bash
   export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
   ENABLED=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get flake_registry.enabled 2>/dev/null || echo false)
   if [[ "$ENABLED" == "true" ]]; then
     KEY="<workflowName>|<failing job name>|<test-id-or-empty>"
     # <primary-checkout-path> is the literal you just read off `git worktree
     # list --porcelain` — substituted verbatim, never a bare "$VAR" expansion.
     if "$CLAUDE_PLUGIN_ROOT/scripts/flake-enforce.sh" is-suspect --key "$KEY" --repo-root <primary-checkout-path>; then
       # Known chronic flake — do NOT auto-rerun. The escalation (tracking issue,
       # blocked:ci label) was already applied by the orchestrator's setup-time
       # enforce pass; your job is to stop, not to burn fix attempts on it.
       echo "blocked #<M> at fix-checks: chronic flake <KEY> is on .shipyard/flake-suspects.txt — auto-rerun suppressed pending human signoff (see the test-stability tracking issue)"
       exit 0
     fi
   fi
   ```
   When the key matches, return the `blocked #<M> at fix-checks: chronic flake ...` string above verbatim and stop — do NOT fall through to re-running, and do NOT count this against the 3-attempt cap (you never attempted a fix; you deliberately declined to rerun a known flake). The orchestrator's reconcile labels the PR `blocked:ci` on a `blocked #<M> at fix-checks:` return, which is exactly the desired end state for a chronic-flake-blocked PR (the setup-time `apply-blocked-ci` action may already have applied it; the label is idempotent). When the key is NOT on the list, proceed normally to step 2.
2. Pull the failing job's own logs — **resolve the job id and use the per-job REST endpoint as the primary path; `gh run view --log-failed` is a fallback, not the default** ([#984](https://github.com/mattsears18/shipyard/issues/984)). `gh run view --log-failed` returns **empty output whenever ANY sibling job in the same run is still `in_progress`** — even when the job you actually need already finished and failed. That emptiness reads as "logs not ready yet," and the natural response is to wait — which is exactly backwards: your own failing job's logs are retrievable the moment *that job* reaches a terminal conclusion, regardless of what the rest of the run is doing.

   ```bash
   RUN_ID=<failing-run-id>   # from the failing check's `link` (step 1's `gh pr checks --json name,state,link`)
   # `[…][0]` inside the --jq filter, never a `| head -1` shell pipe — see
   # Step A above for why.
   JOBID=$(gh api "repos/<owner/repo>/actions/runs/$RUN_ID/jobs" \
     --jq '[.jobs[] | select(.conclusion=="failure") | .id][0] // empty')
   gh api "repos/<owner/repo>/actions/jobs/$JOBID/logs"
   ```

   **Stream the output rather than redirecting it to a file** — a big log fetch redirected to `> failed.log` produces zero stream output for its whole duration and can trip the harness's ~600s stall watchdog (worker-preamble § "Heartbeat emission around long-running commands", fragment [`ci-pitfalls.md`](../../skills/worker-preamble/ci-pitfalls.md); issue [#372](https://github.com/mattsears18/shipyard/issues/372)). The plain call above already streams; that is the form to use.

   **Don't reach for `… 2>&1 | tee <file>` to get both.** A pipe spanning a shell command boundary is itself refused by the worktree-isolation guard ([`dont.md` § "Post-relocation Bash blocks must be plain, single-purpose commands"](../../commands/do-work/dont.md#post-relocation-bash-blocks-must-be-plain-single-purpose-commands-1277)), so it trades a watchdog trip for a denied tool call — the same correction `ci-pitfalls.md` carries for its own copy of this advice. You rarely need the file at all: the streamed output is already in the tool result you're reading. When you genuinely do want it on disk (to grep a very large log), write it there with the `Write` tool from that result, into `$WORKTREE_PATH/.shipyard-scratch/` per `shipyard:worker-preamble` § "Scratch directory" — never `/tmp`, which the scratch-directory rule already rules out.

   The same heartbeat discipline applies to `npm ci` and to a buffered local test re-run in step 3 — keep stream output flowing so a 5–15 min command doesn't read as a stall.

   **If `$JOBID` itself has no `conclusion` yet — the job you actually need, not a sibling, genuinely hasn't finished** — wait for *that job*, not the whole run, then re-fetch:
   ```bash
   gh api "repos/<owner/repo>/actions/jobs/$JOBID" --jq '.status, .conclusion'
   ```
   Do NOT bail "logs unavailable" — that specific job finishes in minutes; a premature bail here is the exact #654 failure mode. But do NOT wait on sibling jobs that have nothing to do with your failing check — that wait is exactly what #984 closes.

   `gh run view --log-failed` still has a legitimate use once the **entire** run has finished: it fetches every failed job's log in one call, convenient when several jobs failed and you'd rather not resolve each job id by hand. It is never the right first move while any job in the run is still running.
2.5. **Infra-flake classification (before any code fix).** With the failed-job logs in hand, run the [Infra-flake classification](#infra-flake-classification-and-re-run-load-bearing) gate. If the failure matches the cancellation / dev-server-timeout / setup-job-failure / runner-lost signature AND your local gates pass AND the logs show no deterministic code error, `gh run rerun --failed` (respecting the attempt-count bound) and return `flake #<M>: re-ran failed jobs (<signature>)` — do NOT proceed to a code fix, and do NOT count this as a fix attempt. Only fall through to step 3 when the logs show a **deterministic code error** (a real defect your diff introduced).
3. Reproduce locally if practical.
4. Fix the smallest thing that resolves the failure. Don't expand scope.
4.5. **Run the repo's unit-test suite locally before pushing the fix ([#658](https://github.com/mattsears18/shipyard/issues/658)).** Same pre-push gate as issue-work [§4.6](./issue-work.md#46-pre-push-local-unit-test-gate-658): detect the unit-test command (`package.json` `scripts["test:unit"]` / `scripts.test`, a jest/vitest config, `pytest`, a `Makefile` `test` target) and run it — scoped to the changed files when the runner supports it, else the full unit suite — and confirm it passes *before* `git push`. Pushing a fix whose unit suite is still red locally just re-reds the same required gate in CI and burns another fix attempt against the 3-cap. This is especially load-bearing for the **i18n-parity signature** (see the [named-failing-check re-verification gate](#named-failing-check-re-verification-gate-load-bearing)): when the failing check is a `locales/*.json` ↔ `lib/strings.ts` parity test, running that parity suite locally is how you *confirm* your key-mirroring fix actually flips it green — never infer it from a "No tests found" worktree-ignore pass, which resolves a different check entirely. Skip only when the repo has no unit suite at all.
5. `git commit`, then push to the PR's remote branch. You're in detached HEAD (per Setup above), so a bare `git push` has no upstream to infer — push explicitly to the branch ref:
   ```bash
   git push origin "HEAD:refs/heads/$HEAD_REF"
   ```
   Never `--no-verify` (see worker-preamble). Never force-push unless rewriting history is genuinely required.
5.5. **Push-verification checkpoint (mandatory, before re-watching or returning ANY disposition) — confirm the push actually reached the remote, as its own plain command ([#1383](https://github.com/mattsears18/shipyard/issues/1383)).** This is deliberately a different, cheaper kind of check than the named-failing-check gate's `head_matches_pushed` comparison below: that gate is a JSON computation over `gh` output, and a computation can be described in a return without ever having actually been run. This one is a plain `git log` diff whose only two readings are "empty" (the push landed) or "not empty" (it didn't) — there's no computed field to paraphrase past. Re-fetch and diff against the ref you just pushed to:
    ```bash
    git fetch origin "$HEAD_REF" -q
    git log --oneline "origin/$HEAD_REF..HEAD"
    ```
    **This MUST print nothing.** Any line of output means your `git push` did not reach the remote — the commit you just made is still local-only, no matter what SHA `git rev-parse HEAD` reports. Do NOT proceed to step 6, do NOT re-probe the rollup, and do NOT write `green` / `noop: already green` / `pending` while this prints anything. Diagnose why the push silently no-opped (wrong branch name in the refspec, a rejected non-fast-forward push whose error scrolled past, a stray `--dry-run`) and retry the push before continuing. The originating repro (session `do-work-20260814T040027Z-97458`, PR #1366 attempt 2 — [#1383](https://github.com/mattsears18/shipyard/issues/1383)) committed locally, never actually pushed, and returned `green` citing the local-only commit's SHA anyway; this checkpoint exists so that specific mistake is mechanically visible to the worker itself before the return is written, not only detectable afterward by the orchestrator's SHA-match spot-check.
6. Re-watch checks — `gh pr checks <M> --repo <owner/repo> --watch --interval 30` again, applying the same force-backgrounded re-block pattern noted above if the harness's 600s cap kicks in. If this re-watch reports "no checks reported" instead of settling, don't assume an infra delay — re-check `mergeStateStatus` per the [DIRTY-PR short-circuit](#dirty-pr-short-circuit-check-before-treating-an-empty-rollup-as-not-started-yet--1015); a sibling merge can have gone DIRTY on you between your push and this watch. Once this settles (or you've watched through at least one settle-cycle and it's genuinely still in flight with zero failures), return per the [Return contract](#return-contract--read-carefully): `green` if fully passing with the evidence clause, `pending #<M>: ...` if still running with nothing failing, `dirty #<M>: ...` if the PR went DIRTY, or loop back into the fix-loop if a check is red.

**Hard cap: 3 fix attempts.** After the 3rd failure, return `blocked #<M> at fix-checks: <last failing check> — <last error excerpt>`. The orchestrator will label the PR `blocked:ci` and move on.

**Record root-cause context before returning `green`.** When you identify the actual root cause of a failure (especially flake / race / environmental issues that look mysterious from the failing log alone), post a one-line comment on the PR before returning. Format: `Fix-checks: <one-line root cause>` (e.g., "Fix-checks: flaky because of a race in the test setup — serialized the fixture init"). This stops the next session's auditor or human reviewer from re-flagging the same failure mode without context. Routine "applied the obvious fix to the obvious error" cases don't need a comment — the diff is the explanation. Use `gh pr comment <M> --repo <owner/repo> --body "..."`; if it errors, log an advisory and continue — don't block the return on a comment failure. This is the fix-checks-only analog of issue-work mode's step 5.5 decision-context rule.

**Record a flake event in the cross-PR flake registry when you conclude a failure was a flake (issue #378, phase 1).** Each `fix-checks-only` worker handles flakes in isolation — none of them sees that the SAME test has flaked on N other PRs this week. The flake registry is the session-spanning record that surfaces the chronic pattern so it can be escalated rather than silently re-run forever. **Gate this on config: only record when `flake_registry.enabled == true`** in the effective config (it defaults to `false`, preserving pre-#378 behavior). When enabled, the orchestrator's dispatch prompt will say so; if you're unsure whether it's enabled, you can probe it yourself:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
# Only record if the registry is enabled for this repo.
ENABLED=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get flake_registry.enabled 2>/dev/null || echo false)
```

**When to record.** Record exactly one event per (workflow, job, test) failure that you concluded was a *flake* — a transient/environmental/race failure that was NOT a real defect in the PR's diff. Concretely: you re-ran the check (or pushed a no-op-equivalent flake-mitigation) and it went green without a substantive code fix that addressed a real bug, OR the failure log shows a known-flaky shape (timeout on a runner, `boundingBox()` returning null intermittently, network blip, runner cancellation). Do NOT record a real failure you fixed with a genuine code change — that's not a flake, it's a bug your PR introduced and corrected. The registry is for chronic *non-actionable-per-PR* flakes; polluting it with real-bug fixes defeats the escalation signal.

**How to record.** One call per flake event, before you return `green`. The `--test` field is optional — if you can pin the failure to a specific test ID (from the failing log), pass it; otherwise the event keys on workflow+job alone:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
"$CLAUDE_PLUGIN_ROOT/scripts/flake-registry.sh" record \
  --repo <owner/repo> --pr <M> \
  --workflow "<workflowName>" --job "<failing job name>" \
  [--test "<test-id>"] --action rerun-failed
# If the record call errors (registry write failure, helper missing), log an
# advisory and continue — never block the `green` return on a registry write.
```

The registry lives at `~/.shipyard/flake-registry.jsonl` (one line per event). The orchestrator reads it at setup time via `flake-registry.sh crossed` and enforces the three escalation actions through `flake-enforce.sh enforce` (issue #385, phase 2): `file-tracking-issue` opens a deduped chronic-flake tracking issue, `stop-auto-rerunning` writes the crossed key to `.shipyard/flake-suspects.txt`, and `apply-blocked-ci` labels affected PRs. **Your recording job here is unchanged** — honestly record one event per flake conclusion when enabled. The *consumption* of those events now has two sides you participate in: (1) you record events (this section), and (2) you honor the `stop-auto-rerunning` output via the pre-rerun suspects check in [fix-loop step 1.5](#fix-loop) — refusing to keep auto-rerunning a flake a prior session escalated. The `file-tracking-issue` and `apply-blocked-ci` actions are performed by the orchestrator's setup-time enforce pass, not from this mode.

## Don't

- Don't open a new PR. The PR is already open; this mode repairs CI only.
- **Don't bail `blocked … logs unavailable while run in progress`.** That's a wait-signal for *your own failing job*, never for the whole run — resolve the job id and fetch its logs via the per-job endpoint per [Fix-loop step 2](#fix-loop) / [Infra-flake classification Step A](#infra-flake-classification-and-re-run-load-bearing); only wait when that specific job (not a sibling) genuinely lacks a `conclusion`. A premature "logs unavailable" bail while your own job already failed is the exact [#654](https://github.com/mattsears18/shipyard/issues/654) failure mode (~139k tokens burned, no fix pushed, a healthy PR mislabeled) — and waiting the same way because a *sibling* job is still running, when your own failing job's logs were already fetchable, is the [#984](https://github.com/mattsears18/shipyard/issues/984) variant (~310k tokens burned across two dispatches, no diagnosis produced either time).
- **Don't read an empty `gh run view --log-failed` as "logs not ready yet."** Empty output while a sibling job is `in_progress` means the wrong command was used, not that you need to wait longer — resolve the job id from `/actions/runs/<run-id>/jobs` and fetch that job's logs from `/actions/jobs/<job-id>/logs` instead ([#984](https://github.com/mattsears18/shipyard/issues/984)).
- **Don't return `blocked … CI workflows not triggering / workflow initialization delay / infrastructure issue`.** That framing is almost always a DIRTY PR (see [DIRTY-PR short-circuit](#dirty-pr-short-circuit-check-before-treating-an-empty-rollup-as-not-started-yet--1015)), not GitHub Actions infrastructure — a DIRTY PR has no merge ref, so `gh pr checks <M>` reporting "no checks reported" is permanent, not transient. Check `mergeStateStatus` before ever writing "infrastructure issue" or "workflow initialization delay" in a blocked reason. This was the exact misdiagnosis in [#1015](https://github.com/mattsears18/shipyard/issues/1015) (PR #1013, ~135k tokens spent polling a PR that could never queue a check) — the correct return there was `dirty #1013: PR conflicts with main; no merge ref, so no checks will run`, not `blocked`.
- **Don't treat a cancelled job / dev-server boot timeout / setup-job failure as an undiagnosable code failure.** Those are the infra-flake signature — when local gates pass, `gh run rerun --failed` and return `flake #<M>: re-ran failed jobs (<signature>)` per [Infra-flake classification](#infra-flake-classification-and-re-run-load-bearing), do NOT attempt a code fix. But do NOT re-run *forever*: the attempt-count bound converts a chronic infra flake into a `blocked:ci` hand-off for a human/operator.
- Don't modify the PR title or description.
- Don't close the linked issue from this PR. The original PR body already has the `Closes #N` line; merging the rebased branch closes the issue automatically.
- Don't add new tests or refactors. Fix only what's needed to turn the failing checks green.
- Don't keep trying past 3 fix attempts. The cap is a circuit breaker, not a suggestion.
- **Don't return `green #<M>` on the basis of a hypothesis.** "I rebased onto a commit that should fix this" is a hypothesis until CI confirms it. The contract is unambiguous: `green` means the rollup is fully `SUCCESS` (or `SKIPPED` / `NEUTRAL`) at the moment of return. If checks are still queued / running, you have not finished the fix-loop — keep watching, or return `blocked` if the 3-attempt cap is up. The orchestrator's step A reconcile spot-checks every `green` return against `gh pr view <M> --json statusCheckRollup` and will silently downgrade you to `pending` / `failing` if the rollup contradicts the claim. Returning `green` on a `PENDING` rollup wastes a turn and earns you a `[fix-checks-verify] downgraded` advisory in the orchestrator's log.
- **Don't return `green #<M>` without re-verifying the NAMED failing check flipped to SUCCESS** ([#416](https://github.com/mattsears18/shipyard/issues/416)). `--watch` exiting zero is necessary but not sufficient — it can exit on a stale pre-push rollup, and it says nothing about *which* check you fixed. If you concluded the failure was cause X, fixed X, and the real failing check Y is still red, you've misdiagnosed; returning `green` ships a false-green that nearly auto-merges a red PR. Re-probe the specific check(s) that were failing at dispatch on the post-push SHA per the [named-failing-check re-verification gate](#named-failing-check-re-verification-gate-load-bearing) — confirm each named check's latest run is SUCCESS AND the rollup head SHA matches your push — before you may claim `green`. The canonical trap: "fixing" the jest worktree-ignore "No tests found" artifact while the real failure is an i18n-parity test (`locales/en.json` missing keys) — two different checks; fixing the former never turns the latter green.
- **Don't return `green` / `noop: already green` without the `@<head-SHA>` citation, and don't cite a stale or abbreviated SHA** ([#1211](https://github.com/mattsears18/shipyard/issues/1211)). The citation must be the full 40-character `headRefOid` from the SAME `gh pr view` call that produced your evidence-clause counts — never a SHA carried over from an earlier turn, never shortened. The orchestrator's reconcile rejects a cited SHA that doesn't match the PR's live head exactly as it would a fabricated rollup count: it discards your claim and re-derives the disposition from ground truth.
- **Don't return `green` / `noop: already green` from your assigned check passing alone, from "the others are pre-existing/unrelated," or from a local test pass — the claim is about the PR's FULL required rollup, not your slice of it** ([#754](https://github.com/mattsears18/shipyard/issues/754)). A required check that was red before you were even dispatched, and that you never touched, still blocks the merge — it doesn't get a pass for having "not regressed." Ditto for a local test suite you ran N times and got green: that's evidence for diagnosis, never a substitute for reading the PR's `statusCheckRollup` on GitHub immediately before you return. The repro: PR #2489 got `green` from a worker that fixed only `Lint & Typecheck` while required `Unit Tests` stayed FAILURE, and `noop: already green` from a worker that ran the unit suite locally three times while the PR's CI `Unit Tests` check was still FAILURE. If any check in the current rollup besides your named target is red, return `blocked #<M> at fix-checks: <that check> — <reason>` instead.
- **Don't return `green` / `noop: already green` from "no failures in the rollup" alone** ([#985](https://github.com/mattsears18/shipyard/issues/985) / [#987](https://github.com/mattsears18/shipyard/issues/987)). "No failures" and "all checks are green" are different predicates — a rollup with a still-`pending` required check satisfies the first and fails the second. The evidence clause in the return contract above exists precisely so this substitution can't be made silently: it requires the *pending* count stated as a number (`0 pending`), not a prose "no failures" or "nothing's red." If pending is nonzero, the correct return is `pending #<M>: <n> check(s) still running (<names>)`, never `green`.
- **Don't return narrative status updates.** Strings like "waiting for monitor," "shard 2 still running," "routine progress, awaiting E2E," "unit tests pass, awaiting shards" are NOT acceptable terminal returns. The agent harness treats every assistant message ending your turn as a completion notification, so each narrative update forces the orchestrator to spend a turn acknowledging a stale re-notification. The only acceptable terminal returns are the documented strings: `green #<M> @<head-SHA> (rollup verified ...)`, `noop: already green #<M> @<head-SHA> (rollup verified ...)`, `pending #<M>: <n> check(s) still running (<names>)`, `dirty #<M>: PR conflicts with <default-branch>; no merge ref, so no checks will run`, `flake #<M>: re-ran failed jobs (<signature>)`, `blocked #<M> at fix-checks: <reason>`. If CI is still running and you'd otherwise return a narrative, either keep the `gh pr checks <M> --watch --interval 30` foreground bash call alive (that blocks your own turn until the rollup resolves) or, once you've watched through at least one settle-cycle and confirmed nothing is failing, return the honest `pending` disposition instead.
- **Don't substitute a `Monitor`/backgrounded poll loop for the in-fix-loop foreground `--watch` ([#753](https://github.com/mattsears18/shipyard/issues/753)).** This mode's `gh pr checks <M> --watch --interval 30` is the one sanctioned, *foreground*, self-heartbeating CI-watch — it blocks your own turn and can't outlive your return. Spinning up a `Monitor` sub-task or a backgrounded `gh run watch` to do the same job and then returning a narrative like *"the background waiter will notify me… Waiting"* is the exact anti-pattern this issue documents: it duplicates the foreground watch at extra cost and can strand the dispatch slot if you return before it resolves. See `shipyard:worker-preamble` § "Return-contract discipline".
- **Don't return without `TaskStop`'ing any `Monitor` sub-tasks you spawned.** This mode is the canonical spawner of Monitors (watching shard rollups, polling for run completion) and the canonical victim of [#297](https://github.com/mattsears18/shipyard/issues/297)'s notification leak — workers returned `green`/`blocked`/`reaped:` and left their Monitors running, each one re-invoking the orchestrator for a no-op turn for the next 15–60 min. The worker-preamble's "Stop background processes before returning" section is the source of truth — it applies on EVERY termination path (clean returns, bails, reaps). If you only used the foreground `gh pr checks <M> --watch --interval 30` pattern (no `Monitor`, no `run_in_background: true` Bash), there's nothing to stop; the foreground command exits with your push and can't outlive the return.
- **Don't skip the push-verification checkpoint before returning a disposition** ([#1383](https://github.com/mattsears18/shipyard/issues/1383)). `git log --oneline "origin/$HEAD_REF..HEAD"` after a fresh `git fetch origin "$HEAD_REF"` must print nothing before you proceed past step 5 — any output means your commit never left the machine, and citing its local SHA in a `green` return is exactly the #1383 repro (PR #1366 attempt 2).
- **Don't push a fix without running the repo's unit suite locally first** ([#658](https://github.com/mattsears18/shipyard/issues/658)). Typecheck + lint passing locally is not sufficient — a change can pass both yet still fail the required **Unit Tests** gate on a repo-specific invariant (the canonical case: an i18n-parity test on `locales/*.json` ↔ `lib/strings.ts`). Run the unit suite (scoped to changed files when possible) per fix-loop step 4.5 and confirm it's green before `git push`, so you don't re-red the same gate and burn another fix attempt.
- Don't `--no-verify` to skip hooks. Fix the underlying issue. (See worker-preamble for the absolute prohibition.)
- **Never create a credential.** See `shipyard:worker-preamble` § "Never create a credential" — a missing credential is a hand-back, not something to route around ([#1166](https://github.com/mattsears18/shipyard/issues/1166)).
- **Never irreversibly mutate live external state.** See `shipyard:worker-preamble` § "Never irreversibly mutate live external state — hand it back" — a delete or access-widening change against a live surface is a hand-back, and "the documented rule's precondition doesn't apply" is not itself grounds to proceed ([#1519](https://github.com/mattsears18/shipyard/issues/1519)).
- Don't disable a failing test to make checks pass. If the test is genuinely broken (not the code), comment on the PR with the evidence and return `blocked #<M> at fix-checks: <reason>`.
- Don't edit `.github/workflows/` or branch protection to make a check pass.
- **Leave your worktree checked out at the PR's head commit when you return** (not `main` / the default branch). Detached HEAD is the expected state in this mode — you never need to be on a named branch. See worker-preamble's worktree discipline rule 3.
