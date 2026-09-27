#!/usr/bin/env bun
// Self-check for install.ts's preset selection: the pure selectPresets() for every
// stack (none/ts/ios/both) and presetPriority(). Run: ./test-install-mode.ts
import { presetPriority, selectPresets } from "./scripts/manifest.ts";

let failures = 0;
const eq = (a: unknown, b: unknown, msg: string): void => {
  if (JSON.stringify(a) === JSON.stringify(b)) return;
  console.error(`FAIL: ${msg}: got ${JSON.stringify(a)}, want ${JSON.stringify(b)}`);
  failures++;
};

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
eq(
  selectPresets(ids, "none"),
  {
    install: ["diff-minimal"],
    skip: ["button-design", "button-design-ios", "tdd", "tdd-ios", "watch-only-ios"],
    counterpart: {},
  },
  "no flag: language-neutral presets only, and nothing to remove",
);

// priority
const P = { tdd: 11, "parse-dont-validate": 9, "tdd-special-ios": 3 };
eq(presetPriority(P, "tdd-ios"), 11, "tdd-ios inherits tdd");
eq(presetPriority(P, "parse-dont-validate-ios"), 9, "pdv-ios inherits pdv");
eq(presetPriority(P, "tdd-special-ios"), 3, "own entry wins");
eq(presetPriority(P, "diff-minimal"), 10, "default");

if (failures) {
  console.error(`${failures} failure(s)`);
  process.exit(1);
}
console.log("test-install-mode: all passed");
