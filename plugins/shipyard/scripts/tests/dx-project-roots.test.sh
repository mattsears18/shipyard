#!/usr/bin/env bash
# Test suite for scripts/dx-project-roots.sh (issue #1593).
#
# The dx-catalog's presence probes used to run at the repo root only, so on a
# non-workspace monorepo (projects at apps/<name>/, no `workspaces` field) they
# reported linter / type-checker / setup-script as missing when every project
# had them one directory down. dx-project-roots.sh enumerates the project roots
# the catalog now runs its probes against. These fixtures reproduce the
# lightwork repo shape from #1593's repro, plus the workspace, depth-bound,
# exclusion, and non-git fallback cases.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/dx-project-roots.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../dx-project-roots.sh"

if [[ ! -f "$helper" ]]; then
  echo "FAIL: helper not found at $helper" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_equals() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    ok "$label"
  else
    bad "$label"
    printf '    expected: %s\n' "$(printf '%s' "$expected" | tr '\n' ' ')"
    printf '    actual:   %s\n' "$(printf '%s' "$actual" | tr '\n' ' ')"
  fi
}

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

# make_repo <name> <file>... — a git repo with each named file committed.
make_repo() {
  local name="$1"; shift
  local dir="$tmp_root/$name" f
  mkdir -p "$dir"
  for f in "$@"; do
    mkdir -p "$dir/$(dirname "$f")"
    printf '{}\n' > "$dir/$f"
  done
  git -C "$dir" init -q -b main
  git -C "$dir" -c user.email=t@t -c user.name=t add -A
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q -m init
  printf '%s' "$dir"
}

echo "dx-project-roots: monorepo project-root discovery (issue #1593)"
echo

# --- 1. The #1593 repro shape: non-workspace monorepo -----------------------
echo "1. non-workspace monorepo (lightwork shape)"
repo=$(make_repo lightwork \
  package.json \
  apps/lightwork/package.json apps/lightwork/tsconfig.json \
  apps/lightwork/scripts/setup.sh \
  apps/marketing/package.json apps/marketing/tsconfig.json)
assert_equals "$(bash "$helper" "$repo")" ".
apps/lightwork
apps/marketing" "both apps/* projects are roots alongside ."

# --- 2. Single-project repo: just the root ----------------------------------
echo "2. single-project repo"
repo=$(make_repo single package.json tsconfig.json src/index.ts)
assert_equals "$(bash "$helper" "$repo")" "." "only the repo root"

# --- 3. Workspaces are honored beyond the depth bound -----------------------
echo "3. workspaces field"
repo=$(make_repo workspaces package.json libs/a/b/c/pkg/package.json)
printf '{"workspaces":["libs/a/b/c/*"]}\n' > "$repo/package.json"
git -C "$repo" -c user.email=t@t -c user.name=t commit -qam ws
assert_equals "$(bash "$helper" "$repo")" ".
libs/a/b/c/pkg" "workspace member deeper than the depth bound is a root"
printf '{"workspaces":{"packages":["libs/a/b/c/*"]}}\n' > "$repo/package.json"
git -C "$repo" -c user.email=t@t -c user.name=t commit -qam ws2
assert_equals "$(bash "$helper" "$repo")" ".
libs/a/b/c/pkg" "object-form workspaces.packages is honored too"

# --- 4. Depth bound without workspaces ---------------------------------------
echo "4. depth bound"
repo=$(make_repo deep package.json libs/a/b/c/pkg/package.json packages/scope/name/package.json)
assert_equals "$(bash "$helper" "$repo")" ".
packages/scope/name" "depth-3 project kept, depth-5 project dropped"
assert_equals "$(DX_ROOTS_MAX_DEPTH=5 bash "$helper" "$repo")" ".
libs/a/b/c/pkg
packages/scope/name" "DX_ROOTS_MAX_DEPTH widens the bound"

# --- 5. Excluded trees -------------------------------------------------------
echo "5. excluded trees"
repo=$(make_repo excl package.json \
  test/fixtures/app/package.json src/__fixtures__/x/package.json \
  pkg/testdata/package.json vendor/lib/go.mod services/api/go.mod)
assert_equals "$(bash "$helper" "$repo")" ".
services/api" "fixtures/testdata/vendor manifests are not roots; a go.mod project is"

# --- 6. Only tracked files count --------------------------------------------
echo "6. untracked manifests ignored in a git repo"
repo=$(make_repo tracked package.json apps/web/package.json)
mkdir -p "$repo/apps/scratch"; printf '{}\n' > "$repo/apps/scratch/package.json"
assert_equals "$(bash "$helper" "$repo")" ".
apps/web" "untracked apps/scratch is not a root"

# --- 7. Non-git directory falls back to find --------------------------------
echo "7. non-git fallback"
plain="$tmp_root/plain"
mkdir -p "$plain/apps/one" "$plain/node_modules/dep"
printf '{}\n' > "$plain/package.json"
printf '[project]\n' > "$plain/apps/one/pyproject.toml"
printf '{}\n' > "$plain/node_modules/dep/package.json"
assert_equals "$(bash "$helper" "$plain")" ".
apps/one" "find fallback discovers apps/one and skips node_modules"

# --- 8. Usage errors ---------------------------------------------------------
echo "8. usage errors"
out=$(bash "$helper" "$tmp_root/does-not-exist"); rc=$?
assert_equals "$rc" "64" "non-directory argument exits 64"
assert_equals "${out%%:*}" "USAGE_ERROR" "non-directory argument prints USAGE_ERROR"
out=$(bash "$helper" a b); rc=$?
assert_equals "$rc" "64" "two arguments exits 64"

echo
echo "Passed: $pass  Failed: $fail"
[[ "$fail" -eq 0 ]]
