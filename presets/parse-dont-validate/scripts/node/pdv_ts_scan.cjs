#!/usr/bin/env node
/*
 * Parse, Don't Validate — TypeScript AST scanner.
 *
 * Uses the TypeScript Compiler API (`typescript`, resolved from the target
 * project) to walk a real AST — no regex. Reads a JSON job on stdin:
 *
 *     { "files": [ { "path": "src/user.ts", "isParser": false }, ... ] }
 *
 * and writes findings to stdout:
 *
 *     { "findings": [ { "rule": "PDV004", "path": "src/user.ts", "line": 12 }, ... ] }
 *
 * Waiver comments and result presentation are handled by the Python driver;
 * this helper only reports structural findings. It never prints an empty
 * findings list for an input it could not use: a missing/empty/malformed job,
 * file arguments (which it ignores), an unreadable source, or a TypeScript
 * compiler it cannot load all exit non-zero with a message on stderr. An empty
 * result and an empty input must not look alike.
 */
'use strict';

const fs = require('fs');
const path = require('path');
const { createRequire } = require('module');

function fail(code, msg) {
  process.stderr.write(msg + '\n');
  process.exit(code);
}

function loadTypeScript(bases) {
  // Resolve `typescript` from the directory of each file being scanned first —
  // Node walks up from there, so a monorepo package that carries its own
  // `node_modules/typescript` is found even though the driver runs from the
  // repo root (it must, for git paths). Then the cwd, then this helper.
  //
  // TypeScript 7 (the native compiler) ships no JS compiler API, so a copy
  // without `createSourceFile` is skipped, not returned: a package on TS 7
  // falls through to a TS 5 install further out, e.g. at the repo root.
  const hasApi = (mod) => mod && typeof mod.createSourceFile === 'function';
  for (const base of bases) {
    try {
      const req = createRequire(path.join(base, '__pdv_resolve__.cjs'));
      const mod = req('typescript');
      if (hasApi(mod)) return mod;
    } catch (_) { /* try next base */ }
  }
  try {
    const mod = require('typescript');
    return hasApi(mod) ? mod : null;
  } catch (_) { return null; }
}

let ts = null;

// Casts to these types are ordinary structural narrowing (built-ins, DOM/BOM,
// standard-library globals), NOT domain-brand forging — PDV004 ignores them.
// A cast to a project brand like `Email`/`UserId` is not in this set and still
// flags outside a parser module.
const IGNORE = new Set([
  // language / utility types
  'String', 'Number', 'Boolean', 'Array', 'Object', 'Record', 'Readonly',
  'Partial', 'Required', 'Pick', 'Omit', 'Promise', 'Error', 'Function',
  'Date', 'RegExp', 'Map', 'Set', 'WeakMap', 'WeakSet', 'Symbol', 'BigInt',
  'ArrayBuffer', 'DataView', 'Uint8Array', 'Int8Array', 'Uint16Array',
  'Uint32Array', 'Float32Array', 'Float64Array',
  // DOM / BOM / web-platform globals
  'Node', 'Element', 'Event', 'EventTarget', 'Document', 'Window', 'Text',
  'Blob', 'File', 'FormData', 'URL', 'URLSearchParams', 'Headers', 'Request',
  'Response', 'FileList', 'DataTransfer', 'MouseEvent', 'KeyboardEvent',
  'PointerEvent', 'FocusEvent', 'InputEvent', 'DragEvent', 'TouchEvent',
  'CustomEvent', 'ErrorEvent', 'MessageEvent', 'Storage', 'Location',
]);
// Whole families of platform types that are always structural narrowing.
const IGNORE_PREFIX = /^(HTML|SVG|CSS|WebGL|Audio|Video|Media|Canvas|RTCP?|IDB)/;
const VALIDATOR = /^(is[A-Z]\w*|validate\w*|checkValid\w*)$/;

function scanFile(file, findings) {
  let text;
  try {
    text = fs.readFileSync(file.path, 'utf8');
  } catch (e) {
    // Never skip silently: an unread file would drop out of the results and
    // read as a file with no findings.
    fail(3, 'pdv_ts_scan: cannot read ' + file.path + ': ' + e.message);
  }
  const sf = ts.createSourceFile(
    file.path, text, ts.ScriptTarget.Latest, /* setParentNodes */ true);

  const lineOf = (node) =>
    sf.getLineAndCharacterOfPosition(node.getStart(sf)).line + 1;
  const add = (rule, node) =>
    findings.push({ rule, path: file.path, line: lineOf(node) });
  const isUnknown = (t) => t && t.kind === ts.SyntaxKind.UnknownKeyword;

  const checkValidator = (name, returnType, node) => {
    if (name && returnType &&
        returnType.kind === ts.SyntaxKind.BooleanKeyword &&
        VALIDATOR.test(name)) {
      add('PDV003', node);
    }
  };

  const visit = (node) => {
    // PDV001 — the `any` type, wherever it appears (`: any`, `as any`, `T<any>`).
    if (node.kind === ts.SyntaxKind.AnyKeyword) add('PDV001', node);

    // PDV002 — JSON.parse whose result is not immediately typed `unknown`.
    if (ts.isCallExpression(node) &&
        ts.isPropertyAccessExpression(node.expression) &&
        ts.isIdentifier(node.expression.expression) &&
        node.expression.expression.text === 'JSON' &&
        node.expression.name.text === 'parse') {
      const p = node.parent;
      const typedUnknown =
        (p && p.kind === ts.SyntaxKind.AsExpression && isUnknown(p.type)) ||
        (p && ts.isVariableDeclaration(p) && isUnknown(p.type));
      if (!typedUnknown) add('PDV002', node);
    }

    // PDV003 — boolean validator (function decl, method, or arrow/fn expr).
    if ((ts.isFunctionDeclaration(node) || ts.isMethodDeclaration(node)) && node.name) {
      checkValidator(node.name.getText(sf), node.type, node.name);
    }
    if (ts.isVariableDeclaration(node) && node.name && node.initializer &&
        (ts.isArrowFunction(node.initializer) || ts.isFunctionExpression(node.initializer))) {
      checkValidator(node.name.getText(sf), node.initializer.type, node.name);
    }

    // PDV004 — brand cast (`x as Brand` / `<Brand>x`) outside a parser module.
    if (!file.isParser) {
      let typeNode = null;
      if (node.kind === ts.SyntaxKind.AsExpression ||
          node.kind === ts.SyntaxKind.TypeAssertionExpression) {
        typeNode = node.type;
      }
      if (typeNode && ts.isTypeReferenceNode(typeNode) &&
          ts.isIdentifier(typeNode.typeName)) {
        const name = typeNode.typeName.text;
        if (!IGNORE.has(name) && !IGNORE_PREFIX.test(name)) {
          add('PDV004', node);
        }
      }
    }

    ts.forEachChild(node, visit);
  };
  visit(sf);
}

const STDIN_HINT =
  'pdv_ts_scan reads a JSON job on stdin — {"files":[{"path":"src/a.ts",' +
  '"isParser":false}]} — and ignores file arguments. It is not the entry ' +
  'point: run `parse_dont_validate.py scan` instead.';

function main() {
  // Every path out of here that examined nothing exits non-zero. Printing
  // {"findings":[]} for a mis-invocation is what made a wrong call read
  // exactly like a clean scan.
  if (process.argv.length > 2) fail(2, STDIN_HINT);
  if (process.stdin.isTTY) fail(2, STDIN_HINT);

  let raw;
  try {
    raw = fs.readFileSync(0, 'utf8');
  } catch (e) {
    fail(2, 'pdv_ts_scan: cannot read stdin: ' + e.message + '\n' + STDIN_HINT);
  }
  if (!raw.trim()) fail(2, 'pdv_ts_scan: empty stdin.\n' + STDIN_HINT);

  let job;
  try {
    job = JSON.parse(raw);
  } catch (e) {
    fail(2, 'pdv_ts_scan: malformed JSON job on stdin: ' + e.message + '\n' +
            STDIN_HINT);
  }
  const files = Array.isArray(job.files) ? job.files : null;
  if (!files) fail(2, 'pdv_ts_scan: JSON job has no "files" array.\n' + STDIN_HINT);
  if (files.length === 0) {
    fail(2, 'pdv_ts_scan: JSON job listed zero files — nothing was examined, ' +
            'which is not the same as a clean scan.');
  }

  const bases = [];
  for (const file of files) {
    if (!file || typeof file.path !== 'string') {
      fail(2, 'pdv_ts_scan: every entry of "files" needs a string "path".');
    }
    const dir = path.dirname(path.resolve(file.path));
    if (!bases.includes(dir)) bases.push(dir);
  }
  bases.push(process.cwd(), __dirname);

  ts = loadTypeScript(bases);
  if (!ts) {
    fail(3,
      'cannot scan TypeScript — no `typescript` install with a compiler API ' +
      'was found. TypeScript 7 ships none, so keep a TS 5.x install alongside ' +
      'it (e.g. `npm i -D typescript@5` at the repo root) so the parser can ' +
      'build an AST.');
  }

  const findings = [];
  for (const file of files) scanFile(file, findings);
  process.stdout.write(JSON.stringify({ findings }));
}

main();
