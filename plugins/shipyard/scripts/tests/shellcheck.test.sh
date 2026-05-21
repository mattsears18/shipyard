#!/usr/bin/env bash
# Test: every shell script under plugins/ must pass `shellcheck` cleanly
# (warnings or higher fail the test). Mirrors the CI gate in
# .github/workflows/shellcheck.yml so a developer can run the same check
# locally before pushing.
#
# Rationale: see issue #102. Plugin shell scripts handle inputs the plugin
# treats as untrusted; a quoting / command-injection regression must not be
# allowed to land silently. The CI workflow is the primary gate; this test
# duplicates it so the local test harness (`shell-tests` job) also flags it.
#
# Skip behavior: if `shellcheck` is not installed locally, the test prints a
# warning and exits 0. CI installs shellcheck explicitly, so the gate still
# fires there. We don't want every contributor's local `bash *.test.sh` run
# to fail just because they haven't installed shellcheck yet.

set -u

GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'

# Locate the repo root by walking up from this test file until we find
# `.shellcheckrc` (or a `.git` directory as a fallback). We can't just rely on
# `git rev-parse` because the test must work inside CI's checkout AND inside
# nested worktrees.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$here"
while [[ "$repo_root" != "/" ]]; do
  if [[ -f "$repo_root/.shellcheckrc" || -d "$repo_root/.git" ]]; then
    break
  fi
  repo_root="$(dirname "$repo_root")"
done

if [[ "$repo_root" == "/" ]]; then
  printf '%sFAIL%s  could not locate repo root from %s\n' "$RED" "$RESET" "$here" >&2
  exit 1
fi

if ! command -v shellcheck >/dev/null 2>&1; then
  printf '%sSKIP%s  shellcheck not installed locally — CI will still gate this.\n' "$YELLOW" "$RESET"
  exit 0
fi

# Collect every *.sh under plugins/. Use a plain newline-delimited list (no
# `mapfile`) so the test works on macOS's bundled bash 3.2 too — none of the
# script paths contain whitespace, so newline splitting is safe.
scripts_list=$(cd "$repo_root" && find plugins -type f -name '*.sh' | sort)

if [[ -z "$scripts_list" ]]; then
  printf '%sFAIL%s  no shell scripts found under %s/plugins — find glob is broken.\n' \
    "$RED" "$RESET" "$repo_root" >&2
  exit 1
fi

count=$(printf '%s\n' "$scripts_list" | wc -l | tr -d ' ')
printf 'Linting %s script(s) under %s/plugins/:\n' "$count" "$repo_root"
printf '%s\n' "$scripts_list" | sed 's/^/  /'

# Run shellcheck on all scripts as a single invocation so it picks up the
# .shellcheckrc at $repo_root. `xargs -E ''` ensures we don't choke on
# unexpected EOF tokens; `-r` skips invocation when stdin is empty.
if printf '%s\n' "$scripts_list" | (cd "$repo_root" && xargs shellcheck); then
  printf '%sPASS%s  shellcheck clean across %s script(s).\n' \
    "$GREEN" "$RESET" "$count"
  exit 0
else
  printf '%sFAIL%s  shellcheck reported findings — see above.\n' "$RED" "$RESET" >&2
  exit 1
fi
