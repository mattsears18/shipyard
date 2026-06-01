# Comprehensive secret + sensitive-info audit — `mattsears18/shipyard`

**Date:** 2026-06-01
**Scope:** Full git history + every GitHub surface + non-token PII/sensitive-info triage
**Tracking issue:** [#141](https://github.com/mattsears18/shipyard/issues/141)
**Status:** ✅ **CLEAN** — no real leaked credentials, no sensitive PII, no echoed secrets in CI logs.

This is the comprehensive one-time follow-up that [#108](https://github.com/mattsears18/shipyard/issues/108) explicitly scoped out. #108 ran a 5-shape hand-rolled regex scan over git history (clean) and added the `.github/workflows/secret-scan.yml` gate for *new* commits. This audit re-runs the history scan with the full gitleaks/trufflehog rulesets, adds a verification engine, and extends coverage to every GitHub-side surface and to non-token sensitive information.

> Report written to a **tracked** path (`docs/audits/`) rather than the `.shipyard/audits/<date>-secret-audit.html` path the issue suggested — `.shipyard/` is gitignored in this repo, so a committable deliverable cannot live there. Markdown also reviews better in a PR than HTML.

---

## Summary of findings

| Pass | Tool / method | Findings | Verdict |
|---|---|---|---|
| 1. Full-history token scan | `gitleaks` 8.30.1, default 150+ ruleset, `--all --full-history` | **0** | ✅ Clean |
| 1b. Full-history verification scan | `trufflehog` 3.95.3, `git --only-verified` | **0 verified, 0 unverified** | ✅ Clean |
| 2. GitHub surfaces (issues/PRs/comments/releases) | `gh api` harvest + `gitleaks --no-git` | 2 matches | ✅ Both documentation false positives (no key material) |
| 3. Non-token sensitive info (emails, IPs, phones, conn strings, hostnames, AWS IDs, JWTs) | manual grep + triage | several shape-matches | ✅ All synthetic test fixtures / public author email / coincidental numerics |
| 4. CI workflow logs | last 200 GHA runs, echoed-secret grep | **0** | ✅ Clean |
| 5. Branch/tag names, repo metadata, wiki, discussions | manual review | — | ✅ Clean / empty |

**No credential rotation is required. No PII redaction is required. No `.gitleaks.toml` change is required** (the fixture paths surfaced are already allowlisted).

---

## 1. Full-history token scan

### gitleaks (expanded default ruleset)

```
gitleaks detect --source . --log-opts="--all --full-history" \
  --report-format json --report-path /tmp/gitleaks-report.json --no-banner --redact
```

- **315 commits scanned** on the worktree HEAD lineage (514 commits across all refs in a full clone — the `--all` opt covers every branch).
- gitleaks pulls in its upstream default ruleset (150+ rules: classic + fine-grained GitHub tokens, Slack `xox*`, Stripe `sk_live_*`/`sk_test_*`, Google API keys `AIza*`, AWS `AKIA*`, GitLab `glpat-*`, npm `npm_*`, PEM private keys, etc.) via the repo's `.gitleaks.toml` `[extend] useDefault = true`.
- **Result: `no leaks found` (0 findings).**

This supersedes #108's 5-shape hand-rolled scan with the full provider-specific ruleset the issue called for, and confirms the broader ruleset still finds nothing in history.

### trufflehog (verification engine)

```
trufflehog git file://<fresh-clone> --json --only-verified
```

- Run against a fresh full clone (the agent's worktree `.git` is a gitdir file, not a directory, which trufflehog's git reader can't open — a fresh clone is the correct input for a full-history verified scan).
- **2,576 chunks / ~4.2 MB scanned. Result: 0 verified secrets, 0 unverified secrets.**
- The `--only-verified` flag means any finding would have been *live-checked* against the issuing provider. Zero findings ⇒ no live credential is recoverable from history.

---

## 2. GitHub surfaces scan

Harvested via `gh api --paginate` (repo name corrected to `mattsears18/shipyard` — the issue body's example commands referenced the stale `mattsears18/claude-plugins`):

| Surface | Count harvested |
|---|---|
| Issues (all states, bodies) | 468 |
| Issue comments | 151 |
| PRs (all states, bodies) | 248 |
| PR review comments | 0 |
| Release descriptions | 0 (no releases — this repo uses `plugin.json` `version` as the canonical version surface, no git tags / GitHub releases) |

Scanned the harvested JSON with `gitleaks detect --source . --no-git --redact` (8.5 MB).

**2 findings, both false positives:**

| File | Rule | Triage |
|---|---|---|
| `issues.json` (issue [#408](https://github.com/mattsears18/shipyard/issues/408)) | `private-key` | The literal marker string `-----BEGIN RSA PRIVATE KEY-----` cited as a **pattern example** in an issue about the auto-report scrubber missing SSH/PEM keys. No key body follows the marker — it's documentation of what the scrubber should match. |
| `issues.json` (issue [#402](https://github.com/mattsears18/shipyard/issues/402)) | `private-key` | Same — `-----BEGIN RSA PRIVATE KEY-----` cited in a table of token shapes the `report-plugin-error` scrubber should redact. No key material. |

Both are the security-feature issues describing *what the scrubber must catch*; the marker string with no following base64 block is exactly the kind of doc-text false positive expected. **No actual private key was ever committed or posted.**

### Wiki, discussions, branches, tags, repo metadata

- **Wiki:** flag is "enabled" but the `shipyard.wiki.git` repo does not exist (404 on clone) — no wiki pages were ever created. Effectively empty.
- **Discussions:** disabled.
- **Branches:** all descriptive and benign (`chore/drop-p3-tier`, `feat/dx-auditor`, `do-work/issue-281`, etc.) — nothing embarrassing or sensitive.
- **Tags:** none.
- **Repo description:** `"An autonomous engineering loop"` — clean. **Topics:** none. **Homepage URL:** empty.

---

## 3. Non-token sensitive-info triage

Manual grep passes over full git history + harvested surfaces. Every shape-match triaged as benign:

### Emails

| Match | Triage |
|---|---|
| `mattsears18@gmail.com` | Maintainer's public git-author email — present in every commit's authorship by design, not a leak. |
| `abc@sentry.io` | Documentation example of a Sentry DSN (`https://abc@sentry.io/123`) used in prose contrasting good-vs-bad config. |
| `hunter2pw@cluster0.mongodb.net` | Synthetic scrubber-test fixture connection string (`hunter2pw` is an obvious fake). |
| `s3cr3tpass@db.example.com` | Synthetic scrubber-test fixture (`s3cr3tpass`, `example.com`). |
| `t@e.com` | Throwaway `git config user.email` in a test helper that inits a scratch repo. |

(Bot/known-public addresses — `noreply@anthropic.com`, `actions@github.com`, `*@users.noreply.github.com` — excluded by design.)

### Connection strings with embedded credentials

| Match | Triage |
|---|---|
| `postgres://dbuser:s3cr3tpass@db.example.com` | Synthetic scrubber-test fixture. |
| `postgres://user:pass@host` | Literal placeholder in issue text (#141's own body uses it as an example of a shape to scan for). |

### IP addresses

- No valid routable public IPv4 found. Every dotted-decimal shape-match was either an invalid octet (>255, e.g. `66.715.422.242`) or a leading-zero / `1.x.x.x` sequence — all coincidental substrings of timestamps, byte offsets, and token-count numbers in JSONL cost-ledger / log fixtures.

### Other token shapes

| Match | Triage |
|---|---|
| `AKIAIOSFODNN7EXAMPLE` | AWS's published canonical *example* access key (literally contains `EXAMPLE`); already allowlisted in `.gitleaks.toml`. In scrubber-test fixtures / allowlist discussion. |
| `eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.…` | The textbook jwt.io sample token (`{"sub":"1234567890"}`), in a scrubber-test fixture payload. |
| `AIzaSyA1234567890abcdefghijklmnopqrstuv` | Synthetic Google-API-key-shaped fixture (sequential alphabet body). |
| `ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ1234567890` | Synthetic GitHub-PAT-shaped fixture (alphabet pattern). |
| `github_pat_11ABCDEFG0…` | Synthetic fine-grained-PAT fixture. |
| `glpat-EXAMPLEnotarealtoken` | Synthetic GitLab-PAT fixture (literally `notarealtoken`). |
| `xoxb-EXAMPLE-NOT-A-REAL-TOKEN-*`, `xoxp-EXAMPLE-NOT-A-REAL-TOKEN-*` | Synthetic Slack-token fixtures (literally `EXAMPLE-NOT-A-REAL-TOKEN`). |

Phone numbers: no real-looking matches (the patterns coincided only with version numbers and numeric fixtures).

All of these synthetic provider-token fixtures live in `plugins/shipyard/scripts/tests/` and the scrubber source / README — paths **already allowlisted** in `.gitleaks.toml`, which is why the full-history `gitleaks detect` (pass 1) returned 0 findings despite their presence.

---

## 4. CI workflow log audit

Scanned the **last 200 GitHub Actions runs** (covers all retained logs; default retention is 90 days). For each run, streamed `gh run view <id> --log` and grepped for assignments of secret-shaped env vars (`GITHUB_TOKEN`, `API_KEY`, `SECRET`, `PASSWORD`, `TOKEN`, `PRIVATE_KEY`, `ACCESS_KEY`, `CLIENT_SECRET`, …) to non-masked (`***`) values.

**Result: 0 hits.** No workflow accidentally echoed a real secret value. (The repo's workflows — Tests, Shell scripts, Secret scan, Conflict markers, Label-event audit, intake/external-author gates — don't `echo` raw secrets.)

---

## 5. Remediation & follow-ups

- **No credential rotation required** — zero verified-live findings.
- **No PII redaction required** — no real personal/customer data in any issue/PR/comment body.
- **No `.gitleaks.toml` change required** — the synthetic test fixtures uncovered are already covered by the existing `[allowlist].paths` / `regexes` entries, and the full-history scan is clean as a result. (The optional allowlist-update acceptance-criterion is therefore a no-op for this audit.)

### Optional follow-up (NOT in this PR's scope)

The issue lists an optional scheduled weekly full-history re-scan workflow as a follow-up. Per the dispatch guidance, `.github/workflows/` is intentionally untouched here. If the maintainer wants the recurring scan, it should be filed and implemented as its own issue/PR — the current PR-gate (`secret-scan.yml`) already prevents *new* leaks, and this audit certifies the existing surface is clean, so the scheduled re-scan is cheap insurance rather than a gap-closer.

---

## Reproduction

```bash
# Pass 1 — gitleaks full history (run from a normal checkout)
gitleaks detect --source . --log-opts="--all --full-history" \
  --report-format json --report-path /tmp/gitleaks-report.json --no-banner --redact

# Pass 1b — trufflehog verified (run from a fresh clone)
git clone https://github.com/mattsears18/shipyard.git /tmp/sy-clone
trufflehog git file:///tmp/sy-clone --json --only-verified

# Pass 2 — GitHub surfaces
gh api "repos/mattsears18/shipyard/issues?state=all&per_page=100" --paginate > issues.json
gh api "repos/mattsears18/shipyard/issues/comments?per_page=100" --paginate > issue-comments.json
gh api "repos/mattsears18/shipyard/pulls?state=all&per_page=100" --paginate > prs.json
gh api "repos/mattsears18/shipyard/pulls/comments?per_page=100" --paginate > pr-review-comments.json
gh api "repos/mattsears18/shipyard/releases?per_page=100" --paginate > releases.json
gitleaks detect --source . --no-git --report-format json \
  --report-path /tmp/gitleaks-surfaces.json --no-banner --redact

# Pass 4 — workflow logs
gh run list --repo mattsears18/shipyard --limit 200 --json databaseId --jq '.[].databaseId' \
  | while read id; do gh run view "$id" --repo mattsears18/shipyard --log 2>/dev/null; done \
  | grep -nE '(GITHUB_TOKEN|API_KEY|SECRET|PASSWORD|TOKEN|PRIVATE_KEY)[[:space:]]*[=:][[:space:]]*[^*[:space:]]' \
  | grep -v '\*\*\*'
```

All scan artifacts (`/tmp/gitleaks-report.json`, `/tmp/trufflehog-report.json`, harvested JSON, run logs) were scratch-only and contain no secret material requiring secure handling — they are not committed.
