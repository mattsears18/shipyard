---
name: filing-github-issues
description: Use when filing GitHub issues from an audit — provides title-prefix conventions, label discovery, duplicate search, body templates, and the safe `gh issue create` pattern. Invoked by every agent in the `app-audits` plugin.
---

# Filing GitHub Issues (audit conventions)

Shared filing conventions for audit agents. The point: one consistent issue shape across audit types so the tracker stays legible.

## Resolve the target repo

The orchestrator passes `<owner/repo>` in the agent prompt. Use it for every `gh` call. Don't re-resolve from cwd inside the agent — the orchestrator already did that.

## Discover labels once

Cache the result for the rest of the run:

```bash
gh label list --repo <owner/repo> --limit 100
```

Apply whichever of these actually exist: `bug`, `enhancement`, `documentation`, `design`, `a11y`, `performance`, `security`, `web`, `ios`, `android`, `ci`. If a useful label doesn't exist, *don't* create it autonomously — that's a repo-config decision. Use the closest existing label and note the missing label in your end-of-run summary so the user can decide.

## Agent-identifying label (REQUIRED)

Every issue you file MUST also carry an `audit:<dimension>` label identifying which audit agent filed it. Your agent's system prompt tells you which one to apply.

| Agent | Required label | Color (if auto-creating) |
|---|---|---|
| `lighthouse-auditor` | `audit:lighthouse` | `c5def5` |
| `web-ux-auditor` | `audit:web-ux` | `c5def5` |
| `mobile-ux-auditor` | `audit:mobile-ux` | `c5def5` |
| `security-auditor` | `audit:security` | `c5def5` |
| `a11y-auditor` | `audit:a11y` | `c5def5` |
| `seo-auditor` | `audit:seo` | `c5def5` |
| `privacy-auditor` | `audit:privacy` | `c5def5` |
| `release-readiness-auditor` | `audit:release-readiness` | `c5def5` |
| `pwa-auditor` | `audit:pwa` | `c5def5` |
| `tech-debt-auditor` | `audit:tech-debt` | `c5def5` |
| `testing-auditor` | `audit:testing` | `c5def5` |

**Auto-create your audit:* label if it doesn't exist** — this is the one exception to the "don't auto-create labels" rule, because the label is the agent's own metadata, not a repo-config decision. Do this once at the start of the run:

```bash
gh label list --repo <owner/repo> --limit 100 | grep -q "^audit:<dimension>" || \
  gh label create "audit:<dimension>" --repo <owner/repo> --color c5def5 --description "Created by app-audits:<agent-name>"
```

Then pass `--label "audit:<dimension>"` on every `gh issue create` you do.

## Deduplication (two-tier)

**This is the single most important section.** Repeat audits must not produce duplicate issues. Use both tiers — fingerprint first (deterministic), pre-fetched list second (judgment).

### Tier 1 — Fingerprint marker (deterministic)

Every issue body MUST end with a hidden HTML comment containing a stable `audit-key`:

```
<!-- audit-key=<dimension>/<finding-type>[/<scope>] -->
```

The fingerprint is the finding's stable identity — same finding on a future audit MUST produce the same key. Rules for constructing it:

- `<dimension>` is your agent's audit slug (`lighthouse`, `web-ux`, etc.)
- `<finding-type>` is a stable, kebab-case identifier for the *kind* of finding (use the Lighthouse audit ID directly when applicable, otherwise pick a short canonical name)
- `<scope>` is optional — include when the same finding-type can occur in multiple places (per-route, per-component, per-platform)

Examples:

| Finding | audit-key |
|---|---|
| Lighthouse `robots-txt` failing | `lighthouse/robots-txt` |
| Lighthouse `document-title` empty on `/register` | `lighthouse/document-title/register` |
| Lighthouse `errors-in-console` React #418 | `lighthouse/errors-in-console/react-418` |
| WCAG color contrast on primary button | `a11y/color-contrast/btn-primary` |
| Typography hierarchy issues across auth flow | `web-ux/typography-hierarchy/auth-flow` |
| Missing OG image on `/login` | `seo/missing-og-image/login` |
| Undisclosed Mixpanel processor | `privacy/undisclosed-processor/mixpanel` |
| Missing iOS app icon at 1024×1024 | `release-readiness/icon-missing/ios-1024` |
| PWA manifest missing 512×512 icon | `pwa/manifest-icon-missing/512` |
| Stale TODOs in `lib/auth/` | `tech-debt/stale-todos/lib-auth` |
| `@ts-ignore` pile-up in `lib/api/` | `tech-debt/suppression-pileup/ts-ignore/lib-api` |
| Skipped tests > 6mo in `billing/` | `tech-debt/stale-skipped-tests/billing` |
| Dead feature flag `new_checkout` | `tech-debt/dead-flag/new-checkout` |
| Internal calls to deprecated `getUserSync` | `tech-debt/deprecated-internal-use/getUserSync` |
| Direct dep `react-router` 2+ majors behind | `tech-debt/outdated-dep/react-router` |
| Critical-path coverage gap in `lib/auth/` | `testing/coverage-gap/lib-auth` |
| Test workflow not in branch protection | `testing/ci-gate-missing/branch-protection` |
| Empty/no-assertion tests in `billing/` | `testing/no-assertion-tests/billing` |
| Tautological assertions in `utils/` | `testing/tautological-assertions/utils` |
| Swallowed failures in async tests | `testing/swallowed-failures` |
| Title/body mismatch tests in `auth/` | `testing/title-body-mismatch/auth` |
| Snapshot-only on behavioral units in `hooks/` | `testing/snapshot-only-behavioral/hooks` |
| Repo has API routes but zero integration tests | `testing/missing-test-type/integration` |
| Flaky test `Auth › refresh token retries` | `testing/flaky-test/auth-refresh-token-retries` |
| Flaky job — `e2e.yml` retries on same SHA | `testing/flaky-job/e2e` |
| Test runner doesn't upload JUnit artifacts | `testing/no-test-reporting` |

DON'T include in the key:
- Timestamps, dates, version numbers
- Volatile file paths
- Random content from the finding
- Anything that would change across runs

### Tier 2 — Pre-fetched audit-labeled issues (judgment)

At the start of every run, before filing anything, fetch all issues across all audit dimensions in one call and cache the result:

```bash
gh issue list --repo <owner/repo> --search '"audit-key="' --state all --limit 100 \
  --json number,title,state,labels,body
```

This gives you the full universe of audit-filed issues. Use it for:

- **Cross-audit dedup** — when your finding overlaps with another agent's (e.g., both `lighthouse` and `a11y` catch color contrast), reading the cached bodies lets you detect the overlap and skip.
- **Fuzzy matches** — a finding whose audit-key has subtly shifted (e.g., the scope changed) but is clearly the same issue. Read titles + bodies; use judgment.

### Filing decision per finding

For each finding you'd file:

1. **Build the audit-key** for this finding.
2. **Check the cached pre-fetched list** for an issue whose body contains `audit-key=<your-key>` OR is semantically the same finding under a related key.
3. **If found and OPEN** → skip filing. Add to "Skipped (duplicates)" with the existing issue number.
4. **If found and CLOSED** → file a new issue. Add `**Regression of #N**` as the first line of the body and reuse the same audit-key.
5. **If no match** → file with the audit-key appended to the body.

This makes dedup behavior idempotent: running `/audit lighthouse` twice in a row should produce zero new issues on the second run.

## Conventional Commit title prefixes

Required — most target repos enforce this via commitlint and the squash-merge subject becomes the release-please commit. Pick:

| Intent | Prefix |
|---|---|
| Broken behavior, wrong output | `fix(<scope>):` |
| Missing feature / new content | `feat(<scope>):` |
| Performance optimization | `perf(<scope>):` |
| Build / tooling / source maps | `chore(<scope>):` |
| Documentation only | `docs(<scope>):` |
| Refactor without behavior change | `refactor(<scope>):` |
| Test additions | `test(<scope>):` |

Scope is the area: `web`, `ios`, `android`, `auth`, `a11y`, `design`, `ci`, etc. Multiple scopes allowed: `fix(a11y,web):`.

**The PR title that closes the issue ends up as the public ASC release note** (for app repos with release-please metadata sync). Write titles end-user-readable — no internal jargon, no vendor names where avoidable.

## Issue body template

```markdown
Found by `<audit type>` audit of `<url or surface>` on <YYYY-MM-DD>.

## Finding

<Specific, concrete, with evidence — screenshot path, DOM snippet, metric value, file path>

## Why it matters

<One-sentence impact. Tie to a principle when relevant (WCAG, HIG, Fitts, etc.).>

## Suggested approach

<Optional. Only if specific. Don't pad with generic advice.>

## Acceptance criteria

- [ ] <Verifiable outcome>
- [ ] <Cross-surface consistency check if relevant>
- [ ] <Regression guard for adjacent areas if relevant>

<!-- audit-key=<dimension>/<finding-type>[/<scope>] -->
```

**The `audit-key` HTML comment is mandatory** — it powers idempotent re-runs. If a body would ship without it, that's a bug in your filing process.

## Cross-references

Only reference issue numbers you verified this session via `gh issue view N` or `gh issue list --search`. Inventing numbers trips permission checks and pollutes the tracker.

## Filing command (HEREDOC pattern)

```bash
gh issue create --repo <owner/repo> \
  --label <label1> --label <label2> \
  --title "<conventional-commit title>" \
  --body "$(cat <<'EOF'
<body>
EOF
)"
```

HEREDOC with quoted `'EOF'` preserves backticks, dollar signs, and special chars in the body verbatim.

## Don't

- Don't comment on issues you didn't create unless the user explicitly asks — permission system may deny it.
- Don't `git add` or commit anything.
- Don't push branches.
- Don't ask the user for approval before filing — file P0–P2 findings autonomously, report at the end.
- Don't file P3 / taste suggestions.
- Don't file findings with no evidence (no screenshot, no DOM, no metric → don't file).
