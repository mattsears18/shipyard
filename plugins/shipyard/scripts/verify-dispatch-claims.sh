#!/usr/bin/env bash
# verify-dispatch-claims.sh — re-resolve the factual claims a composed dispatch
# prompt (or a mid-flight `SendMessage` interrupt) makes about ANOTHER PR's or
# issue's live state, and refuse the dispatch when the live state contradicts
# the claim (issue #1553).
#
# Background (issue #1553)
# -----------------------
# `dispatch-rules.md` already requires the orchestrator to verify another PR's
# or issue's live state before asserting it in a dispatch prompt (#781 / #1062,
# extended to every `SendMessage` by #1230). That rule is PROSE ONLY — nothing
# mechanically checks it at composition time, and #1553's repro is the orchest-
# rator violating it against `mattsears18/lightwork`: the composed prompt said
#
#   "this issue is the follow-up to #4661, whose fix **has merged**
#    (PR #4662 -> apps/lightwork/eslint.config.js, confirmed by reading the
#    merged state)"
#
# while PR #4662 was still `OPEN` with auto-merge armed and CI pending. The
# parenthetical "confirmed by reading the merged state" was fabricated: the
# orchestrator had run `gh pr view 4662` minutes earlier, SEEN `OPEN`, and then
# asserted the opposite. The worker distrusted the premise and recovered, but
# only because it chose to — which is exactly what a confidently-phrased prompt
# discourages.
#
# The incentive runs against the prose rule: at dispatch time the prompt is
# being *composed*, the state was checked a few turns earlier, and re-verifying
# feels redundant — which is precisely when a stale premise gets written down
# as a confirmed fact. This script removes the judgment call: it reads the
# composed prompt as a text artifact, finds the claims, and resolves them.
#
# A SECOND claim class, added from a fresh in-session repro on #1553 itself:
# an unverified assertion about a SPEC FILE'S CONTENT ("there is no literal
# fetch command in the spec" — false; the command was in
# `setup/04-backlog-divert.md` step 4). Same failure shape (an unverified fact
# written down as confirmed), same cheap composition-time check (a `grep`), but
# a different referent — a path rather than a number. This script cannot
# adjudicate the substance of such a claim, so it flags the SHAPE and makes the
# composer ground it; see UNGROUNDED below.
#
# Deliberately NARROW, in one specific direction: a claim is only reported when
# it carries a resolvable referent. "The dependency PR already merged", with no
# `#<n>` anywhere on the line, is a real unverified claim and this script says
# nothing about it — there is no number to resolve, and inventing an
# INDETERMINATE for every numberless sentence would bury the checkable findings
# in noise. The prose rule in `dispatch-rules.md` still governs that case; this
# script is the mechanical floor under it, not a replacement for it.
#
# Modes
# -----
#   --scan <prompt-file>
#       Text scan only, no network I/O. Prints one line per detected claim:
#         kind=<merged|closed|content> line=<n> ref=<num|path> phrase=<text>
#       or `none`. Always exits 0 — this is the pure, fixture-testable half.
#
#   --probe <owner/repo> <number>
#       Live resolution of one referent. Prints `pr:<STATE>`, `issue:<STATE>`,
#       or `unknown`. Always exits 0.
#
#   --decide <kind> <probe-result>
#       Pure decision, no I/O. Prints `ok`, `contradicted`, `indeterminate`, or
#       `n/a`. Always exits 0. Same `--decide` split as
#       detect-stale-agent-limitation.sh / detect-ungated-admin-direct-merge.sh.
#
#   --repo <owner/repo> [--self <N>] <prompt-file>
#       Live gate mode: scan, probe every referent, decide, report.
#         exit 0  `OK: ...`            nothing contradicted; safe to dispatch.
#         exit 1  `CONTRADICTED: ...` / `UNGROUNDED: ...` — do NOT dispatch as
#                 written. Each line carries the live state and the conditional
#                 rewrite #1062 prescribes.
#         exit 2  `INDETERMINATE: ...` a claim could not be resolved at all.
#                 FAILS CLOSED — treat exactly like exit 1.
#         exit 64 usage error.
#       `--self <N>` excludes the dispatched issue's own number, which appears
#       throughout a normal prompt and is never a claim about a third party.
#
# Suppressing a claim the composer HAS grounded
# --------------------------------------------
# A hedged line is never reported — "PR #4662 should have merged by the time
# you start; verify with `gh pr view 4662 --json state,mergedAt`" is #1062's
# own prescribed rewrite and is recognized as such. For a content claim that
# the composer genuinely checked and wants to keep unconditional, cite the
# evidence inline with a `(grounded: <command>)` marker on the same line — the
# same `evidence_pointer` convention `backlog-filter.sh` already uses.
#
# Conditional clauses (issue #1621)
# ---------------------------------
# A merge/close keyword preceded IN THE SAME CLAUSE by a conditional
# introducer (`if `, `when `, `once `, `after `, `unless `) is a branch of an
# instruction, not an assertion: "if #1620 has merged by then, resolve against
# its content" says nothing about #1620's live state. `if it` in HEDGE_RE is
# one instance of that rule, not the rule — the referent can be `#<N>` or
# `PR #<N>` just as well. A clause ends at `;`, an em dash, or one of `. , : ! ?`
# followed by whitespace, so "When I checked, #4662 has merged" is still
# reported. A line is suppressed only when EVERY assertive match on it is
# conditional; one unconditional match anywhere on the line still reports it.
# Findings are also deduplicated per (line, referent): a line naming the same
# `#<N>` several times yields one finding, not one per mention.
set -u

HEDGE_RE="should have|may |might |could |assum|expect|presumably|likely|probably|verify|re-check|recheck|check with|confirm with|unverified|by the time|once it|if it|unless |whether |grounded:"

# Assertive merge/land phrasings. Both alternations require a helper verb or a
# preposition adjacent to the keyword, so a bare "merge conflict" or "the
# landing gate" never matches.
MERGED_RE="(^|[^a-z])(has|have|had|already|was|were|is|are|now|just)[ ]+(merged|landed)|(^|[^a-z])(merged|landed)[ ]+(already|at|on|into|in to)"

# Assertive closed phrasings. Restricted to `closed` — "resolved" and "fixed"
# describe the WORK far more often than the issue's GitHub state.
CLOSED_RE="(^|[^a-z])(has|have|had|already|was|were|is|are|now|just)[ ]+(closed)|(^|[^a-z])closed[ ]+(already|as|at|on)"

# Negative-existence assertions about a file's content.
CONTENT_RE="there (is|are) no |does not (contain|include|have|name|mention|exist)|do not (contain|include|have|name|mention|exist)|is absent from|are absent from|nothing in |never (appears|mentions|names)|no such "

# No backslashes anywhere in these patterns on purpose: awk's `-v` assignment
# runs escape processing over the value first, so a `\.` would arrive as a
# plain `.` (matching any character) plus a gawk warning on stderr. `[.]` and
# an unescaped `/` inside a bracket expression say the same thing, safely.
PATH_RE="[A-Za-z0-9_./-]+[.](md|sh|mjs|js|json|ya?ml)"

usage() {
  cat <<'USAGE'
verify-dispatch-claims.sh — re-resolve a dispatch prompt's claims about another
PR's/issue's live state, and refuse the dispatch on a contradiction (#1553).

  --scan   <prompt-file>                  text scan only (no network), exit 0
  --probe  <owner/repo> <number>          live referent resolution, exit 0
  --decide <kind> <probe-result>          pure decision, exit 0
  --repo   <owner/repo> [--self <N>] <prompt-file>
                                          live gate: 0 ok / 1 contradicted /
                                          2 indeterminate / 64 usage

See the header comment in this file for the #1553 background, the hedged-line
and `(grounded: <cmd>)` suppression rules, and the deliberate narrowness.
USAGE
}

scan_prompt() {
  local file="$1" self="${2:-}"
  if [ ! -f "$file" ]; then
    echo "none"
    return
  fi
  awk -v hedge_re="$HEDGE_RE" \
      -v merged_re="$MERGED_RE" \
      -v closed_re="$CLOSED_RE" \
      -v content_re="$CONTENT_RE" \
      -v path_re="$PATH_RE" \
      -v self="$self" '
    function trim_phrase(p) {
      gsub(/[\t]+/, " ", p)
      gsub(/  +/, " ", p)
      # The assertive-phrasing patterns open with `(^|[^a-z])`, so the match
      # carries one leading delimiter (a space, a `*`, a backtick). Drop it.
      sub(/^[^A-Za-z0-9#]+/, "", p)
      sub(/[ ]+$/, "", p)
      if (length(p) > 100) { p = substr(p, 1, 97) "..." }
      return p
    }
    # conditional_prefix(prefix) — 1 when the clause ending at the keyword
    # contains a conditional introducer (#1621). `prefix` is the lowercased
    # text up to and including the match start.
    function conditional_prefix(prefix,    clause) {
      clause = prefix
      gsub(/[.,:!?][ \t]/, "|", clause)
      gsub(/;/, "|", clause)
      gsub(/—/, "|", clause)
      sub(/^.*[|]/, "", clause)
      return (clause ~ /(^|[^a-z])(if|when|once|after|unless)[ ]/)
    }
    # unconditional_match(s, re) — the first match of `re` in `s` that is NOT
    # inside a conditional clause. Sets MSTART/MLEN and returns 1, else 0.
    function unconditional_match(s, re,    rest, off, abs) {
      rest = s
      off = 0
      while (match(rest, re)) {
        abs = off + RSTART
        if (!conditional_prefix(substr(s, 1, abs))) {
          MSTART = abs
          MLEN = RLENGTH
          return 1
        }
        off = off + RSTART + RLENGTH - 1
        rest = substr(s, off + 1)
      }
      return 0
    }
    function emit(kind, ref, phrase) {
      printf "kind=%s line=%d ref=%s phrase=%s\n", kind, NR, ref, trim_phrase(phrase)
      found = 1
    }
    BEGIN { found = 0 }
    {
      line = $0
      gsub(/\r/, "", line)
      # Markdown citation links (`[#1062](https://...)`) and bare URLs are
      # references to a RULE, not claims about live state. Strip both before
      # extracting referents so a cited issue number is never probed.
      stripped = line
      gsub(/\[[^]]*\]\([^)]*\)/, " ", stripped)
      gsub(/https?:\/\/[^ )]*/, " ", stripped)
      lower = tolower(stripped)

      if (lower ~ hedge_re) next

      kind = ""
      if (unconditional_match(lower, merged_re)) { kind = "merged" }
      else if (unconditional_match(lower, closed_re)) { kind = "closed" }
      else if (match(lower, merged_re) || match(lower, closed_re)) {
        # Every assertive match on the line sits in a conditional clause.
        next
      }

      if (kind != "") {
        phrase = substr(stripped, MSTART, MLEN)
        rest = stripped
        split("", seen)
        while (match(rest, /#[0-9]+/)) {
          num = substr(rest, RSTART + 1, RLENGTH - 1)
          rest = substr(rest, RSTART + RLENGTH)
          if (self != "" && num == self) continue
          if (num in seen) continue
          seen[num] = 1
          emit(kind, num, phrase)
        }
        next
      }

      if (match(lower, content_re)) {
        phrase = substr(stripped, RSTART, RLENGTH)
        if (match(stripped, path_re)) {
          emit("content", substr(stripped, RSTART, RLENGTH), phrase)
        }
      }
    }
    END { if (!found) print "none" }
  ' "$file"
}

probe_ref() {
  local repo="$1" num="$2" state
  if ! command -v gh >/dev/null 2>&1; then
    echo "unknown"
    return
  fi
  state="$(gh pr view "$num" --repo "$repo" --json state --jq '.state' 2>/dev/null || true)"
  if [ -n "$state" ]; then
    echo "pr:$state"
    return
  fi
  state="$(gh issue view "$num" --repo "$repo" --json state --jq '.state' 2>/dev/null || true)"
  if [ -n "$state" ]; then
    echo "issue:$state"
    return
  fi
  echo "unknown"
}

decide() {
  local kind="${1:-}" probe="${2:-unknown}"
  case "$kind" in
    merged)
      case "$probe" in
        pr:MERGED)        echo "ok" ;;
        pr:OPEN|pr:CLOSED) echo "contradicted" ;;
        # A merge claim cannot attach to an issue number — nothing to check.
        issue:*)          echo "n/a" ;;
        *)                echo "indeterminate" ;;
      esac
      ;;
    closed)
      case "$probe" in
        pr:MERGED|pr:CLOSED|issue:CLOSED) echo "ok" ;;
        pr:OPEN|issue:OPEN)               echo "contradicted" ;;
        *)                                echo "indeterminate" ;;
      esac
      ;;
    # A content claim's substance is not machine-resolvable; the SHAPE is the
    # finding. See UNGROUNDED in the header.
    content) echo "contradicted" ;;
    *)       echo "indeterminate" ;;
  esac
}

field_of() {
  # field_of <claim-line> <key> — claim lines are `k=v` pairs, and `phrase=`
  # is always last so it may contain spaces.
  local claim="$1" key="$2" rest
  case "$key" in
    phrase) printf '%s' "${claim#*phrase=}" ;;
    *)
      rest="${claim#*"$key"=}"
      printf '%s' "${rest%% *}"
      ;;
  esac
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --scan)
    if [ "$#" -lt 2 ]; then usage >&2; exit 64; fi
    scan_prompt "$2" "${3:-}"
    exit 0
    ;;
  --probe)
    if [ "$#" -lt 3 ]; then usage >&2; exit 64; fi
    probe_ref "$2" "$3"
    exit 0
    ;;
  --decide)
    if [ "$#" -lt 3 ]; then usage >&2; exit 64; fi
    decide "$2" "$3"
    exit 0
    ;;
esac

REPO=""
SELF=""
PROMPT_FILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 || exit 64 ;;
    --self) SELF="${2:-}"; shift 2 || exit 64 ;;
    -*) usage >&2; exit 64 ;;
    *) PROMPT_FILE="$1"; shift ;;
  esac
done

if [ -z "$REPO" ] || [ -z "$PROMPT_FILE" ]; then
  usage >&2
  exit 64
fi

if [ ! -f "$PROMPT_FILE" ]; then
  printf 'INDETERMINATE: prompt file not found: %s\n' "$PROMPT_FILE"
  exit 2
fi

CLAIMS="$(scan_prompt "$PROMPT_FILE" "$SELF")"

if [ "$CLAIMS" = "none" ]; then
  printf 'OK: no checkable state or content claims detected\n'
  exit 0
fi

contradicted=0
indeterminate=0
verified=0

while IFS= read -r claim; do
  [ -n "$claim" ] || continue
  kind="$(field_of "$claim" "kind")"
  lineno="$(field_of "$claim" "line")"
  ref="$(field_of "$claim" "ref")"
  phrase="$(field_of "$claim" "phrase")"

  if [ "$kind" = "content" ]; then
    contradicted=$((contradicted + 1))
    # shellcheck disable=SC2016  # backticks are literal markdown, not substitution
    printf 'UNGROUNDED: line %s asserts the content of `%s` ("%s") without evidence. Run the grep at composition time, then either drop the claim or cite it inline as `(grounded: <command>)`.\n' \
      "$lineno" "$ref" "$phrase"
    continue
  fi

  probe="$(probe_ref "$REPO" "$ref")"
  verdict="$(decide "$kind" "$probe")"

  case "$verdict" in
    ok) verified=$((verified + 1)) ;;
    n/a) : ;;
    contradicted)
      contradicted=$((contradicted + 1))
      case "$probe" in
        issue:*) subcmd="issue" ;;
        *)       subcmd="pr" ;;
      esac
      # shellcheck disable=SC2016  # backticks are literal markdown, not substitution
      printf 'CONTRADICTED: line %s claims #%s %s ("%s") but its live state is %s. Rewrite conditionally per #1062: "#%s should have %s by the time you start; verify with `gh %s view %s --json state,mergedAt` before relying on it." If the line is really a conditional branch ("if #%s has %s, ..."), keep the if/when/once/after/unless introducer in the same clause as the keyword — no comma, colon, or semicolon between them — and it is not reported (#1621).\n' \
        "$lineno" "$ref" "$kind" "$phrase" "$probe" \
        "$ref" "$kind" "$subcmd" "$ref" \
        "$ref" "$kind"
      ;;
    *)
      indeterminate=$((indeterminate + 1))
      printf 'INDETERMINATE: line %s claims #%s %s ("%s") but #%s could not be resolved in %s. Treat as unverified.\n' \
        "$lineno" "$ref" "$kind" "$phrase" "$ref" "$REPO"
      ;;
  esac
done <<EOF
$CLAIMS
EOF

if [ "$contradicted" -gt 0 ]; then
  printf 'REFUSE: %d unverified claim(s) — rewrite before dispatching (issue #1553).\n' "$contradicted"
  exit 1
fi

if [ "$indeterminate" -gt 0 ]; then
  printf 'REFUSE: %d unresolvable claim(s) — fails closed (issue #1553).\n' "$indeterminate"
  exit 2
fi

printf 'OK: %d state claim(s) verified against live GitHub state\n' "$verified"
exit 0
