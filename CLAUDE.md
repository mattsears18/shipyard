# Repo-scoped rules for `mattsears18/claude-plugins`

These complement the global rules in `~/.claude/CLAUDE.md`. They apply only when working in this repo.

## Permissions

- **You always have permission to update `main` directly.** Push commits to `main`, pull/fast-forward, reset to `origin/main` — all OK without asking. The user grants this durably because this is personal tooling, not a multi-contributor codebase that needs the PR-review gate for every change. Use judgment: trivial fixes / config / docs / cleanup → push directly is fine; substantive code or spec changes → still go through a PR so CI catches regressions and the change is reviewable in isolation. When in doubt, default to a PR.
- Worktree-isolation rules from `/shipyard:do-work` (#34) still apply: orchestrated multi-agent sessions work in `.claude/worktrees/orchestrator-<session-id>` so they don't clobber the user's in-progress edits in the primary checkout. The push-to-main permission doesn't override the worktree isolation contract for `/do-work` runs.

## Label conventions

One-stop reference for the label families `/shipyard:do-work` and the broader plugin treat as load-bearing. Grouped by what the label *is*, not who applies it.

### Origin labels

Two label families mark *where* an issue came from, not what state it's in:

- `user-feedback` — issue filed via real-world feedback (raw text from a user)
- `audit:<dimension>` — issue filed by a shipyard auditor agent (`audit:security`, `audit:privacy`, `audit:dx`, etc.)

Both are applied at intake and **never removed**. They inform routing (e.g. `user-feedback` + `needs-refinement` routes to the classify+rewrite refiner branch per #145) and provide provenance for the lifetime of the issue. If we add a new issue origin in the future (e.g. Dependabot follow-ups, `/shipyard:my-turn-filed` items), it joins this class.

We intentionally don't prefix `user-feedback` with `origin:` for naming consistency — that's a breaking change with low payoff. If a sweeping rename ever happens, it's its own issue; for now, document the convention and leave the name.

### Session-stamp label

- `shipyard` (renamed from `do-work` in 1.2.0) — the orchestrator session stamp on every PR it produces. Hooks, the orphan-triage sweep, the failing-PR scan, and the end-of-session summary all key off it. Don't remove it.

### State labels (auto-managed)

These reflect transient state and are managed by `/shipyard:do-work`:

- `blocked` — added when an agent returns `blocked: <reason>`. The orchestrator never removes it on its own; the step 3d.2 sweep in `plugins/shipyard/commands/do-work.md` auto-clears it on referential `Blocked by #N` resolution, but otherwise it stays until a human or follow-up issue clears it.
- `ci-blocked` — added when a PR exhausts the 3-attempt fix-checks cap (the orchestrator's circuit breaker). The step 3d.1 sweep in `plugins/shipyard/commands/do-work.md` auto-clears it when a new commit lands on the PR's head branch (the "stuck" premise no longer holds), letting shipyard retry.

### Gate labels (intake → human review)

- `needs-refinement` — **generic pipeline gate** (semantics generalized in 1.3.28, [#145](https://github.com/mattsears18/claude-plugins/issues/145)): "this issue isn't ready for `/shipyard:do-work` dispatch yet — a refiner needs to process it first." Applied conditionally at intake by `.github/workflows/intake-refinement-gate.yml` (external authors, bodies with `## Open questions` headings, bare one-liners, bot-authored). `/shipyard:refine-issues` (renamed from `/shipyard:refine-feedback` — alias preserved) branches by source signal: user-feedback gets classify+rewrite, open-questions get resolve-defaults, anything else falls through to `escalate-to-triage` (which swaps `needs-refinement` for `needs-triage`).
- `needs-human-review` — **decoupled** from `needs-refinement` in 1.3.28. Specifically a human sign-off gate: applied only by the user-feedback classify+rewrite branch of `/shipyard:refine-issues`, the `external-author-gate.yml` workflow, and `issue-worker.md` step 6 for external-author PRs. The resolve-defaults and escalate-to-triage branches do NOT apply it — trusted-author issues that pass through resolve-defaults become dispatch-eligible immediately.
- `needs-triage` — fall-through label applied by `/shipyard:refine-issues`' escalate-to-triage branch when no refiner rule matches. `/do-work` excludes it from dispatch; `/shipyard:my-turn` surfaces it for human triage.
