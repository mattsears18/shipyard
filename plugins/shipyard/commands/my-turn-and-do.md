---
description: Alias for /do-work --operate — runs the autonomous /do-work loop AND drives browser-completable operator actions in the user's real, logged-in Chrome, continuously, until both the code backlog and the operator queue are empty.
argument-hint: [--repo owner/repo] [--concurrency N] [--dry-run] [--record]
---

# /my-turn-and-do

**`/my-turn-and-do` is a thin alias for [`/shipyard:do-work --operate`](./do-work.md).** It exists as a memorable name for "do my work *and* operate the browser for me." All behavior lives in `/do-work` and its [operator phase](./do-work/operate.md) — this file just forwards.

> **Re-parented from `/my-turn` to `/do-work` (was: action-taking sibling of `/my-turn`).** Earlier versions extended [`/shipyard:my-turn`](./my-turn.md) — a one-shot, surface-the-#1-action behavior. That was the wrong lineage: the intent is a **continuous autonomous loop** that does the normal `/do-work` issue-burndown **as well as** any browser-completable operator action it needs, not one task and stop. So it's now `/do-work --operate`. For the human counterpart — an interactive walkthrough of the items that genuinely need *you* (decisions and judgment calls `--operate` can't complete), one at a time until the human-only queue is empty — use [`/my-turn`](./my-turn.md). The three-command division: `/my-turn` = human-only interactive walkthrough; `/do-work` = autonomous code loop; `/do-work --operate` (this command) = code loop **+** browser operation.

## What it does

Running `/my-turn-and-do` is exactly `/do-work --operate`:

1. Runs the normal autonomous **code loop** — picks open issues, dispatches parallel workers in worktrees, opens PRs, arms auto-merge, fixes failing CI, keeps `main` green. (See [`/do-work`](./do-work.md).)
2. **Plus** drains a browser-action queue by driving your **real, logged-in Chrome** — the work `/do-work` otherwise defers or hands back: closing a superseded PR, pasting a CI secret, toggling a referenced provider setting, posting an unambiguous reply, merging/closing via the UI when `gh` can't. Fed reactively (worker hand-backs + `external-dependency` / `needs-operator` defers) and proactively (a `/my-turn`-style sweep filtered to browser-completable items). See [`do-work/operate.md`](./do-work/operate.md).

Code workers parallelize per `--concurrency`; browser actions serialize on the main thread (your real Chrome is a singleton). The loop ends when the code backlog, the in-flight set, **and** the operator queue are all empty.

**Invoking this command is standing authorization** to perform any browser-completable action without per-action confirmation ([#608](https://github.com/mattsears18/shipyard/issues/608)). Genuine human-judgment items (PR review, contestable replies — the `needs-human-review` class) are still handed back to you, never auto-decided. `--dry-run` previews without acting.

## Onboarding

The operator phase runs a **self-onboarding preflight** once at session start — if a prerequisite is missing (`gh` auth, the Claude Chrome extension, a site permission) it diagnoses the gap and walks you through fixing it interactively, then proceeds. If no browser backend is reachable it degrades to the normal code loop and surfaces operator items as hand-backs (never aborts). See [`do-work/operate.md` → Preflight](./do-work/operate.md#preflight--detect-gaps-and-guided-setup).

First-run tip: `/do-work --operate --dry-run` (or `/my-turn-and-do --dry-run`) runs the preflight and previews what it would do without touching the browser.

## Args

Identical to [`/do-work`](./do-work.md#args), with `--operate` implied (you don't pass it — the alias sets it). Commonly: `--repo owner/repo`, `--concurrency N`, `--dry-run` (preview only), `--record` (capture browser actions as GIFs, extension backend only). `--label` / `--prioritize-label` / `--fast` all carry through from `/do-work`.

## Don't

- **Don't expect `/my-turn` semantics.** This is the continuous *autonomous* `/do-work` loop with a browser-operator layer — it works the backlog and drives the browser without per-step human pacing. For the human-only interactive walkthrough (the items that genuinely need *you*, walked one at a time), use [`/my-turn`](./my-turn.md).
- Everything else: the prohibitions live in [`do-work/dont.md`](./do-work/dont.md) and the operator-specific ones in [`do-work/operate.md` → Don't](./do-work/operate.md#dont).
