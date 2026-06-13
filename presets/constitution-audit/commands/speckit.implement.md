---
description: "Execute /speckit-implement, but block code-writing until a quoted, principle-by-principle constitution audit has been produced"
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Behavior

Execute the canonical stock `/speckit-implement` flow with **one mandatory change** to the prerequisite phase: the constitution read is no longer "IF EXISTS, read it" — it is "REQUIRED IF EXISTS, audit it in writing."

### Mandatory Constitution Audit (runs BEFORE any task execution)

When `.specify/memory/constitution.md` exists:

1. Read `.specify/memory/constitution.md` in full. Do not skim, do not summarise — load every numbered principle into context.
2. Resolve the feature directory (`.specify/feature.json.feature_directory`, falling back to the canonical lookup the stock flow uses).
3. Write `<feature-directory>/constitution-audit.md` containing, for **every** numbered principle in the constitution:
   - The principle name / number (e.g. `Principle III: Test-First Development`).
   - **A direct quoted sentence from the constitution body for that principle.** If you cannot quote it, you have not loaded it — stop, re-read the constitution, and try again. Paraphrases are not acceptable.
   - A verdict, exactly one of: `PASS`, `VIOLATES`, or `N/A`.
   - If `VIOLATES`: a written justification naming the specific tasks / files / decisions that breach the principle, and the proposed mitigation or explicit waiver.
   - If `N/A`: a one-line justification for why the principle does not apply to this feature.
4. Implementation MUST NOT begin until `constitution-audit.md` exists and every principle in the constitution is represented with either `PASS` or a justified `VIOLATES` / `N/A` entry. A `VIOLATES` entry is not a blocker by itself — it is an acknowledged, documented exception — but a missing or unquoted principle IS a blocker.

When `.specify/memory/constitution.md` does **not** exist, skip the audit and continue with the stock flow.

### Stock Flow

After the audit gate passes, execute the canonical stock `/speckit-implement` flow unchanged (prerequisite checks, task execution, normal hook handling, completion report).

## Failure Policy

- If the constitution exists but you cannot produce a complete quoted audit, return an error and mark the command as incomplete. Do not start implementing tasks.
- If `constitution-audit.md` is written without a quoted sentence for every principle, treat it as missing — re-run the audit step.
- Do not silently downgrade this step to optional behaviour.

## Completion Report

On success, include:
- Whether a constitution audit was performed (and the path to `constitution-audit.md` if so)
- Count of principles audited and the breakdown (PASS / VIOLATES / N/A)
- The normal stock `/speckit-implement` completion summary
