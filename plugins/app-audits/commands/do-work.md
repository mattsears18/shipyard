---
description: Continuously work through open GitHub issues — pick the best ones, implement in parallel worktrees, open PRs, enable auto-merge, then loop. Runs until zero matching issues remain.
argument-hint: [--repo owner/repo] [--label LABEL ...] [--concurrency N]
---

# /do-work

Burns down the issue backlog. Each iteration: pick a non-overlapping batch → dispatch K agents in parallel worktrees → wait for all → loop. Ends when no candidates remain. The loop runs in the main session; per-issue work is delegated.

## Args

`$ARGUMENTS` may include:

- **--repo owner/repo** (optional): target repo. Default: `gh repo view --json nameWithOwner -q .nameWithOwner`. If not in a repo, ask via `AskUserQuestion`.
- **--label LABEL** (optional, repeatable): only work on issues with all listed labels. Without it: any open candidate issue.
- **--concurrency N** (optional, default `3`): max issues to work in parallel per iteration. Set to `1` for sequential.

## Loop

### 1. Resolve repo + user

```bash
gh repo view --json nameWithOwner -q .nameWithOwner   # if --repo omitted
gh api user -q .login                                  # the gh-authenticated user
```

Cache both for the session.

### 2. PR triage — fix failing checks before new work

Before picking any new issues, sweep your own open PRs in the target repo and unblock anything that's red. New failures may have appeared since the last iteration (flaky tests, dependency updates, base-branch drift), so re-run this every loop.

```bash
gh pr list --repo <owner/repo> --state open --author @me \
  --search '-label:ci-blocked -is:draft' \
  --json number,title,headRefName,statusCheckRollup,mergeStateStatus \
  --limit 100
```

Filter to PRs where `statusCheckRollup` contains any entry with `conclusion: FAILURE` (or `state: FAILURE` / `ERROR` / `TIMED_OUT`). Ignore `PENDING` / `IN_PROGRESS` — those are still running and auto-merge will catch them.

If the failing list is empty → skip to step 3.

Otherwise dispatch one `app-audits:issue-worker` agent **per failing PR**, in parallel, with `isolation: "worktree"`. If the failing PRs exceed `--concurrency`, process in batches of `--concurrency`; within a batch, dispatch in parallel and block until all return before starting the next batch.

Prompt template:

> Fix failing CI checks on PR #<M> in `<owner/repo>` (branch `<headRefName>`) in **fix-checks-only mode**. The PR is already open — do NOT open a new one, do NOT change scope, do NOT modify the PR title/description, do NOT close the linked issue from this PR. Check out the branch (`gh pr checkout <M> --repo <owner/repo>`), then run only the fix-checks loop: pull failed logs (`gh run view <run-id> --repo <owner/repo> --log-failed`), reproduce locally if practical, fix the smallest thing, commit + push to the same branch, re-watch with `gh pr checks <M> --repo <owner/repo> --watch --interval 30`. Hard cap: 3 fix attempts. If checks are already green by the time you start, return `noop: already green`. If you can't fix in 3 attempts, return `blocked: <last failing check> — <last error excerpt>`.

Reconcile returns:

- **green** / **noop** → PR is fine, continue.
- **blocked** → comment on the PR summarizing the blocker, add the `ci-blocked` label to the PR so it's skipped on subsequent iterations, continue.
- **errored** (agent itself failed) → record and continue.

After reconciliation, proceed to step 3 — even if some PRs ended up `ci-blocked`. The orchestrator's job is to keep moving; a human can intervene on persistently red PRs.

### 3. Fetch + filter the backlog

```bash
gh issue list --repo <owner/repo> --state open --limit 100 \
  --json number,title,labels,assignees,body,createdAt,updatedAt \
  --search 'is:issue is:open -linked:pr -label:blocked -label:wontfix -label:needs-design -label:discussion'
```

Add `label:<L>` qualifiers for each `--label` arg.

Client-side filter:

- Drop issues assigned to a user **other than** the gh-authenticated user (they own it).
- Drop issues whose body contains `Blocked by #N` where #N is still open.
- Drop the issue if `gh pr list --search "in:body Closes #<N>"` returns an open PR (belt-and-suspenders against the `-linked:pr` qualifier).

### 4. Rank the candidates

Sort the surviving candidates by:

1. **Priority label**: `P0` > `P1` > `P2` > unlabeled.
2. **Type**: `bug` > `fix(...)` titles > `feat(...)` titles > `chore(...)` > everything else.
3. **Staleness**: oldest `updatedAt` first within the same tier — stale work counts.

If empty → loop ends; report "backlog empty" and stop.

### 5. Scoping pre-flight (parallel, read-only)

Take the top `2 × concurrency` ranked candidates. For each, dispatch a short read-only scoping agent in parallel. Each agent reads the issue + does a quick `grep` / `Explore` pass and returns:

```
{ issue: N, files: ["path/a", "path/b", ...], touches_lockfile: bool }
```

Treat `touches_lockfile: true` for issues that obviously edit `package.json`, `pnpm-lock.yaml`, `Gemfile.lock`, `go.sum`, `Cargo.lock`, migrations, or root build config. Use the issue body/title — don't over-investigate. Budget ~30s per scoping agent.

### 6. Greedy-pack the batch

Walk the ranked list (best first), maintaining a batch and a `claimed_paths` set:

- Add the candidate if **no predicted file overlaps** anything in `claimed_paths` (compare both exact paths and parent-dir prefixes — `src/auth/login.ts` collides with `src/auth/`).
- If `touches_lockfile`, only add when the batch is empty; then close the batch.
- Stop when batch size hits `--concurrency` or the ranked list is exhausted.

Unbatched candidates roll over to the next iteration.

### 7. Self-assign the batch

For every issue in the batch:

```bash
gh issue edit <N> --repo <owner/repo> --add-assignee @me
```

Do this *before* dispatch so a concurrent `/do-work` or a re-fetch can't double-grab.

### 8. Dispatch in parallel

Send one message with N `Agent` calls — `subagent_type: "app-audits:issue-worker"`, `isolation: "worktree"`, one issue per agent. Block until all return.

Prompt template:

> Work issue #<N> in `<owner/repo>` to completion. You are already self-assigned. Open a PR that closes the issue, get checks green, enable auto-merge, return. Use TDD when adding new behavior. If you hit a blocker you can't resolve in 3 fix attempts on the same PR, return with `blocked: <reason>` — don't burn the session on one issue.

### 9. Reconcile returns and loop

For each returned agent:

- **shipped** (PR open, auto-merge enabled, checks green or queued) → record and continue.
- **blocked** → comment on the issue summarizing the blocker, add the `blocked` label, continue.
- **errored** (agent itself failed) → record in the session log, continue.

After the batch is fully reconciled, loop to step 2 (re-triage PRs, then re-fetch the backlog). Loop ends only when step 4 returns zero candidates.

## End-of-session summary

When the loop ends, report:

```
/do-work session:
Issues processed: N
Shipped: M (#A → PR #X, #B → PR #Y, ...)
Blocked: K (#P — <reason>, #Q — <reason>)
Errored: J (#R — <agent error>)
Remaining open (non-candidate): L (linked PRs, blocked, assigned elsewhere)
```

## Don't

- Don't work on issues assigned to other users — soft-lock via `gh api user` check.
- Don't merge manually. Use `--auto`. Auto-merge waits for green.
- Don't disable required checks or weaken branch protection to make a PR pass.
- Don't loop on the same issue. Once the agent returns `blocked`, label it and skip.
- Don't fabricate acceptance criteria. The agent should infer reasonable ones from title + context; if even that's unclear, it returns `blocked`.
- Don't batch two lockfile-touchers (or two issues hitting overlapping paths) into the same iteration — that's what step 6 is for.
- Don't dispatch without `isolation: "worktree"` when concurrency > 1. Shared working tree + parallel agents = corrupted state.
- Don't skip the scoping pre-flight to "save time" — one rebase from a missed collision costs more than the whole pre-flight.
- Don't skip PR triage to "save time" — a red PR you opened last iteration won't auto-merge no matter how many new issues you ship. Clearing the red is the highest-leverage work in the loop.
- Don't retry a `ci-blocked` PR — that label exists so the orchestrator stops banging on the same wall. A human needs to look.
