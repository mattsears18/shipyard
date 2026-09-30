---
name: mode-shim-preamble
description: Shared scaffold every /shipyard:do-work mode-shim agent (`shipyard:issue-worker` and its six per-mode siblings — fix-checks-worker, fix-rebase-worker, fix-main-ci-worker, fix-pr-batch-worker, investigate-worker, spike-worker) loads — the frontmatter worktree-isolation declaration, the identical worker-preamble bullet list, and the mode→shim mapping table. Referenced by all 7 agents instead of each re-inlining the same ~15-20 lines of boilerplate. Closes #879.
---

# Mode-shim preamble (every `/shipyard:do-work` mode-shim agent)

The scaffold every one of the seven `agents/issue-worker.md` + `agents/{fix-checks,fix-rebase,fix-main-ci,fix-pr-batch,investigate,spike}-worker.md` files shares, independent of which mode it dispatches. Each shim's own `.md` file references this skill by name instead of repeating the language verbatim, and keeps only what's genuinely unique to it: its frontmatter identity (`name`, `description`, `model` — **never** touched by this skill), its own model-choice reasoning sentence, its per-mode `--label shipyard` / auto-merge caveat bullets, its wrong-shim fail-safe string, and its "Per-mode spec" pointer to the canonical `agents/issue-worker/<mode>.md` file.

This skill composes with `shipyard:worker-preamble` (the actual rule bodies — worktree discipline, the hook-bypass prohibition, the auto-merge/snapshot pattern, the return-contract discipline) and with each mode's own per-mode file under `agents/issue-worker/`. Neither of those is owned by this skill; this skill owns only the *scaffold around* them — the parts of a shim's own `.md` file that were byte-for-byte (or near-byte-for-byte) identical across all seven regardless of mode.

## Worktree isolation — declared, not policed

Every worker shim declares `isolation: worktree` in its own frontmatter. Claude Code provisions the worktree, pins the working directory, and enforces containment for the shim **and every subagent it spawns** — blocking file edits, command working directories, and git redirects that target the main checkout, and refusing any command it cannot statically verify stays inside the worktree. See [Claude Code's worktree isolation](https://code.claude.com/docs/en/worktrees#how-claude-code-enforces-isolation) for the four checks.

The `Agent` tool (the default shape for all seven modes, as of [#825](https://github.com/mattsears18/shipyard/issues/825)) resolves each shim by its `subagent_type` — its frontmatter `name:`, e.g. `shipyard:fix-checks-worker`. `/shipyard:do-work` dispatches this shim by name again, as the default shape, after [#791](https://github.com/mattsears18/shipyard/issues/791) briefly routed every `mode:`-driven worker through the `Workflow` substrate exclusively.

There is nothing for a caller to pass and nothing for shipyard to police. A new worktree-isolated shim needs only the frontmatter field. `shipyard:worker-preamble` § "Worktree discipline" remains the source of truth for the rules that *follow* from being isolated (never `gh pr checkout`; never `git switch` to the default branch on return) — those are branch-management rules the harness has no opinion about, not containment rules.

## Shared worker-preamble bullets

Every shim's own "Shared rules — load first" section keeps this identical lead-in and close, plus its own bullet list built from `shipyard:worker-preamble`:

> Before doing anything else, **load the `shipyard:worker-preamble` skill**. That skill carries the rules every worker mode shares:
>
> - Worktree discipline (never `cd` outside your worktree; never use `gh pr checkout`; never `git switch` to the default branch on return).
> - The worktree-reaped escape hatch (`WORKTREE_PATH` capture + pre-write directory check).
> - The absolute prohibition on `--no-verify` / `--no-gpg-sign` / `--no-commit-hooks` / any hook-bypass flag.
> - The return-contract discipline (no narrative status updates; run everything synchronously to a terminal state before returning).
>
> The worker-preamble skill is the single source of truth for those rules.

The four bullets above are identical across all seven shims and are the ones this skill standardizes. **Two more bullets belong in each shim's own file, not here** — the `--label shipyard` requirement and the auto-merge/snapshot pattern — because their wording carries genuine per-mode content (e.g. fix-checks-only is the one mode that DOES `--watch` CI; fix-rebase and fix-checks-only never open a *new* PR at all; spike's bullet covers both `gh pr create` and `gh issue create`). Keep those two in the agent file, sandwiched between the lead-in and the close above.

## Mode → shim mapping

Claude Code subagents take their model from frontmatter — the `model:` field is read once per agent definition and applies to every invocation. `shipyard:issue-worker`'s router handles `mode: issue-work`; each sibling shim exists so its per-mode behavioral spec stays in one place (`agents/issue-worker/<mode>.md`).

| Mode                     | Shim agent                     | Model |
|--------------------------|--------------------------------|-------|
| `issue-work`             | `shipyard:issue-worker`        | opus  |
| `fix-checks-only`        | `shipyard:fix-checks-worker`   | opus  |
| `fix-rebase`             | `shipyard:fix-rebase-worker`   | opus  |
| `fix-main-ci`            | `shipyard:fix-main-ci-worker`  | opus  |
| `fix-failing-prs-batch`  | `shipyard:fix-pr-batch-worker` | opus  |
| `investigate`            | `shipyard:investigate-worker`  | opus  |
| `spike`                  | `shipyard:spike-worker`        | opus  |

**Per-mode model tiering is retired.** Shims previously pinned cheaper tiers per workload (Haiku for `fix-checks-only`, Sonnet for the mid-tier modes, Opus reserved for the verify gate). That optimization stopped paying: [#854](https://github.com/mattsears18/shipyard/issues/854) found Haiku mis-judging `fix-rebase` conflicts and [#1383](https://github.com/mattsears18/shipyard/issues/1383) measured it returning false-green `fix-checks-only` results. Every shim now uses the `opus` **family alias**, which the harness resolves to the newest allowed Opus — so a pin can no longer go stale across model generations the way the verify gate's `claude-opus-4-8` had. A consuming repo that wants a cheaper tier for a given mode sets `models.<mode>` in its own config; the built-in default no longer makes that choice on its behalf.

## What this skill does NOT cover

- **Frontmatter** (`name`, `description`, `model`) — each shim's registered identity as a dispatchable `subagent_type`. Never move this into a skill; the orchestrator and hand dispatches bind to the exact `subagent_type` string.
- **The per-mode behavioral spec** (`agents/issue-worker/<mode>.md`) — the issue-handling lifecycle, fix-loop semantics, trivial-conflict-or-bail policy, author-trust gating, return-string vocabulary. That's the entire point of having seven separate agents rather than one generic one.
- **The wrong-shim fail-safe string** (`blocked: wrong shim — <name> dispatched for mode <X>; refusing to guess`) — each shim's own literal name is load-bearing content, kept in the agent file.
- **The `--label shipyard` and auto-merge/snapshot bullets** in each shim's "Shared rules" section — see "Shared worker-preamble bullets" above for why these two stay per-file.
- **The per-mode model-choice reasoning sentence** (why *this* mode gets *this* tier, beyond the one-line table reason above) — each shim keeps its own fuller paragraph when it has one (e.g. `fix-rebase-worker`'s #854 postmortem, `spike-worker`'s "why no model pin" essay). The table here is the quick-reference; the fuller narrative is domain content that stays put.

When in doubt: if a line's content differs meaningfully by mode, it stays in the agent file; if it's identical scaffold regardless of mode, it belongs here.
