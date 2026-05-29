---
description: "Generate an actionable, dependency-ordered tasks.md for the feature based on available design artifacts. Per BeadBits Constitution v2.3.0 Principle VII (Feature-Work Isolation), this command MUST run inside the feature's dedicated worktree; the agent cd's into the worktree recorded in .specify/feature.json before writing tasks.md."
argument-hint: "Optional task generation constraints"
compatibility: "Requires spec-kit project structure with .specify/ directory"
metadata:
  author: "beadbits"
  source: ".specify/presets/worktree-isolation/commands/speckit.tasks.md"
user-invocable: true
disable-model-invocation: false
---


## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Pre-Execution Checks

**Check for extension hooks (before tasks generation)**:
- Check if `.specify/extensions.yml` exists in the project root.
- If it exists, read it and look for entries under the `hooks.before_tasks` key
- Filter, evaluate, and emit hook banners per the standard format.
- If no hooks are registered or `.specify/extensions.yml` does not exist, skip silently.

## Outline

### 0. cd into the feature's worktree (MANDATORY — Principle VII)

Per BeadBits Constitution v2.3.0 Principle VII (Feature-Work Isolation),
/speckit-tasks MUST execute with the agent's cwd set to the feature's worktree.
This step runs BEFORE any filesystem write performed by the rest of this
outline.

1. Read `.specify/feature.json` (relative to the current cwd). If the file
   is missing or cannot be parsed as JSON, ERROR with:
   "Cannot resolve feature: .specify/feature.json is missing or malformed.
   Run /speckit-specify to (re)initialize a feature."
   Do NOT proceed.

2. Let `WT = feature.json.worktree_path`.

3. If `WT` is null or the field is absent:
   Emit a single-sentence warning:
   "This feature has no recorded worktree_path (likely created before
   Constitution v2.3.0). Proceeding in the current cwd; Principle VII
   isolation is not enforced for this invocation."
   Then proceed in the current cwd. Skip steps 4–6.

4. If `WT` is non-null but the directory does NOT exist on disk:
   ERROR with:
   "Worktree directory '<WT>' is recorded in .specify/feature.json but
   does not exist on disk. Recreate it with:
       git worktree add '<WT>' <feature-branch>
   then re-invoke /speckit-tasks."
   Do NOT proceed. (The feature branch can be read from
   feature.json.feature_directory's NNN- prefix or from `git branch --list`.)

5. If `WT` is non-null, exists on disk, and matches the current cwd
   (resolved to absolute path), proceed silently — no cd needed.

6. Otherwise (`WT` is non-null, exists, and differs from cwd):
   Prefix every subsequent shell invocation in this command with
   `cd "<WT>" && ...` so the cd is visible in the session log. All
   filesystem writes performed by the rest of this outline land inside
   the worktree. Do not silently rely on tools that ignore cwd
   (absolute-path file writers) as a substitute — the cd MUST appear
   in the session log for post-hoc isolation auditing.

### End cd-block (Principle VII enforcement complete)

### 1. Setup

Run `.specify/scripts/bash/setup-tasks.sh --json` from repo root and parse FEATURE_DIR, TASKS_TEMPLATE, and AVAILABLE_DOCS list. `FEATURE_DIR` and `TASKS_TEMPLATE` must be absolute paths when provided. `AVAILABLE_DOCS` is a list of document names/relative paths available under `FEATURE_DIR` (for example `research.md` or `contracts/`). For single quotes in args like "I'm Groot", use escape syntax: e.g 'I'\''m Groot' (or double-quote if possible: "I'm Groot").

### 2. Load design documents

Read from FEATURE_DIR:
- **Required**: plan.md (tech stack, libraries, structure), spec.md (user stories with priorities)
- **Optional**: data-model.md (entities), contracts/ (interface contracts), research.md (decisions), quickstart.md (test scenarios)
- Note: Not all projects have all documents. Generate tasks based on what's available.

### 3. Execute task generation workflow

- Load plan.md and extract tech stack, libraries, project structure
- Load spec.md and extract user stories with their priorities (P1, P2, P3, etc.)
- If data-model.md exists: Extract entities and map to user stories
- If contracts/ exists: Map interface contracts to user stories
- If research.md exists: Extract decisions for setup tasks
- Generate tasks organized by user story (see Task Generation Rules below)
- Generate dependency graph showing user story completion order
- Create parallel execution examples per user story
- Validate task completeness (each user story has all needed tasks, independently testable)

### 4. Generate tasks.md

Read the tasks template from TASKS_TEMPLATE (from the JSON output above) and use it as structure. If TASKS_TEMPLATE is empty, fall back to `.specify/templates/tasks-template.md`. Fill with:
- Correct feature name from plan.md
- Phase 1: Setup tasks (project initialization)
- Phase 2: Foundational tasks (blocking prerequisites for all user stories)
- Phase 3+: One phase per user story (in priority order from spec.md)
- Each phase includes: story goal, independent test criteria, tests (if requested), implementation tasks
- Final Phase: Polish & cross-cutting concerns
- All tasks must follow the strict checklist format (see Task Generation Rules below)
- Clear file paths for each task
- Dependencies section showing story completion order
- Parallel execution examples per story
- Implementation strategy section (MVP first, incremental delivery)

### 5. Report

Output path to generated tasks.md and summary:
- Total task count
- Task count per user story
- Parallel opportunities identified
- Independent test criteria for each story
- Suggested MVP scope (typically just User Story 1)
- Format validation: Confirm ALL tasks follow the checklist format (checkbox, ID, labels, file paths)

### 6. Check for extension hooks (after tasks)

After tasks.md is generated, check if `.specify/extensions.yml` exists in the project root.
- If it exists, read it and look for entries under the `hooks.after_tasks` key
- Filter, evaluate, and emit hook banners per the standard format.
- If no hooks are registered or `.specify/extensions.yml` does not exist, skip silently.

Context for task generation: $ARGUMENTS

The tasks.md should be immediately executable - each task must be specific enough that an LLM can complete it without additional context.

## Task Generation Rules

**CRITICAL**: Tasks MUST be organized by user story to enable independent implementation and testing.

**Tests are OPTIONAL**: Only generate test tasks if explicitly requested in the feature specification or if user requests TDD approach.

### Checklist Format (REQUIRED)

Every task MUST strictly follow this format:

```text
- [ ] [TaskID] [P?] [Story?] Description with file path
```

**Format Components**:

1. **Checkbox**: ALWAYS start with `- [ ]` (markdown checkbox)
2. **Task ID**: Sequential number (T001, T002, T003...) in execution order
3. **[P] marker**: Include ONLY if task is parallelizable (different files, no dependencies on incomplete tasks)
4. **[Story] label**: REQUIRED for user story phase tasks only
   - Format: [US1], [US2], [US3], etc. (maps to user stories from spec.md)
   - Setup phase: NO story label
   - Foundational phase: NO story label
   - User Story phases: MUST have story label
   - Polish phase: NO story label
5. **Description**: Clear action with exact file path

**Examples**:

- ✅ CORRECT: `- [ ] T001 Create project structure per implementation plan`
- ✅ CORRECT: `- [ ] T005 [P] Implement authentication middleware in src/middleware/auth.py`
- ✅ CORRECT: `- [ ] T012 [P] [US1] Create User model in src/models/user.py`
- ✅ CORRECT: `- [ ] T014 [US1] Implement UserService in src/services/user_service.py`
- ❌ WRONG: `- [ ] Create User model` (missing ID and Story label)

### Task Organization

1. **From User Stories (spec.md)** - PRIMARY ORGANIZATION:
   - Each user story (P1, P2, P3...) gets its own phase
   - Map all related components to their story:
     - Models needed for that story
     - Services needed for that story
     - Interfaces/UI needed for that story
     - If tests requested: Tests specific to that story
   - Mark story dependencies (most stories should be independent)

2. **From Contracts**:
   - Map each interface contract → to the user story it serves
   - If tests requested: Each interface contract → contract test task [P] before implementation in that story's phase

3. **From Data Model**:
   - Map each entity to the user story(ies) that need it
   - If entity serves multiple stories: Put in earliest story or Setup phase
   - Relationships → service layer tasks in appropriate story phase

4. **From Setup/Infrastructure**:
   - Shared infrastructure → Setup phase (Phase 1)
   - Foundational/blocking tasks → Foundational phase (Phase 2)
   - Story-specific setup → within that story's phase

### Phase Structure

- **Phase 1**: Setup (project initialization)
- **Phase 2**: Foundational (blocking prerequisites - MUST complete before user stories)
- **Phase 3+**: User Stories in priority order (P1, P2, P3...)
  - Within each story: Tests (if requested) → Models → Services → Endpoints → Integration
  - Each phase should be a complete, independently testable increment
- **Final Phase**: Polish & Cross-Cutting Concerns

## Constitution v2.3.0 Principle VII compliance note

This preset override exists specifically to close the resume-case gap left by PR #21
for `/speckit-tasks`. The substantive operational behaviour it adds beyond the stock
`speckit-tasks` skill is:

1. Reading `worktree_path` from `.specify/feature.json` at the cwd.
2. `cd`-ing into that path before any filesystem write performed by the tasks outline.
3. Erroring out (rather than silently proceeding) when the recorded worktree directory
   has been deleted from disk without `git worktree remove`.

The cd-block at `### 0.` is byte-identical across all four feature-scoped command
overrides (`/speckit-clarify`, `/speckit-plan`, `/speckit-tasks`, `/speckit-implement`)
modulo the slash-command substitution; this is enforced by SC-002 in
`specs/022-worktree-isolation-resume/quickstart.md`.
