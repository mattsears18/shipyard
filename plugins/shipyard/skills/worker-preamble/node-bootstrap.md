# Worker-preamble fragment — Node dependency bootstrap + hook/test silent-pass gates

On-demand fragment of the `shipyard:worker-preamble` skill (see [`SKILL.md`](./SKILL.md)). Load this when a worker mode runs the **target repo's** local tests / pre-push hooks before pushing — primarily against Node-based or self-hosting target repos. It carries the three silent-quality-gate-bypass guards: missing `node_modules` (#316), non-executable husky hooks (#459), and a test runner that ignores the worktree path (#369). The per-mode specs under `agents/issue-worker/` point here by name (`worker-preamble § "Dependency-bootstrap check for Node-based target repos"`, `§ "Husky / core.hooksPath hooks silently skipped on a missing exec bit"`, `§ "Test-runner silent-pass when the target repo ignores worktree paths"`).

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
