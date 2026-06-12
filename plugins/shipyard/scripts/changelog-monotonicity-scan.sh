#!/usr/bin/env bash
# changelog-monotonicity-scan.sh — fail when any `### <version>` heading
# present on the merge-base side of CHANGELOG.md is absent on the head side.
#
# Background (issue #555): during a high-concurrency /shipyard:do-work
# session, sibling-PR merge conflict resolutions silently deleted released
# CHANGELOG entries from `main`. PR #552 and PR #553 merged via the
# admin-direct path; their merge-time conflict resolutions against the
# moving CHANGELOG dropped main's `### 1.9.10` entry entirely and also
# dropped the `### 1.9.9` heading + summary paragraph (PR #545's release),
# leaving the 1.9.9 bullets orphaned under the 1.9.12 entry. The losses
# were only noticed because a manual rebase of a blocked PR put a human
# eyeball on the file.
#
# The existing conflict-marker gate (#436) catches *unresolved* markers;
# it cannot catch a *resolved-wrong* merge that silently deletes whole
# heading blocks. This script closes that gap: it compares the `### <ver>`
# heading set in CHANGELOG.md on the merge-base against the heading set on
# the PR head (or working tree) and fails when any heading was deleted.
#
# Design: "only headings present on the merge-base side count"
# A PR that re-numbers its OWN unmerged entry (which was never on the base)
# does NOT false-positive — the new heading simply doesn't appear in the
# base's heading set so there is nothing to miss. Only genuinely released
# entries (those already on the merge-base) are protected.
#
# Usage (CI — PR context):
#   bash plugins/shipyard/scripts/changelog-monotonicity-scan.sh
#
# Usage (CI — push-to-main context, compare against parent commit):
#   bash plugins/shipyard/scripts/changelog-monotonicity-scan.sh HEAD~1
#
# Usage (explicit merge-base ref):
#   bash plugins/shipyard/scripts/changelog-monotonicity-scan.sh <ref>
#
# Usage (explicit CHANGELOG path, e.g. for other repos):
#   CHANGELOG_PATH=docs/CHANGELOG.md \
#     bash plugins/shipyard/scripts/changelog-monotonicity-scan.sh
#
# Exit status:
#   0 — no released headings were deleted (clean)
#   1 — one or more released headings are missing from the head
#   2 — usage / environment error (not in a git repo, CHANGELOG not found, etc.)
#
# The scan is intentionally scoped to `### ` headings (H3, the version
# heading level used in this repo's CHANGELOG). H1 (`# `) and H2 (`## `)
# section headings are structural and not versioned — they are not
# protected by this gate.
#
# Opt-out: a CHANGELOG file can carry a `changelog-monotonicity-scan: allow`
# directive to exempt itself (useful for test fixtures that construct
# synthetic CHANGELOGs). This directive is checked on the head-side file;
# a CHANGELOG without the directive is always scanned.

set -u

CHANGELOG_PATH="${CHANGELOG_PATH:-CHANGELOG.md}"

# Heading pattern: a line that starts with `### ` (H3, version entries).
# We match the literal prefix rather than a regex so prose lines with `###`
# deeper in a paragraph don't accidentally match.
HEADING_PREFIX='### '

usage() {
  cat >&2 <<'EOF'
usage: changelog-monotonicity-scan.sh [<merge-base-ref>]

  Scans CHANGELOG.md for deleted `### <version>` headings.

  With no argument, auto-computes the merge-base between HEAD and
  origin/HEAD (or origin/main / origin/master as fallback). Pass an
  explicit git ref to override the merge-base computation.

  Set CHANGELOG_PATH env var to scan a different file (default: CHANGELOG.md).

  Exit status: 0 = clean, 1 = deleted heading(s) found, 2 = env/usage error.
EOF
  exit 2
}

case "${1:-}" in
  -h|--help) usage ;;
esac

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "changelog-monotonicity-scan: not inside a git work tree" >&2
  exit 2
fi

# Resolve the CHANGELOG path relative to the repo root so the script works
# from any subdirectory.
repo_root="$(git rev-parse --show-toplevel)"
changelog_full="$repo_root/$CHANGELOG_PATH"

# (A) If a merge-base ref was supplied explicitly, use it; otherwise auto-detect.
if [[ $# -ge 1 ]]; then
  merge_base_ref="$1"
  # Validate the ref resolves.
  if ! git rev-parse --verify "$merge_base_ref^{commit}" >/dev/null 2>&1; then
    echo "changelog-monotonicity-scan: cannot resolve ref '$merge_base_ref'" >&2
    exit 2
  fi
else
  # Auto-compute the merge-base between HEAD and the remote default branch.
  # Try origin/HEAD first (most reliable in CI), then fall back to common
  # default branch names.
  remote_default=""
  for candidate in origin/HEAD origin/main origin/master; do
    if git rev-parse --verify "$candidate" >/dev/null 2>&1; then
      remote_default="$candidate"
      break
    fi
  done

  if [[ -z "$remote_default" ]]; then
    # No remote ref found — we're likely in a shallow clone or a fixture repo.
    # Fall back to HEAD~1 so a single-commit fixture still exercises the logic.
    if git rev-parse --verify "HEAD~1" >/dev/null 2>&1; then
      merge_base_ref="HEAD~1"
    else
      # Very first commit; nothing to compare against — treat as clean.
      echo "changelog-monotonicity-scan: only one commit in history, nothing to compare — skipping."
      exit 0
    fi
  else
    merge_base_ref="$(git merge-base HEAD "$remote_default" 2>/dev/null)" || {
      echo "changelog-monotonicity-scan: could not compute merge-base between HEAD and $remote_default" >&2
      exit 2
    }
    if [[ -z "$merge_base_ref" ]]; then
      echo "changelog-monotonicity-scan: empty merge-base between HEAD and $remote_default" >&2
      exit 2
    fi
  fi
fi

# (B) Check whether the CHANGELOG even exists on the base side.
# If it didn't exist on the base (brand-new file), there are no released
# entries to protect — the scan is a no-op.
if ! git show "${merge_base_ref}:${CHANGELOG_PATH}" >/dev/null 2>&1; then
  echo "changelog-monotonicity-scan: $CHANGELOG_PATH not present on base ($merge_base_ref) — no released entries to protect."
  exit 0
fi

# (C) Check whether the CHANGELOG exists on the head side.
if [[ ! -f "$changelog_full" ]]; then
  echo "changelog-monotonicity-scan: $CHANGELOG_PATH missing from working tree — was it deleted?" >&2
  exit 1
fi

# (D) Opt-out directive: if the working-tree CHANGELOG carries the allow
# directive on a line by itself (optionally with leading whitespace), skip
# the scan entirely (useful for test fixture files that construct synthetic
# CHANGELOGs). The directive must appear at the start of a line so that
# prose *describing* the directive (e.g. in a CHANGELOG entry that mentions
# "changelog-monotonicity-scan: allow directive") does not trip the check.
if grep -qE '^\s*changelog-monotonicity-scan: allow' "$changelog_full" 2>/dev/null; then
  echo "changelog-monotonicity-scan: $CHANGELOG_PATH carries the allow directive — skipping."
  exit 0
fi

# (E) Extract the `### <version>` headings from the merge-base CHANGELOG.
# Use git show to read the file at the base ref without checking it out.
# Store each heading (without leading `### `) in an array.
base_headings=()
while IFS= read -r line; do
  base_headings+=("$line")
done < <(git show "${merge_base_ref}:${CHANGELOG_PATH}" 2>/dev/null \
  | grep "^${HEADING_PREFIX}" \
  | sed "s/^${HEADING_PREFIX}//")

if [[ ${#base_headings[@]} -eq 0 ]]; then
  # No versioned headings on the base — nothing to protect.
  echo "changelog-monotonicity-scan: no '${HEADING_PREFIX}' headings on base side — skipping."
  exit 0
fi

# (F) Extract the `### <version>` headings from the working-tree CHANGELOG
# into a temporary file for membership testing.
head_headings_tmp="$(mktemp)"
trap 'rm -f "$head_headings_tmp"' EXIT
grep "^${HEADING_PREFIX}" "$changelog_full" 2>/dev/null \
  | sed "s/^${HEADING_PREFIX}//" > "$head_headings_tmp"

# (G) Check for deletions: any base heading absent from the head is a violation.
# Use grep -qxF for exact-line membership test (no regex, no partial match,
# bash 3-compatible — no declare -A required).
missing=()
for h in "${base_headings[@]}"; do
  if ! grep -qxF -- "$h" "$head_headings_tmp" 2>/dev/null; then
    missing+=("$h")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo >&2
  echo "changelog-monotonicity-scan: deleted released CHANGELOG heading(s) detected." >&2
  echo "The following '${HEADING_PREFIX}' heading(s) exist on the merge-base but are" >&2
  echo "absent from the current ${CHANGELOG_PATH}:" >&2
  for h in "${missing[@]}"; do
    printf '  ### %s\n' "$h" >&2
  done
  echo >&2
  echo "Released entries must never be deleted from CHANGELOG.md." >&2
  echo "If this is a conflict-resolution artifact, restore the missing heading(s)." >&2
  echo "See https://github.com/mattsears18/shipyard/issues/555" >&2
  exit 1
fi

count="${#base_headings[@]}"
echo "changelog-monotonicity-scan: all ${count} released '${HEADING_PREFIX}' heading(s) present — clean."
exit 0
