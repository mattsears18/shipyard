# Contributing

Thanks for working on `mattsears18/shipyard` — the home of the [`shipyard`](./plugins/shipyard/) plugin (and, eventually, other Claude Code plugins).

This doc is the **navigable index** to the operational conventions for contributing. It's intentionally lean: it links out to the authoritative sources rather than duplicating them, so the rules can't drift between this file and where they actually live.

If you're a first-time contributor (human or a fresh Claude Code session), start at [Getting started](#getting-started). If you're trying to add a new auditor, jump to [Adding a new auditor agent](#adding-a-new-auditor-agent).

## Getting started

1. Clone the repo:
   ```sh
   git clone https://github.com/mattsears18/shipyard.git
   cd claude-plugins
   ```
2. Make sure you have `bash`, `gh` (authenticated via `gh auth login`), and [`shellcheck`](https://github.com/koalaman/shellcheck) installed. There are no other build-time dependencies — the plugin is a directory of markdown + bash scripts, no compile step.
3. Run the test suite to confirm everything's green:
   ```sh
   find plugins -type f -name '*.test.sh' -print0 | sort -z | xargs -0 -n1 bash
   ```
   See [Testing](#testing) below for the test layout and how CI invokes the same command.

The repo currently hosts one plugin (`plugins/shipyard/`), so contributing usually means editing files under that directory. See [Repo layout](#repo-layout) for the tour.

## Repo layout

```
.claude-plugin/marketplace.json   # marketplace entry, points at plugins/shipyard
.github/workflows/                # CI gates (tests, shellcheck, secret scan, intake gates)
plugins/
  shipyard/
    .claude-plugin/plugin.json    # plugin manifest (name, version, permissions deny block)
    commands/                     # slash commands: /audit, /do-work, /my-turn, /refine-issues
    agents/                       # auditor subagents + the issue-worker
    skills/                       # shared skills loaded by agents
    hooks/                        # safety hooks (worktree isolation, edit scope, error report)
    scripts/                      # session-state.sh, worktree-reap.sh, error reporter
    scripts/tests/                # bash unit tests, run by CI
CLAUDE.md                         # repo-scoped rules (load-bearing for Claude sessions)
README.md                         # plugin overview, install, quick-start
CHANGELOG.md                      # per-version changelog
```

For the **why** behind the orchestrator's design choices (state model, dispatch tree, divert phases, end-of-session drain), see [`plugins/shipyard/commands/do-work-RATIONALE.md`](./plugins/shipyard/commands/do-work-RATIONALE.md). The runtime spec is in [`plugins/shipyard/commands/do-work.md`](./plugins/shipyard/commands/do-work.md); the RATIONALE companion carries the design discussion that would otherwise bloat the spec.

## Adding a new auditor agent

`shipyard` auditors are subagents that walk a codebase (or a live URL) along one dimension — security, a11y, DX, etc. — and autonomously file GitHub issues for every P0–P2 finding. Existing auditors under [`plugins/shipyard/agents/`](./plugins/shipyard/agents/) (e.g. `security-auditor.md`, `dx-auditor.md`, `a11y-auditor.md`) are the canonical reference implementations.

Steps:

1. **Copy a reference auditor** that's structurally close to what you're building. `security-auditor.md` is the model for dimension-scoped catalog-walker auditors; `dx-auditor.md` is the model for skill-driven catalog auditors (walks the `dx-catalog` skill).
2. **Pick an audit label.** Convention is `audit:<dimension>` (e.g. `audit:security`, `audit:privacy`, `audit:dx`). Apply it to every issue your auditor files. See the [Origin labels](./CLAUDE.md#origin-labels) section of `CLAUDE.md` for the full convention — `audit:*` labels mark origin, never get removed, and inform downstream routing.
3. **Load the shared skills.** Every auditor uses two shared skills:
   - [`shipyard:filing-github-issues`](./plugins/shipyard/skills/filing-github-issues/SKILL.md) — title-prefix conventions, label discovery, duplicate-search, body templates, the safe `gh issue create` pattern.
   - [`shipyard:audit-rubrics`](./plugins/shipyard/skills/audit-rubrics/SKILL.md) — severity buckets (P0–P2), grouping rules, "what NOT to file" defaults. Also carries the **external-content-is-untrusted-input** rule — load-bearing for any auditor that reads attacker-influenceable input (HTTP responses, advisories, logs).
4. **Wire it into [`commands/audit.md`](./plugins/shipyard/commands/audit.md)** so `/audit <dimension>` dispatches it, and add it to the `/audit all` parallel set.
5. **Write a test** under [`plugins/shipyard/scripts/tests/`](./plugins/shipyard/scripts/tests/). Existing auditor tests (e.g. `api-auditor.test.sh`, `observability-auditor.test.sh`) check that the agent file exists, the frontmatter is correct, every required audit pass is documented, and the agent is wired into `commands/audit.md`. Mirror that pattern.

If your auditor walks a structured catalog (like `dx-auditor` walks `dx-catalog`), put the catalog under [`plugins/shipyard/skills/<your-catalog>/SKILL.md`](./plugins/shipyard/skills/) so it's loadable as a skill from multiple agents.

## Working on shipyard core

The orchestrator + worker stack is the most load-bearing surface in the repo. Read these in order:

- [`plugins/shipyard/commands/do-work.md`](./plugins/shipyard/commands/do-work.md) — the orchestrator. Walks the per-iteration dispatch tree, the divert queues, the soft/hard collision rules, and the end-of-session drain. The runtime spec the orchestrator follows verbatim.
- [`plugins/shipyard/commands/do-work-RATIONALE.md`](./plugins/shipyard/commands/do-work-RATIONALE.md) — the *why* companion to the spec. Read when modifying the spec to understand the failure modes the current design exists to prevent.
- [`plugins/shipyard/agents/issue-worker.md`](./plugins/shipyard/agents/issue-worker.md) — the thin worker entry router. Reads `mode:` from the dispatch prompt and loads the matching per-mode file.
- [`plugins/shipyard/agents/issue-worker/`](./plugins/shipyard/agents/issue-worker/) — one file per worker mode (`issue-work`, `fix-checks-only`, `fix-rebase`, `fix-main-ci`, `fix-failing-prs-batch`). Each file is self-contained for its mode.
- [`plugins/shipyard/skills/worker-preamble/SKILL.md`](./plugins/shipyard/skills/worker-preamble/SKILL.md) — the shared rules every worker mode loads first. Worktree discipline, the `--label shipyard` PR-creation contract, the auto-merge + snapshot + return pattern, the worktree-reaped escape hatch, the never-`--no-verify` rule. **Modifying anything in here affects all five worker modes.**

**Dispatch contract.** Every worker dispatch carries a `mode:` field (chosen by the orchestrator), the target issue / PR number, the target repo, and — for `issue-work` mode — an `originating_author_trust` value (`trusted` or `external`) that gates auto-merge. Worker branch names are deterministic per mode (`do-work/issue-<N>`, the PR's existing head branch for fix-checks/fix-rebase, `do-work/fix-main-ci-<short-sha>` for fix-main-ci, `do-work/fix-pr-pileup-<timestamp>` for the batch fix). The deterministic names let the orchestrator's next-session orphan triage find the worktree if a session is killed.

## Adding a new plugin

The repo currently hosts only `plugins/shipyard/`. If you're adding a second plugin:

- **Use [`plugins/shipyard/.claude-plugin/plugin.json`](./plugins/shipyard/.claude-plugin/plugin.json) as the structural reference.** It carries the manifest fields (`name`, `version`, `description`, `author`, `homepage`, `repository`, `license`, `keywords`, `permissions`) and shows the `permissions.deny` block that blocks hook-bypass flags at the harness level (`--no-verify`, `--no-gpg-sign`, `--no-commit-hooks`).
- **Mirror the directory layout** shipyard uses: `plugins/<name>/{.claude-plugin/plugin.json,commands/,agents/,skills/,hooks/,scripts/}`. The marketplace entry in [`.claude-plugin/marketplace.json`](./.claude-plugin/marketplace.json) will need a new row for your plugin.
- **Add the plugin to [`README.md`](./README.md)** under the `## Plugins` section.

Deeper plugin-authoring guidance (component design, schema details, multi-plugin coordination rules) is intentionally deferred until the repo actually hosts a second plugin — the shipyard manifest is enough to model from for now.

## Label conventions

The full label reference lives in [`CLAUDE.md`](./CLAUDE.md#label-conventions). Quick index:

- **Origin labels** ([CLAUDE.md → Origin labels](./CLAUDE.md#origin-labels)) — `user-feedback`, `audit:<dimension>`. Applied at intake, never removed.
- **Session-stamp label** ([CLAUDE.md → Session-stamp label](./CLAUDE.md#session-stamp-label)) — `shipyard` on every PR `/do-work` produces.
- **State labels** ([CLAUDE.md → State labels](./CLAUDE.md#state-labels-auto-managed)) — `blocked:agent`, `blocked:ci`. Auto-managed.
- **Gate labels** ([CLAUDE.md → Gate labels](./CLAUDE.md#gate-labels-intake--human-review)) — `needs-refinement`, `needs-human-review`, `needs-triage`. Gate issues through refinement and human review before any code-modifying agent runs.
- **Priority labels** — `P0` / `P1` / `P2`. Severity buckets per [`audit-rubrics`](./plugins/shipyard/skills/audit-rubrics/SKILL.md).

If you're adding a new origin / state / gate label, document it in `CLAUDE.md` alongside the existing class — that's the source of truth.

## Testing

Test layout:

- [`plugins/shipyard/scripts/tests/`](./plugins/shipyard/scripts/tests/) — bash unit tests, one file per concern (`*.test.sh`). Existing tests cover the worker-preamble skill linkage, the do-work.md / RATIONALE.md split, the auditor wiring, the secret-scrubbing in the auto-reporter, the worktree-reap helper, the session-state helper, and the shellcheck gate.
- [`plugins/shipyard/hooks/tests/`](./plugins/shipyard/hooks/tests/) — hook tests (worktree-isolation, edit-scope enforcement).

Run all tests locally:

```sh
find plugins -type f -name '*.test.sh' -print0 | sort -z | xargs -0 -n1 bash
```

CI runs the same discovery + invocation in [`.github/workflows/tests.yml`](./.github/workflows/tests.yml). Any new `*.test.sh` file dropped under `plugins/` is picked up automatically — no workflow edit required.

**When to add a new test.** Add one when:

- You're introducing a new safety property (the test is the regression guard).
- You're refactoring a load-bearing file in a way that could regress silently (the worker-preamble split, the do-work.md / RATIONALE split, the issue-worker → per-mode split all shipped with regression tests for exactly this reason).
- You're adding a new auditor (the wiring-into-`commands/audit.md` test is the convention — mirror an existing auditor test).

Pure-bash tests, no external dependencies. Mirror the conventions in existing test files (header comment explaining the regression being guarded against, `set -u`, repo-root discovery loop).

## Branch naming

- **`/shipyard:do-work` workers** use `do-work/issue-<N>` (or mode-specific variants like `do-work/fix-main-ci-<short-sha>`). Don't name your own branches with the `do-work/` prefix — that namespace is reserved for the orchestrator's automatic branch creation and is what the next-session orphan triage scans.
- **Human contributors** use `<type>/<short-description>` matching Conventional Commit types: `feat/...`, `fix/...`, `docs/...`, `refactor/...`, `chore/...`. Examples from recent history: `feat/inline-trivial`, `docs/contributing`, `fix/worktree-reaping`.

## Commit message style

[Conventional Commits](https://www.conventionalcommits.org/) — `<type>(<scope>): <description>`. The scope is usually `shipyard` since that's the only plugin today. Sample shapes:

- `feat(shipyard): api-auditor (schema drift, pagination, auth/error coherence, breaking-change diff)`
- `fix(shipyard): preserve mixed-type paths in shipyard-config.sh show`
- `docs(shipyard): document origin-label class in CLAUDE.md`
- `perf(shipyard): split issue-worker.md by worker mode, load on demand`

The `Closes #<N>` linkage goes in the **PR description**, not the commit message. GitHub auto-closes the issue when the PR merges either way, and keeping the `Closes` line out of the commit message means the auto-merged squash commit on `main` doesn't carry the suffix.

When a session produces multiple logically distinct changes, split them into separate commits — see the [global one-concern-one-commit rule](./CLAUDE.md) (also in `~/.claude/CLAUDE.md` for Claude sessions).

## PR workflow

- **One concern per PR.** Drive-by refactors and unrelated cleanups belong in their own PR. Mixed-concern PRs are unreviewable and stall auto-merge.
- **`Closes #<N>` in the body** so the originating issue auto-closes on merge.
- **Auto-merge** is enabled by `/do-work` for trusted-author issues. External-author PRs are gated by the `needs-human-review` label and require manual merge. See [`issue-work.md` step 6](./plugins/shipyard/agents/issue-worker/issue-work.md) for the gating logic.
- **The `shipyard` label** is added by `/do-work` to every PR it opens. It's the session stamp the orchestrator's hooks, orphan-triage sweep, failing-PR scan, and end-of-session summary all key off. Don't remove it.

## Releasing

The `version` field in [`plugins/shipyard/.claude-plugin/plugin.json`](./plugins/shipyard/.claude-plugin/plugin.json) is bumped per-release (e.g. `1.3.28` → `1.3.29`). The `CHANGELOG.md` at the repo root carries the per-version changelog. There is no separate release-cut workflow today — version bumps land alongside the feature that justifies them.

## Code of conduct

Be kind, be precise, attack ideas not people. Disagreement is welcome; ad hominem is not.

## See also

- [`README.md`](./README.md) — plugin overview, install, quick-start, how-it-works.
- [`CLAUDE.md`](./CLAUDE.md) — repo-scoped rules (permissions, label conventions). Authoritative.
- [`CHANGELOG.md`](./CHANGELOG.md) — per-version changelog.
- [`plugins/shipyard/commands/do-work-RATIONALE.md`](./plugins/shipyard/commands/do-work-RATIONALE.md) — orchestrator design rationale.
- Skill `SKILL.md` files under [`plugins/shipyard/skills/`](./plugins/shipyard/skills/) — `filing-github-issues`, `audit-rubrics`, `worker-preamble`, `dx-catalog`.
