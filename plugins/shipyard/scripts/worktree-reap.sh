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
#       no-lock        — lock file doesn't exist (safe to reap)
#       dead           — lock PID is dead (safe to reap, original semantics)
#       self-ancestor  — lock PID is alive AND is either (a) the declared
#                        orchestrator PID (via `SHIPYARD_ORCHESTRATOR_PID`
#                        env var or `--orchestrator-pid` flag) or (b) our
#                        own / an ancestor of ours (safe to reap — orchestrator
#                        owns this lock)
#       peer-alive     — lock PID is alive AND is NOT the declared orchestrator
#                        PID AND is NOT in our ancestor chain (defer — likely
#                        a peer agent or other instance)
#     Env vars:
#       SHIPYARD_ORCHESTRATOR_PID — explicit orchestrator PID. Takes
#                        precedence over the ancestor walk for the
#                        self-ancestor check. Overridden by `--orchestrator-pid`
#                        if both are set.
#     Exit codes:
#       0  classification emitted
#       64 bad usage (missing path, malformed flag value)
#
# Callers should reap on `no-lock` / `dead` / `self-ancestor`, defer on
# `peer-alive`.
#
#   detect-orchestrator-pid [<comm-name>]
#     Walks the process-ancestor chain and prints the PID of the nearest
#     ancestor whose `comm` matches <comm-name> (default `claude`). Empty
#     stdout if no match. Used to bootstrap SHIPYARD_ORCHESTRATOR_PID.
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
#       1. Optionally perform the actual `git worktree remove --force`
#          (skipped when `--skip-remove` is passed — used for "deferred"
#          action, since the worktree isn't actually removed).
#       2. For `reaped-orphan-orchestrator` action: if the worktree-remove
#          fails (typical when the dir is on disk but no longer registered
#          with git — common after a crash), fall back to `rm -rf` and
#          emit the `-raw-rm` action variant in the audit line.
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
#          the helper falls back to rm -rf; for reaped/deferred a failed
#          remove still emits the audit line (the caller decides whether
#          to log success or not). Exit 0 means the audit-line write
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
  worktree-reap.sh detect-orchestrator-pid [<comm-name>]
  worktree-reap.sh find-orphan-orchestrators --repo-root <path> \
                                             --current-session-id <id>
  worktree-reap.sh reap-orphan-branches --repo-root <path> \
                                        --session-id <id> [--dry-run]
  worktree-reap.sh reap-session-worktrees --repo-root <path> \
                                          --session-id <id> \
                                          [--agent-id <id> ...] [--dry-run]
  worktree-reap.sh reap --action <reaped|deferred|reaped-orphan-orchestrator> \
                        --worktree-path <path> --worktree-name <name> \
                        --session-id <id> [--actor-pid <pid>] \
                        [--classification <c>] [--reason <r>] \
                        [--lock-pid <pid|null>] \
                        [--reaped-session-id <id>] [--phase <p>] \
                        [--skip-remove]

classify-lock — Prints one of: no-lock | dead | self-ancestor | peer-alive

detect-orchestrator-pid — Walks the process-ancestor chain and prints the
                          PID of the nearest ancestor whose `comm` matches
                          <comm-name> (default `claude`). Empty stdout if
                          no match. Useful for bootstrapping
                          SHIPYARD_ORCHESTRATOR_PID in shell snippets that
                          want classify-lock to short-circuit reliably.

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
                          and audit writes.

reap                    — Performs the worktree-remove (when applicable)
                          and writes one append-only JSONL line to
                          $SHIPYARD_HOME/reap-audit.jsonl describing the
                          outcome. Issue #284 single source of truth for
                          reap-audit writes — call sites no longer inline
                          the printf >> $REAP_AUDIT_LOG line.
                          Actions:
                            reaped               — successful agent
                                                    worktree reap
                                                    (requires
                                                    --classification,
                                                    --lock-pid).
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

  # Argv parsing: positional <lock-file-path> first, then optional
  # --orchestrator-pid <N>. Flag-after-positional is the typical shape from
  # the orchestrator's call sites (`classify-lock "$wt_dir/locked"
  # --orchestrator-pid $$`); flag-before-positional also accepted.
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
  # ancestor-walk fallback. The --orchestrator-pid flag path already validates
  # above; this guard catches malformed env-var values.
  if [ -n "$orchestrator_pid" ] && ! [[ "$orchestrator_pid" =~ ^[0-9]+$ ]]; then
    echo "classify-lock: SHIPYARD_ORCHESTRATOR_PID must be a non-negative integer (got: $orchestrator_pid)" >&2
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

  echo "peer-alive"
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
      if [ "$skip_remove" -eq 0 ]; then
        # Best-effort unlock first; matches the inline pattern.
        git worktree unlock "$worktree_path" 2>/dev/null || true
        git worktree remove --force "$worktree_path" 2>/dev/null || true
      fi
      emit_line "{\"ts\":$(json_str "$ts"),\"session\":$(json_str "$session_id"),\"actor_pid\":$actor_pid,\"worktree\":$(json_str "$worktree_name"),\"action\":\"reaped\",\"classification\":$(json_str "$classification"),\"lock_pid\":$lock_pid$phase_suffix}"
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
      # Try the structured `git worktree remove --force` path first. On
      # failure (typical when the worktree dir is on disk but no longer
      # registered with git — common after a crash, see #280), fall back
      # to `rm -rf` and emit the `-raw-rm` action variant so the source
      # of the reap stays traceable.
      local actual_action="reaped-orphan-orchestrator"
      if [ "$skip_remove" -eq 0 ]; then
        if ! git worktree remove --force "$worktree_path" 2>/dev/null; then
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
    printf 'reaped: %s\n' "$name"
    if [ "$dry_run" -eq 0 ]; then
      reap_action \
        --action reaped \
        --worktree-path "$worktree_path" \
        --worktree-name "$name" \
        --session-id "$session_id" \
        --classification "$classification" \
        --phase "cleanup-session-targeted" \
        --lock-pid "$lock_pid" \
        >/dev/null 2>&1 || true
    fi
  done

  return 0
}

main() {
  local sub="${1:-}"
  case "$sub" in
    classify-lock)
      shift
      classify_lock "$@"
      ;;
    detect-orchestrator-pid)
      # Emit the PID of the nearest ancestor whose `comm` is `claude` (or
      # the override passed as the first arg). Empty stdout on no match.
      # Exit 0 whether or not a match was found — the caller decides what
      # to do with an empty result.
      shift
      detect_orchestrator_pid "${1:-claude}"
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
