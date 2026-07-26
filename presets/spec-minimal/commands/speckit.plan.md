---
description: "Composable wrapper for /speckit-plan that holds the documentation tree to spec.md, plan.md, tasks.md, and optional quickstart.md via a mandatory prompt rule plus a self-healing post-flight enforcer."
---

## Wrapper Layer

This preset wraps the stock `/speckit-plan` command (and any inner wrapper, such
as the constitution-audit Constitution Check gate, that the core flow expands
to). It enforces a strictly minimal artifact tree.

Enforcement has two halves — the prompt rule below prevents, and the post-flight
enforcer guarantees. `presets/spec-minimal/README.md` is the canonical
description of the mechanism; do not restate it elsewhere.

### Documentation Rule (MANDATORY — NO EXCEPTIONS)

The feature directory MUST contain ONLY these files at the top level:

- `spec.md`
- `plan.md`
- `tasks.md`
- `quickstart.md` (optional but allowed)

`research.md`, `data-model.md`, and `contracts/` **MUST NOT be created** — not as
files, not as directories, not in any form. There is no escape hatch. Any content
that the stock flow would have written into one of those paths MUST instead be
inlined as a section of `plan.md`.

When you reach any step of the core flow that would create `research.md`,
`data-model.md`, or `contracts/`, do not create the path. Fold its content into
`plan.md` and continue.

In the **Project Structure → Documentation (this feature)** subsection of
`plan.md`, list exactly the allowed files and nothing else.

### Core Flow

{CORE_TEMPLATE}

### Post-Flight Enforcement (MANDATORY — LAST STEP)

After the entire core flow above has completed, and before reporting success, run
the enforcer as the final step:

```bash
.specify/presets/spec-minimal/scripts/bash/enforce-minimal-tree.sh "$SPECIFY_FEATURE_DIRECTORY"
```

The enforcer is self-healing: if a forbidden artifact is on disk it folds the
content into `plan.md` under an `## Inlined from <name>` heading (inside an
idempotent sentinel block) and then deletes the artifact. Unknown top-level
entries only produce a `warning:` on stderr — they never fail the run, so
stacking with other presets is safe.

Handle the exit code as follows:

- **`0`** — the tree is clean. If the enforcer reported that it folded and
  removed any artifacts, tell the user exactly which ones were inlined into
  `plan.md` and removed, then report success.
- **`1`** — healing was required but impossible (for example `plan.md` is
  missing, in which case nothing was removed). Surface the error verbatim, fix
  the underlying problem, and re-run the enforcer. Do not report success.
- **`2`** — bad usage: the invocation above is wrong. Fix the call and re-run.

Only report success once the enforcer exits `0`.
