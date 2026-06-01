# lite preset

Trims the markdown footprint of `/speckit-specify` and `/speckit-plan`.

## What it cuts

| Command | Default artifacts | Under `lite` |
|---|---|---|
| `/speckit-specify` | `spec.md` with all sections | `spec.md` minus **Assumptions**, **Key Entities**, and **Success Criteria** |
| `/speckit-plan` | `plan.md` + `research.md` + `data-model.md` + `quickstart.md` + `contracts/` | `plan.md` (+ `research.md` only if decisions were made) |

## Install

```bash
specify preset add --dev ~/Code/speckit-squads/presets/lite
```

## Stacking

Both overridden commands (`speckit.specify`, `speckit.plan`) are also replaced by the `worktree-isolation` preset. Whichever is installed with the lower priority number wins. If you want both behaviors (worktree `cd` enforcement **and** trimmed artifacts), you need to fold the lite-preset's instructions into worktree-isolation's command files rather than stack them.

## When NOT to use

- Features that introduce real new entities (use the default preset; `data-model.md` is genuinely useful).
- Public-facing APIs across service boundaries (use the default preset; `contracts/` is the source of truth).
- First feature in a new project (the full artifact set helps establish norms).
