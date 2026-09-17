#!/usr/bin/env bash
# session-state.sh — atomic JSON read/write helpers for the /shipyard:do-work
# orchestrator's session-state file.
#
# Background (see issue #103): the orchestrator's eight state structures
# (in_flight, ready_issues, failed_prs, raw_backlog, divert_queue,
# session_prs, deferred_issues, main_ci, plus soft-collision counters) used
# to live entirely in the LLM's working memory — re-narrated as prose in the
# invariant line and status line every turn. That's token-expensive and
# drift-prone. Promoting state to a small JSON file at
# `$SHIPYARD_HOME/sessions/<session-id>.json` (default
# `$HOME/.shipyard/sessions/<session-id>.json`) gives us:
#
#   1. A machine-readable view that external tools (dashboards, notifiers)
#      can subscribe to via file-change watchers.
#   2. A durable record that survives across orchestrator turns — the model
#      no longer pays the token cost of re-typing state each turn.
#   3. A foundation for a future `/do-work --resume <session-id>` flag.
#
# Atomicity is the load-bearing property. Every update writes to
# `<path>.tmp.<pid>` and atomically renames into place — a partial write
# (process killed mid-update, filesystem full, etc.) leaves the previous
# state file intact rather than corrupting the source of truth.
#
# This file is the *durable record*, not the orchestrator's working memory.
# The orchestrator still has to keep the model in its head to make
# dispatch decisions (path collisions, lockfile sections, etc.); the JSON
# file is what the model writes through each turn so the artifact exists
# outside the transcript.
#
# Subcommands:
#
#   init     — create a fresh session state file at the deterministic path.
#              `--session-id` and `--repo` are required; `--concurrency`,
#              `--soft-collision-concurrency`, and `--force` are optional.
#              Without `--force`, refuses to overwrite an existing file
#              (exit 2) — protects against accidentally clobbering an
#              active session's state.
#
#   read     — emit the current state on stdout. Whole file when called
#              without `--path`; a single jq path when called with one.
#              Exit 3 if the session file does not exist.
#
#   update   — merge one or more jq `--set` expressions into the file
#              atomically. Each `--set` is a complete jq assignment, e.g.
#              `.session_prs += [96]` or `.main_ci.status = "green"`.
#              Exit 3 if the session file does not exist (no file is
#              created — update is "modify existing state," not "create").
#              Opportunistically auto-flushes the setup-timing sidecar
#              (issue #283) when `.setup` is null and a sidecar exists —
#              guarantees the orchestrator's per-phase timing data lands
#              in the session file even if step 6.8's explicit flush is
#              skipped. Pass `--skip-timing-autoflush` to disable (used
#              by setup-timing.sh's own flush to avoid recursion).
#
#   cleanup  — remove the session file at end-of-session. Idempotent
#              (re-runs after the file is gone exit 0 — the failure mode
#              we're guarding against is a half-cleanup, not a missing
#              file).
#
#   is-active — liveness check used by the orphan-sweep (commands/do-work/
#              setup.md step 1.6). Exit 0 if the session file exists AND
#              its `.pid` is alive (per `kill -0 $pid`); exit 1 if any of
#              those conditions fails. Designed to be the FIRST gate in
#              the sweep — if `is-active` exits 0, the sweep skips the
#              candidate regardless of mtime. Defends against the race
#              where a quiet-but-alive orchestrator's file would otherwise
#              be reaped by a concurrent sweep based on mtime alone
#              (issue #253). The 30-min `find -mmin +30` mtime floor in
#              step 1.6 stays as defense-in-depth against PID recycling.
#
#   bump-tokens — atomically add token-usage counts to the session's
#              `.tokens` block. The `tokens` field tracks token spend
#              at three levels of granularity: `totals` (cumulative
#              across the session, including orchestrator overhead),
#              `per_issue.<N>` (sum across every agent that touched
#              issue N), and `per_pr.<M>` (sum across every agent that
#              touched PR M). Pass `--issue N` and/or `--pr M` to
#              attribute the delta — neither flag only bumps `totals`
#              (use for orchestrator-side overhead). `--mode` and
#              `--model` are recorded into a small `.tokens.per_invocation`
#              ring buffer for traceability (capped at the most recent
#              200 entries to keep the file small). Exit 3 if the session
#              file does not exist.
#
#              `--degraded-total-only` is the harness-side gap fallback
#              from #279: when the sub-agent task-notification <usage>
#              block only emits `total_tokens` (no input/output/cache
#              breakdown), callers pass `--input <total_tokens>
#              --degraded-total-only` (other token flags MUST be omitted /
#              zero). The bump lands in `.tokens.totals.input` and stamps
#              `degraded: true` on the per_invocation entry; the
#              session-level `.tokens.degraded_attribution_count`
#              increments by 1 so the end-of-session summary can surface
#              a banner. Cost will under-count (no output 5x multiplier,
#              no cache 10% multiplier) but the data lands somewhere
#              durable instead of being silently dropped at $0.
#              `--degraded-total-only` requires `--input <total_tokens>`
#              to be non-zero — `--input 0` is rejected with exit 64
#              (#320). A real agent completion always has non-zero
#              `total_tokens`; passing 0 is an orchestrator copy-paste
#              of the breakdown-fields default, and silently recording
#              $0 across an entire session was a worse failure mode
#              than the dispatch erroring loud.
#
#   read-tokens — emit token data on stdout. `--format json` (default)
#              prints the relevant slice; `--format comment` emits a
#              ready-to-post Markdown comment body marked with the
#              `<!-- do-work-cost-tracking -->` sentinel for idempotent
#              edit-or-create on the issue/PR. Pair with `--issue N` or
#              `--pr M` to scope; without either, emits the session-wide
#              totals. Exit 3 if the session file does not exist.
#
#   set-progress — atomically set `progress_current` / `progress_total` on
#              a single in-flight slot. Used by /shipyard:status (issue
#              #167) to render batch-style progress (e.g. `4/7`) on
#              workers that process N items per dispatch. The two values
#              live on the slot record itself (not on a separate per-worker
#              status file) — the session state file is already the
#              single source of truth for in-flight worker bookkeeping.
#              `--slot <id>` is required; `--current N` / `--total N` are
#              optional (pass either, both, or neither — neither is a
#              no-op success). Pass `--current null` / `--total null` to
#              clear a previously-set value. Exit 3 if the session file
#              does not exist; exit 64 if the slot is unknown.
#
#   record-session-end — stamp a terminal `.session_end` reason on the
#              session file before cleanup reaps it (issue #1252). Closes
#              the gap where a session that dies mid-flight (crash,
#              interrupt, harness limit) never records why it stopped,
#              making it indistinguishable from a clean exit after the
#              fact. `--reason` is a closed enum: `completed` (every
#              workable issue closed/dispositioned and every session PR
#              merged), `bounded-exit` (drain stopped on a safety bound —
#              max_drain_hours, a still-red/DIRTY/pending PR, or a
#              non-zero completion-ledger bucket — with unfinished tail
#              remaining), or `user-stop` (an explicit stop signal ended
#              the session early). `--detail` is optional free-text
#              elaboration, stored as `null` when omitted. Shares
#              --allow-degraded-init / --degraded-init-repo and
#              --expected-repo / --skip-repo-check with `update`. Exit 64
#              on an unrecognized `--reason`; exit 3 if the session file
#              does not exist and --allow-degraded-init was not passed.
#
#   record-stall — append one entry to `.stalled_dispatches` (issue
#              #1302). Typed alternative to hand-building a
#              `.stalled_dispatches = [...]` jq literal through `update`
#              — the orchestrator's own working-memory bash array (see
#              do-work/steady-state.md's A.0.5) is still the fast
#              same-turn source of truth for cap/collision decisions;
#              this call mirrors ONE freshly-appended entry to the
#              durable file so `/shipyard:status` and post-crash
#              forensics can see it without waiting for the end-of-
#              session summary. A single-entry typed call keeps the
#              argument small specifically to avoid the large nested-
#              JSON `--set` payload issue #1302 found gets denied
#              outright by Auto Mode's classifier. `--target`, `--mode`,
#              `--trigger` (`non-terminal-return`|`harness-failed`), and
#              `--outcome` (`resumed`|`handed-back`|`dropped-clean`) are
#              required; `--resumed-pr <N>` is optional (omit or pass
#              `null` for no PR). `detected_at` is stamped internally at
#              call time — never caller-supplied, so entries are always
#              ordered by actual write time. Shares
#              --allow-degraded-init / --degraded-init-repo and
#              --expected-repo / --skip-repo-check with `update`. Exit 64
#              on an unrecognized enum value; exit 3 if the session file
#              does not exist and --allow-degraded-init was not passed.
#
#   record-denial — append one entry to `.dispatch_denials` (issue
#              #1302). Same rationale and shape as `record-stall` above,
#              for the harness permission classifier denying a worker
#              dispatch call outright (issue #718) instead of a stalled
#              worker. `--target`, `--mode`, `--denial-text`, `--attempt`
#              (`1`|`2`), and `--outcome`
#              (`reframed`|`shipped-after-reframe`|`handed-back`) are
#              required. `denied_at` is stamped internally at call time.
#              Shares the same degraded-init / cross-repo-guard flags as
#              `update`. Exit 64 on an unrecognized enum value; exit 3 if
#              the session file does not exist and --allow-degraded-init
#              was not passed.
#
# Pricing table:
#
#   The USD estimate in `bump-tokens` and `read-tokens` uses a hardcoded
#   pricing table embedded in this script (per 1M tokens, current as of
#   2026-07-13). Update the `PRICING_JQ` block below when Anthropic
#   changes pricing or ships a new model.
#
#   An unknown model is NOT silently priced at zero (issue #728). $0.00 is
#   a legitimate value and must not double as the error sentinel: a stale
#   table would otherwise report a confident — and confidently wrong —
#   near-zero spend for every dispatch on a model it hasn't heard of.
#   Instead, `bump-tokens` on a table miss:
#
#     * still records the token counts (no data is lost),
#     * emits a loud warning on stderr (the call is fire-and-forget, so it
#       must not fail the dispatch — but it must not be silent either),
#     * records the model id in the session's `.tokens.unpriced_models`
#       set and stamps `unpriced: true` on the `per_invocation` entry.
#
#   `read-tokens`, the end-of-session summary, and `/shipyard:cost report`
#   read that set and label the USD total a LOWER BOUND when it's non-empty.
#   `scripts/tests/pricing-coverage.test.sh` asserts every model id shipped
#   in the repo (config defaults + agent-shim frontmatter) resolves to a
#   pricing row, so a new model can't ship into a $0 hole.
#
# Environment variables:
#
#   SHIPYARD_HOME — base directory for shipyard's per-user state. Defaults
#                   to `$HOME/.shipyard`. Sessions live at
#                   `$SHIPYARD_HOME/sessions/<session-id>.json`. Override
#                   via env (no CLI flag) so the orchestrator and the test
#                   suite can both relocate without touching the wire.
#
# Exit codes:
#
#   0   — success
#   2   — refused to clobber an existing file (init without --force)
#   3   — session file does not exist (read or update)
#   64  — usage error (bad subcommand or missing required argument).
#         Mirrors `sysexits.h`'s EX_USAGE so callers can branch on it.
#   65+ — internal helper failure (jq missing, write permission denied,
#         etc.) — never papered over with exit 0; the orchestrator should
#         see and surface these.
#   66  — cross-repo write refused on `update` / `bump-tokens` (issue
#         #365). The session file's `.repo` doesn't match the caller's
#         --expected-repo (or $SHIPYARD_EXPECTED_REPO). Defends against
#         the cross-session contamination race where a concurrent
#         /do-work session's session-id stash clobbers the caller's id
#         and writes land against the wrong session file. Pass
#         --skip-repo-check to override for legitimate cross-repo
#         helpers (e.g. the orphan-sweep at setup.md step 1.6).

set -u
# `pipefail` is load-bearing for the `jq ... | atomic_write` contract
# (issue #357). Without it, the pipeline's exit status is `atomic_write`'s
# alone — masking a jq compile error or runtime failure that produces no
# stdout. With it, the pipeline reports any failing stage, so the caller's
# `if ! jq ... | atomic_write` branch fires reliably on upstream failures.
# Paired with the empty-tempfile guard in `atomic_write` itself: belt AND
# suspenders, because the orchestrator depends on the session JSON never
# being silently truncated.
set -o pipefail

# --------------------------------------------------------------------------
# Shared helpers (shipyard_home, require_jq, atomic_write) — issue #887.
# --------------------------------------------------------------------------
# shellcheck source=lib/common.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# --------------------------------------------------------------------------
# Dependency check — jq is required for both read (path selection) and
# update (atomic merge). The script intentionally has no python3 fallback:
# jq is already in shipyard's dependency surface (used by every gh query in
# do-work.md), and a single tool simplifies the atomic-write contract.
# --------------------------------------------------------------------------
require_jq

usage() {
  cat <<'EOF' >&2
Usage:
  session-state.sh init        --session-id <id> --repo <owner/repo>
                               [--concurrency N] [--soft-collision-concurrency N]
                               [--pid N] [--degraded-recovery] [--force]
  session-state.sh read        --session-id <id> [--path <jq-path>]
  session-state.sh update      --session-id <id> --set '<jq-expr>' [--set ...]
                               [--set-file <path-to-jq-expr>] [...]
                               [--skip-timing-autoflush]
                               [--allow-degraded-init] [--degraded-init-repo <r>]
                               [--expected-repo <owner/repo>] [--skip-repo-check]
  session-state.sh set-slot    --session-id <id> --slot-id <id>
                               --kind issue|fix-checks|fix-rebase|fix-main-ci|
                                      fix-failing-prs-batch|investigate|spike
                               --target <str> [--agent-id <id>] [--model <alias>]
                               [--started-at <RFC3339>] [--version-slot <X.Y.Z>]
                               [--worktree-path <abs-path>]
                               [--hard-path <p>]... [--soft-path <p>]...
                               [--allow-degraded-init] [--degraded-init-repo <r>]
                               [--expected-repo <owner/repo>] [--skip-repo-check]
  session-state.sh release-slot --session-id <id> --slot-id <id>
                               [--allow-degraded-init] [--degraded-init-repo <r>]
                               [--expected-repo <owner/repo>] [--skip-repo-check]
  session-state.sh cleanup     --session-id <id>
                               [--reap-audit --reaper-session-id <id>
                                [--reaper-pid N] [--reason <str>] [--phase <str>]]
  session-state.sh is-active   --session-id <id>
  session-state.sh bump-tokens --session-id <id>
                               [--issue N] [--pr N]
                               [--input N] [--output N]
                               [--cache-read N] [--cache-creation N]
                               [--mode <kind>] [--model <id>]
                               [--allow-degraded-init] [--degraded-init-repo <r>]
                               [--degraded-total-only]
                               [--expected-repo <owner/repo>] [--skip-repo-check]
  session-state.sh read-tokens --session-id <id>
                               [--issue N] [--pr N]
                               [--format json|comment]
  session-state.sh set-progress --session-id <id>
                               --slot <slot-id>
                               [--current N|null] [--total N|null]
  session-state.sh record-session-end --session-id <id>
                               --reason completed|bounded-exit|user-stop
                               [--detail <str>]
                               [--allow-degraded-init] [--degraded-init-repo <r>]
                               [--expected-repo <owner/repo>] [--skip-repo-check]
  session-state.sh record-stall --session-id <id>
                               --target <str> --mode <kind>
                               --trigger non-terminal-return|harness-failed
                               --outcome resumed|handed-back|dropped-clean
                               [--resumed-pr N]
                               [--allow-degraded-init] [--degraded-init-repo <r>]
                               [--expected-repo <owner/repo>] [--skip-repo-check]
  session-state.sh record-denial --session-id <id>
                               --target <str> --mode <kind>
                               --denial-text <str> --attempt 1|2
                               --outcome reframed|shipped-after-reframe|handed-back
                               [--allow-degraded-init] [--degraded-init-repo <r>]
                               [--expected-repo <owner/repo>] [--skip-repo-check]

Environment:
  SHIPYARD_HOME                base dir for sessions/ (default: $HOME/.shipyard)
  SHIPYARD_EXPECTED_REPO       fallback for --expected-repo on update /
                               bump-tokens when the flag isn't passed.
                               When set, every write-class call is guarded
                               against cross-repo state contamination
                               (issue #365). Override per-call via
                               --expected-repo / --skip-repo-check.

Exit codes:
  0   success (is-active: file exists and pid is alive)
  1   is-active: file missing OR pid unset OR pid dead
  2   refused to clobber (init w/o --force)
  3   session file missing (read, update / bump-tokens without
      --allow-degraded-init, read-tokens, set-progress)
  64  usage error
  65+ internal helper failure
  66  cross-repo write refused (update / bump-tokens, issue #365)
EOF
}

# usage_error [<subcommand>]
#
# Print the usage block, then emit ONE more line naming the actual outcome,
# then exit 64. Why: usage()'s heredoc unconditionally ends with the
# exit-code legend above, and that legend's own last row describes exit 66
# (the #365 cross-repo write refusal) — the most alarming-sounding entry in
# the table. A caller that reads a failed invocation's stderr through
# `tail` (a normal thing to do against a chatty helper) sees those two
# legend lines as if they were the actual result, misreading a plain exit-64
# usage error as a cross-repo contamination refusal (issue #1039). Emitting
# a named final line on every usage-error path fixes that for `tail -N`
# reads of any N that still includes this line, mirroring the distinct
# per-call header check_repo_match() already prints ahead of its own exit
# 66. Call this in place of the previous bare `usage; exit 64` (or
# `usage` on its own line followed by `exit 64`) at every usage-error site;
# any subcommand-specific reason should already have been echoed to stderr
# by the caller before this runs.
usage_error() {
  local subcommand="${1:-}"
  usage
  if [[ -n "$subcommand" ]]; then
    echo "session-state.sh: ${subcommand}: usage error (exit 64)" >&2
  else
    echo "session-state.sh: usage error (exit 64)" >&2
  fi
  exit 64
}

# --------------------------------------------------------------------------
# Pricing table — USD per 1M tokens, current as of 2026-08-13 (verified
# against https://platform.claude.com/docs/en/about-claude/pricing — see
# issue #1342). Update alongside Anthropic's pricing page whenever pricing
# changes OR a new model ships. A model that is NOT listed here is treated
# as *unpriced*, not as free: see the "Pricing table" section of the header
# comment and `resolve_pricing_row` below (issue #728).
#
# Cache rows follow Anthropic's published multipliers off the input rate:
# cache_read = 0.1x input, cache_creation (5-minute TTL) = 1.25x input.
#
# NOTE (#728): the `claude-opus-4-7` / `claude-opus-4-6` rows previously
# carried the pre-Opus-4.5 rate ($15/$75). Opus-tier pricing is $5/$25 —
# the stale rows over-reported every Opus dispatch by 3x, which is the same
# "confidently wrong number" failure this issue exists to close, so they are
# corrected here alongside the new `claude-opus-4-8` row.
#
# NOTE (#1342): `claude-opus-5` was missing entirely (booked every Opus-5
# dispatch at a confident $0.00 until #728's loud-warning path caught it
# live) — added at the same $5/$25 rate as every other current Opus-tier
# model. While verifying that rate against the authoritative pricing page,
# the existing `claude-sonnet-5` row was found to ALSO be wrong: it carried
# $3/$15 (the rate Sonnet 5 was originally scheduled to rise to on
# 2026-09-01), but Anthropic's pricing page now states that increase will
# NOT occur — the $2/$10 introductory rate is the permanent standard price.
# Corrected here; every Sonnet-5 dispatch billed under the old $3/$15 row
# was over-reported by 1.5x. Historical `~/.shipyard/cost-history.jsonl`
# records are NOT retroactively re-priced by this change (out of scope for
# #1342 — flagged there as a separate decision for a maintainer to make).
# --------------------------------------------------------------------------
PRICING_JQ='{
  "claude-fable-5":    { "input": 10.00, "output": 50.00, "cache_read": 1.00, "cache_creation": 12.50 },
  "claude-opus-5":     { "input":  5.00, "output": 25.00, "cache_read": 0.50, "cache_creation":  6.25 },
  "claude-opus-4-8":   { "input":  5.00, "output": 25.00, "cache_read": 0.50, "cache_creation":  6.25 },
  "claude-opus-4-7":   { "input":  5.00, "output": 25.00, "cache_read": 0.50, "cache_creation":  6.25 },
  "claude-opus-4-6":   { "input":  5.00, "output": 25.00, "cache_read": 0.50, "cache_creation":  6.25 },
  "claude-sonnet-5":   { "input":  2.00, "output": 10.00, "cache_read": 0.20, "cache_creation":  2.50 },
  "claude-sonnet-4-6": { "input":  3.00, "output": 15.00, "cache_read": 0.30, "cache_creation":  3.75 },
  "claude-sonnet-4-5": { "input":  3.00, "output": 15.00, "cache_read": 0.30, "cache_creation":  3.75 },
  "claude-haiku-4-5":  { "input":  1.00, "output":  5.00, "cache_read": 0.10, "cache_creation":  1.25 }
}'

# --------------------------------------------------------------------------
# Degraded-attribution blended-rate mix (issue #1330) — ANALYTICALLY
# DERIVED, NOT MEASURED.
#
# `--degraded-total-only` (see cmd_bump_tokens below) is fed a single
# total_tokens figure with no input/output/cache-read/cache-creation split
# — the harness-side gap from issue #279. Prior to #1330, that whole total
# was priced entirely at the model's `input` rate. That is not a neutral
# fallback: it systematically misprices in both directions relative to a
# real agentic dispatch's actual token mix, whose composition is NOT
# input-dominated. Every "round" of an agentic tool loop resends the
# accumulated conversation so far as context — the overwhelming majority of
# which was already seen (and cached) in a prior round — so it is billed at
# the ~10x-cheaper `cache_read` rate, not the `input` rate. Only the
# incremental new content each round (a fresh tool result, a new user
# message) bills as `input` or `cache_creation`, and the model's own
# generated tokens bill as `output` (priced ~5x higher than `input`). A
# dispatch that runs many tool-call rounds — the common shape for
# issue-work / fix-checks / investigate dispatches — therefore skews
# heavily toward `cache_read`, not `input`.
#
# This mix is DERIVED FROM THAT STRUCTURAL REASONING, not measured against
# this repo's own history: as of 2026-08-13 zero records in
# ~/.shipyard/cost-history.jsonl carry a non-degraded `per_invocation`
# breakdown (206/206 session records are 100% `--degraded-total-only`,
# confirmed via `jq -s '[.[] | select((.tokens.output // 0) > 0)] |
# length'` returning 0) — there is no historical non-degraded data to
# derive an empirical mix from yet. Once the harness-side gap (#279) is
# closed upstream and a meaningful sample of non-degraded per_invocation
# entries accumulates, this mix should be RE-DERIVED empirically from
# those records (grouped by mode/model if the mix varies meaningfully
# across them) rather than left as an analytic estimate indefinitely.
#
# Fractions MUST sum to 1.0 — each represents the assumed share of a
# degraded dispatch's total_tokens actually spent in that bucket, at that
# bucket's per-token rate, when computing a blended per-token price. See
# `cmd_bump_tokens`'s `--degraded-total-only` branch for how this is
# applied, and `cmd_read_tokens` for `estimated_usd_upper_bound`'s
# separate, mix-independent true-ceiling computation (pricing the whole
# total at the single most expensive rate in PRICING_JQ) — a blended
# estimate is still an estimate, not a bound, so the two fields answer
# different questions.
# --------------------------------------------------------------------------
DEGRADED_BLEND_MIX_JQ='{
  "input":          0.07,
  "output":         0.04,
  "cache_read":     0.86,
  "cache_creation":  0.03
}'

# Bare-alias map. Some dispatch sites pass `opus` / `sonnet` / `haiku`
# rather than a canonical id; each resolves to the *current* model of that
# tier. Keep in lockstep with PRICING_JQ when a tier's current model rolls.
#
# NOTE (#1342): `opus` and `sonnet` previously pointed at `claude-opus-4-8`
# and `claude-sonnet-4-6` respectively, even though `claude-opus-5` and
# `claude-sonnet-5` are both now in PRICING_JQ above and are the actual
# current-generation flagships of their tiers (shipyard's own
# `models.issue_work` built-in default already treats `claude-sonnet-5` as
# "the" current Sonnet — see shipyard-config.sh). That was a genuine drift,
# not a deliberate pin: the comment above has always said "keep in lockstep
# ... when a tier's current model rolls," and the tier rolled without this
# map following. Repointed to the current generation; `haiku` is unchanged
# because no newer Haiku has shipped.
ALIASES_JQ='{
  "opus":   "claude-opus-5",
  "sonnet": "claude-sonnet-5",
  "haiku":  "claude-haiku-4-5"
}'

# --------------------------------------------------------------------------
# Session-inheritable model floor (issue #1342).
#
# `spike` (see agents/spike-worker.md's "Why no model pin") declares no
# `models.spike` config default and no shim `model:` frontmatter — by
# design, it inherits whatever model the CALLING SESSION itself is running
# as (dispatch-rules.md's routing table: "default (session model / Opus)").
# `resolve-dispatch-model.sh spike` correctly returns empty for exactly this
# reason. That means neither of pricing-coverage.test.sh's other two
# coverage scans — config `models.*` defaults, agent-shim `model:`
# frontmatter — can ever see the model that actually bills a spike
# dispatch: nothing in this repo names it.
#
# This list is the maintained floor that closes that blind spot: the
# current flagship id for each model family a session could plausibly be
# running as when it dispatches an un-pinned mode. Update it IN THE SAME PR
# that adds a PRICING_JQ row for a new family flagship (a full-generation
# bump, e.g. Opus 4.x -> Opus 5 — not a same-generation point release) —
# deliberately kept adjacent to PRICING_JQ in this file so the two are hard
# to update one without the other. This cannot guarantee coverage of a
# model generation nobody has shipped yet (no static list can — see
# pricing-coverage.test.sh's own header comment), but it turns "is the
# CURRENTLY known session-inheritable floor priced" into an assertion CI
# actually runs, instead of the single hardcoded `claude-opus-4-8` literal
# this replaces, whose staleness is exactly what let #1342 happen.
# --------------------------------------------------------------------------
# shellcheck disable=SC2034  # read by pricing-coverage.test.sh via a source
# grep, not referenced from within this script itself — see that test's
# "session-inheritable" coverage section for the consumer.
SESSION_INHERITABLE_MODELS_JQ='["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5", "claude-fable-5"]'

# resolve_pricing_row <model-id>
#
# Echo the pricing row for <model-id> as compact JSON, or the empty string
# when the model is unknown to the table. The caller distinguishes the two
# (a "" return is the unpriced sentinel) — this is the single place the
# lookup lives, so bump-tokens' warning and the USD math can never disagree
# about whether a model was priced.
#
# Lookup is alias-then-longest-prefix, not exact-match (closes #226): the
# harness reports dated ids like `claude-haiku-4-5-20251001`, and some
# callers pass bare aliases. A dated suffix resolves via the prefix match;
# a bare alias resolves via ALIASES_JQ. Longest-prefix (rather than first
# match) keeps `claude-opus-4-8` from being swallowed by a hypothetical
# shorter `claude-opus-4` key.
resolve_pricing_row() {
  local model="${1:-}"
  [[ -z "$model" ]] && { printf ''; return 0; }
  jq -c -n \
    --arg model "$model" \
    --argjson pricing "$(jq -c -n "$PRICING_JQ")" \
    --argjson aliases "$(jq -c -n "$ALIASES_JQ")" '
      ($aliases[$model] // $model) as $resolved
      | $pricing
      | to_entries
      | map(select(.key as $k | $resolved | startswith($k)))
      | sort_by(-(.key | length))
      | (.[0].value // empty)
    ' 2>/dev/null
}

# Resolve the canonical session-file path. Mirrors the spec in
# commands/do-work.md: `$SHIPYARD_HOME/sessions/<session-id>.json`.
session_path() {
  local session_id="$1"
  local home
  home=$(shipyard_home)
  printf '%s/sessions/%s.json\n' "$home" "$session_id"
}

# Atomic write: take JSON on stdin, write to <target>.tmp.<pid>, then
# `mv -f` into place. Now shared in lib/common.sh (issue #887) — this was
# the canonical (most defensive, 0-byte-guarded) implementation of the
# atomic_write() logic duplicated across this file, shipyard-config.sh,
# gh-cached.sh, and eas-watch.sh; see that file's own comment for the full
# empty-write-guard rationale (issue #357) this extraction preserves
# byte-for-byte.

# Cross-repo write guard (issue #365). When a write-class subcommand
# (`update`, `bump-tokens`) resolves to a session file whose `.repo` does
# NOT match the caller's expected repo, refuse the write and log loudly.
# Defends against the failure mode where two `/shipyard:do-work` sessions
# run concurrently against different repos and the orchestrator's
# session-id stash race causes one session's write calls to land against
# the other session's state file — silently cross-wiring token
# attributions, `session_prs` appends, and `reconciled_agent_ids`.
#
# Inputs:
#   $1  target file path (already resolved via session_path)
#   $2  expected repo string (caller-supplied; either from --expected-repo
#       or from $SHIPYARD_EXPECTED_REPO). Empty string → check is a no-op.
#   $3  caller subcommand name (for stderr context, e.g. "update")
#
# Exit codes:
#   0   match (or no-op when expected_repo is empty)
#   66  mismatch — refuse the write. Distinct from the existing exits
#       (0 success / 2 init-clobber / 3 file-missing / 64 usage / 65+
#       internal) so callers can branch on it.
check_repo_match() {
  local target="$1"
  local expected_repo="$2"
  local subcommand="$3"

  # Empty expected_repo → caller opted out (or wasn't told what to expect).
  # The orchestrator SHOULD pass --expected-repo on every write but the
  # check is opt-in to avoid breaking older callers / cleanup helpers that
  # legitimately operate on cross-repo session files (e.g. the orphan
  # session-file sweep at setup.md step 1.6).
  if [[ -z "$expected_repo" ]]; then
    return 0
  fi

  # File missing → not our problem here. Caller's own existence checks
  # (and the --allow-degraded-init recovery path) handle that.
  if [[ ! -f "$target" ]]; then
    return 0
  fi

  local actual_repo
  actual_repo=$(jq -r '.repo // ""' "$target" 2>/dev/null)

  # Empty `.repo` field (legacy file, partial write) → don't block; the
  # cross-repo race we're guarding against produces a populated `.repo`
  # field that doesn't match, not an empty one.
  if [[ -z "$actual_repo" ]]; then
    return 0
  fi

  if [[ "$actual_repo" != "$expected_repo" ]]; then
    cat >&2 <<EOF
session-state.sh: ${subcommand}: cross-repo write refused (issue #365)
  session file:   $target
  file's .repo:   $actual_repo
  expected repo:  $expected_repo
  This is the cross-session contamination guard: the session file's
  recorded repo does not match the caller's expected repo, which means
  the caller's --session-id resolved to a session file owned by a
  different /shipyard:do-work run. Refusing the write to avoid silently
  corrupting another session's token attributions and session_prs.
  If this refusal is wrong (e.g., the caller is a legitimate
  cross-repo cleanup helper), pass --skip-repo-check to override.
EOF
    return 66
  fi

  return 0
}

cmd_init() {
  local session_id=""
  local repo=""
  local concurrency=2
  local soft_concurrency=3
  local force=0
  # --pid is the orchestrator's process id at init time. The orphan-sweep
  # in setup.md step 1.6 uses it (via `is-active`) to skip files belonging
  # to a process that's still alive — defending against the race where a
  # concurrent /do-work session's sweep would otherwise reap an active
  # peer's file based on mtime alone (issue #253). Default to $PPID — the
  # immediate parent of this script's bash, which in the orchestrator's
  # call chain is the bash hook invoked by Claude Code. Callers that have
  # a more authoritative pid (e.g. a wrapper that knows the orchestrator's
  # actual pid) can override with --pid <N>. 0 means "do not stamp" —
  # makes the field a no-op for callers (test fixtures) that don't want
  # liveness checking.
  local pid="${PPID:-0}"
  # --degraded-recovery flags this init as a fallback path (bump-tokens
  # auto-creating after a file-disappear-mid-session event, per issue
  # #253's cost-tracking workaround). Stamps `.degraded_recovery_at` so
  # the file is identifiable in audits and metrics.
  local degraded_recovery=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      --concurrency) concurrency="${2:-}"; shift 2 ;;
      --soft-collision-concurrency) soft_concurrency="${2:-}"; shift 2 ;;
      --pid) pid="${2:-}"; shift 2 ;;
      --degraded-recovery) degraded_recovery=1; shift ;;
      --force) force=1; shift ;;
      *) echo "init: unknown arg $1" >&2; usage_error "init" ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "init: --session-id is required" >&2
    usage_error "init"
  fi
  if [[ -z "$repo" ]]; then
    echo "init: --repo is required" >&2
    usage_error "init"
  fi
  if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
    echo "init: --pid must be a non-negative integer (got: $pid)" >&2
    exit 64
  fi

  local target
  target=$(session_path "$session_id")

  if [[ -e "$target" && "$force" -ne 1 ]]; then
    echo "init: $target already exists (use --force to overwrite)" >&2
    exit 2
  fi

  # Build the initial JSON via jq -n so quoting / number-vs-string typing
  # is handled correctly. Every field the spec calls out is initialised to
  # its empty value so reads of fresh sessions never trip on missing keys.
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local degraded_at_json="null"
  if [[ "$degraded_recovery" -eq 1 ]]; then
    degraded_at_json="\"$now\""
  fi
  jq -n \
    --arg session_id "$session_id" \
    --arg repo "$repo" \
    --argjson concurrency "$concurrency" \
    --argjson soft "$soft_concurrency" \
    --argjson pid "$pid" \
    --argjson degraded_recovery_at "$degraded_at_json" \
    --arg now "$now" \
    '{
       session_id: $session_id,
       repo: $repo,
       concurrency: $concurrency,
       soft_collision_concurrency: $soft,
       pid: $pid,
       started_at: $now,
       updated_at: $now,
       degraded_recovery_at: $degraded_recovery_at,
       session_end: null,
       in_flight: {},
       # returned_agent_ids (issue #1237): persisted counterpart to the
       # session-local reconciled_agent_ids working-memory set. Written by
       # steady-state.md A.1, once per dispatch, BEFORE any per-mode reap
       # runs -- maps agent-id to an iso8601 timestamp. worktree-reap.sh
       # reap --action reaped consults it as the mechanical proof that an
       # agent own terminal return reached the orchestrator before its
       # worktree is destroyed; a merged PR or a green rollup observed by
       # some other channel is not that proof. See worktree-reap.sh reap
       # docstring for the full gate plus the documented
       # bypass-return-check exceptions.
       returned_agent_ids: {},
       ready_issues: [],
       failed_prs: [],
       raw_backlog: [],
       unfiltered_open_count: 0,
       me_assigned_open: 0,
       last_fresh_fetch: null,
       divert_queue: [],
       # awaiting_external — the #1390 park queue: workers that finished
       # everything they could and are waiting on a long external job. One
       # entry per parked worker; the orchestrator re-runs the probe on
       # each entry every periodic-refresh tick and resumes that SAME agent
       # when it goes terminal. Not a human hand-back until the bound
       # (awaiting_external.max_hours) expires.
       awaiting_external: [],
       session_prs: [],
       deferred_issues: [],
       soft_caps: {},
       stalled_dispatches: [],
       dispatch_denials: [],
       main_ci: {
         status: "unknown",
         earliest_red_run_id: null,
         earliest_red_run_url: null,
         earliest_red_sha: null,
         checked_at: null
       },
       drain: {
         active: false,
         started_at: null,
         polls: 0
       },
       tokens: {
         totals: {
           input: 0,
           output: 0,
           cache_read: 0,
           cache_creation: 0,
           estimated_usd: 0,
           degraded_attribution_count: 0
         },
         per_issue: {},
         per_pr: {},
         per_invocation: [],
         unpriced_models: []
       },
       setup: null
     }' | atomic_write "$target"
}

cmd_read() {
  local session_id=""
  local path=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      --path) path="${2:-}"; shift 2 ;;
      *) echo "read: unknown arg $1" >&2; usage_error "read" ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "read: --session-id is required" >&2
    usage_error "read"
  fi

  local target
  target=$(session_path "$session_id")

  if [[ ! -f "$target" ]]; then
    echo "read: $target does not exist" >&2
    exit 3
  fi

  if [[ -z "$path" ]]; then
    cat "$target"
  else
    # `jq -r` so string values come out unquoted (matches the
    # caller-friendly shape the tests assert on). Use the user-supplied
    # path verbatim — they're the trusted side of this call (the
    # orchestrator's own scripts).
    jq -r "$path" "$target"
  fi
}

cmd_update() {
  local session_id=""
  local -a sets=()
  # Internal flag — disables the opportunistic auto-flush of the
  # setup-timing sidecar (see below). Used by setup-timing.sh's own flush
  # call into `update` to avoid recursive auto-flush. Not part of the
  # documented public CLI surface; callers outside this script should
  # leave it off.
  local skip_timing_autoflush=0
  # --allow-degraded-init and --degraded-init-repo extend the same recovery
  # path bump-tokens has carried since issue #253 to the `update` subcommand
  # (issue #281). The original repro: an orchestrator-side `update` call
  # during the drain phase returned exit 3 because a concurrent /do-work
  # session's orphan-sweep had reaped this session's file (the PID-liveness
  # gate failed in some still-unidentified way, but the failure was real:
  # `lightwork-20260523T193509Z-9686` lost its state mid-session). bump-
  # tokens had a degraded-recovery path; update did not. Result: the
  # orchestrator had to call `init --force` by hand to recover, and any
  # working-memory mirroring `update` between the disappear and the manual
  # init-force silently failed at exit 3.
  #
  # With this flag set, an `update` against a missing file recreates a
  # minimal state file via `cmd_init --degraded-recovery` (same shape and
  # `.degraded_recovery_at` stamp as bump-tokens) and then proceeds with
  # the update. State from before the disappear is lost (the file was
  # gone), but every subsequent update lands somewhere durable. Callers
  # that want strict "must-have-pre-existing-file" semantics simply omit
  # the flag — the original exit-3 behaviour is preserved by default to
  # avoid masking real bugs (forgotten init, wrong session-id, etc.).
  local allow_degraded_init=0
  local degraded_init_repo=""
  # --expected-repo / --skip-repo-check are the issue #365 cross-repo
  # write guard. When --expected-repo is set (or SHIPYARD_EXPECTED_REPO
  # is in the env), refuse the write if the session file's .repo doesn't
  # match. --skip-repo-check is the explicit override for legitimate
  # cross-repo helpers (e.g., the orphan-sweep at setup.md step 1.6).
  local expected_repo="${SHIPYARD_EXPECTED_REPO:-}"
  local skip_repo_check=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      --set) sets+=("${2:-}"); shift 2 ;;
      # --set-file <path> (issue #1561): read one jq expression from a file
      # instead of the command line. Post-relocation, the worktree-isolation
      # guard refuses an `update` whose `--set` value carries a JSON object
      # literal (`.in_flight = {"slot-1": {...}}`) as "too complex to
      # verify". Writing the expression with the Write tool and passing its
      # path keeps the Bash call plain. The whole file is ONE expression
      # (newlines allowed); order relative to --set flags is preserved.
      --set-file)
        local set_file="${2:-}"
        if [[ -z "$set_file" || ! -f "$set_file" || ! -r "$set_file" ]]; then
          echo "update: --set-file '${set_file}' is not a readable file" >&2
          usage_error "update"
        fi
        local set_file_expr
        set_file_expr=$(cat "$set_file")
        if [[ -z "${set_file_expr//[[:space:]]/}" ]]; then
          echo "update: --set-file '${set_file}' is empty" >&2
          usage_error "update"
        fi
        sets+=("$set_file_expr")
        shift 2
        ;;
      --skip-timing-autoflush) skip_timing_autoflush=1; shift ;;
      --allow-degraded-init) allow_degraded_init=1; shift ;;
      --degraded-init-repo) degraded_init_repo="${2:-}"; shift 2 ;;
      --expected-repo) expected_repo="${2:-}"; shift 2 ;;
      --skip-repo-check) skip_repo_check=1; shift ;;
      *) echo "update: unknown arg $1" >&2; usage_error "update" ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "update: --session-id is required" >&2
    usage_error "update"
  fi
  if [[ ${#sets[@]} -eq 0 ]]; then
    echo "update: at least one --set <jq-expr> or --set-file <path> is required" >&2
    usage_error "update"
  fi

  local target
  target=$(session_path "$session_id")

  # Cross-repo write guard (issue #365). Run BEFORE the file-existence /
  # degraded-recovery branch — if the file exists and its .repo doesn't
  # match, refuse before any other side effects. When the file is
  # missing AND --allow-degraded-init is set, the check is a no-op (the
  # degraded-recovery init below writes --degraded-init-repo into .repo,
  # which is by construction what the caller expected).
  if [[ "$skip_repo_check" -eq 0 ]]; then
    if ! check_repo_match "$target" "$expected_repo" "update"; then
      exit 66
    fi
  fi

  if [[ ! -f "$target" ]]; then
    if [[ "$allow_degraded_init" -eq 1 ]]; then
      # Degraded recovery: the file disappeared while the session was
      # running (issue #281 — same race surface as #253's bump-tokens
      # recovery, but for the `update` codepath). Recreate a minimal
      # session file marked as degraded-recovery, then fall through to
      # the update. Use the supplied repo string or a sentinel.
      local recovery_repo="${degraded_init_repo:-unknown/unknown}"
      if ! cmd_init \
            --session-id "$session_id" \
            --repo "$recovery_repo" \
            --degraded-recovery \
            >/dev/null; then
        echo "update: degraded recovery init failed for $target" >&2
        exit 68
      fi
      # Log the recovery to stderr — invisible to callers that 2>/dev/null
      # but visible in the orchestrator transcript so the user knows
      # session state was recreated mid-session.
      echo "update: $target was missing — degraded-init recovered (state from before the disappear is lost)" >&2
    else
      echo "update: $target does not exist (use init first)" >&2
      exit 3
    fi
  fi

  # Self-healing setup-timing flush (issue #283). The orchestrator is
  # supposed to call `setup-timing.sh flush` at step 6.8, but the
  # flush is structurally easy to skip (one bash block buried in a
  # long step body, fire-and-forget posture hides silent skips,
  # `concurrency == 1` skip-list misread as "skip every timing call").
  # `cmd_update` is called dozens of times per session for working-
  # memory mirroring, so opportunistically firing the flush here turns
  # the orchestrator-side discipline into a mechanical guarantee: if a
  # sidecar exists and `.setup` is still null, the next update closes
  # the gap. Cheap check (one stat + one jq) on every update; the
  # actual flush only fires at most once per session because after
  # success `.setup` is no longer null. The `--skip-timing-autoflush`
  # flag is set by setup-timing.sh's own flush call back into update
  # so this branch doesn't recurse on itself.
  if [[ "$skip_timing_autoflush" -eq 0 ]]; then
    local sidecar="${target%.json}.timing.json"
    if [[ -f "$sidecar" ]]; then
      local current_setup
      current_setup=$(jq -r '.setup // "null"' "$target" 2>/dev/null)
      if [[ "$current_setup" == "null" ]]; then
        # Locate setup-timing.sh relative to this script. Fire-and-forget:
        # a flush failure must NOT block the caller's update. Capture the
        # exit status explicitly (rather than swallowing it with
        # `|| true`) so a persistently-failing flush leaves a trace: a
        # stderr diagnostic visible to a `2>&1`-attached debugging session
        # but invisible by default (matching the degraded-recovery
        # precedent a few dozen lines above). Before this, the autoflush
        # failed silently on every single cmd_update call with nothing
        # anywhere recording it — issue #876.
        local this_dir flush_status=0
        this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [[ -f "${this_dir}/setup-timing.sh" ]]; then
          "${this_dir}/setup-timing.sh" flush --session-id "$session_id" 2>/dev/null || flush_status=$?
          if [[ "$flush_status" -ne 0 ]]; then
            printf 'update: setup-timing-autoflush-failed session=%s status=%s (visible via 2>&1, suppressed by default)\n' \
              "$session_id" "$flush_status" >&2
          fi
        fi
      fi
    fi
  fi

  # Compose all --set expressions into a single jq pipeline. Each --set is
  # a complete assignment; piping them through `|` makes a single jq
  # invocation that touches the file once. The `.updated_at = <now>`
  # bookend gives every successful write a fresh timestamp.
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local jq_pipeline=""
  for expr in "${sets[@]}"; do
    if [[ -z "$jq_pipeline" ]]; then
      jq_pipeline="$expr"
    else
      jq_pipeline="$jq_pipeline | $expr"
    fi
  done
  jq_pipeline="$jq_pipeline | .updated_at = \$now"

  if ! jq --arg now "$now" "$jq_pipeline" "$target" | atomic_write "$target"; then
    echo "update: jq expression failed — file left unchanged" >&2
    exit 68
  fi
}

# shellcheck disable=SC2016
# rationale: this function builds jq programs whose single-quoted bodies
# reference jq variables (`$input`, `$pr`, `$usd_delta`, etc.) bound via the
# `--arg` / `--argjson` flags. The single-quoted form is the correct,
# safe shape — shell expansion would corrupt the jq program. The disable
# is scoped to this function only.
cmd_bump_tokens() {
  local session_id=""
  local issue=""
  local pr=""
  local input=0
  local output=0
  local cache_read=0
  local cache_creation=0
  local mode=""
  local model=""
  # --allow-degraded-init makes bump-tokens resilient to a file-disappear-
  # mid-session event (issue #253). When the session file has been reaped
  # underneath us — e.g. by a concurrent /do-work session's orphan-sweep —
  # the bump can recreate a fresh, minimally-populated state file (marked
  # with .degraded_recovery_at so audits + metrics can distinguish it from
  # a healthy init) and proceed with the bump. Bumps that happened before
  # the disappear are still lost (the file is gone), but every bump from
  # the disappear forward lands somewhere durable and the session-level
  # ledger flush still has data to write at end-of-session. --degraded-
  # init-repo supplies the repo string for the recovery init (since
  # bump-tokens doesn't normally need to know the repo). Falls back to
  # "unknown/unknown" when not supplied — better to keep the data than
  # error out because of a missing string field.
  local allow_degraded_init=0
  local degraded_init_repo=""
  # --degraded-total-only is a *separate* degraded path from
  # --allow-degraded-init (which addresses #253's file-disappear race).
  # It addresses #279's harness-side gap: when the Claude Code sub-agent
  # task-notification <usage> block only emits `total_tokens` (no input/
  # output/cache breakdown), the orchestrator's A.0 attribution can't pass
  # the four required counts. Without this flag the only options are
  # (a) skip the bump entirely — leaving every cost-tracking comment at
  # $0 — or (b) silently collapse total_tokens into --input, which lies
  # about the breakdown and was explicitly forbidden by #225. With the
  # flag, callers pass `--input <total_tokens>` (other token flags MUST
  # be omitted / zero), the bump lands in the input bucket, and the
  # per_invocation entry is marked with `degraded: true` so downstream
  # readers can distinguish degraded attribution from a real input-only
  # invocation. The session-level `.tokens.degraded_attribution_count`
  # counter increments on every degraded bump so the end-of-session
  # summary can surface a one-line banner.
  local degraded_total_only=0
  # --expected-repo / --skip-repo-check — issue #365 cross-repo write
  # guard, same shape as cmd_update. The cross-session contamination
  # race specifically affects bump-tokens because that's where token
  # attributions land; without the guard, a stash-file race silently
  # cross-wires cost ledgers between sessions.
  local expected_repo="${SHIPYARD_EXPECTED_REPO:-}"
  local skip_repo_check=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      --issue) issue="${2:-}"; shift 2 ;;
      --pr) pr="${2:-}"; shift 2 ;;
      --input) input="${2:-0}"; shift 2 ;;
      --output) output="${2:-0}"; shift 2 ;;
      --cache-read) cache_read="${2:-0}"; shift 2 ;;
      --cache-creation) cache_creation="${2:-0}"; shift 2 ;;
      --mode) mode="${2:-}"; shift 2 ;;
      --model) model="${2:-}"; shift 2 ;;
      --allow-degraded-init) allow_degraded_init=1; shift ;;
      --degraded-init-repo) degraded_init_repo="${2:-}"; shift 2 ;;
      --degraded-total-only) degraded_total_only=1; shift ;;
      --expected-repo) expected_repo="${2:-}"; shift 2 ;;
      --skip-repo-check) skip_repo_check=1; shift ;;
      *) echo "bump-tokens: unknown arg $1" >&2; usage_error "bump-tokens" ;;
    esac
  done

  # --degraded-total-only callers must NOT pass any breakdown fields.
  # The flag's contract is "I only have total_tokens — surface it on
  # --input." Passing --output / --cache-read / --cache-creation
  # alongside is a programming error (mixed-mode attribution would
  # silently corrupt the data) — reject usage-error rather than guess.
  #
  # The flag also requires a non-zero --input. A real agent completion
  # always has non-zero total_tokens; --input 0 (or --input omitted,
  # which defaults to 0) is the orchestrator copy-paste trap from
  # issue #320: the canonical call shape paired --degraded-total-only
  # with `--input 0 --output 0 --cache-read 0 --cache-creation 0`
  # (defaults from the strict path), and every degraded bump in the
  # session silently recorded $0. Fail loud rather than swallow the
  # whole session's spend.
  if [[ "$degraded_total_only" -eq 1 ]]; then
    if [[ "$output" != "0" ]] || [[ "$cache_read" != "0" ]] || [[ "$cache_creation" != "0" ]]; then
      echo "bump-tokens: --degraded-total-only is exclusive with --output / --cache-read / --cache-creation (pass --input <total_tokens> only)" >&2
      exit 64
    fi
    if [[ "$input" == "0" ]] || [[ -z "$input" ]]; then
      echo "bump-tokens: --degraded-total-only requires --input <total_tokens> (got --input 0 — pass the actual total from the <usage> block, not the breakdown-fields default)" >&2
      exit 64
    fi
  fi

  if [[ -z "$session_id" ]]; then
    echo "bump-tokens: --session-id is required" >&2
    usage_error "bump-tokens"
  fi

  local target
  target=$(session_path "$session_id")

  # Cross-repo write guard (issue #365). Same shape as cmd_update —
  # check before the file-existence / degraded-recovery branch.
  if [[ "$skip_repo_check" -eq 0 ]]; then
    if ! check_repo_match "$target" "$expected_repo" "bump-tokens"; then
      exit 66
    fi
  fi

  if [[ ! -f "$target" ]]; then
    if [[ "$allow_degraded_init" -eq 1 ]]; then
      # Degraded recovery: the file disappeared while the session was
      # running (issue #253 — concurrent orphan-sweep race). Recreate a
      # minimal session file marked as degraded-recovery, then fall
      # through to the bump. Use the supplied repo string or a sentinel.
      local recovery_repo="${degraded_init_repo:-unknown/unknown}"
      # Stamp with this script's PPID — the bash that invoked us. Same
      # default semantics as a normal init.
      if ! cmd_init \
            --session-id "$session_id" \
            --repo "$recovery_repo" \
            --degraded-recovery \
            >/dev/null; then
        echo "bump-tokens: degraded recovery init failed for $target" >&2
        exit 68
      fi
      # Log the recovery to stderr — invisible to callers that 2>/dev/null
      # but visible in the orchestrator transcript so the user knows
      # cost-tracking degraded mid-session.
      echo "bump-tokens: $target was missing — degraded-init recovered (cost data from before the disappear is lost)" >&2
    else
      echo "bump-tokens: $target does not exist (use init first)" >&2
      exit 3
    fi
  fi

  # Normalise unset counts to 0; reject negative deltas (the orchestrator
  # never subtracts tokens, only adds them — guard against typos).
  local n
  for n in "$input" "$output" "$cache_read" "$cache_creation"; do
    if ! [[ "$n" =~ ^[0-9]+$ ]]; then
      echo "bump-tokens: token counts must be non-negative integers (got: $n)" >&2
      exit 64
    fi
  done

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Compose the jq pipeline. The structure mirrors the orchestrator's three
  # attribution levels: always bump `.tokens.totals`; conditionally bump the
  # per-issue / per-pr buckets when --issue / --pr is supplied; always
  # append a `per_invocation` ring-buffer entry (cap at 200) for trace.
  #
  # `cost` is computed from the pricing row resolved by `resolve_pricing_row`:
  #
  #   usd = (input * P.input + output * P.output
  #        + cache_read * P.cache_read + cache_creation * P.cache_creation) / 1e6
  #
  # Unpriced model (a non-empty --model that misses the table) → the token
  # counts are still recorded, but the dispatch is flagged rather than
  # silently booked at $0.00 (issue #728). We warn loudly on stderr and mark
  # the invocation + the session-level `unpriced_models` set so every
  # downstream reader can label the USD figure a LOWER BOUND.
  #
  # An *empty* --model is a different thing (the caller didn't attribute a
  # model at all) and is NOT flagged as unpriced — `per_invocation[].model`
  # is already null, which is self-describing.
  local price_row
  price_row=$(resolve_pricing_row "$model")
  local unpriced=0
  if [[ -n "$model" && -z "$price_row" ]]; then
    unpriced=1
    echo "bump-tokens: WARNING — model '${model}' is not in the pricing table; its token counts are recorded but its USD cost is UNKNOWN (booked as 0). Session USD totals are a LOWER BOUND. Add the model to PRICING_JQ in $(basename "${BASH_SOURCE[0]}") — see https://github.com/mattsears18/shipyard/issues/728" >&2
  fi

  # --------------------------------------------------------------------------
  # Mode/model policy-consistency check (issue #978). `--model` is the
  # ORCHESTRATOR's self-reported belief about which model a dispatch ran on —
  # nothing in the harness exposes "which model did this Agent dispatch
  # actually run on" after the fact, so bump-tokens cannot verify the claim
  # against ground truth. What it CAN check is policy consistency: when
  # `--mode` names a mode that has a `models.<mode>` override configured for
  # this repo, does the billed model's family agree with that override? A
  # mismatch here is exactly the failure that produced a confidently-wrong
  # $4.39 total for a session that actually burned 2.6M+ tokens on Opus — the
  # orchestrator self-reported `claude-sonnet-5` for dispatches that had
  # really run on Opus. This is advisory-only and fails open: an unreadable
  # config, a missing resolver script, or an unresolvable mode/model all skip
  # the check silently rather than block the bump — the token counts must
  # land either way.
  #
  # Re-derive the SHIPYARD_REPO_ROOT pin before resolving (issue #1185). This
  # call is on the every-reconcile-turn hot path and is invoked from a fresh
  # `Bash` tool call each time (shell state — including any export the
  # orchestrator's own preamble made in a PRIOR call — does not survive
  # across calls), so without this re-derivation `resolve-dispatch-model.sh`
  # (via `shipyard-config.sh`) falls back to resolving config against cwd —
  # post-relocation the orchestrator worktree, a fresh checkout that by
  # construction can never contain the gitignored `.shipyard/config.local.json`
  # layer. That silently drops a repo/user/local override back to shipyard's
  # own built-in default and produces a FALSE mismatch warning against a
  # dispatch that was in fact correct. Mirror the same stash-file idiom every
  # other post-relocation call site uses (`setup/00-config-worktree.md` step
  # 0.56) — guarded so an already-set SHIPYARD_REPO_ROOT (an explicit caller
  # override, or a value inherited from this same process's environment)
  # stays authoritative and is never clobbered.
  if [[ -z "${SHIPYARD_REPO_ROOT:-}" ]]; then
    local _pin_root _pin
    _pin_root=$(git rev-parse --show-toplevel 2>/dev/null)
    if [[ -n "$_pin_root" ]]; then
      _pin=$(cat "${_pin_root}/.shipyard-primary-root" 2>/dev/null)
      [[ -n "$_pin" ]] && export SHIPYARD_REPO_ROOT="$_pin"
    fi
  fi

  if [[ -n "$mode" && -n "$model" ]]; then
    local dispatch_model_resolver
    dispatch_model_resolver="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-dispatch-model.sh"
    if [[ -f "$dispatch_model_resolver" ]]; then
      local expected_family actual_family
      expected_family=$(bash "$dispatch_model_resolver" "$mode" 2>/dev/null) || expected_family=""
      if [[ -n "$expected_family" ]]; then
        actual_family=$(bash "$dispatch_model_resolver" --map "$model" 2>/dev/null) || actual_family=""
        if [[ -n "$actual_family" && "$actual_family" != "$expected_family" ]]; then
          # Suppress rather than warn when the resolved value is merely
          # shipyard's own built-in default (issue #1185) — every mode has
          # a built-in `models.<mode>` entry, so `expected_family` is
          # non-empty even with NO repo/user/local override configured. A
          # mismatch against a genuinely-configured override is strong
          # evidence something is wrong; a mismatch against the built-in
          # default is the exact shape a lost config layer (or simply "no
          # override was ever set") produces, and warning on it makes the
          # check fire on every dispatch for a mode nobody overrode.
          local expected_source
          expected_source=$(bash "$dispatch_model_resolver" --source "$mode" 2>/dev/null) || expected_source=""
          if [[ "$expected_source" != "defaults" ]]; then
            echo "bump-tokens: WARNING — mode '${mode}' is billed against model '${model}' (family: ${actual_family}), but models.${mode} resolves to '${expected_family}' in the merged config rooted at ${SHIPYARD_REPO_ROOT:-$(pwd)}. Either the dispatch didn't honor the configured override, or --model was reported incorrectly — this session's cost attribution for this mode may be wrong. See https://github.com/mattsears18/shipyard/issues/978" >&2
          fi
        fi
      fi
    fi
  fi
  # A miss still needs a numeric row for the arithmetic below; the `unpriced`
  # flag — not the zeros — is what carries "we don't know what to charge".
  [[ -z "$price_row" ]] && price_row='{"input":0,"output":0,"cache_read":0,"cache_creation":0}'

  local jq_args=(
    --arg now "$now"
    --argjson input "$input"
    --argjson output "$output"
    --argjson cache_read "$cache_read"
    --argjson cache_creation "$cache_creation"
    --arg mode "$mode"
    --arg model "$model"
    --arg issue "$issue"
    --arg pr "$pr"
    --argjson p "$price_row"
    --argjson unpriced "$unpriced"
    --argjson degraded "$degraded_total_only"
    --argjson mix "$DEGRADED_BLEND_MIX_JQ"
  )

  local issue_branch=""
  if [[ -n "$issue" ]]; then
    if ! [[ "$issue" =~ ^[0-9]+$ ]]; then
      echo "bump-tokens: --issue must be a positive integer (got: $issue)" >&2
      exit 64
    fi
    # degraded_attribution_count (issue #1218) lives INSIDE this bucket
    # object, not just at the session-level .tokens.degraded_attribution_count
    # — the goal is that a reader holding only this bucket (e.g. the
    # persisted per-issue ledger row cost-history.sh projects from it) can
    # tell "genuinely zero output" from "output folded into input, unknown"
    # without fetching a different record. A plain 0/1 counter (not a null
    # on .output) is required here because this bucket accumulates across
    # possibly many bump-tokens calls — some real, some degraded — and
    # nulling .output on a degraded bump would destroy real output tokens
    # already summed in from an earlier, non-degraded bump for the same
    # issue. The counter composes correctly with the existing `+=`
    # accumulation: it only ever increments, never nulls out real data.
    issue_branch='
      | .tokens.per_issue[$issue] //= {input: 0, output: 0, cache_read: 0, cache_creation: 0, estimated_usd: 0, degraded_attribution_count: 0}
      | .tokens.per_issue[$issue].input          += $input
      | .tokens.per_issue[$issue].output         += $output
      | .tokens.per_issue[$issue].cache_read     += $cache_read
      | .tokens.per_issue[$issue].cache_creation += $cache_creation
      | .tokens.per_issue[$issue].estimated_usd  += $usd_delta
      | (if $degraded == 1 then
           .tokens.per_issue[$issue].degraded_attribution_count = ((.tokens.per_issue[$issue].degraded_attribution_count // 0) + 1)
         else . end)
    '
  fi

  local pr_branch=""
  if [[ -n "$pr" ]]; then
    if ! [[ "$pr" =~ ^[0-9]+$ ]]; then
      echo "bump-tokens: --pr must be a positive integer (got: $pr)" >&2
      exit 64
    fi
    # Same self-contained-bucket rationale as issue_branch above (issue #1218).
    pr_branch='
      | .tokens.per_pr[$pr] //= {input: 0, output: 0, cache_read: 0, cache_creation: 0, estimated_usd: 0, issue: null, degraded_attribution_count: 0}
      | .tokens.per_pr[$pr].input          += $input
      | .tokens.per_pr[$pr].output         += $output
      | .tokens.per_pr[$pr].cache_read     += $cache_read
      | .tokens.per_pr[$pr].cache_creation += $cache_creation
      | .tokens.per_pr[$pr].estimated_usd  += $usd_delta
      | (if $degraded == 1 then
           .tokens.per_pr[$pr].degraded_attribution_count = ((.tokens.per_pr[$pr].degraded_attribution_count // 0) + 1)
         else . end)
    '
    # If an --issue was provided alongside --pr, cross-link them so a future
    # PR-targeted read can resolve the corresponding issue without a GitHub
    # round-trip.
    if [[ -n "$issue" ]]; then
      pr_branch="$pr_branch
      | .tokens.per_pr[\$pr].issue = (\$issue | tonumber)
      "
    fi
  fi

  # Compose the full pipeline. `$usd_delta` is computed once at the top and
  # reused in every accumulator below. `$p` (the pricing row) and `$unpriced`
  # are resolved shell-side by `resolve_pricing_row` so the warning and the
  # arithmetic can never disagree about whether the model was priced.
  #
  # Degraded branch (issue #1330): a `--degraded-total-only` bump has its
  # entire total folded into `$input` (the strict-path fields are all 0 —
  # enforced above), so pricing it at `$p.input` alone is exactly what the
  # non-degraded formula below already reduces to for that shape. Instead,
  # apply `$mix` (DEGRADED_BLEND_MIX_JQ) as a blended per-token rate: the
  # assumed fraction of the total actually spent in each bucket, times that
  # bucket's rate. This replaces the pre-#1330 behavior of pricing 100% of
  # a degraded total at the (comparatively expensive, and structurally
  # wrong-shaped for an agentic dispatch) input rate. The non-degraded
  # branch is byte-for-byte the pre-existing formula — a real breakdown
  # bump's price never depends on `$mix`.
  local jq_pipeline='
    (
      if $degraded == 1 then
        ($input * (
             (($mix.input          // 0) * ($p.input // 0))
           + (($mix.output         // 0) * ($p.output // 0))
           + (($mix.cache_read     // 0) * ($p.cache_read // 0))
           + (($mix.cache_creation // 0) * ($p.cache_creation // 0))
         )) / 1000000
      else
        ($input * ($p.input // 0)
         + $output * ($p.output // 0)
         + $cache_read * ($p.cache_read // 0)
         + $cache_creation * ($p.cache_creation // 0)
        ) / 1000000
      end
      ) as $usd_delta
    | .tokens.unpriced_models //= []
    | (if $unpriced == 1
         then .tokens.unpriced_models = ((.tokens.unpriced_models + [$model]) | unique)
         else . end)
    | .tokens.totals.input          += $input
    | .tokens.totals.output         += $output
    | .tokens.totals.cache_read     += $cache_read
    | .tokens.totals.cache_creation += $cache_creation
    | .tokens.totals.estimated_usd  += $usd_delta
    '"$issue_branch""$pr_branch"'
    | .tokens.per_invocation += [{
        at: $now,
        mode: ($mode | if . == "" then null else . end),
        model: ($model | if . == "" then null else . end),
        issue: ($issue | if . == "" then null else (. | tonumber) end),
        pr: ($pr | if . == "" then null else (. | tonumber) end),
        input: $input,
        output: $output,
        cache_read: $cache_read,
        cache_creation: $cache_creation,
        estimated_usd: $usd_delta,
        unpriced: ($unpriced == 1),
        degraded: ($degraded == 1)
      }]
    | .tokens.per_invocation = (.tokens.per_invocation | if length > 200 then .[-200:] else . end)
    | (if $degraded == 1 then
         .tokens.degraded_attribution_count = ((.tokens.degraded_attribution_count // 0) + 1)
         | .tokens.totals.degraded_attribution_count = ((.tokens.totals.degraded_attribution_count // 0) + 1)
       else . end)
    | .updated_at = $now
  '

  if ! jq "${jq_args[@]}" "$jq_pipeline" "$target" | atomic_write "$target"; then
    echo "bump-tokens: jq expression failed — file left unchanged" >&2
    exit 68
  fi
}

# shellcheck disable=SC2016
# rationale: same as cmd_bump_tokens — the jq programs in this function
# use single quotes to wrap jq syntax with embedded jq variables, not
# shell variables. Single-quoting is correct.
cmd_read_tokens() {
  local session_id=""
  local issue=""
  local pr=""
  local format="json"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      --issue) issue="${2:-}"; shift 2 ;;
      --pr) pr="${2:-}"; shift 2 ;;
      --format) format="${2:-json}"; shift 2 ;;
      *) echo "read-tokens: unknown arg $1" >&2; usage_error "read-tokens" ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "read-tokens: --session-id is required" >&2
    usage_error "read-tokens"
  fi

  if [[ "$format" != "json" && "$format" != "comment" ]]; then
    echo "read-tokens: --format must be 'json' or 'comment' (got: $format)" >&2
    exit 64
  fi

  local target
  target=$(session_path "$session_id")

  if [[ ! -f "$target" ]]; then
    echo "read-tokens: $target does not exist" >&2
    exit 3
  fi

  # 0-byte file guard (issue #357). A session file that exists but is empty
  # is a known corruption mode from prior shipyard versions where an
  # `update`'s failed jq pipeline could silently truncate the file (root
  # cause fixed in atomic_write but legacy state may persist on disk).
  # Without this guard, the jq scope projection below would produce an
  # empty object and the `--format comment` branch would emit a
  # zero-cost cost-tracking comment on the issue/PR — misleading to the
  # reader (looks like the worker did nothing) and worse than no comment
  # at all. Surface the corruption with a clear message and exit 3 so
  # the orchestrator's posting branch skips the comment rather than
  # publish a $0 stub.
  if [[ ! -s "$target" ]]; then
    echo "[cost-tracking] session file 0-byte at read-tokens; cost data unrecoverable for session $session_id" >&2
    exit 3
  fi

  # Resolve the scope. --pr wins over --issue if both supplied (the comment
  # surfaces on the PR; issue scoping is only used for /shipyard:my-turn
  # cost surfacing). Without either, scope is session-wide totals.
  local scope_jq
  # `unpriced_jq` yields the set of unpriced model ids in scope (issue #728).
  # Session scope reads the durable session-level set; issue/pr scope derives
  # it from the matching per_invocation entries. (The per_invocation ring
  # buffer is capped at 200, so the session-level set — which never forgets —
  # is the authoritative one where it's available.)
  local unpriced_jq
  if [[ -n "$pr" ]]; then
    scope_jq='.tokens.per_pr[$key] // {input:0, output:0, cache_read:0, cache_creation:0, estimated_usd:0, issue:null, degraded_attribution_count:0}'
    unpriced_jq='[.tokens.per_invocation[]? | select(.pr == ($key | tonumber)) | select(.unpriced == true) | .model] | unique'
  elif [[ -n "$issue" ]]; then
    scope_jq='.tokens.per_issue[$key] // {input:0, output:0, cache_read:0, cache_creation:0, estimated_usd:0, degraded_attribution_count:0}'
    unpriced_jq='[.tokens.per_invocation[]? | select(.issue == ($key | tonumber)) | select(.unpriced == true) | .model] | unique'
  else
    scope_jq='.tokens.totals'
    unpriced_jq='.tokens.unpriced_models // []'
  fi

  local key=""
  if [[ -n "$pr" ]]; then
    key="$pr"
  elif [[ -n "$issue" ]]; then
    key="$issue"
  fi

  if [[ "$format" == "json" ]]; then
    # `unpriced_models` rides alongside the scope's token counts so a JSON
    # consumer can tell "this cost $0" from "we don't know what this cost".
    # `estimated_usd_degraded` / `estimated_usd_upper_bound` (issue #1327)
    # make the degraded-ness of this scope structurally visible in the
    # emitted JSON itself, rather than requiring the reader to separately
    # remember to check degraded_attribution_count before trusting
    # estimated_usd. A scope object from an older shipyard session file
    # with no degraded_attribution_count field reads `// 0` — not
    # degraded, no upper-bound marker — so this stays backward compatible
    # without any change to the write path (bump-tokens) or a stored
    # schema.
    #
    # estimated_usd_upper_bound is a TRUE ceiling (issue #1330), not a
    # mirror of estimated_usd. Before #1330, a degraded scope's
    # estimated_usd was itself computed by pricing the whole total at the
    # `input` rate, which — loosely — over-stated cost relative to the
    # (cheaper) cache_read-dominated mix a real dispatch actually has, so
    # mirroring it as "the upper bound" was a defensible approximation.
    # Now that bump-tokens prices a degraded total with a blended mix
    # (DEGRADED_BLEND_MIX_JQ, itself an assumption, not a measurement),
    # estimated_usd is a best-effort estimate that could in principle land
    # on either side of the true cost — it is no longer definitionally a
    # ceiling. The true ceiling is computed independently of both the mix
    # and whichever model billed this scope: the scope's total token count
    # (every bucket summed, since a degraded bump could in principle have
    # been priced at any bucket's rate) times the single most expensive
    # per-token rate found anywhere in PRICING_JQ.
    jq --arg key "$key" \
       --argjson pricing "$(jq -c -n "$PRICING_JQ")" "
      ($scope_jq) as \$__scope
      | (((\$__scope.degraded_attribution_count // 0)) > 0) as \$__degraded
      | ([\$pricing[] | .input, .output, .cache_read, .cache_creation] | max) as \$__max_rate_per_1m
      | ((\$__scope.input // 0) + (\$__scope.output // 0) + (\$__scope.cache_read // 0) + (\$__scope.cache_creation // 0)) as \$__total_tokens
      | \$__scope + {
          unpriced_models: ($unpriced_jq),
          estimated_usd_degraded: \$__degraded,
          estimated_usd_upper_bound: (if \$__degraded then ((\$__total_tokens * \$__max_rate_per_1m) / 1000000) else null end)
        }
      " "$target"
    return 0
  fi

  # format=comment: emit a Markdown body marked with the dedup sentinel.
  # Mode counts come from per_invocation entries that match the scope.
  local mode_filter
  local scope_label
  if [[ -n "$pr" ]]; then
    mode_filter='[.tokens.per_invocation[] | select(.pr == ($key | tonumber))]'
    scope_label="PR #$pr"
  elif [[ -n "$issue" ]]; then
    mode_filter='[.tokens.per_invocation[] | select(.issue == ($key | tonumber))]'
    scope_label="Issue #$issue"
  else
    mode_filter='.tokens.per_invocation'
    scope_label="session"
  fi

  local session_repo
  session_repo=$(jq -r '.repo' "$target")
  local session_started
  session_started=$(jq -r '.started_at' "$target")
  local session_id_str
  session_id_str=$(jq -r '.session_id' "$target")

  jq -r \
    --arg key "$key" \
    --arg scope_label "$scope_label" \
    --arg session_id "$session_id_str" \
    --arg started "$session_started" \
    --arg repo "$session_repo" \
    "
    ($scope_jq) as \$scope
    | ($unpriced_jq) as \$unpriced
    | ($mode_filter) as \$invocations
    | (\$invocations | map(.mode) | unique | map(select(. != null)) | join(\", \")) as \$modes
    | (\$invocations | map(.model) | unique | map(select(. != null)) | join(\", \")) as \$models
    | (\$invocations | length) as \$count
    | (\$scope.input + \$scope.output + \$scope.cache_read + \$scope.cache_creation) as \$total_tokens
    | (\$scope.degraded_attribution_count // 0) as \$__cost_degraded_count
    | (\$__cost_degraded_count > 0) as \$__cost_degraded
    | (\$scope.estimated_usd | (. * 100 | round) as \$cents | \"\$\" + ((\$cents / 100 | floor) | tostring) + \".\" + ((\$cents % 100) | if . < 10 then \"0\\(.)\" else \"\\(.)\" end)) as \$__usd_formatted
    | (if \$__cost_degraded then
         \"~\" + \$__usd_formatted + \" (blended-rate estimate — token breakdown unavailable for \" + (\$__cost_degraded_count | tostring) + \"/\" + (\$count | tostring) + \" dispatches)\"
       else
         \$__usd_formatted
       end) as \$__cost_display
    | \"<!-- do-work-cost-tracking -->\n\" +
      \"### Shipyard cost — \" + \$scope_label + \"\n\n\" +
      \"| Metric | Value |\n\" +
      \"|---|---|\n\" +
      \"| Input tokens | \" + (\$scope.input | tostring) + \" |\n\" +
      \"| Output tokens | \" + (\$scope.output | tostring) + \" |\n\" +
      \"| Cache read | \" + (\$scope.cache_read | tostring) + \" |\n\" +
      \"| Cache creation | \" + (\$scope.cache_creation | tostring) + \" |\n\" +
      \"| **Total tokens** | **\" + (\$total_tokens | tostring) + \"** |\n\" +
      \"| Estimated cost (USD) | \" + \$__cost_display + \" |\n\" +
      \"| Worker invocations | \" + (\$count | tostring) + \" |\n\" +
      (if \$modes != \"\" then \"| Modes | \" + \$modes + \" |\n\" else \"\" end) +
      (if \$models != \"\" then \"| Models | \" + \$models + \" |\n\" else \"\" end) +
      \"| Session | \`\" + \$session_id + \"\` (\" + \$started + \") |\n\" +
      \"| Repo | \" + \$repo + \" |\n\n\" +
      (if (\$unpriced | length) > 0 then
         \"> ⚠️ **The USD figure above is a LOWER BOUND.** \" +
         (\$unpriced | length | tostring) +
         \" model(s) in this scope are missing from the pricing table, so their spend is booked as \$0.00: \" +
         (\$unpriced | map(\"\`\" + . + \"\`\") | join(\", \")) +
         \". Add them to \`PRICING_JQ\` in \`scripts/session-state.sh\` (see issue #728).\n\n\"
       else \"\" end) +
      (if (\$scope.degraded_attribution_count // 0) > 0 then
         \"> ⚠️ **UNRELIABLE — Output tokens / cache read / cache creation for this scope are undercounted.** \" +
         ((\$scope.degraded_attribution_count // 0) | tostring) +
         \" dispatch(es) in this scope used the total-tokens-only fallback (no input/output/cache breakdown from the harness), so their whole token total was folded into Input tokens above. This is not a lower or upper bound on Output/Cache figures — it depends on the real input/output/cache mix, which is exactly what is missing (see issue #1035, #1218).\n\n\"
       else \"\" end) +
      \"_Posted automatically by \`/shipyard:do-work\` for cost-tracking. Edit-or-create idempotency keyed on the HTML sentinel comment above._\n\"
    " "$target"
}

# shellcheck disable=SC2016
# rationale: this function builds jq programs whose single-quoted bodies
# reference jq variables (`$slot`, `$current`, `$total`) bound via the
# `--arg` / `--argjson` flags. The single-quoted form is the correct,
# safe shape — shell expansion would corrupt the jq program. The disable
# is scoped to this function only.
# --------------------------------------------------------------------------
# set-slot / release-slot (issue #1561) — flag-shaped hot-path writes.
#
# The orchestrator's per-dispatch `.in_flight` write used to be spelled as
# `update --set '.in_flight = {"slot-1": {kind: ..., ...}}'`. Post-relocation
# the worktree-isolation guard refuses that command (a JSON object literal in
# a --set value is "too complex to verify"), so the durable session record
# silently stopped updating and /shipyard:status showed nothing in flight.
# These subcommands take only plain flags, build the object with `jq -n
# --arg` (no string interpolation of caller values into jq source), and hand
# the resulting assignment to cmd_update — so they inherit its atomic write,
# degraded-init recovery, cross-repo guard, and `.updated_at` stamp.
# --------------------------------------------------------------------------

cmd_set_slot() {
  local session_id="" slot_id="" kind="" target_str="" agent_id="" model=""
  local started_at="" version_slot="" worktree_path=""
  local -a hard_paths=() soft_paths=() passthrough=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      --slot-id) slot_id="${2:-}"; shift 2 ;;
      --kind) kind="${2:-}"; shift 2 ;;
      --target) target_str="${2:-}"; shift 2 ;;
      --agent-id) agent_id="${2:-}"; shift 2 ;;
      --model) model="${2:-}"; shift 2 ;;
      --started-at) started_at="${2:-}"; shift 2 ;;
      --version-slot) version_slot="${2:-}"; shift 2 ;;
      --worktree-path) worktree_path="${2:-}"; shift 2 ;;
      --hard-path) hard_paths+=("${2:-}"); shift 2 ;;
      --soft-path) soft_paths+=("${2:-}"); shift 2 ;;
      --allow-degraded-init|--skip-repo-check) passthrough+=("$1"); shift ;;
      --degraded-init-repo|--expected-repo) passthrough+=("$1" "${2:-}"); shift 2 ;;
      *) echo "set-slot: unknown arg $1" >&2; usage_error "set-slot" ;;
    esac
  done

  if [[ -z "$session_id" || -z "$slot_id" || -z "$kind" || -z "$target_str" ]]; then
    echo "set-slot: --session-id, --slot-id, --kind and --target are required" >&2
    usage_error "set-slot"
  fi
  case "$kind" in
    issue|fix-checks|fix-rebase|fix-main-ci|fix-failing-prs-batch|investigate|spike) ;;
    *) echo "set-slot: --kind must be one of issue|fix-checks|fix-rebase|fix-main-ci|fix-failing-prs-batch|investigate|spike (got: $kind)" >&2
       exit 64 ;;
  esac
  if [[ -z "$started_at" ]]; then
    started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi

  local hard_json="[]" soft_json="[]"
  if [[ ${#hard_paths[@]} -gt 0 ]]; then
    hard_json=$(printf '%s\n' "${hard_paths[@]}" | jq -R . | jq -s -c .)
  fi
  if [[ ${#soft_paths[@]} -gt 0 ]]; then
    soft_json=$(printf '%s\n' "${soft_paths[@]}" | jq -R . | jq -s -c .)
  fi

  # Optional fields are omitted (not null) when unset, matching the schema's
  # "absent on a dispatch that carried no coordination paragraph" contract
  # for version_slot. agent_id and model default to null / "default".
  local record
  if ! record=$(jq -n -c \
      --arg kind "$kind" \
      --arg target "$target_str" \
      --arg agent_id "$agent_id" \
      --arg model "${model:-default}" \
      --arg started_at "$started_at" \
      --arg version_slot "$version_slot" \
      --arg worktree_path "$worktree_path" \
      --argjson hard "$hard_json" \
      --argjson soft "$soft_json" \
      '{kind: $kind, target: $target,
        claimed_paths: {hard: $hard, soft: $soft},
        agent_id: (if $agent_id == "" then null else $agent_id end),
        model: $model, started_at: $started_at,
        progress_current: null, progress_total: null, progress_updated_at: null}
       + (if $version_slot == "" then {} else {version_slot: $version_slot} end)
       + (if $worktree_path == "" then {} else {worktree_path: $worktree_path} end)'); then
    echo "set-slot: failed to build slot record" >&2
    exit 68
  fi
  local slot_json
  slot_json=$(jq -n -c --arg s "$slot_id" '$s')

  cmd_update --session-id "$session_id" \
    --set ".in_flight = ((.in_flight // {}) + {${slot_json}: ${record}})" \
    ${passthrough[@]+"${passthrough[@]}"}
}

cmd_release_slot() {
  local session_id="" slot_id=""
  local -a passthrough=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      --slot-id) slot_id="${2:-}"; shift 2 ;;
      --allow-degraded-init|--skip-repo-check) passthrough+=("$1"); shift ;;
      --degraded-init-repo|--expected-repo) passthrough+=("$1" "${2:-}"); shift 2 ;;
      *) echo "release-slot: unknown arg $1" >&2; usage_error "release-slot" ;;
    esac
  done
  if [[ -z "$session_id" || -z "$slot_id" ]]; then
    echo "release-slot: --session-id and --slot-id are required" >&2
    usage_error "release-slot"
  fi
  local slot_json
  slot_json=$(jq -n -c --arg s "$slot_id" '$s')
  # Releasing an absent slot is an idempotent no-op (del on a missing key).
  cmd_update --session-id "$session_id" \
    --set ".in_flight = ((.in_flight // {}) | del(.[${slot_json}]))" \
    ${passthrough[@]+"${passthrough[@]}"}
}

cmd_set_progress() {
  local session_id=""
  local slot=""
  local current=""
  local current_set=0
  local total=""
  local total_set=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      --slot) slot="${2:-}"; shift 2 ;;
      --current) current="${2:-}"; current_set=1; shift 2 ;;
      --total) total="${2:-}"; total_set=1; shift 2 ;;
      *) echo "set-progress: unknown arg $1" >&2; usage_error "set-progress" ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "set-progress: --session-id is required" >&2
    usage_error "set-progress"
  fi
  if [[ -z "$slot" ]]; then
    echo "set-progress: --slot is required" >&2
    usage_error "set-progress"
  fi

  # Neither flag set → no-op success. Callers can pass `set-progress
  # --session-id x --slot s1` defensively from a batch refactor without
  # tripping a usage error.
  if [[ $current_set -eq 0 && $total_set -eq 0 ]]; then
    return 0
  fi

  # Validate the values. Accept positive integers or the literal `null`
  # (which clears a previously-set value). Negative numbers and non-integers
  # are rejected so a typo doesn't silently persist as a string.
  local current_jq="null"
  if [[ $current_set -eq 1 ]]; then
    if [[ "$current" == "null" ]]; then
      current_jq="null"
    elif [[ "$current" =~ ^[0-9]+$ ]]; then
      current_jq="$current"
    else
      echo "set-progress: --current must be a non-negative integer or 'null' (got: $current)" >&2
      exit 64
    fi
  fi

  local total_jq="null"
  if [[ $total_set -eq 1 ]]; then
    if [[ "$total" == "null" ]]; then
      total_jq="null"
    elif [[ "$total" =~ ^[0-9]+$ ]]; then
      total_jq="$total"
    else
      echo "set-progress: --total must be a non-negative integer or 'null' (got: $total)" >&2
      exit 64
    fi
  fi

  local target
  target=$(session_path "$session_id")

  if [[ ! -f "$target" ]]; then
    echo "set-progress: $target does not exist (use init first)" >&2
    exit 3
  fi

  # Verify the slot exists in .in_flight. set-progress is "modify an
  # existing slot record," not "create a slot" — the slot is added by
  # step C dispatch with the worker's claimed_paths + agent_id. If the
  # caller is updating a slot that doesn't exist, that's a programming
  # error worth surfacing (likely the worker returned and the slot got
  # released before the progress write landed — race window is narrow
  # but real).
  if ! jq -e --arg slot "$slot" '.in_flight | has($slot)' "$target" >/dev/null 2>&1; then
    echo "set-progress: slot '$slot' not present in .in_flight" >&2
    exit 64
  fi

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Compose the jq pipeline. Each field is updated only when its --set was
  # provided this call — preserves a previously-set total when only current
  # advances (the common case for a progressing batch worker).
  local jq_pipeline=""
  if [[ $current_set -eq 1 ]]; then
    jq_pipeline=".in_flight[\$slot].progress_current = $current_jq"
  fi
  if [[ $total_set -eq 1 ]]; then
    if [[ -z "$jq_pipeline" ]]; then
      jq_pipeline=".in_flight[\$slot].progress_total = $total_jq"
    else
      jq_pipeline="$jq_pipeline | .in_flight[\$slot].progress_total = $total_jq"
    fi
  fi
  jq_pipeline="$jq_pipeline | .in_flight[\$slot].progress_updated_at = \$now | .updated_at = \$now"

  if ! jq --arg slot "$slot" --arg now "$now" "$jq_pipeline" "$target" | atomic_write "$target"; then
    echo "set-progress: jq expression failed — file left unchanged" >&2
    exit 68
  fi
}

# cmd_record_session_end — stamp a terminal reason on the session file
# before cleanup reaps it (issue #1252). Three of six recent sessions on
# the maintainer's own machine terminated with a non-empty `.in_flight`
# and no record of why — the orchestrator process ended before it ever
# reached cleanup-summary.md's normal exit path, so nothing distinguished
# that abnormal termination from a clean one after the fact.
#
# `--reason` is a closed enum, not free text — validated here so a typo
# can't silently produce an unparseable value nothing downstream expects:
#   completed    — every open workable issue closed/dispositioned AND
#                  every session PR merged (do-work.md's completion
#                  contract, met in full).
#   bounded-exit — the drain stopped on a safety bound (max_drain_hours
#                  ceiling, a blocked:ci / rebase-blocked / still-pending
#                  PR, or a non-zero completion-ledger bucket) rather than
#                  because the work was actually done.
#   user-stop    — an explicit `stop` / `drain` signal ended the session
#                  before the queues were empty.
# `--detail` is free-text elaboration (drain-exit reason, session_prs
# counts, ledger bucket counts) — optional, stored as `null` when omitted.
#
# Shares the same missing-file recovery (--allow-degraded-init /
# --degraded-init-repo) and cross-repo write guard (--expected-repo /
# --skip-repo-check) as `update`, for the same reasons (issues #253/#281,
# #365) — this call sits in the same end-of-session write-through path.
cmd_record_session_end() {
  local session_id=""
  local reason=""
  local detail=""
  local allow_degraded_init=0
  local degraded_init_repo=""
  local expected_repo="${SHIPYARD_EXPECTED_REPO:-}"
  local skip_repo_check=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      --reason) reason="${2:-}"; shift 2 ;;
      --detail) detail="${2:-}"; shift 2 ;;
      --allow-degraded-init) allow_degraded_init=1; shift ;;
      --degraded-init-repo) degraded_init_repo="${2:-}"; shift 2 ;;
      --expected-repo) expected_repo="${2:-}"; shift 2 ;;
      --skip-repo-check) skip_repo_check=1; shift ;;
      *) echo "record-session-end: unknown arg $1" >&2; usage_error "record-session-end" ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "record-session-end: --session-id is required" >&2
    usage_error "record-session-end"
  fi
  case "$reason" in
    completed|bounded-exit|user-stop) ;;
    *)
      echo "record-session-end: --reason must be one of completed|bounded-exit|user-stop (got: '$reason')" >&2
      exit 64
      ;;
  esac

  local target
  target=$(session_path "$session_id")

  if [[ "$skip_repo_check" -eq 0 ]]; then
    if ! check_repo_match "$target" "$expected_repo" "record-session-end"; then
      exit 66
    fi
  fi

  if [[ ! -f "$target" ]]; then
    if [[ "$allow_degraded_init" -eq 1 ]]; then
      local recovery_repo="${degraded_init_repo:-unknown/unknown}"
      if ! cmd_init \
            --session-id "$session_id" \
            --repo "$recovery_repo" \
            --degraded-recovery \
            >/dev/null; then
        echo "record-session-end: degraded recovery init failed for $target" >&2
        exit 68
      fi
      echo "record-session-end: $target was missing — degraded-init recovered (state from before the disappear is lost)" >&2
    else
      echo "record-session-end: $target does not exist (use init first)" >&2
      exit 3
    fi
  fi

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if ! jq \
        --arg reason "$reason" \
        --arg detail "$detail" \
        --arg now "$now" \
        '.session_end = {reason: $reason, detail: (if $detail == "" then null else $detail end), recorded_at: $now} | .updated_at = $now' \
        "$target" | atomic_write "$target"; then
    echo "record-session-end: jq expression failed — file left unchanged" >&2
    exit 68
  fi
}

# cmd_record_stall — append one entry to `.stalled_dispatches` (issue
# #1302). See the "record-stall" subcommand doc in the header comment for
# the full rationale: a typed, single-entry call keeps the argument small
# enough that Auto Mode's classifier doesn't refuse it the way it refused
# the large nested-JSON `.stalled_dispatches = [...]` `--set` payload the
# issue's repro hit. `--target` / `--mode` / `--trigger` / `--outcome` are
# a closed shape mirroring do-work/orchestrator-state-reference.md's
# documented `stalled_dispatches` entry — validated here so a typo can't
# silently produce a value nothing downstream expects. `detected_at` is
# always stamped internally at call time, never caller-supplied.
#
# Shares the same missing-file recovery (--allow-degraded-init /
# --degraded-init-repo) and cross-repo write guard (--expected-repo /
# --skip-repo-check) as `update` / `record-session-end`, for the same
# reasons (issues #253/#281, #365) — this call fires from the same
# reconcile path those callers write from.
cmd_record_stall() {
  local session_id=""
  local target=""
  local mode=""
  local trigger=""
  local outcome=""
  local resumed_pr=""
  local allow_degraded_init=0
  local degraded_init_repo=""
  local expected_repo="${SHIPYARD_EXPECTED_REPO:-}"
  local skip_repo_check=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      --target) target="${2:-}"; shift 2 ;;
      --mode) mode="${2:-}"; shift 2 ;;
      --trigger) trigger="${2:-}"; shift 2 ;;
      --outcome) outcome="${2:-}"; shift 2 ;;
      --resumed-pr) resumed_pr="${2:-}"; shift 2 ;;
      --allow-degraded-init) allow_degraded_init=1; shift ;;
      --degraded-init-repo) degraded_init_repo="${2:-}"; shift 2 ;;
      --expected-repo) expected_repo="${2:-}"; shift 2 ;;
      --skip-repo-check) skip_repo_check=1; shift ;;
      *) echo "record-stall: unknown arg $1" >&2; usage_error "record-stall" ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "record-stall: --session-id is required" >&2
    usage_error "record-stall"
  fi
  if [[ -z "$target" ]]; then
    echo "record-stall: --target is required" >&2
    usage_error "record-stall"
  fi
  case "$mode" in
    issue-work|fix-checks-only|fix-rebase|fix-main-ci|fix-failing-prs-batch|investigate|spike) ;;
    *)
      echo "record-stall: --mode must be one of issue-work|fix-checks-only|fix-rebase|fix-main-ci|fix-failing-prs-batch|investigate|spike (got: '$mode')" >&2
      exit 64
      ;;
  esac
  case "$trigger" in
    non-terminal-return|harness-failed) ;;
    *)
      echo "record-stall: --trigger must be one of non-terminal-return|harness-failed (got: '$trigger')" >&2
      exit 64
      ;;
  esac
  case "$outcome" in
    resumed|handed-back|dropped-clean) ;;
    *)
      echo "record-stall: --outcome must be one of resumed|handed-back|dropped-clean (got: '$outcome')" >&2
      exit 64
      ;;
  esac

  local resumed_pr_json="null"
  if [[ -n "$resumed_pr" ]] && [[ "$resumed_pr" != "null" ]]; then
    if ! [[ "$resumed_pr" =~ ^[0-9]+$ ]]; then
      echo "record-stall: --resumed-pr must be a non-negative integer, 'null', or omitted (got: '$resumed_pr')" >&2
      exit 64
    fi
    resumed_pr_json="$resumed_pr"
  fi

  local target_path
  target_path=$(session_path "$session_id")

  if [[ "$skip_repo_check" -eq 0 ]]; then
    if ! check_repo_match "$target_path" "$expected_repo" "record-stall"; then
      exit 66
    fi
  fi

  if [[ ! -f "$target_path" ]]; then
    if [[ "$allow_degraded_init" -eq 1 ]]; then
      local recovery_repo="${degraded_init_repo:-unknown/unknown}"
      if ! cmd_init \
            --session-id "$session_id" \
            --repo "$recovery_repo" \
            --degraded-recovery \
            >/dev/null; then
        echo "record-stall: degraded recovery init failed for $target_path" >&2
        exit 68
      fi
      echo "record-stall: $target_path was missing — degraded-init recovered (state from before the disappear is lost)" >&2
    else
      echo "record-stall: $target_path does not exist (use init first)" >&2
      exit 3
    fi
  fi

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if ! jq \
        --arg target "$target" \
        --arg mode "$mode" \
        --arg trigger "$trigger" \
        --arg outcome "$outcome" \
        --argjson resumed_pr "$resumed_pr_json" \
        --arg now "$now" \
        '.stalled_dispatches = ((.stalled_dispatches // []) + [{
           target: $target,
           mode: $mode,
           trigger: $trigger,
           outcome: $outcome,
           resumed_pr: $resumed_pr,
           detected_at: $now
         }]) | .updated_at = $now' \
        "$target_path" | atomic_write "$target_path"; then
    echo "record-stall: jq expression failed — file left unchanged" >&2
    exit 68
  fi
}

# cmd_record_denial — append one entry to `.dispatch_denials` (issue
# #1302). Same rationale as cmd_record_stall above — a typed, single-
# entry call for the harness permission classifier denying a worker
# dispatch call outright (issue #718), instead of a hand-built
# `.dispatch_denials = [...]` jq literal through `update`. `--target` /
# `--mode` / `--denial-text` / `--attempt` / `--outcome` mirror do-work/
# orchestrator-state-reference.md's documented `dispatch_denials` entry
# shape. `denied_at` is always stamped internally at call time.
#
# Shares the same missing-file recovery and cross-repo write guard as
# `update` / `record-session-end` / `record-stall`.
cmd_record_denial() {
  local session_id=""
  local target=""
  local mode=""
  local denial_text=""
  local attempt=""
  local outcome=""
  local allow_degraded_init=0
  local degraded_init_repo=""
  local expected_repo="${SHIPYARD_EXPECTED_REPO:-}"
  local skip_repo_check=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      --target) target="${2:-}"; shift 2 ;;
      --mode) mode="${2:-}"; shift 2 ;;
      --denial-text) denial_text="${2:-}"; shift 2 ;;
      --attempt) attempt="${2:-}"; shift 2 ;;
      --outcome) outcome="${2:-}"; shift 2 ;;
      --allow-degraded-init) allow_degraded_init=1; shift ;;
      --degraded-init-repo) degraded_init_repo="${2:-}"; shift 2 ;;
      --expected-repo) expected_repo="${2:-}"; shift 2 ;;
      --skip-repo-check) skip_repo_check=1; shift ;;
      *) echo "record-denial: unknown arg $1" >&2; usage_error "record-denial" ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "record-denial: --session-id is required" >&2
    usage_error "record-denial"
  fi
  if [[ -z "$target" ]]; then
    echo "record-denial: --target is required" >&2
    usage_error "record-denial"
  fi
  case "$mode" in
    issue-work|fix-checks-only|fix-rebase|fix-main-ci|fix-failing-prs-batch|investigate|spike) ;;
    *)
      echo "record-denial: --mode must be one of issue-work|fix-checks-only|fix-rebase|fix-main-ci|fix-failing-prs-batch|investigate|spike (got: '$mode')" >&2
      exit 64
      ;;
  esac
  if [[ -z "$denial_text" ]]; then
    echo "record-denial: --denial-text is required" >&2
    usage_error "record-denial"
  fi
  case "$attempt" in
    1|2) ;;
    *)
      echo "record-denial: --attempt must be 1 or 2 (got: '$attempt')" >&2
      exit 64
      ;;
  esac
  case "$outcome" in
    reframed|shipped-after-reframe|handed-back) ;;
    *)
      echo "record-denial: --outcome must be one of reframed|shipped-after-reframe|handed-back (got: '$outcome')" >&2
      exit 64
      ;;
  esac

  local target_path
  target_path=$(session_path "$session_id")

  if [[ "$skip_repo_check" -eq 0 ]]; then
    if ! check_repo_match "$target_path" "$expected_repo" "record-denial"; then
      exit 66
    fi
  fi

  if [[ ! -f "$target_path" ]]; then
    if [[ "$allow_degraded_init" -eq 1 ]]; then
      local recovery_repo="${degraded_init_repo:-unknown/unknown}"
      if ! cmd_init \
            --session-id "$session_id" \
            --repo "$recovery_repo" \
            --degraded-recovery \
            >/dev/null; then
        echo "record-denial: degraded recovery init failed for $target_path" >&2
        exit 68
      fi
      echo "record-denial: $target_path was missing — degraded-init recovered (state from before the disappear is lost)" >&2
    else
      echo "record-denial: $target_path does not exist (use init first)" >&2
      exit 3
    fi
  fi

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if ! jq \
        --arg target "$target" \
        --arg mode "$mode" \
        --arg denial_text "$denial_text" \
        --argjson attempt "$attempt" \
        --arg outcome "$outcome" \
        --arg now "$now" \
        '.dispatch_denials = ((.dispatch_denials // []) + [{
           target: $target,
           mode: $mode,
           denied_at: $now,
           denial_text: $denial_text,
           attempt: $attempt,
           outcome: $outcome
         }]) | .updated_at = $now' \
        "$target_path" | atomic_write "$target_path"; then
    echo "record-denial: jq expression failed — file left unchanged" >&2
    exit 68
  fi
}

# cmd_is_active — liveness check used by the orphan-sweep (setup.md step
# 1.6). The race the sweep guards against: a concurrent /do-work session
# in another terminal runs the sweep against this session's file. The
# original implementation relied on `find -mmin +30` alone — that worked
# when the orchestrator wrote through often, but failed (issue #253) when
# an orchestrator legitimately went quiet for 30+ minutes (long-running
# drain phases, CI watches) while still active and writing through later.
#
# The contract: exit 0 if the session is active (file exists AND `.pid`
# is a non-zero integer AND the process is alive via `kill -0`); exit 1
# otherwise. Missing file = not active = exit 1 (callers reading exit 1
# should fall through to their own mtime / cleanup logic, NOT treat this
# as a hard error).
#
# Why `kill -0`: POSIX defines `kill -0 <pid>` as a permission-and-existence
# check — no signal is delivered, the kernel just resolves the pid and
# returns 0 if it exists. The only false-positive vector is PID recycling:
# the OS could reassign $pid to an unrelated process during our absence.
# That's why setup.md step 1.6 stacks `is-active` AND the 30-min mtime
# floor — both have to fail before reap, so a recycled-pid + recent-mtime
# scenario still skips the reap.
cmd_is_active() {
  local session_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      *) echo "is-active: unknown arg $1" >&2; usage_error "is-active" ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "is-active: --session-id is required" >&2
    usage_error "is-active"
  fi

  local target
  target=$(session_path "$session_id")

  # Missing file → not active. Quiet exit (no stderr) so callers can use
  # `is-active` in if-conditions without producing noise.
  if [[ ! -f "$target" ]]; then
    exit 1
  fi

  # Read `.pid` defensively — old session files written before this field
  # existed will have `.pid` = null. Treat null / 0 / missing as "no
  # liveness signal," fall through to exit 1 so the caller's mtime backstop
  # decides. A live, recently-touched file from an older shipyard version
  # is still protected by the 30-min mtime floor in step 1.6.
  local pid
  pid=$(jq -r '.pid // 0' "$target" 2>/dev/null)
  if [[ -z "$pid" ]] || [[ "$pid" == "null" ]] || [[ "$pid" == "0" ]]; then
    exit 1
  fi
  if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
    # Corrupt pid field — treat as "no liveness signal." The mtime backstop
    # still applies in the caller.
    exit 1
  fi

  if kill -0 "$pid" 2>/dev/null; then
    exit 0
  fi

  exit 1
}

cmd_cleanup() {
  local session_id=""
  # --reap-audit (issue #281, acceptance criterion 2) — when set, writes
  # a single JSONL line to $SHIPYARD_HOME/reap-audit.jsonl BEFORE the
  # rm -f. The line captures everything the file would otherwise carry
  # to its grave: the reaped session's pid, started_at, updated_at, repo,
  # token totals (so the loss is quantified), degraded_attribution_count,
  # and the timestamp of the reap. Plus the reaper's session id and pid
  # — that's the attribution criterion 2 calls for: when a peer's sweep
  # reaps our file, the next investigator can see who did it and when.
  #
  # Off by default. The end-of-session cleanup-summary.md step 7 path
  # does NOT pass --reap-audit because that's a happy-path delete (the
  # session is genuinely done), not a "reap." Only setup.md step 1.6's
  # peer-sweep callsite passes it, since that IS a reap-of-someone-else.
  # The format mirrors worktree-reap.sh's audit-log lines (same JSONL
  # file) — see issue #284 for the worktree-side encoding. The
  # action is "reaped-session-file" so a reader can distinguish session-
  # file reaps from worktree reaps.
  local reap_audit=0
  local reaper_session_id=""
  local reaper_pid="$$"
  local reason=""
  local phase=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session-id) session_id="${2:-}"; shift 2 ;;
      --reap-audit) reap_audit=1; shift ;;
      --reaper-session-id) reaper_session_id="${2:-}"; shift 2 ;;
      --reaper-pid) reaper_pid="${2:-}"; shift 2 ;;
      --reason) reason="${2:-}"; shift 2 ;;
      --phase) phase="${2:-}"; shift 2 ;;
      *) echo "cleanup: unknown arg $1" >&2; usage_error "cleanup" ;;
    esac
  done

  if [[ -z "$session_id" ]]; then
    echo "cleanup: --session-id is required" >&2
    usage_error "cleanup"
  fi

  # --reap-audit requires --reaper-session-id so the audit-log line
  # actually identifies the reaper. Reject usage-error rather than
  # emit a line with an empty reaper field — that would be unparseable
  # forensic data later.
  if [[ "$reap_audit" -eq 1 ]] && [[ -z "$reaper_session_id" ]]; then
    echo "cleanup: --reap-audit requires --reaper-session-id" >&2
    exit 64
  fi
  if [[ "$reap_audit" -eq 1 ]] && ! [[ "$reaper_pid" =~ ^[0-9]+$ ]]; then
    echo "cleanup: --reaper-pid must be a non-negative integer (got: $reaper_pid)" >&2
    exit 64
  fi

  local target
  target=$(session_path "$session_id")

  # Idempotent: missing file is a no-op success. The failure mode we're
  # guarding against is a session that half-cleaned (the file exists but
  # is corrupt, or the cleanup ran on the wrong session-id) — not a
  # session whose file is already gone.
  if [[ -f "$target" ]]; then
    # If --reap-audit is set, capture the reaped session's state BEFORE
    # we rm it so the audit line carries the loss-attribution data.
    # Best-effort: a corrupt JSON gets `null` for each captured field,
    # which is still better than no audit entry at all.
    if [[ "$reap_audit" -eq 1 ]]; then
      local shipyard_home
      shipyard_home=$(shipyard_home)
      mkdir -p "$shipyard_home" 2>/dev/null || true
      local audit_log="$shipyard_home/reap-audit.jsonl"
      local ts
      ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

      # mtime of the reaped file in seconds-since-epoch; helps determine
      # how stale the file was at the moment of reap. macOS and Linux
      # `stat` flags differ — try GNU first, fall back to BSD.
      local mtime_epoch
      mtime_epoch=$(stat -c %Y "$target" 2>/dev/null || stat -f %m "$target" 2>/dev/null || echo "null")
      [[ -z "$mtime_epoch" ]] && mtime_epoch="null"

      # Build the audit line with the reaped session's metadata. We use
      # jq to construct the JSON so quoting / typing is correct.
      # `--argjson` for numeric and null fields; `--arg` for strings.
      # Any field missing from the source file becomes JSON null in the
      # output line — the schema is best-effort, not strict.
      local audit_line
      audit_line=$(jq -c -n \
        --arg ts "$ts" \
        --arg reaped_session_id "$session_id" \
        --arg reaper_session_id "$reaper_session_id" \
        --argjson reaper_pid "$reaper_pid" \
        --arg reason "$reason" \
        --arg phase "$phase" \
        --argjson mtime_epoch "$mtime_epoch" \
        --slurpfile src "$target" \
        '{
          ts: $ts,
          action: "reaped-session-file",
          reaped_session_id: $reaped_session_id,
          reaper_session_id: $reaper_session_id,
          reaper_pid: $reaper_pid,
          reaped_pid: ($src[0].pid // null),
          reaped_repo: ($src[0].repo // null),
          reaped_started_at: ($src[0].started_at // null),
          reaped_updated_at: ($src[0].updated_at // null),
          reaped_mtime_epoch: $mtime_epoch,
          reaped_tokens_totals: ($src[0].tokens.totals // null),
          reaped_degraded_attribution_count: ($src[0].tokens.degraded_attribution_count // 0),
          reaped_degraded_recovery_at: ($src[0].degraded_recovery_at // null),
          reaped_per_invocation_count: ($src[0].tokens.per_invocation // [] | length),
          reaped_session_end: ($src[0].session_end // null),
          reaped_in_flight_count: ($src[0].in_flight // {} | length),
          reason: (if $reason == "" then null else $reason end),
          phase: (if $phase == "" then null else $phase end)
        }' 2>/dev/null)

      # Fire-and-forget: a permission error / disk-full / corrupt source
      # JSON must NOT abort the reap. The reap itself is the load-bearing
      # work; the audit line is observability.
      if [[ -n "$audit_line" ]]; then
        printf '%s\n' "$audit_line" >> "$audit_log" 2>/dev/null || true
      fi
    fi
    rm -f "$target"
  fi
  # Also drop any leftover .tmp.<pid> files from a crashed update — these
  # are safe to remove unconditionally because they're per-pid and the
  # session we're cleaning up is by definition done.
  rm -f "${target}.tmp."* 2>/dev/null || true
}

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------

if [[ $# -lt 1 ]]; then
  usage_error
fi

subcmd="$1"
shift

case "$subcmd" in
  init)         cmd_init "$@" ;;
  read)         cmd_read "$@" ;;
  update)       cmd_update "$@" ;;
  cleanup)      cmd_cleanup "$@" ;;
  bump-tokens)  cmd_bump_tokens "$@" ;;
  read-tokens)  cmd_read_tokens "$@" ;;
  set-progress) cmd_set_progress "$@" ;;
  set-slot)     cmd_set_slot "$@" ;;
  release-slot) cmd_release_slot "$@" ;;
  record-session-end) cmd_record_session_end "$@" ;;
  record-stall) cmd_record_stall "$@" ;;
  record-denial) cmd_record_denial "$@" ;;
  is-active)    cmd_is_active "$@" ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    echo "session-state.sh: unknown subcommand $subcmd" >&2
    usage_error "$subcmd"
    ;;
esac
