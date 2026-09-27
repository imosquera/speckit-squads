#!/usr/bin/env bun
// tdd preset: selftest-tdd.ts
// Self-contained test for check-tests-accompany.ts and jev-judge.ts. No test
// framework required.
//
// Usage: bun presets/tdd/scripts/ts/selftest-tdd.ts

import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

const HERE = import.meta.dir;
const CHECK = join(HERE, "check-tests-accompany.ts");
const JEV = join(HERE, "jev-judge.ts");
const WORK = mkdtempSync(join(tmpdir(), "selftest-tdd-"));
let failures = 0;

function report(ok: boolean, name: string, detail: string) {
  if (ok) console.log(`PASS: ${name}`);
  else { console.log(`FAIL: ${name} — ${detail}`); failures++; }
}

async function run(cmd: string[], opts: { cwd?: string; env?: Record<string, string | undefined> } = {}) {
  const p = Bun.spawn(cmd, { cwd: opts.cwd, env: { ...process.env, ...opts.env }, stdout: "pipe", stderr: "pipe" });
  const [out, err] = [await new Response(p.stdout).text(), await new Response(p.stderr).text()];
  return { code: await p.exited, out: out + err };
}

const git = (cwd: string, ...args: string[]) =>
  run(["git", "-c", "user.name=t", "-c", "user.email=t@t", ...args], { cwd });

// ------------------------------------------------- check-tests-accompany.ts
// A fresh repo on main, a feature branch, then the files: committed when
// prefixed "c:", untracked otherwise.
async function gate(name: string, want: number, ...files: string[]) {
  const dir = join(WORK, name);
  await run(["git", "init", "-q", "-b", "main", dir]);
  await git(dir, "commit", "-q", "--allow-empty", "-m", "base");
  await git(dir, "checkout", "-q", "-b", "feature");
  for (const f of files) {
    const p = f.replace(/^c:/, "");
    mkdirSync(join(dir, dirname(p)), { recursive: true });
    writeFileSync(join(dir, p), "x\n");
    if (f.startsWith("c:")) { await git(dir, "add", p); await git(dir, "commit", "-q", "-m", p); }
  }
  const r = await run(["bun", CHECK], { cwd: dir });
  report(r.code === want, name, `want rc=${want}, got rc=${r.code}\n    ${r.out.trim()}`);
}

await gate("empty", 4);
await gate("prod-only", 1, "src/app.py");
await gate("prod-committed-only", 1, "c:src/app.ts");
await gate("prod-and-pytest", 0, "src/app.py", "tests/test_app.py");
await gate("prod-and-jest", 0, "c:src/app.ts", "src/app.test.ts");
await gate("prod-and-go", 0, "pkg/x.go", "pkg/x_test.go");
await gate("prod-and-dunder", 0, "lib/a.js", "lib/__tests__/a.js");
await gate("tests-only", 0, "tests/test_new.py");
await gate("docs-only", 0, "README.md", "docs/guide.md");
await gate("config-only", 0, "package.json");
{
  // A bad --base is a usage error, never a pass.
  const r = await run(["bun", CHECK, "--base", "no-such-ref"], { cwd: join(WORK, "prod-only") });
  report(r.code === 2, "bad-base", `got rc=${r.code}`);
}

// ------------------------------------------------------------ jev-judge.ts
// Driven through the real SDK against a fake Jev (TYPESAFE_BASE_URL). The fake
// answers from the state it is sent, so each fixture checks the whole path:
// state built, request shaped, answer mapped to a decision and an exit code.
type Json = Record<string, any>;
let lastRequest: { auth: string | null; body: Json } | null = null;

const server = Bun.serve({
  port: 0,
  async fetch(req) {
    const body = (await req.json()) as Json;
    const auth = req.headers.get("authorization");
    lastRequest = { auth, body };
    if (auth !== "Bearer test-key") return new Response("{}", { status: 401 });
    const s = body.state, q = body.questions, text = JSON.stringify(s);
    if (text.includes("FORCE_400")) return new Response('{"error":"bad"}', { status: 400 });
    const choice = (pick: string, conf: number) => ({
      type: "choice", choice: pick, confidence: conf,
      probabilities: Object.fromEntries(Object.keys(q.red_reason.criteria).map(k => [k, k === pick ? conf : (1 - conf) / 3])),
    });
    let answers: Json;
    if (q.red_reason) {
      const out: string = s.suite_output, conf = text.includes("AMBIGUOUS") ? 0.5 : 0.93;
      answers = { red_reason: /SyntaxError|Cannot find module/.test(out) ? choice("harness_error", conf)
        : /\b0 fail/.test(out) ? choice("passes_immediately", conf)
        : /Expected/.test(out) ? choice("expected_red", conf) : choice("none_of_these", conf) };
    } else {
      const p = "baseline_run" in s ? (text.includes("AMBIGUOUS") ? 0.5 : s.baseline_run.includes("✓ totals") ? 0.95 : 0.05)
        : "scenario" in s ? (s.test.includes(s.scenario) ? 0.95 : 0.2)
        : s.path.endsWith(".md") ? 0.97 : 0.1;
      answers = { q: { type: "noul", noul: p } };
    }
    return Response.json({ model: "jev-fake", answers, usage: { input_tokens: 1, output_tokens: 1 } });
  },
});

const fixtures: Record<string, string> = {
  "t.test.ts": 'test("adds", () => expect(add(1, 2)).toBe(3));\n',
  "red.out": "error: Expected: 3\nReceived: undefined\n 0 pass\n 1 fail\n",
  "harness.out": "SyntaxError: Unexpected token ')'\n 0 pass\n 1 fail\n",
  "passes.out": " 1 pass\n 0 fail\n",
  "fail.out": "✗ totals > sums rows\n",
  "base-pass.out": "✓ totals > sums rows\n",
  "base-fail.out": "✗ totals > sums rows\n",
  "base-unsure.out": "AMBIGUOUS\n",
  "doc.diff": "+# Guide\n+Some prose.\n",
  "code.diff": "+export const f = (x: number) => x * 2;\n",
};
for (const [name, body] of Object.entries(fixtures)) writeFileSync(join(WORK, name), body);

const jevEnv = (extra: Record<string, string | undefined> = {}) =>
  ({ TYPESAFE_BASE_URL: server.url.origin, TYPESAFE_API_KEY: "test-key", ...extra });

async function jev(name: string, want: number, wantDecision: string | null | undefined,
                   extra: Record<string, string | undefined>, ...args: string[]) {
  const r = await run(["bun", JEV, ...args], { cwd: WORK, env: jevEnv(extra) });
  let decision: string | null | undefined;
  try { decision = JSON.parse(r.out).decision; } catch { decision = undefined; }
  report(r.code === want && decision === wantDecision && !r.out.includes("test-key"), `jev ${name}`,
    `want rc=${want} decision=${wantDecision}, got rc=${r.code} decision=${decision}\n    ${r.out.trim()}`);
}

const A = { TDD_JEV_AUTOMATE_RED: "1" };
const red = (out: string, scenario = "adds two numbers") =>
  ["red-reason", "--scenario", scenario, "--test", "t.test.ts", "--output", out];

// use case 1: the three Red fixtures, automated
await jev("red-real", 0, "expected_red", A, ...red("red.out"));
await jev("red-harness", 0, "harness_error", A, ...red("harness.out"));
await jev("red-passes", 0, "passes_immediately", A, ...red("passes.out"));
// ...and shadow mode (the default) and low confidence both fall back
await jev("red-shadow", 3, null, {}, ...red("red.out"));
await jev("red-lowconf", 3, null, A, ...red("red.out", "AMBIGUOUS"));
// use case 2: regression, baseline failure, undecided
await jev("base-regress", 0, "regression", {}, "baseline", "--failure", "fail.out", "--baseline", "base-pass.out");
await jev("base-known", 0, "baseline_failure", {}, "baseline", "--failure", "fail.out", "--baseline", "base-fail.out");
await jev("base-unsure", 3, null, {}, "baseline", "--failure", "fail.out", "--baseline", "base-unsure.out");
// use case 3: covered vs flagged
await jev("covers-yes", 0, "covered", {}, "covers", "--scenario", "adds", "--test", "t.test.ts");
await jev("covers-flag", 0, "flag", {}, "covers", "--scenario", "subtracts", "--test", "t.test.ts");
// use case 4: exemption accepted vs refused
await jev("exempt-doc", 0, "exempt", {}, "exempt", "--path", "docs/guide.md", "--diff", "doc.diff");
await jev("exempt-code", 0, "refused", {}, "exempt", "--path", "src/f.ts", "--diff", "code.diff");
// fallback path: no key, API error — the preset then behaves exactly as today
await jev("no-key", 3, null, { TYPESAFE_API_KEY: "" }, ...red("red.out", "s"));
await jev("api-error", 3, null, A, ...red("red.out", "FORCE_400"));
// a malformed call prints plain text, not a decision
await jev("bad-usage", 2, undefined, {}, "red-reason", "--scenario", "s");

// The request itself: key only in the header, none_of_these offered.
lastRequest = null;
await run(["bun", JEV, ...red("red.out", "s")], { cwd: WORK, env: jevEnv() });
const req = lastRequest as { auth: string | null; body: Json } | null;
report(!!req && req.auth === "Bearer test-key" && "none_of_these" in req.body.questions.red_reason.criteria
  && !JSON.stringify(req.body).includes("test-key"), "jev request shape", JSON.stringify(req));

// measure: agreement and confident share over past Red records
const rec = (output: string, label: string) =>
  JSON.stringify({ scenario: "adds", test: fixtures["t.test.ts"], output: fixtures[output], label });
writeFileSync(join(WORK, "records.jsonl"),
  [rec("red.out", "expected_red"), rec("harness.out", "harness_error"), rec("passes.out", "expected_red")].join("\n") + "\n");
{
  const r = await run(["bun", JEV, "measure", "--records", "records.jsonl"], { cwd: WORK, env: jevEnv() });
  let m: Json = {};
  try { m = JSON.parse(r.out); } catch { /* reported below */ }
  report(m.n === 3 && Math.round(m.agreement * 3) === 2 && m.share_confident === 1, "jev measure", r.out.trim());
}

server.stop(true);
rmSync(WORK, { recursive: true, force: true });
console.log(failures ? `${failures} failure(s)` : "all passed");
process.exit(failures ? 1 : 0);
