---
description: "Create spec.md from a feature description, omitting Assumptions and Key Entities sections (lite preset)"
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding.

## Pre-Execution Checks

Run the standard `before_specify` hook chain exactly as the canonical `/speckit-specify` does (this is what creates the worktree and `.specify/feature.json`). Do not skip it — this preset is about output trimming, not workflow shortcuts.

## Outline

1. Resolve the feature directory from `.specify/feature.json`. If the file is missing, the `before_specify` hook did not run — error and stop.

2. Render the spec from the standard `spec-template.md`, with these explicit deletions:

   - **DROP** the `## Assumptions` section entirely (do not output the header or any bullets).
   - **DROP** the `### Key Entities` section entirely. If the feature genuinely needs entity modeling, that belongs in a follow-up `/speckit-plan` cycle (which under the lite preset also skips `data-model.md`, so consider whether you really need entities at all).

3. Keep all other mandatory sections: User Scenarios (P1/P2/P3 as applicable), Edge Cases, Functional Requirements, Functional Programming Constraints, Platform Constraints, Success Criteria.

4. Write the result to `<feature_directory>/spec.md`.

5. Run the standard `after_specify` hook chain (e.g., `speckit.graphify.update`, `speckit.git.commit`) — the lite preset does not interfere with hooks.

## Rationale

- **Assumptions** is almost always either empty or a dumping ground for things that belong in the spec body or in `research.md`. Removing it forces relevant context into the right home.
- **Key Entities** without a corresponding `data-model.md` (which lite plan also skips) is duplicate noise. The Functional Requirements section already names the data the feature touches.
