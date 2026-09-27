#!/usr/bin/env bun
// diff-minimal preset: check-plan-scope.ts
// Body of check-plan-scope.sh, which owns usage checking and directory dedupe
// and calls this once per feature directory (already known to hold spec.md).
// See that script for the contract and exit codes.

import { existsSync, statSync } from "node:fs";
import { join } from "node:path";
import { S, heading, logicalLines, mustNotPaths, pathPattern, pyPath, readLines, strip } from "./scope-common.ts";

const arg = process.argv[2];
if (!arg) {
  console.error("usage: check-plan-scope.ts <feature-dir>");
  process.exit(2);
}
const feature = pyPath(arg);

const paths = mustNotPaths(readLines(join(arg, "spec.md")));
if (!paths.length) {
  console.log("diff-minimal: spec forbids no paths — nothing to check.");
  process.exit(0);
}

// A line that says "don't touch X" names X on purpose.
const NEGATION = new RegExp(
  (String.raw`must\s+not|do(es)?\s+not\s+(touch|modify|edit|change)|never\s+(touch|modify|edit)` +
    String.raw`|out\s+of\s+scope|forbidden|excluded|exclude|no\s+changes?\s+to|not\s+in\s+scope` +
    String.raw`|leave\s+(it\s+)?alone|untouched`).replaceAll(String.raw`\s`, S),
  "i",
);
// Whole sections that exist to restate the exclusions.
const EXEMPT_HEADING = /scope|non-goals?|out of scope|corrections|constraints/i;

const patterns = paths.map((p) => [p, pathPattern(p)] as const);
const violations: [name: string, n: number, listed: string, text: string][] = [];

for (const name of ["plan.md", "tasks.md", "quickstart.md", "research.md"]) {
  const path = join(arg, name);
  if (!existsSync(path) || !statSync(path).isFile()) continue;

  let exemptUntil: number | null = null; // heading level we are exempt beneath
  // Fold wrapped continuations before matching: these artifacts are prose, and
  // a restatement that wraps ("this file MUST NOT be / touched") lost its
  // negation on the physical line carrying the path and was reported as a
  // violation (issue #68). Headings still arrive as their own entries, so the
  // exempt-heading state machine below is unchanged.
  for (const [n, line] of logicalLines(readLines(path))) {
    const h = heading(line);
    if (h) {
      const [level, title] = h;
      if (exemptUntil !== null && level <= exemptUntil) exemptUntil = null;
      if (EXEMPT_HEADING.test(title)) exemptUntil = level;
      continue;
    }
    if (exemptUntil !== null) continue;
    if (NEGATION.test(line)) continue;
    for (const [listed, pat] of patterns) {
      if (pat.test(line)) {
        // A folded block can be a whole paragraph; keep the report readable.
        let text = strip(line);
        const cps = Array.from(text);
        if (cps.length > 200) text = cps.slice(0, 197).join("") + "...";
        violations.push([name, n, listed, text]);
        break;
      }
    }
  }
}

if (violations.length) {
  console.error("error: plan artifacts touch paths the spec put out of scope");
  for (const [name, n, listed, text] of violations) {
    console.error(`  ${feature}/${name}:${n}: forbidden by \`${listed}\``);
    console.error(`      ${text}`);
  }
  console.error(
    "\nEither remove the work from the plan, or — if the path is genuinely required —\n" +
      "amend `## Scope discipline` in spec.md and say so on the tracking issue.\n" +
      "Never widen the plan quietly.",
  );
  process.exit(1);
}

console.log(`diff-minimal: plan artifacts respect all ${paths.length} out-of-scope path(s).`);
