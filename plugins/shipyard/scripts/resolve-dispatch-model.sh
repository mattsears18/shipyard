#!/usr/bin/env bash
# resolve-dispatch-model.sh — resolve the `model` parameter the orchestrator
# passes on an `Agent` dispatch for a given worker mode, from the merged
# shipyard config's `models.<mode>` key.
#
# This script is the SINGLE EXECUTABLE SOURCE OF TRUTH for "which model does
# this mode dispatch on".
#
# Background (issue #727)
# ----------------------
# `models.*` was a DEAD config surface: it was defined in the schema, settable
# via `/shipyard:config set models.issue_work <id>`, documented in CLAUDE.md,
# and covered by tests — but READ BY NOTHING. Actual model selection lived
# exclusively in each agent shim's `model:` frontmatter, which a consumer repo
# cannot override. So a user who set `models.issue_work: claude-sonnet-4-6` to
# cut spend silently kept dispatching on the session model (Opus) with no
# warning anywhere. A config key that silently no-ops is worse than no key.
#
# The fix (option (a) on #727 — honor the config): the orchestrator calls this
# script at dispatch time and passes the result as the `Agent` tool's `model`
# parameter, which takes precedence over the agent definition's frontmatter.
# Frontmatter stays the DEFAULT; config OVERRIDES it.
#
# Why the output is a family alias, not the configured id verbatim
# ---------------------------------------------------------------
# The `Agent` tool's `model` parameter is an enum — `opus` | `sonnet` | `haiku`
# | `fable` — not a free-form model id. The config surface (and the pricing
# table in session-state.sh) speak in concrete ids like `claude-sonnet-4-6`.
# This script bridges the two: it maps a configured id onto the Agent-tool
# alias for its model family. Passing an unmapped id straight through would
# fail the tool call's input validation, which is exactly the kind of silent
# dispatch-time break #727 exists to prevent.
#
# Usage — live resolution (the normal path):
#   bash resolve-dispatch-model.sh <mode>
#     <mode> is a worker mode in either form: `issue-work` or `issue_work`.
#     -> prints the Agent-tool model alias on stdout (`opus`/`sonnet`/`haiku`/`fable`)
#     -> prints NOTHING (empty stdout, exit 0) when the mode has no configured
#        model, or the configured id maps to no known family. The caller then
#        OMITS the `model` parameter and the shim's frontmatter default applies.
#     -> exit 0 on a successful decision (including the empty case), 64 on a
#        usage error (unknown mode).
#
# Usage — pure mapping (hermetic; for tests and for callers that already hold
# the configured id):
#   bash resolve-dispatch-model.sh --map <model-id>
#     -> same stdout contract, no config read, no filesystem access.
#
# Fail-open posture: an unreadable config, an absent key, or an unrecognized
# model id all resolve to the EMPTY string — i.e. "fall back to the shim's
# frontmatter default". A typo'd config value must never hard-fail a dispatch
# or silently substitute a wrong-tier model; the frontmatter pin is a safe,
# already-reviewed default. The warning goes to stderr so the orchestrator can
# surface it without the value polluting stdout.
#
# Usage — advisory fallback-chain helper (issue #766, NOT wired into
# dispatch — read the caveat below before reusing this elsewhere):
#   bash resolve-dispatch-model.sh --fallback-chain <family-or-id>
#     -> prints the recommended per-family degrade-on-overload chain as a
#        comma-separated list of Agent-tool aliases, e.g. `sonnet,haiku` for
#        `opus`. Empty output (exit 0) for the cheapest tier (`haiku`, which
#        has nowhere lower to fall back to) or an unrecognized family.
#
# Why this is a *documentation* helper, not a dispatch-time resolver — read
# this before wiring it into anything else
# ---------------------------------------------------------------------------
# `models.<mode>` (the rest of this script) is a DISPATCH-TIME override: its
# output becomes the `Agent` tool's `model` parameter on every worker dispatch,
# so setting it changes real behavior. Claude Code's own `fallbackModel`
# setting (v2.1.166+) is a DIFFERENT axis entirely — it lives in the user's
# `settings.json`, governs what the *session's own* CLI process retries when
# a model request comes back overloaded, and has no equivalent parameter on
# the `Agent` tool this script's live path feeds (the tool's `model` field is
# a single enum value, not a list). There is no dispatch-time hook to wire a
# fallback chain into, so `--fallback-chain` does NOT get consumed by
# `dispatch-rules.md` / `setup/07-pool-fill.md` the way the live `<mode>` path
# does — it exists purely so a human (or `do-work-RATIONALE.md`'s worked
# example) can compute the recommended `fallbackModel` array for whichever
# model a given `models.<mode>` entry resolves to, without hand-maintaining
# the family-tier ordering in prose. Do NOT treat an unconsumed
# `--fallback-chain` call site as the #727 dead-config-surface anti-pattern
# repeating — #727's bug was a *config key* nothing read; this is a *pure
# function* whose only "caller" is a human copying its output into their own
# `settings.json`, which this repo cannot write on the user's behalf.
# See `do-work-RATIONALE.md`'s "fallbackModel" section for the full
# recommendation and worked settings.json example.

set -uo pipefail

# ---------------------------------------------------------------------------
# The mapping. Pure function of the configured model id — no I/O, no network.
# ---------------------------------------------------------------------------
# Matches on the model FAMILY substring, so every id shape the config or the
# harness can carry resolves without a per-version table to maintain:
#   claude-opus-4-8 / claude-opus-4-8-20260115 / opus  -> opus
#   claude-sonnet-4-6 / sonnet                         -> sonnet
#   claude-haiku-4-5 / haiku                           -> haiku
#   claude-fable-5 / fable                             -> fable
map_model() {
  local id="$1"
  id="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"

  case "$id" in
    '')       printf '' ;;
    *opus*)   printf 'opus\n' ;;
    *sonnet*) printf 'sonnet\n' ;;
    *haiku*)  printf 'haiku\n' ;;
    *fable*)  printf 'fable\n' ;;
    *)
      echo "resolve-dispatch-model: '${id}' matches no known model family (opus/sonnet/haiku/fable) — omitting the Agent \`model\` parameter; the shim's frontmatter default applies" >&2
      printf ''
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Advisory fallback-chain table (issue #766). Pure function of a model
# FAMILY (already resolved via map_model, or a bare alias) — no I/O. Ordered
# highest-tier-first, degrading toward cheaper/faster tiers so a session that
# hits an overloaded top tier still completes the dispatch instead of failing
# it outright. Capped at 3 entries (fable's chain) to mirror Claude Code's own
# documented `fallbackModel` limit of three models.
#
# `haiku` is intentionally the floor — it's already the cheapest/fastest tier
# shipyard dispatches on, so there is nothing lower to degrade to.
# ---------------------------------------------------------------------------
fallback_chain_for_family() {
  local family="$1"
  family="$(printf '%s' "$family" | tr '[:upper:]' '[:lower:]')"

  case "$family" in
    fable)  printf 'opus,sonnet,haiku\n' ;;
    opus)   printf 'sonnet,haiku\n' ;;
    sonnet) printf 'haiku\n' ;;
    haiku)  printf '' ;;   # already the floor tier — nothing cheaper to fall back to
    *)
      echo "resolve-dispatch-model: '${family}' matches no known model family (opus/sonnet/haiku/fable) — no fallback-chain recommendation" >&2
      printf ''
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Mode-name normalization. Dispatch prompts and the routing table speak in
# hyphenated mode names (`fix-checks-only`); the config schema's `models.*`
# keys are underscored (`fix_checks_only`). Accept both.
# ---------------------------------------------------------------------------
normalize_mode() {
  local mode="$1"
  mode="$(printf '%s' "$mode" | tr '[:upper:]-' '[:lower:]_')"

  case "$mode" in
    issue_work|fix_checks_only|fix_rebase|fix_main_ci|fix_failing_prs_batch|investigate|verify|spike)
      printf '%s\n' "$mode"
      ;;
    *)
      return 1
      ;;
  esac
}

main() {
  if [ "${1:-}" = "--map" ]; then
    if [ "$#" -ne 2 ]; then
      echo "usage: $0 --map <model-id>" >&2
      exit 64
    fi
    map_model "$2"
    exit 0
  fi

  if [ "${1:-}" = "--fallback-chain" ]; then
    if [ "$#" -ne 2 ]; then
      echo "usage: $0 --fallback-chain <family-or-model-id>" >&2
      exit 64
    fi
    # Accept either a bare family alias or a full model id (map_model resolves
    # a full id like claude-opus-4-8 to its family first).
    local resolved_family
    resolved_family="$(map_model "$2" 2>/dev/null)"
    fallback_chain_for_family "${resolved_family:-$2}"
    exit 0
  fi

  local mode="${1:-}"
  if [ -z "$mode" ]; then
    echo "usage: $0 <mode>" >&2
    echo "       $0 --map <model-id>" >&2
    echo "       $0 --fallback-chain <family-or-model-id>" >&2
    echo "modes: issue-work fix-checks-only fix-rebase fix-main-ci fix-failing-prs-batch investigate verify spike" >&2
    exit 64
  fi

  local key
  if ! key="$(normalize_mode "$mode")"; then
    echo "resolve-dispatch-model: unknown mode '${mode}'" >&2
    echo "modes: issue-work fix-checks-only fix-rebase fix-main-ci fix-failing-prs-batch investigate verify spike" >&2
    exit 64
  fi

  local script_dir configured
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # A missing key / unreadable config is not an error — it means "no override",
  # which is the fail-open path back to the shim's frontmatter default.
  configured="$(bash "${script_dir}/shipyard-config.sh" get "models.${key}" 2>/dev/null)" || configured=""

  map_model "$configured"
}

main "$@"
