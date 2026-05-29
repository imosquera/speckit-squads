---
description: "Execute the implementation planning workflow using the plan template to generate design artifacts. Per BeadBits Constitution v2.3.0 Principle VII (Feature-Work Isolation), this command MUST run inside the feature's dedicated worktree; the agent cd's into the worktree recorded in .specify/feature.json before writing any plan artifacts."
argument-hint: "Optional guidance for the planning phase"
compatibility: "Requires spec-kit project structure with .specify/ directory"
metadata:
  author: "beadbits"
  source: ".specify/presets/worktree-isolation/commands/speckit.plan.md"
user-invocable: true
disable-model-invocation: false
---


## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Pre-Execution Checks

**Check for extension hooks (before planning)**:
- Check if `.specify/extensions.yml` exists in the project root.
- If it exists, read it and look for entries under the `hooks.before_plan` key
- If the YAML cannot be parsed or is invalid, skip hook checking silently and continue normally
- Filter out hooks where `enabled` is explicitly `false`. Treat hooks without an `enabled` field as enabled by default.
- For each remaining hook, do **not** attempt to interpret or evaluate hook `condition` expressions:
  - If the hook has no `condition` field, or it is null/empty, treat the hook as executable
  - If the hook defines a non-empty `condition`, skip the hook and leave condition evaluation to the HookExecutor implementation
- When constructing slash commands from hook command names, replace dots (`.`) with hyphens (`-`). For example, `speckit.git.commit` → `/speckit-git-commit`.
- For each executable hook, output the standard hook banner (optional vs mandatory) and wait for mandatory hooks to complete before proceeding to the Outline.
- If no hooks are registered or `.specify/extensions.yml` does not exist, skip silently.

## Outline

### 0. cd into the feature's worktree (MANDATORY — Principle VII)

Per BeadBits Constitution v2.3.0 Principle VII (Feature-Work Isolation),
/speckit-plan MUST execute with the agent's cwd set to the feature's worktree.
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
   then re-invoke /speckit-plan."
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

Run `.specify/scripts/bash/setup-plan.sh --json` from repo root and parse JSON for FEATURE_SPEC, IMPL_PLAN, SPECS_DIR, BRANCH. For single quotes in args like "I'm Groot", use escape syntax: e.g 'I'\''m Groot' (or double-quote if possible: "I'm Groot").

### 2. Load context

Read FEATURE_SPEC and `.specify/memory/constitution.md`. Load IMPL_PLAN template (already copied).

### 3. Execute plan workflow

Follow the structure in IMPL_PLAN template to:
- Fill Technical Context (mark unknowns as "NEEDS CLARIFICATION")
- Fill Constitution Check section from constitution
- Evaluate gates (ERROR if violations unjustified)
- Phase 0: Generate research.md (resolve all NEEDS CLARIFICATION)
- Phase 1: Generate data-model.md, contracts/, quickstart.md
- Phase 1: Update agent context by running the agent script
- Re-evaluate Constitution Check post-design

### 4. Stop and report

Command ends after Phase 2 planning. Report branch, IMPL_PLAN path, and generated artifacts.

### 5. Check for extension hooks (after plan)

Check if `.specify/extensions.yml` exists in the project root.
- If it exists, read it and look for entries under the `hooks.after_plan` key
- If the YAML cannot be parsed or is invalid, skip hook checking silently and continue normally
- Filter out hooks where `enabled` is explicitly `false`. Treat hooks without an `enabled` field as enabled by default.
- For each remaining hook, do **not** attempt to interpret or evaluate hook `condition` expressions:
  - If the hook has no `condition` field, or it is null/empty, treat the hook as executable
  - If the hook defines a non-empty `condition`, skip the hook and leave condition evaluation to the HookExecutor implementation
- When constructing slash commands from hook command names, replace dots (`.`) with hyphens (`-`). For example, `speckit.git.commit` → `/speckit-git-commit`.
- For each executable hook, output the standard hook banner (optional vs mandatory).
- If no hooks are registered or `.specify/extensions.yml` does not exist, skip silently

## Phases

### Phase 0: Outline & Research

1. **Extract unknowns from Technical Context** above:
   - For each NEEDS CLARIFICATION → research task
   - For each dependency → best practices task
   - For each integration → patterns task

2. **Generate and dispatch research agents**:

   ```text
   For each unknown in Technical Context:
     Task: "Research {unknown} for {feature context}"
   For each technology choice:
     Task: "Find best practices for {tech} in {domain}"
   ```

3. **Consolidate findings** in `research.md` using format:
   - Decision: [what was chosen]
   - Rationale: [why chosen]
   - Alternatives considered: [what else evaluated]

**Output**: research.md with all NEEDS CLARIFICATION resolved

### Phase 1: Design & Contracts

**Prerequisites:** `research.md` complete

1. **Extract entities from feature spec** → `data-model.md`:
   - Entity name, fields, relationships
   - Validation rules from requirements
   - State transitions if applicable

2. **Define interface contracts** (if project has external interfaces) → `/contracts/`:
   - Identify what interfaces the project exposes to users or other systems
   - Document the contract format appropriate for the project type
   - Examples: public APIs for libraries, command schemas for CLI tools, endpoints for web services, grammars for parsers, UI contracts for applications
   - Skip if project is purely internal (build scripts, one-off tools, etc.)

3. **Agent context update**:
   - Update the plan reference between the `<!-- SPECKIT START -->` and `<!-- SPECKIT END -->` markers in `CLAUDE.md` to point to the plan file created in step 1 (the IMPL_PLAN path)

**Output**: data-model.md, /contracts/*, quickstart.md, updated agent context file

## Key rules

- Use absolute paths for filesystem operations; use project-relative paths for references in documentation and agent context files
- ERROR on gate failures or unresolved clarifications

## Constitution v2.3.0 Principle VII compliance note

This preset override exists specifically to close the resume-case gap left by PR #21
for `/speckit-plan`. The substantive operational behaviour it adds beyond the stock
`speckit-plan` skill is:

1. Reading `worktree_path` from `.specify/feature.json` at the cwd.
2. `cd`-ing into that path before any filesystem write performed by the plan outline.
3. Erroring out (rather than silently proceeding) when the recorded worktree directory
   has been deleted from disk without `git worktree remove`.

The cd-block at `### 0.` is byte-identical across all four feature-scoped command
overrides (`/speckit-clarify`, `/speckit-plan`, `/speckit-tasks`, `/speckit-implement`)
modulo the slash-command substitution; this is enforced by SC-002 in
`specs/022-worktree-isolation-resume/quickstart.md`.
