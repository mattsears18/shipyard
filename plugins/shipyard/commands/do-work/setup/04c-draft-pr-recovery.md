# /shipyard:do-work — Step 5.75: Seed inherited draft PRs (cross-session draft-PR recovery)

Deep-linked from [`04-backlog-divert.md`](./04j-failing-pr-snapshot.md#575-seed-inherited-draft-prs-draft-pr-recovery) — read this file only when you reach that pointer, not as part of the ordered per-session walk.

## Why this exists

Closes [#1069](https://github.com/mattsears18/shipyard/issues/1069) — a draft PR is invisible to every existing sweep. [Step 5's failed-PR scan](./04j-failing-pr-snapshot.md#5-snapshot-failing-prs) keys on a red check rollup; [step 5.7's inherited-DIRTY seed](./04j-failing-pr-snapshot.md#57-seed-inherited-dirty-prs-into-session_prs-cross-session-drain-hand-off) keys on `mergeStateStatus == "DIRTY"`. A draft PR is typically neither: on any repo whose CI guards jobs with a `draft != true` condition (a common cost optimization), every check reads `SKIPPED` — not red — and `mergeStateStatus` reads `CLEAN`. Nothing in the session ever looks at it. The concrete repro (`mattsears18/lightwork#3465`) sat stranded 2 days holding a P1 fix that needed nothing but `gh pr ready` — the orchestrator only caught it by inspecting the open-PR list by hand.

## What this step does

Runs [`scripts/draft-pr-recovery.sh`](../../../scripts/draft-pr-recovery.sh) `enforce` — the single executable source of truth for both the classification decision and the recovery action, mirroring the `detect-ungated-admin-direct-merge.sh` precedent (issue #716: a condition restated in prose drifts; a condition that is one script cannot). It lists open `@me`-authored draft PRs and, for each, classifies it into `ready` or one of six `hand-back:*` reasons, then acts:

- **`ready`** — agent-authored (a `Co-Authored-By:` trailer naming Claude, or a `Claude-Session:` trailer — **not** the `do-work/*` branch prefix; issue #1069 notes the repro PR's branch was `fix/android-sdk-root-3461`), carries no gate label, has at least one closing-issue reference and every one of them is still OPEN, and the body is non-empty with no WIP/DO-NOT-MERGE marker and no unchecked task-list item. The script marks it ready (`gh pr ready`) and arms auto-merge the same gated/ungated-aware way [issue-work.md step 6.a](../../../agents/issue-worker/issue-work.md#6a-run-the-ungated-admin-direct-merge-pre-check-first--before-any-merge-call-598--602--716) does — on the rare ungated admin-direct-merge repo shape it readies the PR but leaves it for manual merge with an advisory comment rather than blocking this setup step on a synchronous `--watch`.
- **Any `hand-back:*` reason** — a PR that already carries a gate label (`needs-human-review`, `wontfix`, `discussion`, `duplicate`, `invalid`, `agent-console`, or any `blocked:*`) is left alone (idempotent — no re-label, no re-comment; a human or a prior sweep already dispositioned it). Everything else — no closing reference, a closing-referenced issue that's already CLOSED (moot work), an empty body, a WIP/DO-NOT-MERGE marker, or an unchecked task-list item — gets `needs-human-review` applied (label created idempotently first) plus a one-line comment naming which signal tripped.
- **Not agent-authored at all** — skipped entirely, no output, no mutation. This is deliberately narrower than "any trusted author": scoping the query itself to `--author @me` means every candidate the script even considers is already trust-scoped by construction, so a stranger's or a human maintainer's own draft is never touched.

**A human's deliberate WIP draft must never be auto-readied.** The classifier is ordered so any ONE of several independent signals (gate label, closed closing-issue, empty/WIP/unchecked body) is sufficient to force a hand-back — see the script's own header comment for the full precedence and the fail-safe posture (an unreadable signal always resolves toward hand-back, never toward ready).

## Invocation

Part of the [setup parallelization batch](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch) — it can fire alongside steps 1 / 2 / 3d.1 / 3d.2 / 4.5a / 4.5b / 5 / 5.7. Reuse the literal plugin-root value already resolved at step-0 (orchestrator-supplied or self-resolved, [#965](https://github.com/mattsears18/shipyard/issues/965)) rather than re-deriving it:

```bash
export CLAUDE_PLUGIN_ROOT="<plugin-root literal>"
DRAFT_PR_RECOVERY_OUTPUT=$("$CLAUDE_PLUGIN_ROOT/scripts/draft-pr-recovery.sh" enforce --repo "<owner/repo>" 2>&1)
```

The call is fire-and-forget from the setup step's point of view — the script itself performs the `gh pr ready` / `gh pr merge --auto` / `gh pr edit --add-label` mutations synchronously and returns once every candidate has been classified and acted on; there is nothing further for the orchestrator to poll. Each output line is a JSON object: `{"number":N,"disposition":"...","action":"...","url":"..."}`. Hold the parsed lines in a session-local `inherited_draft_prs` list (see [`orchestrator-state-reference.md`](../orchestrator-state-reference.md#cold-orchestrator-state-structures)) — this is the **surfacing floor** issue #1069 requires even independent of the auto-ready path: every inherited draft this step classified (readied or handed back) must appear in the [end-of-session summary](../cleanup-summary.md#end-of-session-summary), never silently absent from the session's view. A `ready` entry whose action starts with `readied-and-auto-merge-armed` also belongs in `session_prs` — it's now a real open PR under this session's ownership, same as any other freshly-armed auto-merge, so a subsequent red check gets picked up by the normal drain machinery.

**Idempotent across sessions.** Re-running this step is safe: an already-gated hand-back PR is a no-op (the script's own dedup — see above), and a PR that already merged or was closed since the last session simply won't appear in the `is:draft` query anymore.

**Gate on the same C=1 lazy-load carve-out as step 5 / 5.7** — at `concurrency == 1` this can defer to the first idle turn; [steady-state step D's failed-PR scan](../steady-state.md#d-periodic-refresh) is the natural place to pick it up alongside the other lazy-loaded snapshots, since it already re-derives the `@me` open-PR list there.
