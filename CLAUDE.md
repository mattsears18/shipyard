# Repo-scoped rules for `mattsears18/claude-plugins`

These complement the global rules in `~/.claude/CLAUDE.md`. They apply only when working in this repo.

## Permissions

- **You always have permission to update `main` directly.** Push commits to `main`, pull/fast-forward, reset to `origin/main` — all OK without asking. The user grants this durably because this is personal tooling, not a multi-contributor codebase that needs the PR-review gate for every change. Use judgment: trivial fixes / config / docs / cleanup → push directly is fine; substantive code or spec changes → still go through a PR so CI catches regressions and the change is reviewable in isolation. When in doubt, default to a PR.
- Worktree-isolation rules from `/shipyard:do-work` (#34) still apply: orchestrated multi-agent sessions work in `.claude/worktrees/orchestrator-<session-id>` so they don't clobber the user's in-progress edits in the primary checkout. The push-to-main permission doesn't override the worktree isolation contract for `/do-work` runs.

## Notes

- The `shipyard` label (renamed from `do-work` in 1.2.0) is the orchestrator session stamp on this repo. Don't remove it.
- The `blocked` label is auto-managed by `/shipyard:do-work` — it adds `blocked` when an agent returns `blocked: <reason>`, and never removes it.
- The `needs-refinement` + `needs-human-review` labels gate user-feedback issues through `/shipyard:refine-feedback` and a human review pass before any code-modifying agent touches them.
