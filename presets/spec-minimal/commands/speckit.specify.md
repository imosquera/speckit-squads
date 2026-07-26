---
description: "Composable wrapper for /speckit-specify that trims Assumptions, Key Entities, and Success Criteria out of spec.md."
---

## Wrapper Layer

This preset wraps the stock `/speckit-specify` command. Keep the stock workflow for branch/worktree setup, feature directory creation, template loading, checklist generation, hooks, and reporting. Apply the rules below when the core command renders the spec.

### Output Rules

After the stock command writes `spec.md`, run the deterministic section stripper:

```bash
.specify/presets/spec-minimal/scripts/bash/strip-spec-sections.sh "$SPECIFY_FEATURE_DIRECTORY/spec.md"
```

It removes `## Assumptions`, `### Key Entities`, and `## Success Criteria` (idempotently — safe to run repeatedly). Keep all other mandatory sections intact, including User Scenarios, Edge Cases, Functional Requirements, Functional Programming Constraints, and Platform Constraints.

### Core Flow

{CORE_TEMPLATE}
