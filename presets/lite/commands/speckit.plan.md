---
description: "Create plan.md in lite mode by default; pass --full to run the complete stock /speckit-plan flow"
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding.

## Mode Switch

Lite mode is the default. If `$ARGUMENTS` contains `--full`, remove that token from the arguments and run the canonical stock `/speckit-plan` behavior unchanged (including generation of any standard plan artifacts). Do not apply lite skips when `--full` is present.

## Pre-Execution Checks

Run the standard `before_plan` hook chain. Do not skip it.

## Outline

1. Resolve the feature directory from `.specify/feature.json`. Error if missing.

2. Load context: `.specify/memory/constitution.md` and `<feature_directory>/spec.md`.

3. Write `<feature_directory>/plan.md` from the standard `plan-template.md`. In the **Project Structure → Documentation (this feature)** subsection, replace the documentation tree with the lite-preset version:

   ```text
   specs/[###-feature]/
   ├── plan.md              # This file (/speckit-plan command output)
   ├── research.md          # Phase 0 output — only if decisions need persisting
   └── tasks.md             # Phase 2 output (/speckit-tasks command)
   ```

   Do not list `data-model.md`, `quickstart.md`, or `contracts/` in the tree, and do not create those files. If `/speckit-plan` was previously run under the default preset and those files already exist on disk, leave them in place (do not delete) but do not regenerate them.

4. Write `<feature_directory>/research.md` **only if** Phase 0 surfaced non-trivial decisions worth persisting (e.g., a library was chosen between alternatives, a deprecation was navigated, a perf characteristic was measured). For purely-mechanical features with no real research, omit `research.md` entirely.

5. Run the standard `after_plan` hook chain.

## Explicit Skips

- `data-model.md` — entity diagrams. The feature spec's Functional Requirements already enumerate the data shape; a separate file is duplication for most features.
- `quickstart.md` — usually duplicates the project README or stays empty. If a runbook is genuinely needed, write it directly into the project README.
- `contracts/` — API contracts. Only meaningful for cross-service work. For intra-app features, the TypeScript types or function signatures are the contract; codifying them in markdown is double-bookkeeping.

If the feature truly needs one of these (e.g., a new public HTTP API), generate it ad-hoc inside `plan.md` as a section rather than as a separate file.
