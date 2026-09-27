#!/usr/bin/env bun
// Install every extension and preset in this repo into a Spec Kit project via
// `specify ... add --dev`. --dev COPIES the directory (no symlink), so edits here
// are not live: re-run with --force after changing anything to refresh the target.
//
// Every extension and every language-neutral preset always installs. The paired
// language presets are opt-in: --ts installs the TypeScript ones, --ios the Swift
// (`X-ios`) ones, both flags both sets (a mixed project, e.g. an Xcode app with a
// TypeScript backend); see selectPresets() in scripts/manifest.ts.
//
// Usage: ./install.ts [--force] [--ts] [--ios] <project-dir>
import { existsSync, readdirSync, statSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { KINDS, type Stack, cmp, manifests, presetPriority, selectPresets } from "./scripts/manifest.ts";

const REPO_DIR = import.meta.dir;
const BUN = process.execPath;
const ME = basename(process.argv[1] ?? "install.ts");
const USAGE = `usage: ${ME} [--force|-f] [--ts] [--ios] <project-dir>
  --ts        install the TypeScript presets
  --ios       install the Swift presets
  --ts --ios  install both sets, for a mixed project
  neither     only the language-neutral extensions and presets`;

const usageError = (msg: string): never => {
  console.error(`error: ${msg}`);
  console.error(USAGE);
  process.exit(2);
};

let force = false;
let tsFlag = false;
let iosFlag = false;
let projectArg = "";
for (const arg of process.argv.slice(2)) {
  if (arg === "-h" || arg === "--help") {
    console.log(USAGE);
    process.exit(0);
  } else if (arg === "-f" || arg === "--force") {
    force = true;
  } else if (arg === "--ts") {
    tsFlag = true;
  } else if (arg === "--ios") {
    iosFlag = true;
  } else if (arg.startsWith("-")) {
    usageError(`unknown flag: ${arg}`);
  } else {
    if (projectArg) usageError("only one project-dir may be given");
    projectArg = arg;
  }
}
if (!projectArg) {
  console.error(USAGE);
  process.exit(2);
}

const isDir = (p: string): boolean => {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
};
if (!isDir(join(projectArg, ".specify"))) {
  console.error(`error: ${projectArg} is not a Spec Kit project (.specify/ missing)`);
  process.exit(1);
}
const PROJECT_DIR = resolve(projectArg);
process.chdir(PROJECT_DIR);
// ponytail: no "bun on PATH" check — this file already runs under bun.

// No flag installs only the language-neutral items: every extension, and the
// presets that are not one member of a TypeScript/Swift pair.
const STACK: Stack = tsFlag && iosFlag ? "both" : tsFlag ? "ts" : iosFlag ? "ios" : "none";
console.log(`==> stack: ${STACK === "none" ? "language-neutral only (pass --ts and/or --ios for the language presets)" : STACK}`);

// Pre-flight: CLI verbs, script paths, typecheck.
if (Bun.spawnSync([BUN, join(REPO_DIR, "check-cli-usage.ts")], { stdio: ["inherit", "inherit", "inherit"] }).exitCode !== 0)
  process.exit(1);


// ORDERING CONTRACT for /speckit-implement (issue #25). `specify` resolves a command
// by (priority ASC, id ASC); the highest-precedence `wrap` composes outermost, and
// the nearest `replace` is the base. explicit-task-dependencies (the `replace`
// executor) must sort last, or it swallows the wrappers. Load-bearing numbers:
//   5 worktree-isolation (the cd precedes every write), 7 progress-report,
//   8 implement-prelude-skills, 9 parse-dont-validate (also orders the
//   /speckit-constitution pair), 11 tdd, 20 explicit-task-dependencies.
// Everything else installs at the CLI default of 10. An `X-ios` preset takes X's
// number (presetPriority), so tdd-ios is 11 and parse-dont-validate-ios is 9.
const PRIORITY: Record<string, number> = {
  "worktree-isolation": 5,
  "progress-report": 7,
  "implement-prelude-skills": 8,
  "ponytail-plan": 8, // speckit.plan only: outside library-research (10) and parse-dont-validate (9)
  "parse-dont-validate": 9,
  tdd: 11, // Red-Green-Refactor hugs the implementation, inside pdv
  "explicit-task-dependencies": 20,
};

/** `yes | specify <args> 2>&1`: combined output and specify's own exit code. */
function specify(args: string[]): { out: string; rc: number } {
  const r = Bun.spawnSync(["sh", "-c", 'yes | "$@" 2>&1', "sh", "specify", ...args], { stdout: "pipe", stderr: "inherit" });
  return { out: r.stdout.toString().replace(/\n+$/, ""), rc: r.exitCode ?? 1 };
}

/** Indent specify's output 4 spaces, to stderr. */
const indentErr = (out: string): void => {
  process.stderr.write(out.split("\n").map((l) => `    ${l}`).join("\n") + "\n");
};

function installOne(kind: string, name: string, src: string, priority?: number): boolean {
  const prio = priority === undefined ? [] : ["--priority", String(priority)];
  const add = specify([kind, "add", "--dev", src, ...prio]);
  if (add.rc === 0) {
    console.log("  installed");
    return true;
  }
  if (!add.out.includes("already installed")) {
    console.log("  FAILED:");
    indentErr(add.out);
    return false;
  }
  if (!force) {
    // A --dev registration is a stale snapshot with whatever priority it had.
    console.log("  already installed (stale snapshot; use --force to refresh)");
    return true;
  }
  const rm = specify([kind, "remove", name]);
  if (rm.rc !== 0 && !/not installed|not found|unknown/i.test(rm.out)) {
    console.log("  FAILED during remove:");
    indentErr(rm.out);
    return false;
  }
  const re = specify([kind, "add", "--dev", src, ...prio]);
  if (re.rc === 0) {
    console.log("  reinstalled (--force refresh)");
    return true;
  }
  console.log("  FAILED during re-add:");
  indentErr(re.out);
  return false;
}

/**
 * --force only: de-register the other member of a TypeScript/iOS pair if it is installed,
 * so switching stacks never leaves both wrappers of one command in place. Never
 * called for "both", which has no counterparts.
 */
function removeCounterpart(other: string): boolean {
  if (!isDir(join(".specify/presets", other))) return true;
  const rm = specify(["preset", "remove", other]);
  if (rm.rc === 0 || /not installed|not found|unknown/i.test(rm.out)) {
    console.log(`  removed ${other} (other stack's counterpart)`);
    return true;
  }
  console.log(`  FAILED removing ${other}:`);
  indentErr(rm.out);
  return false;
}

let exit = 0;
const skipped = new Set<string>(); // presets of the other stack: no post-install either
for (const [kind, manifest] of KINDS) {
  const ids = manifests(REPO_DIR, kind, manifest).map((m) => m.id);
  if (kind === "extensions") {
    for (const id of ids) {
      console.log(`==> extension: ${id}`);
      if (!installOne("extension", id, join(REPO_DIR, kind, id) + "/")) exit = 1;
    }
    continue;
  }
  const { install, skip, counterpart } = selectPresets(ids, STACK);
  for (const id of skip) skipped.add(id);
  // ts skips the iOS set, ios the TypeScript set, both skips nothing.
  if (skip.length) console.log(`==> skipping presets (stack ${STACK}): ${skip.join(", ")}`);
  // A skip never uninstalls: language presets from an earlier --ts/--ios run stay,
  // as the stale snapshot they are, until an install with the flag refreshes them.
  const stale = skip.filter((id) => isDir(join(".specify/presets", id)));
  if (stale.length) console.log(`  note: already installed, left as is and not refreshed: ${stale.join(", ")} (pass --ts/--ios to refresh)`);
  for (const id of install) {
    const prio = presetPriority(PRIORITY, id);
    console.log(`==> preset: ${id} (priority ${prio})`);
    if (!installOne("preset", id, join(REPO_DIR, kind, id) + "/", prio)) exit = 1;
    const other = counterpart[id];
    if (other === undefined) continue;
    if (force) {
      if (!removeCounterpart(other)) exit = 1;
    } else if (isDir(join(".specify/presets", other))) {
      console.log(`  warning: ${other} (other stack) is also installed; re-run with --force to remove it`);
    }
  }
}

// Harness wiring `specify` cannot do (.claude/settings.json, CLAUDE.md): any item
// may ship scripts/ts/post-install.ts <project-dir>. Auto-discovered.
for (const [kind] of KINDS) {
  const dir = join(REPO_DIR, kind);
  const ids = existsSync(dir) ? readdirSync(dir).filter((n) => !n.startsWith(".") && isDir(join(dir, n))).sort(cmp) : [];
  for (const id of ids) {
    const post = join(dir, id, "scripts/ts/post-install.ts");
    if (!existsSync(post) || (kind === "presets" && skipped.has(id))) continue;
    console.log(`==> post-install: ${id}`);
    if (Bun.spawnSync([BUN, post, PROJECT_DIR], { stdio: ["inherit", "inherit", "inherit"] }).exitCode !== 0) exit = 1;
  }
}

// Command names do not predict script names, and a consumer agent cannot read this
// repo's CLAUDE.md, so the command -> script index is generated into the project.
if (Bun.spawnSync([BUN, join(REPO_DIR, "scripts/gen-agent-index.ts"), REPO_DIR, PROJECT_DIR], { stdio: ["inherit", "inherit", "inherit"] }).exitCode !== 0)
  exit = 1;

console.log(`\nDone. Target: ${PROJECT_DIR}`);
process.exit(exit);
