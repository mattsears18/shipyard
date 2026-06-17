---
description: Survey open PRs, the issue backlog, and recent comments to surface the single next action currently blocked on the user (not on Claude). Read-only — pairs with /shipyard:do-work as the human-driven counterpart.
argument-hint: [--repo owner/repo] [--all] [--limit N] [--chrome-prompt]
---

# /my-turn

Answer *"what do you need from me right now?"* with **the single next action** — by default, the one highest-leverage thing currently blocked on the user, rendered as a focused `→ Next:` directive. Behind that #1 item sits the same ranked survey of everything blocked on a human: the PRs that need the user's review, the issues blocked on a human decision, the failing checks that exhausted the orchestrator's fix-loop, the unresolved review comments tagging the user. The full ranked list renders only on `--all` (or an explicit `--limit N > 1`). **Read-only / advisory-only for v1.** No mutations, no dispatch — execution stays in `/shipyard:do-work` and other dedicated commands. The user reads the output, picks an item, and acts on it manually. When the top item is a [decision-gated issue](#decision-gated-handoff-offer), the command additionally *offers* (read-only — it prints an offer, it does not execute) to hand off to the mutating sibling [`/shipyard:resolve-decisions`](./resolve-decisions.md), which walks the blocking decisions one-by-one and records the answers ([#566](https://github.com/mattsears18/shipyard/issues/566)).

Pass `--chrome-prompt` to switch into **chrome-prompt mode**: the entire visible output is a single copy-paste-ready prompt block for the [Claude for Chrome browser extension](https://chrome.google.com/webstore/detail/claude-for-chrome), with unmistakable copy dividers and nothing else above or below it (no `→ Next:` chrome, no ranked list). The user highlights the block, pastes it into the extension, and the extension acts. This is text-emission only — no MCP, no Claude Code execution; the deliverable is the prompt itself. (Distinct from [#585](https://github.com/mattsears18/shipyard/issues/585), which drives Chrome directly via `chrome-devtools-mcp`.)

Pairs with [`/shipyard:do-work`](./do-work.md) — that one is the agent-driven loop (Claude works the backlog autonomously); this one is the human-driven counterpart (the user reads what the loop *couldn't* resolve and decides what to do). For an execution counterpart that drives the browser action after surfacing the top item, see [`/shipyard:my-turn-and-do`](./my-turn-and-do.md) ([#585](https://github.com/mattsears18/shipyard/issues/585)).

## Args

`$ARGUMENTS` may include:

- **--repo owner/repo** (optional, default: cwd's repo via `gh repo view --json nameWithOwner -q .nameWithOwner`). If not in a repo, ask via `AskUserQuestion`.
- **--all** (optional, default off): render the **full ranked list** instead of just the single next action. Without this flag (and without an explicit `--limit N > 1`), the command prints only the #1-ranked item as a focused `→ Next:` directive — see [Output](#output). Use `--all` when you want the whole backlog of human-blocked items, not just the next step. In `--chrome-prompt` mode, mirrors this same single-vs-all behavior: without `--all`, the prompt covers only the #1 action; with `--all`, the prompt covers all human-blocked actions batched into a single extension prompt.
- **--limit N** (optional, default `25` *when the list renders*): cap the printed list at N items. Only meaningful in list mode — i.e. when `--all` is passed, or when `--limit N` is given with `N > 1` (which itself opts into list mode). `--limit 1` is equivalent to the default single-action mode. Items beyond the cap are summarized as `… and <K> more (rerun with --limit <K+N> to see all)`. In `--chrome-prompt` mode, `--limit` caps the number of actions included in the batched prompt when combined with `--all`.
- **--chrome-prompt** (optional, default off): switch into **chrome-prompt mode** — the entire visible output is a single copy-paste-ready prompt block suitable for the Claude for Chrome browser extension. The output is prompt-only: no `→ Next:` chrome, no ranked list, no preamble. The copy region is marked with unmistakable dividers. After the prompt block, a clearly-separated section lists anything that cannot be done by the extension or by Claude (manual/external steps, things needing maintainer auth, judgment calls the user must make personally); this section is omitted entirely when empty. See [Chrome-prompt mode](#chrome-prompt-mode) for the full render spec. **Composes with `--all`**: without `--all`, the prompt is built from the #1-ranked action only; with `--all`, all human-blocked actions are batched into one prompt.

**Mode resolution.** The command runs in one of three render modes:

- **Single-action mode (default)** — no `--all`, no `--limit N` with `N > 1`, and no `--chrome-prompt`. Print only the top-ranked item as a `→ Next:` directive. This is the default because the command's promise is *focus*: the one thing to do next, not a backlog to re-prioritize.
- **List mode** — `--all` is present, OR `--limit N` is given with `N > 1`, AND `--chrome-prompt` is NOT present. Print the full ranked list (capped at `--limit`, default `25`). `--all` with no `--limit` shows every item.
- **Chrome-prompt mode** — `--chrome-prompt` is present. The entire output is a single copy-paste-ready prompt block (see [Chrome-prompt mode](#chrome-prompt-mode)). `--all` and `--limit` still govern how many actions are included in the prompt, but the outer render is always prompt-only.

`--all` and `--limit` compose within all three modes: `--chrome-prompt --all --limit 10` builds a batched chrome-prompt covering the top 10 human-blocked actions. In single-action mode and chrome-prompt-without-`--all` mode, `--limit` has no effect (only one item is surfaced).

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
- **Issue with `needs-operator` label** ([#608](https://github.com/mattsears18/shipyard/issues/608)) — blocked on a **browser/console operator action**, not a decision: paste a CI secret, flip a provider-console toggle, close a superseded PR, or another action completable by manipulating a browser. The operator can be **a human OR Claude** — `/do-work --operate` (a.k.a. [`/shipyard:my-turn-and-do`](./my-turn-and-do.md)) drives these in the user's real Chrome via the extension. `/shipyard:do-work` (no `--operate`) excludes `needs-operator` from code-worker dispatch (it isn't code work), so `/my-turn` surfaces it as a human-actionable operator item. The rendered action is the concrete operator step (e.g. `paste the EXPO_ASC_* secret in repo settings`, `close superseded duplicate PR #N`); when the item is browser-completable, note that `/shipyard:my-turn-and-do` can do it for you. Distinguish from `needs-human-review` (a genuine human *decision*, which Claude can't make) — `needs-operator` is a mechanical action either party can perform.
- **Issue with the legacy `needs-refinement` label** (stale — the label was eliminated in [#520](https://github.com/mattsears18/shipyard/issues/520); `/shipyard:refine-issues` no longer applies or reads it, detecting candidates by source-signal scan instead). If any open issue still carries `needs-refinement`, it's a leftover from before the migration — surface it so the user can remove the label (the GitHub label object was intentionally left for manual cleanup). The issue's actual refinement, if needed, now happens automatically via the signal scan; the stale label is purely a housekeeping nudge.
- **Issue with `needs-human-review` + the `<!-- do-work-needs-decomposition -->` body marker** ([#498](https://github.com/mattsears18/shipyard/issues/498); the epic-handoff is re-keyed from the former dedicated `needs-decomposition` label onto `needs-human-review` + this marker by [#519](https://github.com/mattsears18/shipyard/issues/519)'s binary-backlog fold) — a `/do-work` scope agent confirmed the epic is non-shippable as a single PR. (The marker is what distinguishes an epic-decomposition handoff from every *other* `needs-human-review` issue — refined user-feedback, external-author, design-gated — which surface via the generic `needs-human-review` bucket above; render this one as the more-specific "epic awaiting decomposition" action when the marker is present.) If there's **no** `<!-- do-work-decompose-agent -->` idempotency sentinel in any comment, `/shipyard:decompose-epic` hasn't been run yet — the user can run it to auto-shard the epic into dispatch-ready sub-issues (for `Multi-PR sequence:` / `Missing dependency:` evidence classes). If a sentinel comment **is** present and reads `couldn't auto-decompose:`, the epic is a genuine human-decomposition handoff (non-mechanical evidence class, or too big to shard cleanly) — the user decomposes it by hand. Either way the epic is blocked on the user, not on Claude.
- **Agent refuses now surface via the `needs-human-review` bucket above** (changed in [#521](https://github.com/mattsears18/shipyard/issues/521)). The former `blocked:agent-hard` label was eliminated: a worker that hard-bails for a pure security / scope / prompt-injection *refuse* (no open `Blocked by #<M>` reference) now carries `needs-human-review`, so the "Claude gave up; a human must actually look" signal is already covered by the `needs-human-review` signal above — it doesn't need its own bucket. The bail comment (`steady-state.md`'s bail handler writes a `Worker returned blocked: <reason>. Classified as needs-human-review` comment) records *why*, so cite it in the rendered action when the issue's `needs-human-review` arrived via an agent refuse rather than the refinement / external-author / design-gate paths. The former **clearable-hard-block** signal (body has ≥1 `Blocked by #<M>` reference, all closed) is **removed** — a dependency-wait now carries no label at all; the `Blocked by #<M>` body-reference filter auto-clears it the instant the blocker closes (it becomes a plain workable issue with no human action needed), so there is nothing for `/my-turn` to surface (per [#500](https://github.com/mattsears18/shipyard/issues/500) → [#521](https://github.com/mattsears18/shipyard/issues/521)).
- **Issue authored by `$ME` with no linked PR and no `needs-human-review` label** — the user filed something and nothing's happened; `/shipyard:do-work` should be picking it up, but if it's not (wrong priority label, missing labels), the user should triage. (`blocked:agent-soft` issues ARE workable and auto-clear at next-session backlog fetch — they don't need user triage; a dependency-wait carries no label and auto-clears when its blocker closes.)
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

Merge the candidates from passes A–D into a single ranked list. Each item carries a priority tier and, within its tier, a **leverage score** (highest-leverage first) with `createdAt` ascending (oldest first) as the final tie-breaker — see [Secondary sort](#secondary-sort). The leverage score, not raw age, is what determines the single `→ Next:` directive in single-action mode (issue [#565](https://github.com/mattsears18/shipyard/issues/565)).

### Priority tiers

- **P0 — blocking other work**
  - PRs awaiting `$ME`'s review (any age) — `$ME` is literally what's stopping merge
  - Issues with `needs-human-review` label — `/shipyard:do-work` is skipping them (this now includes the former `needs-design` design-gates, folded into `needs-human-review` per [#515](https://github.com/mattsears18/shipyard/issues/515))
  - Issues with `needs-operator` label — blocked on a browser/console operator action ([#608](https://github.com/mattsears18/shipyard/issues/608)); a human can do it, or `/shipyard:my-turn-and-do` (`/do-work --operate`) can drive it in the browser
  - Red main / failing CI on default branch with no `fix-main-ci` PR open

- **P1 — decisions**
  - PRs with `blocked:ci` (3-attempt orchestrator fix-loop exhausted, needs human eyes)
  - (Agent refuses now carry `needs-human-review` and surface under the **P0** `needs-human-review` bucket above — the former dedicated P1 `blocked:agent-hard` entry was removed in [#521](https://github.com/mattsears18/shipyard/issues/521); cite the worker's bail comment in the rendered action so the refuse reason is visible. See [#500](https://github.com/mattsears18/shipyard/issues/500) → [#521](https://github.com/mattsears18/shipyard/issues/521).)
  - Issues still carrying the legacy `needs-refinement` label (stale — eliminated per [#520](https://github.com/mattsears18/shipyard/issues/520); remove the label)
  - Issues with `needs-human-review` + the `<!-- do-work-needs-decomposition -->` body marker (a scope agent confirmed the epic is non-shippable as a single PR — run `/shipyard:decompose-epic` to auto-shard the mechanical cases, or decompose by hand if a `couldn't auto-decompose:` sentinel comment is already present; re-keyed from `needs-decomposition` by [#519](https://github.com/mattsears18/shipyard/issues/519))
  - Issues authored by `$ME` with no linked PR (the user filed it, nothing happened)
  - Open review comment threads on `$ME`'s PRs awaiting reply
  - Issues where the last comment was a question or `@$ME` mention from someone else

- **P2 — housekeeping**
  - PRs with `mergeStateStatus: DIRTY` >24h (rebase didn't auto-fire)
  - Draft PRs stale >7 days (finish or close)
  - (The former **clearable** `blocked:agent-hard` housekeeping entry was removed in [#521](https://github.com/mattsears18/shipyard/issues/521) — a dependency-wait carries no label and auto-clears via the `Blocked by #<M>` body-reference filter when its blocker closes, so there's no leftover label for a human to remove.)
  - `CHANGES_REQUESTED` on `$ME`'s open PRs (the user owes the reviewer a response)

### Secondary sort — leverage score, then age (issue [#565](https://github.com/mattsears18/shipyard/issues/565))

Within each tier, sort by a **leverage score descending** (highest-leverage first), and break ties by `createdAt` ascending (oldest first). **Leverage is the primary within-tier key; age is only the tie-breaker.** This is the fix for [#565](https://github.com/mattsears18/shipyard/issues/565): the old flat `createdAt`-ascending secondary sort made the *stalest* item the sole `→ Next:` directive in single-action mode, which on a P0 tier dominated by long-lived `needs-human-review` issues regularly surfaced an auto-undecomposable epic — the *least* actionable item — directly contradicting the command's "single highest-leverage thing blocked on you" promise. Oldest-first is a reasonable *tie-breaker*, but it is not a *leverage* signal, and in single-action mode the secondary sort alone determines the one rendered item.

**The leverage score is derived entirely from signals the survey passes A–D already collect** — no new `gh` calls, no new round-trips. Higher score = higher leverage = a human action that unblocks the most downstream work for the least effort. Rank within a tier by this order (4 = highest leverage, 1 = lowest):

1. **Score 4 — pure-decision item.** The human action is a single decision that flips the item to dispatch-eligible / mergeable: a `needs-human-review` issue whose body enumerates product / schema / design questions with **no** external-console, on-device, or external-dependency requirement; a PR awaiting `$ME`'s review; an issue where the last comment is a direct question or `@$ME` ping awaiting a one-line answer. One human call converts the item to workable-by-`/do-work` (or merges it) — the highest leverage per unit of effort, so these float to the top of their tier.
2. **Score 3 — quick external action.** The next step is a fast, mechanical action in a third-party console or repo settings: paste a CI secret, toggle a Firebase auth provider, delete a stale branch, flip a GitHub setting. Recognized by the [third-party console deep-link](#third-party-console-deep-links) signals (a derivable provider deep link) and by `external-dependency` / secret-paste phrasing. Slower than a pure decision (a context-switch into a provider UI) but still bounded and unblocking.
3. **Score 2 — on-device / multi-party verification.** The action needs a device, a build, or coordination with another party (run a build through TestFlight, verify an on-device flow, get a second person to confirm). Higher effort and higher latency than a console toggle.
4. **Score 1 — auto-undecomposable epic / parking-lot umbrella.** A `needs-human-review` issue carrying the `<!-- do-work-needs-decomposition -->` body marker **and** a `couldn't auto-decompose:` sentinel comment (`/decompose-epic` already determined it can't be mechanically sharded). A by-hand decomposition is *real work*, not a "next step" — these are low-leverage **as a single human action** by definition, so they **sink** to the bottom of their tier rather than floating to the top on age alone. This is the exact item the [#565](https://github.com/mattsears18/shipyard/issues/565) repro surfaced as a false `→ Next:` (the 4-week-stale `epic(aso)` #540).

Items that match none of the above (e.g. a stale draft PR, a `CHANGES_REQUESTED` PR, a `mergeStateStatus: DIRTY` PR) take a **neutral middle score (2)** so the leverage ordering only *re-orders* the clear high/low-leverage cases and otherwise falls back to the age tie-breaker — it never invents urgency for a housekeeping item. The score is a within-tier ordering signal only; it never moves an item across tiers (a P2 pure-decision item does not outrank a P0 epic).

**Worked example (the [#565](https://github.com/mattsears18/shipyard/issues/565) repro).** A P0 tier with 19 `needs-human-review` issues: under the old oldest-first sort, the 4-week-stale auto-undecomposable `epic(aso)` #540 ranked #1 and became the sole `→ Next:`. Under leverage-then-age, #540 scores 1 (auto-undecomposable epic) and sinks; a pure-decision issue like "feature blocked on 7 product/schema decisions the user can answer in minutes" scores 4 and floats to the top of P0 — so the `→ Next:` directive now points at the genuinely highest-leverage human action, restoring the headline promise.

Surface a single age string per item regardless of leverage score — `<N>d` for ≥1 day, `<N>h` for ≥1 hour, else `<N>m`.

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

When the action's next step lives in a **third-party console**, append the provider deep link on its own indented line below the GitHub artifact URL (see [Third-party console deep links](#third-party-console-deep-links)):

```
→ Next: create a Test User on the test Meta app 982594884358918 (#74)
  https://github.com/owner/repo/issues/74
  https://developers.facebook.com/apps/982594884358918/roles/test-users/
```

Rules for the single-action render:

- **`→ Next:` line.** The `→ Next: ` prefix, then the **imperative action** (verb-first, sentence-case, same shape as the list-mode action — see [Rendering rules](#rendering-rules)), then the artifact ref `(#<num>)` in parentheses at the end. This is the one mandatory line.
- **URL line.** The clickable GitHub artifact URL on its own indented line directly below.
- **Third-party console deep link (when applicable).** When the action's actual work happens in a provider console (Meta / Firebase / Vercel / App Store Connect / Apple Developer / Play Console / GCP / GitHub settings), append the most-specific-reachable provider deep link on its own indented line below the artifact URL, derived per [Third-party console deep links](#third-party-console-deep-links). Falls back to the provider's top-level console when the specific page isn't derivable; omit only when no third-party console is involved.
- **Dependency / unblocks context (optional).** If the top item *unblocks* other tracked work (e.g. a CI-secret fix that gates a release PR, an issue whose closure is referenced by `Blocked by #<N>` on another open item), append one indented parenthetical line naming what it unblocks: `(then <downstream> can go out)` / `(unblocks #<N>)`. This is part of "what to do next" — it tells the user *why* this is the next step. Derive it from the same signals the ranking uses (the dependency edges in Pass A/B); if there's no downstream dependency, omit the line.
- **Remainder footer (optional).** If the survey produced more than one item, append a single blank line then `<K> more item<s> — rerun with --all to see the full list` where `K` is the count of remaining items. If the top item was the only one, omit this footer. The structural footer from list mode (`main: red` / `<N> blocked:ci PRs`) still applies *in addition* when relevant — render it on its own line below the remainder footer.
- **Release-please / version-bump PR as the top item.** A discretionary release PR (per [Ranking → Release-please / version-bump PRs](#release-please--version-bump-prs-discretionary)) must **never** render as the sole `→ Next:` directive unless a concrete downstream dependency is blocked on the release shipping (the same exception that lets it rank up). The bottom-of-P2 ranking already keeps it out of the top slot whenever any other human-blocked item exists; this rule covers the case where it is the *only* item. Instead of a false-urgency directive, render the discretionary phrasing — the same shape as the [empty state](#empty-state), because there's no action *blocked on you*, just an open option:

  ```
  Nothing blocking you — the release PR #<num> is ready to ship whenever you want.
    https://github.com/owner/repo/pull/<num>
  ```

When the survey returns exactly one item, single-action mode renders just the `→ Next:` directive (plus its URL and any dependency line) with no remainder footer — the one item IS the whole list. (The lone-release-PR case above is the exception: it renders the discretionary phrasing instead of a `→ Next:` directive.)

#### Decision-gated handoff offer

When the top `→ Next:` item is a **decision-gated** issue — a `needs-human-review` issue that scores leverage **4** as a *pure-decision item* because its body (or a scope-preflight comment) enumerates **answerable** blocking decisions (a numbered "Blocking decisions before any code can be written" list, an `## Open questions` / `## Open product/schema questions` heading, a `<!-- do-work-human-decision-required -->` marker, or a `design`-gated set of questions) — append a single **opt-in offer** line below the directive, after any dependency/console line:

```
→ Next: answer the 7 product/schema decisions blocking the orgs feature (#1816)
  https://github.com/owner/repo/issues/1816
  Want me to walk you through them one at a time (with a recommendation for each)? Run /shipyard:resolve-decisions --issue 1816
```

The offer is a **hand-off to the sibling [`/shipyard:resolve-decisions`](./resolve-decisions.md) command**, which runs the interactive one-by-one walkthrough (restate → options → **recommendation+reasoning** → lock → room to clarify) and then performs the **mutation** (post a structured decisions comment + remove the gating label so `/do-work` can pick the issue up). The walkthrough and mutation live **entirely in that command** — `/my-turn` stays read-only and only *offers* the hand-off ([#566](https://github.com/mattsears18/shipyard/issues/566)). This preserves the [single-action contract](#single-action-mode-default): the `→ Next:` directive is unchanged; the offer is one extra advisory line, not a second action or an auto-launch.

Rules for the offer line:

- **Only for a genuinely decision-gated item.** Apply it only when the top item is a leverage-score-4 pure-decision `needs-human-review` issue with answerable decisions present. Do **NOT** append it to an epic-decomposition handoff (`<!-- do-work-needs-decomposition -->` — that's `/shipyard:decompose-epic`'s job, score 1), an `external-dependency` defer (`<!-- do-work-external-dependency -->`), or an external-author trust gate — those carry `needs-human-review` but enumerate no answerable decisions, so there's nothing to walk.
- **Offer only, never execute.** `/my-turn` does not walk the decisions, post any comment, or remove any label — it prints the offer and stops. Running the walkthrough is the user's explicit next step (`/shipyard:resolve-decisions`). This is the read-only boundary; do not cross it.
- **List mode.** In `--all` / `--limit N > 1` list mode, the offer is not rendered per-row (it would be noise across a long list); the decision-gated item still renders its normal action row. The hand-off offer is a single-action-mode affordance only.

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

### Chrome-prompt mode (`--chrome-prompt`)

When `--chrome-prompt` is present, the **entire visible output** is a single copy-paste-ready prompt block. Nothing appears above the opening divider line and nothing appears below the closing divider line except the optional "can't be automated" section. The user highlights from the first divider line to the last, pastes the whole thing into the Claude for Chrome browser extension, and the extension acts — no further reading or interpretation required.

**Survey and ranking run identically.** The same passes A–D run, the same priority tiers and leverage scores apply, and `--all` / `--limit` govern which actions are included (top-1 without `--all`; all ranked items with `--all`, capped at `--limit`). The only difference is the render.

**Prompt construction.** The body of the pasted prompt is self-contained instructions telling the extension what to do — concrete enough that the extension can act without re-deriving anything:

- For each included action: the imperative action sentence (verb-first, sentence-case), the GitHub artifact URL, and — when applicable — the third-party console deep link (same derivation as the standard render). The extension can navigate to URLs; include them literally.
- Enough context to identify each item unambiguously: PR or issue number, what to click, what to decide, what text to type (e.g. for a review: whether to approve or request changes).
- When covering multiple actions (`--all`), present them as a numbered list inside the prompt body, ordered by the same ranking used by the standard render.

**Layout.** Print exactly this structure, with no other content outside the dividers and the trailing section:

```
                                               (one blank line)
──────────────── COPY THE PROMPT BELOW ────────────────
                                               (one blank line)
<the full pasteable prompt for the Claude Chrome extension>
                                               (one blank line)
──────────────── COPY THE PROMPT ABOVE ────────────────
                                               (one blank line)

⚠️  Can't be automated (do these yourself):
- <item>
```

Rules for each layout element:

- **Divider lines.** Use exactly `──────────────── COPY THE PROMPT BELOW ────────────────` and `──────────────── COPY THE PROMPT ABOVE ────────────────` (em-dashes `─`, U+2500, repeated). The labels are capitalised; the dashes form a full-width visual rule. One blank line on each interior side of the dividers.
- **Prompt body.** Self-contained, complete instructions. No meta-commentary ("here is what you should do"), no output-format instructions to the reader — write to the extension as if it were receiving the instructions directly. Use the present-tense imperative ("Go to ...", "Open ...", "Click ...", "Review ..."). Include all URLs. For decision-gated items, enumerate the specific decisions to make and any context the extension needs to recommend or resolve them.
- **"Can't be automated" section.** Appears after the closing divider, separated by one blank line. The `⚠️  Can't be automated (do these yourself):` header is followed by a bullet list of items that are out of reach for the browser extension: actions requiring physical device access, external-service credentials the extension doesn't have, real-world coordination with a third party, or judgment calls explicitly flagged as needing the user's personal decision. **Omit the section entirely** (header and all) when there are no such items — do not emit an empty section or a "none" bullet. The classification heuristic: an action is browser-doable if it consists of navigation + clicking + typing in a browser tab using the user's session; it is NOT browser-doable if it requires out-of-browser credentials, a native device (TestFlight, on-device build), a third party's manual action, or a purely personal judgment the user must own.
- **Empty state in chrome-prompt mode.** When passes A–D return zero items, emit the same empty-state text as normal mode but wrap it in the dividers so the output shape is consistent:

  ```
                                                 (one blank line)
  ──────────────── COPY THE PROMPT BELOW ────────────────
                                                 (one blank line)
  Nothing on your plate — backlog is clean. No actions for the Chrome extension right now.
                                                 (one blank line)
  ──────────────── COPY THE PROMPT ABOVE ────────────────
  ```

**What chrome-prompt mode does NOT emit:**

- No `→ Next:` prefix or directive.
- No ranked numbered list above or outside the dividers.
- No tier headers, signal labels, or remainder footer.
- No decision-gated handoff offer (the `/shipyard:resolve-decisions` offer is a terminal-output affordance; the chrome-prompt output goes to the extension, not to the terminal reader's action queue).
- No structural footer line (`main: green · ...`).

**Distinction from #585.** The `--chrome-prompt` flag is text-emission only: Claude emits a prompt string and stops. No `chrome-devtools-mcp` calls, no browser automation, no MCP connection. The Claude for Chrome extension is a separate agent that receives the text and operates independently. Issue [#585](https://github.com/mattsears18/shipyard/issues/585) covers the complementary mode where Claude Code itself drives the browser via MCP — do not conflate the two.

### Rendering rules

These apply to the **list-mode** items and to the action sentence inside the single-action `→ Next:` directive.

Per item — **one line by default**:

- **Index** (1-based, monotonic across the entire list) followed by `.`
- **Artifact ref** — `#<num>` only (no `PR`/`Issue` prefix — the URL discloses the type; the number is the disambiguator).
- **Imperative action** — verb-first, sentence-case, no trailing period. This is the only mandatory content. Examples: `review and approve or request changes`, `investigate failing check, fix or escalate`, `reply to question or close`, `make the design call (see thread) or break into spike + impl`, `enable Email/Password in Firebase Console for <project>`, `set real values for placeholder secrets via firebase functions:secrets:set --project test`, `review the refuse reason in the comment; clear, re-scope, or close` (agent-refuse `needs-human-review`, per [#521](https://github.com/mattsears18/shipyard/issues/521)).
- **Stale suffix** (optional) — append `(<N>d stale)` only when the item's age crosses a threshold worth flagging: **≥7d** for any item, or **≥1d** for `awaiting your review` (the highest-leverage block). Default: no age string. The point is a flag, not a metric.
- **URL** — clickable `<https://...>` at end of line so terminals render it as a hyperlink. Two spaces before the URL for visual separation.
- **Third-party console deep link** (optional) — when the item's action's next step lives in a provider console (Meta / Firebase / Vercel / App Store Connect / Apple Developer / Play Console / GCP / GitHub settings), append the most-specific-reachable provider deep link `<https://...>` after the GitHub artifact URL (two spaces before it), derived per [Third-party console deep links](#third-party-console-deep-links). Falls back to the provider's top-level console when the specific page isn't derivable. Omit when no third-party console is involved. Example: `6. #74 create a Test User on the test Meta app 982594884358918  <https://github.com/owner/repo/issues/74>  <https://developers.facebook.com/apps/982594884358918/roles/test-users/>`.

**Drop by default:**

- **Title restatement.** The action sentence carries the artifact's intent in active voice; the title is reference, not headline. Include only when the action genuinely doesn't disambiguate without it (rare — e.g. `#42 review (auth refactor)` to distinguish from `#43 review (logging migration)` when several PRs are queued).
- **Per-item signal labels** (`needs-human-review`, `blocked:ci`, `awaiting your review`, `DIRTY`). The action sentence already encodes the signal; the label is metadata on the artifact for users who want the receipt.
- **Tier headers** (`P0 — blocking other work`, etc.). Items are already ranked; the position is the priority. Internal ranking still uses P0/P1/P2 (see [Ranking](#ranking)) — the tiers just don't render.
- **The opening `HUMAN ACTIONS NEEDED — …` banner.** Redundant — the user just typed the slash command.

**Multi-line items.** Only when the next action genuinely doesn't fit on one line *and* breaking it loses information. Follow-up lines are indented and still action-shaped (continuation of the verb), never framing or restatement.

**Optional footer line** — one line, terse, at the bottom of the list. Surface only if at least one is true: red main with no `fix-main-ci` PR open (`main: red`), open `blocked:ci` PRs (`<N> blocked:ci PRs`), or a clean state worth noting (`main: green`). Skip entirely if there's nothing structural worth flagging. Never a paragraph; never a recap of items already in the list.

### Third-party console deep links

When the next action's actual work happens in a **third-party provider console** ([#523](https://github.com/mattsears18/shipyard/issues/523)) — the user has to create a test user in the Meta App Dashboard, enable an auth provider in the Firebase Console, paste a secret into a GitHub repo's Actions settings, submit a build in App Store Connect, etc. — the rendered action **MUST** append a clickable deep link to the **most specific reachable page**, derived from identifiers already in hand (app ID, project ID, bundle ID, team/owner slug, etc.). The information needed to build the link is almost always already present in the issue/PR body, a comment, or the repo's config — turning it into a URL costs the user one navigation they'd otherwise do by hand, across a provider UI with many nested pages.

This applies to **all three render modes**: the single-action `→ Next:` directive (the deep link goes on the indented URL line, *in addition to* the GitHub artifact URL — see [Single-action mode](#single-action-mode-default)), the list-mode rows (the deep link is appended after the GitHub artifact URL — see [Rendering rules](#rendering-rules)), and the chrome-prompt body (include the URL literally in the prompt text so the extension can navigate directly — see [Chrome-prompt mode](#chrome-prompt-mode)).

**Provider URL templates.** Substitute the bracketed identifiers from the action's context. Extend this table as new providers/actions surface — it's a starting set, not a closed list:

| Provider | Action | URL template |
|---|---|---|
| Meta App Dashboard | Test Users | `https://developers.facebook.com/apps/<APP_ID>/roles/test-users/` |
| Meta App Dashboard | App settings / basic | `https://developers.facebook.com/apps/<APP_ID>/settings/basic/` |
| Firebase Console | Auth users | `https://console.firebase.google.com/project/<PROJECT_ID>/authentication/users` |
| Firebase Console | Auth providers | `https://console.firebase.google.com/project/<PROJECT_ID>/authentication/providers` |
| Vercel | Project | `https://vercel.com/<TEAM>/<PROJECT>` |
| App Store Connect | App | `https://appstoreconnect.apple.com/apps/<APP_ID>` |
| Apple Developer | Identifiers | `https://developer.apple.com/account/resources/identifiers/list` |
| Play Console | App dashboard | `https://play.google.com/console/u/0/developers/<DEV_ID>/app/<APP_ID>/app-dashboard` |
| GCP Console | Project | `https://console.cloud.google.com/home/dashboard?project=<PROJECT_ID>` |
| GitHub | Repo Actions secrets | `https://github.com/<owner>/<repo>/settings/secrets/actions` |

**Fallback when the specific page isn't derivable.** If a required identifier is missing (you know it's a Firebase auth task but the body never names the `<PROJECT_ID>`), link the provider's **top-level console** rather than no link at all — a one-hop landing page still beats prose-only navigation:

| Provider | Top-level fallback |
|---|---|
| Meta App Dashboard | `https://developers.facebook.com/apps/` |
| Firebase Console | `https://console.firebase.google.com/` |
| Vercel | `https://vercel.com/dashboard` |
| App Store Connect | `https://appstoreconnect.apple.com/apps` |
| Apple Developer | `https://developer.apple.com/account/` |
| Play Console | `https://play.google.com/console/` |
| GCP Console | `https://console.cloud.google.com/` |
| GitHub | `https://github.com/<owner>/<repo>` |

**Derivation rules:**

- **Use identifiers already in hand — never fabricate one to fill a template.** Pull `<APP_ID>` / `<PROJECT_ID>` / `<owner>`/`<repo>` from the action's context (the issue or PR body that produced the item, a comment, the resolved repo). If you can only partially fill a template (e.g. the provider and a project ID but not the exact sub-page), link the deepest page you *can* fully construct, then fall back up the hierarchy — most-specific-reachable wins, but a guessed identifier is worse than the fallback (a wrong deep link sends the user to someone else's app).
- **Read-only constraint still holds.** Deriving the link is pure string construction from data already surveyed; it adds no `gh` mutation and no new API round-trip. Do **not** call out to a provider API to *discover* a missing identifier — that's scope creep and may require credentials the command doesn't have. Missing identifier ⇒ top-level fallback, full stop.
- **One deep link per action.** If an action plausibly touches two consoles, link the one where the *next* step happens; don't stack multiple provider links on one directive.

### Internal fields (used for ranking, not rendered)

The ranking step still needs the underlying signals to produce the order — they just don't appear in the rendered output. The internal projection per item carries:

- **Tier** — P0 / P1 / P2 (see [Ranking](#ranking)).
- **Leverage score** — 4 / 3 / 2 / 1 (see [Secondary sort](#secondary-sort--leverage-score-then-age-issue-565)), derived from the same survey signals. The **primary** within-tier sort key (descending); not rendered. Issue [#565](https://github.com/mattsears18/shipyard/issues/565).
- **Why-on-user** — the signal name that fired (`awaiting your review`, `blocked:ci`, `needs-human-review`, etc.). Used by the ranking + dedup logic; not rendered unless multiple signals merged into one row produced a non-obvious action verb, in which case a single inline `(also: <signal>)` suffix is permitted.
- **Age** — `createdAt` for new items, `updatedAt` for label-change items (v1 heuristic: use the older of the two; under-counts but never over-counts). The **tie-breaker** within a leverage score (oldest first); also triggers the stale suffix.
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

- **Don't mutate any state.** No `gh pr edit`, no `gh issue close`, no comments posted, no labels changed. The command is advisory; mutation lives in `/shipyard:do-work` and other dedicated commands. The [decision-gated handoff offer](#decision-gated-handoff-offer) is **not** an exception — it *prints an offer* to run `/shipyard:resolve-decisions` and stops; the walkthrough and its record-and-unblock mutation (post decisions comment + remove gate label) happen entirely inside that sibling command when the user runs it, never inside `/my-turn`. Offering a hand-off is read-only; executing it is the sibling command's job ([#566](https://github.com/mattsears18/shipyard/issues/566)). A future v2 may offer one-keystroke handoff into `/do-work` for items the orchestrator could auto-resolve, but that's out of scope for v1.
- **Don't dispatch any agents.** The user wants a quick survey, not a 20-minute autonomous session. If the user wants Claude to *work* the items, they'll run `/shipyard:do-work` separately.
- **Don't scan other repos.** Current repo only. Cross-repo digest is a future v2; for v1 the user can re-run with `--repo` in different cwds.
- **Don't write a report file.** v1 is terminal-only. If the user wants persistence, they can pipe via shell redirection from outside the slash-command UI; that's their concern, not the command's. Add `--output <path>` later if useful.
- **Don't surface PRs / issues authored by bots** (Dependabot, Renovate, etc.) unless they specifically request review from `$ME` — those auto-update PRs are noise in a "human action needed" list and have their own automation handling them.
- **Don't present an open release-please / version-bump PR as a top-priority "next action."** A manual gate is discretionary, not blocking — the commits it releases are already on the default branch and nothing downstream cascades from it. Surface it as housekeeping (bottom of P2 — see [Ranking → Release-please / version-bump PRs](#release-please--version-bump-prs-discretionary)); only let it rank up or render as a top `→ Next:` directive when something downstream explicitly blocks on the release shipping. When it's the only human-blocked item, prefer the "release is ready whenever you want" phrasing over a false-urgency directive.
- **Don't include items where the next action is obviously Claude's, not the user's.** A PR with failing checks but NOT carrying `blocked:ci` is still inside `/shipyard:do-work`'s fix-loop — surfacing it would tell the user to step on the orchestrator's work. The `blocked:ci` label is the explicit "Claude gave up, human must" signal; absence of it means leave it alone.
- **Don't deep-dive on team membership for review requests.** v1 matches `$ME` directly against `reviewRequests`; team-via-membership lookups would add an extra `gh api` round-trip per PR and are out of scope. Users on teams will still see direct review requests in v1; team-level requests roll up via the GitHub UI's notification stream, which the user has anyway.
- **Don't repeat work `/shipyard:do-work`'s upfront summary already does.** `/do-work`'s step 2 prints a buckets table with workable / skipped / blocked counts. That's a *backlog snapshot*; `/my-turn` is a *human-actions list*. They share inputs but have different shapes — don't try to merge them.
- **Don't add framing back to the output.** No tier headers (`P0 — blocking other work`), no opening banner (`HUMAN ACTIONS NEEDED — …`), no closing prose paragraph (`Main CI on main is green, two PRs are still draining…`), no per-item title restatements, no per-item signal-label lines, no per-item age lines (except the stale suffix described in [Rendering rules](#rendering-rules)). The user asked for "what do I need to do" in imperative voice — every line of framing pushes the verb further down the screen. When in doubt: would removing this line lose any *action* information? If no, remove it.
- **Don't sort the within-tier order by age alone.** The within-tier secondary sort is **leverage score first, age only as the tie-breaker** (see [Secondary sort](#secondary-sort--leverage-score-then-age-issue-565)). A flat `createdAt`-ascending sort makes the *stalest* item the sole `→ Next:` in single-action mode — which on a `needs-human-review`-dominated P0 tier regularly surfaces an auto-undecomposable epic (the least actionable item), contradicting the command's "highest-leverage" promise (issue [#565](https://github.com/mattsears18/shipyard/issues/565)). Oldest-first is the tie-breaker, not the ranking signal.
- **Don't dump the full ranked list by default.** The default render is [single-action mode](#single-action-mode-default) — just the #1 item as a `→ Next:` directive. A 20-line backlog reintroduces the prioritization burden the command exists to remove and reads as an issue dump rather than "your next step." The full list is opt-in via `--all` (or `--limit N > 1`). The only exception is the [empty state](#empty-state), which is identical across modes.
- **In `--chrome-prompt` mode, don't emit anything outside the dividers except the "can't be automated" section.** The entire output must be highlightable as one clean copy region. Any preamble, status line, `→ Next:` directive, or trailing prose outside the defined layout breaks the copy flow and defeats the mode's purpose. The "can't be automated" section is intentionally after the closing divider — it is for the human's eyes, not for the extension to execute, and it must not be inside the prompt body.
- **In `--chrome-prompt` mode, don't emit the extension-handoff offer from [Decision-gated handoff offer](#decision-gated-handoff-offer).** That offer (`Want me to walk you through them one at a time? Run /shipyard:resolve-decisions ...`) is a terminal-output affordance for the human reading the terminal — it has no place in a prompt destined for the browser extension. Chrome-prompt mode is exclusively for extension consumption; terminal-only affordances are suppressed.
- **Don't call any MCP browser tools or attempt to drive the browser from `--chrome-prompt` mode.** The flag emits a text prompt and stops. Browser execution (if desired) is the Claude for Chrome extension's job, triggered when the user pastes the prompt. Driving the browser directly is [#585](https://github.com/mattsears18/shipyard/issues/585)'s scope, not this flag's.
