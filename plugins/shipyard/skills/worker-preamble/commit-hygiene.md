# Worker-preamble fragment — Pre-commit hygiene (escape symlinks)

On-demand fragment of the `shipyard:worker-preamble` skill (see [`SKILL.md`](./SKILL.md)). Load this when a worker mode created the `node_modules → ../../../node_modules` bootstrap symlink (see [`node-bootstrap.md`](./node-bootstrap.md)) and must avoid staging it into a commit. The per-mode specs under `agents/issue-worker/` point here by name (`worker-preamble § "Pre-commit hygiene — escape symlinks"`).

## Pre-commit hygiene — escape symlinks

A companion failure mode to the dependency-bootstrap symlink ([#351](https://github.com/mattsears18/shipyard/issues/351)): the worker creates `node_modules → ../../../node_modules` per the bootstrap rules (see [`node-bootstrap.md`](./node-bootstrap.md)), then accidentally stages it into a commit via a stray `git add -A`, a misclick on `git add node_modules`, or path globbing that happens to include the symlink. The committed `120000` symlink mode rides into the commit and stays dangerous forever — when a downstream consumer cherry-picks the commit onto a different checkout depth, `../../../node_modules` resolves to a different (or non-existent) path. The salvage cost is a follow-up `fix(repo): remove stray node_modules symlink from cherry-pick` commit on the receiving end; the prevention cost is zero if you follow the symlink-creation hygiene in the dependency-bootstrap fragment.

The `refuse-escape-symlink-commit.sh` hook (registered as PreToolUse → Bash in `hooks.json`) is the load-bearing enforcement. It refuses any Bash `git commit` invocation whose staged file set includes a symlink whose target either starts with `/` or contains a literal `..` path segment. The hook's stderr explains the failure mode and the fix; do NOT bypass it.

If you genuinely need to commit a symlink with `../` in the target (rare — and a strong signal to re-think the design), return `blocked:` so a human can decide. The hook intentionally has no bypass flag, paralleling the no-`--no-verify` rule for commit hooks.
