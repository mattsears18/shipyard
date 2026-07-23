# /shipyard:do-work — Setup phase

The session-startup steps (0.4 → 7). Runs once, end of phase hands off to [steady-state](./steady-state.md). The thin entry [`commands/do-work.md`](../do-work.md) owns the [orchestrator-state struct list](../do-work.md#orchestrator-state) and the [session state file schema](../do-work.md#session-state-file); this file owns the actual setup-step execution.

## This file is a thin router — load only the sub-phase you need

This phase used to live as one ~283KB file, which exceeds the 256KB single-file `Read` limit so the orchestrator couldn't read its own primary phase file in one call ([#611](https://github.com/mattsears18/shipyard/issues/611)). It's now split into step-cluster sub-files under [`setup/`](./setup/), mirroring the [thin-router + on-demand-load pattern](../do-work.md#phase-routing) the parent `do-work.md` already uses for its phase files. **Load only the sub-file(s) for the step(s) you're executing — not all five.** The setup steps run in order (sub-phase 1 → 5), so a fresh session typically loads them sequentially as it advances; a re-entry that only needs one step (e.g. a deep-link from another phase file into the trusted-author allowlist) loads only that sub-file.

| Setup sub-phase | Owns | When to load |
|---|---|---|
| [`setup/00-config-worktree.md`](./setup/00-config-worktree.md) | Lightweight C=1 index; run-once Setup preamble; steps **0.3 → 0.9.1** (`CLAUDE_PLUGIN_ROOT` re-export, repo-level opt-in check, orchestrator-worktree relocation, per-worktree session-id storage, fire-once parallelization batch, `blocker_state` cache, `gh-cached.sh` / `gh-batch.sh` wrappers) | First — at session start, before any other setup step |
| [`setup/01-repo-recovery.md`](./setup/01-repo-recovery.md) | Steps **1 → 3.5** (resolve repo + user, silent-direct-merge repo-shape detection, missing-`workflow`-scope preflight warning, session-state init, orphan session-file + orphan orchestrator-worktree reaps, trusted-author allowlist, backlog overview, label-ensure + prior-session recovery, refinement invocation) | After config + worktree relocation completes |
| [`setup/04-backlog-divert.md`](./setup/04-backlog-divert.md) | Steps **4 → 5.8** (fetch + rank the backlog, main-CI / PR-pileup divert checks, failing-PR snapshot, seed inherited DIRTY PRs into `session_prs`, flake-registry enforcement) | After the backlog overview + label setup completes |
| [`setup/06-scope-preflight.md`](./setup/06-scope-preflight.md) | Steps **6 → 6.8** (initial scope pre-flight — pre-scope synthetic-defer detectors, freshness check, per-class evidence shapes, per-returned-entry handling; status-line + state-change-banner UI; setup-timing flush) | After the backlog fetch + divert checks complete |
| [`setup/07-pool-fill.md`](./setup/07-pool-fill.md) | Step **7** (initial pool fill — dispatch the first wave of workers, then hand off to [steady-state](./steady-state.md)) | Last — after scope pre-flight, immediately before steady-state takes over |

### How to load on demand

Read only the sub-phase relevant to the step you're executing. A cold session walks them in order (00 → 01 → 04 → 06 → 07) as it advances through setup; don't pre-load all five at once. A **deep-link from another phase file** (e.g. [`steady-state.md`](./steady-state.md) referencing the [trusted-author allowlist](./setup/01-repo-recovery.md#17-resolve-trusted-author-allowlist), or [`drain.md`](./drain.md) referencing [seed-inherited-DIRTY-PRs](./setup/04-backlog-divert.md#57-seed-inherited-dirty-prs-into-session_prs-cross-session-drain-hand-off)) targets exactly one sub-file — load that one, not the whole setup phase. The [`dont.md`](./dont.md) prohibition list stays a sidebar across every setup sub-phase, exactly as it is across the other phases.

**Don't pre-load adjacent sub-phases.** Each cluster is self-contained for its step range; pulling the others into context defeats the split that exists to keep every phase file under the read limit. The next step's sub-file loads when you reach it.
