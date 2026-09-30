#!/usr/bin/env bash
# Test: every documented `gh api` REST call that passes a field (-f / -F /
# --field / --raw-field) also names its method explicitly (-X / --method).
# Issue #1652.
#
# `gh api` silently switches its default method from GET to POST the moment
# any field is supplied. shipyard:update-roadmap's documented milestone
# fetch (`gh api repos/<o>/<r>/milestones --paginate -f state=all`) was
# therefore a POST to "create a milestone", not a list call — it only
# failed (422) by accident, and its cold-start branch could misread that
# error as "zero milestones". A spec author reading "-f state=all" as a
# query parameter is the natural mistake, so this suite pins the rule
# mechanically across every agent-read markdown surface.
#
# Scope: plugins/shipyard/{skills,commands,agents}/**/*.md — the specs an
# agent copies commands out of verbatim. `gh api graphql` is exempt (GraphQL
# is always POST, and -f query=... is its normal shape).
#
# The scanner is self-tested against fixtures first (a known-bad call must
# be flagged, known-good calls must not) so a scanner that silently matches
# nothing can't report a vacuous pass.
#
# Pure bash + grep/awk — no network, no `gh`.
#
# Run with:
#   plugins/shipyard/scripts/tests/gh-api-field-method.test.sh

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

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

# scan_file <path> — prints "<path>:<line>: <gh api ...>" for every gh api
# REST call that passes a field without an explicit method. Backslash line
# continuations are joined so a multi-line fenced call is scanned whole.
scan_file() {
  awk -v file="$1" '
    function check(text, lineno,    rest, seg, i) {
      rest = text
      while ((i = index(rest, "gh api")) > 0) {
        seg = substr(rest, i)
        rest = substr(rest, i + 6)
        # The call ends at the first backtick, pipe, semicolon, &&, or $( close.
        sub(/[`|;].*$/, "", seg)
        sub(/&&.*$/, "", seg)
        if (seg ~ /^gh api[ \t]+graphql([ \t]|$)/) continue
        if (seg !~ /[ \t](-f|-F|--field|--raw-field)([ \t=]|$)/) continue
        if (seg ~ /[ \t](-X|--method)([ \t=]|$)/ || seg ~ /[ \t]-X[A-Z]/) continue
        printf "%s:%d: %s\n", file, lineno, seg
      }
    }
    {
      line = $0
      if (buf == "") start = NR
      if (line ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, " ", line); buf = buf line; next }
      buf = buf line
      check(buf, start)
      buf = ""
    }
    END { if (buf != "") check(buf, start) }
  ' "$1"
}

echo "== scanner self-test (fixtures) =="
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gh-api-field-method.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/bad-inline.md" <<'EOF'
Fetch all milestones (`gh api repos/<owner>/<repo>/milestones --paginate -f state=all --jq '.[]'`).
EOF
cat > "$tmp/bad-fenced.md" <<'EOF'
```bash
gh api repos/o/r/issues \
  --paginate \
  -F per_page=100
```
EOF
cat > "$tmp/good.md" <<'EOF'
Fetch (`gh api -X GET repos/o/r/milestones --paginate -f state=all`).
Patch (`gh api repos/o/r/milestones/3 -X PATCH -f description="x"`).
Create (`gh api --method POST repos/o/r/labels -f name=x`).
GraphQL (`gh api graphql -f query='{ viewer { login } }'`).
No fields (`gh api repos/o/r/milestones --jq '.[] | select(.state == "open")'`).
```bash
gh api graphql \
  -f query="$q" -F num=3
```
EOF

if [[ -n "$(scan_file "$tmp/bad-inline.md")" ]]; then
  ok "flags an inline gh api call with -f and no -X"
else
  bad "did NOT flag an inline gh api call with -f and no -X"
fi
if [[ -n "$(scan_file "$tmp/bad-fenced.md")" ]]; then
  ok "flags a backslash-continued fenced gh api call with -F and no -X"
else
  bad "did NOT flag a backslash-continued fenced gh api call with -F and no -X"
fi
good_out="$(scan_file "$tmp/good.md")"
if [[ -z "$good_out" ]]; then
  ok "does not flag -X GET / -X PATCH / --method POST / graphql / field-less calls"
else
  bad "false positive on known-good calls: $good_out"
fi

echo "== live scan: plugins/shipyard/{skills,commands,agents} =="
scanned=0
violations=""
while IFS= read -r f; do
  scanned=$((scanned+1))
  out="$(scan_file "$f")"
  if [[ -n "$out" ]]; then
    violations+="$out"$'\n'
  fi
done < <(find "$repo_root/plugins/shipyard/skills" "$repo_root/plugins/shipyard/commands" "$repo_root/plugins/shipyard/agents" -type f -name '*.md' | sort)

if [[ $scanned -gt 0 ]]; then
  ok "scanned $scanned markdown files"
else
  bad "scanned zero markdown files — scan roots moved?"
fi
if [[ -z "$violations" ]]; then
  ok "no gh api REST call passes -f/-F without an explicit -X/--method"
else
  bad "gh api calls pass a field without -X/--method (gh defaults these to POST — add -X GET for a read):"
  printf '%s' "$violations" | sed 's/^/        /'
fi

# The update-roadmap skill specifically: its milestone list fetch must be an
# explicit GET, and its cold-start branch must not treat an error as empty.
skill="$repo_root/plugins/shipyard/skills/update-roadmap/SKILL.md"
if [[ "$(grep -c 'gh api -X GET repos/<owner>/<repo>/milestones' "$skill")" -ge 2 ]]; then
  ok "update-roadmap: both milestone fetch sites use -X GET"
else
  bad "update-roadmap: expected both milestone fetch sites to use -X GET"
fi
if grep -qF 'An error is not an empty list' "$skill"; then
  ok "update-roadmap: cold start refuses to read an error as zero milestones"
else
  bad "update-roadmap: missing the error-is-not-empty cold-start guard"
fi

echo
total=$((pass + fail))
if [[ $fail -eq 0 ]]; then
  printf '%sPASS%s  %d/%d assertions passed\n' "$GREEN" "$RESET" "$pass" "$total"
  exit 0
else
  printf '%sFAIL%s  %d/%d assertions failed\n' "$RED" "$RESET" "$fail" "$total"
  exit 1
fi
