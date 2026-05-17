# /do-work — Graceful Shutdown & Hard-Kill Recovery

**Date**: 2026-05-17
**Affected**: `plugins/app-audits/commands/do-work.md`, `plugins/app-audits/agents/issue-worker.md`

## Problem

`/do-work` runs a rolling worker pool of background agents that knock down a GitHub issue backlog. Today it has no graceful end:

- The only way to stop a session is to kill the process (Ctrl+C or close the chat).
- A hard kill abandons whatever the in-flight agents were doing. Their worktrees survive on disk but the orchestrator's mental state (which slot owned which issue, which paths were claimed) is gone.
- A fresh `/do-work` rebuilds its queues from GitHub on startup, so it implicitly "resumes" the backlog — but it has no awareness of the orphan worktrees left behind. They sit as dead weight until manually cleaned, and any committed-but-unpushed work in them is silently abandoned.

We want two things:

1. **A graceful "stop"** — the user can ask the running session to finish what it has in flight and exit cleanly.
2. **Safe recovery from a hard kill** — the next `/do-work` invocation detects orphan worktrees from the prior session, salvages any committed work, and cleans up the rest before starting normal work.

## Design

Two independent mechanisms, plus a labeling convention that supports both, sharing one underlying naming rule.

### Shared foundation: deterministic branch naming

The orchestrator currently lets each `issue-worker` agent choose its branch name freely. We change it so the orchestrator **mandates** the name in the dispatch prompt:

- Issue work: `do-work/issue-<N>` (e.g., `do-work/issue-1234`)
- Fix-checks-only work: continues to use the existing PR's branch (no new name needed)

This single constraint makes `git worktree list | grep ' do-work/'` a complete, self-describing inventory of `/do-work`-owned worktrees. No sidecar metadata file, no `.do-work/state.json`, no separate registry. Git becomes the source of truth for "what was this session doing?"

### Shared foundation: `do-work` label on issues and PRs

Every issue picked up and every PR opened by `/do-work` is stamped with a `do-work` label. The label is **write-once** — never removed, even on block, abandon, or merge. It gives the user:

- A permanent audit trail on GitHub: `gh issue list --label do-work --state closed`, `gh pr list --label do-work --state all`.
- A cross-check during orphan triage: an open issue with `do-work` + `@me` assignee + no closing PR + no `do-work/issue-<N>` worktree is an inconsistent state worth flagging (e.g., dispatched but agent died before its first commit). Not a recovery action in v1, just logged.
- A backstop discriminator if branch-name conventions ever drift.

**Setup-time idempotent creation** — runs once at the start of every session, before any other label operation:

```bash
gh label create do-work --description "Worked on by /do-work" --color 5319E7 2>/dev/null || true
```

**On dispatch** — when self-assigning an issue, add the label in the same `gh issue edit` call:

```bash
gh issue edit <N> --add-assignee @me --add-label do-work
```

**On PR open** — the issue-worker agent's prompt instructs it to include `--label do-work` in its `gh pr create` call. Permanent on the PR.

**Reporting** — the end-of-session summary gains two cumulative-count lines:

```
Lifetime via /do-work: <I> issues closed, <P> PRs opened
```

…sourced from `gh issue list --label do-work --state closed --json number -q '. | length'` and the equivalent for PRs. These are repo-wide totals, not session-scoped — the per-session counts continue to be reported above them.

**Naming collision warning**: a user who runs `/do-work --label do-work` would be telling the orchestrator to filter the backlog to issues already touched by `/do-work` — a near-empty set in practice. Filter labels and the output label happen to share a string but play different roles. Documented as a footgun; no code-level protection needed.

### Mechanism 1: Soft drain via typed keyword

**Trigger** — the orchestrator wakes on two kinds of events: an agent completion notification, and a new user message. On the latter only, evaluate the new message: if its entire trimmed body is one of the trigger phrases, drain mode is engaged.

Trigger phrases (matched against the full trimmed body, case-insensitive — never as substrings):

- `stop`
- `drain`
- `/do-work stop`

Substring matching is deliberately avoided so phrases like "don't stop yet" or "I'll drain it later" do not trigger.

**Behavior on first trigger**:

1. Acknowledge immediately: *"Draining: N in flight, no new dispatches. Will exit when they finish or settle."*
2. Set internal `draining = true` flag (TodoWrite entry, mental state — does not need persisting because drain is bounded in time).
3. Steady-state loop **continues to reconcile completions** so in-flight agents are properly recorded.
4. **Dispatch step (5/C) is short-circuited** — slots stay empty as they free up.
5. **Periodic refresh (D) is skipped** — no point fetching new backlog or scanning for new failing PRs.
6. When `in_flight` empties → jump straight to end-of-session drain (CI pending poll) → cleanup → summary → exit.

**Second-trigger escalation**: if the user types a stop signal again while already draining, skip the CI pending-poll phase and exit immediately after cleanup. Useful when CI is slow and the user wants out.

**Why this is safe**: agents commit at logical milestones (TDD test → commit, implementation → commit, etc.) and are dispatched with `--auto` merge. Letting them run to natural completion never loses work. Killing them mid-edit would.

### Mechanism 2: Orphan triage on the next run

A new **Setup step 0** runs before existing step 1 (resolve repo + user). It scans for orphan worktrees and triages each one, finishing entirely during setup so the steady-state loop begins with a clean slate.

**Discovery**:

```bash
git worktree list --porcelain | awk '/^branch refs\/heads\/do-work\//'
```

**Classification + action** — for each `do-work/issue-<N>` branch found:

| Worktree state | Action |
|---|---|
| No commits beyond base | `git worktree remove --force <path>` → `git branch -D <branch>` → `gh issue edit <N> --remove-assignee @me` |
| Uncommitted edits, no commits | Same as above. Partial WIP from an agent mid-edit is not coherent enough to push. |
| Commits ahead, branch not pushed | `git push -u origin <branch>` → check for existing PR (`gh pr list --head do-work/issue-<N>`). If none, open with `--fill` + enable `--auto`. Count as a newly-shipped item. |
| Commits ahead, pushed, no PR open | Open PR with `--fill` + `--auto`. |
| Commits ahead, pushed, PR open | Inspect `statusCheckRollup`. If failing → push onto `failed_prs` for normal fix-checks dispatch. If pending/green → leave alone, auto-merge handles it. |
| Branch is `[gone]` upstream | Standard end-of-session cleanup logic already reaps these — `git worktree remove` + `git branch -D`. |

Triage runs inline in the orchestrator using short `git` and `gh` calls. No dispatched agents. Can be parallelized via background Bash if there are many, but realistic counts are ≤ `--concurrency`.

**After triage runs, normal setup proceeds** (resolve repo, fetch backlog, snapshot failing PRs, initial scope pre-flight, initial pool fill). Issues unassigned during triage flow naturally back into `raw_backlog`. PRs added to `failed_prs` are processed first by the dispatch rules.

**Logged in the session summary** as a new line:

```
Recovered from prior session: X orphan worktrees (Y salvaged → PRs, Z abandoned)
```

## Touchpoints

### `plugins/app-audits/commands/do-work.md`

1. **New `## Setup` step 0** — "Orphan triage from prior sessions" — inserted before existing step 1. Contains the classification table and the git/gh commands. Also runs the idempotent `gh label create do-work ...` at the very top.
2. **Existing step 5 (Initial pool fill) + dispatch rules** — two changes to the dispatch sequence:
   - Self-assign gains `--add-label do-work`: `gh issue edit <N> --add-assignee @me --add-label do-work`.
   - The issue-work prompt template gains two lines: *"Create your branch as `do-work/issue-<N>`. Do not use any other name."* and *"When opening the PR, pass `--label do-work` to `gh pr create`."*
3. **New `## Soft drain` section** between "Steady state" and "Termination" — defines trigger phrases, acknowledgment format, dispatch/refresh skips, second-trigger escalation.
4. **`## Steady state` step C dispatch** — one-line guard: *"If `draining` is true, skip dispatch. The slot stays empty."*
5. **`## Steady state` step D periodic refresh** — one-line guard: *"Skip during drain."*
6. **`## Termination`** — clarify drain-mode termination: as soon as `in_flight` empties, regardless of backlog state. The existing "all queues empty" termination remains valid for the natural exit.
7. **`## End-of-session summary`** — add two new lines: the "Recovered from prior session" line and the "Lifetime via /do-work" cumulative counts.
8. **`## Don't` section** — add:
   - *"Don't claim a worktree whose branch doesn't match `do-work/*`. That's not yours."*
   - *"Don't run orphan triage while another `/do-work` session may be active on the same repo. Triage is idempotent but parallel salvage on the same orphan wastes work and may produce confusing PR comments. If you suspect a parallel session, ask the user before triaging."*
   - *"Don't remove the `do-work` label on block, abandon, or any other outcome. It is write-once. Adding the `blocked` / `ci-blocked` label alongside it is how block state is signaled — they coexist."*

### `plugins/app-audits/agents/issue-worker.md`

Two small changes:

1. A note in the preamble that branch name is provided by the orchestrator in the dispatch prompt and must be honored exactly — the agent does not invent its own name.
2. The PR-open step (existing) is updated to include `--label do-work` in `gh pr create`.

## Edge cases

- **First-run-after-upgrade**: worktrees from sessions before this change use free-form branch names, not `do-work/*`. The new triage step won't see them and will leave them alone. Expected behavior; user can clean them manually. Issues/PRs from prior sessions also lack the `do-work` label — lifetime reporting starts from the first post-upgrade session forward.
- **User deletes the `do-work` label** from the repo mid-session: the next `--add-label do-work` call would fail. The setup-time idempotent create re-establishes it next session, so impact is contained to the current session and only manifests on dispatch. Acceptable; not worth defensive coding.
- **Parallel sessions on the same repo**: the existing self-assign soft-lock prevents both sessions from picking the same new issue. Triage is idempotent — pushing an already-pushed branch is a no-op; opening a duplicate PR fails fast and is caught. We don't need a lock file; just the documented expectation in "Don't".
- **Multi-repo**: each repo has its own `do-work/issue-N` namespace; no cross-repo collision possible.
- **Orphan for an issue that has since been closed / has a merged PR**: the "branch is `[gone]`" path applies — cleanup reaps it.
- **Manual override** for an orphan the user wants to keep: rename the branch to anything not matching `do-work/*`. Triage will leave it alone.

## Non-goals

- **Persisted orchestrator state across sessions**: rejected. GitHub + git are authoritative; persisting in-flight tables to a JSON file mostly duplicates what the next session will rebuild anyway, and adds race conditions if two sessions run in parallel.
- **Hard-cancel of in-flight agents on soft drain**: rejected. Killing an agent mid-edit risks discarding committed-but-unpushed work. Letting agents run to natural completion always preserves work because of how they commit.
- **Pre-set time / issue-count budgets** (`--max-issues`, `--time-budget`): out of scope for this spec. Could be added later as an orthogonal feature that simply triggers soft drain when its condition fires.
- **`Ctrl+C` interception**: out of scope. Hard kill remains the user's prerogative; safety comes from the recovery path.

## Testability

- Orphan triage paths can be exercised by manually fabricating worktrees: `git worktree add worktrees/do-work-issue-1 -b do-work/issue-1`, optionally adding commits / staged edits / uncommitted edits, then running `/do-work` and verifying each branch of the classification table.
- Soft drain can be exercised in any low-traffic repo by typing `stop` mid-session and verifying the orchestrator acknowledges, lets in-flight finish, then runs cleanup and summary.
- Label correctness can be verified post-session with `gh issue list --label do-work --assignee @me` and `gh pr list --label do-work --author @me` — every item the session touched should appear.
