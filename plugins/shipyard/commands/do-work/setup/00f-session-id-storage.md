# /shipyard:do-work — Setup phase · session-id storage

**Setup sub-phase fragment, loaded from [`00-config-worktree.md`](./00-config-worktree.md)'s step-0.55 pointer — part of the ordered per-session walk, not a conditional deep-link.** Runs immediately after step 0.5's `EnterWorktree` relocation completes. Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md). Prev: [`00-config-worktree.md`](./00-config-worktree.md#05-move-into-the-orchestrators-worktree) (step 0.5). Next: [`00k-repo-root-pin.md`](./00k-repo-root-pin.md) for step 0.56.

### 0.55 Session-id storage (per-worktree, not /tmp)

**The session id MUST be stashed at `<orch-worktree>/.shipyard-session-id`, NOT at any globally-shared path like `/tmp/shipyard-session-id.txt`.** Closes [#365](https://github.com/mattsears18/shipyard/issues/365).

The orchestrator's many Bash tool calls each need to know `<session-id>` to substitute into the `--session-id "<session-id>"` templates throughout this file (e.g. `session-state.sh update`, `setup-timing.sh end`, `cost-history.sh flush`, the `--reaper-session-id "<session-id>"` audit-stamps). The harness-env quirk (same class as [#322](https://github.com/mattsears18/shipyard/issues/322) for `$WORKTREE_PATH` and [#354](https://github.com/mattsears18/shipyard/issues/354) for `$CLAUDE_PLUGIN_ROOT`) is that **each Bash tool call is hermetic** — env vars set in call N are not visible in call N+1, and `export SESSION_ID=...` doesn't persist. A natural workaround is to write the id to a file the orchestrator re-reads at the top of every Bash call.

**The file MUST live inside the orchestrator's own worktree.** The orchestrator worktree path is unique per session by construction (`.claude/worktrees/orchestrator-<session-id>` — see [00-config-worktree.md's step 0.5](00-config-worktree.md#05-move-into-the-orchestrators-worktree)), so a per-worktree path is unique per session by extension. A globally-shared path like `/tmp/shipyard-session-id.txt` is **forbidden** — when two `/shipyard:do-work` sessions run concurrently against different repos, both write to the same `/tmp` path; the later starter clobbers the first, redirecting every subsequent `session-state.sh bump-tokens` / `update` call to the WRONG session file. Token attributions, `session_prs` appends, and `reconciled_agent_ids` entries leak into the wrong session's state, corrupting both cost ledgers. This is the failure mode #365 documents end-to-end.

**Write the id at session start, immediately after the orchestrator worktree is created.** Place this block after the [00-config-worktree.md step 0.5 timing close](00-config-worktree.md#05-move-into-the-orchestrators-worktree) and before [00-config-worktree.md step 0.7](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch):

```bash
# Worktree-relative, not `$ORCH_WT`-prefixed — that var doesn't survive this hermetic call (#1182).
printf '%s\n' "<session-id>" > .shipyard-session-id
```

**Read it back at the top of every Bash tool call that needs the id.** Cheap (one `cat`); robust against the harness's per-call hermetic-shell semantics; impossible to race because the path is per-session-unique:

```bash
SESSION_ID=$(cat .shipyard-session-id 2>/dev/null)
# ... use $SESSION_ID in subsequent calls; e.g. session-state.sh update --session-id "$SESSION_ID" --set '...'
```

Equivalently — for a drifted-off cwd — derive the orchestrator worktree path and read the stash from there. **Do NOT derive it from `git rev-parse --show-toplevel`** (issue [#477](https://github.com/mattsears18/shipyard/issues/477)): `git rev-parse --show-toplevel` returns whatever worktree the shell's cwd is in, and the harness can silently relocate the orchestrator's own Bash-tool cwd into a just-returned **agent's** `agent-*` isolation worktree on a reconcile turn (the same `isolation: "worktree"` cwd-leak class as [#452](https://github.com/mattsears18/shipyard/issues/452), which [A.0.6's primary-leak guard](../steady-state.md#a06-primary-checkout-branch-leak-guard-fires-every-reconcile-turn-before-a1) already hardens against). When cwd is in an `agent-*` worktree, `git rev-parse --show-toplevel` returns the **agent** worktree path — which has no `.shipyard-session-id` stash (that file lives only in the orchestrator worktree, per the "MUST live inside the orchestrator's own worktree" rule above). The `cat` then comes up empty, every downstream `session-state.sh` call is invoked with an empty `--session-id` and exits 64 (`--session-id is required`), and the turn silently loses its cost attribution + `session_prs` append (a lost `session_prs` append can strand a PR out of the drain watch list).

Derive the session id with the `session-identity.sh derive-session-id` helper instead of an inline `awk` walk. The helper globs `<repo-root>/.claude/worktrees/orchestrator-*` (cwd-independent given the explicit `--repo-root`, so it is immune to the #477 cwd-leak) and reads the `.shipyard-session-id` stash from the **newest-by-mtime** orchestrator worktree.

**Newest-by-mtime, not first-in-listing-order — issue [#513](https://github.com/mattsears18/shipyard/issues/513).** The previous inline derive used `awk '... {print p; exit}'`, which returns the *first* `orchestrator-*` entry in `git worktree list --porcelain` order. When prior crashed sessions leave their `orchestrator-<dead-id>` worktrees un-reaped (the *step 1.6.5 sweep (removed — the harness reaps worktrees)* didn't run, or hasn't run yet), "first in listing order" is the **oldest orphan**, so the derive read a dead orphan's stash and every `session-state.sh update` / `bump-tokens` write landed in the orphan's session file — same repo, so the `--expected-repo` guard never tripped, silently corrupting the cost ledger, `/shipyard:status`, and `--resume` while this session's real file stayed at init defaults (the #513 repro: 245k tokens + 11 deferred issues + `session_prs += [1897]` all misattributed to a 6-day-old orphan). The live session's orchestrator worktree was created **this run** in [00-config-worktree.md's step 0.5](00-config-worktree.md#05-move-into-the-orchestrators-worktree), so among any set of coexisting orchestrator worktrees it has the newest directory mtime — selecting newest resolves to the live session whenever orphans coexist, and is a no-op (a single candidate) in the common one-worktree case. (The deeper fix is to make *step 1.6.5 (removed — the harness reaps worktrees)* reap orphans so the multi-orchestrator-worktree precondition rarely arises in the first place; newest-by-mtime is the correctness floor for when it does.)

```bash
export CLAUDE_PLUGIN_ROOT="<plugin-root literal>"
# Derive the session id from the NEWEST orchestrator-* worktree's stash
# (issue #513 — newest, not first-in-listing-order, so an accumulated orphan
# from a prior crashed session can't shadow the live session). cwd-independent
# given the explicit --repo-root (immune to the #477 cwd-leak).
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
SESSION_ID=$("$CLAUDE_PLUGIN_ROOT/scripts/session-identity.sh" derive-session-id \
  --repo-root "$REPO_ROOT" 2>/dev/null)
# Last-resort fallback for a non-worktree layout where the glob found no
# orchestrator worktree: the cwd-derived stash read. Vulnerable to the #477
# cwd-leak, so only when the helper came up empty.
[ -z "$SESSION_ID" ] && SESSION_ID=$(cat "$REPO_ROOT/.shipyard-session-id" 2>/dev/null)
```

The `REPO_ROOT` derived from `git rev-parse --show-toplevel` here only feeds the `--repo-root` glob anchor — under the #477 cwd-leak it may resolve to an `agent-*` worktree, but every linked worktree's `.claude/worktrees/` directory shares the same primary checkout, so the glob still enumerates the same orchestrator worktrees regardless of which linked worktree the cwd sits in. (The cwd-leak only breaks a derive that *reads the stash directly from `show-toplevel`* — which is exactly the last-resort fallback line, used only when the glob found nothing.)

**Defense in depth — `session-state.sh` enforces a cross-repo write guard.** Even if the orchestrator's id-stash mechanism is bypassed or corrupted, `session-state.sh update` and `session-state.sh bump-tokens` accept an `--expected-repo <owner/repo>` flag (also accepted via `SHIPYARD_EXPECTED_REPO=<owner/repo>` env var). When the flag is set and the resolved session file's `.repo` field doesn't match, the call exits 66 with a loud stderr log naming both repos — refusing the write rather than silently corrupting another session's state. The orchestrator SHOULD pass `--expected-repo <owner/repo>` on every `update` and `bump-tokens` call; the `--skip-repo-check` flag is reserved for the rare legitimate cross-repo helper (e.g., the orphan-sweep at step 1.6, which intentionally operates on session files belonging to other repos). See [session-state.sh's cross-repo guard](../../../scripts/session-state.sh) for the exit-code contract.

**Don't reach for option 2 from #365** ("skip the file entirely, compute the session id from the worktree path"). The compute-from-worktree-path approach is appealing in theory but invasive in practice — the orchestrator's many Bash tool calls would all need to walk `git worktree list` to find their worktree, parse the orchestrator-<id> suffix, and handle the edge cases where the cwd isn't inside an orchestrator worktree (foreground vs. background subshells, the user's primary-checkout invocation, etc.). The per-worktree stash file is the minimum-surgery shim that addresses the race without redesigning the lookup pattern. Reserve compute-from-worktree-path for a follow-up issue if the stash-file approach ever becomes load-bearing in a way that warrants the larger change.

**Continue to [`00k-repo-root-pin.md`'s step 0.56](./00k-repo-root-pin.md#056-pin-shipyard_repo_root-to-the-primary-checkout-1059) once this step completes.**
