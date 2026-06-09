# spec-minimal preset

Wraps `/speckit-specify` and `/speckit-plan` to trim the generated artifacts without replacing the stock command flow.

## What it cuts

| Command | Default artifacts | Under `spec-minimal` |
|---|---|---|
| `/speckit-specify` | `spec.md` with all sections | `spec.md` minus **Assumptions**, **Key Entities**, and **Success Criteria**, plus an inline HTML preview for UI-touching features |
| `/speckit-plan` | `plan.md` + `research.md` + `data-model.md` + `quickstart.md` + `contracts/` | `plan.md` (+ `research.md` only if decisions were made) |

## Install

```bash
specify preset add --dev ~/Code/speckit-squads/presets/spec-minimal
```

## Stacking

The `spec-minimal` preset can be stacked with implement-focused presets (for example `worktree-isolation` and `graphify-on-implement`) without command collisions because it composes with the stock `speckit.specify` and `speckit.plan` flows instead of replacing them.

## When NOT to use

- Features that introduce real new entities (use the default preset; `data-model.md` is genuinely useful).
- Public-facing APIs across service boundaries (use the default preset; `contracts/` is the source of truth).
- First feature in a new project (the full artifact set helps establish norms).
