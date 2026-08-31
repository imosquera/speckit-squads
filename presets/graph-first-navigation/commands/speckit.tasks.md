---
description: "Derive task ordering and blast radius from the graph, not from grep"
strategy: "wrap"
---

## Wrapper Layer

This preset wraps `/speckit-tasks`. It composes over whichever layer owns the
task body (including `explicit-task-dependencies`, which **replaces** it). It
adds one obligation: the plan's `## Navigation` section is the authority for
which modules a task touches, and any structural question raised while writing
tasks is answered by the graph or the language server, not by a text search.

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

### Core Flow

{CORE_TEMPLATE}

### Navigation Pass (MANDATORY — runs after the core flow)

1. **Read `## Navigation` from `plan.md`.** If the section is missing and the
   project has a `graphify-out/` directory, that is a defect in the plan: run
   the queries yourself now (`graphify query "what calls <symbol>"`,
   `graphify query "what imports <module>"`) and write the section into
   `plan.md` before continuing.

2. **Check freshness before trusting it.**

   ```bash
   .specify/presets/graph-first-navigation/scripts/bash/graph-freshness.sh .
   ```

   `STALE` means rebuild (`graphify update`) and re-query — not fall back to
   grep. `ABSENT` means this project has no graph; skip this pass and say so.

3. **Fold callers and dependents into the task list.** Every caller or dependent
   the graph named for a module a task modifies must be covered by a task —
   updated, or explicitly recorded as unaffected with a one-line reason. A task
   list that changes a module while leaving a known dependent unmentioned is
   incomplete.

4. **Order by the graph's edges.** Where the graph shows module B depends on
   module A, B's task depends on A's. Use that to set task dependencies (and,
   under `explicit-task-dependencies`, wave assignment) rather than guessing
   from directory layout.

### Failure Policy

- Do not answer "which tasks does this touch" with a Grep sweep while a fresh
  graph exists. Grep may confirm an exact string; it does not establish an edge.
- Do not record "no dependents" from a stale graph.

### When grep is still correct here

Literal strings, comment and log text, config values, generated or vendored
files, and anything the graph does not model.

## Completion Report

On success, include:
- Whether `## Navigation` was present or had to be reconstructed.
- Any task added or reordered because of a graph edge.
- The normal stock `/speckit-tasks` completion summary.
