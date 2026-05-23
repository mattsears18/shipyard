---
description: Print the installed shipyard plugin version.
---

# /shipyard:version

Prints the `version` field from the installed plugin's `plugin.json`. One line, no flags. Answers "what version of shipyard am I running?" without grepping `~/.claude/plugins/installed_plugins.json`.

## What the assistant should do when this command runs

Run:

```bash
jq -r '.version' "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json"
```

Print stdout verbatim. If `jq` is unavailable or the file is missing, surface the error and stop — don't try to compute the version another way.

`${CLAUDE_PLUGIN_ROOT}` resolves to the *installed* plugin directory (under `~/.claude/plugins/cache/shipyard/shipyard/<version>/`), so the result reflects what's actually loaded — not whatever copy is checked out in a repo.

## Related

- [`/shipyard:update`](./update.md) — bump to the latest published version.
- [`CHANGELOG.md`](../../../CHANGELOG.md) — what's in each release.
