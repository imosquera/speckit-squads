#!/usr/bin/env bun
// Self-check for install.ts's stack selection: detectIos()/detectWeb()/detectStack()
// on throwaway trees, parseStack(), and the pure selectPresets()/presetPriority()
// for every stack. Run: ./test-install-mode.ts
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import {
  detectIos,
  detectStack,
  detectWeb,
  parseStack,
  presetPriority,
  selectPresets,
} from "./scripts/manifest.ts";

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

eq(detectWeb(tree("package.json")), "package.json", "package.json at root");
eq(detectWeb(tree("functions/package.json")), "functions/package.json", "package.json one level down");
eq(detectWeb(tree("tsconfig.json")), "tsconfig.json", "tsconfig.json at root");
eq(detectWeb(tree("node_modules/package.json")), null, "node_modules ignored");
eq(detectWeb(tree("a/b/package.json")), null, "two levels down is not searched (web)");
eq(detectWeb(tree("App.xcodeproj/", "Sources/App.swift", "Package.swift")), null, "Swift-only tree");
eq(detectWeb(join(TMP, "missing")), null, "missing dir (web)");

eq(
  detectStack(tree("App.xcodeproj/", "functions/package.json")),
  { stack: "both", markers: ["App.xcodeproj", "functions/package.json"] },
  "xcodeproj + functions/package.json -> both",
);
eq(detectStack(tree("ios/App.xcodeproj/")), { stack: "ios", markers: ["ios/App.xcodeproj"] }, "ios only");
eq(detectStack(tree("package.json", "src/")), { stack: "ts", markers: ["package.json"] }, "ts only");
eq(detectStack(tree()), { stack: "ts", markers: [] }, "empty -> ts");

eq(parseStack("ts"), "ts", "parseStack ts");
eq(parseStack("web"), null, "parseStack web is not a stack");
eq(parseStack("ios"), "ios", "parseStack ios");
eq(parseStack("both"), "both", "parseStack both");
eq(parseStack("iOS"), null, "parseStack is case-sensitive");
eq(parseStack(""), null, "parseStack empty");
eq(parseStack("all"), null, "parseStack unknown");

// selection
const ids = ["button-design", "button-design-ios", "diff-minimal", "tdd", "tdd-ios", "watch-only-ios"];
eq(
  selectPresets(ids, "ios"),
  {
    install: ["button-design-ios", "diff-minimal", "tdd-ios", "watch-only-ios"],
    skip: ["button-design", "tdd"],
    counterpart: { "button-design-ios": "button-design", "tdd-ios": "tdd" },
  },
  "ios stack",
);
eq(
  selectPresets(ids, "ts"),
  {
    install: ["button-design", "diff-minimal", "tdd"],
    skip: ["button-design-ios", "tdd-ios", "watch-only-ios"],
    counterpart: { "button-design": "button-design-ios", tdd: "tdd-ios" },
  },
  "ts stack (base-less -ios preset skipped)",
);
eq(selectPresets(ids, "both"), { install: ids, skip: [], counterpart: {} }, "both stack installs every preset");
eq(selectPresets(["-ios"], "ts").install, ["-ios"], "bare -ios is not a pair");

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
