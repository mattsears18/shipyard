#!/usr/bin/env bash
# detect-ci-runner-capacity.sh — read this repo's CI executor capacity: is it
# backed by a self-hosted runner pool (fixed, small), and if so, how many
# runners are online/idle right now, and how deep is the queued-run backlog.
#
# Background (issue #1141)
# -------------------------
# `--concurrency N` bounds how many WORKERS `/shipyard:do-work` runs at once.
# It says nothing about how many CI RUNS those workers generate, or whether
# the repo's CI executor can absorb them. On a repo whose CI runs on a small,
# fixed self-hosted runner pool, worker throughput and CI-landing throughput
# can decouple: the session dispatches happily while the queue behind the
# runners grows without bound. This script is the single executable read of
# that pool's shape, so a session can (a) clamp its effective concurrency
# toward the pool size at startup when it was only asking for the built-in/
# config default, and (b) surface a "queue depth far exceeds pool capacity"
# observation in the end-of-session summary instead of leaving the operator
# to notice N open PRs and guess why they haven't landed.
#
# Usage — live detection (the normal path):
#   bash detect-ci-runner-capacity.sh <owner/repo>
#   bash detect-ci-runner-capacity.sh --repo <owner/repo>   (alias; #1454)
#     -> prints one of, on stdout (single line):
#          hosted
#          self-hosted pool_total=<N> pool_idle=<M> queued=<Q>
#          unknown
#        diagnostics on stderr. Exits 0 whenever the invocation itself was
#        well-formed — this is an advisory read, never a hard failure once
#        it's actually running: an unreadable signal (bad permissions, a
#        nonexistent repo, a transient API error) degrades to `unknown`, it
#        never blocks or fails the caller's setup flow. A malformed
#        INVOCATION — a missing/unrecognized argument, or an <owner/repo>
#        that doesn't have exactly one '/' — is a distinct failure: it exits
#        64 (EX_USAGE) with a `usage:` message on stderr and prints nothing
#        on stdout, rather than silently treating an unexpected token as the
#        repo and reporting a plausible-looking verdict for it (issue
#        #1454 — a caller that passed `run --repo owner/name` used to get
#        `hosted` back for the nonexistent repo "run").
#
#   `hosted`       => no self-hosted runners are registered for this repo.
#                     GitHub-hosted runners are elastic, not a fixed-pool
#                     constraint — nothing to clamp toward.
#   `self-hosted`  => a registered self-hosted runner pool exists.
#                     pool_total = ONLINE runner count (the realistic ceiling
#                     on concurrent CI runs right now); pool_idle = online
#                     AND NOT busy; queued = runs currently queued repo-wide
#                     (an approximate depth signal, not exact — see below).
#   `unknown`      => the runner-pool signal could not be read at all. The
#                     most common cause is that the `gh` token lacks repo
#                     ADMIN on `repos/{owner}/{repo}/actions/runners` (that
#                     endpoint 404s/403s for anything less); a nonexistent
#                     repo hits the same 404 path. Callers MUST NOT clamp on
#                     `unknown` — an unreadable signal is not evidence of a
#                     small pool, only evidence we couldn't look. `unknown`
#                     is distinguished from `hosted` by checking BOTH `gh
#                     api`'s own exit status AND that the response body
#                     actually carries a `.runners` array — `gh api` writes
#                     its JSON error envelope (e.g. `{"message":"Not
#                     Found",...}`) to stdout on a non-2xx response, and jq's
#                     `.runners | length` on a body with no such key
#                     evaluates to 0 (`null | length` is 0), which used to be
#                     indistinguishable from a genuine zero-runner read
#                     (issue #1454).
#
# Usage — pure decision (hermetic, for tests and for callers that already
# hold the three runner-count signals):
#   bash detect-ci-runner-capacity.sh --decide <RUNNER_COUNT> <ONLINE_COUNT> <BUSY_COUNT>
#     -> prints the same `hosted` / `self-hosted pool_total=... pool_idle=...`
#        token shape (never `unknown` — a failed API read is a live-path-only
#        concern, out of scope for the pure decision; queued depth is also
#        live-path-only and is not part of this pure decision).
#
# Usage — pure dispatch-time backpressure decision (issue #1156, hermetic,
# no network calls):
#   bash detect-ci-runner-capacity.sh --decide-backpressure \
#     <POOL_TOTAL> <QUEUED> <IN_FLIGHT> <MULTIPLIER> <MIN_IN_FLIGHT>
#     -> prints "hold" or "dispatch" on stdout (single line).
#
#   This is a SEPARATE decision from `decide()` above: `decide()` answers
#   "what shape is this repo's CI pool" (a one-time, session-start read);
#   `decide_backpressure()` answers "should THIS dispatch turn fill a freed
#   slot, or hold it" against a LIVE queued-run count re-read every dispatch
#   turn (`/shipyard:do-work` steady-state.md step C). Kept in this same
#   script because both consume the same pool-shape signal and this keeps a
#   single executable source of truth for CI-capacity decisions rather than
#   splitting the logic across two scripts.
#
#   - POOL_TOTAL     — `.ci_capacity.pool_total` from session state (the
#                       session-start online-runner count; 0 disables the
#                       check entirely — always "dispatch").
#   - QUEUED          — a LIVE re-read of `gh run list --status queued`
#                       (never the stale `queued_at_start` snapshot).
#   - IN_FLIGHT       — count of workers currently in `.in_flight` BEFORE
#                       this slot is filled.
#   - MULTIPLIER      — `ci.backpressure_multiplier` config value (default 5).
#                       Threshold = POOL_TOTAL × MULTIPLIER.
#   - MIN_IN_FLIGHT   — `ci.backpressure_min_in_flight` config value
#                       (default 1). Escape valve: if IN_FLIGHT is already
#                       below this floor, always "dispatch" regardless of
#                       queue depth, so a saturated pool can never fully
#                       stall the session with backlog work still waiting.
#
#   All five inputs degrade to a safe default on non-numeric input rather
#   than erroring (POOL_TOTAL/QUEUED/IN_FLIGHT -> 0, MULTIPLIER -> 5,
#   MIN_IN_FLIGHT -> 1) — this is an advisory throughput check, not a
#   security gate, so a malformed input should never crash the dispatch
#   loop; it degrades toward "dispatch" (POOL_TOTAL=0) or toward the
#   documented default threshold.
#
# Fail-safe posture: this is advisory-only, unlike the ungated-merge and
# gate-narrowing detectors (which gate a security-relevant merge decision).
# A false `unknown` costs nothing but a missed clamp/hint; a false
# `self-hosted` on a repo that's actually GitHub-hosted would wrongly clamp
# concurrency for no reason, so `unknown` is the safe default whenever the
# runners endpoint itself cannot be read cleanly — never guess `hosted` or
# fabricate a pool size. Likewise, `decide_backpressure()` fails toward
# "dispatch" on a zero/unreadable pool size — never toward holding every
# slot on a signal we couldn't actually read.
#
# Queue-depth caveat: `gh run list --status queued` is a repo-wide, all-
# workflow count — it does not distinguish which queued runs are actually
# waiting on THIS pool of self-hosted runners vs. a GitHub-hosted runner
# label that has effectively-unlimited capacity. On a repo that mixes both
# (some jobs `runs-on: self-hosted`, others `runs-on: ubuntu-latest`), the
# queued count is an upper bound on self-hosted contention, not an exact
# count. Callers treat it as a coarse "is the backlog roughly in proportion
# to the pool" signal, not a precise scheduling input.
#
# Usage — pure resume decision (issue #1402, hermetic, no network calls):
#   bash detect-ci-runner-capacity.sh --decide-resume \
#     <POOL_TOTAL> <QUEUED> <MULTIPLIER>
#     -> prints "resume" or "held" on stdout (single line).
#
#   A THIRD decision, alongside `decide()` and `decide_backpressure()`:
#   `decide_backpressure()` answers "should THIS turn fill a freed slot",
#   gated by an escape valve that guarantees at least `MIN_IN_FLIGHT` workers
#   stay dispatched — a guarantee that only holds while some worker IS in
#   flight. `decide_resume()` answers the inverse question asked from a
#   `paused_on_environment` pause, where by construction NO worker is in
#   flight (that's the deadlock condition that caused the pause in the first
#   place, see steady-state.md's "Session-wide environmental pause" section)
#   — so there is no in-flight count for an escape valve to protect, and this
#   function deliberately has none. Same threshold shape as
#   `decide_backpressure()` (`queued > pool_total * multiplier`), inverted:
#   "held" means the condition that caused the pause hasn't cleared yet;
#   "resume" means it has (or POOL_TOTAL is unreadable/zero, same defensive
#   default `decide_backpressure()` uses — never hold on a signal that
#   couldn't actually be read).
#
#   - POOL_TOTAL   — the pool size recorded when the pause was armed
#                     (`paused_on_environment.resume_probe_pool_total`).
#   - QUEUED        — a LIVE re-read of `gh run list --status queued`.
#   - MULTIPLIER    — `ci.backpressure_multiplier` config value (default 5),
#                      the SAME threshold multiplier that triggered the
#                      original hold — resume uses the same bar the hold did,
#                      not a separate hysteresis band.
#
#   Both numeric inputs degrade to 0 on non-numeric input (never crash);
#   MULTIPLIER degrades to 5. A zero/unreadable POOL_TOTAL always "resume"s
#   — an unreadable signal is not evidence the environment is still
#   saturated, only evidence the watcher couldn't check.

set -uo pipefail

decide() {
  local runner_count="$1" online_count="$2" busy_count="$3" idle

  case "$runner_count" in ''|*[!0-9]*) runner_count=0 ;; esac
  case "$online_count" in ''|*[!0-9]*) online_count=0 ;; esac
  case "$busy_count" in ''|*[!0-9]*) busy_count=0 ;; esac

  if [ "$runner_count" -eq 0 ]; then
    printf 'hosted\n'
    return 0
  fi

  idle=$((online_count - busy_count))
  [ "$idle" -lt 0 ] && idle=0
  printf 'self-hosted pool_total=%d pool_idle=%d\n' "$online_count" "$idle"
}

decide_backpressure() {
  local pool_total="$1" queued="$2" in_flight="$3" multiplier="$4" min_in_flight="$5"

  case "$pool_total" in ''|*[!0-9]*) pool_total=0 ;; esac
  case "$queued" in ''|*[!0-9]*) queued=0 ;; esac
  case "$in_flight" in ''|*[!0-9]*) in_flight=0 ;; esac
  case "$multiplier" in ''|*[!0-9.]*) multiplier=5 ;; esac
  case "$min_in_flight" in ''|*[!0-9]*) min_in_flight=1 ;; esac

  # A zero/unreadable pool size disables the check entirely — never gate
  # dispatch on a signal we couldn't actually read.
  if [ "$pool_total" -eq 0 ]; then
    printf 'dispatch\n'
    return 0
  fi

  # Escape valve — never let backpressure hold every slot on a saturated
  # pool. At least MIN_IN_FLIGHT workers stay dispatched regardless of
  # queue depth, so a heavily-backpressured session can't go fully idle
  # with backlog work still waiting and nothing ever filling a slot.
  if [ "$in_flight" -lt "$min_in_flight" ]; then
    printf 'dispatch\n'
    return 0
  fi

  awk -v q="$queued" -v p="$pool_total" -v m="$multiplier" \
    'BEGIN { print (q > p * m) ? "hold" : "dispatch" }'
}

decide_resume() {
  local pool_total="$1" queued="$2" multiplier="$3"

  case "$pool_total" in ''|*[!0-9]*) pool_total=0 ;; esac
  case "$queued" in ''|*[!0-9]*) queued=0 ;; esac
  case "$multiplier" in ''|*[!0-9.]*) multiplier=5 ;; esac

  # A zero/unreadable pool size always resumes — never hold a pause open on
  # a signal we couldn't actually read (same defensive posture as
  # decide_backpressure's zero-pool "dispatch" default).
  if [ "$pool_total" -eq 0 ]; then
    printf 'resume\n'
    return 0
  fi

  # Deliberately NO escape valve here — decide_backpressure's IN_FLIGHT
  # escape valve exists to guarantee forward progress while other workers
  # are running; a paused_on_environment pause exists precisely because NO
  # worker is in flight, so there is nothing for an escape valve to protect.
  awk -v q="$queued" -v p="$pool_total" -v m="$multiplier" \
    'BEGIN { print (q > p * m) ? "held" : "resume" }'
}

# usage — print the full usage block to stderr. Print-only: callers decide
# the exit code (0 for -h/--help, 64/EX_USAGE for every invocation-shape
# error — per sysexits.h and this script family's own convention, see e.g.
# classify-backlog.sh, audit-schedule.sh, and the -h/--help handling in
# detect-ungated-admin-direct-merge.sh / detect-missing-workflow-scope.sh /
# verify-config-labels.sh). Every invocation-shape error in the live-detection
# positional path below routes through here (issue #1454) — previously only
# the empty-repo case printed usage, and nothing rejected an unexpected
# leading token or extra positional, so a mis-invocation like
# `detect-ci-runner-capacity.sh run --repo owner/name` silently took "run" as
# the repo instead of erroring. (issue #1550: -h/--help used to fall into the
# unrecognized-flag branch below and exit 64, breaking the "usage() is the
# normative source of a script's call shape" fallback its three siblings
# honor — usage() no longer force-exits so -h/--help can print the same
# block and exit 0 instead.)
usage() {
  echo "usage: $0 <owner/repo>" >&2
  echo "       $0 --repo <owner/repo>" >&2
  echo "       $0 --decide <RUNNER_COUNT> <ONLINE_COUNT> <BUSY_COUNT>" >&2
  echo "       $0 --decide-backpressure <POOL_TOTAL> <QUEUED> <IN_FLIGHT> <MULTIPLIER> <MIN_IN_FLIGHT>" >&2
  echo "       $0 --decide-resume <POOL_TOTAL> <QUEUED> <MULTIPLIER>" >&2
  echo "       $0 --help" >&2
}

main() {
  case "${1:-}" in
    -h|--help)
      usage
      exit 0
      ;;
  esac

  if [ "${1:-}" = "--decide" ]; then
    if [ "$#" -ne 4 ]; then
      echo "usage: $0 --decide <RUNNER_COUNT> <ONLINE_COUNT> <BUSY_COUNT>" >&2
      exit 1
    fi
    decide "$2" "$3" "$4"
    exit 0
  fi

  if [ "${1:-}" = "--decide-backpressure" ]; then
    if [ "$#" -ne 6 ]; then
      echo "usage: $0 --decide-backpressure <POOL_TOTAL> <QUEUED> <IN_FLIGHT> <MULTIPLIER> <MIN_IN_FLIGHT>" >&2
      # The natural wrong guess is the no-flag form's shape — a single
      # <owner/repo> (issue #1597). This mode is a pure decision: it never
      # reads the repo, so name where the five inputs come from instead of
      # leaving the caller to reverse-engineer them.
      if [ "$#" -eq 2 ] && [[ "$2" == */* ]]; then
        echo "  '$2' looks like <owner/repo> — --decide-backpressure takes no repo; it is a pure decision over five numbers:" >&2
        echo "    POOL_TOTAL=.ci_capacity.pool_total (session state)  QUEUED=live 'gh run list --status queued' count" >&2
        echo "    IN_FLIGHT=.in_flight count before filling the slot   MULTIPLIER=ci.backpressure_multiplier  MIN_IN_FLIGHT=ci.backpressure_min_in_flight" >&2
        echo "  Full call site: commands/do-work/steady-state.md step C (queue-depth backpressure check)." >&2
      fi
      exit 1
    fi
    decide_backpressure "$2" "$3" "$4" "$5" "$6"
    exit 0
  fi

  if [ "${1:-}" = "--decide-resume" ]; then
    if [ "$#" -ne 4 ]; then
      echo "usage: $0 --decide-resume <POOL_TOTAL> <QUEUED> <MULTIPLIER>" >&2
      exit 1
    fi
    decide_resume "$2" "$3" "$4"
    exit 0
  fi

  # Live-detection positional path — the only unguarded shape before #1454.
  # Reject (a) a missing repo, (b) an unrecognized leading flag-shaped token
  # (anything starting with '-' that isn't one of the three modes above or
  # the --repo alias), and (c) more positionals than a single <owner/repo>
  # (or --repo's own arg) supplies. All route to `usage` (exit 64) rather
  # than silently treating the first token as the repo.
  local repo=""
  case "${1:-}" in
    "")
      usage
      exit 64
      ;;
    --repo)
      if [ "$#" -ne 2 ] || [ -z "${2:-}" ]; then
        echo "detect-ci-runner-capacity: --repo requires exactly one <owner/repo> value" >&2
        usage
        exit 64
      fi
      repo="$2"
      ;;
    -*)
      echo "detect-ci-runner-capacity: unrecognized flag '$1'" >&2
      usage
      exit 64
      ;;
    *)
      if [ "$#" -ne 1 ]; then
        echo "detect-ci-runner-capacity: unexpected extra argument(s) after '$1' -- did you mean --repo $1 ...?" >&2
        usage
        exit 64
      fi
      repo="$1"
      ;;
  esac

  # Validate the positional's SHAPE before ever using it — a bare token with
  # no '/' (e.g. the 'run' in the #1454 repro), a leading/trailing slash, or
  # more than one slash cannot be a real <owner/repo> and must never reach
  # `gh api`.
  case "$repo" in
    */*/*|*/|/*)
      echo "detect-ci-runner-capacity: '$repo' does not look like <owner/repo>" >&2
      usage
      exit 64
      ;;
    *[!A-Za-z0-9._/-]*)
      echo "detect-ci-runner-capacity: '$repo' contains characters not valid in a GitHub owner/repo" >&2
      usage
      exit 64
      ;;
    */*)
      : # exactly one slash, both sides non-empty, allowed charset -- OK
      ;;
    *)
      echo "detect-ci-runner-capacity: '$repo' does not look like <owner/repo> (missing '/')" >&2
      usage
      exit 64
      ;;
  esac

  local runners_json runner_count online_count busy_count queued decision api_rc

  # Requires repo ADMIN — fails closed for anything less. That's fine: this
  # is an advisory read, and `unknown` is the correct, safe response to "I
  # couldn't check." Capture the exit status explicitly (issue #1454 —
  # this previously wasn't checked at all): `gh api` writes a well-formed
  # JSON error envelope (e.g. `{"message":"Not Found",...}`) to STDOUT on a
  # non-2xx response, so the pre-existing `[ -z "$runners_json" ]` empty-body
  # check never caught it, and jq's `.runners | length` on that body
  # silently evaluates to 0 (`null | length` is 0 in jq) -- indistinguishable
  # from "a real, successful read that found zero self-hosted runners". A
  # nonexistent repo and a genuinely-hosted repo both fell through to the
  # same confident `hosted` verdict.
  runners_json="$(gh api "repos/${repo}/actions/runners" 2>/dev/null)"
  api_rc=$?
  if [ "$api_rc" -ne 0 ] || [ -z "$runners_json" ]; then
    echo "detect-ci-runner-capacity: could not read repos/${repo}/actions/runners (needs repo admin, the repo may not exist, or a transient API error) -- treating as unknown" >&2
    printf 'unknown\n'
    exit 0
  fi

  # Defense in depth alongside the exit-code check above: require the body
  # to actually carry a `.runners` array before trusting anything parsed
  # from it, so a future response shape that returns 0 with an unexpected
  # body still can't masquerade as a successful zero-runner read.
  if ! printf '%s' "$runners_json" | jq -e 'has("runners") and (.runners | type == "array")' >/dev/null 2>&1; then
    echo "detect-ci-runner-capacity: repos/${repo}/actions/runners response had no '.runners' array (malformed or error body) -- treating as unknown" >&2
    printf 'unknown\n'
    exit 0
  fi

  runner_count="$(printf '%s' "$runners_json" | jq -r '.runners | length' 2>/dev/null)"
  case "$runner_count" in
    ''|*[!0-9]*)
      echo "detect-ci-runner-capacity: runners response for '${repo}' was unparseable -- treating as unknown" >&2
      printf 'unknown\n'
      exit 0
      ;;
  esac

  online_count="$(printf '%s' "$runners_json" | jq -r '[.runners[] | select(.status=="online")] | length' 2>/dev/null)"
  busy_count="$(printf '%s' "$runners_json" | jq -r '[.runners[] | select(.busy==true)] | length' 2>/dev/null)"

  decision="$(decide "$runner_count" "$online_count" "$busy_count")"

  queued=0
  if [ "$runner_count" -gt 0 ]; then
    queued="$(gh run list --repo "$repo" --status queued --limit 100 --json databaseId --jq 'length' 2>/dev/null)"
    case "$queued" in ''|*[!0-9]*) queued=0 ;; esac
  fi

  printf 'repo=%s runner_count=%s online_count=%s busy_count=%s queued=%s\n' \
    "$repo" "$runner_count" "$online_count" "$busy_count" "$queued" >&2

  if [ "$decision" = "hosted" ]; then
    printf 'hosted\n'
  else
    printf '%s queued=%d\n' "$decision" "$queued"
  fi
}

main "$@"
