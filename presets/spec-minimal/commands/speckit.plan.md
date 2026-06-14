---
description: "Composable wrapper for /speckit-plan that strictly enforces a four-file documentation tree (spec.md, plan.md, tasks.md, requirements.md) via filesystem blockers, not post-hoc cleanup."
---

## Wrapper Layer

This preset wraps the stock `/speckit-plan` command. The deterministic enforcement is delegated to two scripts so the rule is mechanical, not prompt-dependent.

### Documentation Rule (MANDATORY — NO EXCEPTIONS)

The feature directory MUST contain ONLY these four files at the top level:

- `spec.md`
- `plan.md`
- `tasks.md`
- `requirements.md`

`research.md`, `data-model.md`, `quickstart.md`, and `contracts/` MUST NOT be created. There is no escape hatch. Content that would have lived in those files MUST be inlined as a section of `plan.md` or `requirements.md`.

### Enforcement (deterministic, not prompt-dependent)

Run the pre-flight blocker BEFORE the stock plan flow executes:

```bash
.specify/presets/spec-minimal/scripts/bash/block-forbidden-artifacts.sh "$SPECIFY_FEATURE_DIRECTORY"
```

This pre-creates `research.md`, `data-model.md`, `quickstart.md` as empty directories and `contracts/` as a read-only directory, so any stock-flow attempt to write those names fails immediately with `EISDIR` or `EACCES`. Forbidden files are physically uncreatable for the duration of the run.

In the **Project Structure → Documentation (this feature)** subsection of `plan.md`, list exactly the four allowed files and nothing else.

Run the post-flight verifier AFTER the stock plan flow completes, before reporting success:

```bash
.specify/presets/spec-minimal/scripts/bash/verify-minimal-tree.sh "$SPECIFY_FEATURE_DIRECTORY"
```

This fails the run (non-zero exit) if any forbidden artifact ended up on disk, and cleans up the empty sentinel directories on success. If it exits non-zero, surface the error verbatim to the user — do not retry, do not silently delete, do not report success.

### Core Flow

{CORE_TEMPLATE}
