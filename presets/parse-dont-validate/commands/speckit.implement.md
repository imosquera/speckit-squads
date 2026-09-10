---
description: "Run /speckit-implement under Parse, Don't Validate discipline"
strategy: "wrap"
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Wrapper Layer

This preset wraps `/speckit-implement` (and any inner wrapper the core-flow seam
expands to). It honors one design discipline while code is written, then runs
**one mandatory scan gate** after the core flow, before reporting completion. It
does not change how tasks are executed.

### Design discipline (applies while code is written)

Parse, don't validate. A validator says "this is fine, continue" and throws the
proof away the instant it returns; a parser takes a blob and returns either a
**more precise type** or a typed error. Encode what you checked in the type so
future code never re-checks.

Whenever this run touches code that ingests untrusted data (network, disk, env,
user input, `JSON.parse` / `json.loads`), prefer parsing over validating. The
principle is language-general; apply the idioms of whichever language you write:

1. **Boundary is untyped-safe, domain is precise.** Untrusted input enters as
   `unknown` (TypeScript) — never `any` — or as a value immediately fed to a
   parser (Python), never left as `Any`. `JSON.parse` returns `any` and
   `json.loads` returns `Any`; treat their output as raw until a parser has run.
2. **Parse at the boundary into branded / nominal domain types.** Turn `string`
   into `Email`, `number`/`int` into `UserId` (TypeScript: a non-exported
   `unique symbol` brand or a schema library's `.brand()`; Python: `NewType`, a
   pydantic/attrs model, or a frozen dataclass). Illegal states become
   unrepresentable; downstream code trusts the type instead of re-checking.
3. **Parsers return a discriminated Result, not a boolean and not a throw.**
   TypeScript: a `{ kind: "ok" | "err" }` union so failure is visible in the
   signature and exhaustiveness (`never`-narrowing) catches missing cases.
   Python: return the parsed model or raise a single typed parse error at the
   boundary — do not add boolean `isValid*` / `is_valid_*` / `validate*`
   functions that callers must remember to re-run.
4. **The cast is confined to the parser.** `x as Brand` (TS) / `cast(Brand, x)`
   (Python) is the one sanctioned lie, allowed only inside the parser module
   that owns that brand. Never forge a brand elsewhere.
5. **A schema library is welcome.** Zod / valibot / io-ts (TS) and pydantic /
   attrs / msgspec (Python) satisfy this discipline and are preferred over
   hand-rolled casts when the project already has one. The library is a tool;
   the boundary discipline is still yours.

Respect any project constitution and existing conventions. If the feature has no
TypeScript or Python surface, this discipline is a no-op and you proceed with the
stock flow.

### Core Flow

Apply the discipline above to any TypeScript or Python written by the flow below.

{CORE_TEMPLATE}

### Mandatory anti-pattern scan (runs AFTER all task execution)

After the entire core flow above finishes, gate completion on a deterministic scan of the
TypeScript/Python changed during this run:

1. **Review the discipline items** the scan enforces:

   ```sh
   python3 .specify/presets/parse-dont-validate/scripts/python/parse_dont_validate.py checklist
   ```

2. **Scan the changed files.** This is the whole invocation — one command, from
   anywhere in the checkout:

   ```sh
   python3 .specify/presets/parse-dont-validate/scripts/python/parse_dont_validate.py scan --new-only
   ```

   With no paths the script inspects the git change set — working-tree changes
   **plus** work already committed on the current branch, so the gate still
   fires even if a post-implement hook has committed the implementation. It
   anchors at the git worktree root itself, so it cannot silently scan one file
   because you started in a subdirectory. `--new-only` re-scans the base ref's
   copy of the same files and subtracts every finding that reproduces there, so
   what you get back is what *this run* introduced — do not hand-verify findings
   against `main` yourself. Pass explicit paths/dirs to narrow, or `--base
   <ref>` to pin the branch base (needed only when the base cannot be
   auto-detected; `--new-only` exits `3` and says so).

   Drop `--new-only` to see the pre-existing findings too — informative, but
   never a reason to hold up this feature.

   **A scan that examined nothing never exits zero.** Exit `2` is a bad
   invocation (an unknown option, `--base` with no ref); exit `3` is a scan that
   could not run (missing `node`/`typescript`, paths that resolved to no file,
   a cwd outside any git worktree); exit `4` is an empty *input* — the change
   set holds no TypeScript or Python. Read the message and fix the call. Never
   invoke `scripts/node/pdv_ts_scan.cjs` yourself: it takes a JSON job on stdin
   and ignores file arguments, so a direct call with filenames used to print an
   empty findings list that read exactly like a pass.

   Both languages are analysed as real ASTs. Scanning **TypeScript** requires
   `node` on PATH and `typescript` installed in the project (the Node helper
   uses the TypeScript Compiler API). If the scanner exits `3` with a message
   that `typescript` is missing, install it (`npm i -D typescript`) and re-run —
   do not treat a missing parser as a pass.

3. **Resolve every finding.** For each reported `PDVxxx`, either:
   - **Fix it** — replace the validator / `any` / `Any` / stray cast with a
     parser that returns a precise type (this is the default and preferred
     outcome), or
   - **Waive it at the boundary** — if the finding is a legitimate narrowing
     cast or deserialization *inside the parser module*, add a
     `parse-dont-validate: allow PDVxxx (<reason>)` comment on that line (`//`
     for TypeScript, `#` for Python). Waive only at the trusted parser boundary;
     a waiver anywhere else is the bug this preset exists to catch.

   Re-run `scan --new-only` until it exits zero. **Do not report completion while it exits
   non-zero.**

If the run produced no TypeScript or Python, `scan` exits `4` saying nothing was
scanned. That is the one non-zero exit you may proceed past — and only after
confirming this run really wrote no TypeScript or Python; say so in the
completion report.

## Failure Policy

- A non-zero exit from `parse_dont_validate.py scan --new-only` is a hard stop on reporting
  completion. Exit `1` means findings: fix the flagged code or add a boundary
  waiver, then re-scan. Exits `2`/`3` mean the gate never ran — fix the
  invocation or the environment and run it; they are not a pass. Exit `4` means
  nothing was scanned, which is a pass only for a run with no TypeScript or
  Python in it.
- Do not silence a finding by deleting the offending line's functionality, by
  widening a type to escape the regex, or by waiving outside a parser module.
  The point is a real parser at the boundary, not a green scan.
- If the feature has no TypeScript or Python, do not fabricate parsing work —
  the gate is a no-op.

## Completion Report

On success, include:
- The normal `/speckit-implement` completion summary from the core flow.
- Whether the parse-don't-validate scan ran and that it exited zero.
- Any findings that were fixed (what became a parser) and any that were waived
  at a parser boundary (with the reason).
