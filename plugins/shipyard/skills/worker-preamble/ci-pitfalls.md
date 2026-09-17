# Worker-preamble fragment — CI / push pitfalls (vacuous verification, git-diff-rewriting proxy, heartbeat, locale parity, fixture branch pin, push-protection)

On-demand fragment of the `shipyard:worker-preamble` skill (see [`SKILL.md`](./SKILL.md)). Load this when a worker mode **verifies a CI result**, builds or debugs a pipeline that parses `git diff` output, runs long-running commands (CI babysitting, full local test suites), adds user-facing strings, authors git-using shell test fixtures, or adds secret-shaped test fixtures. The per-mode specs under `agents/issue-worker/` point here by name (`worker-preamble § "An absence-assertion that observed nothing is not a pass"`, `§ "A `git diff`-rewriting shell proxy may be active"`, `§ "A truncated read cannot support a negative claim"`, `§ "Heartbeat emission around long-running commands"`, `§ "Mirror new string constants into locale / parity files"`, `§ "Pin the default branch in git-using test fixtures"`, `§ "GitHub push-protection blocking a synthetic test-fixture secret"`).

## An absence-assertion that observed nothing is not a pass

**Never assert "nothing failed" without first asserting that you observed something.** A check whose result cannot distinguish *"nothing bad found"* from *"nothing looked at"* is not a check — it is a coin that always lands green. This failure mode reports success in the **dangerous direction**: it converts "I could not verify" into "verified green", and every downstream claim that trusted it (the `checks: green` suffix in a return string, an orchestrator's trust-but-verify probe, a post-merge "main is healthy" conclusion) inherits a verdict that was never actually taken.

The canonical instance (issue [#717](https://github.com/mattsears18/shipyard/issues/717)): **`gh run list --commit <sha>` matches only on a FULL 40-char SHA.** An abbreviated SHA silently matches **zero** runs — gh exits 0 and prints an empty list. So:

```bash
# BAD — vacuously "green". A short SHA matches 0 runs, so `failures` is 0, so the
# check passes while having observed nothing at all.
sha=$(git rev-parse --short HEAD)
failures=$(gh run list --commit "$sha" --json conclusion \
             --jq '[.[] | select(.conclusion != "success")] | length')
[ "$failures" -eq 0 ] && echo "main is green"   # <-- a lie on an empty set
```

**Use the shared helper — don't re-derive the guard per call-site.**

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
# GOOD — one executable answer to "is CI green for <target>?", with the
# observed-something precondition built in.
"$CLAUDE_PLUGIN_ROOT/scripts/assert-ci-green.sh" <owner/repo> --commit HEAD
case $? in
  0) : ;;  # green    — >=1 run observed, every workflow's latest completed run
           #            passed, AND that run actually executed its steps
  1) : ;;  # red      — a workflow's latest *executed* run failed
  3) : ;;  # pending  — runs observed, no completed verdict yet
  2) : ;;  # unknown  — NOT VERIFIED (0 runs matched / ref unresolvable / gh failed)
  4) : ;;  # unproven — NOT VERIFIED: a run reported success but a path filter
           #            skipped every real step, and no run in the lookback
           #            window executed. Never treat as green. (#1495)
esac
```

[`scripts/assert-ci-green.sh`](../../scripts/assert-ci-green.sh) resolves the ref to a full SHA itself (so a caller passing `HEAD` or a short hash cannot reintroduce the trap), refuses to answer `green` on an empty result set, and aggregates at per-workflow / latest-run granularity. It also accepts `--branch <name>` for a default-branch health read, `--classify '<json>'` for a run-list payload you already hold, and `--classify-steps '<jobs-json>'` for a `gh run view --json jobs` payload.

**The second vacuous shape — a run that passed without running anything ([#1495](https://github.com/mattsears18/shipyard/issues/1495)).** The trap above is "0 runs observed". One layer down is "1 run observed, and it did nothing": on a repo with `paths` / `paths-ignore` filters (or a `detect-paths` fan-out job), a docs-only commit produces a required job whose `conclusion` is `success` while **every substantive step is `skipped`** — checkout included. Zero tests ran. The run's own conclusion field has no way to express that, so `jobs[].conclusion` is as unreliable here as `length == 0` was there, and the last run that *did* execute the suite may still be failing — a stale red that silently poisons every branch cut afterwards. `assert-ci-green.sh` walks `jobs[].steps[]` for the deciding run, and on a vacuous one walks back to the most recent run that really executed and reports **that** verdict (`--max-lookback`, default 5; `--no-step-check` opts out). Don't substitute a `jobs[].conclusion` read for it.

**The four rules, if you must hand-roll a verification anyway:**

1. **Full SHA, always.** `git rev-parse HEAD` — never `--short`, never a hash copied from a log line. `gh run list --commit` does not accept abbreviated SHAs and does not warn.
2. **`total == 0` is `unknown`, never `green`.** Assert the set is non-empty *before* asserting it is clean. Emit `could not verify — 0 runs matched <sha>` and treat it as not-verified.
3. **A job that skipped its real steps is `unproven`, never `green`.** Assert the run actually *did* something before reading its `success` as evidence — the step-level analogue of rule 2.
4. **`unknown` and `unproven` are their own outcomes.** Don't fold either into green ("nothing red, ship it") or into red ("assume the worst"). The caller usually wants to widen the window, walk back, retry, or bail — what it must never do is proceed as if it has a verdict.

**The pattern generalizes past `gh` — watch for any tool whose degenerate output reads as a pass.** Two more from the same session that filed #717:

- GNU grep prints `Binary file <f> matches` (one line, no matches) instead of the matched lines when the file contains a NUL byte — a scanner extracting headings silently got nothing, and "no bad headings found" read as a pass. It passed on macOS/BSD grep and failed only on CI.
- `grep -P` is **unsupported on macOS** (BSD grep). The error was swallowed by a `2>/dev/null`, the check false-negatived, and the NUL byte it was looking for went undetected — caught only because `file` reported `data` instead of `UTF-8 text`.

In both, an empty/degenerate tool result was consumed as evidence of absence. When you write a check, ask: *what does this print when it fails to look at anything?* If the answer is "the same thing it prints when everything is fine," the check is broken — add the "I observed N things" precondition, and give any new guard a **negative control** (a test that proves the guard's removal changes the outcome; a test that passes with and without the fix is itself an instance of this bug).

## A `git diff`-rewriting shell proxy may be active ([#1333](https://github.com/mattsears18/shipyard/issues/1333))

The same vacuous-pass shape, from a different source: some environments run a token-optimizing shell hook (e.g. `rtk`, "Rust Token Killer") that transparently rewrites certain commands before they run. When active, a **bare or singly-piped `git diff [...]` invocation issued as the entirety of one Bash tool call** — nothing else in the same call — can come back as a non-standard, stat-like summary instead of real diff output: no `---`/`+++` headers, no `@@` hunks, and critically no leading `diff --git a/<path> b/<path>` line that every genuine `git diff` invocation emits first, regardless of content shape. A pipeline that parses that output for `+`-prefixed added lines (or counts `--name-only` lines) silently sees less than it should — an empty parse that reads as "nothing changed" and can invert a correctness guard's whole purpose.

**Recognize it** by the missing `diff --git` header, or by output shaped like a file-stat summary (`<path> | N +`, `N file(s) changed`) where a unified diff was expected. **Work around it**: `rtk proxy git diff [...]` returns the real, unrewritten output for a one-off manual check; for code that parses `git diff` programmatically, prefer invoking it from inside a script (`bash <script>`) rather than a bare/piped top-level shell command — a script's own internal `git diff` calls were not observed to be rewritten the same way. Either way, treat a diff that's supposed to be non-empty but doesn't start with `diff --git` as untrustworthy input, not as "no changes" — bail loud rather than trust an empty parse, applying the same "what does this print when it fails to look at anything?" test from above. See [`scripts/verify-added-lines-survived.sh`](../../scripts/verify-added-lines-survived.sh) and `agents/issue-worker/fix-rebase.md` §4.6 item 5 for the fixed pattern. This is user-global tooling outside any target repo — never edit its configuration, never try to disable it; the fix is always on the parsing side.

## A truncated read cannot support a negative claim

A close cousin of the section above, but distinct: that section is about a query that matched **zero items** (an empty result set silently reading as "clean"). This one is about a query that matched **plenty**, but the tool handed back only part of it with no signal that anything was cut — and the missing part happened to hold the thing you were looking for. **A partial capture that doesn't contain X is not evidence that X isn't there; it's only evidence that X isn't in the part you happened to see.** The two failure modes rhyme (both convert "I didn't look far enough" into "verified absent") but the fix is different: the absence-assertion guard is about checking the set is non-empty *before* trusting a clean result; this one is about checking the capture is *complete* before trusting a negative grep against it.

**The canonical instance** (issue [#988](https://github.com/mattsears18/shipyard/issues/988)): while triaging a CI failure, a session ran `gh run view <run-id> --log` to fetch a run's full log, grepped the 25,857-line capture for every failure marker it could think of (`FAILURE:`, `error:`, `##[error]`, `Killed`, `No space`, `OutOfMemory`, `timed out`), got **zero** hits, and concluded the job died silently — "the signature of the runner being killed" — and filed a GitHub issue on that premise. The conclusion was wrong: `gh run view --log` had silently truncated its output, and the failing job's tail — where an ordinary, fully-legible `fatal error: ... No space left on device` lived — fell past the cut. `gh` gave no truncation warning, no non-zero exit, nothing distinguishing "complete" from "cut off." A subsequently-dispatched worker found the real error immediately by fetching the *specific failing job's* log instead of the whole run's — the drill-to-job pattern this fragment already documents above (`worker-preamble § "An absence-assertion that observed nothing is not a pass"` neighbors this section; the job-level fetch pattern itself lives in each diagnostic mode's fix-loop, e.g. `fix-checks-only.md`'s Step A). The filed issue's acceptance criteria had to be corrected afterward because they'd been written against a diagnosis that never happened.

**This is specifically a hazard for absence-based claims** — "no error in the log," "nothing failed," "the job died silently," "this file doesn't mention X" — because a truncated fetch makes *absence of evidence* indistinguishable from *evidence of absence*, and it fails silently by construction: there's no signal in the moment that you're reasoning over a partial artifact. It's also self-reinforcing in a bad way — long artifacts are exactly the ones attached to hard, slow-to-reproduce failures, so truncation bites hardest where a wrong diagnosis is most expensive.

**The rule generalizes past `gh run view`.** Any read with a size/length cap you don't control can trigger it: a paginated API response, a `grep` over a capped shell capture, or — reflexively, inside this very session — the `Read` tool's own per-call token cap. `Read` announces its own truncation cleanly (a `<system-reminder>` naming the exact line range shown, the total, and an explicit *"Do NOT answer from this page alone if the answer may be further in the file"*), which is the well-behaved case: heed that signal and page to the next offset before asserting anything the unread portion could contradict. `gh run view --log` is the badly-behaved case — it truncates with **no signal at all** — which is exactly why it's the dangerous one and why the discipline below can't rely on the tool to tell you.

1. **Prefer the narrowest fetch that scopes to what you need.** Drill to the specific job's log rather than the whole run's (`gh api repos/<owner>/<repo>/actions/jobs/<job-id>/logs`, per issue [#984](https://github.com/mattsears18/shipyard/issues/984)) — a single job's output is far less likely to hit a truncation ceiling than an entire multi-job run's. For a file `Read`, an `offset`/`limit` aimed at the section you already suspect holds the answer beats a blind full read that gets cut off before reaching it.
2. **Before drawing a negative conclusion from a capped read, check for a completion signal.** When the tool tells you it truncated (a `Read` system-reminder, an API's `truncated: true` / pagination cursor), that's your answer — don't override it by reasoning "it's probably fine." When the tool is silent (`gh run view --log` gives you nothing to check programmatically), sanity-check the capture yourself: does the tail look like where the artifact should actually end — a job-completion marker, the shell prompt returning, a closing brace? If the capture ends mid-step, mid-line, or just stops, treat it as truncated regardless of what the exit code says.
3. **If you can't fetch to completion, either page or say so.** Page to the next chunk (`Read`'s `offset`, a paginated API's cursor, or — for CI logs — the job-level fetch from (1)) before asserting a negative. If paging genuinely isn't practical, state the limit explicitly in whatever you write down — "I read the first N lines/tokens and did not find X there; I have not verified the remainder" — rather than writing an unqualified "X is not present." The qualified version is honest and still useful; the unqualified version is the thing that ends up wrong in a filed issue's acceptance criteria.
4. **The check is the same regardless of what's being searched.** Before treating a "not found" result as a finding, ask: *could this tool have silently truncated what I just searched?* If yes, the honest next step is "page to completion" or "state the limit" — never "conclude absence and move on."

## Heartbeat emission around long-running commands

The Claude Code harness runs a **stream watchdog** over each worker dispatch: if the worker emits no stream output (stdout/stderr) for ~600s, the harness concludes the agent has stalled, kills it, and the orchestrator gets back `status: failed / summary: Agent stalled: no progress for 600s (stream watchdog did not recover)`. The killed worker leaves an agent worktree behind for the next session's startup sweep to reap, and the failure path emits no `usage` block, so the burned tokens aren't attributed to any per-PR bucket (issue [#372](https://github.com/mattsears18/shipyard/issues/372) — observed in a `mattsears18/lightwork` drain-phase `fix-checks-worker` dispatch killed mid-`Web E2E Tests` shard).

The watchdog is correct for foregrounded LLM work — 600s of genuine silence from the model *is* a stall. It misfires on worker modes (especially **fix-checks-only**, which is the canonical victim because its whole job is babysitting CI) that shell out to commands which legitimately run for 5–15 minutes with **no intervening stream output**:

- `npm ci` / `npm install` against a cold cache — **especially on a large monorepo**, where a single app's install alone can run several minutes (issue [#757](https://github.com/mattsears18/shipyard/issues/757)),
- `git commit` when the repo wires a slow pre-commit hook (typecheck + lint + prettier + a secret scan is a common combination that can itself run minutes with no output until the hook finishes — [#757](https://github.com/mattsears18/shipyard/issues/757)),
- `gh run view <run-id> --log-failed > /tmp/log` (the redirect swallows all output — the watchdog sees zero stream bytes for the whole download),
- a test suite run that buffers output (`npm run test:e2e:web`, `npx lhci autorun`, `pytest -q`, an emulator-backed `npm run test:unit`),
- `gh pr checks <M> --watch --interval 30` parked on a long E2E shard.

**A distinct, earlier trap on the same class of command: the Bash tool's own default timeout, not just the 600s harness watchdog.** The `Bash` tool itself defaults to a **120000ms (2-minute)** timeout per call, independent of and shorter than the 600s stream watchdog — a plain `npm ci` or a hook-wrapped `git commit` on a large repo can hit *this* wall well before the watchdog would ever engage. The fix is mechanical: **pass an explicit `timeout` parameter** (up to the tool's own cap, `600000` — 10 minutes) on the Bash call for any command from the bulleted list above, rather than accepting the 2-minute default and then reaching for a background/Monitor workaround when it trips:

```
Bash({ command: "npm ci --no-audit --no-fund --prefer-offline", timeout: 600000, description: "Install deps (large repo, bounded to 10 min)" })
```

If the command can plausibly run past even the 10-minute cap, that is what the heartbeat-loop pattern (pattern 3 below) is for — it turns an unboundedly-long, single silent Bash call into a foreground loop of short heartbeat-emitting calls, so neither the tool's own timeout nor the stream watchdog is ever the limiting factor.

The watchdog keys on **stream output**, not on tool-call boundaries — a single Bash tool call that runs silently for 600s trips it even though the agent is making real progress. **The fix is to keep stream output flowing while a long-running command is in flight.** Three patterns, in order of preference:

1. **Don't redirect long-running command output to a file.** The single biggest offender is `... > /tmp/log` on a slow command — the redirect is exactly what starves the watchdog. Let the command stream to the terminal and `tee` if you also need the file:
   ```bash
   # BAD — silent for the whole download, trips the watchdog on a big failed-log fetch.
   gh run view "$run_id" --repo "$repo" --log-failed > /tmp/failed.log
   # GOOD — output streams to stdout (feeds the watchdog) AND lands in the file.
   gh run view "$run_id" --repo "$repo" --log-failed 2>&1 | tee /tmp/failed.log
   ```
2. **Prefer the streaming/progress form of the command.** `npm ci` already prints progress to stderr by default — do NOT silence it with `--silent` / `--quiet` / `> /dev/null` on the path where the watchdog is a risk. `gh pr checks <M> --watch --interval 30` emits a status table on every interval tick, so it self-heartbeats and never needs wrapping (this is why the fix-checks-only fix-loop is watchdog-safe as written). For a test runner that buffers, pass its line-reporter / non-quiet flag (`jest --verbose`, `pytest -v`, `vitest --reporter=verbose`) so each test result is a stream write.
3. **Wrap a genuinely-silent unavoidable command in a heartbeat loop.** When a command *must* run silently for minutes (a compile step with no progress output, a vendor CLI that only prints on completion), background it and emit a heartbeat line on an interval until it exits. The heartbeat lines are the stream output the watchdog needs:
   ```bash
   # Run the silent command in the background, emit a heartbeat every 60s until it finishes.
   slow_silent_command > /tmp/out.log 2>&1 &
   cmd_pid=$!
   while kill -0 "$cmd_pid" 2>/dev/null; do
     beat_ts=$(date -u +%H:%M:%S)
     echo "[heartbeat] $beat_ts — still running slow_silent_command (pid $cmd_pid)"
     sleep 60
   done
   wait "$cmd_pid"   # propagate the real exit status
   ```
   The `[heartbeat]` prefix is a convention, not a parsed sentinel — its only job is to be a stream write the watchdog can see. Keep the interval comfortably under the watchdog window (60s against a ~600s watchdog leaves a 10× margin); don't tighten it to the point of log spam.

**Scope.** This applies to *every* worker mode, but the high-risk surface is fix-checks-only (CI babysitting on E2E/Lighthouse-heavy repos), fix-main-ci / fix-failing-prs-batch (which run the target repo's full test suite locally), **and issue-work's own local-verification chain — `npm ci` on a large monorepo, a slow pre-commit hook, and the local unit-test run mandated by [`issue-work.md` §4.6](../../agents/issue-worker/issue-work.md#46-pre-push-local-unit-test-gate-658) are exactly as watchdog-risky as a CI babysit and get the same treatment ([#757](https://github.com/mattsears18/shipyard/issues/757)).** Do NOT treat issue-work as low-risk here just because most of its steps checkpoint naturally — the install/hook/test steps specifically do not. **Do NOT** add busy-work `echo`s to *fast* commands — the heartbeat pattern is reserved for commands that can plausibly exceed the watchdog window with no natural output. Reflexive heartbeating everywhere is log noise that costs context tokens for no liveness benefit.

**Never open a Monitor / background-wait for a local install, hook, or test run and end your turn — this is the local-step instance of the `shipyard:worker-preamble` § "Return-contract discipline" rule 1 ([#529](https://github.com/mattsears18/shipyard/issues/529), reproduced concretely by [#757](https://github.com/mattsears18/shipyard/issues/757)).** The #529 rule is usually illustrated with a CI test-waiter; #757's repro shows the identical failure mode against `npm ci` and a hook-wrapped `git commit` — a worker opened a `Monitor` mid-`npm ci` and ended its turn to "wait", and separately narrated *"the commit is running through the hook in the background… I'll continue when it resolves"* and stopped without pushing. Both are non-terminal narratives that report the dispatch complete while the actual work — the install, the commit, the push — is still in flight or (worse) already finished with nobody there to push it; in the #757 repro the orchestrator had to finish the commit + push by hand. The fix is the same as for any other long local command: **keep it in a single foreground call** — an explicit bounded `timeout` (above) for a command that streams its own progress, or the heartbeat loop (pattern 3 below) for one that's genuinely silent — and do not end your turn until that call returns.

**If a long local step is interrupted anyway (killed, or you're resuming after a stall), verify actual state before re-running anything.** A killed `npm ci` may have finished installing before the kill; a killed `git commit` may have already landed the commit (git commits synchronously — the hook runs, then the commit either lands or it doesn't, so "the hook seemed to hang" often just means it finished and the process was killed on the way out). Blindly re-running `npm ci` or re-committing on top of an already-successful prior attempt wastes the same budget you're trying to conserve, and a duplicate commit attempt can produce a confusing state. Before retrying, cheaply check what already happened:

```bash
# Was node_modules actually populated by the last (possibly-killed) npm ci?
node_modules_entries=$(ls -A node_modules 2>/dev/null)
[ -d node_modules ] && [ -n "$node_modules_entries" ] && echo "node_modules present — install likely completed, don't re-run npm ci blind"

# Did the commit actually land despite the turn ending mid-hook?
git status --porcelain   # clean + HEAD advanced past the base branch ⇒ commit landed
git log -1 --oneline

# Was it already pushed?
git log "origin/${LOCAL_BRANCH:-HEAD}..HEAD" --oneline 2>/dev/null   # empty ⇒ already pushed (or nothing to push)
```

If the state shows the step already succeeded, move straight to the next step (push, or open the PR) rather than repeating work that's already done.

> **Not implementable from this repo: a tunable watchdog threshold.** Issue [#372](https://github.com/mattsears18/shipyard/issues/372) also floated a per-mode `stall_seconds` config knob (e.g. `workers.fix_checks_only.stall_seconds = 1200`). The 600s watchdog lives in the Claude Code **harness**, not in shipyard — shipyard can't read, raise, or disable it from a config file, so a config key would be an unenforceable no-op. The heartbeat contract above is the in-repo lever that actually moves the failure mode: it keeps the existing watchdog from firing rather than trying to change a threshold shipyard doesn't own.

## A foreground call the harness auto-backgrounds past 600s ([#829](https://github.com/mattsears18/shipyard/issues/829))

The `Bash` tool caps a **foreground** call at 600s. Exceeding it does not error — the harness silently **moves the command to the background** and hands control back with `Command did not complete within its 600s timeout and was moved to the background … Output is being written to: <file>`. This is precisely the mechanism `SKILL.md`'s Return-contract-discipline rule 1 (issue [#529](https://github.com/mattsears18/shipyard/issues/529)) mandates you use for a long wait (a test suite, an emulator-backed run) — so hitting the cap lands you in the *state* #529 forbids (a live background process, no terminal result in hand) through no choice of your own. This is the **worker-side** half of the #829/#838 pair: #829 is the upstream cause documented here; [#838](https://github.com/mattsears18/shipyard/issues/838)/[#833](https://github.com/mattsears18/shipyard/issues/833) is the downstream orchestrator-side contract for a worker that stops anyway without a terminal return. This section is what keeps you from stopping in the first place.

**Name it correctly: this is sanctioned harness behavior, not a #529 breach.** You did not arm a background waiter and return — the harness backgrounded a foreground call you were correctly, compliantly blocking on. A worker that reads its own situation as a rule violation improvises badly under that misreading (a bare `sleep 45; tail …` retry, or worse, a narrative return); the correct response below is prescribed, not invented.

**Re-block your turn on this exact pattern** — a second foreground call that polls the backgrounded job's own output file until it has content, then reads it:

```bash
until [ -s "<output-file>" ]; do sleep 15; done; cat "<output-file>"
```

This is compliant for three reasons: it is itself a **foreground** call, so it blocks your turn exactly like the original command would have; it self-heartbeats via the `until`/`sleep` loop (so the stream watchdog above never fires); and it cannot outlive your return, so it satisfies #529 and #707 alike. It is also the "wait for a condition, not a fixed sleep" shape the harness's own guard steers toward when it blocks a naive `sleep N; tail …` retry — that guard is pointing you at this pattern, not at `Monitor` or `run_in_background: true`, even though its error text can read that way. **This exact loop can itself be refused by Auto Mode's compound-command classifier in a worktree-isolated session, even though it's read-only — if that happens, don't retry the same shape with cosmetic tweaks; load [Claude Code's command-shape check](https://code.claude.com/docs/en/worktrees#how-claude-code-enforces-isolation) for the reproduced refusal shapes and the `Monitor`-based fallback that actually gets accepted ([#981](https://github.com/mattsears18/shipyard/issues/981)).**

**Anti-patterns — do not do these instead:**
- Do NOT return a narrative status ("tests are still running, I'll check back") — that's the #529 violation this pattern exists to avoid.
- Do NOT re-run the command from scratch — it's still running in the background; restarting duplicates work in flight and risks duplicate side effects.
- Do NOT reach for `Monitor` merely because the harness's own guard text suggests it — that's the [#753](https://github.com/mattsears18/shipyard/issues/753) anti-pattern (a per-worker poll loop duplicating the orchestrator's own CI watch), not what the guard is actually steering you toward.

**Optional, not a substitute for the above:** if the target repo's test runner supports narrower invocations (a single spec file, a tagged subset), pre-splitting a *known*-long suite can avoid the cap. But host contention — self-hosted runners sharing the same box — makes runtime unpredictable session to session (the identical command can run in ~60s once and exceed 600s minutes later with no code change), so the re-block pattern above is the reliable answer; don't rely on runtime estimation to dodge the cap.

## Mirror new string constants into locale / parity files

A recurring, self-inflicted CI red ([#418](https://github.com/mattsears18/shipyard/issues/418)): you add a user-facing string to a centralized strings module (e.g. `lib/strings.ts`, `src/i18n/keys.ts`, a `messages.ts` constant bag), open the PR, and CI goes red on a **parity test** that asserts every string key has a matching entry in every locale file. The repo's local pre-push hook didn't catch it (the parity test isn't always wired into the pre-push suite), so the break only surfaces in CI — costing a fix-checks cycle to add the one missing key. Repro: a single `mattsears18/lightwork` session (`do-work-20260531T113301Z-98771`) tripped this 3× across PRs #1443 / #1444 / #1447 — each added a `Strings.*` leaf in `lib/strings.ts` but forgot the matching key in `locales/en.json`, reddening the repo's `i18n.test.ts` parity test.

**The class is general** even though the trigger is repo-specific: many repos lock down a "centralized strings ↔ locale-file parity" invariant with a test. The shapes vary —

- i18n locale parity: `locales/en.json`, `locales/*.json`, `lang/*.yml`, a `messages/` dir — the test asserts the key set matches across every locale.
- Enum / constant ↔ lookup-table parity: a string-constant enum whose every member must have a row in a display-name map, a color map, an icon map.
- Snapshot / fixture parity: a generated `*.snap` or golden fixture that enumerates the full key set.

**The check.** Before opening the PR, if your diff **adds a key to a centralized string / constant module**, grep for a parity or locale test (`i18n.test.*`, `*parity*`, `locales/`, `messages/`, `lang/`, a `*.snap` enumerating keys) and **mirror the new key into every file the test requires** — the locale JSON, the display-name map, the fixture — in the same PR. The cheapest signal is to run the repo's full test suite locally (not just the pre-push subset) once after adding a string; if a parity test reds, add the missing mirror entry before you push. When the repo ships only a stub / placeholder value convention for non-default locales (common — translators fill them in later), mirror the key with the default-locale value or the repo's documented placeholder, not a blank.

**When NOT to worry about this.** Diffs that don't touch a centralized string / constant module (pure logic, config, docs) can't trip a key-parity test — skip the check. And if the repo has no parity test (the grep comes up empty), there's nothing to mirror; don't invent locale files the repo doesn't have.

## Pin the default branch in git-using test fixtures

A pre-push silent-pass with an *invisible host dependency* ([#475](https://github.com/mattsears18/shipyard/issues/475)): you add or edit a shell test fixture that builds a throwaway repo with a bare `git init` and later refers to the default branch by name — `git checkout main`, `git rev-parse main`, `git branch -f main`, an assertion against a `refs/heads/main` ref. Your pre-push sweep runs the suite locally and it passes — because your dev machine's `init.defaultBranch` is `main` (the macOS / recent-git default). CI's runner is GitHub-hosted Ubuntu, whose `init.defaultBranch` is **`master`**, so the fresh repo's initial branch is `master`, the `main` pathspec doesn't resolve, and the test reds with `error: pathspec 'main' did not match any file(s) known to git` (or an empty-ref assertion failure). The break only surfaces post-push, and on a repo that admin-direct-merges **ungated** (no required status checks — the `merged-direct-ungated` case) there is no PR gate to catch it before it reddens the default branch.

Repro ([#466](https://github.com/mattsears18/shipyard/issues/466) → recovery [#473](https://github.com/mattsears18/shipyard/issues/473)): a worker added `plugins/shipyard/scripts/tests/fix-rebase-version-coordination.test.sh`, which `git init -q`'d a fixture repo then `git checkout main`'d it. The worker's macOS pre-push sweep passed; PR #472 admin-direct-merged ungated; CI's Ubuntu runner failed the `git checkout main` with `pathspec 'main' did not match`, cascading three assertion failures and reddening both the `Tests` and `Shell scripts (lint + tests)` workflows on `main`. Recovery PR #473 pinned the fixture with `git init -q -b main`.

**The authoring rule.** When your diff **adds or edits a `*.test.sh` (or any test fixture) that runs `git init` and then references the default branch by name**, pin the fixture's initial branch so it's deterministic regardless of the host's `init.defaultBranch`:

```bash
# Pin the default branch — CI's init.defaultBranch may be 'master', not 'main'.
git init -q -b main
# (equivalent, for older git that lacks `git init -b`:)
git -c init.defaultBranch=main init -q
```

A bare `git init` whose fixture never names the default branch (it only uses `git branch` / `git for-each-ref` generically, or commits onto whatever the initial branch is without caring what it's called) is **not** at risk — don't churn those. The risk is specifically *bare `git init` + a hard-coded branch name later in the same fixture*.

**The verification recipe (catches the whole class deterministically).** Pinning is the fix; this is the cheap way to *prove* you got it — and to catch any fixture you edited that still has a latent host dependency. Re-run the new/changed suite once under a forced non-`main` default, exactly how recovery PR #473 reproduced the failure. An ephemeral `GIT_CONFIG_GLOBAL` pointed at a config that sets `init.defaultBranch=master` reproduces CI's Ubuntu environment without touching your real git config:

```bash
# Reproduce CI's `init.defaultBranch=master` locally and re-run the suite.
# If it passes here, it passes on CI's Ubuntu runner too.
tmp_gitconfig="$(mktemp)"
printf '[init]\n\tdefaultBranch = master\n' > "$tmp_gitconfig"
GIT_CONFIG_GLOBAL="$tmp_gitconfig" bash plugins/shipyard/scripts/tests/<changed-suite>.test.sh
rm -f "$tmp_gitconfig"
```

A suite that passes under `init.defaultBranch=master` has no remaining host dependency on the default-branch name; one that fails has exactly the #475 gap and needs a `git init -b main` pin (or its assertions de-hardcoded) before you push.

**When NOT to worry about this.** Diffs that don't add or edit a git-using `*.test.sh` fixture (pure docs, config, non-shell tests, a fixture that doesn't shell out to `git init`) can't trip this — skip the check. And a target repo that isn't shell-test-driven, or whose CI runner shares your host's `init.defaultBranch`, won't surface the divergence; the recipe is cheap insurance specifically when you're authoring a new git-using shell fixture against a self-hosting repo like `mattsears18/shipyard`.

## GitHub push-protection blocking a synthetic test-fixture secret

A push-time analogue to the classifier-denial boundary ([#440](https://github.com/mattsears18/shipyard/issues/440)): you add a NEW test fixture containing a realistic-shaped secret — `xoxb-`/`xoxp-` Slack tokens, `sk_live_`/`sk_test_` Stripe keys, `ghp_`/`github_pat_` GitHub tokens, `AKIA…` AWS keys — because the fixture's whole job is to exercise a scrubber, a secret-scanning rule, or a redaction regex you're adding. The fixture value is **synthetic** (made up, matches the shape but unlocks nothing), but it's realistic enough that **GitHub's server-side push-protection** rejects your `git push` with a `GH013: Repository rule violations` / "Push cannot contain secrets" error naming the detector that matched (Slack API Token, Stripe API Key, etc.).

**The trap: this is NOT the same scanner as `.gitleaks.toml`.** This repo wires two distinct committed-content scanners, and allowlisting a fixture in one does NOT exempt it from the other:

- **`.gitleaks.toml`** (driven by `.github/workflows/secret-scan.yml`) is the in-repo gitleaks config. Its `[allowlist].paths` already exempts the scrubber test fixtures (`plugins/shipyard/scripts/tests/report-plugin-error.test.sh`, etc.) — so the CI gitleaks job stays green on those files.
- **GitHub native push-protection** (Settings → Code security → "Push protection") is a *separate, server-side* detector that runs on every push regardless of `.gitleaks.toml`. It has its own ruleset and its own (org/repo-level) bypass surface. A path allowlisted in `.gitleaks.toml` is still subject to push-protection. This is exactly the surprise the #402 and #408 scrubber-fixture workers hit: the fixtures were already gitleaks-allowlisted, yet the push still bounced.

**What to do when push-protection blocks a synthetic-fixture push, in order:**

1. **NEVER click the server-side unblock URL.** The error output includes an "allow secret" / "unblock" link that registers a push-protection bypass for that blob. Following it is a repo-security-posture decision (it tells GitHub "this secret is intentional, let it through forever"), which is a **maintainer** decision, not a worker decision — and it normalizes a bypass path that a future real-secret leak could ride. Treat the unblock URL exactly like the classifier-denial "argue past it" surface: off-limits.
2. **Rewrite the fixture to an obviously-synthetic value that still matches the pattern under test.** The detector keys on *shape*; your test keys on *the scrubber matching the shape*. Both are satisfied by a value that's clearly fake to a human reader — embed an `EXAMPLE` / `NOT-A-REAL-TOKEN` / `DO-NOT-USE` marker inside the token body while preserving the prefix and length class the regex needs:
   ```
   # Bounced by push-protection (realistic random-looking body — shown
   # here abstractly so this very doc doesn't trip the detector):
   xoxb-<11 digits>-<11 digits>-<24 random alphanumerics>
   # Synthetic, still matches the xoxb-[…] shape under test, passes push-protection:
   xoxb-EXAMPLE-NOT-A-REAL-TOKEN-000000000000
   ```
   Verify the rewritten value still exercises the regex/scrubber you're testing — run the test locally — before re-pushing. The point is a fixture that (a) the detector lets through and (b) still asserts what the original asserted.
3. **Rebuild the commit so the flagged blob never enters pushed history.** Push-protection scans the *diff*, but the flagged blob also lives in your local commit. A plain amend-then-push can still bounce if the original blob is reachable. Rebuild the offending commit (`git commit --amend` for a single-commit branch, or `git rebase` to rewrite the commit that introduced the blob) so the realistic-shaped value is gone from the history you push — then `git push --force-with-lease` your own feature branch. (Force-pushing *your own* `do-work/issue-<N>` branch is fine per the "don't force-push shared/main" rule; this isn't a shared branch.)
4. **If the fixture genuinely can't be made synthetic-looking while still testing what it must** (rare — some detectors validate a checksum, e.g. Stripe key Luhn-style checks, so an `EXAMPLE`-laced body won't match), do NOT click the unblock URL and do NOT bypass. Return `blocked: push-protection blocks synthetic fixture and value can't be made obviously-fake while still matching the detector — needs maintainer decision on repo push-protection bypass` and let the maintainer decide whether to register a bypass or restructure the test.

**Mirror to `.gitleaks.toml` when you add a fixture file.** If your new fixture lives in a *new* file (not one already covered by `.gitleaks.toml`'s `[allowlist].paths`), the CI gitleaks job will red on it even after push-protection is satisfied. Add the new fixture path to `.gitleaks.toml`'s `paths` allowlist in the same PR — otherwise you trade a push-time block for a CI-time red and pay a fix-checks cycle. The two scanners protect the same surface (committed content) but are configured independently; a synthetic-fixture PR usually needs to satisfy both.

**When NOT to worry about this.** A diff with no new realistic-shaped secret values can't trip push-protection — most PRs never touch this. The failure mode is specific to work that *adds* secret-shaped fixtures (scrubber tests, secret-scan rule tests, redaction-regex tests). And if push-protection blocks a value that is NOT synthetic — a real token that leaked into your diff — none of the above applies: scrub the real secret out entirely, rotate it if it was ever real, and never commit it. The synthetic-fixture path is for values that were fake from the start.
