---
description: "Enforce a mandatory Functional Programming Paradigms section"
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
**Functional Programming Paradigms** section in `.specify/memory/constitution.md`
after the core flow has written it. It does not otherwise change the workflow.

Other presets may stack the same way and inject their own governance sections.
Never assume this preset owns the whole document.

### Core Flow

{CORE_TEMPLATE}

## Enforcement Rules (MANDATORY — after the core flow)

Once the entire core flow above has completed and the constitution has been
written, ensure the canonical section below exists **exactly once**.

- **Match on the section title, not on its number.** A section counts as
  already present if its heading ends with `Functional Programming Paradigms (MANDATORY)`,
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

### I. Functional Programming Paradigms (MANDATORY)

All implementation MUST follow functional programming discipline throughout the codebase.
No exceptions are permitted without an explicit governance amendment.

- **Pure functions**: Every function MUST be free of observable side effects and MUST NOT
  mutate state outside its own scope.
- **Higher-order functions**: `map`, `filter`, `reduce`, and function composition MUST replace
  imperative loops (`for`/`while`). Recursion or functional iterators MUST be used instead.
- **Referential transparency**: Any function call MUST be replaceable with its return value
  without altering program behavior. Functions that violate this are not permitted.
- **No shared mutable state**: All required data MUST be passed as arguments. Global or
  shared mutable variables are prohibited.
- **Declarative style**: Code MUST describe *what* is computed, not *how* iteration proceeds.

## Output

The core flow writes `.specify/memory/constitution.md`. This layer edits that
file in place to enforce the section above, leaving every other section — including
governance sections injected by other stacked presets — untouched.
