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

## Onboarding — P2

### `missing-readme-quickstart`

- **Category:** onboarding
- **Severity:** P2
- **Applies to:** *(any)*
- **Audit key:** `dx/onboarding/missing-readme-quickstart`
- **Needs triage:** no

**Title:** `docs(dx): add Quickstart section to README`

**Detect (missing if README absent OR has no quickstart heading):**

```bash
if [ ! -f README.md ] && [ ! -f README.rst ] && [ ! -f README ]; then
  echo "no-readme"
else
  grep -iE '^#+ +(install|quickstart|getting started|setup|usage)' README.md 2>/dev/null
fi
```

**Why it matters:** A new contributor's first 60 seconds with the repo determines whether they get to a green local run or abandon. A quickstart section is the single highest-ROI doc.

**Suggested approach:** Add an "Install" or "Quickstart" heading near the top of `README.md` with the literal commands to clone, install, and run the project locally.

**Acceptance:**
- [ ] `README.md` contains an Install/Quickstart/Getting Started heading.
- [ ] Heading lists the exact commands (no placeholders).

---

### `missing-contributing`

- **Category:** onboarding
- **Severity:** P2
- **Applies to:** *(any)*
- **Audit key:** `dx/onboarding/missing-contributing`
- **Needs triage:** no

**Title:** `docs(dx): add CONTRIBUTING.md`

**Detect:**

```bash
ls CONTRIBUTING.md CONTRIBUTING.rst docs/CONTRIBUTING.md .github/CONTRIBUTING.md 2>/dev/null
```

**Why it matters:** External contributors need to know how to branch, test, and submit. Without `CONTRIBUTING.md`, every first-time PR re-asks the maintainer the same questions.

**Suggested approach:** Add a `CONTRIBUTING.md` covering: branch naming, how to run tests locally, PR title conventions, and review/merge expectations.

**Acceptance:**
- [ ] `CONTRIBUTING.md` exists at one of the standard paths.
- [ ] Document covers branching, testing, and PR conventions.

---

### `missing-env-example`

- **Category:** onboarding
- **Severity:** P2
- **Applies to:** *(any)*
- **Audit key:** `dx/onboarding/missing-env-example`
- **Needs triage:** no

**Title:** `docs(dx): commit .env.example`

**Detect (only file an issue if .env is referenced AND no .env.example exists):**

```bash
references_env=$(grep -rE '(process\.env\.|os\.getenv|os\.environ|ENV\[)' \
  --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' \
  --include='*.py' --include='*.rb' --include='*.go' . 2>/dev/null | head -1)
has_example=$(ls .env.example .env.sample .env.template 2>/dev/null)
[ -n "$references_env" ] && [ -z "$has_example" ] && echo "missing"
```

**Why it matters:** A new contributor pulls the repo, runs the install command, and the app explodes on missing env vars. Without `.env.example`, they have to grep the code to find out what to set.

**Suggested approach:** Copy `.env` to `.env.example`, then redact every value (replace with placeholder like `CHANGEME` or a description of the value). Commit `.env.example`. Confirm `.env` itself is in `.gitignore`.

**Acceptance:**
- [ ] `.env.example` exists at repo root.
- [ ] Lists every env var the code reads.
- [ ] All values are placeholders (no real secrets).

---

### `missing-pr-template`

- **Category:** onboarding
- **Severity:** P2
- **Applies to:** *(any)*
- **Audit key:** `dx/onboarding/missing-pr-template`
- **Needs triage:** no

**Title:** `docs(dx): add pull request template`

**Detect:**

```bash
ls .github/PULL_REQUEST_TEMPLATE.md .github/pull_request_template.md \
   .github/PULL_REQUEST_TEMPLATE/*.md 2>/dev/null
```

**Why it matters:** A PR template forces every author to answer the same three questions (what, why, test plan) before review, which compounds into faster cycle time.

**Suggested approach:** Add `.github/PULL_REQUEST_TEMPLATE.md` with sections for Summary, Why, and Test Plan.

**Acceptance:**
- [ ] `.github/PULL_REQUEST_TEMPLATE.md` exists.
- [ ] Template prompts for Summary, Why, and Test Plan (or equivalents).

---

### `missing-issue-templates`

- **Category:** onboarding
- **Severity:** P2
- **Applies to:** *(any)*
- **Audit key:** `dx/onboarding/missing-issue-templates`
- **Needs triage:** no

**Title:** `docs(dx): add issue templates`

**Detect:**

```bash
ls .github/ISSUE_TEMPLATE/*.md .github/ISSUE_TEMPLATE/*.yml .github/ISSUE_TEMPLATE/*.yaml 2>/dev/null
```

**Why it matters:** Issue templates raise the floor on bug reports — repro steps, expected vs. actual, environment. Without them, half of all issues land as "it doesn't work."

**Suggested approach:** Add at least one Markdown or YAML template under `.github/ISSUE_TEMPLATE/` (e.g., `bug_report.md` and `feature_request.md`).

**Acceptance:**
- [ ] `.github/ISSUE_TEMPLATE/` has at least one template.
- [ ] Template includes repro steps and expected/actual sections (for bugs).

---

### `missing-codeowners`

- **Category:** onboarding
- **Severity:** P2
- **Applies to:** *(any)*
- **Audit key:** `dx/onboarding/missing-codeowners`
- **Needs triage:** no

**Title:** `chore(dx): add CODEOWNERS`

**Detect (skip if solo repo — only 1 collaborator):**

```bash
collaborators=$(gh api "repos/<owner/repo>/collaborators" --jq 'length' 2>/dev/null || echo 0)
[ "$collaborators" -le 1 ] && echo "solo-repo-skip"
ls .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS 2>/dev/null
```

**Why it matters:** Without `CODEOWNERS`, PR review-assignment is manual every time, and code areas drift toward owner-of-the-week. The file is also enforceable via branch protection.

**Suggested approach:** Add `.github/CODEOWNERS` mapping at minimum `*` to one or two trusted reviewers. Refine by path as the team grows.

**Acceptance:**
- [ ] `.github/CODEOWNERS` exists.
- [ ] Wildcard rule (`*`) maps to at least one owner.
- [ ] Branch protection requires review from CODEOWNERS (verify in repo settings).

---

### `missing-license`

- **Category:** onboarding
- **Severity:** P2
- **Applies to:** *(any)*
- **Audit key:** `dx/onboarding/missing-license`
- **Needs triage:** no

**Title:** `docs(dx): add LICENSE file`

**Detect:**

```bash
ls LICENSE LICENSE.md LICENSE.txt LICENCE LICENCE.md COPYING 2>/dev/null
```

**Why it matters:** A repo without an explicit license is "all rights reserved" — every outside contribution is legally ambiguous, and many orgs forbid using or even forking such repos.

**Suggested approach:** Add a `LICENSE` file. MIT or Apache-2.0 are the most common defaults. Choose deliberately; the choice is hard to undo.

**Acceptance:**
- [ ] `LICENSE` (or similar) file exists at repo root.
- [ ] License is one of: MIT, Apache-2.0, BSD-*, MPL-2.0, GPL-*, or another OSI-approved license.

---

### `missing-setup-script`

- **Category:** onboarding
- **Severity:** P2
- **Applies to:** *(any)*
- **Audit key:** `dx/onboarding/missing-setup-script`
- **Needs triage:** no

**Title:** `chore(dx): add setup script or devcontainer`

**Detect:**

```bash
[ -d .devcontainer ] || [ -f scripts/setup.sh ] || [ -f bin/setup ] || [ -f Makefile ] || [ -f Justfile ]
```

**Why it matters:** "Clone → install → run" should be one command. Without a setup script or devcontainer, every new contributor reinvents the install sequence from the README and gets it slightly wrong.

**Suggested approach:** Add `scripts/setup.sh` (or `bin/setup`) that runs the install + any one-time setup. Alternatively, a `.devcontainer/devcontainer.json` for Codespaces/VS Code.

**Acceptance:**
- [ ] Setup script or devcontainer present.
- [ ] One command brings a fresh checkout to a runnable state.
