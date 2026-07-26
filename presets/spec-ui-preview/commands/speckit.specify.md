---
description: "Composable wrapper for /speckit-specify that adds a mandatory, GitHub-safe inline HTML UI preview section for UI-touching features."
---

## Wrapper Layer

This preset wraps the stock `/speckit-specify` command. Keep the stock workflow for branch/worktree setup, feature directory creation, template loading, checklist generation, hooks, and reporting. Apply the rules below when the core command renders the spec.

It also composes with any other wrapper around `speckit.specify` — notably `spec-minimal`. When two wrappers are stacked, the engine orders them by install priority ascending, then alphabetically by preset id; whichever comes first ends up as the outer layer. Ordering does not matter here: the two layers are independent. `spec-minimal`'s section stripper only removes `## Assumptions`, `### Key Entities`, and `## Success Criteria`, and never touches the `## UI Preview (Requirement)` section this preset writes.

### UI Preview Layer

If the feature touches user-facing UI, insert a new top-level `## UI Preview (Requirement)` section immediately after `## User Scenarios & Testing` and before `## Functional Requirements`.

The preview must be a self-contained HTML fragment with inline `style="..."` attributes only. Do not use `<style>`, `<script>`, `<link>`, remote assets, or external fonts.

Use this sentinel block so updates can replace the preview idempotently:

```markdown
## UI Preview (Requirement)

This preview is part of the requirement, not a suggestion. Any implementation
that materially diverges from the visual intent below must be re-spec'd. The
markup is GitHub-markdown-safe (inline styles only) and renders inline in
GitHub, VS Code, and Obsidian previews.

<details open>
  <summary><strong>Inline HTML preview</strong> (click to collapse)</summary>

<!-- BEGIN: spec-ui-preview preset -->
<div style="...">
  ...generated fragment...
</div>
<!-- END: spec-ui-preview preset -->

</details>
```

When a Functional Requirement is directly expressed by a visible element in the preview, append `(see UI Preview)` instead of repeating the visual details in prose.

If the feature does not touch user-facing UI, add nothing — do not emit an empty preview section.

### Core Flow

{CORE_TEMPLATE}
