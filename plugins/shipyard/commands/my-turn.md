---
description: Walk the human through everything that genuinely needs a person — decisions and judgment calls /do-work can't complete. Collects every open decision across all gated issues in one uninterrupted run, batch-records them, then walks the remaining action items one at a time until the human-only queue is empty. Interactive and human-facing; pairs with /shipyard:do-work as the human-driven counterpart.
argument-hint: [--repo owner/repo] [--all] [--limit N] [--chrome-prompt]
---

# /my-turn

Answer *"what do you need from me right now?"* by **getting you through the human-only backlog in one session** (issue [#635](https://github.com/mattsears18/shipyard/issues/635)) — **every open decision first, asked back-to-back with no work in between**, then one batched commit that records them all, then the remaining action items walked one at a time until the queue is empty (issue [#1070](https://github.com/mattsears18/shipyard/issues/1070)). The queue is deliberately narrow: **only items that genuinely require a human** — a decision, a judgment call, anything that **cannot** be completed by `/shipyard:do-work`. Code work and browser-completable operator actions (close a superseded PR, paste a CI secret, toggle a non-security console setting) belong to the operator layer, not here, and are filtered out (see [Human-only queue filter](#human-only-queue-filter)).

**`/my-turn` is a router, not an investigator** (issue [#1073](https://github.com/mattsears18/shipyard/issues/1073)). It answers *what needs you and where to look* — never *why something is broken*. Root-causing a failure (reading CI logs, drilling into a run's jobs, tracing a stack trace) is `/shipyard:do-work`'s work, not this command's, regardless of how high the item ranks — see [Performance budget → Per-item investigation ceiling](#performance-budget) for the concrete bound and [Don't](#dont) for the rule this promise cashes out to.

**Answering is decoupled from acting.** You should never sit waiting on Claude between two of your own answers — no comment gets posted, no label gets edited, and no codebase gets re-read mid-run. See [Walkthrough mode](#walkthrough-mode-default) for the three phases.

This is the **human counterpart** to the two autonomous loops — the three-command division of labor:

| Command | Role | Loops? |
|---|---|---|
| [`/shipyard:do-work`](./do-work.md) | Autonomous continuous loop — **code work only** | yes (autonomous) |
| [`/shipyard:do-work`](./do-work.md) (operator-inclusive by default) | The `/do-work` loop **plus** driving Chrome to complete browser-completable operator actions | yes (autonomous) |
| **`/my-turn`** (this command) | Surface **only** genuinely human-required items; collect every open decision in one run, batch-record them, then walk the remaining action items until the human-only queue is empty | yes (interactive, human-paced) |

**`/my-turn` stays human-facing and non-autonomous.** It dispatches no *mutating* agents and shares none of `/do-work`'s worker/execution machinery — the autonomous loop is `/do-work`'s job, and `/my-turn` is the deliberately separate human-paced counterpart. (Its one concurrency carve-out is [Phase 1](#phase-1--collect-no-mutation-no-work)'s **read-only** bulk context pass, which may fan out readers to prepare the questions; see [Don't](#dont).) The only state it mutates is what the human directs by answering: for a [decision-gated issue](#decision-gated-walkthrough) it reuses the mutating sibling [`/shipyard:resolve-decisions`](./resolve-decisions.md)' interactive walkthrough (restate → options → recommendation → record the answers + clear the gate, per [#566](https://github.com/mattsears18/shipyard/issues/566)) — with the record step [deferred](./resolve-decisions.md#firing-mode--immediate-default-vs-deferred-batch-caller) to a single batched commit. Everything else is surfaced for the human to act on; the command advances when *they* finish an item, not when an agent does.

Pass `--chrome-prompt` to switch into **chrome-prompt mode**: the entire visible output is a single copy-paste-ready prompt block for the [Claude for Chrome browser extension](https://chrome.google.com/webstore/detail/claude-for-chrome), with unmistakable copy dividers and nothing else above or below it (no walkthrough prompts, no ranked list). The user highlights the block, pastes it into the extension, and the extension acts. This is text-emission only — no MCP, no Claude Code execution; the deliverable is the prompt itself. (Distinct from `/do-work`, which drives Chrome directly.)

Pairs with [`/shipyard:do-work`](./do-work.md) — that one is the agent-driven loop (Claude works the backlog autonomously); this one is the human-driven counterpart (the user works through what the loops *couldn't* resolve). For the autonomous loop that ALSO drives browser-completable operator actions, see [`/shipyard:do-work`](./do-work.md) (operator-inclusive by default; explicitly `/do-work`).

**Bucket ownership.** `/do-work` and `/my-turn` are meant to jointly partition the backlog with no gap and no overlap. [`do-work/setup/backlog-ownership.md`](./do-work/setup/backlog-ownership.md) is the canonical bucket→owner table both commands are checked against — this file's [survey passes](#survey-passes) and [Human-only queue filter](#human-only-queue-filter) implement `/my-turn`'s slice of it (issue [#1076](https://github.com/mattsears18/shipyard/issues/1076)).

## Args

`$ARGUMENTS` may include:

- **--repo owner/repo** (optional, default: cwd's repo via `gh repo view --json nameWithOwner -q .nameWithOwner`). If not in a repo, ask via `AskUserQuestion`.
- **--all** (optional, default off): render the **full ranked list** as a static, non-interactive snapshot instead of walking the queue. Without this flag (and without an explicit `--limit N > 1`), the command runs the **interactive advancing walkthrough** — it walks you through the human-only queue one item at a time, advancing until it's empty (see [Walkthrough mode](#walkthrough-mode-default)). Use `--all` when you want to *see* the whole human-blocked backlog at a glance without being walked through it. In `--chrome-prompt` mode, mirrors this same single-vs-all behavior: without `--all`, the prompt covers only the #1 action; with `--all`, the prompt covers all human-blocked actions batched into a single extension prompt.
- **--limit N** (optional, default `25` *when the list renders*): cap the printed list at N items. Only meaningful in list mode — i.e. when `--all` is passed, or when `--limit N` is given with `N > 1` (which itself opts into list-snapshot mode). `--limit 1` surfaces only the top-ranked item as a one-shot snapshot (no advancing walkthrough). Items beyond the cap are summarized as `… and <K> more (rerun with --limit <K+N> to see all)`. In `--chrome-prompt` mode, `--limit` caps the number of actions included in the batched prompt when combined with `--all`.
- **--chrome-prompt** (optional, default off): switch into **chrome-prompt mode** — the entire visible output is a single copy-paste-ready prompt block suitable for the Claude for Chrome browser extension. Unlike every other mode, chrome-prompt mode's queue is the **[Chrome-completable queue filter](#chrome-completable-queue-filter)**, not the [Human-only queue filter](#human-only-queue-filter) — its consumer is a browser extension, not a human at a terminal, so it draws from `agent-console` / browser-completable items rather than human decisions ([#1092](https://github.com/mattsears18/shipyard/issues/1092)). The output is prompt-only: no walkthrough, no ranked list, no preamble. The copy region is marked with unmistakable dividers. After the prompt block, a clearly-separated section lists anything that cannot be done by the extension — manual/external steps, things needing maintainer auth, and every genuine human-only decision item the queue itself excludes from the prompt; this section is omitted entirely when empty. See [Chrome-prompt mode](#chrome-prompt-mode---chrome-prompt) for the full render spec. **Composes with `--all`**: without `--all`, the prompt is built from the #1-ranked *browser-completable* action only; with `--all`, all browser-completable actions are batched into one prompt (human-only items still populate the trailing "can't be automated" section either way).

**Mode resolution.** The command runs in one of three modes:

- **Walkthrough mode (default)** — no `--all`, no `--limit N` with `N > 1`, and no `--chrome-prompt`. Run the three phases (see [Walkthrough mode](#walkthrough-mode-default)): **collect** every decision across all decision-gated issues with no mutation in between, **commit** them in one batch, then **walk** the remaining action items one at a time until the queue is empty. This is the default because the command's promise is to *get you through* the human-only backlog, not just print it — and because answering N decisions shouldn't cost N round-trips of waiting.
- **List-snapshot mode** — `--all` is present, OR `--limit N` is given with `N > 1`, AND `--chrome-prompt` is NOT present. Print the full ranked list as a static snapshot (capped at `--limit`, default `25`), no walkthrough. `--all` with no `--limit` shows every item. Use this to *eyeball* the human-blocked backlog without being walked through it.
- **Chrome-prompt mode** — `--chrome-prompt` is present. The entire output is a single copy-paste-ready prompt block (see [Chrome-prompt mode](#chrome-prompt-mode---chrome-prompt)). `--all` and `--limit` still govern how many actions are included in the prompt, but the outer render is always prompt-only.

`--all` and `--limit` compose within list-snapshot and chrome-prompt modes: `--all --limit 10` (list-snapshot) builds a static top-10 human-blocked list; `--chrome-prompt --all --limit 10` builds a batched chrome-prompt covering the top 10 *browser-completable* actions (per the [Chrome-completable queue filter](#chrome-completable-queue-filter) — a different queue than list-snapshot's). In `--limit 1` snapshot mode and chrome-prompt-without-`--all` mode, `--limit` has no effect (only one item is surfaced).

## Setup

### 1. Resolve repo

```bash
gh repo view --json nameWithOwner -q .nameWithOwner   # if --repo omitted
```

### 2. Resolve the authenticated user

The "me" in "what do you need from me right now?" is whoever the local `gh` is authenticated as — the survey ranks items by *that user's* relationship to each PR/issue (requested reviewer, assignee, mentioned in comment, etc.). Resolve once at setup:

```bash
gh api user --jq .login   # → $ME
```

If `gh` is not authenticated, abort with a clear error directing the user to `gh auth login`.

**`$ME` names this repo's automation identity — not "the human," even though the two are the same login** ([#1089](https://github.com/mattsears18/shipyard/issues/1089)). On a shipyard-driven repo, `/shipyard:do-work` workers, auditors, and scope agents all comment, file, and act through the maintainer's own authenticated `gh` — a worker's bail explanation, an auditor's finding, a scope agent's defer note are all `author.login == $ME`, exactly like a comment the maintainer typed themselves. Any signal below that compares `author != $ME` (or `author == $ME`) to distinguish "a human did this" from "automation did this" is testing the wrong thing — it degenerates to a tautology or a vacuous-false on a repo shape where every actor shares one login. Two signals were found broken by exactly this collapse and fixed by testing **intent/content markers instead of identity** — see [Pass B's last-signal bullet](#pass-b--open-issues) and [Pass C's skip-gate](#pass-c--unanswered-review-comments-on-mes-prs) below. Any *new* signal reasoning about who-authored-what should default to the same content-based approach rather than re-deriving an identity comparison that can't hold here.

### 3. Resolve the untriaged-issue human-ownership config gate ([#1077](https://github.com/mattsears18/shipyard/issues/1077))

An **untriaged-looking issue** — one matching investigate mode's detection signals (a bot-shaped trusted author, or a symptom-shaped body; see [`04d-investigate-routing.md`](./do-work/setup/04d-investigate-routing.md)) — is `/shipyard:do-work`'s by default: it is routed to `investigate_candidates` and dispatched via investigate mode, so under the default config there is nothing for `/my-turn` to surface (see [`backlog-ownership.md` bucket 5](./do-work/setup/backlog-ownership.md#ownership-table)). `triage.investigate_dispatch: false` is the **one** configuration under which these become genuinely human-owned (the pre-#556 skip-and-surface behavior). Resolve it once at setup so Pass B's untriaged-issue signal below knows whether to fire:

> **This bucket is identified by re-running the detection predicate, not by reading a label** ([#1120](https://github.com/mattsears18/shipyard/issues/1120)). It keyed off `needs-triage` until that label was retired. Reuse [`backlog-filter.sh`](../scripts/backlog-filter.sh)'s `is_investigate_signal` rather than hand-rolling the match — a second copy of that predicate is exactly the drift that script exists to prevent.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
investigate_dispatch=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get triage.investigate_dispatch 2>/dev/null || echo "true")
```

### 4. Resolve the stale-undispatched-issue threshold ([#1078](https://github.com/mattsears18/shipyard/issues/1078))

Pass B's "authored by `$ME`, never dispatched" signal (below) gates on an age threshold so a freshly-filed issue that simply hasn't had its turn isn't misread as a misconfiguration. Resolve it once at setup — the `CLAUDE_PLUGIN_ROOT` export is repeated here rather than assumed carried over from step 3, since shell variables don't survive across separate tool calls:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
stale_undispatched_days=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get my_turn.stale_undispatched_days 2>/dev/null)
[[ "$stale_undispatched_days" =~ ^[0-9]+$ ]] || stale_undispatched_days=7
```

### 5. Resolve the per-item investigation-depth ceiling ([#1073](https://github.com/mattsears18/shipyard/issues/1073))

[Phase 3](#phase-3--walk-the-rest)'s per-item action derivation is capped at a small, fixed number of tool calls beyond the survey projection (see [Performance budget → Per-item investigation ceiling](#performance-budget)) so ranking an item highly is never license to root-cause it. Resolve the ceiling once at setup — the `CLAUDE_PLUGIN_ROOT` export is repeated here rather than assumed carried over from step 4, since shell variables don't survive across separate tool calls:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
max_diagnostic_reads_per_item=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get my_turn.max_diagnostic_reads_per_item 2>/dev/null)
[[ "$max_diagnostic_reads_per_item" =~ ^[0-9]+$ ]] || max_diagnostic_reads_per_item=1
```

Default `1` — at most one extra read beyond the survey projection per item (e.g. a single `gh pr view` on the item's own number for a field Pass A's list projection omitted). `0` disables the extra read entirely — the rendered action must come from the survey projection alone, or the item renders in its [degraded form](#performance-budget). Raising it is an explicit per-repo opt-in to deeper per-item grounding; it never licenses reading CI logs, drilling into a run's jobs, or otherwise establishing *root cause* — the [Don't diagnose](#dont) rule is unconditional regardless of this value.

### 6. Resolve the disposition-call detection toggle ([#1074](https://github.com/mattsears18/shipyard/issues/1074))

[Disposition-call detection](#disposition-call-detection-1074) below is a heuristic — completion-assertion phrase matching over a comment's text — and heuristics can misfire on a repo whose comment conventions don't match the assumed phrasing. Resolve the toggle once at setup so Pass A/B know whether to apply it — the `CLAUDE_PLUGIN_ROOT` export is repeated here rather than assumed carried over from step 5, since shell variables don't survive across separate tool calls:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
disposition_call_detection=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get my_turn.disposition_call_detection 2>/dev/null)
[[ "$disposition_call_detection" == "false" ]] || disposition_call_detection="true"
```

Default `true`. When `false`, skip the disposition-call signals entirely — a `needs-human-review` issue or draft PR that would otherwise match falls back to the pre-#1074 behavior (an ordinary `needs-human-review` item, walked in [Phase 3](#phase-3--walk-the-rest)).

### 7. Resolve the operator-phase assumption for the `agent-console` filter ([#1093](https://github.com/mattsears18/shipyard/issues/1093))

The [Human-only queue filter](#human-only-queue-filter) excludes `agent-console` items on the premise that `/shipyard:do-work`'s browser-operator phase drains them — true only under `/do-work`'s default invocation. `--no-operate` / `--hands-off` turns that phase off entirely, and under that opt-out `agent-console` items stay gated exactly like `needs-human-review` — nothing drains them. `--no-operate` / `--hands-off` is a **per-invocation CLI flag, not persisted state**, so `/my-turn` — a separate command invocation, possibly run hours or days after the `/do-work` session it's reasoning about — cannot observe which way the *last* `/do-work` run was actually started. Reading `/do-work`'s live session state to answer that directly is a distinct capability, tracked separately in [#1080](https://github.com/mattsears18/shipyard/issues/1080), and is **not** what this step does.

Until #1080 lands, `/my-turn` relies on a **declared** per-repo assumption the maintainer sets once — the same shape [#1077](https://github.com/mattsears18/shipyard/issues/1077) used for `triage.investigate_dispatch`, applied here to a knob `/my-turn` alone reads (there is nothing for `/do-work` itself to condition — its operator phase is already default-on). Resolve it once at setup — the `CLAUDE_PLUGIN_ROOT` export is repeated here rather than assumed carried over from step 6, since shell variables don't survive across separate tool calls:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
assume_operator_enabled=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get my_turn.assume_operator_enabled 2>/dev/null)
[[ "$assume_operator_enabled" == "true" || "$assume_operator_enabled" == "false" ]] || assume_operator_enabled="false"
```

**Default `true`** (declared in the schema — an unresolved `shipyard-config.sh get` call with no override returns `true`, matching `/do-work`'s own operator-inclusive-by-default posture) — the common case, where the maintainer runs a bare `/do-work`. Set `my_turn.assume_operator_enabled: false` in `shipyard.config.json` for a repo whose maintainer habitually runs `/do-work --no-operate` / `--hands-off` — this tells `/my-turn` those `agent-console` items are NOT being drained automatically, so it surfaces them in the human-only queue instead of filtering them to a pointer line. **A failed resolution (script missing, `jq` error, malformed output) degrades to `false` — surfacing, not hiding** — deliberately the *opposite* fallback direction from `disposition_call_detection` above: an uncertain config state should never silently reproduce the pre-#1093 unconditional-filter behavior that stranded every `agent-console` item under `--no-operate`.

**This is a declared assumption, not an observed fact.** If the maintainer's actual `/do-work` invocation pattern varies run to run, this knob will occasionally be wrong in either direction until [#1080](https://github.com/mattsears18/shipyard/issues/1080)'s session-state read lands — it is the best available approximation, not a fix for the underlying observability gap.

### 8. Resolve `ci.skip_drain_rebase` for the DIRTY-PR author-scoping gate ([#1075](https://github.com/mattsears18/shipyard/issues/1075))

Pass A's `mergeStateStatus: DIRTY` signal (below) is author-scoped to non-`@me` PRs on the premise that `/shipyard:do-work`'s drain-phase `fix-rebase` worker mode adopts and rebases `@me`-authored `DIRTY` PRs across sessions — see [`do-work/drain.md`](./do-work/drain.md#drain-protocol). That premise holds only while drain-phase rebase dispatch actually runs: `ci.skip_drain_rebase: true` turns it off entirely, for every author, so under that config nothing adopts a `@me` DIRTY PR either — the author-scoped exclusion would strand it, invisible to `/my-turn` (filtered by author) and untouched by `/do-work` (rebase dispatch disabled). This is the same config-conditional-ownership shape [#1093](https://github.com/mattsears18/shipyard/issues/1093) established for the `agent-console` filter (see [Setup step 7](#7-resolve-the-operator-phase-assumption-for-the-agent-console-filter-1093) above), applied here to an **existing** `/do-work`-side knob rather than a new `my_turn.*` one — `ci.skip_drain_rebase` already governs `/do-work`'s own drain-phase behavior, so there's nothing new to declare in the schema.

Resolve it once at setup — the `CLAUDE_PLUGIN_ROOT` export is repeated here rather than assumed carried over from step 7, since shell variables don't survive across separate tool calls:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
skip_drain_rebase=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get ci.skip_drain_rebase 2>/dev/null)
[[ "$skip_drain_rebase" == "true" || "$skip_drain_rebase" == "false" ]] || skip_drain_rebase="true"
```

`/do-work`'s own default for this knob is `false` (drain-phase rebase dispatch runs), so the common case scopes Pass A's DIRTY-PR signal to `author.login != $ME`. **A failed resolution (script missing, `jq` error, malformed output) degrades to `true`** — the opposite direction from `/do-work`'s own default, deliberately: an uncertain read must never cause `/my-turn` to silently apply the author-scoped exclusion (hiding a `@me` PR that might not actually be getting rebased) — surfacing every DIRTY PR, regardless of author, is always the safe failure mode. This mirrors `assume_operator_enabled`'s degrade-to-surfacing direction above, not `disposition_call_detection`'s degrade-to-default direction.

**Two carve-outs preserve visibility for a `@me` DIRTY PR even under the default (`ci.skip_drain_rebase: false`)** — see the Pass A bucket below: a `@me` DIRTY PR that also carries `blocked:ci` is already caught, at full priority, by the separate `blocked:ci` signal (an observable "given up" label, unrelated to author). A `@me` DIRTY PR that `/do-work`'s drain-phase rebase has genuinely given up on for a *rebase-specific* reason (`rebase_blocked_prs` — a non-trivial conflict — or the 3-successful-rebase rate-limit cap) has no such observable signal: both states are per-session, in-memory drain bookkeeping ([`drain.md`](./do-work/drain.md#drain-protocol)) that's never persisted to a label or anything else `gh` can read. Per [#1075](https://github.com/mattsears18/shipyard/issues/1075): prefer keeping a `@me` DIRTY PR visible at the bottom of its tier over dropping it silently — a false negative here strands the PR with no path to anyone.

### 9. Resolve `/do-work`'s live session state (optional enrichment) ([#1080](https://github.com/mattsears18/shipyard/issues/1080))

`/my-turn` and `/do-work` communicate through exactly one channel by default: GitHub labels — `/my-turn` reads no `/do-work` session state on its own. This step adds a second, best-effort read of `/do-work`'s own on-disk session file, used **only** to suppress items a live session is already working on and to cheaply enrich the default-branch CI read (see [the default-branch CI line](#default-branch-ci-line) below) instead of re-deriving it by hand — the six-`gh`-call repro the originating issue measured. **Strictly optional, degrade-silently input: `/my-turn` MUST still produce a correct queue on a machine that has never run `/do-work`**, and a missing, unreadable, malformed, wrong-repo, or stale session file must never change the output shape, error, or warn — this step simply contributes nothing on any of those paths.

**1. Find the newest session file for this repo, best-effort** (mirrors [`/shipyard:status`'s](./status.md) own file-discovery idiom — `shopt -s nullglob` over `sessions/*.json`):

```bash
SHIPYARD_HOME="${SHIPYARD_HOME:-$HOME/.shipyard}"
session_id=""
if [[ -d "$SHIPYARD_HOME/sessions" ]]; then
  shopt -s nullglob
  candidates=("$SHIPYARD_HOME"/sessions/*.json)
  shopt -u nullglob
  newest_updated_at=""
  for f in "${candidates[@]}"; do
    repo_field=$(jq -r '.repo // empty' "$f" 2>/dev/null) || continue
    [[ "$repo_field" == "<owner/repo>" ]] || continue
    updated_at=$(jq -r '.updated_at // empty' "$f" 2>/dev/null) || continue
    [[ -n "$updated_at" ]] || continue
    # ISO-8601 UTC timestamps (fixed-width, always Z-suffixed) compare
    # correctly as plain strings — no date-parsing needed to find "newest".
    if [[ -z "$newest_updated_at" || "$updated_at" > "$newest_updated_at" ]]; then
      newest_updated_at="$updated_at"
      session_id=$(jq -r '.session_id // empty' "$f" 2>/dev/null)
      [[ -n "$session_id" ]] || session_id="$(basename "$f" .json)"
    fi
  done
fi
```

Any failure along the way — no `sessions/` dir (a machine that's never run `/do-work`), no file matching this repo, a corrupt file `jq` can't parse — simply leaves `session_id` empty. Treat that exactly like "this step doesn't apply": skip steps 2–3 below and proceed to the survey passes unchanged.

**2. Gate `.in_flight` on liveness — the same two-gate pattern `/shipyard:do-work`'s own step 1.6 orphan sweep uses** ([#253](https://github.com/mattsears18/shipyard/issues/253)):

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
live=0
if [[ -n "$session_id" ]]; then
  if "$CLAUDE_PLUGIN_ROOT/scripts/session-state.sh" is-active --session-id "$session_id" 2>/dev/null; then
    live=1
  fi
fi
```

**Why liveness, not just "the file exists."** The newest session file for a repo is very often a *dead* one — a `/do-work` run that finished normally, or crashed, leaves its file on disk until a future `/do-work` session's own step 1.6 sweep reaps it; `/my-turn` never runs that sweep itself, so a stale file can sit there indefinitely. `.in_flight` names workers that were live *at the last write* — reading it from a dead session's file would list agents that no longer exist, silently telling the human to skip an issue nobody is actually touching. `is-active` (the identical helper the orphan-sweep already uses) exits `0` only when the file's `.pid` is alive (`kill -0 $pid`); exit `1` covers a dead pid, a missing/null pid (an older shipyard version, or a degraded-recovery file), or the file having disappeared between step 1 and here. **Any of those degrades to `live=0` — `.in_flight` is read no further and nothing is suppressed on its account.** `.main_ci` (step 3) is read regardless of `$live` — see why there.

**3. Read the two fields this step consumes, gated as above:**

```bash
in_flight_issue_targets=""
in_flight_pr_targets=""
if [[ "$live" == "1" ]]; then
  in_flight_issue_targets=$("$CLAUDE_PLUGIN_ROOT/scripts/session-state.sh" read \
    --session-id "$session_id" \
    --path '.in_flight[] | select(.kind == "issue" or .kind == "investigate" or .kind == "spike") | .target' 2>/dev/null)
  in_flight_pr_targets=$("$CLAUDE_PLUGIN_ROOT/scripts/session-state.sh" read \
    --session-id "$session_id" \
    --path '.in_flight[] | select(.kind == "fix-checks" or .kind == "fix-rebase") | .target' 2>/dev/null)
fi

main_ci_status="unknown"
if [[ -n "$session_id" ]]; then
  main_ci_status=$("$CLAUDE_PLUGIN_ROOT/scripts/session-state.sh" read \
    --session-id "$session_id" --path \
    'if .main_ci.checked_at and ((now - (.main_ci.checked_at | fromdateiso8601)) <= 1800) then .main_ci.status else "unknown" end' \
    2>/dev/null)
  [[ -n "$main_ci_status" ]] || main_ci_status="unknown"
fi
```

`main_ci_status` is read **regardless of `$live`** — deliberately. Unlike `.in_flight` (a claim about what a *process* is doing right now, meaningless once that process is dead), `.main_ci` is a cached snapshot of a `gh`-observable fact (the default branch's CI state) that stays true independent of whether the writer is still running. Its own `checked_at` freshness bound (30 minutes — the same window [#253](https://github.com/mattsears18/shipyard/issues/253)'s reap sweep uses) is the correct staleness gate for a *fact*, in place of a liveness gate for a *process*; older than that, `main_ci_status` resolves to `"unknown"` and the rest of this step behaves as if it never ran.

**Consumed by:**
- The [Human-only queue filter](#human-only-queue-filter)'s in-flight suppression bullet and the [in-flight pointer line](#in-flight-pointer-line) in Output — `in_flight_issue_targets` / `in_flight_pr_targets`, gated by `$live`.
- The [default-branch CI line](#default-branch-ci-line) in Output — `main_ci_status`, gated by its own freshness.

**Left unconsumed, deliberately.** `deferred_issues`, `divert_queue`, `session_prs`, `rebase_blocked_prs`, and `rebase_success_counts` are read by nothing in this step. Each is a plausible future enrichment — `deferred_issues` most of all, since most of its defer classes already surface via an existing GitHub label (`needs-human-review` / `agent-console`) and only its two label-less classes (`untrusted-author`, `confirmed-blocker-still-open`) would add anything genuinely new — but folding all six fields into one pass risks exactly the kind of broad, hard-to-verify change this file's own [Don't](#dont) section keeps `/my-turn`'s *own* output away from. This step is a narrower, independently-verifiable slice: the two fields that directly answer the two concrete costs the originating [#1080](https://github.com/mattsears18/shipyard/issues/1080) repro measured — recommending an issue a live worker already owns, and re-deriving red-main state by hand across six `gh` calls. **This does not change [Setup step 7](#7-resolve-the-operator-phase-assumption-for-the-agent-console-filter-1093)'s behavior** — the session-state schema has no field recording whether a given `/do-work` run's operator phase was enabled, so step 7's declared `my_turn.assume_operator_enabled` config knob remains the only signal for that question; wiring a live read for it is future work, not part of this fix.

## Survey passes

Run each of the following passes in parallel (one batch of `gh` calls in a single message). Each pass produces a list of candidate items; the final ranking step merges them.

### Pass A — Open PRs

```bash
gh pr list --repo <owner/repo> --state open --limit 200 \
  --json number,title,url,isDraft,author,createdAt,updatedAt,labels,reviewDecision,reviewRequests,mergeStateStatus,statusCheckRollup,headRefName,closingIssuesReferences
```

From this projection, derive per-PR signals:

- **PR awaiting `$ME`'s review** — `reviewRequests` contains `$ME` (direct) OR `$ME` is on a team in `reviewRequests` (skip the team-lookup for v1; direct match only). `reviewDecision` is `REVIEW_REQUIRED`. Highest-leverage human action — `$ME` is literally what's blocking merge.
- **PR with `blocked:ci` label** — the orchestrator's 3-attempt fix-loop ran out; needs manual investigation.
- **PR with `mergeStateStatus: DIRTY`** that has been DIRTY for `>24h` — rebase didn't auto-fire, or auto-merge isn't armed. Whether this signal is author-scoped depends on `ci.skip_drain_rebase` (resolved once at [Setup step 8](#8-resolve-ciskip_drain_rebase-for-the-dirty-pr-author-scoping-gate-1075)) — the same config-conditional-ownership shape [#1093](https://github.com/mattsears18/shipyard/issues/1093) established for `agent-console`, applied here to `/do-work`'s drain-phase `fix-rebase` adoption of `@me`-authored DIRTY PRs ([#1075](https://github.com/mattsears18/shipyard/issues/1075)):
  - **`ci.skip_drain_rebase: false` (the default)** — scope to `author.login != $ME`. A `@me`-authored DIRTY PR is `/do-work`'s: drain-phase `fix-rebase` adopts and rebases it across sessions (see [`do-work/drain.md`](./do-work/drain.md#drain-protocol)), so it's excluded from this signal.
  - **`ci.skip_drain_rebase: true`** — no author scoping. Drain-phase rebase dispatch is off entirely regardless of author, so a `@me` DIRTY PR is exactly as much `/my-turn`'s problem as any other author's.
- **`@me`-authored PR with `mergeStateStatus: DIRTY` >24h, only when `ci.skip_drain_rebase: false`** ([#1075](https://github.com/mattsears18/shipyard/issues/1075)) — a fallback safety net for the exclusion above. `/do-work`'s two genuine rebase give-up states — `rebase_blocked_prs` (a non-trivial conflict the drain won't retry) and the 3-successful-rebase rate-limit cap — are **per-session, in-memory drain bookkeeping** ([`drain.md`](./do-work/drain.md#drain-protocol)), never persisted to a label or any other `gh`-observable signal, so `/my-turn` cannot distinguish "actively being rebased this session" from "quietly stuck with nothing draining it." Rather than drop these silently, they still surface here — at the [lowest leverage score](#secondary-sort--leverage-score-then-age-issue-565) within their tier, not the neutral score other DIRTY PRs get, so they're visible without crowding out a genuinely `/my-turn`-owned item. Excludes a `@me` DIRTY PR that already carries `blocked:ci` — that's caught, at full priority, by the bullet above ([Dedup](#dedup) applies if both would otherwise match).
- **Draft PR last updated >7 days ago** — stale; either finish or close.
- **PR with `CHANGES_REQUESTED` `reviewDecision` authored by `$ME`** — the user submitted a PR that someone (human or bot) asked for changes on; the ball is back on their court.
- **Draft PR carrying `needs-human-review` whose linked issue closed out from under it — a disposition call** ([#1074](https://github.com/mattsears18/shipyard/issues/1074), only when [`disposition_call_detection`](#6-resolve-the-disposition-call-detection-toggle-1074) is `true`). `closingIssuesReferences[].number` names the issue(s) this PR would close on merge; cross-reference against **Pass B's already-fetched open-issue set** (no extra `gh` call — both passes run in the same batch) — if a referenced number is absent from that set while the PR itself is still open, the issue closed (e.g. `NOT_PLANNED`) while the PR was in flight. See [Disposition-call detection](#disposition-call-detection-1074) for the full signal and the templated options.

### Pass B — Open issues

```bash
gh issue list --repo <owner/repo> --state open --limit 200 \
  --json number,title,url,author,assignees,createdAt,updatedAt,labels,comments \
  --jq '[.[] | . + {comments: (.comments | map({author: .author.login, body: (.body[:280]), createdAt}) | .[-3:])}]'
```

The `comments` projection keeps only the last 3 comments on each issue, and each comment is trimmed to its first 280 chars + author login + createdAt. The Pass B signals only inspect the most-recent comment author (`@<$ME>` ping detection) and the first chunk of its body (substring match for `?` and the mention shape) — keeping the full comment history per issue (or full bodies) burns tool-result tokens for fields nothing reads. Worker-preamble §"`gh` JSON discipline" covers the convention.

From this projection, derive per-issue signals:

- **Issue with `needs-human-review` label — render from the provenance marker, not from prose inference** ([#1091](https://github.com/mattsears18/shipyard/issues/1091)). `/shipyard:do-work` deliberately **excludes** `needs-human-review` from dispatch (see the client-side filter in [`do-work/setup.md`](./do-work/setup.md) step 4, [`do-work/drain.md`](./do-work/drain.md), and [`do-work/steady-state.md`](./do-work/steady-state.md)), so without a `/my-turn` signal a human-gated issue is invisible to both loops and stacks up in the backlog with no path to a human — exactly what `/my-turn` exists to surface. But the label is a catch-all — every code path that applies it also writes a distinct provenance marker as the first (or, where a dedupe sentinel already owns the first line, second) line of its comment, and every marker below is read from the **same Pass B `comments` projection already fetched** (zero extra `gh` calls — the [per-item investigation ceiling](#per-item-investigation-ceiling-1073) is not spent on this lookup). Scan the issue's trimmed `comments` array for the newest comment carrying one of these markers and render per this table — absent marker degrades to the generic "review and clear, re-scope, or close" render:

  | Marker | Provenance | Human action |
  |---|---|---|
  | (none — co-label `user-feedback` present, body already rewritten) | Refined user-feedback awaiting maintainer approval ([`/shipyard:refine-issues`](./refine-issues.md) classify+rewrite branch) | Review the rewritten body, approve or request changes, remove the label when satisfied |
  | `<!-- do-work-refinement-fallthrough -->` | Refinement fall-through — no automated refiner rule matched (bare one-liner, unrecognized bot shape) ([`/shipyard:refine-issues`](./refine-issues.md) Branch C, [#520](https://github.com/mattsears18/shipyard/issues/520)) | Triage by hand — write the issue up so a refiner rule (or a future one) can act on it, or close if out of scope |
  | `<!-- do-work-legacy-needs-design -->` | Design-gated — migrated from the legacy `needs-design` label ([#515](https://github.com/mattsears18/shipyard/issues/515) / [#537](https://github.com/mattsears18/shipyard/issues/537)); **not** produced going forward — [#767](https://github.com/mattsears18/shipyard/issues/767) made a plain open design/architecture decision in-scope for `/do-work` to resolve itself, so this marker only appears on pre-#767 issues a legacy-label migration sweep touched | Make the design call (or break the issue into a design spike + an implementation issue so the impl half becomes dispatch-eligible), then remove the label |
  | `<!-- do-work-agent-refuse -->` | Agent refuse — a worker hard-bailed for a pure security / scope / prompt-injection *refuse* (no open `Blocked by #<M>` reference) ([#521](https://github.com/mattsears18/shipyard/issues/521)) | Cite the bail reason from the marked comment in the rendered action; review, clear, re-scope, or close |
  | `<!-- do-work-investigation-disposition -->` | Investigate-mode or spike-mode disposition — an investigation-style worker reached a conclusion but the resolution needs a human (product/business/legal call, access the worker lacks, ambiguous correct behavior) ([`investigate.md` § 4b](../agents/issue-worker/investigate.md#4b-genuinely-needs-a-human--apply-needs-human-review-return-blocked-style-the-investigatedneeds-human-review-path), [`spike.md` § 4b](../agents/issue-worker/spike.md#4b-not-actionable--route-to-a-human), [#514](https://github.com/mattsears18/shipyard/issues/514)) | Cite the one-line reason from the marked comment; make the call, or hand the impl half back to `/do-work` once resolved |
  | `<!-- do-work-untrusted-author-review -->` | External-author trust review — see the dedicated bullet below | See below |
  | `<!-- do-work-needs-decomposition -->` | Epic-decomposition handoff — see the dedicated bullet below | See below |
  | `<!-- do-work-classifier-undispatchable -->` | Classifier-undispatchable — see the dedicated bullet below | See below |
  | `<!-- do-work-human-decision-required -->` | Enumerated human decision — decision-gated, walked in [Phase 1](#phase-1--collect-no-mutation-no-work), not this bucket | n/a here |

  **`<!-- do-work-needs-decomposition -->` and `<!-- do-work-classifier-undispatchable -->` predate this table and are grandfathered spellings of the same `do-work-<provenance>` marker convention** — not renamed to a new scheme, since both already ride live issues and a rename would break `/decompose-epic`'s and this table's existing lookups against issues stamped before #1091.

  The reviewer **is the user** (or, more precisely: a maintainer; the survey assumes `$ME` is one). (Full producer inventory and marker-vs-sentinel distinction — [issue #1091](https://github.com/mattsears18/shipyard/issues/1091); design-gate provenance history — [RATIONALE → Label-lifecycle provenance](./do-work-RATIONALE.md#needs-design--needs-human-review-issue-515-binary-backlog-phase-1).)
- **Issue with `needs-human-review`, no enumerated decision, and thread evidence the gated work is already complete or all-but-complete — a disposition call** ([#1074](https://github.com/mattsears18/shipyard/issues/1074), only when [`disposition_call_detection`](#6-resolve-the-disposition-call-detection-toggle-1074) is `true`). Distinct from the design-gate / refined-feedback cases above: here the gate label was never cleared after the work landed, so the only remaining human action is a keep/close/split judgment, not a question the body poses. See [Disposition-call detection](#disposition-call-detection-1074) for the exact signal (derived entirely from this same Pass B projection — `labels`, `updatedAt`, `comments[-1]` — no extra `gh` call).
- **Issue with `needs-human-review` + a `<!-- do-work-untrusted-author-review -->` comment — external-author trust review** ([#1079](https://github.com/mattsears18/shipyard/issues/1079)). A third `needs-human-review` case, distinct from the refined-feedback and design-gate ones above: `/shipyard:do-work`'s bucket-0.5 security gate (`author.login` NOT in `trusted_authors`) drops the issue from dispatch — that gate is unchanged and never relaxes here — and the label is purely the surfacing side effect, applied once per issue by [`04`'s bucket-0.5 handoff](./do-work/setup/04-backlog-divert.md#4-fetch--rank-the-backlog). The sentinel comment is what distinguishes this case from the other two `needs-human-review` populations, and it already states the concrete action: render it directly rather than re-deriving it. The human decision is one of three: **vouch** (add the author to `.shipyard/trusted-authors.txt`, or re-file the issue under a trusted account — both documented in the sentinel comment), **triage without vouching** (work it by hand, outside `/do-work`), or **close** (spam / out of scope). This is the category the [Human-only queue filter](#human-only-queue-filter) already listed by name — "external-author trust review" — before this fix populated it.
- **Issue with the `agent-console` label** ([#608](https://github.com/mattsears18/shipyard/issues/608), renamed from `needs-operator` in [#995](https://github.com/mattsears18/shipyard/issues/995) — the legacy-name back-compat window is closed, per [#1082](https://github.com/mattsears18/shipyard/issues/1082): zero issues in this repo carried `needs-operator` at migration time, so there is nothing left to recognize under the old name) — blocked on a **browser/console operator action**, not a decision: paste a CI secret, flip a provider-console toggle, close a superseded PR, or another action completable by manipulating a browser. **This is `/do-work`'s job when its operator phase is enabled — the default, but not guaranteed** ([#635](https://github.com/mattsears18/shipyard/issues/635); config-conditional per [#1093](https://github.com/mattsears18/shipyard/issues/1093)). The operator can be **a human OR Claude**, and `/shipyard:do-work` (operator-inclusive by default) drives these in the user's real Chrome via the extension. But `--no-operate` / `--hands-off` — a per-invocation flag `/my-turn` cannot observe directly (see [Setup step 7](#7-resolve-the-operator-phase-assumption-for-the-agent-console-filter-1093); the underlying observability gap is tracked separately in [#1080](https://github.com/mattsears18/shipyard/issues/1080)) — disables that drain entirely, and under that opt-out these items stay gated exactly like `needs-human-review` with nothing draining them. So whether the item is excluded from the human-only queue is gated on `$assume_operator_enabled` (resolved once at [Setup step 7](#7-resolve-the-operator-phase-assumption-for-the-agent-console-filter-1093), default `true`):
  - **`$assume_operator_enabled == "true"` (the default)** — excluded from `/my-turn`'s human-only walkthrough queue (see [Human-only queue filter](#human-only-queue-filter)). `/my-turn` does NOT walk these items; at most it surfaces a single one-line pointer (`<N> browser-completable operator action<s> — run /shipyard:do-work to have Claude complete them`) so the user knows they exist and which command drains them.
  - **`$assume_operator_enabled == "false"`** — the maintainer has declared this repo's `/do-work` runs skip the operator phase, so nothing drains these automatically. Surface the item in the human-only queue directly (leverage [score 3](#secondary-sort--leverage-score-then-age-issue-565), P1 tier — see [Ranking](#ranking)) instead of filtering it to a pointer line — the pointer line must never name a command configured not to do the work.

  Distinguish from `needs-human-review` (a genuine human *decision*, which Claude can't make and which `/my-turn` always walks regardless of this gate) — `agent-console` is a mechanical action, so it's the *filtering*, not the item's existence, that's config-conditional.
- **Untriaged-looking issue (matches an investigate detection signal), only when `$investigate_dispatch == "false"`** ([#1077](https://github.com/mattsears18/shipyard/issues/1077), retargeted off the retired `needs-triage` label by [#1120](https://github.com/mattsears18/shipyard/issues/1120)) — under the default (`triage.investigate_dispatch: true`, resolved once in [Setup step 3](#3-resolve-the-untriaged-issue-human-ownership-config-gate-1077)), `/shipyard:do-work` routes a trusted-author untriaged-looking issue to `investigate_candidates` and dispatches it via investigate mode itself, so there is nothing for a human to do here and this signal correctly stays silent (see [`backlog-ownership.md` bucket 5](./do-work/setup/backlog-ownership.md#ownership-table)). When `investigate_dispatch` is `false`, `/shipyard:do-work` drops these issues outright instead of routing them — the pre-#556 skip-and-surface behavior — so they have no other consumer and become genuinely human-owned. The human action is a single decision: set a priority + type label (or close as out of scope, or leave it pending more thought).
- **Issue with `needs-human-review` + the `<!-- do-work-needs-decomposition -->` body marker** — a `/do-work` scope agent confirmed the epic is non-shippable as a single PR. (Epic-handoff provenance — formerly the dedicated `needs-decomposition` label, re-keyed onto `needs-human-review` + this marker — in [RATIONALE → Label-lifecycle provenance](./do-work-RATIONALE.md#needs-decomposition--tracking--needs-human-review--body-marker-issue-519).) (The marker is what distinguishes an epic-decomposition handoff from every *other* `needs-human-review` provenance in the [table above](#pass-b--open-issues) — render this one as the more-specific "epic awaiting decomposition" action when the marker is present.) If there's **no** `<!-- do-work-decompose-agent -->` idempotency sentinel in any comment, `/shipyard:decompose-epic` hasn't been run yet — the user can run it to auto-shard the epic into dispatch-ready sub-issues (for `Multi-PR sequence:` / `Missing dependency:` evidence classes). If a sentinel comment **is** present and reads `couldn't auto-decompose:`, the epic is a genuine human-decomposition handoff (non-mechanical evidence class, or too big to shard cleanly) — the user decomposes it by hand. Either way the epic is blocked on the user, not on Claude.
- **Agent refuses surface via the `needs-human-review` bucket above, identified by the `<!-- do-work-agent-refuse -->` marker** ([#1091](https://github.com/mattsears18/shipyard/issues/1091); formerly identified by prose-searching the bail comment — the marker is the deterministic replacement). A worker that hard-bails for a pure security / scope / prompt-injection *refuse* (no open `Blocked by #<M>` reference) carries `needs-human-review`, so the "Claude gave up; a human must actually look" signal is already covered by the `needs-human-review` signal above — it doesn't need its own bucket. The bail comment (`steady-state.md`'s bail handler writes a `<!-- do-work-agent-refuse -->`-prefixed `Worker returned blocked: <reason>. Classified as needs-human-review` comment) records *why*, so cite it in the rendered action when the marker is present. A **dependency-wait** (body has ≥1 `Blocked by #<M>` reference) carries no label at all — the `Blocked by #<M>` body-reference filter auto-clears it the instant the blocker closes (it becomes a plain workable issue with no human action needed), so there is nothing for `/my-turn` to surface. (Provenance — the former `blocked:agent-hard` label and clearable-hard-block signal, both eliminated — in [RATIONALE → Label-lifecycle provenance](./do-work-RATIONALE.md#agent-refuses-surface-via-needs-human-review-dependency-waits-carry-no-label-issue-521).)
- **Issue with `needs-human-review` + the `<!-- do-work-classifier-undispatchable -->` body marker** ([#953](https://github.com/mattsears18/shipyard/issues/953)) — categorically different from the agent-refuse bucket immediately above, even though both carry `needs-human-review`: here **no worker ever ran**. The Claude Code harness's own auto-mode permission classifier refused the orchestrator's dispatch call outright, on both permitted attempts ([#718](https://github.com/mattsears18/shipyard/issues/718)'s one-corrective-re-dispatch-then-stop contract), so there is no implementation attempt, no code read, and no worker bail reasoning to review — only the fact that dispatch itself was refused. Render this distinctly from an agent-refuse ("a worker tried and gave up because <reason>"): the action here is "either do this work by hand, or make a permission-policy call that would let the classifier allow it" — there is no bail reasoning to summarize because none exists. Do not conflate this with the ordinary `needs-human-review` bucket above by citing a nonexistent worker rationale.
- **Issue authored by `$ME`, no linked PR, no `needs-human-review` label, no `shipyard` label, NOT self-assigned to `$ME`, and `createdAt` older than `$stale_undispatched_days` days** ([#1078](https://github.com/mattsears18/shipyard/issues/1078)) — the precise "`/do-work` never claimed this" signal, not merely "no PR yet." The old predicate (authored-by-`$ME` + no-linked-PR + no `needs-human-review`, with nothing else) is a **tautology on a solo-maintainer repo**: it's true of every workable issue `/do-work` simply hasn't reached yet, which is the normal steady state of a healthy backlog — a live measurement against a real repo found it would have surfaced the *entire* undispatched backlog, including issues a concurrent `/do-work` session was actively working at that exact moment. `/do-work` stamps the `shipyard` session-stamp label and self-assigns `@me` (the soft lock — see [`inline-trivial.md`](./do-work/inline-trivial.md) § "the `shipyard` label is the session stamp") on **every** issue it dispatches, before implementation begins — so the ABSENCE of *both* is the actual "`/do-work` never touched this" evidence, not the absence of a linked PR alone (which is equally true of an issue sitting in the dispatch queue mid-session, or one two minutes old). The age threshold is what keeps a just-filed issue from false-positiving before `/do-work` has had a chance to reach it. Implementation: `assignees` does NOT contain `$ME` AND `labels` does NOT contain `shipyard` AND `labels` does NOT contain `needs-human-review` AND `createdAt` is more than `$stale_undispatched_days` days in the past (config `my_turn.stale_undispatched_days`, default 7, resolved once at [Setup step 4](#4-resolve-the-stale-undispatched-issue-threshold-1078)). All four fields already ride the Pass B projection above — no added `gh` call. (`blocked:agent-soft` issues already carry the `shipyard` label from the worker that bailed on them, so the label conjunct alone excludes them — they auto-clear at next-session backlog fetch and don't need user triage. A dependency-wait carries no `shipyard` label either and auto-clears the instant its blocker closes; if one sits past the age threshold, it's because its blocker has been open that long too — a legitimate housekeeping nudge to check the blocker, not a misfire of this signal.)
- **Issue assigned to someone other than `$ME`, with `updatedAt` >30 days old** ([#1076](https://github.com/mattsears18/shipyard/issues/1076)) — `/shipyard:do-work` intentionally skips any issue assigned to another user (see [`backlog-ownership.md` bucket 1](./do-work/setup/backlog-ownership.md#ownership-table)), so on a solo-maintainer repo a stale assignment was reaching nobody before this signal existed. Implementation: `assignees` is non-empty, does NOT contain `$ME`, and `updatedAt` is more than 30 days in the past — the assignee has gone quiet. The action is to reassign to `$ME`, unassign so `/shipyard:do-work` can pick it up, or ping the assignee. An issue assigned to another user that's still fresh (`updatedAt` ≤30d) is NOT surfaced — the assignee may simply be actively working it.
- **Last comment carries an intent-to-ask signal — content-based, not author-identity-based** ([#1089](https://github.com/mattsears18/shipyard/issues/1089)). The prior version of this signal keyed on "last comment authored by someone other than `$ME`" — structurally dead on this repo shape, per [Setup step 2](#2-resolve-the-authenticated-user): every comment, human or agent, carries the same `$ME` login, so the identity test can never fire. Test **intent**, not authorship, against the newest comment (any author — do NOT filter by `author != $ME`):
  - an explicit `@<$ME>` mention — a deliberate address survives the identity collapse regardless of who wrote it;
  - a shipyard handoff sentinel (a comment body starting with `<!-- shipyard-` — e.g. `<!-- shipyard-worker-progress -->`, left by a worker whose worktree was reaped mid-investigation) **with no accompanying gate label** on the issue (`needs-human-review`, `agent-console`) — a handoff comment that landed without also getting a label is otherwise invisible to every other Pass B bucket, since those all key off the label;
  - a literal `?` **only when the issue carries none of those same gate labels already** — a labeled issue is already covered by its own bucket above ([needs-human-review](#pass-b--open-issues) / `agent-console`), so an unconditional `?` match would double-surface the same item under two buckets.

  Implementation: read the newest entry in `comments` (any author). Fires if the body contains `@<login>` for `$ME`, OR (the body starts with `<!-- shipyard-` AND `labels` excludes `needs-human-review`/`agent-console`), OR (the body contains `?` AND `labels` excludes those same two labels).

### Pass C — Unanswered review comments on `$ME`'s PRs

**Skip this pass entirely when the repo has no non-`$ME` participants** ([#1089](https://github.com/mattsears18/shipyard/issues/1089)). Pass C's own signal below ("last commenter not `$ME`") is exactly the identity test [Setup step 2](#2-resolve-the-authenticated-user) warns about — on a solo/agent-driven repo where every comment (human or automation) rides the same `$ME` login, the predicate can never be satisfied, so the per-PR follow-up calls below (the single largest line item in the [Performance budget](#performance-budget)) are pure cost for a guaranteed-empty result. Decide this from data already in hand — no extra `gh` call: take the distinct `.author.login` values across **Pass A's already-fetched open-PR projection** (same survey batch, no round-trip), drop `$ME`. If the remaining set is empty, skip Pass C outright — return no candidates, make zero `gh api` calls. If it's non-empty, this repo has genuine outside participation and the pass is worth its cost; run it as below, unchanged.

Open PRs authored by `$ME` may have review comments awaiting reply. `gh pr list` doesn't return review-comment threads; use a per-PR follow-up only for PRs that aren't already surfaced in Pass A's higher-priority buckets, capped at the 20 most-recently-updated. For each:

```bash
gh api repos/<owner/repo>/pulls/<M>/comments --jq '.[] | {id, user: .user.login, body, created_at, in_reply_to_id}'
```

Surface the PR if there's an unresolved review comment thread where the last comment is from a non-`$ME` author. (v1 heuristic — GitHub's API doesn't expose the `resolved` flag on classic review comments; "last commenter not `$ME`" is a reasonable proxy.)

## Human-only queue filter

After the passes collect candidates and **before** ranking, drop everything that isn't genuinely blocked on a *human* — anything `/shipyard:do-work` can complete on its own ([#635](https://github.com/mattsears18/shipyard/issues/635)). This is the filter that makes `/my-turn`'s queue mean *"only what needs you, the person"* rather than *"everything not yet done."* Under the three-command division of labor:

- **`/do-work` owns code work** — issues an autonomous code worker can implement. These never enter `/my-turn`'s queue in the first place (a workable, ungated issue is `/do-work`'s; the passes above already only collect human-blocked signals), and the [Don't](#dont) rules keep them out.
- **`/do-work` owns browser-completable operator actions — when its operator phase is enabled** ([#1093](https://github.com/mattsears18/shipyard/issues/1093)) — `agent-console` items, and any item whose next step is a mechanical browser/console action Claude can drive in the user's real Chrome (close a superseded PR, paste a CI secret, toggle a non-security console setting, post an unambiguous reply). This holds under `/do-work`'s default (operator-inclusive), but `--no-operate` / `--hands-off` disables it — a per-invocation flag `/my-turn` cannot observe directly (the underlying fix is tracked in [#1080](https://github.com/mattsears18/shipyard/issues/1080)), so `/my-turn` instead relies on the declared `my_turn.assume_operator_enabled` config knob (default `true`, resolved once at [Setup step 7](#7-resolve-the-operator-phase-assumption-for-the-agent-console-filter-1093)). **When `true` (the default) — exclude these from the walkthrough queue.** They are surfaced — if any exist — only as a single one-line pointer (see [the operator pointer](#operator-pointer-line) in Output), never walked. **When `false`** — the maintainer has declared this repo's `/do-work` doesn't drain them — **include these in the walkthrough queue** instead; the pointer must never name a command configured not to do the work.
- **`/do-work` owns CI recovery on the default branch** — a dedicated `fix-main-ci` worker mode exists exactly for red main / failing CI with no fix-main-ci PR open. That's `/do-work`'s condition to catch on its own; it never enters `/my-turn`'s queue.
- **`/do-work` owns `@me`-authored DIRTY PRs — scoped, and only while drain-phase rebase dispatch is enabled** ([#1075](https://github.com/mattsears18/shipyard/issues/1075)) — the drain-phase `fix-rebase` worker mode adopts and rebases a `@me`-authored `mergeStateStatus: DIRTY` PR across sessions (see [`do-work/drain.md`](./do-work/drain.md#drain-protocol)). This holds under the default (`ci.skip_drain_rebase: false`, resolved once at [Setup step 8](#8-resolve-ciskip_drain_rebase-for-the-dirty-pr-author-scoping-gate-1075)); when `true`, drain-phase rebase dispatch is off entirely and a `@me` DIRTY PR is `/my-turn`'s exactly like any other author's. **Unlike the `agent-console` gate above, this is narrower than "all-or-nothing":** even under the default config, a `@me` DIRTY PR still surfaces here as a low-priority fallback when `/do-work`'s rebase-specific give-up states (`rebase_blocked_prs`, the rate-limit cap) aren't observable from a `gh` projection — see the Pass A bucket above. An outside-contributor's DIRTY PR is never affected by this gate; it's `/my-turn`'s regardless.
- **`/do-work` owns an issue or PR a LIVE session is actively working on right now** ([#1080](https://github.com/mattsears18/shipyard/issues/1080), optional — applies only when [Setup step 9](#9-resolve-do-works-live-session-state-optional-enrichment-1080) found a live session's `.in_flight`). An issue with a live `issue` / `investigate` / `spike` slot, or a PR with a live `fix-checks` / `fix-rebase` slot, has an agent working it *this instant* — nothing for the human to do until it returns. Exclude any survey candidate whose number appears in `in_flight_issue_targets` (issues) or `in_flight_pr_targets` (PRs). **Suppression only, never assertion** — the absence of this signal (no session file for this repo, a dead session, session state unreadable) changes nothing; the candidate is judged on every other signal exactly as it is today. See the [in-flight pointer line](#in-flight-pointer-line) in Output for how a suppression is surfaced (never silently, and never as a walked item).
- **`/my-turn` owns genuine human-required items** — and *only* these survive into the ranked queue: a `needs-human-review` decision/judgment call (design call, product/schema decision, epic-decomposition handoff a human must do by hand, an agent-refuse a human must adjudicate, external-author trust review, a disposition call — see [Disposition-call detection](#disposition-call-detection-1074), [#1074](https://github.com/mattsears18/shipyard/issues/1074)), an untriaged-looking issue **only when `triage.investigate_dispatch: false`** (under the default it's `/do-work`'s, dispatched via investigate mode — see the Pass B bucket above and [#1077](https://github.com/mattsears18/shipyard/issues/1077)), an `agent-console` item **only when `my_turn.assume_operator_enabled: false`** (nothing is assumed to be draining these either — see the Pass B bucket above and [#1093](https://github.com/mattsears18/shipyard/issues/1093)), a PR awaiting `$ME`'s review, an unanswered question / `@$ME` ping, a `blocked:ci` PR needing human eyes, and the housekeeping signals (stale draft, a non-`@me` DIRTY PR — plus a `@me` DIRTY PR fallback when the rebase give-up state isn't observable, per the bullet above and [#1075](https://github.com/mattsears18/shipyard/issues/1075) — `CHANGES_REQUESTED`, stale assigned-to-other issues, stale never-claimed-by-`/do-work` own-authored issues). These are the things no automation can finish for the user.

**The discriminator is "can `/do-work` complete it without a human decision, and is `/do-work` actually configured to?"** If yes to both → it's the operator layer's, filtered out (pointer only). If it needs a person to *decide* or *judge* something no automation can — it stays, unconditionally. If the operator layer *could* complete it mechanically but isn't assumed to be running (`my_turn.assume_operator_enabled: false`, [#1093](https://github.com/mattsears18/shipyard/issues/1093)) — it also stays, since nothing else will. A `needs-human-review` item that is *also* a security/access-control console toggle (which the operator layer hands back rather than drives, per [#626](https://github.com/mattsears18/shipyard/issues/626)) still needs the human, so it stays in the queue regardless of the config gate.

The remaining (human-only) candidates are what the [Ranking](#ranking) step orders and the [Walkthrough](#walkthrough-mode-default) consumes.

## Ranking

Merge the human-only candidates (those surviving the [Human-only queue filter](#human-only-queue-filter)) into a single ranked list. Each item carries a priority tier and, within its tier, a **leverage score** (highest-leverage first) with `createdAt` ascending (oldest first) as the final tie-breaker — see [Secondary sort](#secondary-sort--leverage-score-then-age-issue-565). The leverage score, not raw age, is what determines the order the [walkthrough](#walkthrough-mode-default) advances through — and which item leads (issue [#565](https://github.com/mattsears18/shipyard/issues/565)).

### Priority tiers

Ranking runs over the **human-only candidates that survive the [Human-only queue filter](#human-only-queue-filter)** — under `my_turn.assume_operator_enabled: true` (the default), `agent-console` / browser-completable items are already filtered out (they're assumed to be `/do-work`'s, surfaced only via the [operator pointer](#operator-pointer-line)), so they do NOT appear in any tier below. **Under `my_turn.assume_operator_enabled: false`** ([#1093](https://github.com/mattsears18/shipyard/issues/1093)), they survive the filter instead and appear in **P1** below.

- **P0 — blocking other work**
  - PRs awaiting `$ME`'s review (any age) — `$ME` is literally what's stopping merge
  - Issues with `needs-human-review` label — `/shipyard:do-work` is skipping them (this now includes design-gated issues — see the Pass B bucket above)
  - Draft PRs with `needs-human-review` whose linked issue closed out from under them — a PR-shaped disposition call ([#1074](https://github.com/mattsears18/shipyard/issues/1074); see the Pass A bucket above) — same "blocked pending a human sign-off" shape as the issue-level bucket above
  - Untriaged-looking issues (matching an investigate detection signal), only when `triage.investigate_dispatch: false` ([#1077](https://github.com/mattsears18/shipyard/issues/1077)) — same "blocked on a human, `/do-work` won't touch it" shape as `needs-human-review` above (see the Pass B bucket above); absent under the default config

- **P1 — decisions**
  - PRs with `blocked:ci` (3-attempt orchestrator fix-loop exhausted, needs human eyes)
  - (Agent refuses carry `needs-human-review` and surface under the **P0** `needs-human-review` bucket above; cite the worker's bail comment in the rendered action so the refuse reason is visible. See the Pass B agent-refuses bucket above for provenance.)
  - Issues with `needs-human-review` + the `<!-- do-work-needs-decomposition -->` body marker (a scope agent confirmed the epic is non-shippable as a single PR — run `/shipyard:decompose-epic` to auto-shard the mechanical cases, or decompose by hand if a `couldn't auto-decompose:` sentinel comment is already present; see the Pass B bucket above)
  - Issues with `agent-console`, **only when `my_turn.assume_operator_enabled: false`** ([#1093](https://github.com/mattsears18/shipyard/issues/1093)) — same "blocked on a human because nothing is currently draining it" shape as `blocked:ci` above; excluded entirely under the default config (see the Pass B bucket above)
  - Open review comment threads on `$ME`'s PRs awaiting reply
  - Issues whose last comment carries an intent-to-ask signal — a `@$ME` mention, an un-labeled shipyard handoff sentinel, or a `?` with no gate label already applied ([#1089](https://github.com/mattsears18/shipyard/issues/1089); see the Pass B bucket above)

- **P2 — housekeeping**
  - PRs from other authors with `mergeStateStatus: DIRTY` >24h (rebase didn't auto-fire) — `/do-work`'s drain-phase `fix-rebase` only adopts `@me` PRs ([#1075](https://github.com/mattsears18/shipyard/issues/1075)); OR any-author DIRTY PR when `ci.skip_drain_rebase: true` (drain-phase rebase dispatch disabled entirely — see the Pass A bucket above)
  - `@me`-authored PRs with `mergeStateStatus: DIRTY` >24h, only when `ci.skip_drain_rebase: false` (the default) — `/do-work`'s fix-rebase is presumed to be adopting these, but they still surface here (at the bottom of this tier, see [Leverage score](#secondary-sort--leverage-score-then-age-issue-565)) since the two rebase give-up states aren't `gh`-observable ([#1075](https://github.com/mattsears18/shipyard/issues/1075); see the Pass A bucket above)
  - Draft PRs stale >7 days (finish or close)
  - (A dependency-wait carries no label and auto-clears via the `Blocked by #<M>` body-reference filter when its blocker closes, so there's no leftover label for a human to remove — see the Pass B agent-refuses bucket above for provenance.)
  - `CHANGES_REQUESTED` on `$ME`'s open PRs (the user owes the reviewer a response)
  - Issues assigned to someone other than `$ME`, stale >30 days (see the Pass B bucket above — [#1076](https://github.com/mattsears18/shipyard/issues/1076))
  - Issues authored by `$ME`, never claimed by `/do-work`, stale >`$stale_undispatched_days` days ([#1078](https://github.com/mattsears18/shipyard/issues/1078)) — a "check your labels" nudge, not a blocking decision (see the Pass B bucket above)

### Secondary sort — leverage score, then age (issue [#565](https://github.com/mattsears18/shipyard/issues/565))

Within each tier, sort by a **leverage score descending** (highest-leverage first), and break ties by `createdAt` ascending (oldest first). **Leverage is the primary within-tier key; age is only the tie-breaker.** This is the fix for [#565](https://github.com/mattsears18/shipyard/issues/565): the old flat `createdAt`-ascending secondary sort made the *stalest* item the head of the queue, which on a P0 tier dominated by long-lived `needs-human-review` issues regularly surfaced an auto-undecomposable epic — the *least* actionable item — first, directly contradicting the command's "highest-leverage thing blocked on you" promise. Oldest-first is a reasonable *tie-breaker*, but it is not a *leverage* signal, and the order the secondary sort produces is the order the [walkthrough](#walkthrough-mode-default) advances through (and the one item a `--limit 1` snapshot renders).

**The leverage score is derived entirely from signals the survey passes A–C already collect** — no new `gh` calls, no new round-trips. Higher score = higher leverage = a human action that unblocks the most downstream work for the least effort. Note the operator-console class (paste a CI secret, flip a provider toggle) is not scored here **when `my_turn.assume_operator_enabled: true`** (the default) — it's filtered out by the [Human-only queue filter](#human-only-queue-filter) as `/do-work`'s work. **When `false`** ([#1093](https://github.com/mattsears18/shipyard/issues/1093)), it scores 3 (below) instead of being filtered. Rank within a tier by this order (4 = highest leverage, 1 = lowest):

1. **Score 4 — pure-decision item.** The human action is a single decision that flips the item to dispatch-eligible / mergeable (or resolves it outright): a `needs-human-review` issue whose body enumerates product / schema / design questions with **no** external-console, on-device, or external-dependency requirement; a **disposition-call** issue or draft PR — `needs-human-review`, no enumerated decision, but the thread shows the gated work is complete or all-but-complete, so the human call is close / keep-open / split rather than answering a body question (see [Disposition-call detection](#disposition-call-detection-1074), [#1074](https://github.com/mattsears18/shipyard/issues/1074)); an external-author trust-review issue (the `<!-- do-work-untrusted-author-review -->` sentinel — the decision is vouch / triage-by-hand / close, a single templated call, per [#1079](https://github.com/mattsears18/shipyard/issues/1079)); an untriaged-looking issue (only when `triage.investigate_dispatch: false`) needing just a priority + type label to become dispatch-eligible; a PR awaiting `$ME`'s review; an issue where the last comment is a direct question or `@$ME` ping awaiting a one-line answer. One human call converts the item to workable-by-`/do-work` (or merges it, or closes it) — the highest leverage per unit of effort, so these float to the top of their tier.
2. **Score 3 — quick human action.** A bounded, fast human step that isn't a pure decision but that no automation can take for the user: reply to a review comment thread with a substantive answer, make a small judgment call documented inline, delete a stale branch or flip a GitHub setting that the operator layer was unable to drive (e.g. a security/access-control toggle the operator layer hands back per [#626](https://github.com/mattsears18/shipyard/issues/626)); or an `agent-console` item itself, **only when `my_turn.assume_operator_enabled: false`** ([#1093](https://github.com/mattsears18/shipyard/issues/1093)) — nothing is currently assumed to be draining these automatically, so the mechanical action falls to the human directly. Bounded and unblocking, slightly slower than a one-line decision. (Pure mechanical operator-console actions are NOT here under the default config — they're the operator layer's and filtered out.)
3. **Score 2 — on-device / multi-party verification.** The action needs a device, a build, or coordination with another party (run a build through TestFlight, verify an on-device flow, get a second person to confirm). Higher effort and higher latency.
4. **Score 1 — auto-undecomposable epic / parking-lot umbrella.** A `needs-human-review` issue carrying the `<!-- do-work-needs-decomposition -->` body marker **and** a `couldn't auto-decompose:` sentinel comment (`/decompose-epic` already determined it can't be mechanically sharded); **or a `@me`-authored DIRTY PR fallback, only when `ci.skip_drain_rebase: false`** ([#1075](https://github.com/mattsears18/shipyard/issues/1075) — see the Pass A bucket above) — `/do-work`'s two rebase-specific give-up states aren't `gh`-observable, so surfacing beats silence, but it sinks to the bottom exactly like the epic case since the item is presumptively `/do-work`'s and only shown out of caution. A by-hand decomposition is *real work*, not a "next step" — these are low-leverage **as a single human action** by definition, so they **sink** to the bottom of their tier rather than floating to the top on age alone. This is the exact item the [#565](https://github.com/mattsears18/shipyard/issues/565) repro surfaced as a false first item (the 4-week-stale `epic(aso)` #540).

Items that match none of the above (e.g. a stale draft PR, a `CHANGES_REQUESTED` PR, a non-`@me` `mergeStateStatus: DIRTY` PR) take a **neutral middle score (2)** so the leverage ordering only *re-orders* the clear high/low-leverage cases and otherwise falls back to the age tie-breaker — it never invents urgency for a housekeeping item. The score is a within-tier ordering signal only; it never moves an item across tiers (a P2 pure-decision item does not outrank a P0 epic).

**Worked example (the [#565](https://github.com/mattsears18/shipyard/issues/565) repro).** A P0 tier with 19 `needs-human-review` issues: under the old oldest-first sort, the 4-week-stale auto-undecomposable `epic(aso)` #540 ranked #1 and was walked first. Under leverage-then-age, #540 scores 1 (auto-undecomposable epic) and sinks; a pure-decision issue like "feature blocked on 7 product/schema decisions the user can answer in minutes" scores 4 and floats to the top of P0 — so the walkthrough starts with the genuinely highest-leverage human action, restoring the headline promise.

Surface a single age string per item regardless of leverage score — `<N>d` for ≥1 day, `<N>h` for ≥1 hour, else `<N>m`.

### Dedup

An item may match multiple signals (e.g. a PR is both `blocked:ci` AND DIRTY); collapse to a single rendered row, keep the highest-priority signal, list the secondary signals in the "why" column.

### Release-please / version-bump PRs (discretionary)

A release-please / version-bump PR is a **manual gate, not a blocker.** The commits it releases are already on the default branch; the PR only bumps version + changelog, and nothing downstream cascades from it — it doesn't block other PRs, CI, or development, and release-please keeps rolling more commits into it while it sits open. Recognize one by the same heuristic `/shipyard:do-work` uses for its auto-merge exception: a `chore(release):` title prefix **or** a `release-please--*` head branch.

Such a PR is **discretionary housekeeping** — rank it at the **bottom of P2**, never P0/P1, regardless of which Pass-A signal it matched. A CLEAN release PR is "ready to ship whenever you want," not "blocked on you," so promoting it conflates *highest-ranked human-only item* with *blocking other work* — the exact false-urgency this de-prioritization prevents.

**Exception — promote only on a concrete downstream dependency.** If another open item explicitly waits on the release shipping — it carries `Blocked by #<release-PR>` in its body, or otherwise references the version going live — the release PR is genuinely gating tracked work and MAY rank up to the tier of the work it unblocks. Absent such an edge, it stays discretionary.

## Output

Print to the terminal. **No file artifact** — the walkthrough is interactive and ephemeral; the user acts on each item as it surfaces. The output format is intentionally terse: the user asked for "what do I need to do" — not "what's the state of the repo." Cut the framing, lead with the verb.

The render depends on the resolved mode (see [Args → Mode resolution](#args)):

### Walkthrough mode (default)

When neither `--all` nor `--limit N > 1` is given, **get the human through the entire human-only queue in one session** ([#635](https://github.com/mattsears18/shipyard/issues/635)) — but in three phases, not one interleaved loop ([#1070](https://github.com/mattsears18/shipyard/issues/1070)). Every **question** is asked first, back-to-back; every **mutation** fires afterward in one batch; the items that need the human to *do* something rather than *decide* something are walked last.

**Why the split.** The command's promise is to *get you through* the human-only backlog. The pre-[#1070](https://github.com/mattsears18/shipyard/issues/1070) loop honored that but paid for it in latency: after the maintainer answered the last decision on one issue, the flow posted a comment and edited labels — GitHub round-trips — *before* the next issue's first question rendered, and it re-grounded each recommendation in fresh codebase reads at ask-time. The maintainer's own framing:

> I would prefer that the my-turn command simply collect any input that it needs from me — FOR ALL ISSUES — and then get to work. that way I don't have to sit and wait for the work to be implemented before moving on to the next thing that needs my input.

So: **collect every answer with nothing in between, then act.**

#### Phase 1 — Collect (no mutation, no work)

**Partition the ranked human-only queue** into two disjoint sets:

- **Decision-gated items** — leverage-score-4 pure-decision `needs-human-review` issues with answerable enumerated decisions (see [Decision-gated walkthrough](#decision-gated-walkthrough) for the exact trigger surface), **plus disposition-call issues and draft PRs** (see [Disposition-call detection](#disposition-call-detection-1074), [#1074](https://github.com/mattsears18/shipyard/issues/1074)) — the thread-evidenced fourth trigger class. Both are Phase 1's: each is a one-line answer that unblocks the item, which is exactly what the collect run batches.
- **Everything else** — PRs awaiting review, unanswered questions, `blocked:ci`, epic-decomposition handoffs, housekeeping. These are **set aside untouched** for [Phase 3](#phase-3--walk-the-rest).

Then, **before asking anything**, run **one bulk context pass** that gathers everything the whole collect run will need: every decision-gated issue's (and disposition-call item's) body and comment thread, and the codebase grounding behind *all* the recommendations. Doing this once up front — rather than per-decision at ask-time — is what removes the wait between questions. This pass **may fan out parallel read-only research agents** (see the narrowed no-agent rule in [Don't](#dont)); it performs no mutation of any kind.

Then ask. **Rules for the collect run:**

- **No GitHub mutation fires during Phase 1.** No `gh issue comment`, no `gh issue edit`, no `gh pr close`, no label change, no reply posted. The reused `/shipyard:resolve-decisions` walkthrough runs in its [deferred firing mode](./resolve-decisions.md#firing-mode--immediate-default-vs-deferred-batch-caller) — it yields the decision set as a value instead of recording it. A disposition call's own (self-contained, non-`/resolve-decisions`) walkthrough follows the same deferred shape: it yields the chosen option as a value, journaled exactly like an enumerated decision, and its record action fires only in [Phase 2](#phase-2--commit-all-mutation-batched).
- **Group independent decisions; ask dependent ones singly.** Batch up to 4 **mutually independent** decisions into a single `AskUserQuestion` call. A decision whose options depend on an earlier answer — the carry-forward edge that [`resolve-decisions.md` part 4](./resolve-decisions.md#the-per-decision-walkthrough) makes load-bearing — is asked **alone, in source order**, with the locked answers echoed forward as constraints. Batching removes the *work* between questions, never the *sequencing* carry-forward needs.
- **Order by issue, issues by rank.** Walk issue-by-issue in the existing [ranked](#ranking) order so related decisions stay adjacent and the maintainer isn't context-switched between unrelated features mid-run.
- **Journal every answer immediately.** Append each answer to `~/.shipyard/my-turn-<repo-slug>.json` the moment it's given — a local file write, not a network call, so it costs no perceptible latency. This is the crash-safety boundary: a session that dies mid-collect has lost nothing, and a re-invocation detects the journal and offers to **resume** (continue collecting) or **commit** (fire Phase 2 on what's already answered). Keep the per-issue answered/skipped state in the journal, not just the answers — Phase 2 needs it to pick the right branch.
- **Mid-run controls still apply.** `resolve-decisions`' controls are unchanged: "help me think through this one" detours and re-elicits the same decision; "skip this one" records it unresolved; "stop / we'll finish later" halts the collect run. A halt goes straight to Phase 2 with whatever was answered.

#### Phase 2 — Commit (all mutation, batched)

Replay the journal and fire every item's record step together. Per item, apply exactly the branch an immediate run would have — the branch depends on **which of the two Phase 1 classes** the item was:

**Enumerated decision-gated issues** — [`/resolve-decisions`' record step](./resolve-decisions.md#record--unblock):

- **Every decision answered** → post the structured `<!-- shipyard-resolve-decisions -->` decisions comment and **remove the gate label**; the issue is now dispatch-ready.
- **Any decision skipped, or the run halted before the issue finished** → post the **partial** comment and **leave the gate label on**. This is `resolve-decisions`' partial-run rule, generalized per-issue: batching changes *when* the record fires, never *what* it decides.

**Disposition-call items** ([#1074](https://github.com/mattsears18/shipyard/issues/1074)) — the item's own [record shape](#disposition-call-detection-1074), fired by option chosen (never `/resolve-decisions`' shape — a disposition call doesn't make the item dispatch-ready, it resolves it):

- **Close as done** → `gh issue close <N> --repo <owner/repo> --reason completed` (or `gh pr close <M> --repo <owner/repo>` for a PR-shaped call), with a closing comment citing the rationale.
- **Keep open** → post a comment naming precisely what remains, and remove `needs-human-review` only if the named remainder is itself autonomously workable by `/do-work`; leave the label on otherwise.
- **Close and split** → file a fresh, ungated follow-up issue for the named remainder (`--label shipyard`), then close the original as completed with a comment linking the follow-up.
- **Skipped, or halted before answered** → no mutation; leave the item exactly as-is (label unchanged) for a future run.

**Decisions whose implementation is a production mutation — offer to run it here** ([#1563](https://github.com/mattsears18/shipyard/issues/1563)). Some recorded decisions have no code to write. Their implementation outline is a short list of exact CLI commands that mutate a production data store or a shared cloud resource, such as enabling PITR, creating scheduler jobs, or running an additive backfill. Clearing the gate so the issue lands on `agent-console` hands those commands to `/do-work`'s operator layer. On a host whose permission classifier treats prod mutation as shared-resource modification, that layer [cannot run them](./do-work/operate/01-queue-and-authorization.md#production-class-console-actions--one-batched-confirmation-then-stop-the-class-after-a-denial-1563), so the maintainer walks the same item twice. `/my-turn` is attended, so after the batched record, offer each such issue's commands **once**, in a single `AskUserQuestion` that names every command verbatim:

- **Run them now** → run each command in the foreground as its own plain `Bash` call, so the maintainer approves each one at the harness permission prompt. Report each result. Once every command succeeds, post a comment naming what ran and close the issue as completed. If a command is refused or fails, stop that issue, leave it on `agent-console`, and post the exact commands that remain.
- **Leave it for `/do-work`** → no extra mutation beyond the record step. Name the permission-rule remedy in the summary (for example `Bash(gcloud firestore:*)` via `/permissions`) so the next `/do-work` session can run the commands.

This offer covers CLI commands only. A browser-only action stays a hand-back, per the [Don't](#dont) rule against driving the browser. A **delete** or an **access-widening** change is never run here, even with the maintainer present. It stays a hand-back: surface the exact command for the maintainer to run themselves. Never route around a refusal with a different command or a different tool.

Then print a one-block summary — which issues are now dispatch-ready, which were closed / kept open / split, which stayed gated and why — and **stop**. `/my-turn` dispatches no code workers and does not chain into `/do-work`; the maintainer runs `/shipyard:do-work` when they want the newly-unblocked work implemented.

Clear the journal only after the batch has been recorded successfully. If a record call fails, leave the journal intact and say which items did not land — losing a maintainer's answered decision set is far worse than a duplicate comment, and both record shapes' sentinels/idempotency checks already make a re-run safe.

#### Phase 3 — Walk the rest

Now walk the non-decision items set aside in Phase 1 — **one at a time, advancing until the queue is empty**, exactly as before:

1. **Surface the top item.** Render the highest-ranked remaining item as a focused `→ Now:` directive (format below).
2. **Walk it.**
   - **PR awaiting `$ME`'s review** → surface the PR URL and the diff summary, and prompt the user to review; when they've approved / requested changes, the item is done.
   - **Unanswered question / `@$ME` ping** → surface the question and the thread URL; the user posts their reply (or asks Claude to draft one for them to send) — `/my-turn` does not post on the user's behalf unless they direct it as part of the walkthrough.
   - **`blocked:ci` PR / epic to decompose by hand / housekeeping (stale draft, DIRTY, `CHANGES_REQUESTED`)** → surface the concrete next step and the URL, and point at the dedicated command where one applies (`/shipyard:decompose-epic` for a mechanically-shardable epic, `/shipyard:do-work` for a `blocked:ci` PR). Derive the next step from the survey projection alone, within the [per-item investigation ceiling](#per-item-investigation-ceiling-1073) — do not read CI logs or drill into a failing run's jobs to name the root cause; when the ceiling would be exceeded, render the [degraded form](#per-item-investigation-ceiling-1073) instead (see [Don't → Don't diagnose](#dont)). The user acts; the item is done when they say so.
3. **Confirm done, then advance.** When the user signals the current item is handled (submitted the review, posted the reply, closed the PR — or they say "skip" / "next"), **immediately advance to the next-ranked item** and repeat from step 1. Do NOT exit after one item; do NOT require the user to re-invoke the command.
4. **Terminate when the queue is empty.** Print the [empty state](#empty-state) confirmation and stop cleanly. See [Termination contract](#termination-contract) for the exact exit conditions.

**When a phase is empty, skip it silently.** No decision-gated issues → go straight to Phase 3. Nothing but decisions → Phase 2's summary is the last thing printed. Never announce a phase that has no work in it.

**The headline render** for the current [Phase 3](#phase-3--walk-the-rest) item (Phase 1 renders no `→ Now:` directive — it is a question run, not an item walk):

```
→ Now: answer the 7 product/schema decisions blocking the orgs feature (#1816)
  https://github.com/owner/repo/issues/1816
  (unblocks the orgs epic — 3 issues are Blocked by this)

  [1 of 6 human-only items]
```

When the action's next step lives in a **third-party console** (e.g. a security/access-control toggle the operator layer handed back), append the provider deep link on its own indented line below the GitHub artifact URL (see [Third-party console deep links](#third-party-console-deep-links)):

```
→ Now: enable the OAuth redirect URI a human must sign off (#74)
  https://github.com/owner/repo/issues/74
  https://console.firebase.google.com/project/<project>/authentication/providers
```

Rules for the per-item headline render:

- **`→ Now:` line.** The `→ Now: ` prefix, then the **imperative action** (verb-first, sentence-case, same shape as the list-mode action — see [Rendering rules](#rendering-rules)), then the artifact ref `(#<num>)` in parentheses at the end. This is the one mandatory line.
- **URL line.** The clickable GitHub artifact URL on its own indented line directly below.
- **Third-party console deep link (when applicable).** When the action's actual work happens in a provider console the human must operate (Meta / Firebase / Vercel / App Store Connect / Apple Developer / Play Console / GCP / GitHub settings), append the most-specific-reachable provider deep link on its own indented line below the artifact URL, derived per [Third-party console deep links](#third-party-console-deep-links). Falls back to the provider's top-level console when the specific page isn't derivable; omit when no console is involved. (A *mechanical* console action would have been filtered out as the operator layer's; what reaches here is a console step that needs the human's judgment or sign-off.)
- **Dependency / unblocks context (optional).** If the current item *unblocks* other tracked work (e.g. an issue whose closure is referenced by `Blocked by #<N>` on another open item), append one indented parenthetical line naming what it unblocks: `(unblocks #<N>)` / `(then <downstream> can go out)`. This tells the user *why* this is the next step. Derive it from the same signals the ranking uses (the dependency edges in Pass A/B); if there's no downstream dependency, omit the line.
- **Progress footer.** Append a blank line then `[<i> of <N> human-only items]` so the user always sees where they are in the walkthrough. When the current item is the last, render `[last human-only item]`.
- **Release-please / version-bump PR as a queue item.** A discretionary release PR (per [Ranking → Release-please / version-bump PRs](#release-please--version-bump-prs-discretionary)) is ranked at the bottom of P2, so it's only ever walked *after* every genuinely-blocking item — and only when something downstream blocks on the release shipping (the same exception that lets it rank up). If the release PR is the *only* human-blocked item, don't render a false-urgency directive — render the discretionary phrasing instead and terminate (there's no action *blocked on you*, just an open option):

  ```
  Nothing blocking you — the release PR #<num> is ready to ship whenever you want.
    https://github.com/owner/repo/pull/<num>
  ```

#### Decision-gated walkthrough

A **decision-gated** issue is a `needs-human-review` issue that scores leverage **4** as a *pure-decision item* because its body (or a scope-preflight comment) enumerates **answerable** blocking decisions (a numbered "Blocking decisions before any code can be written" list, an `## Open questions` / `## Open product/schema questions` heading, a `<!-- do-work-human-decision-required -->` marker, or a `design`-gated set of questions) — **or the thread carries a disposition-call signal** ([#1074](https://github.com/mattsears18/shipyard/issues/1074); see [Disposition-call detection](#disposition-call-detection-1074) below for that fourth trigger). This is the trigger surface [Phase 1](#phase-1--collect-no-mutation-no-work) partitions on. The two classes are walked differently: the three body-enumerated triggers are walked by **reusing `/shipyard:resolve-decisions`' interactive flow** ([#566](https://github.com/mattsears18/shipyard/issues/566), [#635](https://github.com/mattsears18/shipyard/issues/635)); a disposition call is walked by its own templated flow, defined below, since its question isn't enumerated anywhere to reuse.

**Body-enumerated decisions** — reuse the [per-decision walkthrough](./resolve-decisions.md#the-per-decision-walkthrough) verbatim: for each blocking decision, emit the 5-part format (restated question → concrete options with trade-offs → **a clear recommendation with reasoning** → lock + carry-forward → room to clarify before locking). Honor its mid-walkthrough controls ("help me think through this one", "skip this one", "stop / we'll finish later") and its partial-run rule (a skipped or halted decision-set does NOT clear the gate). **Don't re-implement that flow here — invoke its spec** so the two commands stay in lockstep.

**Run it in [deferred firing mode](./resolve-decisions.md#firing-mode--immediate-default-vs-deferred-batch-caller)** ([#1070](https://github.com/mattsears18/shipyard/issues/1070)): the walkthrough yields its decision set as a value and records **nothing**. `/my-turn` journals it and fires [resolve-decisions' Record + unblock](./resolve-decisions.md#record--unblock) for every collected issue together in [Phase 2](#phase-2--commit-all-mutation-batched). A `gh issue comment` or `gh issue edit` landing between two of the maintainer's answers is exactly the latency [#1070](https://github.com/mattsears18/shipyard/issues/1070) removes — the standalone `/resolve-decisions --issue N` path still records immediately, since with one issue there is nothing to batch.

**Disposition calls** ([#1074](https://github.com/mattsears18/shipyard/issues/1074)) — emit the same restated-question → options → recommendation → lock shape, but with the fixed [templated options](#disposition-call-detection-1074) (close as done / keep open / close and split) standing in for parts 1–3 rather than a body-derived question, and with no carry-forward needed (each disposition call is a single, independent decision). Same mid-walkthrough controls apply. This flow is journaled and deferred exactly like a body-enumerated decision, but its own record shape fires in Phase 2 — never `/resolve-decisions`' decisions-comment-and-unblock shape, since a disposition call doesn't make an item dispatch-ready, it resolves it (close / keep-open / split).

Rules for the decision-gated item:

- **Only for a genuinely decision-gated item.** Walk decisions only when the current item is a leverage-score-4 pure-decision `needs-human-review` issue with answerable decisions present, **or a disposition call per the detection below**. Do **NOT** treat an epic-decomposition handoff (`<!-- do-work-needs-decomposition -->` — that's `/shipyard:decompose-epic`'s job, score 1), an `external-dependency` defer (`<!-- do-work-external-dependency -->` — that's the operator layer's, already filtered out), a classifier-undispatchable hand-back (`<!-- do-work-classifier-undispatchable -->` — [#953](https://github.com/mattsears18/shipyard/issues/953); there is no enumerated decision to walk, only "do it by hand or grant a policy exception"), an external-author trust gate, an agent refuse (`<!-- do-work-agent-refuse -->`), a refinement fall-through (`<!-- do-work-refinement-fallthrough -->`), a legacy design-gate migration (`<!-- do-work-legacy-needs-design -->`), or an investigation-mode disposition (`<!-- do-work-investigation-disposition -->` — [#1091](https://github.com/mattsears18/shipyard/issues/1091)) as decision-gated — those carry `needs-human-review` but enumerate no answerable decisions **and no disposition-call signal**, so there's nothing to walk; surface them as a plain "what to do next" item and let the user act. **Clearing `needs-human-review` on a classifier-undispatchable item is not itself a fix** — nothing about the issue's content changed, so a bare label-clear followed by re-dispatch will most likely hit the same classifier denial again; only clear the label once the human has actually done the work by hand, or made an explicit permission-policy call that changes what a future dispatch attempt will look like.
- **The batched decisions record is the only mutation.** Posting the decisions comments and removing the gate labels (for body-enumerated decisions), or closing / keeping-open / splitting (for a disposition call, per its own [record shape](#disposition-call-detection-1074)), happen in [Phase 2](#phase-2--commit-all-mutation-batched), and only for the option the human actually chose — `/my-turn` performs no *other* mutation beyond these two documented record shapes (no arbitrary `gh pr edit`, no posting on the user's behalf outside the record). The mutation is what the human directed by working through the item; that's the human-facing boundary, not a violation of it. Deferring it to a batch changes the timing, not the boundary.
- **Only for a genuinely decision-gated item — and only its own decisions.** Phase 1 collects decisions **only** from issues that pass the trigger surface above. Never invent a question for an issue that enumerates none just to give the batch more to ask; an issue with no answerable decisions belongs to [Phase 3](#phase-3--walk-the-rest).
- **List-snapshot mode.** In `--all` / `--limit N > 1` snapshot mode there is no walkthrough — the decision-gated item renders its normal action row plus a one-line pointer (`→ run /shipyard:resolve-decisions --issue <N> to walk these` for a body-enumerated item; `→ close, keep open, or split — see thread` for a disposition call), since the snapshot is a static view, not an interactive session.

#### Disposition-call detection ([#1074](https://github.com/mattsears18/shipyard/issues/1074))

A **disposition call** is the fourth trigger class alongside the three body-enumerated ones above — and the only one that isn't a question the body poses at all. It fires on a `needs-human-review` issue, or a draft `needs-human-review` PR, whose gated work is already complete or all-but-complete, so the only remaining human action is a keep / close / split judgment rather than answering an enumerated question. Unlike the body-enumerated classes, a disposition call is inferred from the **thread**, not the body: the gate label was simply never cleared after the work landed. The repro that motivated this ([#1074](https://github.com/mattsears18/shipyard/issues/1074)): a `needs-human-review` issue whose own comment thread reads *"Fixed and verified — native Android push now delivers"*, body enumerating zero decisions, gate label still on a day-plus later.

**Detection — zero extra `gh` calls, derived entirely from data the survey passes already fetched.** Gated by [`disposition_call_detection`](#6-resolve-the-disposition-call-detection-toggle-1074) (default `true`):

- **Issue-shaped.** The issue carries `needs-human-review`, matches **none** of the three body-enumerated triggers above, AND the *newest* comment in Pass B's already-trimmed `comments` array (`comments[-1]`, the most recent of the kept last-3) asserts completion — a phrase like "fixed and verified", "verified", "completed", "resolved", "confirmed working", "works now", "closes this", "done", or a checked-off acceptance-criteria list with at most one item still open and prose explaining why that one can't be closed out. Because the label is still on the issue and nothing newer than that comment walked the assertion back, the gate label is — by construction — older than the completion assertion: this is the **strongest signal** the [original issue](https://github.com/mattsears18/shipyard/issues/1074) names, and it requires no timestamp comparison, since the projection's own recency ordering already proves it.
- **PR-shaped** (validated against [PR #1100 / issue #1096](https://github.com/mattsears18/shipyard/pull/1100)). A **draft** PR carries `needs-human-review`, and one of its `closingIssuesReferences[].number` (added to Pass A's `--json` fields — same call, no round-trip) is **absent from Pass B's already-fetched open-issue set**. Pass B fetches every open issue (up to 200) in the same survey batch, so an absent number means that issue closed (e.g. `NOT_PLANNED`) while the PR was still in flight — the PR's own fate is now a disposition call, with nothing left to decide about the underlying feature since the issue that motivated it is gone.

**Guard — don't invent a disposition call.** This class fires only when a completion-assertion or closed-linked-issue signal is actually present in the fetched projection. A `needs-human-review` issue with a quiet thread, or a draft PR whose linked issue is still open, is **not** a disposition call — it stays in the ordinary `needs-human-review` bucket ([Phase 3](#phase-3--walk-the-rest)), never a manufactured close/keep/split question. This is the same "never invent a question for an issue that enumerates none" guard the body-enumerated classes already carry (see the Rules above) — extended to disposition calls, not an exception to it.

**Templated options.** A disposition call has a near-fixed shape, so its walkthrough is templated rather than improvised:

| Option | When to recommend |
|---|---|
| **Close as done** | The completion assertion covers the item's entire scope — no named remainder, or the remainder is trivially covered by the same verified path. |
| **Keep open** (name precisely what remains) | The thread names a specific unfinished or unverified piece, AND that piece is genuinely **distinct** code from what's already verified — not merely an artifact of the same verified path. |
| **Close and split the remainder into a narrow follow-up** | The remainder is real but small and well-scoped enough to become its own dispatch-ready issue, decoupling the verified core from the unverified edge. |

The recommendation turns on exactly one question: is the unfinished remainder **shared with an already-verified path** (favors close-as-done) or **genuinely distinct, unverified code** (favors keep-open or split)? A worked example from the originating repro: a web-push service worker's `notificationclick` handler is a *different* code path from an already-verified native tap-handler — so "close as fully verified" would have been wrong there, and "keep open, naming the unverified web hop" was the right call. Answering this from the survey projection alone (the same completion-assertion comment already read for detection, not a second investigation) stays within the [per-item investigation ceiling](#per-item-investigation-ceiling-1073).

**Record shape.** Lead every disposition-call mutation with the idempotency sentinel `<!-- shipyard-disposition-call -->` on its own first line (mirrors `/resolve-decisions`' `<!-- shipyard-resolve-decisions -->` — a re-run checks for it before re-mutating). Fires in [Phase 2](#phase-2--commit-all-mutation-batched):

- **Close as done** → `gh issue close <N> --repo <owner/repo> --reason completed` (or `gh pr close <M> --repo <owner/repo>` for a PR-shaped call), with a closing comment citing the disposition rationale.
- **Keep open** → post a comment naming precisely what remains (per the maintainer's answer), and remove `needs-human-review` only if the named remainder is itself autonomously workable by `/do-work` — leave the label on if the remainder still needs a human call (rare; usually means "close and split" was the better-fitting option).
- **Close and split** → file a fresh, ungated follow-up issue for the named remainder (`--label shipyard`, per `shipyard:filing-github-issues`), then close the original as completed with a comment linking the follow-up.

**Validated example.** Applying this detection to [PR #1100](https://github.com/mattsears18/shipyard/pull/1100) / issue #1096 from this same session: #1096 closed `NOT_PLANNED` mid-dispatch when the maintainer shelved the approach, leaving PR #1100 open as a `needs-human-review` draft with no enumerated decision anywhere. Under the PR-shaped signal above, `#1096` is absent from Pass B's open-issue set while PR #1100 remains open and draft — a disposition call, correctly promoted to Phase 1 rather than left for a Phase 3 walk.

### List-snapshot mode (`--all`, or `--limit N > 1`)

Print the full ranked list as a static snapshot — **no phased run, no questions, no mutation**; this mode exists to let the user *eyeball* the human-only backlog at a glance. Lead with the verb; same terse, framing-free shape as before. Format:

```
1. #142 review and approve or request changes  <https://github.com/owner/repo/pull/142>
2. #155 read refined body, set priority label, remove needs-human-review  <https://github.com/owner/repo/issues/155>
3. #148 investigate failing check (`gh pr checks 148 --watch`), fix or escalate  <https://github.com/owner/repo/pull/148>
4. #161 reply to @<other-login>'s question or close if stale  <https://github.com/owner/repo/issues/161>
5. #134 finish draft and mark ready-for-review, or close (11d stale)  <https://github.com/owner/repo/pull/134>

1 blocked:ci PR
```

<a id="operator-pointer-line"></a>**Operator pointer line.** Renders only when `my_turn.assume_operator_enabled` is `true` (the default — resolved once at [Setup step 7](#7-resolve-the-operator-phase-assumption-for-the-agent-console-filter-1093)) AND the [Human-only queue filter](#human-only-queue-filter) excluded one or more `agent-console` / browser-completable items: append a single one-line pointer below the structural footer so the user knows those items exist and which command drains them (never list them individually — they aren't `/my-turn`'s work):

```
6 browser-completable operator actions excluded — run /shipyard:do-work to have Claude complete them
```

**When `my_turn.assume_operator_enabled` is `false`, don't render this pointer at all** ([#1093](https://github.com/mattsears18/shipyard/issues/1093)). The items it would name aren't excluded from the queue in the first place under that config — they're walked as ordinary human-only items instead (see the [Human-only queue filter](#human-only-queue-filter)) — and the whole reason for the config gate is that the pointer line must never name a command configured not to do the work.

This pointer, when it renders, is the *only* trace of operator items in `/my-turn` output. It renders in list-snapshot mode (below the structural footer) and, in [walkthrough mode](#walkthrough-mode-default), once at the end when the queue empties (alongside the empty-state confirmation) — never as a walked item.

<a id="in-flight-pointer-line"></a>**In-flight pointer line** ([#1080](https://github.com/mattsears18/shipyard/issues/1080)). Renders only when [Setup step 9](#9-resolve-do-works-live-session-state-optional-enrichment-1080) found a live session AND the [Human-only queue filter](#human-only-queue-filter)'s in-flight suppression bullet actually excluded ≥1 candidate this run:

```
2 items excluded — a live /shipyard:do-work session is already working on them
```

Same placement as the [operator pointer line](#operator-pointer-line) above (list-snapshot mode: below the structural footer; walkthrough mode: once at the end alongside the empty-state confirmation) — never a walked item, never listed individually. **Never renders when Setup step 9 found nothing to read** (no session file for this repo, a dead session, an unreadable/malformed file) — silence here is the correct degrade, not a state worth calling out.

<a id="default-branch-ci-line"></a>**Default-branch CI line** ([#1080](https://github.com/mattsears18/shipyard/issues/1080)). Renders only when [Setup step 9](#9-resolve-do-works-live-session-state-optional-enrichment-1080)'s `main_ci_status` resolved to `"red"` from a fresh (≤30 min old) cached reading — green, pending, and `"unknown"` never render a line, and `/do-work` already owns fixing a red default branch on its own (see [Human-only queue filter](#human-only-queue-filter)), so this line is purely informational and never a queue item:

```
default branch CI: red (cached — /shipyard:do-work owns recovery)
```

When `$live == 1` and a live `.in_flight` slot carries `kind == "fix-main-ci"` (already read in [Setup step 9](#9-resolve-do-works-live-session-state-optional-enrichment-1080) step 3), append `— a live session is already on it`. This is exactly the "is red main already claimed" question the originating [#1080](https://github.com/mattsears18/shipyard/issues/1080) repro spent six `gh` calls answering by hand; here it costs zero calls beyond what step 9 already fetched. **Enrichment only** — never a queue item, and it never renders from a stale or absent reading.

### Chrome-prompt mode (`--chrome-prompt`)

When `--chrome-prompt` is present, the **entire visible output** is a single copy-paste-ready prompt block. Nothing appears above the opening divider line and nothing appears below the closing divider line except the optional "can't be automated" section. The user highlights from the first divider line to the last, pastes the whole thing into the Claude for Chrome browser extension, and the extension acts — no further reading or interpretation required.

**Survey and ranking run identically; the queue filter is inverted, not shared** ([#1092](https://github.com/mattsears18/shipyard/issues/1092)). The same passes A–C run, and the same priority tiers and leverage scores compute over the results — but chrome-prompt mode's *consumer* is not a human at a terminal, it's the Claude for Chrome browser extension pasted into a live session. The [Human-only queue filter](#human-only-queue-filter) exists to hand a human only the items *they* must decide or judge — it deliberately drops everything `/do-work`'s browser-completable operator layer can drive (`agent-console` items, per the [Pass B bucket](#pass-b--open-issues)). That's exactly backwards for an audience that IS a browser extension: an `agent-console` item (close a superseded PR, flip a non-security console toggle, take a `console-action`) is precisely what the extension can navigate, click, and type its way through; a `needs-human-review` decision is precisely what it cannot. So chrome-prompt mode runs the **[Chrome-completable queue filter](#chrome-completable-queue-filter)** below in place of the Human-only queue filter — everything else (survey, ranking, `--all` / `--limit` governing how many actions are included: top-1 without `--all`; all ranked browser-completable items with `--all`, capped at `--limit`) is unchanged. See "Distinction from `/do-work`" below for how this composes with the agent-driven operator phase that does the equivalent work directly.

#### Chrome-completable queue filter

The inverse of the [Human-only queue filter](#human-only-queue-filter), applied only in chrome-prompt mode:

- **Include in the prompt body** — issues carrying the `agent-console` label (renamed from `needs-operator` in [#995](https://github.com/mattsears18/shipyard/issues/995); the legacy-name back-compat window is closed per [#1082](https://github.com/mattsears18/shipyard/issues/1082)) whose action is a mechanical navigate/click/type step: close a superseded PR, merge a ready PR, flip a non-security console toggle, take a `console-action`, post an unambiguous reply. These are the same items `/do-work`'s operator layer would drive itself via MCP ([`operate.md`](./do-work/operate.md)); the extension drives the identical class of action through the user's own live browser session instead.
- **Exclude — route to the ["can't be automated" section](#chrome-prompt-mode---chrome-prompt) instead** — two disjoint classes, neither belongs in the pasted prompt:
  1. **Every item that survives the ordinary [Human-only queue filter](#human-only-queue-filter) unchanged** — `needs-human-review` decisions, disposition calls, PRs awaiting `$ME`'s review, `blocked:ci`, unanswered questions, and the housekeeping signals. These need the user's own judgment; an extension acting on the user's behalf can't supply that.
  2. **A credential- or account-creation-shaped `agent-console` item.** Detect it from the same Pass B `comments` projection already fetched (zero extra `gh` calls): the newest trimmed comment contains the `<!-- do-work-external-dependency -->` marker, or the substring "provisioning" (case-insensitive) — the two shapes [`issue-work.md` §4.4](../agents/issue-worker/issue-work.md#44-external-provisioning-guard--dont-commit-dead-config-for-an-unprovisioned-service-628)'s worker-side bail and the scope-preflight `external-dependency` defer both produce for "a real secret/account doesn't exist yet." Typing or pasting a real credential value, or creating a new account, is a harness-level prohibition that binds the extension exactly as it binds `/do-work`'s own MCP-driven operator phase ([#991](https://github.com/mattsears18/shipyard/issues/991); see this repo's `CLAUDE.md` § "Standing grant for authenticated browser work" for the same absolute limits — never a password, never a secret value, never a new account). Carrying the `agent-console` label is necessary but not sufficient for inclusion — this narrower check runs first and wins.

On a repo where every human-blocked item is a decision and every operator item is a plain `agent-console` action (none provisioning-shaped), the prompt body is non-empty — it's built entirely from that operator set.

**Prompt construction.** The body of the pasted prompt is self-contained instructions telling the extension what to do — concrete enough that the extension can act without re-deriving anything:

- For each included action: the imperative action sentence (verb-first, sentence-case), the GitHub artifact URL, and — when applicable — the third-party console deep link (same derivation as the standard render). The extension can navigate to URLs; include them literally.
- Enough context to identify each item unambiguously: PR or issue number, what to click, what to decide, what text to type (e.g. for a review: whether to approve or request changes).
- When covering multiple actions (`--all`), present them as a numbered list inside the prompt body, ordered by the same ranking used by the standard render.

**Layout.** Print exactly this structure, with no other content outside the dividers and the trailing section:

```
                                               (one blank line)
──────────────── COPY THE PROMPT BELOW ────────────────
                                               (one blank line)
<the full pasteable prompt for the Claude Chrome extension>
                                               (one blank line)
──────────────── COPY THE PROMPT ABOVE ────────────────
                                               (one blank line)

⚠️  Can't be automated (do these yourself):
- <item>
```

Rules for each layout element:

- **Divider lines.** Use exactly `──────────────── COPY THE PROMPT BELOW ────────────────` and `──────────────── COPY THE PROMPT ABOVE ────────────────` (em-dashes `─`, U+2500, repeated). The labels are capitalised; the dashes form a full-width visual rule. One blank line on each interior side of the dividers.
- **Prompt body.** Self-contained, complete instructions. No meta-commentary ("here is what you should do"), no output-format instructions to the reader — write to the extension as if it were receiving the instructions directly. Use the present-tense imperative ("Go to ...", "Open ...", "Click ...", "Review ..."). Include all URLs. For decision-gated items, enumerate the specific decisions to make and any context the extension needs to recommend or resolve them.
- **"Can't be automated" section.** Appears after the closing divider, separated by one blank line. Populated by every item the [Chrome-completable queue filter](#chrome-completable-queue-filter) excluded from the prompt body: the ordinary human-only queue (decisions, disposition calls, PR review, `blocked:ci`, unanswered questions, housekeeping) plus any credential-/account-creation-shaped `agent-console` item. Render one bullet per item using the same imperative-action + URL shape as [list-snapshot rows](#rendering-rules), capped at `--limit` (default 25) with the same `… and <K> more (rerun with --limit <K+N> to see all)` overflow line list-snapshot mode uses when the cap is exceeded. The `⚠️  Can't be automated (do these yourself):` header introduces it. **Omit the section entirely** (header and all) when there are no such items — do not emit an empty section or a "none" bullet. The classification heuristic restates the filter's exclusion rule: an action is browser-doable if it consists of navigation + clicking + typing in a browser tab using the user's session; it is NOT browser-doable if it requires out-of-browser credentials, a native device (TestFlight, on-device build), a third party's manual action, or a purely personal judgment the user must own.
- **Empty state in chrome-prompt mode.** Two distinct cases, since the [Chrome-completable queue filter](#chrome-completable-queue-filter) can be empty while the ordinary human-only queue isn't (or vice versa):

  - **Nothing at all** — both the Chrome-completable set and the ordinary human-only queue are empty. Emit the same empty-state text as normal mode, wrapped in the dividers so the output shape is consistent:

    ```
                                                   (one blank line)
    ──────────────── COPY THE PROMPT BELOW ────────────────
                                                   (one blank line)
    Nothing on your plate — backlog is clean. No actions for the Chrome extension right now.
                                                   (one blank line)
    ──────────────── COPY THE PROMPT ABOVE ────────────────
    ```

  - **Nothing browser-completable, but human-only items remain** — the prompt body says so explicitly instead of emitting a divider block with nothing for the extension to act on, and the "can't be automated" section carries the real items:

    ```
                                                   (one blank line)
    ──────────────── COPY THE PROMPT BELOW ────────────────
                                                   (one blank line)
    Nothing for the Chrome extension to do right now — every open item needs your own judgment. Run /my-turn (without --chrome-prompt) to walk them.
                                                   (one blank line)
    ──────────────── COPY THE PROMPT ABOVE ────────────────

    ⚠️  Can't be automated (do these yourself):
    - <item>
    ```

**What chrome-prompt mode does NOT emit:**

- No `→ Now:` prefix or directive, and no interactive walkthrough — chrome-prompt mode is a one-shot text emission, not the phased run.
- No ranked numbered list above or outside the dividers.
- No tier headers, signal labels, or remainder footer.
- No operator pointer line. Under the [Chrome-completable queue filter](#chrome-completable-queue-filter), `agent-console` items are the prompt's primary payload, not something filtered out — the [operator pointer line](#operator-pointer-line) is a walkthrough-mode / list-snapshot-mode-only affordance for a human reader; it has no role in a prompt the extension consumes directly.
- No inline decision walkthrough (the `/shipyard:resolve-decisions` flow is a terminal-interactive affordance; the chrome-prompt output goes to the extension, not into an interactive session).
- No structural footer line (`<N> blocked:ci PRs`).

**Distinction from `/do-work`.** The `--chrome-prompt` flag is text-emission only: Claude emits a prompt string and stops. No `chrome-devtools-mcp` calls, no browser automation, no MCP connection. The Claude for Chrome extension is a separate agent that receives the text and operates independently. `/do-work` (operator-inclusive by default) covers the complementary mode where Claude Code itself drives the browser via MCP — do not conflate the two. **Both target the identical [Chrome-completable set](#chrome-completable-queue-filter)** — the same `agent-console` items `/do-work`'s proactive sweep would enqueue and drive directly are what `--chrome-prompt` hands to the extension as text; the only difference is *who* drives the browser (Claude Code itself vs. the user pasting into the extension), never *which* items are in scope. This is the coherent story the [Chrome-completable queue filter](#chrome-completable-queue-filter) buys: before this fix, the two commands nominally overlapped on the same class of work while `--chrome-prompt` silently targeted the opposite queue.

### Termination contract

The phased run is the only mode that continues until a queue is exhausted, so it needs a defined exit ([#635](https://github.com/mattsears18/shipyard/issues/635)). It **terminates cleanly** when any of:

- **Both queues are empty** — every decision was collected and committed, and every [Phase 3](#phase-3--walk-the-rest) item has been walked (handled or skipped). Print the [empty state](#empty-state) confirmation, plus the [operator pointer line](#operator-pointer-line) if any `agent-console` items were filtered out, plus the [in-flight pointer line](#in-flight-pointer-line) and [default-branch CI line](#default-branch-ci-line) if applicable ([#1080](https://github.com/mattsears18/shipyard/issues/1080)), and stop.
- **The user stops it** — the user says "stop" / "that's enough" / "done for now" at any point. **Where the halt lands matters:**
  - **During [Phase 1](#phase-1--collect-no-mutation-no-work)** → do **not** discard the answers already given. Proceed directly to [Phase 2](#phase-2--commit-all-mutation-batched) and commit them, applying the per-issue answered/partial branch, then report what landed and how many decisions remain uncollected (`<K> decisions left — rerun /my-turn to continue`). Skipping Phase 2 on a halt would throw away work the maintainer already did.
  - **During Phase 3** → halt immediately; confirm what's been handled and how many items remain (`<K> human-only items left — rerun /my-turn to continue`), and stop.
- **Only a discretionary release PR remains** — render the "ready to ship whenever you want" phrasing (see [walkthrough mode](#walkthrough-mode-default)) and stop, since there's no action *blocked on you*.

**A halted or skipped decision set still follows the partial-run rule** — the gate is NOT cleared unless every blocking decision on that issue was answered.

The run does NOT re-run the survey passes after each item by default — it consumes the up-front ranked queue. **Re-derive only on a defined refresh:** the natural one is **after Phase 2**, since committing decisions plausibly changed the queue (an unblocked issue may be what another item was `Blocked by`); re-run the passes once there before starting Phase 3. Also re-derive if the user reports they completed something out-of-band. Don't re-survey between questions or on every Phase 3 step — that burns the [performance budget](#performance-budget) and reorders the queue under the user mid-session.

### Rendering rules

These apply to the **list-snapshot** items and to the action sentence inside the walkthrough's `→ Now:` directive.

Per item — **one line by default**:

- **Index** (1-based, monotonic across the entire list) followed by `.`
- **Artifact ref** — `#<num>` only (no `PR`/`Issue` prefix — the URL discloses the type; the number is the disambiguator).
- **Imperative action** — verb-first, sentence-case, no trailing period. This is the only mandatory content. Examples: `review and approve or request changes`, `investigate failing check, fix or escalate`, `reply to question or close`, `make the design call (see thread) or break into spike + impl`, `enable Email/Password in Firebase Console for <project>`, `set real values for placeholder secrets via firebase functions:secrets:set --project test`, `review the refuse reason in the comment; clear, re-scope, or close` (agent-refuse `needs-human-review`, `<!-- do-work-agent-refuse -->`, per [#521](https://github.com/mattsears18/shipyard/issues/521)), `vouch for @<author> (add to .shipyard/trusted-authors.txt or re-file), triage by hand, or close` (external-author trust review, `<!-- do-work-untrusted-author-review -->`, per [#1079](https://github.com/mattsears18/shipyard/issues/1079)), `close as done, keep open (name what remains), or split into a follow-up` (disposition call, per [#1074](https://github.com/mattsears18/shipyard/issues/1074)), `write up so a refiner rule can act, or close` (refinement fall-through, `<!-- do-work-refinement-fallthrough -->`, per [#520](https://github.com/mattsears18/shipyard/issues/520)), `cite the disposition reason in the comment; make the call or hand back to /do-work` (investigation-mode disposition, `<!-- do-work-investigation-disposition -->`, per [#514](https://github.com/mattsears18/shipyard/issues/514)) — all four per the [provenance marker table](#pass-b--open-issues), [#1091](https://github.com/mattsears18/shipyard/issues/1091).
- **Stale suffix** (optional) — append `(<N>d stale)` only when the item's age crosses a threshold worth flagging: **≥7d** for any item, or **≥1d** for `awaiting your review` (the highest-leverage block). Default: no age string. The point is a flag, not a metric.
- **URL** — clickable `<https://...>` at end of line so terminals render it as a hyperlink. Two spaces before the URL for visual separation.
- **Third-party console deep link** (optional) — when the item's action's next step lives in a provider console (Meta / Firebase / Vercel / App Store Connect / Apple Developer / Play Console / GCP / GitHub settings), append the most-specific-reachable provider deep link `<https://...>` after the GitHub artifact URL (two spaces before it), derived per [Third-party console deep links](#third-party-console-deep-links). Falls back to the provider's top-level console when the specific page isn't derivable. Omit when no third-party console is involved. Example: `6. #74 create a Test User on the test Meta app 982594884358918  <https://github.com/owner/repo/issues/74>  <https://developers.facebook.com/apps/982594884358918/roles/test-users/>`.

**Drop by default:**

- **Title restatement.** The action sentence carries the artifact's intent in active voice; the title is reference, not headline. Include only when the action genuinely doesn't disambiguate without it (rare — e.g. `#42 review (auth refactor)` to distinguish from `#43 review (logging migration)` when several PRs are queued).
- **Per-item signal labels** (`needs-human-review`, `blocked:ci`, `awaiting your review`, `DIRTY`). The action sentence already encodes the signal; the label is metadata on the artifact for users who want the receipt.
- **Tier headers** (`P0 — blocking other work`, etc.). Items are already ranked; the position is the priority. Internal ranking still uses P0/P1/P2 (see [Ranking](#ranking)) — the tiers just don't render.
- **The opening `HUMAN ACTIONS NEEDED — …` banner.** Redundant — the user just typed the slash command.

**Multi-line items.** Only when the next action genuinely doesn't fit on one line *and* breaking it loses information. Follow-up lines are indented and still action-shaped (continuation of the verb), never framing or restatement.

**Optional footer line** — one line, terse, at the bottom of the list. Surface only if there are open `blocked:ci` PRs (`<N> blocked:ci PRs`). Skip entirely if there's nothing structural worth flagging. Never a paragraph; never a recap of items already in the list.

### Third-party console deep links

When the next action's actual work happens in a **third-party provider console** ([#523](https://github.com/mattsears18/shipyard/issues/523)) — the user has to create a test user in the Meta App Dashboard, enable an auth provider in the Firebase Console, paste a secret into a GitHub repo's Actions settings, submit a build in App Store Connect, etc. — the rendered action **MUST** append a clickable deep link to the **most specific reachable page**, derived from identifiers already in hand (app ID, project ID, bundle ID, team/owner slug, etc.). The information needed to build the link is almost always already present in the issue/PR body, a comment, or the repo's config — turning it into a URL costs the user one navigation they'd otherwise do by hand, across a provider UI with many nested pages.

This applies to **all three modes**: the walkthrough `→ Now:` headline (the deep link goes on the indented URL line, *in addition to* the GitHub artifact URL — see [Walkthrough mode](#walkthrough-mode-default)), the list-snapshot rows (the deep link is appended after the GitHub artifact URL — see [Rendering rules](#rendering-rules)), and the chrome-prompt body (include the URL literally in the prompt text so the extension can navigate directly — see [Chrome-prompt mode](#chrome-prompt-mode---chrome-prompt)).

**Provider URL templates.** Substitute the bracketed identifiers from the action's context. Extend this table as new providers/actions surface — it's a starting set, not a closed list:

| Provider | Action | URL template |
|---|---|---|
| Meta App Dashboard | Test Users | `https://developers.facebook.com/apps/<APP_ID>/roles/test-users/` |
| Meta App Dashboard | App settings / basic | `https://developers.facebook.com/apps/<APP_ID>/settings/basic/` |
| Firebase Console | Auth users | `https://console.firebase.google.com/project/<PROJECT_ID>/authentication/users` |
| Firebase Console | Auth providers | `https://console.firebase.google.com/project/<PROJECT_ID>/authentication/providers` |
| Vercel | Project | `https://vercel.com/<TEAM>/<PROJECT>` |
| App Store Connect | App | `https://appstoreconnect.apple.com/apps/<APP_ID>` |
| Apple Developer | Identifiers | `https://developer.apple.com/account/resources/identifiers/list` |
| Play Console | App dashboard | `https://play.google.com/console/u/0/developers/<DEV_ID>/app/<APP_ID>/app-dashboard` |
| GCP Console | Project | `https://console.cloud.google.com/home/dashboard?project=<PROJECT_ID>` |
| GitHub | Repo Actions secrets | `https://github.com/<owner>/<repo>/settings/secrets/actions` |

**Fallback when the specific page isn't derivable.** If a required identifier is missing (you know it's a Firebase auth task but the body never names the `<PROJECT_ID>`), link the provider's **top-level console** rather than no link at all — a one-hop landing page still beats prose-only navigation:

| Provider | Top-level fallback |
|---|---|
| Meta App Dashboard | `https://developers.facebook.com/apps/` |
| Firebase Console | `https://console.firebase.google.com/` |
| Vercel | `https://vercel.com/dashboard` |
| App Store Connect | `https://appstoreconnect.apple.com/apps` |
| Apple Developer | `https://developer.apple.com/account/` |
| Play Console | `https://play.google.com/console/` |
| GCP Console | `https://console.cloud.google.com/` |
| GitHub | `https://github.com/<owner>/<repo>` |

**Derivation rules:**

- **Use identifiers already in hand — never fabricate one to fill a template.** Pull `<APP_ID>` / `<PROJECT_ID>` / `<owner>`/`<repo>` from the action's context (the issue or PR body that produced the item, a comment, the resolved repo). If you can only partially fill a template (e.g. the provider and a project ID but not the exact sub-page), link the deepest page you *can* fully construct, then fall back up the hierarchy — most-specific-reachable wins, but a guessed identifier is worse than the fallback (a wrong deep link sends the user to someone else's app).
- **Read-only constraint still holds.** Deriving the link is pure string construction from data already surveyed; it adds no `gh` mutation and no new API round-trip. Do **not** call out to a provider API to *discover* a missing identifier — that's scope creep and may require credentials the command doesn't have. Missing identifier ⇒ top-level fallback, full stop.
- **One deep link per action.** If an action plausibly touches two consoles, link the one where the *next* step happens; don't stack multiple provider links on one directive.

### Internal fields (used for ranking, not rendered)

The ranking step still needs the underlying signals to produce the order — they just don't appear in the rendered output. The internal projection per item carries:

- **Tier** — P0 / P1 / P2 (see [Ranking](#ranking)).
- **Leverage score** — 4 / 3 / 2 / 1 (see [Secondary sort](#secondary-sort--leverage-score-then-age-issue-565)), derived from the same survey signals. The **primary** within-tier sort key (descending); not rendered. Issue [#565](https://github.com/mattsears18/shipyard/issues/565).
- **Why-on-user** — the signal name that fired (`awaiting your review`, `blocked:ci`, `needs-human-review`, etc.). Used by the ranking + dedup logic; not rendered unless multiple signals merged into one row produced a non-obvious action verb, in which case a single inline `(also: <signal>)` suffix is permitted.
- **Age** — `createdAt` for new items, `updatedAt` for label-change items (v1 heuristic: use the older of the two; under-counts but never over-counts). The **tie-breaker** within a leverage score (oldest first); also triggers the stale suffix.
- **URL** — surfaces unmodified.

### Empty state

If the human-only queue is empty — passes A–C returned zero human-only items, or the [walkthrough](#walkthrough-mode-default) just exhausted the queue — print a single friendly one-liner and exit cleanly. **Unchanged across modes** — the empty state is identical whether the queue started empty or the walkthrough drained it, and whether or not `--all` / `--limit` is passed. No banner, no multi-line prose — this is the one case where the answer to "what do I need to do" is actively "nothing," and the rendering should mirror the content. If `agent-console` items were filtered out, append the [operator pointer line](#operator-pointer-line) below it so the user knows the operator layer still has work. Append the [in-flight pointer line](#in-flight-pointer-line) and/or the [default-branch CI line](#default-branch-ci-line) too, when either applies ([#1080](https://github.com/mattsears18/shipyard/issues/1080)) — a genuinely empty human-only queue is still worth knowing "and here's what's already being worked."

```
Nothing on your plate — backlog is clean. Try /shipyard:audit to surface fresh work, or take a break.
```

### Limit overflow (list-snapshot mode only)

In **list-snapshot mode**, if the ranked list has more items than `--limit`, print the first `--limit` items then:

```
  … and <K> more (rerun with --limit <K+N> to see all)
```

This overflow line is list-snapshot-mode only. In [walkthrough mode](#walkthrough-mode-default) there's no overflow — the loop walks every human-only item in turn, so nothing is hidden behind a cap; the `[<i> of <N> human-only items]` progress footer is the "how much is left" signal instead.

## Performance budget

The full survey should complete in well under 10 seconds for a backlog of ~100 PRs and ~200 issues:

- Pass A + Pass B: two parallel `gh` calls, each ~1–2s
- Pass C: skipped entirely (zero calls) when the repo has no non-`$ME` PR authors ([#1089](https://github.com/mattsears18/shipyard/issues/1089)) — the common case on a solo/agent-driven repo. Otherwise capped at 20 per-PR follow-ups, run in parallel, ~3s total

If a backlog blows the budget, `--limit` already provides a knob; otherwise file an issue for a future v2 that uses GraphQL to collapse Passes A+B+C into one round-trip.

**[Phase 1](#phase-1--collect-no-mutation-no-work)'s bulk context pass is budgeted separately, and deliberately front-loads cost.** It runs once, after the survey and before the first question, and it may fan out read-only readers in parallel. Its budget is *not* "as fast as possible" but "all of it before the maintainer is asked anything" — the metric that matters is the gap between two consecutive answers, which should be **zero** tool calls in the steady case. Spending a few extra seconds up front to buy that is the trade [#1070](https://github.com/mattsears18/shipyard/issues/1070) makes; re-reading the codebase between two questions to save it is exactly the anti-pattern. **This front-loading is scoped to grounding a *decision* the human is about to be asked to make** — a design tradeoff, a scope call, the recommendation behind a decision-gated issue's options. It is not, and must never be read as, license to establish *why* a [Phase 3](#phase-3--walk-the-rest) item (a red check, a `blocked:ci` PR) broke; that's diagnosis, and the ceiling below governs it regardless of how much budget Phase 1 spent.

### Per-item investigation ceiling ([#1073](https://github.com/mattsears18/shipyard/issues/1073))

The survey passes' own budget above governs *collection*. This governs what happens **after** an item is ranked and its rendered action is being written — the gap the original v1 budget left open, and the one an agent under pressure to write a genuinely useful `→ Now:` line has every incentive to fill by digging deeper.

**The ceiling: deriving any single item's rendered action costs zero additional tool calls beyond the survey projection in the steady case, and never more than `$max_diagnostic_reads_per_item` (default `1`, resolved once at [Setup step 5](#5-resolve-the-per-item-investigation-depth-ceiling-1073)).** The survey projection is Passes A–C's own `gh` output, plus — for a decision-gated issue only — [Phase 1](#phase-1--collect-no-mutation-no-work)'s bulk context pass. One extra read means exactly one: e.g. a single `gh pr view` on the item's own number for a field the list projection didn't request. It never means reading CI logs, drilling into a run's jobs (`gh run view --json jobs`, `gh api .../actions/runs/<id>/jobs`), tracing a stack trace, or otherwise walking multiple `gh` calls to reconstruct *why* something failed — that is root-causing, and root-causing an item is always out of scope for `/my-turn` regardless of how it's ranked (see [Don't → Don't diagnose](#dont)).

**This applies to every item, in every mode (walkthrough, list-snapshot, chrome-prompt), to every signal in [Ranking](#ranking) today, and to any signal added later.** The bound is structural — expressed as a ceiling on tool calls, not as a list of signals to be careful with — so it doesn't need updating every time a new label or PR state is added to the survey. A P0 item is the strongest possible "invest here" signal the ranking produces; the ceiling is what stops that signal from being read as license to keep digging until the action sentence feels satisfying.

**Degraded render — when the ceiling would be exceeded.** Stop and render exactly what the survey established instead of continuing to investigate: the known signal, the artifact URL, and a pointer to the command that owns going deeper (`/shipyard:do-work`, `/shipyard:decompose-epic`). For example, a `blocked:ci` PR whose failure isn't legible from the check-rollup name alone renders as `#148 investigate failing check — run /shipyard:do-work to have Claude diagnose and fix it <url>`, never a line naming the specific failing step or error string pulled from a log. The degraded form is not a failure state or a fallback to apologize for — it is the correct, complete render for an item whose diagnosis is someone else's job. See [Rendering rules](#rendering-rules) for how this composes with the one-line-by-default render shape.

**[Disposition-call detection](#disposition-call-detection-1074) ([#1074](https://github.com/mattsears18/shipyard/issues/1074)) costs *zero* additional tool calls, not merely staying within the ceiling.** Both signals — a completion-asserting last comment, or a PR's closing-reference number absent from Pass B's already-fetched open-issue set — read fields Passes A and B already fetched in the survey batch itself. It is the surfacing of *that* an item is a disposition call and *what* the templated options are, never an investigation into *why* the underlying work is or isn't complete — the same router-not-investigator boundary this whole section exists to enforce.

## Don't

- **Don't diagnose — surface** ([#1073](https://github.com/mattsears18/shipyard/issues/1073)). An item's rendered action must be derivable from the survey passes' own projection plus, at most, the [per-item investigation ceiling](#per-item-investigation-ceiling-1073)'s one extra read — never by reading CI logs, drilling into a run's jobs, tracing a stack trace, or otherwise establishing *why* something failed. `/my-turn` establishes *that* an item needs the human and *where* to look; it never establishes *root cause* — that's `/shipyard:do-work`'s job (specifically its `investigate` mode), and doing it here spends the human's wall-clock producing something they didn't ask for. This is unconditional regardless of priority tier: ranking an item **P0** is the strongest "invest here" signal the command produces, and it is exactly the signal that tempts an agent to keep digging past the ceiling to write a satisfying action line — resist it. When the concrete next step can't be written within the ceiling, render the [degraded form](#per-item-investigation-ceiling-1073) (known signal + artifact URL + owning command) instead of investigating further.
- **Don't mutate beyond what the human directs, and don't mutate during [Phase 1](#phase-1--collect-no-mutation-no-work) at all.** The *only* mutation `/my-turn` performs is the [batched decisions record](#phase-2--commit-all-mutation-batched) (post the `<!-- shipyard-resolve-decisions -->` decisions comment + remove the gate label), and only because the human worked through the decisions — it's the reused `/shipyard:resolve-decisions` mutation, the human-directed outcome of the walkthrough, not autonomous action ([#566](https://github.com/mattsears18/shipyard/issues/566), [#635](https://github.com/mattsears18/shipyard/issues/635)). **It fires in Phase 2, never mid-question** ([#1070](https://github.com/mattsears18/shipyard/issues/1070)) — a GitHub round-trip between two of the maintainer's answers is the latency the phase split exists to remove. **Everything else stays hands-off:** no `gh pr edit`, no `gh issue close`, no labels changed on other issues, no comments posted on the user's behalf outside the decisions record. The one other human-directed mutation is the [production-mutation offer](#phase-2--commit-all-mutation-batched) ([#1563](https://github.com/mattsears18/shipyard/issues/1563)). It runs a recorded decision's exact CLI commands only when the maintainer picks "Run them now", with each command approved at the harness permission prompt, then comments on and closes that one issue.
- **Don't dispatch mutating agents or share `/do-work`'s worker/execution machinery.** `/my-turn` is human-facing and human-paced — the autonomous loop (code workers, the operator phase, parallel worktrees) is `/shipyard:do-work` / `/do-work`'s job. `/my-turn` never spawns a code worker, never opens a PR, never drives the browser, and never dispatches an agent that mutates anything. Running a maintainer-approved production command inline, in the [production-mutation offer](#phase-2--commit-all-mutation-batched), is a foreground call in this same session, not a dispatched agent. If the user wants Claude to *work* the items, they run `/shipyard:do-work` (autonomous code loop **+** browser operation, operator-inclusive by default) separately.
  - **Read-only research agents are permitted, and only in [Phase 1](#phase-1--collect-no-mutation-no-work)'s bulk context pass** ([#1070](https://github.com/mattsears18/shipyard/issues/1070)). Once the mutations move to Phase 2, gathering issue bodies and codebase grounding is what's left of the wait — fanning that out in parallel is the difference between a snappy question run and a slow one. Such an agent may **read only**: no file writes, no `gh` mutation, no browser, no PR. The rule this narrows is "no *autonomous* work," not "no concurrency" — a read-only reader produces context for a human to decide on, which is precisely what `/my-turn` is for.
- **Don't chain into `/do-work`.** [Phase 2](#phase-2--commit-all-mutation-batched) ends by naming which issues are now dispatch-ready and stopping. Kicking off implementation because decisions just got unblocked would make `/my-turn` autonomous and start burning tokens the maintainer didn't ask for; running `/shipyard:do-work` is their call and their keystroke.
- **Don't surface items `/do-work` can complete — and is actually configured to complete.** Code work is always filtered out by the [Human-only queue filter](#human-only-queue-filter). Browser-completable `agent-console` operator actions are filtered out **only when `my_turn.assume_operator_enabled: true`** (the default, resolved once at [Setup step 7](#7-resolve-the-operator-phase-assumption-for-the-agent-console-filter-1093)) — `/my-turn` assumes `/do-work`'s operator phase is draining them, so at most a single [operator pointer line](#operator-pointer-line) notes that operator-completable items exist and which command drains them, never walked individually. **When `my_turn.assume_operator_enabled: false`** ([#1093](https://github.com/mattsears18/shipyard/issues/1093)) — the maintainer has declared `/do-work` runs in this repo skip the operator phase — walk these items directly instead; don't keep pointing at a command configured not to do the work. Similarly, a `@me`-authored DIRTY PR is filtered out of the primary DIRTY-PR signal **only when `ci.skip_drain_rebase: false`** (the default, resolved once at [Setup step 8](#8-resolve-ciskip_drain_rebase-for-the-dirty-pr-author-scoping-gate-1075)) — drain-phase `fix-rebase` is presumed to be adopting it — but it still surfaces as a low-priority fallback rather than being dropped outright, and **when `ci.skip_drain_rebase: true`** it's unscoped entirely ([#1075](https://github.com/mattsears18/shipyard/issues/1075)); an outside-contributor's DIRTY PR is never filtered by this gate.
- **Don't scan other repos.** Current repo only. Cross-repo digest is a future v2; for v1 the user can re-run with `--repo` in different cwds.
- **Don't write a report file.** v1 is terminal-only. If the user wants persistence, they can pipe via shell redirection from outside the slash-command UI; that's their concern, not the command's. Add `--output <path>` later if useful.
- **Don't surface PRs / issues authored by bots** (Dependabot, Renovate, etc.) unless they specifically request review from `$ME` — those auto-update PRs are noise in a "human action needed" list and have their own automation handling them.
- **Don't present an open release-please / version-bump PR as a top-priority "next action."** A manual gate is discretionary, not blocking — the commits it releases are already on the default branch and nothing downstream cascades from it. Surface it as housekeeping (bottom of P2 — see [Ranking → Release-please / version-bump PRs](#release-please--version-bump-prs-discretionary)); only let it rank up or lead the walkthrough when something downstream explicitly blocks on the release shipping. When it's the only human-blocked item, prefer the "release is ready whenever you want" phrasing over a false-urgency directive.
- **Don't include items where the next action is obviously Claude's, not the user's.** A PR with failing checks but NOT carrying `blocked:ci` is still inside `/shipyard:do-work`'s fix-loop — surfacing it would tell the user to step on the orchestrator's work. The `blocked:ci` label is the explicit "Claude gave up, human must" signal; absence of it means leave it alone.
- **Don't deep-dive on team membership for review requests.** v1 matches `$ME` directly against `reviewRequests`; team-via-membership lookups would add an extra `gh api` round-trip per PR and are out of scope. Users on teams will still see direct review requests in v1; team-level requests roll up via the GitHub UI's notification stream, which the user has anyway.
- **Don't repeat work `/shipyard:do-work`'s upfront summary already does.** `/do-work`'s step 2 prints a buckets table with workable / skipped / blocked counts. That's a *backlog snapshot*; `/my-turn` is a *human-actions list*. They share inputs but have different shapes — don't try to merge them.
- **Don't add framing back to the output.** No tier headers (`P0 — blocking other work`), no opening banner (`HUMAN ACTIONS NEEDED — …`), no closing prose paragraph (`Main CI on main is green, two PRs are still draining…`), no per-item title restatements, no per-item signal-label lines, no per-item age lines (except the stale suffix described in [Rendering rules](#rendering-rules)). The user asked for "what do I need to do" in imperative voice — every line of framing pushes the verb further down the screen. When in doubt: would removing this line lose any *action* information? If no, remove it.
- **Don't sort the within-tier order by age alone.** The within-tier secondary sort is **leverage score first, age only as the tie-breaker** (see [Secondary sort](#secondary-sort--leverage-score-then-age-issue-565)). A flat `createdAt`-ascending sort makes the *stalest* item lead the walkthrough — which on a `needs-human-review`-dominated P0 tier regularly surfaces an auto-undecomposable epic (the least actionable item) first, contradicting the command's "highest-leverage" promise (issue [#565](https://github.com/mattsears18/shipyard/issues/565)). Oldest-first is the tie-breaker, not the ranking signal.
- **Don't dump the full ranked list by default, and don't stop after one item.** The default render is the phased run ([collect](#phase-1--collect-no-mutation-no-work) → [commit](#phase-2--commit-all-mutation-batched) → [walk](#phase-3--walk-the-rest)), which continues until both queues are empty. Don't print a static 20-line backlog (that reintroduces the prioritization burden the command exists to remove; that's opt-in via `--all` / `--limit N > 1`), and **don't exit after surfacing one item** — the pre-[#635](https://github.com/mattsears18/shipyard/issues/635) "single-action" behavior forced a re-invoke per action and defeated the point of ranking the whole queue. The only exception is the [empty state](#empty-state).
- **Don't interleave collecting with acting.** This is the [#1070](https://github.com/mattsears18/shipyard/issues/1070) regression to guard against, and it reappears in subtle forms: recording issue A's decisions before asking issue B's first question, re-reading the codebase between two questions to ground the next recommendation, or slipping a PR-review item into the middle of the question run because it ranked higher. All three put the maintainer back to waiting mid-thought. **Every question first, then every mutation, then the action items** — if a step would make the human wait on Claude between two answers, it belongs in Phase 1's bulk context pass or in Phase 2, not between the questions.
- **Don't ask a dependent decision inside a batched `AskUserQuestion` call.** Grouping is for **mutually independent** decisions only. When an answer constrains a later question's options, that later question must be asked alone and after — [`resolve-decisions`' carry-forward](./resolve-decisions.md#the-per-decision-walkthrough) is the whole reason the walkthrough is sequential, and batching a dependent pair silently discards it to save one round-trip.
- **Don't discard journaled answers.** Answers live in `~/.shipyard/my-turn-<repo-slug>.json` from the moment they're given. Never abandon the run without firing [Phase 2](#phase-2--commit-all-mutation-batched) on what was collected — not on a halt, not on an error, not on a re-invocation. Clear the journal only after the records land; if a record call fails, keep it and say which issues didn't commit. Re-running is safe (the `<!-- shipyard-resolve-decisions -->` / `<!-- shipyard-disposition-call -->` sentinels are idempotent); losing a maintainer's decisions is not.
- **Don't invent a disposition call** ([#1074](https://github.com/mattsears18/shipyard/issues/1074)). The class fires only when [Disposition-call detection](#disposition-call-detection-1074)'s actual signal is present — a completion-asserting last comment, or a PR whose linked issue closed out from under it. A `needs-human-review` issue with a quiet thread and no such signal is an ordinary human-review item, not a disposition call; don't manufacture a close/keep/split question for it just to give Phase 1 more to batch.
- **In `--chrome-prompt` mode, don't emit anything outside the dividers except the "can't be automated" section.** The entire output must be highlightable as one clean copy region. Any preamble, status line, `→ Now:` directive, walkthrough prompt, or trailing prose outside the defined layout breaks the copy flow and defeats the mode's purpose. The "can't be automated" section is intentionally after the closing divider — it is for the human's eyes, not for the extension to execute, and it must not be inside the prompt body.
- **In `--chrome-prompt` mode, don't run the inline decision walkthrough or any interactive prompt.** The interactive [decision-gated walkthrough](#decision-gated-walkthrough) is a terminal-interactive affordance for the human at the terminal — it has no place in a one-shot prompt destined for the browser extension. Chrome-prompt mode is exclusively for extension consumption; terminal-only and interactive affordances are suppressed.
- **Don't treat `/do-work`'s session state as authoritative, and don't let it add items or urgency** ([#1080](https://github.com/mattsears18/shipyard/issues/1080)). [Setup step 9](#9-resolve-do-works-live-session-state-optional-enrichment-1080)'s optional session-file read is a **suppression and enrichment** signal only — it can drop a candidate (a live in-flight issue/PR) or annotate the output (the default-branch CI line), but it must never manufacture a new queue item, bump an item's tier or leverage score, or otherwise change what would have been ranked without it. And it's always optional: a missing, unreadable, malformed, wrong-repo, or dead (PID not alive) session file must silently produce the *exact same* queue `/my-turn` would render on a machine that has never run `/do-work` — no error, no warning, no degraded-output banner, no change in output shape.
- **Don't call any MCP browser tools or attempt to drive the browser.** `/my-turn` never drives the browser — not in `--chrome-prompt` mode (which emits a text prompt and stops; browser execution is the Claude for Chrome extension's job when the user pastes the prompt) and not in walkthrough mode (it surfaces items for the human; it does not act). Driving the browser directly is `/do-work`'s scope, not this command's.
