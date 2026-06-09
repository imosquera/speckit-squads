---
description: "Composable wrapper for /speckit-plan that trims the documentation tree produced by the stock command."
---

## Wrapper Layer

This preset wraps the stock `/speckit-plan` command. Keep the stock flow for prerequisites, artifact loading, planning decisions, validation, and hooks. Apply the documentation-tree rule below when the core command writes the plan.

### Documentation Rule

In the **Project Structure → Documentation (this feature)** subsection, keep the plan-scoped artifacts that matter for the minimal flow:

- `spec.md`
- `plan.md`
- `research.md`
- `tasks.md`

Omit `data-model.md`, `quickstart.md`, and `contracts/` from the tree and do not generate those files unless the feature genuinely needs them.

If the feature truly needs one of the omitted artifacts, write it ad hoc inside `plan.md` as a section instead of creating a separate file.

### Core Flow

{CORE_TEMPLATE}
