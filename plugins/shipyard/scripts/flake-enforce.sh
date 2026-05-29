#!/usr/bin/env bash
# flake-enforce.sh — phase-2 enforcement of the cross-PR flake registry.
#
# Background (issue #385, phase 2 of #378). Phase 1 (scripts/flake-registry.sh,
# closed #378 via PR #384) shipped the data layer: the append-only
# `~/.shipyard/flake-registry.jsonl` ledger, the windowed per-(workflow,job,test)
# aggregation, and the `crossed` reader that names which flakes have crossed the
# escalation threshold AND echoes the configured `actions` array onto each row.
# Phase 1 deliberately stopped before ENFORCING those actions.
#
# This helper is the enforcement consumer. It reads `flake-registry.sh crossed`
# output (piped on stdin, or computed for a repo via --repo) and performs the
# three configured escalation actions per crossed row, each idempotent so
# re-running `/do-work` across sessions doesn't duplicate side effects:
#
#   file-tracking-issue   Open a chronic-flake tracking issue in the affected
#                         repo, linking the registry-derived rerun events and
#                         the affected PR list, stamped with a stable
#                         `flake-key=<...>` HTML marker + an `audit:test-stability`
#                         label. DEDUPE: if an OPEN issue carrying the same
#                         `flake-key=` marker already exists, skip (no new issue,
#                         no duplicate-comment spam).
#
#   stop-auto-rerunning   Append the crossed (workflow|job|test) key to a
#                         per-repo `.shipyard/flake-suspects.txt` so the
#                         `fix-checks-only` worker refuses to keep auto-rerunning
#                         it until a human signs off (removes the line). DEDUPE:
#                         a key already present is not re-appended; the file is
#                         created if missing. `.shipyard/` is gitignored in
#                         shipyard-convention repos — this is a LOCAL human-signoff
#                         gate, not committed policy.
#
#   apply-blocked-ci      Label each still-open affected PR `blocked:ci` with a
#                         comment referencing the tracking issue, so the human
#                         sees "this isn't my PR — it's the chronic flake."
#                         DEDUPE: a PR already carrying `blocked:ci` is not
#                         re-labeled and not re-commented.
#
# Which actions run is driven by each row's own `actions` array (echoed by
# `crossed` from the effective config) — a row whose `actions` omits
# `apply-blocked-ci` won't get its PRs labeled. The orchestrator gates the whole
# step on `flake_registry.enabled == true` before ever invoking this helper;
# this helper does NOT re-read config to decide whether to run (it trusts the
# caller's gate), but it DOES honor each row's per-row `actions` set.
#
# Read site (issue #385 note — "setup once per session vs per-dispatch"):
# the orchestrator invokes this at SETUP time, once per session (cheapest;
# see commands/do-work/setup.md). The `stop-auto-rerunning` consumer side
# (fix-checks-only's pre-rerun suspects check) re-reads the suspects file on
# every dispatch, so a flake that escalates mid-session is still honored by
# the next fix-checks worker even though the issue/label actions ran only once.
#
# Subcommands:
#
#   enforce [--repo <owner/repo>] [--window-days N] [--rerun-threshold N]
#           [--distinct-prs-threshold N] [--dry-run] [--from-stdin]
#     Read crossed rows and enforce each row's actions. By default, computes
#     crossed rows itself by shelling out to flake-registry.sh with the same
#     flags (so the caller doesn't have to). Pass --from-stdin to feed a
#     precomputed `crossed` JSON array on stdin instead (avoids a second
#     aggregation pass when the orchestrator already ran `crossed`). --dry-run
#     prints the planned actions to stdout (one per line) and performs NO
#     side effects — no issue filed, no file written, no PR labeled. --repo
#     restricts both the crossed computation AND the PR-labeling scope.
#
#   suspects-list [--repo-root <path>]
#     Print the current flake-suspects keys (one per line) for the repo whose
#     root is --repo-root (default: cwd). Empty output (exit 0) if no suspects
#     file. Used by fix-checks-only's pre-rerun check.
#
#   is-suspect --key "<workflow|job|test>" [--repo-root <path>]
#     Exit 0 if the key is on the suspects list, exit 1 if not. The key format
#     is the pipe-joined (workflow, job, test) — same shape stop-auto-rerunning
#     writes. fix-checks-only builds the key from the failing check's
#     (workflow, job, test) and calls this before re-running.
#
# Environment variables:
#
#   SHIPYARD_HOME — base dir for the registry (default: $HOME/.shipyard).
#                   Passed through to flake-registry.sh.
#   GH            — gh binary override (for tests). Defaults to `gh`.
#
# Exit codes:
#   0    success (including "nothing crossed" — no-op)
#   64   usage error
#   65+  internal helper failure (jq missing, flake-registry.sh missing, etc.)

set -u

# --------------------------------------------------------------------------
# Dependencies
# --------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "flake-enforce.sh: jq is required but not installed" >&2
  exit 65
fi

GH="${GH:-gh}"

# flake-registry.sh lives alongside this script.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLAKE_REGISTRY="${HERE}/flake-registry.sh"

STABILITY_LABEL="audit:test-stability"
BLOCKED_CI_LABEL="blocked:ci"

usage() {
  cat <<'EOF' >&2
Usage:
  flake-enforce.sh enforce [--repo <owner/repo>] [--window-days N]
                           [--rerun-threshold N] [--distinct-prs-threshold N]
                           [--dry-run] [--from-stdin]
  flake-enforce.sh suspects-list [--repo-root <path>]
  flake-enforce.sh is-suspect --key "<workflow|job|test>" [--repo-root <path>]

Environment:
  SHIPYARD_HOME  base dir for the registry (default: $HOME/.shipyard)
  GH             gh binary override (default: gh)

Exit codes:
  0    success (incl. "nothing crossed")
  64   usage error
  65+  internal helper failure
EOF
}

# --------------------------------------------------------------------------
# flake-suspects helpers — the stop-auto-rerunning storage.
#
# The suspects file lives at <repo-root>/.shipyard/flake-suspects.txt, one
# key per line. The key is the pipe-joined (workflow, job, test); an empty
# test component is preserved so workflow+job-only flakes have a stable key.
# `.shipyard/` is gitignored in shipyard-convention repos, so this is a LOCAL
# gate — a human clears a suspect by deleting its line.
# --------------------------------------------------------------------------
suspects_path() {
  local repo_root="$1"
  printf '%s/.shipyard/flake-suspects.txt\n' "$repo_root"
}

# Build the canonical suspect key from a crossed row's components.
suspect_key() {
  local workflow="$1" job="$2" test="$3"
  printf '%s|%s|%s\n' "$workflow" "$job" "$test"
}

# Append a key to the suspects file iff not already present. Echoes "added"
# or "skip" so the caller can report. Creates the file + parent dir on first
# write. A leading "# " comment block documents the file's purpose on creation.
suspects_add() {
  local repo_root="$1" key="$2"
  local path
  path="$(suspects_path "$repo_root")"

  if [[ -f "$path" ]] && grep -qxF "$key" "$path" 2>/dev/null; then
    printf 'skip\n'
    return 0
  fi

  mkdir -p "$(dirname "$path")"
  if [[ ! -f "$path" ]]; then
    cat > "$path" <<'HDR'
# flake-suspects.txt — chronic-flake suspects (shipyard flake-registry phase 2, issue #385).
# One key per line: "<workflow>|<job>|<test>" (test component may be empty).
# fix-checks-only refuses to auto-rerun a check whose key is listed here until
# a human signs off by DELETING the line. Lines beginning with # are comments.
# This file is gitignored (.shipyard/) — it is a LOCAL human-signoff gate, not
# committed policy.
HDR
  fi
  printf '%s\n' "$key" >> "$path"
  printf 'added\n'
}

# --------------------------------------------------------------------------
# enforce
# --------------------------------------------------------------------------
cmd_enforce() {
  local repo="" window_days="" rerun_threshold="" distinct_prs_threshold=""
  local dry_run=0 from_stdin=0 repo_root=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)                   repo="${2:-}"; shift 2 ;;
      --window-days)            window_days="${2:-}"; shift 2 ;;
      --rerun-threshold)        rerun_threshold="${2:-}"; shift 2 ;;
      --distinct-prs-threshold) distinct_prs_threshold="${2:-}"; shift 2 ;;
      --repo-root)              repo_root="${2:-}"; shift 2 ;;
      --dry-run)                dry_run=1; shift ;;
      --from-stdin)             from_stdin=1; shift ;;
      *) echo "enforce: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  [[ -z "$repo_root" ]] && repo_root="$(pwd)"

  # Source the crossed rows.
  local crossed_json
  if [[ $from_stdin -eq 1 ]]; then
    crossed_json="$(cat)"
  else
    if [[ ! -x "$FLAKE_REGISTRY" ]]; then
      echo "enforce: flake-registry.sh not found/executable at $FLAKE_REGISTRY" >&2
      exit 65
    fi
    local args=(crossed --format json)
    [[ -n "$repo" ]]                   && args+=(--repo "$repo")
    [[ -n "$window_days" ]]            && args+=(--window-days "$window_days")
    [[ -n "$rerun_threshold" ]]        && args+=(--rerun-threshold "$rerun_threshold")
    [[ -n "$distinct_prs_threshold" ]] && args+=(--distinct-prs-threshold "$distinct_prs_threshold")
    crossed_json="$("$FLAKE_REGISTRY" "${args[@]}")" || {
      echo "enforce: flake-registry.sh crossed failed" >&2
      exit 65
    }
  fi

  # Validate it parses as a JSON array.
  if ! printf '%s' "$crossed_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "enforce: crossed input is not a JSON array" >&2
    exit 65
  fi

  local n
  n="$(printf '%s' "$crossed_json" | jq 'length')"
  if [[ "$n" -eq 0 ]]; then
    # Nothing crossed — clean no-op.
    return 0
  fi

  # Iterate rows. Each row is a compact JSON object on its own line.
  local row
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    enforce_row "$row" "$repo" "$repo_root" "$dry_run"
  done < <(printf '%s' "$crossed_json" | jq -c '.[]')
}

# Enforce one crossed row's actions.
enforce_row() {
  local row="$1" repo_filter="$2" repo_root="$3" dry_run="$4"

  local r_repo r_workflow r_job r_test r_events r_distinct
  r_repo="$(printf '%s' "$row"     | jq -r '.repo')"
  r_workflow="$(printf '%s' "$row" | jq -r '.workflow')"
  r_job="$(printf '%s' "$row"      | jq -r '.job')"
  r_test="$(printf '%s' "$row"     | jq -r '.test // ""')"
  r_events="$(printf '%s' "$row"   | jq -r '.events')"
  r_distinct="$(printf '%s' "$row" | jq -r '.distinct_prs')"

  # The effective repo for this row's gh actions. A row carries its own .repo;
  # the --repo filter (when set) already restricted `crossed`, but guard anyway.
  local repo="$r_repo"
  [[ -n "$repo_filter" && "$repo_filter" != "$repo" ]] && return 0

  local key
  key="$(suspect_key "$r_workflow" "$r_job" "$r_test")"

  # Stable dedupe marker for the tracking issue — a hash-free, human-legible
  # key derived from repo+workflow+job+test. Embedded as an HTML comment so an
  # `gh issue list --search` substring match dedupes across sessions.
  local flake_key
  flake_key="$(printf '%s' "$key" | jq -Rr '@base64')"

  local human_label="$r_workflow / $r_job"
  [[ -n "$r_test" ]] && human_label="$human_label / $r_test"

  local pr_list
  pr_list="$(printf '%s' "$row" | jq -r '(.prs // []) | map(tostring) | join(", ")')"

  # Which actions does this row request?
  local has_file has_stop has_block
  has_file="$(printf '%s'  "$row" | jq -r 'any(.actions[]?; . == "file-tracking-issue")')"
  has_stop="$(printf '%s'  "$row" | jq -r 'any(.actions[]?; . == "stop-auto-rerunning")')"
  has_block="$(printf '%s' "$row" | jq -r 'any(.actions[]?; . == "apply-blocked-ci")')"

  local tracking_issue_url=""

  # ---- file-tracking-issue --------------------------------------------------
  if [[ "$has_file" == "true" ]]; then
    if [[ "$dry_run" -eq 1 ]]; then
      printf 'DRY-RUN file-tracking-issue repo=%s flake=%q events=%s prs=[%s]\n' \
        "$repo" "$human_label" "$r_events" "$pr_list"
    else
      tracking_issue_url="$(do_file_tracking_issue \
        "$repo" "$human_label" "$flake_key" "$r_events" "$r_distinct" "$pr_list" "$row")"
    fi
  fi

  # ---- stop-auto-rerunning --------------------------------------------------
  if [[ "$has_stop" == "true" ]]; then
    if [[ "$dry_run" -eq 1 ]]; then
      printf 'DRY-RUN stop-auto-rerunning repo_root=%s key=%q\n' "$repo_root" "$key"
    else
      local outcome
      outcome="$(suspects_add "$repo_root" "$key")"
      printf 'stop-auto-rerunning %s key=%q\n' "$outcome" "$key" >&2
    fi
  fi

  # ---- apply-blocked-ci -----------------------------------------------------
  if [[ "$has_block" == "true" ]]; then
    local prs
    prs="$(printf '%s' "$row" | jq -r '(.prs // [])[]' 2>/dev/null)"
    local pr
    for pr in $prs; do
      [[ -z "$pr" ]] && continue
      if [[ "$dry_run" -eq 1 ]]; then
        printf 'DRY-RUN apply-blocked-ci repo=%s pr=%s flake=%q\n' "$repo" "$pr" "$human_label"
      else
        do_apply_blocked_ci "$repo" "$pr" "$human_label" "$tracking_issue_url"
      fi
    done
  fi
}

# ---- file-tracking-issue side effect ---------------------------------------
# Dedupe: search OPEN issues for the flake-key marker. If one exists, echo its
# URL and skip. Otherwise ensure the stability label exists, then file. Echoes
# the issue URL on stdout (consumed by apply-blocked-ci to cross-reference).
do_file_tracking_issue() {
  local repo="$1" human_label="$2" flake_key="$3" events="$4" distinct="$5" pr_list="$6" row="$7"
  local marker="flake-key=${flake_key}"

  # Dedupe across sessions — an OPEN issue carrying this exact marker means we
  # already filed it. `--search` does a full-text match on the marker token.
  local existing
  existing="$("$GH" issue list --repo "$repo" --state open \
    --search "$marker in:body" \
    --json number,url --jq '.[0].url // ""' 2>/dev/null || echo "")"
  if [[ -n "$existing" ]]; then
    printf '%s' "$existing"
    printf 'file-tracking-issue skip (exists) repo=%s url=%s flake=%q\n' \
      "$repo" "$existing" "$human_label" >&2
    return 0
  fi

  # Ensure the stability label exists (idempotent — create errors are swallowed
  # when the label already exists).
  "$GH" label create "$STABILITY_LABEL" --repo "$repo" \
    --description "Chronic CI flake escalated by the shipyard flake registry" \
    --color "FBCA04" >/dev/null 2>&1 || true

  local title="test-stability: chronic CI flake in ${human_label}"
  # Build the body via a single-quoted heredoc captured with `read -r -d ''`
  # (read returns nonzero at the unterminated-by-newline EOF — that's expected,
  # so the `|| true`). Single-quoting the EOF delimiter keeps the embedded
  # backticks literal; we substitute the dynamic fields with a trailing sed-free
  # printf so the markdown backticks don't trip command substitution.
  local prs_display="${pr_list:-none}"
  local body
  IFS= read -r -d '' body <<EOF || true
<!-- ${marker} -->
A test/check has crossed the chronic-flake escalation threshold tracked by the shipyard cross-PR flake registry (issue #378 / #385).

## Flake

- **Location:** \`${human_label}\`
- **Flake events (within window):** ${events}
- **Distinct PRs affected:** ${distinct}
- **Affected PRs:** ${prs_display}

## Why this issue exists

Each \`fix-checks-only\` worker handles flakes per-PR in isolation, so a test that flakes across many PRs gets silently re-run forever instead of root-caused. This issue surfaces the chronic pattern so the root cause gets fixed rather than papered over.

While this issue is open, the flake key is on the local \`.shipyard/flake-suspects.txt\` list, so \`fix-checks-only\` will **stop auto-rerunning** the check until a human signs off (deletes the suspect line). Affected PRs may carry \`blocked:ci\` referencing this issue.

## Resolution

Fix the root cause of the flake (race, timeout, environmental dependency), then remove the key from \`.shipyard/flake-suspects.txt\` and clear \`blocked:ci\` from the affected PRs.

<sub>Filed by shipyard flake-registry phase 2 (\`scripts/flake-enforce.sh\`). Dedupe marker: \`${marker}\`.</sub>
EOF

  # `gh issue create` prints the new issue's URL on stdout (no --json flag).
  local url
  url="$("$GH" issue create --repo "$repo" \
    --title "$title" \
    --body "$body" \
    --label "$STABILITY_LABEL" 2>/dev/null | tail -n1 || echo "")"

  printf '%s' "$url"
  printf 'file-tracking-issue created repo=%s url=%s flake=%q\n' "$repo" "${url:-?}" "$human_label" >&2
}

# ---- apply-blocked-ci side effect ------------------------------------------
# Dedupe: skip a PR already carrying blocked:ci. Otherwise label + comment.
do_apply_blocked_ci() {
  local repo="$1" pr="$2" human_label="$3" tracking_url="$4"

  # Only act on OPEN PRs that don't already carry the label. Read state and
  # the comma-joined label set on separate lines (a tab-split would mangle
  # multi-word label names).
  local view state labels
  view="$("$GH" pr view "$pr" --repo "$repo" \
    --json state,labels \
    --jq '.state, ([.labels[].name] | join(","))' 2>/dev/null || echo "")"
  state="$(printf '%s\n' "$view" | sed -n '1p')"
  labels="$(printf '%s\n' "$view" | sed -n '2p')"
  if [[ "$state" != "OPEN" ]]; then
    printf 'apply-blocked-ci skip (state=%s) repo=%s pr=%s\n' "${state:-?}" "$repo" "$pr" >&2
    return 0
  fi
  if [[ ",$labels," == *",${BLOCKED_CI_LABEL},"* ]]; then
    printf 'apply-blocked-ci skip (already labeled) repo=%s pr=%s\n' "$repo" "$pr" >&2
    return 0
  fi

  "$GH" pr edit "$pr" --repo "$repo" --add-label "$BLOCKED_CI_LABEL" >/dev/null 2>&1 || true

  local ref="${tracking_url:-the chronic-flake tracking issue}"
  "$GH" pr comment "$pr" --repo "$repo" --body \
"This PR is labeled \`blocked:ci\` because its failing check (\`${human_label}\`) crossed the shipyard chronic-flake escalation threshold — **this isn't your PR's fault, it's a known chronic flake**. See ${ref} for the root-cause tracking. The flake is on the local flake-suspects list, so shipyard will not auto-rerun it until a human signs off." \
    >/dev/null 2>&1 || true

  printf 'apply-blocked-ci labeled repo=%s pr=%s\n' "$repo" "$pr" >&2
}

# --------------------------------------------------------------------------
# suspects-list / is-suspect — the stop-auto-rerunning consumer side.
# --------------------------------------------------------------------------
cmd_suspects_list() {
  local repo_root=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo-root) repo_root="${2:-}"; shift 2 ;;
      *) echo "suspects-list: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done
  [[ -z "$repo_root" ]] && repo_root="$(pwd)"

  local path
  path="$(suspects_path "$repo_root")"
  [[ -f "$path" ]] || return 0
  # Strip comments + blank lines.
  grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$path" 2>/dev/null || true
}

cmd_is_suspect() {
  local repo_root="" key=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo-root) repo_root="${2:-}"; shift 2 ;;
      --key)       key="${2:-}"; shift 2 ;;
      *) echo "is-suspect: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done
  [[ -z "$repo_root" ]] && repo_root="$(pwd)"
  if [[ -z "$key" ]]; then
    echo "is-suspect: --key is required" >&2
    usage
    exit 64
  fi

  local path
  path="$(suspects_path "$repo_root")"
  [[ -f "$path" ]] || return 1
  if grep -qxF "$key" "$path" 2>/dev/null; then
    return 0
  fi
  return 1
}

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  usage
  exit 64
fi

subcmd="$1"
shift

case "$subcmd" in
  enforce)       cmd_enforce "$@" ;;
  suspects-list) cmd_suspects_list "$@" ;;
  is-suspect)    cmd_is_suspect "$@" ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    echo "flake-enforce.sh: unknown subcommand $subcmd" >&2
    usage
    exit 64
    ;;
esac
