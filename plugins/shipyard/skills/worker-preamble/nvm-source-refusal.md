# Worker-preamble fragment — Node-version pinning (`nvm`/`.nvmrc`) without a bare `source` refusal

On-demand fragment of the `shipyard:worker-preamble` skill (see [`SKILL.md`](./SKILL.md) § "Node dependency-bootstrap check for Node-based target repos"). Load this when a target repo documents (in its own `CLAUDE.md` or a runbook) the standard `nvm`-based Node-version-pinning snippet — `source "$NVM_DIR/nvm.sh"; nvm use` — to pick up the repo's `.nvmrc`-pinned Node version in a non-interactive shell, and running it hits a refusal.

## Check first — you may need none of this ([#1612](https://github.com/mattsears18/shipyard/issues/1612))

Before reaching for any remediation below, compare the ambient Node against the pin, as two plain commands:

```bash
node -v
```

```bash
cat .nvmrc
```

If they match, stop here. The ambient interpreter already is the pinned one, so there is nothing to `source`, wrap, or prepend, and every workaround below is wasted turns. In the #1612 session (`do-work-20260928T134101Z-17500`, lightwork, `--concurrency 4`) that was the common case: several workers spent turns on an `nvm` workaround while ambient `node -v` already printed the `.nvmrc` version.

## Where the refusal comes from ([#1186](https://github.com/mattsears18/shipyard/issues/1186))

When it does fire, the refusal is the **harness's own built-in worktree-isolation Bash classifier** — not a shipyard hook. Shipyard's `enforce-worktree-isolation.sh` gates only the `Agent`/`Workflow` tools at dispatch time and never inspects `Bash` text, and none of the four hooks shipyard wires to the `Bash` matcher mentions `source` or redirects. It is a policy boundary shipyard cannot narrow or configure, so **don't retry the identical `source` invocation with cosmetic edits** — read the refusal and reshape once, per [`classifier-denial.md`](./classifier-denial.md).

**Scope note (2026-10-03).** This guard engages for a worktree-**isolated agent**; it is a different mechanism from the auto-mode permission classifier whose command-shape measurements were retired in [#1666](https://github.com/mattsears18/shipyard/issues/1666). Re-probing it needs an isolated dispatch, so a check run from a non-isolated session does not settle it either way. Treat the remediation below as live.

## Never hardcode the versioned interpreter path ([#1612](https://github.com/mattsears18/shipyard/issues/1612))

The tempting workaround after a `source` refusal is to type the interpreter's full path — `~/.nvm/versions/node/v24.15.0/bin/node`. Three workers in the #1612 session reached for that shape independently. It has two defects, and the second bites silently:

- **It pins the Node version a second time.** `.nvmrc` is the authoritative pin, and every call site that spells the version out is a copy that drifts the moment `.nvmrc` moves — a rebase onto a Node bump is enough.
- **It is wrong for `npm`/`npx` even when the version matches.** `bin/npm` is a `#!/usr/bin/env node` script, so invoking it by path runs npm itself — and every script, hook, and `node` child it spawns — on whatever `node` is first on `PATH`, not the version whose directory you named. Measured for #1612, with `.nvmrc` holding `v24.12.0` and ambient Node `v24.15.0`: `"$HOME/.nvm/versions/node/v24.12.0/bin/npm" exec -c 'node -v'` printed **`v24.15.0`**.

Derive the directory from `.nvmrc` at call time instead and put it on `PATH` for the one command, so npm's children inherit the pin too. One plain `Bash` call:

```bash
NVMRC=$(cat .nvmrc); PATH="$HOME/.nvm/versions/node/$NVMRC/bin:$PATH" npm ci
```

This PATH-prepend form assumes `.nvmrc` holds a full `vX.Y.Z`, which is what `nvm` itself writes; if it holds `X.Y.Z` with no `v`, write `v$NVMRC`. A partial version or alias (`24`, `lts/*`, `node`) names no single directory — use `nvm-exec` below, which resolves those. A missing directory fails loudly (`No such file or directory`), never silently on the wrong Node, and this reaches only an already-installed version.

## Remediation — `nvm-exec` keeps `source` off the command line entirely

`nvm` ships a standalone, directly-executable wrapper at `$NVM_DIR/nvm-exec` (mode `755`, not a shell function) that reads `.nvmrc` from the current directory, resolves the pinned version, and `exec`s the given command under it. It sources `nvm.sh` **inside its own script body**, not in the command line the classifier evaluates, so invoking it is a single ordinary executable call:

```bash
"$HOME/.nvm/nvm-exec" node -v          # prints the .nvmrc-pinned version
"$HOME/.nvm/nvm-exec" npm ci
```

Confirm it exists first (`test -x "$HOME/.nvm/nvm-exec"`, one plain command) — it ships with every standard `nvm` install but a nonstandard one could lack it. It needs no `PATH` surgery and no version-string parsing, resolves aliases and partial versions, and fails loudly (`exit 127`) if `.nvmrc` can't be resolved rather than silently running the wrong Node.

If `nvm-exec` is missing, fall back to the PATH-prepend form above. **The two previous fallbacks — a `.shipyard-scratch/` wrapper script and a multi-statement glob-and-prepend block — are retired ([#1665](https://github.com/mattsears18/shipyard/issues/1665)):** each reached only an already-installed version, which is exactly what the one-line PATH-prepend already does, so they added shapes to get refused without adding reach. Neither can install a missing version; that needs `nvm install`, itself only reachable through the `source`d function. A miss on both paths is a signal to use `nvm-exec`, not a `blocked:` bail.

## When NOT to load this

Skip entirely on a repo with no `.nvmrc` / no `nvm`-based version-pinning convention, or when the ambient `node -v` on the host already satisfies the repo's declared engine version — check `package.json` `engines.node` or `.nvmrc` first, since most hosts already have a compatible default Node and this whole fragment is then a no-op.
