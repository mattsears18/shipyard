---
name: audit-rubrics
description: Use when auditing any app to determine what to file vs skip — provides severity buckets (P0-P2), grouping rules, and "what NOT to file" defaults. Invoked by every agent in the `shipyard` plugin.
---

# Audit Rubrics

Shared severity, grouping, and "what to skip" rules across audit types. The point: keep the tracker high-signal.

## Severity buckets

| Bucket | Definition | File? |
|---|---|---|
| **P0** | Broken or unusable. Untappable buttons, overlapping elements, contrast failures on primary actions, runtime errors on the golden path, exposed secrets, RCE vectors. | Yes, always |
| **P1** | Significant friction or risk. Confusing affordances, hidden critical features, missing security headers, dark mode regressions, a11y failures on common flows, dependency CVEs without patches. | Yes |
| **P2** | Polish or moderate risk. Spacing inconsistencies, copy improvements, visual hierarchy nits, low-severity CVEs with patches available, missing best-practices headers. | Yes |

**File P0–P2.** Taste / "would be nice" suggestions are not findings — volume kills tracker signal.

## Grouping rules

**Group ruthlessly.** One issue should have a scope a single PR could plausibly close.

Group by:

- **Same root cause across surfaces.** Five surfaces with the same spacing inconsistency = one issue listing all five, not five issues.
- **Same area, related findings.** Three copy nits on the auth flow → one "copy pass on auth flow" issue.
- **Same audit-tool category.** All unused-JavaScript findings → one `perf(web): bundle size` issue.

Don't group:

- **Different platforms.** A web issue and an iOS issue with similar symptoms are separate issues — different fixes, different reviewers.
- **Different severities.** A P0 doesn't get bundled with P2s.
- **Different audit dimensions.** A security issue and a UX issue that both touch the login screen are separate issues.

If you're filing more than ~10–15 issues from a single audit, you're not grouping enough. Re-group before filing.

## Cross-audit dedup

When two audit agents catch the same thing (e.g. Lighthouse a11y flags low contrast, web-ux agent also flags it), file it once. The agent finishing first wins; the second agent's filing skill should find the open issue via the duplicate search and skip.

## What NOT to file

- **Taste / "would be nice."** "I'd use a more modern font." Not an issue.
- **Findings with no evidence.** No screenshot, DOM snippet, metric, or file path → drop the finding.
- **Platform-deprecation noise we can't fix.** Third-party cookies, future Chrome quirks not yet shipped.
- **Test infrastructure unless asked.** Flaky E2E tests are a separate concern from product quality audits.
- **Things already explicitly tracked.** Always run the duplicate search first.
- **Generic moralizing.** "Bad design" is not a finding. "Primary CTA contrast 2.8:1, fails WCAG AA" is.

## Decided not to file: leave a decision trail

When you consider a finding and decide NOT to file it for a contextual reason — "intentional per design doc X," "covered by open issue #N," "intentional tradeoff (see PR #M)," "applies to a stack we don't use," "out of scope for this audit dimension" — record the decision so the next audit doesn't re-litigate the same finding from scratch.

Two surfaces, both required when applicable:

1. **The audit's end-of-run summary.** Add a `Skipped (decided not to file)` section to the return summary, one bullet per skipped finding with the rationale. This sits alongside the existing `Skipped (duplicates)` block and uses the same shape. The next session's auditor reading the prior transcript (or `.shipyard/audits/<YYYY-MM-DD>-shipyard-audit.md`) sees the decision and doesn't re-flag.
2. **If the skipped finding has a natural home issue** — i.e., there's an existing open issue covering the area the finding sits in (e.g., a finding about a screen that already has an open issue, or a finding the next audit will re-derive from the same code) — also post a one-line comment on that issue: `Audit on <YYYY-MM-DD> considered <finding> and decided not to file: <rationale>`. Use `gh issue comment <N> --repo <owner/repo> --body "..."`. If the comment errors (rate limit, permission), log an advisory and continue — the in-summary record is the source of truth; the in-issue comment is the cross-reference.

What counts as "decided not to file" (vs. just "skipped" — different concept):

- **Skipped (duplicate)** — already-existing open issue covers it. Use the existing `Skipped (duplicates)` block. No new comment needed; the dedup-fingerprint match is the trail.
- **Skipped (not applicable to stack)** — the dx-auditor's existing "applies_to" filter, or any analogous "this category doesn't apply to this codebase" filter. The auditor's existing return summary already covers this category.
- **Decided not to file** — you considered filing and chose not to *because of context outside the audit's evidence bar* (intentional design choice, covered elsewhere, accepted tradeoff). This is the new category that needs the trail — the rationale would be lost otherwise.

If you didn't decide against anything, the section omits entirely. The threshold for adding a bullet is "the next auditor would re-derive this finding and re-consider filing if I don't write it down" — not every micro-skip merits a bullet.

## Evidence bar

Every issue needs at least one of:

- A screenshot path (web: from `take_screenshot`; mobile: from `store-assets/screenshots/*` or `maestro-output/*`)
- A DOM snippet (from `take_snapshot` or the Lighthouse `details.items[].node.snippet`)
- A specific metric (`LCP 2.6 s`, `contrast ratio 2.8:1`, `npm audit HIGH severity in <package>`)
- A specific file path + line (for code-level findings)

No evidence → not a finding worth filing.

## Title quality bar

A good audit issue title:

- Starts with the right Conventional Commits prefix + scope
- Names the surface or area concretely (`task card title`, `tab bar`, `Firebase storage rules`, `entry-*.js bundle`)
- Describes the *defect*, not the *fix* (`fix(web): task card title wraps mid-word on narrow viewports` — not `fix(web): add word-break-keep-all to task card title`)
- Reads as something an end user could understand (these titles often become public release notes)

Bad: `Improve task card`. Good: `fix(web): task card title overflows the avatar column at 375px`.
