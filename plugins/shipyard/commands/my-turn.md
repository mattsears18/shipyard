---
description: Survey open PRs, the issue backlog, and recent comments to surface the single next action currently blocked on the user (not on Claude). Read-only — pairs with /shipyard:do-work as the human-driven counterpart.
argument-hint: [--repo owner/repo] [--all] [--limit N]
---

# /my-turn

Answer *"what do you need from me right now?"* with **the single next action** — by default, the one highest-leverage thing currently blocked on the user, rendered as a focused `→ Next:` directive. Behind that #1 item sits the same ranked survey of everything blocked on a human: the PRs that need the user's review, the issues blocked on a human decision, the failing checks that exhausted the orchestrator's fix-loop, the unresolved review comments tagging the user. The full ranked list renders only on `--all` (or an explicit `--limit N > 1`). **Read-only / advisory-only for v1.** No mutations, no dispatch — execution stays in `/shipyard:do-work` and other dedicated commands. The user reads the output, picks an item, and acts on it manually.

Pairs with [`/shipyard:do-work`](./do-work.md) — that one is the agent-driven loop (Claude works the backlog autonomously); this one is the human-driven counterpart (the user reads what the loop *couldn't* resolve and decides what to do).

## Args

`$ARGUMENTS` may include:

- **--repo owner/repo** (optional, default: cwd's repo via `gh repo view --json nameWithOwner -q .nameWithOwner`). If not in a repo, ask via `AskUserQuestion`.
- **--all** (optional, default off): render the **full ranked list** instead of just the single next action. Without this flag (and without an explicit `--limit N > 1`), the command prints only the #1-ranked item as a focused `→ Next:` directive — see [Output](#output). Use `--all` when you want the whole backlog of human-blocked items, not just the next step.
- **--limit N** (optional, default `25` *when the list renders*): cap the printed list at N items. Only meaningful in list mode — i.e. when `--all` is passed, or when `--limit N` is given with `N > 1` (which itself opts into list mode). `--limit 1` is equivalent to the default single-action mode. Items beyond the cap are summarized as `… and <K> more (rerun with --limit <K+N> to see all)`.

**Mode resolution.** The command runs in one of two render modes:

- **Single-action mode (default)** — no `--all`, and no `--limit N` with `N > 1`. Print only the top-ranked item as a `→ Next:` directive. This is the default because the command's promise is *focus*: the one thing to do next, not a backlog to re-prioritize.
- **List mode** — `--all` is present, OR `--limit N` is given with `N > 1`. Print the full ranked list (capped at `--limit`, default `25`). `--all` with no `--limit` shows every item.

Both flags compose: `--all --limit 10` renders the list capped at 10. The mode is purely a rendering choice — every survey pass and the full ranking run identically regardless of mode; only the **render** differs (top item only vs. the capped list).

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
- **PR with `blocked:ci` label** — the orchestrator's 3-attempt fix-loop ran out; needs manual investigation.
- **PR with `mergeStateStatus: DIRTY`** that has been DIRTY for `>24h` — rebase didn't auto-fire, or auto-merge isn't armed.
- **Draft PR last updated >7 days ago** — stale; either finish or close.
- **PR with `CHANGES_REQUESTED` `reviewDecision` authored by `$ME`** — the user submitted a PR that someone (human or bot) asked for changes on; the ball is back on their court.

### Pass B — Open issues

```bash
gh issue list --repo <owner/repo> --state open --limit 200 \
  --json number,title,url,author,assignees,createdAt,updatedAt,labels,comments \
  --jq '[.[] | . + {comments: (.comments | map({author: .author.login, body: (.body[:280]), createdAt}) | .[-3:])}]'
```

The `comments` projection keeps only the last 3 comments on each issue, and each comment is trimmed to its first 280 chars + author login + createdAt. The Pass B signals only inspect the most-recent comment author (`@<$ME>` ping detection) and the first chunk of its body (substring match for `?` and the mention shape) — keeping the full comment history per issue (or full bodies) burns tool-result tokens for fields nothing reads. Worker-preamble §"`gh` JSON discipline" covers the convention.

From this projection, derive per-issue signals:

- **Issue with `needs-human-review` label** — `/shipyard:do-work` is skipping it until a human signs off. Two canonical cases now share this label: (1) refined user-feedback issues awaiting maintainer approval, and (2) **design-gated issues** (formerly `needs-design`, folded in per [#515](https://github.com/mattsears18/shipyard/issues/515)) — blocked on a human design decision before they're agent-workable. `/shipyard:do-work` deliberately **excludes** `needs-human-review` from dispatch (see the client-side filter in [`do-work/setup.md`](./do-work/setup.md) step 4, [`do-work/drain.md`](./do-work/drain.md), and [`do-work/steady-state.md`](./do-work/steady-state.md)), so without a `/my-turn` signal a human-gated issue is invisible to both loops and stacks up in the backlog with no path to a human — exactly what `/my-turn` exists to surface. The reviewer **is the user** (or, more precisely: a maintainer; the survey assumes `$ME` is one). For a design-gated issue the human action is to make the design call (or break the issue into a design spike + an implementation issue so the impl half becomes dispatch-eligible).
- **Issue with `needs-refinement` label** and no `<!-- do-work-refinement-agent -->` sentinel in any comment — `/shipyard:refine-issues` hasn't run yet OR ran and got blocked; the user may need to nudge it. (`needs-refinement` is the generic pipeline gate; the refiner branches by source signal — user-feedback classify+rewrite, open-questions resolve-defaults, or escalate-to-triage fall-through.)
- **Issue with `needs-decomposition` label** ([#498](https://github.com/mattsears18/shipyard/issues/498)) — a `/do-work` scope agent confirmed the epic is non-shippable as a single PR. If there's **no** `<!-- do-work-decompose-agent -->` sentinel in any comment, `/shipyard:decompose-epic` hasn't been run yet — the user can run it to auto-shard the epic into dispatch-ready sub-issues (for `Multi-PR sequence:` / `Missing dependency:` evidence classes). If a sentinel comment **is** present and reads `couldn't auto-decompose:`, the epic is a genuine human-decomposition handoff (non-mechanical evidence class, or too big to shard cleanly) — the user decomposes it by hand. Either way the epic is blocked on the user, not on Claude.
- **Issue with `blocked:agent-hard` label** (or legacy `blocked:agent` — same semantics, awaiting migration per [#300](https://github.com/mattsears18/shipyard/issues/300)) — split into two signals by whether the block is auto-clearable, per [#500](https://github.com/mattsears18/shipyard/issues/500):
  - **Non-clearable hard-block** — at least one body-referenced blocker (`Blocked by #<M>`) is still OPEN, **OR** the body carries no `Blocked by #<M>` references at all (the common case: a pure security / scope / prompt-injection *refuse* that `steady-state.md`'s bail-classification table stamped `blocked:agent-hard` because it "genuinely needs human review" / "definitely needs a human eye"). This is "Claude gave up; a human must actually look" — the orchestrator hard-blocked the issue out of dispatch across sessions and nothing moves it without a human. **P1 — decisions** (see [Ranking](#ranking)).
  - **Clearable hard-block** — the body has ≥1 `Blocked by #<M>` reference AND every referenced blocker is `CLOSED` / `MERGED` — likely clearable; user should just remove the label. **P2 — housekeeping** (unchanged).

  Implementation: extract every `Blocked by #<M>` reference from the issue body (same regex `steady-state.md`'s step 3d.2 sub-sweep uses). If there are **zero** references → non-clearable (a refuse, not a dependency wait). If there is ≥1 reference and **any** referenced issue is still OPEN → non-clearable. **Only** when ≥1 reference exists and *all* referenced issues are CLOSED/MERGED → clearable. The refuse reason the worker recorded in the issue comment (`steady-state.md`'s bail-classification table writes a `Worker returned blocked: <reason>. Classified as ...` comment) can be cited in the rendered action so the user knows *why* it was hard-blocked without opening the issue.
- **Issue authored by `$ME` with no linked PR and no `blocked:agent-hard` / legacy `blocked:agent` / `needs-human-review` label** — the user filed something and nothing's happened; `/shipyard:do-work` should be picking it up, but if it's not (wrong priority label, missing labels), the user should triage. (`blocked:agent-soft` issues ARE workable and auto-clear at next-session backlog fetch — they don't need user triage.)
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
  - Issues with `needs-human-review` label — `/shipyard:do-work` is skipping them (this now includes the former `needs-design` design-gates, folded into `needs-human-review` per [#515](https://github.com/mattsears18/shipyard/issues/515))
  - Red main / failing CI on default branch with no `fix-main-ci` PR open

- **P1 — decisions**
  - PRs with `blocked:ci` (3-attempt orchestrator fix-loop exhausted, needs human eyes)
  - **Non-clearable `blocked:agent-hard` issues** (or legacy `blocked:agent`) — a body-referenced blocker is still OPEN, or there are no `Blocked by #<M>` references at all (a pure security / scope / prompt-injection refuse). `/shipyard:do-work` hard-blocked it out of dispatch and only a human can move it; surface so the refuse actually gets eyes (per [#500](https://github.com/mattsears18/shipyard/issues/500)).
  - Issues with `needs-refinement` and no refinement-agent sentinel yet
  - Issues with `needs-decomposition` (a scope agent confirmed the epic is non-shippable as a single PR — run `/shipyard:decompose-epic` to auto-shard the mechanical cases, or decompose by hand if a `couldn't auto-decompose:` sentinel comment is already present)
  - Issues authored by `$ME` with no linked PR (the user filed it, nothing happened)
  - Open review comment threads on `$ME`'s PRs awaiting reply
  - Issues where the last comment was a question or `@$ME` mention from someone else

- **P2 — housekeeping**
  - PRs with `mergeStateStatus: DIRTY` >24h (rebase didn't auto-fire)
  - Draft PRs stale >7 days (finish or close)
  - **Clearable** `blocked:agent-hard` issues (or legacy `blocked:agent`) — the body has ≥1 `Blocked by #<M>` reference and every referenced blocker is closed (likely clearable: just remove the label). The non-clearable case is P1, not here (see [#500](https://github.com/mattsears18/shipyard/issues/500)).
  - `CHANGES_REQUESTED` on `$ME`'s open PRs (the user owes the reviewer a response)

### Secondary sort

Within each tier, sort by `createdAt` ascending (oldest first). Surface a single age string per item — `<N>d` for ≥1 day, `<N>h` for ≥1 hour, else `<N>m`.

### Dedup

An item may match multiple signals (e.g. a PR is both `blocked:ci` AND DIRTY); collapse to a single rendered row, keep the highest-priority signal, list the secondary signals in the "why" column.

### Release-please / version-bump PRs (discretionary)

A release-please / version-bump PR is a **manual gate, not a blocker.** The commits it releases are already on the default branch; the PR only bumps version + changelog, and nothing downstream cascades from it — it doesn't block other PRs, CI, or development, and release-please keeps rolling more commits into it while it sits open. Recognize one by the same heuristic `/shipyard:do-work` uses for its auto-merge exception: a `chore(release):` title prefix **or** a `release-please--*` head branch.

Such a PR is **discretionary housekeeping** — rank it at the **bottom of P2**, never P0/P1, regardless of which Pass-A signal it matched. A CLEAN release PR is "ready to ship whenever you want," not "blocked on you," so promoting it conflates *highest-ranked human-only item* with *blocking other work* — the exact false-urgency this de-prioritization prevents.

**Exception — promote only on a concrete downstream dependency.** If another open item explicitly waits on the release shipping — it carries `Blocked by #<release-PR>` in its body, or otherwise references the version going live — the release PR is genuinely gating tracked work and MAY rank up to the tier of the work it unblocks. Absent such an edge, it stays discretionary.

## Output

Print to the terminal. **No file artifact for v1** — the data is ephemeral and the user wants to read it once, act, and move on. The output format is intentionally terse: the user asked for "what do I need to do" — not "what's the state of the repo." Cut the framing, lead with the verb.

The render depends on the resolved mode (see [Args → Mode resolution](#args)):

### Single-action mode (default)

When neither `--all` nor `--limit N > 1` is given, print **only the #1-ranked item** as a focused directive. The command's promise is *focus* — "the ONE thing blocking the most, that I should do next" — and a 20-line ranked list reintroduces exactly the prioritization burden the command exists to remove. Format:

```
→ Next: re-paste the empty EXPO_ASC_* + ANDROID_SERVICE_ACCOUNT_JSON CI secrets (#1382)
  https://github.com/owner/repo/issues/1382
  (then the v2.37.0 release PR #1391 can go out)

5 more items — rerun with --all to see the full list
```

Rules for the single-action render:

- **`→ Next:` line.** The `→ Next: ` prefix, then the **imperative action** (verb-first, sentence-case, same shape as the list-mode action — see [Rendering rules](#rendering-rules)), then the artifact ref `(#<num>)` in parentheses at the end. This is the one mandatory line.
- **URL line.** The clickable URL on its own indented line directly below.
- **Dependency / unblocks context (optional).** If the top item *unblocks* other tracked work (e.g. a CI-secret fix that gates a release PR, an issue whose closure is referenced by `Blocked by #<N>` on another open item), append one indented parenthetical line naming what it unblocks: `(then <downstream> can go out)` / `(unblocks #<N>)`. This is part of "what to do next" — it tells the user *why* this is the next step. Derive it from the same signals the ranking uses (the dependency edges in Pass A/B); if there's no downstream dependency, omit the line.
- **Remainder footer (optional).** If the survey produced more than one item, append a single blank line then `<K> more item<s> — rerun with --all to see the full list` where `K` is the count of remaining items. If the top item was the only one, omit this footer. The structural footer from list mode (`main: red` / `<N> blocked:ci PRs`) still applies *in addition* when relevant — render it on its own line below the remainder footer.
- **Release-please / version-bump PR as the top item.** A discretionary release PR (per [Ranking → Release-please / version-bump PRs](#release-please--version-bump-prs-discretionary)) must **never** render as the sole `→ Next:` directive unless a concrete downstream dependency is blocked on the release shipping (the same exception that lets it rank up). The bottom-of-P2 ranking already keeps it out of the top slot whenever any other human-blocked item exists; this rule covers the case where it is the *only* item. Instead of a false-urgency directive, render the discretionary phrasing — the same shape as the [empty state](#empty-state), because there's no action *blocked on you*, just an open option:

  ```
  Nothing blocking you — the release PR #<num> is ready to ship whenever you want.
    https://github.com/owner/repo/pull/<num>
  ```

When the survey returns exactly one item, single-action mode renders just the `→ Next:` directive (plus its URL and any dependency line) with no remainder footer — the one item IS the whole list. (The lone-release-PR case above is the exception: it renders the discretionary phrasing instead of a `→ Next:` directive.)

### List mode (`--all`, or `--limit N > 1`)

Print the full ranked list. Lead with the verb; same terse, framing-free shape as before. Format:

```
1. #142 review and approve or request changes  <https://github.com/owner/repo/pull/142>
2. #155 read refined body, set priority label, remove needs-human-review  <https://github.com/owner/repo/issues/155>
3. #148 investigate failing check (`gh pr checks 148 --watch`), fix or escalate  <https://github.com/owner/repo/pull/148>
4. #161 reply to @<other-login>'s question or close if stale  <https://github.com/owner/repo/issues/161>
5. #134 finish draft and mark ready-for-review, or close (11d stale)  <https://github.com/owner/repo/pull/134>

main: green · 1 blocked:ci PR
```

### Rendering rules

These apply to the **list-mode** items and to the action sentence inside the single-action `→ Next:` directive.

Per item — **one line by default**:

- **Index** (1-based, monotonic across the entire list) followed by `.`
- **Artifact ref** — `#<num>` only (no `PR`/`Issue` prefix — the URL discloses the type; the number is the disambiguator).
- **Imperative action** — verb-first, sentence-case, no trailing period. This is the only mandatory content. Examples: `review and approve or request changes`, `investigate failing check, fix or escalate`, `reply to question or close`, `make the design call (see thread) or break into spike + impl`, `enable Email/Password in Firebase Console for <project>`, `set real values for placeholder secrets via firebase functions:secrets:set --project test`, `review the refuse reason in the comment; clear, re-scope, or close` (non-clearable `blocked:agent-hard`), `remove the blocked:agent-hard label — referenced blockers are resolved` (clearable).
- **Stale suffix** (optional) — append `(<N>d stale)` only when the item's age crosses a threshold worth flagging: **≥7d** for any item, or **≥1d** for `awaiting your review` (the highest-leverage block). Default: no age string. The point is a flag, not a metric.
- **URL** — clickable `<https://...>` at end of line so terminals render it as a hyperlink. Two spaces before the URL for visual separation.

**Drop by default:**

- **Title restatement.** The action sentence carries the artifact's intent in active voice; the title is reference, not headline. Include only when the action genuinely doesn't disambiguate without it (rare — e.g. `#42 review (auth refactor)` to distinguish from `#43 review (logging migration)` when several PRs are queued).
- **Per-item signal labels** (`needs-human-review`, `blocked:ci`, `awaiting your review`, `DIRTY`). The action sentence already encodes the signal; the label is metadata on the artifact for users who want the receipt.
- **Tier headers** (`P0 — blocking other work`, etc.). Items are already ranked; the position is the priority. Internal ranking still uses P0/P1/P2 (see [Ranking](#ranking)) — the tiers just don't render.
- **The opening `HUMAN ACTIONS NEEDED — …` banner.** Redundant — the user just typed the slash command.

**Multi-line items.** Only when the next action genuinely doesn't fit on one line *and* breaking it loses information. Follow-up lines are indented and still action-shaped (continuation of the verb), never framing or restatement.

**Optional footer line** — one line, terse, at the bottom of the list. Surface only if at least one is true: red main with no `fix-main-ci` PR open (`main: red`), open `blocked:ci` PRs (`<N> blocked:ci PRs`), or a clean state worth noting (`main: green`). Skip entirely if there's nothing structural worth flagging. Never a paragraph; never a recap of items already in the list.

### Internal fields (used for ranking, not rendered)

The ranking step still needs the underlying signals to produce the order — they just don't appear in the rendered output. The internal projection per item carries:

- **Tier** — P0 / P1 / P2 (see [Ranking](#ranking)).
- **Why-on-user** — the signal name that fired (`awaiting your review`, `blocked:ci`, `needs-human-review`, etc.). Used by the ranking + dedup logic; not rendered unless multiple signals merged into one row produced a non-obvious action verb, in which case a single inline `(also: <signal>)` suffix is permitted.
- **Age** — `createdAt` for new items, `updatedAt` for label-change items (v1 heuristic: use the older of the two; under-counts but never over-counts). Used to trigger the stale suffix.
- **URL** — surfaces unmodified.

### Empty state

If passes A–D return zero items: print a single friendly one-liner and exit cleanly. **Unchanged across modes** — the empty state is identical whether or not `--all` / `--limit` is passed, since there's no #1 item to lead with and no list to render. No banner, no multi-line prose — the empty case is the only case where the answer to "what do I need to do" is actively "nothing," and the rendering should mirror the content.

```
Nothing on your plate — backlog is clean. Try /shipyard:audit to surface fresh work, or take a break.
```

### Limit overflow (list mode only)

In **list mode**, if the ranked list has more items than `--limit`, print the first `--limit` items then:

```
  … and <K> more (rerun with --limit <K+N> to see all)
```

This overflow line is list-mode only. In **single-action mode** the analogous "there's more behind this" signal is the remainder footer (`<K> more item<s> — rerun with --all to see the full list`) described under [Single-action mode](#single-action-mode-default).

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
- **Don't present an open release-please / version-bump PR as a top-priority "next action."** A manual gate is discretionary, not blocking — the commits it releases are already on the default branch and nothing downstream cascades from it. Surface it as housekeeping (bottom of P2 — see [Ranking → Release-please / version-bump PRs](#release-please--version-bump-prs-discretionary)); only let it rank up or render as a top `→ Next:` directive when something downstream explicitly blocks on the release shipping. When it's the only human-blocked item, prefer the "release is ready whenever you want" phrasing over a false-urgency directive.
- **Don't include items where the next action is obviously Claude's, not the user's.** A PR with failing checks but NOT carrying `blocked:ci` is still inside `/shipyard:do-work`'s fix-loop — surfacing it would tell the user to step on the orchestrator's work. The `blocked:ci` label is the explicit "Claude gave up, human must" signal; absence of it means leave it alone.
- **Don't deep-dive on team membership for review requests.** v1 matches `$ME` directly against `reviewRequests`; team-via-membership lookups would add an extra `gh api` round-trip per PR and are out of scope. Users on teams will still see direct review requests in v1; team-level requests roll up via the GitHub UI's notification stream, which the user has anyway.
- **Don't repeat work `/shipyard:do-work`'s upfront summary already does.** `/do-work`'s step 2 prints a buckets table with workable / skipped / blocked counts. That's a *backlog snapshot*; `/my-turn` is a *human-actions list*. They share inputs but have different shapes — don't try to merge them.
- **Don't add framing back to the output.** No tier headers (`P0 — blocking other work`), no opening banner (`HUMAN ACTIONS NEEDED — …`), no closing prose paragraph (`Main CI on main is green, two PRs are still draining…`), no per-item title restatements, no per-item signal-label lines, no per-item age lines (except the stale suffix described in [Rendering rules](#rendering-rules)). The user asked for "what do I need to do" in imperative voice — every line of framing pushes the verb further down the screen. When in doubt: would removing this line lose any *action* information? If no, remove it.
- **Don't dump the full ranked list by default.** The default render is [single-action mode](#single-action-mode-default) — just the #1 item as a `→ Next:` directive. A 20-line backlog reintroduces the prioritization burden the command exists to remove and reads as an issue dump rather than "your next step." The full list is opt-in via `--all` (or `--limit N > 1`). The only exception is the [empty state](#empty-state), which is identical across modes.
