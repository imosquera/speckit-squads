#!/usr/bin/env bun
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
 *
 * Runtime: bun. This file is typechecked by TypeScript 7 (`bun run typecheck`
 * at the speckit-squads root), but the compiler it *drives* is the consumer
 * project's TS 5.x, loaded dynamically — TS 7 has no JS compiler API. So
 * `typescript` is never imported statically; `TsApi` below types only the
 * surface this scanner touches.
 */

import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

// --- the slice of the TS 5.x compiler API this scanner uses -----------------

interface TsNode {
  kind: number;
  parent?: TsNode;
  getStart(sf?: TsSourceFile): number;
  getText(sf?: TsSourceFile): string;
}
interface TsSourceFile extends TsNode {
  getLineAndCharacterOfPosition(pos: number): { line: number; character: number };
}
interface TsIdentifier extends TsNode { text: string }
interface TsTyped extends TsNode { type?: TsNode }
interface TsCallExpression extends TsNode { expression: TsNode }
interface TsPropertyAccessExpression extends TsNode {
  expression: TsNode;
  name: TsIdentifier;
}
interface TsVariableDeclaration extends TsNode {
  name: TsNode;
  type?: TsNode;
  initializer?: TsNode;
}
interface TsFunctionLike extends TsNode { name?: TsNode; type?: TsNode }
interface TsTypeReferenceNode extends TsNode { typeName: TsNode }

interface TsApi {
  createSourceFile(
    fileName: string, text: string, target: number, setParentNodes?: boolean,
  ): TsSourceFile;
  forEachChild(node: TsNode, cb: (child: TsNode) => void): void;
  ScriptTarget: { Latest: number };
  SyntaxKind: {
    AnyKeyword: number;
    UnknownKeyword: number;
    BooleanKeyword: number;
    AsExpression: number;
    TypeAssertionExpression: number;
  };
  isCallExpression(n: TsNode): n is TsCallExpression;
  isPropertyAccessExpression(n: TsNode): n is TsPropertyAccessExpression;
  isIdentifier(n: TsNode): n is TsIdentifier;
  isVariableDeclaration(n: TsNode): n is TsVariableDeclaration;
  isFunctionDeclaration(n: TsNode): n is TsFunctionLike;
  isMethodDeclaration(n: TsNode): n is TsFunctionLike;
  isArrowFunction(n: TsNode): n is TsFunctionLike;
  isFunctionExpression(n: TsNode): n is TsFunctionLike;
  isTypeReferenceNode(n: TsNode): n is TsTypeReferenceNode;
}

interface JobFile { path: string; isParser?: unknown }
interface Finding { rule: string; path: string; line: number }

function fail(code: number, msg: string): never {
  process.stderr.write(msg + '\n');
  process.exit(code);
}

const errMsg = (e: unknown): string => (e instanceof Error ? e.message : String(e));

function hasApi(mod: unknown): mod is TsApi {
  return typeof mod === 'object' && mod !== null &&
    typeof (mod as { createSourceFile?: unknown }).createSourceFile === 'function';
}

function loadTypeScript(bases: string[]): TsApi | null {
  // Resolve `typescript` from the directory of each file being scanned first —
  // resolution walks up from there, so a monorepo package that carries its own
  // `node_modules/typescript` is found even though the driver runs from the
  // repo root (it must, for git paths). Then the cwd, then this helper.
  //
  // TypeScript 7 (the native compiler) ships no JS compiler API, so a copy
  // without `createSourceFile` is skipped, not returned: a package on TS 7
  // falls through to a TS 5 install further out, e.g. at the repo root.
  for (const base of bases) {
    try {
      const req = createRequire(path.join(base, '__pdv_resolve__.cjs'));
      const mod: unknown = req('typescript');
      if (hasApi(mod)) return mod;
    } catch { /* try next base */ }
  }
  try {
    const mod: unknown = createRequire(import.meta.url)('typescript');
    return hasApi(mod) ? mod : null;
  } catch { return null; }
}

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

function scanFile(ts: TsApi, file: JobFile, findings: Finding[]): void {
  let text: string;
  try {
    text = fs.readFileSync(file.path, 'utf8');
  } catch (e) {
    // Never skip silently: an unread file would drop out of the results and
    // read as a file with no findings.
    fail(3, 'pdv_ts_scan: cannot read ' + file.path + ': ' + errMsg(e));
  }
  const sf = ts.createSourceFile(
    file.path, text, ts.ScriptTarget.Latest, /* setParentNodes */ true);

  const lineOf = (node: TsNode): number =>
    sf.getLineAndCharacterOfPosition(node.getStart(sf)).line + 1;
  const add = (rule: string, node: TsNode): void => {
    findings.push({ rule, path: file.path, line: lineOf(node) });
  };
  const isUnknown = (t: TsNode | undefined): boolean =>
    !!t && t.kind === ts.SyntaxKind.UnknownKeyword;

  const checkValidator = (name: string, returnType: TsNode | undefined, node: TsNode): void => {
    if (name && returnType &&
        returnType.kind === ts.SyntaxKind.BooleanKeyword &&
        VALIDATOR.test(name)) {
      add('PDV003', node);
    }
  };

  const visit = (node: TsNode): void => {
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
        (!!p && p.kind === ts.SyntaxKind.AsExpression && isUnknown((p as TsTyped).type)) ||
        (!!p && ts.isVariableDeclaration(p) && isUnknown(p.type));
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
      let typeNode: TsNode | undefined;
      if (node.kind === ts.SyntaxKind.AsExpression ||
          node.kind === ts.SyntaxKind.TypeAssertionExpression) {
        typeNode = (node as TsTyped).type;
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

function main(): void {
  // Every path out of here that examined nothing exits non-zero. Printing
  // {"findings":[]} for a mis-invocation is what made a wrong call read
  // exactly like a clean scan.
  if (process.argv.length > 2) fail(2, STDIN_HINT);
  if (process.stdin.isTTY) fail(2, STDIN_HINT);

  let raw: string;
  try {
    raw = fs.readFileSync(0, 'utf8');
  } catch (e) {
    fail(2, 'pdv_ts_scan: cannot read stdin: ' + errMsg(e) + '\n' + STDIN_HINT);
  }
  if (!raw.trim()) fail(2, 'pdv_ts_scan: empty stdin.\n' + STDIN_HINT);

  let job: unknown;
  try {
    job = JSON.parse(raw);
  } catch (e) {
    fail(2, 'pdv_ts_scan: malformed JSON job on stdin: ' + errMsg(e) + '\n' +
            STDIN_HINT);
  }
  const rawFiles: unknown =
    typeof job === 'object' && job !== null ? (job as { files?: unknown }).files : undefined;
  if (!Array.isArray(rawFiles)) {
    fail(2, 'pdv_ts_scan: JSON job has no "files" array.\n' + STDIN_HINT);
  }
  if (rawFiles.length === 0) {
    fail(2, 'pdv_ts_scan: JSON job listed zero files — nothing was examined, ' +
            'which is not the same as a clean scan.');
  }

  const files: JobFile[] = [];
  const bases: string[] = [];
  for (const entry of rawFiles as unknown[]) {
    const p: unknown =
      typeof entry === 'object' && entry !== null ? (entry as { path?: unknown }).path : undefined;
    if (typeof p !== 'string') {
      fail(2, 'pdv_ts_scan: every entry of "files" needs a string "path".');
    }
    files.push({ path: p, isParser: (entry as { isParser?: unknown }).isParser });
    const dir = path.dirname(path.resolve(p));
    if (!bases.includes(dir)) bases.push(dir);
  }
  bases.push(process.cwd(), import.meta.dir);

  const ts = loadTypeScript(bases);
  if (!ts) {
    fail(3,
      'cannot scan TypeScript — no `typescript` install with a compiler API ' +
      'was found. TypeScript 7 ships none, so keep a TS 5.x install alongside ' +
      'it (e.g. `npm i -D typescript@5` at the repo root) so the parser can ' +
      'build an AST.');
  }

  const findings: Finding[] = [];
  for (const file of files) scanFile(ts, file, findings);
  process.stdout.write(JSON.stringify({ findings }));
}

main();
