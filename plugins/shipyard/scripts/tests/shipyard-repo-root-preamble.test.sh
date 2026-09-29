#!/usr/bin/env bash
# Test: every post-relocation orchestrator bash block that invokes
# shipyard-config.sh (directly, or via a helper like resolve-dispatch-model.sh
# that shells out to it) also re-derives and re-exports the SHIPYARD_REPO_ROOT
# pin from the step-0.56 `.shipyard-primary-root` stash — issue #1059 (phase
# 1: the pin itself + the one known-affected consumer), #1064 (phase 2: sweep
# every remaining call site).
#
# Background
# ----------
# `shipyard-config.sh`'s `repo_root()` resolves via `git rev-parse
# --show-toplevel` from cwd unless `SHIPYARD_REPO_ROOT` overrides it. Setup
# step 0.5 relocates the orchestrator's session into a fresh worktree checked
# out from origin/<default-branch> — which, by construction, cannot contain
# gitignored files like `.shipyard/config.local.json`. Step 0.56
# (setup/00-config-worktree.md) stashes the PRIMARY checkout's root at
# `<orch-worktree>/.shipyard-primary-root` and documents that every
# SUBSEQUENT config read this session should re-derive `SHIPYARD_REPO_ROOT`
# from that stash — the same way every `${CLAUDE_PLUGIN_ROOT}`-consuming
# block already re-derives that variable (each Bash-tool call is a fresh,
# hermetic subshell — nothing set in call N survives into call N+1).
#
# #1059's own PR (#1063) wired the pin at its origin (step 0.56) plus the one
# call site its repro named (the flake-registry enforcement in
# setup/04-backlog-divert.md's step 5.8) and deliberately left every other
# post-relocation `shipyard-config.sh get` / `resolve-dispatch-model.sh` call
# site un-swept as a follow-up. #1064 is that follow-up. This suite is the
# durable regression guard so a NEW call site added later can't silently
# reintroduce the same gap: a repo with `.shipyard/config.local.json` set
# would have that layer silently drop out of the merged config for whichever
# call site forgot the pin, with no error — exactly the class of bug #1059
# reported (this session's own orchestrator run hit it directly, on
# resolve-dispatch-model.sh, while dogfooding #1064 itself).
#
# What this test checks
# ----------------------
# For each scanned file, walk every ```bash code block (any indent, matching
# the plugin-root preamble test's own fence walker). A block "counts" if it
# invokes `${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh"` or
# `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-dispatch-model.sh"` literally. A
# counting block passes if it ALSO pins SHIPYARD_REPO_ROOT to the
# `<primary-root literal>` placeholder somewhere in the same block — either
# the canonical `export SHIPYARD_REPO_ROOT="<primary-root literal>"` or a
# per-command `SHIPYARD_REPO_ROOT=<primary-root literal>` env prefix.
#
# Issue #1619: until then the pin was re-derived from the step-0.56 stash
# (`SHIPYARD_REPO_ROOT=$(cat .shipyard-primary-root 2>/dev/null || pwd)` +
# `export SHIPYARD_REPO_ROOT`) and this check accepted any block carrying the
# `.shipyard-primary-root` marker. Current harness builds refuse exporting a
# computed value post-relocation (same trigger #1607 retired for
# CLAUDE_PLUGIN_ROOT), so the stash read no longer counts as a pin, and
# check (5) asserts the retired form — and the sibling
# `SHIPYARD_ORCHESTRATOR_PID=$(...)` + export — is gone from every
# orchestrator-phase bash block.
#
# Block-local variable check (issue #1276). A bareword-variable prefix
# (`$VAR/.shipyard-primary-root` or `${VAR}/.shipyard-primary-root`) is only
# a genuine re-derivation if VAR was itself assigned EARLIER IN THE SAME
# block — every Bash-tool call is its own hermetic subshell (#354), so a
# variable assigned in an earlier call (a different fenced block, or plain
# prose describing one) reads back empty here, with no error. #1276's repro
# was exactly this shape: `setup/04-backlog-divert.md`'s step-5.8 flake-enforce
# block read `$ORCH_WT/.shipyard-primary-root`, but `$ORCH_WT` is assigned
# only inside `00-config-worktree.md`'s raw-`git worktree add` fallback block
# — a different file, read many calls later — so it was always empty, the
# stash read silently failed, and the pin fell through to
# `git rev-parse --show-toplevel` (the orchestrator worktree, exactly what
# the pin exists to avoid). The substring-only check above would have passed
# that block outright; this second pass is what actually catches it. A
# `$(git rev-parse --show-toplevel)/.shipyard-primary-root` command
# substitution, or a bare relative `.shipyard-primary-root` with no prefix,
# is always valid regardless of block-local assignment — neither is a
# bareword variable reference.
#
# --- File discovery (issue #1105) -------------------------------------------
#
# This suite originally walked a hardcoded FILES array (six files named by
# #1064's own sweep). #1105 converted it to the same MECHANICAL discovery
# `claude-plugin-root-preamble.test.sh` already uses for the analogous
# ${CLAUDE_PLUGIN_ROOT} preamble, after the hardcoded array was caught
# missing a real, live call site: `setup/01b-backlog-overview.md`'s step-2
# `triage.investigate_dispatch` read called `shipyard-config.sh` post-
# relocation with no SHIPYARD_REPO_ROOT pin, and was never added to the
# array (#1064's sweep predates that file growing the call — it isn't in
# the six files #1064 named). #1105 fixed that specific gap and switched
# discovery so a NEW call site in a NEW file can't reintroduce it silently —
# this is the exact rot `claude-plugin-root-preamble.test.sh`'s own #910
# history describes (59% of real occurrences uncovered before its glob
# conversion), just found here one file at a time instead of by count.
#
# Candidates: every *.md file under commands/do-work/ (recursively, so a
# future setup/ or operate/ sub-file is swept in automatically) MINUS
# setup/00-config-worktree.md and setup/01c-label-recovery-refine.md, both
# excluded explicitly rather than scanned-and-ignored — see the Scope
# paragraph below for why a scan would false-positive on each. A candidate
# with zero call-bearing bash blocks is a no-op (nothing to check), so this
# glob is safe to keep wide.
#
# Scope — explicitly NOT setup/00-config-worktree.md. That file's step 0.4
# `shipyard-config.sh` reads run BEFORE step 0.5's relocation (against the
# PRIMARY checkout directly, where SHIPYARD_REPO_ROOT is a no-op — the cwd
# IS already the primary checkout) and step 0.56 is where the pin itself is
# DEFINED, not consumed — sweeping that file would produce false positives
# against reads that are correct exactly as written.
#
# Scope — also explicitly NOT setup/01c-label-recovery-refine.md ([#1202](https://github.com/mattsears18/shipyard/issues/1202)).
# Steps 3b and 3c's canonical implementation moved into this file's own
# sections and now runs pre-relocation, at step 0.45 — before step 0.5's
# `EnterWorktree`, for the identical reason 00-config-worktree.md's step 0.4
# is excluded above. Every `shipyard-config.sh` call site in this file (the
# `worktree_reap.warn_threshold` / `worktree_reap.max_per_session` /
# `auto_merge.method` reads) lives inside the 3b/3c pre-relocation bash
# blocks, so sweeping the file would produce the same class of false
# positive.
#
# Also explicitly NOT any agents/issue-worker/*.md file (out of SCAN_DIRS
# entirely — the glob only walks commands/do-work/). Workers run in their
# OWN isolated worktree, resolve their OWN config against their own cwd, and
# step 0.56 documents "Scope: orchestrator session only — never propagate
# into a dispatched worker." A worker-side shipyard-config.sh call correctly
# has no SHIPYARD_REPO_ROOT pin at all.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/shipyard-repo-root-preamble.test.sh

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

DO_WORK_DIR="$repo_root/plugins/shipyard/commands/do-work"

# Mechanical discovery (issue #1105, converting the #354/#910 pattern
# `claude-plugin-root-preamble.test.sh` already uses for the analogous
# ${CLAUDE_PLUGIN_ROOT} preamble): every *.md file under commands/do-work/,
# recursively, MINUS the pre-relocation files below (excluded explicitly —
# see the Scope notes above for why a scan would false-positive on each, not
# just find nothing). A new commands/do-work/ file is covered automatically
# the moment it grows a real call site — no hand-maintained array entry
# needed.
EXCLUDE_FILES=(
  "$DO_WORK_DIR/setup/00-config-worktree.md"
  "$DO_WORK_DIR/setup/01c-label-recovery-refine.md"
)
is_excluded() {
  local candidate="$1" ex
  for ex in "${EXCLUDE_FILES[@]}"; do
    [[ "$candidate" == "$ex" ]] && return 0
  done
  return 1
}
FILES=()
while IFS= read -r -d '' f; do
  is_excluded "$f" && continue
  FILES+=("$f")
done < <(find "$DO_WORK_DIR" -type f -name '*.md' -print0 2>/dev/null | sort -z)

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

echo "SHIPYARD_REPO_ROOT pin regression tests (issue #1059/#1064, discovery per #1105)"
echo

# (1) Discovery sanity. A `find` scope regression (wrong repo_root, a
# directory rename that silently drops commands/do-work/ out of scope) would
# make FILES empty and every subsequent check "pass" vacuously — the exact
# false-confidence failure mode #910 was filed to close for the sibling
# ${CLAUDE_PLUGIN_ROOT} test, now closed here too. Assert discovery found a
# non-trivial number of files, and that a small canary set of well-known
# files — including the file #1105 found this array had been missing —
# was among them.
if (( ${#FILES[@]} >= 20 )); then
  assert_pass "discovery found ${#FILES[@]} candidate *.md files under commands/do-work/ (minus setup/00-config-worktree.md, setup/01c-label-recovery-refine.md)"
else
  assert_fail "discovery found ${#FILES[@]} candidate *.md files under commands/do-work/ (expected >= 20 — DO_WORK_DIR or repo_root may be wrong)"
fi

CANARY_FILES=(
  "$DO_WORK_DIR/dispatch-rules.md"
  "$DO_WORK_DIR/drain.md"
  "$DO_WORK_DIR/steady-state.md"
  "$DO_WORK_DIR/inline-trivial.md"
  "$DO_WORK_DIR/setup/00b-parallelization-cache.md"
  "$DO_WORK_DIR/setup/04-backlog-divert.md"
  "$DO_WORK_DIR/setup/04d-investigate-routing.md"
  "$DO_WORK_DIR/setup/01b-backlog-overview.md"
)
for canary in "${CANARY_FILES[@]}"; do
  found=0
  for f in "${FILES[@]}"; do
    [[ "$f" == "$canary" ]] && { found=1; break; }
  done
  if (( found )); then
    assert_pass "discovery includes canary file ${canary#"$repo_root"/}"
  else
    assert_fail "discovery includes canary file ${canary#"$repo_root"/} (missing — DO_WORK_DIR or exclude list may have regressed)"
  fi
done

# (1b) Every excluded file must still exist and still be excluded — a rename
# of either would silently stop excluding anything (EXCLUDE_FILES just
# wouldn't match), re-introducing the false-positive scan the Scope notes
# above document.
for ex in "${EXCLUDE_FILES[@]}"; do
  rel="${ex#"$repo_root"/}"
  if [[ -f "$ex" ]]; then
    assert_pass "$rel (the excluded pre-relocation file) still exists at the expected path"
  else
    assert_fail "$rel (the excluded pre-relocation file) still exists at the expected path (renamed? EXCLUDE_FILES needs updating)"
  fi
  excluded_ok=1
  for f in "${FILES[@]}"; do
    [[ "$f" == "$ex" ]] && excluded_ok=0
  done
  if (( excluded_ok )); then
    assert_pass "$rel is excluded from the scanned FILES set"
  else
    assert_fail "$rel is excluded from the scanned FILES set (exclude filter regressed)"
  fi
done

# (2) Walk every bash code block in every scanned file, IN FILE ORDER. A
# block that invokes shipyard-config.sh or resolve-dispatch-model.sh must
# also pin SHIPYARD_REPO_ROOT to the <primary-root literal> somewhere in the
# same block (#1619) — AND, if a .shipyard-primary-root read appears via a
# bareword variable prefix
# (`$VAR/.shipyard-primary-root` / `${VAR}/.shipyard-primary-root`), that
# variable must itself be assigned earlier in the SAME block (issue #1276 —
# see the header comment above for why: a variable assigned in a different
# Bash-tool call, or never assigned at all, reads back empty with no error).
walk_blocks() {
  local file="$1"
  awk '
    BEGIN { in_block = 0 }

    /^[ \t]*```bash[ \t]*$/ {
      in_block = 1
      block_start = NR
      has_call = 0
      has_pin = 0
      bad_var = ""
      delete assigned
      next
    }

    /^[ \t]*```[ \t]*$/ {
      if (in_block) {
        printf "%d|%d|%d|%s\n", block_start, has_call, has_pin, bad_var
      }
      in_block = 0
      next
    }

    in_block {
      line = $0
      # Unbraced spelling (issue #1308 — the braced form is refused outright
      # by the harness worktree-isolation guard, so no call site uses it any
      # more). Matching only the braced form here made this whole suite pass
      # over ZERO call-bearing blocks; the discovery floor below is what
      # caught that, and it must keep catching it.
      if (line ~ /\$CLAUDE_PLUGIN_ROOT\/scripts\/shipyard-config\.sh"/ ||
          line ~ /\$CLAUDE_PLUGIN_ROOT\/scripts\/resolve-dispatch-model\.sh"/) {
        has_call = 1
      }
      # The pin is the substituted literal (issue #1619) — never the retired
      # stash read, which current harness builds refuse to export.
      if (line ~ /SHIPYARD_REPO_ROOT="?<primary-root literal>/) {
        has_pin = 1
      }

      # Bareword-variable-prefixed pin reference: $VAR/.shipyard-primary-root
      # or ${VAR}/.shipyard-primary-root. A $(...) command substitution
      # (e.g. $(git rev-parse --show-toplevel)/.shipyard-primary-root) never
      # matches either pattern, so it is never flagged here.
      matched_var = ""
      if (match(line, /\$\{[A-Za-z_][A-Za-z0-9_]*\}\/\.shipyard-primary-root/)) {
        seg = substr(line, RSTART, RLENGTH)
        sub(/^\$\{/, "", seg)
        sub(/\}\/\.shipyard-primary-root$/, "", seg)
        matched_var = seg
      } else if (match(line, /\$[A-Za-z_][A-Za-z0-9_]*\/\.shipyard-primary-root/)) {
        seg = substr(line, RSTART, RLENGTH)
        sub(/^\$/, "", seg)
        sub(/\/\.shipyard-primary-root$/, "", seg)
        matched_var = seg
      }
      if (matched_var != "" && !(matched_var in assigned) && bad_var == "") {
        bad_var = matched_var
      }

      # Track simple `VAR=...` assignments (leading whitespace / `export `
      # stripped) so a LATER line in this same block can reference them.
      tmp = line
      sub(/^[ \t]+/, "", tmp)
      sub(/^export[ \t]+/, "", tmp)
      if (match(tmp, /^[A-Za-z_][A-Za-z0-9_]*=/)) {
        assigned[substr(tmp, 1, RLENGTH - 1)] = 1
      }
    }
  ' "$file"
}

# scan_repo_root_file (issue #1378) — walks FILE's blocks in order via
# walk_blocks, tracking the nearest EARLIER block (anywhere in the file)
# that carries the .shipyard-primary-root marker, and appends one rendered
# diagnostic per offending call-block to the global OFFENSE_MSGS array.
# CALL_BLOCK_COUNT is populated as a side effect. Both globals reset on
# entry, so this is safe to call repeatedly against different files (the
# real scan loop below, or a fixture in (2b)).
#
# Unlike the sibling claude-plugin-root-preamble.test.sh, there is no
# adjacency or two-block-idiom concept here at all — this suite's own rule
# (see the header comment) is that EVERY call-bearing block must
# independently re-derive the pin, because each Bash-tool call is its own
# hermetic subshell. So a nearby re-derivation in a DIFFERENT block never
# satisfies the check, no matter how close it is — but a worker who doesn't
# know that (and has seen the sibling test's two-block idiom) can plausibly
# assume it does, exactly the confusion #1378 reports for the sibling file.
# Naming the nearest re-derivation AND spelling out why it doesn't count is
# the fix here, mirroring #1378's "nearest preamble found" treatment.
OFFENSE_MSGS=()
CALL_BLOCK_COUNT=0
scan_repo_root_file() {
  local file="$1"
  OFFENSE_MSGS=()
  CALL_BLOCK_COUNT=0
  local last_pin_line=0
  local fence_line has_call has_pin bad_var
  while IFS='|' read -r fence_line has_call has_pin bad_var; do
    if (( has_call )); then
      CALL_BLOCK_COUNT=$((CALL_BLOCK_COUNT + 1))
      if [[ -n "$bad_var" ]]; then
        OFFENSE_MSGS+=("${file#"$repo_root"/}: bash block at line $fence_line reads \"\$${bad_var}/.shipyard-primary-root\" but \$${bad_var} is never assigned earlier in the same block — every Bash-tool call is its own hermetic subshell (#354), so this always reads empty and silently falls through (issue #1276)")
      elif (( has_pin )); then
        : # pass
      else
        local msg
        if (( last_pin_line > 0 )); then
          msg="${file#"$repo_root"/}: bash block at line $fence_line calls shipyard-config.sh/resolve-dispatch-model.sh but does not itself pin SHIPYARD_REPO_ROOT (expected: export SHIPYARD_REPO_ROOT=\"<primary-root literal>\" — #1619)
         nearest re-derivation in this file: line $last_pin_line — REJECTED: it is a DIFFERENT bash block; every Bash-tool call is its own hermetic subshell (#354), so this block must re-derive the pin itself (no two-block idiom exception here, unlike the sibling \$CLAUDE_PLUGIN_ROOT preamble test) (issue #1059/#1064)"
        else
          msg="${file#"$repo_root"/}: bash block at line $fence_line calls shipyard-config.sh/resolve-dispatch-model.sh but never pins SHIPYARD_REPO_ROOT (expected: export SHIPYARD_REPO_ROOT=\"<primary-root literal>\" — #1619) — no re-derivation found anywhere earlier in this file either (issue #1059/#1064)"
        fi
        OFFENSE_MSGS+=("$msg")
      fi
    fi
    if (( has_pin )); then
      last_pin_line=$fence_line
    fi
  done < <(walk_blocks "$file")
}

offending_blocks=0
total_call_blocks=0
for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || continue
  scan_repo_root_file "$f"
  total_call_blocks=$((total_call_blocks + CALL_BLOCK_COUNT))
  if (( ${#OFFENSE_MSGS[@]} > 0 )); then
    for msg in "${OFFENSE_MSGS[@]}"; do
      offending_blocks=$((offending_blocks + 1))
      assert_fail "$(printf '%s' "$msg" | head -n 1)"
      printf '%s\n' "$msg" | tail -n +2
    done
  fi
done

# (2a) Message-content fixture tests (issue #1378, mirroring the sibling
# claude-plugin-root-preamble.test.sh's (3d)). Fixture X proves the
# nearest-re-derivation-elsewhere case names the other block and states
# explicitly why it doesn't count; fixture Y proves the true-absence case
# doesn't falsely point at a nonexistent nearby block.
fixture_dir=$(mktemp -d 2>/dev/null || mktemp -d -t shipyard-1378-repo-root)
if [[ -n "$fixture_dir" && -d "$fixture_dir" ]]; then

  # Fixture X: a SEPARATE block re-derives the pin, but the call-bearing
  # block does not do so itself — must be reported as a different-block
  # rejection, not a bare "missing" message.
  fixture_x="$fixture_dir/different-block.md"
  {
    echo "# Fixture X"
    echo
    echo '```bash'
    # shellcheck disable=SC2016  # literal fixture text — must NOT expand
    echo 'export SHIPYARD_REPO_ROOT="<primary-root literal>"'
    echo '```'
    echo
    echo "Some prose in between."
    echo
    echo '```bash'
    # shellcheck disable=SC2016  # literal fixture text — must NOT expand
    echo '"$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get foo.bar'
    echo '```'
  } > "$fixture_x"
  pin_line_x=$(grep -n '^```bash$' "$fixture_x" | sed -n '1p' | cut -d: -f1)
  call_line_x=$(grep -n '^```bash$' "$fixture_x" | sed -n '2p' | cut -d: -f1)

  scan_repo_root_file "$fixture_x"
  if (( ${#OFFENSE_MSGS[@]} == 1 )); then
    msg_x="${OFFENSE_MSGS[0]}"
    if [[ "$msg_x" == *"nearest re-derivation in this file: line $pin_line_x"* \
       && "$msg_x" == *"REJECTED: it is a DIFFERENT bash block"* \
       && "$msg_x" == *"line $call_line_x"* ]]; then
      assert_pass "fixture: pin re-derived in a different block — diagnostic names the nearest re-derivation (line $pin_line_x) and states why it doesn't count (issue #1378)"
    else
      assert_fail "fixture: pin re-derived in a different block — diagnostic content did not match expectations (issue #1378)"
      printf '         got: %s\n' "$msg_x"
    fi
  else
    assert_fail "fixture: pin re-derived in a different block — expected exactly 1 offending block, got ${#OFFENSE_MSGS[@]} (issue #1378)"
  fi

  # Fixture Y: no re-derivation exists anywhere in the file.
  fixture_y="$fixture_dir/no-pin-anywhere.md"
  {
    echo "# Fixture Y"
    echo
    echo '```bash'
    # shellcheck disable=SC2016  # literal fixture text — must NOT expand
    echo '"$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get foo.bar'
    echo '```'
  } > "$fixture_y"
  call_line_y=$(grep -n '^```bash$' "$fixture_y" | sed -n '1p' | cut -d: -f1)

  scan_repo_root_file "$fixture_y"
  if (( ${#OFFENSE_MSGS[@]} == 1 )); then
    msg_y="${OFFENSE_MSGS[0]}"
    if [[ "$msg_y" == *"no re-derivation found anywhere earlier in this file either"* \
       && "$msg_y" == *"line $call_line_y"* ]]; then
      assert_pass "fixture: no re-derivation anywhere in the file — diagnostic says so explicitly (issue #1378)"
    else
      assert_fail "fixture: no re-derivation anywhere in the file — diagnostic content did not match expectations (issue #1378)"
      printf '         got: %s\n' "$msg_y"
    fi
  else
    assert_fail "fixture: no re-derivation anywhere in the file — expected exactly 1 offending block, got ${#OFFENSE_MSGS[@]} (issue #1378)"
  fi

  rm -rf "$fixture_dir"
else
  assert_fail "could not create sandbox for message-content fixture tests (issue #1378)"
fi

if (( offending_blocks == 0 )); then
  assert_pass "all $total_call_blocks bash blocks calling shipyard-config.sh/resolve-dispatch-model.sh across ${#FILES[@]} scanned files re-derive the SHIPYARD_REPO_ROOT pin"
fi

# (3) Sanity check that this suite actually found something to check — a
# scope regression (wrong FILES paths, a rename) would make total_call_blocks
# 0 and every check above "pass" vacuously, the same false-confidence trap
# issue #910 called out for the plugin-root preamble test.
if (( total_call_blocks >= 10 )); then
  assert_pass "discovery found $total_call_blocks call-bearing bash blocks (expected >= 10 — sweep covers a non-trivial surface)"
else
  assert_fail "discovery found $total_call_blocks call-bearing bash blocks (expected >= 10 — FILES list or repo_root may be wrong)"
fi

# (4) The step-0.56 origin itself must still document the stash file this
# whole pin depends on — a rename there would silently break every
# consumer's `cat ".../.shipyard-primary-root"` re-derivation with no error.
# Scan across setup/*.md to find which file documents step 0.56, since the
# split (issue #1431) moved it to 00k-repo-root-pin.md.
found_origin=false
for origin_file in "$DO_WORK_DIR"/setup/*.md; do
  if [[ -f "$origin_file" ]] && grep -q '### 0.56' "$origin_file" && grep -qF '.shipyard-primary-root' "$origin_file"; then
    found_origin=true
    origin_name=$(basename "$origin_file")
    break
  fi
done
if $found_origin; then
  assert_pass "setup/$origin_name still documents the .shipyard-primary-root stash (step 0.56 origin)"
else
  assert_fail "setup/*.md must document the .shipyard-primary-root stash (step 0.56 origin) — cannot find it in any setup file"
fi

# (5) Issue #1619 — the retired computed-value exports must not survive in
# any orchestrator-phase bash block. `SHIPYARD_REPO_ROOT=$(cat
# .shipyard-primary-root ...)` + `export SHIPYARD_REPO_ROOT` and
# `SHIPYARD_ORCHESTRATOR_PID=$(... detect-orchestrator-pid)` + export are
# both refused post-relocation ("exporting a value this command computes"),
# the same trigger #1607 retired for CLAUDE_PLUGIN_ROOT. Prose may still
# NAME the retired forms (00k-repo-root-pin.md and dont.md do, to explain
# why they're gone) — only fenced bash blocks are scanned. Scans every
# commands/do-work/ file, including the two pre-relocation exclusions above:
# neither has a reason to carry these forms either.
retired_scan() {
  awk '
    /^[ \t]*```bash[ \t]*$/ { inb = 1; next }
    /^[ \t]*```[ \t]*$/ { inb = 0; next }
    inb && ($0 ~ /(^|[ \t;])(export[ \t]+)?(SHIPYARD_REPO_ROOT|SHIPYARD_ORCHESTRATOR_PID)="?\$\(/ ||
             $0 ~ /^[ \t]*export[ \t]+(SHIPYARD_REPO_ROOT|SHIPYARD_ORCHESTRATOR_PID)[ \t]*$/) {
      print FILENAME ":" NR
    }
  ' "$@"
}

ALL_DO_WORK=()
while IFS= read -r -d '' f; do
  ALL_DO_WORK+=("$f")
done < <(find "$DO_WORK_DIR" -type f -name '*.md' -print0 2>/dev/null | sort -z)

retired_hits=$(retired_scan "${ALL_DO_WORK[@]}")
if [[ -z "$retired_hits" ]]; then
  assert_pass "no orchestrator-phase bash block exports a computed SHIPYARD_REPO_ROOT / SHIPYARD_ORCHESTRATOR_PID (issue #1619)"
else
  assert_fail "orchestrator-phase bash block(s) still export a computed SHIPYARD_REPO_ROOT / SHIPYARD_ORCHESTRATOR_PID (issue #1619) — replace with export SHIPYARD_REPO_ROOT=\"<primary-root literal>\" / export SHIPYARD_ORCHESTRATOR_PID=\"<orchestrator-pid literal>\":"
  printf '%s\n' "$retired_hits" | sed "s|^$repo_root/|         |"
fi

# Non-vacuity: the literal export must actually be the form in use, so a
# future rename of the placeholder can't leave check (2) matching nothing.
literal_count=0
for f in "${ALL_DO_WORK[@]}"; do
  n=$(grep -cF -- 'export SHIPYARD_REPO_ROOT="<primary-root literal>"' "$f" || true)
  literal_count=$((literal_count + n))
done
if (( literal_count >= 25 )); then
  assert_pass "orchestrator-phase files carry the SHIPYARD_REPO_ROOT literal export in $literal_count place(s) (issue #1619)"
else
  assert_fail "orchestrator-phase files carry the SHIPYARD_REPO_ROOT literal export in only $literal_count place(s) — expected >= 25 (issue #1619)"
fi

# The scan must actually detect each retired shape (fixture), and must not
# flag the literal forms that replaced them.
retired_fixture_dir=$(mktemp -d 2>/dev/null || mktemp -d -t shipyard-1619)
if [[ -n "$retired_fixture_dir" && -d "$retired_fixture_dir" ]]; then
  retired_fixture="$retired_fixture_dir/retired.md"
  {
    echo '```bash'
    # shellcheck disable=SC2016  # literal fixture text — must NOT expand
    echo 'SHIPYARD_REPO_ROOT=$(cat .shipyard-primary-root 2>/dev/null || pwd)'
    echo 'export SHIPYARD_REPO_ROOT'
    # shellcheck disable=SC2016  # literal fixture text — must NOT expand
    echo '  export SHIPYARD_ORCHESTRATOR_PID=$("$CLAUDE_PLUGIN_ROOT/scripts/session-identity.sh" detect-orchestrator-pid)'
    echo 'export SHIPYARD_REPO_ROOT="<primary-root literal>"'
    echo 'export SHIPYARD_ORCHESTRATOR_PID="<orchestrator-pid literal>"'
    echo '```'
  } > "$retired_fixture"
  fixture_hits=$(retired_scan "$retired_fixture" | wc -l | tr -d ' ')
  if [[ "$fixture_hits" == "3" ]]; then
    assert_pass "retired-form scan flags the stash read, its bare export, and the computed PID export, and passes the literal forms (issue #1619)"
  else
    assert_fail "retired-form scan should flag exactly 3 fixture lines, flagged $fixture_hits (issue #1619)"
  fi
  rm -rf "$retired_fixture_dir"
else
  assert_fail "could not create sandbox for retired-form fixture (issue #1619)"
fi

echo
printf 'passed: %d, failed: %d\n' "$pass" "$fail"
if (( fail > 0 )); then
  exit 1
fi
exit 0
