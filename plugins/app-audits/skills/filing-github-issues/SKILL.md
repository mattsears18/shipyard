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

**Auto-create your audit:* label if it doesn't exist** — this is the one exception to the "don't auto-create labels" rule, because the label is the agent's own metadata, not a repo-config decision. Do this once at the start of the run:

```bash
gh label list --repo <owner/repo> --limit 100 | grep -q "^audit:<dimension>" || \
  gh label create "audit:<dimension>" --repo <owner/repo> --color c5def5 --description "Created by app-audits:<agent-name>"
```

Then pass `--label "audit:<dimension>"` on every `gh issue create` you do.

## Search for duplicates before filing

For every finding, before `gh issue create`:

```bash
gh issue list --repo <owner/repo> --search "<distinctive-keyword>" --state all --limit 10 --json number,title,state
```

Pick distinctive keywords from the finding itself (`robots.txt`, `LCP`, `hydration`, `color contrast`, `tap target`, `Firebase rules`). If a closely-matching **open** issue exists, skip filing and note the existing issue number in your summary. A closed issue with the same title may indicate a regression — file with a "regression of #N" line in the body.

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
```

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
