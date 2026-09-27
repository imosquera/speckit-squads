#!/usr/bin/env bun
// tdd preset: jev-judge.ts
// Answers the TDD cycle's bounded judgment calls with Jev (TypeSafe's System
// One model) through @typesafe-ai/sdk. The implementing agent still writes the
// tests and the code; this only replaces the classification pauses around them.
//
// Usage:
//   jev-judge.ts red-reason --scenario TEXT --test FILE --output FILE
//   jev-judge.ts baseline   --failure FILE --baseline FILE
//   jev-judge.ts covers     --scenario TEXT --test FILE
//   jev-judge.ts exempt     --path PATH --diff FILE
//   jev-judge.ts measure    --records FILE.jsonl
// FILE may be `-` for stdin (at most one per call).
//
// Prints one JSON line. Its `record` field is what goes in the per-scenario
// record, so a wrong auto-decision can be traced.
//
// Exit codes:
//   0  decided: act on `decision`
//   3  fall back to the preset's non-Jev behaviour, unchanged. No
//      TYPESAFE_API_KEY, no SDK, any API error, a low-confidence answer,
//      `none_of_these`, or red-reason in shadow mode (the default until
//      TDD_JEV_AUTOMATE_RED=1).
//   2  usage error
//
// The API key is read by the SDK from TYPESAFE_API_KEY and nowhere else. It is
// never printed, logged, or accepted as an argument.

import type { TypeSafeClient as Client } from "@typesafe-ai/sdk";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const SDK = "@typesafe-ai/sdk";
const DECIDE = 0.85; // at or above: automate. Below: today's behaviour.
const LIMIT = 8000; // chars per state field; keeps each call fast
const OK = 0, FALLBACK = 3, USAGE = 2;

type Out = {
  case: string;
  source: "jev" | "fallback";
  decision: string | null;
  answer?: string | number;
  confidence?: number;
  model?: string;
  reason?: string;
  record: string;
};

function emit(out: Out, code: number): never {
  process.stdout.write(JSON.stringify(out) + "\n");
  process.exit(code);
}

function usage(msg: string): never {
  process.stderr.write(`jev-judge: ${msg}\n`);
  process.exit(USAGE);
}

// ---------------------------------------------------------------- arguments
const [cmd, ...rest] = process.argv.slice(2);
const args: Record<string, string> = {};
for (let i = 0; i < rest.length; i += 2) {
  const k = rest[i], v = rest[i + 1];
  if (!k?.startsWith("--") || v === undefined) usage(`bad argument near ${k ?? "(end)"}`);
  args[k.slice(2)] = v;
}
let stdinUsed = false;
function need(name: string): string {
  const v = args[name];
  if (v === undefined || v === "") usage(`${cmd} needs --${name}`);
  return v;
}
function file(name: string, keep: "head" | "tail" = "head"): string {
  const p = need(name);
  if (p === "-") {
    if (stdinUsed) usage("only one argument may read stdin");
    stdinUsed = true;
  }
  let text: string;
  try {
    text = readFileSync(p === "-" ? 0 : p, "utf8");
  } catch (e) {
    usage(`cannot read --${name} ${p}: ${(e as Error).message}`);
  }
  if (text.length <= LIMIT) return text;
  return keep === "head" ? text.slice(0, LIMIT) + "\n…[truncated]" : "…[truncated]\n" + text.slice(-LIMIT);
}

// ---------------------------------------------------------------- the SDK
// Resolved at runtime, never bundled: the project's own copy, then the copy
// beside this script (the speckit-squads checkout), then the cache the
// preset's post-install.sh fills. None found is a fallback, not an error.
async function client(caseName: string): Promise<Client> {
  const fallback: (reason: string) => never = reason =>
    emit({ case: caseName, source: "fallback", decision: null, reason, record: `jev ${caseName}: unavailable (${reason})` }, FALLBACK);
  if (!process.env.TYPESAFE_API_KEY?.trim()) fallback("no TYPESAFE_API_KEY");
  const cache = join(process.env.XDG_CACHE_HOME || join(homedir(), ".cache"), "speckit-squads", "tdd-jev");
  let path: string | undefined;
  for (const base of [process.cwd(), dirname(import.meta.path), cache]) {
    try {
      path = Bun.resolveSync(SDK, base);
      break;
    } catch { /* next */ }
  }
  if (!path || !existsSync(path)) fallback(`${SDK} not installed`);
  try {
    const mod = (await import(path!)) as typeof import("@typesafe-ai/sdk");
    return new mod.TypeSafeClient({ timeout: 15_000, retry: { maxRetries: 1 } });
  } catch (e) {
    fallback(`sdk: ${(e as Error).message}`);
  }
}

async function ask<T>(caseName: string, run: (c: Client) => Promise<T>): Promise<T> {
  const c = await client(caseName);
  try {
    return await run(c);
  } catch (e) {
    const err = e as Error & { status?: number };
    const reason = `api error: ${err.name}${err.status ? ` ${err.status}` : ""}`;
    emit({ case: caseName, source: "fallback", decision: null, reason, record: `jev ${caseName}: ${reason}` }, FALLBACK);
  }
}

const pct = (x: number) => x.toFixed(2);

// ---------------------------------------------------------------- questions
// One bounded question per judgment. Every criterion is one sentence with no
// "and"/"or"; every Choice carries none_of_these.
const RED = {
  type: "choice" as const,
  instructions: "The new test in `test_source` was just run as part of the suite. Which option describes its result in `suite_output`?",
  criteria: {
    expected_red: "The test fails because the behavior it checks does not exist yet.",
    harness_error: "The test never reaches its assertions.",
    passes_immediately: "The test passes.",
    none_of_these: "No other option describes the result.",
  },
};

async function redReason(state: Record<string, string>) {
  const r = await ask("red_reason", c => c.systemOne({ state, questions: { red_reason: RED } }));
  return { model: r.model, ...r.answers.red_reason };
}

function noul(instructions: string, yes: string, no: string) {
  return { type: "noul" as const, instructions, criteria: { true: yes, false: no } };
}

async function yesNo(caseName: string, state: Record<string, string>, q: ReturnType<typeof noul>) {
  const r = await ask(caseName, c => c.systemOne({ state, questions: { q } }));
  return { model: r.model, p: r.answers.q.noul };
}

// ---------------------------------------------------------------- commands
switch (cmd) {
  case "red-reason": {
    const state = { scenario: need("scenario"), test_source: file("test"), suite_output: file("output", "tail") };
    const a = await redReason(state);
    const confident = a.confidence >= DECIDE && a.choice !== "none_of_these";
    const automate = process.env.TDD_JEV_AUTOMATE_RED === "1";
    const mode = !confident ? "fallback: low confidence" : automate ? "automated" : "shadow";
    emit({
      case: "red_reason", source: "jev", model: a.model, answer: a.choice, confidence: a.confidence,
      decision: confident && automate ? a.choice : null,
      record: `jev red_reason=${a.choice} conf=${pct(a.confidence)} (${mode})`,
    }, confident && automate ? OK : FALLBACK);
  }
  case "baseline": {
    const state = { failing_test_output: file("failure", "tail"), baseline_run: file("baseline", "tail") };
    const a = await yesNo("baseline", state, noul(
      "Was the test failing in `failing_test_output` passing in `baseline_run`?",
      "The baseline run shows this test passing.",
      "The baseline run shows this test failing."));
    const decision = a.p >= DECIDE ? "regression" : a.p <= 1 - DECIDE ? "baseline_failure" : null;
    emit({
      case: "baseline", source: "jev", model: a.model, answer: a.p, decision,
      record: `jev baseline p(passing_at_baseline)=${pct(a.p)} → ${decision ?? "fallback: undecided"}`,
    }, decision ? OK : FALLBACK);
  }
  case "covers": {
    const state = { scenario: need("scenario"), test: file("test") };
    const a = await yesNo("covers", state, noul(
      "Does `test` exercise `scenario`?",
      "The test checks the behavior the scenario describes.",
      "The test checks some other behavior."));
    const decision = a.p >= DECIDE ? "covered" : "flag";
    emit({
      case: "covers", source: "jev", model: a.model, answer: a.p, decision,
      record: `jev covers p=${pct(a.p)} → ${decision}`,
    }, OK);
  }
  case "exempt": {
    const state = { path: need("path"), diff: file("diff") };
    const a = await yesNo("exempt", state, noul(
      "Is the file at `path` untestable: docs, pure configuration, or generated output?",
      "The file holds no executable logic.",
      "The file holds logic a test could exercise."));
    const decision = a.p >= DECIDE ? "exempt" : "refused";
    emit({
      case: "exempt", source: "jev", model: a.model, answer: a.p, decision,
      record: `jev exempt ${state.path} p=${pct(a.p)} → ${decision}`,
    }, OK);
  }
  case "measure": {
    // Replays past Red records ({scenario, test, output, label} per line, label
    // one of RED's options) to decide whether red-reason may automate.
    const lines = file("records").split("\n").filter(l => l.trim());
    if (!lines.length) usage("--records holds no records");
    const labels = Object.keys(RED.criteria);
    let agree = 0, confident = 0, confidentAgree = 0;
    for (const [i, line] of lines.entries()) {
      let rec: { scenario?: unknown; test?: unknown; output?: unknown; label?: unknown };
      try { rec = JSON.parse(line); } catch { usage(`record ${i + 1} is not JSON`); }
      const { scenario, test, output, label } = rec;
      if (typeof scenario !== "string" || typeof test !== "string" || typeof output !== "string"
          || typeof label !== "string" || !labels.includes(label)) {
        usage(`record ${i + 1} needs string scenario, test, output and a label in ${labels.join("|")}`);
      }
      const a = await redReason({ scenario, test_source: test.slice(0, LIMIT), suite_output: output.slice(-LIMIT) });
      const hit = a.choice === label;
      if (hit) agree++;
      if (a.confidence >= DECIDE) { confident++; if (hit) confidentAgree++; }
    }
    const n = lines.length;
    process.stdout.write(JSON.stringify({
      case: "measure", n,
      agreement: agree / n,
      share_confident: confident / n,
      confident_agreement: confident ? confidentAgree / confident : null,
    }) + "\n");
    process.exit(OK);
  }
  default:
    usage(`unknown command ${cmd ?? "(none)"}; expected red-reason|baseline|covers|exempt|measure`);
}
