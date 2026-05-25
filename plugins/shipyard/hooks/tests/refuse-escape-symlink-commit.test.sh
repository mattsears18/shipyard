#!/usr/bin/env bash
# Test suite for hooks/refuse-escape-symlink-commit.sh.
#
# Run with:
#   bash plugins/shipyard/hooks/tests/refuse-escape-symlink-commit.test.sh
#
# Each test crafts a PreToolUse JSON payload for a Bash tool call, sets up a
# fixture git repo with (or without) a staged escape-symlink, pipes the payload
# to the hook, and asserts on stderr + exit code. Exit 2 == blocked, exit 0 ==
# allowed (transparent).
#
# The hook decides whether a `git commit` Bash call should be blocked because
# the staged file set contains a symlink whose target escapes the worktree
# (absolute path, or contains `..` segments). See plugins/shipyard/hooks/
# refuse-escape-symlink-commit.sh for the decision rules and #351 for the
# motivation (worker-bootstrap node_modules symlinks getting cherry-picked
# into landed commits).

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="${here}/../refuse-escape-symlink-commit.sh"

if [[ ! -f "$hook" ]]; then
  echo "FAIL: hook not found at $hook" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

# Each test creates a fresh git repo in $TMP and stages whatever it needs.
TMP=$(mktemp -d -t shipyard-escape-symlink-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# Helper — invoke hook with payload on stdin.
# Returns: "<exit_code>::<stderr>"
run_hook() {
  local payload="$1"
  local stderr exit_code
  stderr=$(printf '%s' "$payload" | bash "$hook" 2>&1 >/dev/null)
  exit_code=$?
  printf '%s::%s' "$exit_code" "$stderr"
}

assert_exit() {
  local result="$1"
  local want="$2"
  local label="$3"
  local got="${result%%::*}"
  if [[ "$got" == "$want" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (want exit %s, got %s)\n' "$RED" "$RESET" "$label" "$want" "$got"
    printf '    stderr: %s\n' "${result#*::}"
    fail=$((fail+1))
  fi
}

assert_blocked_with() {
  local result="$1"
  local needle="$2"
  local label="$3"
  local got="${result%%::*}"
  local stderr="${result#*::}"
  if [[ "$got" == "2" && "$stderr" == *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    want exit 2 and stderr containing %q\n' "$needle"
    printf '    got exit %s, stderr: %s\n' "$got" "$stderr"
    fail=$((fail+1))
  fi
}

# Build a payload: tool_name, command, cwd.
# Passes args via env to avoid quote-escaping nightmares — the test
# commands include both single and double quotes, escaped newlines, etc.
mkpayload() {
  local tool="$1" cmd="$2" cwd="$3"
  TOOL="$tool" CMD="$cmd" CWD="$cwd" python3 -c '
import json, os
print(json.dumps({
    "tool_name": os.environ["TOOL"],
    "cwd": os.environ["CWD"],
    "tool_input": {"command": os.environ["CMD"]},
}))'
}

# Build a fresh git repo with the given fixture files. Returns the repo path.
# Args after $1 (repo subdir name): pairs of <op> <args> where op is one of:
#   regular <path> <content>            — regular file
#   symlink <path> <target>             — symlink (target is literal, no resolution)
#   stage <path>                        — git add <path>
#   stage-force <path>                  — git add -f <path>
mkrepo() {
  local name="$1"; shift
  local repo="$TMP/$name"
  mkdir -p "$repo"
  ( cd "$repo" && git init -q && git config user.email t@e.com && git config user.name t \
    && git config commit.gpgsign false && git config core.autocrlf input ) >/dev/null
  # Process fixture instructions in order.
  while (( $# > 0 )); do
    local op="$1"; shift
    case "$op" in
      regular)
        local path="$1" content="$2"; shift 2
        mkdir -p "$repo/$(dirname "$path")"
        printf '%s' "$content" > "$repo/$path"
        ;;
      symlink)
        local path="$1" target="$2"; shift 2
        mkdir -p "$repo/$(dirname "$path")"
        ( cd "$repo" && ln -s "$target" "$path" )
        ;;
      stage)
        local path="$1"; shift
        ( cd "$repo" && git add -- "$path" ) >/dev/null 2>&1 || true
        ;;
      stage-force)
        local path="$1"; shift
        ( cd "$repo" && git add -f -- "$path" ) >/dev/null 2>&1
        ;;
      *)
        echo "mkrepo: unknown op '$op'" >&2; return 1 ;;
    esac
  done
  printf '%s' "$repo"
}

# -----------------------------------------------------------------------------
echo "== Non-Bash tools pass through transparently"
# -----------------------------------------------------------------------------

repo=$(mkrepo "noop-1")
out=$(run_hook "$(mkpayload Edit "git commit -m x" "$repo")")
assert_exit "$out" "0" "Edit tool with 'git commit' string → not blocked"

out=$(run_hook "$(mkpayload Read "git commit -m x" "$repo")")
assert_exit "$out" "0" "Read tool → not blocked"

# -----------------------------------------------------------------------------
echo "== Bash calls that aren't a git commit pass through"
# -----------------------------------------------------------------------------

repo=$(mkrepo "noop-2" \
  symlink node_modules ../../../node_modules \
  stage-force node_modules)

# Even with an escape symlink staged, a non-commit bash call is irrelevant.
out=$(run_hook "$(mkpayload Bash "git status" "$repo")")
assert_exit "$out" "0" "git status (no commit) → allowed even with staged escape symlink"

out=$(run_hook "$(mkpayload Bash "ls -la" "$repo")")
assert_exit "$out" "0" "ls -la → allowed"

out=$(run_hook "$(mkpayload Bash "git push -u origin main" "$repo")")
assert_exit "$out" "0" "git push → allowed"

# Boundary check: `git commit-tree` is a different command and must NOT match.
out=$(run_hook "$(mkpayload Bash "git commit-tree HEAD^{tree} -m x" "$repo")")
assert_exit "$out" "0" "git commit-tree → not blocked (not a commit invocation)"

# `commit` as a literal substring elsewhere shouldn't match either.
out=$(run_hook "$(mkpayload Bash "echo committed" "$repo")")
assert_exit "$out" "0" "echo containing 'committed' → not blocked"

out=$(run_hook "$(mkpayload Bash "grep -r 'git commit' docs/" "$repo")")
assert_exit "$out" "0" "grep containing 'git commit' as quoted needle → not blocked"

# -----------------------------------------------------------------------------
echo "== Clean staged state (no symlinks) passes through"
# -----------------------------------------------------------------------------

repo=$(mkrepo "clean-1" \
  regular src/code.ts "export const x = 1;" \
  stage src/code.ts)

out=$(run_hook "$(mkpayload Bash "git commit -m 'feat: add x'" "$repo")")
assert_exit "$out" "0" "git commit with only regular files staged → allowed"

# -----------------------------------------------------------------------------
echo "== Staged in-tree symlinks pass through"
# -----------------------------------------------------------------------------
# A symlink whose target stays inside the worktree is fine — that's a normal
# repo-tracked symlink, not a worker-bootstrap escape artifact.

repo=$(mkrepo "in-tree-1" \
  regular src/real.ts "export const real = 1;" \
  symlink src/alias.ts real.ts \
  stage src/real.ts \
  stage src/alias.ts)

out=$(run_hook "$(mkpayload Bash "git commit -m 'add alias'" "$repo")")
assert_exit "$out" "0" "staged in-tree relative symlink → allowed"

repo=$(mkrepo "in-tree-2" \
  regular a/foo.txt "foo" \
  regular b/bar.txt "bar" \
  symlink b/foo-link ../a/foo.txt \
  stage a/foo.txt \
  stage b/bar.txt \
  stage b/foo-link)

# Has one `../` but the resolved target stays inside the worktree. The decision
# rule uses literal `..` segments — this WILL be blocked. Document the behavior:
# the false-positive cost (blocking a legitimate `../sibling` symlink) is
# accepted because (a) intra-repo symlinks with `..` are rare in practice and
# (b) the worker can unstage and the maintainer can land it manually on the
# rare occasion.
out=$(run_hook "$(mkpayload Bash "git commit -m 'sibling link'" "$repo")")
assert_blocked_with "$out" "escape" \
  "staged symlink with literal '../' → blocked (accepts false-positive on rare intra-repo cases)"

# -----------------------------------------------------------------------------
echo "== Staged escape symlinks are blocked"
# -----------------------------------------------------------------------------
# The canonical failure mode from #351: node_modules → ../../../node_modules
# was created by the worker's dependency-bootstrap step, then somehow ended up
# in `git add` (likely a misclick or stray `git add -A`). The symlink target
# escapes the worktree and becomes dangling on any downstream checkout.

repo=$(mkrepo "escape-1" \
  symlink node_modules ../../../node_modules \
  stage-force node_modules)

out=$(run_hook "$(mkpayload Bash "git commit -m 'unrelated change'" "$repo")")
assert_blocked_with "$out" "node_modules" \
  "node_modules → ../../../node_modules → blocked"
assert_blocked_with "$out" "escape" \
  "blocked message mentions 'escape'"

# Same shape but only `../` (one level up — still escapes).
repo=$(mkrepo "escape-2" \
  symlink linked ../something \
  stage-force linked)
out=$(run_hook "$(mkpayload Bash "git commit -m x" "$repo")")
assert_blocked_with "$out" "linked" \
  "single-level ../ escape → blocked"

# Absolute symlink target — escape by being absolute.
repo=$(mkrepo "escape-3" \
  symlink config-link /etc/hosts \
  stage-force config-link)
out=$(run_hook "$(mkpayload Bash "git commit -m x" "$repo")")
assert_blocked_with "$out" "config-link" \
  "absolute symlink target → blocked"

# Multiple escape symlinks — message names all of them.
repo=$(mkrepo "escape-4" \
  symlink first ../foo \
  symlink second /etc/bar \
  stage-force first \
  stage-force second)
out=$(run_hook "$(mkpayload Bash "git commit -m x" "$repo")")
assert_blocked_with "$out" "first" "multi-escape: 'first' named in stderr"
assert_blocked_with "$out" "second" "multi-escape: 'second' named in stderr"

# -----------------------------------------------------------------------------
echo "== Boundary forms of the commit invocation are recognized"
# -----------------------------------------------------------------------------

repo=$(mkrepo "boundary-1" \
  symlink node_modules ../../../node_modules \
  stage-force node_modules)

# `git commit -m`
out=$(run_hook "$(mkpayload Bash "git commit -m 'x'" "$repo")")
assert_blocked_with "$out" "node_modules" "git commit -m → caught"

# `git commit -am` (combined)
out=$(run_hook "$(mkpayload Bash "git commit -am 'x'" "$repo")")
assert_blocked_with "$out" "node_modules" "git commit -am → caught"

# Chained command — && git commit ...
out=$(run_hook "$(mkpayload Bash "git add foo && git commit -m 'x'" "$repo")")
assert_blocked_with "$out" "node_modules" "chained && git commit → caught"

# Chained with ;
out=$(run_hook "$(mkpayload Bash "echo hi ; git commit -m 'x'" "$repo")")
assert_blocked_with "$out" "node_modules" "chained ; git commit → caught"

# Multi-line command (newline-separated) — use $'...' for the literal newline
out=$(run_hook "$(mkpayload Bash $'git add foo\ngit commit -m x' "$repo")")
assert_blocked_with "$out" "node_modules" "multi-line git commit → caught"

# Heredoc-supplied commit message (the issue-work.md PR creation pattern)
out=$(run_hook "$(mkpayload Bash $'git commit -m "$(cat <<EOF\nfix: x\nEOF\n)"' "$repo")")
assert_blocked_with "$out" "node_modules" "heredoc commit message → caught"

# -----------------------------------------------------------------------------
echo "== Malformed payloads exit 0 (defensive default)"
# -----------------------------------------------------------------------------
# A hook that crashes-and-blocks every Bash call would be catastrophic.

out=$(run_hook "not-json-at-all")
assert_exit "$out" "0" "malformed JSON → allowed"

out=$(run_hook "{}")
assert_exit "$out" "0" "empty object → allowed"

out=$(run_hook '{"tool_name":"Bash"}')
assert_exit "$out" "0" "missing tool_input → allowed"

out=$(run_hook '{"tool_name":"Bash","tool_input":{}}')
assert_exit "$out" "0" "missing command → allowed"

# Bash call with no cwd → can't inspect repo → allow rather than false-block.
out=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}')
assert_exit "$out" "0" "missing cwd → allowed"

# Bash call with cwd that isn't a git repo → no staged paths to inspect → allow.
not_a_repo="$TMP/not-a-repo"
mkdir -p "$not_a_repo"
out=$(run_hook "$(mkpayload Bash "git commit -m x" "$not_a_repo")")
assert_exit "$out" "0" "cwd not a git repo → allowed (git commit would fail on its own)"

# -----------------------------------------------------------------------------
echo "== Summary"
# -----------------------------------------------------------------------------

total=$((pass+fail))
if (( fail == 0 )); then
  printf '%s%d/%d tests pass.%s\n' "$GREEN" "$pass" "$total" "$RESET"
  exit 0
else
  printf '%s%d/%d tests pass — %d failures.%s\n' "$RED" "$pass" "$total" "$fail" "$RESET"
  exit 1
fi
