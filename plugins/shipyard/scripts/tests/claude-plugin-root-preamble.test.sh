#!/usr/bin/env bash
# Test: every bash code block in the /shipyard:do-work orchestrator + worker
# spec tree that references ${CLAUDE_PLUGIN_ROOT} also carries a valid
# preamble as its first non-blank line(s) — either the canonical compound
# fallback-export (or a bare script-invocation block immediately preceded by
# a preamble-only block — the two-block idiom used in a few places, see (3)
# below), OR, for ORCHESTRATOR-PHASE files only (commands/do-work/**), the
# post-relocation literal export (issue #1181, reshaped by #1607 — see below).
#
# Background — issue #354: $CLAUDE_PLUGIN_ROOT expands to the empty string
# inside the Bash-tool subprocess shells the orchestrator uses. The very
# first templated invocation of /shipyard:do-work (setup.md step 0.4's
# `"${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" exists`) therefore
# evaluates as `/scripts/shipyard-config.sh` and exits 127. Every subsequent
# script invocation anywhere in the orchestrator or worker spec tree would
# fail the same way.
#
# The fix is an idempotent preamble at the top of every bash snippet:
#
#   export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
#
# Semantics:
#   - When the harness DOES set $CLAUDE_PLUGIN_ROOT, the `${VAR:-default}`
#     short-circuits and the export is a no-op.
#   - When the harness does NOT set it (the observed steady-state for every
#     Bash-tool call inside this orchestrator), the fallback PROBES two
#     install layouts in order (issue #883 collapsed this from four layers
#     to two — see below):
#       1. repo-local `<repo>/plugins/shipyard` IF it actually carries a
#          `scripts/` dir (the dogfooding case — shipyard's own checkout).
#          Kept unconditionally: #907 is the governing decision on whether
#          this layer survives, and it kept it (added a staleness warning,
#          did not remove the layer);
#       2. else the AUTHORITATIVE installed path from
#          `$HOME/.claude/plugins/installed_plugins.json` (the `installPath`
#          for `shipyard@shipyard`) IF it carries a `scripts/` dir (issue
#          #681). This is the loaded install under `cache/<mp>/<plugin>/
#          <version>/`, and it resolves identically for the maintainer's own
#          installs and for any marketplace consumer — it isn't a special
#          case;
#       3. else the repo-local path anyway (preserves a meaningful path for
#          error messaging when neither layer above resolves).
#
#   Collapsed from four layers to two (issue #883): the preamble used to
#   ALSO glob `$HOME/.claude/plugins/marketplaces/*/plugins/shipyard` as a
#   third layer (hardened against a shadowing `.bak` sibling and a
#   version-mismatched marketplace checkout — issue #681/#417), used only
#   when installed_plugins.json was unreadable or missing the
#   `shipyard@shipyard` entry. installed_plugins.json is populated by the
#   harness's own plugin manager for every install method (verified
#   directly against the maintainer's own install before this collapse
#   landed — see #883's decision comment), so that third layer was pure
#   dead weight in practice. Dropping it saves ~350 bytes per occurrence
#   (~696 -> ~403 bytes) while keeping the one layer that's both
#   authoritative and universal. Helper-script extraction (source a
#   `resolve-plugin-root.sh`) was proposed and explicitly rejected for this
#   same issue: every occurrence runs in a fresh, hermetic subshell, so
#   sourcing a helper first requires re-deriving $CLAUDE_PLUGIN_ROOT to
#   locate it — the circularity this whole preamble exists to avoid.
#
# This test is the regression guard: if anyone adds a new bash block that
# uses $CLAUDE_PLUGIN_ROOT without a valid preamble at its top, the test
# fails. Existing blocks were swept by the issue #354 PR (then shrunk in
# place by issue #883); new ones (or any block whose preamble got moved /
# removed / reverted to the old four-layer form) regress here.
#
# --- Unbraced-expansion convention (issue #1308) ---------------------------
#
# Every INVOCATION site spells the variable unbraced — `$CLAUDE_PLUGIN_ROOT`,
# never `${CLAUDE_PLUGIN_ROOT}`. The braced form is refused outright by the
# harness's worktree-isolation guard once a session is isolated in a worktree
# ("this command is too complex to verify that it stays inside the worktree"),
# and that refusal fires on the BRACES, not on statement count, loop shape,
# block length, or whether the expansion sits in command position — the four
# axes issues #1182 / #1277 / #1289 / #1291 each decomposed in turn without
# stopping the refusals. See setup/00-config-worktree.md step 0.3 for the
# controlled experiment table that isolated it.
#
# Two consequences for this test:
#
#   - `has_ref` below matches the UNBRACED spelling. Matching only the braced
#     form after the #1308 sweep would make every check pass vacuously across
#     zero blocks — an absence-assertion that observed nothing, which is not a
#     pass (see worker-preamble's ci-pitfalls.md). Check (3b) asserts a floor
#     on the observed block count so that failure mode can't recur silently.
#   - Check (8) bans the braced spelling outright, repo-wide across the
#     plugin's markdown. That is the actual convention guard: without it, a
#     re-braced call site would simply drop out of coverage rather than fail.
#
# The one place the braced spelling legitimately survives is the canonical
# preamble itself (`${CLAUDE_PLUGIN_ROOT:-...}`) — `${VAR:-default}` has no
# unbraced spelling in POSIX shell. That is exactly why the preamble is
# PRE-RELOCATION-ONLY and why the literal-export form below exists for everything
# after it. Check (8) matches the braced form with a CLOSING brace only, so
# the `:-` default form is untouched.
#
# --- Post-relocation literal-export form (issue #1181, #1607) -----------------------
#
# The compound preamble above is refused by the harness once the orchestrator
# session is isolated in its own worktree ("this command is too complex to
# verify that it stays inside the worktree") — so it is only valid PRE-
# relocation: do-work/setup/00-config-worktree.md's steps 0.3, 0.4, and the
# pre-EnterWorktree timing-start bracket at the top of step 0.5. Step 0.5
# resolves CLAUDE_PLUGIN_ROOT post-relocation via a decomposed (non-compound)
# sequence of plain commands and stashes the result to
# `<orch-worktree>/.shipyard-plugin-root` — every other ORCHESTRATOR-PHASE
# block (everything under commands/do-work/, recursively — steady-state.md,
# drain.md, cleanup-summary.md, inline-trivial.md, dispatch-rules.md, and the
# rest of setup/) opens with an export of that resolved LITERAL, which the
# orchestrator substitutes for the placeholder:
#
#   export CLAUDE_PLUGIN_ROOT="<plugin-root literal>"
#
# (Issue #1607: until then these blocks read the stash back with
# `CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)` +
# `export CLAUDE_PLUGIN_ROOT`. Current harness builds refuse that — they
# object to exporting a value the command computes — so check (7) now
# asserts the retired form is absent from every orchestrator-phase block.)
#
# WORKER-SIDE files (skills/worker-preamble/**, agents/issue-worker/**) are a
# separate case and are NOT eligible for this literal-export form: a dispatched
# worker runs in its own agent-* worktree with no .shipyard-plugin-root
# stash of its own (it gets the resolved literal via its dispatch prompt
# instead, per issue #965) — the compound block there is the worker's own
# fallback for when that literal is missing, and stays required.
#
# --- File discovery (issue #910) -------------------------------------------
#
# Earlier versions of this test walked a hardcoded FILES array. Since #611
# split setup.md into a thin router + step-cluster sub-files under
# commands/do-work/setup/, setup.md itself carries ZERO ${CLAUDE_PLUGIN_ROOT}
# occurrences (they moved to the sub-files) — the array entry passed
# vacuously and covered nothing. Separately, dispatch-rules.md,
# skills/worker-preamble/SKILL.md (+ its on-demand fragments),
# agents/issue-worker/issue-work.md, and agents/issue-worker/fix-rebase.md
# all grew their own preamble-carrying bash blocks over time and were never
# added to the array either — 41 of 69 preamble occurrences (59%) had zero
# regression coverage at the time #910 was filed.
#
# Rather than append the missing filenames (which just recreates the same
# rot at the next reorg — see #611's own history), FILES below is discovered
# MECHANICALLY: every *.md file under the three directories that make up the
# do-work orchestrator + worker spec tree — commands/do-work/ (recursive,
# so a future setup/ or operate/ sub-file is swept in automatically),
# skills/worker-preamble/ (the skill + all its on-demand fragments), and
# agents/issue-worker/ (every per-mode worker spec) — is a candidate. A
# candidate with zero ${CLAUDE_PLUGIN_ROOT}-referencing bash blocks is a
# no-op (nothing to check), so this glob is safe to keep wide: adding a new
# file to any of these three directories costs nothing until it actually
# grows a bash block using the variable, at which point this test starts
# covering it with no manual edit required.
#
# Scope — explicitly the do-work orchestrator + worker spec tree. NOT
# version.md, eas-watch.md, init.md, or status.md: those are different
# surfaces with different rationales (version.md wants the *installed*
# plugin path, not the repo checkout; eas-watch.md runs in an Expo project
# where the repo's plugins/shipyard doesn't exist; status.md is invoked by
# the user, not templated into orchestrator output; init.md only mentions
# the variable in prose/JSON, never in a bash block).
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/claude-plugin-root-preamble.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$here"
while [[ "$repo_root" != "/" ]]; do
  if [[ -d "$repo_root/.git" || -f "$repo_root/CHANGELOG.md" ]]; then
    break
  fi
  repo_root="$(dirname "$repo_root")"
done

if [[ "$repo_root" == "/" ]]; then
  echo "FAIL: could not locate repo root from $here" >&2
  exit 1
fi

# Directories that make up the do-work orchestrator + worker spec tree.
# Every *.md file under these (recursively) is a discovery candidate.
SCAN_DIRS=(
  "$repo_root/plugins/shipyard/commands/do-work"
  "$repo_root/plugins/shipyard/skills/worker-preamble"
  "$repo_root/plugins/shipyard/agents/issue-worker"
)

FILES=()
while IFS= read -r -d '' f; do
  FILES+=("$f")
done < <(find "${SCAN_DIRS[@]}" -type f -name '*.md' -print0 2>/dev/null | sort -z)

# The canonical preamble line. Anchored against literal text so any
# substitution (e.g. swapping the fallback path) trips this test. The
# preamble now embeds a single-quoted jq filter ('.plugins[...]'), so it
# can no longer live inside a single-quoted assignment — a quoted here-doc
# (<<'EOF') captures it verbatim with no escaping. Command substitution
# strips the trailing newline, so the value is exactly the one-line preamble.
EXPECTED_PREAMBLE=$(cat <<'PREAMBLE_EOF'
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
PREAMBLE_EOF
)

# The post-relocation literal export (issue #1181, reshaped by #1607) — the
# ONLY other valid form, and only for orchestrator-phase files (see
# ORCH_PHASE_DIR below). One line: an export of the placeholder the
# orchestrator substitutes with the root step 0.4 echoed.
EXPECTED_LITERAL_EXPORT='export CLAUDE_PLUGIN_ROOT="<plugin-root literal>"'

# The retired stash-read (#1607): exporting a computed value is refused by
# current harness builds, so no orchestrator-phase bash block may read the
# stash back into CLAUDE_PLUGIN_ROOT. Check (7) asserts its absence.
# shellcheck disable=SC2016  # literal text — must NOT expand $(...)
RETIRED_STASH_READ='CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root'

# Orchestrator-phase scope: everything under commands/do-work/ (recursively).
# Worker-side files (skills/worker-preamble/**, agents/issue-worker/**) are
# NOT in this directory and stay compound-preamble-only.
ORCH_PHASE_DIR="$repo_root/plugins/shipyard/commands/do-work"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() {
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"
  pass=$((pass+1))
}

assert_fail() {
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"
  fail=$((fail+1))
}

echo "claude-plugin-root preamble regression tests (issue #354, discovery per #910)"
echo

# (1) Discovery sanity. A `find` scope regression (wrong repo_root, a
# directory rename that silently drops out of SCAN_DIRS) would make FILES
# empty and every subsequent check "pass" vacuously — exactly the
# false-confidence failure mode #910 was filed to close, just moved one
# layer down. Assert discovery actually found a non-trivial number of files,
# and that a small canary set of well-known phase/skill files — which must
# always exist under this scope — was among them.
if (( ${#FILES[@]} >= 10 )); then
  assert_pass "discovery found ${#FILES[@]} candidate *.md files under SCAN_DIRS"
else
  assert_fail "discovery found ${#FILES[@]} candidate *.md files under SCAN_DIRS (expected >= 10 — SCAN_DIRS or repo_root may be wrong)"
fi

CANARY_FILES=(
  "$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
  "$repo_root/plugins/shipyard/commands/do-work/drain.md"
  "$repo_root/plugins/shipyard/commands/do-work/cleanup-summary.md"
  "$repo_root/plugins/shipyard/commands/do-work/inline-trivial.md"
  "$repo_root/plugins/shipyard/skills/worker-preamble/SKILL.md"
)
for canary in "${CANARY_FILES[@]}"; do
  found=0
  for f in "${FILES[@]}"; do
    [[ "$f" == "$canary" ]] && { found=1; break; }
  done
  if (( found )); then
    assert_pass "discovery includes canary file $canary"
  else
    assert_fail "discovery includes canary file $canary (missing — SCAN_DIRS regressed)"
  fi
done

# (2) The canonical preamble is documented in setup step 0.3, so any
# reader of the spec can find the rationale for the pattern in one place.
# Since #611 split setup.md into a thin router + step-cluster sub-files,
# step 0.3 currently lives in do-work/setup/00-config-worktree.md — but the
# router/fragment pattern is designed to move a step's content to a new
# fragment once its parent crosses the token-budget cap (issue #1453), so
# this scans across every setup/*.md fragment for the content rather than
# hardcoding the one file it happens to live in today (mirrors the fix in
# shipyard-repo-root-preamble.test.sh check (4)).
SETUP_DIR="$repo_root/plugins/shipyard/commands/do-work/setup"
if grep -qFl "### 0.3 \`CLAUDE_PLUGIN_ROOT\` re-export preamble" "$SETUP_DIR"/*.md 2>/dev/null; then
  assert_pass "setup/*.md documents step 0.3 (preamble rationale)"
else
  assert_fail "setup/*.md documents step 0.3 (preamble rationale)"
fi

if grep -qFl "$EXPECTED_PREAMBLE" "$SETUP_DIR"/*.md 2>/dev/null; then
  assert_pass "setup/*.md contains the canonical preamble line"
else
  assert_fail "setup/*.md contains the canonical preamble line"
fi

# (3) Walk every bash code block in every discovered file, IN FILE ORDER.
# For each block that references ${CLAUDE_PLUGIN_ROOT}, the block passes if
# EITHER:
#   (a) its own first non-blank line is the canonical compound preamble
#       (the common, single-block idiom), OR
#   (b) the block is a bare script-invocation block (no preamble of its
#       own) immediately preceded — in the same file, skipping only prose
#       between fences — by a bash block whose ENTIRE content is the
#       canonical preamble line and nothing else (the two-block idiom used
#       by skills/worker-preamble/SKILL.md's step-0 / mid-session-anchoring
#       sections, which document the preamble once and then show two
#       different follow-up commands that reuse it), OR
#   (c) — ORCHESTRATOR-PHASE FILES ONLY (issue #1181, reshaped by #1607) —
#       its own first non-blank line is the post-relocation literal export
#       (`export CLAUDE_PLUGIN_ROOT="<plugin-root literal>"`). Before #1607
#       this was a stash-read two-liner, which current harness builds
#       refuse. NOT a valid form for worker-side files
#       (skills/worker-preamble/**, agents/issue-worker/**) — those keep (a)
#       or (b) only.
#
# Walking is done by an awk one-liner that emits one line per bash block:
# "<block_start_line>|<has_ref 0/1>|<is_preamble_only 0/1>|<contains_preamble 0/1>|<first_non_blank_line>|<second_non_blank_line>"
#
# `contains_preamble` (issue #1378) is new: it's 1 when ANY line in the
# block — not just the first — matches the canonical preamble exactly once
# leading whitespace is stripped. It is what lets scan_file_for_offenses
# below name the NEAREST earlier preamble-bearing block for an offending
# block's diagnostic, rather than only reporting that a valid preamble is
# absent at the point of failure. (`is_preamble_only` still requires the
# preamble to be the block's ENTIRE content — the narrower predicate the
# two-block idiom in (b) actually needs — so the two fields answer different
# questions: "is a preamble anywhere in this block" vs. "is this block
# nothing BUT a preamble".)
walk_blocks() {
  local file="$1"
  awk -v expected="$EXPECTED_PREAMBLE" '
    BEGIN { in_block = 0 }

    # opening bash fence (any indent)
    /^[ \t]*```bash[ \t]*$/ {
      in_block = 1
      block_start = NR
      first_line = ""
      second_line = ""
      first_line_num = 0
      has_ref = 0
      contains_preamble = 0
      nonblank_count = 0
      next
    }

    # closing fence
    /^[ \t]*```[ \t]*$/ {
      if (in_block) {
        stripped = first_line
        sub(/^[ \t]+/, "", stripped)
        is_preamble_only = (nonblank_count == 1 && stripped == expected) ? 1 : 0
        printf "%d|%d|%d|%d|%s|%s\n", block_start, has_ref, is_preamble_only, contains_preamble, first_line, second_line
      }
      in_block = 0
      next
    }

    # inside a block
    in_block {
      # Unbraced spelling only (issue #1308) — `$CLAUDE_PLUGIN_ROOT` followed
      # by a non-identifier character or end-of-line. Deliberately does NOT
      # match `${CLAUDE_PLUGIN_ROOT:-...}` (the char after `$` is `{`), so a
      # preamble-only block still reports has_ref=0 and is recognised as the
      # leading block of the two-block idiom.
      if (/\$CLAUDE_PLUGIN_ROOT([^A-Za-z0-9_]|$)/) {
        has_ref = 1
      }
      line_stripped = $0
      sub(/^[ \t]+/, "", line_stripped)
      if (line_stripped == expected) {
        contains_preamble = 1
      }
      if (/[^ \t]/) {
        nonblank_count++
        if (first_line == "") {
          first_line = $0
          first_line_num = NR
        } else if (second_line == "") {
          second_line = $0
        }
      }
    }
  ' "$file"
}

# build_offending_message (issue #1378) — renders the full multi-line
# diagnostic for one offending block. Pulled out of the scan loop so the
# exact same text-building logic backs both the real repo scan below AND
# the fixture-driven message-content tests in (3d) — a diagnostic that's
# only ever exercised by the real scan can drift or regress silently the
# next time someone "cleans up" the loop it lives in.
#
# $1 file  $2 fence_line  $3 is_orch_phase  $4 block_idx
# $5 last_preamble_idx (-1 if none found yet)  $6 last_preamble_line
# $7 first_line (of the offending block)  $8 trail (space-separated line
#    numbers of blocks since the last preamble-bearing block, oldest first)
build_offending_message() {
  local file="$1" fence_line="$2" is_orch_phase="$3" block_idx="$4"
  local last_preamble_idx="$5" last_preamble_line="$6" first_line="$7" trail="$8"
  local -a lines=()
  if (( last_preamble_idx >= 0 )); then
    if (( block_idx - last_preamble_idx == 1 )); then
      # The nearest preamble is in the IMMEDIATELY preceding block, but that
      # block mixes in other content — so the two-block idiom's "preamble-only"
      # requirement rejects it despite the adjacency being right.
      lines+=("$file: bash block at line $fence_line uses \$CLAUDE_PLUGIN_ROOT — the immediately preceding block (line $last_preamble_line) already contains the preamble, but REJECTED: that block is not preamble-only (other content is mixed in with it), so the two-block idiom does not recognize it")
      lines+=("         fix: make the block at line $last_preamble_line contain ONLY the preamble line, or move the preamble to be this block's own first line")
    else
      local intervening=$(( block_idx - last_preamble_idx - 1 ))
      local trail_str="${trail// /, }"
      lines+=("$file: bash block at line $fence_line uses \$CLAUDE_PLUGIN_ROOT — nearest preamble found at line $last_preamble_line (compound form), REJECTED: not *immediately* preceding; $intervening intervening bash block(s) (line(s) $trail_str) separate it from line $fence_line")
      lines+=("         fix: move the preamble at line $last_preamble_line into this block as its own first line(s), or remove/merge whatever sits between them")
    fi
    if (( is_orch_phase )); then
      lines+=("         note: this file is orchestrator-phase — the post-relocation literal export ($EXPECTED_LITERAL_EXPORT) is also a valid alternative form here (#1607)")
    fi
  else
    lines+=("$file: bash block at line $fence_line uses \$CLAUDE_PLUGIN_ROOT but no preamble was found anywhere earlier in this file")
    lines+=("         expected either: $EXPECTED_PREAMBLE")
    if (( is_orch_phase )); then
      lines+=("                     or: $EXPECTED_LITERAL_EXPORT   (orchestrator-phase files only — see dont.md § \"Never export a computed value\", #1607)")
    fi
    lines+=("         got:             $first_line")
  fi
  printf '%s\n' "${lines[@]}"
}

# scan_file_for_offenses (issue #1378) — walks FILE's blocks in order,
# tracking the nearest preceding preamble-bearing block (by block index, not
# just line number, so "immediately preceding" and "N intervening blocks"
# are both exact) and appending one rendered diagnostic per offending block
# to the global OFFENSE_MSGS array. REF_BLOCK_COUNT is also populated as a
# side effect so the caller can fold it into total_ref_blocks without a
# second pass. Both globals are reset on entry, so this is safe to call
# repeatedly against different files (the real scan loop, or a fixture).
OFFENSE_MSGS=()
REF_BLOCK_COUNT=0
scan_file_for_offenses() {
  local file="$1" is_orch_phase="$2"
  OFFENSE_MSGS=()
  REF_BLOCK_COUNT=0
  local block_idx=0 last_preamble_line=0 last_preamble_idx=-1
  local -a trail=()
  local prev_is_preamble_only=0
  local fence_line has_ref is_preamble_only contains_preamble first_line second_line
  while IFS='|' read -r fence_line has_ref is_preamble_only contains_preamble first_line second_line; do
    block_idx=$((block_idx + 1))
    if (( has_ref )); then
      REF_BLOCK_COUNT=$((REF_BLOCK_COUNT + 1))
      stripped_first="$first_line"
      # strip leading whitespace for comparison (preamble may be indented
      # to match the fence indent, e.g. inside a numbered list item).
      stripped_first="${stripped_first#"${stripped_first%%[![:space:]]*}"}"
      stripped_second="$second_line"
      [[ -n "$stripped_second" ]] && stripped_second="${stripped_second#"${stripped_second%%[![:space:]]*}"}"
      if [[ "$stripped_first" == "$EXPECTED_PREAMBLE" ]]; then
        : # (a) inline compound preamble — pass
      elif (( prev_is_preamble_only )); then
        : # (b) two-block idiom — pass
      elif (( is_orch_phase )) && [[ "$stripped_first" == "$EXPECTED_LITERAL_EXPORT" ]]; then
        : # (c) post-relocation literal export, orchestrator-phase only — pass (#1607)
      else
        local msg
        msg=$(build_offending_message "$file" "$fence_line" "$is_orch_phase" "$block_idx" "$last_preamble_idx" "$last_preamble_line" "$first_line" "${trail[*]:-}")
        OFFENSE_MSGS+=("$msg")
      fi
    fi
    if (( contains_preamble )); then
      last_preamble_line=$fence_line
      last_preamble_idx=$block_idx
      trail=()
    else
      trail+=("$fence_line")
    fi
    prev_is_preamble_only=$is_preamble_only
  done < <(walk_blocks "$file")
}

offending_blocks=0
total_ref_blocks=0
for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || continue
  case "$f" in
    "$ORCH_PHASE_DIR"/*) is_orch_phase=1 ;;
    *)                   is_orch_phase=0 ;;
  esac
  scan_file_for_offenses "$f" "$is_orch_phase"
  total_ref_blocks=$((total_ref_blocks + REF_BLOCK_COUNT))
  if (( ${#OFFENSE_MSGS[@]} > 0 )); then
    for msg in "${OFFENSE_MSGS[@]}"; do
      offending_blocks=$((offending_blocks + 1))
      assert_fail "$(printf '%s' "$msg" | head -n 1)"
      printf '%s\n' "$msg" | tail -n +2
    done
  fi
done

if (( offending_blocks == 0 )); then
  assert_pass "all $total_ref_blocks bash blocks using \$CLAUDE_PLUGIN_ROOT across ${#FILES[@]} scanned files carry a valid preamble"
fi

# (3b) Vacuous-pass guard (issue #1308). Check (3) above is an ABSENCE
# assertion: it only reports offending blocks, so a `has_ref` pattern that
# stops matching — because the spelling convention changed underneath it, as
# it did during the #1308 sweep — turns the whole check into "0 blocks
# examined, 0 offences found, PASS". That is a pass over nothing, not a pass.
# #910 closed the same failure shape one layer up (an empty FILES array);
# this closes it at the block layer. The floor is deliberately well below the
# real count (~180 at the time of writing) so ordinary spec churn never trips
# it — only a matcher that has gone blind.
REF_BLOCK_FLOOR=100
if (( total_ref_blocks >= REF_BLOCK_FLOOR )); then
  assert_pass "block-level discovery observed $total_ref_blocks \$CLAUDE_PLUGIN_ROOT blocks (>= floor $REF_BLOCK_FLOOR)"
else
  assert_fail "block-level discovery observed only $total_ref_blocks \$CLAUDE_PLUGIN_ROOT blocks (expected >= $REF_BLOCK_FLOOR — the has_ref matcher has likely gone blind, making check (3) pass vacuously; see issue #1308)"
fi

# (3c) Convention guard (issue #1308). The BRACED spelling
# `${CLAUDE_PLUGIN_ROOT}` is refused by the harness worktree-isolation guard
# in every isolated session, so no invocation site may use it. Scanned across
# the whole plugin's markdown (not just SCAN_DIRS): the refusal is a property
# of the shell syntax, so it applies identically to /shipyard:my-turn,
# /shipyard:file-issue, the auditor skills, and every other surface that
# templates a helper invocation.
#
# The pattern requires a CLOSING brace, so the canonical preamble's
# `${CLAUDE_PLUGIN_ROOT:-...}` default-expansion is deliberately NOT matched —
# it has no unbraced spelling and is pre-relocation-only by design (#1181).
# Exactly ONE file is exempt: the fragment that documents the ban. It quotes
# the braced spelling in its controlled-experiment table, so a blanket scan
# would flag the documentation of the rule as a violation of it. The exemption
# is a single named path, and its existence is asserted below — a rename or
# deletion must not silently widen the hole into "no file is scanned".

PLUGIN_ROOT_DIR="$repo_root/plugins/shipyard"
# shellcheck disable=SC2016  # literal search text — must NOT expand
braced_hits=$(grep -rlF '${CLAUDE_PLUGIN_ROOT}' "$PLUGIN_ROOT_DIR" --include='*.md' 2>/dev/null \
  | sort)
if [[ -z "$braced_hits" ]]; then
  assert_pass "no braced \${CLAUDE_PLUGIN_ROOT} spelling anywhere in the plugin's markdown (issue #1308)"
else
  assert_fail "braced \${CLAUDE_PLUGIN_ROOT} found — the harness refuses this form in an isolated session; use the unbraced \$CLAUDE_PLUGIN_ROOT (issue #1308)"
  while IFS= read -r hit; do
    printf '         %s\n' "${hit#"$repo_root/"}"
  done <<< "$braced_hits"
fi

# (3d) Message-content fixture tests (issue #1378). Checks (1)-(3c) above
# only assert PRESENCE/ABSENCE of a valid preamble — none of them assert
# what the FAILURE MESSAGE actually says. That's exactly the gap #1378
# reports: three workers in one session read a message that correctly said
# "not preceded by a valid preamble" and each independently "fixed" it by
# adding a second, non-adjacent preamble block, because the message never
# said a preamble already existed 11 lines up — only that one wasn't found
# immediately before. These three fixtures pin the diagnostic's CONTENT so
# that regression can't recur silently the way the original gap did.
#
# Each fixture is a synthetic .md file built from $EXPECTED_PREAMBLE itself
# (never a hand-typed copy) so a future change to the canonical preamble
# text can't silently desync the fixture from what the scanner actually
# looks for.
fixture_dir=$(mktemp -d 2>/dev/null || mktemp -d -t shipyard-1378)
if [[ -n "$fixture_dir" && -d "$fixture_dir" ]]; then

  # Fixture A: the preamble exists earlier in the file, but is separated
  # from the offending block by one intervening (unrelated) bash block and
  # surrounding prose — the exact shape of all three #1378 repros.
  fixture_a="$fixture_dir/non-adjacent.md"
  {
    echo "# Fixture A"
    echo
    echo "Some setup prose."
    echo
    echo '```bash'
    printf '%s\n' "$EXPECTED_PREAMBLE"
    echo '```'
    echo
    echo "Unrelated prose describing an intervening step."
    echo
    echo '```bash'
    echo "git rev-parse --show-toplevel"
    echo '```'
    echo
    echo "More prose before the actual consumer."
    echo
    echo '```bash'
    # shellcheck disable=SC2016  # literal fixture text — must NOT expand
    echo '"$CLAUDE_PLUGIN_ROOT/scripts/worktree-reap.sh" triage-orphan-branches'
    echo '```'
  } > "$fixture_a"
  preamble_line_a=$(grep -n '^```bash$' "$fixture_a" | sed -n '1p' | cut -d: -f1)
  offending_line_a=$(grep -n '^```bash$' "$fixture_a" | sed -n '3p' | cut -d: -f1)

  scan_file_for_offenses "$fixture_a" 0
  if (( ${#OFFENSE_MSGS[@]} == 1 )); then
    msg_a="${OFFENSE_MSGS[0]}"
    if [[ "$msg_a" == *"nearest preamble found at line $preamble_line_a"* \
       && "$msg_a" == *"not *immediately* preceding"* \
       && "$msg_a" == *"1 intervening bash block(s)"* \
       && "$msg_a" == *"line $offending_line_a"* ]]; then
      assert_pass "fixture: non-adjacent preamble — diagnostic names the nearest preamble (line $preamble_line_a), the adjacency rejection reason, and the intervening-block count (issue #1378)"
    else
      assert_fail "fixture: non-adjacent preamble — diagnostic content did not match expectations (issue #1378)"
      printf '         got: %s\n' "$msg_a"
    fi
  else
    assert_fail "fixture: non-adjacent preamble — expected exactly 1 offending block, got ${#OFFENSE_MSGS[@]} (issue #1378)"
  fi

  # Fixture B: no preamble exists anywhere earlier in the file — the
  # diagnostic must say so explicitly rather than pointing at a nearby block
  # that doesn't exist.
  fixture_b="$fixture_dir/no-preamble.md"
  {
    echo "# Fixture B"
    echo
    echo '```bash'
    # shellcheck disable=SC2016  # literal fixture text — must NOT expand
    echo '"$CLAUDE_PLUGIN_ROOT/scripts/worktree-reap.sh" triage-orphan-branches'
    echo '```'
  } > "$fixture_b"
  offending_line_b=$(grep -n '^```bash$' "$fixture_b" | sed -n '1p' | cut -d: -f1)

  scan_file_for_offenses "$fixture_b" 0
  if (( ${#OFFENSE_MSGS[@]} == 1 )); then
    msg_b="${OFFENSE_MSGS[0]}"
    if [[ "$msg_b" == *"no preamble was found anywhere earlier in this file"* \
       && "$msg_b" == *"line $offending_line_b"* ]]; then
      assert_pass "fixture: no preamble anywhere in the file — diagnostic says so explicitly (issue #1378)"
    else
      assert_fail "fixture: no preamble anywhere in the file — diagnostic content did not match expectations (issue #1378)"
      printf '         got: %s\n' "$msg_b"
    fi
  else
    assert_fail "fixture: no preamble anywhere in the file — expected exactly 1 offending block, got ${#OFFENSE_MSGS[@]} (issue #1378)"
  fi

  # Fixture C: the preamble is in the IMMEDIATELY preceding block, but that
  # block mixes in other content — so the two-block idiom's "preamble-only"
  # requirement rejects it despite the adjacency being right. This must
  # produce a DIFFERENT diagnosis than fixture A's non-adjacent case.
  fixture_c="$fixture_dir/adjacent-not-preamble-only.md"
  {
    echo "# Fixture C"
    echo
    echo '```bash'
    printf '%s\n' "$EXPECTED_PREAMBLE"
    echo 'echo "also doing something else in the same block"'
    echo '```'
    echo
    echo '```bash'
    # shellcheck disable=SC2016  # literal fixture text — must NOT expand
    echo '"$CLAUDE_PLUGIN_ROOT/scripts/worktree-reap.sh" triage-orphan-branches'
    echo '```'
  } > "$fixture_c"
  preamble_line_c=$(grep -n '^```bash$' "$fixture_c" | sed -n '1p' | cut -d: -f1)

  scan_file_for_offenses "$fixture_c" 0
  if (( ${#OFFENSE_MSGS[@]} == 1 )); then
    msg_c="${OFFENSE_MSGS[0]}"
    if [[ "$msg_c" == *"the immediately preceding block (line $preamble_line_c)"* \
       && "$msg_c" == *"not preamble-only"* ]]; then
      assert_pass "fixture: adjacent-but-mixed preamble — diagnostic distinguishes this from the non-adjacent case (issue #1378)"
    else
      assert_fail "fixture: adjacent-but-mixed preamble — diagnostic content did not match expectations (issue #1378)"
      printf '         got: %s\n' "$msg_c"
    fi
  else
    assert_fail "fixture: adjacent-but-mixed preamble — expected exactly 1 offending block, got ${#OFFENSE_MSGS[@]} (issue #1378)"
  fi

  rm -rf "$fixture_dir"
else
  assert_fail "could not create sandbox for message-content fixture tests (issue #1378)"
fi

# (4) Sanity check — the preamble itself must actually work. Run it in a
# clean shell and confirm $CLAUDE_PLUGIN_ROOT resolves to a path that
# contains the helper scripts. This is the runtime contract the docs
# encode; if the path computation regresses (e.g. someone changes
# "plugins/shipyard" to "plugin/shipyard"), this catches it.
sanity_dir=$(env -i HOME="$HOME" PATH="$PATH" bash -c "
  cd '$repo_root'
  $EXPECTED_PREAMBLE
  echo \"\$CLAUDE_PLUGIN_ROOT\"
")
if [[ -d "$sanity_dir" && -x "$sanity_dir/scripts/shipyard-config.sh" ]]; then
  assert_pass "preamble resolves to a directory containing scripts/shipyard-config.sh"
else
  assert_fail "preamble resolves to a directory containing scripts/shipyard-config.sh (got '$sanity_dir')"
fi

# (5) Consumer-install sanity check (issue #417, re-verified after the
# #883 layer collapse). Simulate a marketplace-installed shipyard running
# against a repo with NO repo-local plugins/shipyard: the probe must fall
# through repo-local (layer 1 fails) to installed_plugins.json's
# installPath (layer 2) — the one layer that replaces the old layers 2+3.
#
# Build a throwaway sandbox: a fake $HOME with an installed_plugins.json
# pointing at a cache install, and a fake consumer git repo with no
# plugins/shipyard dir. Then run the preamble with cd into the consumer
# repo and confirm it resolves to the cache install path.
sandbox=$(mktemp -d 2>/dev/null || mktemp -d -t shipyard-417)
if [[ -n "$sandbox" && -d "$sandbox" ]]; then
  fake_home="$sandbox/home"
  cache_install="$fake_home/.claude/plugins/cache/shipyard/shipyard/9.9.9"
  mkdir -p "$cache_install/scripts"
  mkdir -p "$fake_home/.claude/plugins"
  printf '{"plugins":{"shipyard@shipyard":[{"installPath":"%s"}]}}\n' \
    "$cache_install" > "$fake_home/.claude/plugins/installed_plugins.json"
  consumer_repo="$sandbox/consumer"
  mkdir -p "$consumer_repo"
  ( cd "$consumer_repo" && git init -q 2>/dev/null )

  consumer_dir=$(env -i HOME="$fake_home" PATH="$PATH" bash -c "
    cd '$consumer_repo'
    $EXPECTED_PREAMBLE
    echo \"\$CLAUDE_PLUGIN_ROOT\"
  ")
  if [[ "$consumer_dir" == "$cache_install" ]]; then
    assert_pass "preamble falls through to installed_plugins.json's installPath when repo has no plugins/shipyard (issue #417)"
  else
    assert_fail "preamble falls through to installed_plugins.json's installPath when repo has no plugins/shipyard (got '$consumer_dir', expected '$cache_install')"
  fi
  rm -rf "$sandbox"
else
  assert_fail "could not create sandbox for consumer-install sanity check"
fi

# (6) Malformed/partial installed_plugins.json entry falls through to the
# repo-local-anyway default rather than being trusted blindly (issue
# #883). Before the layer collapse, a malformed layer-2 entry (installPath
# set but no scripts/ dir — e.g. a stale or half-written record) fell
# through to layer 3 (the marketplace glob). That layer no longer exists,
# so the guard's fall-through destination changed to the final
# repo-local-anyway default — this proves the `-d "$I/scripts"` guard is
# still load-bearing post-collapse, not silently dead code.
sandbox=$(mktemp -d 2>/dev/null || mktemp -d -t shipyard-883)
if [[ -n "$sandbox" && -d "$sandbox" ]]; then
  fake_home="$sandbox/home"
  broken_install="$fake_home/.claude/plugins/cache/shipyard/shipyard/0.0.0"
  # installPath is recorded but the directory has NO scripts/ subdir —
  # simulates a stale/half-written installed_plugins.json entry.
  mkdir -p "$broken_install"
  mkdir -p "$fake_home/.claude/plugins"
  printf '{"plugins":{"shipyard@shipyard":[{"installPath":"%s"}]}}\n' \
    "$broken_install" > "$fake_home/.claude/plugins/installed_plugins.json"
  consumer_repo="$sandbox/consumer"
  mkdir -p "$consumer_repo"
  ( cd "$consumer_repo" && git init -q 2>/dev/null )
  # Canonicalize via `git rev-parse --show-toplevel` itself (the same call
  # the preamble makes) rather than the raw mktemp path — on macOS $TMPDIR
  # is a symlink (/var/... -> /private/var/...), so comparing against the
  # raw path would spuriously fail even though the preamble resolved
  # correctly.
  consumer_repo_canonical=$(cd "$consumer_repo" && git rev-parse --show-toplevel)

  resolved=$(env -i HOME="$fake_home" PATH="$PATH" bash -c "
    cd '$consumer_repo'
    $EXPECTED_PREAMBLE
    echo \"\$CLAUDE_PLUGIN_ROOT\"
  ")
  expected_fallback="$consumer_repo_canonical/plugins/shipyard"
  if [[ "$resolved" == "$expected_fallback" ]]; then
    assert_pass "a malformed installed_plugins.json entry (no scripts/ dir) falls through to the repo-local-anyway default (issue #883)"
  else
    assert_fail "a malformed installed_plugins.json entry should fall through to repo-local-anyway (got '$resolved', expected '$expected_fallback')"
  fi
  rm -rf "$sandbox"
else
  assert_fail "could not create sandbox for malformed-installed_plugins.json sanity check (#883)"
fi

# (7) The retired stash-read (#1607) must not survive in any
# orchestrator-phase bash block. `CLAUDE_PLUGIN_ROOT=$(cat
# .shipyard-plugin-root ...)` + `export CLAUDE_PLUGIN_ROOT` was documented
# as measured-safe post-relocation and is refused by current harness builds
# ("exporting a value this command computes"). Prose may still NAME the
# retired form (dont.md does, to explain why it's gone) — only fenced bash
# blocks are scanned.
retired_hits=""
for f in "${FILES[@]}"; do
  [[ "$f" == "$ORCH_PHASE_DIR"/* ]] || continue
  hits=$(awk -v needle="$RETIRED_STASH_READ" '
    /^[ \t]*```bash[ \t]*$/ { inb = 1; next }
    /^[ \t]*```[ \t]*$/ { inb = 0; next }
    inb && index($0, needle) { print FILENAME ":" NR }
  ' "$f")
  [[ -n "$hits" ]] && retired_hits+="$hits"$'\n'
done
if [[ -z "$retired_hits" ]]; then
  assert_pass "no orchestrator-phase bash block reads .shipyard-plugin-root into an exported CLAUDE_PLUGIN_ROOT (issue #1607)"
else
  assert_fail "orchestrator-phase bash block(s) still use the refused stash-read export (issue #1607) — replace with $EXPECTED_LITERAL_EXPORT:"
  printf '%s' "$retired_hits" | sed 's/^/         /'
fi

# Non-vacuity: the literal export must actually be the form in use, so a
# future rename of the placeholder can't make check (3)(c) silently match
# nothing while (7) passes on an empty corpus.
literal_count=0
for f in "${FILES[@]}"; do
  [[ "$f" == "$ORCH_PHASE_DIR"/* ]] || continue
  n=$(grep -cF -- "$EXPECTED_LITERAL_EXPORT" "$f" || true)
  literal_count=$((literal_count + n))
done
if (( literal_count >= 50 )); then
  assert_pass "orchestrator-phase files carry the literal export in $literal_count place(s) (issue #1607)"
else
  assert_fail "orchestrator-phase files carry the literal export in only $literal_count place(s) — expected >= 50 (issue #1607)"
fi

# The retired two-liner, placed in a synthetic orchestrator-phase file, must
# now be reported as an offense by check (3) — it is no longer form (c).
retired_fixture_dir=$(mktemp -d 2>/dev/null || mktemp -d -t shipyard-1607)
if [[ -n "$retired_fixture_dir" && -d "$retired_fixture_dir" ]]; then
  retired_fixture="$retired_fixture_dir/retired.md"
  {
    echo '```bash'
    echo "$RETIRED_STASH_READ 2>/dev/null)"
    echo 'export CLAUDE_PLUGIN_ROOT'
    # shellcheck disable=SC2016  # literal fixture text
    echo '"$CLAUDE_PLUGIN_ROOT/scripts/foo.sh" --help'
    echo '```'
  } > "$retired_fixture"
  scan_file_for_offenses "$retired_fixture" 1
  if (( ${#OFFENSE_MSGS[@]} == 1 )); then
    assert_pass "check (3) rejects the retired stash-read two-liner in an orchestrator-phase block (issue #1607)"
  else
    assert_fail "check (3) should reject the retired stash-read two-liner (got ${#OFFENSE_MSGS[@]} offense(s), expected 1)"
  fi
  rm -rf "$retired_fixture_dir"
else
  assert_fail "could not create sandbox for retired-stash-read fixture (#1607)"
fi

# (9) The compound preamble is PRE-RELOCATION ONLY (issue #1625). #1607 and
# #1619 retired the refused "export a computed value" stash-reads, but the
# compound `${CLAUDE_PLUGIN_ROOT:-$(...)}` one-liner is itself an export of a
# computed value, and step 0.3's own callout says it is refused post-isolation.
# Check (3)(a) still accepts it in any file, so eight post-relocation blocks
# kept it unnoticed. This check fails on any fenced bash block under
# commands/do-work/** that carries the compound form, outside an explicit
# allowlist of files whose compound blocks genuinely run before step 0.5's
# EnterWorktree:
#
#   setup/00-config-worktree.md       steps 0.3 / 0.4 / the 0.5 timing bracket
#   setup/00i-staleness-gate.md       the pre-relocation staleness gate
#   setup/01c-label-recovery-refine.md step 3c, whose normative call site is
#                                      00e-pre-relocation-sweeps.md step 5
#
# Anything else under commands/do-work/ opens with the literal export instead.
# The needle is the loose `CLAUDE_PLUGIN_ROOT:-$(` so a reworded variant of
# the compound form is caught too, not only the canonical text.
# shellcheck disable=SC2016  # literal search text — must NOT expand $(...)
COMPOUND_NEEDLE='CLAUDE_PLUGIN_ROOT:-$('
PRE_RELOCATION_ALLOWLIST=(
  "$ORCH_PHASE_DIR/setup/00-config-worktree.md"
  "$ORCH_PHASE_DIR/setup/00i-staleness-gate.md"
  "$ORCH_PHASE_DIR/setup/01c-label-recovery-refine.md"
)

# find_post_relocation_compound FILE — prints FILE:LINE for each fenced bash
# block line carrying the compound needle. Prose mentions are ignored.
find_post_relocation_compound() {
  awk -v needle="$COMPOUND_NEEDLE" '
    /^[ \t]*```bash[ \t]*$/ { inb = 1; next }
    /^[ \t]*```[ \t]*$/ { inb = 0; next }
    inb && index($0, needle) { print FILENAME ":" NR }
  ' "$1"
}

is_pre_relocation_allowlisted() {
  local f="$1" a
  for a in "${PRE_RELOCATION_ALLOWLIST[@]}"; do
    [[ "$f" == "$a" ]] && return 0
  done
  return 1
}

# Every allowlisted file must exist and still carry the compound form: a
# rename would otherwise leave a dead entry, and an entry whose file no
# longer needs the exemption is a hole a future post-relocation block could
# slip through.
for a in "${PRE_RELOCATION_ALLOWLIST[@]}"; do
  if [[ -f "$a" && -n "$(find_post_relocation_compound "$a")" ]]; then
    assert_pass "pre-relocation allowlist entry ${a#"$repo_root/"} exists and still carries the compound preamble (issue #1625)"
  else
    assert_fail "pre-relocation allowlist entry ${a#"$repo_root/"} is missing or no longer carries the compound preamble — drop it from PRE_RELOCATION_ALLOWLIST (issue #1625)"
  fi
done

compound_hits=""
for f in "${FILES[@]}"; do
  [[ "$f" == "$ORCH_PHASE_DIR"/* ]] || continue
  is_pre_relocation_allowlisted "$f" && continue
  hits=$(find_post_relocation_compound "$f")
  [[ -n "$hits" ]] && compound_hits+="$hits"$'\n'
done
if [[ -z "$compound_hits" ]]; then
  assert_pass "no post-relocation orchestrator-phase bash block uses the compound CLAUDE_PLUGIN_ROOT preamble (issue #1625)"
else
  assert_fail "post-relocation orchestrator-phase bash block(s) still use the compound preamble, which is refused post-isolation (issue #1625) — replace with $EXPECTED_LITERAL_EXPORT, or add the file to PRE_RELOCATION_ALLOWLIST only if the block genuinely runs before step 0.5:"
  printf '%s' "$compound_hits" | sed "s|^$repo_root/|         |"
fi

# Fixture: prove the detector actually fires. A synthetic block carrying the
# canonical compound preamble must be reported; the same text in prose, and
# a literal-export block, must not.
compound_fixture_dir=$(mktemp -d 2>/dev/null || mktemp -d -t shipyard-1625)
if [[ -n "$compound_fixture_dir" && -d "$compound_fixture_dir" ]]; then
  compound_fixture="$compound_fixture_dir/post-relocation.md"
  {
    echo "Prose that names the form: $EXPECTED_PREAMBLE"
    echo
    echo '```bash'
    echo "$EXPECTED_LITERAL_EXPORT"
    # shellcheck disable=SC2016  # literal fixture text
    echo '"$CLAUDE_PLUGIN_ROOT/scripts/foo.sh" --help'
    echo '```'
    echo
    echo '```bash'
    echo "  $EXPECTED_PREAMBLE"
    # shellcheck disable=SC2016  # literal fixture text
    echo '  "$CLAUDE_PLUGIN_ROOT/scripts/foo.sh" --help'
    echo '```'
  } > "$compound_fixture"
  fixture_hits=$(find_post_relocation_compound "$compound_fixture")
  expected_hit="$compound_fixture:9"
  if [[ "$fixture_hits" == "$expected_hit" ]]; then
    assert_pass "fixture: the post-relocation detector reports exactly the indented compound block, not the prose mention or the literal-export block (issue #1625)"
  else
    assert_fail "fixture: the post-relocation detector reported '$fixture_hits', expected '$expected_hit' (issue #1625)"
  fi
  rm -rf "$compound_fixture_dir"
else
  assert_fail "could not create sandbox for post-relocation compound-preamble fixture (#1625)"
fi

echo
printf 'passed: %d, failed: %d\n' "$pass" "$fail"
if (( fail > 0 )); then
  exit 1
fi
exit 0
