---
name: dx-catalog
description: Use when auditing a codebase for missing developer-experience features — standard tooling, contributor docs, observability services, and Claude Code setup. Provides the 25-item catalog walked by `app-audits:dx-auditor`.
---

# DX Catalog

Catalog of 25 polished-repo features the `dx-auditor` agent walks. Items are grouped by category. Each item is a self-contained subsection with a stable `id`, stack `applies_to`, severity, detection probe, why-it-matters, suggested approach, and acceptance criteria.

## How the auditor uses this catalog

1. **Detect stacks once.** Cache the result for the run.
   ```bash
   stacks=()
   [ -f package.json ] && stacks+=(js)
   [ -f tsconfig.json ] && stacks+=(ts)
   { [ -f pyproject.toml ] || [ -f requirements.txt ]; } && stacks+=(py)
   [ -f go.mod ] && stacks+=(go)
   [ -f Gemfile ] && stacks+=(rb)
   [ -d .claude ] && stacks+=(claude)
   ```

2. **For each catalog item:**
   - If `applies_to` and `stacks` are disjoint → skip (record reason for the summary).
   - Run the `Detect` probe.
   - If it returns 0 / matches (i.e., the thing exists) → skip.
   - Otherwise file an issue:
     - Title from the item's `Title:` field
     - Body from the standard template (see `app-audits:filing-github-issues`)
     - Labels: `audit:dx`, plus the item's severity (`P0`/`P1`/`P2`), plus `needs-triage` if the item carries that flag
     - Audit-key from the item's `Audit key:` field

## Severity bands (per category)

| Category | Severity |
|---|---|
| tooling | **P1** |
| onboarding | **P2** |
| observability | **P2** |
| claude-code | **P2** |

---

## Tooling — P1

### `missing-ci-workflow`

- **Category:** tooling
- **Severity:** P1
- **Applies to:** *(any)*
- **Audit key:** `dx/tooling/missing-ci-workflow`
- **Needs triage:** no

**Title:** `chore(dx): add CI workflow`

**Detect (missing if this prints nothing):**

```bash
ls .github/workflows/*.yml .github/workflows/*.yaml 2>/dev/null
```

**Why it matters:** Without CI, every push is on trust. Lint/format/test regressions land silently and surface only when someone runs the suite locally.

**Suggested approach:** Add `.github/workflows/ci.yml` running install + lint + test on `push` and `pull_request`. Use the detected stack's standard runner (`setup-node@v4` for js/ts, `setup-python@v5` for py, `setup-go@v5` for go).

**Acceptance:**
- [ ] `.github/workflows/ci.yml` exists.
- [ ] Workflow runs on push and PR.
- [ ] At least one quality gate (lint or test) executes.

---

### `missing-linter`

- **Category:** tooling
- **Severity:** P1
- **Applies to:** js, ts, py, go
- **Audit key:** `dx/tooling/missing-linter`
- **Needs triage:** no

**Title:** `chore(dx): add linter configuration`

**Detect (per stack; missing if all relevant probes return empty):**

```bash
# JS/TS
ls .eslintrc .eslintrc.* eslint.config.* biome.json 2>/dev/null
# Python
ls .ruff.toml ruff.toml 2>/dev/null
{ [ -f pyproject.toml ] && grep -qE '^\[tool\.(ruff|flake8|pylint)\]' pyproject.toml; }
# Go
ls .golangci.yml .golangci.yaml 2>/dev/null
```

**Why it matters:** A linter is a cheap, automatic reviewer. Without one, style debates happen in PR comments instead of being enforced by the toolchain.

**Suggested approach:** Adopt the ecosystem standard — ESLint or Biome for js/ts, Ruff for python, golangci-lint for go. Wire `--check` mode into CI.

**Acceptance:**
- [ ] Linter config file present at repo root.
- [ ] `<linter> --check .` (or equivalent) runs in CI.

---

### `missing-formatter`

- **Category:** tooling
- **Severity:** P1
- **Applies to:** js, ts, py, go
- **Audit key:** `dx/tooling/missing-formatter`
- **Needs triage:** no

**Title:** `chore(dx): add formatter configuration`

**Detect:**

```bash
# JS/TS — Prettier
ls .prettierrc .prettierrc.* prettier.config.* 2>/dev/null
[ -f package.json ] && jq -e '.prettier' package.json >/dev/null 2>&1
# Python — Ruff format / Black
{ [ -f pyproject.toml ] && grep -qE '^\[tool\.(ruff\.format|black)\]' pyproject.toml; }
# Go — gofmt is built in; check for gofmt step in CI
grep -lr "gofmt\|go fmt" .github/workflows/ 2>/dev/null
```

**Why it matters:** Consistent formatting eliminates a whole class of PR-review comments and merge conflicts on whitespace.

**Suggested approach:** Add `.prettierrc.json` (single-quote, trailing-comma, print-width 100) for js/ts. Enable `[tool.ruff.format]` in `pyproject.toml` for python. Add a `gofmt -l .` check to CI for go.

**Acceptance:**
- [ ] Formatter config present (or gofmt check in CI for go).
- [ ] `<formatter> --check .` runs in CI.

---

### `missing-type-checker`

- **Category:** tooling
- **Severity:** P1
- **Applies to:** js, py
- **Audit key:** `dx/tooling/missing-type-checker`
- **Needs triage:** no

**Title:** `chore(dx): add static type checking`

**Detect:**

```bash
# JS — adopt TypeScript or @ts-check via jsconfig
[ -f tsconfig.json ] || [ -f jsconfig.json ]
# Python
ls mypy.ini pyrightconfig.json pyrightconfig.toml 2>/dev/null
{ [ -f pyproject.toml ] && grep -qE '^\[tool\.(mypy|pyright)\]' pyproject.toml; }
```

**Why it matters:** Static types catch a category of bugs at edit time that otherwise hit prod. The shift-left payoff compounds across the lifetime of the repo.

**Suggested approach:** For pure-js codebases, add `tsconfig.json` with `allowJs: true, checkJs: true` and migrate incrementally. For python, add `mypy.ini` or `[tool.mypy]` and gate CI on it.

**Acceptance:**
- [ ] Type-checker config present.
- [ ] `<type-checker>` runs in CI as a required step.

---

### `missing-pre-commit`

- **Category:** tooling
- **Severity:** P1
- **Applies to:** *(any)*
- **Audit key:** `dx/tooling/missing-pre-commit`
- **Needs triage:** no

**Title:** `chore(dx): add pre-commit hooks`

**Detect:**

```bash
[ -d .husky ] && ls .husky/* 2>/dev/null
[ -f .pre-commit-config.yaml ] || [ -f .pre-commit-config.yml ]
[ -f package.json ] && jq -e '."lint-staged"' package.json >/dev/null 2>&1
```

**Why it matters:** Pre-commit hooks catch lint/format failures locally, before they hit CI and burn 5 minutes of every contributor's day.

**Suggested approach:** For js/ts, install Husky + lint-staged with a `pre-commit` hook running the formatter on staged files. For other stacks, adopt the `pre-commit` framework with project-appropriate hooks.

**Acceptance:**
- [ ] Pre-commit hook config present.
- [ ] Hook runs format/lint on staged files.

---

### `missing-runtime-pin`

- **Category:** tooling
- **Severity:** P1
- **Applies to:** *(any)*
- **Audit key:** `dx/tooling/missing-runtime-pin`
- **Needs triage:** no

**Title:** `chore(dx): pin runtime version`

**Detect:**

```bash
[ -f .nvmrc ] || [ -f .node-version ] || [ -f .python-version ] || [ -f .tool-versions ]
[ -f package.json ] && jq -e '.engines.node' package.json >/dev/null 2>&1
```

**Why it matters:** Without a runtime pin, every contributor's "works on my machine" carries a different Node/Python/etc. version. CI failures from version drift waste real time.

**Suggested approach:** Add `.nvmrc` / `.python-version` / `.tool-versions` with the version the project actually uses. For js/ts, also add `engines.node` to `package.json`.

**Acceptance:**
- [ ] Runtime version pinned in a checked-in file.
- [ ] CI uses the same version (via `setup-node` `node-version-file`, etc.).

---

### `missing-lockfile`

- **Category:** tooling
- **Severity:** P1
- **Applies to:** js, ts, py, rb, go
- **Audit key:** `dx/tooling/missing-lockfile`
- **Needs triage:** no

**Title:** `chore(dx): commit dependency lockfile`

**Detect:**

```bash
# JS/TS — must have one if package.json exists
if [ -f package.json ]; then
  ls package-lock.json yarn.lock pnpm-lock.yaml bun.lockb 2>/dev/null
fi
# Python (poetry/uv)
[ -f pyproject.toml ] && ls poetry.lock uv.lock 2>/dev/null
# Ruby
[ -f Gemfile ] && [ -f Gemfile.lock ]
# Go
[ -f go.mod ] && [ -f go.sum ]
```

**Why it matters:** Without a lockfile, two `npm install`s on different machines can resolve to different dependency trees, causing impossible-to-reproduce bugs.

**Suggested approach:** Run the install command and commit the resulting lockfile. Add it to the repo's `.gitignore` allowlist if it was accidentally excluded.

**Acceptance:**
- [ ] Lockfile present at repo root.
- [ ] Lockfile is tracked in git (not in `.gitignore`).

---

### `missing-dep-automation`

- **Category:** tooling
- **Severity:** P1
- **Applies to:** *(any)*
- **Audit key:** `dx/tooling/missing-dep-automation`
- **Needs triage:** no

**Title:** `chore(dx): enable automated dependency updates`

**Detect:**

```bash
[ -f .github/dependabot.yml ] || [ -f .github/dependabot.yaml ] \
  || [ -f renovate.json ] || [ -f .github/renovate.json ]
```

**Why it matters:** Without automated dep updates, security patches and bug fixes age in the lockfile until something breaks. Dependabot/Renovate keeps the diff small and continuous.

**Suggested approach:** Add `.github/dependabot.yml` configured for the detected package ecosystem with weekly cadence. Alternative: `renovate.json` if the org standardizes on Renovate.

**Acceptance:**
- [ ] Dependabot or Renovate config file present.
- [ ] Configured for the right package ecosystem (npm / pip / gomod / etc.).
