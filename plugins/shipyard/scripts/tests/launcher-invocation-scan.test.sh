#!/usr/bin/env bash
# Test: no ```bash fenced block in the spec corpus invokes a script through
# the `bash` / `sh` launcher with a path the isolation guard cannot
# statically resolve (issue #1566).
#
# Background — issue #1566. Post-`EnterWorktree`, Claude Code's
# worktree-isolation guard refuses a command that hands a launcher a script
# path it cannot resolve:
#
#   This session is isolated in the worktree ..., but this command runs bash
#   in a plain command; what it reads or is handed as shell text cannot be
#   shown not to run git. Refusing to run it
#
# BOTH halves are required, measured live one variable at a time (full
# observation table in do-work-RATIONALE.md § "The #1566 launcher
# measurement"):
#
#   bash <spelled-out-literal>/scripts/x.sh --help       RUNS
#   plugins/shipyard/scripts/x.sh --help                 RUNS
#   "$CLAUDE_PLUGIN_ROOT/scripts/x.sh" get a.b           RUNS
#   echo "$CLAUDE_PLUGIN_ROOT/scripts/x.sh"              RUNS
#   bash "$CLAUDE_PLUGIN_ROOT/scripts/x.sh" get a.b      REFUSED
#
# So this is NOT the #1474 whole-word rule — the literal suffix still
# rescues the word everywhere else. What is refused is specifically the
# launcher in front of an expansion. Direct exec is immune to both halves,
# which is why the sweep targets the launcher rather than substituting
# literals (the remedy four prior sweeps applied and watched re-accumulate).
#
# Direct exec is unconditionally safe for shipped scripts: every production
# script under plugins/shipyard/scripts/ carries a `#!` shebang at committed
# mode 100755, enforced by script-exec-bits.test.sh.
#
# SCOPE — why this scans ```bash fences only, repo-wide, rather than joining
# compound-block-scan.sh's curated FILES list. The shape is unambiguous
# wherever it appears in an executable block, so it needs no per-file
# judgment about pre- vs post-relocation. But it MUST NOT look at prose:
# dont.md's worked-example table, do-work-RATIONALE.md's historical #1474
# observation rows, and several fragments all quote the refused form on
# purpose, as inline code or inside a plain (non-`bash`) fence. Restricting
# the scan to ```bash fences is what lets this be a repo-wide guard with no
# allowlist to drift.
#
# Pure bash + awk + git. Run with:
#
#   bash plugins/shipyard/scripts/tests/launcher-invocation-scan.test.sh

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../../../.." && pwd)"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_equals() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected: %s\n' "$expected"
    printf '    actual:   %s\n' "$actual"
    fail=$((fail+1))
  fi
}

# _scan <file>... — prints "<file>:<line>: <text>" for every launcher
# invocation found inside a ```bash fence. Silent when clean.
_scan() {
  awk '
    FNR == 1 { in_block = 0 }

    /^[[:space:]]*```bash[[:space:]]*$/ { in_block = 1; next }
    /^[[:space:]]*```[[:space:]]*$/     { in_block = 0; next }

    in_block {
      line = $0
      # Strip `#` comments: this corpus writes prose in bash comments and
      # some of it legitimately names the refused form.
      sub(/#.*$/, "", line)
      # A launcher (bash/sh) whose next word begins with an expansion, or
      # whose next word is a quote immediately followed by one. The leading
      # class keeps `--foo-bash`, `nodebash`, and the like from matching,
      # while allowing the launcher to open the line or sit after `$(`,
      # `|`, `&&`, `!` etc.
      if (line ~ /(^|[^-A-Za-z0-9_.\/])(bash|sh)[[:space:]]+["'"'"']?\$/) {
        printf "%s:%d: %s\n", FILENAME, FNR, $0
      }
    }
  ' "$@"
}

echo "== launcher invocation scan — no \`bash \"\$VAR/...\"\` in bash fences (#1566)"

cd "$repo_root" || { echo "FAIL: cannot cd to repo root" >&2; exit 1; }

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "SKIP: not a git work tree"
  exit 0
fi

# --- Self-test: the scanner actually detects the shape it targets --------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/bad.md" <<'FIXTURE'
Prose mentioning `bash "$CLAUDE_PLUGIN_ROOT/scripts/x.sh"` must NOT match.

```
bash "$CLAUDE_PLUGIN_ROOT/scripts/x.sh" --flag
```

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/x.sh" --flag
```
FIXTURE

bad_hits="$(_scan "$tmp/bad.md" | wc -l | tr -d ' ')"
assert_equals "$bad_hits" "1" "detects the launcher form inside a bash fence only (not prose, not a plain fence)"

cat > "$tmp/good.md" <<'FIXTURE'
```bash
"$CLAUDE_PLUGIN_ROOT/scripts/x.sh" --flag
VERDICT=$("$CLAUDE_PLUGIN_ROOT/scripts/x.sh" run)
bash plugins/shipyard/scripts/x.sh --help
bash /abs/literal/path/scripts/x.sh --help
chmod +x "$WORKTREE_PATH/.shipyard-scratch/helper.sh"
# bash "$CLAUDE_PLUGIN_ROOT/scripts/x.sh" is refused — see #1566
```
FIXTURE

good_hits="$(_scan "$tmp/good.md" | wc -l | tr -d ' ')"
assert_equals "$good_hits" "0" "accepts direct exec, literal-path launchers, and commented mentions"

# --- The real sweep -----------------------------------------------------
# Portable discovery: `mapfile` is bash 4+, and macOS ships bash 3.2, so a
# read loop is used instead. A `mapfile: command not found` there would
# otherwise leave md_files unset and the whole sweep silently skipped while
# the suite still reported PASS — the vacuous-pass shape this file guards
# against elsewhere.
md_files=()
while IFS= read -r f; do
  [[ -n "$f" ]] && md_files+=("$f")
done < <(git ls-files -- '*.md' | grep '^plugins/')

if [[ ${#md_files[@]} -eq 0 ]]; then
  echo "  ${RED}FAIL${RESET}  discovery found no markdown under plugins/"
  fail=$((fail+1))
else
  findings="$(_scan "${md_files[@]}")"
  found_count="$(printf '%s' "$findings" | grep -c . || true)"
  if [[ "$found_count" != "0" ]]; then
    printf '  %sFAIL%s  %d launcher invocation(s) found in ```bash fences\n' \
      "$RED" "$RESET" "$found_count"
    printf '%s\n' "$findings" | sed 's/^/        /'
    # shellcheck disable=SC2016  # literal advice text — must NOT expand
    printf '    Use direct exec instead: "$CLAUDE_PLUGIN_ROOT/scripts/<name>.sh" --flag\n'
    printf '    See commands/do-work/dont.md § "The launcher rule (#1566)".\n'
    fail=$((fail+1))
  else
    printf '  %sPASS%s  %d markdown file(s) free of the launcher shape\n' \
      "$GREEN" "$RESET" "${#md_files[@]}"
    pass=$((pass+1))
  fi

  # Floor guard: a scan that walked nothing is indistinguishable from a
  # scan that found nothing (the vacuous-pass failure mode, #1312).
  if [[ ${#md_files[@]} -lt 100 ]]; then
    printf '  %sFAIL%s  discovery walked only %d file(s) — below the 100 floor\n' \
      "$RED" "$RESET" "${#md_files[@]}"
    fail=$((fail+1))
  else
    assert_equals "ok" "ok" "discovery floor met (${#md_files[@]} files >= 100)"
  fi
fi

echo
if [[ "$fail" -gt 0 ]]; then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass"
  exit 1
fi
printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
exit 0
