---
description: "Scope renames, signature changes, and type changes with the language server before the first edit"
strategy: "wrap"
---

## Wrapper Layer

This preset wraps `/speckit-implement`. It adds one obligation, before any
implementation work starts: renames, signature changes, and type changes are
scoped with the **language server**, not discovered afterwards by compiling in
a loop. The language server has to be **reachable** for that to be a real
obligation rather than a slogan, so step 2 probes for it and names the fallback
when it is absent.

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

### Scoping Pass (MANDATORY — FIRST STEP, before any edit)

1. **Freshness first.**

   ```bash
   .specify/presets/graph-first-navigation/scripts/bash/graph-freshness.sh .
   ```

   A feature worktree diverges from the commit the graph was built at, so this
   check is load-bearing here more than anywhere else. `STALE` → rebuild
   (`graphify update`) and re-check. `ABSENT` → no graph in this project; fall
   back to the language server if the probe in step 2 finds it, and to grep if
   it does not — and say which.

2. **Enumerate the blast radius of every identity-changing edit** — every
   rename, signature change, type change, moved export, or deleted symbol the
   tasks call for.

   **Establish availability with the probe, not with a failed call:**

   ```bash
   command -v typescript-language-server
   ```

   Not found → do not call the LSP tool; it fails with `ENOENT`. Use the graph
   and grep, and record that provenance. `CLAUDE.md` has the bootstrap that makes
   the probe succeed — this preset's `post-install.sh` puts a resolver shim under
   that name on `PATH`; an `export PATH=…` from a shell tool never reaches the
   agent process the LSP tool spawns from. Found → the LSP tool is the
   **required** instrument:

   - `findReferences` — every reference to the symbol
   - `incomingCalls` — every caller of the function
   - `goToImplementation` — every implementer of the interface
   - `goToDefinition` — the one true definition, before assuming there is one

   For module- and system-level questions ("what reads this collection", "what
   depends on this package"), use the graph: `graphify query "what imports
   <module>"`, `graphify explain "<module>"`.

   **Warm it before believing a negative.** `typescript-language-server` loads a
   project lazily, so the first cross-file `findReferences` can report "2
   references across 1 file" for a symbol that has 26 across 4 once the callers
   are loaded. Run a query inside the target file first, and cross-check any
   "nothing else uses this" against `graphify query` before acting on it — the
   same rule the graph's own freshness check exists to enforce.

3. **Record the scope** in the implementation notes or the task's progress entry
   before editing: symbol, instrument used (LSP operation or graph query), and
   the number of sites found. That record is what makes the later "everything
   updated" claim checkable.

4. **Then edit** — every site from the enumeration, in one pass.

Running `tsc --noEmit` afterwards is a **verification** step, not a discovery
step. If the compiler surfaces a breakage the scoping pass missed, treat it as a
signal the pass was skipped or the graph was stale, and re-run it.

### Core Flow

{CORE_TEMPLATE}

### Failure Policy

- Do not discover the blast radius by compiling in a loop when an LSP tool is
  available. That is the failure mode this preset exists to remove.
- Do not answer "is this symbol used anywhere else" with Grep while a language
  server or a fresh graph can answer it. If neither is available, say so
  explicitly in the completion report — an unverified answer must be labelled.
- A `STALE` graph is a rebuild instruction, never a licence to fall back to grep.

### When grep is still correct here

Literal string and comment searches; config values and env-var names; text in
generated, vendored, or minified files; strings in languages or file formats
neither the graph nor the language server models; and confirming an exact
textual occurrence at a site the graph or LSP already identified.

## Completion Report

On success, include:
- The freshness verdict, and whether a rebuild was needed.
- Each identity-changing edit, the instrument used to scope it, and the number
  of sites updated.
- Anything scoped without an LSP/graph answer, and why.
- The normal `/speckit-implement` completion summary.
