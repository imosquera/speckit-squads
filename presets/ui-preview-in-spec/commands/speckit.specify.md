---
description: Create or update the feature specification from a natural language feature description. Combines two preset behaviours — (1) Constitution v2.3.0 Principle VII worktree isolation (cd into the worktree returned by the before_specify hook before any spec write, and persist worktree_path in .specify/feature.json), and (2) when the feature touches user-facing UI, embed a self-contained inline HTML preview inside spec.md as a requirement artifact. This preset replaces speckit.specify, so it must reproduce — not skip — the worktree-isolation flow.
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Pre-Execution Checks

**Check for extension hooks (before specification)**:
- Check if `.specify/extensions.yml` exists in the project root.
- If it exists, read it and look for entries under the `hooks.before_specify` key.
- If the YAML cannot be parsed or is invalid, skip hook checking silently and continue normally.
- Filter out hooks where `enabled` is explicitly `false`. Treat hooks without an `enabled` field as enabled by default.
- For each remaining hook, do **not** attempt to interpret or evaluate hook `condition` expressions:
  - If the hook has no `condition` field, or it is null/empty, treat the hook as executable.
  - If the hook defines a non-empty `condition`, skip the hook and leave condition evaluation to the HookExecutor implementation.
- When constructing slash commands from hook command names, replace dots (`.`) with hyphens (`-`). For example, `speckit.git.commit` → `/speckit-git-commit`.
- For each executable hook, output the standard hook banner (optional vs mandatory) and wait for mandatory hooks to complete before proceeding to the Outline.
- If no hooks are registered or `.specify/extensions.yml` does not exist, skip silently.

## Outline

The text the user typed after `/speckit-specify` in the triggering message **is** the feature description. Assume you always have it available in this conversation even if `$ARGUMENTS` appears literally below. Do not ask the user to repeat it unless they provided an empty command.

Given that feature description, do this:

1. **Generate a concise short name** (2–4 words) for the feature, using the same rules as the stock command: extract meaningful keywords, prefer action-noun, preserve technical acronyms (OAuth2, API, JWT), keep it concise.

2. **Branch + worktree creation** (optional, via hook) — *worktree-isolation behaviour*:

   If a `before_specify` hook ran successfully in the Pre-Execution Checks above, it
   will have created the feature's git branch **and** a dedicated git worktree, and
   output JSON containing `BRANCH_NAME`, `FEATURE_NUM`, and `WORKTREE_PATH`. Per
   Constitution v2.3.0 Principle VII (Feature-Work Isolation), the primary checkout
   is **NOT** switched to the new branch — the worktree is the new home for all
   feature-scoped work.

   If the user explicitly provided `GIT_BRANCH_NAME`, pass it through to the hook so
   the branch script uses the exact value as the branch name (bypassing all
   prefix/suffix generation).

   **MANDATORY cd step**: Immediately after the hook returns, if `WORKTREE_PATH` is
   present and non-empty in the hook output, the agent MUST `cd` into that path
   before performing ANY filesystem writes for the new feature. Concretely: every
   subsequent shell invocation in this command must be prefixed
   `cd "${WORKTREE_PATH}" && ...` (or the equivalent for the host's tooling). All
   spec artifacts created in step 3 below — **including the UI-preview embed in
   step 6** — are written *inside the worktree*, not inside the primary checkout.
   The cd MUST be visible in the session log so that reviewers can confirm
   isolation post hoc.

   If the hook did NOT run (no `before_specify` hook is configured, or the hook
   produced no `WORKTREE_PATH`), the spec command MAY proceed in the primary
   checkout — but you SHOULD warn the user that Principle VII v2.3.0 expects
   worktree isolation, and offer to run `git worktree add` manually.

   The branch name does **not** dictate the spec directory name; see step 3.

3. **Create the spec feature directory** (inside the worktree):

   Specs live under the default `specs/` directory unless the user explicitly provides `SPECIFY_FEATURE_DIRECTORY`.

   Resolution order for `SPECIFY_FEATURE_DIRECTORY`:
   1. If the user explicitly provided `SPECIFY_FEATURE_DIRECTORY` (env var, argument, or configuration), use it as-is.
   2. Otherwise, auto-generate it under `specs/`:
      - Check `.specify/init-options.json` for `branch_numbering`.
      - If `"timestamp"`: prefix is `YYYYMMDD-HHMMSS` (current timestamp).
      - If `"sequential"` or absent: prefix is `NNN` (next available 3-digit number after scanning existing directories in `specs/`).
      - Construct the directory name: `<prefix>-<short-name>` (e.g., `003-user-auth` or `20260319-143022-user-auth`).
      - Set `SPECIFY_FEATURE_DIRECTORY` to `specs/<directory-name>`.

   Create the directory and spec file (**inside the worktree**, after the cd in step 2):
   - `mkdir -p SPECIFY_FEATURE_DIRECTORY`
   - Copy `.specify/templates/spec-template.md` to `SPECIFY_FEATURE_DIRECTORY/spec.md` as the starting point.
   - Set `SPEC_FILE` to `SPECIFY_FEATURE_DIRECTORY/spec.md`.
   - Persist the resolved paths to `.specify/feature.json` **inside the worktree**:

     ```json
     {
       "feature_directory": "<resolved feature dir>",
       "worktree_path": "<absolute path returned by the before_specify hook, or null if no hook ran>"
     }
     ```

     Recording `worktree_path` here lets `/speckit-clarify`, `/speckit-plan`,
     `/speckit-tasks`, and `/speckit-implement` resolve the worktree on a
     fresh-session resume without re-deriving it from the branch name. Per
     Principle VII, those commands SHOULD refuse to proceed when they detect a
     cwd mismatch.

   **IMPORTANT**:
   - You must only create one feature per `/speckit-specify` invocation.
   - The spec directory name and the git branch name are independent — they may be the same, but that is the user's choice.
   - The spec directory and file are always created by this command, never by the hook.

4. Load `.specify/templates/spec-template.md` to understand required sections.

5. Follow the stock execution flow:
   1. Parse user description from arguments. If empty: ERROR "No feature description provided".
   2. Extract key concepts (actors, actions, data, constraints).
   3. For unclear aspects, make informed guesses; mark with `[NEEDS CLARIFICATION: …]` only when (a) the choice meaningfully affects scope or UX, (b) multiple reasonable interpretations exist, (c) no reasonable default. Maximum 3 markers. Prioritise scope > security > UX > technical.
   4. Fill User Scenarios & Testing. If no clear user flow: ERROR.
   5. Generate Functional Requirements (each testable; document assumptions).
   5.5. **UI-touch check + inline HTML preview** — see step 6 below; perform it here, *between* generating Functional Requirements and writing `SPEC_FILE`.
   6. Define Success Criteria (measurable, technology-agnostic, verifiable).
   7. Identify Key Entities (if data involved).
   8. Return: SUCCESS.

6. **UI-touch check + inline HTML preview delta** (this preset's substantive addition):

   6a. **Detect UI touch.** Classify the feature as UI-touching if any of the following are true (use conservative judgement — when in doubt, treat as UI-touching):
   - The description references a page, screen, route, view, modal, sheet, drawer, popover, toast, banner, card, list, table, form, button, input, icon, badge, chip, avatar, navbar, sidebar, tab, accordion, or any other component noun.
   - It references a visual state: empty state, error state, loading state, success state, hover, focus, pressed, disabled.
   - It references layout, spacing, typography, color, theme, dark mode, light mode, copy/microcopy, iconography, illustration.
   - It references onboarding, settings, profile, dashboard, landing page, or any named user-facing surface in the product.
   - It references responsive behavior, mobile, tablet, desktop, breakpoints, or accessibility (a11y) of a visible element.

   If none of the above apply (e.g. backend-only, infra, tooling, doc-only, schema-only changes), **skip** the rest of step 6 and proceed to step 7.

   6b. **Produce the inline HTML preview.** If UI-touching, generate a self-contained HTML fragment that represents the *minimum viable visual rendering* of the requirement. Constraints (MANDATORY — GitHub markdown safety):
   - Use **only inline `style="…"` attributes**. **No `<style>` tags. No `<script>` tags. No `<link>` tags. No external assets** (no `src="https://…"`, no font CDNs, no remote images).
   - Allowed tags: `div`, `span`, `p`, `h1`–`h6`, `ul`, `ol`, `li`, `a`, `img` (only with `data:` URIs or omitted), `table`, `thead`, `tbody`, `tr`, `td`, `th`, `button`, `input` (presentational only — no `onclick`/handlers), `label`, `form` (presentational only), `section`, `header`, `footer`, `nav`, `main`, `article`, `aside`, `figure`, `figcaption`, `br`, `hr`, `strong`, `em`, `code`, `pre`, `svg` (inline only).
   - Embed any iconography or illustration as inline SVG inside the fragment, or omit it. Do not link to remote SVGs.
   - Use a fixed wrapper width (e.g. `max-width: 480px; margin: 0 auto;`) so the preview renders predictably inside the `<details>` block.
   - Keep the fragment self-contained: opening it in isolation (copy-pasting it into a blank HTML file) MUST render visually without errors.
   - Aim for ~30–120 lines. The preview is a *requirement sketch*, not a production component. Resist the urge to over-engineer.

   6c. **Embed the preview in `spec.md`** — note that `spec.md` lives at `${WORKTREE_PATH}/SPECIFY_FEATURE_DIRECTORY/spec.md`; the write occurs inside the worktree. Insert the preview as a new top-level section titled `## UI Preview (Requirement)` placed immediately after `## User Scenarios & Testing` and before `## Functional Requirements`. Format:

   ```markdown
   ## UI Preview (Requirement)

   This preview is part of the requirement, not a suggestion. Any implementation
   that materially diverges from the visual intent below must be re-spec'd. The
   markup is GitHub-markdown-safe (inline styles only) and renders inline in
   GitHub, VS Code, and Obsidian previews.

   <details open>
     <summary><strong>Inline HTML preview</strong> (click to collapse)</summary>

   <!-- BEGIN: ui-preview-in-spec preset -->
   <div style="…">
     …generated fragment…
   </div>
   <!-- END: ui-preview-in-spec preset -->

   </details>
   ```

   Notes:
   - `<details open>` ensures the preview is visible by default in GitHub.
   - The `<!-- BEGIN/END -->` sentinels let downstream tools and re-runs of this command locate and replace the fragment idempotently.
   - Leave **one blank line** between the closing `</details>` tag and the next markdown heading — GitHub will not parse the following heading as markdown otherwise.

   6d. **Link the preview into Functional Requirements.** When a Functional Requirement is *directly* expressed by a visible element in the preview, append a parenthetical reference like `(see UI Preview)` to that requirement. Do not duplicate the visual description in prose — the preview is canonical for visual intent.

   6e. **Re-run on updates.** If `/speckit-specify` is invoked on an existing spec (update mode), locate the `<!-- BEGIN: ui-preview-in-spec preset -->` … `<!-- END: ui-preview-in-spec preset -->` block in `spec.md` and replace its contents in place. Do not append a second preview block. The update MUST also happen inside the worktree — re-`cd` to `${WORKTREE_PATH}` first if `.specify/feature.json` records one.

7. Write the specification to `SPEC_FILE` (inside the worktree) using the template structure, replacing placeholders with concrete details derived from the feature description while preserving section order and headings. If the UI-touch check fired, the preview block from step 6 is included.

8. **Specification Quality Validation**: write `SPECIFY_FEATURE_DIRECTORY/checklists/requirements.md` (inside the worktree) and iterate per the stock command's flow (max 3 iterations; handle `[NEEDS CLARIFICATION]` markers with up to 3 `AskUserQuestion` calls or markdown question tables, depending on preset stack).

9. **Report completion** to the user with `SPECIFY_FEATURE_DIRECTORY`, `SPEC_FILE`, **`WORKTREE_PATH`** (so the user can `cd` themselves on the next session), whether the UI preview block was inserted, checklist results, and readiness for the next phase (`/speckit-clarify` or `/speckit-plan`).

10. **Check for extension hooks (after specification)**: same as the stock command — read `hooks.after_specify` from `.specify/extensions.yml` and surface optional / mandatory hooks per the standard format.

## Quick Guidelines

- Focus on **WHAT** users need and **WHY**. The preview pins the visual *what*; do not describe implementation details (component library, framework, CSS-in-JS, etc.) in the preview comments.
- The preview is a requirement, not a mock-up gallery. One preview per spec. If the feature genuinely needs multiple states (e.g. empty vs populated), render them side-by-side or stacked inside the single fragment using inline flex/grid wrappers.
- Avoid HOW to implement (no tech stack, APIs, code structure) in the spec body. The HTML preview is the one allowed exception, and only because it pins visual intent.
- DO NOT create any checklists embedded in the spec body. The requirements checklist is a separate artifact (step 8).

## Compliance note

This preset combines two operational behaviours beyond the stock `speckit-specify` skill:

1. **Worktree isolation (Constitution v2.3.0 Principle VII)** — reads `WORKTREE_PATH` from the `before_specify` hook, `cd`s into it before any filesystem write, and persists `worktree_path` in `.specify/feature.json`. This must NOT be skipped when this preset replaces the stock command; otherwise spec artifacts land in the primary checkout and violate Principle VII.
2. **UI-touch classifier + mandatory inline HTML preview** — when the feature touches UI, a self-contained HTML fragment is embedded in `spec.md` (inside the worktree) wrapped in `<!-- BEGIN/END -->` sentinels for idempotent updates.

All other behaviour (branch creation, feature directory layout, template loading, functional requirement extraction, validation checklist, after-hook chain) is unchanged from the stock command. The worktree itself is created by `.specify/extensions/git/scripts/bash/create-new-feature.sh` via the `before_specify` hook.
