#!/usr/bin/env bash
# shipyard statusline — shows last main-branch CI status for the cwd's repo
#
# Designed for Claude Code statusline ("statusLine" in settings.json). It runs
# every few seconds while CC is open, so we cache aggressively. One `gh` call
# per CACHE_TTL window per repo, period.
#
# Wire it up by adding to ~/.claude/settings.json (or .claude/settings.json):
#
#   "statusLine": {
#     "type": "command",
#     "command": "${CLAUDE_PLUGIN_ROOT}/scripts/statusline.sh"
#   }
#
# Output: a short colored segment like "main:✓" (green) or "main:✗ #18234" (red).
# If the cwd isn't a git repo with a GitHub remote, or `gh` isn't authed, the
# script outputs nothing — Claude Code will just render its default statusline.

set -u

CACHE_TTL="${SHIPYARD_STATUSLINE_CACHE_TTL:-30}"   # seconds; tune via env
CACHE_DIR="${TMPDIR:-/tmp}/shipyard-statusline"
mkdir -p "$CACHE_DIR" 2>/dev/null || exit 0

# ANSI color helpers. Claude Code's statusline renders ANSI escapes.
GREEN=$'\033[32m'
RED=$'\033[31m'
YELLOW=$'\033[33m'
DIM=$'\033[2m'
RESET=$'\033[0m'

# Claude Code passes session metadata as JSON on stdin. We don't use it (we
# detect the repo from cwd via git), but we need to consume stdin so the
# upstream process doesn't block. Use a non-blocking read with a tiny timeout.
read -r -t 0.05 _ignored 2>/dev/null || true

# Resolve the repo from cwd. If we're not inside a git repo, bail silently.
repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -z "$repo_root" ] && exit 0

# Resolve the GitHub slug (owner/repo). We don't require `gh repo view` — using
# `git remote get-url` keeps this fast and lets us skip the gh call entirely
# when the repo isn't on github.com.
remote_url=$(git -C "$repo_root" remote get-url origin 2>/dev/null) || exit 0
slug=$(echo "$remote_url" | sed -E 's#(git@github\.com:|https?://github\.com/)([^/]+/[^/.]+)(\.git)?$#\2#')
case "$slug" in
  */*) ;;       # ok, looks like owner/repo
  *) exit 0 ;;  # not a GitHub remote
esac

# Cache key is per-slug so worktrees of the same repo share the cache.
cache_file="$CACHE_DIR/$(echo "$slug" | tr '/' '_').json"

# If the cache is fresh, reuse it. mtime check is portable across macOS/Linux.
needs_refresh=1
if [ -f "$cache_file" ]; then
  if [ "$(uname)" = "Darwin" ]; then
    cache_age=$(( $(date +%s) - $(stat -f %m "$cache_file" 2>/dev/null || echo 0) ))
  else
    cache_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
  fi
  [ "$cache_age" -lt "$CACHE_TTL" ] && needs_refresh=0
fi

if [ "$needs_refresh" -eq 1 ]; then
  # Resolve default branch (cached separately, longer TTL — default branch
  # almost never changes, so we cache for an hour). Skip the lookup if we
  # already have it.
  branch_cache="$CACHE_DIR/$(echo "$slug" | tr '/' '_').branch"
  if [ -f "$branch_cache" ]; then
    if [ "$(uname)" = "Darwin" ]; then
      branch_age=$(( $(date +%s) - $(stat -f %m "$branch_cache" 2>/dev/null || echo 0) ))
    else
      branch_age=$(( $(date +%s) - $(stat -c %Y "$branch_cache" 2>/dev/null || echo 0) ))
    fi
    if [ "$branch_age" -lt 3600 ]; then
      default_branch=$(cat "$branch_cache" 2>/dev/null)
    fi
  fi
  if [ -z "${default_branch:-}" ]; then
    default_branch=$(gh repo view "$slug" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null) || default_branch=""
    [ -n "$default_branch" ] && echo "$default_branch" > "$branch_cache"
  fi

  # If we still can't resolve a default branch, bail.
  [ -z "$default_branch" ] && exit 0

  # Walk the latest completed runs on the default branch to find the earliest
  # unfixed red run (or determine green). 10 entries is plenty for staying
  # cheap; if main has been red for >10 commits, "red since N runs ago" is the
  # right framing regardless.
  runs=$(gh run list --repo "$slug" --branch "$default_branch" \
    --status completed --limit 10 \
    --json conclusion,databaseId,url 2>/dev/null) || runs=""

  if [ -z "$runs" ] || [ "$runs" = "[]" ] || [ "$runs" = "null" ]; then
    echo "{\"status\":\"unknown\"}" > "$cache_file"
  else
    # Walk newest → oldest. While runs are "failure", remember the latest one
    # (will be overwritten as we find earlier ones). Break on first "success".
    parsed=$(echo "$runs" | python3 -c '
import json, sys
runs = json.load(sys.stdin)
if not runs:
    print(json.dumps({"status": "unknown"}))
    sys.exit(0)
newest = runs[0]
if newest.get("conclusion") == "success":
    print(json.dumps({"status": "green", "newest_id": newest.get("databaseId")}))
    sys.exit(0)
# Newest is failure (or something else, e.g. cancelled — treat non-success as red).
earliest_red = newest
for r in runs[1:]:
    if r.get("conclusion") == "success":
        break
    earliest_red = r
print(json.dumps({
    "status": "red",
    "earliest_red_id": earliest_red.get("databaseId"),
    "earliest_red_url": earliest_red.get("url"),
}))
' 2>/dev/null) || parsed="{\"status\":\"unknown\"}"
    echo "$parsed" > "$cache_file"
  fi
fi

# Read the cached result and render.
status=$(python3 -c "import json,sys; d=json.load(open('$cache_file')); print(d.get('status','unknown'))" 2>/dev/null) || status="unknown"

case "$status" in
  green)
    printf "%smain:✓%s" "$GREEN" "$RESET"
    ;;
  red)
    run_id=$(python3 -c "import json,sys; d=json.load(open('$cache_file')); print(d.get('earliest_red_id',''))" 2>/dev/null)
    if [ -n "$run_id" ]; then
      printf "%smain:✗ #%s%s" "$RED" "$run_id" "$RESET"
    else
      printf "%smain:✗%s" "$RED" "$RESET"
    fi
    ;;
  *)
    printf "%smain:?%s" "$DIM" "$RESET"
    ;;
esac
