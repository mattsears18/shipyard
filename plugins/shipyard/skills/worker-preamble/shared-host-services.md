# You may be one of N concurrent tenants on this host ([#1594](https://github.com/mattsears18/shipyard/issues/1594))

On-demand fragment of `shipyard:worker-preamble`. Load it **before booting any long-lived local service** — an emulator suite, a dev server, a test database, a mock API — **before using a browser MCP such as Playwright**, or when a service-backed test run fails in a way your diff does not explain.

## The failure mode

`/shipyard:do-work --concurrency N` runs up to N workers **on the same physical host at the same time**, each in its own worktree. Worktrees isolate files, branches, and the git index. They do **not** isolate TCP ports, emulator data directories, or any other machine-wide resource.

A target repo's local test runner is usually written for a single tenant. A common shape: before booting, it kills whatever is listening on its fixed port set (clearing a stale emulator from a crashed earlier run), then binds those same ports. That is correct when you are alone on the machine. Under concurrency it is destructive: the second worker to start its run kills the first worker's live services.

The repro (issue #1594, session `do-work-20260919T014132Z-18851` against `mattsears18/lightwork`, `--concurrency 6`): one worker booted the Firebase emulator suite plus an Expo web server on the repo's default ports (8080/8082/4400/9099/9199/5001). A second worker's `npm run test:unit` then tore both down — those ports were bound before its run and free after.

## Why it is worse than a flake

The victim never sees "a peer killed my emulator." It sees **its own suite failing on its own diff**, often naming its own test files, with nothing pointing anywhere else. The natural response is to debug the diff, and a worker that concludes its change broke something may weaken a correct assertion until the run goes green. The failure produces a wrong diagnosis, not just a retry cost.

## What to do

1. **Look for a repo-provided port-isolation mechanism before you boot anything.** Many monorepos with a fixed-port dev stack already ship one: an env var that switches the runner to a per-run port window, a wrapper script that claims free ports, a `CI_PARALLEL`-style flag. Search `package.json` scripts, `scripts/`, the test runner's own source, and `CLAUDE.md` / `CONTRIBUTING.md` for words like `port`, `parallel`, `isolat`, `window`. The #1594 repo shipped `LIGHTWORK_CI_PARALLEL=1` plus `scripts/with-run-ports.js`. The victim worker had used it for its Playwright run, which was unaffected, but not for `test:unit`, which was the run that collided. **Use the mechanism for every service-backed run, not just the one you remembered it for.**
2. **Never assume a default port is yours.** If the repo has no isolation mechanism and your run must bind fixed ports, first check whether something is already listening on them (`lsof -nP -iTCP:<port> -sTCP:LISTEN`). A listener you did not start is probably a live peer's service, not debris. Do not kill it. The broad-process-kill prohibition in the core `SKILL.md` already forbids pattern kills, and a PID you did not spawn is not yours to end. The one exception is a listener you can prove belongs to your own earlier run in this dispatch. If the ports are held, wait and retry. If they stay held, say so in your return; don't route around it.
3. **Before you debug your diff, rule out a peer's teardown.** When a service-backed suite fails with connection-refused / `ECONNRESET` / emulator-not-running / "port already in use" errors, or passes in isolation and fails in the full run, check whether the services it needs are still up. If they vanished mid-run, re-run under the isolation mechanism (or once the ports are free) before you change any assertion. **Never weaken or delete a correct assertion to get past a failure you have not attributed to your own change.**
4. **Say it in your return.** If you hit a cross-tenant collision, name it (`ports <list> were torn down mid-run by a concurrent tenant; re-ran under <mechanism>`). The orchestrator can then tell a real regression from contention and file the target-repo gap if no isolation mechanism exists.

## Browser-MCP artifacts land in the orchestrator's worktree, not yours ([#1612](https://github.com/mattsears18/shipyard/issues/1612))

A session-level MCP server is another shared resource. It is launched once for the whole `/do-work` session, so it is rooted at the **orchestrator's** worktree, not at the dispatched worker's. The Playwright MCP is the concrete case: every file it writes lands under `.claude/worktrees/orchestrator-<session-id>/`, outside your isolation boundary.

Measured for #1612 from a worker's worktree:

- `browser_take_screenshot` with a **relative** `filename` wrote the file at the orchestrator worktree's root.
- The same call with an **absolute** `filename` inside the worker's own worktree was refused: *"File access denied: … is outside allowed roots. Allowed roots: `<orchestrator worktree>/.playwright-mcp`, `<orchestrator worktree>"`*. You cannot redirect the output into your own worktree.
- `browser_navigate` alone wrote a page snapshot to `<orchestrator worktree>/.playwright-mcp/page-<timestamp>.yml`. Every browser action can leave a file, not just an explicit screenshot.

Those files can't reach your diff, but you can't delete them either (the path is outside your worktree), and they sit untracked in a tree the orchestrator may `git add` from. In the #1612 repro a worker left `post-1280.png`, `post-390.png`, `post-390-top.png`, and a `.playwright-mcp/` directory there, and they were only caught because the worker happened to mention them.

What to do:

1. **Prefer the target repo's own browser tooling for artifacts you keep.** A screenshot taken with the repo's Playwright install (its test runner, or `npx playwright screenshot <url> <path>`) from your own worktree lands in your worktree, where you can read, attach, or discard it. Reserve the MCP for interactive inspection.
2. **When you do use the MCP, pass an explicit `filename` on every artifact-writing call,** prefixed with your issue number (`1612-post-390.png`), so the files are identifiable, never the auto-generated `page-<timestamp>` name.
3. **List every file the MCP wrote in your return, on one line starting `Stray artifacts:`,** with paths relative to the orchestrator worktree, including `.playwright-mcp/` when any browser action ran — e.g. `Stray artifacts: 1612-post-390.png, .playwright-mcp/`. Under a structured return, put the line in `summary`. It is not a disposition line; keep your single terminal line as the mode requires. The orchestrator removes exactly those paths (`steady-state.md` § "A.0.7"), so a file you leave off the line is a file nobody reaps.

## Scope

- This concerns resources **outside** your worktree that other workers can touch. Files inside your worktree are yours alone and are covered by the worktree-discipline rules in the core.
- It applies in every mode that runs local services: issue-work, fix-checks-only, fix-rebase, fix-main-ci, fix-failing-prs-batch, investigate, spike.
- At `--concurrency 1` no other `/do-work` worker is running. The host can still run other things (a self-hosted CI runner, a second `/do-work` session, the human's own dev server), so rule 2 still applies there.
- On the orchestrator side, the `mode: issue-work` dispatch prompt carries a "Concurrent tenants on a shared host" Context paragraph whenever the session runs at `concurrency > 1`. See `commands/do-work/dispatch-rules.md`'s concurrent-tenant augmentation. The paragraph tells the worker it has live siblings, and this fragment tells it what to do about them.
