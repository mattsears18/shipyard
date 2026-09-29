#!/usr/bin/env bash
# co-scope-groups.sh — mechanical half of scope-preflight's co-scope grouping
# (issue #1596).
#
# Background (issue #1596)
# ------------------------
# Scope pre-flight scopes strictly one issue per scope agent. When several
# issues come out of the same audit run, that guarantees one of two bad
# outcomes: dispatch workers that collide on the same file (two auto-merge-
# armed PRs conflicting on one line, by construction), or serialize work that
# was genuinely independent. The collision is only visible from ABOVE both
# issues. Session `do-work-20260919T014132Z-18851` (mattsears18/lightwork)
# found lightwork#4892 and #4895 were two bugs in the same function of
# `public/sw.js` that both required the same `CACHE_VERSION` bump — one PR,
# not two — while two other sibling sets from the same audit were correctly
# shipped as separate PRs.
#
# This script owns the two parts of that decision that must NOT be a
# judgment call:
#
#   groups    — which candidates form a co-scope set. Issues sharing a
#               co-scope marker (`<!-- audit-run=<id> -->` by default, the
#               marker every `/shipyard:audit` filing carries) are a bounded,
#               mechanical candidate set — no heuristic.
#   validate  — whether a group scope agent's `one-pr` / `partial` verdict is
#               allowed to stand. The default is `separate`; a bundle stands
#               only when its `shared_surface` path appears in the `files`
#               list of EVERY bundled issue's ready entry. Anything else —
#               malformed, unjustified, a bundled issue that isn't ready —
#               falls back to `separate`. This is the guard against the
#               grouping pass becoming a licence to widen scope (the issue's
#               explicit caution).
#
# The judgment itself (are these one change?) stays with the group scope
# agent — see commands/do-work/setup/06h-co-scope-grouping.md.
#
# Usage
# -----
#   co-scope-groups.sh groups [--key <name>]... [--max <n>] [FILE]
#       Input (FILE or stdin): JSON array of {number, body}, in backlog-rank
#       order. Output: JSON array of {key, value, issues: [N, ...]} — only
#       sets of >= 2. A set larger than --max (default 6) is chunked in rank
#       order; a trailing chunk of one is dropped (it scopes individually).
#       An issue carrying several configured markers joins the FIRST --key's
#       group only, so no issue is ever in two groups. With no --key, the
#       default key is `audit-run`.
#
#   co-scope-groups.sh validate [FILE]
#       Input: one group scope-agent return (see 06h for the shape). Output:
#       one line, always —
#         verdict=bundle primary=<N> issues=<N,M,...> reason=<token>
#         verdict=separate primary= issues= reason=<token>
#
# Exit codes: 0 on any verdict/grouping (a fallback to `separate` is still a
# successful, fail-safe answer); 64 usage error; 65 unparseable input for
# `groups` (there is no safe grouping to invent from garbage — the caller
# scopes every candidate individually, which is today's behavior).
#
# Pure bash + jq.

set -u

usage_text() {
  echo "usage: co-scope-groups.sh groups [--key <name>]... [--max <n>] [FILE]"
  echo "       co-scope-groups.sh validate [FILE]"
}

usage() {
  usage_text >&2
  exit 64
}

cmd_groups() {
  local keys=() max=6 file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --key)
        [[ $# -ge 2 ]] || usage
        if [[ ! "$2" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
          echo "co-scope-groups.sh: invalid --key '$2' (want [a-z0-9][a-z0-9_-]*)" >&2
          exit 64
        fi
        keys+=("$2"); shift 2 ;;
      --max)
        [[ $# -ge 2 && "$2" =~ ^[0-9]+$ && "$2" -ge 2 ]] || usage
        max="$2"; shift 2 ;;
      -*) usage ;;
      *) [[ -z "$file" ]] || usage; file="$1"; shift ;;
    esac
  done
  [[ ${#keys[@]} -gt 0 ]] || keys=("audit-run")

  local input
  if [[ -n "$file" ]]; then
    [[ -r "$file" ]] || { echo "co-scope-groups.sh: cannot read $file" >&2; exit 65; }
    input="$(cat "$file")"
  else
    input="$(cat)"
  fi

  local keys_json
  keys_json="$(printf '%s\n' "${keys[@]}" | jq -R . | jq -s .)"

  # For each issue: the first configured key whose marker it carries.
  # Marker grammar: `<!-- <key>=<value> -->`, value [A-Za-z0-9._:-]+.
  if ! printf '%s' "$input" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "co-scope-groups.sh: input is not a JSON array" >&2
    exit 65
  fi
  printf '%s' "$input" | jq -c --argjson keys "$keys_json" --argjson max "$max" '
    def marker($k): (.body // "") as $b
      | ($b | [match("<!--\\s*" + $k + "=([A-Za-z0-9._:-]+)\\s*-->"; "g")] | first // null)
      | if . == null then null else .captures[0].string end;
    [ .[] | select(.number != null) | . as $i
      | ([ $keys[] | . as $k | ($i | marker($k)) as $v
           | select($v != null) | {key: $k, value: $v} ] | first // null) as $m
      | select($m != null)
      | {number: $i.number, key: $m.key, value: $m.value} ]
    | . as $tagged
    # Preserve first-appearance (rank) order of each (key,value) set.
    | [ $tagged[] | {key, value} ] | unique_by([.key, .value]) as $sets
    | [ $sets[] | . as $s
        | { key: $s.key, value: $s.value,
            first: ([ $tagged | to_entries[] | select(.value.key == $s.key and .value.value == $s.value) | .key ] | min),
            issues: [ $tagged[] | select(.key == $s.key and .value == $s.value) | .number ] } ]
    | sort_by(.first)
    | [ .[] | . as $g
        | [ range(0; ($g.issues | length); $max) as $o | $g.issues[$o:$o + $max] ]
        | .[] | select(length >= 2)
        | {key: $g.key, value: $g.value, issues: .} ]
  '
}

cmd_validate() {
  local file="${1:-}"
  local input
  if [[ -n "$file" ]]; then
    input="$(cat "$file" 2>/dev/null)" || input=""
  else
    input="$(cat)"
  fi
  if ! printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "verdict=separate primary= issues= reason=unparseable"
    return 0
  fi
  printf '%s' "$input" | jq -r '
    def sep($r): "verdict=separate primary= issues= reason=" + $r;
    def ready_entry($n): [ (.entries // [])[]
      | select(.issue == $n and (.files | type) == "array"
               and (has("deferred") | not) and (has("already_landed") | not)) ] | first // null;
    def strip_line: sub(":[0-9]+(-[0-9]+)?$"; "");
    . as $g
    | ($g.members // []) as $members
    | if ($g.grouping // "") == "separate" then sep("grouping-separate")
      elif (["one-pr", "partial"] | index($g.grouping // "")) == null then sep("invalid-grouping")
      elif ($g.primary_issue | type) != "number" then sep("missing-primary")
      elif ($g.bundled_issues | type) != "array" then sep("missing-bundled-issues")
      else
        ($g.bundled_issues | unique) as $b
        | if ($b | length) < 2 then sep("bundle-too-small")
          elif ($b | index($g.primary_issue)) == null then sep("primary-not-in-bundle")
          elif ([ $b[] | . as $x | select(($members | index($x)) == null) ] | length) > 0 then sep("bundled-issue-not-a-member")
          elif $g.grouping == "one-pr" and ($b != ($members | unique)) then sep("grouping-mismatch")
          elif $g.grouping == "partial" and ($b == ($members | unique)) then sep("grouping-mismatch")
          elif ([ $b[] | . as $x | select(($g | ready_entry($x)) == null) ] | length) > 0 then
            sep("bundled-issue-not-ready:" + ([ $b[] | . as $x | select(($g | ready_entry($x)) == null) | tostring ] | join(",")))
          elif (($g.shared_surface // "") | strip_line | length) == 0 then sep("missing-shared-surface")
          else
            (($g.shared_surface) | strip_line) as $p
            | if ([ $b[] | . as $n | select(( ($g | ready_entry($n)).files | index($p) ) == null) ] | length) > 0
              then sep("shared-surface-not-in-files")
              else "verdict=bundle primary=\($g.primary_issue) issues=\([ $b[] | tostring ] | join(",")) reason=shared-surface"
              end
          end
      end
  '
}

[[ $# -ge 1 ]] || usage
sub="$1"; shift
case "$sub" in
  -h|--help) usage_text; exit 0 ;;
  groups) cmd_groups "$@" ;;
  validate) cmd_validate "$@" ;;
  *) usage ;;
esac
