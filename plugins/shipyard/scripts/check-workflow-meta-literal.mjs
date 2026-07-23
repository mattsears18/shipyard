#!/usr/bin/env node
/*
 * check-workflow-meta-literal.mjs — assert a Dynamic Workflows script's
 * `export const meta = { ... }` header contains ONLY literal nodes.
 * ==========================================================================
 *
 * WHY THIS EXISTS (issue #809)
 * ----------------------------
 * The `Workflow` tool validates `meta` at the TOOL-CALL BOUNDARY, before the
 * script is ever executed, and rejects the entire script unless every node
 * inside the `meta` object is a literal — no variables, no function calls, no
 * spreads, no template interpolation, and (the trap that actually shipped) no
 * string concatenation. `'a' + 'b'` parses as a `BinaryExpression`, so a
 * `description` assembled from `+`-joined fragments is rejected with:
 *
 *   Invalid workflow script: meta must be a pure literal:
 *   non-literal node type in meta: BinaryExpression
 *
 * `node --check` PASSES on that form — the concatenation is perfectly valid
 * JavaScript — which is exactly why shipyard 4.0.0 through 4.0.3 shipped with
 * every `/shipyard:do-work` dispatch broken and zero CI signal. A grep for
 * `export const meta` would not have caught it either. Only something that
 * actually parses the object catches this class, hence this checker.
 *
 * WHAT IT DOES
 * ------------
 * Locates `export const meta =` in each file, then parses the value with a
 * self-contained recursive-descent parser whose grammar admits ONLY:
 *
 *   value    := StringLiteral | NumericLiteral | 'true' | 'false' | 'null'
 *             | ObjectLiteral | ArrayLiteral
 *   Object   := '{' ( Property ( ',' Property )* ','? )? '}'
 *   Property := ( Identifier | StringLiteral ) ':' value
 *   Array    := '[' ( value ( ',' value )* ','? )? ']'
 *
 * Anything outside that grammar — a `+`, a backtick, a bare identifier, a call,
 * a spread, a computed key, a shorthand property — is reported with the same
 * "non-literal node type in meta" vocabulary the real tool uses, plus a line
 * number. It also asserts `meta.name` and `meta.description` are present and are
 * non-empty string literals, since the tool requires both.
 *
 * Deliberately dependency-free: no acorn, no espree, no npm install. The repo's
 * CI is plain bash + jq + whatever node ships on the runner, and adding a parser
 * dependency to guard one object literal is a worse trade than 200 lines of
 * hand-rolled lexer. A no-substitution template literal (plain backticks with no
 * `${}`) is rejected too — it is a `TemplateLiteral` AST node rather than a
 * `Literal`, and the safe, unambiguous form is a single quoted string.
 *
 * USAGE
 *   node check-workflow-meta-literal.mjs <workflow.js> [<workflow.js> ...]
 *
 * EXIT CODES
 *   0  every file's `meta` is a pure literal with a valid name + description
 *   1  at least one file failed (diagnostics on stdout)
 *   2  usage error / unreadable file
 *
 * Consumed by scripts/tests/workflow-meta-pure-literal-809.test.sh, which also
 * runs it against deliberately-broken fixtures (including a byte-for-byte copy
 * of the #809 regression) to prove the checker actually fails on them.
 */

import { readFileSync } from 'node:fs'

const PUNCT = new Set(['{', '}', '[', ']', ':', ','])
const KEYWORD_LITERALS = new Set(['true', 'false', 'null'])

/** Human-readable AST-node name for a token that has no place in a pure literal. */
function nodeTypeFor(tok) {
  if (tok.type === 'op' && (tok.value === '+' || tok.value === '-' || tok.value === '*' ||
      tok.value === '/' || tok.value === '%' || tok.value === '?' || tok.value === '|' ||
      tok.value === '&')) {
    return 'BinaryExpression'
  }
  if (tok.type === 'op' && tok.value === '...') return 'SpreadElement'
  if (tok.type === 'op' && tok.value === '(') return 'CallExpression'
  if (tok.type === 'template') return 'TemplateLiteral'
  if (tok.type === 'ident') return 'Identifier'
  if (tok.type === 'eof') return 'UnexpectedEndOfInput'
  return 'UnexpectedToken'
}

function makeLexer(src, startPos) {
  let pos = startPos

  function lineOf(p) {
    let line = 1
    for (let i = 0; i < p && i < src.length; i++) if (src[i] === '\n') line++
    return line
  }

  function skipTrivia() {
    for (;;) {
      while (pos < src.length && /\s/.test(src[pos])) pos++
      if (src.startsWith('//', pos)) {
        const nl = src.indexOf('\n', pos)
        pos = nl === -1 ? src.length : nl + 1
        continue
      }
      if (src.startsWith('/*', pos)) {
        const end = src.indexOf('*/', pos + 2)
        pos = end === -1 ? src.length : end + 2
        continue
      }
      break
    }
  }

  function readString(quote) {
    const at = pos
    pos++ // opening quote
    let out = ''
    while (pos < src.length) {
      const ch = src[pos]
      if (ch === '\\') {
        // Escape sequences are part of a StringLiteral — consume the pair.
        out += src[pos + 1] ?? ''
        pos += 2
        continue
      }
      if (ch === quote) {
        pos++
        return { type: 'string', value: out, pos: at, line: lineOf(at) }
      }
      if (ch === '\n') break // unterminated single-line string
      out += ch
      pos++
    }
    return { type: 'bad', value: 'unterminated string', pos: at, line: lineOf(at) }
  }

  function next() {
    skipTrivia()
    if (pos >= src.length) return { type: 'eof', value: '', pos, line: lineOf(pos) }
    const at = pos
    const ch = src[pos]
    const line = lineOf(at)

    if (ch === "'" || ch === '"') return readString(ch)
    if (ch === '`') { pos++; return { type: 'template', value: '`', pos: at, line } }
    if (src.startsWith('...', pos)) { pos += 3; return { type: 'op', value: '...', pos: at, line } }
    if (PUNCT.has(ch)) { pos++; return { type: 'punct', value: ch, pos: at, line } }

    if (/[0-9]/.test(ch) || (ch === '.' && /[0-9]/.test(src[pos + 1] ?? ''))) {
      let out = ''
      while (pos < src.length && /[0-9a-zA-Z._]/.test(src[pos])) { out += src[pos]; pos++ }
      return { type: 'number', value: out, pos: at, line }
    }

    if (/[A-Za-z_$]/.test(ch)) {
      let out = ''
      while (pos < src.length && /[A-Za-z0-9_$]/.test(src[pos])) { out += src[pos]; pos++ }
      return { type: 'ident', value: out, pos: at, line }
    }

    pos++
    return { type: 'op', value: ch, pos: at, line }
  }

  return { next, lineOf, position: () => pos }
}

/**
 * Parse one pure-literal value. Pushes a diagnostic onto `errors` and returns
 * undefined on the first violation (fail fast — one clear message beats a
 * cascade of parser noise from a desynced stream).
 */
function parseValue(lex, path, errors) {
  const tok = lex.next()

  if (tok.type === 'string') return { kind: 'string', value: tok.value }
  if (tok.type === 'number') return { kind: 'number', value: tok.value }
  if (tok.type === 'ident' && KEYWORD_LITERALS.has(tok.value)) {
    return { kind: 'keyword', value: tok.value }
  }
  if (tok.type === 'punct' && tok.value === '{') return parseObject(lex, path, errors)
  if (tok.type === 'punct' && tok.value === '[') return parseArray(lex, path, errors)

  errors.push({
    line: tok.line,
    path,
    nodeType: nodeTypeFor(tok),
    detail: tok.type === 'ident'
      ? `bare identifier \`${tok.value}\` — only string/number/true/false/null/object/array literals are allowed`
      : tok.type === 'template'
        ? 'backtick template literal — use a single-quoted string literal instead (a template is a TemplateLiteral node, not a Literal, even with no ${} interpolation)'
        : `unexpected token \`${tok.value}\``,
  })
  return undefined
}

function parseArray(lex, path, errors) {
  const items = []
  for (;;) {
    // Peek for the empty/trailing-comma close by parsing a value and letting the
    // separator check below drive; handle `]` explicitly first via a save/restore
    // is unnecessary because parseValue would report it — so probe directly.
    const probe = lex.next()
    if (probe.type === 'punct' && probe.value === ']') return { kind: 'array', value: items }
    if (probe.type === 'string') items.push({ kind: 'string', value: probe.value })
    else if (probe.type === 'number') items.push({ kind: 'number', value: probe.value })
    else if (probe.type === 'ident' && KEYWORD_LITERALS.has(probe.value)) {
      items.push({ kind: 'keyword', value: probe.value })
    } else if (probe.type === 'punct' && probe.value === '{') {
      const v = parseObject(lex, `${path}[${items.length}]`, errors)
      if (errors.length) return undefined
      items.push(v)
    } else if (probe.type === 'punct' && probe.value === '[') {
      const v = parseArray(lex, `${path}[${items.length}]`, errors)
      if (errors.length) return undefined
      items.push(v)
    } else {
      errors.push({
        line: probe.line,
        path: `${path}[${items.length}]`,
        nodeType: nodeTypeFor(probe),
        detail: `unexpected token \`${probe.value}\` in array literal`,
      })
      return undefined
    }

    const sep = lex.next()
    if (sep.type === 'punct' && sep.value === ',') continue
    if (sep.type === 'punct' && sep.value === ']') return { kind: 'array', value: items }
    errors.push({
      line: sep.line,
      path: `${path}[${items.length - 1}]`,
      nodeType: nodeTypeFor(sep),
      detail: sep.value === '+'
        ? 'string concatenation — collapse it to ONE string literal; `+` parses as a BinaryExpression, which the Workflow tool rejects'
        : `expected \`,\` or \`]\` but found \`${sep.value}\``,
    })
    return undefined
  }
}

function parseObject(lex, path, errors) {
  const props = {}
  for (;;) {
    const keyTok = lex.next()
    if (keyTok.type === 'punct' && keyTok.value === '}') return { kind: 'object', value: props }

    let key
    if (keyTok.type === 'string') key = keyTok.value
    else if (keyTok.type === 'ident') key = keyTok.value
    else if (keyTok.type === 'number') key = keyTok.value
    else {
      errors.push({
        line: keyTok.line,
        path,
        nodeType: nodeTypeFor(keyTok),
        detail: keyTok.value === '...'
          ? 'object spread — `meta` must be written out literally, not composed from another object'
          : keyTok.value === '['
            ? 'computed property key — keys must be plain identifiers or string literals'
            : `unexpected token \`${keyTok.value}\` where a property key was expected`,
      })
      return undefined
    }

    const colon = lex.next()
    if (!(colon.type === 'punct' && colon.value === ':')) {
      errors.push({
        line: colon.line,
        path: `${path}.${key}`,
        nodeType: colon.value === '(' ? 'FunctionExpression' : nodeTypeFor(colon),
        detail: colon.value === '('
          ? 'method shorthand — `meta` may only contain literal values'
          : (colon.type === 'punct' && (colon.value === ',' || colon.value === '}'))
            ? 'shorthand property — write `key: <literal>` explicitly'
            : `expected \`:\` after property key but found \`${colon.value}\``,
      })
      return undefined
    }

    const value = parseValue(lex, `${path}.${key}`, errors)
    if (errors.length) return undefined
    props[key] = value

    const sep = lex.next()
    if (sep.type === 'punct' && sep.value === ',') continue
    if (sep.type === 'punct' && sep.value === '}') return { kind: 'object', value: props }
    errors.push({
      line: sep.line,
      path: `${path}.${key}`,
      nodeType: nodeTypeFor(sep),
      detail: sep.value === '+'
        ? 'string concatenation — collapse it to ONE string literal on one line; `+` parses as a BinaryExpression, which the Workflow tool rejects at the tool-call boundary (this is the exact #809 regression)'
        : `expected \`,\` or \`}\` after the property value but found \`${sep.value}\``,
    })
    return undefined
  }
}

/** Returns { ok, errors[], meta } for one file's source text. */
export function checkSource(src, label) {
  const errors = []
  // Anchor to a line-start declaration. `meta` is a top-level export, so it
  // always begins a line — and anchoring this way is what keeps the locator from
  // matching a `export const meta = { name, description }` example written inside
  // the file's own header comment (every line of which starts with ` * `).
  const m = /^[ \t]*export\s+const\s+meta\s*=/m.exec(src)
  if (!m) {
    return {
      ok: false,
      errors: [{ line: 0, path: 'meta', nodeType: 'MissingExport', detail: 'no top-level `export const meta = { ... }` declaration found (it must start its own line)' }],
      meta: undefined,
      label,
    }
  }

  const lex = makeLexer(src, m.index + m[0].length)
  const open = lex.next()
  if (!(open.type === 'punct' && open.value === '{')) {
    return {
      ok: false,
      errors: [{
        line: open.line,
        path: 'meta',
        nodeType: nodeTypeFor(open),
        detail: '`meta` must be an object literal written inline',
      }],
      meta: undefined,
      label,
    }
  }

  const meta = parseObject(lex, 'meta', errors)
  if (errors.length) return { ok: false, errors, meta: undefined, label }

  // The tool requires both fields, and both must be usable strings.
  for (const field of ['name', 'description']) {
    const v = meta.value[field]
    if (!v) {
      errors.push({ line: 0, path: `meta.${field}`, nodeType: 'MissingProperty', detail: `\`meta.${field}\` is required by the Workflow tool` })
    } else if (v.kind !== 'string' || v.value.trim() === '') {
      errors.push({ line: 0, path: `meta.${field}`, nodeType: 'InvalidProperty', detail: `\`meta.${field}\` must be a non-empty string literal` })
    }
  }

  return { ok: errors.length === 0, errors, meta, label }
}

// --------------------------------------------------------------------------
// CLI
// --------------------------------------------------------------------------
const isMain = process.argv[1] && import.meta.url === `file://${process.argv[1]}`
if (isMain) {
  const files = process.argv.slice(2)
  if (files.length === 0) {
    console.error('usage: check-workflow-meta-literal.mjs <workflow.js> [...]')
    process.exit(2)
  }

  let failed = 0
  for (const file of files) {
    let src
    try {
      src = readFileSync(file, 'utf8')
    } catch (err) {
      console.error(`error: cannot read ${file}: ${err.message}`)
      process.exit(2)
    }

    const result = checkSource(src, file)
    if (result.ok) {
      console.log(`OK    ${file}: meta is a pure literal (name + description present)`)
    } else {
      failed++
      for (const e of result.errors) {
        console.log(`FAIL  ${file}: meta must be a pure literal: non-literal node type in meta: ${e.nodeType}`)
        console.log(`        at ${e.path}${e.line ? ` (line ${e.line})` : ''}: ${e.detail}`)
      }
    }
  }

  process.exit(failed > 0 ? 1 : 0)
}
