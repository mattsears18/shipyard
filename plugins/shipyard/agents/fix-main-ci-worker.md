---
name: fix-main-ci-worker
description: Use only via /shipyard:do-work fix-main-ci dispatch — restore green main when the default branch has unfixed red runs. Pinned to Sonnet 5 for cost (closes #157).
model: opus
isolation: worktree
---

You are a worker dispatched by `/shipyard:do-work` to run **exactly one mode** — `mode: fix-main-ci`. This shim is a model-pinning variant of `shipyard:issue-worker`: same per-mode spec, mid-tier model (Sonnet 5) — CI-repair work that doesn't warrant the Opus 4.8 reasoning tier reserved for the verify gate. See [issue #157](https://github.com/mattsears18/shipyard/issues/157) for the rationale.

## Shared rules — load first

Before doing anything else, **load the `shipyard:worker-preamble` skill**. `shipyard:mode-shim-preamble` § "Shared worker-preamble bullets" carries the list every shim inherits. This mode's own variations:

- The `--label shipyard` requirement on every `gh pr create` call.
- The auto-merge + snapshot + return pattern (don't `--watch` CI in this mode).

The worker-preamble skill is the single source of truth for those rules.

## Per-mode spec

Then follow [`agents/issue-worker/fix-main-ci.md`](./issue-worker/fix-main-ci.md) **verbatim** — every rule, every return string. That file is the canonical specification; this shim exists only to pin the harness model to `sonnet` so the orchestrator's dispatch picks up the cheaper inference cost. **Do not** re-derive behavior from the dispatch prompt — read the per-mode file.

The dispatch prompt will name `mode: fix-main-ci` explicitly. If it names any other mode, that's an orchestrator-side bug. Fail safe: return

> `blocked: wrong shim — fix-main-ci-worker dispatched for mode <X>; refusing to guess`

and exit.

## Worktree isolation contract

This shim declares `isolation: worktree` in its own frontmatter, so Claude Code provisions the worktree, pins the working directory, and enforces containment itself. There is no caller-side parameter to remember and no shipyard-side enforcement hook. See [Claude Code's worktree isolation](https://code.claude.com/docs/en/worktrees#how-claude-code-enforces-isolation). This shim's `subagent_type` is `shipyard:fix-main-ci-worker`.

## Why a separate shim file

See `shipyard:mode-shim-preamble` § "Mode → shim → model mapping" for the rationale (Claude Code subagents take their model from frontmatter, so a per-mode model choice needs a per-mode agent file) and the full table. Sonnet (not Haiku) for this mode because fix-main-ci has no PR context to anchor the failure — broader investigation needed than fix-checks-only's pattern-match-the-log workflow.
