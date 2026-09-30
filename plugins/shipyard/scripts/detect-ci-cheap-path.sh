#!/usr/bin/env bash
# detect-ci-cheap-path.sh — read whether a repo's CI has a "cheap path": a
# pull_request-triggered workflow that skips itself (via `paths-ignore:`) for
# a diff confined to certain globs (docs, comments, config-only, etc.), and
# decide whether a CANDIDATE issue's body-referenced file paths fall entirely
# inside that cheap zone.
#
# Background (issue #1157 — follow-up to #1141 / #1156)
# --------------------------------------------------------
# #1141 clamps effective concurrency toward a self-hosted CI runner pool's
# size at session start; #1156 adds a live, dispatch-time hold when the
# queued-run backlog outgrows that pool. Both treat every candidate issue as
# equally CI-expensive. But on a repo whose CI is path-gated (a workflow
# declares `paths-ignore: ['docs/**', '**/*.md']` under its `pull_request:`
# trigger), a docs-only or config-only PR never even runs the heavy job — it
# costs the runner pool nothing. #1141's own repro noted the maintainer
# manually picking a docs-only issue for the last free dispatch slot on a
# saturated pool, specifically because it wouldn't queue behind the runner
# backlog. This script formalizes that judgment call:
#
#   1. Read a repo's workflow files and extract the `paths-ignore:` glob
#      list from any pull_request-triggered workflow that has one (the
#      "cheap path" — a diff that stays entirely inside these globs doesn't
#      trigger that workflow's job at all).
#   2. Given a candidate's set of file paths (extracted from its issue title
#      + body by the caller, mirroring inline-trivial's `\b[\w./-]+\.\w{1,5}\b`
#      pattern), decide whether EVERY one of them matches at least one of
#      the cheap-path globs.
#
# Scope, deliberately narrow (issue #1157's design questions):
#   - Only `paths-ignore:` (an EXCLUDE list — directly invertible: "matches
#     the ignore list" == "doesn't trigger this workflow") is detected. A
#     workflow that instead uses an INCLUDE-only `paths:` allowlist has an
#     implicit complement that isn't safely invertible from the allowlist
#     alone without also knowing every other path in the repo, so it is not
#     treated as evidence of a cheap path here. A repo with no `paths-ignore:`
#     anywhere in its `pull_request`-triggered workflows has NO cheap path —
#     every PR runs the same CI regardless of changed files — and this
#     script reports that honestly (`no-cheap-path`) rather than guessing.
#   - Issue #1600 adds the job-level lane: a `dorny/paths-filter` step whose
#     filter is `'**'` plus `'!...'` negations under
#     `predicate-quantifier: every` (see extract_dorny_globs_from_file). The
#     negations are an exclude list too, so they invert the same way.
#   - Across workflow files the per-file glob sets are INTERSECTED, not
#     unioned (#1600): a path is only cheap when every path-filtered
#     workflow skips it. Workflows with no filter don't participate.
#   - This is a heuristic, advisory read, same posture as
#     detect-ci-runner-capacity.sh: a malformed/unreadable workflow file
#     degrades toward "found nothing" (never toward fabricating a glob list),
#     and a match/no-match decision on zero evidence (no candidate paths
#     found, or no globs known) always resolves to `no-match` — never bias
#     dispatch toward a candidate this script couldn't actually evaluate.
#
# Usage — live glob discovery (repo-local, no network calls):
#   bash detect-ci-cheap-path.sh <workflows-dir>
#     -> prints one of, on stdout (single line):
#          cheap-path-available globs=<comma-separated-glob-list>
#          no-cheap-path
#        diagnostics on stderr. ALWAYS exits 0 (advisory read).
#
# Usage — pure path-extraction (hermetic, for tests and callers that want to
# pull candidate file paths out of an issue's title+body text):
#   bash detect-ci-cheap-path.sh --extract-paths "<text>"
#     -> prints comma-separated, de-duplicated file-looking tokens matched by
#        the same `\b[\w./-]+\.\w{1,5}\b` pattern inline-trivial's rule 7
#        uses for its own file-path detection (empty line if none found).
#
# Usage — pure match decision (hermetic, no network calls):
#   bash detect-ci-cheap-path.sh --match <paths-csv> <globs-csv>
#     -> prints "match" or "no-match" on stdout (single line).
#     "match" requires: at least one candidate path AND at least one glob
#     (never bias on zero evidence), AND every candidate path matches at
#     least one glob.

set -uo pipefail

# glob_to_regex <glob> — translate a simple shell/gitignore-style glob
# (supporting `**/`, `/**`, `**`, `*`, `?`) into an ERE anchored on the full
# string, for use with bash's [[ =~ ]]. Regex metacharacters other than
# * ? are escaped first so a glob like `docs/**` doesn't get corrupted by
# stray `.`/`+`/etc. `**/` and `/**` get gitignore-style "optional directory
# prefix/suffix" semantics (`**/*.md` matches a root-level `README.md`, not
# just `a/README.md`) rather than requiring a literal separator to be
# present — the naive "`**` -> `.*`" substitution alone would reject a
# root-level file against a `**/*.md`-style glob, which is the common case
# in a workflow's `paths-ignore:` list.
glob_to_regex() {
  local g="$1" out
  # shellcheck disable=SC2016 # the sed program is intentionally single-quoted (no shell expansion wanted)
  out="$(printf '%s' "$g" | sed -e 's/[.[\^$()+{}|]/\\&/g')"
  out="${out//\*\*\//@@DSSLASH@@}"
  out="${out//\/\*\*/@@SLASHDS@@}"
  out="${out//\*\*/@@DOUBLESTAR@@}"
  out="${out//\*/[^/]*}"
  out="${out//\?/.}"
  out="${out//@@DSSLASH@@/(.*\/)?}"
  out="${out//@@SLASHDS@@/(\/.*)?}"
  out="${out//@@DOUBLESTAR@@/.*}"
  printf '^%s$' "$out"
}

# trim <string> — strip leading/trailing whitespace and a single pair of
# matching quote characters.
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  s="${s%\'}"; s="${s#\'}"
  s="${s%\"}"; s="${s#\"}"
  printf '%s' "$s"
}

# extract_paths <text> — mirrors inline-trivial rule 7's file-path regex
# (`\b[\w./-]+\.\w{1,5}\b`), de-duplicated, comma-joined.
extract_paths() {
  local text="$1"
  printf '%s' "$text" \
    | grep -oE '[A-Za-z0-9_./-]+\.[A-Za-z0-9_]{1,5}\b' \
    | awk '!seen[$0]++' \
    | paste -sd, -
}

# match_paths <paths-csv> <globs-csv> — "match" iff every path matches at
# least one glob, and both lists are non-empty.
match_paths() {
  local paths_csv="$1" globs_csv="$2"
  if [ -z "$paths_csv" ] || [ -z "$globs_csv" ]; then
    printf 'no-match\n'
    return 0
  fi

  local -a paths globs
  IFS=',' read -ra paths <<< "$paths_csv"
  IFS=',' read -ra globs <<< "$globs_csv"

  local p g regex matched any_path=0
  for p in "${paths[@]}"; do
    p="$(trim "$p")"
    [ -z "$p" ] && continue
    any_path=1
    matched=0
    for g in "${globs[@]}"; do
      g="$(trim "$g")"
      [ -z "$g" ] && continue
      regex="$(glob_to_regex "$g")"
      if [[ "$p" =~ $regex ]]; then
        matched=1
        break
      fi
    done
    if [ "$matched" -eq 0 ]; then
      printf 'no-match\n'
      return 0
    fi
  done

  if [ "$any_path" -eq 0 ]; then
    printf 'no-match\n'
    return 0
  fi
  printf 'match\n'
}

# extract_globs_from_file <file> — print each `paths-ignore:` glob found in
# a workflow file, one per line. Handles both flow style
# (`paths-ignore: ['a', 'b']`) and block style (`paths-ignore:` followed by
# indented `- 'a'` lines). Best-effort: an unparseable file yields nothing,
# never an error.
extract_globs_from_file() {
  local file="$1"
  [ -f "$file" ] || return 0

  awk '
    BEGIN { collecting = 0 }
    /paths-ignore[ \t]*:/ {
      line = $0
      sub(/^[^:]*:/, "", line)
      gsub(/^[ \t]+/, "", line)
      gsub(/[ \t]+$/, "", line)
      if (line ~ /^\[/) {
        gsub(/^\[/, "", line)
        gsub(/\][ \t]*$/, "", line)
        n = split(line, arr, ",")
        for (i = 1; i <= n; i++) {
          g = arr[i]
          gsub(/^[ \t'"'"'"]+/, "", g)
          gsub(/[ \t'"'"'"]+$/, "", g)
          if (g != "") print g
        }
        collecting = 0
        next
      }
      collecting = 1
      next
    }
    collecting == 1 {
      if ($0 ~ /^[ \t]*-[ \t]*.+/) {
        g = $0
        sub(/^[ \t]*-[ \t]*/, "", g)
        sub(/#.*/, "", g)
        gsub(/^[ \t'"'"'"]+/, "", g)
        gsub(/[ \t'"'"'"]+$/, "", g)
        if (g != "") print g
        next
      } else {
        collecting = 0
      }
    }
  ' "$file" 2>/dev/null
}

# extract_dorny_globs_from_file <file> — print each cheap-lane glob a
# `dorny/paths-filter` step declares, one per line (issue #1600).
#
# The shape recognized is the "everything except" filter a job gates its
# heavy steps on:
#
#   - uses: dorny/paths-filter@v4
#     with:
#       predicate-quantifier: every
#       filters: |
#         code:
#           - '**'
#           - '!**/*.md'
#           - '!docs/**'
#
# A filter qualifies only when BOTH hold, and each negation (minus its `!`)
# is emitted as a cheap glob:
#   - it carries the positive catch-all `'**'` plus at least one `'!...'`
#     negation, AND
#   - the step sets `predicate-quantifier: every`. Under dorny's default
#     (`some`), `'**'` alone satisfies the filter for every file, so the
#     negations exclude NOTHING — that repo has no cheap lane at all, and
#     reporting one would bias dispatch toward PRs that still run the full
#     matrix (the exact failure #1600 exists to prevent).
#
# A negated glob that is ALSO a positive pattern of another filter in the
# same step is dropped: that is the "re-admit" idiom (a second filter ORed
# into the heavy gate for a path the negation excludes), so a diff there is
# not reliably cheap. Only an exact-text re-admit is detected; this stays a
# heuristic, advisory read like the rest of this script. Flow-style filter
# lists and a `filters:` value naming an external file are not parsed —
# they yield nothing, never a guess.
extract_dorny_globs_from_file() {
  local file="$1"
  [ -f "$file" ] || return 0

  awk '
    function indent_of(s,   m) { match(s, /^[ ]*/); return RLENGTH }
    function unquote(s) {
      sub(/[ \t]+#.*$/, "", s)
      gsub(/^[ \t'"'"'"]+/, "", s)
      gsub(/[ \t'"'"'"]+$/, "", s)
      return s
    }
    function reset_step() {
      in_step = 0; every = 0; in_filters = 0; filters_col = -1
      cur = ""; nfilters = 0
      delete pats; delete fnames
    }
    function flush_step(   i, f, n, k, arr, p, g, positives, has_all, negs) {
      if (!in_step) return
      if (every) {
        # Collect every positive pattern, keyed by filter, for the re-admit check.
        for (i = 1; i <= nfilters; i++) {
          f = fnames[i]
          n = split(pats[f], arr, "\n")
          for (k = 1; k <= n; k++) {
            p = arr[k]
            if (p != "" && substr(p, 1, 1) != "!" && p != "**") positives[f SUBSEP p] = 1
          }
        }
        for (i = 1; i <= nfilters; i++) {
          f = fnames[i]
          n = split(pats[f], arr, "\n")
          has_all = 0; negs = 0
          for (k = 1; k <= n; k++) {
            if (arr[k] == "**") has_all = 1
            if (substr(arr[k], 1, 1) == "!") negs++
          }
          if (!has_all || negs == 0) continue
          for (k = 1; k <= n; k++) {
            p = arr[k]
            if (substr(p, 1, 1) != "!") continue
            g = substr(p, 2)
            if (g == "" || readmitted(g, f, positives)) continue
            print g
          }
        }
      }
      reset_step()
    }
    function readmitted(g, self, positives,   key, parts) {
      for (key in positives) {
        split(key, parts, SUBSEP)
        if (parts[1] != self && parts[2] == g) return 1
      }
      return 0
    }
    BEGIN { reset_step() }
    {
      line = $0
      if (line ~ /^[ \t]*$/ || line ~ /^[ \t]*#/) next
      ind = indent_of(line)

      if (line ~ /uses:[ \t]*["'"'"']?dorny\/paths-filter/) {
        flush_step()
        in_step = 1
        # The step key column: `uses:` itself (for `- uses:` add the dash).
        step_col = ind
        if (line ~ /^[ ]*-[ ]+uses:/) { t = line; sub(/^[ ]*-[ ]+/, "", t); step_col = length(line) - length(t) }
        next
      }
      if (!in_step) next

      if (ind < step_col) { flush_step(); next }

      if (in_filters) {
        if (ind <= filters_col) {
          in_filters = 0
        } else if (line ~ /^[ ]*-[ ]*/) {
          if (cur != "") {
            p = line; sub(/^[ ]*-[ ]*/, "", p); p = unquote(p)
            if (p != "") pats[cur] = (pats[cur] == "" ? p : pats[cur] "\n" p)
          }
          next
        } else if (line ~ /^[ ]*[A-Za-z0-9_.-]+:[ \t]*$/) {
          cur = line; sub(/^[ ]*/, "", cur); sub(/:[ \t]*$/, "", cur)
          fnames[++nfilters] = cur
          next
        } else {
          cur = ""
          next
        }
      }

      if (line ~ /predicate-quantifier:/) {
        v = line; sub(/^[^:]*:/, "", v); v = unquote(v)
        if (v == "every") every = 1
        next
      }
      if (line ~ /^[ ]*filters:[ \t]*[|>]/) {
        in_filters = 1; filters_col = ind; cur = ""
        next
      }
    }
    END { flush_step() }
  ' "$file" 2>/dev/null
}

# decide_repo_shape <workflows-dir> — the live-discovery path.
decide_repo_shape() {
  local dir="$1" f glob_str=""
  if [ ! -d "$dir" ]; then
    echo "detect-ci-cheap-path: workflows dir '${dir}' not found -- treating as no-cheap-path" >&2
    printf 'no-cheap-path\n'
    return 0
  fi

  # A diff is cheap only if EVERY path-filtered workflow skips it (issue
  # #1600): union the globs WITHIN one file (a trigger-level `paths-ignore:`
  # and a job-level dorny negation each independently skip that file's
  # heavy work), then INTERSECT across files. The pre-#1600 union across
  # files over-claimed — a glob one light workflow ignores (`.github/**` in
  # a bundle-size check) was reported cheap even though the heavy workflow
  # still runs on it. The intersection is exact-text, so a glob spelled
  # differently in two workflows drops out: the conservative direction.
  # A workflow declaring no filter at all is not part of the intersection —
  # its cost can't be read from the file, and an unfiltered repo stays
  # `no-cheap-path` because no workflow contributes a glob.
  local -a common=() file_globs=() next=()
  local first=1 g item file_csv
  while IFS= read -r -d '' f; do
    file_globs=()
    while IFS= read -r g; do
      [ -n "$g" ] && file_globs+=("$g")
    done < <(extract_globs_from_file "$f"; extract_dorny_globs_from_file "$f")
    [ "${#file_globs[@]}" -eq 0 ] && continue

    file_csv=",$(IFS=,; printf '%s' "${file_globs[*]}"),"
    if [ "$first" -eq 1 ]; then
      first=0
      common=("${file_globs[@]}")
    else
      next=()
      for item in ${common[@]+"${common[@]}"}; do
        case "$file_csv" in *",${item},"*) next+=("$item");; esac
      done
      common=(${next[@]+"${next[@]}"})
    fi
  done < <(find "$dir" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) -print0 2>/dev/null | sort -z)

  if [ "${#common[@]}" -eq 0 ]; then
    printf 'no-cheap-path\n'
    return 0
  fi

  # De-duplicate while preserving order.
  local -a deduped=()
  local seen_csv=","
  for item in "${common[@]}"; do
    case "$seen_csv" in
      *",${item},"*) ;;
      *) deduped+=("$item"); seen_csv="${seen_csv}${item},";;
    esac
  done

  glob_str="$(IFS=,; printf '%s' "${deduped[*]}")"
  printf 'cheap-path-available globs=%s\n' "$glob_str"
}

main() {
  if [ "${1:-}" = "--extract-paths" ]; then
    if [ "$#" -ne 2 ]; then
      echo "usage: $0 --extract-paths <text>" >&2
      exit 1
    fi
    extract_paths "$2"
    exit 0
  fi

  if [ "${1:-}" = "--match" ]; then
    if [ "$#" -ne 3 ]; then
      echo "usage: $0 --match <paths-csv> <globs-csv>" >&2
      exit 1
    fi
    match_paths "$2" "$3"
    exit 0
  fi

  local dir="${1:-}"
  if [ -z "$dir" ]; then
    echo "usage: $0 <workflows-dir>" >&2
    echo "       $0 --extract-paths <text>" >&2
    echo "       $0 --match <paths-csv> <globs-csv>" >&2
    exit 1
  fi

  decide_repo_shape "$dir"
}

main "$@"
