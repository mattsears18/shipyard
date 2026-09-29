On-demand fragment of the `shipyard:worker-preamble` skill (see [`SKILL.md`](./SKILL.md) § "Step-0 cwd fail-fast"). It covers the case where your worktree **is the `/shipyard:do-work` orchestrator's own worktree** ([#1613](https://github.com/mattsears18/shipyard/issues/1613)). Load it when `assert-not-orchestrator-worktree.sh` prints `orchestrator`.

## Why the git-dir check misses this

The step-0 check compares `git rev-parse --git-dir` with `--git-common-dir`. They are equal only in the **primary** checkout. The orchestrator's worktree (`.claude/worktrees/orchestrator-<session-id>`, or a hand-named `do-work-orchestrator-*`) is a *linked* worktree, so they differ there too and the check passes. Claude Code's own isolation guard does not catch it either: that guard blocks the **main** checkout, and the orchestrator's worktree is not the main checkout.

## What was observed (#1613)

In one lightwork session (plugin 4.55.28), two dispatches landed in the orchestrator's worktree: one `fix-checks-only` and one `issue-work`. Both came through the `Agent` tool, against shims that declare `isolation: worktree`. Four other `issue-work` dispatches in the same session got their own `agent-*` worktrees. So the condition is **intermittent**, and not tied to a particular mode.

- The first worker had no warning. It checked the orchestrator's tree out detached at a PR head and left an uncommitted edit there. Afterwards the orchestrator's `.shipyard-session-id` stash was gone.
- The second worker was warned and wrote nothing. It reported that Bash isolation is pinned when the worker launches. `EnterWorktree` moves the logical cwd but not the Bash guard, and `ExitWorktree` is refused from a cwd-overridden subagent. The only place it could run Bash was the orchestrator's tree.

That report is the only evidence for the mechanism. It is harness-internal, so it can't be seen or changed from this repo. Any real fix has to be harness-side: pin each worker's Bash isolation to its own worktree at launch.

## What to do

**Do not write anything.** No `Edit`/`Write`, no `git checkout`/`switch`/`commit`/`stash`/`clean`/`restore`, no file deletes. That covers every file in this tree, including the orchestrator's `.shipyard-*` stash files. The orchestrator is running from this directory, so any change here corrupts its state.

**Do not try to escape.** `EnterWorktree`/`ExitWorktree` don't move the Bash guard (see above). A nested `Agent` with `isolation: "worktree"` did get a writable worktree in the #1613 repro, but it is **not sanctioned**. You couldn't run the local gates yourself, so its results would reach you only secondhand. Per [`fan-out-verification.md`](./fan-out-verification.md), a gate result has to be one you ran. It also leaves extra `agent-*` worktrees on disk.

**Return, verbatim, with your actual toplevel filled in:**

> `blocked: dispatch-isolation pinned to the orchestrator's worktree (<TOPLEVEL>) — refusing to write there (see #1613). Re-dispatch required.`

The reconcile sorts `isolation pinned to the orchestrator's worktree` into the **soft** class (`blocked:agent-soft`). That means the issue can be retried later in the session, and it does not go to the human-review queue. The difference from the #486 primary-checkout mispin, which returns a refuse, is that this one is intermittent: a later dispatch will plausibly get a correct worktree.
