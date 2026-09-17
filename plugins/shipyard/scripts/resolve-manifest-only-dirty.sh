#!/usr/bin/env bash
# resolve-manifest-only-dirty.sh — resolve a DIRTY PR in-process, without
# dispatching a full fix-rebase worker, when the rebase is either clean or
# conflicts ONLY on the version-coordinated manifest `.version` row (+
# optionally the top-of-file CHANGELOG entry).
#
# Background (issue #1377). On a `version_coordination`-enabled repo whose
# release convention bumps a shared manifest row on every merge (this repo's
# own "ALWAYS cut a release when a PR merges" rule), a sibling PR merging
# while another is still in flight DIRTYs the second PR's manifest/CHANGELOG
# rows — not a race, a structural consequence of allocating a version at
# dispatch time. `agents/issue-worker/fix-rebase.md` §4.6 already resolves
# this deterministically (take main's version, bump at the PR's release
# level to the next free slot, re-number the CHANGELOG heading, place
# newest-first) — but paying for a full worker dispatch (a fresh isolated
# worktree, an agent turn, a model call) to run a two-line renumber is
# expensive: one measured session spent 8 of 25 dispatches (~32%, ~1.11M
# input tokens) on exactly this. This script is the orchestrator's own
# in-process shortcut for the common, cheap case; a manifest/CHANGELOG
# resolution here is functionally identical to what the worker would have
# produced, so the caller treats a `resolved` exit as equivalent to a
# `rebased #<M>` worker return. Anything wider than the recognized case
# defers to the normal fix-rebase dispatch — this script never attempts a
# semantic merge.
#
# This also covers the DEFAULT_BRANCH != coordinated case for free: any
# DIRTY PR whose rebase turns out to be conflict-free once actually
# attempted (GitHub's cached mergeStateStatus can be stale) is resolved and
# pushed here too, with no manifest/CHANGELOG config required at all.
#
# Design — an EPHEMERAL, NESTED git worktree, not the caller's own checkout.
# The orchestrator (or, via a hand-invocation, a fix-rebase-adjacent context)
# calls this script from ITS OWN worktree/cwd, which must stay untouched —
# this script never changes the caller's checked-out branch. It creates a
# short-lived `git worktree add --detach` under --scratch-root (default
# .shipyard-scratch/, already self-ignored by worker-preamble convention),
# does all rebase/resolve/verify/push work there, and removes it before
# returning — success or failure. Nested worktrees under an existing linked
# worktree are ordinary git and were confirmed to work in this environment.
#
# Usage:
#   resolve-manifest-only-dirty.sh resolve --repo <owner/repo> --pr <M>
#       --head-ref <headRefName> --default-branch <branch>
#       [--manifest <path>] [--version-jq <jq-expr>] [--changelog <path>]
#       [--scratch-root <path>] [--cursor-file <path>]
#
# --manifest / --version-jq / --changelog are optional — omit them (or pass
# empty strings) when `version_coordination` isn't enabled on this repo. A
# clean rebase is still attempted and pushed; only an ACTUAL conflict on the
# manifest/CHANGELOG rows requires them to be set, and their absence in that
# case is treated as "can't resolve this conflict" (deferred), not a script
# error.
#
# Version-floor enforcement (issue #1539)
# ---------------------------------------
# The release-bump guard (scripts/tests/release-bump-required.test.sh)
# requires the head manifest version to be STRICTLY GREATER than the
# merge-base's — "not lower" is not enough. After rebasing onto
# origin/<default-branch>, that merge-base IS origin/<default-branch>, so
# its manifest version is the floor the resolved head must clear.
#
# Only ONE of this script's three paths used to compute that floor: the
# manifest-conflict path (floor bumped at the PR's release level). The other
# two left the head at whatever it already was — the clean-rebase path did no
# version work at all, and the CHANGELOG-only-conflict path reused whatever
# git's own 3-way merge left on disk. When a sibling PR had already merged
# the SAME version this PR carried, both sides' identical `.version` edit
# auto-merged and the head landed EQUAL to the new floor: the script reported
# `resolved`, the PR flipped DIRTY -> MERGEABLE, and the guard failed it one
# CI cycle later (`base=4.51.7, head=4.51.7`).
#
# That state is also OUTSIDE this script's own entry condition — a PR that is
# merely failing a check is BLOCKED, not DIRTY — so a re-run deferred
# `not-dirty` and the script could not clean up after itself. The entry
# condition is deliberately NOT widened (see the `not-dirty` defer below);
# instead the post-rebase enforcement block makes the bad state unreachable.
#
# Version-cursor participation (issue #1539, secondary finding)
# -------------------------------------------------------------
# Whenever this script ALLOCATES a version it folds in, and then advances,
# next-available-version.sh's `--cursor-file` (default `.shipyard-version-
# cursor`, the same literal the orchestrator passes to `compute`). Without
# it, resolving two DIRTY PRs in one pass handed both the same floor+1 slot —
# costing a guaranteed extra DIRTY -> resolve round for every PR after the
# first, since whichever merged first immediately re-dirtied the rest at the
# same version. Reading a cursor can only ever raise the slot handed out, so
# it cannot reintroduce a collision.
#
# Keeping the PR's own pre-allocated slot (issue #1571)
# -----------------------------------------------------
# Folding the cursor in unconditionally had a cost of its own: `compute` had
# ALREADY advanced the cursor to this PR's own slot when the PR was dispatched,
# so `max(floor, cursor)` equalled the PR's version and the allocator skipped
# past it to the next one. Every DIRTY PR burned a version number it already
# legitimately held, and the released sequence grew permanent gaps. The
# allocator now keeps `pr_version` whenever it is still strictly above the
# floor, and reallocates (cursor fold included) only once main has reached or
# passed it. See allocate_slot below.
#
# Exit status / stdout (exactly one line):
#   0  resolved pr=<M> version=<next-free-or-empty> head=<new-sha>
#      The rebase (clean, or a recognized manifest/CHANGELOG conflict) was
#      resolved and force-pushed. Caller should treat this exactly like a
#      `rebased #<M>` fix-rebase worker return — no worker dispatch needed.
#   1  deferred reason=<short-code>: <detail>
#      Could not resolve in-process (PR no longer DIRTY, conflict extends
#      beyond the recognized set, a safety-net check tripped, or the push
#      lease was rejected). Caller falls back to the normal fix-rebase
#      dispatch — nothing was pushed, and any local rebase state was
#      aborted and cleaned up.
#   2  deferred reason=script-error: <detail>
#      Usage error or a missing required tool. Caller treats identically to
#      exit 1 (fall back to worker dispatch); the distinct code is only so a
#      human reading logs can tell a real conflict apart from an
#      environment problem.
#
# Never left behind: the ephemeral worktree is removed via a trap on every
# exit path, and `git rebase --abort` runs before any bail that leaves the
# ephemeral worktree mid-rebase.

set -u
export LC_ALL=C
# Never pop an interactive editor for `git rebase --continue` — this script
# always resolves conflicts by staging content directly, never by writing a
# commit message.
export GIT_EDITOR=true

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "$here/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  resolve-manifest-only-dirty.sh resolve --repo <owner/repo> --pr <M>
      --head-ref <headRefName> --default-branch <branch>
      [--manifest <path>] [--version-jq <jq-expr>] [--changelog <path>]
      [--scratch-root <path>] [--cursor-file <path>]
  resolve-manifest-only-dirty.sh --help
EOF
}

# -h/--help exits 0 before any tool-availability check or subcommand
# validation (issue #1550's sweep) — the usage() block is the normative
# source of this script's call shape when spec prose drifts, and that
# fallback only works if --help itself doesn't require a working `gh`/`jq`
# just to print it.
case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

defer() {
  # $1: short reason code, $2: human detail
  printf 'deferred reason=%s: %s\n' "$1" "$2"
  exit 1
}

script_error() {
  printf 'deferred reason=script-error: %s\n' "$1"
  exit 2
}

require_jq "resolve-manifest-only-dirty.sh"
GH="${GH:-gh}"
for tool in "$GH" git awk sed; do
  command -v "$tool" >/dev/null 2>&1 || script_error "required tool '$tool' not found on PATH"
done

sub="${1:-}"
[ $# -gt 0 ] && shift
[ "$sub" = "resolve" ] || { usage >&2; script_error "unknown or missing subcommand '$sub'"; }

REPO=""
PR=""
HEAD_REF=""
DEFAULT_BRANCH=""
MANIFEST=""
VERSION_JQ=".version"
CHANGELOG=""
SCRATCH_ROOT=".shipyard-scratch"
CURSOR_FILE=".shipyard-version-cursor"

while [ $# -gt 0 ]; do
  case "$1" in
    --cursor-file) CURSOR_FILE="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --pr) PR="${2:-}"; shift 2 ;;
    --head-ref) HEAD_REF="${2:-}"; shift 2 ;;
    --default-branch) DEFAULT_BRANCH="${2:-}"; shift 2 ;;
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --version-jq) VERSION_JQ="${2:-.version}"; shift 2 ;;
    --changelog) CHANGELOG="${2:-}"; shift 2 ;;
    --scratch-root) SCRATCH_ROOT="${2:-.shipyard-scratch}"; shift 2 ;;
    *) usage >&2; script_error "unknown argument: $1" ;;
  esac
done

if [ -z "$REPO" ] || [ -z "$PR" ] || [ -z "$HEAD_REF" ] || [ -z "$DEFAULT_BRANCH" ]; then
  usage >&2
  script_error "--repo, --pr, --head-ref, and --default-branch are required"
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || script_error "not inside a git working tree"

# Absolutize the cursor path up front — several blocks below run inside
# `( cd "$WT_DIR" && ... )` subshells, and a relative path would resolve
# somewhere else entirely from in there.
case "$CURSOR_FILE" in
  ""|/*) : ;;
  *) CURSOR_FILE="$PWD/$CURSOR_FILE" ;;
esac

# --- Version helpers (issue #1539) ------------------------------------------
# `version_gt` / `version_max` / `is_semver` come from lib/common.sh, sourced
# above — the SAME strictly-greater `sort -V` comparison next-available-
# version.sh uses and release-bump-required.test.sh's guard asserts with. This
# script must never reimplement a semver compare of its own: this bug WAS a
# drift between "not lower" and "strictly higher".

# compute_next_free <base_version> <pr_version> <floor> — infer the PR's own
# release LEVEL from its (base -> pr) delta, then bump <floor> at that level.
# Mirrors fix-rebase.md §4.6 step 1 and next-available-version.sh's `compute`.
# Prints the next free slot, or nothing when the inputs aren't usable semver.
compute_next_free() {
  local base="$1" pr="$2" floor="$3" level
  is_semver "$floor" || { printf '' ; return; }
  local b_maj b_min p_maj p_min f_maj f_min f_pat
  IFS='.' read -r b_maj b_min _ <<< "$base"
  IFS='.' read -r p_maj p_min _ <<< "$pr"
  if [ "${p_maj:-0}" -gt "${b_maj:-0}" ] 2>/dev/null; then
    level="major"
  elif [ "${p_min:-0}" -gt "${b_min:-0}" ] 2>/dev/null; then
    level="minor"
  else
    level="patch"
  fi
  IFS='.' read -r f_maj f_min f_pat <<< "$floor"
  case "$level" in
    major) printf '%s.0.0' "$((f_maj + 1))" ;;
    minor) printf '%s.%s.0' "$f_maj" "$((f_min + 1))" ;;
    *)     printf '%s.%s.%s' "$f_maj" "$f_min" "$((f_pat + 1))" ;;
  esac
}

# cursor_read — the persisted next-available-version cursor's value, or empty
# when there's no usable one. Never fatal; a missing cursor just means "no
# same-pass sibling has claimed anything above the floor yet".
cursor_read() {
  [ -n "$CURSOR_FILE" ] || return 0
  [ -f "$CURSOR_FILE" ] || return 0
  local v
  v=$(cat "$CURSOR_FILE" 2>/dev/null || echo "")
  is_semver "$v" || return 0
  printf '%s' "$v"
}

# cursor_advance <version> — record a slot this script just handed out, so the
# NEXT resolve (or the orchestrator's next `compute`) floors above it. Uses
# version_max so a lower value can never lower the cursor.
cursor_advance() {
  [ -n "$CURSOR_FILE" ] || return 0
  is_semver "$1" || return 0
  local prev
  prev=$(cursor_read)
  printf '%s' "$(version_max "$prev" "$1")" > "$CURSOR_FILE" 2>/dev/null || true
}

# allocate_slot <base_version> <pr_version> <floor> — the ONE place this
# script picks a new version.
#
# Step 1 (issue #1571): KEEP the PR's own pre-allocated version whenever main
# has not reached it. A version this PR already carries is this PR's own claim
# — the orchestrator's next-available-version.sh `compute` handed it out at
# dispatch time and no sibling holds it — so as long as it is still strictly
# above <floor> it satisfies the release-bump guard as-is and there is nothing
# to reallocate.
#
# This early return is load-bearing, not an optimization. Without it the
# cursor fold below counted the PR's OWN claim against it: `compute` had
# already advanced the cursor TO this PR's slot at dispatch, so
# `max(floor, cursor)` equalled pr_version and compute_next_free returned the
# slot ABOVE it. At --concurrency 1 every PR that goes DIRTY from its
# predecessor's merge burned one version number that way, leaving permanent
# gaps in the released sequence (observed live: 4.55.5 -> 4.55.6 and
# 4.55.7 -> 4.55.8 in session do-work-20260916T112450Z-93563).
#
# Step 2 (issue #1539): only when main HAS reached or passed the PR's version
# — so the claim is genuinely dead — fold the persisted cursor into the floor,
# so two resolves in one pass can't hand out the same slot, then bump at the
# PR's own release level. A cursor strictly above pr_version means some LATER
# dispatch claimed higher slots; that is real contention and must still be
# skipped past. Either way the result is strictly greater than <floor>, which
# is exactly what the release-bump guard requires.
allocate_slot() {
  local base="$1" pr="$2" floor="$3" cursor effective
  if is_semver "$pr" && version_gt "$pr" "$floor"; then
    printf '%s' "$pr"
    return
  fi
  cursor=$(cursor_read)
  effective=$(version_max "$floor" "$cursor")
  compute_next_free "$base" "$pr" "$effective"
}

# --- Pre-flight: confirm DIRTY is still the state (state drifts between
# the caller's snapshot and this script running) ---------------------------
preflight=$("$GH" pr view "$PR" --repo "$REPO" --json mergeStateStatus,state 2>/dev/null)
[ -n "$preflight" ] || defer "preflight-failed" "could not read PR #$PR state"
pr_state=$(printf '%s' "$preflight" | jq -r '.state')
merge_state=$(printf '%s' "$preflight" | jq -r '.mergeStateStatus')
[ "$pr_state" = "OPEN" ] || defer "not-open" "PR #$PR is $pr_state, not OPEN"
# The DIRTY-only entry condition is deliberate and stays narrow (#1539's
# tertiary finding). A PR that is merely FAILING a check reports BLOCKED, not
# DIRTY — repairing that is fix-checks-only's job, and this script has no
# branch-name lock (it checks out detached on purpose), so force-pushing a
# rebase at a merely-red PR could race a live fix-checks worker holding that
# same head branch. The reason a red-not-dirty PR used to be UNRECOVERABLE
# here is that this script created that state itself; the post-rebase
# version-floor enforcement below makes it unreachable instead.
[ "$merge_state" = "DIRTY" ] || defer "not-dirty" "PR #$PR mergeStateStatus=$merge_state, not DIRTY"

# --- Scratch worktree setup -------------------------------------------------
mkdir -p "$SCRATCH_ROOT" 2>/dev/null || script_error "could not create scratch root '$SCRATCH_ROOT'"
# Resolve to an absolute path — every downstream path built from
# $SCRATCH_ROOT must stay valid even after a `cd "$WT_DIR"` into a subshell
# several directories below it (the safety-net calls below do exactly
# that), which a relative path wouldn't survive.
SCRATCH_ROOT="$(cd "$SCRATCH_ROOT" && pwd)"
printf '*\n' > "$SCRATCH_ROOT/.gitignore" 2>/dev/null || true
git worktree prune >/dev/null 2>&1 || true

WT_DIR="$SCRATCH_ROOT/vc-resolve-$PR-$$-$RANDOM"
# Inline trap command (not a named function) so it fires reliably on every
# exit path — best-effort, never lets a cleanup failure mask the real exit
# code. Mirrors this directory's own trap convention (assert-rebase-diff-
# nonempty.sh, gh-batch.sh, etc. all use an inline string here too).
trap 'if [ -d "$WT_DIR" ]; then git -C "$WT_DIR" rebase --abort >/dev/null 2>&1 || true; git worktree remove "$WT_DIR" --force >/dev/null 2>&1 || true; rm -rf "$WT_DIR" 2>/dev/null || true; fi; git worktree prune >/dev/null 2>&1 || true' EXIT

git fetch origin "$HEAD_REF" "$DEFAULT_BRANCH" --quiet 2>/dev/null \
  || defer "fetch-failed" "could not fetch origin/$HEAD_REF and origin/$DEFAULT_BRANCH"

PRE_HEAD_OID=$(git rev-parse "origin/$HEAD_REF" 2>/dev/null)
[ -n "$PRE_HEAD_OID" ] || defer "fetch-failed" "origin/$HEAD_REF did not resolve after fetch"

git worktree add --detach "$WT_DIR" "origin/$HEAD_REF" --quiet 2>/dev/null \
  || defer "worktree-add-failed" "could not create ephemeral worktree at $WT_DIR"

# --- Ref-derived facts, resolved ONCE for every path below --------------------
# All four read from refs only, so nothing the ephemeral worktree does can
# change them. They were previously computed inside the conflict branch alone;
# the post-rebase version-floor enforcement (#1539) needs them on the
# clean-rebase path too.
BASE_SHA=$(git merge-base "origin/$HEAD_REF" "origin/$DEFAULT_BRANCH" 2>/dev/null)
FLOOR=""
PR_VERSION=""
BASE_VERSION=""
if [ -n "$MANIFEST" ]; then
  FLOOR=$(git show "origin/$DEFAULT_BRANCH:$MANIFEST" 2>/dev/null | jq -r "$VERSION_JQ" 2>/dev/null)
  PR_VERSION=$(git show "origin/$HEAD_REF:$MANIFEST" 2>/dev/null | jq -r "$VERSION_JQ" 2>/dev/null)
  [ -n "$BASE_SHA" ] && BASE_VERSION=$(git show "$BASE_SHA:$MANIFEST" 2>/dev/null | jq -r "$VERSION_JQ" 2>/dev/null)
  [ "$FLOOR" = "null" ] && FLOOR=""
  [ "$PR_VERSION" = "null" ] && PR_VERSION=""
  [ "$BASE_VERSION" = "null" ] && BASE_VERSION=""
fi

# Set to 1 by whichever step actually rewrites the coordinated row, so the
# known-rewrites record below is keyed on "did we rewrite it", not on "did it
# conflict" — the version-floor enforcement rewrites both rows on paths where
# neither ever conflicted.
MANIFEST_REWRITTEN=0
CHANGELOG_REWRITTEN=0
# Non-empty only when this run HANDED OUT a version slot (so the cursor is
# advanced exactly once, after the push actually lands).
ALLOCATED=""

# --- Attempt the rebase ------------------------------------------------------
if git -C "$WT_DIR" rebase "origin/$DEFAULT_BRANCH" >/dev/null 2>&1; then
  NEXT_FREE=""
else
  # --- Conflict triage: recognized set is {manifest, changelog} only -------
  CONFLICTED=$(git -C "$WT_DIR" diff --name-only --diff-filter=U 2>/dev/null)
  [ -n "$CONFLICTED" ] || defer "rebase-failed-no-conflict" "rebase exited non-zero but no conflicted paths found"

  UNRECOGNIZED=""
  MANIFEST_CONFLICTED=0
  CHANGELOG_CONFLICTED=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [ -n "$MANIFEST" ] && [ "$f" = "$MANIFEST" ]; then
      MANIFEST_CONFLICTED=1
    elif [ -n "$CHANGELOG" ] && [ "$f" = "$CHANGELOG" ]; then
      CHANGELOG_CONFLICTED=1
    else
      UNRECOGNIZED="$UNRECOGNIZED $f"
    fi
  done <<EOF
$CONFLICTED
EOF

  if [ -n "$UNRECOGNIZED" ]; then
    defer "conflict-wider" "conflict extends beyond coordinated manifest+CHANGELOG rows ($UNRECOGNIZED trimmed)"
  fi
  if [ "$MANIFEST_CONFLICTED" -eq 0 ] && [ "$CHANGELOG_CONFLICTED" -eq 0 ]; then
    # Conflicted paths existed but matched neither recognized file — only
    # reachable if MANIFEST/CHANGELOG were both empty while a conflict
    # still occurred (vc disabled on this repo).
    defer "vc-disabled" "rebase conflicted but no coordinated manifest/CHANGELOG configured"
  fi

  # Resolved above, unconditionally; required whenever there IS a recognized
  # conflict — both the manifest resolution and the known-rewrites extraction
  # below need it, and either can run without the other (e.g. CHANGELOG-only
  # conflicted, MANIFEST auto-merged clean).
  [ -n "$BASE_SHA" ] || defer "merge-base-failed" "could not resolve the merge-base of origin/$HEAD_REF and origin/$DEFAULT_BRANCH"

  # --- Hunk-shape gates, via git's diff3 conflict markers -------------------
  # Regenerating in diff3 style gives an explicit ours/base/theirs split per
  # hunk (see resolve-append-only-conflict.sh for the sibling technique).
  # During a REBASE, "ours" is the branch being rebased ONTO (main) and
  # "theirs" is the commit being replayed (this PR) — confirmed empirically
  # against this environment's git before relying on it here.
  extract_single_hunk() {
    # $1: conflicted file (worktree-relative). Regenerates it in diff3 form
    # and, IFF it contains exactly one hunk, splits pre-hunk content into
    # $2, ours/base/theirs into $3/$4/$5, and trailing (post-hunk) content
    # into $6. Prints "1" on stdout if exactly one hunk was found and
    # split, else "0" (multi-hunk — caller must bail, nothing is written).
    local file="$1" prefile="$2" oursfile="$3" basefile="$4" theirsfile="$5" trailfile="$6"
    git -C "$WT_DIR" checkout --conflict=diff3 -- "$file" 2>/dev/null || { echo 0; return; }
    : > "$prefile"; : > "$oursfile"; : > "$basefile"; : > "$theirsfile"; : > "$trailfile"
    awk -v prefile="$prefile" -v oursfile="$oursfile" -v basefile="$basefile" -v theirsfile="$theirsfile" -v trailfile="$trailfile" '
      BEGIN { sect = "pre"; n = 0 }
      /^<<<<<<< / { n++; sect = "ours"; next }
      /^\|\|\|\|\|\|\| / { sect = "base"; next }
      /^=======$/ { sect = "theirs"; next }
      /^>>>>>>> / { sect = "trail"; next }
      sect == "pre"    { print > prefile; next }
      sect == "ours"   { print > oursfile; next }
      sect == "base"   { print > basefile; next }
      sect == "theirs" { print > theirsfile; next }
      sect == "trail"  { print > trailfile; next }
      { next }
      END { printf "%d\n", n > "/dev/stderr" }
    ' "$WT_DIR/$file" 2> "$SCRATCH_ROOT/.vc-resolve-nhunks-$$"
    local n
    n=$(cat "$SCRATCH_ROOT/.vc-resolve-nhunks-$$" 2>/dev/null || echo 0)
    rm -f "$SCRATCH_ROOT/.vc-resolve-nhunks-$$"
    if [ "${n:-0}" = "1" ]; then echo 1; else echo 0; fi
  }

  if [ "$MANIFEST_CONFLICTED" -eq 1 ]; then
    # Structural check, not a hunk-count heuristic: read BOTH sides' full
    # manifest content directly ("ours" during a rebase is the branch being
    # rebased onto — origin/$DEFAULT_BRANCH; "theirs" is the commit being
    # replayed — origin/$HEAD_REF, confirmed empirically against this
    # environment's git), blank out the version field on each via jq, and
    # require the two blanked documents to be byte-identical. This is a
    # stronger guarantee than "the diff hunk was N lines" — it directly
    # proves every OTHER key is unchanged, so a whole-file `--ours` +
    # single jq-set of the version field cannot silently discard a
    # legitimate PR edit to some other key (the issue #646 failure shape).
    GATE_OURS_FULL=$(git show "origin/$DEFAULT_BRANCH:$MANIFEST" 2>/dev/null)
    GATE_THEIRS_FULL=$(git show "origin/$HEAD_REF:$MANIFEST" 2>/dev/null)
    if [ -z "$GATE_OURS_FULL" ] || [ -z "$GATE_THEIRS_FULL" ]; then
      defer "manifest-read-failed" "could not read $MANIFEST from both sides of the conflict"
    fi
    GATE_OURS_NOVER=$(printf '%s' "$GATE_OURS_FULL" | jq -S --arg z "__vc_sentinel__" "$VERSION_JQ = \$z" 2>/dev/null)
    GATE_THEIRS_NOVER=$(printf '%s' "$GATE_THEIRS_FULL" | jq -S --arg z "__vc_sentinel__" "$VERSION_JQ = \$z" 2>/dev/null)
    if [ -z "$GATE_OURS_NOVER" ] || [ "$GATE_OURS_NOVER" != "$GATE_THEIRS_NOVER" ]; then
      defer "manifest-conflict-outside-version-row" "manifest conflict touches more than the $VERSION_JQ row"
    fi
  fi

  if [ "$CHANGELOG_CONFLICTED" -eq 1 ]; then
    C_PRE="$SCRATCH_ROOT/.vc-c-pre-$$"
    C_OURS="$SCRATCH_ROOT/.vc-c-ours-$$"
    C_BASE="$SCRATCH_ROOT/.vc-c-base-$$"
    C_THEIRS="$SCRATCH_ROOT/.vc-c-theirs-$$"
    C_TRAIL="$SCRATCH_ROOT/.vc-c-trail-$$"
    SINGLE=$(extract_single_hunk "$CHANGELOG" "$C_PRE" "$C_OURS" "$C_BASE" "$C_THEIRS" "$C_TRAIL")
    if [ "$SINGLE" != "1" ]; then
      rm -f "$C_PRE" "$C_OURS" "$C_BASE" "$C_THEIRS" "$C_TRAIL"
      defer "changelog-multi-hunk" "CHANGELOG conflict has more than one hunk — needs manual rebase"
    fi
    # Version-heading insert: both sides' conflicting content must itself
    # START with a `### <version>` heading line — this is the semantic
    # shape check (a version block being prepended), deliberately NOT a
    # "nothing may precede the hunk in the whole file" position check,
    # since a real CHANGELOG.md legitimately has unconflicted prose (a
    # title, a `## shipyard` section heading) ahead of the first entry.
    C_OURS_FIRST=$(head -1 "$C_OURS" 2>/dev/null)
    C_THEIRS_FIRST=$(head -1 "$C_THEIRS" 2>/dev/null)
    case "$C_OURS_FIRST" in
      "### "*) : ;;
      *)
        rm -f "$C_PRE" "$C_OURS" "$C_BASE" "$C_THEIRS" "$C_TRAIL"
        defer "changelog-conflict-outside-top-insert" "CHANGELOG conflict's main-side content is not a version heading insert"
        ;;
    esac
    case "$C_THEIRS_FIRST" in
      "### "*) : ;;
      *)
        rm -f "$C_PRE" "$C_OURS" "$C_BASE" "$C_THEIRS" "$C_TRAIL"
        defer "changelog-conflict-outside-top-insert" "CHANGELOG conflict's PR-side content is not a version heading insert"
        ;;
    esac
    rm -f "$C_PRE" "$C_OURS" "$C_BASE" "$C_THEIRS" "$C_TRAIL"
  fi

  # --- Resolve the manifest --------------------------------------------------
  if [ "$MANIFEST_CONFLICTED" -eq 1 ]; then
    if [ -z "$FLOOR" ] || [ -z "$PR_VERSION" ] || [ -z "$BASE_VERSION" ]; then
      defer "version-read-failed" "could not read $MANIFEST version at one of floor/pr/base refs"
    fi

    NEXT_FREE=$(allocate_slot "$BASE_VERSION" "$PR_VERSION" "$FLOOR")
    is_semver "$NEXT_FREE" \
      || defer "version-compute-failed" "could not compute a next-free slot above $FLOOR for $MANIFEST"
    ALLOCATED="$NEXT_FREE"

    git -C "$WT_DIR" checkout --ours -- "$MANIFEST" 2>/dev/null \
      || defer "manifest-checkout-failed" "git checkout --ours $MANIFEST failed"
    TMP_MANIFEST="$SCRATCH_ROOT/.vc-manifest-$$"
    if ! jq --arg newver "$NEXT_FREE" "$VERSION_JQ = \$newver" "$WT_DIR/$MANIFEST" > "$TMP_MANIFEST" 2>/dev/null; then
      rm -f "$TMP_MANIFEST"
      defer "manifest-jq-set-failed" "jq could not set $VERSION_JQ to $NEXT_FREE"
    fi
    mv "$TMP_MANIFEST" "$WT_DIR/$MANIFEST"
    git -C "$WT_DIR" add "$MANIFEST"
    MANIFEST_REWRITTEN=1
  else
    # Manifest wasn't in conflict — either untouched, or git's own 3-way
    # merge already resolved it. Either way its post-merge value on disk IS
    # the version any changelog resolution below should reuse...
    NEXT_FREE=$(jq -r "$VERSION_JQ" "$WT_DIR/$MANIFEST" 2>/dev/null || echo "")
    [ "$NEXT_FREE" = "null" ] && NEXT_FREE=""

    # ...unless it fails the release-bump guard's STRICTLY-GREATER floor
    # (issue #1539). A sibling PR that already merged this PR's exact version
    # makes both sides' `.version` edit identical, so git auto-merges it
    # silently and the head lands EQUAL to the new merge-base — which the
    # guard rejects. Re-allocate HERE, before the CHANGELOG renumber below,
    # rather than after the rebase finishes: the conflict hunk's PR side is an
    # unambiguous handle on this PR's own heading, whereas rewriting the
    # finished file would have to guess which of two identically-numbered
    # `### <version>` headings (ours and the sibling's) is ours.
    if [ -n "$FLOOR" ] && [ -n "$PR_VERSION" ] && [ -n "$BASE_VERSION" ] \
       && [ "$PR_VERSION" != "$BASE_VERSION" ] \
       && ! version_gt "$NEXT_FREE" "$FLOOR"; then
      NEXT_FREE=$(allocate_slot "$BASE_VERSION" "$PR_VERSION" "$FLOOR")
      is_semver "$NEXT_FREE" \
        || defer "version-compute-failed" "could not compute a next-free slot above $FLOOR for $MANIFEST"
      ALLOCATED="$NEXT_FREE"
      REALLOC_MANIFEST="$SCRATCH_ROOT/.vc-manifest-realloc-$$"
      if ! jq --arg newver "$NEXT_FREE" "$VERSION_JQ = \$newver" "$WT_DIR/$MANIFEST" > "$REALLOC_MANIFEST" 2>/dev/null; then
        rm -f "$REALLOC_MANIFEST"
        defer "manifest-jq-set-failed" "jq could not set $VERSION_JQ to $NEXT_FREE"
      fi
      mv "$REALLOC_MANIFEST" "$WT_DIR/$MANIFEST"
      git -C "$WT_DIR" add "$MANIFEST"
      MANIFEST_REWRITTEN=1
    fi
  fi

  # --- Resolve the CHANGELOG (renumber PR's own entry, hoist above main's) --
  if [ "$CHANGELOG_CONFLICTED" -eq 1 ]; then
    [ -n "$NEXT_FREE" ] || defer "changelog-no-version" "no resolved manifest version available to renumber the CHANGELOG heading with"
    C_PRE="$SCRATCH_ROOT/.vc-c-pre-$$"
    C_OURS="$SCRATCH_ROOT/.vc-c-ours-$$"
    C_BASE="$SCRATCH_ROOT/.vc-c-base-$$"
    C_THEIRS="$SCRATCH_ROOT/.vc-c-theirs-$$"
    C_TRAIL="$SCRATCH_ROOT/.vc-c-trail-$$"
    SINGLE=$(extract_single_hunk "$CHANGELOG" "$C_PRE" "$C_OURS" "$C_BASE" "$C_THEIRS" "$C_TRAIL")
    if [ "$SINGLE" != "1" ]; then
      rm -f "$C_PRE" "$C_OURS" "$C_BASE" "$C_THEIRS" "$C_TRAIL"
      defer "changelog-resolve-shape-changed" "CHANGELOG hunk shape changed between gate check and resolution"
    fi
    RENUMBERED="$SCRATCH_ROOT/.vc-c-renumbered-$$"
    # Line 1 only — the gate above already confirmed $C_THEIRS's first line
    # is a `### <version>` heading, so a `1s/…/…/` address is both
    # sufficient and (unlike a GNU-only `0,/regex/` address, which BSD/macOS
    # sed rejects with "bad flag in substitute command") portable.
    sed -E "1s/^### [0-9]+\\.[0-9]+\\.[0-9]+/### $NEXT_FREE/" "$C_THEIRS" > "$RENUMBERED"
    # $C_PRE is the shared, unconflicted content BEFORE the hunk (a real
    # CHANGELOG.md typically has a `# Changelog` title + `## shipyard`
    # section heading here) — it must be preserved, not just the hunk's
    # two sides + trailing content.
    cat "$C_PRE" "$RENUMBERED" "$C_OURS" "$C_TRAIL" > "$WT_DIR/$CHANGELOG"
    rm -f "$C_PRE" "$C_OURS" "$C_BASE" "$C_THEIRS" "$C_TRAIL" "$RENUMBERED"
    git -C "$WT_DIR" add "$CHANGELOG"
    CHANGELOG_REWRITTEN=1
  fi

  git -C "$WT_DIR" rebase --continue >/dev/null 2>&1 \
    || defer "rebase-continue-failed" "git rebase --continue failed after resolution (possible second conflict stop)"
fi

# --- Post-rebase version-floor enforcement (issue #1539) --------------------
# The rebase is finished on every path above. The head manifest version must
# now be STRICTLY GREATER than the version at origin/$DEFAULT_BRANCH — which
# IS the rebased head's merge-base, and therefore exactly the `base=` the
# release-bump guard compares against. Only the manifest-conflict path
# guaranteed that; the clean-rebase and CHANGELOG-only-conflict paths could
# leave the head EQUAL to the floor (a sibling PR having already merged the
# same version makes both sides' `.version` edit identical, so git auto-merges
# it silently) and this script would still report `resolved`.
#
# Scoped to a PR that ALREADY claims a version of its own (PR_VERSION !=
# BASE_VERSION). A PR that never touched the manifest must not have one
# invented for it here: bumping it would newly touch the watched prefix and
# demand a CHANGELOG entry the PR was never required to have.
if [ -n "$MANIFEST" ] && [ -n "$FLOOR" ] && [ -n "$PR_VERSION" ] \
   && [ -n "$BASE_VERSION" ] && [ "$PR_VERSION" != "$BASE_VERSION" ]; then
  HEAD_VERSION=$(jq -r "$VERSION_JQ" "$WT_DIR/$MANIFEST" 2>/dev/null)
  [ "$HEAD_VERSION" = "null" ] && HEAD_VERSION=""
  [ -n "$HEAD_VERSION" ] \
    || defer "version-read-failed" "could not read $VERSION_JQ from the resolved $MANIFEST"

  if ! version_gt "$HEAD_VERSION" "$FLOOR"; then
    CORRECTED=$(allocate_slot "$BASE_VERSION" "$PR_VERSION" "$FLOOR")
    is_semver "$CORRECTED" \
      || defer "version-floor-uncorrectable" "resolved $MANIFEST version $HEAD_VERSION is not strictly above the floor $FLOOR and no corrected slot could be computed"

    # The guard also requires a matching `### <version> — <date>` heading, so
    # the CHANGELOG entry has to move in lockstep. Exactly one heading may
    # carry the stale version: zero means this repo doesn't use that heading
    # shape (bump the manifest alone), more than one means the entry can't be
    # told from a released sibling's and this is not ours to guess at.
    if [ -n "$CHANGELOG" ] && [ -f "$WT_DIR/$CHANGELOG" ]; then
      HEAD_VERSION_RE="${HEAD_VERSION//./\\.}"
      HEADING_HITS=$(grep -cE "^### ${HEAD_VERSION_RE} " "$WT_DIR/$CHANGELOG" 2>/dev/null)
      if [ "${HEADING_HITS:-0}" -gt 1 ]; then
        defer "changelog-heading-ambiguous" "$CHANGELOG carries $HEADING_HITS '### $HEAD_VERSION' headings — cannot tell this PR's entry from a released one"
      fi
      if [ "${HEADING_HITS:-0}" -eq 1 ]; then
        REFLOOR_CL="$SCRATCH_ROOT/.vc-c-refloor-$$"
        if ! sed -E "s/^### ${HEAD_VERSION_RE} /### $CORRECTED /" "$WT_DIR/$CHANGELOG" > "$REFLOOR_CL" 2>/dev/null; then
          rm -f "$REFLOOR_CL"
          defer "changelog-refloor-failed" "could not renumber the $CHANGELOG heading from $HEAD_VERSION to $CORRECTED"
        fi
        mv "$REFLOOR_CL" "$WT_DIR/$CHANGELOG"
        git -C "$WT_DIR" add "$CHANGELOG"
        CHANGELOG_REWRITTEN=1
      fi
    fi

    REFLOOR_MANIFEST="$SCRATCH_ROOT/.vc-manifest-refloor-$$"
    if ! jq --arg newver "$CORRECTED" "$VERSION_JQ = \$newver" "$WT_DIR/$MANIFEST" > "$REFLOOR_MANIFEST" 2>/dev/null; then
      rm -f "$REFLOOR_MANIFEST"
      defer "manifest-jq-set-failed" "jq could not set $VERSION_JQ to $CORRECTED during version-floor enforcement"
    fi
    mv "$REFLOOR_MANIFEST" "$WT_DIR/$MANIFEST"
    git -C "$WT_DIR" add "$MANIFEST"
    MANIFEST_REWRITTEN=1
    NEXT_FREE="$CORRECTED"
    ALLOCATED="$CORRECTED"

    # Fold the correction into the commit the rebase just produced rather than
    # adding one of its own — an extra commit would need a Conventional
    # Commits subject of its own on every repo that scans them.
    git -C "$WT_DIR" commit --amend --no-edit --quiet >/dev/null 2>&1 \
      || defer "version-floor-commit-failed" "could not fold the corrected version $CORRECTED into the rebased commit"
  fi
fi

# --- Known-rewrites record for the added-lines-survived guard below ---------
# Keyed on what was actually REWRITTEN, not on what conflicted — the
# version-floor enforcement above rewrites both coordinated rows on paths
# where neither ever conflicted (#1539).
KNOWN_REWRITES="$SCRATCH_ROOT/.vc-known-rewrites-$$"
: > "$KNOWN_REWRITES"
if [ "$MANIFEST_REWRITTEN" -eq 1 ] && [ -n "$MANIFEST" ] && [ -n "$BASE_SHA" ]; then
  M_DIFF=$(git diff "$BASE_SHA" "origin/$HEAD_REF" -- "$MANIFEST" 2>/dev/null)
  case "$M_DIFF" in
    "" | "diff --git "*)
      M_LINE=$(printf '%s\n' "$M_DIFF" | awk '/^\+\+\+/{next} /^\+/{line=substr($0,2); if (line ~ /[^ \t]/) print line}' | grep -F -- "$PR_VERSION" | head -1 || true)
      [ -n "$M_LINE" ] && printf '%s\t%s\n' "$MANIFEST" "$M_LINE" >> "$KNOWN_REWRITES"
      ;;
    *) : ;; # unexpected diff shape — leave unexempted, verify step below is stricter, never looser
  esac
fi
if [ "$CHANGELOG_REWRITTEN" -eq 1 ] && [ -n "$CHANGELOG" ] && [ -n "$BASE_SHA" ]; then
  CL_DIFF=$(git diff "$BASE_SHA" "origin/$HEAD_REF" -- "$CHANGELOG" 2>/dev/null)
  case "$CL_DIFF" in
    "" | "diff --git "*)
      CL_LINE=$(printf '%s\n' "$CL_DIFF" | awk '/^\+\+\+/{next} /^\+/{line=substr($0,2); if (line ~ /[^ \t]/) print line}' | grep -E '^### ' | head -1 || true)
      [ -n "$CL_LINE" ] && printf '%s\t%s\n' "$CHANGELOG" "$CL_LINE" >> "$KNOWN_REWRITES"
      ;;
    *) : ;;
  esac
fi

# --- Safety nets (mirrors fix-rebase.md steps 5.5-5.8) ----------------------
# Issue #1462: a raw whole-tree `git grep` for the marker pattern
# false-positives DETERMINISTICALLY on this repo's own clean tree, because
# `plugins/shipyard/scripts/tests/conflict-marker-scan.test.sh` ships marker-
# shaped fixture strings as its test data. Shell out to the authoritative
# scanner instead — it already honors that fixture's `conflict-marker-scan:
# allow` opt-out directive and is the same script wired into the `conflict
# markers` CI required check, so a worktree that passes here also passes CI.
# Fall back to the raw grep ONLY if the scanner binary is somehow missing —
# a genuine surviving marker must remain fatal either way.
CONFLICT_SCANNER="$here/conflict-marker-scan.sh"
if [ -f "$CONFLICT_SCANNER" ]; then
  if ! ( cd "$WT_DIR" && bash "$CONFLICT_SCANNER" >/dev/null 2>&1 ); then
    defer "conflict-markers-remain" "conflict markers survived resolution"
  fi
elif git -C "$WT_DIR" grep -qnE '^(<{7}|={7}|>{7})( |$)' -- . 2>/dev/null; then
  defer "conflict-markers-remain" "conflict markers survived resolution"
fi

if [ -n "$CHANGELOG" ]; then
  SCANNER="$here/changelog-monotonicity-scan.sh"
  if [ -f "$SCANNER" ]; then
    if ! ( cd "$WT_DIR" && CHANGELOG_PATH="$CHANGELOG" bash "$SCANNER" "origin/$DEFAULT_BRANCH" >/dev/null 2>&1 ); then
      defer "changelog-heading-deleted" "resolution deleted a released CHANGELOG heading"
    fi
  fi
fi

DIFF_GUARD="$here/assert-rebase-diff-nonempty.sh"
if [ -f "$DIFF_GUARD" ]; then
  if ! ( cd "$WT_DIR" && bash "$DIFF_GUARD" "origin/$DEFAULT_BRANCH" "origin/$HEAD_REF" >/dev/null 2>&1 ); then
    defer "empty-diff" "rebase result has an empty diff vs base — refusing to push"
  fi
fi

SURVIVED_GUARD="$here/verify-added-lines-survived.sh"
if [ -f "$SURVIVED_GUARD" ]; then
  MERGE_BASE=$(git merge-base "origin/$HEAD_REF" "origin/$DEFAULT_BRANCH" 2>/dev/null)
  KNOWN_REWRITES_ARG=""
  [ -n "${KNOWN_REWRITES:-}" ] && [ -s "$KNOWN_REWRITES" ] && KNOWN_REWRITES_ARG="$KNOWN_REWRITES"
  if [ -n "$MERGE_BASE" ]; then
    if [ -n "$KNOWN_REWRITES_ARG" ]; then
      SURVIVED_OK=0
      ( cd "$WT_DIR" && bash "$SURVIVED_GUARD" "$MERGE_BASE" "origin/$HEAD_REF" "$KNOWN_REWRITES_ARG" >/dev/null 2>&1 ) && SURVIVED_OK=1
    else
      SURVIVED_OK=0
      ( cd "$WT_DIR" && bash "$SURVIVED_GUARD" "$MERGE_BASE" "origin/$HEAD_REF" >/dev/null 2>&1 ) && SURVIVED_OK=1
    fi
    [ "$SURVIVED_OK" = "1" ] || defer "added-lines-missing" "a PR-added line did not survive the resolution verbatim"
  fi
fi
[ -n "${KNOWN_REWRITES:-}" ] && rm -f "$KNOWN_REWRITES"

# --- Push ---------------------------------------------------------------
NEW_HEAD=$(git -C "$WT_DIR" rev-parse HEAD 2>/dev/null)
[ -n "$NEW_HEAD" ] || defer "no-head" "rebased worktree has no resolvable HEAD"

LEASE="refs/heads/$HEAD_REF:$PRE_HEAD_OID"
if ! git -C "$WT_DIR" push --force-with-lease="$LEASE" origin "HEAD:refs/heads/$HEAD_REF" >/dev/null 2>&1; then
  defer "push-lease-rejected" "head branch $HEAD_REF moved since fetch — someone else pushed"
fi

# Only now — after the slot is actually claimed on the remote — record it, so
# the next resolve in this same pass (and the orchestrator's next `compute`)
# floors above it instead of handing out the identical value (#1539).
[ -n "$ALLOCATED" ] && cursor_advance "$ALLOCATED"

printf 'resolved pr=%s version=%s head=%s\n' "$PR" "${NEXT_FREE:-}" "$NEW_HEAD"
exit 0
