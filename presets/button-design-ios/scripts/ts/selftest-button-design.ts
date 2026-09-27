#!/usr/bin/env bun
// button-design-ios preset: selftest-button-design.ts
// Self-contained test for check-buttons.ts. The checker is read-only, so every
// case asserts the exit code AND that spec.md was left byte-identical.
//
// Usage: bun presets/button-design-ios/scripts/ts/selftest-button-design.ts

import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const CHECK = join(import.meta.dir, "check-buttons.ts");
const WORK = mkdtempSync(join(tmpdir(), "selftest-button-design-"));
process.on("exit", () => rmSync(WORK, { recursive: true, force: true }));
let failures = 0;

function run(...args: string[]) {
  const p = Bun.spawnSync(["bun", CHECK, ...args], { stdout: "pipe", stderr: "pipe" });
  return { rc: p.exitCode ?? -1, out: p.stdout.toString() + p.stderr.toString() };
}

// `web` simulates a project that also installs the web button-design preset:
// the nearest `.specify/` carries `presets/button-design/`.
function check(name: string, want: number, mode: "spec" | "plan", spec: string, plan = "", web = false) {
  const root = join(WORK, name);
  const dir = join(root, "specs", "001-feature");
  mkdirSync(dir, { recursive: true });
  mkdirSync(join(root, ".specify", "presets", web ? "button-design" : "button-design-ios"), { recursive: true });
  const specPath = join(dir, "spec.md");
  writeFileSync(specPath, `# Feature\n\n${spec}\n`);
  writeFileSync(join(dir, "plan.md"), `# Plan\n\n${plan}\n`);
  const before = readFileSync(specPath, "utf8");
  const r = run(mode, mode === "plan" ? dir : specPath);
  if (r.rc !== want) {
    console.log(`FAIL: ${name} — want rc=${want}, got rc=${r.rc}`);
    console.log(r.out.replace(/^/gm, "    ").trimEnd());
    failures++;
  } else if (readFileSync(specPath, "utf8") !== before) {
    console.log(`FAIL: ${name} — spec.md was modified`);
    failures++;
  } else console.log(`PASS: ${name}`);
}

const HEAD = `## iOS Actions & Buttons

| Screen | Label | Control | Style | Role | Placement | Safeguard |
|---|---|---|---|---|---|---|`;

const GOOD = `${HEAD}
| Export sheet | Export Report | Button | automatic | — | toolbar .confirmationAction | — |
| Export sheet | Cancel | Button | automatic | cancel | toolbar .cancellationAction | — |
| Settings | Save Changes | Button | \`.borderedProminent\` | — | bottom bar | — |
| Settings | Delete Account | Button | .bordered | role: .destructive | inline | confirmationDialog |
| Settings | Privacy Policy | Link | — | — | inline | — |
| Settings | Notifications | NavigationLink | — | — | list row | — |
| Inbox | Delete Message | Button | automatic | destructive | swipe action | undo |

## Functional Requirements`;

const NONE = `## iOS Actions & Buttons

None — no user-facing iOS UI.`;
const NONE_OLD_WORDING = `## iOS Actions & Buttons

None — no user-facing UI.`;
// What button-design-ios <= 1.1.0 wrote: the web preset's headings.
const toLegacy = (t: string) => t.replace("## iOS Actions & Buttons", "## Actions & Buttons").replace("## iOS Button System", "## Button System");
// The web preset's own section, as the web layer writes it in a mixed project.
const WEB_SECTION = `## Actions & Buttons

| Screen | Label | Kind | Role | Safeguard |
|---|---|---|---|---|
| Export | Submit | button | primary | — |
| Export | Email | button | primary | — |`;
const WEB_PLAN = `## Button System

**Component:** reuse \`Button\` from \`src/ui/Button.tsx\`.
**Touch targets:** 20×20`;

const row = (r: string) => `${HEAD}\n${r}`;

// --- spec mode
check("spec-good", 0, "spec", GOOD);
check("spec-none", 0, "spec", NONE);
check("spec-none-old-wording", 0, "spec", NONE_OLD_WORDING);
check("spec-toolbar-no-primary", 0, "spec", row("| Editor | Bold | Button | plain | — | toolbar .primaryAction | — |"));
check("spec-alert-safeguard", 0, "spec", row("| Files | Remove File | Button | bordered | destructive | inline | alert |"));
check("spec-missing", 1, "spec", "## User Scenarios");
check("spec-no-table", 1, "spec", "## iOS Actions & Buttons\n\nSome prose about buttons.");
check("spec-web-columns", 1, "spec", `## iOS Actions & Buttons

| Screen | Label | Kind | Role | Safeguard |
|---|---|---|---|---|
| Export | Download Report | button | primary | — |`);
check("spec-two-prominent", 1, "spec", `${HEAD}
| Export | Download Report | Button | borderedProminent | — | inline | — |
| Export | Email Report | Button | borderedProminent | — | inline | — |`);
check("spec-generic-label", 1, "spec", row("| Export | Submit | Button | borderedProminent | — | inline | — |"));
check("spec-generic-link", 1, "spec", row("| Home | Click here | Link | — | — | inline | — |"));
check("spec-long-label", 1, "spec", row("| Export | Download The Quarterly Report | Button | borderedProminent | — | inline | — |"));
check("spec-bare-delete", 1, "spec", row("| Files | Delete | Button | bordered | destructive | inline | confirmationDialog |"));
check("spec-unguarded-delete", 1, "spec", row("| Files | Delete File | Button | bordered | destructive | inline | — |"));
check("spec-delete-no-role", 1, "spec", row("| Files | Delete File | Button | bordered | — | inline | confirmationDialog |"));
check("spec-unguarded-cancel", 1, "spec", row("| Billing | Cancel Subscription | Button | bordered | destructive | inline | — |"));
check("spec-link-with-role", 1, "spec", row("| Home | Pricing | NavigationLink | — | destructive | inline | — |"));
check("spec-link-prominent", 1, "spec", row("| Home | Pricing | NavigationLink | borderedProminent | — | inline | — |"));
check("spec-bad-control", 1, "spec", row("| Home | Pricing | chip | — | — | inline | — |"));
check("spec-bad-style", 1, "spec", row("| Home | Save Draft | Button | outlined | — | inline | — |"));
check("spec-bad-role", 1, "spec", row("| Home | Save Draft | Button | bordered | primary | inline | — |"));
check("spec-no-placement", 1, "spec", row("| Home | Save Draft | Button | bordered | — | — | — |"));
check("spec-cancel-in-confirm", 1, "spec", row("| Sheet | Cancel | Button | automatic | cancel | toolbar .confirmationAction | — |"));
check("spec-destructive-in-cancel", 1, "spec", row("| Sheet | Discard Draft | Button | automatic | destructive | toolbar .cancellationAction | confirmationDialog |"));

// --- migration: pre-1.2 heading, accepted only without the web preset
check("spec-legacy-ios-only", 0, "spec", toLegacy(GOOD));
check("spec-legacy-ios-only-bad", 1, "spec", toLegacy(row("| Export | Submit | Button | borderedProminent | — | inline | — |")));
check("spec-legacy-with-web", 1, "spec", toLegacy(GOOD), "", true);

// --- mixed project: both sections, each checker reads only its own
check("spec-mixed", 0, "spec", `${WEB_SECTION}\n\n${GOOD}`, "", true);
check("spec-mixed-ios-none", 0, "spec", `${WEB_SECTION}\n\n## iOS Actions & Buttons\n\nNone — no user-facing iOS UI.`, "", true);
check("spec-mixed-web-only", 1, "spec", WEB_SECTION, "", true);

// --- plan mode
const PLAN_GOOD = `## iOS Button System

**Component:** reuse \`PrimaryButtonStyle\` from \`Sources/DesignSystem/Buttons.swift\`.
**Styles & tint:**
- **Primary:** \`.borderedProminent\` with the app \`.tint\`
- **Destructive:** \`role: .destructive\`, system red
**States & feedback:** pressed via \`configuration.isPressed\`, \`.disabled\`, loading ProgressView; \`.sensoryFeedback(.success, trigger:)\` on save.
**Hit targets:** 44×44pt minimum via \`.frame(minWidth: 44, minHeight: 44)\` and \`.contentShape(Rectangle())\`.
**Accessibility:** labels scale with Dynamic Type up to AX5; icon-only buttons get \`.accessibilityLabel\`.
**Placement:** Save in the bottom bar within thumb reach; Cancel in \`.cancellationAction\`.`;
const PLAN_NO_PLACEMENT = PLAN_GOOD.slice(0, PLAN_GOOD.lastIndexOf("**Placement:**"));

check("plan-good", 0, "plan", GOOD, PLAN_GOOD);
check("plan-hover-note", 0, "plan", GOOD, PLAN_GOOD.replace("pressed via", "hover (iPad pointer), pressed via"));
check("plan-spec-none", 0, "plan", NONE, "");
check("plan-spec-legacy", 0, "plan", "## User Scenarios", "");
check("plan-missing-section", 1, "plan", GOOD, "## Summary");
check("plan-missing-marker", 1, "plan", GOOD, PLAN_NO_PLACEMENT);
check("plan-empty-marker", 1, "plan", GOOD, `${PLAN_NO_PLACEMENT}**Placement:**`);
check("plan-small-target", 1, "plan", GOOD, PLAN_GOOD.replace("44×44pt", "32x32pt"));
check("plan-no-dynamic-type", 1, "plan", GOOD, PLAN_GOOD.replace("Dynamic Type", "the system font"));
check("plan-web-markers", 1, "plan", GOOD, PLAN_GOOD.replace("**Hit targets:**", "**Touch targets:**"));
check("plan-legacy-ios-only", 0, "plan", toLegacy(GOOD), toLegacy(PLAN_GOOD));
check("plan-legacy-plan-only", 0, "plan", GOOD, toLegacy(PLAN_GOOD));
check("plan-legacy-with-web", 1, "plan", GOOD, toLegacy(PLAN_GOOD), true);
check("plan-legacy-spec-with-web", 0, "plan", toLegacy(GOOD), "", true);
check("plan-mixed", 0, "plan", `${WEB_SECTION}\n\n${GOOD}`, `${WEB_PLAN}\n\n${PLAN_GOOD}`, true);
check("plan-mixed-ios-none", 0, "plan", `${WEB_SECTION}\n\n${NONE}`, WEB_PLAN, true);
check("plan-mixed-ios-missing", 1, "plan", `${WEB_SECTION}\n\n${GOOD}`, WEB_PLAN, true);

// --- usage
if (run().rc === 2) console.log("PASS: usage-no-args");
else { console.log("FAIL: usage-no-args"); failures++; }

if (failures > 0) {
  console.log(`${failures} failure(s)`);
  process.exit(1);
}
console.log("all button-design-ios checks passed");
