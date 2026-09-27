#!/usr/bin/env bun
// tdd preset: post-install.ts <project-dir>
// Installs @typesafe-ai/sdk, which jev-judge.ts loads, into a machine-level
// cache with bun.
//
// Not into the preset tree: consumers commit .specify/, so a node_modules there
// would be committed with it. Not into the project: a consumer's dependency
// list is not ours to edit. jev-judge.ts resolves the project's own copy first,
// so a project that already depends on the SDK never uses this one.
//
// Best effort and idempotent: Jev is optional, so a failed install is a
// notice, never an install failure. Nothing to reverse on uninstall: the cache
// is shared by every project that installs the preset.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const VERSION = "0.6.0";
const cache = join(process.env.XDG_CACHE_HOME || join(homedir(), ".cache"), "speckit-squads", "tdd-jev");
const off = "Jev judgments stay off (the TDD cycle runs without them)";

try {
  const pkg = JSON.parse(readFileSync(join(cache, "node_modules/@typesafe-ai/sdk/package.json"), "utf8"));
  if (pkg.version === VERSION) {
    console.log(`  @typesafe-ai/sdk ${VERSION} already cached for Jev`);
    process.exit(0);
  }
} catch { /* not cached yet */ }

try {
  mkdirSync(cache, { recursive: true });
  if (!existsSync(join(cache, "package.json"))) writeFileSync(join(cache, "package.json"), '{"private":true}\n');
  const r = Bun.spawnSync([process.execPath, "add", "--silent", `@typesafe-ai/sdk@${VERSION}`],
    { cwd: cache, stdout: "ignore", stderr: "ignore" });
  console.log(r.exitCode === 0
    ? `  cached @typesafe-ai/sdk ${VERSION} for Jev at ${cache}`
    : `  notice: could not install @typesafe-ai/sdk — ${off}`);
} catch (e) {
  console.log(`  notice: could not install @typesafe-ai/sdk (${(e as Error).message}) — ${off}`);
}
