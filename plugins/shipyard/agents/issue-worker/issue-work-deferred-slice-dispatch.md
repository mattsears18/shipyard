# issue-work.md § 6.7 — Deferred-slice disposition: hand back an autonomously-workable residual to a new issue, keep the issue open ([#986](https://github.com/mattsears18/shipyard/issues/986))

On-demand fragment of [`issue-work.md`](./issue-work.md). Loaded only when you discover, **mid-implementation**, that a dispatch-level constraint is blocking part of the issue's acceptance criteria — see the trigger below. Unlike [§6.5](./issue-work-split-dispatch.md) and [§6.6](./issue-work-verification-dispatch.md), nothing sets a Context paragraph for this ahead of time; there is no scope-preflight carve-out that predicts it, because the constraint isn't intrinsic to the issue — it's a property of *this session's* dispatch. You recognize the shape yourself, while implementing.

**Run this step only when ALL three hold:**

1. Your dispatch prompt's Context block states a **session-scoped, dispatch-level** restriction that isn't intrinsic to the issue itself — e.g. an explicit "Off-limits: `<path>` — another worker owns it this session" note, or any similar transient file/resource-ownership constraint the orchestrator (or a human curating the dispatch) imposed to avoid a race with a concurrently-dispatched sibling worker.
2. That restriction prevents you from satisfying every acceptance-criteria bullet in the issue within this PR — some AC items genuinely require touching the off-limits surface.
3. The deferred remainder is **autonomously workable** — ordinary follow-up code needing no human or operator judgment, blocked only by this session's transient constraint, not by anything intrinsic to the work.

If (3) doesn't hold — the remainder needs a human decision or an operator/browser action — this is **not** your shape: use [§6.5](./issue-work-split-dispatch.md) instead (its `agent-console`/`needs-human-review` residual label exists precisely for a remainder that needs a person). If (1) or (2) doesn't hold, this fragment doesn't apply at all — proceed with the ordinary resolving-PR path and skip straight to step 7.

**Why this differs from §6.5, not a rename of it.** §6.5 fires from a Context paragraph scope-preflight set *before* dispatch, because the residual needs a human — so the issue gets gated (`agent-console`/`needs-human-review`) until one acts. This shape is discovered by the worker itself, mid-implementation, and the residual needs no human at all — gating it with either label would strand ordinary, dispatch-ready work behind a review queue nobody needs to clear (exactly the P2 risk issue #986 flags: "a less-careful worker... could wrongly apply `needs-operator`/`needs-human-review` and strand an autonomously-workable follow-up behind a human gate"). So instead of a category label on `#<N>`, the residual becomes a **new, ungated GitHub issue**: immediately re-dispatchable by a future `/do-work` run the instant this session's transient constraint no longer applies. Nothing here is a new schema `outcome` value — like [#997](https://github.com/mattsears18/shipyard/issues/997)'s terminal-state-recheck bail before it, this rides the existing `shipped` outcome (see [issue-work.md](./issue-work.md) [step 8](./issue-work.md#8-return)); the `partial ... deferred to #<F>` qualifier is documentation, not new structured surface.

You are here because this PR ships only the completable slice; issue `#<N>` itself is not resolved. [§5's second exception](./issue-work.md#5-commit--push--pr) already required you to reference `#<N>` with a bare URL (never a closing keyword) and [§5.85's trigger shape (5)](./issue-work.md#585-post-pr-create-non-close-parentepic-leak-verification) already required the leak-verification loop to run treating `#<N>` as the protected issue — confirm both ran and passed before continuing.

1. **File a fresh follow-up issue** for the deferred acceptance-criteria items, per [`shipyard:filing-github-issues`](../../skills/filing-github-issues/SKILL.md) conventions — a clear title, the specific deferred AC bullets, a one-line note of *why* it was split out (name the off-limits/ownership constraint), and — on a repo with `milestones.enabled` + `milestones.assign_on_file` both `true` — a milestone resolved per `shipyard:worker-preamble`'s [`milestone-prohibition.md`](../../skills/worker-preamble/milestone-prohibition.md) fragment: inherit `#<N>`'s own milestone when it already has one; otherwise run `shipyard:filing-github-issues` § "Milestone assignment" in full (BET-matching against the open milestone list, falling back to `milestones.fallback` when nothing matches) — never skip straight to filing bare just because `#<N>` has no milestone to inherit (issue [#1421](https://github.com/mattsears18/shipyard/issues/1421)). Apply the `shipyard` session-stamp label **ensure-then-label** (this repo's standing convention — a missing label is created, never silently dropped) but apply **no gate label** — no `agent-console` and no `needs-human-review`. The entire point of this shape is that the follow-up is immediately dispatch-eligible, not parked behind a review queue.

   ```bash
   WORKTREE_PATH="$(git rev-parse --show-toplevel)"
   mkdir -p "$WORKTREE_PATH/.shipyard-scratch"
   ```

   Write the follow-up issue body (with the `Write` tool — a heredoc `--body "$(cat <<EOF ... EOF)"` is refused per [#979](https://github.com/mattsears18/shipyard/issues/979)) to `$WORKTREE_PATH/.shipyard-scratch/followup-issue-body.md`, then resolve the milestone (a no-op — `MILESTONE_TITLE` stays empty — when `milestones.enabled`/`milestones.assign_on_file` isn't both `true`):

   ```bash
   export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
   MILESTONE_TITLE=""
   milestones_enabled=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get milestones.enabled 2>/dev/null || echo false)
   milestones_assign_on_file=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get milestones.assign_on_file 2>/dev/null || echo false)
   if [ "$milestones_enabled" = "true" ] && \
      [ "$milestones_assign_on_file" = "true" ]; then
     # Tier 1 — inherit #<N>'s own milestone when it has one.
     MILESTONE_TITLE=$(gh issue view <N> --repo <owner/repo> --json milestone --jq '.milestone.title // empty' 2>/dev/null)
     # Tier 2 — #<N> has none: BET-match + fallback, same as any other filer.
     # Run shipyard:filing-github-issues § "Milestone assignment" steps 1-4
     # here against this follow-up's own content (never #<N>'s title/keywords)
     # when MILESTONE_TITLE is still empty at this point.
   fi
   ```

   ```bash
   gh label create shipyard --repo <owner/repo> \
     --description "Worked on by /shipyard:do-work" --color 5319E7 2>/dev/null || true
   # No `2>&1 | tail -1` — a pipe spanning a shell command boundary is refused
   # by the worktree-isolation guard (dont.md's post-relocation rule). With
   # `--json number --jq '.number'` the only thing gh writes to stdout IS the
   # number, so the tail was never load-bearing; leaving stderr unmerged is
   # also strictly better, since a gh error now lands on stderr where you can
   # read it instead of being captured as if it were the issue number.
   FOLLOWUP=$(gh issue create --repo <owner/repo> --label shipyard \
     --title "<deferred-scope title>" \
     --body-file "$WORKTREE_PATH/.shipyard-scratch/followup-issue-body.md" \
     ${MILESTONE_TITLE:+--milestone "$MILESTONE_TITLE"} \
     --json number --jq '.number')
   ```

   If `$FOLLOWUP` comes back empty, the create failed — read the error gh
   printed to stderr and bail rather than referencing an empty issue number.

2. **Reference `#<FOLLOWUP>` in this PR's body** — a plain mention (`Deferred to #<FOLLOWUP>: <one-line reason>`) is fine here. `#<FOLLOWUP>` is a brand-new issue this PR was never going to close, so there's no closing-link leak risk the way there is for the dispatched issue `#<N>` itself — that reference still needs the ordinary [§5](./issue-work.md#5-commit--push--pr) treatment (a `Closes` line if this PR genuinely resolves `#<N>` in full — it doesn't here, so use the bare-URL form for `#<N>` per the same rule §6.5 follows for its own non-closing case).

3. **Post a disposition comment on `#<N>`.** Write to `$WORKTREE_PATH/.shipyard-scratch/deferred-slice-comment.md`:

   ```
   ## Split disposition — completable slice shipped, remainder deferred to a new issue

   **Shipped:** <completable_scope> via PR #<M>.

   **Deferred:** <deferred_scope> — blocked this session by: <the off-limits/ownership constraint, named>. Tracked in #<FOLLOWUP> (no gate label — dispatch-ready once the constraint clears).

   This issue remains OPEN, with no gate label, so a future `/do-work` run can pick up the deferred slice once <constraint> no longer applies.
   ```

   Then:

   ```bash
   gh issue comment <N> --repo <owner/repo> --body-file "$WORKTREE_PATH/.shipyard-scratch/deferred-slice-comment.md"
   ```

   No cleanup follows — see `worker-preamble` § "Scratch directory" ([#1347](https://github.com/mattsears18/shipyard/issues/1347)).

**Do NOT apply any gate label to `#<N>` or to `#<FOLLOWUP>`.** Both stay unlabeled beyond the `shipyard` session stamp — that's the entire distinguishing property of this shape versus §6.5. If you find yourself reaching for `agent-console`/`needs-human-review` here, condition (3) above didn't actually hold and you're in the wrong fragment — go back to [§6.5](./issue-work-split-dispatch.md).

If either the follow-up issue creation, the comment, or the labeling errors (rate limit, permission), log an advisory and retry once; if it still fails, don't block your return on it — note the failure in your step-8 return string so the orchestrator can retry.

Once this fragment's disposition is applied, return to [`issue-work.md`](./issue-work.md) and continue at step 7, then return via step 8's `partial ... deferred to #<F>` return shape.
