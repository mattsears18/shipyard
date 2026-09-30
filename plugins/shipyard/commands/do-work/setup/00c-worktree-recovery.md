# /shipyard:do-work — Setup phase · EnterWorktree failure recovery (case 2)

**Setup sub-phase fragment, loaded from [`00-config-worktree.md`](./00-config-worktree.md#05-move-into-the-orchestrators-worktree)'s step-0.5 EnterWorktree-fallback pointer — not part of the ordered per-session walk.** Owns the recovery path for the case step 0.5's raw-git-only fallback doesn't cover: `EnterWorktree` is offered as a tool but the call itself errors (most commonly a repo-level `WorktreeCreate` hook rejecting the harness's payload). Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md).

## Two distinct "EnterWorktree failed" cases ([#1066](https://github.com/mattsears18/shipyard/issues/1066))

Step 0.5's raw `git worktree add` fallback was written for one case only — "an environment where `EnterWorktree` is unavailable" (an older Claude Code build, or a harness variant that only exposes `Bash`). A second, structurally different case had no recovery path at all before this fragment existed:

1. **Unavailable** — the tool doesn't exist to call. The raw-git-plus-`cd` fallback in `00-config-worktree.md` is the correct (and only possible) recovery.
2. **Available and invoked, but the call itself errors** — most commonly a repo-level `WorktreeCreate` hook (configured in the *target repo's* `.claude/hooks/` + `settings.json`) rejecting the payload Claude Code sends, e.g.:
   ```
   WorktreeCreate hook failed: ${CLAUDE_PROJECT_DIR}/.claude/hooks/worktree-create.sh:
   worktree-create hook: missing worktree_path or repo_root in hook input
   ```
   Reading step 0.5 literally without this fragment, the orchestrator was stuck: the primary path errored, and the documented fallback's precondition ("EnterWorktree unavailable") was false — the tool exists and works fine in general, it just rejected *this* call.

**This is a target-repo-side configuration issue, not a shipyard or harness bug.** If you see the error above (or one shaped like it — any `WorktreeCreate hook failed:` or `WorktreeRemove hook failed:` line), the fix belongs in the target repo's hook script, not in this spec. Naming it here is the point: without this callout, an operator debugging a stuck session has no reason to suspect the *target repo* rather than shipyard or Claude Code itself.

## Recovery — create-then-enter-by-path

**Don't drop straight to the raw-git-only fallback for case 2 — it works, but it doesn't register harness isolation** (the fallback's own warning applies: `Edit`/`Write` calls get refused on a background-job session afterward). Try this first instead:

```bash
SY_TOPLEVEL="$(git rev-parse --show-toplevel)"
cd "$SY_TOPLEVEL"   # be robust to subdir invocation
ORCH_WT=".claude/worktrees/orchestrator-<session-id>"
DEFAULT_BRANCH=$(gh repo view <owner/repo> --json defaultBranchRef -q .defaultBranchRef.name)
git fetch origin "$DEFAULT_BRANCH"
git worktree add "$ORCH_WT" "origin/$DEFAULT_BRANCH"
```

Then call `EnterWorktree` again — this time with `path: "$ORCH_WT"`, NOT `name:`. Entering an **existing** worktree by path is a different code path from creating one: it does not invoke `WorktreeCreate` (that hook fires only on worktree *creation*, and the worktree already exists on disk from the raw `git worktree add` above), so it succeeds even when the `name:`-form's create call was rejected — while still flipping the harness's isolation flag the raw-git-only fallback does not. This is the recovery [#1066](https://github.com/mattsears18/shipyard/issues/1066) reports as verified working in-session.

**Only if this recovery ALSO fails** (rarer still — e.g. `EnterWorktree` genuinely isn't offered as a tool at all, collapsing case 2 into case 1) — fall through to the raw-git-only fallback in `00-config-worktree.md`, and accept its documented `Edit`/`Write`-refusal risk on a background-job session.

## Implication for worker dispatch, not just this step

**A `WorktreeCreate` hook that rejects the orchestrator's own `EnterWorktree` call will reject every subsequently-dispatched worker's `isolation: "worktree"` the same way — this is worse than one blocked step.** Every `mode:`-driven worker is dispatched via `Agent(isolation: "worktree")` under the default dispatch shape (see [`dispatch-rules.md`'s Agent-tool dispatch section](../dispatch-rules.md#agent-tool-dispatch--the-default-dispatch-shape-825)), which provisions its worktree through the identical harness mechanism that just failed here. There is no create-then-enter-by-path equivalent available from *inside* an `Agent` call — the isolation option is entirely harness-managed, and shipyard has no lever to intercept how it creates the worktree.

If you hit case 2 at step 0.5, treat it as a signal for the rest of the session: **there is no alternate dispatch shape to fall back to.** The `Workflow`-tool substrate that once filled that role was removed in [#1654](https://github.com/mattsears18/shipyard/issues/1654), and it was never a working escape hatch anyway — [#895](https://github.com/mattsears18/shipyard/issues/895) found it had no working orchestrator-isolation state, so a worker dispatched through it could not reliably perform a single file write. The recovery is to fix the repo's `WorktreeCreate` hook (or run with `--concurrency 1` in the primary checkout if the repo genuinely has no isolation story), not to route around it.

**A repo-wide preflight probe was considered and deliberately not built here.** Dispatching one throwaway `Agent(isolation: "worktree")` early (at `--concurrency ≥ 2`) to detect this deterministically before the pool fills would add a full agent-dispatch's worth of cost and complexity to detect a condition this fragment's step-0.5 signal already surfaces for free the moment it's hit. File a follow-up issue if a specific session's cost profile justifies building it.
