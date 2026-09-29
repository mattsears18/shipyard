#!/usr/bin/env bash
# Test: scripts/co-scope-groups.sh — scope-preflight co-scope grouping
# (issue #1596), plus the spec wiring that makes the orchestrator and the
# issue-work worker actually use it.
#
# Fixtures mirror the issue's own repro (session
# do-work-20260919T014132Z-18851, mattsears18/lightwork): three sibling sets
# from one audit run, one of which (#4892/#4895, same function in sw.js,
# same CACHE_VERSION line) must bundle while the others stay separate.
#
# Pure bash + jq, no network. Run with:
#   bash plugins/shipyard/scripts/tests/co-scope-groups-1596.test.sh

set -u

GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
pass=0
fail=0

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_eq() {
  if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (got: $1 | want: $2)"; fi
}
assert_file_contains() {
  if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3 (missing in $1: $2)"; fi
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_root="$(cd "$here/../.." && pwd)"
script="$plugin_root/scripts/co-scope-groups.sh"

echo "co-scope-groups.sh tests (issue #1596)"
echo

if [[ ! -x "$script" ]]; then
  bad "script exists and is executable ($script)"
  printf '%sFAIL%s  1 test(s) failed (0 passed)\n' "$RED" "$RESET" >&2
  exit 1
fi
ok "script exists and is executable"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------- groups ---
cat > "$tmp/backlog.json" <<'JSON'
[
  {"number": 4892, "body": "SW navigate branch bug\n<!-- audit-key=pwa/sw/nav -->\n<!-- audit-run=audit-20260918T223506Z-0c6b -->"},
  {"number": 4700, "body": "hand-filed, no marker"},
  {"number": 4893, "body": "<!-- audit-run=audit-20260918T223506Z-0c6b --> manifest icon"},
  {"number": 4895, "body": "second sw.js bug <!-- audit-run=audit-20260918T223506Z-0c6b -->"},
  {"number": 5001, "body": "<!-- audit-run=audit-OTHER --> lone sibling"},
  {"number": 5002, "body": "no body key"},
  {"number": 5003}
]
JSON

out="$("$script" groups "$tmp/backlog.json")"
assert_eq "$(jq -c . <<<"$out")" \
  '[{"key":"audit-run","value":"audit-20260918T223506Z-0c6b","issues":[4892,4893,4895]}]' \
  "groups: issues sharing an audit-run marker form one set, rank order kept; singletons and unmarked issues are excluded"

out="$("$script" groups < "$tmp/backlog.json")"
assert_eq "$(jq -r '.[0].issues | join(",")' <<<"$out")" "4892,4893,4895" \
  "groups: reads stdin when no FILE is given"

out="$("$script" groups --max 2 "$tmp/backlog.json")"
assert_eq "$(jq -c '[.[].issues]' <<<"$out")" '[[4892,4893]]' \
  "groups --max 2: an oversized set is chunked in rank order and a trailing chunk of one is dropped"

cat > "$tmp/multi.json" <<'JSON'
[
  {"number": 1, "body": "<!-- audit-run=r1 --> <!-- batch=b1 -->"},
  {"number": 2, "body": "<!-- batch=b1 -->"},
  {"number": 3, "body": "<!-- audit-run=r1 -->"},
  {"number": 4, "body": "<!-- batch=b1 -->"}
]
JSON
out="$("$script" groups --key audit-run --key batch "$tmp/multi.json")"
assert_eq "$(jq -c '[.[] | {key, issues}]' <<<"$out")" \
  '[{"key":"audit-run","issues":[1,3]},{"key":"batch","issues":[2,4]}]' \
  "groups: an issue carrying several markers joins only the first --key's set (never two groups)"

out="$("$script" groups --key batch "$tmp/multi.json")"
assert_eq "$(jq -c '[.[].issues]' <<<"$out")" '[[1,2,4]]' \
  "groups --key batch: a configured non-default key is honored"

out="$("$script" groups <<<'[]')"
assert_eq "$out" "[]" "groups: empty backlog yields []"

"$script" groups <<<'not json' >/dev/null 2>&1
assert_eq "$?" "65" "groups: unparseable input exits 65 (caller scopes individually)"

"$script" groups --key 'Bad Key' <<<'[]' >/dev/null 2>&1
assert_eq "$?" "64" "groups: an invalid --key name is a usage error"

"$script" bogus >/dev/null 2>&1
assert_eq "$?" "64" "unknown subcommand is a usage error"

# -------------------------------------------------------------- validate ---
# The lightwork partial case: #4892 + #4895 share sw.js; #4893 is disjoint.
partial='{
  "group_key": "audit-run=audit-20260918T223506Z-0c6b",
  "members": [4892, 4893, 4895],
  "grouping": "partial",
  "grouping_rationale": "both edit the navigate branch of public/sw.js and both bump CACHE_VERSION",
  "primary_issue": 4892,
  "bundled_issues": [4892, 4895],
  "shared_surface": "public/sw.js:12",
  "entries": [
    {"issue": 4892, "files": ["public/sw.js"], "lockfile_sections": []},
    {"issue": 4893, "files": ["public/manifest.json"], "lockfile_sections": []},
    {"issue": 4895, "files": ["public/sw.js", "lib/offline.ts"], "lockfile_sections": []}
  ]
}'
assert_eq "$("$script" validate <<<"$partial")" \
  "verdict=bundle primary=4892 issues=4892,4895 reason=shared-surface" \
  "validate: a justified partial bundle stands (shared_surface :line suffix stripped before matching files)"

v() { jq -c "$1" <<<"$partial" | "$script" validate; }

assert_eq "$(v '.grouping = "separate"')" \
  "verdict=separate primary= issues= reason=grouping-separate" \
  "validate: separate stays separate"
assert_eq "$(v '.grouping = "merge-them"')" \
  "verdict=separate primary= issues= reason=invalid-grouping" \
  "validate: an unknown grouping value falls back to separate"
assert_eq "$(v '.grouping = "one-pr"')" \
  "verdict=separate primary= issues= reason=grouping-mismatch" \
  "validate: one-pr whose bundle is not every member falls back to separate"
assert_eq "$(v '.bundled_issues = [4892,4893,4895]')" \
  "verdict=separate primary= issues= reason=grouping-mismatch" \
  "validate: partial whose bundle is every member falls back to separate"
assert_eq "$(v '.shared_surface = "lib/route-metadata.ts"')" \
  "verdict=separate primary= issues= reason=shared-surface-not-in-files" \
  "validate: a shared_surface absent from a bundled issue's files falls back to separate (no scope widening)"
assert_eq "$(v 'del(.shared_surface)')" \
  "verdict=separate primary= issues= reason=missing-shared-surface" \
  "validate: a bundle with no shared_surface justification falls back to separate"
assert_eq "$(v '.entries[2] = {"issue": 4895, "deferred": "x", "defer_reason_class": "human-decision-required", "evidence_pointer": "y"}')" \
  "verdict=separate primary= issues= reason=bundled-issue-not-ready:4895" \
  "validate: a bundled issue whose own entry is not ready falls back to separate"
assert_eq "$(v '.primary_issue = 4893')" \
  "verdict=separate primary= issues= reason=primary-not-in-bundle" \
  "validate: a primary_issue outside the bundle falls back to separate"
assert_eq "$(v '.bundled_issues = [4892, 9999]')" \
  "verdict=separate primary= issues= reason=bundled-issue-not-a-member" \
  "validate: a bundled issue outside the co-scope set falls back to separate"
assert_eq "$(v '.bundled_issues = [4892]')" \
  "verdict=separate primary= issues= reason=bundle-too-small" \
  "validate: a one-issue bundle falls back to separate"

one_pr="$(jq -c '.members = [4892, 4895] | .grouping = "one-pr" | .entries = [.entries[0], .entries[2]]' <<<"$partial")"
assert_eq "$("$script" validate <<<"$one_pr")" \
  "verdict=bundle primary=4892 issues=4892,4895 reason=shared-surface" \
  "validate: a justified one-pr bundle over the whole set stands"

assert_eq "$("$script" validate <<<'garbage')" \
  "verdict=separate primary= issues= reason=unparseable" \
  "validate: unparseable input fails safe to separate (exit 0)"

# ------------------------------------------------------------ spec wiring ---
setup_dir="$plugin_root/commands/do-work/setup"
frag="$setup_dir/06h-co-scope-grouping.md"
if [[ -f "$frag" ]]; then ok "06h-co-scope-grouping.md fragment exists"; else bad "06h-co-scope-grouping.md fragment exists"; fi
assert_file_contains "$frag" "co-scope-groups.sh\" groups" "06h runs the groups subcommand"
assert_file_contains "$frag" "co-scope-groups.sh\" validate" "06h runs the validate subcommand"
assert_file_contains "$frag" "closingIssuesReferences" "06h verifies closingIssuesReferences lists every bundled issue after ship"
assert_file_contains "$frag" "default stays \`separate\`" "06h states separate is the default"
assert_file_contains "$setup_dir/06-scope-preflight.md" "06h-co-scope-grouping.md" "06-scope-preflight.md points at the co-scope fragment"
assert_file_contains "$plugin_root/commands/do-work/setup.md" "06h-co-scope-grouping.md" "setup.md's routing table has a row for 06h"
assert_file_contains "$setup_dir/06g-scope-staleness-probe.md" "06h-co-scope-grouping.md" "06g's return-shape contract points at the group envelope"
assert_file_contains "$plugin_root/commands/do-work/dispatch-rules.md" "Co-scoped bundle" "dispatch-rules.md carries the co-scoped bundle augmentation"
assert_file_contains "$plugin_root/commands/do-work/steady-state.md" "bundled_issues" "steady-state.md's shipped handler checks bundled_issues"
assert_file_contains "$plugin_root/commands/do-work.md" "bundled_issues" "do-work.md's orchestrator state documents bundled_issues"
assert_file_contains "$plugin_root/agents/issue-worker/issue-work.md" "issue-work-co-scoped-bundle.md" "issue-work.md points at the bundle fragment"
wfrag="$plugin_root/agents/issue-worker/issue-work-co-scoped-bundle.md"
assert_file_contains "$wfrag" "Closes #" "worker bundle fragment requires a closing line per bundled issue"
assert_file_contains "$wfrag" "§5.8" "worker bundle fragment runs §5.8 per bundled issue"
assert_file_contains "$plugin_root/scripts/shipyard-config.sh" '"co_scope_keys": ["audit-run"]' "shipyard-config.sh default carries scope.co_scope_keys"
assert_file_contains "$plugin_root/schemas/shipyard.config.schema.json" '"co_scope_keys"' "schema defines scope.co_scope_keys"

echo
if [[ "$fail" -gt 0 ]]; then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
fi
printf '%sPASS%s  all %d tests passed\n' "$GREEN" "$RESET" "$pass"
