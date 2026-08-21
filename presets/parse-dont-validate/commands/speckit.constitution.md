---
description: "Enforce a mandatory Parse, Don't Validate constitution section"
strategy: "wrap"
---

## User Input

```text
$ARGUMENTS
```

You MUST consider the user input before proceeding.

## Wrapper Layer

This preset wraps `/speckit-constitution` (and any inner wrapper the core-flow
seam expands to). It adds exactly one thing: it enforces a canonical
**Parse, Don't Validate** section in `.specify/memory/constitution.md`
after the core flow has written it. It does not otherwise change the workflow.

Other presets may stack the same way and inject their own governance sections.
Never assume this preset owns the whole document.

### Core Flow

{CORE_TEMPLATE}

## Enforcement Rules (MANDATORY — after the core flow)

Once the entire core flow above has completed and the constitution has been
written, ensure the canonical section below exists **exactly once**.

- **Match on the section title, not on its number.** A section counts as
  already present if its heading ends with `Parse, Don't Validate (MANDATORY)`,
  whatever roman numeral it currently carries. Replace that entire section body
  with the canonical text below, keeping its existing number.
- If no such section exists, insert it as a new numbered principle section,
  after the last existing numbered principle section, preserving all other
  constitution content.
- **Renumber all numbered principle sections sequentially** (`### I.`,
  `### II.`, `### III.`, …) in document order after inserting. Another preset
  stacked on this command injects its own section the same way, so the numeral
  in the canonical text below is a placeholder — the final numbering is
  whatever sequential position the section lands in. Never emit two sections
  with the same numeral.
- Do not weaken, paraphrase, or omit any of the constraints.
- Do not remove or reword a governance section injected by another preset.

## Canonical Section (body MUST be present verbatim)

The roman numeral below is a placeholder; the body is what must appear verbatim.

### I. Parse, Don't Validate (MANDATORY)

Untrusted data MUST be parsed into precise domain types at the boundary, never
merely validated and passed along as loose primitives. A validator answers
"is this ok?" and discards the answer the instant it returns; a parser returns a
more precise type that carries the proof forward. The type system MUST carry the
proof, not the programmer's memory. This principle is language-general and
applies to every TypeScript and Python surface in the codebase.

- **Keep the boundary untyped-safe**: All data entering the system from outside
  (network, disk, env, user input, `JSON.parse` / `json.loads`) MUST stay
  untyped-safe until parsed — `unknown` in TypeScript, or handed straight to a
  parser in Python. The `any` type (TypeScript) and the `Any` type (Python) are
  prohibited in domain code.
- **Branded / nominal domain types**: Values the program has earned the right to
  trust MUST be encoded as distinct types (e.g. `Email`, `UserId`), not bare
  `string`/`number`/`int`. Primitives that can be confused MUST be branded
  (TypeScript `unique symbol` / schema `.brand()`; Python `NewType`, pydantic /
  attrs model, or frozen dataclass) so they are not interchangeable.
- **Parsers, not validators**: Boundary functions MUST return a parsed domain
  type — a discriminated `Result` (`{ kind: "ok" | "err" }`) in TypeScript, or
  the parsed model / a single typed parse error in Python. Boolean `isValid*` /
  `is_valid_*` / `validate*` functions and scattered `throw`/`raise`-based
  validation at boundaries are prohibited.
- **The cast is confined to the parser**: Type assertions that mint a branded
  type (`x as Brand` in TypeScript, `cast(Brand, x)` in Python) are permitted
  ONLY inside the parser module that owns that brand. Forging a brand anywhere
  else is prohibited.
- **No shotgun parsing**: A given piece of data MUST be parsed once, at its
  boundary. Re-checking already-parsed values with scattered defensive `if`
  statements is prohibited.

## Output

The core flow writes `.specify/memory/constitution.md`. This layer edits that
file in place to enforce the section above, leaving every other section — including
governance sections injected by other stacked presets — untouched.
