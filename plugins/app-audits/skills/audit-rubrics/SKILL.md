---
name: audit-rubrics
description: Use when auditing any app to determine what to file vs skip — provides severity buckets (P0-P3), grouping rules, and "what NOT to file" defaults. Invoked by every agent in the `app-audits` plugin.
---

# Audit Rubrics

Shared severity, grouping, and "what to skip" rules across audit types. The point: keep the tracker high-signal.

## Severity buckets

| Bucket | Definition | File? |
|---|---|---|
| **P0** | Broken or unusable. Untappable buttons, overlapping elements, contrast failures on primary actions, runtime errors on the golden path, exposed secrets, RCE vectors. | Yes, always |
| **P1** | Significant friction or risk. Confusing affordances, hidden critical features, missing security headers, dark mode regressions, a11y failures on common flows, dependency CVEs without patches. | Yes |
| **P2** | Polish or moderate risk. Spacing inconsistencies, copy improvements, visual hierarchy nits, low-severity CVEs with patches available, missing best-practices headers. | Yes |
| **P3** | Taste or suggestion. Color refinements, animation ideas, "would be nice", subjective microcopy preferences. | **No** — default skip |

**Default cutoff: file P0–P2, skip P3.** Volume kills tracker signal.

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

- **P3 / taste.** "I'd use a more modern font." Not an issue.
- **Findings with no evidence.** No screenshot, DOM snippet, metric, or file path → drop the finding.
- **Platform-deprecation noise we can't fix.** Third-party cookies, future Chrome quirks not yet shipped.
- **Test infrastructure unless asked.** Flaky E2E tests are a separate concern from product quality audits.
- **Things already explicitly tracked.** Always run the duplicate search first.
- **Generic moralizing.** "Bad design" is not a finding. "Primary CTA contrast 2.8:1, fails WCAG AA" is.

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
