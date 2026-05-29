---
description: "Identify underspecified areas in the current feature spec by asking up to 5 highly targeted clarification questions and encoding answers back into the spec. Per BeadBits Constitution v2.3.0 Principle VII (Feature-Work Isolation), this command MUST run inside the feature's dedicated worktree; the agent cd's into the worktree recorded in .specify/feature.json before writing any spec edits."
argument-hint: "Optional areas to clarify in the spec"
compatibility: "Requires spec-kit project structure with .specify/ directory"
metadata:
  author: "beadbits"
  source: ".specify/presets/worktree-isolation/commands/speckit.clarify.md"
user-invocable: true
disable-model-invocation: false
---


## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Pre-Execution Checks

**Check for extension hooks (before clarification)**:
- Check if `.specify/extensions.yml` exists in the project root.
- If it exists, read it and look for entries under the `hooks.before_clarify` key
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
/speckit-clarify MUST execute with the agent's cwd set to the feature's worktree.
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
   then re-invoke /speckit-clarify."
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

### 1. Goal & context

Goal: Detect and reduce ambiguity or missing decision points in the active feature specification and record the clarifications directly in the spec file.

Note: This clarification workflow is expected to run (and be completed) BEFORE invoking `/speckit-plan`. If the user explicitly states they are skipping clarification (e.g., exploratory spike), you may proceed, but must warn that downstream rework risk increases.

### 2. Prerequisites

Run `.specify/scripts/bash/check-prerequisites.sh --json --paths-only` from repo root **once** (combined `--json --paths-only` mode / `-Json -PathsOnly`). Parse minimal JSON payload fields:
- `FEATURE_DIR`
- `FEATURE_SPEC`
- (Optionally capture `IMPL_PLAN`, `TASKS` for future chained flows.)
- If JSON parsing fails, abort and instruct user to re-run `/speckit-specify` or verify feature branch environment.
- For single quotes in args like "I'm Groot", use escape syntax: e.g 'I'\''m Groot' (or double-quote if possible: "I'm Groot").

### 3. Ambiguity scan

Load the current spec file. Perform a structured ambiguity & coverage scan using this taxonomy. For each category, mark status: Clear / Partial / Missing. Produce an internal coverage map used for prioritization (do not output raw map unless no questions will be asked).

Functional Scope & Behavior:
- Core user goals & success criteria
- Explicit out-of-scope declarations
- User roles / personas differentiation

Domain & Data Model:
- Entities, attributes, relationships
- Identity & uniqueness rules
- Lifecycle/state transitions
- Data volume / scale assumptions

Interaction & UX Flow:
- Critical user journeys / sequences
- Error/empty/loading states
- Accessibility or localization notes

Non-Functional Quality Attributes:
- Performance (latency, throughput targets)
- Scalability (horizontal/vertical, limits)
- Reliability & availability (uptime, recovery expectations)
- Observability (logging, metrics, tracing signals)
- Security & privacy (authN/Z, data protection, threat assumptions)
- Compliance / regulatory constraints (if any)

Integration & External Dependencies:
- External services/APIs and failure modes
- Data import/export formats
- Protocol/versioning assumptions

Edge Cases & Failure Handling:
- Negative scenarios
- Rate limiting / throttling
- Conflict resolution (e.g., concurrent edits)

Constraints & Tradeoffs:
- Technical constraints (language, storage, hosting)
- Explicit tradeoffs or rejected alternatives

Terminology & Consistency:
- Canonical glossary terms
- Avoided synonyms / deprecated terms

Completion Signals:
- Acceptance criteria testability
- Measurable Definition of Done style indicators

Misc / Placeholders:
- TODO markers / unresolved decisions
- Ambiguous adjectives ("robust", "intuitive") lacking quantification

For each category with Partial or Missing status, add a candidate question opportunity unless:
- Clarification would not materially change implementation or validation strategy
- Information is better deferred to planning phase (note internally)

### 4. Prioritized question queue

Generate (internally) a prioritized queue of candidate clarification questions (maximum 5). Do NOT output them all at once. Apply these constraints:
- Maximum of 5 total questions across the whole session.
- Each question must be answerable with EITHER:
   - A short multiple‑choice selection (2–5 distinct, mutually exclusive options), OR
   - A one-word / short‑phrase answer (explicitly constrain: "Answer in <=5 words").
- Only include questions whose answers materially impact architecture, data modeling, task decomposition, test design, UX behavior, operational readiness, or compliance validation.
- Ensure category coverage balance: attempt to cover the highest impact unresolved categories first; avoid asking two low-impact questions when a single high-impact area (e.g., security posture) is unresolved.
- Exclude questions already answered, trivial stylistic preferences, or plan-level execution details (unless blocking correctness).
- Favor clarifications that reduce downstream rework risk or prevent misaligned acceptance tests.
- If more than 5 categories remain unresolved, select the top 5 by (Impact * Uncertainty) heuristic.

### 5. Sequential questioning loop

- Present EXACTLY ONE question at a time.
- For multiple‑choice questions:
   - **Analyze all options** and determine the **most suitable option** based on best practices, common patterns, risk reduction, and alignment with explicit project goals.
   - Present your **recommended option prominently** at the top with clear reasoning (1-2 sentences explaining why this is the best choice).
   - Format as: `**Recommended:** Option [X] - <reasoning>`
   - Then render all options as a Markdown table:

     | Option | Description |
     |--------|-------------|
     | A | <Option A description> |
     | B | <Option B description> |
     | C | <Option C description> (add D/E as needed up to 5) |
     | Short | Provide a different short answer (<=5 words) (Include only if free-form alternative is appropriate) |

   - After the table, add: `You can reply with the option letter (e.g., "A"), accept the recommendation by saying "yes" or "recommended", or provide your own short answer.`
- For short‑answer style (no meaningful discrete options):
   - Provide your **suggested answer** based on best practices and context.
   - Format as: `**Suggested:** <your proposed answer> - <brief reasoning>`
   - Then output: `Format: Short answer (<=5 words). You can accept the suggestion by saying "yes" or "suggested", or provide your own answer.`
- After the user answers:
   - If the user replies with "yes", "recommended", or "suggested", use your previously stated recommendation/suggestion as the answer.
   - Otherwise, validate the answer maps to one option or fits the <=5 word constraint.
   - If ambiguous, ask for a quick disambiguation (count still belongs to same question; do not advance).
   - Once satisfactory, record it in working memory (do not yet write to disk) and move to the next queued question.
- Stop asking further questions when:
   - All critical ambiguities resolved early (remaining queued items become unnecessary), OR
   - User signals completion ("done", "good", "no more"), OR
   - You reach 5 asked questions.
- Never reveal future queued questions in advance.
- If no valid questions exist at start, immediately report no critical ambiguities.

### 6. Integration after each accepted answer

- Maintain in-memory representation of the spec (loaded once at start) plus the raw file contents.
- For the first integrated answer in this session:
   - Ensure a `## Clarifications` section exists (create it just after the highest-level contextual/overview section per the spec template if missing).
   - Under it, create (if not present) a `### Session YYYY-MM-DD` subheading for today.
- Append a bullet line immediately after acceptance: `- Q: <question> → A: <final answer>`.
- Then immediately apply the clarification to the most appropriate section(s):
   - Functional ambiguity → Update or add a bullet in Functional Requirements.
   - User interaction / actor distinction → Update User Stories or Actors subsection.
   - Data shape / entities → Update Data Model.
   - Non-functional constraint → Add/modify measurable criteria in Success Criteria.
   - Edge case / negative flow → Add a new bullet under Edge Cases / Error Handling.
   - Terminology conflict → Normalize term across spec.
- If the clarification invalidates an earlier ambiguous statement, replace that statement instead of duplicating; leave no obsolete contradictory text.
- Save the spec file AFTER each integration to minimize risk of context loss (atomic overwrite).
- Preserve formatting: do not reorder unrelated sections; keep heading hierarchy intact.
- Keep each inserted clarification minimal and testable (avoid narrative drift).

### 7. Validation

Performed after EACH write plus final pass:
- Clarifications session contains exactly one bullet per accepted answer (no duplicates).
- Total asked (accepted) questions ≤ 5.
- Updated sections contain no lingering vague placeholders the new answer was meant to resolve.
- No contradictory earlier statement remains.
- Markdown structure valid; only allowed new headings: `## Clarifications`, `### Session YYYY-MM-DD`.
- Terminology consistency: same canonical term used across all updated sections.

### 8. Write spec

Write the updated spec back to `FEATURE_SPEC`.

### 9. Report completion

After questioning loop ends or early termination:
- Number of questions asked & answered.
- Path to updated spec.
- Sections touched (list names).
- Coverage summary table listing each taxonomy category with Status: Resolved / Deferred / Clear / Outstanding.
- If any Outstanding or Deferred remain, recommend whether to proceed to `/speckit-plan` or run `/speckit-clarify` again later post-plan.
- Suggested next command.

### 10. Behavior rules

- If no meaningful ambiguities found, respond: "No critical ambiguities detected worth formal clarification." and suggest proceeding.
- If spec file missing, instruct user to run `/speckit-specify` first.
- Never exceed 5 total asked questions.
- Avoid speculative tech stack questions unless the absence blocks functional clarity.
- Respect user early termination signals ("stop", "done", "proceed").
- If quota reached with unresolved high-impact categories remaining, explicitly flag them under Deferred with rationale.

Context for prioritization: $ARGUMENTS

## Post-Execution Checks

**Check for extension hooks (after clarification)**:
- Check if `.specify/extensions.yml` exists in the project root.
- If it exists, read it and look for entries under the `hooks.after_clarify` key
- Filter, evaluate, and emit hook banners per the standard format (optional vs mandatory).
- If no hooks are registered or `.specify/extensions.yml` does not exist, skip silently.

## Constitution v2.3.0 Principle VII compliance note

This preset override exists specifically to close the resume-case gap left by PR #21
for `/speckit-clarify`. The substantive operational behaviour it adds beyond the stock
`speckit-clarify` skill is:

1. Reading `worktree_path` from `.specify/feature.json` at the cwd.
2. `cd`-ing into that path before any filesystem write performed by the clarify outline.
3. Erroring out (rather than silently proceeding) when the recorded worktree directory
   has been deleted from disk without `git worktree remove`.

The cd-block at `### 0.` is byte-identical across all four feature-scoped command
overrides (`/speckit-clarify`, `/speckit-plan`, `/speckit-tasks`, `/speckit-implement`)
modulo the slash-command substitution; this is enforced by SC-002 in
`specs/022-worktree-isolation-resume/quickstart.md`.
