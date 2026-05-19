#!/bin/bash
# do-work dashboard live updater
#
# Polls every 10 seconds and rewrites the dynamic bits of the dashboard
# HTML in place:
#   - flips "PR #N · pending" badges to "merged ✓" / "closed" as PRs settle
#   - refreshes repo-health stat tiles: Main CI, Failing PRs (all authors),
#     Open PRs (repo), Open issues (repo)
#
# Static bits (worker cards, shipped-PR rows, diversion banners) remain the
# orchestrator's job — it has session state the script can't see (which slot
# is doing what, whether a diversion is enqueued vs in flight). This script
# only touches values it can derive from `gh`.
#
# Spawned in background by the /do-work command after writing the initial
# dashboard. Exits cleanly if the dashboard file disappears.
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

# Cache default branch (rarely changes; one-shot at startup).
DEFAULT_BRANCH=$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"

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

  # 2. Refresh repo-wide open counts (Open PRs, Open issues tiles).
  open_issues=$(gh issue list --repo "$REPO" --state open --limit 200 --json number --jq 'length' 2>/dev/null || echo "")
  open_prs=$(gh pr list --repo "$REPO" --state open --limit 100 --json number --jq 'length' 2>/dev/null || echo "")

  if [ -n "$open_issues" ] && [ -n "$open_prs" ]; then
    sed "${SED_INPLACE[@]}" \
      -e "s|<a href=\"${REPO_URL}/issues\" target=\"_blank\">[0-9]\{1,4\}</a>|<a href=\"${REPO_URL}/issues\" target=\"_blank\">${open_issues}</a>|" \
      -e "s|<a href=\"${REPO_URL}/pulls\" target=\"_blank\">[0-9]\{1,4\}</a>|<a href=\"${REPO_URL}/pulls\" target=\"_blank\">${open_prs}</a>|" \
      "$DASHBOARD"
  fi

  # 3. Refresh Main CI tile — show green only when every workflow on main has
  # a successful most-recent COMPLETED run. The bug we're avoiding: filtering
  # by `--status completed` hid in-progress workflows, which then let a sibling
  # `Release Please` success on the newest commit mask a failing `CI` workflow.
  # The fix: fetch ALL runs (any status) and aggregate PER WORKFLOW, not per
  # commit. For each workflow on main, find its most recent COMPLETED run —
  # that's the workflow's current health. Overall main is red if any workflow's
  # most-recent-completed result is red, even if a sibling workflow already
  # finished green on the newest commit or if the workflow's own newest run is
  # still in progress.
  main_runs_json=$(gh run list --repo "$REPO" --branch "$DEFAULT_BRANCH" \
    --limit 60 \
    --json databaseId,conclusion,status,url,headSha,createdAt,workflowName 2>/dev/null)
  if [ -n "$main_runs_json" ] && [ "$main_runs_json" != "[]" ]; then
    main_status_line=$(echo "$main_runs_json" | python3 -c "
import json, sys
try:
    runs = json.load(sys.stdin)
except Exception:
    print('')
    sys.exit(0)
if not runs:
    print('')
    sys.exit(0)
RED = {'failure', 'timed_out', 'startup_failure', 'cancelled', 'action_required'}
OK = {'success', 'skipped', 'neutral'}
# Group runs by workflowName, keeping gh's newest-first order within each.
by_wf = {}
for r in runs:
    wf = r.get('workflowName') or ''
    by_wf.setdefault(wf, []).append(r)
# For each workflow, classify by its most recent COMPLETED run.
red_runs = []
green_runs = []
pending_workflows = 0
for wf, wf_runs in by_wf.items():
    wf_runs.sort(key=lambda r: r.get('createdAt') or '', reverse=True)
    last_completed = next((r for r in wf_runs if (r.get('status') or '').lower() == 'completed'), None)
    if last_completed is None:
        pending_workflows += 1
        continue
    c = (last_completed.get('conclusion') or '').lower()
    if c in RED:
        red_runs.append(last_completed)
    elif c in OK:
        green_runs.append(last_completed)
    else:
        pending_workflows += 1
if red_runs:
    # Most recent failing run wins the link target — that's the most actionable.
    red_runs.sort(key=lambda r: r.get('createdAt') or '', reverse=True)
    print(f\"red\t{red_runs[0].get('databaseId','')}\")
elif pending_workflows > 0:
    print('pending\t')
elif green_runs:
    print(f\"green\t{green_runs[0].get('databaseId','')}\")
else:
    print('unknown\t')
" 2>/dev/null)
    main_conclusion=$(echo "$main_status_line" | cut -f1)
    main_run_id=$(echo "$main_status_line" | cut -f2)
    case "$main_conclusion" in
      green)
        # Replace the entire <div class="stat ci-*"> block for Main CI with a green one.
        # We use a python-driven replacement to avoid sed multi-line headaches.
        python3 - "$DASHBOARD" "$main_run_id" "$REPO_URL" <<'PYEOF'
import re, sys, pathlib
path = pathlib.Path(sys.argv[1])
run_id = sys.argv[2]
repo_url = sys.argv[3]
html = path.read_text()
new_tile = (
    f'<div class="stat ci-green">\n'
    f'        <div class="label">Main CI</div>\n'
    f'        <div class="value">✓ <a href="{repo_url}/actions" target="_blank">green</a></div>\n'
    f'        <div class="sub">last completed run #{run_id}</div>\n'
    f'      </div>'
)
html = re.sub(
    r'<div class="stat ci-(green|red|pending|unknown)">\s*<div class="label">Main CI</div>.*?</div>\s*</div>',
    new_tile,
    html,
    count=1,
    flags=re.DOTALL,
)
path.write_text(html)
PYEOF
        ;;
      red)
        python3 - "$DASHBOARD" "$main_run_id" "$REPO_URL" <<'PYEOF'
import re, sys, pathlib
path = pathlib.Path(sys.argv[1])
run_id = sys.argv[2]
repo_url = sys.argv[3]
html = path.read_text()
new_tile = (
    f'<div class="stat ci-red">\n'
    f'        <div class="label">Main CI</div>\n'
    f'        <div class="value">✗ <a href="{repo_url}/actions/runs/{run_id}" target="_blank">#{run_id}</a></div>\n'
    f'        <div class="sub">earliest red run · see banner above</div>\n'
    f'      </div>'
)
html = re.sub(
    r'<div class="stat ci-(green|red|pending|unknown)">\s*<div class="label">Main CI</div>.*?</div>\s*</div>',
    new_tile,
    html,
    count=1,
    flags=re.DOTALL,
)
path.write_text(html)
PYEOF
        ;;
      pending)
        python3 - "$DASHBOARD" "$REPO_URL" <<'PYEOF'
import re, sys, pathlib
path = pathlib.Path(sys.argv[1])
repo_url = sys.argv[2]
html = path.read_text()
new_tile = (
    f'<div class="stat ci-pending">\n'
    f'        <div class="label">Main CI</div>\n'
    f'        <div class="value">⏳ <a href="{repo_url}/actions" target="_blank">pending</a></div>\n'
    f'        <div class="sub">workflows still running on newest commit</div>\n'
    f'      </div>'
)
html = re.sub(
    r'<div class="stat ci-(green|red|pending|unknown)">\s*<div class="label">Main CI</div>.*?</div>\s*</div>',
    new_tile,
    html,
    count=1,
    flags=re.DOTALL,
)
path.write_text(html)
PYEOF
        ;;
    esac
  fi

  # 4. Refresh Failing PRs (all authors) tile — count distinct open PRs whose
  # check rollup contains a hard failure. Threshold-cross styling is handled
  # by toggling the `.failing-prs-pileup` modifier class on the tile.
  failing_count=$(gh pr list --repo "$REPO" --state open --limit 200 \
    --json number,statusCheckRollup 2>/dev/null | python3 -c "
import json, sys
try:
    prs = json.load(sys.stdin)
except Exception:
    print('')
    sys.exit(0)
def is_failing(pr):
    for c in (pr.get('statusCheckRollup') or []):
        if c.get('conclusion') in ('FAILURE','ERROR','TIMED_OUT'): return True
        if c.get('state') in ('FAILURE','ERROR','TIMED_OUT'): return True
    return False
print(len([p for p in prs if is_failing(p)]))
" 2>/dev/null)

  if [ -n "$failing_count" ]; then
    pileup_class=""
    pileup_sub=""
    if [ "$failing_count" -ge 10 ]; then
      pileup_class=" failing-prs-pileup"
      pileup_sub='        <div class="sub">⚠️ threshold (10) crossed — divert active</div>'
    else
      pileup_sub='        <div class="sub">below divert threshold (10)</div>'
    fi
    python3 - "$DASHBOARD" "$failing_count" "$pileup_class" "$pileup_sub" <<'PYEOF'
import re, sys, pathlib
path = pathlib.Path(sys.argv[1])
count = sys.argv[2]
extra_cls = sys.argv[3]
sub_line = sys.argv[4]
html = path.read_text()
new_tile = (
    f'<div class="stat{extra_cls}">\n'
    f'        <div class="label">Failing PRs · all authors</div>\n'
    f'        <div class="value">{count} <span style="font-size: 14px; color: var(--text-faint);">(@me: ?)</span></div>\n'
    f'{sub_line}\n'
    f'      </div>'
)
html = re.sub(
    r'<div class="stat( failing-prs-pileup)?">\s*<div class="label">Failing PRs · all authors</div>.*?</div>\s*</div>',
    new_tile,
    html,
    count=1,
    flags=re.DOTALL,
)
path.write_text(html)
PYEOF
  fi

  # 5. Optional mirror (e.g. into the user's repo for git tracking).
  if [ -n "$MIRROR" ]; then
    cp "$DASHBOARD" "$MIRROR" 2>/dev/null
  fi

  sleep "$INTERVAL"
done
