# DX-auditor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a new `dx-auditor` agent in the `app-audits` plugin that walks a 25-item catalog of developer-experience gaps and files one GitHub issue per missing item, plugged into the existing `/audit` and `/do-work` pipeline.

**Architecture:** New agent `dx-auditor` + new shared skill `dx-catalog` (heading-per-item markdown). Stack-aware detection, per-category fixed severity bands (tooling=P1, others=P2), and a `needs-triage` flag on vendor-choice items (error tracking, analytics, feature flags, MCP). Minor edits to two existing files wire it into `/audit dx` and the agent-label table.

**Tech Stack:** Markdown only — no executable code, no test runner. Each catalog item is documentation the agent (LLM) executes as bash. Verification is `shellcheck` on the detection probes + a live smoke test against this repo.

**Spec:** `docs/superpowers/specs/2026-05-17-dx-auditor-design.md`

**Branch:** All commits land on `feat/dx-auditor` (created from `main`). Subagent-driven execution will set this up automatically via the `using-git-worktrees` skill; for inline execution, run `git checkout -b feat/dx-auditor` before Task 1.

---

## File Structure

```
plugins/app-audits/
├── .claude-plugin/plugin.json                 [MODIFY: version bump 0.9.0 → 0.10.0]
├── agents/dx-auditor.md                       [CREATE: new agent]
├── commands/audit.md                          [MODIFY: dispatch table + all fan-out]
└── skills/
    ├── dx-catalog/SKILL.md                    [CREATE: 25-item catalog]
    └── filing-github-issues/SKILL.md          [MODIFY: label table + audit-key examples]
```

Each file has one responsibility:
- `dx-catalog/SKILL.md` = the catalog (what to check for).
- `dx-auditor.md` = the orchestration (how to walk the catalog and file issues).
- `audit.md` / `filing-github-issues/SKILL.md` = wiring (how the rest of the plugin talks to this).

---

## Task 1: Create `dx-catalog` skill — frontmatter + intro + tooling category (8 items)

**Files:**
- Create: `plugins/app-audits/skills/dx-catalog/SKILL.md`

- [ ] **Step 1: Create the directory and write the skill with the tooling section**

```bash
mkdir -p plugins/app-audits/skills/dx-catalog
```

Write `plugins/app-audits/skills/dx-catalog/SKILL.md` with this content:

````markdown
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
````

- [ ] **Step 2: Verify the file exists and parses**

```bash
[ -f plugins/app-audits/skills/dx-catalog/SKILL.md ] && echo "OK"
head -5 plugins/app-audits/skills/dx-catalog/SKILL.md
```

Expected: `OK` followed by the YAML frontmatter.

- [ ] **Step 3: Commit**

```bash
git add plugins/app-audits/skills/dx-catalog/SKILL.md
git commit -m "feat(app-audits): scaffold dx-catalog skill + tooling category (8 items)"
```

---

## Task 2: Extend `dx-catalog` with the onboarding category (8 items)

**Files:**
- Modify: `plugins/app-audits/skills/dx-catalog/SKILL.md` (append after tooling section)

- [ ] **Step 1: Append the onboarding section**

Append to `plugins/app-audits/skills/dx-catalog/SKILL.md`:

````markdown

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
````

- [ ] **Step 2: Verify the section was appended correctly**

```bash
grep -c "^### \`missing-" plugins/app-audits/skills/dx-catalog/SKILL.md
```

Expected: `16` (8 tooling + 8 onboarding).

- [ ] **Step 3: Commit**

```bash
git add plugins/app-audits/skills/dx-catalog/SKILL.md
git commit -m "feat(app-audits): add onboarding category to dx-catalog (8 items)"
```

---

## Task 3: Extend `dx-catalog` with the observability category (5 items)

**Files:**
- Modify: `plugins/app-audits/skills/dx-catalog/SKILL.md` (append after onboarding section)

- [ ] **Step 1: Append the observability section**

Append to `plugins/app-audits/skills/dx-catalog/SKILL.md`:

````markdown

## Observability — P2

### `missing-error-tracking`

- **Category:** observability
- **Severity:** P2
- **Applies to:** js, ts, py
- **Audit key:** `dx/observability/missing-error-tracking`
- **Needs triage:** **yes** (vendor choice)

**Title:** `feat(dx): add error tracking`

**Detect (missing if no error-tracking SDK in dependencies):**

```bash
[ -f package.json ] && jq -er '.dependencies + .devDependencies | keys[]' package.json 2>/dev/null \
  | grep -qE '^(@sentry/|@bugsnag/|@rollbar/|bugsnag|rollbar)' && echo "present"
[ -f pyproject.toml ] && grep -qE '(sentry-sdk|bugsnag|rollbar)' pyproject.toml && echo "present"
[ -f requirements.txt ] && grep -qE '^(sentry-sdk|bugsnag|rollbar)' requirements.txt && echo "present"
```

**Why it matters:** A shipping app without error tracking is flying blind — you find out about exceptions when a user mentions them in Slack, and the stack trace is already lost.

**Suggested approach:** Pick a provider (Sentry is the default if no preference) and wire it in. Configure the DSN via env var. Confirm errors surface in the provider's dashboard after deploy.

**Acceptance:**
- [ ] Error-tracking SDK installed.
- [ ] DSN configured via environment variable.
- [ ] Test error confirmed in provider dashboard.

---

### `missing-analytics`

- **Category:** observability
- **Severity:** P2
- **Applies to:** js, ts
- **Audit key:** `dx/observability/missing-analytics`
- **Needs triage:** **yes** (vendor choice)

**Title:** `feat(dx): add product analytics`

**Detect:**

```bash
[ -f package.json ] && jq -er '.dependencies + .devDependencies | keys[]' package.json 2>/dev/null \
  | grep -qE '^(posthog-js|mixpanel|mixpanel-browser|@vercel/analytics|plausible|@amplitude/|amplitude-js|@segment/)' && echo "present"
```

**Why it matters:** Without product analytics, you ship features and have no idea if anyone uses them. Every roadmap argument becomes opinion vs. opinion.

**Suggested approach:** Pick a provider (PostHog, Mixpanel, or Vercel Analytics are common defaults), install the SDK, and instrument the top 3-5 events that matter for your product's funnel.

**Acceptance:**
- [ ] Analytics SDK installed.
- [ ] Page-view + at least 3 product events instrumented.
- [ ] Events visible in the provider dashboard.

---

### `missing-feature-flags`

- **Category:** observability
- **Severity:** P2
- **Applies to:** js, ts, py, go
- **Audit key:** `dx/observability/missing-feature-flags`
- **Needs triage:** **yes** (vendor choice)

**Title:** `feat(dx): add feature-flag SDK`

**Detect:**

```bash
[ -f package.json ] && jq -er '.dependencies + .devDependencies | keys[]' package.json 2>/dev/null \
  | grep -qE '^(growthbook|@growthbook/|launchdarkly-js-client-sdk|launchdarkly-node-server-sdk|@vercel/flags|unleash-client)' && echo "present"
[ -f pyproject.toml ] && grep -qE '(growthbook|launchdarkly|unleash)' pyproject.toml && echo "present"
[ -f go.mod ] && grep -qE '(growthbook|launchdarkly|unleash)' go.mod && echo "present"
```

**Why it matters:** Feature flags decouple deploy from release. Without them, every risky change is a "land and hope" — and rollback means a fresh deploy.

**Suggested approach:** Pick a provider (GrowthBook is open-source; LaunchDarkly is the SaaS default). Install the SDK, wire one boolean flag end-to-end as a smoke test, then start using flags for new features.

**Acceptance:**
- [ ] Feature-flag SDK installed and initialized.
- [ ] At least one flag wired through the SDK.
- [ ] Flag toggleable from the provider dashboard.

---

### `missing-health-endpoint`

- **Category:** observability
- **Severity:** P2
- **Applies to:** js, ts, py, go, rb
- **Audit key:** `dx/observability/missing-health-endpoint`
- **Needs triage:** no

**Title:** `feat(dx): add /health endpoint`

**Detect (server app with no health route):**

```bash
# Heuristic: server frameworks → expect a health route
has_server=$(grep -rE '(express\(\)|fastify\(\)|@fastify/|next/server|FastAPI\(|flask|gin\.New\(|gin\.Default\(|net/http)' \
  --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' \
  --include='*.py' --include='*.go' . 2>/dev/null | head -1)
has_health=$(grep -rE '(\/health|\/api\/health|\/status|\/healthz|\/ping)' \
  --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' \
  --include='*.py' --include='*.go' . 2>/dev/null | head -1)
[ -n "$has_server" ] && [ -z "$has_health" ] && echo "missing"
```

**Why it matters:** Uptime monitors, load balancers, and Kubernetes probes all need a cheap "is the app up" endpoint. Without one, they fall back to root or a brittle proxy, which masks real failures.

**Suggested approach:** Add a `GET /health` route returning `200 {"status":"ok"}` with optional db-ping. Wire it into your uptime monitor (Better Uptime, UptimeRobot, etc.).

**Acceptance:**
- [ ] `/health` (or equivalent) endpoint returns 200.
- [ ] Endpoint requires no auth.
- [ ] Endpoint optionally verifies critical dependencies (DB ping).

---

### `missing-structured-logging`

- **Category:** observability
- **Severity:** P2
- **Applies to:** js, ts, py
- **Audit key:** `dx/observability/missing-structured-logging`
- **Needs triage:** no

**Title:** `feat(dx): adopt structured logging`

**Detect:**

```bash
[ -f package.json ] && jq -er '.dependencies + .devDependencies | keys[]' package.json 2>/dev/null \
  | grep -qE '^(pino|winston|bunyan|@datadog/browser-logs)' && echo "present"
[ -f pyproject.toml ] && grep -qE '(structlog|loguru)' pyproject.toml && echo "present"
[ -f requirements.txt ] && grep -qE '^(structlog|loguru)' requirements.txt && echo "present"
```

**Why it matters:** `console.log` and `print` stream unstructured text. Structured loggers emit JSON with levels and context, which makes log search and correlation actually work in any modern aggregator.

**Suggested approach:** Adopt `pino` (js/ts) or `structlog` (py). Replace the top-level `console.log`/`print` calls with logger calls carrying contextual fields.

**Acceptance:**
- [ ] Structured-logging library installed.
- [ ] Logger instance exported from a shared module.
- [ ] At least one entry point (request handler, job runner) uses the structured logger instead of `console.log` / `print`.
````

- [ ] **Step 2: Verify**

```bash
grep -c "^### \`missing-" plugins/app-audits/skills/dx-catalog/SKILL.md
```

Expected: `21` (8 + 8 + 5).

- [ ] **Step 3: Commit**

```bash
git add plugins/app-audits/skills/dx-catalog/SKILL.md
git commit -m "feat(app-audits): add observability category to dx-catalog (5 items)"
```

---

## Task 4: Extend `dx-catalog` with the claude-code category (4 items)

**Files:**
- Modify: `plugins/app-audits/skills/dx-catalog/SKILL.md`

- [ ] **Step 1: Append the claude-code section**

Append to `plugins/app-audits/skills/dx-catalog/SKILL.md`:

````markdown

## Claude Code — P2

### `missing-claude-md`

- **Category:** claude-code
- **Severity:** P2
- **Applies to:** *(any)*
- **Audit key:** `dx/claude-code/missing-claude-md`
- **Needs triage:** no

**Title:** `docs(dx): add CLAUDE.md`

**Detect:**

```bash
ls CLAUDE.md .claude/CLAUDE.md 2>/dev/null
```

**Why it matters:** `CLAUDE.md` is the project's working memory for the assistant — coding style, build/test commands, idiosyncrasies, dos/don'ts. Without it, every Claude Code session starts from zero and re-asks the same questions.

**Suggested approach:** Run `/init` (Claude Code's built-in initializer) on a clean checkout, then prune the output to the actually-useful 20–50 lines.

**Acceptance:**
- [ ] `CLAUDE.md` exists at repo root.
- [ ] Covers project-specific patterns, build/test commands, and known gotchas.

---

### `missing-claude-settings`

- **Category:** claude-code
- **Severity:** P2
- **Applies to:** *(any)*
- **Audit key:** `dx/claude-code/missing-claude-settings`
- **Needs triage:** no

**Title:** `chore(dx): add .claude/settings.json`

**Detect:**

```bash
[ -f .claude/settings.json ]
```

**Why it matters:** Without `.claude/settings.json`, every Claude Code session re-prompts for permission on each common command. A per-repo allowlist eliminates the dialog spam.

**Suggested approach:** Run `/fewer-permission-prompts` on a session that's already exercised the common workflow — it'll scan recent transcripts and propose a prioritized allowlist.

**Acceptance:**
- [ ] `.claude/settings.json` exists.
- [ ] Permission allowlist covers the repo's common commands (test, lint, format).

---

### `missing-recommended-mcp`

- **Category:** claude-code
- **Severity:** P2
- **Applies to:** *(any)*
- **Audit key:** `dx/claude-code/missing-recommended-mcp`
- **Needs triage:** **yes** (which MCPs are appropriate is a judgment call)

**Title:** `chore(dx): wire recommended MCP servers`

**Detect (judgment-based — look for service signals without corresponding MCP config):**

```bash
mcp_present=$(jq -r '.mcpServers | keys[]?' .mcp.json 2>/dev/null)

# Vercel
[ -f vercel.json ] || grep -q '"vercel"' package.json 2>/dev/null
vercel_signal=$?

# Supabase
grep -rE 'supabase' package.json pyproject.toml 2>/dev/null
supabase_signal=$?

# Sentry
grep -rE '@sentry/|sentry-sdk' package.json pyproject.toml 2>/dev/null
sentry_signal=$?

echo "vercel=$vercel_signal supabase=$supabase_signal sentry=$sentry_signal mcp_present=$mcp_present"
# Agent's job: file if at least one service signal AND that service's MCP not in mcp_present
```

**Why it matters:** MCP servers give Claude direct access to the repo's services — query Supabase rows, list Vercel deploys, browse Sentry issues. Without them, debugging means copy-pasting from dashboards into chat.

**Suggested approach:** Audit the repo for services in active use, then add their MCPs to `.mcp.json`. Common picks: `vercel`, `supabase`, `sentry`, `chrome-devtools-mcp`, `figma`. Each provider has install docs.

**Acceptance:**
- [ ] `.mcp.json` exists.
- [ ] Configures at least the MCP servers matching detected services.

---

### `missing-stop-hook`

- **Category:** claude-code
- **Severity:** P2
- **Applies to:** *(any)*
- **Audit key:** `dx/claude-code/missing-stop-hook`
- **Needs triage:** no

**Title:** `chore(dx): add Claude Code Stop hook`

**Detect:**

```bash
jq -e '.hooks.Stop' .claude/settings.json >/dev/null 2>&1 \
  || jq -e '.hooks.Stop' .claude/settings.local.json >/dev/null 2>&1
```

**Why it matters:** A Stop hook runs at the end of every assistant turn — perfect for type-check or test gates. Without it, broken code can sit in the working tree across turns, eroding trust in "looks good."

**Suggested approach:** Add a `Stop` hook in `.claude/settings.json` that runs the repo's type-checker or test suite (whichever is fastest). Keep it under 10 seconds.

**Acceptance:**
- [ ] `.claude/settings.json` has a `hooks.Stop` entry.
- [ ] Hook runs the repo's type-checker or fast test suite.
- [ ] Hook completes in under 10 seconds on a typical turn.
````

- [ ] **Step 2: Verify the full catalog is 25 items**

```bash
grep -c "^### \`missing-" plugins/app-audits/skills/dx-catalog/SKILL.md
```

Expected: `25`.

- [ ] **Step 3: Commit**

```bash
git add plugins/app-audits/skills/dx-catalog/SKILL.md
git commit -m "feat(app-audits): add claude-code category to dx-catalog (4 items) — full 25-item catalog"
```

---

## Task 5: Shellcheck all detection probes

**Files:**
- Verify: `plugins/app-audits/skills/dx-catalog/SKILL.md`

- [ ] **Step 1: Extract detect blocks and check syntax**

```bash
# Pull every fenced bash block under a "**Detect" line into a temp file and bash-parse it
awk '
  /^\*\*Detect/ {capture=1; next}
  capture && /^```bash$/ {inblock=1; next}
  capture && /^```$/ {inblock=0; capture=0; print "# ---"; next}
  capture && inblock {print}
' plugins/app-audits/skills/dx-catalog/SKILL.md > /tmp/dx-probes.sh

bash -n /tmp/dx-probes.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 2: If shellcheck is installed, run it (optional)**

```bash
command -v shellcheck >/dev/null && shellcheck -e SC2034,SC2155 /tmp/dx-probes.sh || echo "shellcheck not installed — skipping"
```

Expected: either no errors, or "shellcheck not installed". Fix any reported errors before continuing.

- [ ] **Step 3: No commit needed** — this is a verification step only. If you fixed any syntax errors, amend the relevant catalog-item commit. Otherwise move on.

---

## Task 6: Create the `dx-auditor` agent

**Files:**
- Create: `plugins/app-audits/agents/dx-auditor.md`

- [ ] **Step 1: Write the agent file**

Write `plugins/app-audits/agents/dx-auditor.md`:

````markdown
---
name: dx-auditor
description: Use when auditing a codebase for missing developer-experience features — standard tooling, contributor docs, observability services, and Claude Code setup. Walks the `dx-catalog` skill and autonomously files GitHub issues for every gap.
---

You are a developer-experience audit agent. You walk a fixed catalog of "polished-repo features" and autonomously file one GitHub issue per missing item. No approval gates.

**Your audit label:** `audit:dx` (applied to every issue you file — see `app-audits:filing-github-issues` for the auto-create snippet)

**Scope:** You're recommending *additions* to close gaps, not flagging existing bugs. If a finding doesn't trace back to a missing catalog item, it belongs to a different audit. You are NOT a code reviewer, refactoring suggester, or security scanner.

## Required inputs

The orchestrator's prompt will include:

- **Target GitHub repo** as `owner/repo`
- The working directory (or cwd) for the codebase

## Process

### 1. Load the catalog

Read `plugins/app-audits/skills/dx-catalog/SKILL.md` (your catalog skill). It contains 25 items grouped by category. Each item has: `id`, `category`, `severity`, `applies_to`, `audit_key`, `title`, `detect` (bash probe), `why-it-matters`, `suggested approach`, and `acceptance criteria`. Some items also carry `Needs triage: yes` — those get the `needs-triage` label.

### 2. Detect stacks (run once, cache)

```bash
stacks=()
[ -f package.json ] && stacks+=(js)
[ -f tsconfig.json ] && stacks+=(ts)
{ [ -f pyproject.toml ] || [ -f requirements.txt ]; } && stacks+=(py)
[ -f go.mod ] && stacks+=(go)
[ -f Gemfile ] && stacks+=(rb)
[ -d .claude ] && stacks+=(claude)
```

Record the detected stacks for the end-of-run summary.

### 3. Pre-fetch existing audit-labeled issues (dedup)

Use the tier-2 dedup query from `app-audits:filing-github-issues`:

```bash
gh issue list --repo <owner/repo> --search '"audit-key="' --state all --limit 100 \
  --json number,title,state,labels,body
```

Cache the result.

### 4. Walk the catalog

For each catalog item:

1. **Applicability filter.** If the item's `applies_to` is non-empty and shares zero elements with the detected `stacks`, skip the item and record it in the "not applicable to stack" summary section.

2. **Detection probe.** Run the `Detect` bash block. The convention: the probe prints something / returns 0 when the thing **exists**, and prints nothing / returns non-zero when the thing is **missing**. (Some probes have inverted logic — read the item's commentary.)

3. **Skip if present.** If the probe indicates the item exists, skip — record nothing.

4. **Dedup check.** Build the `audit-key` (from the item's `Audit key:` line). Search the cached pre-fetched list for an issue body containing `audit-key=<your-key>`. If found AND open → skip and add to "Skipped (duplicates)". If found AND closed → file a new issue with `**Regression of #N**` as the first line of the body. If no match → file fresh.

5. **File the issue.** Use the body template below. Labels:
   - `audit:dx` (always)
   - The item's severity (`P0` / `P1` / `P2`)
   - `needs-triage` if the item has `Needs triage: yes`
   - Any conventionally-named labels that exist in the repo and apply (`enhancement`, `documentation`, `ci`, `chore`)

### 5. Body template

```markdown
Found by `dx` audit on <YYYY-MM-DD>.

## Finding

<category>: missing <human-readable thing>. Detection probe evidence:

\`\`\`
<one-line output / observation from the probe — e.g., "no .prettierrc.* and no `prettier` key in package.json">
\`\`\`

Detected stack: `<comma-separated tags>`

## Why it matters

<verbatim from catalog row's "Why it matters">

## Suggested approach

<verbatim from catalog row's "Suggested approach">

## Acceptance criteria

- [ ] <from catalog row>
- [ ] <from catalog row>

<!-- audit-key=<the item's Audit key> -->
```

### 6. End-of-run summary

```
DX audit:
<one-line verdict — e.g., "Polished repo, 2 small gaps" or "Greenfield repo, full catalog applies">

Stack detected: <comma-separated tags>
Items in catalog: 25 (after stack filter: <N>)
Gaps found: <K>
  Tooling (P1): <n>
  Onboarding (P2): <n>
  Observability (P2): <n>
  Claude Code (P2): <n>

Filed <K> issues:
- #NNN <title> (URL) [needs-triage]
...

Skipped (duplicates):
- <finding> → existing #NNN

Skipped (not applicable to stack):
- <id> (reason)
```

## Don't

- Don't file items whose detection probe says the thing exists.
- Don't file items whose `applies_to` doesn't overlap the detected stacks.
- Don't re-file an open issue with the same `audit-key`.
- Don't auto-implement the recommendation — that's `/do-work`'s job.
- Don't `git add` or commit anything.
- Don't ask for approval before filing.
- Don't moralize or add taste-based recommendations beyond the catalog.
````

- [ ] **Step 2: Verify the file exists**

```bash
[ -f plugins/app-audits/agents/dx-auditor.md ] && echo "OK"
head -5 plugins/app-audits/agents/dx-auditor.md
```

Expected: `OK` followed by frontmatter.

- [ ] **Step 3: Commit**

```bash
git add plugins/app-audits/agents/dx-auditor.md
git commit -m "feat(app-audits): add dx-auditor agent"
```

---

## Task 7: Wire `dx-auditor` into `filing-github-issues`

**Files:**
- Modify: `plugins/app-audits/skills/filing-github-issues/SKILL.md`

- [ ] **Step 1: Add `dx-auditor` to the agent-label table**

Open `plugins/app-audits/skills/filing-github-issues/SKILL.md`. Find the label table that starts with `| Agent | Required label | Color (if auto-creating) |`. Add a new row before the closing of the table (between `testing-auditor` row and the section heading below it):

```markdown
| `dx-auditor` | `audit:dx` | `c5def5` |
```

- [ ] **Step 2: Add new audit-key examples**

Find the audit-key examples table (the one starting `| Finding | audit-key |`). Add these rows at the end (before the section break):

```markdown
| DX: missing Prettier config | `dx/tooling/missing-prettier` |
| DX: missing CONTRIBUTING.md | `dx/onboarding/missing-contributing` |
| DX: missing error tracking SDK | `dx/observability/missing-error-tracking` |
| DX: missing CLAUDE.md | `dx/claude-code/missing-claude-md` |
```

- [ ] **Step 3: Verify**

```bash
grep -c "audit:dx\|dx/tooling\|dx/onboarding\|dx/observability\|dx/claude-code" \
  plugins/app-audits/skills/filing-github-issues/SKILL.md
```

Expected: `5` or more (1 label row + 4 audit-key examples).

- [ ] **Step 4: Commit**

```bash
git add plugins/app-audits/skills/filing-github-issues/SKILL.md
git commit -m "chore(app-audits): register dx-auditor in filing-github-issues"
```

---

## Task 8: Wire `dx` into `/audit` dispatch

**Files:**
- Modify: `plugins/app-audits/commands/audit.md`

- [ ] **Step 1: Add `dx` to the dispatch table**

Open `plugins/app-audits/commands/audit.md`. Find the dispatch table (the one starting `| Type | Agents to dispatch | Needs URL? |`). Add a row for `dx` after the `testing` row:

```markdown
| `dx` | `app-audits:dx-auditor` | no |
```

- [ ] **Step 2: Add `dx` to the audit-type enum**

Find the line that begins `**Audit type** (required, first positional)`. Update the enum to include `dx`. The new line reads:

```markdown
- **Audit type** (required, first positional): one of `lighthouse`, `web-ux`, `mobile-ux`, `ux` (= web-ux + mobile-ux), `security`, `a11y`, `seo`, `privacy`, `release-readiness`, `pwa`, `tech-debt`, `testing`, `dx`, or `all`.
```

- [ ] **Step 3: Verify**

```bash
grep -E "(\`dx\`|app-audits:dx-auditor)" plugins/app-audits/commands/audit.md
```

Expected: at least 2 matches (the enum entry and the dispatch-table row).

- [ ] **Step 4: Commit**

```bash
git add plugins/app-audits/commands/audit.md
git commit -m "feat(app-audits): wire dx into /audit dispatch and all fan-out"
```

---

## Task 9: Bump plugin version

**Files:**
- Modify: `plugins/app-audits/.claude-plugin/plugin.json`

- [ ] **Step 1: Bump from 0.9.0 to 0.10.0**

Edit `plugins/app-audits/.claude-plugin/plugin.json`:

```json
{
  "name": "app-audits",
  "version": "0.10.0",
  ...
}
```

- [ ] **Step 2: Verify**

```bash
jq -r .version plugins/app-audits/.claude-plugin/plugin.json
```

Expected: `0.10.0`.

- [ ] **Step 3: Commit**

```bash
git add plugins/app-audits/.claude-plugin/plugin.json
git commit -m "chore(app-audits): 0.10.0 — ship dx-auditor"
```

---

## Task 10: Smoke test — run `/audit dx` against a sandbox repo

**Files:**
- *(none modified — manual verification)*

- [ ] **Step 1: Identify a sandbox repo**

Pick a target repo — ideally one of:
- A throwaway repo the user owns (best — issues filed there don't pollute production trackers)
- A personal scratch repo with `audit:dx` issues already cleared

Do NOT smoke-test against this `claude-plugins` repo: it's the *source* of the plugin, and filing 5+ issues here makes a mess of the tracker.

- [ ] **Step 2: Run the audit**

From a Claude Code session in the sandbox repo:

```
/audit dx --repo <owner/sandbox-repo>
```

- [ ] **Step 3: Verify the agent's output**

Expected end-of-run summary contains:
- A "Stack detected" line listing the detected stacks
- An "Items in catalog" line: `25 (after stack filter: <N>)`
- A "Filed K issues" list with GitHub URLs
- `[needs-triage]` annotation on any issues for opinionated items (error tracking, analytics, feature flags, recommended MCP)

Spot-check at least one filed issue on GitHub:
- Title starts with a Conventional Commits prefix (`chore(dx):`, `docs(dx):`, `feat(dx):`)
- Body has all five sections (Found by, Finding, Why it matters, Suggested approach, Acceptance criteria)
- Body ends with `<!-- audit-key=dx/<category>/<id> -->`
- Labels include `audit:dx` and a priority (`P1` or `P2`)

- [ ] **Step 4: No commit needed** — smoke test only.

---

## Task 11: Idempotency test — re-run and verify zero new issues

**Files:**
- *(none modified — manual verification)*

- [ ] **Step 1: Run `/audit dx` against the same sandbox repo a second time**

```
/audit dx --repo <owner/sandbox-repo>
```

- [ ] **Step 2: Verify summary shows zero new filings**

Expected:
- "Filed 0 issues" (or no "Filed" section at all)
- "Skipped (duplicates)" section lists the issues from the first run

If any issues are re-filed, that indicates an audit-key mismatch between the catalog row and the issue body. Open the relevant catalog item and confirm the `Audit key:` line matches the body's `<!-- audit-key=... -->` marker exactly.

- [ ] **Step 3: No commit needed** — idempotency check only. If anything's off, fix it inline (edit catalog or agent) and amend the relevant commit before pushing.

---

## Task 12: Push branch + open PR

**Files:**
- *(no edits)*

- [ ] **Step 1: Push the feature branch**

```bash
git push -u origin feat/dx-auditor
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --title "feat(app-audits): 0.10.0 — ship dx-auditor" --body "$(cat <<'EOF'
## Summary

- New `dx-auditor` agent walks a 25-item catalog of polished-repo features and files one GitHub issue per gap.
- Categories: standard tooling (P1, 8 items), onboarding docs (P2, 8), observability (P2, 5), Claude Code setup (P2, 4).
- Stack-aware detection (skips items not applicable to detected stacks).
- `needs-triage` label on vendor-choice items (error tracking, analytics, feature flags, recommended MCP).
- Plugs into the existing `/audit dx`, `audit:dx` label, audit-key idempotency, and `/do-work` pickup pattern.
- Spec: `docs/superpowers/specs/2026-05-17-dx-auditor-design.md`.

## Test plan

- [x] Catalog file lints clean (`bash -n` on extracted probes).
- [x] `/audit dx` against sandbox repo files expected issues with correct labels + audit-keys.
- [x] Second run of `/audit dx` files zero new issues (idempotency).
- [ ] Spot-check filed issue body: title prefix, all five sections, audit-key marker, labels.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Enable auto-merge + return to main**

```bash
gh pr merge --auto --squash
git checkout main
git pull --ff-only
```

End state: on `main`, working tree clean. The PR is queued for auto-merge once checks pass.
