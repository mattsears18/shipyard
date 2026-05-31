#!/usr/bin/env bash
# scripts/enable-branch-protection.sh — make the CI gates *required* on main
# (issue #404 — "test + lint workflows run on PRs but aren't required checks").
#
# Background: this repo has three CI workflows that run the test/lint gates on
# every pull_request to main —
#
#   - .github/workflows/tests.yml      → check "bash test suites"
#   - .github/workflows/shellcheck.yml → checks "shellcheck" and "shell tests"
#   - .github/workflows/secret-scan.yml→ check "gitleaks"
#
# but main has no branch protection, so none of these *gate* merge. A PR whose
# tests run is red can still be merged (manually or via auto-merge) and the
# regression lands on main. The CI signal exists; it just isn't enforced.
#
# Enabling required status checks is a GitHub *admin* action — there is no
# committable file in the repo that turns it on. This script wraps the exact
# `gh api` call (with the correct check-context names, which are easy to get
# subtly wrong) so the one-time enablement is a single, reviewable command
# rather than a hand-assembled API payload. It does NOT decide policy for you:
# you must pass --apply to actually mutate the branch; the default is a dry-run
# that prints the payload and the current state so you can eyeball it first.
#
# Why a human runs this and not a /shipyard:do-work worker: per CLAUDE.md the
# maintainer's documented workflow is "push direct to main for trivial changes".
# Required checks coexist with that via admin bypass (enforce_admins=false, the
# default this script writes), so day-to-day direct pushes keep working — only
# PR *merges* with red checks get blocked. But flipping repo-level branch
# protection is a policy decision, so it's gated behind an explicit --apply.
#
# Usage:
#   ./scripts/enable-branch-protection.sh            # dry-run: show current state + the payload
#   ./scripts/enable-branch-protection.sh --dry-run  # same as no args (explicit)
#   ./scripts/enable-branch-protection.sh --apply     # actually enable required checks on main
#   ./scripts/enable-branch-protection.sh --show      # just print current protection state, then exit
#   ./scripts/enable-branch-protection.sh --help
#
# Optional overrides:
#   REPO=owner/name   target repo (default: mattsears18/shipyard)
#   BRANCH=name       target branch (default: main)
#
# Requires: gh (authenticated with admin on the target repo), jq.

set -euo pipefail

REPO="${REPO:-mattsears18/shipyard}"
BRANCH="${BRANCH:-main}"

# The required status-check *contexts* — these are the check-run names exactly
# as they appear in the PR checks UI / the check-runs API, NOT the workflow
# `name:` headers and NOT the workflow filenames. Getting these wrong makes the
# branch protection wait forever on a check that never reports. Verified against
# `gh api repos/<repo>/commits/<branch>/check-runs` on 2026-05-31.
REQUIRED_CONTEXTS=(
  "bash test suites"   # .github/workflows/tests.yml
  "shellcheck"         # .github/workflows/shellcheck.yml (job: shellcheck)
  "shell tests"        # .github/workflows/shellcheck.yml (job: shell-tests)
  "gitleaks"           # .github/workflows/secret-scan.yml
)

GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

mode="dry-run"

usage() {
  cat <<'EOF'
Usage: scripts/enable-branch-protection.sh [--dry-run|--apply|--show|--help]

Makes the CI test/lint workflows *required* status checks on main, so a PR
with red tests can no longer merge. Wraps the exact `gh api` enablement call
for issue #404.

  (no args)   Dry-run: print current protection state and the payload that
              --apply would PUT. Mutates nothing.
  --dry-run   Same as no args (explicit).
  --apply     Actually enable required status checks on the target branch.
  --show      Print current branch-protection state, then exit.
  --help      Print this message and exit.

Required checks written: "bash test suites", "shellcheck", "shell tests",
"gitleaks". enforce_admins is left false so the documented push-direct-to-main
workflow keeps working; only PR merges with red checks are blocked.

Env overrides: REPO (default mattsears18/shipyard), BRANCH (default main).
Requires gh (authenticated, admin on the repo) and jq.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)   mode="apply"; shift ;;
    --dry-run) mode="dry-run"; shift ;;
    --show)    mode="show"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "${RED}error:${RESET} unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for tool in gh jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "${RED}error:${RESET} required tool not found: $tool" >&2
    exit 1
  fi
done

echo "${BOLD}branch protection — required CI checks${RESET} (issue #404)"
echo "repo:   $REPO"
echo "branch: $BRANCH"
echo

# ---------------------------------------------------------------------------
# Show current state. A 404 ("Branch not protected") is the expected starting
# state for this repo; surface it plainly rather than as an error.
# ---------------------------------------------------------------------------
echo "${BOLD}Current protection${RESET}"
current="$(gh api "repos/$REPO/branches/$BRANCH/protection" 2>/dev/null || true)"
if [[ -z "$current" ]] || echo "$current" | jq -e '.message == "Branch not protected"' >/dev/null 2>&1; then
  printf '  %snone%s  branch is not protected (no required status checks)\n' "$YELLOW" "$RESET"
else
  contexts="$(echo "$current" | jq -r '.required_status_checks.contexts // [] | join(", ")')"
  if [[ -n "$contexts" ]]; then
    printf '  %sset%s   required contexts: %s\n' "$GREEN" "$RESET" "$contexts"
  else
    printf '  %spartial%s protection exists but no required status-check contexts\n' "$YELLOW" "$RESET"
  fi
fi
echo

if [[ "$mode" == "show" ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Build the protection payload. enforce_admins=false keeps the documented
# push-direct-to-main workflow working; required_pull_request_reviews=null
# means "don't require review approvals" (this is a single-maintainer repo);
# strict=false means "don't require the branch to be up to date before merge"
# (avoids forcing a rebase storm on every in-flight PR when main moves).
# ---------------------------------------------------------------------------
contexts_json="$(printf '%s\n' "${REQUIRED_CONTEXTS[@]}" | jq -R . | jq -s .)"
payload="$(jq -n --argjson contexts "$contexts_json" '{
  required_status_checks: { strict: false, contexts: $contexts },
  enforce_admins: false,
  required_pull_request_reviews: null,
  restrictions: null
}')"

echo "${BOLD}Payload (--apply would PUT this)${RESET}"
echo "$payload" | jq .
echo

if [[ "$mode" == "dry-run" ]]; then
  echo "${YELLOW}Dry-run only — nothing was changed.${RESET}"
  echo "Re-run with ${BOLD}--apply${RESET} to enable required checks on $BRANCH."
  exit 0
fi

# ---------------------------------------------------------------------------
# Apply. The branch-protection endpoint takes a PUT with the full payload.
# ---------------------------------------------------------------------------
echo "${BOLD}Applying${RESET} required status checks to $REPO@$BRANCH ..."
echo "$payload" | gh api -X PUT "repos/$REPO/branches/$BRANCH/protection" \
  -H "Accept: application/vnd.github+json" --input - >/dev/null

# Verify the contexts landed.
applied="$(gh api "repos/$REPO/branches/$BRANCH/protection" \
  --jq '.required_status_checks.contexts // [] | join(", ")' 2>/dev/null || true)"
if [[ -n "$applied" ]]; then
  echo "${GREEN}Done.${RESET} required contexts now: $applied"
else
  echo "${RED}error:${RESET} applied the payload but could not read back the required contexts." >&2
  exit 1
fi
