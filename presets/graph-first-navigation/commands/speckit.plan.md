---
description: "Record graph-derived callers and dependents for every module the plan touches"
strategy: "wrap"
---

## Wrapper Layer

This preset wraps `/speckit-plan`. It adds one mandatory pass: the modules the
change touches are looked up in the knowledge graph, and the answers are
recorded in `plan.md` under a `## Navigation` section. A plan that lists
affected files without that provenance is incomplete.

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

### Freshness gate (MANDATORY — before the core flow)

```bash
.specify/presets/graph-first-navigation/scripts/bash/graph-freshness.sh .
```

- `ABSENT` — this project has no graph. Skip the Navigation pass entirely, say
  so in the completion report, and run the core flow unchanged. Grep is the
  correct instrument here.
- `STALE` — **rebuild the graph** (`graphify update`, or the `/graphify` skill
  with `--update`) and re-run the check. A stale graph does **not** license a
  fall back to grep; it licenses a rebuild. If the rebuild is impossible in
  this session (tool missing, unauthenticated), say so explicitly in
  `## Navigation` and mark every entry below it `provenance: unverified`.
- `FRESH` — proceed.

### Core Flow

Run the core plan flow first so the affected-module list exists.

{CORE_TEMPLATE}

### Navigation Pass (MANDATORY — runs after the core flow)

1. **Enumerate the modules the change touches** from the finished `plan.md` —
   every file, module, or symbol the plan says it will add, modify, or delete.

2. **Query the graph for each one.** Use the graph, not Grep/Glob:

   ```bash
   graphify query "what calls <symbol or module>"
   graphify query "what imports <module>"
   graphify explain "<module>"
   graphify path "<module A>" "<module B>"
   ```

   Where the module is TypeScript and the change is a rename, a signature
   change, or a type change, also enumerate exact call sites with the language
   server (`findReferences` / `incomingCalls` via the LSP tool). The graph gives
   the shape of the blast radius; the language server gives the precise list.

3. **Write `## Navigation` into `plan.md`**, one entry per module:

   ```markdown
   ## Navigation

   Graph freshness: <sha of built_at_commit> (FRESH at plan time)

   ### <module path>

   - **Callers:** <symbol/module list, or "none">
   - **Dependents:** <modules that import or read this, or "none">
   - **Reads/writes:** <collections, tables, endpoints the graph reports, or "none">
   - **Provenance:** graphify query | LSP findReferences | unverified (graph stale)
   ```

   "none" is a real answer and must be recorded as one — but only from a fresh
   graph. Never write "none" off a `STALE` verdict.

4. **Reconcile.** If the graph names a caller or dependent the plan does not
   account for, that is a gap in the plan, not a footnote: revise the plan's
   scope, task list, or risks to cover it before finishing.

### Failure Policy

- Do not invent callers, dependents, or "none" answers. Every line under
  `## Navigation` must come from a query actually run in this session.
- Do not substitute a Grep sweep for a graph query and label it graph
  provenance. If the graph could not be queried, write `unverified` and say why.
- The Navigation section is not optional when a graph exists. A plan without it
  is incomplete.

### When grep is still correct here

Literal strings, comment and log text, config values and env-var names,
generated or vendored files, and anything the graph does not model. Those
searches need no justification and no Navigation entry.

## Completion Report

On success, include:
- The freshness verdict, and whether a rebuild was needed.
- How many modules were queried and where the answers landed.
- Any caller or dependent the graph surfaced that changed the plan's scope.
- The normal stock `/speckit-plan` completion summary.
