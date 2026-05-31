---
name: filing-github-issues
description: Use when filing GitHub issues from an audit — provides title-prefix conventions, label discovery, duplicate search, body templates, and the safe `gh issue create` pattern. Invoked by every agent in the `shipyard` plugin.
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
| `dx-auditor` | `audit:dx` | `c5def5` |

**Auto-create your audit:* label if it doesn't exist** — this is the one exception to the "don't auto-create labels" rule, because the label is the agent's own metadata, not a repo-config decision. Do this once at the start of the run:

```bash
gh label list --repo <owner/repo> --limit 100 | grep -q "^audit:<dimension>" || \
  gh label create "audit:<dimension>" --repo <owner/repo> --color c5def5 --description "Created by shipyard:<agent-name>"
```

Then pass `--label "audit:<dimension>"` on every `gh issue create` you do.

## `needs-triage` label (when the finding needs refinement before work)

Apply `needs-triage` to any issue you file that **can't be picked up by `/do-work` as-is** because it requires human judgment before implementation. Signals:

- Root cause is ambiguous — the symptom is real but the fix path requires investigation you couldn't do from the audit surface.
- Acceptance criteria can't be made concrete without product/design/legal input (e.g., "what should the empty state look like?").
- Scope spans multiple surfaces or repos and needs decomposition into smaller issues.
- The finding implies a decision (which library to adopt, whether to deprecate an API) rather than a mechanical fix.

If the finding is clean — concrete evidence, obvious fix, verifiable acceptance criteria — do **not** apply `needs-triage`. The label exists to keep `/do-work` from burning agent time on under-specified work; it's not a generic "needs review" flag.

This label is part of the plugin's workflow contract with `/do-work`, so **auto-create it if missing** (same exception as `audit:*`):

```bash
gh label list --repo <owner/repo> --limit 100 | grep -q "^needs-triage" || \
  gh label create "needs-triage" --repo <owner/repo> --color fbca04 --description "Needs refinement before /do-work picks it up"
```

Then pass `--label "needs-triage"` on the `gh issue create` for that finding. Note in your end-of-run summary which issues you triaged out (with reason) so the user knows what's awaiting their input.

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
| DX: missing Prettier config | `dx/tooling/missing-prettier` |
| DX: missing CONTRIBUTING.md | `dx/onboarding/missing-contributing` |
| DX: missing error tracking SDK | `dx/observability/missing-error-tracking` |
| DX: missing CLAUDE.md | `dx/claude-code/missing-claude-md` |

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

Required — most target repos enforce this via commitlint, and the conventional-commit title is what release-please picks up to drive changelog + version bumps. Pick:

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
<!-- audit-run=<run-id> -->   (only when the orchestrator supplied a run id — see "Per-run attribution marker")
```

**The `audit-key` HTML comment is mandatory** — it powers idempotent re-runs. If a body would ship without it, that's a bug in your filing process. The `audit-run` comment is conditional — include it only when the dispatch prompt supplied a run id (see "Per-run attribution marker" below).

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

## Capture the real issue number — never guess or read it back stale (REQUIRED)

`gh issue create` prints the URL of the issue it just created to **stdout** (e.g. `https://github.com/<owner>/<repo>/issues/152`). That URL — and the number derived from it — is the **only** authoritative record of what you filed. Capture it inline and report exactly that:

```bash
issue_url=$(gh issue create --repo <owner/repo> \
  --label <label1> --label <label2> \
  --title "<conventional-commit title>" \
  --body "$(cat <<'EOF'
<body>
EOF
)")
echo "filed: $issue_url"   # e.g. https://github.com/<owner>/<repo>/issues/152
```

**This matters because audits dispatch many auditors in parallel** (the `all` path runs 12+ agents at once). GitHub assigns issue numbers **sequentially across all concurrent creates**, so a number you predict ("the last issue was #149, so mine will be #150") or read back with a *separate* `gh issue list` *after* filing is unreliable — a sibling auditor's concurrent create may have taken the number you expected, and your read-back can return a stale or colliding value. The result is agent summaries whose issue numbers don't match what was actually filed, colliding numbers across agents, and — worst case — a genuine finding that was silently lost because nobody held its real number. This is the failure mode [#435](https://github.com/mattsears18/shipyard/issues/435) documents (a 15-auditor `mattsears18/mattsears18.com` run where two auditors both reported `#150`/`#152` and one real finding was never traced to its actual number).

Hard rules:

- **Never report a predicted number.** Don't compute "next issue number will be N" from a pre-fetch and report N.
- **Never report a number read back from a separate post-filing `gh issue list`.** The concurrent-create race makes the read-back ambiguous. The `gh issue create` stdout is captured *inside the create call itself*, so it can't race.
- **Report the captured URL verbatim** in your return summary (the number is derivable from the URL; when in doubt report the full URL, which is unambiguous). See "Return summary — report captured URLs" below.

If `gh issue create` fails (non-zero exit, empty stdout), treat that finding as **not filed** — report it in your summary as a filing failure with the error, do NOT report a guessed number for it.

## Per-run attribution marker (when the orchestrator supplies a run id)

When the dispatching `/shipyard:audit` prompt supplies an **audit run id** (a short token unique to this `/audit` invocation), append it to every issue body as a hidden HTML comment alongside the `audit-key`:

```
<!-- audit-run=<run-id> -->
```

This lets the orchestrator definitively attribute filed issues to a single audit run when it reconciles after all agents return — it can `gh issue list --search '"audit-run=<run-id>"'` to enumerate exactly what this run produced, cross-check that count against the URLs each agent reported, and flag any agent whose reported URLs don't resolve (a lost or misreported filing). The marker is run-scoped and volatile by design — unlike `audit-key` (which is stable across runs for dedup), `audit-run` changes every invocation, so do NOT use it for deduplication. When the prompt supplies no run id, omit the marker.

## Return summary — report captured URLs

Your end-of-run summary's "Filed N issues" list MUST report the **captured `gh issue create` URLs** from the section above — one line per issue, the verbatim URL (the number is derivable from it). Never a predicted number, never a number from a separate post-filing `gh issue list`. If a `gh issue create` failed, list that finding under a "Filing failures" line with the error instead of a number, so the orchestrator's reconciliation can tell a lost finding apart from a successfully-filed one.

## Don't

- Don't comment on issues you didn't create unless the user explicitly asks — permission system may deny it.
- Don't `git add` or commit anything.
- Don't push branches.
- Don't ask the user for approval before filing — file P0–P2 findings autonomously, report at the end.
- Don't file taste / "would be nice" suggestions.
- Don't file findings with no evidence (no screenshot, no DOM, no metric → don't file).
