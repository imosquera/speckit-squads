---
description: "Execute /speckit-plan, but require the Constitution Check section of plan.md to contain a direct quoted sentence from each constitution principle"
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Behavior

Execute the canonical stock `/speckit-plan` flow with **one mandatory change** to the Constitution Check section of the generated `plan.md`.

### Mandatory Quoted Constitution Check

When `.specify/memory/constitution.md` exists, the Constitution Check section of `plan.md` MUST contain, for **every** numbered principle in the constitution:

- The principle name / number as a sub-heading or bullet (e.g. `- **Principle III: Test-First Development**`).
- **A direct quoted sentence from the constitution body for that principle.** If you cannot quote it, you have not loaded it — stop, re-read `.specify/memory/constitution.md`, and try again. Paraphrases, summaries, and "follows the constitution" boilerplate are not acceptable.
- A verdict, exactly one of: `PASS`, `VIOLATES`, or `N/A`.
- If `VIOLATES`: a written justification naming the specific plan decisions that breach the principle, and the proposed mitigation or explicit waiver to be re-checked at `/speckit-implement` time.
- If `N/A`: a one-line justification for why the principle does not apply to this feature.

The blanket sentence "No violations" is forbidden — it does not prove the constitution was loaded. Quote-or-it-didn't-happen.

When `.specify/memory/constitution.md` does **not** exist, the Constitution Check section may state "No constitution defined" and the stock flow continues unchanged.

### Stock Flow

Everything else in the canonical stock `/speckit-plan` flow runs unchanged (Technical Context, Project Structure, Phase 0/1 artefacts as configured, etc.).

## Failure Policy

- If `plan.md` is written without a quoted entry for every principle in the constitution, return an error and mark the command as incomplete. The downstream `/speckit-implement` (especially when paired with the `constitution-audit` preset's implement override) will refuse to start.
- Do not silently downgrade this step to optional behaviour.

## Completion Report

On success, include:
- Whether the Constitution Check was quoted (and the count of principles covered)
- The normal stock `/speckit-plan` completion summary
