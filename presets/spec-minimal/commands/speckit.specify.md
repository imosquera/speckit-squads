---
description: "Create spec.md in spec-minimal mode by default; pass --full to run the complete stock /speckit-specify flow. Spec-minimal mode also embeds a GitHub-safe inline HTML preview for UI-touching features."
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding.

## Mode Switch

Spec-minimal mode is the default. If `$ARGUMENTS` contains `--full`, remove that token from the arguments and run the canonical stock `/speckit-specify` behavior unchanged (including all standard sections such as Assumptions and Key Entities). Do not apply any spec-minimal trimming when `--full` is present.

## Pre-Execution Checks

Run the standard `before_specify` hook chain exactly as the canonical `/speckit-specify` does (this is what creates the worktree and `.specify/feature.json`). Do not skip it — this preset is about output trimming, not workflow shortcuts.

## Outline

1. Resolve the feature directory from `.specify/feature.json`. If the file is missing, the `before_specify` hook did not run — error and stop.

2. Render the spec from the standard `spec-template.md`, with these explicit deletions:

   - **DROP** the `## Assumptions` section entirely (do not output the header or any bullets).
   - **DROP** the `### Key Entities` section entirely. If the feature genuinely needs entity modeling, that belongs in a follow-up `/speckit-plan` cycle (which under the spec-minimal preset also skips `data-model.md`, so consider whether you really need entities at all).
   - **DROP** the `## Success Criteria` section entirely (do not output the header or any content).

3. Keep all other mandatory sections: User Scenarios (P1/P2/P3 as applicable), Edge Cases, Functional Requirements, Functional Programming Constraints, Platform Constraints.

4. If the feature touches user-facing UI, embed a self-contained inline HTML preview inside the spec as a requirement artifact.

    4a. Treat the feature as UI-touching if it references a page, screen, route, view, modal, sheet, drawer, popover, toast, banner, card, list, table, form, button, input, icon, badge, chip, avatar, navbar, sidebar, tab, accordion, visual state, layout, spacing, typography, color, theme, microcopy, onboarding, settings, dashboard, landing page, responsive behavior, or accessibility of a visible element.

    4b. If UI-touching, generate a self-contained HTML fragment that uses only inline `style="..."` attributes. No `<style>`, `<script>`, `<link>`, remote assets, or external fonts.

    4c. Insert the preview as a new top-level section titled `## UI Preview (Requirement)` immediately after `## User Scenarios & Testing` and before `## Functional Requirements`.

    4d. Use the sentinel block below so future updates can replace the preview idempotently:

    ```markdown
    ## UI Preview (Requirement)

    This preview is part of the requirement, not a suggestion. Any implementation
    that materially diverges from the visual intent below must be re-spec'd. The
    markup is GitHub-markdown-safe (inline styles only) and renders inline in
    GitHub, VS Code, and Obsidian previews.

    <details open>
       <summary><strong>Inline HTML preview</strong> (click to collapse)</summary>

   <!-- BEGIN: spec-minimal preset -->
    <div style="...">
       ...generated fragment...
    </div>
   <!-- END: spec-minimal preset -->

    </details>
    ```

    4e. When a Functional Requirement is directly expressed by a visible element in the preview, append `(see UI Preview)` to that requirement instead of restating the visual details in prose.

5. Write the result to `<feature_directory>/spec.md`.

6. Run the standard `after_specify` hook chain (e.g., `speckit.graphify.update`, `speckit.git.commit`) — the spec-minimal preset does not interfere with hooks.

## Rationale

- **Assumptions** is almost always either empty or a dumping ground for things that belong in the spec body or in `research.md`. Removing it forces relevant context into the right home.
- **Key Entities** without a corresponding `data-model.md` (which spec-minimal plan also skips) is duplicate noise. The Functional Requirements section already names the data the feature touches.
- **Success Criteria** as typically written are either obvious restatements of the Functional Requirements or untestable platitudes. Concrete acceptance signals belong in the tasks (as done-conditions on individual tasks), not as a separate spec section.
