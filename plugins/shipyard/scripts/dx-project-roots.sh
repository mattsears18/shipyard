#!/usr/bin/env bash
# dx-project-roots.sh — list the PROJECT ROOTS of an audited repo, so
# `shipyard:dx-catalog`'s presence probes run against every project in a
# monorepo instead of only the repo root (issue #1593).
#
# Background (issue #1593)
# ------------------------
# Every dx-catalog `Detect` probe was written as a repo-root probe
# (`[ -f tsconfig.json ]`, `ls eslint.config.*`, `[ -f scripts/setup.sh ]`).
# On a non-workspace monorepo — a root `package.json` with no `workspaces`
# field, real projects at `apps/<name>/` — those probes all come back negative
# even though every project carries the tooling one directory down. A
# `/shipyard:audit all` run against mattsears18/lightwork
# (`audit-20260918T223506Z-0c6b`, 2026-09-18) reported `missing-type-checker`,
# `missing-setup-script`, and `missing-linter` against a repo that has all
# three; only the auditor's manual verify-before-file judgment kept them from
# being filed.
#
# What counts as a project root
# -----------------------------
# The repo root (always, printed first as `.`), plus every directory holding a
# stack manifest the catalog's stack detection recognizes — `package.json`,
# `tsconfig.json`, `pyproject.toml`, `requirements.txt`, `go.mod`, `Gemfile` —
# that is either:
#
#   * at most DX_ROOTS_MAX_DEPTH directory levels below the root (default 3,
#     which covers `apps/<name>/` and `packages/<scope>/<name>/`), or
#   * matched by a pattern in the root `package.json`'s `workspaces` field
#     (the array form or the `{ "packages": [...] }` form), at any depth.
#
# Directories under `node_modules/`, `vendor/`, `.git/`, and test-fixture
# trees (`fixtures/`, `__fixtures__/`, `testdata/`) are never project roots —
# a fixture's `package.json` describes a test input, not a project whose
# tooling the audit should demand.
#
# Discovery reads `git ls-files` (tracked files only — so ignored build output
# and installed dependencies can never masquerade as projects) and falls back
# to a bounded `find` when the directory is not a git work tree.
#
# Usage
# -----
#   dx-project-roots.sh [<repo-dir>]
#
# Prints one path per line, relative to <repo-dir> (default: cwd), `.` first,
# the rest sorted and de-duplicated. Exit 0 on success; exit 64 on a usage
# error (a non-directory argument), printing `USAGE_ERROR: ...` on stdout.

set -u

MAX_DEPTH="${DX_ROOTS_MAX_DEPTH:-3}"
case "$MAX_DEPTH" in
  ''|*[!0-9]*) MAX_DEPTH=3 ;;
esac

if [ "$#" -gt 1 ]; then
  echo "USAGE_ERROR: expected at most one argument (<repo-dir>), got $#"
  exit 64
fi

target="${1:-.}"
if [ ! -d "$target" ]; then
  echo "USAGE_ERROR: not a directory: $target"
  exit 64
fi
cd "$target" || { echo "USAGE_ERROR: cannot enter directory: $target"; exit 64; }

# --- 1. Enumerate candidate manifest files ----------------------------------
list_files() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files -- . 2>/dev/null
  else
    find . -type f \
      \( -name node_modules -o -name .git -o -name vendor \) -prune -o -type f -print 2>/dev/null \
      | sed 's|^\./||'
  fi
}

is_manifest() {
  case "${1##*/}" in
    package.json|tsconfig.json|pyproject.toml|requirements.txt|go.mod|Gemfile) return 0 ;;
  esac
  return 1
}

is_excluded_dir() {
  case "/$1/" in
    */node_modules/*|*/vendor/*|*/.git/*|*/fixtures/*|*/__fixtures__/*|*/testdata/*) return 0 ;;
  esac
  return 1
}

dir_depth() {
  # Number of path components in a relative directory path.
  local d="$1" slashes
  slashes="${d//[!\/]/}"
  echo $(( ${#slashes} + 1 ))
}

# --- 2. Workspace patterns from the root package.json -----------------------
workspace_patterns=""
if [ -f package.json ] && command -v jq >/dev/null 2>&1; then
  workspace_patterns=$(jq -r '
    (.workspaces // empty)
    | if type == "array" then .[]
      elif type == "object" then (.packages // [])[]
      else empty end
    | select(type == "string")
  ' package.json 2>/dev/null | sed -e 's|^\./||' -e 's|/*$||')
fi

matches_workspace() {
  local dir="$1" pat
  [ -n "$workspace_patterns" ] || return 1
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    # Negated workspace entries (`!packages/private`) exclude, they never add.
    case "$pat" in '!'*) continue ;; esac
    # shellcheck disable=SC2053  # $pat is intentionally a glob pattern
    if [[ "$dir" == $pat ]]; then
      return 0
    fi
  done <<EOF
$workspace_patterns
EOF
  return 1
}

# --- 3. Collect roots --------------------------------------------------------
roots=""
while IFS= read -r file; do
  [ -n "$file" ] || continue
  is_manifest "$file" || continue
  case "$file" in
    */*) dir="${file%/*}" ;;
    *) continue ;;   # a root-level manifest — the root is always printed
  esac
  is_excluded_dir "$dir" && continue
  if [ "$(dir_depth "$dir")" -le "$MAX_DEPTH" ] || matches_workspace "$dir"; then
    roots="${roots}${dir}
"
  fi
done <<EOF
$(list_files)
EOF

echo "."
if [ -n "$roots" ]; then
  printf '%s' "$roots" | LC_ALL=C sort -u
fi
exit 0
