#!/usr/bin/env bash
# scripts/setup.sh — one canonical "clone → runnable" entry point for the
# mattsears18/shipyard repo (issue #399).
#
# This repo has no build step: the plugin is a directory of markdown + bash
# scripts. "Setup" therefore means (1) confirming the small set of host
# tools a contributor needs are present, and (2) running the bash test
# suite so a fresh checkout is verified green in one command — exactly the
# flow CONTRIBUTING.md's "Getting started" documents, wrapped behind a
# single invocation.
#
# Usage:
#   ./scripts/setup.sh            # check prerequisites, then run the test suite
#   ./scripts/setup.sh --check    # check prerequisites only, skip the tests
#   ./scripts/setup.sh --help     # print usage and exit
#
# Exit status is non-zero if a required tool is missing or the test suite
# fails, so the script is safe to use as a CI / pre-flight gate too.

set -euo pipefail

# Resolve the repo root from this script's location so the script works
# regardless of the caller's cwd (run from anywhere, including via an
# absolute path).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

run_tests=1

usage() {
  cat <<'EOF'
Usage: scripts/setup.sh [--check] [--help]

Brings a fresh checkout of mattsears18/shipyard to a runnable, verified state.

  (no args)   Check prerequisites, then run the bash test suite.
  --check     Check prerequisites only; skip the test suite.
  --help      Print this message and exit.

Prerequisites checked: bash, git, gh, shellcheck, jq.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) run_tests=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "${RED}error:${RESET} unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

echo "${BOLD}shipyard setup${RESET} — verifying a fresh checkout is runnable"
echo "repo root: $REPO_ROOT"
echo

# ---------------------------------------------------------------------------
# 1. Prerequisite check.
#
# These mirror CONTRIBUTING.md's "Getting started": bash + gh + shellcheck
# are the documented requirements; git and jq are implied by the workflows
# the contributor will run (gh shells out to git; several scripts/tests use
# jq). gh authentication is checked as a warning, not a hard failure — a
# contributor can run the test suite without an authenticated gh.
# ---------------------------------------------------------------------------
required=(bash git gh shellcheck jq)
missing=()

echo "${BOLD}Checking prerequisites${RESET}"
for tool in "${required[@]}"; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf '  %sok%s    %s\n' "$GREEN" "$RESET" "$tool"
  else
    printf '  %smiss%s  %s\n' "$RED" "$RESET" "$tool"
    missing+=("$tool")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo
  echo "${RED}Missing required tools:${RESET} ${missing[*]}" >&2
  echo "Install them and re-run. See CONTRIBUTING.md → Getting started." >&2
  echo "  - gh:         https://cli.github.com/" >&2
  echo "  - shellcheck: https://github.com/koalaman/shellcheck" >&2
  echo "  - jq:         https://jqlang.github.io/jq/" >&2
  exit 1
fi

# Soft check: gh authentication. Not required to run the tests, but a
# contributor will need it for any /shipyard:do-work or gh-driven flow.
if gh auth status >/dev/null 2>&1; then
  printf '  %sok%s    gh authenticated\n' "$GREEN" "$RESET"
else
  printf '  %swarn%s  gh not authenticated (run: gh auth login)\n' "$YELLOW" "$RESET"
fi

echo
echo "${GREEN}All required tools present.${RESET}"

if [[ "$run_tests" -eq 0 ]]; then
  echo "--check given; skipping test suite."
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Run the bash test suite — the same discovery + invocation CI uses
#    (.github/workflows/tests.yml) and CONTRIBUTING.md documents.
# ---------------------------------------------------------------------------
echo
echo "${BOLD}Running test suite${RESET} (find plugins -name '*.test.sh')"
echo

cd "$REPO_ROOT"

tests=()
while IFS= read -r -d '' f; do
  tests+=("$f")
done < <(find plugins -type f -name '*.test.sh' -print0 | sort -z)

if [[ ${#tests[@]} -eq 0 ]]; then
  echo "${RED}No test files found under plugins/ matching *.test.sh${RESET}" >&2
  exit 1
fi

echo "Found ${#tests[@]} test file(s)."
echo

failed=0
for t in "${tests[@]}"; do
  if bash "$t"; then
    :
  else
    rc=$?
    echo "${RED}FAILED${RESET} ($rc): $t" >&2
    failed=$((failed + 1))
  fi
done

echo
if [[ "$failed" -gt 0 ]]; then
  echo "${RED}$failed test suite(s) failed.${RESET}" >&2
  exit 1
fi

echo "${GREEN}All ${#tests[@]} test suite(s) passed. Checkout is runnable.${RESET}"
