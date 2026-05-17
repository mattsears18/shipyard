---
description: Continuously work through open GitHub issues — pick the best ones, implement in parallel worktrees, open PRs, enable auto-merge, then loop. Runs until zero matching issues remain.
argument-hint: [--repo owner/repo] [--label LABEL ...] [--prioritize-label LABEL] [--concurrency N]
---

# /do-work

Burns down the issue backlog with a **rolling worker pool**. Keeps `--concurrency` agents in flight at all times. The instant any agent returns, the orchestrator reconciles its result and dispatches a replacement into the freed slot — no batched waits. Ends when the backlog and the in-flight set are both empty.

## Args

`$ARGUMENTS` may include:

- **--repo owner/repo** (optional): target repo. Default: `gh repo view --json nameWithOwner -q .nameWithOwner`. If not in a repo, ask via `AskUserQuestion`.
- **--label LABEL** (optional, repeatable): only work on issues with all listed labels. Without it: any open candidate issue.
- **--prioritize-label LABEL** (optional): if provided, issues carrying this label sort ahead of everything else in the backlog — they still pass through normal eligibility (assignee, blocked, linked-PR filters), but get a priority boost above the `P0/P1/P2` tiers. Issues without the label fall back to the normal ranking. Differs from `--label`, which **filters** the backlog rather than reordering it.
- **--concurrency N** (optional, default `2`): the size of the rolling worker pool — i.e. the number of agents the orchestrator keeps in flight at any moment. Set to `1` for sequential.

## Orchestrator state

Across the session, the orchestrator maintains four mental data structures. Hold them in your head (or in `TodoWrite` if you prefer durable scratch); they are the entire state machine.

- **`in_flight`**: { slot_id → { kind: "issue" | "fix-checks", target: <#N or #M>, claimed_paths: [...], agent_id } }. Size is bounded by `--concurrency`.
- **`ready_issues`**: priority queue of *scoped* issue candidates — `{ number, claimed_paths, touches_lockfile, rank_key }` — ready to dispatch the moment a slot opens. Refilled from the backlog as it drains.
- **`failed_prs`**: queue of red PRs needing fix-checks-only work. Highest priority — drained before `ready_issues`.
- **`raw_backlog`**: ranked list of issue numbers not yet scoped. Source for refilling `ready_issues`.

When a slot opens, the dispatch order is always: `failed_prs` first, then `ready_issues` (subject to path-collision and lockfile rules).

## Setup (run once)

### 1. Resolve repo + user

```bash
gh repo view --json nameWithOwner -q .nameWithOwner   # if --repo omitted
gh api user -q .login                                  # the gh-authenticated user
gh repo view <owner/repo> --json defaultBranchRef -q .defaultBranchRef.name   # default branch (cached as <default-branch>)
```

Cache all three for the session.

### 2. Ensure label exists + recover from prior session

**2a. Ensure required labels exist** (idempotent — each command succeeds whether the label is already there or not). The `do-work` label is the session stamp; `P0`/`P1`/`P2`/`P3` are the priority tiers used both by the auto-triage in step 3 and the ranking step that follows it:

```bash
gh label create do-work --repo <owner/repo> --description "Worked on by /do-work" --color 5319E7 2>/dev/null || true
gh label create P0 --repo <owner/repo> --description "Critical / release-blocker" --color B60205 2>/dev/null || true
gh label create P1 --repo <owner/repo> --description "High — this cycle"          --color D93F0B 2>/dev/null || true
gh label create P2 --repo <owner/repo> --description "Normal"                     --color FBCA04 2>/dev/null || true
gh label create P3 --repo <owner/repo> --description "Low / nice-to-have"         --color 0E8A16 2>/dev/null || true
```

**2b. Orphan worktree triage** — scan for `do-work/*` worktrees left behind by a prior killed session:

```bash
git worktree list --porcelain | awk '/^branch refs\/heads\/do-work\//{print $2}' | sed 's|refs/heads/||'
```

For each `do-work/issue-<N>` branch found, resolve its worktree path with `git worktree list | grep "\[do-work/issue-<N>\]" | awk '{print $1}'` (`<path>` below), then inspect its state and act according to the table. Track `salvaged_count` (worktrees that produced or kept an open PR) and `abandoned_count` (worktrees removed) — both default to 0 and feed into the end-of-session summary.

All git/gh commands below run with `-C <path>` (or `(cd <path> && ...)` for `gh pr create`) so they operate on the orphan worktree, not the orchestrator's main checkout.

| Worktree state | How to detect | Action |
|---|---|---|
| No commits beyond base | `git -C <path> rev-list --count origin/<default-branch>..HEAD` returns `0` | `git worktree remove --force <path>` → `git branch -D do-work/issue-<N>` → `gh issue edit <N> --repo <owner/repo> --remove-assignee @me`. `abandoned_count++`. Issue flows back into the backlog on the normal fetch (step 3). |
| Only uncommitted edits, no commits | Same `rev-list` returns `0` but `git -C <path> status --porcelain` is non-empty | Same as above — partial WIP from an agent mid-edit is not coherent enough to push. `abandoned_count++`. |
| Commits ahead, not pushed | `git -C <path> rev-list --count origin/<default-branch>..HEAD` > 0 AND `git ls-remote --heads origin do-work/issue-<N>` is empty | `git -C <path> push -u origin do-work/issue-<N>` → `gh pr list --repo <owner/repo> --head do-work/issue-<N> --json number --jq '.[0].number'`; if empty, `(cd <path> && gh pr create --repo <owner/repo> --fill --label do-work)` then enable auto-merge. `salvaged_count++`. |
| Commits ahead, pushed, no PR open | Same `rev-list` > 0 AND `ls-remote` shows the branch AND `gh pr list --head` is empty | `(cd <path> && gh pr create --repo <owner/repo> --fill --label do-work)` then enable auto-merge. `salvaged_count++`. |
| Commits ahead, pushed, PR open | `gh pr list --head` returns a PR number | `gh pr view <M> --repo <owner/repo> --json statusCheckRollup`. If any check is `FAILURE` / `ERROR` / `TIMED_OUT` → push `{number: <M>, ...}` onto `failed_prs`. Otherwise leave alone — auto-merge will handle it. `salvaged_count++`. |
| Branch is `[gone]` upstream | `git branch -v` shows `[gone]` next to the branch name | `(no-op — handled by end-of-session cleanup)` |

**Inconsistency log (advisory)** — also run a one-line label cross-check:

```bash
gh issue list --repo <owner/repo> --label do-work --assignee @me --state open --search '-linked:pr' --json number
```

Any results here that DON'T correspond to a `do-work/*` worktree on disk are "dispatched but agent died before its first commit" cases. Log them in the session summary as an advisory — don't auto-act.

### 3. Fetch + rank the backlog

```bash
gh issue list --repo <owner/repo> --state open --limit 100 \
  --json number,title,labels,assignees,body,createdAt,updatedAt \
  --search 'is:issue is:open -linked:pr -label:blocked -label:wontfix -label:needs-design -label:needs-triage -label:discussion'
```

Add `label:<L>` qualifiers for each `--label` arg.

**Auto-triage priority labels.** Before ranking, ensure every fetched issue carries exactly one of `P0`/`P1`/`P2`/`P3`. For each issue whose `labels` array contains **none** of those four, judge severity from the title, body, and existing labels (`bug`, `security`, `a11y`, `perf`, `chore`, …) using the [audit-rubrics severity buckets](../skills/audit-rubrics/SKILL.md):

- `P0` — broken or unusable: runtime errors on the golden path, exposed secrets, RCE vectors, contrast failures on primary actions
- `P1` — significant friction or risk: confusing affordances, missing security headers, a11y failures on common flows, CVEs without patches
- `P2` — polish or moderate risk: spacing nits, copy improvements, low-severity CVEs with patches available
- `P3` — taste / suggestion: subjective microcopy, "would be nice" refinements

When torn between two tiers, pick the lower-severity one — over-labeling `P0` poisons the priority signal for the rest of the session. Apply exactly one label per issue:

```bash
gh issue edit <N> --repo <owner/repo> --add-label <Px>
```

Skip any issue that already carries one or more `P0`/`P1`/`P2`/`P3` labels — preserve the human judgment that set them, even if you'd have picked a different tier. Don't remove existing priority labels, and don't add a second one. If multiple priority labels somehow coexist on the same issue, leave them alone (a human can clean up); ranking will use the highest one.

Client-side filter:

- Drop issues assigned to a user **other than** the gh-authenticated user (they own it).
- Drop issues whose body contains `Blocked by #N` where #N is still open.
- Drop the issue if `gh pr list --search "in:body Closes #<N>"` returns an open PR (belt-and-suspenders against the `-linked:pr` qualifier).

Sort the survivors:

1. **Prioritized label** (only if `--prioritize-label` was passed): issues carrying that label come first. Issues without it fall to the next tier.
2. **Priority label**: `P0` > `P1` > `P2` > `P3` > unlabeled. Convention: `P0` = critical/release-blocker, `P1` = high (this cycle), `P2` = normal, `P3` = low / nice-to-have. After the step-3 auto-triage pass, the `unlabeled` tier should normally be empty — it remains as a safety net for issues triage somehow skipped. If an issue carries multiple priority labels, rank by the highest one present.
3. **Type**: `bug` > `fix(...)` titles > `feat(...)` titles > `chore(...)` > everything else.
4. **Staleness**: oldest `updatedAt` first within the same tier — stale work counts.

This ordered list is the initial `raw_backlog`. If empty AND no failing PRs exist (next step) → loop ends immediately; report "backlog empty" and stop.

### 4. Snapshot failing PRs

```bash
gh pr list --repo <owner/repo> --state open --author @me \
  --search '-label:ci-blocked -is:draft' \
  --json number,title,headRefName,statusCheckRollup,mergeStateStatus \
  --limit 100
```

Filter to PRs where `statusCheckRollup` contains any entry with `conclusion: FAILURE` / `state: FAILURE` / `ERROR` / `TIMED_OUT`. Ignore `PENDING` / `IN_PROGRESS` — those are still running and auto-merge will catch them.

Each entry → push onto `failed_prs`, **deduped against entries already in `failed_prs`** (step 2b may already have enqueued some). These are the highest-priority work items because a red PR you opened last session won't auto-merge no matter how many new issues you ship.

### 5. Initial scope pre-flight

Take the top `2 × concurrency` from `raw_backlog`. Dispatch read-only scoping agents in parallel (one message, multiple `Agent` tool calls — these are short-lived and *not* backgrounded, so block until all return). Each returns:

```
{ issue: N, files: ["path/a", "path/b", ...], touches_lockfile: bool }
```

`touches_lockfile: true` for issues that obviously edit `package.json`, `pnpm-lock.yaml`, `Gemfile.lock`, `go.sum`, `Cargo.lock`, migrations, or root build config. Use the issue body/title — don't over-investigate. Budget ~30s per scoping agent.

Push the results onto `ready_issues` (preserving rank). Remove those issue numbers from `raw_backlog`.

### 6. Initial pool fill

Dispatch up to `--concurrency` workers in parallel — one message with N background `Agent` calls (`run_in_background: true`, `subagent_type: "app-audits:issue-worker"`, `isolation: "worktree"`). For each slot, pick the next job using the **dispatch rules** below.

Once the pool is full, **return control** — you'll be notified the moment any agent completes. Do not poll. Do not sleep.

## Steady state (event-driven)

When an agent completes, the harness notifies you. Each notification is one orchestrator turn. In that turn:

### A. Reconcile the return

The agent's last line tells you what happened.

For **issue work** (`shipped` / `blocked` / `errored`):

- **shipped #<N> via PR #<M>** — checks may be `green`, `pending`, or `failing`. Record. Don't act on `pending`/`failing` here — periodic triage (step D) will catch failures next time it runs.
- **blocked #<N>** — comment on the issue summarizing the blocker, add the `blocked` label, continue.
- **errored** — record in the session log, continue.

For **fix-checks work** (`green` / `noop` / `blocked`):

- **green #<M>** / **noop: already green #<M>** — PR is fine, continue.
- **blocked #<M> at fix-checks** — comment on the PR summarizing the blocker, add the `ci-blocked` label so it's skipped from now on, continue.
- **errored** — record and continue.

### B. Release the slot

Remove the completed entry from `in_flight`. Its `claimed_paths` are now free.

### C. Dispatch a replacement (if work remains)

**Drain guard:** if `draining = true`, skip — the slot stays empty until in-flight empties and the loop terminates.

Otherwise, apply the **dispatch rules** to pick the next job. If a job is dispatched, the slot is filled again immediately. If no compatible job exists (e.g., backlog dry, or every remaining candidate collides with what's still in flight), leave the slot empty — the next completion will trigger another attempt.

### D. Periodic refresh

**Drain guard:** skip during drain — refresh is pointless when no new work will be dispatched.

Otherwise, every `--concurrency` completions (a full pool's worth), refresh queues in the background:

1. **Failed-PR scan** — re-run the step-4 query. Append any newly-red PRs to `failed_prs` (deduped against entries already in `in_flight` or `failed_prs`).
2. **Backlog refill** — if `ready_issues` size < `--concurrency`, take the next `2 × concurrency` from `raw_backlog` and dispatch scoping agents in parallel. Append results to `ready_issues`. If `raw_backlog` itself runs low (< `2 × concurrency`), re-run the step-3 backlog fetch to discover newly-opened issues.

The refresh runs in the same turn as the completion handler — it's a quick burst of read-only `gh` calls plus optional parallel scope dispatches. It does **not** delay the replacement dispatch in step C.

## Dispatch rules (used by step 6 and step C)

When filling a slot, walk this decision tree:

1. **`failed_prs` non-empty?** → pop the front entry. Path-collision rules don't apply (you're working an existing PR's branch, not a new path claim). Dispatch a fix-checks-only worker.

   Prompt template:

   > Fix failing CI checks on PR #<M> in `<owner/repo>` (branch `<headRefName>`) in **fix-checks-only mode**. The PR is already open — do NOT open a new one, do NOT change scope, do NOT modify the PR title/description, do NOT close the linked issue from this PR. Check out the branch (`gh pr checkout <M> --repo <owner/repo>`), then run the fix-loop: pull failed logs (`gh run view <run-id> --repo <owner/repo> --log-failed`), reproduce locally if practical, fix the smallest thing, commit + push to the same branch, re-watch with `gh pr checks <M> --repo <owner/repo> --watch --interval 30`. Hard cap: 3 fix attempts. If checks are already green by the time you start, return `noop: already green`. If you can't fix in 3 attempts, return `blocked: <last failing check> — <last error excerpt>`.

2. **`ready_issues` non-empty?** → scan from the head for the first entry whose `claimed_paths` **don't collide** with any entry in `in_flight` (exact paths + parent-dir prefixes; `src/auth/login.ts` collides with `src/auth/`).

   - If the candidate `touches_lockfile`: dispatch only when `in_flight` is empty. While it runs, dispatch nothing else — other slots stay parked until it returns.
   - Otherwise: self-assign the issue first (`gh issue edit <N> --add-assignee @me --add-label do-work`) **before** dispatching, to soft-lock against parallel `/do-work` instances and stamp the `do-work` label.

   Prompt template:

   > Work issue #<N> in `<owner/repo>` to completion. You are already self-assigned. Create your branch as `do-work/issue-<N>` — do not use any other name. Open a PR that closes the issue and pass `--label do-work` to `gh pr create`. Enable auto-merge, snapshot the current check state, and return — **do not `--watch` CI**. The orchestrator handles failed-check recovery on a periodic refresh. Use TDD when adding new behavior. If you hit a blocker before push (ambiguous scope, can't reproduce, etc.), return with `blocked: <reason>` — don't burn the session on one issue.

3. **All `ready_issues` collide with `in_flight`?** → leave the slot empty for now. When the next completion frees up paths, retry. If nothing in `ready_issues` is ever compatible (rare — usually a same-path cluster), wait for the colliding worker to return.

4. **`ready_issues` empty but `raw_backlog` non-empty?** → trigger a scope-refill burst (step D's backlog refill) in this same turn, then retry from step 2 with the refilled queue.

5. **Nothing to dispatch (all queues empty and no candidate available)?** → leave the slot empty. Termination check kicks in once `in_flight` also empties.

Dispatch is via **background agents**: `run_in_background: true`, `isolation: "worktree"`. The harness will notify you on completion — that drives the next iteration of the steady-state loop.

## Soft drain

The orchestrator wakes on two kinds of events: agent-completion notifications and new user messages. On user-message turns only, evaluate the new message body — if its entire **trimmed** body matches one of these trigger phrases (case-insensitive, full body only — never as a substring), drain mode is engaged:

- `stop`
- `drain`
- `/do-work stop`

Substring matching is deliberately avoided. Phrases like "don't stop yet" or "I'll drain it later" do not trigger.

**On first trigger:**

1. Acknowledge in chat: *"Draining: \<N\> in flight, no new dispatches. Will exit when they finish or settle."*
2. Set `draining = true` in TodoWrite.
3. Steady-state Step A (reconcile) and Step B (release slot) continue normally — in-flight agents must still be properly recorded as they complete.
4. Steady-state Step C (dispatch) and Step D (periodic refresh) become no-ops while `draining = true` (the guards in those steps handle this).
5. When `in_flight` empties → run the end-of-session drain (CI pending poll, max 15 min) → end-of-session cleanup → end-of-session summary → exit.

**Second trigger** — typing a stop phrase again while already draining — still waits for `in_flight` to empty (in-flight agents are never hard-cancelled), but skips the CI pending-poll phase and exits immediately after cleanup. Useful when CI is slow and the user wants out.

**Why this is safe:** agents commit at logical milestones (TDD test → commit, implementation → commit) and PRs are opened with `--auto`. Letting an in-flight agent finish naturally never loses work. Killing it mid-edit could.

## Termination

The loop ends when **all of** the following are true at the same time:

- `in_flight` is empty (no agents running),
- `failed_prs` is empty,
- `ready_issues` is empty,
- `raw_backlog` is empty AND a fresh step-3 fetch returns zero new candidates.

**Drain-mode termination**: when `draining = true` (see [Soft drain](#soft-drain)), the exit condition collapses to `in_flight` empty — `failed_prs` / `ready_issues` / `raw_backlog` are left as-is and rebuilt next session. The drain → cleanup → summary flow below still runs.

Run end-of-session drain → cleanup → summary.

## End-of-session drain

Once the termination conditions above are met, some PRs you opened this session may still be `pending` CI. Don't terminate with red PRs hiding in flight.

Drain protocol:

1. Query open PRs you authored this session whose checks are still in progress:
   ```bash
   gh pr list --repo <owner/repo> --state open --author @me \
     --search '-label:ci-blocked -is:draft' \
     --json number,statusCheckRollup --limit 100
   ```
2. If any rollup has only `PENDING` / `IN_PROGRESS` / `QUEUED` entries → poll every 60s for up to 15 min, re-running the step-4 failing-PR snapshot each pass. If newly-red PRs appear, dispatch fix-checks-only workers against them (subject to `--concurrency`) and continue draining until they too settle.
3. After 15 min, stop draining and report whatever's still pending in the summary — the user can re-run `/do-work` later, which will sweep those PRs on its next setup pass.

## End-of-session cleanup

Each dispatched agent created a worktree and a local branch. After auto-merge fires with `--delete-branch`, the remote branch is gone but the local branch + worktree linger as dead weight in the main checkout. Reap them before the summary.

Run from the main checkout (not from inside any worktree). The `[gone]` upstream marker is what makes this safe — only branches whose remote was deleted post-merge match. Open / blocked / in-flight PRs still have live remotes, so they're untouched.

1. Prune stale remote refs so merged-and-deleted branches surface as `[gone]`:
   ```bash
   git fetch --prune
   ```

2. Snapshot what's about to be reaped (for the summary):
   ```bash
   git branch -v | grep '\[gone\]' || echo "(nothing to clean)"
   ```

3. For each `[gone]` branch, remove its worktree (if any) then delete the branch:
   ```bash
   git branch -v | grep '\[gone\]' | sed 's/^[+* ]//' | awk '{print $1}' | while read branch; do
     worktree=$(git worktree list | grep "\\[$branch\\]" | awk '{print $1}')
     if [ -n "$worktree" ] && [ "$worktree" != "$(git rev-parse --show-toplevel)" ]; then
       git worktree remove --force "$worktree"
     fi
     git branch -D "$branch"
   done
   ```

4. Final consistency pass — drop any worktrees whose checkout directory was deleted out from under git:
   ```bash
   git worktree prune
   ```

Record the count of worktrees and branches removed; pipe it into the summary.

## End-of-session summary

When the loop ends (drain completes or times out, and cleanup has run), report:

```
/do-work session:
Recovered from prior session: <salvaged_count> salvaged (PRs created/kept), <abandoned_count> abandoned
Advisory: <A> labeled+assigned issues with no worktree and no PR (#<N>, ...)  # omit line if A == 0
Issues processed: N
Shipped: M (#A → PR #X [merged|green|pending], #B → PR #Y [merged|green|pending], ...)
In flight at exit: F (#C → PR #Z still pending CI after drain)
Blocked: K (#P — <reason>, #Q — <reason>)
Errored: J (#R — <agent error>)
Cleaned up: <W> worktrees, <B> branches (merged + remote-deleted)
Remaining open (non-candidate): L (linked PRs, blocked, assigned elsewhere)
Lifetime via /do-work: <I> issues closed, <P> PRs opened (repo-wide totals)
```

The lifetime line is sourced from two queries run just before printing the summary:

```bash
gh issue list --repo <owner/repo> --label do-work --state closed --limit 1000 --json number --jq 'length'
gh pr list --repo <owner/repo> --label do-work --state all --limit 1000 --json number --jq 'length'
```

If either query fails (e.g., the label doesn't exist yet because this is a fresh repo), default to `0`.

## Don't

- Don't work on issues assigned to other users — soft-lock via `gh api user` check.
- Don't merge manually. Use `--auto`. Auto-merge waits for green.
- Don't disable required checks or weaken branch protection to make a PR pass.
- Don't re-dispatch the same issue. Once the agent returns `blocked`, label it and never queue it again.
- Don't fabricate acceptance criteria. The agent should infer reasonable ones from title + context; if even that's unclear, it returns `blocked`.
- Don't dispatch two workers whose `claimed_paths` overlap — the dispatch rules exist exactly to prevent this. Two agents touching the same files in parallel worktrees will collide on the same lines and produce merge conflicts neither can resolve.
- Don't dispatch alongside a lockfile-toucher. While a lockfile worker runs, the rest of the pool parks. Resume normal dispatch only after it returns.
- Don't dispatch without `run_in_background: true` and `isolation: "worktree"`. Background dispatch is what gives you the rolling pool; without it, the orchestrator blocks on each agent and loses the whole point of `--concurrency`. Worktree isolation prevents parallel checkouts from corrupting each other.
- Don't poll for agent completion. The harness notifies you. Polling burns turns and cache.
- Don't wait for the whole pool to drain before dispatching replacements. The instant any single slot opens, fill it (subject to dispatch rules). "Batched parallel" is the old design — it left two slots idle while one slow worker ran.
- Don't skip the initial scope pre-flight to "save time" — one rebase from a missed collision costs more than the whole pre-flight.
- Don't skip the periodic failed-PR refresh. New failures appear from flaky tests, base drift, and dependency updates; if you don't sweep, they sit red forever.
- Don't retry a `ci-blocked` PR — that label exists so the orchestrator stops banging on the same wall. A human needs to look.
- Don't run end-of-session cleanup from inside a worktree — `git worktree remove` on your own checkout fails. Always run from the repo's primary working tree.
- Don't cleanup branches by name or pattern — only by `[gone]` upstream. Anything else risks reaping open or blocked PRs the orchestrator didn't author.
- Don't claim a worktree whose branch doesn't match `do-work/*` during orphan triage. That branch is not yours — it could be a developer's WIP.
- Don't run orphan triage while another `/do-work` session may be active on the same repo. Triage is idempotent but parallel salvage on the same orphan wastes work and may produce confusing PR comments. If you suspect a parallel session, ask the user before triaging.
- Don't remove the `do-work` label on block, abandon, or any other outcome. It is write-once. Adding `blocked` / `ci-blocked` alongside it is how block state is signaled — they coexist.
