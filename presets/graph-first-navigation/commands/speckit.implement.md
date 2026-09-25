---
description: "Scope renames, signature changes, and type changes with the graph before the first edit, then catch every call site with the typecheck"
strategy: "wrap"
---

## Wrapper Layer

This preset wraps `/speckit-implement`. It adds one obligation, before any
implementation work starts: renames, signature changes, and type changes are
scoped with the **knowledge graph** before the first edit, and every call site
is then caught by **one** run of the project's typecheck — not discovered by
editing blind and compiling in a loop.

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
   check is load-bearing here more than anywhere else. `STALE` → rebuild with
   the command the verdict printed, path and all (`graphify update <this
   worktree>`) and re-check; a bare `graphify update` rebuilds whichever
   project the CWD resolves to, which from a worktree is regularly another one.
   `UNKNOWN` → freshness is unanswerable, not failed; carry on and treat only
   negative findings ("nothing else calls this") as unverified. `ABSENT` → no
   graph in this project; build one (`graphify update <this worktree>`), and
   use grep only until it exists — and say which.

2. **Enumerate the blast radius of every identity-changing edit** — every
   rename, signature change, type change, moved export, or deleted symbol the
   tasks call for.

   Scope each one with the graph:

   ```bash
   graphify query "what calls <symbol>"
   graphify query "what imports <module>"
   graphify explain "<module>"
   ```

   The graph gives the shape of the blast radius — which modules and symbols
   depend on the one changing — so the edit plan covers them before the first
   keystroke. Never act on a *negative* answer ("nothing else calls this")
   from a `STALE` or `UNKNOWN` graph; rebuild first.

3. **Record the scope** in the implementation notes or the task's progress entry
   before editing: symbol, instrument used (graph query, or grep with the
   reason), and the number of sites found. That record is what makes the later "everything
   updated" claim checkable.

4. **Then edit** — every site from the enumeration, in one pass.

5. **Then typecheck once** — the project's own `typecheck` script where it has
   one (`package.json`), `tsc --noEmit` otherwise. The compiler lists every call
   site the edit broke, precisely; fix those and re-run until clean. A breakage
   the scoping pass did not predict is a signal the pass was skipped or the
   graph was stale — re-run the pass, not just the compiler.

### Core Flow

{CORE_TEMPLATE}

### Failure Policy

- Do not discover the blast radius by editing blind and compiling in a loop.
  Scope with the graph first; the typecheck confirms and pins down call sites.
- Do not answer "is this symbol used anywhere else" with Grep while a fresh
  graph can answer it. If none is available, say so explicitly in the
  completion report — an unverified answer must be labelled.
- A `STALE` graph is a rebuild instruction, never a licence to fall back to grep.

### When grep is still correct here

Literal string and comment searches; config values and env-var names; text in
generated, vendored, or minified files; strings in languages or file formats
the graph does not model; and confirming an exact textual occurrence at a site
the graph already identified.

## Completion Report

On success, include:
- The freshness verdict, and whether a rebuild was needed.
- Each identity-changing edit, the instrument used to scope it, and the number
  of sites updated.
- Anything scoped without a graph answer, and why.
- The typecheck result after the edit.
- The normal `/speckit-implement` completion summary.
