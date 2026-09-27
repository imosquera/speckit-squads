#!/usr/bin/env bun
// stale-tasks-guard extension: selftest-stale-tasks-guard.ts
// Self-contained test for stale-tasks-guard.ts. No test framework required.
//
// Usage: bun extensions/stale-tasks-guard/scripts/ts/selftest-stale-tasks-guard.ts

import { mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const GUARD = join(import.meta.dir, "stale-tasks-guard.ts");
const WORK = mkdtempSync(join(tmpdir(), "selftest-stale-tasks-guard-"));
let failures = 0;

type Result = { code: number; out: string; err: string };

function run(cmd: string[], cwd: string, env: Record<string, string | undefined> = {}): Result {
  const base: Record<string, string | undefined> = { ...process.env };
  delete base.SPECIFY_FEATURE;
  delete base.SPECIFY_FEATURE_DIRECTORY;
  const r = Bun.spawnSync(cmd, { cwd, env: { ...base, ...env }, stdout: "pipe", stderr: "pipe" });
  return { code: r.exitCode ?? -1, out: r.stdout.toString(), err: r.stderr.toString() };
}

const guard = (cwd: string, env: Record<string, string | undefined> = {}) => run(["bun", GUARD], cwd, env);

function git(cwd: string, ...args: string[]) {
  const r = run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", ...args], cwd);
  if (r.code !== 0) throw new Error(`git ${args.join(" ")}: ${r.err}`);
}

function check(name: string, r: Result, code: number, out: RegExp | null, err: RegExp | null) {
  const problems: string[] = [];
  if (r.code !== code) problems.push(`exit ${r.code}, want ${code}`);
  if (out ? !out.test(r.out) : r.out !== "") problems.push(`stdout ${JSON.stringify(r.out)}`);
  if (err ? !err.test(r.err) : r.err !== "") problems.push(`stderr ${JSON.stringify(r.err)}`);
  if (problems.length === 0) console.log(`PASS: ${name}`);
  else { console.log(`FAIL: ${name} — ${problems.join("; ")}`); failures++; }
}

function setTime(path: string, epoch: number) { utimesSync(path, epoch, epoch); }

const STALE = /^STALE TASKS DETECTED\n   spec\.md was modified (\d+)m after tasks\.md was last generated\.\n   Run \/speckit-tasks to reconcile, then re-run \/speckit-implement\.\n   To bypass: \/speckit-implement --force\n$/;

try {
  const now = Math.floor(Date.now() / 1000);

  // 1. Not a git repo, no env: unresolvable, skip with advisory.
  const plain = join(WORK, "plain");
  mkdirSync(plain);
  check("no repo, no env -> skip", guard(plain), 0, null,
    /^stale-tasks-guard: could not resolve a feature directory for <unknown branch>; skipping guard\n$/);

  // 2. SPECIFY_FEATURE naming a missing dir.
  check("SPECIFY_FEATURE missing dir -> skip", guard(plain, { SPECIFY_FEATURE: "009-x" }), 0, null,
    /for 009-x; skipping guard\n$/);

  // 3. SPECIFY_FEATURE_DIRECTORY with missing files: silent 0.
  const fd = join(plain, "feat");
  mkdirSync(fd);
  check("env dir, files missing -> 0 silent", guard(plain, { SPECIFY_FEATURE_DIRECTORY: "feat" }), 0, null, null);

  // 4. spec newer than tasks (no git): stale, delta in minutes.
  writeFileSync(join(fd, "spec.md"), "s\n");
  writeFileSync(join(fd, "tasks.md"), "t\n");
  setTime(join(fd, "tasks.md"), now - 3600);
  setTime(join(fd, "spec.md"), now - 600);
  const r4 = guard(plain, { SPECIFY_FEATURE_DIRECTORY: fd });
  check("spec newer (mtime) -> stale", r4, 1, STALE, null);
  if (STALE.exec(r4.out)?.[1] !== "50") { console.log(`FAIL: delta minutes — ${r4.out}`); failures++; }

  // 5. spec older: not stale.
  setTime(join(fd, "spec.md"), now - 7200);
  check("spec older (mtime) -> 0", guard(plain, { SPECIFY_FEATURE_DIRECTORY: "feat" }), 0, null, null);

  // 6. Git repo, branch with a slash resolves specs/<last segment>; commit time wins over mtime.
  const repo = join(WORK, "repo");
  mkdirSync(repo);
  git(repo, "init", "-q", "-b", "feat/001-thing");
  const sd = join(repo, "specs", "001-thing");
  mkdirSync(sd, { recursive: true });
  writeFileSync(join(sd, "spec.md"), "s\n");
  writeFileSync(join(sd, "tasks.md"), "t\n");
  git(repo, "add", "specs/001-thing/spec.md");
  run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", "spec"], repo,
    { GIT_COMMITTER_DATE: `@${now - 7200} +0000`, GIT_AUTHOR_DATE: `@${now - 7200} +0000` });
  git(repo, "add", "specs/001-thing/tasks.md");
  run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", "tasks"], repo,
    { GIT_COMMITTER_DATE: `@${now - 3600} +0000`, GIT_AUTHOR_DATE: `@${now - 3600} +0000` });
  // Checkout-like mtimes that would say "stale" if raw mtime were used.
  setTime(join(sd, "tasks.md"), now - 100);
  setTime(join(sd, "spec.md"), now - 10);
  check("clean files use commit time -> 0", guard(repo), 0, null, null);

  // 7. Dirty spec.md uses its mtime -> stale vs tasks commit time.
  writeFileSync(join(sd, "spec.md"), "s2\n");
  setTime(join(sd, "spec.md"), now - 60);
  const r7 = guard(repo);
  check("dirty spec newer than tasks commit -> stale", r7, 1, STALE, null);
  if (STALE.exec(r7.out)?.[1] !== "59") { console.log(`FAIL: dirty delta minutes — ${r7.out}`); failures++; }

  // 8. SPECIFY_FEATURE overrides the branch.
  check("SPECIFY_FEATURE overrides branch", guard(repo, { SPECIFY_FEATURE: "nope" }), 0, null, /for nope; skipping guard\n$/);
} finally {
  rmSync(WORK, { recursive: true, force: true });
}

if (failures > 0) { console.log(`${failures} failure(s)`); process.exit(1); }
console.log("all passed");
