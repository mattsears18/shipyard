# DX-auditor design

**Status:** approved, awaiting plan
**Author:** brainstorm 2026-05-17
**Plugin:** `app-audits`

A new audit agent that recommends missing developer-experience features — standard tooling, contributor docs, observability services, and Claude Code setup — by walking a curated catalog and filing one GitHub issue per gap.

---

## Goals

- Surface DX gaps that aren't bugs but cost the team velocity (no CI, no Sentry, no CONTRIBUTING.md, no Prettier).
- Plug into the existing `app-audits` pipeline (`/audit dx`, `audit:dx` label, idempotent re-runs, `/do-work` picks them up).
- Be opinionated but not noisy on polished repos — stack-filter the catalog so a Python repo doesn't get Prettier recommendations.

## Non-goals

- Not a *code quality* auditor — naming, refactoring, "this could be a hook," etc. belong elsewhere.
- Not a *tech-debt* auditor — that's `tech-debt-auditor`'s territory (stale TODOs, dead flags).
- Not a *security* auditor — dep CVEs and secrets-in-git are `security-auditor`.
- Not a config generator — the agent files issues describing the gap and a suggested approach; `/do-work` implements.

## Architecture

Three new files, two edits, plus a version bump.

### Create

1. **`plugins/app-audits/agents/dx-auditor.md`** — the agent.
   - Walks the catalog, runs each detection probe, files an issue per gap via `filing-github-issues`.
   - Audit label: `audit:dx`.
   - Mirrors the shape of `tech-debt-auditor.md` (passes → findings → file → summary).

2. **`plugins/app-audits/skills/dx-catalog/SKILL.md`** — the catalog skill.
   - Heading-per-item structure under category sections.
   - Reusable: future per-stack catalogs (`expo-dx-catalog`, `nextjs-dx-catalog`) can complement it.

### Edit

3. **`plugins/app-audits/commands/audit.md`** — dispatch table.
   - Add row: `dx` → `app-audits:dx-auditor`, no URL needed.
   - Add `dx` to the `all` fan-out.

4. **`plugins/app-audits/skills/filing-github-issues/SKILL.md`** — required-label table.
   - Add row: `dx-auditor` → `audit:dx`.
   - Add audit-key examples for the new dimension.

### Bump

5. **`plugins/app-audits/.claude-plugin/plugin.json`** — minor bump (`0.9.0` → `0.10.0` at ship time).

## Catalog schema

Heading-per-item Markdown, four category sections, 25 items total.

Each item is one self-contained subsection:

```markdown
### `missing-prettier`

- **Category:** tooling
- **Severity:** P1
- **Applies to:** js, ts
- **Audit key:** `dx/tooling/missing-prettier`
- **Needs triage:** no

**Title:** `chore(dx): add Prettier config`

**Detect (missing if this returns non-zero / no output):**

```bash
test -f .prettierrc || test -f .prettierrc.json || test -f .prettierrc.js \
  || jq -e '.prettier' package.json >/dev/null 2>&1
```

**Why it matters:** Consistent formatting eliminates a whole class of PR-review comments and merge conflicts on whitespace.

**Suggested approach:** Add a `.prettierrc.json` with single-quote, trailing-comma, print-width 100. Wire `prettier --check` into the CI workflow.

**Acceptance:**
- [ ] Repo has a Prettier config at root.
- [ ] `npx prettier --check .` runs in CI.
```

### Stack detection (cached once per run)

```bash
stacks=()
test -f package.json     && stacks+=(js)
test -f tsconfig.json    && stacks+=(ts)
test -f pyproject.toml -o -f requirements.txt && stacks+=(py)
test -f go.mod           && stacks+=(go)
test -f Gemfile          && stacks+=(rb)
test -d .claude          && stacks+=(claude)   # used by the claude-code category
```

`applies_to` is ANDed against `stacks`. Empty `applies_to` = always applies.

### Severity (per-category fixed band)

| Category | Severity |
|---|---|
| tooling | **P1** |
| onboarding | **P2** |
| observability | **P2** |
| claude-code | **P2** |

Severity is pinned per row in the catalog (denormalized from category) for clarity and to allow targeted exceptions later.

### `needs-triage` flag

Per-row `needs_triage: true` is set on items that require a product decision the auditor can't make from signals alone:

- `missing-error-tracking` — Sentry? Bugsnag? Rollbar?
- `missing-analytics` — PostHog? Mixpanel? Vercel Analytics? Plausible?
- `missing-feature-flags` — GrowthBook? LaunchDarkly? Vercel Flags?
- `missing-recommended-mcp` — which MCP servers are appropriate?

`/do-work` skips `needs-triage` issues — the human chooses the vendor first.

## Catalog contents (25 items)

### Tooling — P1 (8 items)

1. `missing-ci-workflow` — no `.github/workflows/*.yml`
2. `missing-linter` — no ESLint/Biome (js/ts), Ruff (py), golangci (go)
3. `missing-formatter` — no Prettier (js/ts), Ruff format (py), gofmt-in-CI (go)
4. `missing-type-checker` — no `tsconfig.json` (js→ts adoption), no `mypy.ini`/`pyrightconfig.json` (py)
5. `missing-pre-commit` — no `.husky/`, no `lint-staged`, no `.pre-commit-config.yaml`
6. `missing-runtime-pin` — no `.nvmrc` / `engines.node` / `.python-version` / `.tool-versions`
7. `missing-lockfile` — `package.json` but no lockfile (or equivalent absence in pip/poetry/go)
8. `missing-dep-automation` — no `.github/dependabot.yml` or `renovate.json`

### Onboarding — P2 (8 items)

9. `missing-readme-quickstart` — README exists but no "Install / Run / Getting started" heading
10. `missing-contributing` — no `CONTRIBUTING.md`
11. `missing-env-example` — `.env` referenced in code but no `.env.example` checked in
12. `missing-pr-template` — no `.github/PULL_REQUEST_TEMPLATE.md`
13. `missing-issue-templates` — no `.github/ISSUE_TEMPLATE/*`
14. `missing-codeowners` — no `.github/CODEOWNERS` (skip if repo has 1 collaborator)
15. `missing-license` — no `LICENSE` / `LICENSE.md` / `LICENSE.txt`
16. `missing-setup-script` — neither `.devcontainer/`, `scripts/setup.sh`, nor `bin/setup`

### Observability — P2 (5 items)

17. `missing-error-tracking` *(needs-triage)* — no `@sentry/*`, `bugsnag`, `@rollbar/*` in deps
18. `missing-analytics` *(needs-triage)* — no `posthog-js`, `mixpanel`, `@vercel/analytics`, `plausible`, `amplitude`
19. `missing-feature-flags` *(needs-triage)* — no `growthbook`, `launchdarkly`, `@vercel/flags`, `unleash`
20. `missing-health-endpoint` — server app with no `/health`, `/api/health`, or `/status` route
21. `missing-structured-logging` — no `pino`, `winston`, `bunyan` (js) / no `structlog`, `loguru` (py)

### Claude Code — P2 (4 items)

22. `missing-claude-md` — no `CLAUDE.md`
23. `missing-claude-settings` — no `.claude/settings.json` (drives repeated permission prompts)
24. `missing-recommended-mcp` *(needs-triage)* — repo deploys to Vercel / uses Supabase / wires Sentry, but `.mcp.json` doesn't configure the corresponding MCP
25. `missing-stop-hook` — no `.claude/settings.json` `hooks.Stop` running type-check or tests

## Detection flow (the agent's loop)

```
1. Resolve target repo (passed in by orchestrator).
2. Detect stacks (one-time bash block, cached for the run).
3. Pre-fetch existing audit-labeled issues (filing-github-issues tier-2 dedup).
4. For each catalog item:
   a. If `applies_to` ∩ `stacks` = ∅ → skip (record reason).
   b. Run `detect` probe.
   c. If probe returns 0 / matches (i.e., the thing exists) → skip.
   d. Else build audit-key, check dedup cache, file via gh issue create:
      - --label audit:dx
      - --label P0 / P1 / P2 from the row
      - --label needs-triage if row has the flag
5. Emit end-of-run summary.
```

## Issue body template

```markdown
Found by `dx` audit on <YYYY-MM-DD>.

## Finding

<category>: missing <human-readable thing name>. Detection probe evidence:

```
<the one-line output of the probe — e.g., "no .prettierrc.* present and no `prettier` key in package.json">
```

Detected stack: `<comma-separated stack tags>`

## Why it matters

<verbatim from catalog row's `Why it matters`>

## Suggested approach

<verbatim from catalog row's `Suggested approach`>

## Acceptance criteria

- [ ] <from catalog row>
- [ ] <from catalog row>

<!-- audit-key=dx/<category>/<id> -->
```

## End-of-run summary

```
DX audit:
<one-line verdict — typical: "Polished repo, 2 small gaps" or "Greenfield repo, full catalog applies">

Stack detected: <js, ts, claude, ...>
Items in catalog: 25 (after stack filter: <N>)
Gaps found: <K>
  Tooling (P1): <n>
  Onboarding (P2): <n>
  Observability (P2): <n>
  Claude Code (P2): <n>

Filed K issues:
- #NNN <title> (URL) [needs-triage]
...

Skipped (duplicates):
- <finding> → existing #NNN

Skipped (not applicable to stack):
- <id> (reason)
```

## Orchestrator wiring

In `commands/audit.md`, add to the dispatch table:

| Type | Agents to dispatch | Needs URL? |
|---|---|---|
| `dx` | `app-audits:dx-auditor` | no |

And add `dx` to the `all` fan-out (parallel with the others).

In `filing-github-issues/SKILL.md`, add to the required-label table:

| Agent | Required label | Color |
|---|---|---|
| `dx-auditor` | `audit:dx` | `c5def5` |

And add the new audit-key examples (e.g., `dx/tooling/missing-prettier`, `dx/observability/missing-error-tracking`, `dx/claude-code/missing-claude-md`).

## Out of scope (for v1)

- **User-configurable catalog** — `.audit/dx-catalog.yml` overrides. Defer; full catalog covers 80% of cases.
- **Per-stack catalog skills** — `expo-dx-catalog`, `nextjs-dx-catalog`. Defer; the base catalog handles cross-stack basics.
- **Auto-implementation** — the auditor only files issues; `/do-work` implements. No exception.

## Risks

- **Noise on first run.** A virgin repo could see 15–20 DX issues filed. Mitigation: stack filter keeps the count realistic per repo; `needs-triage` keeps `/do-work` from auto-implementing the opinionated ones.
- **Vendor-opinion contamination.** Recommending Sentry specifically (vs. Bugsnag/Rollbar) is opinionated. Mitigation: `needs-triage` flag puts the vendor choice in front of a human before any code change.
- **Stale detection probes.** As ecosystems evolve, the `detect:` bash lines decay (e.g., a new linter convention). Mitigation: catalog lives in a skill, easy to PR-update; per-row probes are short.

## Acceptance criteria (for the implementation plan)

- [ ] `/audit dx` on this repo files 0 issues (since this repo is polished — or if any file, they're genuine gaps).
- [ ] `/audit dx` run twice in a row produces 0 new issues the second time (idempotency via audit-key).
- [ ] `/audit all` includes `dx` in the parallel fan-out and the consolidated summary.
- [ ] `/do-work` correctly skips DX issues carrying `needs-triage`.
- [ ] On a stack-mismatched detection (e.g., Python repo, JS catalog item), the item is skipped and noted in the "not applicable to stack" section of the summary.
