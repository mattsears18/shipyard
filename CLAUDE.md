# Repo-scoped rules for `mattsears18/shipyard`

These complement the global rules in `~/.claude/CLAUDE.md`. They apply only when working in this repo.

## Permissions

- **You always have permission to update `main` directly.** Push commits to `main`, pull/fast-forward, reset to `origin/main` — all OK without asking. The user grants this durably because this is personal tooling, not a multi-contributor codebase that needs the PR-review gate for every change. Use judgment: trivial fixes / config / docs / cleanup → push directly is fine; substantive code or spec changes → still go through a PR so CI catches regressions and the change is reviewable in isolation. When in doubt, default to a PR.
- Worktree-isolation rules from `/shipyard:do-work` (#34) still apply: orchestrated multi-agent sessions work in `.claude/worktrees/orchestrator-<session-id>` so they don't clobber the user's in-progress edits in the primary checkout. The push-to-main permission doesn't override the worktree isolation contract for `/do-work` runs.

## Release process

**ALWAYS cut a release when a PR merges.** No exceptions for "trivial" docs-only PRs — `/shipyard:update` and the marketplace only see what's in `plugin.json`'s `version` field. A PR that merges without a version bump is invisible to every existing installation, so the work might as well not have shipped.

What "cut a release" means in this repo:

1. Bump `plugins/shipyard/.claude-plugin/plugin.json` `version` (semver — patch bump for fixes / docs / config; minor for new features; major when the user explicitly says so).
2. Add a new `### <version> — <YYYY-MM-DD>` entry at the top of the `## shipyard` section in `CHANGELOG.md`. Match the prose style of recent entries: one summary paragraph leading with what changed and why, then a bullet list naming the specific files / surfaces touched. Reference the closed issue numbers + PR number inline.
3. Commit the bump + CHANGELOG entry. Per the [Permissions section](#permissions) above, this can land directly on `main` (docs + config — pre-authorized) — no separate PR needed for the release bump itself.

There are **no git tags and no GitHub releases** — `plugin.json` is the canonical version surface, and the marketplace checks it directly. Don't introduce a tag/release workflow without asking; the current shape is intentional.

If multiple PRs merge in a tight window without each one cutting its own release (i.e., catch-up situation), bundle them into one version bump with one CHANGELOG entry that names each PR's contribution. The "one release per PR" rule is the steady-state aspiration, not a rigid requirement that forces tiny patch-bump churn.

## Label conventions

One-stop reference for the label families `/shipyard:do-work` and the broader plugin treat as load-bearing. Grouped by what the label *is*, not who applies it.

### Origin labels

Two label families mark *where* an issue came from, not what state it's in:

- `user-feedback` — issue filed via real-world feedback (raw text from a user)
- `audit:<dimension>` — issue filed by a shipyard auditor agent (`audit:security`, `audit:privacy`, `audit:dx`, etc.)

Both are applied at intake and **never removed**. They inform routing (e.g. `user-feedback` + `needs-refinement` routes to the classify+rewrite refiner branch per #145) and provide provenance for the lifetime of the issue. If we add a new issue origin in the future (e.g. Dependabot follow-ups, `/shipyard:my-turn-filed` items), it joins this class.

We intentionally don't prefix `user-feedback` with `origin:` for naming consistency — that's a breaking change with low payoff. If a sweeping rename ever happens, it's its own issue; for now, document the convention and leave the name.

### Session-stamp label

- `shipyard` — the orchestrator session stamp on every PR it produces. Hooks, the orphan-triage sweep, the failing-PR scan, and the end-of-session summary all key off it. Don't remove it.

### State labels (auto-managed)

These reflect transient state and are managed by `/shipyard:do-work`. Both live in the `blocked:*` namespace so the label itself communicates the block category without reading the comment trail.

- `blocked:agent` — added when an agent returns `blocked: <reason>`. The orchestrator never removes it on its own; the step 3d.2 sweep in `plugins/shipyard/commands/do-work.md` auto-clears it on referential `Blocked by #N` resolution, but otherwise it stays until a human or follow-up issue clears it.
- `blocked:ci` — added when a PR exhausts the 3-attempt fix-checks cap (the orchestrator's circuit breaker). The step 3d.1 sweep in `plugins/shipyard/commands/do-work.md` auto-clears it when a new commit lands on the PR's head branch (the "stuck" premise no longer holds), letting shipyard retry.

Reserves space for future categories (`blocked:external` for upstream / vendor blocks, `blocked:design` for design-gated work) — those aren't created proactively; add them when the first instance appears, per the `audit:*` precedent.

### Gate labels (intake → human review)

- `needs-refinement` — **generic pipeline gate**: "this issue isn't ready for `/shipyard:do-work` dispatch yet — a refiner needs to process it first." Applied conditionally at intake by `.github/workflows/intake-refinement-gate.yml` (external authors, bodies with `## Open questions` headings, bare one-liners, bot-authored). `/shipyard:refine-issues` branches by source signal: user-feedback gets classify+rewrite, open-questions get resolve-defaults, anything else falls through to `escalate-to-triage` (which swaps `needs-refinement` for `needs-triage`).
- `needs-human-review` — a human sign-off gate, decoupled from `needs-refinement`: applied only by the user-feedback classify+rewrite branch of `/shipyard:refine-issues`, the `external-author-gate.yml` workflow, and `issue-worker.md` step 6 for external-author PRs. The resolve-defaults and escalate-to-triage branches do NOT apply it — trusted-author issues that pass through resolve-defaults become dispatch-eligible immediately.
- `needs-triage` — fall-through label applied by `/shipyard:refine-issues`' escalate-to-triage branch when no refiner rule matches. `/do-work` excludes it from dispatch; `/shipyard:my-turn` surfaces it for human triage.

### Epic-decomposition labels (scope-agent handoff → auto-shard)

A two-label pair drives the epic-decomposition pipeline (`needs-decomposition` is the trigger surface, `tracking` is the post-shard parent marker). Both are in `/do-work`'s dispatch-exclusion set.

- `needs-decomposition` — applied by `do-work/setup.md` step 6's Deferred recording path when a scope agent returns `confirmed-non-shippable-as-single-PR` (#498). It surfaces an epic as a human-handoff: `/do-work` stops re-scoping it every session and `/my-turn` surfaces it. `/shipyard:decompose-epic` (#501) consumes this label — for `Multi-PR sequence:` / `Missing dependency:` evidence classes it auto-shards the epic into dispatch-ready sub-issues (an ordered `Blocked by #<sibling>` chain), then swaps the label to `tracking` on the parent; for non-mechanical classes (`Multi-service coordination:`, `Body cites <artifact>:`) it leaves `needs-decomposition` in place for the human. Idempotency sentinel: `<!-- do-work-decompose-agent -->`.
- `tracking` — applied by `/shipyard:decompose-epic` to a parent epic once it has been auto-sharded into sub-issues (#501). The parent is no longer a workable leaf — its children carry the dispatchable units — so `tracking` keeps it out of `/do-work` dispatch (enumerated in the step-4 exclusion set alongside `needs-decomposition`). The parent stays OPEN as the tracking umbrella; closing it once all children land is a human's call.

## Configuration (`shipyard.config.json` + layered overrides)

Shipyard runs against a 4-layer config. Effective config is the deep-merge of all four layers in order — later wins, arrays are replaced (not concatenated), and objects merge key-by-key recursively.

| Layer | Path | Committed? | Purpose |
|---|---|---|---|
| 1. Built-in defaults | hardcoded in `plugins/shipyard/scripts/shipyard-config.sh` | n/a | Always present; bottom layer |
| 2. User-global | `~/.shipyard/config.json` | no (per-user) | Default models, default auto-merge policy, cost-tracking opt-out — across every repo (set via the `default_*` / `cost_tracking_enabled` aliases, remapped onto canonical paths on load) |
| 3. Repo-level | `<repo>/shipyard.config.json` | **yes** | Shared policy, reviewable in PRs; opt-in surface for `/shipyard:do-work` |
| 4. Personal override | `<repo>/.shipyard/config.local.json` | no (gitignored) | Per-repo personal overrides without touching committed policy |

### Opt-in contract

`/shipyard:do-work` checks for `<repo>/shipyard.config.json` at session start (step 0.4):

- **Present**: load the merged effective config and dispatch normally.
- **Missing**: warn and fall back to built-in defaults. The hard refusal gate is deferred until `/shipyard:init` adoption is widespread. Pass `--strict` to opt into the future hard-refusal behavior today.

### Bootstrap

```bash
/shipyard:init                              # interactive
/shipyard:init --auto-merge trusted-only    # non-interactive with one flag
/shipyard:init --dry-run                    # preview without writing
```

Creates `shipyard.config.json` with sensible defaults, appends `.shipyard/` to `.gitignore`, validates against the schema before the write commits.

### Managing config post-bootstrap

```bash
/shipyard:config show                       # effective + source-layer annotation
/shipyard:config show --layer repo          # one layer in isolation
/shipyard:config get auto_merge.policy      # one field
/shipyard:config set auto_merge.policy never           # writes to repo (committed)
/shipyard:config set auto_merge.policy never --local   # writes to .shipyard/config.local.json
/shipyard:config set models.issue_work claude-opus-4-7 --global  # writes to ~/.shipyard/config.json
/shipyard:config edit [--local|--global]    # open in $EDITOR
/shipyard:config validate                   # schema-check all layers
```

Schemas live at `plugins/shipyard/schemas/shipyard.config.schema.json` (repo + local) and `plugins/shipyard/schemas/shipyard.user-config.schema.json` (user-global). Every load and every `set` validates the result before it lands; typos surface as clear errors rather than silent ignores.

### Don't put secrets in any config layer

The schema rejects keys matching `/token|secret|api_key|password|credential/i` regardless of where they appear. Move secrets to environment variables — even `.shipyard/config.local.json` (which is gitignored) is treated as if it could land in a backup or paste-buffer leak.

## Cost-tracking ledger (`~/.shipyard/cost-history.jsonl`)

Persistent cross-session token-usage records live at `~/.shipyard/`. Every `/shipyard:do-work` session's end-of-session cleanup flushes a rolled-up record into this ledger before reaping the per-session state file.

| Path | Format | Lifetime | Contents |
|---|---|---|---|
| `~/.shipyard/cost-history.jsonl` | append-only JSONL | persistent | One line per completed session: id, repo, started/ended timestamps, token totals, by-model rollup, by-mode rollup |
| `~/.shipyard/cost-history-issues.jsonl` | append-only JSONL | persistent | One line per (repo, issue_number); reader dedupes by latest `last_touched` |
| `~/.shipyard/sessions/<id>.json` | atomic JSON | transient | Per-session live state; reaped at end-of-session |
| `~/.shipyard/flake-registry.jsonl` | append-only JSONL | persistent | One line per flake event (repo, pr, workflow, job, test, session, timestamp); cross-PR/cross-session flake registry (#378) |

Use `/shipyard:cost report` to query the persistent ledger. `--last 30d` (default), `--repo <owner/name>`, `--by-issue`, `--by-mode`, `--by-model`, `--top N`, `--trend`, and `--format markdown|csv|json` compose. `/shipyard:cost reset` is destructive but safe (moves to `.bak.<ts>` instead of `rm`); `/shipyard:cost export --to <path>.tar.gz` produces a portable backup.

The ledger is local-only — shipyard never uploads it anywhere. To opt a specific repo out of cost-tracking, set `cost_tracking.enabled: false` for that repo; to opt out across every repo from the user-global layer, set `cost_tracking_enabled: false` in `~/.shipyard/config.json` (it remaps onto `cost_tracking.enabled` on load — a repo-level value still wins). The ledger files are safe to `rm`; deletion only forfeits historical reports.

The **flake registry** at `~/.shipyard/flake-registry.jsonl` (the cross-PR/cross-session flake ledger from #378) follows the same local-only posture: it lives entirely on the local filesystem and is never uploaded anywhere. It records non-PII CI metadata (repo, PR, workflow, job, test id, session id, timestamp), but on a private repo that still accumulates a cross-session record of your test names and PR numbers, so it stays local by design. Collection is **off by default** — flip `flake_registry.enabled: true` to opt in. To opt back out, set `flake_registry.enabled: false`. `flake-registry.sh reset` moves the file to `.bak.<ts>` (recoverable, not `rm`'d); the file is otherwise safe to `rm`, which only forfeits the historical flake-rate window.
