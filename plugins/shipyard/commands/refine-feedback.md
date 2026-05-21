---
description: Back-compat alias for `/shipyard:refine-issues` — see that command for the full spec. The user-feedback classify+rewrite flow now lives in one branch of a source-branched refiner.
argument-hint: [--repo owner/repo] [--issue N] [--concurrency N] [--dry-run]
---

# /refine-feedback (back-compat alias)

`/refine-feedback` is the **back-compatibility alias** for [`/refine-issues`](./refine-issues.md). The two commands are equivalent — they route to the same refinement logic and accept the same arguments.

The rename happened in shipyard 1.3.28 (closes [#145](https://github.com/mattsears18/claude-plugins/issues/145)) when the `needs-refinement` label was generalized from a `user-feedback`-only intake into a universal "this issue isn't ready for `/do-work` dispatch yet" pipeline gate. The user-feedback classify+rewrite flow is now one branch of a source-branched refiner — see `/refine-issues` for the full source-branch table and worker prompt template.

**There is no separate spec here** — invoking `/refine-feedback` invokes `/refine-issues` with the same args. Future plugin versions may drop this alias once muscle memory has converted. Update any local notes / wiki entries / dispatch scripts to use `/refine-issues` directly.

## What to read instead

- **Full refinement spec, source-branch table, worker prompt:** [`./refine-issues.md`](./refine-issues.md)
- **Intake contract for the user-feedback backend** (token discipline, rate limits, body shape): [`./refine-issues.md`](./refine-issues.md#intake-contract-read-this-if-youre-wiring-up-the-user-feedback-backend)
- **What changes vs the old `/refine-feedback` semantics:**
  - The candidate query no longer requires `user-feedback` — it pulls every open `needs-refinement` issue and branches per-issue.
  - The `needs-refinement` label is now applied conditionally at intake by `.github/workflows/intake-refinement-gate.yml`, not exclusively by the user-feedback backend.
  - `needs-human-review` is decoupled from `needs-refinement` — only the `user-feedback` classify+rewrite branch (and `issue-worker.md` step 6 for external-PR origins) co-applies it.
  - New `escalate-to-triage` fall-through branch swaps `needs-refinement` for `needs-triage` when no refiner rule matches.

The behavior for the `user-feedback` + `needs-refinement` combination is unchanged from the pre-rename spec — only the file the spec lives in moved.
