#!/usr/bin/env bash
# detect-premise-on-open-pr.sh — does an issue's body name a path or symbol
# that does not exist on the default branch but DOES exist on an open PR's
# branch? (issue #1602)
#
# Background
# ----------
# A worker that files a follow-up issue often describes the tree as it will
# be once ITS OWN PR merges: "remove the ALLOWED_NESTED_DUPLICATES entry",
# "reuse the constant in scripts/lib/organization-photo-cache-control.js".
# The follow-up enters the ready pool immediately, and the next dispatch
# picks it up against a default branch where that premise is not true YET.
# The worker then sees a path/symbol that "doesn't exist" and reads the issue
# as stale — when the premise is merely EARLY. Shipping "the achievable
# half" against the default branch is the dangerous outcome: the two PRs can
# touch disjoint files (no conflict, nothing marks either dirty), and the
# default branch goes red on a required check once both land.
#
# The existing `blocked-by-in-flight-pr` defer class (#1426) and its
# self-clearing `<!-- do-work-blocked-by-prs: N,M -->` body marker (#1429)
# already cover a scope agent that NOTICES a collision with an open PR. This
# script is the mechanical detector that makes the "premise lives on an open
# PR" case noticeable at all — at scope pre-flight (including the C=1 inline
# path), per bundled issue in a co-scoped bundle (#1596), and at the worker's
# own premise verification (issue-work.md step 2).
#
# What it checks
# --------------
# 1. Extracts every inline-backticked token from the issue body.
# 2. Keeps tokens that look like a repo PATH (contains `/`, or ends in a
#    `.ext` whose extension starts with a letter) or a code SYMBOL
#    (identifier shape, >= 4 chars, and camelCase / snake_case /
#    SCREAMING_CASE — plain lowercase English words are skipped as noise).
# 3. Drops every token that already exists on <base>: a path via
#    `git cat-file -e` (or, for a bare basename with no `/`, any tracked file
#    with that basename), a symbol via `git grep -w -F`.
# 4. For each token ABSENT on <base>, looks for it on the open PRs: a path in
#    a PR's changed-file list (`gh pr list --json files`), a symbol on an
#    added (`+`) line of a PR's diff (`gh pr diff`, capped at --max-diff-prs
#    PRs, only fetched when at least one symbol is absent).
#
# A hit is EVIDENCE, not a verdict on its own: the consumer (scope agent,
# orchestrator, worker) still confirms the hit is load-bearing for an
# acceptance criterion before deferring on it. A miss means "not on any open
# PR" — the token may be genuinely stale, a typo, or prose.
#
# Usage
# -----
#   detect-premise-on-open-pr.sh --repo <owner/repo> (--issue <N> | --body-file <path>)
#                                [--base <ref>] [--exclude-pr <M>]... [--max-diff-prs <K>]
#
#   --base          git ref to test existence against (default: origin/HEAD,
#                   falling back to origin/main). Must already be fetched.
#   --exclude-pr    ignore this PR (repeatable) — e.g. your own PR, or a PR
#                   that already closes the issue.
#   --max-diff-prs  cap on `gh pr diff` calls for symbol lookup (default 30).
#
# Run from inside a checkout of <owner/repo> (the git checks read the local
# object store).
#
# Output (stdout), exit 0:
#   hit pr=<M> kind=<path|symbol> token=<token>        (zero or more lines)
#   verdict=premise-on-open-pr prs=<M>[,<M>...] [truncated=1]
#   verdict=clear checked=<n> absent=<k> [truncated=1]
#
# `truncated=1` means more open PRs existed than --max-diff-prs, so an absent
# symbol might live on a PR that was not scanned.
#
# Exit codes: 0 success (either verdict); 2 INDETERMINATE (base ref missing,
# gh failed, body unreadable) — printed as `verdict=indeterminate reason=...`,
# and a caller must NOT read it as clear; 64 bad usage; 65 missing dependency.
#
# The `gh` binary is overridable via $GH for tests.

set -u

GH="${GH:-gh}"

usage() {
  sed -n '/^# Usage/,/^# The `gh` binary/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

for dep in git jq; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "detect-premise-on-open-pr.sh: $dep is required but not installed" >&2
    exit 65
  fi
done

repo=""
issue=""
body_file=""
base=""
max_diff_prs=30
excludes=" "

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="${2:-}"; shift 2 ;;
    --issue) issue="${2:-}"; shift 2 ;;
    --body-file) body_file="${2:-}"; shift 2 ;;
    --base) base="${2:-}"; shift 2 ;;
    --exclude-pr) excludes="${excludes}${2:-} "; shift 2 ;;
    --max-diff-prs) max_diff_prs="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "detect-premise-on-open-pr.sh: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

if [ -z "$repo" ] || { [ -z "$issue" ] && [ -z "$body_file" ]; }; then
  echo "detect-premise-on-open-pr.sh: --repo and one of --issue / --body-file are required" >&2
  usage >&2
  exit 64
fi
case "$max_diff_prs" in
  ''|*[!0-9]*) echo "detect-premise-on-open-pr.sh: --max-diff-prs must be a non-negative integer" >&2; exit 64 ;;
esac

indeterminate() {
  echo "verdict=indeterminate reason=$1"
  exit 2
}

if ! command -v "$GH" >/dev/null 2>&1; then
  echo "detect-premise-on-open-pr.sh: gh is required but not installed" >&2
  exit 65
fi

# --- Resolve the base ref. ---
if [ -z "$base" ]; then
  if git rev-parse --verify --quiet "origin/HEAD^{commit}" >/dev/null; then
    base="origin/HEAD"
  else
    base="origin/main"
  fi
fi
git rev-parse --verify --quiet "${base}^{commit}" >/dev/null \
  || indeterminate "base-ref-unresolved:${base}"

# --- Read the body. ---
if [ -n "$body_file" ]; then
  [ -r "$body_file" ] || indeterminate "body-file-unreadable"
  body=$(cat "$body_file")
else
  body=$("$GH" issue view "$issue" --repo "$repo" --json body -q .body 2>/dev/null) \
    || indeterminate "gh-issue-view-failed"
fi

# --- Extract + classify inline-backticked tokens. ---
tokens=$(printf '%s\n' "$body" | grep -oE '`[^`[:space:]]+`' | tr -d '`' | sort -u)

paths=""
symbols=""
while IFS= read -r tok; do
  [ -z "$tok" ] && continue
  tok="${tok%()}"
  tok="${tok#./}"
  tok="${tok%/}"
  case "$tok" in
    -*|'#'*|'<'*|'$'*|*'://'*|*'*'*|*'?'*|*'{'*|*'['*|'') continue ;;
  esac
  if printf '%s' "$tok" | grep -qE '^[A-Za-z0-9._@+/-]+$' \
     && { case "$tok" in */*) true ;; *) false ;; esac \
          || printf '%s' "$tok" | grep -qE '\.[A-Za-z][A-Za-z0-9]{0,5}$'; }; then
    paths="${paths}${tok}"$'\n'
  elif printf '%s' "$tok" | grep -qE '^[A-Za-z_][A-Za-z0-9_]{3,}$' \
       && printf '%s' "$tok" | grep -qE '[a-z][A-Z]|_|^[A-Z0-9_]+$'; then
    symbols="${symbols}${tok}"$'\n'
  fi
done <<< "$tokens"

checked=0
absent_paths=""
absent_symbols=""

tree_list=$(git ls-tree -r --name-only "$base" 2>/dev/null) \
  || indeterminate "git-ls-tree-failed"

while IFS= read -r p; do
  [ -z "$p" ] && continue
  checked=$((checked + 1))
  case "$p" in
    */*)
      git cat-file -e "${base}:${p}" 2>/dev/null && continue
      ;;
    *)
      # A bare basename exists when any tracked file IS it or ends in /<it>.
      if printf '%s\n' "$tree_list" | awk -v b="$p" '
           $0 == b || (length($0) > length(b) && substr($0, length($0) - length(b)) == "/" b) { f = 1 }
           END { exit !f }'; then
        continue
      fi
      ;;
  esac
  absent_paths="${absent_paths}${p}"$'\n'
done <<< "$paths"

while IFS= read -r s; do
  [ -z "$s" ] && continue
  checked=$((checked + 1))
  git grep -q -w -F -e "$s" "$base" -- 2>/dev/null
  rc=$?
  if [ "$rc" -eq 0 ]; then
    continue
  elif [ "$rc" -ne 1 ]; then
    indeterminate "git-grep-failed"
  fi
  absent_symbols="${absent_symbols}${s}"$'\n'
done <<< "$symbols"

absent_count=$(printf '%s' "${absent_paths}${absent_symbols}" | grep -c . || true)

if [ "$absent_count" -eq 0 ]; then
  echo "verdict=clear checked=${checked} absent=0"
  exit 0
fi

# --- Look the absent tokens up on the open PRs. ---
open_prs=$("$GH" pr list --repo "$repo" --state open --limit 100 --json number,files 2>/dev/null) \
  || indeterminate "gh-pr-list-failed"
pr_files=$(jq -r '.[] | .number as $n | (.files // [])[] | "\($n)\t\(.path)"' <<< "$open_prs" 2>/dev/null) \
  || indeterminate "gh-pr-list-unparseable"
pr_numbers=$(jq -r '.[].number' <<< "$open_prs" 2>/dev/null) \
  || indeterminate "gh-pr-list-unparseable"

hits=""
add_hit() {
  # add_hit <pr> <kind> <token>
  case "$excludes" in *" $1 "*) return ;; esac
  hits="${hits}hit pr=$1 kind=$2 token=$3"$'\n'
}

while IFS= read -r p; do
  [ -z "$p" ] && continue
  while IFS=$'\t' read -r n f; do
    [ -z "$n" ] && continue
    case "$p" in
      */*) [ "$f" = "$p" ] && add_hit "$n" path "$p" ;;
      *) { [ "$f" = "$p" ] || case "$f" in */"$p") true ;; *) false ;; esac; } && add_hit "$n" path "$p" ;;
    esac
  done <<< "$pr_files"
done <<< "$absent_paths"

truncated=""
if [ -n "$absent_symbols" ]; then
  scanned=0
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    case "$excludes" in *" $n "*) continue ;; esac
    if [ "$scanned" -ge "$max_diff_prs" ]; then
      truncated=" truncated=1"
      break
    fi
    scanned=$((scanned + 1))
    added=$("$GH" pr diff "$n" --repo "$repo" 2>/dev/null | grep -E '^\+' | grep -vE '^\+\+\+ ') || true
    [ -z "$added" ] && continue
    while IFS= read -r s; do
      [ -z "$s" ] && continue
      if printf '%s\n' "$added" | grep -qwF -e "$s"; then
        add_hit "$n" symbol "$s"
      fi
    done <<< "$absent_symbols"
  done <<< "$pr_numbers"
fi

if [ -n "$hits" ]; then
  printf '%s' "$hits" | sort -u
  prs=$(printf '%s' "$hits" | sed -E 's/^hit pr=([0-9]+) .*/\1/' | sort -un | paste -sd, -)
  echo "verdict=premise-on-open-pr prs=${prs}${truncated}"
else
  echo "verdict=clear checked=${checked} absent=${absent_count}${truncated}"
fi
exit 0
