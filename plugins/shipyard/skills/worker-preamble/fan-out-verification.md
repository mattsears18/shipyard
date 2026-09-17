# Worker-preamble fragment — fan-out into your own worktree: verification does not delegate

On-demand fragment of the `shipyard:worker-preamble` skill (see [`SKILL.md`](./SKILL.md) § "Fan-out into your own worktree — verification does not delegate"). Most dispatches never load this: the default worker shape is a single agent doing its own work in its own worktree, and the rules below are a no-op for it. **Load it before you write the dispatch prompts** for a fan-out — the moment you decide to hand parts of your own implementation to subagents that will edit the same worktree you are sitting in ([#1554](https://github.com/mattsears18/shipyard/issues/1554)).

Fan-out is **not** forbidden. For a genuinely wide, mechanical, cleanly-partitionable change (one treatment applied across dozens of files), it is the right move and is materially faster than serial. What this fragment governs is what the subagents are allowed to *conclude*, not whether they may exist.

## The mechanism — one worktree, several writers, and verification that doesn't partition

The rest of `worker-preamble` invests heavily in isolating a worker from its **peers**: worktree discipline, the mid-session cwd anchoring rule, the [`git stash` prohibition](./git-stash-prohibition.md), the [broad-process-kill prohibition](./process-kill-detail.md). Every one of those rules assumes the worktree has **exactly one writer**. Fan-out breaks that assumption from the inside — and it breaks it *silently*, because the preamble's own guarantees keep reading as if they still hold.

The file partitioning is the easy half and usually works: give each subagent a disjoint file list and no file gets touched twice. **The verification does not partition.** A whole-tree `lint` / `typecheck` / full-suite run executed by subagent 3 observes subagents 1, 2, 4, 5 and 6 mid-edit, and the spec gives it no way to tell a peer's half-finished edit apart from a real failure in its own work. Every subagent is looking at a different, transient, unreproducible tree.

**The failure is asymmetric, and quiet in the dangerous direction.** A false **red** is loud and merely expensive: the subagent burns turns proving its innocence and hedges its report. A false **green** — or its more common dress, *"those failures aren't mine, they're environmental"* — is silent, and it is exactly the reasoning a subagent reaches for first when a suite fails in files it does not recognise.

## The repro ([lightwork](https://github.com/mattsears18/lightwork) #4666 → PR #4670, session `session_01Hhpf4cMkHFRhbKhzjv9tF5`, 2026-08-28)

One chrome treatment across ~35 write surfaces — too wide to do serially in budget, cleanly partitionable by file. Six `general-purpose` subagents, each with a disjoint file list, all inheriting the parent worker's worktree. The partitioning worked; the final diff was correct. Every subagent had also been told to run `npm run typecheck` / `npm run lint` before returning. Three distinct bad outcomes, one cause:

1. **Cross-contaminated lint.** Three subagents reported `npm run lint` failing on `no-unused-vars` in files *they had never touched* — peers' in-flight edits. Each independently spent turns re-running a targeted `eslint` to prove innocence, and each hedged its final report (*"lint fails, but not because of this batch"*).
2. **A shared-cache remedy applied blind.** One subagent hit a stale `.expo/cache/eslint/` error naming a test file *another* concurrent subagent had renamed, and cleared the shared cache mid-flight. Correct, as it happened — but it is a destructive shared-state action taken on evidence generated entirely by a peer.
3. **A confidently wrong full-suite verdict.** One subagent ran the full unit suite with no emulator, got 1,231 failures, and reported them as *"pre-existing environmental noise… my report from before stands as final."* The parent had separately run the same suite correctly (per-run emulator ports) and had **1** real failure — a source-pinning test the change genuinely broke. Had the parent trusted that subagent's verdict, a real regression would have shipped.

Nothing shipped wrong, because the parent caught it. Case 3 is the near-miss this fragment exists to make structurally impossible.

## The rule — a fanned-out subagent implements and reports; it does not gate

This is already the spec's model for the **worker's** relationship to the orchestrator (`SKILL.md` § "Return-contract discipline": *your terminal state is reached from LOCAL gates + PR-opened*, and CI confirmation is the orchestrator's job, not yours). Fan-out just needs it stated one level down.

1. **A subagent dispatched into the parent's worktree implements and reports. It never gates.** Its return is *"here is what I changed, and here is what I ran"* — never *"this is verified, ship it."*
2. **It may run a *targeted* check scoped to its own files** for its own fast feedback — `eslint <its files>`, `tsc` on a file list, a named suite covering the module it touched — and it **must say what it ran**, verbatim, in its return. A targeted check is not a gate either; it is evidence the parent weighs.
3. **It must not treat a whole-tree `lint` / `typecheck` / full-suite result as a verdict on its own work, and must never report such a result as final.** If it ran one anyway and it was red, the correct return is *"whole-tree lint was red; I did not attribute it"* — not an innocence verdict, and not an environmental one. **"These failures aren't mine" is the single most dangerous sentence a fanned-out subagent can write**; it is unfalsifiable from inside a tree several peers are editing.
4. **The parent runs the authoritative gates ONCE, after every subagent has returned, and owns the push decision.** That means the parent — not any subagent — satisfies [`issue-work.md` §4.5](../../agents/issue-worker/issue-work.md#45-pre-pr-create-diff-sanity-check) (diff sanity), [§4.6](../../agents/issue-worker/issue-work.md#46-pre-push-local-unit-test-gate-658) (the pre-push unit gate), the CI-superset discovery in §4, and [§5](../../agents/issue-worker/issue-work.md#5-commit--push--pr) (commit, push, PR). **A subagent's green is never a substitute for §4.6** — the parent re-runs it on the settled tree regardless of how many subagents reported clean.
5. **The parent owns the git index.** Subagents edit files; the parent stages and commits. Concurrent `git add` / `git commit` against one shared index is the same one-writer violation in a different costume (racing `.git/index.lock`, and a commit that captures whichever peers happened to have saved by then).
6. **A subagent must not take destructive shared-state actions on evidence it cannot attribute to itself** — clearing a shared build/lint/test cache, `git restore` / `git checkout --` on any path, `rm -rf node_modules`, a dependency reinstall, or killing processes (already prohibited outright by `SKILL.md` § "Never run a broad process kill"). Hand the observation up to the parent and let the parent decide; the parent is the only participant that knows when the tree is quiet.
7. **A suite that needs external services is not a check a fanned-out subagent should run at all.** Firebase emulators with per-run ports, a database container, a seeded dev server — a run without them produces a mass failure whose most natural misreading is *"environmental, not mine"* (repro case 3, exactly). Those suites belong to the parent, once, on the settled tree.

## Put it in the dispatch prompt

The rules above only bind a subagent that is told about them. A fanned-out subagent inherits your task context, not this fragment — so state the contract explicitly in each subagent's prompt. A serviceable shape:

> You are one of several agents editing **one shared worktree** concurrently. Your files: `<disjoint list>`. Edit only those.
>
> **You implement and report; you do not gate.** Do NOT run a whole-tree `lint` / `typecheck` / full test suite — peers are mid-edit, so its result says nothing about your work. A targeted check scoped to your own files is fine; say exactly what you ran.
>
> Do NOT `git add`, `git commit`, `git restore`, clear any shared cache, reinstall dependencies, or kill processes — I own the index and all shared state. If you see something broken outside your files, report it to me; don't act on it.
>
> Return: the files you changed, what you ran, and anything you could not finish. Do not return a verdict on whether the change is ready.

## When NOT to fan out

- **The change isn't cleanly partitionable by file.** Overlapping edits to the same file are a merge problem no contract fixes.
- **The change is small enough to do serially.** Fan-out buys wall-clock time at the cost of a verification story you now have to manage; on a handful of files it is a net loss.
- **The work needs a single coherent design decision applied with judgment** rather than one mechanical treatment repeated. Six agents will make six slightly different calls.

Fan-out remains available and appropriate for the wide-and-mechanical case. The contract above is what makes its verification trustworthy, not a discouragement from using it.
