#!/bin/bash
# do-work dashboard live updater
#
# Polls every 10 seconds and rewrites the dynamic bits of the dashboard
# HTML in place:
#   - flips "PR #N · pending" badges to "merged ✓" / "closed" as PRs settle
#   - syncs the two repo-wide stat tiles (open issues, open PRs)
#
# Static bits (worker cards, shipped-PR rows) remain the orchestrator's job;
# this script only touches values it can derive from `gh`.
#
# Spawned in background by the /do-work command after writing the initial
# dashboard.  Exits cleanly if the dashboard file disappears.
#
# Usage:
#   do-work-dashboard-updater.sh \
#     --repo owner/repo \
#     --dashboard /tmp/do-work-dashboard.html \
#     [--mirror /path/to/copy] \
#     [--interval 10]

set -uo pipefail

REPO=""
DASHBOARD="/tmp/do-work-dashboard.html"
MIRROR=""
INTERVAL=10

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)       REPO="$2";       shift 2 ;;
    --dashboard)  DASHBOARD="$2";  shift 2 ;;
    --mirror)     MIRROR="$2";     shift 2 ;;
    --interval)   INTERVAL="$2";   shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$REPO" ]; then
  echo "--repo owner/repo is required" >&2
  exit 2
fi

# Detect sed in-place flag once (macOS BSD sed needs '' after -i; GNU sed doesn't).
if sed --version >/dev/null 2>&1; then
  SED_INPLACE=(-i)
else
  SED_INPLACE=(-i '')
fi

REPO_URL="https://github.com/${REPO}"

while true; do
  if [ ! -f "$DASHBOARD" ]; then
    sleep "$INTERVAL"
    continue
  fi

  # 1. Flip "pending" → "merged ✓" / "closed" for any PR that's now settled.
  pending_prs=$(grep -oE 'PR #[0-9]+ · pending' "$DASHBOARD" | grep -oE '[0-9]+' | sort -u)
  for pr in $pending_prs; do
    state=$(gh pr view "$pr" --repo "$REPO" --json state --jq '.state' 2>/dev/null || echo "")
    case "$state" in
      MERGED)
        sed "${SED_INPLACE[@]}" \
          -e "s|check-state pending\"><a href=\"${REPO_URL}/pull/${pr}\" target=\"_blank\">PR #${pr} · pending|check-state merged\"><a href=\"${REPO_URL}/pull/${pr}\" target=\"_blank\">PR #${pr} · merged ✓|g" \
          "$DASHBOARD"
        ;;
      CLOSED)
        sed "${SED_INPLACE[@]}" \
          -e "s|check-state pending\"><a href=\"${REPO_URL}/pull/${pr}\" target=\"_blank\">PR #${pr} · pending|check-state failing\"><a href=\"${REPO_URL}/pull/${pr}\" target=\"_blank\">PR #${pr} · closed|g" \
          "$DASHBOARD"
        ;;
    esac
  done

  # 2. Refresh repo-wide open counts in the two stat tiles.
  open_issues=$(gh issue list --repo "$REPO" --state open --limit 200 --json number --jq 'length' 2>/dev/null || echo "")
  open_prs=$(gh pr list --repo "$REPO" --state open --limit 100 --json number --jq 'length' 2>/dev/null || echo "")

  if [ -n "$open_issues" ] && [ -n "$open_prs" ]; then
    sed "${SED_INPLACE[@]}" \
      -e "s|<a href=\"${REPO_URL}/issues\" target=\"_blank\" style=\"color: inherit; text-decoration: none;\">[0-9]\{1,4\}</a>|<a href=\"${REPO_URL}/issues\" target=\"_blank\" style=\"color: inherit; text-decoration: none;\">${open_issues}</a>|" \
      -e "s|<a href=\"${REPO_URL}/pulls\" target=\"_blank\" style=\"color: inherit; text-decoration: none;\">[0-9]\{1,4\}</a>|<a href=\"${REPO_URL}/pulls\" target=\"_blank\" style=\"color: inherit; text-decoration: none;\">${open_prs}</a>|" \
      "$DASHBOARD"
  fi

  # 3. Optional mirror (e.g. into the user's repo for git tracking).
  if [ -n "$MIRROR" ]; then
    cp "$DASHBOARD" "$MIRROR" 2>/dev/null
  fi

  sleep "$INTERVAL"
done
