# /shipyard:do-work — Setup phase · co-scope grouping (sibling issues that may be one change)

**Fragment of step 6 — deep-link only, not part of the ordered per-session walk ([#1596](https://github.com/mattsears18/shipyard/issues/1596)).** Loaded from [`06-scope-preflight.md`'s co-scope pointer](./06-scope-preflight.md#co-scope-grouping--sibling-issues-scoped-together-1596) whenever a scope batch is formed — setup step 6 (both the C=1 just-in-time path and the C≥2 rolling batch) and [step D's scope refill](../steady-state.md#d-periodic-refresh) — and from [`steady-state.md`'s `shipped` handler](../steady-state.md#a1-parse-the-return-string) for the post-ship closing-link check. Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md).

## Why this exists

Scope pre-flight otherwise scopes strictly **one issue per scope agent**. When several issues come out of one audit run, that guarantees one of two bad outcomes: the orchestrator dispatches workers that collide on the same file, or it serializes work that was genuinely independent — and it cannot tell which, because the collision is only visible from *above* both issues. A scope agent looking at #4892 alone sees one bug in `sw.js` and returns `ready`; so does one looking at #4895 alone. Neither is wrong, and neither can know the other exists.

Repro (session `do-work-20260919T014132Z-18851`, `mattsears18/lightwork`, 2026-09-19): three sibling sets from one audit run. lightwork#4892 and #4895 were two bugs in the navigate-mode branch of `public/sw.js` that **both required the same `CACHE_VERSION` bump** — two PRs would have conflicted on that single line by construction, and #4895's own body said fixing #4892 alone did not fix it. They shipped as one PR (#4952, `closingIssuesReferences: [4892, 4895]`); #4893 from the same run was disjoint and shipped separately. Two other sibling sets (#4909/#4910, #4903/#4904) looked adjacent — same app, same route — but touched disjoint files and were correctly parallel-dispatched. Textual path-collision detection would have caught the `sw.js` overlap, but only to **park** the second candidate; parking is the wrong answer when the right answer is one PR.

## 1. Find co-scope sets — mechanical, never a heuristic

Issues sharing a **co-scope marker** in their body form a bounded candidate set. The default key is `audit-run`: every `/shipyard:audit` filing stamps `<!-- audit-run=<run-id> -->` (see [`audit.md`](../../audit.md) and `shipyard:filing-github-issues` § "Per-run attribution marker"). The key list is config-driven via `scope.co_scope_keys` (default `["audit-run"]`; set `[]` to disable co-scoping entirely and scope every candidate individually, the pre-#1596 behavior).

Run the grouping over the **eligible** candidates only — after the [pre-scope detector batch](./06-scope-preflight.md#pre-scope-orchestrator-side-detectors-synthetic-defers), the [freshness check](./06-scope-preflight.md#scope-result-freshness-check-skip-dispatch-when-a-fresh-diagnosis-comment-exists), and the [PR-collision cache-reuse check](./06-scope-preflight.md#pr-collision-cache-reuse-check-1448) have removed anything they settled. The candidate pool is the batch you are about to scope **plus any other `raw_backlog` issue sharing a marker with a batch member** (pull siblings in even from below the `2 × concurrency` window — a sibling left out of the group is exactly the blind spot this fragment closes; at C=1, the top candidate's siblings join it). Write the pool as a JSON array of `{number, body}` in rank order, then:

```bash
export CLAUDE_PLUGIN_ROOT="<plugin-root literal>"
export SHIPYARD_REPO_ROOT="<primary-root literal>"
"$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get scope.co_scope_keys
```

```bash
export CLAUDE_PLUGIN_ROOT="<plugin-root literal>"
"$CLAUDE_PLUGIN_ROOT/scripts/co-scope-groups.sh" groups --key audit-run .shipyard-scratch/co-scope-pool.json
```

(One `--key` per entry of the config value, in config order; an empty config array means skip this fragment.) Output is a JSON array of `{key, value, issues: [N, ...]}` — only sets of ≥2. Sets larger than 6 are chunked in rank order (`--max`), and an issue is never in two sets. Every candidate **not** in any set is scoped exactly as before — one scope agent per issue. A non-zero exit means scope every candidate individually; never invent a grouping.

## 2. One scope agent per set

Dispatch **one** read-only scope agent over each set instead of one per member (same background/inline execution model as the per-issue agents — at C=1 the orchestrator may do it inline). Its prompt carries every member's number and asks for the normal per-issue analysis of each **plus** a grouping judgment. It returns one **group envelope**:

```
{ group_key: "<key>=<value>", members: [N, M, ...],
  grouping: "separate" | "one-pr" | "partial",
  grouping_rationale: "<one or two sentences>",
  primary_issue?: N, bundled_issues?: [N, M, ...], shared_surface?: "<path[:line]>",
  entries: [ <one per-issue entry per member, in the existing Ready / Deferred / Already-landed shapes — unchanged> ] }
```

The per-issue `entries` are **exactly** the shapes in [`06g-scope-staleness-probe.md`](./06g-scope-staleness-probe.md) — the group envelope is additive, never a replacement. Every member gets its own entry, including its own staleness probe.

**The default stays `separate`.** `one-pr` (every member in one PR) and `partial` (a strict subset of ≥2 in one PR, the rest separate) each require a **concrete shared surface**: a file — ideally a line — that every bundled issue's fix must edit, cited as `shared_surface` and present in every bundled issue's own `files` list. "Same audit", "same app", "same route", or "adjacent symptoms" are **not** justifications; lightwork's #4903/#4904 (one a data-table entry in `lib/route-metadata.ts`, one a component heading) shared a route and were correctly `separate`. A bias toward `one-pr` would have produced a single unreviewable diff touching a CSS file and two new route files for no reason — the grouping pass is never a licence to widen scope. At most one bundle per set per pass; if the agent sees two disjoint bundles, it returns the stronger one and the rest go separate (the path-collision check then serializes any residual overlap — safe, merely not optimal). `primary_issue` is the bundled issue whose fix is the anchor (typically the one the other's body says must land with it); it names the branch.

## 3. Validate the verdict — a script, not a judgment

```bash
export CLAUDE_PLUGIN_ROOT="<plugin-root literal>"
"$CLAUDE_PLUGIN_ROOT/scripts/co-scope-groups.sh" validate .shipyard-scratch/co-scope-return.json
```

It prints one line: `verdict=bundle primary=<N> issues=<N,M,...> reason=shared-surface`, or `verdict=separate primary= issues= reason=<token>`. Anything malformed, unjustified (`missing-shared-surface`, `shared-surface-not-in-files`), inconsistent (`grouping-mismatch`, `primary-not-in-bundle`, `bundled-issue-not-a-member`), or with a bundled member whose own entry is not `ready` (`bundled-issue-not-ready:<N,...>`) **fails safe to `separate`**. Log a fallback as `[scope-preflight] co-scope <group_key> → separate (<reason>)`.

## 4. Handle the entries

- **`separate`** (including every fallback) — hand each member's entry to the normal [per-returned-entry handling](./06c-scope-handling-ui.md#handling-each-returned-entry-fires-as-each-background-agent-completes), exactly as if it had come from its own scope agent. Nothing else changes.
- **`bundle`** — non-bundled members' entries go through normal handling. The bundled members become **one** `ready_issues` entry keyed on `primary_issue`: `claimed_paths` and `lockfile_sections` are the union of the bundled entries', `phase_1_scope` is the primary's (a bundled member's own `phase_1_scope`, if any, is appended to it), and the entry carries `bundled_issues: [<every other bundled member>]`. Remove every bundled member from `raw_backlog` — they are claimed by the primary's dispatch and must never be dispatched on their own while it is in flight. Copy `bundled_issues` onto the `in_flight` slot at dispatch.
- Post the grouping on each bundled member as one short comment (`<!-- do-work-co-scoped -->` first line, then `Co-scoped with #<primary> — one PR will close <list>. Shared surface: <shared_surface>. <grouping_rationale>`) so a human reading any one of them sees why it did not get its own PR.

Dispatch with the [co-scoped bundle augmentation](../dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) — `mode: issue-work` against `primary_issue`, branch `do-work/issue-<primary_issue>`, with every bundled issue named as one the PR must close.

## 5. After ship — verify every bundled issue is actually closed by the PR

A worker told to close two issues can easily close only one. On a `shipped #<primary> via PR #<M>` return for a slot whose `in_flight` record carries `bundled_issues`, read GitHub's canonical signal — never the worker's claim:

```bash
gh pr view <M> --repo <owner/repo> --json closingIssuesReferences --jq '[.closingIssuesReferences[].number]'
```

Every bundled issue missing from that list is **returned to `raw_backlog`** (it is still open and nothing will close it) and logged as `[co-scope] PR #<M> does not close #<X> — returned to the backlog`. It is then scoped individually on the next refill — the fix may already cover it, which that scope agent's staleness probe will find. Do not edit the PR body yourself: the worker's own [§5.8](../../../agents/issue-worker/issue-work.md#58-post-pr-create-closing-link-verification) already patches and re-verifies per bundled issue, so a still-missing reference is either a deliberate unbundle (the worker found the shared-surface premise false mid-implementation) or a case that needs the issue scoped on its own.
