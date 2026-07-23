# /shipyard:do-work — Operator phase · steady-state loop hooks

**Operator sub-phase (4 of 4 on-demand bodies, plus [`05-dont.md`](./05-dont.md)).** Owns the two hooks [`steady-state.md`](../steady-state.md) calls into on every run except under the `--no-operate` / `--hands-off` opt-out: the step-A.1 reactive enqueue and the step-D proactive sweep + drain. Router: [`operate.md`](../operate.md). Sidebar: [`dont.md`](../dont.md) (orchestrator-wide) and [`05-dont.md`](./05-dont.md) (operator-phase-specific). Prev: [`03-error-handling-and-safety.md`](./03-error-handling-and-safety.md).

## Operator layer hooks into the steady-state loop

*(Default-on — under `--no-operate` / `--hands-off`, ignore this entire section.)*

On every run except the `--no-operate` / `--hands-off` opt-out, the steady-state loop has a browser-operator layer. The full machinery — backend selection, preflight, standing authorization, per-kind playbooks, the `operator_queue` drain loop, and the proactive sweep — lives in the rest of the operator phase ([the `operator_queue` and its two feeders](../operate/01-queue-and-authorization.md#the-operator_queue-and-its-two-feeders), [playbooks by kind](../operate/02-execution-and-playbooks.md#playbooks-by-kind)); this section is just the two hooks the steady-state loop owns. Under `--no-operate` / `--hands-off`, ignore this entire section: `operator_queue` stays empty and nothing here fires.

### A.1 hook — reactive enqueue

When parsing a worker return in [step A.1](../steady-state.md#a1-parse-the-return-string), if the bail/defer names a **browser-completable** action (a `blocked:`/`deferred:` reason that is an operator action — approve a deployment, paste a secret, toggle a console, a worker **`external provisioning required`** bail that needs an account created / credential set ([#628](https://github.com/mattsears18/shipyard/issues/628)) — or a scope-agent **`external-dependency`** defer), enqueue an `operator_queue` item `{ source: "worker-handback"|"defer", kind, target, plan, origin_ref }` in addition to the normal recording. When the operator layer is active (the default — unless `--no-operate` / `--hands-off`), the [setup step-6 recording path](../setup/06-scope-preflight.md#6-initial-scope-pre-flight) already routes `external-dependency` defers to the `needs-operator` label; the enqueue is the in-session working copy the orchestrator drains this session. **Genuine `human-decision-required` / judgment defers are NOT enqueued** — they stay `needs-human-review` hand-backs.

### D hook — proactive sweep + drain

In [step D's periodic refresh](../steady-state.md#d-periodic-refresh), additionally:

1. **Proactive sweep.** Run a `/my-turn`-style discovery filtered to the **browser-completable subset** — open issues carrying the **`needs-operator`** label, superseded/duplicate PRs to close, CI secrets flagged by a red run (teed up), a referenced provider toggle, an *unambiguous* drafted reply — and enqueue any not already in `operator_queue`. Judgment calls are never enqueued.
2. **Drain.** Whenever the orchestrator is otherwise idle (a code worker is in flight and not yet returned, or this is a step-D tick), pop the highest-`rank_key` `operator_queue` item and execute it **on the main thread** via the [operator phase playbooks](../operate/02-execution-and-playbooks.md#playbooks-by-kind) — serialized, one browser action at a time (the real browser is a singleton; never dispatch a subagent to drive it). On success, remove the item and clear the issue's `needs-operator` label; on a hand-back outcome (e.g. a value only the user holds, or a logged-out console), [`verify`](../operate/02-execution-and-playbooks.md#verify-read-only-console-verification--never-mutates)-read the console first to make the hand-back concrete (confirm the premise, name the exact toggles/values), then leave the label and surface it. When a human has completed a handed-back action mid-session, a `verify` re-read reports pass/fail and a verified pass is what clears the `needs-operator` label and closes the originating issue. Write-through `operator_queue` to the session-state file on each enqueue/drain.

If preflight found no browser backend, the drain is a no-op: items accumulate and are surfaced as hand-backs at end of session ([Degradation](../operate.md#degradation--no-backend-reachable)).
