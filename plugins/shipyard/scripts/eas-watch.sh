#!/usr/bin/env bash
# eas-watch.sh — surface failed EAS builds in real time.
#
# Background (issue #270): EAS build failures are silent unless the user
# has explicitly wired one of EAS's notification surfaces (`eas
# webhook:create`, email opt-in, or a `.eas/workflows/*.yml` workflow that
# posts a GitHub status check). For app repos that run `eas build` from a
# developer laptop, none of these are wired by default — a failed build
# produces nothing visible until the user opens the EAS dashboard.
#
# This helper bridges that gap. It queries `eas build:list --json` for
# the current Expo project, diffs against a small state file at
# `$SHIPYARD_HOME/eas-state.json` ("last seen build id per project"),
# emits a one-line summary of every NEW build (errored or finished),
# and on errored builds writes a structured record to stdout that the
# `/shipyard:eas-watch` slash-command spec consumes (notification routing,
# optional `audit:eas-build` issue filing).
#
# Why a helper script (not inline-in-the-command spec): the EAS CLI output
# is JSON with version-sensitive shape, the state diff has subtle
# idempotency requirements (re-running the command should be a no-op when
# nothing new has happened), and the diff logic deserves a dedicated test
# suite. The slash-command spec at commands/eas-watch.md stays thin
# (resolve the project, invoke this helper, route the structured output)
# while the mechanics live here.
#
# Subcommands:
#
#   list-builds [--project <slug>] [--limit N] [--status <s>] [--profile <p>]
#              Wrap `eas build:list --json` and pass through the relevant
#              filters. Emits raw EAS-CLI JSON on stdout. Exit 3 if
#              `eas` is not on PATH, exit 4 if not inside an Expo project
#              (no app.json / app.config.js).
#
#   project-slug
#              Print the current project's slug (resolved via
#              `eas project:info --json` or app.json's expo.slug field).
#              Exit 4 if no Expo project at cwd.
#
#   state-path
#              Print the canonical state-file path
#              ($SHIPYARD_HOME/eas-state.json) — useful for tests and
#              for the slash-command spec to surface in --json mode.
#
#   state-init
#              Create $SHIPYARD_HOME/eas-state.json with an empty `{}`
#              if it doesn't exist. Idempotent (re-runs leave the file
#              untouched). Honors $SHIPYARD_HOME for relocation.
#
#   state-read [--project <slug>]
#              Emit the current state on stdout. Without --project,
#              prints the whole file; with --project, prints just that
#              project's entry (empty JSON object if the project isn't
#              tracked yet).
#
#   state-update --project <slug> --last-seen-id <id> [--last-checked <iso>]
#              Atomically update one project's state entry. Writes
#              <path>.tmp.<pid> then renames into place — mirrors
#              session-state.sh's atomicity discipline.
#
#   diff --project <slug> --builds-json <file>
#              Compare the build-list JSON against the recorded state for
#              <slug> and emit one line per NEW build (builds whose id
#              comes after the recorded last-seen-id in chronological
#              order). Each line is a single JSON object with fields:
#                {id, status, platform, profile, createdAt, gitCommitHash,
#                 errorMessage, logsUrl}
#              Empty output means no new builds. Does NOT write state —
#              the caller (slash-command spec) decides when to advance
#              the cursor (after notifications fire / issues are filed).
#
# State file shape ($SHIPYARD_HOME/eas-state.json):
#
#   {
#     "version": 1,
#     "projects": {
#       "<slug>": {
#         "last_seen_id": "<build-id>",
#         "last_checked_at": "<ISO-8601 UTC>"
#       }
#     }
#   }
#
# The slug is the EAS project identifier ("@<owner>/<name>"); two distinct
# Expo apps with the same `expo.name` but different owners stay separate.
#
# Atomicity: every write goes through a `.tmp.<pid>` file + `mv`. Partial
# writes leave the previous state file intact.
#
# Environment variables:
#
#   SHIPYARD_HOME      base dir (default: $HOME/.shipyard). Mirrors the
#                      session-state / cost-history convention.
#   SHIPYARD_EAS_CLI   override the `eas` binary path (default: `eas`).
#                      Tests inject a stub via this var.
#
# Exit codes:
#
#   0   success
#   2   state file already exists (state-init without --force; reserved)
#   3   `eas` binary not found on PATH (list-builds, project-slug)
#   4   not inside an Expo project (no app.json / app.config.js at cwd)
#   5   diff: --builds-json file missing or unreadable
#   64  usage error
#   65+ internal helper failure (jq missing, write permission denied)

set -u

if ! command -v jq >/dev/null 2>&1; then
  echo "eas-watch.sh: jq is required but not installed" >&2
  exit 65
fi

usage() {
  cat <<'EOF' >&2
Usage:
  eas-watch.sh list-builds   [--project <slug>] [--limit N]
                             [--status errored|finished|in-progress|...]
                             [--profile <name>]
  eas-watch.sh project-slug
  eas-watch.sh state-path
  eas-watch.sh state-init
  eas-watch.sh state-read    [--project <slug>]
  eas-watch.sh state-update  --project <slug> --last-seen-id <id>
                             [--last-checked <iso-8601>]
  eas-watch.sh diff          --project <slug> --builds-json <file>

Environment:
  SHIPYARD_HOME       base dir for eas-state.json (default: $HOME/.shipyard)
  SHIPYARD_EAS_CLI    `eas` binary override (default: `eas`)

Exit codes:
  0   success
  3   `eas` binary not found
  4   not inside an Expo project
  5   diff: --builds-json file missing
  64  usage error
  65+ internal helper failure
EOF
}

# ---------------------------------------------------------------------------
# Path resolution. Mirrors session-state.sh's $SHIPYARD_HOME convention.
# ---------------------------------------------------------------------------
state_path() {
  local home="${SHIPYARD_HOME:-${HOME}/.shipyard}"
  printf '%s/eas-state.json\n' "$home"
}

# ---------------------------------------------------------------------------
# Atomic-write helper. Writes stdin to <target>.tmp.<pid> then renames.
# A crash mid-write leaves the previous file intact — same property
# session-state.sh relies on.
# ---------------------------------------------------------------------------
atomic_write() {
  local target="$1"
  local dir
  dir=$(dirname "$target")
  mkdir -p "$dir" || { echo "eas-watch.sh: failed to mkdir $dir" >&2; return 65; }
  local tmp="${target}.tmp.$$"
  cat > "$tmp" || { rm -f "$tmp"; return 65; }
  mv -f "$tmp" "$target" || { rm -f "$tmp"; return 65; }
}

# ---------------------------------------------------------------------------
# Expo project detection. Returns 0 if app.json or app.config.{js,ts} is
# at cwd; exit-emits 4 otherwise. Project resolution prefers `eas
# project:info` (authoritative — pulls the EAS-side slug) but falls back
# to app.json's expo.slug field when the EAS CLI isn't available or hasn't
# been linked yet.
# ---------------------------------------------------------------------------
is_expo_project() {
  [[ -f "app.json" ]] || [[ -f "app.config.js" ]] || [[ -f "app.config.ts" ]]
}

# Resolve project slug. Prefer EAS-side identifier ("@owner/name") because
# that's what `eas build:list` emits in its records; fall back to local
# expo.slug when EAS isn't linked.
project_slug() {
  if ! is_expo_project; then
    echo "eas-watch.sh: not inside an Expo project (no app.json / app.config.{js,ts} at cwd)" >&2
    exit 4
  fi
  local eas_cli="${SHIPYARD_EAS_CLI:-eas}"
  # Try `eas project:info --json` first — authoritative if the project is
  # linked. Silently fall through to app.json's expo.slug if that fails;
  # the call requires network + auth and the user may be offline.
  if command -v "$eas_cli" >/dev/null 2>&1; then
    local info
    info=$("$eas_cli" project:info --json 2>/dev/null || true)
    if [[ -n "$info" ]]; then
      local owner name
      owner=$(printf '%s' "$info" | jq -r '.account.name // .ownerAccount.name // empty' 2>/dev/null || true)
      name=$(printf '%s' "$info" | jq -r '.name // .slug // empty' 2>/dev/null || true)
      if [[ -n "$owner" && -n "$name" ]]; then
        printf '@%s/%s\n' "$owner" "$name"
        return 0
      fi
    fi
  fi
  # Fall back to app.json's expo.slug.
  if [[ -f "app.json" ]]; then
    local slug
    slug=$(jq -r '.expo.slug // .name // empty' app.json 2>/dev/null || true)
    if [[ -n "$slug" ]]; then
      # Local-only slug (no owner) — prefix with "local:" so the state
      # file distinguishes it from an EAS-linked entry. Once the project
      # is linked, the canonical "@owner/name" slug will replace it.
      printf 'local:%s\n' "$slug"
      return 0
    fi
  fi
  echo "eas-watch.sh: could not determine project slug" >&2
  exit 4
}

# ---------------------------------------------------------------------------
# list-builds: wrap `eas build:list --json` with shipyard's filter
# conventions.
# ---------------------------------------------------------------------------
list_builds() {
  local project="" limit="20" status="" profile=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)  project="$2"; shift 2 ;;
      --limit)    limit="$2"; shift 2 ;;
      --status)   status="$2"; shift 2 ;;
      --profile)  profile="$2"; shift 2 ;;
      *)          echo "eas-watch.sh: unknown flag for list-builds: $1" >&2; exit 64 ;;
    esac
  done
  local eas_cli="${SHIPYARD_EAS_CLI:-eas}"
  if ! command -v "$eas_cli" >/dev/null 2>&1; then
    echo "eas-watch.sh: \`$eas_cli\` not found on PATH — install with: npm i -g eas-cli" >&2
    exit 3
  fi
  if ! is_expo_project; then
    echo "eas-watch.sh: not inside an Expo project (no app.json / app.config.{js,ts} at cwd)" >&2
    exit 4
  fi
  local args=(build:list --json --non-interactive)
  args+=(--limit "$limit")
  [[ -n "$status" ]]  && args+=(--status "$status")
  [[ -n "$profile" ]] && args+=(--profile "$profile")
  "$eas_cli" "${args[@]}"
}

# ---------------------------------------------------------------------------
# state-init: create the state file with an empty projects map. Idempotent.
# ---------------------------------------------------------------------------
state_init() {
  local path
  path=$(state_path)
  if [[ -f "$path" ]]; then
    return 0
  fi
  printf '{"version":1,"projects":{}}\n' | atomic_write "$path"
}

# state-read: emit whole file or one project's entry.
state_read() {
  local project=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project) project="$2"; shift 2 ;;
      *)         echo "eas-watch.sh: unknown flag for state-read: $1" >&2; exit 64 ;;
    esac
  done
  local path
  path=$(state_path)
  if [[ ! -f "$path" ]]; then
    # Treat missing as empty — caller decides whether to init.
    if [[ -n "$project" ]]; then
      printf '{}\n'
    else
      printf '{"version":1,"projects":{}}\n'
    fi
    return 0
  fi
  if [[ -n "$project" ]]; then
    jq --arg p "$project" '.projects[$p] // {}' "$path"
  else
    cat "$path"
  fi
}

# state-update: atomically write one project's entry.
state_update() {
  local project="" last_seen_id="" last_checked=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)        project="$2"; shift 2 ;;
      --last-seen-id)   last_seen_id="$2"; shift 2 ;;
      --last-checked)   last_checked="$2"; shift 2 ;;
      *)                echo "eas-watch.sh: unknown flag for state-update: $1" >&2; exit 64 ;;
    esac
  done
  if [[ -z "$project" ]]; then
    echo "eas-watch.sh: state-update requires --project <slug>" >&2; exit 64
  fi
  if [[ -z "$last_seen_id" ]]; then
    echo "eas-watch.sh: state-update requires --last-seen-id <id>" >&2; exit 64
  fi
  if [[ -z "$last_checked" ]]; then
    last_checked=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi
  local path
  path=$(state_path)
  # If the file doesn't exist yet, materialize the empty shape first.
  if [[ ! -f "$path" ]]; then
    state_init
  fi
  jq \
    --arg p "$project" \
    --arg id "$last_seen_id" \
    --arg ts "$last_checked" \
    '.projects[$p] = {last_seen_id: $id, last_checked_at: $ts}' \
    "$path" | atomic_write "$path"
}

# ---------------------------------------------------------------------------
# diff: compare a builds-list JSON against recorded state for <project>.
# Emit one JSON line per NEW build (builds whose id appears AFTER the
# recorded last-seen-id in EAS's chronological order — newest-first in
# the input array, so "new" = above the cursor row).
#
# Output is JSONL — one object per line — so callers can `read -r line` it
# without a JSON parser. Each line is a small projection of the relevant
# fields the slash-command spec consumes (id, status, platform, profile,
# createdAt, gitCommitHash, errorMessage, logsUrl).
#
# A build's `status` field can be "errored", "finished", "in-queue",
# "in-progress", "canceled", "new", or "build-failed" depending on EAS
# CLI version. We don't filter here — the caller picks what to notify on.
# The empty-state case (no recorded cursor) emits every build in the input
# so first-run users see something immediately.
# ---------------------------------------------------------------------------
diff_builds() {
  local project="" builds_file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)      project="$2"; shift 2 ;;
      --builds-json)  builds_file="$2"; shift 2 ;;
      *)              echo "eas-watch.sh: unknown flag for diff: $1" >&2; exit 64 ;;
    esac
  done
  if [[ -z "$project" ]]; then
    echo "eas-watch.sh: diff requires --project <slug>" >&2; exit 64
  fi
  if [[ -z "$builds_file" || ! -f "$builds_file" ]]; then
    echo "eas-watch.sh: diff requires --builds-json <file> (file must exist)" >&2
    exit 5
  fi
  local path
  path=$(state_path)
  local last_seen=""
  if [[ -f "$path" ]]; then
    last_seen=$(jq -r --arg p "$project" '.projects[$p].last_seen_id // empty' "$path" 2>/dev/null || true)
  fi
  # EAS returns newest-first. Builds NEWER than last_seen are above it in
  # the array (lower index). Walk newest-first; emit until we hit the
  # cursor row.
  if [[ -z "$last_seen" ]]; then
    # First run for this project — emit every build.
    jq -c '.[] | {
      id, status, platform, profile, createdAt,
      gitCommitHash: (.gitCommitHash // .meta.commit // null),
      errorMessage: (.error.message // .errors[0].message // null),
      logsUrl: (.logsUrl // null)
    }' "$builds_file"
    return 0
  fi
  jq -c --arg cursor "$last_seen" '
    # Walk newest-first, take builds until we see the cursor id.
    [ .[] | . as $b | if $b.id == $cursor then "STOP" else $b end ]
    | (if any(. == "STOP") then (.[0:(index("STOP"))]) else . end)
    | .[]
    | {
      id, status, platform, profile, createdAt,
      gitCommitHash: (.gitCommitHash // .meta.commit // null),
      errorMessage: (.error.message // .errors[0].message // null),
      logsUrl: (.logsUrl // null)
    }
  ' "$builds_file"
}

# ---------------------------------------------------------------------------
# Subcommand dispatch
# ---------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then usage; exit 64; fi
sub="$1"; shift
case "$sub" in
  list-builds)  list_builds "$@" ;;
  project-slug) project_slug ;;
  state-path)   state_path ;;
  state-init)   state_init ;;
  state-read)   state_read "$@" ;;
  state-update) state_update "$@" ;;
  diff)         diff_builds "$@" ;;
  -h|--help)    usage; exit 0 ;;
  *)            echo "eas-watch.sh: unknown subcommand: $sub" >&2; usage; exit 64 ;;
esac
