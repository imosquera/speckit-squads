#!/usr/bin/env bun
// Check for parse_dont_validate.ts's change-set handling:
//   1. the scan anchors at the git worktree root, even from a subdirectory;
//   2. --new-only subtracts findings that already reproduce on the base ref;
//   3. a scan that examined ZERO files never exits like a clean pass (issue #50):
//      bad flag, empty path, non-repo cwd and empty change set each exit non-zero,
//      and the bun helper refuses a job it cannot use;
//   4. vendored `.specify/` tooling is never reported as the project's findings.
// Usage: bun test-pdv-changeset.ts   (exit 0 pass, 1 fail)

import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, copyFileSync, appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = import.meta.dir;
const SCRIPT = join(ROOT, "presets/parse-dont-validate/scripts/ts/parse_dont_validate.ts");
const TS_HELPER = join(ROOT, "presets/parse-dont-validate/scripts/ts/pdv_ts_scan.ts");
const TMP = mkdtempSync(join(tmpdir(), "test-pdv-changeset-"));
const TSR = mkdtempSync(join(tmpdir(), "test-pdv-tsr-"));
process.on("exit", () => {
  rmSync(TMP, { recursive: true, force: true });
  rmSync(TSR, { recursive: true, force: true });
});
let fail = 0;

const indent = (s: string) => s.replace(/\n+$/, "").split("\n").map((l) => `       ${l}`).join("\n");
const bad = (msg: string, extra?: string) => {
  console.log(`  FAIL ${msg}`);
  if (extra !== undefined) console.log(indent(extra));
  fail = 1;
};
function check(name: string, want: number, got: number, extra: string) {
  if (want === got) console.log(`  ok   ${name}`);
  else bad(`${name} (expected exit ${want}, got ${got})`, extra);
}

/** Run a command; stdout and stderr together, as `2>&1` gave the bash test. */
function run(cmd: string[], cwd = TMP, stdin?: string) {
  const p = Bun.spawnSync(cmd, { cwd, stdin: stdin === undefined ? "ignore" : Buffer.from(stdin), stdout: "pipe", stderr: "pipe" });
  return { out: p.stdout.toString() + p.stderr.toString(), st: p.exitCode ?? -1 };
}
const pdv = (args: string[], cwd = TMP) => run(["bun", SCRIPT, ...args], cwd);
const git = (...args: string[]) => {
  const r = run(["git", ...args]);
  if (r.st !== 0) throw new Error(`git ${args.join(" ")} failed:\n${r.out}`);
};
const write = (rel: string, text: string) => {
  mkdirSync(join(TMP, rel, ".."), { recursive: true });
  writeFileSync(join(TMP, rel), text);
};

git("init", "-q", "-b", "main", ".");
git("config", "user.email", "t@t");
git("config", "user.name", "t");
// pre-existing finding on main
write("pkg/old.py", "from typing import Any\ndef handle(x: Any) -> None: ...\n");
git("add", "-A");
git("commit", "-qm", "base");

git("checkout", "-qb", "feature");
// new finding, committed, in a subdirectory
write("functions/src/new.py", "from typing import Any\ndef added(y: Any) -> None: ...\n");
// and a new finding touching the pre-existing file
appendFileSync(join(TMP, "pkg/old.py"), "def later(z: Any) -> None: ...\n");
// Spec Kit's installed tooling is vendored, never the project's findings
write(".specify/presets/x/scripts/ts/tool.ts", "export const v: any = 1;\n");
git("add", "-A");
git("commit", "-qm", "work");

console.log("test-pdv-changeset");
const FN = join(TMP, "functions");

let { out, st } = pdv(["scan", "--base", "main"], FN);
check("scan from a subdirectory sees the whole change set", 1, st, out);
for (const f of ["functions/src/new.py", "pkg/old.py"]) if (!out.includes(f)) bad(`missing ${f} in scan output`, out);
if (out.includes(".specify/")) bad("scan reported vendored .specify/ tooling");

({ out, st } = pdv(["scan", "--base", "main", "--new-only"], FN));
check("--new-only still fails on findings this branch added", 1, st, out);
if (!out.includes("def added")) bad("--new-only dropped a new finding");
if (out.includes("def handle")) bad("--new-only kept a pre-existing finding");
if (!out.includes("def later")) bad("--new-only dropped a new finding in a pre-existing file");
if (!out.includes("ignored 1 pre-existing")) bad("no pre-existing count reported", out);

// a branch that only shifts a pre-existing finding down: still reported by
// scan, still clean under --new-only (fingerprints ignore line numbers).
git("checkout", "-q", "main");
git("checkout", "-qb", "shuffle");
const old = readFileSync(join(TMP, "pkg/old.py"), "utf8");
writeFileSync(join(TMP, "pkg/old.py"), `# a comment\n${old.replace(/\n+$/, "")}`);
git("commit", "-qam", "shuffle");
({ out, st } = pdv(["scan", "--base", "main"]));
check("plain scan reports the shifted pre-existing finding", 1, st, out);
({ out, st } = pdv(["scan", "--base", "main", "--new-only"]));
check("--new-only is clean when the branch only moved existing code", 0, st, out);

// --- a scan that examined nothing is never a clean pass (issue #50)
git("checkout", "-q", "main");
git("checkout", "-qb", "empty");
write("docs/readme.md", "hello\n");
git("add", "-A");
git("commit", "-qm", "docs");

({ out, st } = pdv(["scan", "--base", "main", "--nwe-only"]));
check("a typo'd flag is a usage error, not a clean scan", 2, st, out);
if (!out.includes("unknown option")) bad("typo'd flag not named");

({ out, st } = pdv(["scan", "--base"]));
check("--base with no ref is a usage error", 2, st, out);

// `--base --new-only` used to consume the flag as the ref and exit 4.
({ out, st } = pdv(["scan", "--base", "--new-only"]));
check("--base followed by another option is a usage error", 2, st, out);
if (!out.includes("needs a ref argument")) bad("--base misuse not named", out);

({ out, st } = pdv(["scan", "--base=", "--new-only"]));
check("--base= with an empty ref is a usage error", 2, st, out);

({ out, st } = pdv(["scan", "nosuchfile.ts"]));
check("paths that resolve to nothing are a hard error", 3, st, out);

({ out, st } = pdv(["scan"], "/"));
check("no change set outside a git worktree is a hard error", 3, st, out);

({ out, st } = pdv(["scan", "--base", "main"]));
check("an empty change set exits 4, not 0", 4, st, out);
if (!out.includes("not a clean scan")) bad("empty change set not called out", out);

({ out, st } = run(["bun", TS_HELPER, "some/file.ts"], TMP, ""));
check("the bun helper refuses file arguments", 2, st, out);
if (out.includes("[]")) bad("helper printed an empty findings list");
({ out, st } = run(["bun", TS_HELPER], TMP, ""));
check("the bun helper refuses an empty job", 2, st, out);
({ out, st } = run(["bun", TS_HELPER], TMP, '{"files":[]}'));
check("the bun helper refuses a zero-file job", 2, st, out);

// --- the Python scanner (a tokenizer, not stdlib `ast`) keeps ast's rules
// Each expected `<line>:<rule>` is what the retired stdlib-`ast` scanner reported.
// Strings, comments, f-string literals and lambda params in defaults must not
// trip it; an f-string *expression* must.
console.log("Python scanner");
const PYF = join(TMP, "pyfix");
mkdirSync(PYF, { recursive: true });
writeFileSync(join(PYF, "svc.py"), `from typing import Any, cast
x: Any = 1
s: "Any" = "cast(int, y) json.loads(z)"  # Any cast(
def f(a: Any, cb=lambda p, q: Any, *r: typing.Any) -> bool: ...
def is_ok(v) -> (bool):
    return cast(int, v)
async def validate_it(v) -> bool: ...
def is_opt(v) -> Optional[bool]: ...
d = json.loads(raw); e = a.json.loads(raw)
g = (
    obj
    .cast(1)
)
h = f"{json.loads(raw)!r:>4} {{json.loads(no)}}"
if True: w: Any = 0
def cast(x): ...
k = cast(str, x)  # parse-dont-validate: allow PDV004 (boundary)
`);
copyFileSync(join(PYF, "svc.py"), join(PYF, "user_schema.py"));
const wants: [string, string][] = [
  ["svc.py", "2:PDV001 4:PDV001 5:PDV003 6:PDV004 7:PDV003 9:PDV002 11:PDV004 14:PDV002 15:PDV001"],
  ["user_schema.py", "2:PDV001 4:PDV001 5:PDV003 7:PDV003 15:PDV001"],
];
for (const [f, want] of wants) {
  const got = pdv(["scan", f], PYF)
    .out.split("\n")
    .flatMap((l) => {
      const m = /^[^ ]+\.py:([0-9]+): (PDV[0-9]+)/.exec(l);
      return m ? [`${m[1]}:${m[2]}`] : [];
    })
    .join(" ");
  if (got === want) console.log(`  ok   ${f} findings match ast's rule/line set`);
  else bad(`${f} findings`, `want: ${want}\ngot:  ${got}`);
}
writeFileSync(join(PYF, "bad.py"), "def broken(:\n  x = (1, 2\n");
({ out, st } = pdv(["scan", "bad.py"], PYF));
check("unparseable Python is a scan failure, not a clean file", 3, st, out);
if (!out.includes("cannot parse Python source")) bad("parse failure not named");

// --- the prompt's exit contract is internally consistent
// Every place that states the exit contract must carry the verified exit-4
// carve-out, or a docs-only run cannot satisfy all instructions at once.
const cmdLines = readFileSync(join(ROOT, "presets/parse-dont-validate/commands/speckit.implement.md"), "utf8").split("\n");
const has = (re: RegExp) => cmdLines.some((l) => re.test(l));
const cmdRule = (name: string, re: string) => {
  if (has(new RegExp(re, "i"))) console.log(`  ok   ${name}`);
  else bad(`${name} (no line matching /${re}/ in speckit.implement.md)`);
};
if (has(/Re-run `scan --new-only` until it exits zero\./)) bad("the rerun loop still demands exit zero with no exit-4 carve-out");
else console.log("  ok   the rerun loop admits the verified exit-4 case");
cmdRule("the rerun loop names exit 4", "exits zero, or exits .4.");
cmdRule("the failure policy names the exit-4 exception", "exit-.4. exception");
if (has(/^- Whether the parse-don.t-validate scan ran and that it exited zero\.$/))
  bad("the completion report still requires reporting a zero exit only");
else console.log("  ok   the completion report admits the verified exit-4 case");

// TypeScript 7 ships no JS compiler API (issue #113). A package on TS 7 must
// fall through to a TS 5 install further out; TS 7 alone must exit 3 with the
// install hint instead of crashing on a missing createSourceFile.
console.log("TypeScript 7 resolution");
mkdirSync(join(TSR, "node_modules/typescript"), { recursive: true });
mkdirSync(join(TSR, "pkg/node_modules/typescript"), { recursive: true });
writeFileSync(join(TSR, "pkg/node_modules/typescript/index.js"), 'module.exports = { version: "7.0.2" };\n');
writeFileSync(join(TSR, "node_modules/typescript/index.js"), `module.exports = {
  version: "5.9.3", ScriptTarget: { Latest: 99 }, SyntaxKind: {},
  // Proves this copy was picked; a real AST walk needs the real compiler.
  createSourceFile: () => { throw new Error("resolved-ts5"); },
};
`);
writeFileSync(join(TSR, "pkg/a.ts"), "export const x = 1;\n");
const job = '{"files":[{"path":"pkg/a.ts","parser":false}]}';
({ out } = run(["bun", TS_HELPER], TSR, job));
if (out.includes("resolved-ts5")) console.log("  ok   TS 7 in the package falls through to TS 5 at the root");
else bad("TS 7 in the package did not fall through to TS 5", out);
rmSync(join(TSR, "node_modules"), { recursive: true, force: true });
({ out, st } = run(["bun", TS_HELPER], TSR, job));
check("TS 7 alone exits 3", 3, st, out);
if (out.includes("TS 5.x")) console.log("  ok   the exit-3 message names the TS 5.x requirement");
else bad("the exit-3 message does not name the TS 5.x requirement", out);

console.log(fail === 0 ? "test-pdv-changeset: PASS" : "test-pdv-changeset: FAIL");
process.exit(fail);
