---
description: "Execute /speckit-implement, then block completion until a quoted constitution audit of the written code has been produced and validated by a deterministic script"
---

## Behavior

Execute the core implement flow with **one mandatory audit gate** on the code it produces.

### Core Flow

Run the core implement flow first so that the code the audit covers actually
exists. The core-flow seam below is also the chaining point that lets other
presets wrap this command: when composed, that seam expands to the next inner
wrapper and ultimately the stock flow.

{CORE_TEMPLATE}

### Mandatory Constitution Audit (runs AFTER all task execution)

After the core flow finishes, when `.specify/memory/constitution.md` exists:

1. **List the principles** the audit must cover:

   ```sh
   python3 .specify/presets/constitution-audit/scripts/python/constitution_audit.py list
   ```

   Each printed line is one principle heading you MUST cover in the audit.

2. **Write the audit** to `<feature-directory>/constitution-audit.md` (feature directory comes from `.specify/feature.json.feature_directory`). Audit the code that was **actually written** during this run. For every principle listed above, write a section containing:
   - The principle heading text (so the validator can locate the section).
   - **A direct quoted span (>= 4 words) taken verbatim from that principle's body in the constitution.** Use double quotes, backticks, or a `>` blockquote. Paraphrases will fail validation.
   - A verdict line containing exactly one of: `PASS`, `VIOLATES`, or `N/A`.
   - If `VIOLATES`: a written justification naming the breaching tasks / files / decisions and the proposed mitigation or explicit waiver.
   - If `N/A`: a one-line justification for why the principle does not apply.

3. **Validate the audit** deterministically:

   ```sh
   python3 .specify/presets/constitution-audit/scripts/python/constitution_audit.py validate <feature-directory>/constitution-audit.md
   ```

   If this exits non-zero, the audit is incomplete or contains fabricated quotes. Fix the flagged entries and re-run validation. **Do not report completion until this command exits zero.**

When `.specify/memory/constitution.md` does **not** exist, skip the audit.

## Failure Policy

- A non-zero exit from `constitution_audit.py validate` is a hard stop on reporting completion. The implementation has run, but the audit must pass before the task is considered done.
- If the audit surfaces `VIOLATES` verdicts against the code just written, fix the breaching code (or record an explicit waiver in the audit) before reporting completion.
- The script enforces the quote-substring check; the LLM cannot work around it by paraphrasing or inventing plausible-sounding quotes.

## Completion Report

On success, include:
- The normal completion summary from the core flow
- Whether a constitution audit was performed (path to `constitution-audit.md` if so)
- Confirmation that `constitution_audit.py validate` exited zero
- Any `VIOLATES` verdicts and how they were resolved (fix or waiver)
