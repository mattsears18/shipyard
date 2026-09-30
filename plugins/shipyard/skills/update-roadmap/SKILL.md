---
name: update-roadmap
description: Bring a repo's milestone-based roadmap current — assign a milestone to every open issue that lacks one, author new phases where the backlog has outgrown the existing ones, check each phase's stated bet against reality, detect and record issue dependencies, and surface the judgment calls a human should make. Orchestrator-only — a dispatched /shipyard:do-work worker must never invoke this. Gated on `milestones.enabled`.
---

# Update Roadmap

Bring a repo's roadmap current. Assign a milestone to every open issue that lacks one, author new phases where the backlog has outgrown the existing ones, check each phase's stated bet against reality, detect issue dependencies the backlog hasn't recorded yet, and surface the judgment calls only a human can make.

This skill is a **port** of `mattsears18/lightwork`'s repo-local `.claude/skills/update-roadmap/SKILL.md`, generalized off that repo and with the GitHub Projects v2 half removed (the maintainer dropped the `projects` feature there — see [`do-work-RATIONALE.md → milestones config block`](../../commands/do-work-RATIONALE.md#milestones-config-block--config-surface-only-scope-and-why-projects-projects-v2-was-dropped-issue-1239) for why). The lightwork original paid for the rules below the hard way — several are cautionary notes about specific failures, not hypothetical concerns. This port carries the reasoning forward rather than the bare rule alone. See [issue #1240](https://github.com/mattsears18/shipyard/issues/1240) for the full provenance; the original file was unreachable at port time (see [Provenance note](#provenance-note) below) — this skill was authored from the issue body's detailed spec, which the maintainer wrote to be complete on its own.

## Gate: `milestones.enabled`

**Do nothing unless `milestones.enabled == true` in the repo's effective config.** Read it once at the start of a run:

```bash
CLAUDE_PLUGIN_ROOT="<resolved per shipyard:worker-preamble's step-0 pattern>"
ENABLED=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get milestones.enabled)
if [ "$ENABLED" != "true" ]; then
  echo "milestones.enabled is false (or the block is absent) — nothing to do."
  exit 0
fi
FALLBACK=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get milestones.fallback)
```

A repo that hasn't opted in via `/shipyard:init` (or `/shipyard:config set milestones.enabled true`) gets byte-for-byte no behavior from this skill — no GitHub Milestones API calls, no reads, nothing. This mirrors every other `milestones.*` consumer's inertness contract (see [`do-work/dont.md`'s milestones bullet](../../commands/do-work/dont.md)).

## Who runs this

**Orchestrator-only. A dispatched `/shipyard:do-work` worker must never invoke this skill or touch a milestone.** A worker runs in an isolated worktree scoped to a single issue — it has no view of the whole backlog, and two workers touching milestones concurrently would race each other (one worker's renumber landing mid-read of another worker's cold-start scan). This skill runs from the orchestrator's own context (an explicit `/shipyard:update-roadmap` invocation, or a scheduled end-of-loop step a future issue may wire in), which has the single, serialized view of the backlog the mechanics below assume.

The worker-side half of this boundary — the prohibition a dispatched worker actually reads — lives in `shipyard:worker-preamble`'s [`milestone-prohibition.md`](../worker-preamble/milestone-prohibition.md) fragment, not here. Stating the rule only in this skill (which the orchestrator runs) would be invisible to the agent it's meant to constrain — see that fragment's own header for why the split exists.

## No roadmap file, ever

**Never write a `docs/roadmap.md` (or any other roadmap document).** The lightwork original did exactly this and removed it the same day — it duplicated the milestone descriptions the moment it was written, and now there were two sources that could drift. **The milestone description *is* the roadmap.** If a phase's rationale changes, edit the milestone description via the GitHub API (`gh api repos/<owner>/<repo>/milestones/<number> -X PATCH -f description="..."`) — never author a parallel markdown file that restates it.

## The autonomy boundary

This is the skill's spine: mechanical and reversible gets applied directly; judgment and strategy gets proposed for a human to accept or reject.

| Apply directly | Propose, never apply |
| --- | --- |
| Open issue with no milestone → assign it | Moving an issue that **already has** a milestone to a different phase |
| Creating a phase the backlog warrants, including the fallback | Declaring a phase complete / closing a milestone |
| Renumbering to insert a phase mid-sequence | Rewriting an existing phase's `BET:` |
| Recording a dependency an issue's own text already states | Recording a dependency merely inferred from reading two issues together |

**Deliberate divergence from the lightwork original:** lightwork's version listed *"creating a new phase that claims a slot in the sequence"* under propose-only. This port has explicit maintainer authorization for shipyard to create phases directly — see [Milestone-creation authority](#milestone-creation-authority-split-three-ways) below for the finer-grained split that authority actually takes. Rewriting a bet someone already committed to stays propose-only regardless — that's editing strategy, not filling a gap.

A proposal — whenever this skill needs one — must be **specific enough to accept or reject on the spot**: a proposed title with its sequence number, the exact `BET:` and `DONE LOOKS LIKE:` text as it would be written, which existing phases would renumber, and the specific issues that would move into it from the fallback. "The backlog may warrant a new phase" is not actionable and wastes the round-trip. Post proposals as a single issue comment on the fallback milestone's tracking issue if one exists, or as a top-level comment on the most relevant open issue if not — always tagged `[roadmap proposal]` at the start of the comment so a human scanning the issue list recognizes it immediately.

## Every open issue gets a milestone — always

If no existing phase fits an unmilestoned issue, assign the fallback (`milestones.fallback`, default `Ongoing maintenance`). If even the fallback categorically doesn't fit — the issue is clearly the seed of a phase that doesn't exist yet — that's a signal to create a phase (see [Milestone-creation authority](#milestone-creation-authority-split-three-ways)), not a reason to leave the issue unmilestoned. **An issue with no milestone sits in a "No milestone" bucket nobody opens** — GitHub's milestone-filtered issue views are the primary way both humans and `/do-work`'s future `prioritize_dispatch` consumer will read the roadmap, and an issue outside every milestone is invisible to both.

**But never bulk-assign to the fallback without reading the issue.** A blanket "everything unmilestoned → maintenance" sweep in the lightwork original *"once swallowed two `P0` defects that were breaking `main` and the Cloud Functions deploy."* Match each candidate issue against the phase's `BET:` text, not against keywords in its title — a title containing "fix" or "bug" is not evidence an issue belongs in a maintenance-flavored fallback; read what the issue is actually about and compare it to what each existing phase's bet claims to be doing.

## Milestone-creation authority (split three ways)

Creating a phase is not one action — the right autonomy differs by case. This is the maintainer's explicit decision for this port (superseding any looser "free rein" framing that might read into the autonomy-boundary table above):

| Case | Authority | Why |
| --- | --- | --- |
| **Cold start** — repo has zero milestones | **Apply** | Proposing would leave the entire backlog unmilestoned pending a human. There is no roadmap to disturb, so nothing is at risk. |
| **The fallback milestone** (`milestones.fallback`) | **Apply** | Plumbing, not strategy. It carries no bet, never completes, and always sorts last. |
| **A new phase in an established roadmap** | **Propose** | It claims a slot in the sequence, renumbers existing phases, and asserts a new bet. That is a strategy change. |

**What makes "propose" safe here is the interim placement.** An issue that fits no existing phase goes to the fallback **immediately**, while the phase proposal is pending — never hold an issue unmilestoned waiting for a human to answer a proposal. Without the immediate fallback assignment, "propose, don't apply" would break the every-open-issue-carries-a-milestone rule the moment the sweep found a gap.

This is the same boundary the autonomy table draws generally, applied to the one case (phase creation) where it isn't uniform: fill a gap mechanically, but never re-sequence a plan a human authored.

## Cold start — a repo with zero milestones

The lightwork original never had to handle this; every port of this skill to a fresh repo does. When `gh api -X GET repos/<owner>/<repo>/milestones --paginate -f state=all` returns an empty **JSON array** and `milestones.enabled` just flipped true (or this is genuinely the first run), the skill has to author the **initial phase set** from the actual open backlog, not assume phases already exist to sort issues into.

**An error is not an empty list ([#1652](https://github.com/mattsears18/shipyard/issues/1652)).** Cold start fires only when the fetch exited 0 **and** its output parsed as a JSON array of length zero. A non-zero exit, a non-array body (e.g. a `{"message": ..., "status": "422"}` error object), or unparseable output means *could not read milestones* — stop the run and report it; never treat it as "zero milestones". Misreading an error as empty would author a second, duplicate roadmap on a repo that already has one — the "clean, empty, entirely wrong" failure [Prove a check can fail before trusting it](#prove-a-check-can-fail-before-trusting-it) warns about.

**`-X GET` is load-bearing.** `gh api` silently switches its default method from GET to **POST** as soon as any `-f`/`-F` field is passed, so without `-X GET` this call hits *create a milestone* with body `{"state":"all"}` instead of listing them (#1652's repro got a 422 from the create endpoint). With `-X GET`, the fields become query parameters.

Procedure:

1. Fetch every open issue (`gh issue list --state open --limit 500 --json number,title,body,labels,createdAt`).
2. Cluster them by what they're actually about — read bodies, not just titles or labels; a P0/P1/P2 severity label is a priority signal, not a phase signal. Look for natural groupings: a foundational/infrastructure cluster that blocks everything else usually sorts first, a maintenance/cleanup cluster usually sorts last (feeding the fallback), and everything else clusters by what depends on what (see [Dependency detection](#dependency-detection-issue-1240s-added-scope) below — cold start is exactly where that signal matters most, since there's no existing sequence to lean on).
3. Author each phase with a `BET:` (the wager this phase is making — what becomes true if it succeeds) and a `DONE LOOKS LIKE:` (the concrete, checkable condition for calling it complete) in the milestone description.
4. Number phases sequentially starting at `1`, using the `N · Title` prefix (U+00B7 MIDDLE DOT, one space each side — the schema's fixed separator, not configurable; see [`shipyard.config.schema.json`'s `milestones` block description](../../schemas/shipyard.config.schema.json)).
5. Create the fallback milestone with the **highest** `N` of any milestone in the repo — it always sorts last.
6. Assign every open issue to the phase it fits, or the fallback if none does (per [Every open issue gets a milestone](#every-open-issue-gets-a-milestone--always) above — read each issue, don't keyword-match).

Cold start is **apply**, not propose, per the authority table above — there is no existing roadmap a cold-start authoring could disturb.

## Honesty checks

A roadmap decays quietly rather than loudly. These checks exist to catch the quiet decay before it compounds:

- **Is phase order being respected?** Flag when later-phase work is landing while dispatchable earlier-phase work sits untouched. **Discount human-gated work** — a phase stalled on `needs-human-review` (or any other gate label) is *blocked*, not *skipped*; don't treat a maintainer-side bottleneck as evidence the sequence itself is being ignored.
- **Is a phase secretly done?** A phase whose every issue has closed, but which nobody has declared complete, is a stale roadmap — not a finished one. Propose closing it (never apply — see the autonomy table).
- **Are the bets still true?** A phase's `BET:` contains factual claims that go stale as the codebase changes underneath them. The lightwork example: *"native ships with zero verified E2E coverage"* stops being true the moment that work lands. Verify each open phase's bet against the current state of the code, and propose corrected wording where a claim no longer holds — don't silently leave a false claim in a milestone description just because rewriting a bet is propose-only.
- **Are dates real?** Only write a date into a phase description when the date is real — a store submission deadline, a partner commitment. **Never invent one to populate a timeline.** A fabricated date reads as a commitment nobody made.

## The anti-WIP-limit rule

**Do not flag a phase for holding many `P1`s, and do not propose demotions on that basis.** Agent throughput is not the constraint this roadmap manages — unlike a human team where WIP limits guard against context-switching cost, a phase full of `P1`s dispatches in parallel across worktrees with no equivalent cost. *"A phase full of P1s is the current phase, not an over-committed one."* A large `P1` count inside one phase is a sizing signal about the phase's scope, worth noting if genuinely enormous, but never grounds to demote or split issues purely because there are many of them.

## Dependency detection (issue #1240's added scope)

Under parallel dispatch, sort order *within* a milestone barely changes outcomes — nearly every issue in a phase gets worked in the same session regardless of who goes first. **Dependencies are the exception**: wrong-order work is wasteful or actively conflicting, a correctness problem rather than a preference. So dependency ordering is where the within-milestone effort belongs, and sort tiers are where it doesn't.

Shipyard already has the mechanism: `Blocked by #N` in an issue's body is a **hard gate** ([`01b-backlog-overview.md` bucket 7](../../commands/do-work/setup/01b-backlog-overview.md)) that drops an issue from `/do-work`'s workable queue entirely — not a sort tier. What's missing is that **nothing systematically produces those lines**; they only exist when whoever filed the issue happened to write one. This skill's backlog-wide read is exactly what dependency detection requires and exactly what a single-issue filer lacks — so it's the right place to fix the gap.

**Autonomy boundary for dependencies** — matches the skill's spine:

- **Apply** a `Blocked by #N` line when an issue's own text *states* the dependency ("once #N lands", "after the config block ships", "depends on the new accessor"). Recording an already-stated fact is mechanical.
- **Propose** a dependency that is merely *inferred* from reading two issues together, without either issue stating it. A wrong `Blocked by` stalls real work — it removes the issue from the queue entirely — so inference must never self-apply.

**Also report stale dependencies.** A `Blocked by #N` whose blocker has already closed isn't harmful on its own (bucket 7 re-checks live issue state before treating a reference as blocking), but a chain nobody has pruned is a signal the backlog has drifted from what the sequencing actually implies. Surface it, even though clearing it is optional cleanup rather than a correctness fix.

**Do not attempt to infer file-level conflicts** between issues with no logical dependency. `detect-mutually-blocking-prs.sh` already handles the PR-side collision case; guessing at file-level conflicts from issue text alone would produce false blocks in exactly the place a false positive is most expensive — an issue that's actually fine to dispatch, silently removed from the queue.

## Prove a check can fail before trusting it

A cautionary principle worth carrying forward even though the code that taught it is gone: the lightwork original's now-dropped Projects-v2 board-sync section shipped a real bug. `gh project item-list` does not return issue state, so `.content.state` was always `null`; `select(.content.state == "CLOSED")` matched nothing, and a `// "OPEN"` default silently marked every closed issue open. Seven closed issues read `Todo` on the board while a scripted "closed items" check reported none found — a **clean, empty, entirely wrong** answer, because the query succeeded against a field that didn't exist.

**The generalizable rule:** before trusting any "nothing found" result from a filter you just wrote, run it once against a case you already know should match. A predicate over a field that silently doesn't exist is indistinguishable from a predicate that correctly found nothing — the only way to tell them apart is to prove the filter *can* return non-empty before relying on it returning empty. Apply this to every `gh` `--jq` filter this skill writes, not just milestone-specific ones: if a step below claims "no phases whose bet is stale" or "no dependency-eligible issues," verify that claim against a known-matching case before reporting it.

## Numbering and renumbering

A milestone's sequence position is read back from its title's numeric prefix, `N · Title` (U+00B7 MIDDLE DOT, one space each side — fixed, not configurable; see the schema description cited above). Renumbering existing phases to insert a new one mid-sequence is safe and applies directly (per the autonomy table) **because issues reference milestones by GitHub's own numeric milestone ID, not by title** — renaming a milestone's title (to bump its `N ·` prefix) never breaks any issue's assignment. To insert a phase at position `K`:

1. Rename every existing milestone whose current `N >= K` to `N+1 · <same title>` (in descending `N` order, so no two milestones are ever briefly titled the same during the walk).
2. Create the new milestone titled `K · <new title>`.
3. Re-assign the fallback (still the highest `N`) if the insertion pushed past its old position — the fallback's `N` is always `max(all other N) + 1`, recomputed after any insertion.

## Procedure

1. **Gate check.** Confirm `milestones.enabled == true` (see [Gate](#gate-milestonesenabled) above). Exit cleanly if not.
2. **Fetch current state.** All open issues (`gh issue list --state open --limit 500 --json number,title,body,labels,milestone,createdAt`) and all milestones (`gh api -X GET repos/<owner>/<repo>/milestones --paginate -f state=all --jq '[.[] | {number, title, description, state, open_issues, closed_issues}]'`).
3. **Cold start check.** If the milestone fetch failed or returned anything other than a JSON array, stop and report *could not read milestones* — never fall through to cold start (see [Cold start](#cold-start--a-repo-with-zero-milestones)'s error-is-not-empty rule). If the milestone list is a genuinely empty array, run [Cold start](#cold-start--a-repo-with-zero-milestones) and skip to step 7 once it completes — a freshly cold-started repo has nothing left to sweep in the same run.
4. **Unmilestoned sweep.** For every open issue with no milestone, read it against each phase's `BET:` and assign the best-fitting phase, or the fallback if none fits (per [Every open issue gets a milestone](#every-open-issue-gets-a-milestone--always) — never keyword-match). Create the fallback first if it doesn't exist yet.
5. **Dependency sweep.** For every open issue (milestoned or not), scan its body and — for stated dependencies only — apply a `Blocked by #N` line if one isn't already present (per [Dependency detection](#dependency-detection-issue-1240s-added-scope)). Collect inferred-but-unstated dependencies and stale `Blocked by` references as proposals/reports for step 7, never applied directly.
6. **Honesty checks.** Walk every open milestone and run the four checks in [Honesty checks](#honesty-checks) above. Collect findings — don't apply any of them; all four are propose-only or report-only.
7. **Report.** Post a single summary — as a comment on the fallback milestone's tracking issue if the repo has one, otherwise print it as this run's final output — listing: issues assigned this run (mechanical), phases created this run (cold start / fallback only — mechanical), dependencies recorded this run (stated-only — mechanical), and every proposal / honesty-check finding from steps 5–6, each tagged `[roadmap proposal]` and specific enough to accept or reject on the spot.

## Provenance note

The `mattsears18/lightwork` source file (`.claude/skills/update-roadmap/SKILL.md`) was unreachable at the time this port was authored — the path returned 404 against `mattsears18/lightwork@main`'s GitHub API, and a full-tree search found no `roadmap`-matching path in that branch's history either (see issue [#1240](https://github.com/mattsears18/shipyard/issues/1240)'s PR for the detail). This skill was authored directly from the issue body, which the maintainer wrote with the autonomy boundary, honesty checks, anti-WIP-limit rule, cold-start handling, milestone-creation-authority split, and cautionary "prove a check can fail" note spelled out in enough detail to reconstruct the original's substance without the source file in hand.
