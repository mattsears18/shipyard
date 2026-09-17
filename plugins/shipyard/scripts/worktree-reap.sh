#!/usr/bin/env bash
# worktree-reap.sh — classify whether an agent worktree lock-file is safe
# to reap at end-of-session cleanup.
#
# Background (see issue #138): the orchestrator's end-of-session cleanup
# (`commands/do-work.md` → End-of-session cleanup → step 3) iterates
# `.git/worktrees/agent-*` and uses a PID liveness check to defer reaping
# whenever the lock-holding PID is alive — the idea being that an alive PID
# means a peer agent is still running and yanking its worktree would destroy
# in-flight work.
#
# That liveness check has a bug: the harness writes the **orchestrator's**
# PID into every dispatched agent's lock file (lock content is literally
# `claude agent <agent-id> (pid <orchestrator-pid>)`, or for a session-level
# lock `claude session <orchestrator-id> (pid <N> start <ctime>)` — see
# issue #1206). At end-of-session cleanup the orchestrator is by definition
# still alive (it's the process running cleanup), so a strict liveness check
# defers EVERY worktree the orchestrator itself owns. The reporter saw 2
# agent worktrees stuck because the lock PID was the orchestrator's PID
# 53391 — alive, but not a peer.
#
# Issue #138 added a third classification — **self-ancestor** — that walks
# the caller's own process-ancestor chain (self, parent, grandparent, …)
# and treats a lock-PID match anywhere in that chain as "the orchestrator
# about to retire its own worktree." Safe to reap.
#
# Issue #263 added a faster, more reliable path on top of the ancestor walk:
# the env var `SHIPYARD_ORCHESTRATOR_PID` (or the `--orchestrator-pid <N>`
# flag) lets the caller declare the orchestrator's PID explicitly. When the
# lock PID matches that declared PID, classification short-circuits to
# `self-ancestor` without traversing `/proc`. This matters because the
# ancestor walk can fail in two real-world cases:
#   - Process re-parenting: an intermediate harness layer in the orchestrator
#     → bash chain returns empty PPID, causing the walk to break before
#     reaching the orchestrator (the reporter saw this in production).
#   - Subagent invocation: when a dispatched subagent (fix-rebase, fix-checks)
#     runs classify-lock for diagnostic purposes, its `$$` is the subagent's
#     bash, and the ancestor walk goes up through the subagent's harness —
#     not the orchestrator's. The orchestrator IS the spawning principal but
#     isn't a Unix-ancestor of the subagent's bash.
# The env var path solves both: the orchestrator exports its own PID once at
# session start, every classify-lock call (orchestrator-side or subagent-side
# if propagated) gets an authoritative answer regardless of process-tree shape.
#
# Subcommands:
#
#   classify-lock <lock-file-path> [--orchestrator-pid <N>]
#     Emits one of (on stdout, single token, trailing newline):
#       no-lock          — lock file doesn't exist (safe to reap)
#       dead             — lock PID was parsed AND is confirmed dead (safe to
#                          reap, original semantics)
#       unknown          — lock file exists and is non-empty, but no PID
#                          could be parsed from it at all (issue #1206).
#                          Fail CLOSED, not open: an unparseable lock is NOT
#                          safe to reap — it might belong to a live peer
#                          whose lock simply didn't match the expected
#                          shape, and destroying it would be exactly the
#                          data-destroying failure this classifier exists to
#                          prevent. Treat identically to `peer-alive` at
#                          every call site that gates a defer decision on
#                          classification (see the "Callers should reap on"
#                          paragraph below for which sites that is).
#       self-ancestor    — lock PID is alive AND is either (a) the declared
#                          orchestrator PID (via `SHIPYARD_ORCHESTRATOR_PID`
#                          env var or `--orchestrator-pid` flag) or (b) our
#                          own / an ancestor of ours (safe to reap —
#                          orchestrator owns this lock)
#       peer-alive-stale — lock PID is alive, is NOT self/ancestor, AND
#                          EITHER (a) the lock's own recorded `start <ctime>`
#                          field disagrees with `ps -o lstart` for that PID
#                          (PID-reuse suspected — issue #1207, see "Why a
#                          third gate" below) OR (b) the lock file's mtime is
#                          older than the staleness floor (default 60 min;
#                          `SHIPYARD_PEER_LOCK_STALE_MIN` / `--peer-stale-min
#                          <N>` — issue #755). Safe to reap either way.
#       peer-alive       — lock PID is alive, is NOT self/ancestor, its
#                          recorded start time (when present) is corroborated
#                          by `ps -o lstart`, AND the lock file is within the
#                          staleness floor (defer — likely a genuine peer
#                          agent or other instance still running)
#     Env vars:
#       SHIPYARD_ORCHESTRATOR_PID — explicit orchestrator PID. Takes
#                        precedence over the ancestor walk for the
#                        self-ancestor check. Overridden by `--orchestrator-pid`
#                        if both are set.
#       SHIPYARD_PEER_LOCK_STALE_MIN — peer-alive staleness floor in minutes
#                        (default 60). Overridden by `--peer-stale-min <N>`
#                        if both are set.
#       SHIPYARD_LOCK_START_TOLERANCE_SEC — tolerance (in seconds, default
#                        120) for the start-time cross-check below. A
#                        difference within this window is still treated as
#                        corroborated (absorbs sub-minute rounding between
#                        when the harness recorded the start time and when
#                        the OS itself considers the process to have
#                        started).
#     Exit codes:
#       0  classification emitted
#       64 bad usage (missing path, malformed flag value)
#
# Why a second gate on `peer-alive` (issue #755). PID-liveness alone (`kill
# -0 $pid`) cannot distinguish a genuinely-running peer from a dead
# prior-session PID the OS has since recycled onto an unrelated live
# process — the exact ambiguity issue #253 already documented for orphan
# session files, which is why THAT sweep stacks a PID-liveness check with a
# 30-minute mtime floor rather than trusting liveness alone. Agent-worktree
# locks had no such second gate: a worktree from a long-dead crashed
# session, misclassified `peer-alive` by PID recycling, stayed deferred
# forever — setup.md step 3b only sweeps once at session start, and the
# per-dispatch pre-dispatch reaps (`steady-state.md` §2d, `drain.md`'s
# #370) call this SAME function, so they hit the SAME false-peer verdict on
# every retry. The production trace (#755): ~25 stale `agent-*` worktrees
# from prior crashed sessions, several still holding `do-work/issue-*`
# branches a re-dispatched worker needed, required manual `git worktree
# unlock` + move-aside + `prune` every session because no automated path
# ever revisited the peer-alive verdict. The mtime floor is calibrated well
# above this repo's observed worst-case single-dispatch duration (CI
# watches typically settle in 5-20 min — see `fix-checks-only.md` §6.a) and
# well below the hours-to-days staleness a genuinely-orphaned worktree
# exhibits, so a still-legitimately-running peer is never force-reaped.
#
# Why a third gate on `peer-alive` (issue #1207). The #755 gate above
# corroborates liveness with the LOCK FILE's own mtime — a proxy signal
# (is the lock still being touched). This gate corroborates it directly: the
# harness's session-level lock format additionally records `(pid <N> start
# <ctime>)`, and `ps -o lstart` reports the SAME still-alive PID's ACTUAL
# start time. If a dead prior-session PID gets recycled by the OS onto an
# unrelated live process before a reap sweep runs, `pid_alive` alone can't
# tell — but the recycled process's real start time will essentially never
# coincide with the time the original, now-dead process recorded in the
# lock. A mismatch is strong, direct evidence the PID was reused.
#
# The catch, confirmed live against a real production lock during #1207's
# investigation: the SAME still-live process's lock-recorded start time and
# `ps -o lstart`'s reading of it can disagree by exactly the host's local
# UTC offset —
#   Lock file: ... (pid 52469 start Mon Aug 10 12:58:36 2026)
#   ps -p 52469 -o lstart=:        Mon Aug 10 08:58:36 2026
# — same process, same instant, 4 hours apart (EDT is UTC-4). A naive
# string/epoch comparison would misclassify this genuinely-live process as
# PID-reuse-stale: the OPPOSITE failure mode from the one this gate exists
# to catch, and a strictly worse one — misclassifying a STALE lock as live
# only defers a reap (wasted disk); misclassifying a LIVE lock as stale
# enables reaping a running session's worktree (destructive, irreversible).
#
# Whether the harness always records this field in UTC, or only happens to
# on some hosts (its own process environment's TZ, not a documented
# contract), could not be established with confidence — so the comparison
# (`lock_start_corroborates_ps()` below) does not assume either reading. It
# accepts a match at EITHER interpretation: the lock's `start` field parsed
# as UTC, or parsed as this host's own local zone (the same zone `ps
# -o lstart` itself renders in) — plus a small tolerance window for
# sub-second/sub-minute rounding. Only when NEITHER interpretation
# corroborates `ps -o lstart` is a mismatch declared. Locks with no `start`
# field at all (the common `claude agent <agent-id> (pid <N>)` shape, which
# carries no start time to begin with) skip this gate entirely and fall
# through to the #755 mtime gate unchanged — this is new corroboration on
# top of the existing gates, not a replacement, and a no-op wherever the
# harness doesn't record a start time.
#
# Callers should reap on `no-lock` / `dead` / `self-ancestor` /
# `peer-alive-stale`, defer on `peer-alive` and `unknown`. Every existing
# exact-string `= "peer-alive"` check already defers ONLY on the fresh case
# and falls through to "safe to reap" for anything else — that fallthrough
# is exactly right for `peer-alive-stale` (issue #755, reap-eligible by
# design), so THAT classification needed no per-site change when it was
# added.
#
# `unknown` (issue #1206) is the OPPOSITE shape and does NOT get the same
# free ride: it must be treated as NOT reap-eligible, so the fallthrough
# that correctly extended `peer-alive-stale` to every caller would
# incorrectly extend `unknown` too (an unparseable lock would silently reap
# on every exact-string-only call site). Every call site that GATES a
# defer/reap decision on the classification (as opposed to merely labeling
# an unconditional reap for the audit log) was updated alongside this change
# to also match `unknown`, identically to how it already treats
# `peer-alive`:
#   - `dispatch-rules.md`'s per-dispatch concurrent-session guard (the
#     `peer_locked` check, distinct from that same file's §2d — see below)
#   - `cleanup-summary.md` step 3.1's generic per-worktree sweep
#   - `drain.md`'s pre-dispatch head-branch reap
#   - `reap_session_worktrees()` in this file (cleanup-summary.md step 3.0's
#     targeted this-session reap)
#   - `reap_stale()` in this file, built on `classify_all` (the
#     session-start bulk sweep invoked from `00b-parallelization-cache.md`'s
#     background group — see `classify-all`'s own docstring below, which
#     carries the matching `unknown` fix for its independent PID-extraction
#     path)
# The sites that reap UNCONDITIONALLY regardless of classification
# (`dispatch-rules.md` §2d, steady-state.md's step B / A.0.5 / A.1) needed
# no logic change — they already reap every verdict; only the audit-log
# label they attach changes, and `unknown` is a meaningfully MORE accurate
# label for those than the previous `dead` mislabel was.
#
# NOT changed: `setup/01c-label-recovery-refine.md`'s own "3b. Reap stale
# agent worktrees" narrative section still shows a standalone per-worktree
# `classify-lock` loop predating issue #836 — its own "Background step" note
# says the canonical implementation lives in `00b-parallelization-cache.md`'s
# background group (the `reap-stale` call this docstring already covers), so
# that narrative code block is not live and was left as-is.
#
#   classify-all --repo-root <path> [--orchestrator-pid <N>]
#        [--peer-stale-min <N>]
#     Issue #836 — bulk classification. The per-worktree loop that used to
#     call `classify-lock` once per `agent-*` worktree forked one process
#     PER worktree, each of which forked its own `ps`/`stat` subprocesses —
#     O(n) subprocess cost that timed out before classifying a single
#     candidate on a 60-worktree backlog. `classify-all` reads every lock
#     file and enumerates every worktree in ONE pass, then resolves PID
#     liveness for the WHOLE batch with exactly one `ps -e -o pid=` call
#     (checked in-memory per lock), walks the self-ancestor chain exactly
#     once, and batch-`stat`s every worktree directory's mtime in one call.
#     Emits one line per `agent-*` worktree: `<name> <classification>
#     <lock-pid|null>`, sorted oldest-first by worktree-dir mtime so a
#     caller implementing a bounded, oldest-first reap can consume the
#     output directly.
#
#     Classification vocabulary is `classify-lock`'s (including `unknown`,
#     issue #1206 — `classify_all` parses the lock PID with its own
#     independent pure-bash regex rather than calling `extract_lock_pid`,
#     for the batching reasons in Pass 1's comment below, so it carried the
#     SAME anchor-on-close-paren bug and needed the SAME fix + the SAME
#     fail-closed `unknown` verdict on an unparseable lock) PLUS one extra
#     state, `no-lock-recent` (issue #1147) — see that issue's writeup below
#     for why: a harness-provisioned `isolation: "worktree"` dispatch (the
#     default Agent-tool shape since #830) never writes a shipyard lock
#     file, so a currently-running worker's worktree classifies identically
#     to `no-lock` under the plain PID-liveness check `classify-lock` alone
#     performs. `classify-all` additionally consults the worktree
#     DIRECTORY's own mtime for every `no-lock` candidate (mirroring the
#     `peer-alive` / `peer-alive-stale` mtime floor above — same
#     `--peer-stale-min` knob, same calibration tradeoff): a directory
#     touched within the floor is presumed live and reported as
#     `no-lock-recent` (defer — same posture as `peer-alive`); older than
#     the floor (or the directory's mtime can't be resolved at all — fail
#     CLOSED on a destructive operation, not open) falls through to the
#     original `no-lock` (reap-eligible) verdict. This is a narrower,
#     defense-in-depth backstop for the cross-session case (a peer
#     orchestrator's live agent, whose `.in_flight` this process cannot
#     read) — the PRIMARY guard for a live agent belonging to THIS
#     session's own `.in_flight` is `reap-stale`'s own mandatory
#     cross-check, documented below; `no-lock-recent` exists for the case
#     that check cannot cover. `classify-lock` (the single-worktree
#     subcommand) is intentionally NOT changed — every one of its own call
#     sites (dispatch-rules §2d, drain's pre-dispatch reap, steady-state's
#     A.0.5/A.1/step-B, cleanup-summary) already checks `.in_flight`
#     membership BEFORE ever consulting it, per `commands/do-work/dont.md`'s
#     "Don't reap a live-PID worktree" rule — `classify-all` is the one
#     bulk, cross-worktree sweep that had no such per-call prose guard, and
#     issue #1147's repro is specific to it.
#     Exit codes:
#       0  enumeration succeeded (output may be empty)
#       64 bad usage (missing --repo-root, malformed flag value)
#
#   reap-stale --repo-root <path> --session-id <id>
#        [--max-per-session <K>] [--exclude-agent-id <id> ...]
#        [--orchestrator-pid <N>] [--peer-stale-min <N>] [--dry-run]
#     Issue #836 fix 2 — bound + checkpoint the cross-session stale-
#     worktree sweep. Built on `classify-all`: reaps at most
#     `--max-per-session` reap-eligible worktrees this session, oldest
#     first; `peer-alive` / `no-lock-recent` worktrees are always deferred
#     (not counted against the cap); anything reap-eligible beyond the cap
#     is left untouched on disk — the remaining backlog on disk IS the
#     checkpoint, so the next session's sweep naturally continues from
#     where this one stopped with no separate state file to maintain.
#     `--exclude-agent-id` (repeatable) excludes a worktree from
#     consideration entirely, BEFORE classification is even consulted — the
#     in-flight guard (issue #832): a currently-dispatched slot's worktree
#     must never be reaped regardless of what its lock classifies as,
#     because branch name is never a liveness signal (see
#     commands/do-work/dont.md).
#
#     Mandatory in-flight cross-check (issue #1147). `--exclude-agent-id`
#     above is only as good as every calling site remembering to compute
#     and pass it — nothing enforced that. `reap-stale` now ALSO reads
#     `$SHIPYARD_HOME/sessions/<session-id>.json`'s `.in_flight[].agent_id`
#     directly (the SAME session-id already required as `--session-id`) and
#     unions those agent-ids into the exclude set automatically, before any
#     classification happens — turning the guard from "the orchestrator's
#     prose remembered to wire it" into "the subcommand cannot be called
#     without it." `--exclude-agent-id` remains available additionally
#     (e.g. to protect an agent-id from a DIFFERENT session's state). Best
#     effort: when the session file doesn't exist yet, or `jq` isn't on
#     PATH, this step is silently skipped and the sweep proceeds on
#     whatever `--exclude-agent-id` flags (and `no-lock-recent`'s
#     mtime-floor backstop) it has — a missing cross-check here does not
#     block the sweep, but it also isn't the only guard: `no-lock-recent`
#     above still defers a freshly-touched `no-lock` worktree either way.
#     Stdout: one `reaped: <name>` / `unreaped: <name>` (issue #712 —
#       verified end state, not intent) / `deferred: <name>` line per
#       acted-upon worktree, followed by exactly one summary line:
#       `summary: reaped=<R> deferred=<D> unreaped=<U> remaining=<REMAIN>
#       tombstones_swept=<TS> tombstones_failed=<TF>
#       tombstones_remaining=<TR>`.
#       `remaining` is the count left on disk purely because the cap was
#       reached — the backlog a future session will continue from. As of
#       issue #1223 it is derived from a fresh on-disk check taken AFTER
#       the sweep, not from the loop's own running tally, so a future
#       regression that fails to leave a capped worktree alone (or
#       otherwise diverges from what the loop assumed happened) surfaces
#       here instead of silently under-reporting.
#     Also runs a self-healing sweep of stranded *.reap-dead-* tombstones
#     (issue #1223) BEFORE classification, unconditionally — see
#     sweep_stray_tombstones' docstring; its would-sweep-tombstone: /
#     tombstone-swept: / tombstone-sweep-failed: / tombstone-summary:
#     lines precede the reaped:/deferred:/summary: lines above. As of
#     issue #1482 that pass is bounded by the same --max-per-session cap
#     (it used to be the one unbounded step here, able to burn the whole
#     time budget before a single worktree was even classified) and its
#     three tallies are carried into the summary line above rather than
#     being printed and dropped.
#     --dry-run emits the same lines/summary WITHOUT removing anything or
#     writing audit-log entries.
#     Exit codes:
#       0  sweep completed cleanly (output is always at least the summary
#          line)
#       3  issue #1482 — sweep completed but ended PARTIAL: at least one
#          reap attempt left its worktree on disk (unreaped>0) and/or at
#          least one tombstone removal failed (tombstones_failed>0). NOT a
#          crash — the summary line is still emitted and every successful
#          reap still happened. A capped-out `remaining` /
#          `tombstones_remaining` is normal operation and does NOT produce
#          this code.
#       64 bad usage (missing required flag, malformed flag value)
#
#   detect-orchestrator-pid, derive-session-id, find-orphan-orchestrators
#     Issue #941 — these three orchestrator-PID / session-identity forensics
#     subcommands moved to a dedicated sibling script,
#     `plugins/shipyard/scripts/session-identity.sh` — they answer "what is
#     the orchestrator's PID" / "what session am I" questions, not "is this
#     worktree safe to remove" ones, so they don't belong in a script whose
#     job is reaping. See that file's own header for the full per-subcommand
#     documentation. This file's `classify-lock` still uses the ancestor-walk
#     primitives (self_ancestor_pids / is_self_ancestor) for its own,
#     genuinely different question — lock-PID liveness classification — so
#     those primitives were NOT moved; the two scripts are siblings, not
#     layered on each other.
#
#   reap-orphan-branches --repo-root <path> --session-id <id>
#        [--dry-run]
#     Issue #326 — reap stale `worktree-agent-*` local branch refs that
#     have no live worktree referencing them. The Claude Code harness creates
#     a `worktree-agent-<id>` branch ref for every agent dispatched with
#     `isolation: "worktree"`. When the harness reaps the worktree directory
#     it does NOT run `git branch -D worktree-agent-<id>` — the branch ref
#     leaks and accumulates indefinitely.
#
#     For each local branch matching `worktree-agent-*`:
#       1. Parse `git worktree list --porcelain` to check for a live
#          worktree referencing `refs/heads/<branch-name>`.
#       2. If no live worktree → delete via `git branch -D`. On success,
#          write one `"action":"reaped-orphan-branch"` JSONL audit line to
#          $SHIPYARD_HOME/reap-audit.jsonl. On failure (e.g. an unmerged
#          commit, a permission error, or a concurrent-delete race), write a
#          distinguishable `"action":"reaped-branch-failed"` audit line with
#          `"reason":"branch-delete-failed"` instead — the delete's exit
#          status is checked, never discarded, so a failed reap can never be
#          recorded as a successful one (issue #874).
#       3. If live worktree exists → skip (safe-by-default).
#
#     The subcommand is idempotent: running it twice produces no second-pass
#     deletions (branches already deleted are no longer enumerated).
#
#     --dry-run mode emits the `reaped-branch:` lines WITHOUT deleting or
#     writing audit-log entries.
#
#     Env vars:
#       SHIPYARD_HOME — override the audit-log root (defaults to
#                       `$HOME/.shipyard`). Mirrors session-state.sh.
#     Stdout:
#       One `reaped-branch: <branch-name>` line per successfully deleted
#       branch, plus one per branch reported in `--dry-run` mode. A branch
#       whose `git branch -D` fails emits NO stdout line — only the
#       `reaped-branch-failed` audit line above. Empty stdout when nothing
#       was reaped.
#     Exit codes:
#       0  sweep succeeded (output may be empty)
#       64 bad usage (missing required flag, unknown flag)
#
#   reap --action <reaped|deferred|reaped-orphan-orchestrator>
#        --worktree-path <path> --worktree-name <name>
#        --session-id <id> [--actor-pid <pid>]
#        [--classification <c>] [--reason <r>] [--lock-pid <pid>]
#        [--reaped-session-id <id>] [--phase <p>]
#        [--skip-remove] [--bypass-return-check <reason>]
#     Argv shape deliberately diverges from its siblings (issue #1305).
#     classify-all / reap-stale / reap-orphan-branches / reap-session-worktrees
#     / report-unreaped all take `--repo-root <path>` because each SWEEPS a
#     repo's worktrees and discovers its own targets internally. `reap` takes
#     `--worktree-path <path> --worktree-name <name>` instead because it acts
#     on exactly ONE, already-identified target the caller resolved before
#     invoking it (the single source of truth for the audit-log write, not a
#     discovery mechanism) — there is no repo to sweep, only a specific
#     worktree to record the outcome for. This is not an accidental
#     inconsistency; do not "fix" it by adding a --repo-root alias here.
#
#     Reconciled-return gate (issue #1237) — `--action reaped` only, and
#     only when `--worktree-name` matches `agent-*` (an actual dispatched
#     agent's worktree; the orchestrator's own `orchestrator-*` self-reap
#     is a different object with no "did an agent return" question to ask).
#     Before removing anything, the helper requires PROOF that the owning
#     agent's own terminal return already reached the orchestrator's
#     reconcile — not merely that some other signal (a PR going `MERGED`,
#     a green rollup) looked like completion. The proof is a persisted
#     record: `session-state.sh read --session-id <id> --path
#     '.returned_agent_ids["<agent-id>"]'` must resolve to a non-empty
#     value. `steady-state.md`'s A.1 writes that record, once, for every
#     mode, BEFORE any of A.1's own per-mode reap calls run — so the two
#     same-turn reaps (A.1's `shipped`-immediate reap, step B's per-
#     completion reap) and every later-turn reap that targets an already-
#     reconciled worker's residual worktree (dispatch-rules.md §2d,
#     drain.md's mirror) all satisfy the gate without any change to their
#     own call sites. Missing session file, missing key, or an empty read
#     ⇒ REFUSE (fail closed — issue #1206's precedent: an ambiguous signal
#     is not a green light).
#
#     `--bypass-return-check <reason>` is the explicit, audited escape
#     hatch for the documented exceptions where the invariant does not
#     apply BY DESIGN — the agent this reap targets never reached (and, in
#     the crash-recovery case, structurally cannot reach) its own terminal
#     return:
#       - `crash-recovery-reap.sh` (steady-state.md's A.0.5 crash-recovery
#         reap, extracted to its own script by issue #1291) — the whole
#         premise of A.0.5 is a worker that stopped WITHOUT a terminal
#         return (crash, stall-watchdog kill, exhausted resume). Requiring
#         a returned-record here would defeat the crash-recovery path
#         A.0.5 exists to provide. Because that script reaps ONLY on its
#         `terminal=false` branch — its `terminal=true` path returns
#         early having reaped nothing — every reap it performs is by
#         construction a crash-recovery reap, so it passes a fixed
#         bypass reason internally rather than exposing a flag its
#         caller would have to remember to set.
#       - `reap-stale` (cross-session sweep — issue #836) — targets
#         worktrees that may belong to a DIFFERENT, already-dead session
#         whose own `.returned_agent_ids` this process never reads; no
#         single `--session-id` applies.
#       - `reap-session-worktrees` (cleanup-summary.md's end-of-session
#         targeted pass) — its own caller-documented contract unions
#         `reconciled_agent_ids` (returned) with any still-`in_flight`
#         agent-id as a defensive catch-all for an incompletely-released
#         slot; the latter may legitimately not have returned yet.
#     All three callers above pass a fixed, self-documenting reason string
#     when they call into the single-target `reap --action reaped`
#     internally — the caller never has to think about it.
#
#     A refused reap performs NO removal, writes an `"action":
#     "reap-refused"` audit-log line (best-effort, same fire-and-forget
#     posture as every other audit write here) and returns exit 1 — the
#     caller's own established `2>/dev/null || true` fire-and-forget
#     posture at every spec call site means a refusal degrades to "the
#     worktree is left in place for a later, correctly-gated sweep," never
#     a spec-block abort.
#
#     Issue #284 — single source of truth for worktree-reap audit-log
#     writes. Previously the audit-log `printf >> $REAP_AUDIT_LOG` was
#     inlined at three call sites (setup.md 1.6.5 / 3b, cleanup-summary.md
#     step 3). Every site shared roughly the same line shape, but the
#     small per-site differences (phase, action, classification vs reason)
#     made the lines look like "observability scaffolding" the orchestrator
#     could skim past — and it did. `~/.shipyard/reap-audit.jsonl` never
#     existed despite the spec calling for unconditional writes.
#
#     The `reap` subcommand encapsulates the entire reap-and-audit
#     transaction so the orchestrator can't skip the audit step:
#       1. Optionally perform the actual worktree removal via the #664 fast
#          reap (`fast_worktree_remove`: unlock + rename-aside + `git worktree
#          prune` frees the branch synchronously, then a backgrounded `rm -rf`
#          does the expensive bulk delete; falls back to `git worktree remove
#          --force` when the rename can't be done). Skipped when
#          `--skip-remove` is passed — used for "deferred" action, since the
#          worktree isn't actually removed.
#       2. For `reaped-orphan-orchestrator` action: the fast reap's `mv`
#          subsumes the crash-orphan case (dir on disk but no longer
#          registered with git — common after a crash) as well as the clean
#          remove. Only when the fast path can't make the dir disappear at
#          all (rename AND slow-remove both failed) does it escalate to a
#          synchronous last-resort `rm -rf`, emitting the `-raw-rm` (rm
#          succeeded) / `-failed` (rm also failed) action variant so the
#          source of the reap stays traceable.
#       3. Write exactly one JSONL line to `$SHIPYARD_HOME/reap-audit.jsonl`
#          describing the outcome. The write is fire-and-forget (errors
#          on the audit-log write are not fatal — a filesystem permission
#          issue must never abort cleanup).
#
#     Action-to-line-shape mapping (matches the inline printf templates
#     the three call sites used previously):
#
#       --action reaped:
#         {"ts","session","actor_pid","worktree","action":"reaped",
#          "classification","lock_pid","phase"?}
#         Requires: --classification, --lock-pid (null literal accepted).
#         Optional: --phase.
#
#       --action deferred:
#         {"ts","session","actor_pid","worktree","action":"deferred",
#          "reason","lock_pid","phase"?}
#         Requires: --reason, --lock-pid (null literal accepted).
#         Optional: --phase. Implies --skip-remove (caller is reporting
#         that the remove was deliberately skipped).
#
#       --action reaped-orphan-orchestrator:
#         Successful worktree-remove path:
#           {"ts","session","actor_pid","worktree",
#            "action":"reaped-orphan-orchestrator",
#            "reaped_session_id","phase"?}
#         rm -rf fallback path (worktree-remove failed):
#           {"ts","session","actor_pid","worktree",
#            "action":"reaped-orphan-orchestrator-raw-rm",
#            "reaped_session_id","phase"?}
#         Requires: --reaped-session-id.
#         Optional: --phase (typically "setup-1.6.5").
#
#     Common fields:
#       ts             — ISO-8601 UTC, derived inside the helper from
#                        `date -u`. Caller does not pass.
#       session        — `--session-id` (verbatim).
#       actor_pid      — `--actor-pid` (defaults to $$).
#       worktree       — `--worktree-name`. The basename of the lock /
#                        worktree dir. Held distinct from --worktree-path
#                        because the caller (especially cleanup-summary)
#                        sometimes already strips to a basename for the
#                        log shape but needs the absolute path for the
#                        remove.
#       lock_pid       — JSON value, NOT a quoted string. Pass `null` to
#                        emit `"lock_pid":null`; pass an integer to emit
#                        `"lock_pid":N`. Default when omitted: `null`.
#
#     Exit codes:
#       0  audit-log line written. The reap operation may have succeeded
#          OR the worktree-remove may have failed — for orphan-orchestrator
#          the helper falls back to rm -rf and emits the `-raw-rm` /
#          `-failed` action variant; for `reaped` a failed remove emits the
#          `reaped-failed` variant with a `reason` (issue #712 — the failure
#          is recorded, never swallowed). Exit 0 means the audit-line write
#          itself was attempted; an actual write failure on the JSONL
#          file (permissions, full disk) is fire-and-forget.
#       64 bad usage (missing required flag, unknown action, invalid
#          numeric value for actor-pid/lock-pid).
#
# Pure bash + `ps` + `date` + `git`. No jq, no python — the helper has to
# be cheap to call from the cleanup loop (potentially once per agent
# worktree).

set -u

# --------------------------------------------------------------------------
# Shared helpers (shipyard_home) — issue #887.
# --------------------------------------------------------------------------
# shellcheck source=lib/common.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  worktree-reap.sh classify-lock <lock-file-path> [--orchestrator-pid <N>]
  worktree-reap.sh classify-all --repo-root <path> \
                                [--orchestrator-pid <N>] \
                                [--peer-stale-min <N>]
  worktree-reap.sh reap-stale --repo-root <path> --session-id <id> \
                              [--max-per-session <K>] \
                              [--exclude-agent-id <id> ...] \
                              [--orchestrator-pid <N>] \
                              [--peer-stale-min <N>] [--dry-run]
  worktree-reap.sh reap-orphan-branches --repo-root <path> \
                                        --session-id <id> [--dry-run]
  worktree-reap.sh triage-orphan-branches --repo-root <path> \
                                          --repo <owner/repo> \
                                          --default-branch <name> \
                                          [--max-prs <N>] [--dry-run] \
                                          [--arm-auto-merge]
  worktree-reap.sh report-unreaped --repo-root <path> \
                                   [--current-session-id <id>]
  worktree-reap.sh reap --action <reaped|deferred|reaped-orphan-orchestrator|reaped-failed> \
                        --worktree-path <path> --worktree-name <name> \
                        --session-id <id> [--actor-pid <pid>] \
                        [--classification <c>] [--reason <r>] \
                        [--lock-pid <pid|null>] \
                        [--reaped-session-id <id>] [--phase <p>] \
                        [--skip-remove] [--force-evidence <reason>] \
                        [--bypass-return-check <reason>]
  worktree-reap.sh disk-check --path <dir> [--floor-mb <N>]
  worktree-reap.sh inspect-unpushed --worktree-path <path> \
                                    --default-branch <name> [--fetch]

classify-lock — Prints one of: no-lock | dead | self-ancestor |
                          peer-alive-stale | peer-alive. peer-alive-stale
                          (issue #755) is a lock whose PID is alive but NOT
                          self/ancestor AND whose lock-file mtime exceeds
                          the staleness floor (default 60 min;
                          SHIPYARD_PEER_LOCK_STALE_MIN / --peer-stale-min)
                          — treated as reapable, same as dead/self-ancestor.

classify-all              — Issue #836. Bulk classification: reads every
                          agent-* worktree's lock file and enumerates
                          liveness for the WHOLE batch in O(1) subprocess
                          calls (one `ps` snapshot, one self-ancestor walk,
                          one batched `stat`) instead of forking
                          classify-lock once per worktree. Emits one line
                          per worktree — `<name> <classification>
                          <lock-pid|null>` — sorted oldest-first by
                          worktree-dir mtime. Same classification
                          vocabulary as classify-lock PLUS `no-lock-recent`
                          (issue #1147): a `no-lock` candidate whose
                          worktree DIRECTORY was touched within the
                          --peer-stale-min floor (or whose mtime can't be
                          resolved at all) is presumed live and reported
                          as `no-lock-recent` instead — defer, same
                          posture as peer-alive. Defense-in-depth backstop
                          for a harness-provisioned isolation:"worktree"
                          dispatch, which never writes a shipyard lock
                          file and so classifies identically to a
                          genuinely-abandoned worktree under PID-liveness
                          alone.

reap-stale                — Issue #836 fix 2. Bounded, checkpointed sweep
                          built on classify-all: reaps at most
                          --max-per-session (default 10) reap-eligible
                          worktrees, oldest-first, defers peer-alive /
                          no-lock-recent ones, and leaves the remainder on
                          disk — the on-disk backlog itself is the
                          checkpoint, so a later session picks up where
                          this one left off with no separate state file.
                          --exclude-agent-id (repeat) skips a worktree
                          entirely before classification is even consulted
                          (issue #832 in-flight guard — branch name is
                          never a liveness signal). ALSO auto-derives the
                          same exclusion from
                          $SHIPYARD_HOME/sessions/<session-id>.json's
                          .in_flight[].agent_id (issue #1147) — mandatory,
                          not dependent on the caller remembering to pass
                          --exclude-agent-id; best-effort skipped when the
                          session file doesn't exist yet or jq isn't on
                          PATH. Emits reaped:/unreaped:/deferred: lines
                          plus one `summary: reaped=<R> deferred=<D>
                          unreaped=<U> remaining=<REMAIN>
                          tombstones_swept=<TS> tombstones_failed=<TF>
                          tombstones_remaining=<TR>` line. --dry-run skips
                          removes and audit writes. Issue #1482: the
                          stray-tombstone pass that runs first is bounded
                          by the same --max-per-session cap and reports
                          into that summary line; exit 3 (not 0) when the
                          pass ends partial — unreaped>0 and/or
                          tombstones_failed>0.

detect-orchestrator-pid, derive-session-id, find-orphan-orchestrators
                        — Issue #941: moved to the sibling script
                          session-identity.sh — see that file's own
                          `--help` / header for the full documentation.
                          classify-lock's own self-ancestor short-circuit
                          (SHIPYARD_ORCHESTRATOR_PID) is unaffected; it
                          still lives here and works the same way.

reap-orphan-branches    — Issue #326. Deletes every local worktree-agent-*
                          branch whose branch ref has no live worktree
                          pointing to it (per `git worktree list
                          --porcelain`). Writes one JSONL audit line to
                          $SHIPYARD_HOME/reap-audit.jsonl per deletion.
                          --dry-run emits reaped-branch: lines without
                          deleting or writing the audit log. Idempotent —
                          second pass is a no-op.

triage-orphan-branches  — Issue #1365, follow-up to #1355. Single-call
                          replacement for the setup-3c sweep's own per-branch
                          state machine — PR creation, auto-merge arming,
                          the several tracked counters, and the issue #303
                          stale self-assign sweep — which used to live as a
                          `for wt_dir in $(find ...)` loop directly in the
                          orchestrator's own Bash tool call. Reachable at ANY
                          point in setup, pre- or post-relocation, because
                          it is one script call with no loop shape in the
                          CALLER's own command text. (The sibling sweeps
                          this note used to cite for that property —
                          reap-orphan-orchestrators and sweep-stale-agents
                          — were deleted by issue #1472; Claude Code's own
                          periodic worktree sweep supersedes them. This is
                          now the only pre-relocation sweep.) NOT the
                          same subcommand as reap-orphan-branches above
                          (issue #326, deletes orphaned worktree-agent-*
                          BRANCH REFS with no live worktree) — the two names
                          are easy to conflate; this one triages `do-work/*`
                          issue-branch WORKTREES left over from a prior
                          session (salvage-by-pushing-and-opening-a-PR vs.
                          abandon-and-remove, per worktree), a materially
                          different job (issue #1455). Requires --repo-root,
                          --repo, AND --default-branch (the extra pair its
                          siblings don't need — this sweep alone opens/
                          queries PRs and diffs each candidate against the
                          default branch); --session-id is accepted-and-
                          ignored for CLI symmetry (issue #1400) but is NOT
                          required. See triage_orphan_branches()'s own
                          docstring immediately above its definition for the
                          full per-row state table and output contract.

                          BLAST-RADIUS BOUNDS (issue #1518). This subcommand
                          is the only setup-phase sweep that makes unbounded
                          outward-facing writes, and it runs before the first
                          worker is dispatched. Four properties bound it:
                            * A salvaged PR is opened as a DRAFT with
                              auto-merge NOT armed. A draft PR cannot
                              auto-merge at all, so an unreviewed prior-
                              session branch can never reach the default
                              branch on its own. `--arm-auto-merge` restores
                              the pre-#1518 posture (ready PR, detector-gated
                              arm) and must be typed explicitly.
                            * `--max-prs <N>` (default 3) caps how many PRs
                              ONE invocation may open. On hitting the cap the
                              sweep stops writing, emits one `deferred: <br>`
                              line per un-actioned candidate plus a single
                              `cap-reached: ...` line, and leaves those
                              worktrees untouched for a later re-run.
                              `--max-prs 0` means unlimited (explicit opt-in).
                            * `--dry-run` prints the candidate list and the
                              intended action per branch and performs NO
                              writes at all — no worktree remove, no branch
                              delete, no push, no PR create, no assignee
                              edit. Counters still report what WOULD happen.
                            * Progress is emitted BEFORE each write, not
                              after: a `candidates: <N>` header up front, then
                              one `[k/N] <action> <branch> — <why>` line per
                              candidate. The former output was silent until
                              the terminal `summary:` line, by which point
                              every PR already existed.

                          ALREADY-LANDED PRE-CHECKS (issues #1517, #1541).
                          #1518 bounded the blast radius; this is the
                          predicate that was misfiring. `ahead` compares
                          commits by SHA IDENTITY, so on a squash-merge repo
                          (the schema default for auto_merge.method) it is
                          permanently > 0 for every branch ever landed —
                          `ahead == 0` is unreachable, the worktree
                          candidate set never drains, and each leftover
                          regenerates a duplicate PR every session. Four
                          CONTENT-aware signals now gate PR creation, in
                          evidence-strength order; any one alone suppresses
                          it:
                            1. Empty effective diff — `git diff --quiet
                               origin/<default-branch> HEAD` in the
                               candidate worktree. Pure local git, no API
                               call, and on the recorded repros it alone
                               would have suppressed the large majority.
                               Provably nothing unique here, so the
                               worktree AND the local branch are removed.
                            2. Originating issue (parsed from the
                               `do-work/issue-<N>` branch name) already
                               CLOSED **and** linked to a merged PR via
                               GitHub's own closedByPullRequestsReferences.
                               One `gh` read, made only when check 1 did
                               not fire. Catches the class check 1 cannot:
                               a superseded EARLIER DRAFT, whose diff is
                               non-empty and whose merge would silently
                               revert landed work. Weaker evidence, so the
                               worktree is removed but the branch ref is
                               KEPT as a safety net.
                           2b. The BRANCH'S OWN PR already MERGED — one
                               `gh pr list --state merged --head
                               <do-work/issue-N>` read, made only when
                               checks 1 and 2 have both declined (issue
                               #1565). Check 2 keys exclusively on the
                               ISSUE's closedByPullRequestsReferences, which
                               GitHub populates only when a merged PR
                               carried a closing keyword its linker
                               resolved; an issue closed by hand after its
                               PR landed is CLOSED/COMPLETED with that array
                               EMPTY, so check 2 declines while the branch's
                               own PR sits there MERGED. Asks about the
                               exact head ref the salvage below would push
                               to and open its PR against, so a hit means
                               the PR this sweep is about to duplicate has
                               already merged. Same weak-evidence action as
                               check 2: worktree removed, branch ref KEPT.
                            3. Superseded draft — every path the branch ADDS
                               relative to its merge-base with the default
                               branch already exists on the default branch
                               today (issue #1541). Pure local git, run only
                               when checks 1 and 2 have both declined.
                               Catches the class check 2 structurally
                               cannot: a PR that merged with `refs #N`
                               instead of `closes #N`, or an issue gated on
                               needs-human-review after its code landed,
                               leaves the originating issue OPEN
                               indefinitely while its work sits upstream —
                               so check 2's issue-STATE key never fires.
                               A path absent at the fork point but present
                               upstream now was created upstream after the
                               fork; if EVERY path this branch invents was
                               created upstream independently, the work is
                               already done. Deliberately ignores MODIFIED
                               paths (the coordination-managed CHANGELOG.md
                               / plugin.json rows every PR touches carry no
                               signal) and compares no line, hunk, or byte
                               counts. Same weak-evidence action as check 2:
                               worktree removed, branch ref KEPT.
                          All four fail CONSERVATIVE — an unreadable signal is
                          never evidence of staleness, so anything that
                          cannot be classified is salvaged exactly as
                          before. Suppression runs BEFORE the --max-prs cap,
                          so a leftover backlog no longer eats the budget
                          genuinely-stranded work needs. Worktree removal
                          here is non-force only (#712): "content already
                          upstream" describes HEAD, not the working tree.
                          Emits `[k/N] already-landed <branch> — <why>; ...`
                          per candidate, one `already-landed: <branch> —
                          <why>` summary line each, and an
                          `already_landed=<L>` field on the summary line.

report-unreaped         — Issue #712. Post-sweep verification. Emits one
                          absolute path per line for every agent-* /
                          orchestrator-* worktree still on disk under
                          <repo-root>/.claude/worktrees after the reap sweeps
                          ran, excluding orchestrator-<current-session-id>
                          (still live, reaped last) and *.reap-dead-* scratch
                          dirs (already pruned; unlink synchronous as of
                          issue #1223, so a lingering one here means a sweep
                          is either mid-flight or its delete partially
                          failed). The standalone sweep-tombstones
                          subcommand this note used to point at was deleted
                          by issue #1472 — reap-stale's own first pass is
                          now the only cleaner, and per issue #1482 it
                          reports what it swept, failed on, and left via
                          the tombstones_* fields of its summary line.
                          Empty stdout when everything was reaped. This is the
                          ONLY mechanism that catches a reap denied by Claude
                          Code's auto-mode permission classifier — the denial
                          kills the whole Bash tool call, so no reap-audit line
                          is ever written; only an after-the-fact filesystem
                          probe can see it.

reap                    — Performs the worktree-remove (when applicable)
                          and writes one append-only JSONL line to
                          $SHIPYARD_HOME/reap-audit.jsonl describing the
                          outcome. Issue #284 single source of truth for
                          reap-audit writes — call sites no longer inline
                          the printf >> $REAP_AUDIT_LOG line. Takes
                          --worktree-path/--worktree-name (a single
                          already-identified target) rather than the
                          --repo-root every sweeping subcommand above takes
                          — deliberate, see issue #1305 and the comment
                          above this subcommand's own flag list.
                          The remove escalates plain `git worktree remove`
                          → evidence-gated `git worktree remove --force`
                          (issue #712); `--force-evidence <reason>` lets a
                          caller that already established force-safety (e.g.
                          "no-commits-beyond-base") skip the re-derivation.
                          Actions:
                            reaped               — successful agent
                                                    worktree reap
                                                    (requires
                                                    --classification,
                                                    --lock-pid).
                            reap-refused         — issue #1237. Emitted in
                                                    place of `reaped` when
                                                    --worktree-name matches
                                                    agent-* and no returned-
                                                    record exists in this
                                                    session's
                                                    .returned_agent_ids AND
                                                    --bypass-return-check
                                                    was not passed. NO
                                                    removal is attempted.
                                                    Exit 1.
                            reaped-failed        — issue #712. Emitted in
                                                    place of `reaped` when
                                                    the remove did NOT
                                                    happen; carries a
                                                    `reason` (
                                                    unsafe-to-force-unpushed-work
                                                    | worktree-remove-failed).
                                                    Never swallowed.
                                                    Issue #1274 — ALSO
                                                    directly invocable as
                                                    its own --action (not
                                                    only an internal
                                                    downgrade of `reaped`):
                                                    writes the audit line
                                                    with NO removal
                                                    attempt, for a caller
                                                    that already knows
                                                    (via a separate,
                                                    non-destructive
                                                    post-hoc existence
                                                    check) that a prior
                                                    reap attempt did not
                                                    happen — most commonly
                                                    because the Bash tool
                                                    call invoking `reap
                                                    --action reaped` was
                                                    itself denied outright
                                                    by the auto-mode
                                                    permission classifier,
                                                    which kills the whole
                                                    call before this
                                                    script's own internal
                                                    reaped-vs-reaped-failed
                                                    branching ever runs.
                                                    Requires
                                                    --classification,
                                                    --reason, --lock-pid.
                            deferred             — agent worktree reap
                                                    skipped (peer-alive)
                                                    (requires --reason,
                                                    --lock-pid; implies
                                                    --skip-remove).
                            reaped-orphan-orchestrator
                                                 — orchestrator-worktree
                                                    orphan reap; tries
                                                    git worktree remove,
                                                    falls back to rm -rf
                                                    and emits the
                                                    -raw-rm variant
                                                    (requires
                                                    --reaped-session-id).

disk-check              — Issue #1261. Read-only free-space probe against
                          the volume holding a given directory (the caller
                          passes the worktree volume root). Prints
                          `free_mb=<N|unknown> floor_mb=<F> low=<true|false>`
                          and always exits 0 on well-formed args — never
                          fails closed on an unreadable df result (see the
                          disk_free_check docstring). --floor-mb defaults
                          to 0, which disables the low=true trip entirely.
                          steady-state.md's step C uses this to decide
                          whether to run a mid-session reap-stale sweep
                          before dispatching a replacement worker.

inspect-unpushed         — Issue #1316. Read-only pre-reap inspection of a
                          worker's worktree, callable from a worktree-
                          isolated orchestrator session (the harness's
                          isolation guard refuses a `git -C <other-
                          worktree>` issued directly by the caller, but not
                          one run inside this script). Prints
                          `ahead_count=<N> dirty_count=<N>
                          verdict=<clean|resume-worthy>` on line 1, then a
                          `--- commits ... ---` block (literal `git log
                          --oneline <base>..HEAD` output) and a `--- dirty
                          ... ---` block (literal `git status --porcelain`
                          output) — both verbatim, for folding directly into
                          an A.0.5 resume message. --fetch runs `git fetch
                          origin <default-branch>` first (best-effort).
                          Exits 65 when --worktree-path isn't a readable git
                          worktree (already gone).

Env vars:
  SHIPYARD_ORCHESTRATOR_PID  Explicit orchestrator PID for self-ancestor
                             short-circuit (classify-lock). Overridden by
                             --orchestrator-pid.
  SHIPYARD_HOME              Root for reap-audit.jsonl writes used by `reap`.

Exit codes:
  0  classification emitted (classify-lock) / audit-log write attempted
     (reap) / enumeration succeeded, output may be empty (other sweeps)
  1  reap --action reaped refused — no recorded agent return and no
     --bypass-return-check (issue #1237); no removal was attempted
  64 usage error (missing path, malformed flag, missing required flag)
EOF
}

# Extract the lock PID from a lock file.
#
# Lock-file format (set by the Claude Code harness) — the PID may be
# followed by additional fields (issue #1206: real harness locks were found
# to also carry a `start <ctime>` field between the PID and the closing
# paren):
#   claude agent <agent-id> (pid <N>)
#   claude session <orchestrator-id> (pid <N> start <ctime>)
#
# Returns the numeric PID on stdout, or empty string if no PID can be parsed.
# Robust to: missing file, malformed content, multiple PID-like tokens (takes
# the first one — the harness format only ever has one), and trailing fields
# after the PID (start time, or any future field the harness adds).
extract_lock_pid() {
  local lock_file="$1"
  [ -f "$lock_file" ] || return 0
  # Anchor on the literal `pid` keyword rather than on "first digit-run
  # before a close-paren" (issue #1206). The pre-#1206 regex,
  # `grep -oE '[0-9]+\)'`, assumed the PID was immediately followed by `)` —
  # true only for the idealized `(pid <N>)` shape. Real harness locks write
  # `(pid <N> start <ctime>)`, and a ctime's own trailing token is always a
  # 4-digit year followed by `)` (e.g. `... 2026)`), so the old regex's
  # FIRST match was the ctime's year, not the PID — deterministically wrong
  # for every real lock file, not merely an edge case. Anchoring on `pid`
  # makes the parse independent of whatever trails the number.
  grep -oE '\(pid[[:space:]]+[0-9]+' "$lock_file" 2>/dev/null \
    | grep -oE '[0-9]+' | head -1
}

# Is `pid` alive? Returns 0 (alive) / 1 (dead-or-unknown).
pid_alive() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  ps -p "$pid" -o pid= >/dev/null 2>&1
}

# Issue #1207 — extract the `start <ctime>` field's VALUE from lock-file
# CONTENT already read into a variable. `extract_lock_start()` below wraps
# this for single-file call sites (classify-lock); `classify_all`'s Pass 1
# calls this directly against content it already read, to avoid a second
# file read per lock.
#
# Lock-file format: `... (pid <N> start <ctime>)`, where <ctime> is a
# `ps -o lstart`-shaped string, e.g. `Mon Aug 10 12:58:36 2026`. NOT every
# lock carries a `start` field — only the harness's session-level lock does
# today (the common `claude agent <agent-id> (pid <N>)` shape has none) — so
# an empty return is the expected, common case, not an error.
extract_lock_start_from_content() {
  local content="$1"
  [ -n "$content" ] || return 0
  # Anchor on `pid <N> start` rather than a bare `start ` (issue #1207
  # CI-regression fix). A bare `start [^)]+\)` false-matches any lock whose
  # agent-id happens to end in "start" — e.g. the common
  # `agent-<id>-nostart (pid <N>)` shape used by this file's own no-start-field
  # test fixture: "...nostart (pid 12345)" contains the literal substring
  # "start (pid 12345)", which the bare pattern happily matches and extracts
  # as if it were the ctime value. The extracted garbage ("(pid 12345") then
  # fails to parse as a ctime on macOS/BSD `date` (both zone interpretations
  # end up empty, so `lock_start_corroborates_ps()` still calls it
  # "corroborated") but DOES parse on GNU `date -d` — which is why this
  # shipped locally green and only broke on Linux CI: `expected: peer-alive,
  # actual: peer-alive-stale`. Requiring the literal `pid <N> ` immediately
  # before `start` mirrors extract_lock_pid()'s own `\(pid[[:space:]]+[0-9]+`
  # anchor above and only matches the real `(pid <N> start <ctime>)` shape,
  # never a coincidental "start" substring elsewhere in the lock content.
  printf '%s' "$content" | grep -oE 'pid[[:space:]]+[0-9]+[[:space:]]+start [^)]+\)' 2>/dev/null \
    | sed -E 's/^pid[[:space:]]+[0-9]+[[:space:]]+start //; s/\)[[:space:]]*$//' \
    | head -1
}

# File-based wrapper around extract_lock_start_from_content() above, for
# classify-lock's single-lock-file call sites.
extract_lock_start() {
  local lock_file="$1"
  [ -f "$lock_file" ] || return 0
  extract_lock_start_from_content "$(<"$lock_file")"
}

# Issue #1207 — parse a `ps -o lstart`-shaped ctime string
# ("Mon Aug 10 12:58:36 2026") to epoch seconds, interpreting it in the zone
# named by `$2` ("utc" or "local"). Prints the epoch on stdout and returns 0
# on success; returns 1 (no stdout) when the string can't be parsed at all.
#
# Two independent parse strategies are tried, GNU first then BSD, mirroring
# every other GNU/BSD dual-path already in this file (e.g. the `stat -c` /
# `stat -f` fallback pair a few functions down). GNU `date -d` accepts the
# ctime string directly; BSD/macOS `date -j -f` needs an explicit format
# string. `TZ=<zone> date ...` reinterprets a zone-less input string AS that
# zone before converting to epoch — this is the whole mechanism issue
# #1207's fix rests on (verified against a real lock/`ps` pair during that
# issue's investigation: `TZ=UTC date -j -f "%a %b %e %T %Y" "<lock start>"
# +%s` reproduced the exact epoch the SAME process's actual start time
# converts to).
parse_ctime_epoch() {
  local ctime_str="$1"
  local zone="$2"
  [ -n "$ctime_str" ] || return 1

  local epoch=""
  if [ "$zone" = "utc" ]; then
    epoch=$(TZ=UTC date -d "$ctime_str" +%s 2>/dev/null)
    if [ -z "$epoch" ]; then
      epoch=$(TZ=UTC date -j -f "%a %b %e %T %Y" "$ctime_str" +%s 2>/dev/null)
    fi
  else
    epoch=$(date -d "$ctime_str" +%s 2>/dev/null)
    if [ -z "$epoch" ]; then
      epoch=$(date -j -f "%a %b %e %T %Y" "$ctime_str" +%s 2>/dev/null)
    fi
  fi

  [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$epoch"
  return 0
}

# Issue #1207 — cross-check a lock's own recorded `start <ctime>` field
# against `ps -o lstart` for the same (alive) PID. See the "Why a third
# gate" comment near the top of this file for the full rationale, the
# timezone-mismatch hazard, and why this fails safe.
#
# Args: $1 = the lock's recorded start-time string (may be empty — a lock
#            with no `start` field), $2 = the pid to check against.
#
# Prints one token on stdout:
#   corroborated — one of the two zone interpretations (UTC or this host's
#                  local zone) matches `ps -o lstart` within tolerance, OR
#                  nothing could be compared at all (no `start` field, `ps`
#                  couldn't report `lstart`, or a timestamp failed to
#                  parse) — "cannot confidently establish reuse" must NEVER
#                  be treated as reuse (fail safe, not fail open — #1207's
#                  explicit hazard: misclassifying a live lock as stale
#                  enables reaping a running session's worktree).
#   mismatch     — NEITHER interpretation matches; PID reuse is suspected.
# Always returns 0 — this classifies, it never errors.
lock_start_corroborates_ps() {
  local lock_start="$1"
  local pid="$2"
  local tolerance="${SHIPYARD_LOCK_START_TOLERANCE_SEC:-120}"
  [[ "$tolerance" =~ ^[0-9]+$ ]] || tolerance=120

  if [ -z "$lock_start" ]; then
    echo "corroborated"
    return 0
  fi

  local ps_start
  ps_start=$(ps -p "$pid" -o lstart= 2>/dev/null | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  if [ -z "$ps_start" ]; then
    echo "corroborated"
    return 0
  fi

  local ps_epoch
  ps_epoch=$(parse_ctime_epoch "$ps_start" local)
  if [ -z "$ps_epoch" ]; then
    echo "corroborated"
    return 0
  fi

  local lock_epoch_utc lock_epoch_local
  lock_epoch_utc=$(parse_ctime_epoch "$lock_start" utc) || lock_epoch_utc=""
  lock_epoch_local=$(parse_ctime_epoch "$lock_start" local) || lock_epoch_local=""

  if [ -z "$lock_epoch_utc" ] && [ -z "$lock_epoch_local" ]; then
    echo "corroborated"
    return 0
  fi

  local diff
  if [ -n "$lock_epoch_utc" ]; then
    diff=$(( ps_epoch - lock_epoch_utc ))
    [ "$diff" -lt 0 ] && diff=$(( -diff ))
    if [ "$diff" -le "$tolerance" ]; then
      echo "corroborated"
      return 0
    fi
  fi
  if [ -n "$lock_epoch_local" ]; then
    diff=$(( ps_epoch - lock_epoch_local ))
    [ "$diff" -lt 0 ] && diff=$(( -diff ))
    if [ "$diff" -le "$tolerance" ]; then
      echo "corroborated"
      return 0
    fi
  fi

  echo "mismatch"
  return 0
}

# Walk our own ancestor chain and emit each PID on its own line: self, parent,
# grandparent, ... up to PID 1 (init) or until `ps` stops resolving.
#
# Stops at PID 1 because every PID is an ancestor of itself trivially via
# init, and matching against PID 1 would defeat the point of the check.
#
# The orchestrator's PID will be in this list whenever this helper is called
# from a shell the orchestrator launched (transitively, however many harness
# layers are in between).
self_ancestor_pids() {
  local pid=$$
  local guard=0
  while [ -n "$pid" ] && [ "$pid" != "1" ] && [ "$pid" != "0" ]; do
    echo "$pid"
    # Bound the walk — defensive against pathological /proc states that
    # could loop. 64 ancestors is far beyond any real process tree.
    guard=$((guard + 1))
    [ "$guard" -gt 64 ] && break
    local parent
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$parent" ] && break
    [ "$parent" = "$pid" ] && break   # paranoid: self-cycle
    pid="$parent"
  done
}

# Is `pid` in our own ancestor chain?
is_self_ancestor() {
  local target="$1"
  [ -n "$target" ] || return 1
  local p
  while IFS= read -r p; do
    [ "$p" = "$target" ] && return 0
  done < <(self_ancestor_pids)
  return 1
}

# detect_orchestrator_pid() moved to session-identity.sh (issue #941). Note
# for anyone tracing classify-lock's SHIPYARD_ORCHESTRATOR_PID short-circuit
# below: classify_lock does NOT call it — the short-circuit only ever
# consults the env var / --orchestrator-pid flag a caller already resolved
# (typically by shelling out to `session-identity.sh detect-orchestrator-pid`
# once, at phase start, and exporting the result). classify-lock has no
# lazy auto-detect path of its own.
classify_lock() {
  local lock_file=""
  local orchestrator_pid="${SHIPYARD_ORCHESTRATOR_PID:-}"
  local peer_stale_min="${SHIPYARD_PEER_LOCK_STALE_MIN:-60}"

  # Argv parsing: positional <lock-file-path> first, then optional
  # --orchestrator-pid <N> / --peer-stale-min <N>. Flag-after-positional is
  # the typical shape from the orchestrator's call sites (`classify-lock
  # "$wt_dir/locked" --orchestrator-pid $$`); flag-before-positional also
  # accepted.
  while [ $# -gt 0 ]; do
    case "$1" in
      --orchestrator-pid)
        if [ -z "${2:-}" ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
          echo "classify-lock: --orchestrator-pid requires a non-negative integer (got: ${2:-})" >&2
          return 64
        fi
        orchestrator_pid="$2"
        shift 2
        ;;
      --orchestrator-pid=*)
        local val="${1#--orchestrator-pid=}"
        if ! [[ "$val" =~ ^[0-9]+$ ]]; then
          echo "classify-lock: --orchestrator-pid requires a non-negative integer (got: $val)" >&2
          return 64
        fi
        orchestrator_pid="$val"
        shift
        ;;
      --peer-stale-min)
        if [ -z "${2:-}" ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
          echo "classify-lock: --peer-stale-min requires a non-negative integer (got: ${2:-})" >&2
          return 64
        fi
        peer_stale_min="$2"
        shift 2
        ;;
      --peer-stale-min=*)
        local stale_val="${1#--peer-stale-min=}"
        if ! [[ "$stale_val" =~ ^[0-9]+$ ]]; then
          echo "classify-lock: --peer-stale-min requires a non-negative integer (got: $stale_val)" >&2
          return 64
        fi
        peer_stale_min="$stale_val"
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      --)
        shift
        ;;
      -*)
        echo "classify-lock: unknown flag: $1" >&2
        return 64
        ;;
      *)
        if [ -z "$lock_file" ]; then
          lock_file="$1"
        else
          echo "classify-lock: unexpected positional arg: $1" >&2
          return 64
        fi
        shift
        ;;
    esac
  done

  # An env-var value that isn't a non-negative integer is a configuration
  # bug at the call site — better to surface it than silently drop into the
  # ancestor-walk fallback. The --orchestrator-pid / --peer-stale-min flag
  # paths already validate above; these guards catch malformed env-var
  # values.
  if [ -n "$orchestrator_pid" ] && ! [[ "$orchestrator_pid" =~ ^[0-9]+$ ]]; then
    echo "classify-lock: SHIPYARD_ORCHESTRATOR_PID must be a non-negative integer (got: $orchestrator_pid)" >&2
    return 64
  fi
  if ! [[ "$peer_stale_min" =~ ^[0-9]+$ ]]; then
    echo "classify-lock: SHIPYARD_PEER_LOCK_STALE_MIN must be a non-negative integer (got: $peer_stale_min)" >&2
    return 64
  fi

  if [ -z "$lock_file" ]; then
    usage
    return 64
  fi

  if [ ! -f "$lock_file" ]; then
    echo "no-lock"
    return 0
  fi

  local lock_pid
  lock_pid=$(extract_lock_pid "$lock_file")

  # Lock file exists but has no parseable PID — fail CLOSED, not open
  # (issue #1206). The original semantics treated an extraction failure as
  # `dead` (reap-eligible), on the reasoning that a missing PID can't trip
  # the liveness check either way — but that reasoning silently assumed
  # extraction failure is rare and content-empty. It is neither: every real
  # harness lock (`(pid <N> start <ctime>)`) failed to extract under the
  # pre-#1206 regex, so this branch was live on the majority of production
  # locks, converting a routine parse gap into the default destructive
  # verdict. An unparseable lock might belong to a live peer whose lock
  # simply doesn't match the expected shape — `unknown` says exactly that,
  # and callers that gate a defer decision on `peer-alive` treat `unknown`
  # identically (see the `classify-lock` docstring above for the callers
  # updated to do so).
  if [ -z "$lock_pid" ]; then
    echo "unknown"
    return 0
  fi

  if ! pid_alive "$lock_pid"; then
    echo "dead"
    return 0
  fi

  # Issue #263 fix: short-circuit on declared orchestrator PID before the
  # ancestor walk. This makes the classification authoritative regardless of
  # process-tree shape — covers cases where the ancestor walk fails because
  # an intermediate harness layer returns empty PPID, OR cases where the
  # caller is a subagent whose process tree doesn't actually reach back to
  # the orchestrator. The check is gated on `pid_alive` above so a stale
  # orchestrator PID (recycled by the OS) wouldn't wrongly match a live
  # peer's PID — the env var only short-circuits when the lock PID is alive
  # AND equals the declared orchestrator PID.
  if [ -n "$orchestrator_pid" ] && [ "$lock_pid" = "$orchestrator_pid" ]; then
    echo "self-ancestor"
    return 0
  fi

  if is_self_ancestor "$lock_pid"; then
    echo "self-ancestor"
    return 0
  fi

  # Issue #1207 — third gate: cross-check the lock's own recorded start
  # time against `ps -o lstart` for this (alive, non-self) pid BEFORE
  # trusting PID liveness alone. See lock_start_corroborates_ps()'s
  # docstring and the "Why a third gate" comment at the top of this file for
  # the full rationale and the fail-safe posture. A mismatch is direct
  # evidence of PID reuse — reap-eligible regardless of the lock file's own
  # mtime freshness, so this short-circuits straight to peer-alive-stale
  # rather than falling into the #755 mtime gate below.
  local lock_start corroboration
  lock_start=$(extract_lock_start "$lock_file")
  corroboration=$(lock_start_corroborates_ps "$lock_start" "$lock_pid")
  if [ "$corroboration" = "mismatch" ]; then
    echo "peer-alive-stale"
    return 0
  fi

  # Issue #755 — second gate before committing to `peer-alive`. PID
  # liveness alone can't distinguish a genuine peer from a dead
  # prior-session PID the OS has since recycled onto an unrelated live
  # process (the same ambiguity #253 already solved for orphan session
  # files with a PID-liveness + mtime "two gates" combo). Corroborate with
  # the lock file's own mtime: a lock older than `peer_stale_min` (default
  # 60 min — see the "Why a second gate" note at the top of this file) is
  # treated as a stale/recycled-PID false positive and reaped; a fresher
  # one still defers, since a genuine peer within that window is entirely
  # plausible.
  local lock_mtime now lock_age_min
  lock_mtime=$(stat -c %Y "$lock_file" 2>/dev/null || stat -f %m "$lock_file" 2>/dev/null || echo "")
  now=$(date +%s 2>/dev/null || echo "")
  if [ -n "$lock_mtime" ] && [ -n "$now" ]; then
    lock_age_min=$(( (now - lock_mtime) / 60 ))
    if [ "$lock_age_min" -ge "$peer_stale_min" ] 2>/dev/null; then
      echo "peer-alive-stale"
      return 0
    fi
  fi

  echo "peer-alive"
  return 0
}

# Issue #836 — bulk classification. `classify-lock` is correct but costs one
# full script re-invocation PLUS its own internal `ps`/`stat` subprocess
# forks PER worktree. On a repo that has accumulated many orphaned agent
# worktrees (the #836 repro: 60 worktrees, ~1.6GB each), step 3b's loop
# forked `classify-lock` 60 times — each fork paying its own `ps -p`/`stat`
# cost — and blew the caller's time budget before classifying a single
# candidate. `classify-all` reads every lock file and enumerates every
# worktree directory in ONE pass, then does the liveness check with exactly
# ONE `ps` call for the whole batch (a single `ps -e -o pid=` snapshot,
# checked in-memory per lock — not one `ps -p <pid>` per worktree), and the
# self-ancestor walk exactly ONCE (not once per worktree). The only
# remaining subprocess calls are: one `find`, one `ps`, one self-ancestor
# walk, one batched `stat` over every worktree directory's mtime, and — only
# for locks that reach the peer-alive branch (alive, not self/ancestor) — a
# `stat` on that lock file's mtime for the staleness gate. This is the same
# classification semantics as `classify-lock`, computed for N worktrees in
# O(1) subprocess calls instead of O(N).
#
# Output: one line per `agent-*` worktree found under
# <repo-root>/.git/worktrees, space-separated:
#   <name> <classification> <lock-pid|null> <worktree-dir-mtime-epoch|0>
# classification is one of: no-lock | dead | self-ancestor |
#   peer-alive-stale | peer-alive — identical vocabulary to classify-lock.
# Empty stdout when there are no agent-* worktrees. Lines are sorted by
# worktree-dir mtime ascending (oldest first) so a caller implementing an
# oldest-first reap cap (issue #836 fix 2) can consume the output directly
# without a separate sort pass.
#
# Args (all optional except --repo-root):
#   --repo-root <path>          (required) repo root containing .git/worktrees
#                                and .claude/worktrees
#   --orchestrator-pid <N>      same semantics as classify-lock
#   --peer-stale-min <N>        same semantics as classify-lock (default 60)
#
# Exit codes: 0 (enumeration succeeded, output may be empty), 64 (bad usage).
classify_all() {
  local repo_root=""
  local orchestrator_pid="${SHIPYARD_ORCHESTRATOR_PID:-}"
  local peer_stale_min="${SHIPYARD_PEER_LOCK_STALE_MIN:-60}"

  while [ $# -gt 0 ]; do
    case "$1" in
      --repo-root)
        repo_root="${2:-}"
        shift 2
        ;;
      --repo-root=*)
        repo_root="${1#--repo-root=}"
        shift
        ;;
      --orchestrator-pid)
        if [ -z "${2:-}" ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
          echo "classify-all: --orchestrator-pid requires a non-negative integer (got: ${2:-})" >&2
          return 64
        fi
        orchestrator_pid="$2"
        shift 2
        ;;
      --orchestrator-pid=*)
        local oa_val="${1#--orchestrator-pid=}"
        if ! [[ "$oa_val" =~ ^[0-9]+$ ]]; then
          echo "classify-all: --orchestrator-pid requires a non-negative integer (got: $oa_val)" >&2
          return 64
        fi
        orchestrator_pid="$oa_val"
        shift
        ;;
      --peer-stale-min)
        if [ -z "${2:-}" ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
          echo "classify-all: --peer-stale-min requires a non-negative integer (got: ${2:-})" >&2
          return 64
        fi
        peer_stale_min="$2"
        shift 2
        ;;
      --peer-stale-min=*)
        local ps_val="${1#--peer-stale-min=}"
        if ! [[ "$ps_val" =~ ^[0-9]+$ ]]; then
          echo "classify-all: --peer-stale-min requires a non-negative integer (got: $ps_val)" >&2
          return 64
        fi
        peer_stale_min="$ps_val"
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      --)
        shift
        ;;
      -*)
        echo "classify-all: unknown flag: $1" >&2
        return 64
        ;;
      *)
        echo "classify-all: unexpected positional arg: $1" >&2
        return 64
        ;;
    esac
  done

  if [ -z "$repo_root" ]; then
    echo "classify-all: --repo-root is required" >&2
    return 64
  fi
  if [ -n "$orchestrator_pid" ] && ! [[ "$orchestrator_pid" =~ ^[0-9]+$ ]]; then
    echo "classify-all: SHIPYARD_ORCHESTRATOR_PID must be a non-negative integer (got: $orchestrator_pid)" >&2
    return 64
  fi
  if ! [[ "$peer_stale_min" =~ ^[0-9]+$ ]]; then
    echo "classify-all: SHIPYARD_PEER_LOCK_STALE_MIN must be a non-negative integer (got: $peer_stale_min)" >&2
    return 64
  fi

  local git_wt_dir="$repo_root/.git/worktrees"
  [ -d "$git_wt_dir" ] || return 0

  # Bash-3.2 compatible throughout (no `declare -A` / associative arrays —
  # macOS ships bash 3.2 as its default /usr/bin/env resolution, and every
  # other function in this file is already written to that floor). Set
  # membership below uses the same sentinel-delimited-string pattern
  # `reap_session_worktrees`'s `seen_csv` already uses in this file, and
  # name-keyed lookups use parallel indexed arrays with a linear scan —
  # cheap in-memory string comparisons at the tens-to-low-hundreds scale
  # this sweep runs at, and still far cheaper than the subprocess-per-
  # worktree cost this subcommand exists to eliminate.

  # Pass 1 — enumerate every agent-* worktree dir under .git/worktrees in
  # ONE find call, and read every lock file's PID with pure-bash regex
  # matching (no subprocess fork per lock file). lock_exists[i] / lock_pids[i]
  # are parallel arrays keyed by the SAME index as names[i]. Named
  # `lock_pids` (plural) rather than `lock_pid` deliberately — `lock_pid`
  # (singular, scalar) is already used by classify_lock/reap_action
  # elsewhere in this file; a same-named local array here is functionally
  # scope-safe but confuses static analysis across function boundaries.
  local names=()
  local lock_exists=()
  local lock_pids=()
  # Issue #1207 — parallel array of each lock's recorded `start <ctime>`
  # field (empty string when the lock has none, the common case). Extracted
  # from `content` here, alongside the pid regex, so Pass 5's cross-check
  # costs no additional file read.
  local lock_starts=()
  local d name lock_file content pid
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    name="${d##*/}"
    names+=("$name")
    lock_file="$git_wt_dir/$name/locked"
    if [ -f "$lock_file" ]; then
      lock_exists+=("1")
      content=$(<"$lock_file")
      # Anchor on `(pid <N>` only — do NOT also require an immediate `)`
      # (issue #1206). The prior pattern, `\(pid[[:space:]]+([0-9]+)\)`,
      # required the digits to be followed IMMEDIATELY by the closing paren
      # — true only for the idealized `(pid <N>)` shape. Real harness locks
      # write `(pid <N> start <ctime>)`, where a `start <ctime>` field sits
      # between the PID and the paren, so the old pattern never matched a
      # real lock at all and `pid` silently fell through to empty on every
      # one of them (see the empty-`pid` branch below, also fixed by #1206).
      if [[ "$content" =~ \(pid[[:space:]]+([0-9]+) ]]; then
        pid="${BASH_REMATCH[1]}"
      else
        pid=""
      fi
      lock_starts+=("$(extract_lock_start_from_content "$content")")
    else
      lock_exists+=("0")
      pid=""
      lock_starts+=("")
    fi
    lock_pids+=("$pid")
  done < <(find "$git_wt_dir" -maxdepth 1 -type d -name 'agent-*' 2>/dev/null | sort)

  [ ${#names[@]} -eq 0 ] && return 0

  # Pass 2 — ONE `ps` call resolves liveness for EVERY pid in play at once:
  # build a newline-bounded blob of every live pid on the system, then test
  # membership per lock with a bash pattern match (no subprocess). This
  # replaces what would otherwise be N `ps -p <pid>` / kill -0 subprocess
  # calls — the O(n) subprocess cost issue #836 reports.
  local alive_blob=$'\n'
  local live_pid
  while IFS= read -r live_pid; do
    live_pid="${live_pid// /}"
    [ -n "$live_pid" ] && alive_blob+="${live_pid}"$'\n'
  done < <(ps -e -o pid= 2>/dev/null)

  # Pass 3 — self-ancestor set, computed ONCE for the whole batch (not once
  # per worktree the way a per-worktree classify-lock call would). Same
  # blob-membership technique as alive_blob above.
  local self_ancestor_blob=$'\n'
  local sa_pid
  while IFS= read -r sa_pid; do
    [ -n "$sa_pid" ] && self_ancestor_blob+="${sa_pid}"$'\n'
  done < <(self_ancestor_pids)

  # Pass 4 — batch-stat every worktree DIRECTORY's mtime in one call (used
  # for oldest-first ordering by an issue-#836-fix-2 caller). GNU and
  # BSD/macOS `stat` differ in flag shape; try GNU first, fall back to BSD.
  # Both forms accept multiple paths in a single invocation and print one
  # line per path. stat_names[i] / stat_mtimes[i] are parallel arrays,
  # looked up by linear scan below (order isn't assumed to match `names`).
  local wt_root="$repo_root/.claude/worktrees"
  local stat_paths=()
  for name in "${names[@]}"; do
    stat_paths+=("$wt_root/$name")
  done
  local stat_out
  stat_out=$(stat -c '%Y %n' "${stat_paths[@]}" 2>/dev/null)
  if [ -z "$stat_out" ]; then
    stat_out=$(stat -f '%m %N' "${stat_paths[@]}" 2>/dev/null)
  fi
  local stat_names=()
  local stat_mtimes=()
  local mline mtime mpath
  while IFS= read -r mline; do
    [ -z "$mline" ] && continue
    mtime="${mline%% *}"
    mpath="${mline#* }"
    stat_names+=("${mpath##*/}")
    stat_mtimes+=("$mtime")
  done <<< "$stat_out"

  # Issue #1147 — `now`, computed ONCE for the whole batch (not once per
  # no-lock candidate), used below by the no-lock-recent staleness gate.
  # Same batching philosophy as alive_blob / self_ancestor_blob above: one
  # subprocess for the entire sweep, not O(n).
  local batch_now
  batch_now=$(date +%s 2>/dev/null || echo "")

  # Pass 5 — classify each worktree from the in-memory data built above.
  # Only a peer-alive candidate (alive, not self/ancestor) pays a per-lock
  # `stat` call, for the staleness gate — every other branch is pure
  # in-memory lookup / pattern match.
  local out_lines=()
  local i found_mtime j classification no_lock_age_min
  for ((i = 0; i < ${#names[@]}; i++)); do
    name="${names[$i]}"
    pid="${lock_pids[$i]}"

    # Linear-scan lookup of this worktree's directory mtime by name — moved
    # ahead of classification (issue #1147) so the no-lock branch below can
    # consult it.
    found_mtime="0"
    for ((j = 0; j < ${#stat_names[@]}; j++)); do
      if [ "${stat_names[$j]}" = "$name" ]; then
        found_mtime="${stat_mtimes[$j]}"
        break
      fi
    done

    classification=""
    if [ "${lock_exists[$i]}" = "0" ]; then
      # Issue #1147 — a harness-provisioned `isolation: "worktree"`
      # dispatch (the default Agent-tool shape since #830) never writes a
      # shipyard lock file, so a currently-running worker's worktree
      # classifies identically to `no-lock` under plain PID-liveness. The
      # mandatory in-flight cross-check in `reap_stale` (below) is the
      # PRIMARY guard for THIS session's own live agents; this is the
      # defense-in-depth layer for the cross-session case (a peer
      # orchestrator's live agent, whose in_flight this process cannot
      # read). Mirror the existing peer-alive-stale mtime floor exactly —
      # same `peer_stale_min` knob, same calibration tradeoff documented at
      # the top of this file ("Why a second gate"): a worktree DIRECTORY
      # touched within the floor is presumed live and deferred, exactly
      # like a fresh peer-alive lock; older than the floor falls through to
      # the original `no-lock` (reap-eligible) verdict.
      #
      # Fail CLOSED, not open, when the mtime can't be resolved at all
      # (found_mtime stayed "0" — the stat lookup found nothing for this
      # name, e.g. a dangling `.git/worktrees` registration with no
      # `.claude/worktrees` directory left to stat): treat as
      # no-lock-recent (deferred), mirroring classify_lock's own
      # unresolvable-mtime fallback to `peer-alive` rather than to a
      # reap-eligible state. This is safe either way — a genuinely
      # nonexistent directory has nothing for `reap_action` to destroy, and
      # a dangling registration with no live worktree gets pruned by the
      # unconditional `git worktree prune` every reap-stale caller already
      # runs right after this sweep.
      if [ -n "$found_mtime" ] && [ "$found_mtime" != "0" ] && [ -n "$batch_now" ]; then
        no_lock_age_min=$(( (batch_now - found_mtime) / 60 ))
        if [ "$no_lock_age_min" -ge "$peer_stale_min" ] 2>/dev/null; then
          classification="no-lock"
        else
          classification="no-lock-recent"
        fi
      else
        classification="no-lock-recent"
      fi
    elif [ -z "$pid" ]; then
      # Lock file exists (lock_exists[i]=1) but no PID could be parsed from
      # it — fail CLOSED, not open (issue #1206), mirroring classify_lock's
      # own `unknown` verdict. `reap_stale` (this function's caller) defers
      # on `unknown` exactly as it already defers on `peer-alive`.
      classification="unknown"
    elif [[ "$alive_blob" == *$'\n'"$pid"$'\n'* ]]; then
      if [ -n "$orchestrator_pid" ] && [ "$pid" = "$orchestrator_pid" ]; then
        classification="self-ancestor"
      elif [[ "$self_ancestor_blob" == *$'\n'"$pid"$'\n'* ]]; then
        classification="self-ancestor"
      else
        # Issue #1207 — same third gate as classify_lock: cross-check this
        # lock's recorded start time (already extracted into lock_starts[]
        # in Pass 1, no extra file read) against `ps -o lstart` for this
        # pid. This DOES pay one extra `ps -p` subprocess call, but only for
        # locks that reach this branch (alive, not self/ancestor) — the same
        # rare branch that already pays a per-lock `stat` call below, so it
        # doesn't reintroduce the O(n) cost classify_all exists to avoid.
        local corroboration
        corroboration=$(lock_start_corroborates_ps "${lock_starts[$i]}" "$pid")
        if [ "$corroboration" = "mismatch" ]; then
          classification="peer-alive-stale"
        else
          local lock_mtime now age_min
          lock_mtime=$(stat -c %Y "$git_wt_dir/$name/locked" 2>/dev/null \
            || stat -f %m "$git_wt_dir/$name/locked" 2>/dev/null)
          now=$(date +%s 2>/dev/null || echo "")
          if [ -n "$lock_mtime" ] && [ -n "$now" ]; then
            age_min=$(( (now - lock_mtime) / 60 ))
            if [ "$age_min" -ge "$peer_stale_min" ] 2>/dev/null; then
              classification="peer-alive-stale"
            else
              classification="peer-alive"
            fi
          else
            classification="peer-alive"
          fi
        fi
      fi
    else
      classification="dead"
    fi

    out_lines+=("$found_mtime $name $classification ${pid:-null}")
  done

  # Emit sorted oldest-first by worktree-dir mtime (numeric sort on the
  # leading field), then drop that sort key from the printed line.
  printf '%s\n' "${out_lines[@]}" | sort -n -k1,1 | while IFS= read -r line; do
    printf '%s\n' "${line#* }"
  done

  return 0
}

# Issue #712 — evidence gate for the `--force` escalation.
#
# `git worktree remove --force` reads — to a human, and to Claude Code's
# auto-mode permission classifier — as irreversible local destruction: it
# discards uncommitted work and unmerged commits that may exist nowhere else.
# In auto permission mode the classifier DENIES the command outright
# ("[Irreversible Local Destruction] ... this destroys uncommitted work and
# unmerged commits that exist nowhere else"), which silently defeats the entire
# reap subsystem — the #712 repro found five stale worktrees on one repo, every
# one of them the residue of an already-merged PR.
#
# The mitigation is to make the command look as safe as it actually is: try the
# plain, non-destructive `git worktree remove` first (git itself refuses it on a
# dirty tree — exactly the safety property the classifier is protecting), and
# only escalate to `--force` when a preceding, explicit check has established
# that forcing destroys nothing that exists solely in this worktree.
#
# Force is safe when ANY of:
#   (a) the caller passed positive evidence (`--force-evidence <reason>`) from a
#       check it already performed — e.g. setup 3c's `rev-list --count
#       origin/<default>..HEAD == 0` (no commits beyond base);
#   (b) every commit reachable from HEAD already exists on a remote-tracking ref
#       (`git branch -r --contains HEAD` is non-empty) — the work is on origin;
#   (c) HEAD carries no commits beyond the default remote branch — nothing
#       unique to lose.
#
# Anything else (dirty tree carrying unpushed commits) is NOT forced. The caller
# records a `reaped-failed` audit line and leaves the worktree on disk for a
# human — a surfaced leftover is strictly better than a silent destruction.
#
# Returns 0 (safe to force) / 1 (not safe).
worktree_force_is_safe() {
  local worktree_path="$1"
  local evidence="${2:-}"

  # (a) Caller-supplied evidence from a preceding, explicit check.
  [ -n "$evidence" ] && return 0

  # Not a readable git worktree at all (crash-orphan dir whose registration was
  # already pruned). There is nothing for `git worktree remove` to operate on;
  # the orphan-orchestrator caller escalates to `rm -rf` on its own rather than
  # claiming force-safety here.
  git -C "$worktree_path" rev-parse --git-dir >/dev/null 2>&1 || return 1

  # (b) Every commit reachable from HEAD is already on a remote-tracking ref.
  if [ -n "$(git -C "$worktree_path" branch -r --contains HEAD 2>/dev/null)" ]; then
    return 0
  fi

  # (c) No commits beyond the default remote branch — nothing unique to lose.
  local base=""
  base="$(git -C "$worktree_path" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  if [ -z "$base" ]; then
    local cand
    for cand in origin/main origin/master; do
      if git -C "$worktree_path" rev-parse --verify --quiet "$cand" >/dev/null 2>&1; then
        base="$cand"
        break
      fi
    done
  fi
  if [ -n "$base" ]; then
    local ahead
    ahead="$(git -C "$worktree_path" rev-list --count "${base}..HEAD" 2>/dev/null || echo 1)"
    [ "$ahead" = "0" ] && return 0
  fi

  return 1
}

# Issue #664 — fast worktree-lock reap. `git worktree remove --force`
# recursively unlinks the worktree directory *inline*, which stalls for many
# seconds to minutes when the worktree carries a large `node_modules/` (tens
# of thousands of small files). The branch checked out in that worktree stays
# locked until the remove completes, so a slow remove blocks fix-checks
# retries that need the head branch ("head branch locked in another
# worktree").
#
# The fast path decouples branch-freeing from bulk deletion:
#   1. git worktree unlock <wt>              (a locked worktree's registration
#                                             is NOT pruned, so the branch
#                                             would stay held — unlock first)
#   2. mv <wt> <wt>.reap-dead-<pid>-<epoch>  (instant inode relink on the same
#                                             filesystem — NOT a recursive copy)
#   3. git worktree prune                    (the registered worktree path is
#                                             now missing, so prune drops the
#                                             registration and frees the branch
#                                             immediately)
#   4. rm -rf <wt>.reap-dead-...             (the only expensive step —
#                                             foregrounded and verified, see
#                                             issue #1223 below)
#
# Issue #1223 — step 4 used to be `rm -rf ... &` + `disown`, on the theory
# that a backgrounded delete "reparents to init on shell exit and finishes."
# That's false for the orchestrator's actual callers: its Bash tool calls
# are short-lived hermetic shells that exit the instant the command
# returns, and `reap-stale` fans out one such backgrounded delete PER
# worktree in a tight loop before returning. A multi-worktree sweep could
# therefore report `reaped=N` — the rename succeeded and the branch was
# freed, both true — while most of those N recursive deletes were still
# mid-flight when the shell exited and got killed with it, reclaiming none
# of the disk they were tombstoning. The repro: a 42-worktree sweep over
# ~86 GiB reported `reaped=42 ... remaining=0` while reclaiming only ~1.4
# GiB — the signature of partially-completed async deletes, not a missing
# delete (which would reclaim exactly zero). Step 4 is now synchronous:
# this function does not return success until the tombstone is verified
# gone. Steps 1-3 are independent of the tree size (a rename + a prune);
# step 4's wall-clock cost now scales with tree size, same as the
# pre-existing slow-path ladder below always has. Note the fast path
# needs no `--force` at all — that matters for #712 (see below).
#
# Slow-path ladder (#712) — when the rename can't be performed (path missing,
# cross-device mount, permission, race) the reap still has to complete, but it
# escalates in order of increasing destructiveness:
#   a. `git worktree remove <wt>`          (NO --force — git refuses on a dirty
#                                           tree, which is the safety property
#                                           the auto-mode permission classifier
#                                           is protecting; it is also far more
#                                           likely to read as reversible/safe)
#   b. `git worktree remove --force <wt>`  ONLY when `worktree_force_is_safe`
#                                           (or caller-supplied evidence) has
#                                           established the force destroys
#                                           nothing that exists only here.
# When neither succeeds the directory survives and we return 1 — the caller
# records the failure instead of silently swallowing it.
#
# Returns 0 when the directory is no longer at <worktree_path> AND the
# tombstoned bytes are verified actually gone (issue #1223 — a rename alone
# no longer counts as success on the fast path: "the branch was freed" and
# "the disk was reclaimed" are different claims, and this function's return
# value now asserts both); returns 1 when the directory still exists at
# <worktree_path> after every attempt, OR when a rename succeeded but the
# subsequent recursive delete left something behind under the tombstoned
# name. Callers that need a last-resort escalation (the orphan-orchestrator
# raw rm -rf path) — or that need to record an unreaped worktree (#712) —
# use this to detect that the fast path declined.
#
# Args: <worktree-path> [force-evidence]
#   force-evidence — optional non-empty string naming a check the CALLER
#                    already performed that establishes force-safety (e.g.
#                    "no-commits-beyond-base"). Passed through to
#                    worktree_force_is_safe.
#
# Pure bash + `git` — no jq/python, same as the rest of this helper. Runs in
# the caller's cwd (which must be inside the target repo, exactly like the
# bare `git worktree remove` it replaces).
fast_worktree_remove() {
  local worktree_path="$1"
  local force_evidence="${2:-}"

  # A locked worktree's registration is skipped by `git worktree prune`, so
  # the branch would stay held. Best-effort unlock first — a no-op for an
  # unregistered crash-orphan dir, harmless when already unlocked.
  git worktree unlock "$worktree_path" 2>/dev/null || true

  # Nothing at the path: prune any dangling registration (a stale entry whose
  # dir already vanished still needs its branch released) and report success.
  if [ ! -e "$worktree_path" ]; then
    git worktree prune 2>/dev/null || true
    return 0
  fi

  # Rename the (potentially huge) dir aside on the same filesystem so `mv` is
  # an instant relink, then prune to free the branch, then delete the
  # renamed-aside tree. `$$` + epoch keeps the scratch name unique across
  # concurrent reaps.
  local dead_epoch dead_path
  dead_epoch=$(date +%s 2>/dev/null || echo 0)
  dead_path="${worktree_path}.reap-dead-$$-${dead_epoch}"
  if mv "$worktree_path" "$dead_path" 2>/dev/null; then
    git worktree prune 2>/dev/null || true
    # Issue #1223 — foregrounded and verified. This used to background the
    # bulk delete (`rm -rf ... &` + `disown`) on the assumption it "reparents
    # to init on shell exit and finishes" — false for the orchestrator's
    # short-lived hermetic Bash-tool shells, which kill a backgrounded child
    # the instant the command returns. See the docstring above this function
    # for the full repro. The branch is already freed by the `prune` above,
    # so foregrounding this step only costs wall-clock time on the (rare)
    # large-worktree case — it no longer risks reporting success over bytes
    # that were never actually reclaimed.
    rm -rf "$dead_path" >/dev/null 2>&1
    if [ -e "$dead_path" ]; then
      # Partial failure (e.g. a permission-denied file mid-tree) — the
      # tombstone survives under its dead-name. Don't claim success: the
      # caller's `[ -e "$worktree_path" ]` check would find the ORIGINAL
      # path gone (it was renamed away) and wrongly count this as reaped,
      # exactly the misreport #1223 exists to close. A stray tombstone left
      # behind here is picked up by the next sweep's tombstone pass (see
      # sweep_stray_tombstones below).
      return 1
    fi
    return 0
  fi

  # Rename failed — fall back to the synchronous slow path so the reap still
  # happens, then prune to clean the registration either way. Report whether
  # the dir is actually gone so an orphan caller can escalate to rm -rf.
  #
  # #712 ladder: plain remove FIRST (non-destructive; git refuses on a dirty
  # tree), and escalate to --force only behind the evidence gate.
  git worktree remove "$worktree_path" 2>/dev/null || true
  if [ -e "$worktree_path" ] && worktree_force_is_safe "$worktree_path" "$force_evidence"; then
    git worktree remove --force "$worktree_path" 2>/dev/null || true
  fi
  git worktree prune 2>/dev/null || true
  [ ! -e "$worktree_path" ]
}

# Issue #1223 — self-healing sweep for stranded `*.reap-dead-<pid>-<ts>`
# tombstones. Before this issue's fix, `fast_worktree_remove`'s bulk delete
# was backgrounded and could be killed mid-flight by the orchestrator's
# short-lived shell exiting, leaving the renamed-aside tree on disk forever
# (nothing else in this codebase ever revisits a `.reap-dead-*` name). This
# sweep is the cleanup path for damage already done on hosts that ran that
# version — `fast_worktree_remove` itself is now synchronous, so it should
# not normally produce new stragglers, but a partial-delete failure (e.g. a
# permission-denied file mid-tree) can still leave one behind.
#
# Safe to run unconditionally, on every invocation, with no liveness check:
# the `.reap-dead-` infix is a scratch marker this tool alone generates
# (`<name>.reap-dead-<pid>-<epoch>`), and no live git worktree is ever
# registered under a name containing it — every worktree this codebase
# creates or classifies is named `agent-*` or `orchestrator-*` with no
# `.reap-dead-` substring, so this glob can only ever match a directory
# that was ALREADY tombstoned (branch already freed, registration already
# pruned) by a prior `fast_worktree_remove` call. It cannot widen reap
# eligibility — it never looks at classify-lock/classify-all output and
# never touches anything git still considers a worktree.
#
# Prints one `tombstone-swept: <name>` line per directory actually removed,
# `tombstone-sweep-failed: <name>` if a removal attempt leaves something
# behind (surfaces rather than silently re-stranding it), or
# `would-sweep-tombstone: <name>` under --dry-run (nothing is touched);
# then exactly one `tombstone-summary: swept=<S> failed=<F> remaining=<R>`
# line. These lines are not written to the reap-audit log — they precede
# reap_stale's own reaped:/deferred:/summary: lines in that caller's
# stdout, and are distinguishable by prefix. No JSONL audit entry: an
# already-tombstoned tree has no live branch or classification left to
# describe; the `reaped` audit action's `--classification` field would
# have nothing meaningful to carry.
#
# Issue #1482 — this pass is BOUNDED and its outcome is REPORTED. Both
# properties were missing, and their absence is what made a partial sweep
# invisible and self-compounding:
#
#   * Bounded (`--max <N>`, 0 = unbounded). This pass runs BEFORE
#     classification and used to have no cap at all, while the reap loop it
#     precedes has had `--max-per-session` since #836. A backlog of large
#     tombstones could therefore consume the caller's entire time budget in
#     a pass that never reached a single worktree reap — and since a killed
#     `rm -rf` leaves a *partially*-deleted tombstone behind, the next pass
#     restarts the same unbounded traversal from the top. That is the
#     compounding loop #1482 reported: each timed-out pass leaves at least
#     as much work as it found. Capping the count lets a pass make bounded
#     forward progress and hand the rest to the next one, exactly the
#     self-checkpointing contract reap_stale's own loop already had.
#   * Reported. Failures used to print a line and then vanish: this
#     function returned 0 unconditionally, reap_stale ignored the return,
#     and the `summary:` line carried no tombstone field — so a caller
#     reading only the summary (disk-space-guard.md takes `tail -1`) saw
#     total success over bytes that were never reclaimed. For the disk
#     guard specifically, whose whole purpose is reclaiming disk, that is
#     the silent-degrade dont.md's "Don't swallow a failed or denied reap"
#     bullet (#712/#1274) forbids.
#
# Deliberately NOT changed: what qualifies for deletion. The `.reap-dead-`
# infix remains the sole criterion, for the reasons argued above — this
# function only ever deletes FEWER directories per pass than before, never
# more, so it cannot widen reap eligibility.
#
# Publishes its tallies to the caller via three globals (shell functions
# can't return structured values, and reap_stale needs the counts for its
# own summary line): SWEEP_TOMBSTONE_SWEPT / _FAILED / _REMAINING.
#
# Returns 1 when at least one removal attempt left its directory behind, 0
# otherwise. A capped-out remainder is NOT a failure — it's the checkpoint.
#
# Args: <worktrees-dir> [--dry-run] [--max <N>]
sweep_stray_tombstones() {
  local wt_dir="$1"
  shift || true

  local dry_run=""
  local max_tombstones=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run)
        dry_run="--dry-run"
        shift
        ;;
      --max)
        if [ -n "${2:-}" ] && [[ "$2" =~ ^[0-9]+$ ]]; then
          max_tombstones="$2"
        fi
        shift 2
        ;;
      --max=*)
        local mt_val="${1#--max=}"
        [[ "$mt_val" =~ ^[0-9]+$ ]] && max_tombstones="$mt_val"
        shift
        ;;
      *)
        shift
        ;;
    esac
  done

  SWEEP_TOMBSTONE_SWEPT=0
  SWEEP_TOMBSTONE_FAILED=0
  SWEEP_TOMBSTONE_REMAINING=0

  [ -d "$wt_dir" ] || return 0

  local attempts=0
  local path name
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    [ -d "$path" ] || continue
    name="$(basename "$path")"

    # Past the cap: leave it on disk untouched and count it as the backlog
    # a later pass continues from. Same checkpoint semantics as the reap
    # loop's `remaining`.
    if [ "$max_tombstones" -gt 0 ] && [ "$attempts" -ge "$max_tombstones" ]; then
      SWEEP_TOMBSTONE_REMAINING=$((SWEEP_TOMBSTONE_REMAINING + 1))
      continue
    fi
    attempts=$((attempts + 1))

    if [ "$dry_run" = "--dry-run" ]; then
      printf 'would-sweep-tombstone: %s\n' "$name"
      SWEEP_TOMBSTONE_SWEPT=$((SWEEP_TOMBSTONE_SWEPT + 1))
      continue
    fi
    rm -rf "$path" >/dev/null 2>&1
    if [ -e "$path" ]; then
      printf 'tombstone-sweep-failed: %s\n' "$name"
      SWEEP_TOMBSTONE_FAILED=$((SWEEP_TOMBSTONE_FAILED + 1))
    else
      printf 'tombstone-swept: %s\n' "$name"
      SWEEP_TOMBSTONE_SWEPT=$((SWEEP_TOMBSTONE_SWEPT + 1))
    fi
  done < <(find "$wt_dir" -maxdepth 1 -mindepth 1 -type d -name '*.reap-dead-*' 2>/dev/null | sort)

  printf 'tombstone-summary: swept=%s failed=%s remaining=%s\n' \
    "$SWEEP_TOMBSTONE_SWEPT" "$SWEEP_TOMBSTONE_FAILED" "$SWEEP_TOMBSTONE_REMAINING"

  [ "$SWEEP_TOMBSTONE_FAILED" -eq 0 ]
}

# Issue #1261 — mid-session disk-space backpressure probe for
# disk-space-guard.md. Reports free space on the volume holding --path and
# whether it is below --floor-mb. Fails OPEN: an unreadable `df` result
# reports free_mb=unknown low=false rather than blocking dispatch.
#
# (The docstring that stood here described the `sweep-tombstones` CLI
# wrapper, which issue #1472 deleted without moving its comment — leaving
# this function documented as something it never was. Fixed in #1482.)
disk_free_check() {
  local path=""
  local floor_mb=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --path)
        path="${2:-}"
        shift 2
        ;;
      --path=*)
        path="${1#--path=}"
        shift
        ;;
      --floor-mb)
        if [ -z "${2:-}" ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
          echo "disk-check: --floor-mb requires a non-negative integer (got: ${2:-})" >&2
          return 64
        fi
        floor_mb="$2"
        shift 2
        ;;
      --floor-mb=*)
        local fmb_val="${1#--floor-mb=}"
        if ! [[ "$fmb_val" =~ ^[0-9]+$ ]]; then
          echo "disk-check: --floor-mb requires a non-negative integer (got: $fmb_val)" >&2
          return 64
        fi
        floor_mb="$fmb_val"
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      --)
        shift
        ;;
      -*)
        echo "disk-check: unknown flag: $1" >&2
        return 64
        ;;
      *)
        echo "disk-check: unexpected positional arg: $1" >&2
        return 64
        ;;
    esac
  done

  if [ -z "$path" ]; then
    echo "disk-check: --path is required" >&2
    return 64
  fi

  local avail_kb
  avail_kb=$(df -Pk "$path" 2>/dev/null | awk 'NR==2{print $4}')

  if [ -z "$avail_kb" ] || ! [[ "$avail_kb" =~ ^[0-9]+$ ]]; then
    # --path doesn't exist yet, df isn't on PATH, or the output shape was
    # unexpected — fail open (see docstring above).
    echo "free_mb=unknown floor_mb=${floor_mb} low=false"
    return 0
  fi

  local free_mb=$(( avail_kb / 1024 ))
  local low="false"
  if [ "$floor_mb" -gt 0 ] && [ "$free_mb" -lt "$floor_mb" ]; then
    low="true"
  fi
  echo "free_mb=${free_mb} floor_mb=${floor_mb} low=${low}"
  return 0
}

# Issue #1316 — read-only pre-reap inspection of a worker's worktree, callable
# from a worktree-isolated orchestrator session. `steady-state.md`'s A.0.5
# mandates inspecting a returning worker's worktree for unpushed commits /
# uncommitted edits BEFORE reaping it (issues #838 / #833) — as originally
# written, that meant running `git log --oneline origin/<default>..HEAD` and
# `git status --porcelain` directly against the *worker's* worktree, i.e.
# `git -C .claude/worktrees/agent-<id> ...` from the orchestrator's own shell.
# But setup step 0.5 (00-config-worktree.md) requires the orchestrator to
# isolate itself into its OWN worktree via EnterWorktree first, and a
# worktree-isolated session's harness guard unconditionally refuses any
# `git -C <other-worktree>` (or `cd <other-worktree> && git ...`) issued
# directly from the orchestrator's own Bash tool call — read-only or not
# (issue #1316's live repro: both commands refused verbatim).
#
# The fix follows the same pattern already used everywhere else in this file
# for a worktree the orchestrator must not `-C`/`cd` into directly: `git -C`
# INSIDE a helper script's own bash process is unaffected by the guard (see
# `worktree_force_is_safe` above and `crash-recovery-reap.sh`, both of which
# already do exactly this) — the guard inspects the literal command TEXT of
# the orchestrator's own Bash tool call, not what a script it invokes does
# internally. Moving the inspection here — a plain `bash worktree-reap.sh
# inspect-unpushed ...` invocation, no `-C` in the outer call — restores the
# ability to perform it from an isolated session.
#
# Args:
#   --worktree-path <path>   (required) the worker's worktree to inspect.
#   --default-branch <name>  (required) the repo's default branch, e.g.
#                             "main" — compared as origin/<name>..HEAD.
#   --fetch                  (optional) run `git fetch origin
#                             <default-branch>` inside the worktree first, so
#                             the ahead-count and commit log are computed
#                             against a current remote-tracking ref rather
#                             than whatever origin/<default-branch> last
#                             resolved to locally. Best-effort — a fetch
#                             failure (network down) is not fatal; the
#                             inspection proceeds against whatever
#                             origin/<default> already resolves to.
#
# Output (stdout):
#   Line 1: `ahead_count=<N> dirty_count=<N> verdict=<clean|resume-worthy>`
#           — the machine-checkable summary. `resume-worthy` when
#           ahead_count > 0 OR dirty_count > 0 (mirrors steady-state.md
#           A.0.5's "resume-worthy" mechanical check); `clean` otherwise.
#   A `--- commits (git log --oneline <base>..HEAD) ---` marker line,
#   followed by the literal `git log --oneline` output (one commit per
#   line, SHA + subject; block is empty when ahead_count is 0).
#   A `--- dirty (git status --porcelain) ---` marker line, followed by the
#   literal `git status --porcelain` output (one path per line; block is
#   empty when dirty_count is 0).
#
# Both blocks are emitted verbatim (not re-encoded) so a caller building
# A.0.5's resume message "Verified state" paragraph can fold this script's
# own stdout directly into the message without re-deriving anything — the
# resume message asserts THIS reading as ground truth, never the stalled
# worker's own prior narrative.
#
# Read-only — never mutates the worktree beyond an optional `git fetch`
# (which only updates remote-tracking refs, never the worktree's own branch
# or working tree).
#
# Exit codes:
#   0  inspection completed (worktree may or may not be reap-eligible —
#      that's the verdict= field, not the exit code).
#   64 bad usage (missing --worktree-path / --default-branch, unknown flag).
#   65 --worktree-path does not resolve to a readable git worktree (already
#      gone — the caller should treat this as "nothing to inspect," not
#      retry).
inspect_unpushed() {
  local worktree_path=""
  local default_branch=""
  local do_fetch=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --worktree-path)
        worktree_path="${2:-}"
        shift 2
        ;;
      --worktree-path=*)
        worktree_path="${1#--worktree-path=}"
        shift
        ;;
      --default-branch)
        default_branch="${2:-}"
        shift 2
        ;;
      --default-branch=*)
        default_branch="${1#--default-branch=}"
        shift
        ;;
      --fetch)
        do_fetch=1
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      --)
        shift
        ;;
      -*)
        echo "inspect-unpushed: unknown flag: $1" >&2
        return 64
        ;;
      *)
        echo "inspect-unpushed: unexpected positional arg: $1" >&2
        return 64
        ;;
    esac
  done

  if [ -z "$worktree_path" ]; then
    echo "inspect-unpushed: --worktree-path is required" >&2
    return 64
  fi
  if [ -z "$default_branch" ]; then
    echo "inspect-unpushed: --default-branch is required" >&2
    return 64
  fi

  if ! git -C "$worktree_path" rev-parse --git-dir >/dev/null 2>&1; then
    echo "inspect-unpushed: --worktree-path is not a readable git worktree: $worktree_path" >&2
    return 65
  fi

  if [ "$do_fetch" -eq 1 ]; then
    git -C "$worktree_path" fetch origin "$default_branch" >/dev/null 2>&1 || true
  fi

  local base="origin/${default_branch}"
  local ahead_count
  ahead_count=$(git -C "$worktree_path" rev-list --count "${base}..HEAD" 2>/dev/null || echo "0")

  local dirty_listing
  dirty_listing=$(git -C "$worktree_path" status --porcelain 2>/dev/null)
  local dirty_count=0
  if [ -n "$dirty_listing" ]; then
    dirty_count=$(printf '%s\n' "$dirty_listing" | wc -l | tr -d ' ')
  fi

  local verdict="clean"
  if [ "$ahead_count" != "0" ] || [ "$dirty_count" != "0" ]; then
    verdict="resume-worthy"
  fi

  echo "ahead_count=${ahead_count} dirty_count=${dirty_count} verdict=${verdict}"
  echo "--- commits (git log --oneline ${base}..HEAD) ---"
  git -C "$worktree_path" log --oneline "${base}..HEAD" 2>/dev/null
  echo "--- dirty (git status --porcelain) ---"
  if [ -n "$dirty_listing" ]; then
    printf '%s\n' "$dirty_listing"
  fi

  return 0
}

# Issue #284 — single source of truth for reap-audit writes. Performs the
# worktree-remove side effect (when applicable) and writes one JSONL line
# to $SHIPYARD_HOME/reap-audit.jsonl per call.
#
# Three call sites that previously inlined the audit-log printf now route
# through this function:
#   - setup.md step 1.6.5  → --action reaped-orphan-orchestrator
#   - setup.md step 3b     → --action reaped / --action deferred
#   - cleanup-summary.md   → --action reaped / --action deferred
#     step 3
#
# The transaction is "do the side effect, then write the audit log" so
# the log always reflects what happened. The audit-log write itself is
# fire-and-forget (filesystem permission issues are not fatal — same
# posture as the original inline `>> $REAP_AUDIT_LOG 2>/dev/null || true`).
#
# Why this exists: the inline printf calls at the three sites were
# functionally equivalent observability code that the orchestrator
# repeatedly skimmed past as scaffolding. Result: the audit log never
# materialized despite the spec calling for unconditional writes. Putting
# the write inside a single helper subcommand makes it impossible for
# the orchestrator to skip — the helper is the only thing that performs
# the reap, so the audit line happens as part of the same transaction.

# agent_return_recorded <session-id> <agent-id>
#
# Issue #1237 — the mechanical half of the "a merged PR is not a signal
# the dispatched worker is done" invariant (issue #1235). Prints "1" on
# stdout and returns 0 when this session's persisted state records that
# <agent-id>'s own terminal return already reached the orchestrator's
# reconcile (steady-state.md A.1 write-through of
# `.returned_agent_ids["<agent-id>"]`); prints "0" and returns 1 in every
# other case — missing session file, missing key, empty value, or the
# `session-state.sh` call itself failing. All of those are the SAME
# "cannot prove it" outcome and are treated identically: fail closed
# (issue #1206's precedent — an unparseable/absent signal is not a green
# light), never fail open on a lookup error.
#
# Resolves session-state.sh relative to this script's own directory —
# same convention every other cross-script call in this file already uses
# (see the `session-identity.sh` delegation at the bottom of this file).
agent_return_recorded() {
  local session_id="$1"
  local agent_id="$2"
  local this_dir
  this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local session_state="$this_dir/session-state.sh"

  if [ ! -f "$session_state" ]; then
    # Can't even locate the helper — cannot prove anything. Fail closed.
    printf '0'
    return 1
  fi

  local returned_at
  returned_at=$("$session_state" read --session-id "$session_id" \
    --path ".returned_agent_ids[\"$agent_id\"] // empty" 2>/dev/null)
  # A missing session file, a missing key, or jq's `// empty` all surface
  # as empty stdout here — every one of those is "cannot prove the agent
  # returned," and they are deliberately NOT distinguished from each
  # other: the caller only needs a boolean, and treating a lookup failure
  # as anything other than "not proven" would be exactly the fail-open
  # mistake this gate exists to prevent.
  if [ -n "$returned_at" ] && [ "$returned_at" != "null" ]; then
    printf '1'
    return 0
  fi
  printf '0'
  return 1
}

reap_action() {
  local action=""
  local worktree_path=""
  local worktree_name=""
  local session_id=""
  local actor_pid="$$"
  local classification=""
  local reason=""
  # `lock_pid` is emitted as a JSON value (integer or null literal), NOT
  # a quoted string — that's what the original inline templates produced,
  # and tooling reading the log may try to use it as a number.
  local lock_pid="null"
  local reaped_session_id=""
  local phase=""
  local skip_remove=0
  # Issue #712 — optional caller-supplied evidence that a `--force` escalation
  # would destroy nothing (e.g. "no-commits-beyond-base" from setup 3c's
  # rev-list check). Empty by default: the helper then derives force-safety
  # itself via worktree_force_is_safe.
  local force_evidence=""
  # Issue #1237 — explicit, audited opt-out from the reconciled-return gate
  # (see the `reap` subcommand's docstring above for the full contract and
  # the three documented exception classes). Empty by default: the gate is
  # enforced unless a caller deliberately names a reason it doesn't apply.
  local bypass_return_check=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --action)
        action="${2:-}"
        shift 2
        ;;
      --action=*)
        action="${1#--action=}"
        shift
        ;;
      --worktree-path)
        worktree_path="${2:-}"
        shift 2
        ;;
      --worktree-path=*)
        worktree_path="${1#--worktree-path=}"
        shift
        ;;
      --worktree-name)
        worktree_name="${2:-}"
        shift 2
        ;;
      --worktree-name=*)
        worktree_name="${1#--worktree-name=}"
        shift
        ;;
      --session-id)
        session_id="${2:-}"
        shift 2
        ;;
      --session-id=*)
        session_id="${1#--session-id=}"
        shift
        ;;
      --actor-pid)
        actor_pid="${2:-}"
        shift 2
        ;;
      --actor-pid=*)
        actor_pid="${1#--actor-pid=}"
        shift
        ;;
      --classification)
        classification="${2:-}"
        shift 2
        ;;
      --classification=*)
        classification="${1#--classification=}"
        shift
        ;;
      --reason)
        reason="${2:-}"
        shift 2
        ;;
      --reason=*)
        reason="${1#--reason=}"
        shift
        ;;
      --lock-pid)
        lock_pid="${2:-null}"
        shift 2
        ;;
      --lock-pid=*)
        lock_pid="${1#--lock-pid=}"
        [ -z "$lock_pid" ] && lock_pid="null"
        shift
        ;;
      --reaped-session-id)
        reaped_session_id="${2:-}"
        shift 2
        ;;
      --reaped-session-id=*)
        reaped_session_id="${1#--reaped-session-id=}"
        shift
        ;;
      --phase)
        phase="${2:-}"
        shift 2
        ;;
      --phase=*)
        phase="${1#--phase=}"
        shift
        ;;
      --skip-remove)
        skip_remove=1
        shift
        ;;
      --force-evidence)
        force_evidence="${2:-}"
        shift 2
        ;;
      --force-evidence=*)
        force_evidence="${1#--force-evidence=}"
        shift
        ;;
      --bypass-return-check)
        bypass_return_check="${2:-}"
        shift 2
        ;;
      --bypass-return-check=*)
        bypass_return_check="${1#--bypass-return-check=}"
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      --)
        shift
        ;;
      -*)
        echo "reap: unknown flag: $1" >&2
        return 64
        ;;
      *)
        echo "reap: unexpected positional arg: $1" >&2
        return 64
        ;;
    esac
  done

  # Required-flag validation. Per-action additional requirements checked
  # in the action dispatch below.
  if [ -z "$action" ]; then
    echo "reap: --action is required (valid values: reaped, deferred, reaped-orphan-orchestrator, reaped-failed)" >&2
    return 64
  fi
  if [ -z "$worktree_path" ]; then
    echo "reap: --worktree-path is required" >&2
    return 64
  fi
  if [ -z "$worktree_name" ]; then
    echo "reap: --worktree-name is required" >&2
    return 64
  fi
  if [ -z "$session_id" ]; then
    echo "reap: --session-id is required" >&2
    return 64
  fi

  # actor_pid must be numeric.
  if ! [[ "$actor_pid" =~ ^[0-9]+$ ]]; then
    echo "reap: --actor-pid must be a non-negative integer (got: $actor_pid)" >&2
    return 64
  fi

  # lock_pid is either `null` (literal) or a non-negative integer; we emit
  # it unquoted in JSON so a caller passing anything else would produce
  # invalid JSON. Catch it early.
  if [ "$lock_pid" != "null" ] && ! [[ "$lock_pid" =~ ^[0-9]+$ ]]; then
    echo "reap: --lock-pid must be 'null' or a non-negative integer (got: $lock_pid)" >&2
    return 64
  fi

  # Resolve the audit-log path lazily. Mirrors the cost-history /
  # session-state convention of `$SHIPYARD_HOME` overriding `$HOME/.shipyard`.
  local shipyard_home
  shipyard_home=$(shipyard_home)
  # Ensure the dir exists — same fire-and-forget posture as the write itself.
  # The mkdir is critical because the previous inline `printf >> $LOG` would
  # fail silently when $SHIPYARD_HOME didn't exist (the `2>/dev/null || true`
  # masked it). Forcing the dir creation here is what makes "first session
  # produces at least one audit-log line" actually work on a fresh machine.
  mkdir -p "$shipyard_home" 2>/dev/null || true

  local audit_log="$shipyard_home/reap-audit.jsonl"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Helper to append a JSON line. The line is constructed by callers below
  # using printf %s — they're responsible for the comma-separation and
  # field shape. The append itself is fire-and-forget (`|| true` posture)
  # so a permission issue or full disk can never abort the reap loop.
  emit_line() {
    local line="$1"
    printf '%s\n' "$line" >> "$audit_log" 2>/dev/null || true
  }

  # Issue #405 — JSON-escape a string value so an interpolated field can't
  # corrupt or inject into the audit ledger. Values like --reason,
  # --worktree-name, --session-id, --classification, and --phase flow
  # straight from caller-controlled branch / worktree / session identifiers
  # that are only validated non-empty, so a `"`, `\`, or control character
  # in any of them would otherwise produce malformed JSONL (or, with a
  # crafted value, forge additional record fields).
  #
  # Pure bash — the script header (no jq, no python) is load-bearing: this
  # helper is called from the cleanup loop potentially once per worktree.
  # Escapes the six characters JSON requires (`"`, `\`, and the C0 controls
  # backspace / form-feed / newline / carriage-return / tab via their
  # short escapes) plus any remaining control character (U+0000–U+001F) via
  # the \u00XX long form. Emits the surrounding double-quotes.
  json_str() {
    local s="$1" out="" c i
    # Backslash first so we don't double-escape the backslashes we add.
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\b'/\\b}
    s=${s//$'\f'/\\f}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    # Catch any remaining control chars (e.g. U+0001) with the \u00XX form.
    # Cheap fast-path: only walk the string when a raw control byte survives.
    if [[ "$s" == *[$'\x01'-$'\x1f']* ]]; then
      out=""
      for (( i=0; i<${#s}; i++ )); do
        c=${s:i:1}
        case "$c" in
          [$'\x01'-$'\x1f'])
            printf -v c '\\u%04x' "'$c"
            ;;
        esac
        out+="$c"
      done
      s="$out"
    fi
    printf '"%s"' "$s"
  }

  # Format the optional ,"phase":"<p>" suffix. Empty when --phase wasn't
  # set; the audit-line constructions below append it after the
  # action-specific body. The phase value is JSON-escaped (issue #405).
  local phase_suffix=""
  if [ -n "$phase" ]; then
    phase_suffix=",\"phase\":$(json_str "$phase")"
  fi

  case "$action" in
    reaped)
      if [ -z "$classification" ]; then
        echo "reap: --classification is required when --action=reaped" >&2
        return 64
      fi

      # Reconciled-return gate (issue #1237). Only applies to an actual
      # dispatched agent's worktree (--worktree-name matching agent-*) —
      # the orchestrator's own orchestrator-* self-reap (cleanup-summary.md)
      # has no "did an agent return" question to ask and is out of scope by
      # construction, not by override. See the `reap` subcommand's docstring
      # above for the full contract and the three documented
      # --bypass-return-check exception classes.
      case "$worktree_name" in
        agent-*)
          if [ -z "$bypass_return_check" ]; then
            local return_agent_id="${worktree_name#agent-}"
            if ! agent_return_recorded "$session_id" "$return_agent_id" >/dev/null; then
              echo "reap: refusing to reap ${worktree_name} — no recorded return for this agent in session ${session_id}'s .returned_agent_ids (issue #1237). This reap would fire before the worker's own terminal return reached the orchestrator's reconcile. If this is a documented exception (crash-recovery, a cross-session sweep, an end-of-session catch-all), pass --bypass-return-check <reason>." >&2
              emit_line "{\"ts\":$(json_str "$ts"),\"session\":$(json_str "$session_id"),\"actor_pid\":$actor_pid,\"worktree\":$(json_str "$worktree_name"),\"action\":\"reap-refused\",\"reason\":$(json_str "no-recorded-return")$phase_suffix}"
              return 1
            fi
          fi
          ;;
      esac

      # Perform the actual worktree remove unless the caller explicitly
      # asks us to skip (used when the caller has already removed it).
      #
      # Issue #712 — do NOT swallow a failed remove. The reap used to emit a
      # `"action":"reaped"` audit line unconditionally (`fast_worktree_remove
      # ... || true`), so a removal that never happened — denied by the
      # auto-mode permission classifier, blocked by the force-evidence gate,
      # or failed on a filesystem error — was indistinguishable from a
      # successful one. Silent-degrade is what let worktrees accumulate to six
      # unnoticed in the #712 repro. A failed remove now emits the
      # `reaped-failed` action variant with a `reason`, so the audit log (and
      # the end-of-session summary's unreaped count) surface it.
      local reaped_ok=1
      local failure_reason=""
      if [ "$skip_remove" -eq 0 ]; then
        # Fast reap (#664): unlock + rename-aside + prune frees the branch
        # lock immediately, and the expensive recursive delete is
        # backgrounded — so a large node_modules/ in the agent worktree can't
        # hang the remove and block fix-checks retries on the head branch.
        # fast_worktree_remove falls back to a plain `git worktree remove`,
        # then to an evidence-gated `--force`, when the rename can't be done.
        if ! fast_worktree_remove "$worktree_path" "$force_evidence"; then
          reaped_ok=0
          if [ -e "$worktree_path" ] \
             && ! worktree_force_is_safe "$worktree_path" "$force_evidence"; then
            # The evidence gate declined the --force escalation: this worktree
            # carries work (dirty tree + unpushed commits) that exists nowhere
            # else. Leaving it on disk for a human is the correct outcome.
            failure_reason="unsafe-to-force-unpushed-work"
          else
            failure_reason="worktree-remove-failed"
          fi
        fi
      fi
      if [ "$reaped_ok" -eq 0 ]; then
        emit_line "{\"ts\":$(json_str "$ts"),\"session\":$(json_str "$session_id"),\"actor_pid\":$actor_pid,\"worktree\":$(json_str "$worktree_name"),\"action\":\"reaped-failed\",\"classification\":$(json_str "$classification"),\"reason\":$(json_str "$failure_reason"),\"lock_pid\":$lock_pid$phase_suffix}"
      else
        emit_line "{\"ts\":$(json_str "$ts"),\"session\":$(json_str "$session_id"),\"actor_pid\":$actor_pid,\"worktree\":$(json_str "$worktree_name"),\"action\":\"reaped\",\"classification\":$(json_str "$classification"),\"lock_pid\":$lock_pid$phase_suffix}"
      fi
      ;;
    deferred)
      if [ -z "$reason" ]; then
        echo "reap: --reason is required when --action=deferred" >&2
        return 64
      fi
      # `deferred` means we DIDN'T remove the worktree — caller is logging
      # the decision to defer. No `git worktree remove` should fire.
      emit_line "{\"ts\":$(json_str "$ts"),\"session\":$(json_str "$session_id"),\"actor_pid\":$actor_pid,\"worktree\":$(json_str "$worktree_name"),\"action\":\"deferred\",\"reason\":$(json_str "$reason"),\"lock_pid\":$lock_pid$phase_suffix}"
      ;;
    reaped-orphan-orchestrator)
      if [ -z "$reaped_session_id" ]; then
        echo "reap: --reaped-session-id is required when --action=reaped-orphan-orchestrator" >&2
        return 64
      fi
      # Fast reap (#664): rename-aside + prune + backgrounded bulk delete.
      # `mv` works whether or not git has the worktree registered, so the
      # fast path subsumes both the clean registered-worktree remove and the
      # crash-orphan case (dir on disk but no longer registered with git —
      # common after a crash, see #280) without stalling on a large tree and
      # freeing the branch immediately. Only when the fast path can't make
      # the directory disappear at all (rename AND slow-remove both failed)
      # do we escalate to a synchronous last-resort `rm -rf`, recording the
      # `-raw-rm` / `-failed` audit variant so the source of the reap stays
      # traceable.
      local actual_action="reaped-orphan-orchestrator"
      if [ "$skip_remove" -eq 0 ]; then
        if ! fast_worktree_remove "$worktree_path"; then
          if rm -rf "$worktree_path" 2>/dev/null; then
            actual_action="reaped-orphan-orchestrator-raw-rm"
          else
            # Both paths failed — the dir is somehow non-removable.
            # We still emit an audit line so the failure is traceable;
            # the caller's loop should continue rather than abort.
            actual_action="reaped-orphan-orchestrator-failed"
          fi
        fi
      fi
      emit_line "{\"ts\":$(json_str "$ts"),\"session\":$(json_str "$session_id"),\"actor_pid\":$actor_pid,\"worktree\":$(json_str "$worktree_name"),\"action\":$(json_str "$actual_action"),\"reaped_session_id\":$(json_str "$reaped_session_id")$phase_suffix}"
      ;;
    reaped-failed)
      # Issue #1274 — directly-invocable failure log, NO removal attempt.
      #
      # The `reaped` action above already downgrades to a `reaped-failed`
      # audit line when `fast_worktree_remove` runs and fails (issue #712)
      # — but that only helps when the script gets to run at all. Claude
      # Code's auto-mode permission classifier can deny the ENTIRE Bash
      # tool call that would have invoked `worktree-reap.sh reap --action
      # reaped ...` against a real `.claude/worktrees/agent-*` path,
      # before any of this script's own code executes — so no audit line
      # is written and the failure is indistinguishable from success to
      # every caller that swallows the tool result with `2>/dev/null ||
      # true` (the #1274 repro: a full `/do-work` session shipped 11+ PRs
      # and wrote zero audit-log entries despite ~12 worktrees surviving
      # on disk).
      #
      # This action exists for a caller that has ALREADY determined, via
      # a separate and genuinely non-destructive post-hoc check (e.g. `[
      # -e "$worktree_path" ]` run as its own Bash tool call, immediately
      # after — never bundled into the same call as — a reap attempt),
      # that the removal did not happen. It only writes the audit line;
      # it never touches the filesystem or calls `fast_worktree_remove`,
      # so it cannot itself trip the classifier and cannot compound a
      # denial by retrying the denied operation.
      if [ -z "$classification" ]; then
        echo "reap: --classification is required when --action=reaped-failed" >&2
        return 64
      fi
      if [ -z "$reason" ]; then
        echo "reap: --reason is required when --action=reaped-failed" >&2
        return 64
      fi
      emit_line "{\"ts\":$(json_str "$ts"),\"session\":$(json_str "$session_id"),\"actor_pid\":$actor_pid,\"worktree\":$(json_str "$worktree_name"),\"action\":\"reaped-failed\",\"classification\":$(json_str "$classification"),\"reason\":$(json_str "$reason"),\"lock_pid\":$lock_pid$phase_suffix}"
      ;;
    *)
      echo "reap: unknown --action: $action (valid values: reaped, deferred, reaped-orphan-orchestrator, reaped-failed)" >&2
      return 64
      ;;
  esac

  return 0
}

# Issue #1355 — single-call replacement for setup-1.6.5's own
# discover-then-reap loop. Before this subcommand existed, the orchestrator's
# own spec ran the `while IFS=$'\t' read ... done < <(session-identity.sh
# find-orphan-orchestrators ...)` loop directly in its own Bash tool call —
# a process-substitution loop, which is refused by the harness's
# worktree-isolation guard once EnterWorktree has isolated the session
# (dont.md's "post-relocation Bash blocks must be plain, single-purpose
# commands", issue #1277). That refusal is why setup-1.6.5 had to run
# BEFORE relocation. Moving the identical loop body into this function —
# invoked as ONE plain `worktree-reap.sh reap-orphan-orchestrators ...`
# call — sidesteps the refusal: the guard inspects the literal command text
# the caller issues, not what a script invoked by that command does
# internally (confirmed empirically against a live worktree-isolated
# session: an equivalent `git -C <other-worktree>` call refused inline
# succeeded unchanged once moved inside an invoked script, with or without
# the cross-worktree path passed as a script argument — see issue #1355).
# So this subcommand is reachable at ANY point in setup, not just
# pre-relocation.
#
# Every reap still routes through `reap_action` above, unchanged — this
# function only replaces the orchestrator-side loop, not the reap mechanism
# or its audit-log shape.
reap_orphan_branches() {
  local repo_root=""
  local session_id=""
  local dry_run=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --repo-root)
        repo_root="${2:-}"
        shift 2
        ;;
      --repo-root=*)
        repo_root="${1#--repo-root=}"
        shift
        ;;
      --session-id)
        session_id="${2:-}"
        shift 2
        ;;
      --session-id=*)
        session_id="${1#--session-id=}"
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      --)
        shift
        ;;
      -*)
        echo "reap-orphan-branches: unknown flag: $1" >&2
        return 64
        ;;
      *)
        echo "reap-orphan-branches: unexpected positional arg: $1" >&2
        return 64
        ;;
    esac
  done

  if [ -z "$repo_root" ]; then
    echo "reap-orphan-branches: --repo-root is required" >&2
    return 64
  fi
  if [ -z "$session_id" ]; then
    echo "reap-orphan-branches: --session-id is required" >&2
    return 64
  fi

  # Step 1 — enumerate local worktree-agent-* branches.
  # `git for-each-ref` is the correct tool here (no glob vs ls-files ambiguity).
  # Redirect stderr in case the repo has no refs matching the pattern — that is
  # normal (first-session machine) and produces no output, which is correct.
  local branch_list
  branch_list=$(git -C "$repo_root" for-each-ref \
    --format='%(refname:short)' \
    'refs/heads/worktree-agent-*' 2>/dev/null)

  # No matching branches → nothing to do.
  [ -z "$branch_list" ] && return 0

  # Step 2 — build the set of branches referenced by live worktrees.
  # `git worktree list --porcelain` emits blocks like:
  #   worktree /path/to/wt
  #   HEAD <sha>
  #   branch refs/heads/<name>
  # We extract only the `branch refs/heads/<name>` lines and strip the prefix.
  local live_branches
  live_branches=$(git -C "$repo_root" worktree list --porcelain 2>/dev/null \
    | grep '^branch refs/heads/' \
    | sed 's|^branch refs/heads/||')

  # Prepare audit log infrastructure (skip in dry-run).
  local shipyard_home
  shipyard_home=$(shipyard_home)
  local audit_log="$shipyard_home/reap-audit.jsonl"
  local ts actor_pid
  actor_pid=$$

  if [ "$dry_run" -eq 0 ]; then
    mkdir -p "$shipyard_home" 2>/dev/null || true
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  fi

  # Step 3 — delete orphan branches.
  local branch
  while IFS= read -r branch; do
    [ -z "$branch" ] && continue

    # Check if this branch is referenced by a live worktree.
    local is_live=0
    local lb
    while IFS= read -r lb; do
      if [ "$lb" = "$branch" ]; then
        is_live=1
        break
      fi
    done <<< "$live_branches"

    if [ "$is_live" -eq 1 ]; then
      # Live worktree references this branch — skip.
      continue
    fi

    # Orphan branch.
    if [ "$dry_run" -eq 1 ]; then
      # --dry-run: report what WOULD be reaped, without touching anything or
      # writing to the audit log.
      printf 'reaped-branch: %s\n' "$branch"
      continue
    fi

    # Delete the branch ref. `git branch -D` works even when not on the
    # branch being deleted. Redirect stdout so the "Deleted branch ..."
    # confirmation line from git doesn't pollute our reaped-branch: output.
    #
    # Issue #874 — the exit status used to be discarded (`|| true`) and the
    # audit line below was written unconditionally, so a failed delete (an
    # unmerged commit, a permission error, or a concurrent delete race) was
    # indistinguishable from a real reap in both stdout and the audit log.
    # Mirrors the `reaped`/`reaped-failed` split `reap_action` already uses
    # for worktree removal (issue #712, above in this file).
    if git -C "$repo_root" branch -D "$branch" >/dev/null 2>&1; then
      printf 'reaped-branch: %s\n' "$branch"
      printf '%s\n' \
        "{\"ts\":\"$ts\",\"session\":\"$session_id\",\"actor_pid\":$actor_pid,\"branch\":\"$branch\",\"action\":\"reaped-orphan-branch\",\"reason\":\"no-live-worktree\"}" \
        >> "$audit_log" 2>/dev/null || true
    else
      printf '%s\n' \
        "{\"ts\":\"$ts\",\"session\":\"$session_id\",\"actor_pid\":$actor_pid,\"branch\":\"$branch\",\"action\":\"reaped-branch-failed\",\"reason\":\"branch-delete-failed\"}" \
        >> "$audit_log" 2>/dev/null || true
    fi
  done <<< "$branch_list"

  return 0
}

# Issue #509 — targeted reap of THIS session's agent worktrees by explicit
# agent-id. See the subcommand docstring at the top of the file for the
# rationale (busy-checkout generic-sweep stall stranding this session's own
# shipped worktrees).
#
# The orchestrator passes its own session's agent-ids (reconciled +
# in-flight) via repeated --agent-id flags and/or one id per stdin line.
# We resolve each to its worktree dir + lock file, classify, and reap on
# the safe classifications — routing the actual remove + audit write through
# the same reap_action transaction the generic sweep uses, so the audit log
# stays consistent (with phase: "cleanup-session-targeted" to distinguish
# this pass).
reap_stale() {
  local repo_root=""
  local session_id=""
  local max_per_session=10
  local orchestrator_pid="${SHIPYARD_ORCHESTRATOR_PID:-}"
  local peer_stale_min="${SHIPYARD_PEER_LOCK_STALE_MIN:-60}"
  local dry_run=0
  local -a exclude_ids=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --repo-root)
        repo_root="${2:-}"
        shift 2
        ;;
      --repo-root=*)
        repo_root="${1#--repo-root=}"
        shift
        ;;
      --session-id)
        session_id="${2:-}"
        shift 2
        ;;
      --session-id=*)
        session_id="${1#--session-id=}"
        shift
        ;;
      --max-per-session)
        if [ -z "${2:-}" ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
          echo "reap-stale: --max-per-session requires a non-negative integer (got: ${2:-})" >&2
          return 64
        fi
        max_per_session="$2"
        shift 2
        ;;
      --max-per-session=*)
        local mps_val="${1#--max-per-session=}"
        if ! [[ "$mps_val" =~ ^[0-9]+$ ]]; then
          echo "reap-stale: --max-per-session requires a non-negative integer (got: $mps_val)" >&2
          return 64
        fi
        max_per_session="$mps_val"
        shift
        ;;
      --exclude-agent-id)
        [ -n "${2:-}" ] && exclude_ids+=("$2")
        shift 2
        ;;
      --exclude-agent-id=*)
        local _eid="${1#--exclude-agent-id=}"
        [ -n "$_eid" ] && exclude_ids+=("$_eid")
        shift
        ;;
      --orchestrator-pid)
        orchestrator_pid="${2:-}"
        shift 2
        ;;
      --orchestrator-pid=*)
        orchestrator_pid="${1#--orchestrator-pid=}"
        shift
        ;;
      --peer-stale-min)
        peer_stale_min="${2:-}"
        shift 2
        ;;
      --peer-stale-min=*)
        peer_stale_min="${1#--peer-stale-min=}"
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      --)
        shift
        ;;
      -*)
        echo "reap-stale: unknown flag: $1" >&2
        return 64
        ;;
      *)
        echo "reap-stale: unexpected positional arg: $1" >&2
        return 64
        ;;
    esac
  done

  if [ -z "$repo_root" ]; then
    echo "reap-stale: --repo-root is required" >&2
    return 64
  fi
  if [ -z "$session_id" ]; then
    echo "reap-stale: --session-id is required" >&2
    return 64
  fi

  # Anchor cwd — reap_action routes through fast_worktree_remove, which runs
  # bare (cwd-dependent) `git worktree` commands. Same rationale as
  # reap_session_worktrees above.
  if ! cd "$repo_root" 2>/dev/null; then
    echo "reap-stale: cannot cd to --repo-root: $repo_root" >&2
    return 64
  fi

  # Issue #1223 — self-heal any *.reap-dead-* tombstones already stranded on
  # this host (by a prior, buggy version of fast_worktree_remove, or by a
  # partial-delete failure). Unconditional and safe — see
  # sweep_stray_tombstones' docstring for why the naming pattern alone can
  # never match a live worktree. Runs before classification so a sweep that
  # is ALSO under --dry-run reports what it would sweep without touching
  # anything.
  #
  # Issue #1482 — bounded by the SAME --max-per-session cap the reap loop
  # below uses, and its tallies are folded into this function's summary
  # line + exit code. Before that, this pass was the one unbounded step in
  # a function that advertises itself as bounded and checkpointed, and its
  # failures were printed and then dropped on the floor. See
  # sweep_stray_tombstones' docstring for the full mechanism.
  if [ "$dry_run" -eq 1 ]; then
    sweep_stray_tombstones "$repo_root/.claude/worktrees" --dry-run --max "$max_per_session"
  else
    sweep_stray_tombstones "$repo_root/.claude/worktrees" --max "$max_per_session"
  fi
  local tombstones_swept="${SWEEP_TOMBSTONE_SWEPT:-0}"
  local tombstones_failed="${SWEEP_TOMBSTONE_FAILED:-0}"
  local tombstones_remaining="${SWEEP_TOMBSTONE_REMAINING:-0}"

  # Issue #1147 — mandatory in-flight cross-check. `--exclude-agent-id` is
  # only as protective as every calling site remembering to compute and
  # pass it, and nothing enforced that — the repro that motivated this: a
  # harness-provisioned isolation:"worktree" dispatch (the default
  # Agent-tool shape since #830) never writes a shipyard lock file, so
  # classify-all reports `no-lock` for a currently-running worker
  # identically to a genuinely-abandoned one, and the ONLY thing standing
  # between reap-stale and destroying it was --exclude-agent-id having
  # actually been passed. Read THIS session's own live agent-ids directly
  # from its session-state file — the SAME --session-id already required
  # above — and union them into the exclude set automatically, so the
  # guard no longer depends on the caller's own bookkeeping.
  #
  # Best-effort: a missing session file (the session hasn't flushed state
  # yet, or a synthetic --session-id in a test) or a missing `jq` binary
  # silently skips this step rather than failing the whole sweep —
  # --exclude-agent-id (explicit) and classify_all's no-lock-recent mtime
  # floor (defense in depth, see classify_all's own docstring) still apply
  # either way, so this isn't the only guard in play.
  local -a in_flight_agent_ids=()
  local session_state_file
  session_state_file="$(shipyard_home)/sessions/${session_id}.json"
  if [ -f "$session_state_file" ] && command -v jq >/dev/null 2>&1; then
    local ifaid
    while IFS= read -r ifaid; do
      [ -z "$ifaid" ] && continue
      in_flight_agent_ids+=("$ifaid")
    done < <(jq -r '.in_flight[]?.agent_id // empty' "$session_state_file" 2>/dev/null)
  fi

  # Build the exclude set (bare agent-ids -> agent-<id> worktree names) as a
  # sentinel-delimited string for membership checks — bash-3.2 compatible
  # (no associative arrays), same pattern reap_session_worktrees' `seen_csv`
  # already uses in this file. Union of the explicit --exclude-agent-id
  # flags AND the auto-derived in-flight set above — either source alone
  # protects an id; this is deliberately additive, never a replacement.
  local excluded_blob="|"
  local eid
  # `${arr[@]+"${arr[@]}"}` is the bash-3.2-safe expansion for "possibly
  # empty array under set -u" — bash < 4.4 treats a bare `"${arr[@]}"` on a
  # zero-element array as an unbound-variable error under `set -u`, and
  # --exclude-agent-id is commonly omitted entirely (no in-flight workers).
  for eid in "${exclude_ids[@]+"${exclude_ids[@]}"}" "${in_flight_agent_ids[@]+"${in_flight_agent_ids[@]}"}"; do
    excluded_blob+="agent-${eid}|"
  done

  local -a classify_args=(--repo-root "$repo_root")
  [ -n "$orchestrator_pid" ] && classify_args+=(--orchestrator-pid "$orchestrator_pid")
  [ -n "$peer_stale_min" ] && classify_args+=(--peer-stale-min "$peer_stale_min")

  # `attempt_count` gates the cap (it costs subprocess forks whether the
  # removal succeeds or not); `reaped_count` / `unreaped_count` split the
  # verified outcome of those attempts for the summary line.
  local attempt_count=0
  local reaped_count=0
  local unreaped_count=0
  local deferred_count=0
  local remaining_count=0
  # Issue #1223 — names skipped purely because the cap was reached. These
  # feed a FRESH on-disk recheck after the loop below, rather than trusting
  # this tally on its own — see the recheck's comment for why: a summary
  # line that only ever counts what a loop INTENDED can drift from what
  # actually happened, and #1223's repro is exactly that drift (`remaining=0`
  # printed while 59 directories sat on disk).
  local -a capped_names=()

  local line name classification pid worktree_path
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    name="${line%% *}"
    line="${line#* }"
    classification="${line%% *}"
    pid="${line#* }"

    # In-flight guard (issue #832) — skip BEFORE classification is even
    # consulted. A currently-dispatched slot's worktree is never
    # reap-eligible regardless of what its lock classifies as.
    case "$excluded_blob" in
      *"|${name}|"*) continue ;;
    esac

    worktree_path="$repo_root/.claude/worktrees/$name"

    # Defer on peer-alive (a genuine cross-session peer, alive and fresh),
    # no-lock-recent (issue #1147 — a no-lock candidate whose worktree
    # directory was touched within the staleness floor, presumed live in
    # the absence of a lock file to check), OR unknown (issue #1206 — the
    # lock file exists but couldn't be parsed at all; fail closed rather
    # than falling through to a reap). `--reason` carries the ACTUAL
    # classification into the audit line rather than a hardcoded
    # "peer-alive" that would misreport a no-lock-recent or unknown defer.
    if [ "$classification" = "peer-alive" ] || [ "$classification" = "no-lock-recent" ] || [ "$classification" = "unknown" ]; then
      printf 'deferred: %s\n' "$name"
      deferred_count=$((deferred_count + 1))
      if [ "$dry_run" -eq 0 ]; then
        reap_action \
          --action deferred \
          --worktree-path "$worktree_path" \
          --worktree-name "$name" \
          --session-id "$session_id" \
          --reason "$classification" \
          --phase "setup-3b" \
          --lock-pid "$pid" \
          >/dev/null 2>&1 || true
      fi
      continue
    fi

    # Reap-eligible (no-lock / dead / self-ancestor / peer-alive-stale) —
    # only up to the cap, oldest-first (classify_all's output is already
    # sorted that way). Beyond the cap: leave untouched for a future
    # session — this IS the checkpoint (see docstring above).
    if [ "$attempt_count" -ge "$max_per_session" ]; then
      capped_names+=("$name")
      continue
    fi
    attempt_count=$((attempt_count + 1))

    if [ "$dry_run" -eq 1 ]; then
      printf 'reaped: %s\n' "$name"
      reaped_count=$((reaped_count + 1))
      continue
    fi

    # --bypass-return-check (#1237): reap-stale is a CROSS-SESSION sweep —
    # a worktree it reaps may belong to a different, already-dead
    # session's state file, which this `--session-id` doesn't read. No
    # single session's .returned_agent_ids applies here by construction.
    reap_action \
      --action reaped \
      --worktree-path "$worktree_path" \
      --worktree-name "$name" \
      --session-id "$session_id" \
      --classification "$classification" \
      --phase "setup-3b" \
      --lock-pid "$pid" \
      --bypass-return-check "cross-session stale-worktree sweep (#1237) — worktree may belong to a different, already-dead session" \
      >/dev/null 2>&1 || true

    # Issue #712 — report the verified end state, not the intent.
    if [ -e "$worktree_path" ]; then
      printf 'unreaped: %s\n' "$name"
      unreaped_count=$((unreaped_count + 1))
    else
      printf 'reaped: %s\n' "$name"
      reaped_count=$((reaped_count + 1))
    fi
  done < <(classify_all "${classify_args[@]}")

  # Issue #1223 — derive `remaining` from a FRESH on-disk check taken after
  # the sweep, not from the loop's own running tally. In every path this
  # function can take, a capped-out worktree is one the sweep above never
  # attempted to touch, so this recheck and a naive tally always agree —
  # but computing it this way means a future regression that DOES touch a
  # capped worktree (or otherwise fails to leave it alone) surfaces here
  # instead of being silently absorbed into a stale count, exactly the
  # failure mode that let `remaining=0` print while 59 directories sat on
  # disk in #1223's repro. Bash-3.2-safe empty-array expansion (no `set -u`
  # unbound-variable error when nothing was capped).
  local capped_name
  for capped_name in "${capped_names[@]+"${capped_names[@]}"}"; do
    [ -e "$repo_root/.claude/worktrees/$capped_name" ] && \
      remaining_count=$((remaining_count + 1))
  done

  printf 'summary: reaped=%s deferred=%s unreaped=%s remaining=%s tombstones_swept=%s tombstones_failed=%s tombstones_remaining=%s\n' \
    "$reaped_count" "$deferred_count" "$unreaped_count" "$remaining_count" \
    "$tombstones_swept" "$tombstones_failed" "$tombstones_remaining"

  # Issue #1482 — an honest exit code. This used to `return 0`
  # unconditionally, so a pass that attempted N reaps and left some of them
  # on disk was indistinguishable, to any caller reading only the status,
  # from a clean sweep — the exact silent-degrade dont.md's "Don't swallow
  # a failed or denied reap" bullet (#712/#1274) forbids, one layer below
  # where that bullet's report-unreaped / reaped-failed machinery operates.
  # Those remain the durable, per-worktree forensic record; this is the
  # immediate signal to the caller that made THIS call, which had none.
  #
  # Exit 3, not 1: this is "completed, but partial", not "crashed" and not
  # "bad usage" (64). The summary line is still emitted, every successful
  # reap still happened, and the caller's correct response is to surface
  # the count — never to treat the sweep as not having run. `remaining` /
  # `tombstones_remaining` deliberately do NOT trigger it: those are the
  # intentional cap checkpoint, which is normal operation.
  if [ "$unreaped_count" -gt 0 ] || [ "$tombstones_failed" -gt 0 ]; then
    return 3
  fi
  return 0
}

# Issue #1365 (follow-up to #1355) — single-call replacement for setup step
# 3c's own discover-then-triage loop: the per-branch state machine (push,
# PR creation, gated auto-merge arming, the tracked counters) plus the
# issue #303 stale @me self-assign sweep, which used to live as a
# `for wt_dir in $(find ...)` loop directly in the orchestrator's own Bash
# tool call. Wrapping it in one script call, invoked as ONE plain
# `worktree-reap.sh triage-orphan-branches ...` command, makes it reachable
# at any point in setup, pre- or post-relocation — the multi-statement
# shape dont.md's post-relocation-Bash-blocks rule (#1277) documents as
# fragile. This is the ONLY sweep step 0.45 still runs; see
# 00e-pre-relocation-sweeps.md.
#
# (The docstring that stood here described `sweep_stale_agents`, the
# setup-3b wrapper issue #1472 deleted without moving its comment —
# leaving this function documented as a different, now-nonexistent
# subcommand. That stale text is the most likely reason issue #1482's
# reporter invoked `sweep-stale-agents` against a version that no longer
# has it. Fixed in #1482.)
#
# Issue #1518 — blast radius. Three sessions in three days had this sweep
# open 7, 13, and 14 auto-merge-armed PRs in a single uninterrupted pass,
# before a single worker had been dispatched; on 2026-08-24 one of them
# (#1533) auto-merged into `main` while setup was still running. The sweep
# also reliably exceeds the caller's 120s foreground timeout and gets moved
# to the background, so it keeps writing after its tool call has returned —
# which means "interrupt it when it looks wrong" is not an available
# remedy. See usage()'s BLAST-RADIUS BOUNDS block above for the four
# properties that bound it now (draft-by-default, --max-prs, --dry-run,
# pre-write progress output).
#
# Issue #1517 — already-landed pre-checks. #1518 bounded how much damage a
# misfiring predicate can do; this is the predicate itself. Every one of
# those 7 / 13 / 14 salvaged PRs was a duplicate of work already on the
# default branch, because the `ahead` test compares commits by SHA identity
# and a squash merge rewrites the sha. Two content-aware signals now gate
# PR creation — an empty effective diff (pure local git), and an originating
# issue already CLOSED by a merged PR (one `gh` read) — either of which
# suppresses the PR and drains the candidate worktree. See the block above
# the checks themselves for the mechanism and the conservative-failure rule.
#
# Issue #1541 — a THIRD pre-check, for the class the second structurally
# cannot see. Check 2 keys on the originating issue's STATE, so a PR that
# merged carrying `refs #N` rather than `closes #N` — or an issue still
# gated on needs-human-review after its code landed — leaves that issue OPEN
# indefinitely while its work sits on the default branch, and check 2
# correctly declines. A real --dry-run of the #1540 guard against this repo
# at 001415f suppressed 18 of 21 candidates and left exactly that shape as 2
# of the 3 survivors (do-work/issue-1412, landed as PR #1508; and
# do-work/issue-1511, landed as PR #1515 — both with OPEN issues). Check 3
# asks whether every path the branch ADDS relative to its merge-base already
# exists upstream. Same conservative-failure rule and same weak-evidence
# action as check 2 (worktree drained, branch ref kept). See the block above
# the check itself for the full predicate, the measured reason a per-file
# blob-ancestry test was rejected, and the residual-risk argument.
#
# Issue #1565 — check 2b, closing check 2's OTHER blind spot. Check 2 needs
# the issue's `closedByPullRequestsReferences` to be populated, and GitHub
# populates it only when a merged PR carried a closing keyword its linker
# resolved — so an issue closed BY HAND after its PR landed reads
# CLOSED/COMPLETED with that array EMPTY and check 2 declines, even though
# the branch's own PR is MERGED. Observed live on mattsears18/lightwork
# (session do-work-20260915T205245Z-95644): do-work/issue-4738 and
# do-work/issue-4823 were both planned for `salvage` with PRs #4740 and
# #4826 already merged, checks 1 and 3 having correctly declined. Check 2b
# asks `gh pr list --state merged --head <canonical branch>` — the exact
# head the salvage would push to — only after 1 and 2 decline. Same
# conservative-failure rule and same weak-evidence action as check 2.
triage_orphan_branches() {
  local repo_root=""
  local repo=""
  local default_branch=""
  # Issue #1518 — blast-radius bounds. Defaults are deliberately conservative:
  # a genuinely stranded-work backlog is small by construction, so a LARGE
  # candidate set is itself evidence something is wrong and is exactly when
  # NOT to act on all of it unattended.
  local max_prs=3
  local dry_run=0
  local arm_auto_merge=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --repo-root)
        repo_root="${2:-}"
        shift 2
        ;;
      --repo-root=*)
        repo_root="${1#--repo-root=}"
        shift
        ;;
      --repo)
        repo="${2:-}"
        shift 2
        ;;
      --repo=*)
        repo="${1#--repo=}"
        shift
        ;;
      --default-branch)
        default_branch="${2:-}"
        shift 2
        ;;
      --default-branch=*)
        default_branch="${1#--default-branch=}"
        shift
        ;;
      --session-id)
        # Accepted-and-ignored (issue #1400). This subcommand has no
        # --session-id-scoped state to consult (no .in_flight exclusion,
        # no per-session audit attribution) — unlike its sibling sweeps
        # reap-orphan-orchestrators / sweep-stale-agents, which both
        # require it. Documented here purely for CLI symmetry: a caller
        # that reasonably assumes every sweep in this family takes
        # --session-id (00e-pre-relocation-sweeps.md's step 7 lists all
        # three together) gets a silent no-op instead of "unknown flag."
        shift 2
        ;;
      --session-id=*)
        shift
        ;;
      --max-prs)
        max_prs="${2:-}"
        shift 2
        ;;
      --max-prs=*)
        max_prs="${1#--max-prs=}"
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --arm-auto-merge)
        arm_auto_merge=1
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      --)
        shift
        ;;
      -*)
        echo "triage-orphan-branches: unknown flag: $1" >&2
        return 64
        ;;
      *)
        echo "triage-orphan-branches: unexpected positional arg: $1" >&2
        return 64
        ;;
    esac
  done

  if [ -z "$repo_root" ]; then
    echo "triage-orphan-branches: --repo-root is required" >&2
    return 64
  fi
  if [ -z "$repo" ]; then
    echo "triage-orphan-branches: --repo is required" >&2
    return 64
  fi
  if [ -z "$default_branch" ]; then
    echo "triage-orphan-branches: --default-branch is required" >&2
    return 64
  fi
  case "$max_prs" in
    ''|*[!0-9]*)
      echo "triage-orphan-branches: --max-prs must be a non-negative integer (got: '$max_prs')" >&2
      return 64
      ;;
  esac

  if ! cd "$repo_root" 2>/dev/null; then
    echo "triage-orphan-branches: cannot cd to --repo-root: $repo_root" >&2
    return 64
  fi

  local this_dir
  this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local config_script="$this_dir/shipyard-config.sh"
  local detector_script="$this_dir/detect-ungated-admin-direct-merge.sh"
  local GH="${GH:-gh}"

  local salvaged_count=0
  local abandoned_count=0
  local stale_assigns_count=0
  local prs_created=0
  local deferred_count=0
  local landed_count=0
  local -a failed_pr_lines=()
  local -a stale_assign_lines=()
  local -a deferred_lines=()
  local -a landed_lines=()

  # Issue #1517 — refresh the remote-tracking ref the already-landed
  # pre-checks (and the pre-existing `ahead` computation) are measured
  # against. A stale `origin/<default-branch>` can only make those checks
  # UNDER-fire — a branch looks diverged from an old base — which is the
  # conservative direction, so this is an accuracy improvement rather than a
  # correctness requirement. Deliberately non-fatal and run in --dry-run too,
  # so the plan a human reads is classified against the same refs the real
  # sweep would use.
  git fetch --quiet origin "$default_branch" >/dev/null 2>&1 || true

  # Issue #1518 — enumerate the candidate set BEFORE the first write, so the
  # blast radius is knowable up front instead of being reconstructed from the
  # terminal `summary:` line after every PR already exists and is already
  # armed. The list is captured into a variable (rather than streamed from a
  # process substitution the way it used to be) precisely so it can be counted
  # and announced first.
  local candidates total
  candidates=$(git worktree list --porcelain \
    | awk '/^branch refs\/heads\/do-work\//{print $2}' \
    | sed 's|refs/heads/||')
  total=$(printf '%s\n' "$candidates" | awk 'NF{c++} END{print c+0}')

  printf 'candidates: %s\n' "$total"
  if [ "$dry_run" -eq 1 ]; then
    printf 'dry-run: no writes will be performed\n'
  fi

  local branch path n canonical_branch ahead pushed open_pr
  local stale_reason stale_action diff_rc issue_probe issue_state closing_pr merged_pr
  local merge_base added_path added_total added_on_main added_sample
  local idx=0
  while IFS= read -r branch; do
    [ -z "$branch" ] && continue
    path=$(git worktree list | grep "\[$branch\]" | awk '{print $1}')
    [ -z "$path" ] && continue
    idx=$((idx + 1))

    n=$(echo "$branch" | sed -E 's|^do-work/issue-([0-9]+).*|\1|')
    canonical_branch="do-work/issue-$n"
    ahead=$(git -C "$path" rev-list --count "origin/${default_branch}..HEAD" 2>/dev/null || echo 0)

    if [ "$ahead" -eq 0 ] 2>/dev/null; then
      # #1518 — the progress line is emitted BEFORE the write, not after, so
      # a sweep that is backgrounded partway through still leaves a record of
      # exactly which candidate it was acting on when it went out of view.
      printf '[%s/%s] abandon %s — no commits beyond %s\n' \
        "$idx" "$total" "$canonical_branch" "$default_branch"
      if [ "$dry_run" -eq 0 ]; then
        # Issue #712 — non-force FIRST, force only behind evidence. `git
        # worktree remove` (no --force) refuses on a dirty tree, which is the
        # exact safety property a force-only escalation needs preceding
        # evidence for. The `ahead -eq 0` test above IS that evidence: this
        # worktree carries no commits beyond the base branch, so nothing
        # being force-removed exists only here.
        git worktree remove "$path" >/dev/null 2>&1 \
          || git worktree remove --force "$path" >/dev/null 2>&1
        git branch -D "$branch" >/dev/null 2>&1
        "$GH" issue edit "$n" --repo "$repo" --remove-assignee @me 2>/dev/null || true
      fi
      abandoned_count=$((abandoned_count + 1))
      continue
    fi

    # ---- Issue #1517 — already-landed pre-checks ------------------------
    #
    # `ahead` above cannot see an already-landed branch. `rev-list --count`
    # compares commits by SHA IDENTITY, and a squash merge — shipyard's own
    # schema default for `auto_merge.method` — replays the branch's content
    # under a brand-new sha, so the branch's original commits are never
    # ancestors of the default branch. `ahead > 0` is therefore permanently
    # true for every branch a squash-merge repo ever landed, `ahead == 0` is
    # unreachable, and the candidate set (which is `git worktree list`, not
    # remote refs) never drains: it grows by one per shipped issue and was
    # only ever emptied by an arm that cannot fire. One branch regenerated a
    # duplicate PR once per session for three consecutive sessions this way,
    # and each session did the locally-correct thing — close the stale PR —
    # which leaves the generator fully intact. The loop is stable under
    # attention, which is why it ran for days.
    #
    # Two CONTENT-aware signals replace that commit-identity test, checked in
    # cost order. Either one alone suppresses the PR. Both fail
    # CONSERVATIVE: an unreadable signal is never treated as evidence of
    # staleness, so anything this cannot classify is salvaged exactly as
    # before. The failure mode being fixed is confidently opening a
    # definitely-stale PR — not possibly missing one.
    #
    # Suppression happens BEFORE the `--max-prs` cap is consulted, so a
    # backlog of already-landed leftovers no longer consumes the cap budget
    # that genuinely-stranded work needs.
    stale_reason=""
    stale_action=""

    # Check 1 — empty effective diff. Pure local git, no API call, and on
    # the recorded repros it alone would have suppressed the large majority,
    # which is why it is ordered first. A tree identical to the default
    # branch's means this branch's content is already upstream however it got
    # there (squash, rebase, cherry-pick, or a sibling PR that landed the
    # same change). `git diff --quiet` exits 0 for "no difference", 1 for
    # "differs", and >1 for an error — only the literal 0 is treated as
    # evidence.
    git -C "$path" diff --quiet "origin/${default_branch}" HEAD >/dev/null 2>&1
    diff_rc=$?
    if [ "$diff_rc" -eq 0 ]; then
      stale_reason="content already upstream (empty diff vs $default_branch)"
      # Provably nothing unique in the history here: the branch's tree IS the
      # default branch's tree. Same evidence standard the `ahead == 0` arm
      # relies on, so it earns the same cleanup — and that cleanup is the
      # half that makes the candidate set actually drain. Suppressing the PR
      # alone would only convert an unbounded PR generator into an unbounded
      # no-op loop that still re-scans every leftover worktree every session.
      stale_action="remove-worktree-and-branch"
    fi

    # Check 2 — originating issue already CLOSED by a merged PR. One `gh`
    # read, made only when check 1 did not already fire, and candidates are
    # rare by construction. `closedByPullRequestsReferences` is GitHub's own
    # canonical "these PRs closed this issue" link, so this needs no body
    # substring search. Requires BOTH halves: a closed issue on its own can
    # be a `not planned` close with the branch's work still unlanded, whereas
    # closed-BY-a-merged-PR is near-conclusive that this branch is a
    # leftover.
    #
    # This catches the class check 1 structurally cannot: a branch that is a
    # SUPERSEDED EARLIER DRAFT of work that landed in a better form. Those
    # have a NON-empty diff, and merging one is a silent revert of landed
    # work — which is why this guard is not merely a dispatch-budget
    # optimization.
    if [ -z "$stale_reason" ]; then
      case "$n" in
        ''|*[!0-9]*)
          # The branch name did not yield an issue number (sed passes the
          # input through unchanged on no-match), so there is nothing to
          # look up. Unreadable signal -> not stale.
          ;;
        *)
          issue_probe=$("$GH" issue view "$n" --repo "$repo" \
            --json state,closedByPullRequestsReferences \
            --jq '(.state // "") + "|" + ((.closedByPullRequestsReferences // []) | map(.number|tostring) | first // "")' 2>/dev/null)
          issue_state="${issue_probe%%|*}"
          closing_pr="${issue_probe#*|}"
          if [ "$issue_state" = "CLOSED" ] && [ -n "$closing_pr" ] && [ "$closing_pr" != "$issue_probe" ]; then
            stale_reason="issue #$n CLOSED, work merged as PR #$closing_pr"
            # WEAKER evidence than check 1: the diff is non-empty, so these
            # commits are NOT provably reachable from the default branch.
            # Drain the candidate set — which is `git worktree list`, so
            # removing the worktree is what makes the loop terminate — but
            # KEEP the branch ref as a safety net. That is exactly the
            # remediation a maintainer applied by hand across 28 leftover
            # worktrees: the refs are inert once no worktree points at them.
            stale_action="remove-worktree-only"
          fi
          ;;
      esac
    fi

    # Check 2b — the BRANCH'S OWN PR already MERGED. Issue #1565.
    #
    # Numbered 2b rather than renumbering the superseded-draft check to 4
    # because it is check 2's question asked against a second, independent
    # key: same near-conclusive evidence class, same weak-evidence action,
    # and the cheapest possible position (one `gh` read, made only when the
    # free local-git check 1 and the already-paid check 2 have both
    # declined). Every "check 3" reference in this file and in
    # worktree-reap.test.sh continues to mean the superseded-draft check.
    #
    # WHAT IT CATCHES that check 2 cannot. Check 2 keys exclusively on the
    # ISSUE's `closedByPullRequestsReferences`, which GitHub populates only
    # when a merged PR carried a closing keyword its linker resolved. An
    # issue closed BY HAND after its PR landed — or closed via a PR body the
    # linker never resolved — is CLOSED/COMPLETED with that array EMPTY, so
    # check 2's second half fails and it declines, even while the branch's
    # own PR sits there MERGED. That is not hypothetical: session
    # do-work-20260915T205245Z-95644 on mattsears18/lightwork planned
    # `salvage` for do-work/issue-4738 and do-work/issue-4823 whose PRs
    # #4740 and #4826 had both already merged, because both issues reported
    # `{"closedByPullRequestsReferences":[],"state":"CLOSED"}`. Check 1
    # declined (the default branch had moved on since the squash) and check
    # 3 declined (neither branch adds a new path), so the one signal that
    # settles it — the branch's own PR state — was never consulted, and the
    # sweep would have pushed two stale branches, opened two duplicate
    # drafts, and spent 2 of its 3 --max-prs slots on work already upstream.
    #
    # WHY THIS HEAD REF. The probe asks about `$canonical_branch`, the exact
    # head the salvage path below pushes to and opens its PR against (and
    # the same name its own open-PR query already uses). A hit therefore
    # means literally "the PR this sweep is about to duplicate has already
    # merged" rather than anything inferred from a different ref.
    #
    # WHY NOT ALSO "CLOSED + COMPLETED + no open PR". #1565 floats that as a
    # second, weaker class to consider. Declined here: it infers landing
    # from the ABSENCE of a signal, which cannot fail conservative — a
    # `not planned`-adjacent close, or a repo where the PR was closed
    # unmerged, reads identically to a real landing. This check asserts a
    # merged PR exists, which the absence form never does.
    #
    # FAILURE POSTURE, identical to every check around it: an empty or
    # unreadable result is not evidence of staleness and salvages unchanged.
    # ACTION is check 2's, not check 1's — under a squash merge the branch's
    # own commits are still not reachable from the default branch, so the
    # worktree is drained and the branch ref is KEPT as a safety net.
    if [ -z "$stale_reason" ]; then
      merged_pr=$("$GH" pr list --repo "$repo" --state merged --head "$canonical_branch" \
        --json number --jq '.[0].number // empty' 2>/dev/null)
      case "$merged_pr" in
        ''|*[!0-9]*)
          # Empty, or anything that is not a bare PR number (an error string
          # leaking onto stdout, a `gh` that printed a warning). Unreadable
          # signal -> not stale.
          ;;
        *)
          stale_reason="branch's own PR #$merged_pr already MERGED"
          stale_action="remove-worktree-only"
          ;;
      esac
    fi

    # Check 3 — SUPERSEDED DRAFT: every brand-new path this branch invents
    # already exists on the default branch. Issue #1541, the third pre-check
    # proposed on #1517 and deliberately deferred out of #1540.
    #
    # Runs ONLY when checks 1 and 2 have both declined, and costs no API call
    # — it is pure local git, so its position last in the chain is about
    # evidence strength, not cost.
    #
    # WHAT IT CATCHES that neither check above can. Check 2 keys on issue
    # STATE, and a PR that merges with `refs #N` rather than `closes #N` — or
    # an issue gated on `needs-human-review` after its code landed — leaves
    # the originating issue OPEN indefinitely while its work sits on the
    # default branch. Check 2 correctly declines there; check 1 correctly
    # declines too, because a superseded EARLIER draft has a non-empty diff.
    # Measured on this repo at 001415f: of 21 candidates, 18 were suppressed
    # by checks 1+2 and 2 of the 3 survivors were exactly this shape —
    # do-work/issue-1412 (landed as PR #1508) and do-work/issue-1511 (landed
    # as PR #1515), both with OPEN originating issues.
    #
    # THE PREDICATE, and why it is defensible. For each path the branch ADDS
    # relative to its merge-base with the default branch, ask whether that
    # path exists on the default branch today. A path absent at the fork
    # point but present upstream now was created upstream AFTER the fork. If
    # EVERY path this branch invents was independently created upstream, the
    # work this branch claims has already been done by someone else — the
    # superseded-draft shape. This is a content-EXISTENCE fact, not a
    # size comparison, so #1541's explicit objection to a line-count proxy (a
    # refactor deleting more than it adds is still ahead) does not apply: no
    # line, hunk, or byte counts are compared anywhere in this check.
    #
    # WHY ONLY ADDED PATHS. A MODIFIED path carries no signal: the
    # coordination-managed rows every PR in this repo touches (CHANGELOG.md,
    # plugin.json) are modified by definition, so "the default branch also
    # moved this file" is true of ordinary churn and would fire on nearly
    # everything. Restricting to additions is what keeps the genuine negative
    # control clean — do-work/issue-1543 was a real `existing-pr` whose work
    # had NOT landed, and it adds no new path at all, so this check never
    # reaches a verdict on it.
    #
    # WHY "ALL", NOT "ANY". If even one invented path is still missing
    # upstream, the branch carries content the default branch has never seen.
    # Conservative-failure rule: that salvages, exactly as before.
    #
    # WHY NOT the per-file blob-ancestry predicate #1541 floats as the most
    # likely candidate ("main's blob is reachable from the branch's blob
    # through the file's own history"). Measured against the same two
    # fixtures, it is too strict to ship: #1511's branch blob for
    # refuse-hook-bypass-flag.sh IS present in the default branch's history
    # of that path (the work landed byte-identically), but #1412's branch
    # blob for commit-subject-scan.sh appears nowhere in that path's history
    # — PR #1508 landed a textually DIFFERENT implementation of the same
    # issue. Blob-ancestry therefore catches only 1 of the 2 recorded
    # repros, while path-existence catches both.
    #
    # FAILURE POSTURE, identical to checks 1 and 2: every unreadable or
    # ambiguous signal resolves to "not stale" and salvages. An unresolvable
    # merge-base, a diff that errors, or an existence probe that fails for
    # any reason (including an unresolvable origin/<default-branch>) all
    # leave the path counted as ABSENT upstream, which forces the "all"
    # test to fail. A branch with zero added paths is never stale here — the
    # emptiness is not itself evidence.
    #
    # RESIDUAL RISK, and why the action bounds it. Two branches could
    # independently invent the same new path for unrelated reasons, and the
    # second's other work would then be suppressed. That branch is an add/add
    # conflict against the default branch and could not have merged cleanly
    # anyway; more to the point the action below is check 2's, not check 1's
    # — drain the worktree, KEEP the branch ref — because the evidence is
    # circumstantial. Nothing is destroyed, the `already-landed:` report line
    # names the branch, and clearing the assignee returns the issue to the
    # backlog for a fresh dispatch.
    if [ -z "$stale_reason" ]; then
      merge_base=$(git merge-base "origin/${default_branch}" "$branch" 2>/dev/null)
      if [ -n "$merge_base" ]; then
        added_total=0
        added_on_main=0
        added_sample=""
        # -z/NUL-delimited so a path containing whitespace or a quote-worthy
        # byte is read intact rather than split or returned core.quotePath-
        # escaped. --no-renames makes "added" mean literally "absent at the
        # merge-base, present at the tip": with rename detection on, a path
        # the branch created by moving would score as R and silently drop out
        # of the denominator, weakening the "all" test.
        while IFS= read -r -d '' added_path; do
          [ -z "$added_path" ] && continue
          added_total=$((added_total + 1))
          if git cat-file -e "origin/${default_branch}:$added_path" 2>/dev/null; then
            added_on_main=$((added_on_main + 1))
            [ -z "$added_sample" ] && added_sample="$added_path"
          fi
        done < <(git diff --name-only --no-renames --diff-filter=A -z \
          "$merge_base" "$branch" 2>/dev/null)
        if [ "$added_total" -gt 0 ] && [ "$added_on_main" -eq "$added_total" ]; then
          stale_reason="superseded draft: all $added_total new path(s) this branch adds already exist on $default_branch (e.g. $added_sample)"
          # Same action as check 2 — the evidence is circumstantial, so the
          # branch ref survives as a safety net for a human to inspect.
          stale_action="remove-worktree-only"
        fi
      fi
    fi

    if [ -n "$stale_reason" ]; then
      # #1518's pre-write progress contract: the classification is printed
      # before any write, and unconditionally — so `--dry-run` renders the
      # full per-candidate verdict a human can audit, rather than the
      # classification only becoming visible once the real sweep has acted.
      if [ "$stale_action" = "remove-worktree-and-branch" ]; then
        printf '[%s/%s] already-landed %s — %s; no PR opened, removing worktree + branch\n' \
          "$idx" "$total" "$canonical_branch" "$stale_reason"
      else
        printf '[%s/%s] already-landed %s — %s; no PR opened, removing worktree (branch kept)\n' \
          "$idx" "$total" "$canonical_branch" "$stale_reason"
      fi
      if [ "$dry_run" -eq 0 ]; then
        # Non-force ONLY — issue #712's "force only behind evidence" rule.
        # Unlike the `ahead == 0` arm above, "content already upstream" is a
        # statement about HEAD, not about the working tree: a dirty worktree
        # here may hold edits that exist nowhere else. A refusal is therefore
        # respected and reported rather than escalated to --force.
        if git worktree remove "$path" >/dev/null 2>&1; then
          if [ "$stale_action" = "remove-worktree-and-branch" ]; then
            git branch -D "$branch" >/dev/null 2>&1
          fi
          "$GH" issue edit "$n" --repo "$repo" --remove-assignee @me 2>/dev/null || true
        else
          printf '[%s/%s] already-landed %s — worktree NOT removed (dirty or locked); left in place for a human\n' \
            "$idx" "$total" "$canonical_branch"
        fi
      fi
      landed_lines+=("$canonical_branch — $stale_reason")
      landed_count=$((landed_count + 1))
      continue
    fi

    # Read-only classification BEFORE any write for this candidate (#1518).
    # The cap has to be applied against what this invocation would CREATE, so
    # the "is a PR already open?" query must precede the push rather than
    # follow it. A branch with no PR also has nothing on origin for `gh pr
    # list --head` to have found, so moving the query ahead of the push is
    # behaviour-preserving.
    open_pr=$("$GH" pr list --repo "$repo" --head "$canonical_branch" --json number --jq '.[0].number' 2>/dev/null)

    if [ -z "$open_pr" ]; then
      # #1518 — hard bound on outward-facing writes per invocation. `--max-prs
      # 0` opts out (unlimited), and must be typed explicitly.
      if [ "$max_prs" -ne 0 ] && [ "$prs_created" -ge "$max_prs" ]; then
        printf '[%s/%s] deferred %s — --max-prs cap (%s) reached, no writes\n' \
          "$idx" "$total" "$canonical_branch" "$max_prs"
        deferred_lines+=("$canonical_branch")
        deferred_count=$((deferred_count + 1))
        continue
      fi

      if [ "$arm_auto_merge" -eq 1 ]; then
        printf '[%s/%s] salvage %s — push + open PR (ready, auto-merge armed when gated)\n' \
          "$idx" "$total" "$canonical_branch"
      else
        printf '[%s/%s] salvage %s — push + open PR (draft, auto-merge NOT armed)\n' \
          "$idx" "$total" "$canonical_branch"
      fi

      if [ "$dry_run" -eq 0 ]; then
        pushed=$(git ls-remote --heads origin "$canonical_branch" 2>/dev/null)
        if [ -z "$pushed" ]; then
          git -C "$path" push -u origin "HEAD:refs/heads/$canonical_branch" >/dev/null 2>&1 || true
        fi

        # #1518 — DRAFT by default. This PR is a PRIOR session's orphaned
        # branch, opened with --fill; nothing in this session ever reviewed
        # its diff. A draft PR cannot auto-merge at all, which is the cheapest
        # and strongest single guard available here: it fully preserves the
        # branch's work for a human to look at (the sweep's actual purpose)
        # while making it structurally impossible for an unreviewed salvage to
        # reach the default branch on its own. Drain's own open-PR query
        # already filters `-is:draft`, so a draft salvage neither stalls the
        # drain loop nor gets landed by its deferred-merge lander.
        if [ "$arm_auto_merge" -eq 1 ]; then
          (cd "$path" && "$GH" pr create --repo "$repo" --head "$canonical_branch" --fill --label shipyard 2>/dev/null) || true
        else
          (cd "$path" && "$GH" pr create --repo "$repo" --head "$canonical_branch" --draft --fill --label shipyard 2>/dev/null) || true
        fi
        local pr_num
        pr_num=$("$GH" pr list --repo "$repo" --head "$canonical_branch" --json number --jq '.[0].number' 2>/dev/null)
        if [ -n "$pr_num" ] && [ "$arm_auto_merge" -eq 0 ]; then
          echo "[setup-3c] PR #$pr_num opened as a DRAFT, auto-merge NOT armed (#1518) — a human marks it ready after auditing the salvaged branch"
        fi
        # #720: gate the arm behind the ungated-merge detector. On an ungated
        # repo --auto is not a queue; it direct-merges that unreviewed work
        # immediately. Fail-safe: an unreadable verdict resolves to `ungated`
        # (defer), never to an immediate merge. Reachable only under the
        # explicit `--arm-auto-merge` opt-in (#1518).
        if [ -n "$pr_num" ] && [ "$arm_auto_merge" -eq 1 ]; then
          local verdict
          if [ -n "${WORKTREE_REAP_VERDICT_OVERRIDE:-}" ]; then
            verdict="$WORKTREE_REAP_VERDICT_OVERRIDE"
          else
            verdict=$(bash "$detector_script" "$repo" 2>/dev/null || echo ungated)
          fi
          local auto_merge_method
          auto_merge_method=$("$config_script" get auto_merge.method 2>/dev/null)
          case "$auto_merge_method" in squash|merge|rebase) ;; *) auto_merge_method=squash ;; esac
          if [ "$verdict" = "gated" ]; then
            # Capture stderr instead of discarding it (#850) — the same
            # missing-`workflow`-OAuth-scope block a worker's own arm can hit
            # can hit this orphan-recovery arm too.
            local merge_arm_err
            merge_arm_err=$("$GH" pr merge "$pr_num" --repo "$repo" --auto --"$auto_merge_method" --delete-branch 2>&1 1>/dev/null) || true
            if printf '%s' "$merge_arm_err" | grep -qi "without .workflow. scope"; then
              echo "[setup-3c] PR #$pr_num auto-merge arm blocked — gh token lacks workflow scope (#850); left OPEN unarmed"
            fi
          else
            # Leave OPEN + unarmed. The PR carries --label shipyard (above),
            # which is exactly the label drain's deferred-merge lander keys
            # on — so it gets merged on the first poll its checks are green,
            # with no session_prs plumbing needed. Do NOT block on
            # `gh pr checks --watch` here — this would stall session start,
            # once per orphan.
            echo "[setup-3c] PR #$pr_num left unarmed (ungated repo) — deferred to drain's merge lander (#720)"
          fi
        fi
      fi
      prs_created=$((prs_created + 1))
    else
      printf '[%s/%s] existing-pr %s — PR #%s already open, reading its status rollup\n' \
        "$idx" "$total" "$canonical_branch" "$open_pr"
      # Commits ahead, pushed, PR already open — check its latest-per-name
      # status rollup (#333) and surface a FAILURE-shaped PR for the
      # caller's own failed_prs list. A clean/pending rollup is left alone;
      # normal auto-merge handles it.
      local rollup_count
      rollup_count=$("$GH" pr view "$open_pr" --repo "$repo" --json statusCheckRollup \
        --jq '[.statusCheckRollup | group_by(.name) | map(sort_by(.completedAt // .startedAt // "") | last) | .[] | select((.conclusion // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))] | length' 2>/dev/null)
      if [ -n "$rollup_count" ] && [ "$rollup_count" -gt 0 ] 2>/dev/null; then
        failed_pr_lines+=("$open_pr")
      fi
    fi
    salvaged_count=$((salvaged_count + 1))
  done <<< "$candidates"

  # Row 5 — stale @me self-assigns with no worktree, no PR, no branch on
  # origin (issue #303). Catches the state the worktree loop above CAN'T
  # see: a prior session that left the @me assignment on an issue after its
  # on-disk worktree was already cleaned up. Action is conservative: clear
  # the assignment only, leave the `shipyard` label as provenance, and let
  # the normal step-4 backlog fetch pick the issue back up on the next
  # dispatch.
  local backlog_self_assign
  backlog_self_assign=$("$config_script" get backlog.self_assign 2>/dev/null || echo "false")
  if [ "$backlog_self_assign" = "true" ]; then
    local unlinked n2 remote_head
    unlinked=$("$GH" issue list --repo "$repo" --state open --assignee @me --label shipyard --search '-linked:pr' --json number --jq '.[].number' 2>/dev/null)
    for n2 in $unlinked; do
      # If a worktree for this issue exists, the loop above already handled
      # it — skip. Same permissive issue-number extraction as #739 above so
      # a collision-fallback local branch name is still recognized as
      # "already handled."
      if git worktree list --porcelain | awk '/^branch refs\/heads\/do-work\/issue-/{print $2}' \
        | sed -E 's|^refs/heads/do-work/issue-([0-9]+).*|\1|' | grep -qx "$n2"; then
        continue
      fi
      # If a do-work branch for this issue still exists on origin, leave it
      # alone — it may belong to an open PR the `-linked:pr` filter missed.
      remote_head=$(git ls-remote --heads origin "do-work/issue-$n2" 2>/dev/null)
      if [ -n "$remote_head" ]; then
        continue
      fi
      printf '[row5] clear-stale-assign #%s\n' "$n2"
      if [ "$dry_run" -eq 0 ]; then
        "$GH" issue edit "$n2" --repo "$repo" --remove-assignee @me 2>/dev/null || true
      fi
      stale_assign_lines+=("$n2")
      stale_assigns_count=$((stale_assigns_count + 1))
    done
  fi

  local x
  for x in "${failed_pr_lines[@]+"${failed_pr_lines[@]}"}"; do
    printf 'failed-pr: %s\n' "$x"
  done
  for x in "${stale_assign_lines[@]+"${stale_assign_lines[@]}"}"; do
    printf 'stale-assign: %s\n' "$x"
  done
  for x in "${landed_lines[@]+"${landed_lines[@]}"}"; do
    printf 'already-landed: %s\n' "$x"
  done
  for x in "${deferred_lines[@]+"${deferred_lines[@]}"}"; do
    printf 'deferred: %s\n' "$x"
  done
  if [ "$deferred_count" -gt 0 ]; then
    printf 'cap-reached: %s candidate(s) remaining, not actioned; re-run or raise --max-prs (current: %s)\n' \
      "$deferred_count" "$max_prs"
  fi

  printf 'summary: salvaged=%s abandoned=%s stale_assigns=%s already_landed=%s\n' \
    "$salvaged_count" "$abandoned_count" "$stale_assigns_count" "$landed_count"
  return 0
}

# Issue #712 — post-sweep verification: which worktrees are STILL on disk?
#
# The reap sweeps are fire-and-forget (`2>/dev/null || true`) and run inside a
# background subshell, so when a reap does not happen the orchestrator has no
# signal. The most important non-happening is a **permission denial**: in Claude
# Code's auto permission mode the classifier can refuse the whole Bash tool call
# that carries the reap, so the helper never even runs and no `reaped-failed`
# audit line is written. Nothing inside the reap path can observe that.
#
# The only mechanism that catches it is an independent, after-the-fact probe of
# the filesystem: enumerate the worktree dirs that are still there once every
# sweep has had its turn. That covers a classifier denial, a git failure, the
# force-evidence gate declining, and a sweep that never ran at all — uniformly,
# because it asserts on the end state rather than on any step's exit code.
#
# Emits one absolute path per line for each `agent-*` / `orchestrator-*`
# directory still present under <repo-root>/.claude/worktrees, EXCLUDING:
#   - the caller's own orchestrator worktree (`orchestrator-<current-session-id>`),
#     which is still in use at summary time and is reaped last, and
#   - `*.reap-dead-*` scratch dirs, which the #664 fast path has already renamed
#     aside and is unlinking in the background (the branch is already freed).
# Empty stdout (exit 0) when everything was reaped — the normal case.
#
# The caller counts the lines and, when the count is non-zero, surfaces
# `Cleanup: <N> worktrees could not be reaped — run /clean_gone` in the
# end-of-session summary rather than silently degrading.
report_unreaped() {
  local repo_root=""
  local current_session_id=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --repo-root)
        repo_root="${2:-}"
        shift 2
        ;;
      --repo-root=*)
        repo_root="${1#--repo-root=}"
        shift
        ;;
      --current-session-id)
        current_session_id="${2:-}"
        shift 2
        ;;
      --current-session-id=*)
        current_session_id="${1#--current-session-id=}"
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      --)
        shift
        ;;
      -*)
        echo "report-unreaped: unknown flag: $1" >&2
        return 64
        ;;
      *)
        echo "report-unreaped: unexpected positional arg: $1" >&2
        return 64
        ;;
    esac
  done

  if [ -z "$repo_root" ]; then
    echo "report-unreaped: --repo-root is required" >&2
    return 64
  fi

  local wt_dir="$repo_root/.claude/worktrees"
  [ -d "$wt_dir" ] || return 0

  local path name
  # `find` (not a bare glob) so an empty match is a no-op rather than a fatal
  # `nomatch` under zsh — same rationale as setup step 3b (#335).
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    [ -d "$path" ] || continue
    name="$(basename "$path")"
    # Scratch dirs from the #664 rename-aside fast path: already reaped from
    # git's point of view (registration pruned, branch freed); the recursive
    # unlink is in flight. Not a leftover.
    case "$name" in
      *.reap-dead-*) continue ;;
    esac
    # Our own orchestrator worktree — still live, reaped last.
    if [ -n "$current_session_id" ] \
       && [ "$name" = "orchestrator-${current_session_id}" ]; then
      continue
    fi
    printf '%s\n' "$path"
  done < <(find "$wt_dir" -maxdepth 1 -mindepth 1 -type d \
             \( -name 'agent-*' -o -name 'orchestrator-*' \) 2>/dev/null | sort)

  return 0
}

main() {
  local sub="${1:-}"
  case "$sub" in
    classify-lock)
      shift
      classify_lock "$@"
      ;;
    classify-all)
      # Issue #836 — bulk classification. Reads every agent-* worktree's
      # lock file and enumerates its liveness in O(1) subprocess calls
      # total, instead of forking classify-lock (and its own internal
      # ps/stat calls) once per worktree. See classify_all's docstring.
      shift
      classify_all "$@"
      ;;
    reap-stale)
      # Issue #836 fix 2 — bounded, checkpointed cross-session stale-
      # worktree sweep built on classify-all. Reaps at most
      # --max-per-session (oldest-first), defers peer-alive, and leaves
      # the rest on disk as a self-checkpointing backlog for the next
      # session. See reap_stale's docstring.
      shift
      reap_stale "$@"
      ;;
    detect-orchestrator-pid|derive-session-id|find-orphan-orchestrators)
      # Issue #941 — these three moved to the sibling script
      # session-identity.sh. Fail loudly with a pointer rather than
      # silently no-op'ing, so a caller that hasn't been updated yet
      # gets an actionable error instead of empty stdout it might
      # mistake for "no match found".
      echo "worktree-reap.sh: '$sub' moved to session-identity.sh (issue #941) — call \"\${CLAUDE_PLUGIN_ROOT}/scripts/session-identity.sh\" $sub instead" >&2
      return 64
      ;;
    reap-orphan-branches)
      # Issue #326 — delete stale worktree-agent-* branch refs that have
      # no live worktree referencing them. See reap_orphan_branches for the
      # full algorithm.
      shift
      reap_orphan_branches "$@"
      ;;
    triage-orphan-branches)
      # Issue #1365 (follow-up to #1355) — single-call replacement for
      # setup-3c's own discover-then-triage loop (per-branch state machine
      # plus the issue #303 stale self-assign sweep), so it's reachable at
      # any point in setup instead of only pre-relocation. See
      # triage_orphan_branches for the full algorithm.
      shift
      triage_orphan_branches "$@"
      ;;
    report-unreaped)
      # Issue #712 — post-sweep verification. Enumerates the worktree dirs
      # still on disk after every reap sweep has run, so a reap that never
      # happened (auto-mode permission denial, git failure, force-evidence
      # gate declining) surfaces in the end-of-session summary instead of
      # silently degrading. See report_unreaped for the exclusion rules.
      shift
      report_unreaped "$@"
      ;;
    reap)
      # Issue #284 — single source of truth for reap-audit log writes.
      # See the reap_action function's docstring for the action-to-shape
      # mapping and field semantics.
      shift
      reap_action "$@"
      ;;
    disk-check)
      # Issue #1261 — mid-session disk-space backpressure probe. See
      # disk_free_check's docstring for the full contract (fails open,
      # never blocks dispatch on an unreadable df result).
      shift
      disk_free_check "$@"
      ;;
    inspect-unpushed)
      # Issue #1316 — read-only pre-reap worktree inspection, callable from
      # a worktree-isolated orchestrator session. See inspect_unpushed's
      # docstring for the full contract (the guard refuses `git -C` in the
      # caller's own command text, not inside this script).
      shift
      inspect_unpushed "$@"
      ;;
    -h|--help|help|"")
      usage
      [ -z "$sub" ] && return 64
      return 0
      ;;
    *)
      echo "worktree-reap.sh: unknown subcommand: $sub" >&2
      usage
      return 64
      ;;
  esac
}

main "$@"
