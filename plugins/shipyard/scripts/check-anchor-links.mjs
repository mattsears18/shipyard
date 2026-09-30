#!/usr/bin/env node
/*
 * check-anchor-links.mjs — assert every relative markdown link in the
 * plugin's docs resolves to something real: a `[label](path#anchor)` /
 * `[label](#anchor)` link must resolve to a REAL heading in its target
 * file (GitHub's own anchor-slug algorithm), and a bare `[label](path)`
 * link with NO `#anchor` must resolve to a REAL file or directory on disk.
 * ==========================================================================
 *
 * WHY THIS EXISTS (issue #866, extended by issue #929)
 * -----------------------------------------------------
 * The `/do-work` phase docs cross-reference each other constantly —
 * `commands/do-work/*.md`, `agents/issue-worker/*.md`, and the
 * `skills/worker-preamble/*.md` fragments all link to specific subsections
 * of each other. Every one of those links is a HAND-MAINTAINED string that
 * has to track the target heading's exact GitHub-rendered slug. Nothing
 * mechanically enforced that the two stayed in sync, so anchors rotted
 * silently every time a heading was renamed, split, or moved to a
 * different file — issue #411 fixed 13 of these on 2026-05-31; #866 found
 * a fresh batch two months later, the same drift recurring because nothing
 * was checking for it in CI.
 *
 * Two throwaway Python GitHub-slug verifiers were independently written by
 * two different workers in the same session that produced #866 (one while
 * investigating PR #911, one for PR #912) — proof this check is needed
 * often enough to be worth committing once instead of reinventing per PR.
 *
 * Issue #929 found the sibling drift class: a BARE `[label](path)` link
 * with no `#anchor` at all — e.g. a stale `../../../../agents/...` that's
 * one `../` too deep — was explicitly OUT of this checker's declared scope
 * (step 3 below only ever looked at links carrying a `#anchor`). #929's own
 * repro is `06-scope-preflight.md:56`'s link to `issue-work.md`, resolving
 * one directory level too high after the file was moved during the same
 * doc-restructuring pass that produced #866's anchor rot. Rather than fix
 * that one link and leave the class unguarded, this checker now ALSO
 * validates that every bare relative-path link resolves to a real file or
 * directory on disk (step 3 below, second branch) — the same file-walking
 * and link-extraction machinery already built for the anchor check, so the
 * two validations can't drift out of sync the way two independent
 * implementations would (exactly the duplication hazard #866's own header
 * comment above warns about).
 *
 * WHAT IT DOES
 * ------------
 * Dependency-free (no eval/new Function, matching the convention
 * other spec-consistency checkers already use):
 *
 *   1. Walks every `.md` file under the given root path(s) (a directory is
 *      walked recursively; a bare file path is checked directly).
 *   2. For each file, extracts its ATX headings (`#` … `######`) — SKIPPING
 *      anything inside a fenced code block (``` or ~~~) so a bash-comment
 *      `#` or an illustrative link inside a code fence is never mistaken
 *      for real markdown — and computes each heading's GitHub-rendered
 *      anchor slug (see `githubSlug()` below for the exact algorithm,
 *      calibrated against real headings in this repo — see its own header
 *      comment for the worked example that validated it).
 *   3. Independently, walks every file's `[label](target)` links (again
 *      skipping fenced code and — via `maskCodeSpans()`, a proper
 *      CommonMark backtick-run matcher, NOT a naive `` `[^`]*` `` regex —
 *      inline code spans on the same line, including multi-backtick spans
 *      like `` ```` ```yaml ... ```` `` that wrap literal triple-backticks;
 *      the naive regex mis-paired those runs and silently swallowed real
 *      links after them, which is exactly why #929's own repro line went
 *      undetected until this fix). Every extracted link is then routed by
 *      whether its target carries a `#anchor`:
 *        - WITH an anchor: resolve the target file (same file when the
 *          path portion is empty; otherwise resolved relative to the
 *          SOURCE file's directory) and check the anchor against that
 *          file's heading-slug set from step 2.
 *        - WITHOUT an anchor (issue #929): resolve the target relative to
 *          the SOURCE file's directory and check it exists on disk as
 *          either a file or a directory. `https:`/`mailto:`/`tel:` and any
 *          other URI-scheme target (`^[a-zA-Z][a-zA-Z0-9+.-]*:`) is treated
 *          as external and skipped — only genuinely repo-relative paths
 *          are validated, so a legitimate external link never false-
 *          positives.
 *   4. A bold/italic list-item lead-in ("**4.6. Foo (issue #466).**") is
 *      NOT a heading — GitHub never generates an id for it — so a link
 *      pointing at its would-be slug correctly reports as unresolvable
 *      even though the text is clearly visible in the target file. This is
 *      deliberate: promoting bold lead-ins to headings is a documentation
 *      fix, not something this checker should paper over.
 *
 * Three distinct failure classes are reported, so a human can tell "the
 * anchor drifted" from "the whole file moved/was renamed" from "the bare
 * path itself is stale":
 *   - `missing-file`   — an anchor-carrying link's target file doesn't
 *                        exist at all.
 *   - `missing-anchor` — an anchor-carrying link's target file exists but
 *                        has no heading whose slug matches.
 *   - `broken-path`    — a bare (no-`#anchor`) relative-path link's target
 *                        doesn't exist on disk as a file or directory
 *                        (issue #929).
 *
 * USAGE
 *   node check-anchor-links.mjs <path> [<path> ...]
 *
 *   Each <path> is either a single `.md` file or a directory to walk
 *   recursively for `.md` files. At least one path is required.
 *
 * EXIT CODES
 *   0  every intra-repo link resolved (both #anchor links and bare
 *      relative-path links)
 *   1  one or more broken links found, of either class (diagnostics on
 *      stdout)
 *   2  usage error (no paths given, or a given path doesn't exist)
 *
 * Consumed by scripts/tests/anchor-links-866.test.sh (the anchor-slug
 * algorithm suite — unit-tests it against known real headings including
 * the exact #866 repro case, proves fenced-code and bold-lead-in false
 * positives are suppressed, proves a genuinely broken anchor is caught,
 * and runs this checker against the real `plugins/shipyard/**` + root
 * `CLAUDE.md` tree) and scripts/tests/relative-links-929.test.sh (the bare
 * relative-path suite — unit-tests the `broken-path` class, the
 * multi-backtick masking-fix regression, and re-runs the same real-tree
 * check to guard both classes of drift together).
 */

import fs from 'node:fs';
import path from 'node:path';

// --------------------------------------------------------------------------
// GitHub anchor-slug algorithm
// --------------------------------------------------------------------------
//
// GitHub derives a heading's anchor id from the heading's RENDERED text
// (markdown formatting resolved away — bold/italic/code-span markers and
// link syntax collapse to their inner text), not the raw source line. The
// pipeline below was validated against issue #866's own worked example
// (case 2): the heading
//
//   #### 5.b — Re-validate `scope-agent` and `cached-diagnosis` entries
//
// renders to the text "5.b — Re-validate scope-agent and cached-diagnosis
// entries", and GitHub's actual anchor for it is:
//
//   5b--re-validate-scope-agent-and-cached-diagnosis-entries
//
// Tracing that by hand: the "." in "5.b" and the em-dash "—" are stripped
// as punctuation (word chars, digits, spaces, hyphens, and underscores
// survive; everything else is deleted outright, NOT replaced with a
// space) — deleting the em-dash leaves the space on each side of it
// intact, so "5.b — Re" (with the em-dash removed) becomes "5b  Re" with
// TWO adjacent spaces; each space then becomes its own hyphen with no
// collapsing, producing the double-hyphen "5b--re-..." the real anchor
// shows. This double-hyphen behavior is the tell that GitHub's algorithm
// does NOT collapse whitespace before or after the space→hyphen step —
// getting that detail wrong is exactly the kind of subtle mismatch that
// makes a hand-rolled slugger produce false positives, which is why this
// header documents the derivation instead of just asserting the rule.
// Placeholder tokens used to stash inline code-span content while other
// inline transforms run (see renderInlineMarkdown below). MUST be a shape
// that can never appear verbatim in real heading prose -- a bare number
// surrounded by spaces (an earlier version of this used exactly that) is
// NOT safe: a genuine heading like "Dispatch rules (used by step 7 and
// step C)" contains that shape as real content, so the restore step
// mistook the "7" for a code-span index, read codeSpans[7] (out of
// bounds -> undefined), and spliced the literal string "undefined" into
// the slug -- caught against a real heading in this repo; see the
// regression fixture in the test suite. A NUL byte can never appear in a
// markdown source file's heading text, so wrapping the index in NUL
// bytes makes the token collision-proof regardless of heading wording.
const CODE_PLACEHOLDER_PREFIX = '\u0000CS\u0000';
const CODE_PLACEHOLDER_SUFFIX = '\u0000CE\u0000';

function renderInlineMarkdown(raw) {
  let text = raw;

  // Protect inline code spans FIRST — their literal content (which often
  // contains underscores, e.g. `scope_agent`) must never be run through
  // the italic-stripping regexes below, or `_reason_` inside
  // `defer_reason_class` would be misread as an emphasis span and
  // stripped. Stash each span's inner text and swap in a placeholder that
  // contains no markdown-special characters, then restore verbatim after
  // every other inline transform has run.
  const codeSpans = [];
  text = text.replace(/`([^`]+)`/g, (unused, inner) => {
    codeSpans.push(inner);
    return CODE_PLACEHOLDER_PREFIX + (codeSpans.length - 1) + CODE_PLACEHOLDER_SUFFIX;
  });

  // Images: ![alt](url) -> alt
  text = text.replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1');
  // Links: [text](url) -> text
  text = text.replace(/\[([^\]]*)\]\([^)]*\)/g, '$1');
  // Bold: **text** -> text (asterisk form has no intraword restriction in
  // CommonMark, and no heading in this repo uses a literal standalone `**`,
  // so the naive strip is safe).
  text = text.replace(/\*\*([^*]+)\*\*/g, '$1');
  // Bold/italic underscore forms (__text__ / _text_) DO have CommonMark's
  // intraword restriction — a `_` only opens/closes emphasis when it is
  // NOT adjacent to a word character on the outside. Without honoring that,
  // a literal snake_case identifier typed bare (no backticks) in a heading
  // — e.g. "why ci skip_speculative_rerun does not disable…" — would have
  // its underscores misread as emphasis markers and stripped, mangling the
  // slug (this was caught against a real heading in this repo; see the
  // regression fixture in the test suite). Code-span content is already
  // swapped out for placeholders above, so this restriction only needs to
  // protect BARE identifiers typed directly in heading text.
  text = text.replace(/(?<!\w)__(\S(?:[^_]*\S)?)__(?!\w)/g, '$1');
  text = text.replace(/(?<!\w)_(\S(?:[^_]*\S)?)_(?!\w)/g, '$1');
  // Italic asterisk form: *text* -> text.
  text = text.replace(/\*([^*]+)\*/g, '$1');
  // Strip any raw HTML tags (rare in headings, but cheap to handle).
  text = text.replace(/<[^>]+>/g, '');

  // Restore code-span content verbatim, AFTER emphasis-stripping, so its
  // underscores/asterisks are never treated as markdown syntax.
  const placeholderRe = new RegExp(
    CODE_PLACEHOLDER_PREFIX.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') +
      '(\\d+)' +
      CODE_PLACEHOLDER_SUFFIX.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'),
    'g'
  );
  text = text.replace(placeholderRe, (_, i) => codeSpans[Number(i)]);

  return text;
}

function githubSlug(headingText) {
  let slug = renderInlineMarkdown(headingText).toLowerCase();
  // Keep only letters, digits, spaces, hyphens, underscores — GitHub
  // deletes everything else outright (it does NOT substitute a space),
  // which is what produces the double-hyphen behavior documented above
  // when a deleted character had spaces on both sides.
  slug = slug.replace(/[^a-z0-9 _-]/g, '');
  // Each remaining space becomes its own hyphen — no collapsing.
  slug = slug.replace(/ /g, '-');
  return slug;
}

// --------------------------------------------------------------------------
// Per-file heading extraction (fence-aware)
// --------------------------------------------------------------------------

function isFenceLine(line) {
  return /^\s{0,3}(```+|~~~+)/.test(line);
}

// Explicit `<a id="...">` / `<a name="...">` anchor tags. GitHub renders
// raw HTML in markdown, so an explicit id/name attribute becomes a real
// link-fragment target directly — independent of the heading-slug
// algorithm entirely. This repo's docs use the pattern deliberately (e.g.
// `<a id="agent-console"></a>` in CLAUDE.md, `<a id="operator-pointer-
// line"></a>` in my-turn.md) specifically to hang a stable anchor off a
// bold list-item lead-in that isn't a real heading — exactly the case
// #866's own case 1/4 flags as unresolvable when the promotion DIDN'T
// happen. Ignoring these would false-positive on every one of them.
const EXPLICIT_ANCHOR_RE = /<a\s+(?:id|name)\s*=\s*["']([^"']+)["']/gi;

// Returns { slugs: Set<string>, headingLines: Map<string, number[]> } for
// one file's content — slugs is the full set of anchor ids GitHub would
// generate for this document: every ATX heading's rendered-text slug (with
// the -1/-2/... duplicate-heading suffix rule already applied) PLUS every
// explicit `<a id="...">`/`<a name="...">` target. headingLines maps each
// slug to the 1-indexed source line(s) it came from (for diagnostics only).
function extractHeadingSlugs(content) {
  const lines = content.split('\n');
  const slugs = new Set();
  const headingLines = new Map();
  const seenCount = new Map();
  let inFence = false;

  function record(slug, lineNo) {
    slugs.add(slug);
    const arr = headingLines.get(slug) ?? [];
    arr.push(lineNo);
    headingLines.set(slug, arr);
  }

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (isFenceLine(line)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;

    let m;
    EXPLICIT_ANCHOR_RE.lastIndex = 0;
    while ((m = EXPLICIT_ANCHOR_RE.exec(line)) !== null) {
      record(m[1], i + 1);
    }

    const headingMatch = /^ {0,3}(#{1,6})\s+(.*)$/.exec(line);
    if (!headingMatch) continue;

    let text = headingMatch[2].trim();
    // Strip a trailing closing-hash sequence: "## Foo ##" -> "Foo".
    text = text.replace(/\s+#+\s*$/, '');
    if (!text) continue;

    let base = githubSlug(text);
    if (!base) continue;

    const count = seenCount.get(base) ?? 0;
    const finalSlug = count === 0 ? base : `${base}-${count}`;
    seenCount.set(base, count + 1);

    record(finalSlug, i + 1);
  }

  return { slugs, headingLines };
}

// --------------------------------------------------------------------------
// Inline code-span masking (CommonMark backtick-run matching)
// --------------------------------------------------------------------------

// A naive `/`[^`]*`/g` mask (single-backtick pairing) mis-handles a line
// that contains a MULTI-backtick code span — CommonMark's actual rule is
// that a run of N backticks opens a code span, which stays open until the
// NEXT run of exactly N backticks. This repo's own docs deliberately use
// that (e.g. a 4-backtick span wrapping a literal 3-backtick fence example:
// `` ```` ```yaml .github/workflows/ci.yml ```` ``, from
// `06-scope-preflight.md`'s Detector 1 prose — the exact #929 repro line).
// The naive regex pairs backticks left-to-right without regard to run
// length, so on a line with an odd/mixed backtick count it can span clean
// across real markdown that follows — silently swallowing (and hence never
// checking) any real `[label](target)` link in that stretch. Found while
// building the #929 bare-path check: the checker's OWN masking was hiding
// the very link #929 reported, so `broken-path` would never have fired for
// it without this fix. Returns a same-length string with every matched
// code span (delimiters included) replaced by `x`, so character offsets
// used by callers to slice the ORIGINAL line stay valid; unmatched
// backticks (no closing run of the same length found) are left as literal
// characters, matching CommonMark's own fallback.
function maskCodeSpans(line) {
  let result = '';
  let i = 0;
  const n = line.length;
  while (i < n) {
    if (line[i] !== '`') {
      result += line[i];
      i++;
      continue;
    }
    let openEnd = i;
    while (openEnd < n && line[openEnd] === '`') openEnd++;
    const runLen = openEnd - i;

    let k = openEnd;
    let closeStart = -1;
    let closeEnd = -1;
    while (k < n) {
      if (line[k] !== '`') {
        k++;
        continue;
      }
      let l = k;
      while (l < n && line[l] === '`') l++;
      if (l - k === runLen) {
        closeStart = k;
        closeEnd = l;
        break;
      }
      k = l;
    }

    if (closeStart === -1) {
      // No matching close run — these backticks are literal, not a span.
      result += line.slice(i, openEnd);
      i = openEnd;
    } else {
      result += 'x'.repeat(closeEnd - i);
      i = closeEnd;
    }
  }
  return result;
}

// --------------------------------------------------------------------------
// Per-file link extraction (fence-aware, inline-code-aware)
// --------------------------------------------------------------------------

// Returns an array of { line, label, target } for every markdown link in
// the file, skipping fenced code blocks entirely and masking inline code
// spans on each surviving line first (so a doc that SHOWS example link
// syntax inside backticks, e.g. this very script's own header comment,
// is never mistaken for a real link to follow).
function extractLinks(content) {
  const lines = content.split('\n');
  const links = [];
  let inFence = false;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (isFenceLine(line)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;

    // Mask inline code spans (same length, so character offsets still line
    // up with the original) so link-shaped text inside backticks isn't
    // picked up as a real link — but locate matches against this masked
    // copy and then re-extract label/target from the ORIGINAL line at the
    // same offsets, so a link whose LABEL legitimately contains inline
    // code (e.g. `[`verify`](...)`) isn't reported with its label
    // replaced by placeholder x's in diagnostics. Uses maskCodeSpans(),
    // NOT a naive single-backtick regex — see that function's header for
    // why the naive form silently ate real links on a multi-backtick line.
    const masked = maskCodeSpans(line);

    const linkRe = /\[([^\]\n]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g;
    let m;
    while ((m = linkRe.exec(masked)) !== null) {
      const raw = line.slice(m.index, m.index + m[0].length);
      const rawMatch = /^\[([^\]\n]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)$/.exec(raw);
      const label = rawMatch ? rawMatch[1] : m[1];
      const target = rawMatch ? rawMatch[2] : m[2];
      links.push({ line: i + 1, label, target });
    }
  }

  return links;
}

// --------------------------------------------------------------------------
// File discovery
// --------------------------------------------------------------------------

function walkMarkdownFiles(root) {
  const stat = fs.statSync(root);
  if (stat.isFile()) {
    return root.endsWith('.md') ? [root] : [];
  }
  const out = [];
  const entries = fs.readdirSync(root, { withFileTypes: true });
  for (const entry of entries) {
    const full = path.join(root, entry.name);
    if (entry.isDirectory()) {
      out.push(...walkMarkdownFiles(full));
    } else if (entry.isFile() && entry.name.endsWith('.md')) {
      out.push(full);
    }
  }
  return out;
}

// --------------------------------------------------------------------------
// Main
// --------------------------------------------------------------------------

function main(argv) {
  if (argv.length === 0) {
    console.error('usage: node check-anchor-links.mjs <path> [<path> ...]');
    return 2;
  }

  const files = new Set();
  for (const p of argv) {
    if (!fs.existsSync(p)) {
      console.error(`error: path does not exist: ${p}`);
      return 2;
    }
    for (const f of walkMarkdownFiles(path.resolve(p))) {
      files.add(f);
    }
  }

  if (files.size === 0) {
    console.error('error: no .md files found under the given path(s)');
    return 2;
  }

  // Cache heading-slug extraction per resolved file path so a target
  // referenced by many source files is only parsed once.
  const headingCache = new Map();
  function headingsFor(absPath) {
    if (headingCache.has(absPath)) return headingCache.get(absPath);
    let result = null;
    if (fs.existsSync(absPath) && fs.statSync(absPath).isFile()) {
      const content = fs.readFileSync(absPath, 'utf8');
      result = extractHeadingSlugs(content);
    }
    headingCache.set(absPath, result);
    return result;
  }

  const problems = [];
  let anchorLinksChecked = 0;
  let pathLinksChecked = 0;

  // Any URI-scheme target (https:, mailto:, tel:, ftp:, etc.) is external —
  // never validated against the local filesystem. Generalized beyond the
  // original https:/mailto:/tel: allowlist so a future scheme in these docs
  // doesn't need a matching edit here; verified against every link target
  // in this repo's docs at the time of writing (issue #929) that no
  // genuinely repo-relative path collides with this pattern.
  const URI_SCHEME_RE = /^[a-zA-Z][a-zA-Z0-9+.-]*:/;

  for (const file of Array.from(files).sort()) {
    const content = fs.readFileSync(file, 'utf8');
    const links = extractLinks(content);

    for (const { line, label, target } of links) {
      if (!target) continue;
      if (URI_SCHEME_RE.test(target)) continue;

      const hashIdx = target.indexOf('#');

      if (hashIdx === -1) {
        // Bare relative-path link — no #anchor at all (issue #929). Resolve
        // it against the SOURCE file's directory and check it exists on
        // disk, as either a file or a directory (a link to a folder is
        // legitimate — several of this repo's docs link to `./setup/` /
        // `../agents/issue-worker/` etc.).
        pathLinksChecked++;
        const targetAbs = path.resolve(path.dirname(file), target);
        if (!fs.existsSync(targetAbs)) {
          problems.push({
            kind: 'broken-path',
            file,
            line,
            label,
            target,
            targetAbs,
          });
        }
        continue;
      }

      const rawPathPart = target.slice(0, hashIdx);
      const anchor = target.slice(hashIdx + 1);
      if (!anchor) continue; // bare trailing '#' — nothing to validate

      // Same-file anchor when the path portion is empty.
      const targetAbs = rawPathPart
        ? path.resolve(path.dirname(file), rawPathPart)
        : file;

      // Only .md targets have headings we can validate.
      if (!targetAbs.endsWith('.md')) continue;

      anchorLinksChecked++;
      const headings = headingsFor(targetAbs);

      if (!headings) {
        problems.push({
          kind: 'missing-file',
          file,
          line,
          label,
          target,
          targetAbs,
        });
        continue;
      }

      if (!headings.slugs.has(anchor)) {
        problems.push({
          kind: 'missing-anchor',
          file,
          line,
          label,
          target,
          targetAbs,
          anchor,
        });
      }
    }
  }

  const repoRootGuess = process.cwd();
  function rel(p) {
    return path.relative(repoRootGuess, p) || p;
  }

  if (problems.length === 0) {
    console.log(
      `check-anchor-links: OK — ${anchorLinksChecked} intra-repo #anchor link(s) and ${pathLinksChecked} bare relative-path link(s) checked across ${files.size} file(s), 0 broken.`
    );
    return 0;
  }

  console.log(
    `check-anchor-links: FOUND ${problems.length} broken link(s) (of ${anchorLinksChecked} #anchor link(s) + ${pathLinksChecked} bare relative-path link(s) checked across ${files.size} file(s)):\n`
  );
  for (const p of problems) {
    if (p.kind === 'missing-file') {
      console.log(
        `  ${rel(p.file)}:${p.line}: [${p.label}](${p.target}) -> target file does not exist: ${rel(p.targetAbs)}`
      );
    } else if (p.kind === 'broken-path') {
      console.log(
        `  ${rel(p.file)}:${p.line}: [${p.label}](${p.target}) -> target path does not exist: ${rel(p.targetAbs)}`
      );
    } else {
      console.log(
        `  ${rel(p.file)}:${p.line}: [${p.label}](${p.target}) -> '#${p.anchor}' does not match any heading in ${rel(p.targetAbs)}`
      );
    }
  }
  return 1;
}

const exitCode = main(process.argv.slice(2));
process.exit(exitCode);
