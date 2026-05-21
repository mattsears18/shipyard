---
description: Survey open PRs, the issue backlog, and recent comments to produce a prioritized list of items currently blocked on the user (not on Claude). Read-only — pairs with /shipyard:do-work as the human-driven counterpart.
argument-hint: [--repo owner/repo] [--limit N]
---

# /my-turn

Print a single ranked list answering *"what do you need from me right now?"* — the PRs that need the user's review, the issues blocked on a human decision, the failing checks that exhausted the orchestrator's fix-loop, the unresolved review comments tagging the user. **Read-only / advisory-only for v1.** No mutations, no dispatch — execution stays in `/shipyard:do-work` and other dedicated commands. The user reads the output, picks an item, and acts on it manually.

Pairs with [`/shipyard:do-work`](./do-work.md) — that one is the agent-driven loop (Claude works the backlog autonomously); this one is the human-driven counterpart (the user reads what the loop *couldn't* resolve and decides what to do).

## Args

`$ARGUMENTS` may include:

- **--repo owner/repo** (optional, default: cwd's repo via `gh repo view --json nameWithOwner -q .nameWithOwner`). If not in a repo, ask via `AskUserQuestion`.
- **--limit N** (optional, default `25`): cap the printed list at N items. Useful when the backlog is enormous and the user only wants the top of the stack. Items beyond the cap are summarized as `… and <K> more (rerun with --limit <K+N> to see all)`.

## Setup

### 1. Resolve repo

```bash
gh repo view --json nameWithOwner -q .nameWithOwner   # if --repo omitted
```

### 2. Resolve the authenticated user

The "me" in "what do you need from me right now?" is whoever the local `gh` is authenticated as — the survey ranks items by *that user's* relationship to each PR/issue (requested reviewer, assignee, mentioned in comment, etc.). Resolve once at setup:

```bash
gh api user --jq .login   # → $ME
```

If `gh` is not authenticated, abort with a clear error directing the user to `gh auth login`.

## Survey passes

Run each of the following passes in parallel (one batch of `gh` calls in a single message). Each pass produces a list of candidate items; the final ranking step merges them.

### Pass A — Open PRs

```bash
gh pr list --repo <owner/repo> --state open --limit 200 \
  --json number,title,url,isDraft,author,createdAt,updatedAt,labels,reviewDecision,reviewRequests,mergeStateStatus,statusCheckRollup,headRefName
```

From this projection, derive per-PR signals:

- **PR awaiting `$ME`'s review** — `reviewRequests` contains `$ME` (direct) OR `$ME` is on a team in `reviewRequests` (skip the team-lookup for v1; direct match only). `reviewDecision` is `REVIEW_REQUIRED`. Highest-leverage human action — `$ME` is literally what's blocking merge.
- **PR with `ci-blocked` label** — the orchestrator's 3-attempt fix-loop ran out; needs manual investigation.
- **PR with `mergeStateStatus: DIRTY`** that has been DIRTY for `>24h` — rebase didn't auto-fire, or auto-merge isn't armed.
- **Draft PR last updated >7 days ago** — stale; either finish or close.
- **PR with `CHANGES_REQUESTED` `reviewDecision` authored by `$ME`** — the user submitted a PR that someone (human or bot) asked for changes on; the ball is back on their court.

### Pass B — Open issues

```bash
gh issue list --repo <owner/repo> --state open --limit 200 \
  --json number,title,url,author,assignees,createdAt,updatedAt,labels,comments
```

From this projection, derive per-issue signals:

- **Issue with `needs-human-review` label** — `/shipyard:do-work` is skipping it until a human signs off (canonical case: refined user-feedback issues awaiting maintainer approval). The reviewer **is the user** (or, more precisely: a maintainer; the survey assumes `$ME` is one).
- **Issue with `needs-refinement` label** and no `<!-- do-work-refinement-agent -->` sentinel in any comment — `/shipyard:refine-issues` hasn't run yet OR ran and got blocked; the user may need to nudge it. (Note: `needs-refinement` is the generic pipeline gate as of shipyard 1.3.28; the refiner branches by source signal — user-feedback classify+rewrite, open-questions resolve-defaults, or escalate-to-triage fall-through. See [#145](https://github.com/mattsears18/claude-plugins/issues/145).)
- **Issue with `blocked` label** where every body-referenced blocker (`Blocked by #<M>`) is `CLOSED` / `MERGED` — likely clearable; user should remove the label.
- **Issue authored by `$ME` with no linked PR and no `blocked` / `needs-design` label** — the user filed something and nothing's happened; `/shipyard:do-work` should be picking it up, but if it's not (wrong priority label, missing labels), the user should triage.
- **Issue where the last comment was authored by someone other than `$ME` AND the comment text contains `?` or `@<$ME>`** — someone asked a question or pinged the user; awaiting response. Implementation: walk `comments` newest-first, find the last non-`$ME` comment, check for `?` substring or `@<login>` mention of `$ME`.

### Pass C — Unanswered review comments on `$ME`'s PRs

Open PRs authored by `$ME` may have review comments awaiting reply. `gh pr list` doesn't return review-comment threads; use a per-PR follow-up only for PRs that aren't already surfaced in Pass A's higher-priority buckets, capped at the 20 most-recently-updated. For each:

```bash
gh api repos/<owner/repo>/pulls/<M>/comments --jq '.[] | {id, user: .user.login, body, created_at, in_reply_to_id}'
```

Surface the PR if there's an unresolved review comment thread where the last comment is from a non-`$ME` author. (v1 heuristic — GitHub's API doesn't expose the `resolved` flag on classic review comments; "last commenter not `$ME`" is a reasonable proxy.)

### Pass D — Recent failed CI runs on the default branch

```bash
DEFAULT_BRANCH=$(gh repo view <owner/repo> --json defaultBranchRef -q .defaultBranchRef.name)
gh run list --repo <owner/repo> --branch "$DEFAULT_BRANCH" --status completed --limit 5 \
  --json conclusion,databaseId,url,createdAt,headSha,workflowName
```

If the most recent completed run on default branch is `failure` / `cancelled` / `timed_out` AND no `/shipyard:do-work` `fix-main-ci` divert has landed a PR for it yet (check open PRs for `fix-main-ci-<short-sha>` branch name), surface as a P0 item. The orchestrator should have caught this on its next refresh, but a long-idle repo may have a red main that's sitting unaddressed.

## Ranking

Merge the candidates from passes A–D into a single ranked list. Each item carries a priority tier and a stable secondary sort key (age, oldest first within a tier).

### Priority tiers

- **P0 — blocking other work**
  - PRs awaiting `$ME`'s review (any age) — `$ME` is literally what's stopping merge
  - Issues with `needs-human-review` label — `/shipyard:do-work` is skipping them
  - Red main / failing CI on default branch with no `fix-main-ci` PR open

- **P1 — decisions**
  - PRs with `ci-blocked` (3-attempt orchestrator fix-loop exhausted, needs human eyes)
  - Issues with `needs-refinement` and no refinement-agent sentinel yet
  - Issues authored by `$ME` with no linked PR (the user filed it, nothing happened)
  - Open review comment threads on `$ME`'s PRs awaiting reply
  - Issues where the last comment was a question or `@$ME` mention from someone else

- **P2 — housekeeping**
  - PRs with `mergeStateStatus: DIRTY` >24h (rebase didn't auto-fire)
  - Draft PRs stale >7 days (finish or close)
  - Issues with `blocked` label where every referenced blocker is closed (likely clearable)
  - `CHANGES_REQUESTED` on `$ME`'s open PRs (the user owes the reviewer a response)

### Secondary sort

Within each tier, sort by `createdAt` ascending (oldest first). Surface a single age string per item — `<N>d` for ≥1 day, `<N>h` for ≥1 hour, else `<N>m`.

### Dedup

An item may match multiple signals (e.g. a PR is both `ci-blocked` AND DIRTY); collapse to a single rendered row, keep the highest-priority signal, list the secondary signals in the "why" column.

## Output

Print the ranked list to the terminal. **No file artifact for v1** — the data is ephemeral and the user wants to read it once, act, and move on. Format:

```
HUMAN ACTIONS NEEDED — <owner/repo> — <N> items (P0: <a>, P1: <b>, P2: <c>)

P0 — blocking other work
  1. PR #142 — "feat(shipyard): new my-turn command"
     awaiting your review · 3d old · <https://github.com/owner/repo/pull/142>
     Next: review and approve or request changes

  2. Issue #155 — "[user feedback] login crash on iOS 17"
     needs-human-review since 3d ago · /shipyard:do-work is skipping
     <https://github.com/owner/repo/issues/155>
     Next: read the refined body, set a P0/P1/P2 priority label, remove `needs-human-review`

P1 — decisions
  3. PR #148 — "fix(api): rate-limit retries"
     ci-blocked (3 fix attempts exhausted) · 1d old
     <https://github.com/owner/repo/pull/148>
     Next: investigate the failing check manually (`gh pr checks 148 --watch`), fix or escalate

  4. Issue #161 — "Why does X return null when Y is set?"
     @<$ME> pinged in last comment 2d ago by @<other-login>
     <https://github.com/owner/repo/issues/161>
     Next: reply to the question or close if no longer relevant

P2 — housekeeping
  5. Draft PR #134 — "wip: refactor session-state"
     stale 11d · no recent commits
     <https://github.com/owner/repo/pull/134>
     Next: finish and mark ready-for-review, or close
```

Per item, render:

- **Index** (1-based, monotonic across all tiers — easy to refer to as "item 3" verbally)
- **Artifact** — `PR #<num>` or `Issue #<num>` plus the title (truncate at 60 chars with `…`)
- **Why-on-user** — one line, the signal that fired (`awaiting your review`, `ci-blocked`, etc.). If multiple signals fired, the highest-priority one is the primary; secondaries appear in parens (e.g. `awaiting your review (also: DIRTY)`).
- **Age** — when the item entered its "blocked on human" state — uses `createdAt` for new items, `updatedAt` for label-change items. v1 heuristic: use the older of the two — slightly under-counts age but never over-counts.
- **URL** — clickable `<https://...>` so terminals render it as a hyperlink.
- **Next action** — one-line concrete next step the user can take. Examples: `review and approve or request changes`, `set a priority label and remove needs-human-review`, `investigate the failing check manually`, `reply to the question or close`.

### Empty state

If passes A–D return zero items: print a single line and exit cleanly.

```
HUMAN ACTIONS NEEDED — <owner/repo>

Nothing on your plate — backlog is clean, no PRs awaiting your review,
no orchestrator dead-ends needing a human. Time to start something new
(`/shipyard:audit` if you want fresh issues filed) or take a break.
```

### Limit overflow

If the ranked list has more items than `--limit`, print the first `--limit` items then:

```
  … and <K> more (rerun with --limit <K+N> to see all)
```

## Performance budget

The full survey should complete in well under 10 seconds for a backlog of ~100 PRs and ~200 issues:

- Pass A + Pass B: two parallel `gh` calls, each ~1–2s
- Pass C: capped at 20 per-PR follow-ups, run in parallel, ~3s total
- Pass D: one `gh run list` call, ~1s

If a backlog blows the budget, `--limit` already provides a knob; otherwise file an issue for a future v2 that uses GraphQL to collapse Passes A+B+C into one round-trip.

## Don't

- **Don't mutate any state.** No `gh pr edit`, no `gh issue close`, no comments posted, no labels changed. The command is advisory; mutation lives in `/shipyard:do-work` and other dedicated commands. A future v2 may offer one-keystroke handoff into `/do-work` for items the orchestrator could auto-resolve, but that's out of scope for v1.
- **Don't dispatch any agents.** The user wants a quick survey, not a 20-minute autonomous session. If the user wants Claude to *work* the items, they'll run `/shipyard:do-work` separately.
- **Don't scan other repos.** Current repo only. Cross-repo digest is a future v2; for v1 the user can re-run with `--repo` in different cwds.
- **Don't write a report file.** v1 is terminal-only. If the user wants persistence, they can pipe via shell redirection from outside the slash-command UI; that's their concern, not the command's. Add `--output <path>` later if useful.
- **Don't surface PRs / issues authored by bots** (Dependabot, Renovate, etc.) unless they specifically request review from `$ME` — those auto-update PRs are noise in a "human action needed" list and have their own automation handling them.
- **Don't include items where the next action is obviously Claude's, not the user's.** A PR with failing checks but NOT carrying `ci-blocked` is still inside `/shipyard:do-work`'s fix-loop — surfacing it would tell the user to step on the orchestrator's work. The `ci-blocked` label is the explicit "Claude gave up, human must" signal; absence of it means leave it alone.
- **Don't deep-dive on team membership for review requests.** v1 matches `$ME` directly against `reviewRequests`; team-via-membership lookups would add an extra `gh api` round-trip per PR and are out of scope. Users on teams will still see direct review requests in v1; team-level requests roll up via the GitHub UI's notification stream, which the user has anyway.
- **Don't repeat work `/shipyard:do-work`'s upfront summary already does.** `/do-work`'s step 2 prints a buckets table with workable / skipped / blocked counts. That's a *backlog snapshot*; `/my-turn` is a *human-actions list*. They share inputs but have different shapes — don't try to merge them.
