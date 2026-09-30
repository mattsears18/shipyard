# Worker-preamble fragment — `export VAR=$(cmd)` refused, and how to hand a credential to a command

On-demand fragment of the `shipyard:worker-preamble` skill (see [`SKILL.md`](./SKILL.md) § "On-demand fragments"). Load it when a `Bash` call is refused for exporting a computed value — most often while reading a secret or token into an environment variable so a later command can use it ([#1605](https://github.com/mattsears18/shipyard/issues/1605)).

## The refusal

In a worktree-isolated session, the obvious way to authenticate against a third-party API is refused:

```text
export SENTRY_AUTH_TOKEN=$(gcloud secrets versions access latest --secret=<SECRET_NAME> --project=<project>)
```

> This agent is isolated in the worktree … but this command runs `export SENTRY_AUTH_TOKEN=` with a value every later program inherits (command output) in a plain command, so what it runs cannot be shown not to be git. Refusing to run it.

The guard objects to **exporting a value the command computes to every later program**. What the value is, and where it comes from, make no difference. This is the Claude Code harness's own worktree-isolation check, not a shipyard hook, so there is nothing to configure. Don't retry the same `export` with cosmetic edits. It is refused again for the same reason.

**The two-call split the message suggests cannot work either.** Shell variables do not survive across separate `Bash` calls (`SKILL.md` § "Mid-session cwd anchoring"), so a value computed in one call is gone in the next. Both obvious escape hatches are closed, and the refusal names no working alternative. That is what this fragment is for.

## What is refused and what runs

The orchestrator-side measurements come from [`commands/do-work/dont.md`](../../commands/do-work/dont.md) § "Never `export` a computed value" ([#1607](https://github.com/mattsears18/shipyard/issues/1607), [#1619](https://github.com/mattsears18/shipyard/issues/1619)). The rows marked #1605 were re-measured in an isolated worktree on 2026-09-29, using a harmless `printf` value in place of a real secret:

```text
export V=$(cmd)                                   → REFUSED  (alone, as a plain command — #1605)
V=$(cmd); export V; <use>                         → REFUSED  ("export V exporting a value this command computes")
export V=$(cmd); <use>                            → REFUSED  (same trigger, one statement)
V="$(cmd)" /usr/bin/curl <url>                    → REFUSED  (env prefix carrying a computed value — #1605)
V="$(cmd)" /usr/bin/printenv V                    → RUNS     (same shape, different program — #1605; don't rely on it)
V=$(cmd); <use of V>                              → RUNS     (no export; V is argv-visible, never in a child's env)
curl -H "Authorization: Bearer $(cmd)" <url>      → RUNS     (consumed once, literal text in the same word — #1605)
curl -H "$(cmd)" <url>                            → REFUSED  (the whole word is one expansion — #1605)
export V=/literal/value                           → RUNS     (not computed)
/abs/path/helper.sh <cmd…>                        → RUNS     (helper computes and exports internally — #1605)
```

Two separate rules are at work. The export rule refuses any exported computed value, every time. The whole-word rule (`dont.md` § "The resolvability boundary", [#1474](https://github.com/mattsears18/shipyard/issues/1474)) can refuse a word that is only an unresolvable expansion. The #1605 measurements found that rule context-dependent: a bare `"$(cmd)"` argument ran for `/bin/echo` but was refused for `curl -H`. Don't try to predict it. Keep literal text in the same word as the expansion, which ran in every case measured.

## Working forms, in priority order

### 1. The helper script fetches the credential itself (preferred)

Write a small script to `$WORKTREE_PATH/.shipyard-scratch/`. Seed `.shipyard-scratch/.gitignore` first (`SKILL.md` § "Scratch directory"). Have the script read the credential, export it inside its own process, and `exec` the command that needs it. Here is a generic env-var wrapper, with placeholder names only:

```text
#!/usr/bin/env bash
set -euo pipefail
TOKEN="$(gcloud secrets versions access latest --secret=<SECRET_NAME> --project=<project>)"
[ -n "$TOKEN" ] || { echo "credential unavailable" >&2; exit 1; }
export SENTRY_AUTH_TOKEN="$TOKEN"
exec "$@"
```

Then run `chmod +x` on it and direct-exec it, as two plain commands:

```bash
chmod +x "$WORKTREE_PATH/.shipyard-scratch/with-sentry-token.sh"
```

```bash
"$WORKTREE_PATH/.shipyard-scratch/with-sentry-token.sh" sentry-cli releases list
```

The `chmod` is required, and so is direct exec. `Write` sets no exec bit, and `bash <script>` is itself refused (`SKILL.md` § "Invoke a helper script by direct exec", [#1566](https://github.com/mattsears18/shipyard/issues/1566)). A script in another language works the same way. The issue's own repro used Python, calling `subprocess.run([...], capture_output=True)` and checking for an empty result before use.

**Use this form even where the refused one would have run.** The credential exists only inside that process. It is never in a shell assignment, never in the transcript, and never in a later program's environment. The refused form is worse on every one of those counts. This is the recommended way, not a grudging fallback.

### 2. Inline, where one program consumes the value once

When a single command uses the value as part of a larger argument, assign it without `export` and use it in the same `Bash` call:

```bash
TOKEN=$(gcloud auth print-access-token); curl -s -H "Authorization: Bearer $TOKEN" "https://<api-host>/<path>"
```

The variable never reaches a child's environment, so the export rule does not fire. The literal `Bearer ` prefix in the same word keeps the whole-word rule from firing. For a flag, prefer `--token="$TOKEN"`, one word with a literal prefix, over `--token "$TOKEN"`, where the value stands alone. The one-word inline form, `-H "Authorization: Bearer $(gcloud auth print-access-token)"`, also ran in the #1605 measurements. This repo's specs hoist the substitution onto an assignment instead ([#1314](https://github.com/mattsears18/shipyard/issues/1314)). One caveat: an inline value sits on the process's command line, where other processes on the host can read it. Prefer form 1 for long-lived or high-privilege credentials.

### 3. A computed value that is not secret

For a non-secret value, such as a path, a PID, or a resolved version, run the computing command on its own. Then substitute what it prints as a literal: `export V="<literal it printed>"`. This is exactly how the orchestrator retired its own `VAR=$(…)` + `export VAR` pairs (#1607, #1619). **Never do this with a secret.** Substituting a literal means the value appears in the transcript.

## Don't

- **Don't echo, print, or log the credential** to "see if it worked". Check that it is non-empty inside the helper instead, as form 1 does.
- **Don't write the credential to a file**, even a gitignored one under `.shipyard-scratch/`. The helper reads it at run time. Nothing persists it. This is the same line `SKILL.md` § "Never create a credential" draws.
- **Don't reach for an env prefix** (`V="$(cmd)" tool`). The #1605 measurements refused it for `curl` but ran it for `printenv`, and `dont.md` records further refusals. Whether it runs depends on the program, so it is not a way around the export rule. Use form 1.
- **Don't return `blocked:` over this refusal.** Form 1 always works. A credential you genuinely cannot read is a different case. That one is a `blocked: <what is missing> — needs operator provisioning` hand-back (`SKILL.md` § "Never create a credential").

## The refusal family

This is one of several "the harness refused a shape the obvious approach uses, and here is the form that works" cases. Each has its own fix, and none of those fixes works on another:

| Refused shape | Where the fix lives |
|---|---|
| `export VAR=$(cmd)`, or an env prefix with a computed value | this fragment |
| `source <file>` (for example `nvm use`) | [`nvm-source-refusal.md`](./nvm-source-refusal.md) |
| `bash <script>` | `SKILL.md` § "Invoke a helper script by direct exec" ([#1566](https://github.com/mattsears18/shipyard/issues/1566)) |
| plain `git` rewritten by a host hook into `<launcher> git` | [`launcher-git-refusal.md`](./launcher-git-refusal.md) ([#1558](https://github.com/mattsears18/shipyard/issues/1558)) |
| loops, pipes, heredoc command substitution | [Claude Code's command-shape check](https://code.claude.com/docs/en/worktrees#how-claude-code-enforces-isolation), plus [`body-file-convention.md`](./body-file-convention.md) for `--body` |
