#!/usr/bin/env bun
// install-deps.ts installs a fresh worktree's dependencies at creation and stays out
// of the way: no manifest is a silent no-op, a failing package manager never fails the
// caller, and a directory the base checkout never installed is never installed (#51).
// Cases 1-10 are Node/Python; 11-17 iOS (CocoaPods, Carthage, SwiftPM packages, an Xcode
// app's SwiftPM graph); 18-19 a React Native app that needs both.
// Usage: ./test-worktree-deps.ts
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname } from "node:path";

const SCRIPT = `${import.meta.dir}/extensions/git/scripts/ts/install-deps.ts`;
const TMP = mkdtempSync(`${tmpdir()}/worktree-deps-`);
const CALLS = `${TMP}/calls.log`;
let fail = 0;

function check(what: string, desc: string, expected: string, actual: string): void {
  if (expected === actual) console.log(`  ok: ${what} ${desc}`);
  else {
    console.error(`  FAIL: ${what} ${desc} — expected '${expected}', got '${actual}'`);
    fail = 1;
  }
}
function contains(what: string, needle: string, hay: string): void {
  if (hay.includes(needle)) console.log(`  ok: ${what} mentions '${needle}'`);
  else {
    console.error(`  FAIL: ${what} does not mention '${needle}'`);
    console.error(hay.split("\n").map((l) => `        ${l}`).join("\n"));
    fail = 1;
  }
}
function absent(what: string, needle: string, hay: string): void {
  if (hay.includes(needle)) {
    console.error(`  FAIL: ${what} unexpectedly mentions '${needle}'`);
    fail = 1;
  } else console.log(`  ok: ${what} does not mention '${needle}'`);
}

const git = (dir: string, ...args: string[]) => Bun.spawnSync(["git", "-C", dir, ...args], { stdout: "ignore", stderr: "ignore" });
function makeRepo(name: string, files: Record<string, string> = {}): string {
  const repo = `${TMP}/${name}`;
  mkdirSync(repo, { recursive: true });
  git(repo, "init", "-q");
  git(repo, "config", "user.email", "t@t");
  git(repo, "config", "user.name", "t");
  writeFileSync(`${repo}/README.md`, "hi\n");
  for (const [f, body] of Object.entries(files)) {
    mkdirSync(dirname(`${repo}/${f}`), { recursive: true });
    writeFileSync(`${repo}/${f}`, body);
  }
  git(repo, "add", "-A");
  git(repo, "commit", "-qm", "one");
  return repo;
}
// slugify: a repo dir may contain a space, a branch name may not
const addWt = (repo: string) => (git(repo, "worktree", "add", "-q", "-b", `feat-${basename(repo).replaceAll(" ", "-")}`, `${repo}.wt`), `${repo}.wt`);
const nodeModules = (repo: string, ...dirs: string[]) => dirs.forEach((d) => mkdirSync(`${repo}/${d}/node_modules`, { recursive: true }));
// Stand-in for what an iOS base checkout installed: Pods/, Carthage/Build/, .build/ ...
const installed = (repo: string, ...dirs: string[]) => dirs.forEach((d) => mkdirSync(`${repo}/${d}`, { recursive: true }));

// A fake package manager that records its invocations, or fails on demand.
function fakeBin(dir: string, name: string, code: number): void {
  mkdirSync(dir, { recursive: true });
  writeFileSync(`${dir}/${name}`, `#!/usr/bin/env bash\necho "$(pwd) ${name} $*" >> "${CALLS}"\necho "boom" >&2\nexit ${code}\n`);
  chmodSync(`${dir}/${name}`, 0o755);
}
const resetCalls = () => writeFileSync(CALLS, "");
const calls = () => readFileSync(CALLS, "utf8").replace(/\n+$/, "");
// bun by absolute path, so a PATH without bun still runs the script (case 5).
function run(args: string[], env: Record<string, string> = {}): { out: string; rc: number } {
  const r = Bun.spawnSync([process.execPath, SCRIPT, ...args], { env: { ...process.env, ...env }, stdout: "pipe", stderr: "pipe" });
  return { out: (r.stdout.toString() + r.stderr.toString()).replace(/\n+$/, ""), rc: r.exitCode ?? -1 };
}
const withBin = (bin: string) => ({ PATH: `${bin}:${process.env.PATH}` });
const PKG = { "package.json": '{"name":"x"}\n' };
const SWIFT_PKG = { "Package.swift": "// swift-tools-version:5.9\n" };
const PODS = { Podfile: "platform :ios, '17.0'\n", "Podfile.lock": "PODFILE CHECKSUM: x\n" };
const APP_RESOLVED = (container: string) => ({ [`${container}/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`]: "{}\n" });
const lines = () => calls().split("\n").filter(Boolean);
// The tools run in `dir` itself, in call order, e.g. "pod,xcodebuild".
const tools = (dir: string) => lines().filter((l) => l.startsWith(`${dir} `)).map((l) => l.slice(dir.length + 1).split(" ")[0]).join(",");

try {
  console.log("1. no manifest anywhere -> silent no-op, exit 0");
  let WT = addWt(makeRepo("nomanifest"));
  let r = run([WT]);
  check("no-manifest", "exit code", "0", String(r.rc));
  check("no-manifest", "output", "", r.out);

  console.log("2. manifest the base checkout never installed -> not installed here");
  WT = addWt(makeRepo("uninstalled", { ...PKG, "package-lock.json": "" }));
  resetCalls();
  fakeBin(`${TMP}/bin2`, "npm", 0);
  r = run([WT], withBin(`${TMP}/bin2`));
  check("uninstalled", "exit code", "0", String(r.rc));
  check("uninstalled", "ran no installer", "", calls());

  console.log("3. base has node_modules -> the lockfile picks the package manager");
  let REPO = makeRepo("installed", {
    ...PKG,
    "package-lock.json": "",
    "web/package.json": '{"name":"w"}\n',
    "web/pnpm-lock.yaml": "",
    "docs/package.json": '{"name":"d"}\n',
  });
  nodeModules(REPO, ".", "web"); // docs/ never installed
  WT = addWt(REPO);
  resetCalls();
  fakeBin(`${TMP}/bin3`, "npm", 0);
  fakeBin(`${TMP}/bin3`, "pnpm", 0);
  r = run([WT], withBin(`${TMP}/bin3`));
  check("installed", "exit code", "0", String(r.rc));
  contains("root install", `${WT} npm ci`, calls());
  contains("workspace install", `${WT}/web pnpm install --frozen-lockfile`, calls());
  absent("docs (base never installed it)", `${WT}/docs`, calls());
  contains("summary", "installed:", r.out);

  console.log("4. a failing install reports but does not fail the caller");
  REPO = makeRepo("failing", { ...PKG, "package-lock.json": "" });
  nodeModules(REPO, ".");
  WT = addWt(REPO);
  fakeBin(`${TMP}/bin4`, "npm", 1);
  r = run([WT], withBin(`${TMP}/bin4`));
  check("failing", "exit code", "0", String(r.rc));
  contains("failing", "FAILED in", r.out);

  console.log("5. package manager missing from PATH -> named, not run, still exit 0");
  REPO = makeRepo("notool", { ...PKG, "bun.lockb": "" });
  nodeModules(REPO, ".");
  WT = addWt(REPO);
  r = run([WT], { PATH: "/nonexistent-bin-dir:/usr/bin:/bin" });
  check("no-tool", "exit code", "0", String(r.rc));
  contains("no-tool", "bun", r.out);

  console.log("6. SPECKIT_SKIP_INSTALL=1 skips everything");
  resetCalls();
  fakeBin(`${TMP}/bin6`, "npm", 0);
  r = run([`${TMP}/installed.wt`], { SPECKIT_SKIP_INSTALL: "1", ...withBin(`${TMP}/bin6`) });
  check("skip", "exit code", "0", String(r.rc));
  contains("skip", "SPECKIT_SKIP_INSTALL=1", r.out);
  check("skip", "ran no installer", "", calls());

  console.log("7. a missing / non-worktree path is a warning, never an error");
  r = run([`${TMP}/does-not-exist`]);
  check("missing-path", "exit code", "0", String(r.rc));
  contains("missing-path", "no such worktree", r.out);
  check("no-arg", "exit code", "0", String(run([]).rc));

  console.log("8. the base checkout itself is never installed into");
  resetCalls();
  fakeBin(`${TMP}/bin8`, "npm", 0);
  r = run([`${TMP}/installed`], withBin(`${TMP}/bin8`));
  check("base-checkout", "exit code", "0", String(r.rc));
  check("base-checkout", "ran no installer", "", calls());

  console.log("9. a pnpm workspace child is installed by its root, never on its own");
  REPO = makeRepo("workspace", { ...PKG, "pnpm-lock.yaml": "", "packages/api/package.json": '{"name":"api"}\n' });
  nodeModules(REPO, ".", "packages/api");
  WT = addWt(REPO);
  resetCalls();
  fakeBin(`${TMP}/bin9`, "pnpm", 0);
  fakeBin(`${TMP}/bin9`, "npm", 0);
  r = run([WT], withBin(`${TMP}/bin9`));
  check("workspace", "exit code", "0", String(r.rc));
  contains("workspace root", `${WT} pnpm install --frozen-lockfile`, calls());
  absent("workspace child", "packages/api", calls());
  check("workspace", "installs once", "1", String(calls().split("\n").filter(Boolean).length));

  console.log("10. a base checkout whose path contains a space still resolves");
  REPO = makeRepo("spaced repo", { ...PKG, "package-lock.json": "" });
  nodeModules(REPO, ".");
  WT = addWt(REPO);
  resetCalls();
  fakeBin(`${TMP}/bin10`, "npm", 0);
  r = run([WT], withBin(`${TMP}/bin10`));
  check("spaced", "exit code", "0", String(r.rc));
  absent("spaced", "could not resolve the base checkout", r.out);
  contains("spaced", `${WT} npm ci`, calls());

  // ---- iOS: CocoaPods, Carthage, SwiftPM packages, an Xcode app's SwiftPM graph
  console.log("11. iOS manifests whose deps the base checkout never installed -> not installed here");
  WT = addWt(makeRepo("ios-uninstalled", { ...PODS, ...SWIFT_PKG, "Cartfile.resolved": "" }));
  resetCalls();
  for (const t of ["pod", "swift", "carthage"]) fakeBin(`${TMP}/bin11`, t, 0);
  r = run([WT], withBin(`${TMP}/bin11`));
  check("ios-uninstalled", "exit code", "0", String(r.rc));
  check("ios-uninstalled", "ran no installer", "", calls());

  console.log("12. base has Pods/ -> pod install, then the app's packages; a tracked package lockfile resolves");
  REPO = makeRepo("ios-installed", {
    ...PODS,
    ...APP_RESOLVED("App.xcodeproj"),
    "Kit/Package.swift": "// swift-tools-version:5.9\n",
    "Kit/Package.resolved": "{}\n",
    "Legacy/Podfile.lock": "", // base never ran pod install here
  });
  installed(REPO, "Pods");
  WT = addWt(REPO);
  resetCalls();
  for (const t of ["pod", "swift", "xcodebuild"]) fakeBin(`${TMP}/bin12`, t, 0);
  r = run([WT], withBin(`${TMP}/bin12`));
  check("ios-installed", "exit code", "0", String(r.rc));
  contains("root pods", `${WT} pod install`, calls());
  contains("app packages", `${WT} xcodebuild -resolvePackageDependencies -project App.xcodeproj`, calls());
  check("root order", "pod install before xcodebuild", "pod,xcodebuild", tools(WT));
  contains("package", `${WT}/Kit swift package resolve`, calls());
  absent("Legacy (base never installed it)", `${WT}/Legacy`, calls());
  contains("summary", "installed:", r.out);

  console.log("13. a failing iOS step reports, stops that directory, and does not fail the caller");
  REPO = makeRepo("ios-failing", { ...PODS, ...APP_RESOLVED("App.xcodeproj") });
  installed(REPO, "Pods");
  WT = addWt(REPO);
  resetCalls();
  fakeBin(`${TMP}/bin13`, "pod", 1);
  fakeBin(`${TMP}/bin13`, "xcodebuild", 0);
  r = run([WT], withBin(`${TMP}/bin13`));
  check("ios-failing", "exit code", "0", String(r.rc));
  contains("ios-failing", "FAILED in .: pod install", r.out);
  absent("ios-failing (later step skipped)", "xcodebuild", calls());

  console.log("14. iOS tool missing from PATH -> named, not run, still exit 0");
  REPO = makeRepo("ios-notool", { Cartfile: 'github "x/y"\n', "Cartfile.resolved": 'github "x/y" "1.0"\n' });
  installed(REPO, "Carthage/Build");
  WT = addWt(REPO);
  r = run([WT], { PATH: "/nonexistent-bin-dir:/usr/bin:/bin" });
  check("ios-no-tool", "exit code", "0", String(r.rc));
  contains("ios-no-tool", "carthage", r.out);

  console.log("15. the iOS base checkout itself is never installed into");
  resetCalls();
  for (const t of ["pod", "swift", "xcodebuild"]) fakeBin(`${TMP}/bin15`, t, 0);
  r = run([`${TMP}/ios-installed`], withBin(`${TMP}/bin15`));
  check("ios-base-checkout", "exit code", "0", String(r.rc));
  check("ios-base-checkout", "ran no installer", "", calls());

  console.log("16. a workspace is resolved once, with its shared scheme; committed Pods/ are not reinstalled");
  REPO = makeRepo("ios-workspace", {
    ...PODS,
    "Pods/Manifest.lock": "PODFILE CHECKSUM: x\n", // this team commits Pods/
    "App.xcworkspace/contents.xcworkspacedata": "<Workspace/>\n",
    "App.xcworkspace/xcshareddata/swiftpm/Package.resolved": "{}\n",
    ...APP_RESOLVED("App.xcodeproj"),
    "App.xcodeproj/xcshareddata/xcschemes/App.xcscheme": "<Scheme/>\n",
  });
  WT = addWt(REPO);
  resetCalls();
  for (const t of ["pod", "xcodebuild"]) fakeBin(`${TMP}/bin16`, t, 0);
  r = run([WT], withBin(`${TMP}/bin16`));
  check("ios-workspace", "exit code", "0", String(r.rc));
  contains("ios-workspace", `${WT} xcodebuild -resolvePackageDependencies -workspace App.xcworkspace -scheme App`, calls());
  absent("committed Pods", "pod install", calls());
  check("ios-workspace", "resolves once", "1", String(lines().length));

  console.log("17. iOS paths with spaces: the base checkout still resolves, a spaced container stays one argument");
  REPO = makeRepo("ios spaced repo", { ...SWIFT_PKG, ...APP_RESOLVED("My App.xcodeproj") });
  installed(REPO, ".build");
  WT = addWt(REPO);
  resetCalls();
  for (const t of ["swift", "xcodebuild"]) fakeBin(`${TMP}/bin17`, t, 0);
  r = run([WT], withBin(`${TMP}/bin17`));
  check("ios-spaced", "exit code", "0", String(r.rc));
  absent("ios-spaced", "could not resolve the base checkout", r.out);
  contains("ios-spaced", `${WT} swift package resolve`, calls());
  contains("ios-spaced", `${WT} xcodebuild -resolvePackageDependencies -project My App.xcodeproj`, calls());

  console.log("18. a React Native app gets both: npm at the root first, then pod install in ios/");
  REPO = makeRepo("rn", {
    ...PKG,
    "package-lock.json": "",
    "ios/Podfile": "platform :ios, '17.0'\n",
    "ios/Podfile.lock": "PODFILE CHECKSUM: x\n",
    ...APP_RESOLVED("ios/App.xcodeproj"),
  });
  nodeModules(REPO, ".");
  installed(REPO, "ios/Pods");
  WT = addWt(REPO);
  resetCalls();
  for (const t of ["npm", "pod", "xcodebuild"]) fakeBin(`${TMP}/bin18`, t, 0);
  r = run([WT], withBin(`${TMP}/bin18`));
  check("rn", "exit code", "0", String(r.rc));
  check("rn", "order", `${WT} npm ci|${WT}/ios pod install|${WT}/ios xcodebuild -resolvePackageDependencies -project App.xcodeproj`, lines().join("|"));
  contains("rn", "installing dependencies in 2 directories", r.out);

  console.log("19. a failing root npm install does not stop ios/ from being tried; still exit 0");
  resetCalls();
  fakeBin(`${TMP}/bin19`, "npm", 1);
  for (const t of ["pod", "xcodebuild"]) fakeBin(`${TMP}/bin19`, t, 0);
  r = run([WT], withBin(`${TMP}/bin19`));
  check("rn-failing", "exit code", "0", String(r.rc));
  contains("rn-failing", "FAILED in .: npm ci", r.out);
  contains("rn-failing", `${WT}/ios pod install`, calls());
} finally {
  rmSync(TMP, { recursive: true, force: true });
}

if (fail === 0) console.log("worktree deps check: ok");
else console.error("worktree deps check: FAILED");
process.exit(fail);
