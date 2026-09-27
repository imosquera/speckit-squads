#!/usr/bin/env bun
// Self-check for install.ts's iOS/web mode: detectIos() on throwaway trees, and the
// pure selectPresets()/presetPriority() for both modes. Run: ./test-install-mode.ts
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { detectIos, presetPriority, selectPresets } from "./scripts/manifest.ts";

const TMP = mkdtempSync(join(tmpdir(), "install-mode-"));
let failures = 0;
const check = (cond: boolean, msg: string): void => {
  if (!cond) {
    console.error(`FAIL: ${msg}`);
    failures++;
  }
};
const eq = (a: unknown, b: unknown, msg: string): void =>
  check(JSON.stringify(a) === JSON.stringify(b), `${msg}: got ${JSON.stringify(a)}, want ${JSON.stringify(b)}`);

/** A fresh project containing `paths` (trailing "/" = directory, else empty file). */
let n = 0;
function tree(...paths: string[]): string {
  const root = join(TMP, String(n++));
  mkdirSync(join(root, ".specify"), { recursive: true });
  for (const p of paths) {
    if (p.endsWith("/")) mkdirSync(join(root, p), { recursive: true });
    else {
      mkdirSync(dirname(join(root, p)), { recursive: true });
      writeFileSync(join(root, p), "");
    }
  }
  return root;
}

// detection
eq(detectIos(tree("App.xcodeproj/", "src/")), "App.xcodeproj", "xcodeproj at root");
eq(detectIos(tree("App.xcworkspace/")), "App.xcworkspace", "xcworkspace at root");
eq(detectIos(tree("Package.swift")), "Package.swift", "Package.swift at root");
eq(detectIos(tree("ios/App.xcodeproj/")), "ios/App.xcodeproj", "xcodeproj one level down");
eq(detectIos(tree("Kit/Package.swift")), "Kit/Package.swift", "Package.swift one level down");
eq(detectIos(tree("a/b/App.xcodeproj/")), null, "two levels down is not searched");
eq(detectIos(tree("Pods/Pods.xcodeproj/", "node_modules/Package.swift")), null, "Pods/node_modules ignored");
eq(detectIos(tree("Carthage/X.xcodeproj/", "DerivedData/Y.xcworkspace/", ".build/Package.swift")), null, "Carthage/DerivedData/.build ignored");
eq(detectIos(tree("Foo.app/Package.swift")), null, "bundles not descended into");
eq(detectIos(tree("package.json", "src/index.ts", "web/")), null, "web project");
eq(detectIos(join(TMP, "missing")), null, "missing dir");

// selection
const ids = ["button-design", "button-design-ios", "diff-minimal", "tdd", "tdd-ios", "watch-only-ios"];
eq(
  selectPresets(ids, true),
  {
    install: ["button-design-ios", "diff-minimal", "tdd-ios", "watch-only-ios"],
    skip: ["button-design", "tdd"],
    counterpart: { "button-design-ios": "button-design", "tdd-ios": "tdd" },
  },
  "iOS mode",
);
eq(
  selectPresets(ids, false),
  {
    install: ["button-design", "diff-minimal", "tdd"],
    skip: ["button-design-ios", "tdd-ios", "watch-only-ios"],
    counterpart: { "button-design": "button-design-ios", tdd: "tdd-ios" },
  },
  "web mode (base-less -ios preset skipped)",
);
eq(selectPresets(["-ios"], false).install, ["-ios"], "bare -ios is not a pair");

// priority
const P = { tdd: 11, "parse-dont-validate": 9, "tdd-special-ios": 3 };
eq(presetPriority(P, "tdd-ios"), 11, "tdd-ios inherits tdd");
eq(presetPriority(P, "parse-dont-validate-ios"), 9, "pdv-ios inherits pdv");
eq(presetPriority(P, "tdd-special-ios"), 3, "own entry wins");
eq(presetPriority(P, "diff-minimal"), 10, "default");

rmSync(TMP, { recursive: true, force: true });
if (failures) {
  console.error(`${failures} failure(s)`);
  process.exit(1);
}
console.log("test-install-mode: all passed");
