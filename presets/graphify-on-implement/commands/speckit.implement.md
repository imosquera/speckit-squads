---
description: "Composable wrapper for /speckit-implement that always runs a mandatory graphify refresh once implementation has completed."
---

## Wrapper Layer

This preset wraps the stock `/speckit-implement` command (and any inner wrapper,
such as the implement-prelude-skills layer, that the core-flow seam below expands
to). It adds one mandatory post-implementation step: a knowledge-graph refresh.

Run the core flow first, unchanged — all prerequisite checks, checklist gating,
task execution behavior, and extension hook handling stay exactly as the inner
layers define them. Then run the graph refresh below.

### Core Flow

{CORE_TEMPLATE}

### Graph Refresh (MANDATORY — LAST STEP)

After the entire core flow above has completed — every task executed and marked
`[X]`, every post-execution hook dispatched — and before reporting success, run
the graph refresh as the final step:

1. Resolve the worktree root to graph:
   - Prefer the `worktree_path` value in `.specify/feature.json`.
   - If that file or key is missing, or the path does not exist, use the current
     repository root.
2. Execute `graphify update <resolved-worktree-path>`.

This step is mandatory. It is not conditional on what the core flow did, and it
must not be reordered ahead of implementation.

### Failure Policy

- If the `graphify` CLI is unavailable, unauthenticated, or the update command
  exits non-zero, return an error and mark the overall command as incomplete.
- Do not silently skip this step or downgrade it to optional behavior.

### Completion Report

Only report success once `graphify update` has succeeded. In addition to whatever
the core flow reports, include:

- The path used for the graph refresh
- Confirmation that `graphify update` ran as the final step
- Readiness for follow-up commands
