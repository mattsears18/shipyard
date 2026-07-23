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
# `claude agent <agent-id> (pid <orchestrator-pid>)`). At end-of-session
# cleanup the orchestrator is by definition still alive (it's the process
# running cleanup), so a strict liveness check defers EVERY worktree the
# orchestrator itself owns. The reporter saw 2 agent worktrees stuck because
# the lock PID was the orchestrator's PID 53391 — alive, but not a peer.
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
#       dead             — lock PID is dead (safe to reap, original semantics)
#       self-ancestor    — lock PID is alive AND is either (a) the declared
#                          orchestrator PID (via `SHIPYARD_ORCHESTRATOR_PID`
#                          env var or `--orchestrator-pid` flag) or (b) our
#                          own / an ancestor of ours (safe to reap —
#                          orchestrator owns this lock)
#       peer-alive-stale — lock PID is alive, is NOT self/ancestor, BUT the
#                          lock file's mtime is older than the staleness
#                          floor (default 60 min; `SHIPYARD_PEER_LOCK_STALE_MIN`
#                          / `--peer-stale-min <N>`). Safe to reap — see
#                          "Why a second gate" below (issue #755).
#       peer-alive       — lock PID is alive, is NOT self/ancestor, AND the
#                          lock file is within the staleness floor (defer —
#                          likely a genuine peer agent or other instance
#                          still running)
#     Env vars:
#       SHIPYARD_ORCHESTRATOR_PID — explicit orchestrator PID. Takes
#                        precedence over the ancestor walk for the
#                        self-ancestor check. Overridden by `--orchestrator-pid`
#                        if both are set.
#       SHIPYARD_PEER_LOCK_STALE_MIN — peer-alive staleness floor in minutes
#                        (default 60). Overridden by `--peer-stale-min <N>`
#                        if both are set.
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
# Callers should reap on `no-lock` / `dead` / `self-ancestor` /
# `peer-alive-stale`, defer on `peer-alive`. Every existing exact-string
# `= "peer-alive"` check already defers ONLY on the fresh case and falls
# through to "safe to reap" for anything else — so this new classification
# flows through to every call site (setup 3b, steady-state §2d, drain
# #370, step B, A.0.5, A.1, cleanup-summary) with no per-site change.
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
#     Same classification vocabulary as `classify-lock`. Emits one line per
#     `agent-*` worktree: `<name> <classification> <lock-pid|null>`, sorted
#     oldest-first by worktree-dir mtime so a caller implementing a
#     bounded, oldest-first reap can consume the output directly.
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
#     first; peer-alive worktrees are always deferred (not counted against
#     the cap); anything reap-eligible beyond the cap is left untouched on
#     disk — the remaining backlog on disk IS the checkpoint, so the next
#     session's sweep naturally continues from where this one stopped with
#     no separate state file to maintain. `--exclude-agent-id` (repeatable)
#     excludes a worktree from consideration entirely, BEFORE
#     classification is even consulted — the in-flight guard (issue #832):
#     a currently-dispatched slot's worktree must never be reaped
#     regardless of what its lock classifies as, because branch name is
#     never a liveness signal (see commands/do-work/dont.md).
#     Stdout: one `reaped: <name>` / `unreaped: <name>` (issue #712 —
#       verified end state, not intent) / `deferred: <name>` line per
#       acted-upon worktree, followed by exactly one summary line:
#       `summary: reaped=<R> deferred=<D> unreaped=<U> remaining=<REMAIN>`.
#       `remaining` is the count left on disk purely because the cap was
#       reached — the backlog a future session will continue from.
#     --dry-run emits the same lines/summary WITHOUT removing anything or
#     writing audit-log entries.
#     Exit codes:
#       0  sweep succeeded (output is always at least the summary line)
#       64 bad usage (missing required flag, malformed flag value)
#
#   detect-orchestrator-pid [<comm-name>]
#     Walks the process-ancestor chain and prints the PID of the nearest
#     ancestor whose `comm` matches <comm-name> (default `claude`). Empty
#     stdout if no match. Used to bootstrap SHIPYARD_ORCHESTRATOR_PID.
#
#   derive-session-id --repo-root <path>
#     Issue #513 — recover THIS session's id from disk when the per-call
#     env var doesn't persist (each Bash tool call is hermetic — see
#     setup.md step 0.55). Reads `.shipyard-session-id` from the orchestrator
#     worktree under <repo-root>/.claude/worktrees/orchestrator-*.
#
#     The naive `git worktree list --porcelain | awk '...; exit'` derive
#     picked the FIRST orchestrator-* worktree in listing order, which is
#     the OLDEST orphan when prior crashed sessions left their
#     `orchestrator-<dead-id>` worktrees un-reaped. That misattributed every
#     `session-state.sh` write to a dead orphan's session file (same-repo, so
#     the --expected-repo guard did not catch it).
#
#     This subcommand instead selects the NEWEST `orchestrator-*` worktree by
#     directory mtime — the live session's worktree was just created in
#     setup.md step 0.5, so among coexisting orchestrator worktrees it is the
#     most recently created. Strictly better than first-by-listing-order: it
#     resolves to the live session even when orphans accumulate.
#
#     Stdout: the session id (contents of the chosen worktree's
#       `.shipyard-session-id`, trailing newline stripped). Empty stdout when
#       no orchestrator worktree exists or none carries a readable stash.
#     Exit codes:
#       0  a session id was printed, OR no candidate was found (empty stdout —
#          the caller decides what an empty result means)
#       64 bad usage (missing required flag, unknown flag)
#
#   find-orphan-orchestrators --repo-root <path> --current-session-id <id>
#     Issue #280 — companion to step 1.6's orphan session-file sweep, but
#     for the orchestrator worktrees themselves. If a prior /do-work
#     session crashed before reaching cleanup-summary.md step 6, its
#     `.claude/worktrees/orchestrator-<dead-session-id>` directory is
#     never reaped — step 1.6 only reaps session FILES, and setup.md
#     step 3b only reaps `agent-*` worktrees. The session file might also
#     be gone (its prior cleanup got far enough to flush + delete it,
#     just not far enough to reap its own worktree). Either way, the
#     worktree dir lingers indefinitely.
#
#     This subcommand emits one line per orphan orchestrator worktree
#     path, where "orphan" means:
#       (a) name matches `.claude/worktrees/orchestrator-*`, AND
#       (b) embedded session id is NOT the current session id, AND
#       (c) the owning session is INACTIVE — either the session file
#           is missing from $SHIPYARD_HOME/sessions/<id>.json, OR
#           `session-state.sh is-active` returns non-zero (PID dead,
#           unparseable, or null).
#
#     The caller is responsible for the actual `git worktree remove
#     --force` + audit-log write. This helper just enumerates candidates
#     so the discovery logic is testable in isolation.
#
#     Env vars:
#       SHIPYARD_HOME — override the session-file lookup root (defaults
#                       to `$HOME/.shipyard`). Mirrors session-state.sh.
#     Exit codes:
#       0  enumeration succeeded (output may be empty)
#       64 bad usage (missing required flag)
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
#       2. If no live worktree → delete via `git branch -D` and write
#          one JSONL audit line to $SHIPYARD_HOME/reap-audit.jsonl.
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
#       One `reaped-branch: <branch-name>` line per deleted branch (both
#       live and dry-run). Empty stdout when nothing was reaped.
#     Exit codes:
#       0  sweep succeeded (output may be empty)
#       64 bad usage (missing required flag, unknown flag)
#
#   reap-session-worktrees --repo-root <path> --session-id <id>
#        [--agent-id <id> ...] [--dry-run]
#     Issue #509 — targeted reap of THIS session's agent worktrees by
#     explicit agent-id, run as the FIRST pass at end-of-session cleanup
#     BEFORE the generic `.git/worktrees/agent-*` sweep.
#
#     The generic sweep (cleanup-summary.md step 3) iterates every
#     `.git/worktrees/agent-*` and runs `classify-lock` per worktree. On a
#     busy checkout with many accumulated cross-session agent worktrees, the
#     loop can be slow enough that it does NOT complete within the
#     orchestrator's bash window — reaping a few and stalling before the
#     post-loop counters print, stranding THIS session's own shipped
#     worktrees (the ones holding real merged work whose branches are
#     `[gone]` — the most important to reap). See #509 for the repro
#     (17 agent worktrees, ~6 reaped, then the loop went quiet).
#
#     The orchestrator already knows its OWN session's agent-ids — the union
#     of `reconciled_agent_ids` and the live `in_flight.<slot>.agent_id`
#     values — so it can target them directly rather than depending on the
#     full sweep finishing. Cross-session stragglers are already covered by
#     the next session's setup-3b sweep, so they need not block this
#     session's own reap. This subcommand is bounded by the (small,
#     known) agent-id set, so it always completes regardless of how many
#     unrelated worktrees the checkout has accumulated.
#
#     For each agent-id (passed via repeated `--agent-id` flags AND/OR one
#     id per line on stdin — both sources are unioned and de-duplicated):
#       1. Resolve the worktree dir `<repo-root>/.claude/worktrees/agent-<id>`
#          and its lock file `<repo-root>/.git/worktrees/agent-<id>/locked`.
#       2. Skip silently when the worktree dir doesn't exist (already reaped
#          by the steady-state immediate-reap path, #282 — the common case
#          for `shipped` returns) — emits no line for a non-existent dir.
#       3. `classify-lock` the lock file. Reap on
#          `no-lock`/`dead`/`self-ancestor` (routes through the `reap`
#          transaction so the audit line is written with
#          `phase: "cleanup-session-targeted"`); defer on `peer-alive`
#          (a still-running peer — same safety posture as the generic sweep).
#       4. Emit one status line per acted-upon agent-id:
#            `reaped: agent-<id>`     (worktree removed)
#            `deferred: agent-<id>`   (peer-alive — left for a later sweep)
#
#     The SHIPYARD_ORCHESTRATOR_PID env var (set by the orchestrator at
#     session start) flows through to `classify-lock` so the self-ancestor
#     short-circuit fires for this session's own locks — exactly as the
#     generic sweep relies on it.
#
#     --dry-run mode emits the `reaped:`/`deferred:` lines WITHOUT removing
#     worktrees or writing audit-log entries.
#
#     Env vars:
#       SHIPYARD_HOME              — audit-log root (defaults to
#                                    `$HOME/.shipyard`).
#       SHIPYARD_ORCHESTRATOR_PID  — passed through to classify-lock for the
#                                    self-ancestor short-circuit.
#     Stdout:
#       One `reaped: agent-<id>` / `deferred: agent-<id>` line per
#       acted-upon agent-id. Empty stdout when no targeted worktree exists
#       (all already reaped by the steady-state path).
#     Exit codes:
#       0  sweep succeeded (output may be empty)
#       64 bad usage (missing required flag, unknown flag)
#
#   reap --action <reaped|deferred|reaped-orphan-orchestrator>
#        --worktree-path <path> --worktree-name <name>
#        --session-id <id> [--actor-pid <pid>]
#        [--classification <c>] [--reason <r>] [--lock-pid <pid>]
#        [--reaped-session-id <id>] [--phase <p>]
#        [--skip-remove]
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
  worktree-reap.sh detect-orchestrator-pid [<comm-name>]
  worktree-reap.sh derive-session-id --repo-root <path>
  worktree-reap.sh find-orphan-orchestrators --repo-root <path> \
                                             --current-session-id <id>
  worktree-reap.sh reap-orphan-branches --repo-root <path> \
                                        --session-id <id> [--dry-run]
  worktree-reap.sh reap-session-worktrees --repo-root <path> \
                                          --session-id <id> \
                                          [--agent-id <id> ...] [--dry-run]
  worktree-reap.sh report-unreaped --repo-root <path> \
                                   [--current-session-id <id>]
  worktree-reap.sh reap --action <reaped|deferred|reaped-orphan-orchestrator> \
                        --worktree-path <path> --worktree-name <name> \
                        --session-id <id> [--actor-pid <pid>] \
                        [--classification <c>] [--reason <r>] \
                        [--lock-pid <pid|null>] \
                        [--reaped-session-id <id>] [--phase <p>] \
                        [--skip-remove] [--force-evidence <reason>]

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
                          vocabulary as classify-lock.

reap-stale                — Issue #836 fix 2. Bounded, checkpointed sweep
                          built on classify-all: reaps at most
                          --max-per-session (default 10) reap-eligible
                          worktrees, oldest-first, defers peer-alive ones,
                          and leaves the remainder on disk — the on-disk
                          backlog itself is the checkpoint, so a later
                          session picks up where this one left off with no
                          separate state file. --exclude-agent-id (repeat)
                          skips a worktree entirely before classification
                          is even consulted (issue #832 in-flight guard —
                          branch name is never a liveness signal). Emits
                          reaped:/unreaped:/deferred: lines plus one
                          `summary: reaped=<R> deferred=<D> unreaped=<U>
                          remaining=<REMAIN>` line. --dry-run skips
                          removes and audit writes.

detect-orchestrator-pid — Walks the process-ancestor chain and prints the
                          PID of the nearest ancestor whose `comm` matches
                          <comm-name> (default `claude`). Empty stdout if
                          no match. Useful for bootstrapping
                          SHIPYARD_ORCHESTRATOR_PID in shell snippets that
                          want classify-lock to short-circuit reliably.

derive-session-id       — Issue #513. Prints THIS session's id by reading
                          `.shipyard-session-id` from the NEWEST-by-mtime
                          `orchestrator-*` worktree under
                          <repo-root>/.claude/worktrees. Picking newest (not
                          first-in-listing-order) resolves to the live session
                          even when prior crashed sessions left orphan
                          orchestrator worktrees behind. Empty stdout (exit 0)
                          when no candidate carries a readable stash.

find-orphan-orchestrators — Emits one path per line for each orphan
                          orchestrator worktree under
                          <repo-root>/.claude/worktrees/orchestrator-*
                          whose embedded session id is NOT
                          <current-session-id> AND whose owning session
                          is inactive (session file missing OR PID dead).
                          Empty stdout when there are no orphans.

reap-orphan-branches    — Issue #326. Deletes every local worktree-agent-*
                          branch whose branch ref has no live worktree
                          pointing to it (per `git worktree list
                          --porcelain`). Writes one JSONL audit line to
                          $SHIPYARD_HOME/reap-audit.jsonl per deletion.
                          --dry-run emits reaped-branch: lines without
                          deleting or writing the audit log. Idempotent —
                          second pass is a no-op.

reap-session-worktrees  — Issue #509. Targeted reap of THIS session's agent
                          worktrees by explicit agent-id, run as the FIRST
                          pass at end-of-session cleanup before the generic
                          .git/worktrees/agent-* sweep — so a slow generic
                          sweep on a busy checkout can't strand this
                          session's own shipped worktrees. Reaps on
                          no-lock/dead/self-ancestor, defers on peer-alive.
                          Emits reaped: agent-<id> / deferred: agent-<id>
                          per acted-upon agent-id. --dry-run skips removes
                          and audit writes. Issue #712: a worktree whose
                          removal did NOT happen emits `unreaped: agent-<id>`
                          instead of `reaped:` — the status line reports the
                          verified end state, not the intent.

report-unreaped         — Issue #712. Post-sweep verification. Emits one
                          absolute path per line for every agent-* /
                          orchestrator-* worktree still on disk under
                          <repo-root>/.claude/worktrees after the reap sweeps
                          ran, excluding orchestrator-<current-session-id>
                          (still live, reaped last) and *.reap-dead-* scratch
                          dirs (already pruned; background unlink in flight).
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
                          the printf >> $REAP_AUDIT_LOG line.
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
                            reaped-failed        — issue #712. Emitted in
                                                    place of `reaped` when
                                                    the remove did NOT
                                                    happen; carries a
                                                    `reason` (
                                                    unsafe-to-force-unpushed-work
                                                    | worktree-remove-failed).
                                                    Never swallowed.
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

Env vars:
  SHIPYARD_ORCHESTRATOR_PID  Explicit orchestrator PID for self-ancestor
                             short-circuit (classify-lock). Overridden by
                             --orchestrator-pid.
  SHIPYARD_HOME              Override session-file lookup root for
                             find-orphan-orchestrators (defaults to
                             $HOME/.shipyard). Also the root for
                             reap-audit.jsonl writes used by `reap`.

Exit codes:
  0  classification emitted (classify-lock) / PID printed or empty
     (detect-orchestrator-pid) / enumeration succeeded, output may be
     empty (find-orphan-orchestrators) / audit-log write attempted (reap)
  64 usage error (missing path, malformed flag, missing required flag)
EOF
}

# Extract the lock PID from a lock file.
#
# Lock-file format (set by the Claude Code harness):
#   claude agent <agent-id> (pid <N>)
#
# Returns the numeric PID on stdout, or empty string if no PID can be parsed.
# Robust to: missing file, malformed content, multiple PID-like tokens (takes
# the first one — the harness format only ever has one).
extract_lock_pid() {
  local lock_file="$1"
  [ -f "$lock_file" ] || return 0
  # `\(pid <N>\)` is the canonical shape. The grep below matches `pid <N>)`
  # and strips the trailing `)`; matches `<N>)` for the first decimal
  # sequence followed by a close-paren.
  grep -oE '[0-9]+\)' "$lock_file" 2>/dev/null | tr -d ')' | head -1
}

# Is `pid` alive? Returns 0 (alive) / 1 (dead-or-unknown).
pid_alive() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  ps -p "$pid" -o pid= >/dev/null 2>&1
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

# Walk our own ancestor chain looking for a process whose comm matches the
# Claude Code orchestrator (default: literal `claude`). Emits the matched PID
# on stdout (empty if no match found). Used by the `detect-orchestrator-pid`
# subcommand and by `classify-lock`'s lazy auto-detect path to bootstrap the
# `SHIPYARD_ORCHESTRATOR_PID` short-circuit when callers haven't set it
# explicitly.
#
# The match is intentionally narrow: if the Claude Code binary is renamed,
# this detection returns empty and callers fall back to the ancestor-walk
# semantics inside `classify-lock`. False matches (a foreign `claude` process
# in the chain) are extremely unlikely — process names in the ancestor chain
# of a bash spawned by Claude Code are bash, sh, claude, login, etc. The risk
# threshold is low because a detected PID only short-circuits to
# `self-ancestor` when it EXACTLY matches the lock PID; a wrong detection
# only matters if it coincidentally matches a foreign live PID (negligible
# probability).
detect_orchestrator_pid() {
  local match_comm="${1:-claude}"
  local pid=$$
  local guard=0
  local comm
  while [ -n "$pid" ] && [ "$pid" != "1" ] && [ "$pid" != "0" ]; do
    guard=$((guard + 1))
    [ "$guard" -gt 64 ] && return 0
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')
    # `comm` on macOS returns the full executable path; basename it for the match.
    comm=$(basename "$comm" 2>/dev/null)
    if [ "$comm" = "$match_comm" ]; then
      echo "$pid"
      return 0
    fi
    local parent
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$parent" ] && return 0
    [ "$parent" = "$pid" ] && return 0
    pid="$parent"
  done
}

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

  # Lock file exists but has no parseable PID — treat as dead (the original
  # semantics didn't trip the liveness check either when extraction failed).
  if [ -z "$lock_pid" ]; then
    echo "dead"
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
  local d name lock_file content pid
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    name="${d##*/}"
    names+=("$name")
    lock_file="$git_wt_dir/$name/locked"
    if [ -f "$lock_file" ]; then
      lock_exists+=("1")
      content=$(<"$lock_file")
      if [[ "$content" =~ \(pid[[:space:]]+([0-9]+)\) ]]; then
        pid="${BASH_REMATCH[1]}"
      else
        pid=""
      fi
    else
      lock_exists+=("0")
      pid=""
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

  # Pass 5 — classify each worktree from the in-memory data built above.
  # Only a peer-alive candidate (alive, not self/ancestor) pays a per-lock
  # `stat` call, for the staleness gate — every other branch is pure
  # in-memory lookup / pattern match.
  local out_lines=()
  local i found_mtime j classification
  for ((i = 0; i < ${#names[@]}; i++)); do
    name="${names[$i]}"
    pid="${lock_pids[$i]}"
    classification=""
    if [ "${lock_exists[$i]}" = "0" ]; then
      classification="no-lock"
    elif [ -z "$pid" ]; then
      classification="dead"
    elif [[ "$alive_blob" == *$'\n'"$pid"$'\n'* ]]; then
      if [ -n "$orchestrator_pid" ] && [ "$pid" = "$orchestrator_pid" ]; then
        classification="self-ancestor"
      elif [[ "$self_ancestor_blob" == *$'\n'"$pid"$'\n'* ]]; then
        classification="self-ancestor"
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
    else
      classification="dead"
    fi

    # Linear-scan lookup of this worktree's directory mtime by name.
    found_mtime="0"
    for ((j = 0; j < ${#stat_names[@]}; j++)); do
      if [ "${stat_names[$j]}" = "$name" ]; then
        found_mtime="${stat_mtimes[$j]}"
        break
      fi
    done

    out_lines+=("$found_mtime $name $classification ${pid:-null}")
  done

  # Emit sorted oldest-first by worktree-dir mtime (numeric sort on the
  # leading field), then drop that sort key from the printed line.
  printf '%s\n' "${out_lines[@]}" | sort -n -k1,1 | while IFS= read -r line; do
    printf '%s\n' "${line#* }"
  done

  return 0
}

# Issue #513 — recover THIS session's id from disk by reading the
# `.shipyard-session-id` stash out of the orchestrator's own worktree.
#
# Background: setup.md step 0.55 stashes the session id at
# `<orch-worktree>/.shipyard-session-id` and re-reads it at the top of every
# Bash tool call, because the harness's per-call shells are hermetic (an
# `export SESSION_ID=...` in call N is invisible in call N+1). The original
# porcelain-derive used `awk '... {print p; exit}'` to find the orchestrator
# worktree, which returns the FIRST `orchestrator-*` entry in listing order.
# When prior crashed sessions left their `orchestrator-<dead-id>` worktrees
# un-reaped, "first in listing order" is the OLDEST orphan — so the derive
# read a dead orphan's stash and every `session-state.sh` write landed in
# the orphan's session file (same repo, so `--expected-repo` never tripped).
#
# Fix: select the NEWEST `orchestrator-*` worktree by directory mtime. The
# live session's worktree was created in step 0.5 (this run), so among any
# set of coexisting orchestrator worktrees it is the most recently created.
# Newest-by-mtime is a heuristic, but strictly better than first-by-listing-
# order: it resolves to the live session whenever orphans coexist, and is a
# no-op (single candidate) in the common case of exactly one orchestrator
# worktree.
#
# We deliberately do NOT use `git worktree list` here — `git rev-parse`/`git
# worktree list` are cwd-sensitive and the harness can relocate the
# orchestrator's Bash cwd into a just-returned agent worktree (#477). A
# direct filesystem glob of `<repo-root>/.claude/worktrees/orchestrator-*`
# is cwd-independent given the explicit `--repo-root`.
#
# Stdout: the session id (stash contents, trailing whitespace stripped), or
#   empty when no candidate exists or none has a readable stash.
# Exit: 0 (printed or empty), 64 on bad usage.
derive_session_id() {
  local repo_root=""

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
      --)
        shift
        ;;
      -*)
        echo "derive-session-id: unknown flag: $1" >&2
        return 64
        ;;
      *)
        echo "derive-session-id: unexpected positional arg: $1" >&2
        return 64
        ;;
    esac
  done

  if [ -z "$repo_root" ]; then
    echo "derive-session-id: --repo-root is required" >&2
    return 64
  fi

  local orch_root="$repo_root/.claude/worktrees"
  # No worktrees dir at all → nothing to derive. Empty stdout, exit 0.
  [ -d "$orch_root" ] || return 0

  # Walk every orchestrator-* worktree and keep the one with the newest
  # directory mtime that also carries a readable, non-empty stash. We require
  # the stash to be present so a candidate without one (a half-set-up or
  # already-cleaned worktree) never wins over an older worktree that DOES
  # have the id — correctness beats recency when recency has no id to offer.
  local entry newest_mtime="" newest_id="" mtime stash id
  for entry in "$orch_root"/orchestrator-*; do
    # No-glob-match fallthrough: bash leaves the literal pattern when nothing
    # matches. Guard with `-d` so we silently skip.
    [ -d "$entry" ] || continue

    stash="$entry/.shipyard-session-id"
    [ -f "$stash" ] || continue
    # Strip surrounding whitespace/newlines from the stash contents.
    id="$(tr -d '[:space:]' < "$stash" 2>/dev/null)"
    [ -n "$id" ] || continue

    # Portable mtime: GNU `stat -c %Y` and BSD/macOS `stat -f %m` differ, so
    # try both. Fall back to 0 (oldest) if neither works, so a stat-less
    # platform still picks *a* candidate deterministically (the last one
    # scanned among those tied at 0).
    mtime="$(stat -c %Y "$entry" 2>/dev/null || stat -f %m "$entry" 2>/dev/null || echo 0)"

    if [ -z "$newest_mtime" ] || [ "$mtime" -ge "$newest_mtime" ] 2>/dev/null; then
      newest_mtime="$mtime"
      newest_id="$id"
    fi
  done

  [ -n "$newest_id" ] && printf '%s\n' "$newest_id"
  return 0
}

# Issue #280 — discover orphan orchestrator worktrees from prior crashed
# sessions. Companion to setup.md step 1.6 (which reaps orphan session
# FILES) and step 3b (which reaps `agent-*` worktrees). Neither covers
# the `.claude/worktrees/orchestrator-<dead-session-id>` case.
#
# An orphan, for this helper's purposes, is a worktree directory whose
# basename matches `orchestrator-*` AND whose embedded session id is
# NOT the current session AND whose owning session is inactive (file
# missing OR PID dead). The "or" branch matters: a prior session that
# crashed AFTER session-state cleanup but BEFORE worktree reap (step 7
# → step 6 reordering in cleanup-summary.md) leaves no session file
# behind, but the worktree dir still exists.
#
# We emit paths instead of reaping in-place so:
#   1. The caller controls the audit-log shape (the spec wants
#      action: "reaped-orphan-orchestrator" with phase: "setup-3b-orch").
#   2. The discovery logic is independently testable.
#   3. A dry-run mode comes for free — the caller can choose to log
#      candidates without acting on them.
#
# Output: one absolute path per line, no surrounding quoting. Paths
# always exist at emit time (we filter against `-d` before printing).
# Empty stdout when there are no orphans.
find_orphan_orchestrators() {
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
      --)
        shift
        ;;
      -*)
        echo "find-orphan-orchestrators: unknown flag: $1" >&2
        return 64
        ;;
      *)
        echo "find-orphan-orchestrators: unexpected positional arg: $1" >&2
        return 64
        ;;
    esac
  done

  if [ -z "$repo_root" ]; then
    echo "find-orphan-orchestrators: --repo-root is required" >&2
    return 64
  fi
  if [ -z "$current_session_id" ]; then
    echo "find-orphan-orchestrators: --current-session-id is required" >&2
    return 64
  fi

  local orch_root="$repo_root/.claude/worktrees"
  # No worktrees dir at all → no orphans. Exit cleanly with empty output
  # rather than erroring; a brand-new repo or one that's never run
  # /do-work has nothing to reap.
  [ -d "$orch_root" ] || return 0

  local shipyard_home="${SHIPYARD_HOME:-$HOME/.shipyard}"
  local sessions_dir="$shipyard_home/sessions"

  # Resolve the helper script path so we can call `session-state.sh
  # is-active` against each candidate. This script lives alongside it.
  local self_dir
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local session_state_sh="$self_dir/session-state.sh"

  local entry name session_id session_file
  for entry in "$orch_root"/orchestrator-*; do
    # No-glob-match fallthrough: bash leaves the literal pattern when
    # nothing matches. Guard with `-d` so we silently skip.
    [ -d "$entry" ] || continue

    name=$(basename "$entry")
    # Strip the `orchestrator-` prefix to recover the session id.
    session_id="${name#orchestrator-}"

    # Skip our own worktree — never reap the running session out from
    # under itself.
    [ "$session_id" = "$current_session_id" ] && continue

    session_file="$sessions_dir/$session_id.json"

    # Inactive ≡ (file missing) OR (file present AND is-active exits non-zero).
    # File-missing is the common case for the bug report (#280): the
    # prior session's step 7→8 cleanup ran before its step 6 worktree
    # reap, so its session file is gone but its worktree lingers.
    if [ ! -f "$session_file" ]; then
      printf '%s\n' "$entry"
      continue
    fi

    # File present — defer to session-state.sh is-active for the PID
    # liveness check. If is-active is unavailable (script missing,
    # somehow), fall back to "present file means active" — the
    # conservative choice that preserves a still-running peer.
    if [ ! -x "$session_state_sh" ] && [ ! -f "$session_state_sh" ]; then
      continue
    fi
    if bash "$session_state_sh" is-active --session-id "$session_id" 2>/dev/null; then
      # Owning process is alive — skip.
      continue
    fi
    # File present but PID dead/unparseable → orphan.
    printf '%s\n' "$entry"
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
#   4. rm -rf <wt>.reap-dead-... &           (backgrounded bulk delete — the
#                                             only expensive step, detached so
#                                             it can't stall the caller)
#
# Steps 1-3 are synchronous and fast (a rename + a prune, independent of the
# tree size); only the recursive unlink is backgrounded. Note the fast path
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
# Returns 0 when the directory is no longer at <worktree_path> (renamed away
# or removed); returns 1 when the directory still exists after every attempt,
# so callers that need a last-resort escalation (the orphan-orchestrator raw
# rm -rf path) — or that need to record an unreaped worktree (#712) — can
# detect that the fast path declined.
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
  # an instant relink, then prune to free the branch, then background the
  # recursive unlink. `$$` + epoch keeps the scratch name unique across
  # concurrent reaps.
  local dead_epoch dead_path
  dead_epoch=$(date +%s 2>/dev/null || echo 0)
  dead_path="${worktree_path}.reap-dead-$$-${dead_epoch}"
  if mv "$worktree_path" "$dead_path" 2>/dev/null; then
    git worktree prune 2>/dev/null || true
    # Detach the bulk delete so it outlives this short-lived shell without
    # job-control chatter; it reparents to init on shell exit and finishes.
    rm -rf "$dead_path" >/dev/null 2>&1 &
    disown 2>/dev/null || true
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
    echo "reap: --action is required" >&2
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
  local shipyard_home="${SHIPYARD_HOME:-$HOME/.shipyard}"
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
    *)
      echo "reap: unknown --action: $action" >&2
      return 64
      ;;
  esac

  return 0
}

# Issue #326 — reap stale worktree-agent-* local branch refs.
#
# The Claude Code harness creates one `worktree-agent-<id>` branch per agent
# dispatched with `isolation: "worktree"`. It reaps the worktree DIRECTORY
# but never deletes the branch REF, which accumulates indefinitely (119 stale
# refs observed on a machine that ran /shipyard:do-work a few times).
#
# Algorithm:
#   1. Enumerate local branches matching `worktree-agent-*` via
#      `git for-each-ref --format='%(refname:short)' refs/heads/worktree-agent-*`.
#   2. Build the set of branch names currently referenced by a live worktree
#      by parsing `git worktree list --porcelain` (look for `branch refs/heads/<b>`).
#   3. For each branch in (1) that is NOT in (2): delete it with
#      `git branch -D` and write one JSONL audit line.
#   4. Skip deletion (and audit) in --dry-run mode.
#
# The function runs in whatever cwd was set by the caller (which is expected
# to be the repo root). It does not `cd` itself — the caller is responsible for
# being in the correct git repo before invoking this helper.
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
  local shipyard_home="${SHIPYARD_HOME:-$HOME/.shipyard}"
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

    # Orphan branch — emit the reaped-branch line.
    printf 'reaped-branch: %s\n' "$branch"

    if [ "$dry_run" -eq 0 ]; then
      # Delete the branch ref. `git branch -D` works even when not on the
      # branch being deleted. Redirect stdout so the "Deleted branch ..."
      # confirmation line from git doesn't pollute our reaped-branch: output.
      # Errors are non-fatal (e.g., the branch was deleted in a concurrent
      # run) — fire-and-forget.
      git -C "$repo_root" branch -D "$branch" >/dev/null 2>&1 || true

      # Audit log entry.
      printf '%s\n' \
        "{\"ts\":\"$ts\",\"session\":\"$session_id\",\"actor_pid\":$actor_pid,\"branch\":\"$branch\",\"action\":\"reaped-orphan-branch\",\"reason\":\"no-live-worktree\"}" \
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
reap_session_worktrees() {
  local repo_root=""
  local session_id=""
  local dry_run=0
  local -a agent_ids=()

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
      --agent-id)
        [ -n "${2:-}" ] && agent_ids+=("$2")
        shift 2
        ;;
      --agent-id=*)
        local _aid="${1#--agent-id=}"
        [ -n "$_aid" ] && agent_ids+=("$_aid")
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --)
        shift
        ;;
      -*)
        echo "reap-session-worktrees: unknown flag: $1" >&2
        return 64
        ;;
      *)
        echo "reap-session-worktrees: unexpected positional arg: $1" >&2
        return 64
        ;;
    esac
  done

  if [ -z "$repo_root" ]; then
    echo "reap-session-worktrees: --repo-root is required" >&2
    return 64
  fi
  if [ -z "$session_id" ]; then
    echo "reap-session-worktrees: --session-id is required" >&2
    return 64
  fi

  # Anchor cwd to the target repo root. `reap_action` (which we route the
  # actual `git worktree remove --force` through) runs bare `git worktree
  # remove`, which is cwd-dependent — it operates on whatever repo the cwd
  # resolves to. The generic sweep in cleanup-summary.md step 3 `cd`s into
  # the repo root for the same reason. This helper is a short-lived process
  # invocation, so changing its own cwd is local and harmless to the caller.
  if ! cd "$repo_root" 2>/dev/null; then
    echo "reap-session-worktrees: cannot cd to --repo-root: $repo_root" >&2
    return 64
  fi

  # Union stdin-fed agent-ids (one per line) with the --agent-id flags.
  # Read stdin only when it is not a terminal so an interactive invocation
  # without piped input doesn't block.
  if [ ! -t 0 ]; then
    local _line
    while IFS= read -r _line; do
      # Trim surrounding whitespace; skip blank lines.
      _line="${_line#"${_line%%[![:space:]]*}"}"
      _line="${_line%"${_line##*[![:space:]]}"}"
      [ -z "$_line" ] && continue
      agent_ids+=("$_line")
    done
  fi

  # Nothing to do — no agent-ids supplied at all. Empty stdout, exit 0.
  [ "${#agent_ids[@]}" -eq 0 ] && return 0

  # De-duplicate agent-ids while preserving first-seen order. The
  # reconciled-set ∪ in-flight-set the orchestrator passes can legitimately
  # overlap (a slot reconciled then re-counted), and reaping the same path
  # twice would emit a duplicate status line. `seen_csv` is a sentinel-bounded
  # membership string so we don't need an inner array loop under `set -u`.
  local seen_csv="|"
  local aid
  for aid in "${agent_ids[@]}"; do
    case "$seen_csv" in
      *"|$aid|"*) continue ;;   # already processed
    esac
    seen_csv="${seen_csv}${aid}|"

    local name="agent-${aid}"
    local worktree_path="$repo_root/.claude/worktrees/$name"
    local lock_file="$repo_root/.git/worktrees/$name/locked"

    # Already reaped (the common case for `shipped` returns — the
    # steady-state immediate-reap path #282 removed it mid-session). Skip
    # silently — no line, no error.
    [ -d "$worktree_path" ] || continue

    local classification
    classification=$(classify_lock "$lock_file")

    # Extract the lock PID for the audit line (null literal when missing /
    # unparseable). `extract_lock_pid` already returns a bare numeric PID
    # or empty string.
    local lock_pid
    lock_pid=$(extract_lock_pid "$lock_file")
    [ -z "$lock_pid" ] && lock_pid="null"

    if [ "$classification" = "peer-alive" ]; then
      # A still-running peer holds the lock — defer, same posture as the
      # generic sweep. Left for step B / A.0.5 / next-session setup-3b.
      printf 'deferred: %s\n' "$name"
      if [ "$dry_run" -eq 0 ]; then
        reap_action \
          --action deferred \
          --worktree-path "$worktree_path" \
          --worktree-name "$name" \
          --session-id "$session_id" \
          --reason "peer-alive" \
          --phase "cleanup-session-targeted" \
          --lock-pid "$lock_pid" \
          >/dev/null 2>&1 || true
      fi
      continue
    fi

    # no-lock / dead / self-ancestor — safe to reap.
    if [ "$dry_run" -eq 1 ]; then
      printf 'reaped: %s\n' "$name"
      continue
    fi

    reap_action \
      --action reaped \
      --worktree-path "$worktree_path" \
      --worktree-name "$name" \
      --session-id "$session_id" \
      --classification "$classification" \
      --phase "cleanup-session-targeted" \
      --lock-pid "$lock_pid" \
      >/dev/null 2>&1 || true

    # Issue #712 — report what ACTUALLY happened, not what we intended. The
    # status line used to print `reaped:` before the removal even ran, so a
    # removal that failed still incremented the caller's reaped counter and
    # the leftover worktree went unnoticed. Probe the path: still there ⇒
    # `unreaped:`, which the end-of-session summary surfaces with the
    # `/clean_gone` remediation.
    if [ -e "$worktree_path" ]; then
      printf 'unreaped: %s\n' "$name"
    else
      printf 'reaped: %s\n' "$name"
    fi
  done

  return 0
}

# Issue #836 fix 2 — bound + checkpoint the cross-session stale-worktree
# sweep. Built on top of `classify_all` (fix 1) so the whole sweep — batch
# classify AND bounded reap — happens in one subcommand invocation instead
# of the caller open-coding a loop in the spec's bash block.
#
# The problem this closes: step 3b's sweep has to walk EVERY `agent-*`
# worktree still on disk, including a large backlog accumulated from prior
# crashed sessions or sessions that predate the per-completion reap fixes
# (#282/#334/#771). `git worktree remove` (even the #664 fast rename-aside
# path) still costs a handful of subprocess forks per worktree, so an
# unbounded sweep over a 60-worktree backlog can still outrun a session's
# time budget. `reap-stale` caps how many it actually reaps THIS session
# (oldest-first, `--max-per-session`, default matches
# `worktree_reap.max_per_session` from shipyard-config.sh) and leaves the
# rest untouched on disk for a subsequent session to continue — no separate
# checkpoint FILE is needed, because "which worktrees are still on disk" IS
# the checkpoint: each session that runs this sweep removes up to K more of
# the oldest remaining ones, so the backlog shrinks monotonically session
# over session even though no single session clears it in one pass.
#
# Excludes any worktree whose agent-id is in the caller-supplied in-flight
# set (--exclude-agent-id, repeatable) BEFORE classification is even
# consulted — a currently-dispatched slot's worktree must never be reaped
# regardless of what its lock classifies as (issue #832; branch name is
# never a liveness signal — see commands/do-work/dont.md).
#
# Algorithm:
#   1. classify_all (already oldest-first by worktree-dir mtime).
#   2. Skip any name in the exclude set entirely (no line emitted).
#   3. peer-alive → deferred (not counted against the cap; always deferred).
#   4. no-lock / dead / self-ancestor / peer-alive-stale → reap, up to
#      --max-per-session of them (oldest first, since input is pre-sorted).
#      Beyond the cap: left untouched, counted into the `remaining` total
#      printed in the summary line — this session's forward progress.
#
# Output: one `reaped: <name>` / `unreaped: <name>` (issue #712 — reports
# the VERIFIED end state, not the intent) / `deferred: <name>` line per
# acted-upon worktree, followed by exactly one summary line:
#   summary: reaped=<R> deferred=<D> remaining=<REMAIN>
# `remaining` is the count of reap-eligible worktrees that were left on disk
# because the cap was reached — the backlog a future session will continue
# from. Empty-but-summary stdout (`summary: reaped=0 deferred=0 remaining=0`)
# when there are no agent-* worktrees at all.
#
# --dry-run emits the same lines/summary WITHOUT removing anything or
# writing audit-log entries (mirrors reap-session-worktrees' --dry-run).
#
# Args:
#   --repo-root <path>          (required)
#   --session-id <id>           (required) — passed through to reap_action
#   --max-per-session <K>       (optional, default 10)
#   --exclude-agent-id <id>     (optional, repeatable) — bare agent-id, NOT
#                                the `agent-<id>` worktree name
#   --orchestrator-pid <N>      (optional) — passed through to classify_all
#   --peer-stale-min <N>        (optional) — passed through to classify_all
#   --dry-run                   (optional)
#
# Exit codes: 0 (sweep succeeded, output may be summary-only), 64 (bad usage).
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

  # Build the exclude set (bare agent-ids -> agent-<id> worktree names) as a
  # sentinel-delimited string for membership checks — bash-3.2 compatible
  # (no associative arrays), same pattern reap_session_worktrees' `seen_csv`
  # already uses in this file.
  local excluded_blob="|"
  local eid
  # `${arr[@]+"${arr[@]}"}` is the bash-3.2-safe expansion for "possibly
  # empty array under set -u" — bash < 4.4 treats a bare `"${arr[@]}"` on a
  # zero-element array as an unbound-variable error under `set -u`, and
  # --exclude-agent-id is commonly omitted entirely (no in-flight workers).
  for eid in "${exclude_ids[@]+"${exclude_ids[@]}"}"; do
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

    if [ "$classification" = "peer-alive" ]; then
      printf 'deferred: %s\n' "$name"
      deferred_count=$((deferred_count + 1))
      if [ "$dry_run" -eq 0 ]; then
        reap_action \
          --action deferred \
          --worktree-path "$worktree_path" \
          --worktree-name "$name" \
          --session-id "$session_id" \
          --reason "peer-alive" \
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
      remaining_count=$((remaining_count + 1))
      continue
    fi
    attempt_count=$((attempt_count + 1))

    if [ "$dry_run" -eq 1 ]; then
      printf 'reaped: %s\n' "$name"
      reaped_count=$((reaped_count + 1))
      continue
    fi

    reap_action \
      --action reaped \
      --worktree-path "$worktree_path" \
      --worktree-name "$name" \
      --session-id "$session_id" \
      --classification "$classification" \
      --phase "setup-3b" \
      --lock-pid "$pid" \
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

  printf 'summary: reaped=%s deferred=%s unreaped=%s remaining=%s\n' \
    "$reaped_count" "$deferred_count" "$unreaped_count" "$remaining_count"

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
    detect-orchestrator-pid)
      # Emit the PID of the nearest ancestor whose `comm` is `claude` (or
      # the override passed as the first arg). Empty stdout on no match.
      # Exit 0 whether or not a match was found — the caller decides what
      # to do with an empty result.
      shift
      detect_orchestrator_pid "${1:-claude}"
      ;;
    derive-session-id)
      # Issue #513 — recover THIS session's id from the newest-by-mtime
      # orchestrator-* worktree's `.shipyard-session-id` stash, so the
      # derive resolves to the live session rather than the oldest orphan.
      # See the derive_session_id function's docstring for the algorithm.
      shift
      derive_session_id "$@"
      ;;
    find-orphan-orchestrators)
      # Issue #280 — enumerate orphan `orchestrator-*` worktrees from
      # prior crashed sessions. See the find_orphan_orchestrators
      # function's docstring for the orphan definition.
      shift
      find_orphan_orchestrators "$@"
      ;;
    reap-orphan-branches)
      # Issue #326 — delete stale worktree-agent-* branch refs that have
      # no live worktree referencing them. See reap_orphan_branches for the
      # full algorithm.
      shift
      reap_orphan_branches "$@"
      ;;
    reap-session-worktrees)
      # Issue #509 — targeted reap of THIS session's agent worktrees by
      # explicit agent-id, run before the generic sweep so a slow generic
      # sweep can't strand this session's own shipped worktrees. See
      # reap_session_worktrees for the full algorithm.
      shift
      reap_session_worktrees "$@"
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
