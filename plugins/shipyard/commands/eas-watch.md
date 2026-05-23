---
description: Surface failed EAS builds in real time. Lists recent EAS builds for the current Expo project, diffs against per-project state at ~/.shipyard/eas-state.json, surfaces NEW builds in the terminal, and optionally files audit:eas-build-labeled issues against the project's GitHub repo for errored builds.
argument-hint: [--repo owner/repo] [--limit N] [--file-issue] [--no-file-issue] [--json] [--reset]
---

# /shipyard:eas-watch

Surface failed EAS (Expo Application Services) builds in real time. Closes [#270](https://github.com/mattsears18/shipyard/issues/270).

The problem this solves: EAS build failures are **silent** unless the user has explicitly wired one of EAS's notification surfaces (`eas webhook:create`, email opt-in, or a `.eas/workflows/*.yml` workflow that posts a GitHub status check). For app repos that run `eas build --platform ios --profile production` from a developer laptop, none of these are wired by default — a build failure produces nothing visible until the user opens the EAS dashboard. This command bridges that gap with a poll-and-diff model that composes with `/loop` for poor-man's cron until a cleaner background mechanism exists.

Pairs with [`expo:eas-update-insights`](../../../README.md) — that skill watches OTA-update health post-deploy; this one watches the build leg of the same pipeline.

## When to use

- After running `eas build --platform ios --profile production` from your laptop and wanting to know if it succeeded without re-opening the dashboard.
- Wired into `/loop` for periodic polling: `/loop 5m /shipyard:eas-watch` gives a 5-minute-cadence build-status watcher with no external webhook setup.
- Inside `/shipyard:my-turn` follow-ups — a failed build is something blocked-on-the-user and surfacing it through the same surface as PR review requests / blocked issues keeps the maintainer's attention budget consolidated.

Not the right surface when:

- You already have `eas webhook:create --event BUILD --url <slack-incoming>` wired and it's surfacing into a channel you actually read. The shipyard wrapper is for users without Slack/Discord, or whose laptop-driven builds don't naturally land in any chat surface.
- You want CI / automation to gate on the build status — use the EAS workflow's GitHub-status output for that, not this poll-and-diff loop.

## Args

`$ARGUMENTS` may include:

- **--repo owner/repo** (optional): the GitHub repo to file issues against when `--file-issue` triggers. If omitted, defaults to the cwd's git remote (`gh repo view --json nameWithOwner -q .nameWithOwner`).
- **--limit N** (optional, default `20`): cap the number of recent builds queried from EAS. Set to a value larger than the expected new-build count between invocations — 20 is fine for hourly polling on an active project; bump to 50+ for the catch-up case after a long absence.
- **--file-issue** (opt-in): on each errored build, file an `audit:eas-build`-labeled issue against the repo. Off by default — the maintainer can read the terminal banner without the tracker getting noisy. When enabled, idempotency is handled by the duplicate-search convention from `shipyard:filing-github-issues` (search for the build ID in open issue bodies before filing).
- **--no-file-issue** (opt-out): explicit "I want the banner but not the issue" flag. Equivalent to the default — exists so `/loop` invocations can be unambiguous.
- **--json** (optional): emit the structured diff result on stdout instead of the human banner. Useful when wiring `/shipyard:eas-watch` into other shipyard machinery (e.g. `/shipyard:my-turn` composition).
- **--reset** (rare): wipe the state file's entry for the current project, forcing the next run to treat everything as new. Use after debugging a noisy run, or when you've intentionally invalidated builds (force-rebuilt a release) and want the next poll to re-surface them.

## What the assistant should do when this command runs

The mechanics are split between this spec (orchestration) and [`plugins/shipyard/scripts/eas-watch.sh`](../scripts/eas-watch.sh) (state diff + EAS-CLI wrapping). The spec stays thin: resolve target, invoke helper, route the output. The helper owns the EAS-CLI-shape quirks, the per-project state file, and the diff logic — see its file header for the state-file shape and exit codes.

### 1. Parse args

Default values:

- `repo`: from `gh repo view --json nameWithOwner -q .nameWithOwner` if `--repo` not given. If that fails (not in a git repo, no GitHub remote), continue — the `--file-issue` path will then refuse with a clear error, but the banner path is still useful.
- `limit`: 20.
- `file_issue`: false.
- `json`: false.

### 2. Confirm we're in an Expo project

```bash
SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/eas-watch.sh"
SLUG=$(bash "$SCRIPT" project-slug)
```

If `project-slug` exits non-zero (no `app.json` / `app.config.{js,ts}` at cwd), print a clear one-liner and stop. Do NOT prompt the user to enter a slug manually — wrong cwd is the common case here and the right answer is "cd to your app repo first."

### 3. Materialize the state file (idempotent)

```bash
bash "$SCRIPT" state-init
```

First-run sets up `~/.shipyard/eas-state.json` with `{"version":1,"projects":{}}`. Subsequent runs are no-ops.

If `--reset` was passed, blank this project's entry before listing builds:

```bash
bash "$SCRIPT" state-update --project "$SLUG" --last-seen-id ""
```

### 4. Query recent builds

```bash
BUILDS_FILE=$(mktemp)
bash "$SCRIPT" list-builds --limit "$LIMIT" > "$BUILDS_FILE"
```

`list-builds` wraps `eas build:list --json --non-interactive`. If `eas` is not on PATH, the helper exits 3 with `not found on PATH — install with: npm i -g eas-cli` — surface that message verbatim and stop.

### 5. Diff against state

```bash
NEW_BUILDS=$(bash "$SCRIPT" diff --project "$SLUG" --builds-json "$BUILDS_FILE")
```

Output is JSONL — one JSON object per new build, each carrying `{id, status, platform, profile, createdAt, gitCommitHash, errorMessage, logsUrl}`. Empty output means no new builds — print `No new builds since last check.` and stop (no state advance needed — the cursor hasn't moved).

If `--json` was set, dump `$NEW_BUILDS` on stdout and stop (caller wants the structured result).

### 6. Surface each new build

Walk `$NEW_BUILDS` newest-first (it's already in that order from the helper). For each build:

**Errored builds** (`status` is `errored` or `build-failed` or `canceled`) — banner with the failure step + log URL:

```
✗ EAS build FAILED — <profile>/<platform> (id: <short-id>)
  commit: <gitCommitHash>
  error:  <errorMessage>
  logs:   <logsUrl>
```

**Finished builds** (`status` is `finished`) — quieter one-liner (success isn't news, but worth a confirmation line so the user knows the watcher saw it):

```
✓ EAS build ok — <profile>/<platform> (id: <short-id>, commit: <hash>)
```

**In-progress / queued** (`status` is `in-progress`, `in-queue`, `new`) — skip silently. These will appear again as `finished` or `errored` on a later poll; emitting them now is noise.

### 7. File issues for errored builds (when `--file-issue`)

For each errored build, **before** filing, check for an existing open issue carrying the build id in its body — the duplicate-search convention from `shipyard:filing-github-issues`:

```bash
gh issue list --repo <owner/repo> --state open --search "in:body <build-id>" --json number,url --jq 'length'
```

If `>0`, skip — already filed. If `0`, file:

```bash
gh issue create --repo <owner/repo> \
  --title "fix(eas): <profile>/<platform> build failed — <errorMessage-shortened>" \
  --label "audit:eas-build" \
  --label "shipyard" \
  --body "$(cat <<EOF
## Build failure

- **Build ID**: <id>
- **Platform**: <platform>
- **Profile**: <profile>
- **Created**: <createdAt>
- **Source commit**: <gitCommitHash>
- **Logs**: <logsUrl>

## Error

\`\`\`
<errorMessage>
\`\`\`

## Surfaced by

\`/shipyard:eas-watch\` on $(date -u +%Y-%m-%dT%H:%M:%SZ) — see [#270](https://github.com/mattsears18/shipyard/issues/270) for the watcher's design rationale.

<!-- audit-key: eas-build-<id> -->
EOF
)"
```

Auto-create the `audit:eas-build` label if it doesn't exist — same exception to the "don't auto-create labels" rule that the `audit:*` family enjoys (the label is shipyard's own metadata, not a repo-config decision):

```bash
gh label list --repo <owner/repo> --limit 100 | grep -q "^audit:eas-build" || \
  gh label create "audit:eas-build" --repo <owner/repo> --color c5def5 --description "Created by /shipyard:eas-watch"
```

### 8. Compose with notification surfaces

If the user has wired any of shipyard's notification surfaces (iMessage, Telegram, Slack), and at least one errored build was surfaced, send a one-liner via the configured channel. Detection happens via the existing channel configs (e.g. `~/.shipyard/imessage/access.json`, `~/.shipyard/telegram/config.json`, `~/.shipyard/slack/`). The point isn't to invent new wiring here — it's to reuse what's already configured.

If none of the channels are wired, skip silently — the terminal banner is the primary surface; notifications are the bonus when available.

### 9. Advance the state cursor

Only after surfacing (and optionally filing / notifying), advance the cursor to the newest build seen:

```bash
NEWEST_ID=$(echo "$NEW_BUILDS" | head -1 | jq -r '.id')
bash "$SCRIPT" state-update --project "$SLUG" --last-seen-id "$NEWEST_ID"
```

This is deliberately the LAST step: if a notification call or `gh issue create` fails partway through, the cursor stays where it was so the next invocation re-surfaces the same builds. **Idempotency for `--file-issue` comes from the in:body build-id search in step 7** — re-running won't create duplicate issues; it WILL re-banner the same builds in the terminal, which is fine.

### 10. Summary line

Print a final summary so the user can grep / `/loop` output for the busy iterations:

```
Checked <slug> — <K> new build(s): <K_errored> errored, <K_finished> finished (state advanced to <newest-id>)
```

If no new builds, the step-5 `No new builds since last check.` line is the summary and step 10 is a no-op.

## Composition recipes

### Periodic polling with `/loop`

```bash
/loop 5m /shipyard:eas-watch
```

Polls every 5 minutes. The state file's cursor makes re-runs idempotent — silent runs when nothing's new, banners when builds complete.

### Catch-up after a long absence

```bash
/shipyard:eas-watch --limit 50
```

After a multi-day absence, bump `--limit` so the helper queries enough history to span the gap. The diff still only emits builds NEWER than the cursor, so the output stays bounded.

### Wire into `/shipyard:my-turn`

`/shipyard:my-turn` surveys open PRs, issues, and review comments to surface what's blocked on the user. A failed EAS build is exactly that. When `/shipyard:my-turn` runs, it can shell out to `/shipyard:eas-watch --json` for any Expo repo in its scan list and merge errored builds into its ranked output. (This composition isn't wired automatically yet — the manual workflow is `/shipyard:my-turn` then `/shipyard:eas-watch` in each app repo.)

## Don't

- **Don't advance the cursor before surfacing.** If the surface step (banner, notification, issue file) fails partway, leaving the cursor un-advanced means the next invocation retries from the same point. Advancing early swallows the failure into a permanent miss.
- **Don't auto-file issues by default.** The `--file-issue` flag is opt-in for a reason — the tracker should reflect work the maintainer cares about, and an interactive `eas build` failure is something the maintainer is actively watching, not a background-noise event. Reserve issue filing for `/loop`-driven background polling where the maintainer is NOT at the terminal.
- **Don't poll EAS faster than 5-minute cadence.** `eas build:list` is rate-limited; aggressive polling will hit 429s. The 5-minute floor in the `/loop 5m` recipe is the recommended minimum.
- **Don't write to the state file from inside the slash-command spec.** The atomic-write contract lives in `eas-watch.sh`'s `state-update` subcommand. The spec calls it; the spec doesn't reimplement it.

## Related

- [`shipyard:filing-github-issues`](../skills/filing-github-issues/SKILL.md) — duplicate-search convention reused in step 7 (in:body build-id check).
- [`shipyard:my-turn`](./my-turn.md) — the human-driven counterpart to `/do-work`; failed builds belong on its prioritized list.
- [`/loop`](../../../README.md) — periodic-invocation harness; the canonical companion for this command.
