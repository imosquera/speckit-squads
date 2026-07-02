---
description: "Execute /speckit-plan, then require the plan to name its trust boundaries, branded domain types, and parsers up front — so Parse, Don't Validate is designed in before /speckit-implement enforces it."
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Behavior

Execute the canonical stock `/speckit-plan` flow with **one mandatory gate**: a
Parse boundary design section in the generated `plan.md`.

### Core Flow

Run the core plan flow first so that `plan.md` exists before the gate is
applied. This `{CORE_TEMPLATE}` seam is also the chaining point that lets other
presets wrap this command: when composed, the placeholder expands to the next
inner wrapper and ultimately the stock flow.

{CORE_TEMPLATE}

### Mandatory "Parse Boundaries" section

After the core flow has produced `plan.md`, add a **`## Parse Boundaries`**
section to it. This section makes the *Parse, Don't Validate* discipline a
design decision rather than a write-time afterthought.

Apply this gate only when the feature is implemented in TypeScript (or the
project's primary language is TypeScript). If the feature has no TypeScript
surface, write `## Parse Boundaries` with a single line "N/A — no TypeScript in
this feature" and continue.

For a TypeScript feature, the section MUST enumerate:

1. **Trust boundaries** — every point where untrusted data enters the feature
   (HTTP handlers, DB rows, env, file/CLI input, `JSON.parse`, third-party SDK
   responses). Each entry names the raw input and states that it is typed
   `unknown` (never `any`) on the way in.
2. **Domain types** — the precise / branded types the feature earns the right to
   trust (e.g. `Email`, `UserId`), including how identity is nominal-ized
   (non-exported `unique symbol` brand, or a schema library's `.brand()`).
   Every domain primitive that could be confused with another (`UserId` vs
   `OrderId`) is called out as branded.
3. **Parsers** — for each boundary, the parser function that maps the `unknown`
   blob to a domain type, returning a discriminated `Result`
   (`{ kind: "ok" | "err" }`), not a boolean and not a throw. Name the module
   that owns each parser; brand casts live only there.
4. **Library choice** — whether the feature uses a schema library (Zod /
   valibot / io-ts) or hand-rolled parsers, and why. Prefer an existing project
   dependency over new hand-rolled casts.

Do not write the blanket sentence "inputs are validated" — that is the exact
anti-pattern this section exists to replace. Name the parser, its input type,
and its output type.

## Failure Policy

- A TypeScript feature whose `plan.md` lacks a substantive `## Parse Boundaries`
  section (boundaries + domain types + parsers) is incomplete. Fill it in before
  finishing the command.
- Downstream `/speckit-implement` (under this preset) will scan the written code
  against this design; a plan that hand-waves the boundaries will surface as
  scan findings later.

## Completion Report

On success, include:
- Confirmation that `plan.md` has a `## Parse Boundaries` section (or that it is
  N/A for a non-TypeScript feature).
- A one-line summary of the boundaries, domain types, and parsers identified.
- The normal stock `/speckit-plan` completion summary.
