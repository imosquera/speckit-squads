---
description: Create or update the feature specification from a natural language feature description. Per BeadBits Constitution v2.3.0 Principle VII (Feature-Work Isolation), this command MUST run inside the feature's dedicated worktree; the agent cd's into the worktree returned by the `before_specify` hook before writing any spec artifacts.
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

1. **Generate a concise short name** (2-4 words) for the feature, using the same rules as the stock command: extract meaningful keywords, prefer action-noun, preserve technical acronyms (OAuth2, API, JWT), keep it concise.

2. **Branch + worktree creation** (optional, via hook):

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
   spec artifacts created in step 3 below are written *inside the worktree*, not
   inside the primary checkout. The cd MUST be visible in the session log so that
   reviewers can confirm isolation post hoc.

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
     cwd mismatch (advisory in this amendment; mechanical enforcement via a
     PreToolUse hook is the recommended follow-up).

   **IMPORTANT**:
   - You must only create one feature per `/speckit-specify` invocation.
   - The spec directory name and the git branch name are independent — they may be the same, but that is the user's choice.
   - The spec directory and file are always created by this command, never by the hook.

4. Load `.specify/templates/spec-template.md` to understand required sections.

5. Follow this execution flow (unchanged from the stock command):
   1. Parse user description from arguments. If empty: ERROR "No feature description provided".
   2. Extract key concepts (actors, actions, data, constraints).
   3. For unclear aspects, make informed guesses; mark with `[NEEDS CLARIFICATION: …]` only when (a) the choice meaningfully affects scope or UX, (b) multiple reasonable interpretations exist, (c) no reasonable default. Maximum 3 markers. Prioritise scope > security > UX > technical.
   4. Fill User Scenarios & Testing. If no clear user flow: ERROR.
   5. Generate Functional Requirements (each testable; document assumptions).
   6. Define Success Criteria (measurable, technology-agnostic, verifiable).
   7. Identify Key Entities (if data involved).
   8. Return: SUCCESS.

6. Write the specification to `SPEC_FILE` (inside the worktree) using the template structure, replacing placeholders with concrete details derived from the feature description while preserving section order and headings.

7. **Specification Quality Validation**: write `SPECIFY_FEATURE_DIRECTORY/checklists/requirements.md` (inside the worktree) and iterate per the stock command's flow (max 3 iterations; handle `[NEEDS CLARIFICATION]` markers with up to 3 `AskUserQuestion` calls or markdown question tables, depending on preset stack).

8. **Report completion** to the user with `SPECIFY_FEATURE_DIRECTORY`, `SPEC_FILE`, **`WORKTREE_PATH`** (so the user can `cd` themselves on the next session), checklist results, and readiness for the next phase (`/speckit-clarify` or `/speckit-plan`).

9. **Check for extension hooks (after specification)**: same as the stock command — read `hooks.after_specify` from `.specify/extensions.yml` and surface optional / mandatory hooks per the standard format.

## Quick Guidelines

- Focus on **WHAT** users need and **WHY**.
- Avoid HOW to implement (no tech stack, APIs, code structure) in the spec itself.
- Written for business stakeholders, not developers.
- DO NOT create any checklists that are embedded in the spec body. The requirements checklist is a separate artifact (step 7).

## Constitution v2.3.0 Principle VII compliance note

This preset exists specifically to satisfy "Feature-Work Isolation". The substantive
operational behaviour it adds beyond the stock `speckit-specify` skill is:

1. Reading `WORKTREE_PATH` from the `before_specify` hook's JSON output.
2. `cd`-ing into that path before any filesystem write for the new feature.
3. Persisting `worktree_path` alongside `feature_directory` in `.specify/feature.json`
   so downstream commands can resolve the worktree without re-deriving it.

The worktree itself is created by `.specify/extensions/git/scripts/bash/create-new-feature.sh`,
which this preset's hook chain assumes is invoked via the `before_specify` hook.
