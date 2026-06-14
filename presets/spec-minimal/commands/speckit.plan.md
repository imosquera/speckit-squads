---
description: "Composable wrapper for /speckit-plan that strictly enforces a minimal documentation tree: spec.md, plan.md, tasks.md, requirements.md."
---

## Wrapper Layer

This preset wraps the stock `/speckit-plan` command. Keep the stock flow for prerequisites, artifact loading, planning decisions, validation, and hooks. The **Documentation Rule** below is a hard constraint and overrides any conflicting stock instruction.

### Documentation Rule (MANDATORY — NO EXCEPTIONS)

The feature directory MUST contain ONLY these four files at the top level:

- `spec.md`
- `plan.md`
- `tasks.md`
- `requirements.md`

You MUST NOT create any of the following, under any circumstances:

- `research.md`
- `data-model.md`
- `quickstart.md`
- `contracts/` (directory or any file inside it)
- any other `.md` file or subdirectory beyond the four listed above

This rule is **enforced**, not advisory. There is no "unless truly needed" escape hatch. If the stock `/speckit-plan` template instructs you to write any forbidden file, ignore that instruction. If the feature genuinely requires content that would have lived in a forbidden file (e.g. an entity model, a contract sketch, research notes), inline it as a section inside `plan.md` or `requirements.md` — never as a separate file.

In the **Project Structure → Documentation (this feature)** subsection of `plan.md`, list exactly these four files and nothing else.

### Enforcement Check (run before reporting success)

Before the command reports completion, verify the feature directory:

1. List the contents of the feature directory.
2. If any file or directory other than `spec.md`, `plan.md`, `tasks.md`, `requirements.md` exists at the top level, DELETE it (or fold its content into `plan.md` / `requirements.md` first if it contains useful material).
3. Specifically check for and remove: `research.md`, `data-model.md`, `quickstart.md`, `contracts/`.
4. Only report success once the directory listing matches the allowed set exactly.

If you cannot satisfy this constraint, fail loudly with an explicit error rather than silently producing extra files.

### Core Flow

{CORE_TEMPLATE}
