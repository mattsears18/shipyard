#!/usr/bin/env bash
# trusted-authors-normalize.sh — expand `<name>[bot]` ↔ `app/<name>` aliases.
#
# Background (issue #296): GitHub App accounts return TWO different login
# shapes depending on which API you ask:
#
#   - REST `/repos/.../issues/N/events` returns the legacy-style login:
#       `sentry[bot]`
#   - GraphQL `Bot`/`App` actor objects (what `gh issue view --json author`
#     returns) expose:
#       `app/sentry`
#
# The two strings have nothing in common after lowercasing. A maintainer
# who follows the `.shipyard/trusted-authors.txt` convention and adds
# `sentry[bot]` to their allowlist file will see their bot's issues
# silently bucketed as untrusted by `/shipyard:do-work`, because the
# orchestrator compares against the GraphQL `app/sentry` shape that
# `gh issue list --json author` returns.
#
# This helper normalizes a list of GitHub logins by adding the alias for
# every `<name>[bot]` / `app/<name>` entry. After normalization, the
# allowlist contains BOTH shapes for every GH App account, so the
# downstream literal-substring comparison matches regardless of which
# API the comparison value came from.
#
# Reversibility: the helper never drops or rewrites the original entry —
# it only appends. So a file that says `sentry[bot]` produces
# `{sentry[bot], app/sentry}`, and a file that says `app/sentry` produces
# `{app/sentry, sentry[bot]}`. A file that already lists both shapes
# produces the deduped union.
#
# Human GitHub logins (no `[bot]` suffix, no `app/` prefix) pass through
# unchanged.
#
# Usage:
#
#   # Pipe a list of logins (one per line) through the normalizer:
#   printf 'mattsears18\nsentry[bot]\n' \
#     | "${CLAUDE_PLUGIN_ROOT}/scripts/trusted-authors-normalize.sh"
#   # → mattsears18
#   # → sentry[bot]
#   # → app/sentry
#
#   # Or pass a file path as the first argument:
#   "${CLAUDE_PLUGIN_ROOT}/scripts/trusted-authors-normalize.sh" \
#     .shipyard/trusted-authors.txt
#
# Output format: one normalized login per line, lowercased, deduped, sorted.
# Comments (`#...`) and blank lines in input files are stripped — same
# convention as the documented `.shipyard/trusted-authors.txt` format.
#
# Exit codes:
#   0 — success (output emitted to stdout)
#   64 — usage error (e.g. file argument doesn't exist)
#
# Audit-log mode (--report-aliases): instead of the normal stdout output,
# emit one line per alias added, in the form
# `[trusted-authors] alias: <input> → <added>`. Lets the orchestrator's
# advisory log in step 1.7 surface what aliasing was applied, per the
# acceptance criteria in issue #296.

set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: trusted-authors-normalize.sh [--report-aliases] [<file>]

  Read GitHub logins (one per line) from <file> or stdin, then emit the
  same set with `<name>[bot]` and `app/<name>` aliases cross-added. All
  output is lowercased, deduped, and sorted.

  --report-aliases  Instead of the normalized list, emit one
                    `[trusted-authors] alias: <input> -> <added>` line per
                    alias that was added. Empty output means no aliasing
                    was needed.
EOF
  exit 64
}

report_aliases=0
input_file=""

while [ $# -gt 0 ]; do
  case "$1" in
    --report-aliases)
      report_aliases=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    --*)
      printf 'trusted-authors-normalize.sh: unknown flag %s\n' "$1" >&2
      exit 64
      ;;
    *)
      if [ -n "$input_file" ]; then
        printf 'trusted-authors-normalize.sh: at most one file argument allowed\n' >&2
        exit 64
      fi
      input_file="$1"
      shift
      ;;
  esac
done

# Read input — either the file or stdin.
if [ -n "$input_file" ]; then
  if [ ! -f "$input_file" ]; then
    printf 'trusted-authors-normalize.sh: file not found: %s\n' "$input_file" >&2
    exit 64
  fi
  raw=$(cat "$input_file")
else
  raw=$(cat)
fi

# Strip comments, strip whitespace, drop blanks, lowercase. The pipeline
# mirrors the convention setup.md step 1.7, external-author-gate.yml, and
# label-event-audit.yml all use to canonicalize an allowlist file.
# (intake-refinement-gate.yml was retired in #520 — it used the same
# pipeline before the refinement gate was eliminated.)
normalized=$(printf '%s\n' "$raw" \
  | sed -e 's/#.*$//' -e 's/[[:space:]]//g' \
  | grep -v '^$' \
  | tr '[:upper:]' '[:lower:]' \
  | sort -u || true)

# If the cleaned input is empty, exit clean — no aliasing to do.
if [ -z "$normalized" ]; then
  exit 0
fi

# Walk the deduped, lowercased entries and emit the alias for every
# `<name>[bot]` or `app/<name>` shape. The `aliases` accumulator is
# unioned with the input set at the end.
aliases=""
alias_log=""
while IFS= read -r entry; do
  [ -z "$entry" ] && continue
  case "$entry" in
    app/*)
      # `app/<name>` → also add `<name>[bot]`
      name=${entry#app/}
      aliased="${name}[bot]"
      aliases="${aliases}${aliased}"$'\n'
      alias_log="${alias_log}[trusted-authors] alias: ${entry} -> ${aliased}"$'\n'
      ;;
    *'[bot]')
      # `<name>[bot]` → also add `app/<name>`
      name=${entry%'[bot]'}
      aliased="app/${name}"
      aliases="${aliases}${aliased}"$'\n'
      alias_log="${alias_log}[trusted-authors] alias: ${entry} -> ${aliased}"$'\n'
      ;;
    *)
      # Human login (no `[bot]` suffix, no `app/` prefix). Pass through.
      ;;
  esac
done <<EOF
$normalized
EOF

if [ "$report_aliases" -eq 1 ]; then
  # Emit alias-log lines only. De-dupe in case the same alias was added
  # twice (e.g. file already contained both forms — the second entry
  # produces a redundant alias for the first).
  if [ -n "$alias_log" ]; then
    printf '%s' "$alias_log" | sort -u
  fi
  exit 0
fi

# Normal mode: union of the original set + aliases, deduped, sorted.
{
  printf '%s\n' "$normalized"
  if [ -n "$aliases" ]; then
    printf '%s' "$aliases"
  fi
} | grep -v '^$' | sort -u
