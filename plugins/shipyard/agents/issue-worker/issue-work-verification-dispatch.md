# issue-work.md § 6.6 — Verification disposition: run the auditor, file bugs, disposition — without a PR ([#852](https://github.com/mattsears18/shipyard/issues/852))

On-demand fragment of [`issue-work.md`](./issue-work.md). Loaded only when that file's §6.6 stub says the dispatch prompt's Context block carries a "Verification slice" paragraph — see [#980](https://github.com/mattsears18/shipyard/issues/980) for why this content moved out of the always-loaded core (it's a rare carve-out whose deliverable isn't even a PR).

**Run this step only when the dispatch prompt's Context block carries a "Verification slice" paragraph** (set by [scope-preflight's QA-verification carve-out](../../commands/do-work/setup/06b-scope-carveouts.md#qa-verification-carve-out--run-the-automatable-audit-hand-back-only-the-manual-remainder-852)). When absent — the common case — this section does not apply and behavior is unchanged.

**This dispatch is fundamentally different from every other path in this file: the deliverable is verification, not a code change.** After [step 1](./issue-work.md#1-self-assign-gated-on-backlogself_assign-issue-1248) (self-assign), skip steps 2–6.5 entirely — there is normally no issue body to implement against, no branch, no diff, and no resolving PR to open. Proceed directly:

1. **Dispatch the named auditor.** The dispatch prompt's `verification_slice` names which auditor to run and against what surface (e.g. `functional-qa-auditor against https://test.example.com — sign-in, sign-up, and onboarding flow using the staged audit accounts`). Dispatch it via the `Agent` tool (`subagent_type` matching the named auditor, e.g. `shipyard:functional-qa-auditor`) against exactly that surface and the acceptance criteria it's meant to cover — do not widen the surface beyond what `verification_slice` describes, and do not re-implement the auditor's own filing logic: the auditor autonomously files `bug`-labeled GitHub issues for genuine findings per its own [`filing-github-issues`](../../skills/filing-github-issues/SKILL.md) skill. If the target surface requires authenticated access, follow [`auditing-authenticated-surfaces`](../../skills/auditing-authenticated-surfaces/SKILL.md) conventions (never echo secrets).

2. **Read the auditor's return.** It reports which criteria it exercised, a pass/fail verdict per criterion, and the numbers of any issues it filed. Treat this as the authoritative record — don't re-derive verdicts from your own reading of the surface.

3. **Incidental fix — narrow exception ([#1044](https://github.com/mattsears18/shipyard/issues/1044), widened from coverage-only by [#1623](https://github.com/mattsears18/shipyard/issues/1623)).** The default (below, in "Never open a PR…") still holds for the *resolving* slice: a verification dispatch ships no PR that closes its issue. This step carves out the shapes where landing a small PR anyway is sanctioned — originally the maintainer's own repeated coverage-gap pattern (issue #1044's #3329/PR #3374 precedent), now also a bug you have already diagnosed. It is still not an invitation to widen scope into implementation work.

   - **In scope — a coverage gap:** while running the audit or reading the code under test, you (or the auditor) find that the exercised path has **zero test coverage that the code itself already acknowledges** (e.g. a docstring or comment admitting the gap) — a mechanically-verifiable, trivially-fixable hole, not a design question. The fix is "add the missing test(s)," nothing more.
   - **In scope — a bug you have already diagnosed ([#1623](https://github.com/mattsears18/shipyard/issues/1623)):** a behavioral defect whose cause and fix you established while auditing, sitting in the same area as the surface under verification, needing no design decision. Write the failing test first, then the fix. Filing this instead would pay a second full worker dispatch to re-derive a diagnosis you already hold.
   - **Out of scope — file a follow-up `bug` issue:** a finding that reaches an unrelated subsystem, needs a judgment call this verification cannot settle, or is large enough to meaningfully raise the chance of reddening a required check. The bound is CI risk and unresolved design, not the mere fact that the finding is a bug.
   - **Reference, never close.** The PR body must carry a **bare reference** to the verification issue — `Refs #<N>` — never a closing keyword (`Closes`/`Fixes`/`Resolves #<N>`). This PR does not resolve `#<N>`; step 5's disposition (below) is what closes or gate-labels the verification issue, independent of whether this incidental PR exists.
   - **Otherwise the normal issue-work PR lifecycle applies.** Branch, implement (test-first, scoped to the coverage gap only — no drive-by changes), and commit per [`issue-work.md`](./issue-work.md) §§3–5, including the [§4.6](./issue-work.md#46-pre-push-local-unit-test-gate-658) pre-push unit-test gate. `gh pr create` with `Refs #<N>` in the body and `--label shipyard`. Gate auto-merge on `originating_author_trust` exactly per [§6](./issue-work.md#6-enable-auto-merge-gated-on-originating_author_trust) — an incidental PR opened from a verification dispatch is not exempt from the trust gate.
   - **No coverage gap found — the common case.** Skip this step entirely and continue to step 4 with no PR involved.

4. **Post a verification-status comment on `#<N>`** summarizing the run. A heredoc `--body "$(cat <<EOF ... EOF)"` is refused per [#979](https://github.com/mattsears18/shipyard/issues/979) — `shipyard:worker-preamble` § "Multi-line `--body` payloads"; write the content instead (with the `Write` tool) to `$WORKTREE_PATH/.shipyard-scratch/verification-status-comment.md`:

   ```
   ## Verification status (shipyard)

   Ran `<auditor>` against: <automatable surface, from verification_slice>

   **Checked:**
   - <criterion 1>: <passed | failed — see #<bug-issue>>
   - <criterion 2>: <passed | failed — see #<bug-issue>>

   **Incidental fix:** landed missing test coverage in #<incidental-PR> (Refs #<N>, no closing keyword)

   **Not automatable — still needs a human/device:** <verification_residual>
   ```

   Omit the "Incidental fix" line entirely when step 3 didn't fire. Omit the "Not automatable" line entirely when `verification_residual` is absent (the whole surface was automatable). Then:

   ```bash
   WORKTREE_PATH="$(git rev-parse --show-toplevel)"
   mkdir -p "$WORKTREE_PATH/.shipyard-scratch"
   gh issue comment <N> --repo <owner/repo> --body-file "$WORKTREE_PATH/.shipyard-scratch/verification-status-comment.md"
   ```

   No cleanup follows — see `worker-preamble` § "Scratch directory" ([#1347](https://github.com/mattsears18/shipyard/issues/1347)).

5. **Disposition:**
   - **`verification_residual` is present (the common case)** — apply `agent-console` (a plain device/browser recheck) or `needs-human-review` (a genuine human judgment call — e.g. a subjective design review) per whichever fits the residual's shape, and leave `#<N>` **OPEN**. Apply the label **ensure-then-label-then-verify**, the same idiom §6.5 uses:
     ```bash
     GATE_LABEL="agent-console"   # or "needs-human-review" — pick per the residual's shape
     gh label create "$GATE_LABEL" --repo <owner/repo> \
       --description "Operator/human review gate applied by a verification-disposition hand-back" 2>/dev/null || true
     gh issue edit <N> --repo <owner/repo> --add-label "$GATE_LABEL"
     ```
   - **`verification_residual` is absent** (the entire surface named in `verification_slice` was automatable and the auditor completed its sweep) — close `#<N>` as completed, citing the verification comment:
     ```bash
     gh issue close <N> --repo <owner/repo> --reason "completed" \
       --comment "Verification complete — see the status comment above. Closing as verified."
     ```

If the auditor dispatch itself fails to return (spawn error, tool denial), do not guess at a disposition — return `blocked #<N> at verification: auditor dispatch failed — <reason>` instead of step 5's blocked shape (same free-text vocabulary, just naming this step).

**Never open a *resolving* PR for the verification-only path** — the dispatched issue is already merged, so there is no slice that closes it, and step 5's disposition is what closes or gate-labels it regardless of whether a PR exists. Step 3's incidental carve-out is the only PR this path may produce, and it stays bounded on purpose ([#1623](https://github.com/mattsears18/shipyard/issues/1623)): the test is CI risk and unresolved design, so a finding that reaches an unrelated subsystem or needs a judgment call this verification cannot settle still goes to a follow-up `bug` issue. What is no longer a reason to file is the bare fact that the finding is a bug rather than a coverage gap — re-filing a defect you have already diagnosed buys a second worker dispatch to reach the same conclusion.

Once this fragment's disposition is applied, return to [`issue-work.md`](./issue-work.md) step 8 and return via the `verified #<N>` return shape — if step 3 opened an incidental coverage PR, include its number via step 8's optional `incidental PR: #<M>` suffix so the orchestrator appends it to `session_prs` and drains it like any other PR.
