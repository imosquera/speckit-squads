# spec-minimal preset

Wraps `/speckit-specify` and `/speckit-plan` to trim the generated artifacts without replacing the stock command flow.

## What it cuts

| Command | Default artifacts | Under `spec-minimal` |
|---|---|---|
| `/speckit-specify` | `spec.md` with all sections | `spec.md` minus **Assumptions**, **Key Entities**, and **Success Criteria** |
| `/speckit-plan` | `plan.md` + `research.md` + `data-model.md` + `quickstart.md` + `contracts/` | `spec.md`, `plan.md`, `tasks.md`, optionally `quickstart.md` — `research.md`, `data-model.md`, and `contracts/` are forbidden |

This preset does one thing: artifact minimalism. The inline HTML UI preview lives in the separate `spec-ui-preview` preset, and GitHub issue sync lives in the `git` extension (`/speckit-git-issue`, on the `after_specify` hook).

## How enforcement works

This is the canonical description — `preset.yml` and both command files reference it rather than restating it.

Enforcement has two halves:

1. **The prompt rule prevents.** `commands/speckit.plan.md` carries a mandatory, no-exceptions rule: the agent must never create `research.md`, `data-model.md`, or `contracts/` in the first place. Content that would have gone into one of those paths is inlined as a section of `plan.md` instead.
2. **The post-flight enforcer guarantees.** As the last step of every plan run, `scripts/bash/enforce-minimal-tree.sh "$SPECIFY_FEATURE_DIRECTORY"` runs. It is self-healing rather than read-only: if a forbidden artifact made it to disk anyway, the script folds its content into `plan.md` under an `## Inlined from <name>` heading — inside an idempotent `<!-- BEGIN: spec-minimal inlined <name> -->` / `<!-- END: ... -->` sentinel block — and then deletes the artifact. No content is lost and no broken tree is left behind.

Exit codes: `0` means the tree is clean (healing may have happened, and is reported); `1` means healing was required but impossible — for example `plan.md` is missing, in which case nothing is removed; `2` means bad usage.

Unknown top-level entries are **not** failures. The enforcer emits a `warning:` on stderr and carries on, so a checklist or other file legitimately written by a stacked preset never breaks the run. Nothing is ever pre-created on disk.

## Install

```bash
specify preset add --dev ~/Code/speckit-squads/presets/spec-minimal
```

## Stacking

`spec-minimal` composes with the stock `speckit.specify` and `speckit.plan` flows instead of replacing them, so it stacks cleanly with implement-focused presets such as `worktree-isolation` and `graphify-on-implement`.

Presets that wrap the *same* command nest rather than collide: the engine orders wrappers by priority ascending, then alphabetically by preset id, and each wrapper's core-flow seam expands to the next one in. That makes `spec-minimal` + `spec-ui-preview` + `constitution-audit` a valid stack — each layer sees the stock flow (plus the inner layers) at its seam.

## When NOT to use

- Features that introduce real new entities and need a standalone `data-model.md` (this preset forbids it).
- Public-facing APIs across service boundaries that need a `contracts/` source of truth (forbidden here).
- First feature in a new project (the full artifact set helps establish norms).
