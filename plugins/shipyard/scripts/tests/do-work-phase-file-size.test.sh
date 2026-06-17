#!/usr/bin/env bash
# Test: no /shipyard:do-work phase file crosses the single-file Read size cap.
#
# Issue #611: the monolithic commands/do-work/setup.md grew to ~283KB, past
# the 256KB single-file `Read` limit — so the orchestrator (and any worker
# spawned to edit the spec) could no longer read its own primary phase file in
# one call. The fix split setup.md into a thin router + step-cluster sub-files
# under do-work/setup/. This guard is the regression tripwire: it fails CI the
# moment ANY phase file under commands/do-work/ crosses a conservative
# threshold (240KB) — well under the 256KB hard limit, so a file that's
# *approaching* the cliff reds the build while there's still headroom to split
# it, rather than after it's already un-readable.
#
# The 240KB threshold (not 256KB) is deliberate slack: markdown edits land
# incrementally, and a file at 250KB that a single PR pushes to 257KB would
# slip past a 256KB gate on the merge it crossed. 240KB gives ~16KB of warning
# room — roughly the size of one substantial new step — so the failure fires
# on the PR that *enters* the danger zone, not the one that breaches the limit.
#
# Discovery is glob-based (every *.md under commands/do-work/, recursively) so
# a newly-added phase file or setup sub-file is covered automatically with no
# edit to this test. CI auto-discovers this file via tests.yml's
# `find plugins -type f -name '*.test.sh'`, so no workflow edit is needed
# either.
#
# Pure bash, no external dependencies.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$here"
while [[ "$repo_root" != "/" ]]; do
  if [[ -d "$repo_root/.git" || -f "$repo_root/CHANGELOG.md" ]]; then
    break
  fi
  repo_root="$(dirname "$repo_root")"
done

if [[ "$repo_root" == "/" ]]; then
  echo "FAIL: could not locate repo root from $here" >&2
  exit 1
fi

phase_dir="$repo_root/plugins/shipyard/commands/do-work"

# Conservative cap, in bytes. 240KB < the 256KB single-file Read limit so a
# file that *approaches* the cliff reds the build with headroom to spare.
MAX_BYTES=$((240 * 1024))
# The hard limit this guard exists to keep files under — surfaced in failure
# output so the reader understands why 240KB (not some round 250KB) is the cap.
HARD_LIMIT_BYTES=$((256 * 1024))

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

if [[ ! -d "$phase_dir" ]]; then
  printf '%sFAIL%s  phase dir missing: %s\n' "$RED" "$RESET" "$phase_dir" >&2
  exit 1
fi

echo "do-work phase-file size guard (issue #611)"
echo "  cap: ${MAX_BYTES} bytes (240KB); hard Read limit: ${HARD_LIMIT_BYTES} bytes (256KB)"
echo

# Discover every markdown phase file under commands/do-work/ (recursively, so
# the setup/ sub-files are included). -print0 / read -d '' is safe against odd
# characters; sort for deterministic ordering.
files=()
while IFS= read -r -d '' f; do
  files+=("$f")
done < <(find "$phase_dir" -type f -name '*.md' -print0 | sort -z)

if [[ ${#files[@]} -eq 0 ]]; then
  printf '%sFAIL%s  no *.md phase files found under %s\n' "$RED" "$RESET" "$phase_dir" >&2
  exit 1
fi

for f in "${files[@]}"; do
  rel="${f#"$repo_root"/}"
  bytes=$(wc -c < "$f" | tr -d ' ')
  if (( bytes <= MAX_BYTES )); then
    printf '  %sPASS%s  %s (%d bytes <= %d)\n' "$GREEN" "$RESET" "$rel" "$bytes" "$MAX_BYTES"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (%d bytes > %d cap)\n' "$RED" "$RESET" "$rel" "$bytes" "$MAX_BYTES"
    printf '    This phase file is approaching the %d-byte (256KB) single-file Read limit.\n' "$HARD_LIMIT_BYTES"
    printf '    Split it into a thin router + step-cluster sub-files, mirroring the\n'
    printf '    do-work.md -> do-work/ and setup.md -> setup/ pattern (issue #611).\n'
    fail=$((fail+1))
  fi
done

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d phase file(s) over the size cap (%d under)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d phase file(s) under the %d-byte cap\n' "$GREEN" "$RESET" "$pass" "$MAX_BYTES"
  exit 0
fi
