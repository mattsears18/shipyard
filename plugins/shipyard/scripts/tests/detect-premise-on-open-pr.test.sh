#!/usr/bin/env bash
# Test suite for scripts/detect-premise-on-open-pr.sh (issue #1602) — does an
# issue's body name a path/symbol that is absent on the default branch but
# present on an open PR's branch?
#
# Covers:
#   usage / arg validation     — missing --repo, missing body source, bad cap
#   indeterminate              — unresolvable base ref exits 2, never "clear"
#   clear: everything present  — tokens that exist on base are never hits
#   path hit                   — a full path only an open PR adds
#   basename hit               — a bare `file.js` only an open PR adds
#   symbol hit                 — a camelCase / SCREAMING_CASE symbol only on
#                                an open PR's added lines
#   removed-line is not a hit  — a symbol on a `-` diff line doesn't count
#   --exclude-pr               — the excluded PR's hits are dropped
#   noise filtering            — plain words, commands, globs, URLs skipped
#   absent everywhere          — stale token -> clear with absent>0
#   --max-diff-prs cap         — truncated=1 when the cap is hit
#
# `gh` is mocked via $GH; git runs against a throwaway repo, so the suite
# needs no network. Run with:
#   bash plugins/shipyard/scripts/tests/detect-premise-on-open-pr.test.sh

# shellcheck disable=SC2016  # issue-body fixtures contain literal markdown backticks
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../detect-premise-on-open-pr.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; shift; for l in "$@"; do printf '    %s\n' "$l"; done; fail=$((fail+1)); }

assert_contains() {
  if [[ "$1" == *"$2"* ]]; then ok "$3"; else bad "$3" "expected to contain: $2" "actual: $1"; fi
}
assert_not_contains() {
  if [[ "$1" != *"$2"* ]]; then ok "$3"; else bad "$3" "expected NOT to contain: $2" "actual: $1"; fi
}
assert_exit() {
  if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3" "exit $1, want $2"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- A throwaway repo whose `main` is the "default branch". ---
REPO="$WORK/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
mkdir -p "$REPO/src/lib" "$REPO/__tests__"
printf 'export const existingHelper = 1;\nconst MAX_RETRIES = 3;\n' > "$REPO/src/lib/present.js"
printf 'test("x", () => {});\n' > "$REPO/__tests__/strings.test.ts"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m init

# --- Mock gh. Open PRs: 101 adds src/lib/new-cache.js + contentMaxWidth;
#     102 adds ALLOWED_NESTED_DUPLICATES and removes oldThing;
#     103 touches only an existing file. ---
cat > "$WORK/prs.json" <<'JSON'
[
  {"number": 101, "files": [{"path": "src/lib/new-cache.js"}, {"path": "src/lib/present.js"}]},
  {"number": 102, "files": [{"path": "__tests__/strings.test.ts"}]},
  {"number": 103, "files": [{"path": "src/lib/present.js"}]}
]
JSON
cat > "$WORK/diff.101" <<'DIFF'
diff --git a/src/lib/new-cache.js b/src/lib/new-cache.js
+++ b/src/lib/new-cache.js
+export const CACHE_CONTROL = "max-age=60";
+export function header({ contentMaxWidth }) {}
DIFF
cat > "$WORK/diff.102" <<'DIFF'
diff --git a/__tests__/strings.test.ts b/__tests__/strings.test.ts
+++ b/__tests__/strings.test.ts
+const ALLOWED_NESTED_DUPLICATES = ["a"];
-const oldThing = 1;
DIFF
printf '' > "$WORK/diff.103"

cat > "$WORK/gh" <<MOCK
#!/usr/bin/env bash
work="${WORK}"
if [ "\$1 \$2" = "pr list" ]; then cat "\$work/prs.json"; exit 0; fi
if [ "\$1 \$2" = "pr diff" ]; then echo "\$3" >> "\$work/diff-calls"; cat "\$work/diff.\$3" 2>/dev/null; exit 0; fi
if [ "\$1 \$2" = "issue view" ]; then cat "\$work/issue.\$3.body"; exit 0; fi
exit 1
MOCK
chmod +x "$WORK/gh"

run() { (cd "$REPO" && GH="$WORK/gh" bash "$script" --repo o/r --base main "$@" 2>&1); }
body() { printf '%s\n' "$1" > "$WORK/body.md"; }

echo "detect-premise-on-open-pr.sh test suite"
echo "======================================="

echo; echo "usage / arg validation"
out="$(bash "$script" --issue 1 2>&1)"; rc=$?
assert_exit "$rc" 64 "missing --repo exits 64"
out="$(bash "$script" --repo o/r 2>&1)"; rc=$?
assert_exit "$rc" 64 "missing --issue/--body-file exits 64"
body "x"
out="$(run --body-file "$WORK/body.md" --max-diff-prs abc)"; rc=$?
assert_exit "$rc" 64 "non-integer --max-diff-prs exits 64"

echo; echo "indeterminate: unresolvable base ref"
out="$(cd "$REPO" && GH="$WORK/gh" bash "$script" --repo o/r --base origin/nope --body-file "$WORK/body.md" 2>&1)"; rc=$?
assert_exit "$rc" 2 "unresolvable base exits 2"
assert_contains "$out" "verdict=indeterminate reason=base-ref-unresolved" "unresolvable base reports indeterminate, not clear"

echo; echo "clear: every named token already exists on base"
body 'Fix `src/lib/present.js`, reuse `existingHelper` and `MAX_RETRIES`, see `strings.test.ts`.'
out="$(run --body-file "$WORK/body.md")"; rc=$?
assert_exit "$rc" 0 "clear exits 0"
assert_contains "$out" "verdict=clear checked=4 absent=0" "all-present body is clear with absent=0"
assert_not_contains "$out" "hit " "no hits when nothing is absent"

echo; echo "path hit: a full path only an open PR adds"
body 'Reuse the constant in `src/lib/new-cache.js`.'
out="$(run --body-file "$WORK/body.md")"
assert_contains "$out" "hit pr=101 kind=path token=src/lib/new-cache.js" "full path found on PR 101"
assert_contains "$out" "verdict=premise-on-open-pr prs=101" "verdict names PR 101"

echo; echo "basename hit: a bare file name only an open PR adds"
body 'Reuse the constant in `new-cache.js`.'
out="$(run --body-file "$WORK/body.md")"
assert_contains "$out" "hit pr=101 kind=path token=new-cache.js" "basename found on PR 101"

echo; echo "symbol hits: camelCase and SCREAMING_CASE on added lines"
body 'Remove the `ALLOWED_NESTED_DUPLICATES` entry; the `contentMaxWidth` prop must default to null.'
out="$(run --body-file "$WORK/body.md")"
assert_contains "$out" "hit pr=102 kind=symbol token=ALLOWED_NESTED_DUPLICATES" "SCREAMING_CASE symbol found on PR 102"
assert_contains "$out" "hit pr=101 kind=symbol token=contentMaxWidth" "camelCase symbol found on PR 101"
assert_contains "$out" "verdict=premise-on-open-pr prs=101,102" "verdict lists both PRs, sorted"

echo; echo "a symbol only on a removed (-) line is not a hit"
body 'Drop `oldThing` everywhere.'
out="$(run --body-file "$WORK/body.md")"
assert_contains "$out" "verdict=clear checked=1 absent=1" "removed-line symbol is absent, not a hit"

echo; echo "--exclude-pr drops that PR's hits"
body 'Reuse `src/lib/new-cache.js` and `ALLOWED_NESTED_DUPLICATES`.'
out="$(run --body-file "$WORK/body.md" --exclude-pr 101)"
assert_not_contains "$out" "pr=101" "excluded PR 101 never reported"
assert_contains "$out" "verdict=premise-on-open-pr prs=102" "remaining PR 102 still reported"

echo; echo "noise filtering: words, commands, globs, URLs are not checked"
body 'Run `gh pr list`, keep `shipyard`, glob `app/**`, see `https://example.com/a/b`, flag `--no-verify`, ref `#123`, `true`.'
out="$(run --body-file "$WORK/body.md")"
assert_contains "$out" "verdict=clear checked=0 absent=0" "no noise token is checked"

echo; echo "absent everywhere: a stale token is clear, with absent>0"
body 'Edit `src/lib/gone.js` and `neverDefinedAnywhere`.'
out="$(run --body-file "$WORK/body.md")"
assert_contains "$out" "verdict=clear checked=2 absent=2" "stale tokens are counted absent, no PR hit"

echo; echo "--max-diff-prs caps gh pr diff calls"
rm -f "$WORK/diff-calls"
body 'Use `contentMaxWidth`.'
out="$(run --body-file "$WORK/body.md" --max-diff-prs 1)"
assert_contains "$out" "hit pr=101 kind=symbol token=contentMaxWidth" "first PR within the cap is still scanned"
assert_contains "$out" "truncated=1" "hitting the cap reports truncated=1"
calls="$(wc -l < "$WORK/diff-calls" | tr -d ' ')"
assert_exit "$calls" 1 "exactly one gh pr diff call under --max-diff-prs 1"

echo; echo "no absent symbols -> no gh pr diff calls at all"
rm -f "$WORK/diff-calls"
body 'Reuse `src/lib/new-cache.js`.'
out="$(run --body-file "$WORK/body.md")"
if [[ -e "$WORK/diff-calls" ]]; then bad "path-only lookup made gh pr diff calls"; else ok "path-only lookup makes no gh pr diff calls"; fi

echo; echo "--issue reads the body through gh"
printf 'Reuse `src/lib/new-cache.js`.\n' > "$WORK/issue.7.body"
out="$(run --issue 7)"
assert_contains "$out" "verdict=premise-on-open-pr prs=101" "--issue path fetches the body and detects the hit"

echo
echo "Results: ${GREEN}${pass} passed${RESET}, ${RED}${fail} failed${RESET}"
[[ $fail -eq 0 ]]
