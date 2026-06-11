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

Both are applied at intake and **never removed**. They inform routing (e.g. the `user-feedback` label is the source signal that routes an issue to `/refine-issues`' classify+rewrite branch per #145) and provide provenance for the lifetime of the issue. If we add a new issue origin in the future (e.g. Dependabot follow-ups, `/shipyard:my-turn-filed` items), it joins this class.

We intentionally don't prefix `user-feedback` with `origin:` for naming consistency — that's a breaking change with low payoff. If a sweeping rename ever happens, it's its own issue; for now, document the convention and leave the name.

### Session-stamp label

- `shipyard` — the orchestrator session stamp on every PR it produces. Hooks, the orphan-triage sweep, the failing-PR scan, and the end-of-session summary all key off it. Don't remove it.

### State labels (auto-managed)

These reflect transient state and are managed by `/shipyard:do-work`. Both live in the `blocked:*` namespace so the label itself communicates the block category without reading the comment trail.

- `blocked:agent` — added when an agent returns `blocked: <reason>`. The orchestrator never removes it on its own; the step 3d.2 sweep in `plugins/shipyard/commands/do-work.md` auto-clears it on referential `Blocked by #N` resolution, but otherwise it stays until a human or follow-up issue clears it.
- `blocked:ci` — added when a PR exhausts the 3-attempt fix-checks cap (the orchestrator's circuit breaker). The step 3d.1 sweep in `plugins/shipyard/commands/do-work.md` auto-clears it when a new commit lands on the PR's head branch (the "stuck" premise no longer holds), letting shipyard retry.

Reserves space for future categories (`blocked:external` for upstream / vendor blocks, `blocked:design` for design-gated work) — those aren't created proactively; add them when the first instance appears, per the `audit:*` precedent.

### Gate labels (intake → human review)

> **Binary-backlog migration (#515).** The long-term north star is a strictly binary issue backlog: every open issue is either workable-by-`/do-work` (no gate label) or workable-by-human (`needs-human-review` → surfaced by `/my-turn`). Phase 1 (#515) folded the **inert** design-gate label `needs-design` into `needs-human-review` — a pure dispatch-exclusion + `/my-turn`-surfacing label with no auto-processing machinery, so collapsing it is a lossless rename. **Phase 2 (#519)** folded the `needs-decomposition` / `tracking` epic-decomposition pair into `needs-human-review` — the catch is that pair carries **live machinery** (`/decompose-epic` consumes it), so the fold preserves the machinery by re-keying `/decompose-epic`'s candidate fetch onto `needs-human-review` **+ the `<!-- do-work-needs-decomposition -->` body marker** (stamped on the scope-agent diagnosis comment) rather than a dedicated label. **Phase 2 also eliminated `needs-refinement` entirely (#520)** — rather than fold it into the inert human-gate (which would strand refinable work in the human queue, the hazard below), the persisted refinement gate was retired: `/refine-issues` now detects refinement candidates by a **live source-signal scan** (`user-feedback` label / `## Open questions` heading / bot author) as a pre-dispatch pass, so there's no cached gate state to drift or to exclude from the dispatch fetch; only the genuine no-automated-path fall-through subset lands on `needs-human-review`. The remaining label that still carries **live auto-clearing machinery without a body-marker re-key** stays **separate** because folding it into the inert `needs-human-review` would silently break that machinery (never route auto-retryable/auto-processed work to the human queue): `blocked:agent-hard` (auto-cleared by the referential `Blocked by #N` sweeps). `needs-triage` is **kept as a transitional parking label** — its elimination depends on the investigate-then-fix worker mode (#514) routing untriaged/bot issues to investigate-mode instead of parking them, and #514's orchestrator runtime integration is phase-2 (not yet live). Folding the remaining labels is tracked as follow-up issues.

- `needs-refinement` (**eliminated #520**) — formerly a persisted "this issue isn't ready for `/shipyard:do-work` dispatch yet" pipeline gate applied at intake. Retired in the binary-backlog phase-2 slice: `/shipyard:refine-issues` now detects refinement candidates by a **live source-signal scan** over open issues (`user-feedback` label → classify+rewrite, `## Open questions` heading → resolve-defaults, bot-authored / unrecognized → fall-through to `needs-human-review`) as a pre-dispatch pass, with no persisted label. The scan recomputes candidacy every run, so it never drifts out of sync with the issue body the way a cached gate label did. The GitHub `needs-refinement` label object is left in place for a manual cleanup; nothing applies or reads it. Security is unchanged — external-author issues still get `needs-human-review` from the separate `external-author-gate.yml`.
- `needs-human-review` — a human sign-off gate: applied by the user-feedback classify+rewrite branch of `/shipyard:refine-issues`, the `/refine-issues` **fall-through branch** (the no-automated-path refinement subset, per #520), the `external-author-gate.yml` workflow, `issue-worker.md` step 6 for external-author PRs, and `do-work/setup.md` step 6's Deferred recording path for confirmed-non-shippable epics. The resolve-defaults branch does NOT apply it — trusted-author issues that pass through resolve-defaults become dispatch-eligible immediately. **As of #515 this label also subsumes the former `needs-design` design-gate** — a design-gated issue now carries `needs-human-review`; `/do-work` excludes it from dispatch and `/my-turn` surfaces it. **As of #519 it also subsumes the former `needs-decomposition` / `tracking` epic-decomposition pair** — a confirmed-non-shippable epic now carries `needs-human-review` plus the `<!-- do-work-needs-decomposition -->` body marker (see the Epic-decomposition section below); the marker is what lets `/decompose-epic` find epic handoffs among the broader `needs-human-review` pool.
- `needs-triage` — fall-through label applied by `/shipyard:refine-issues`' escalate-to-triage branch when no refiner rule matches. `/do-work` excludes it from dispatch; `/shipyard:my-turn` surfaces it for human triage. **Transitional parking label** (#515) — kept until #514's investigate-then-fix runtime routing ships and can classify untriaged/bot issues instead of parking them; do NOT fold it into `needs-human-review` yet.

### Epic-decomposition handoff (scope-agent handoff → auto-shard)

As of #519's binary-backlog fold, the epic-decomposition pipeline rides **`needs-human-review` + the `<!-- do-work-needs-decomposition -->` body marker** — there is no longer a dedicated `needs-decomposition` label or a `tracking` parent marker (both folded into `needs-human-review`). The `needs-human-review` label is what `/do-work` excludes from dispatch (it's in the step-4 exclusion set); the body marker is the discriminator that lets `/decompose-epic` separate epic handoffs from every *other* `needs-human-review` issue (refined user-feedback, external-author, design-gated).

- **Trigger:** `do-work/setup.md` step 6's Deferred recording path applies `needs-human-review` AND stamps `<!-- do-work-needs-decomposition -->` on the scope-agent diagnosis comment when a scope agent returns `confirmed-non-shippable-as-single-PR` (#498). It surfaces an epic as a human-handoff: `/do-work` stops re-scoping it every session and `/my-turn` surfaces it.
- **Consumer:** `/shipyard:decompose-epic` (#501) fetches `--label needs-human-review` filtered to issues carrying the `<!-- do-work-needs-decomposition -->` marker — for `Multi-PR sequence:` / `Missing dependency:` evidence classes it auto-shards the epic into dispatch-ready sub-issues (an ordered `Blocked by #<sibling>` chain); for non-mechanical classes (`Multi-service coordination:`, `Body cites <artifact>:`) it escalates and leaves the handoff in place. A successfully-sharded parent **keeps** `needs-human-review` (it's a human-gated tracking umbrella — its children carry the dispatchable units) and stays OPEN until a human closes it.
- **Two distinct sentinels:** `<!-- do-work-needs-decomposition -->` is the *trigger marker* (identifies an epic handoff; persists for the epic's lifetime). `<!-- do-work-decompose-agent -->` is the *idempotency sentinel* (present only after a `/decompose-epic` run; stops re-processing). Don't conflate them.

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
