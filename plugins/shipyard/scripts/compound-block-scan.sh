#!/usr/bin/env bash
# compound-block-scan.sh — flag post-relocation ```bash fenced blocks that
# contain a compound shell shape the harness's worktree-isolation guard is
# known to refuse: "this command is too complex to verify that it stays
# inside the worktree; break it into plain, separate commands."
#
# Background (issue #1277): #1181 established that the guard refuses
# compound shapes post-relocation and decomposed ONE call site (the
# `CLAUDE_PLUGIN_ROOT` preamble at setup step 0.3) into plain sequential
# commands, with an explicit "PRE-RELOCATION ONLY" callout. That fix was
# scoped to the preamble alone — every other post-relocation multi-statement
# block in the orchestrator spec is still templated the same refused way,
# and each orchestrator has to improvise its own split by hand, with no
# guarantee the improvisation preserves the block's semantics.
#
# What actually gets refused (per #1277's corroborated repro set) is NOT
# "more than one line in a fenced block" — plain sequential statements
# (`VAR=$(cmd)` / `export VAR` / `echo ...`) are exercised constantly
# throughout this spec with no reported refusal. What gets refused is a
# SINGLE shell construct whose effect the guard can't cheaply verify stays
# inside the worktree:
#
#   - a `for` / `while` loop wrapping `gh` / `git` calls
#   - a shell pipe (`|`, not `||`) spanning two distinct tool invocations
#     (`printf ... | some-script`, `git show ... | jq ...`)
#
# A THIRD shape was added by issue #1471, which ran a fresh one-variable-at-
# a-time experiment against a live isolated worktree after four earlier
# sweeps (#1308 / #1311 / #1314 / #1352) each fixed a different axis and all
# four still left two mandatory setup blocks refused:
#
#   - an UNQUOTED command substitution with a literal path suffix glued on:
#     `VAR=$(git rev-parse --show-toplevel)/plugins/shipyard` is REFUSED,
#     while `VAR="$(git rev-parse --show-toplevel)/plugins/shipyard"` RUNS.
#     Quoting is the only difference; it holds across both export forms and
#     both line renderings.
#
# #1471's headline finding is deliberately not attempted here. #1471 stated
# it as "the guard refuses a block that REFERENCES a shell variable whose
# value it cannot statically resolve, most reliably one assigned from a
# NETWORK command substitution" -- issue #1474 then measured the boundary
# #1471 left unestablished, and BOTH halves of that statement are wrong:
#
#   - There is no local-vs-network split. `X=$(pwd)`, `X=$(date)`,
#     `X=$(cat <file-in-worktree>)`, `X=$(git rev-parse --show-toplevel)`,
#     `X=$(gh api ...)` and `X=$(curl ...)` all behave IDENTICALLY. The guard
#     does not resolve command-substitution values at all.
#   - It is not about variable references either. `echo "$(pwd)"` is refused
#     as a single statement with no variable in sight.
#
# The measured predicate is: a command is refused when it contains a WORD
# whose ENTIRE content is a single unresolvable expansion (`"$VAR"` or
# `"$(cmd)"`). Any adjacent literal text in the same word rescues it --
# `"$VAR/foo"`, `"prefix-$VAR"`, `"value=$VAR"` all RUN. Position is
# irrelevant (script path, flag value, positional arg, or inside a
# `[ -z "$VAR" ]` test all refuse alike).
#
# #1474 nonetheless decided AGAINST building this into a scanner, and that
# decision is deliberate rather than pending: a prototype of the exact
# measured rule produced 152 findings across this scanner's own six curated
# files, overwhelmingly on pre-relocation blocks (where the guard is inactive)
# and on illustrative pseudo-code never pasted into a single Bash call.
# Distinguishing those requires knowing, per fenced block, whether it runs
# post-relocation AND whether it is executed verbatim -- neither is expressed
# anywhere in the markdown. See do-work-RATIONALE.md's "The #1474
# resolvability-boundary measurement" for the full observation table and
# "The #1474 scanner decision: build nothing" for the five-point reasoning.
# Do not re-propose this scanner without re-running the experiment first.
#
# The spec-side fix is to give every expansion a literal suffix, or to
# substitute the literal outright, which sidesteps the boundary entirely.
#
# A FOURTH shape was added by issue #1561:
#
#   - a `session-state.sh update --set` whose jq expression assigns a
#     NON-EMPTY JSON object literal (`--set '.in_flight = {"slot-1": {...}}'`,
#     `--set ".x = {verdict: ...}"`). The guard refuses it as "too complex to
#     verify", which silently stops the durable session record updating. The
#     fix is `session-state.sh set-slot` / `release-slot` for `.in_flight`,
#     per-field path assignments (`.x.verdict = ...`) elsewhere, or
#     `update --set-file <path>` with the expression written by the Write
#     tool. An EMPTY literal (`.in_flight = {}`) is not flagged. Unlike the
#     other three checks this one reads the RAW block (the literal lives
#     inside the quoted --set value, which strip_quotes() removes).
#
# This scanner flags exactly those four shapes inside ```bash fenced blocks,
# in the spirit of `fence-balance-scan.sh` / `conflict-marker-scan.sh`: a
# cheap, deliberately narrow structural check, not a full shell parser.
#
# Scope (deliberately conservative, issue #1277). Unlike the fence-balance
# and conflict-marker scanners, this one does NOT sweep every tracked file
# by default — the corpus mixes pre-relocation and post-relocation content
# within single files (e.g. `setup/00-config-worktree.md`), and a blind
# repo-wide sweep would false-positive on pre-relocation blocks that
# legitimately keep the compound preamble shape. Instead it walks an
# explicit FILES list (below) of files that are either entirely
# post-relocation, or files this scanner has been deliberately verified
# clean of the false-positive risk. Extend FILES as more of the corpus gets
# swept and verified — same evolutionary path
# `shipyard-repo-root-preamble.test.sh` took (#1064 hardcoded array →
# #1105 mechanical discovery). A hardcoded, honestly-incomplete list beats
# a blanket sweep that either misses pre-relocation exclusions or drowns in
# false positives from jq-internal pipes.
#
# False-positive guards:
#   - Pipe detection strips single- and double-quoted spans from the block
#     BEFORE looking for a bare `|` — a `--jq '[.foo | .bar]'` filter's
#     internal pipe is quoted and never flagged. Quote-stripping runs over
#     the whole block (not line-by-line) because this corpus's `--jq '...'`
#     filters routinely span multiple physical lines before the closing
#     quote.
#   - `||` is never flagged as a pipe — only a single unpaired `|`.
#   - A `case ... in word|word) ... ;; esac` pattern's `|` alternation
#     operator is unquoted and would otherwise false-positive; lines that
#     look like a case-pattern arm (`^[[:space:]]*[A-Za-z0-9_]+(\|[A-Za-z0-9_]+)*\)`)
#     are excluded from the pipe check.
#   - An explicit `<!-- compound-block-scan: allow -->` line immediately
#     before the opening fence skips that block entirely — for the rare
#     case a block is intentionally showing the refused shape as a
#     documented bad example (e.g. inside this scanner's own regression
#     doc, or a "here's what NOT to write" callout).
#
# Usage:
#   bash plugins/shipyard/scripts/compound-block-scan.sh            # scan the built-in FILES list
#   bash plugins/shipyard/scripts/compound-block-scan.sh <path>...  # scan explicit files instead
#
# Exit status: 0 = no compound shapes found, 1 = at least one finding
# (prints file:line + shape + snippet), 2 = usage / environment error.

set -u

usage() {
  cat >&2 <<'EOF'
usage: compound-block-scan.sh [path ...]
  With no args, scans the built-in FILES list (see script header for scope
  rationale). With paths, scans exactly the given files instead.
  --help itself always exits 0, distinct from the usage/environment-error
  exit 2 (#1550).
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "compound-block-scan: not inside a git work tree" >&2
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel)"

# The curated, entirely-post-relocation-or-verified-clean file list. See the
# Scope note in the header for why this isn't a blanket repo sweep yet.
#
# dispatch-rules.md / drain.md / inline-trivial.md / steady-state.md added
# by issue #1289 (the follow-up to #1277/#1288) — an informational sweep at
# #1277's own fix time found roughly a dozen more compound-shape instances
# across these four files beyond setup/04-backlog-divert.md; #1289 verified
# and swept 17 of the 18 flagged locations clean. steady-state.md's single
# remaining block (the ~420-line A.0.5 crash-recovery reap) was deliberately
# exempted via an inline `<!-- compound-block-scan: allow -->` marker rather
# than left off this list entirely, tracked as issue #1291 — #1291 has since
# extracted that block to scripts/crash-recovery-reap.sh and removed the
# marker, so steady-state.md is now clean on its own merits like the other
# three files, with no exemption left in place.
#
# d-tail-merge-sweeps.md added by issue #1479, which split steady-state.md's
# D-tail section out verbatim to get back under the 245760-byte phase-file
# cap. Its blocks were already scanned (and clean) as part of steady-state.md
# before the move — listing the fragment keeps that coverage rather than
# silently losing it to the relocation.
#
# setup/00-config-worktree.md added by issue #1471. This is the file the
# Scope note above names as the archetypal mixed pre/post-relocation case,
# and it is admitted here on exactly the terms that note sets out: its two
# genuinely PRE-relocation blocks (step 0.4's opt-in check, and step 0.5's
# last-resort raw `git worktree add` fallback, both of which run from the
# user's primary checkout before isolation exists) carry explicit
# `<!-- compound-block-scan: allow -->` markers, and every remaining block
# in the file is post-relocation and verified clean. Admitting the file with
# two marked exemptions is strictly better than leaving it unscanned: #1471
# found step 0.5's post-relocation stash read-back refused on live `main`
# with nothing in CI able to see it, because the whole file was off the list.
#
# do-work.md / session-state-file.md / environmental-pause.md added by issue
# #1561: they carry the documented `session-state.sh update` hot-path call
# shapes the object-literal-in-set check guards, and were verified clean of
# the other three shapes when admitted.
FILES=(
  "$repo_root/plugins/shipyard/commands/do-work/setup/00-config-worktree.md"
  "$repo_root/plugins/shipyard/commands/do-work/setup/04-backlog-divert.md"
  "$repo_root/plugins/shipyard/commands/do-work/dispatch-rules.md"
  "$repo_root/plugins/shipyard/commands/do-work/drain.md"
  "$repo_root/plugins/shipyard/commands/do-work/inline-trivial.md"
  "$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
  "$repo_root/plugins/shipyard/commands/do-work/d-tail-merge-sweeps.md"
  "$repo_root/plugins/shipyard/commands/do-work.md"
  "$repo_root/plugins/shipyard/commands/do-work/session-state-file.md"
  "$repo_root/plugins/shipyard/commands/do-work/environmental-pause.md"
)

if [[ $# -gt 0 ]]; then
  candidates=("$@")
else
  candidates=("${FILES[@]}")
fi

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "compound-block-scan: no files to scan" >&2
  exit 0
fi

# _scan_file <path> — prints findings (if any) to stdout, one per line:
#   <path>:<fence-start-line>: <shape> — <one-line context>
# Returns 0 if clean, 1 if it found something.
_scan_file() {
  local file="$1"
  awk -v FILE="$file" '
    function is_case_arm_line(line,    stripped) {
      # Heuristic: a case-pattern arm looks like word-bar-word-bar-word then
      # a close paren (optionally indented), possibly using glob-class
      # syntax such as star-bang-bracket-zero-dash-nine-bracket-star. Such a
      # line legitimately carries an unquoted pipe character as the
      # pattern-alternation operator, not a shell pipe. A quote-stripped
      # empty alternative (an empty single-quoted string as the first
      # pattern arm) can leave the line starting with a bare pipe once the
      # empty string is stripped away — the character class below allows
      # that too, rather than requiring a leading word character.
      return (line ~ /^[[:space:]]*[]A-Za-z0-9_*!.,[-]*([|][]A-Za-z0-9_*!.,[-]*)*[)]/)
    }

    function is_case_construct_line(line) {
      # This corpus also writes a whole case statement compressed onto ONE
      # source line — `case "$X" in pattern) action ;; esac` — rather than
      # the pattern-arm-per-line style is_case_arm_line() targets. On such a
      # line the case-arm pattern is preceded by `case ... in` and followed
      # by `... esac`, so the is_case_arm_line start-anchored check never
      # matches even though the unquoted pipe is still a pattern-alternation
      # operator, not a shell pipe. Recognize the whole-line form directly:
      # a line that opens a case statement (`case <expr> in`) or closes one
      # (contains `esac` as a standalone word) is exempt from the pipe
      # check in its entirety.
      return (line ~ /(^|[^A-Za-z0-9_])case[[:space:]].*[[:space:]]in([[:space:]]|$)/ ||
              line ~ /(^|[^A-Za-z0-9_])esac([^A-Za-z0-9_]|$)/)
    }

    # strip_quotes(s) — remove single- and double-quoted spans AND `#`
    # comment spans from s, replacing each with nothing. Walks char-by-char;
    # handles \" escaping inside double quotes (bash single quotes have no
    # escape mechanism). Comments matter here: this corpus writes ordinary
    # English prose in bash `#` comments (contractions like "it is" / "the
    # repo is" / "main is"), and real bash treats a `#` comment as
    # quote-agnostic —
    # apostrophes inside it never open/close a shell string. Without an
    # explicit comment skip, an odd number of apostrophes in one comment
    # line flips in_s and silently swallows everything up to the NEXT
    # apostrophe anywhere later in the block (including real code on a
    # subsequent line) into the "quoted, ergo stripped" bucket — exactly the
    # false-negative this function exists to avoid producing.
    function strip_quotes(s,    i, c, n, out, in_s, in_d, in_c, prev) {
      out = ""; in_s = 0; in_d = 0; in_c = 0; prev = ""
      n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (in_c) {
          if (c == "\n") { in_c = 0; out = out c }
          prev = c
          continue
        }
        if (in_s) {
          if (c == SQ) { in_s = 0 }
          prev = c
          continue
        }
        if (in_d) {
          if (c == DQ && prev != "\\") { in_d = 0 }
          prev = c
          continue
        }
        if (c == "#") { in_c = 1; prev = c; continue }
        if (c == SQ) { in_s = 1; prev = c; continue }
        if (c == DQ) { in_d = 1; prev = c; continue }
        out = out c
        prev = c
      }
      return out
    }

    BEGIN {
      SQ = sprintf("%c", 39)
      DQ = sprintf("%c", 34)
      in_block = 0
      pending_allow = 0
      found_any = 0
    }

    /^[[:space:]]*<!--[[:space:]]*compound-block-scan:[[:space:]]*allow[[:space:]]*-->[[:space:]]*$/ {
      pending_allow = 1
      next
    }

    /^[[:space:]]*```bash[[:space:]]*$/ {
      in_block = 1
      block_start = NR
      block_text = ""
      raw_first_line = ""
      allow_this = pending_allow
      pending_allow = 0
      next
    }

    /^[[:space:]]*```[[:space:]]*$/ {
      if (in_block) {
        in_block = 0
        if (!allow_this) {
          stripped = strip_quotes(block_text)

          # --- Loop check: for/while keyword + gh/git call in same block ---
          if ((stripped ~ /(^|[^A-Za-z0-9_])for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]]/ ||
               stripped ~ /(^|[^A-Za-z0-9_])while[[:space:]]*\[/ ||
               stripped ~ /(^|[^A-Za-z0-9_])while[[:space:]]+[A-Za-z]/) &&
              (stripped ~ /(^|[^A-Za-z0-9_])gh[[:space:]]/ || stripped ~ /(^|[^A-Za-z0-9_])git[[:space:]]/)) {
            printf "%s:%d: for/while-loop-wraps-gh-or-git — block starting here contains a for/while keyword and a gh/git invocation in the same fenced block\n", FILE, block_start
            found_any = 1
          }

          # --- Pipe check: bare `|` (not `||`, not a case-arm) outside quotes ---
          n = split(stripped, lines, "\n")
          for (li = 1; li <= n; li++) {
            ln = lines[li]
            if (is_case_arm_line(ln) || is_case_construct_line(ln)) continue
            # Replace every `||` with a placeholder so it cannot register as
            # a bare `|`, then look for a remaining `|`.
            tmp = ln
            gsub(/\|\|/, "\x01\x01", tmp)
            if (tmp ~ /\|/) {
              printf "%s:%d: unquoted-pipe — block starting here pipes across a shell command boundary outside any case arm\n", FILE, block_start
              found_any = 1
            }
          }

          # --- Unquoted command substitution with a glued path suffix ---
          # Isolated by issue #1471s controlled experiment: an UNQUOTED
          # command substitution immediately followed by a literal path
          # suffix is refused, while the identical line with the whole word
          # quoted runs. Verified across both the combined `export VAR=...`
          # and the split `VAR=...` plus `export VAR` forms, and across
          # single-line and multi-line rendering, with quoting as the only
          # toggled variable:
          #
          #   CLAUDE_PLUGIN_ROOT=$(git rev-parse --show-toplevel)/plugins/x    REFUSED
          #   CLAUDE_PLUGIN_ROOT="$(git rev-parse --show-toplevel)/plugins/x"  RUNS
          #
          # This shape is NOT caught by command-substitution-scan.sh: that
          # scanner treats a substitution sitting immediately after an `=`
          # as sanctioned assignment-RHS, which this one is. It is also not
          # a compound shape, so neither the loop nor the pipe check above
          # sees it — hence a third shape here rather than a fourth scanner.
          #
          # strip_quotes() has already removed every quoted span, so any
          # `$(...)` surviving into `stripped` is unquoted by construction
          # and the quoted (legal) spelling can never match. The `[^()]`
          # inner class keeps arithmetic expansion `$((expr))` from
          # matching, mirroring the same carve-out in command-substitution-scan.sh.
          # --- Object literal inside an `update --set` value (issue #1561) ---
          # Line-by-line over the RAW block: find a `--set` flag (not
          # `--set-file`) and look, in the text after it, for an assignment
          # (`=`, `+=`, `|=`) or `+` whose right-hand side opens a non-empty
          # object -- `{` followed by anything but `}` on the same line,
          # or `{` ending the line (a multi-line literal). A shell `${VAR}`
          # never matches: its `{` is preceded by `$`, not `=` / `+`.
          rn = split(block_text, rlines, "\n")
          for (ri = 1; ri <= rn; ri++) {
            rl = rlines[ri]
            if (match(rl, /--set[[:space:]]/)) {
              rest = substr(rl, RSTART + RLENGTH)
              if (rest ~ /[=+][[:space:]]*[{]([[:space:]]*$|[[:space:]]*[^}[:space:]])/) {
                printf "%s:%d: object-literal-in-set — block starting here passes a JSON object literal in a session-state.sh --set value; use set-slot/release-slot, per-field path assignments, or --set-file (issue #1561)\n", FILE, block_start
                found_any = 1
                break
              }
            }
          }

          if (stripped ~ /\$\([^()]*\)\//) {
            printf "%s:%d: unquoted-substitution-path-suffix — block starting here glues a literal path suffix onto an UNQUOTED command substitution; quote the whole word (issue #1471)\n", FILE, block_start
            found_any = 1
          }
        }
        next
      }
    }

    in_block {
      block_text = block_text $0 "\n"
      next
    }

    END { exit (found_any ? 1 : 0) }
  ' "$file"
}

found=0
for f in "${candidates[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "compound-block-scan: no such file: $f" >&2
    exit 2
  fi
  if ! _scan_file "$f"; then
    found=1
  fi
done

if [[ "$found" -eq 1 ]]; then
  echo >&2
  echo "compound-block-scan: compound shell shape(s) found in post-relocation fenced bash blocks (issue #1277)." >&2
  echo "These are the shapes the worktree-isolation guard is known to refuse post-relocation:" >&2
  echo "  \"this command is too complex to verify that it stays inside the worktree;" >&2
  echo "   break it into plain, separate commands.\"" >&2
  echo "Decompose the flagged block into plain sequential commands, or extract it behind" >&2
  echo "a script (see plugins/shipyard/commands/do-work/dont.md's post-relocation compound-block" >&2
  echo "rule for both options and when to pick each)." >&2
  exit 1
fi

echo "compound-block-scan: all scanned file(s) are free of the known-refused compound shapes."
exit 0
