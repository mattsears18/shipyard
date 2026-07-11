# Worker-preamble fragment — Node dependency bootstrap + hook/test silent-pass gates

On-demand fragment of the `shipyard:worker-preamble` skill (see [`SKILL.md`](./SKILL.md)). Load this when a worker mode runs the **target repo's** local tests / pre-push hooks before pushing — primarily against Node-based or self-hosting target repos. It carries the silent-quality-gate-bypass guards — missing `node_modules` (#316), non-executable husky hooks (#459), and a test runner that ignores the worktree path (#369) — plus the non-workspace-monorepo root-hook bootstrap gap that rejects a commit and leaves an empty pushed branch (#680). The per-mode specs under `agents/issue-worker/` point here by name (`worker-preamble § "Dependency-bootstrap check for Node-based target repos"`, `§ "Husky / core.hooksPath hooks silently skipped on a missing exec bit"`, `§ "Test-runner silent-pass when the target repo ignores worktree paths"`, `§ "Root-owned commit hooks in a non-workspace monorepo"`).

**Why these live in a worker-preamble fragment and not per-mode.** Every dispatched worker (issue-work, fix-checks-only, fix-rebase, fix-main-ci, fix-failing-prs-batch, investigate) eventually runs `git push` against the target repo, and the silent-test-skip failure modes are identical across modes. One fragment beats six copy-pasted recipes. The shipyard repo itself is shell-test-driven with no `package.json` deps to bootstrap and no husky setup, so a worker dispatched against `mattsears18/shipyard` skips these checks — they guard the *target-repo* tooling (lightwork, mattsears18.com, etc.).

## Dependency-bootstrap check for Node-based target repos

The Claude Code harness creates your agent worktree with `git worktree add` and nothing else — it does NOT install npm dependencies, does NOT symlink `node_modules` from the primary checkout, and does NOT run `npm ci`. For most target repos this is fine (Python, Go, plain shell, docs-only). For **Node-based target repos** it's a silent test-correctness gap, because:

- The repo's pre-push / pre-commit hooks usually shell out to locally-installed binaries via `node_modules/.bin/<tool>` (jest, prettier, eslint, firebase, etc.).
- When `node_modules/` is missing, those shell-outs hit `ENOENT` at the `execFileSync` level. A naive hook script that wraps the call in a try/catch and treats "no output" or "non-numeric exit status" as success will **silently pass** instead of failing loudly. The lightwork project's `scripts/test.js` does exactly this — `--passWithNoTests` semantics get applied to a missing-binary spawn-failure and the push proceeds with zero tests actually run. ([#316](https://github.com/mattsears18/shipyard/issues/316)).
- Net effect: your worker thinks it ran the project's test suite locally, when in fact it ran nothing. The code lands and CI catches the regression — except now you've burned an iteration on a problem your local-test discipline was supposed to catch.

**The check.** Before your first `git push`, if the target repo ships a `package.json` AND your worktree has no `node_modules/`, treat it as a setup-incomplete state — not a "this repo has no deps" state:

```bash
# Run this once near the top of step 4 (implement) — before you write code, before
# you run tests, definitely before you push.
if [ -f package.json ] && [ ! -d node_modules ]; then
  echo "worker-preamble: package.json present but node_modules missing — Node deps not bootstrapped" >&2
  # Try the cheap recovery paths in order. See remediation section below.
fi
```

The check is a one-liner; the remediation is the substantive part.

**Remediation, in order of preference:**

1. **Symlink from the primary checkout.** Cheapest, fastest, and works for almost all tooling (jest, eslint, prettier, firebase CLI). The primary checkout's `node_modules/` is at a deterministic path relative to your worktree — `.claude/worktrees/agent-<id>/` lives inside `<primary-checkout>/.claude/worktrees/`, so the primary's `node_modules` is exactly `../../../node_modules` from your worktree root:
   ```bash
   if [ -d ../../../node_modules ] && [ ! -e node_modules ]; then
     ln -s ../../../node_modules node_modules
     # Also add to the per-worktree exclude so the symlink can NEVER be
     # implicitly staged into a commit (issue #351 — see the "Pre-commit
     # hygiene" section for the salvage cost when it leaks). The
     # per-worktree `.git/info/exclude` is the canonical git mechanism for
     # "ignore this in this checkout only" — it doesn't pollute the repo's
     # `.gitignore` (which would be a public spec change).
     grep -qxF node_modules .git/info/exclude 2>/dev/null \
       || echo node_modules >> .git/info/exclude
   fi
   ```
   Native modules built against the host Node version need rebuild for native modules to load — acceptable trade-off since shipyard already requires the primary checkout to be on a compatible Node version. The symlink only persists for the worktree's lifetime; the orchestrator's reap doesn't touch the primary checkout's `node_modules/`.

   **Auto Mode constraint.** In Auto Mode the symlink step is typically denied by the auto-mode classifier with a message like: *"Symlinking the parent repo's `node_modules` into the worktree creates a writable path linking the worktree to a pre-existing directory outside the session's scope and risks irreversible effects on shared local state; not explicitly authorized."* If you are running under Auto Mode, **skip the symlink entirely and go directly to `npm ci` (path 2 below)** — attempting the `ln -s` first wastes one tool-call turn on a denial that is predictable. Observed in `/shipyard:do-work` session against `mattsears18/lightwork` on 2026-05-24 ([#328](https://github.com/mattsears18/shipyard/issues/328)).

   **Alternative — `cp -al` (hard-link copy).** A hard-link copy doesn't create a cross-directory writable link, so the auto-mode classifier should allow it. Same disk semantics as a symlink (files are not duplicated byte-for-byte), but each file is independently owned by the worktree. Caveat: hard links only work within the same filesystem, which is normally satisfied when the worktree and primary checkout share the same mount. Use as an alternative when `ln -s` is denied and `npm ci` is too slow:
   ```bash
   if [ -d ../../../node_modules ] && [ ! -e node_modules ]; then
     cp -al ../../../node_modules node_modules
     # Same gitignore-via-info/exclude hygiene as the symlink path — the
     # hard-link tree shouldn't leak into a commit either.
     grep -qxF node_modules .git/info/exclude 2>/dev/null \
       || echo node_modules >> .git/info/exclude
   fi
   ```

   **Next 16 / Turbopack constraint — skip BOTH link strategies, go straight to `npm ci` ([#458](https://github.com/mattsears18/shipyard/issues/458)).** Next.js 16's Turbopack refuses a `node_modules` that resolves outside the worktree's filesystem root, failing the build/dev/test with `Symlink ... points out of the filesystem root`. The `../../../node_modules` symlink target is literally outside the worktree root, so the symlink path (path 1) is dead on a Turbopack repo — and the `cp -al` hard-link copy is risky too (Turbopack resolves the real inode, which still lives under the primary checkout's tree, so it can trip the same root check). Don't attempt either link strategy and let each worker rediscover the failure; **detect Turbopack/Next 16 first and fall through deterministically to `npm ci` (path 2)**:
   ```bash
   # Turbopack/Next-16 detection: a next >=16 dep, OR a --turbopack flag wired
   # into any package.json script (next dev/build --turbopack), OR a turbopack
   # config key. Any hit ⇒ skip the link strategies, go straight to npm ci.
   uses_turbopack=false
   if [ -f package.json ]; then
     next_major=$(node -p "((require('./package.json').dependencies?.next||require('./package.json').devDependencies?.next||'').match(/\d+/)||[0])[0]" 2>/dev/null)
     if { [ -n "$next_major" ] && [ "$next_major" -ge 16 ] 2>/dev/null; } \
        || grep -q -- '--turbopack' package.json 2>/dev/null \
        || node -e "process.exit(require('./package.json').turbopack?0:1)" 2>/dev/null; then
       uses_turbopack=true
     fi
   fi
   ```
   When `uses_turbopack=true`, skip path 1's symlink AND its `cp -al` alternative entirely and run `npm ci` (path 2) — the link strategies cannot satisfy Turbopack's root check, so attempting them first only burns a turn on a predictable failure (the same wasted-turn logic as the Auto Mode constraint above). Repro: session `do-work-20260601T004608Z` against `mattsears18/mattsears18.com` (Next 16 + Turbopack) — workers #169 / #140 / #170 each hit `Symlink points out of the filesystem root` on the symlink path and self-recovered to `npm ci`.

2. **Fall back to `npm ci`.** Most correct, slowest (30–90s typical). Use when the symlink path doesn't exist (worktree was created somewhere unusual), when running under Auto Mode (see constraint above), when the repo uses Next 16 / Turbopack (see constraint above — the link strategies fail Turbopack's filesystem-root check), or when a previous attempt with the symlink hit native-module loader errors:
   ```bash
   npm ci --no-audit --no-fund --prefer-offline
   ```

3. **Bail with `blocked:` if both paths fail.** Don't push a Node-repo change whose local tests didn't actually run — the silent-pass failure is exactly the gap this check exists to close. Return `blocked: cannot bootstrap node_modules — symlink target missing AND npm ci failed (<reason>)` and let the orchestrator pick a different issue.

**When NOT to run the check.** Don't run it for non-Node repos (no `package.json`), don't run it inside a sub-directory of a monorepo unless that sub-dir has its own `package.json` (the root's deps may satisfy the sub-dir's tooling), and don't run it for documentation-only changes to a Node repo (no tests to skip silently if your diff is `*.md` files).

**Exception — root-owned commit hooks in a monorepo ([#680](https://github.com/mattsears18/shipyard/issues/680)).** The "sub-dir only unless it has its own `package.json`" carve-out above is about the deps your *tests* need. It does NOT cover commit-hook tooling: in a non-workspace monorepo, husky / commitlint / lint-staged are usually installed from the **root** `package.json` (often not a workspace member), so they resolve against the **root** `node_modules` regardless of which sub-dir your code change lives in. If you bootstrap only the app workspace and skip the root, the commit hook fails and your commit is rejected. Whenever the repo **root** owns the commit hooks, bootstrap the root too — see [§ "Root-owned commit hooks in a non-workspace monorepo"](#root-owned-commit-hooks-in-a-non-workspace-monorepo) below.

## Root-owned commit hooks in a non-workspace monorepo

A fourth silent-quality-gate hazard, and the one that leaves *remote-visible debris* ([#680](https://github.com/mattsears18/shipyard/issues/680)). Here the app you're changing lives in a workspace sub-dir (`apps/<app>/`, `packages/<pkg>/`), but the repo installs its **commit-hook** tooling — husky + commitlint + lint-staged — from the **root** `package.json`, which is frequently *not* a workspace member. `git worktree add` runs no `npm ci` anywhere, and a `CLAUDE.md` that says "`npm ci` in a fresh worktree" (plus the sub-dir-only carve-out in the dependency-bootstrap "When NOT to run" note above) can lead a worker to bootstrap only the app workspace and leave the **root** `node_modules` empty. Then `.husky/commit-msg` (typically `npx --no commitlint ...`, or a `node_modules/.bin/lint-staged` shell-out) resolves against the absent root `node_modules`, the hook errors, and `git commit` is **rejected** — and a worker that already ran `git push` has left an **empty branch** on the remote, which the orchestrator's orphan-branch triage (setup step 3c) and any human reading `git branch -r` mistake for abandoned worker debris.

Confirmed repro (issue #680): session `session_01Hs4CqGT53F6kwVasHiyLnH` against `mattsears18/lightwork` (2026-07-10), issue-work on `lightwork#2388`. The monorepo's app is at `apps/lightwork/`; husky + commitlint are installed from the root `package.json`, which is not a workspace member. The worker `npm ci`'d only in `apps/lightwork`, `.husky/commit-msg` (`npx --no commitlint`) failed against the missing root `node_modules`, the commit was rejected, and an empty branch had already been pushed before the worker diagnosed it. This shape — root-level husky/commitlint/lint-staged with the app in a workspace sub-dir — is the default for `npm workspaces`, `pnpm`, `turbo`, and `nx` monorepos, so it's common, not exotic.

### Bootstrap the ROOT when it owns the commit hooks

Before your first commit, if the repo **root** wires commit hooks — a `.husky/` directory at the root, OR the root `package.json` declares `husky` / `commitlint` (`@commitlint/cli`) / `lint-staged` in `devDependencies` or `dependencies`, OR carries a `lint-staged` / `commitlint` config key or a `prepare: "husky"` script — bootstrap the **root** `node_modules` in addition to whatever workspace sub-dir you bootstrapped for tests, even when your code change is confined to the sub-dir:

```bash
# From your worktree root (repo root; `git rev-parse --show-toplevel`).
# Detect root-level hook tooling that resolves against the ROOT node_modules.
if [ -f package.json ] && [ ! -d node_modules ]; then
  if [ -d .husky ] \
     || node -e "const p=require('./package.json'),d={...p.dependencies,...p.devDependencies};process.exit((d.husky||d.commitlint||d['@commitlint/cli']||d['lint-staged']||p['lint-staged']||p.commitlint||(p.scripts&&p.scripts.prepare&&/husky/.test(p.scripts.prepare)))?0:1)" 2>/dev/null; then
    echo "worker-preamble: repo root owns commit hooks but root node_modules is missing — bootstrap the ROOT, not just the app workspace (#680)" >&2
    # Apply the SAME remediation ladder as the dependency-bootstrap section
    # above — symlink ../../../node_modules → cp -al → npm ci — but at the
    # repo ROOT, not the workspace sub-dir. (The `../../../node_modules`
    # symlink target IS the primary checkout's root node_modules.) The Auto
    # Mode / Turbopack constraints apply identically.
  fi
fi
```

The remediation is the same ladder documented in the dependency-bootstrap section (symlink `../../../node_modules` → `cp -al` → `npm ci`, subject to the Auto Mode and Turbopack constraints); the only difference is *where* you apply it — the repo root, not the workspace sub-dir. When both the root (for hooks) and a workspace sub-dir (for tests) need deps, bootstrap **both**.

### Never `git push` before the first `git commit` succeeds

Independent of the root-bootstrap fix above, and worth doing regardless: it bounds the blast radius of *any* commit-hook failure, not just this one. A rejected commit-hook (the root-`node_modules` gap here, a non-executable hook per the section below, a genuine lint failure) exits `git commit` non-zero and lands **no commit**. If you already ran `git push` — or ran commit and push as a fire-and-forget pair without checking the commit's exit status — you push a branch with zero commits, the empty-branch debris above. **Gate the push on the commit actually succeeding:**

```bash
git add <specific paths>
if git commit -m "<message>"; then
  git push -u origin <branch>
else
  # Commit was REJECTED (non-zero exit) — do NOT push. A hook likely fired;
  # see the diagnostic below before assuming the diff is at fault.
  echo "worker-preamble: git commit failed — NOT pushing (an empty branch would be remote-visible debris)" >&2
fi
```

Never run `git commit … && git push` without observing the commit's exit status, and never `git push` speculatively "to be safe" before the commit has landed.

### Diagnostic — a rejected commit with `.husky/` present is a missing-`node_modules` tell, not a bad diff

When `git commit` fails and the repo wires committed hooks (`.husky/` present, or `core.hooksPath` resolves in-tree), suspect the **commit hook**, not your changes, first. A `commit-msg` / `pre-commit` hook that shells out to `npx --no commitlint` / `node_modules/.bin/lint-staged` fails with an `ENOENT`- or "command not found"-shaped error when the `node_modules` it resolves against (usually the **root** — see above) is missing, and that error is easy to misread as a lint failure in your diff. Before touching your changes:

```bash
# If commit failed and hooks are wired, check the ROOT node_modules first.
[ -d .husky ] && [ ! -d node_modules ] && \
  echo "worker-preamble: commit likely rejected by a hook resolving against a missing root node_modules — bootstrap it (see above) and retry the commit, do NOT rewrite the diff" >&2
```

Bootstrap the missing `node_modules` (per "Bootstrap the ROOT" above), then retry the commit. Do NOT reach for `--no-verify` — the hook *should* run — and do NOT start rewriting a diff that was never the problem.

## Husky / `core.hooksPath` hooks silently skipped on a missing exec bit

A third silent-quality-gate-bypass, adjacent to the two above but with a different root cause ([#459](https://github.com/mattsears18/shipyard/issues/459)). Here `node_modules` is present and the test config is fine — but the repo's **pre-commit hook itself never runs**, because the hook file in your fresh agent worktree lacks the executable bit. The commit lands with lint-staged / prettier / eslint never having fired, and you didn't pass `--no-verify` — git skipped the hook on its own.

**Mechanism.** Husky (and any repo that sets `core.hooksPath` to a committed hooks dir) relies on the hook file being mode `100755`. Git **silently ignores a hook that isn't marked executable** — it prints a one-line `hint:` to stderr (`hint: The '.husky/pre-commit' hook was ignored because it's not set as executable.`) and then **exits 0, committing anyway**. The hint is advisory; the commit is not blocked. Two ways a fresh worktree ends up with non-executable hooks:

- **The hook was committed without the exec bit.** `git worktree add` checks out each file with the mode recorded in the index. If the repo committed `.husky/pre-commit` as `100644` (a common mistake — easy to do on Windows or after a `chmod`-losing copy), every checkout, worktree or not, gets a non-executable hook. The primary checkout often masks this because the developer ran `husky install` once, which can re-set the bit out-of-band.
- **The repo provisions hooks via a `prepare` / `postinstall` script that never ran in the worktree.** Husky v9's `prepare: "husky"` script (run by `npm install`) is what wires `core.hooksPath` and sets perms. A bare `git worktree add` runs no npm lifecycle script, so if the repo depends on `prepare` to make hooks live, the worktree's hooks are inert. (This overlaps the dependency-bootstrap gap above — if you `npm ci` to bootstrap deps, its `prepare` script usually fixes the hooks as a side effect; the failure mode here is specifically the path where deps were symlinked, not `npm ci`'d, so `prepare` never ran.)

Confirmed repro (issue #459): `mattsears18.com` session `do-work-20260601T004608Z`, the #170 issue-work worker — git silently skipped the non-executable `.husky/pre-commit`, so lint-staged / formatting gates never ran on the commit. A local sanity check shows the behavior cleanly: a `.husky/pre-commit` that `exit 1`s blocks the commit when mode `755`, but is skipped (commit exits 0, only a `hint:` to stderr) when mode `644`.

**The check.** Before your first commit, if the repo wires a committed hooks dir (`.husky/` present, or `git config core.hooksPath` resolves inside the worktree), confirm the hooks that exist are executable. Cheap one-liner:

```bash
# Resolve the hooks dir: explicit core.hooksPath wins, else .husky/ is the husky default.
HOOKS_DIR="$(git config --get core.hooksPath || true)"
[ -z "$HOOKS_DIR" ] && [ -d .husky ] && HOOKS_DIR=.husky
if [ -n "$HOOKS_DIR" ] && [ -d "$HOOKS_DIR" ]; then
  # Any extensionless regular hook file present-but-not-executable is the silent-skip risk.
  NON_EXEC=$(find "$HOOKS_DIR" -maxdepth 1 -type f ! -perm -u+x ! -name '*.*' 2>/dev/null)
  if [ -n "$NON_EXEC" ]; then
    echo "worker-preamble: hooks present but not executable — git will silently skip them:" >&2
    echo "$NON_EXEC" >&2
  fi
fi
```

The `! -name '*.*'` filter skips husky's own helper files (`_/husky.sh`, `.gitignore`) — hook entrypoints are extensionless (`pre-commit`, `commit-msg`, `pre-push`).

**Remediation, in order:**

1. **`chmod +x` the hook files in the worktree.** Restores the exec bit locally so git runs the hooks for *your* commits. This does NOT change the committed mode (so it's not a stray diff) — it only fixes the working-tree perms for this worktree's lifetime, which is exactly the scope of the problem:
   ```bash
   chmod +x "$HOOKS_DIR"/* 2>/dev/null || true
   ```
   If the underlying cause is the committed mode being `100644` (not just a worktree-checkout artifact), that's a real repo bug worth fixing in the issue you're working — but only if it's in scope. Don't fold a `git update-index --chmod=+x` mode-fix into an unrelated PR; file a follow-up issue instead.

2. **Or `npm ci` to let the `prepare` script re-provision hooks.** If the repo wires hooks through husky's `prepare` script and you haven't bootstrapped deps yet, `npm ci` runs `prepare` as a lifecycle step, which re-sets `core.hooksPath` and the exec bits. Prefer this when you're already going to `npm ci` for the dependency-bootstrap check above — one command fixes both gaps.

3. **Never reach for `--no-verify` as a "workaround."** This is the inverse of the `--no-verify` prohibition: the hook *should* run and you must make it run, not skip it because it's inconvenient that it isn't running. A silently-skipped hook is a latent quality-gate bypass; the fix is to make the gate fire, never to formalize the bypass.

**When NOT to worry about this.** Repos with no `.husky/` and no `core.hooksPath` (the hooks live in the default `.git/hooks`, which `git worktree add` shares from the common dir and which carry their committed mode) — there's nothing to fix. Documentation-only diffs that wouldn't trip a lint-staged gate anyway. And the shipyard repo itself has no husky setup, so a worker dispatched against `mattsears18/shipyard` skips this check — it's the *target-repo* hooks (lightwork, mattsears18.com, etc.) that this guards.

## Test-runner silent-pass when the target repo ignores worktree paths

A second silent-pass failure mode, distinct from the missing-`node_modules` case above ([#369](https://github.com/mattsears18/shipyard/issues/369)). Here `node_modules` is fully present and the binaries resolve fine — but the target repo's test config **ignores the worker's own worktree path**, so the runner silently skips every test the worker just wrote.

**Mechanism.** A repo that runs `/shipyard:do-work` against itself commonly adds `/.claude/worktrees/` to its test runner's path-ignore list (jest `testPathIgnorePatterns`, vitest `exclude`, pytest `norecursedirs`, mocha `--ignore`) so the **primary** checkout's test runner doesn't sweep into agent worktrees during local dev. That pattern is correct for the primary use case but **wrong** for the worker use case: when the worker (or its pre-push hook) runs the suite *from inside* `.claude/worktrees/agent-*/`, the runner computes the absolute path of every test file — which now begins with `.../.claude/worktrees/agent-*/...` — and the ignore pattern matches the worker's own files. The runner reports "No tests found" / "0 tests", the hook treats that as a pass, and the push proceeds with zero tests actually run. The lightwork repro: `jest.config.js` with `testPathIgnorePatterns: ['/node_modules/', '/functions/', '/.claude/worktrees/']` silently skipped a worker's new `__tests__/chunk-load-recovery.test.ts` while reporting code 0 (session `do-work-20260528T015557Z-14129`, [`lightwork#1362`](https://github.com/mattsears18/lightwork/pull/1362)).

**The signal.** When you run the target repo's test suite (or read your pre-push hook's output) and see a **zero-tests-found pass** — `No tests found`, `0 tests`, `0 passed`, `--passWithNoTests` firing — against a diff that **does** add or modify test files, do NOT treat it as a green local run. A zero-test pass on a test-touching diff is the silent-pass tell.

**The recovery, in order:**

1. **Re-run with the worktree-ignore entry stripped.** If the repo's config ignores `/.claude/worktrees/`, re-run the suite with the *other* ignore entries preserved but the worktree entry dropped, so the runner sees your worktree's tests. Jest takes repeatable `--testPathIgnorePatterns` flags that **replace** the config value, so pass the surviving entries explicitly:
   ```bash
   # jest: replace the config's ignore list, keeping everything EXCEPT /.claude/worktrees/
   npx jest --testPathIgnorePatterns='/node_modules/' --testPathIgnorePatterns='/functions/'
   ```
   The vitest / pytest / mocha equivalents differ (`vitest --exclude`, pytest `--override-ini`, mocha `--ignore`) — the principle is the same: override the config so the runner stops ignoring your own worktree. Confirm the re-run now reports a non-zero test count before trusting it.

2. **Bail loudly if you can't override.** If the runner has no clean override (or the override still reports zero tests), do NOT let the push ride the silent pass. Return:
   ```
   blocked: pre-push test runner silently passed — target repo's test config ignores worktree paths, local tests did not run
   ```
   This is option 3 from [#369](https://github.com/mattsears18/shipyard/issues/369): the smallest-signal response. It doesn't second-guess the target repo's config; it just refuses to launder a zero-test pass into a "tests pass locally" claim. CI will run the tests from a fresh (non-worktree) checkout, but bailing here saves the wasted iteration the orchestrator otherwise pays for.

**When NOT to worry about this.** Documentation-only diffs (no test files touched) legitimately produce a zero-test pass — that's not the failure mode. The tell is specifically a zero-test pass on a diff that *added or changed* test files. And the override (step 1) is only needed when the config actually ignores `/.claude/worktrees/`; most repos don't, and their runner finds your tests normally.
