# /shipyard:do-work — Session state file

The session-state JSON schema, the `session-state.sh` helper subcommand reference, the write-through site table, and the cost-tracking write-through rules — the parts of the durable per-session record that are each **consumed once** (the schema, read at `init`) or by a **specific site** named in its own row (the write-through table is a 16-row lookup pointing back into the other phase files that actually perform each write). The thin entry [`commands/do-work.md`](../do-work.md) owns the [orchestrator-state struct list](../do-work.md#orchestrator-state) and a short pointer to this file; this file owns the on-disk mirror's full shape and mechanics. **Reference block — load it when you need the exact schema, a `session-state.sh` subcommand's flags, or which step writes which field — not on every turn** (mirrors the [dispatch-rules.md split #616](./dispatch-rules.md); split out under [#808](https://github.com/mattsears18/shipyard/issues/808)).

## Session state file

The orchestrator mirrors every [orchestrator-state](../do-work.md#orchestrator-state) structure into a small JSON file at `$SHIPYARD_HOME/sessions/<session-id>.json` (default: `~/.shipyard/sessions/<session-id>.json`). The file is the durable record of the session — written through whenever state changes, read back by external tools (and a future `/do-work --resume <session-id>` flag), and removed at end-of-session by the cleanup step. The LLM's per-turn working memory still drives dispatch decisions; the file is the mirror, not the algorithm. See [RATIONALE → Session state file](../do-work-RATIONALE.md#session-state-file--why-a-file-at-all) for the design discussion.

### Schema

```json
{
  "session_id": "<uuid or stable id>",
  "repo": "owner/repo",
  "concurrency": 2,
  "soft_collision_concurrency": 3,
  "started_at": "2026-05-20T17:31:14Z",
  "updated_at": "2026-05-20T18:04:22Z",

  "in_flight": {
    "slot1": { "kind": "issue", "target": 90, "claimed_paths": { "hard": [], "soft": [] }, "agent_id": "...", "model": "sonnet", "started_at": "2026-05-20T17:35:01Z", "progress_current": null, "progress_total": null, "progress_updated_at": null }
  },
  "ready_issues": [],
  "scope_bg_count": 0,
  "failed_prs": [],
  "raw_backlog": [],
  "unfiltered_open_count": 0,
  "me_assigned_open": 0,
  "last_fresh_fetch": null,
  "divert_queue": [],
  "awaiting_external": [
    { "issue": 3986, "mode": "issue-work", "what": "mobile-e2e run 31859829802", "probe": "gh run view 31859829802 --json status,conclusion", "eta": "~40m", "agent_id": "a42c0f5b9243bb353", "worktree_path": "/repo/.claude/worktrees/agent-a42c0f5b9243bb353", "parked_at": "2026-08-15T02:44:00Z", "deadline_at": "2026-08-15T04:44:00Z", "polls": 3 }
  ],
  "paused_on_environment": null,
  "operator_queue": [],
  "session_prs": [],
  "deferred_issues": [
    { "issue": 1075, "reason": "Gated on #1077 — low-urgency soft concern", "defer_reason_class": "confirmed-blocker-still-open", "evidence_pointer": "Blocked by #1077", "provenance": "orchestrator-judgment", "deferred_at": "2026-05-23T14:12:00Z" }
  ],
  "soft_caps": { "CLAUDE.md": 2 },
  "ci_capacity": { "shape": "self-hosted", "pool_total": 4, "queued_at_start": 6, "cheap_ci_globs": "docs/**,**/*.md" },
  "last_backpressure_check": { "verdict": "checked", "at": "2026-05-20T18:04:52Z" },
  "peer_sessions": { "count": 1, "claimed_targets": [1201], "checked_at": "2026-05-20T17:31:20Z" },
  "main_ci": {
    "status": "green",
    "earliest_red_run_id": null,
    "earliest_red_run_url": null,
    "earliest_red_sha": null,
    "checked_at": "2026-05-20T18:04:22Z"
  },
  "drain": { "active": false, "started_at": null, "polls": 0 },
  "session_end": null,

  "tokens": {
    "totals": {
      "input": 0, "output": 0, "cache_read": 0, "cache_creation": 0,
      "estimated_usd": 0
    },
    "per_issue": {
      "153": { "input": 18203, "output": 4102, "cache_read": 8210, "cache_creation": 0, "estimated_usd": 0.59 }
    },
    "per_pr": {
      "200": { "input": 18203, "output": 4102, "cache_read": 8210, "cache_creation": 0, "estimated_usd": 0.59, "issue": 153 }
    },
    "per_invocation": [],
    "degraded_attribution_count": 0
  }
}
```

Field names match the [orchestrator-state](../do-work.md#orchestrator-state) structure names 1:1 so a reader of either surface (file or prose) can cross-reference without translation. `started_at` and `updated_at` are always-present ISO-8601 UTC timestamps; `updated_at` advances on every successful `update` call so external watchers can detect change without diffing the body. `in_flight.<slot>.model` ([#978](https://github.com/mattsears18/shipyard/issues/978)) is the family alias `resolve-dispatch-model.sh` resolved for the slot's mode at dispatch time (`opus`/`sonnet`/`haiku`/`fable`), or `"default"` when the resolver returned empty — see the [per-slot dispatch metadata write-through](./steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action) for where it's written and [`/shipyard:status`](../status.md) for where it's read back.

`awaiting_external` ([#1390](https://github.com/mattsears18/shipyard/issues/1390)) is the park queue for workers that finished everything they could and are waiting on a long external job (a dispatched CI run, an EAS/store build, a deploy). One entry per parked worker, written by [steady-state.md's `awaiting-external` reconcile branch](./steady-state.md#a1-parse-the-return-string) and re-polled by [step D's `awaiting_external` sweep](./steady-state.md#d-periodic-refresh). `what` / `probe` / `eta` come verbatim from the worker's return (`probe` only after it re-passes [`scripts/validate-awaiting-external-probe.sh`](../../scripts/validate-awaiting-external-probe.sh) orchestrator-side — a worker-supplied string the orchestrator *executes* is re-validated at the trust boundary, never trusted because the worker claims it validated it). `agent_id` + `worktree_path` are what make the `SendMessage` resume possible, which is why the worktree of a parked worker is deliberately NOT reaped while its entry is live. `deadline_at` is `parked_at + awaiting_external.max_hours` (default 2), computed at the **first** park and carried unchanged across any re-park, so the bound cannot be rolled forward; `polls` is a diagnostic counter for the end-of-session summary. Unlike `divert_queue`, entries are never *dispatched* from this queue — they are resumed or expired. This queue is registered in [drain.md's termination-queue registry](./drain.md#termination-assertion), so a session cannot declare itself done while a worker is still parked.

`paused_on_environment` ([#1402](https://github.com/mattsears18/shipyard/issues/1402)) is a nullable, at-most-one-active session-wide pause — `null` for the entire session unless [step C's queue-depth backpressure check](./steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action) holds a slot AND, after that turn's dispatch decisions, `in_flight` has drained to `paused_on_environment.pause_when_in_flight_at_or_below` (default `0`) — no worker remains in flight whose completion would otherwise wake the orchestrator for a retry. Distinct from `awaiting_external`, which parks ONE worker on a job it started; this pauses the WHOLE dispatch loop instead. When set: `{ reason, resume_probe_repo, resume_probe_pool_total, resume_probe_multiplier, paused_at, deadline_at }` — `resume_probe_pool_total` / `resume_probe_multiplier` are the exact values [`scripts/watch-resume-probe.sh`](../../scripts/watch-resume-probe.sh) re-checks against a LIVE queue re-read via [`detect-ci-runner-capacity.sh --decide-resume`](../../scripts/detect-ci-runner-capacity.sh), armed as a background `Monitor` so a future notification exists to resume the loop (see [steady-state.md's "Session-wide environmental pause"](./environmental-pause.md) for the full mechanism). Unlike `awaiting_external`'s worker-supplied `probe` string, nothing here is worker-supplied — the orchestrator constructs the probe entirely from session-state values, so there is no untrusted-string trust boundary to re-validate at execution time. `deadline_at` is `paused_at + paused_on_environment.max_hours` (default 4), computed at the **first** pause and never recomputed — mirroring `awaiting_external.max_hours`'s anchoring rule exactly — so the bound cannot be rolled forward by a re-pause. **Deliberately no `polls` counter** (unlike `awaiting_external.polls`) — the watcher runs entirely inside a backgrounded `Monitor`, so the orchestrator has no visibility into intermediate poll ticks until the terminal notification arrives; there is nothing to increment between arm and resume. Cleared to `null` (never re-parked over a live entry) on the watcher's `resumed` line (a fresh backlog fetch follows before dispatch resumes) or on `held-timeout`/`error` (degrades to a genuine hand-back instead). This entry is registered in [drain.md's termination-queue registry](./drain.md#termination-assertion), so a session cannot declare itself done while a pause is active and unexpired. Currently CI-queue-depth-specific — the only environmental-halt detector this repo has wired ([#1156](https://github.com/mattsears18/shipyard/issues/1156)/[#1399](https://github.com/mattsears18/shipyard/issues/1399)).

`ci_capacity` ([#1141](https://github.com/mattsears18/shipyard/issues/1141)) is written once, at [setup step 1.36](./setup/01-repo-recovery.md#136-detect-ci-executor-pool-capacity-and-clamp-toward-it-1141), immediately after `init`. `.shape` is one of `self-hosted` (a registered self-hosted runner pool exists — `.pool_total` is its online-runner count), `hosted` (no self-hosted runners registered; GitHub-hosted runners are elastic, not a fixed-pool constraint — `.pool_total` is `0`), or `unknown` (the runner-pool signal couldn't be read, most commonly a `gh` token without repo admin — `.pool_total` is `0`, and this must never be treated as evidence of a small pool). `.queued_at_start` is a session-start snapshot only; the [end-of-session summary](./cleanup-summary.md#end-of-session-summary)'s `CI executor capacity` banner re-queries queue depth fresh at session end rather than trusting this field, since a multi-hour session's queue depth at exit — not at start — is what explains why PRs are still open. `.cheap_ci_globs` ([#1157](https://github.com/mattsears18/shipyard/issues/1157)) is written alongside the rest of the object, at [step 1.37](./setup/01-repo-recovery.md#137-detect-ci-cheap-path-availability-1157) — a comma-separated `paths-ignore:` glob list scraped from the repo's `pull_request`-triggered workflows (empty string when the repo has no such path, meaning every PR runs the same CI regardless of changed files). [Steady-state.md step C](./steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action)'s CI-cheap bias reads it to decide whether preferring a cheap candidate under a backpressure hold is even possible on this repo. The whole `ci_capacity` object is never mutated after the initial write; it does not need `update` write-through wiring for the rest of the session's life.

`last_backpressure_check` ([#1414](https://github.com/mattsears18/shipyard/issues/1414)) is written every turn [steady-state.md's queue-depth backpressure check](./steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action) runs its self-hosted branch (`.ci_capacity.shape == "self-hosted" && .ci_capacity.pool_total > 0`) — `.verdict` mirrors that turn's `ci_backpressure` invariant-line value (`"checked"` or `"held"`; never written for `n/a`/`skipped-hosted`, since those turns never enter the branch) and `.at` is the write's own UTC timestamp. It exists so a durable, session-scoped signal survives past the Bash-tool call that computed it — the in-memory `$ci_backpressure` shell variable does not. [`isolation: worktree` frontmatter](https://code.claude.com/docs/en/sub-agents#supported-frontmatter-fields)'s CI-backpressure gate ([`scripts/assert-ci-backpressure-checked.sh --live`](../../scripts/assert-ci-backpressure-checked.sh)) reads it to distinguish "the check ran recently" from "it plainly didn't," before ever considering blocking a backlog-slot-filling dispatch. Fire-and-forget write (never blocks the turn on its own success); read fresh, never cached, by the gate script.

`peer_sessions` ([#1204](https://github.com/mattsears18/shipyard/issues/1204)) is written once, at [setup step 1.65](./setup/01-repo-recovery.md#165-detect-live-peer-sessions-on-this-repo-1204), immediately after [step 1.6](./setup/01-repo-recovery.md#16-reap-orphan-session-files-cost-ledger-recovery)'s orphan-session sweep. `.count` is the number of OTHER live `/shipyard:do-work` sessions detected working this same repo (a peer session file whose mtime is within the freshness window AND whose `.repo` matches). `.claimed_targets` is the deduped union of every detected peer's `.in_flight[].target` set — the issue/PR numbers [step 4's peer-claimed drop rule](./setup/04-backlog-divert.md#4-fetch--rank-the-backlog) excludes from `raw_backlog` so this session never duplicates a peer's in-progress dispatch. Like `ci_capacity`, the whole object is a setup-time snapshot — resolved once and held for the rest of the session, never re-resolved mid-session; `.count` feeds [step E's invariant line](./steady-state.md#e-invariant-line-end-of-every-steady-state-turn) as `peers=<n>`.

`session_end` ([#1252](https://github.com/mattsears18/shipyard/issues/1252)) starts `null` at `init` and is stamped exactly once, at [cleanup-summary.md's end-of-session cleanup step 0](./cleanup-summary.md#end-of-session-cleanup), immediately before any worktree reaping starts and well before [step 8](./cleanup-summary.md#end-of-session-cleanup) removes the file. It closes the gap the issue's own observation table names directly: three of six recent sessions on the maintainer's machine terminated with a non-empty `.in_flight` and no record of why, because the orchestrator process ended before it ever reached its normal exit path — indistinguishable after the fact from a session that finished cleanly. When present, the object is `{ "reason": "completed" | "bounded-exit" | "user-stop", "detail": "<free text>" | null, "recorded_at": "<ISO-8601 UTC>" }`. `reason` is derived mechanically from state the session already computed while exiting drain — never hand-narrated — per the three-way split in [cleanup-summary.md's own step 0](./cleanup-summary.md#end-of-session-cleanup): `user-stop` when the drain-exit reason is the soft-drain second-stop-signal case; `completed` when the drain exited via `all PRs settled` AND every `session_prs` entry landed merged (no `blocked:ci` / rebase-blocked / still-pending residue) AND the [completion ledger](./setup/04f-completion-ledger.md)'s dispatchable (bucket 10) and unaccounted (bucket 11) counts are both `0`; `bounded-exit` otherwise (the `max_drain_hours` ceiling fired, or an unfinished tail remains). The write goes through the dedicated `record-session-end` subcommand (below) rather than a bare `update --set` so the reason enum is validated at write time. **Non-fatal by design** — same posture as every other write-through call (see [Failure mode](#failure-mode--write-through-breakage) below): a failed stamp is logged and the session proceeds; recording why a session ended must never itself block it from ending. Because [step 8](./cleanup-summary.md#end-of-session-cleanup) deletes the file shortly after, `session_end` matters in three places: the [End-of-session summary](./cleanup-summary.md#end-of-session-summary)'s `Session end:` line (rendered from the same in-hand values, not re-read from the file); the on-disk HTML report (also written before deletion); and — for the abnormal case the issue actually reports, a predecessor that died before ever reaching this step — the **next** session's orphan sweep (`scripts/sweep-orphan-sessions.sh`), which now surfaces a still-null `.session_end` on a dead-PID file as `[abnormal-exit: no session_end recorded, in_flight=<n>]`, and `session-state.sh cleanup --reap-audit`'s `reaped_session_end` / `reaped_in_flight_count` fields, which persist the same signal into `~/.shipyard/reap-audit.jsonl` past the file's own deletion.

`unfiltered_open_count` / `me_assigned_open` / `last_fresh_fetch` ([#1246](https://github.com/mattsears18/shipyard/issues/1246)) are the [step E invariant-line](./steady-state.md#e-invariant-line-end-of-every-steady-state-turn) tokens that detect a regression in the client-side eligibility filter itself — the mechanism [#332](https://github.com/mattsears18/shipyard/issues/332) and [#1194](https://github.com/mattsears18/shipyard/issues/1194) each shipped once, twice, and which had no field to write into until this issue. All three default to their init value (`0`, `0`, `null`) and are stamped together, from the SAME wide-fetch payload and BEFORE classification runs, at exactly two sites: [steady-state.md step C's lightweight backlog re-check](./steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action) (every dispatch) and [drain.md's termination-assertion step 4](./drain.md#termination-assertion) (the fresh-fetch verification immediately before handoff to drain). Both call `scripts/backlog-filter.sh summary --me <login>` against the wide fetch — the same pure-function split `classify` uses, so the count can never drift from what `classify` itself would report. `unfiltered_open_count` is the wide fetch's raw array length (the universe BEFORE the eligibility filter runs); `me_assigned_open` narrows that to the count of returned issues whose `assignees` includes the gh-authenticated user — the bucket a wrong assignee filter is most likely to silently erase (a healthy filter's output always includes every `@me`-assigned open issue somewhere in `in_flight` ∪ `ready_issues` ∪ `raw_backlog` ∪ `deferred_issues` ∪ issues already closed this session). `last_fresh_fetch` is the current UTC `HH:MM:SS` at the moment the wide fetch returns — the [step E terminating-idle-proof staleness guard](./steady-state.md#e-invariant-line-end-of-every-steady-state-turn) refuses to declare "backlog empty" on a value older than 60 seconds. `unfiltered_open_count` also feeds [`setup/04f-completion-ledger.md`](./setup/04f-completion-ledger.md)'s `<total>` — the completion ledger's own "every open issue must land in exactly one bucket" gate is what makes a `raw_backlog=0`-but-`unfiltered_open_count=29` divergence loud rather than merely recorded: an issue the ledger can't place lands in bucket 11 (Unaccounted) and blocks termination outright, rather than being a token nobody reads. **The "wrong assignee filter" reading of `me_assigned_open` applies only when `backlog.respect_assignees == true` — issue [#1248](https://github.com/mattsears18/shipyard/issues/1248), which defaults the assignee-based drop clause OFF.** With the default, `classify` never drops on assignee, so the field is no longer a filter-defect detector for that purpose; it remains a plain self-assigned-open-issue count, still stamped the same way, still consumed by the completion ledger's divergence check. See [steady-state.md's own purpose-narrowing note](./steady-state.md#e-invariant-line-end-of-every-steady-state-turn) for the full explanation.

The `tokens` block is the **per-session** cost ledger — written through `session-state.sh bump-tokens` after each Agent dispatch returns. `.tokens.totals` is cumulative across the session (including orchestrator overhead); `.tokens.per_issue[<N>]` and `.tokens.per_pr[<M>]` are attribution buckets the cost-comment hook in [step A reconcile](./steady-state.md#a-reconcile-the-return) reads when posting `<!-- do-work-cost-tracking -->`-marked comments on the resulting issue/PR. The persistent cross-session ledger at `~/.shipyard/cost-history.jsonl` is [#163](https://github.com/mattsears18/shipyard/issues/163)'s scope — out of scope here. `per_invocation` is a ring buffer capped at the most-recent 200 entries; each entry carries `degraded: <bool>`. `degraded_attribution_count` counts the degraded bumps (see [step A.0 degraded path](./steady-state.md#degraded-path--total-only-fallback-when-the-harness-usage-block-lacks-the-breakdown) — harness-gap fallback from [#279](https://github.com/mattsears18/shipyard/issues/279)) and, together with `per_invocation | length`, drives the [end-of-session banner](./cleanup-summary.md#end-of-session-summary) — which branches on the ratio so "100% of dispatches degraded" reads as a structural harness shape rather than per-dispatch degradation ([#295](https://github.com/mattsears18/shipyard/issues/295)).

### Helper script — `plugins/shipyard/scripts/session-state.sh`

Every write goes through the helper, which writes to `<target>.tmp.<pid>` and atomically renames into place. **Never edit the JSON directly with `Edit` / `Write` / `jq` / a shell heredoc** — none of those preserve the atomic-rename contract. Subcommands:

```bash
# Set up the session file at startup (step 0.5). init stamps a .pid (default
# $PPID) so the orphan-sweep (setup.md step 1.6) can skip via `is-active`
# while this process is alive — defends against #253's concurrent-sweep race.
plugins/shipyard/scripts/session-state.sh init \
  --session-id "<session-id>" \
  --repo "<owner/repo>" \
  --concurrency <N> \
  --soft-collision-concurrency <N>

# Read the whole file or one jq path.
plugins/shipyard/scripts/session-state.sh read --session-id "<session-id>" [--path ".session_prs"]

# Merge jq assignments atomically. --allow-degraded-init: RECOMMENDED (#281 — survives mid-session file disappear).
# Never put a non-empty JSON object literal in a --set value: post-relocation
# the isolation guard refuses it (#1561). Assign per field, or Write the
# expression to a file and pass --set-file <path> (one expression per file,
# newlines allowed; applied in order with any --set flags).
plugins/shipyard/scripts/session-state.sh update --session-id "<session-id>" \
  --set '.session_prs += [96]' --set '.main_ci.status = "green"' --allow-degraded-init --degraded-init-repo "<owner/repo>"
plugins/shipyard/scripts/session-state.sh update --session-id "<session-id>" \
  --set-file "<worktree>/.shipyard-scratch/state-expr.jq"

# Create/replace one .in_flight slot (#1561) — plain flags only. started_at
# defaults to now; progress_* start null; version_slot / worktree_path are
# omitted unless passed. Repeat --hard-path / --soft-path per path. Accepts
# the same --allow-degraded-init / --degraded-init-repo / --expected-repo /
# --skip-repo-check flags as update.
plugins/shipyard/scripts/session-state.sh set-slot --session-id "<session-id>" \
  --slot-id "<slot-id>" --kind issue --target "#<N>" \
  --agent-id "<agent-id>" --model "<alias-or-default>" \
  [--started-at <iso>] [--version-slot <X.Y.Z>] [--worktree-path <abs>] \
  --hard-path "<path>" --soft-path "<path>"

# Remove one .in_flight slot (#1561). Idempotent on an absent slot.
plugins/shipyard/scripts/session-state.sh release-slot --session-id "<session-id>" --slot-id "<slot-id>"

# Liveness check for the orphan-sweep (setup.md step 1.6). Exit 0 when file
# exists AND .pid is alive (kill -0); exit 1 otherwise.
plugins/shipyard/scripts/session-state.sh is-active --session-id "<session-id>"

# Bump token-usage counts after an Agent dispatch returns. --issue / --pr
# optional. --allow-degraded-init + --degraded-init-repo REQUIRED (see
# steady-state.md A.0). Strict path — harness <usage> exposes the breakdown:
plugins/shipyard/scripts/session-state.sh bump-tokens \
  --session-id "<session-id>" --issue <N> --pr <M> \
  --input <N> --output <N> --cache-read <N> --cache-creation <N> \
  --mode <mode> --model <model-id> --allow-degraded-init --degraded-init-repo "<owner/repo>"
# Degraded path (#279 — <usage> total-only): REPLACE the four breakdown flags
# with `--input <total_tokens> --degraded-total-only` (mutually exclusive; #320).

# Read aggregated token data. --format json (default) or comment (Markdown
# body with the <!-- do-work-cost-tracking --> sentinel for idempotent posting).
plugins/shipyard/scripts/session-state.sh read-tokens \
  --session-id "<session-id>" --pr <M> --format comment

# Set progress counters on an in-flight slot (feeds /shipyard:status; #167).
plugins/shipyard/scripts/session-state.sh set-progress \
  --session-id "<session-id>" --slot "<slot-id>" --current 4 --total 7

# Stamp a terminal reason on the way out (issue #1252). --reason is a
# closed enum (usage-error on anything else); --detail is optional
# free-text elaboration. Shares --allow-degraded-init / --degraded-init-repo
# and --expected-repo / --skip-repo-check with `update`.
plugins/shipyard/scripts/session-state.sh record-session-end \
  --session-id "<session-id>" --reason completed \
  --detail "drain exited via all PRs settled; session_prs merged=3 blocked:ci=0 rebase-blocked=0 pending=0"

# Remove the file at end-of-session (cleanup step).
plugins/shipyard/scripts/session-state.sh cleanup --session-id "<session-id>"
```

Exit codes:

- `0` — success.
- `2` — `init` refused to clobber an existing file (use `--force` if the clobber is intentional). Protects against accidentally re-initialising a session that's still active.
- `3` — `read` or `update` ran on a session file that does not exist. Distinct from `0` so the orchestrator can branch on "first-write to a session that wasn't initialised" vs "successful read."
- `64` — usage error (bad subcommand, missing required arg). Mirrors `sysexits.h`'s `EX_USAGE`.
- `65+` — internal helper failure (jq missing, write permission denied). Never papered over — the orchestrator should surface these so the user sees why state stopped updating.

### When the orchestrator writes through

Every state-mutation site writes through. Batch writes at end-of-turn — one `update` call with multiple `--set` flags, not a flurry per field. See [RATIONALE → Write-through cadence](../do-work-RATIONALE.md#write-through-cadence--why-batched-per-turn).

| Site | What changes | When |
|---|---|---|
| [Step 0.5 → step 1.5](./setup/01-repo-recovery.md#15-initialise-the-session-state-file) | Session file created with `init`; `ci_capacity` written through immediately after (from [step 1.36](./setup/01-repo-recovery.md#136-detect-ci-executor-pool-capacity-and-clamp-toward-it-1141)'s and [step 1.37](./setup/01-repo-recovery.md#137-detect-ci-cheap-path-availability-1157)'s reads) | once, at startup |
| [Step 1.65](./setup/01-repo-recovery.md#165-detect-live-peer-sessions-on-this-repo-1204) | `peer_sessions` | once, at setup |
| [Step 4](./setup/04-backlog-divert.md#4-fetch--rank-the-backlog) | `raw_backlog`, `trusted_authors` (if dynamically loaded) | once, post-fetch |
| [Step 4.5](./setup/04-backlog-divert.md#45-divert-checks-main-ci--pr-pileup) | `main_ci`, `divert_queue` | at setup + step D refresh |
| [Step 5](./setup/04j-failing-pr-snapshot.md#5-snapshot-failing-prs) | `failed_prs`; [step 5.7](./setup/04j-failing-pr-snapshot.md#57-seed-inherited-dirty-prs-into-session_prs-cross-session-drain-hand-off) seeds `session_prs` with inherited DIRTY-but-green `@me` PRs (deferred to step D at C=1) | once, post-snapshot |
| [Step 6](./setup/06-scope-preflight.md#6-initial-scope-pre-flight) | `scope_bg_count` (incremented when batch fires; decremented as each background agent returns), `ready_issues` (appended as results arrive), `deferred_issues` (with `provenance: "scope-agent"` and `deferred_at` on new entries) | rolling, as background scope agents return |
| Step 7 (initial pool fill) | `in_flight`, `soft_caps` | per dispatch |
| [Step A reconcile](./steady-state.md#a-reconcile-the-return) | `in_flight` (release), `session_prs`, `failed_prs`, `deferred_issues` (via blocked), `awaiting_external` (append, on an `awaiting-external` park — #1390), `tokens` (via `bump-tokens`) | every completion |
| [Step B release](./steady-state.md#b-release-the-slot) | `in_flight` (slot removal), `soft_caps` (decrement) | every completion |
| [Step C dispatch](./steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action) | `in_flight` (new slot), `ready_issues` (consumed), `failed_prs` (consumed), `soft_caps` (increment), `raw_backlog` (post-refill), `unfiltered_open_count` / `me_assigned_open` / `last_fresh_fetch` (#1246, from the same lightweight backlog re-check's wide fetch), `paused_on_environment` (set, when the [session-wide pause trigger](./environmental-pause.md) fires — #1402) | every dispatch |
| [Step D refresh](./steady-state.md#d-periodic-refresh) | `awaiting_external` (re-poll: `polls` bumped, entry removed on terminal-probe resume or deadline expiry — #1390), `main_ci`, `divert_queue`, `failed_prs`, `session_prs` (inherited/mid-session DIRTY-but-green `@me` PRs adopted for drain — #373), `scope_bg_count` (incremented on refill burst fire; decremented as each background agent returns), `ready_issues` (appended as results arrive), `raw_backlog`, `deferred_issues` | every full-pool refresh |
| [`watch-resume-probe.sh` resume notification](./environmental-pause.md) | `paused_on_environment` (cleared to `null` — on the watcher's `resumed` line before a fresh backlog fetch, or on `held-timeout`/`error` before degrading to a hand-back) | on the `Monitor`'s terminal-line notification only (issue #1402) |
| [Drain termination-assertion step 4](./drain.md#termination-assertion) | `unfiltered_open_count` / `me_assigned_open` / `last_fresh_fetch` (#1246, from the fresh-fetch verification, before classification runs), plus `raw_backlog` / `investigate_candidates` (net-new appends, if any) | once, immediately before handoff to drain |
| Drain phase | `drain.active`, `drain.polls`, `session_prs`, `failed_prs`, `in_flight` | every poll |
| [Cleanup step 0](./cleanup-summary.md#end-of-session-cleanup) | `session_end` (#1252, via `record-session-end` — derived from drain-exit data already in hand, never re-queried) | once, before any reaping starts |
| [Cleanup step 7](./cleanup-summary.md#end-of-session-cleanup) | Session record flushed to `~/.shipyard/cost-history.jsonl` via `cost-history.sh flush` | last, immediately before the session file is removed |
| [Cleanup step 8](./cleanup-summary.md#end-of-session-cleanup) | Session file removed via `session-state.sh cleanup` | last, after the user-facing summary prints |

### Failure mode — write-through breakage

If `session-state.sh update` fails (exit code != 0), log `[session-state] update failed: <exit code> — session file out of sync with working memory; continuing` and continue the turn. Working memory is authoritative; the next turn's update cycle re-attempts the write. Do not stall dispatch on a file-write failure. Mid-session exit-3 (file disappeared) is handled inline by `--allow-degraded-init` (issue #281) — the canonical `update` template above passes it by default. See [RATIONALE → Failure mode](../do-work-RATIONALE.md#failure-mode--write-through-breakage) for the full failure-mode discussion.

### Cost-tracking write-through

After every Agent dispatch returns, the orchestrator extracts the dispatch's `usage` payload (input/output/cache_read/cache_creation token counts; model id) and attributes it via `bump-tokens` before reconciling the return string. **This is not optional, and the call site is [step A.0](./steady-state.md#a0-attribute-the-dispatchs-token-usage-mandatory--before-any-return-string-parsing) — not this section.** The numbered first-step framing is load-bearing: a previous version of these docs described the hook only in prose here and in the write-through table below, and the orchestrator silently skipped attribution across an entire 16-PR session ([#197](https://github.com/mattsears18/shipyard/issues/197)). The mechanical contract lives at the dispatch site (A.0); this section documents the *rules* the helper call follows.

The attribution rules:

- **Worker dispatches with an associated issue or PR** — pass `--issue <N>` (issue-work, fix-checks-only) and/or `--pr <M>` (fix-checks-only, fix-rebase, fix-main-ci, fix-failing-prs-batch) along with `--mode <mode>` and `--model <id>`. Both the per-issue/per-pr bucket and `.tokens.totals` get bumped; a `per_invocation` ring-buffer entry is recorded for trace.
- **Orchestrator-side overhead** — calls without `--issue` or `--pr` only bump `.tokens.totals`. Use this for the orchestrator's own per-turn token cost (the scope-pre-flight pass at step 6, the periodic refresh at step D, etc.) — those don't attribute to a specific PR.

The hook is observational and write-only — `bump-tokens` never affects dispatch decisions. If the helper call errors, log `[bump-tokens] attribution failed: <exit code>; continuing` and proceed; the dollar-cost data point is lost but the session marches on.

The persistent cross-session ledger at `~/.shipyard/cost-history.jsonl` is [#163](https://github.com/mattsears18/shipyard/issues/163)'s scope — out of scope here. This section covers the per-session in-memory accounting only; the artifact comments posted on the issue/PR are the durable export.

**This accounting is post-hoc, not pre-emptive — and stays that way.** The Claude API's beta "Task Budgets" feature (`output_config.task_budget`) gives a dispatch a token ceiling it's aware of *while running*; shipyard has no equivalent because the feature is not exposed on the `Agent`-tool dispatch surface this section's write-through attributes *after the fact* — confirmed unsupported on Claude Code, dual-sourced against both the platform docs and the `Agent` tool's own parameter surface. See [RATIONALE → Task Budgets](../do-work-RATIONALE.md#task-budgets--not-exposed-on-the-agent-dispatch-surface-spiked-and-closed-negative-765) for the full investigation and why no `budgets.<mode>` config surface follows from it.
