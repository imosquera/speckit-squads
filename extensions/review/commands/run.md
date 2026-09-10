---
description: Comprehensive code review using specialized agents — orchestrates code, comments, tests, errors, types, and simplify agents sequentially.
scripts:
  sh: scripts/bash/detect-changed-files.sh
  ps: scripts/powershell/detect-changed-files.ps1
---

# Comprehensive PR Review

Run a comprehensive pull request review using multiple specialized agents, each focusing on a different aspect of code quality.

**Review Aspects (optional):** "$ARGUMENTS"

## Review Workflow:

1. **Load Configuration**
   - Read the project config file at `.specify/extensions/review/review-config.yml` (if it exists).
   - If the file does not exist, fall back to the `defaults.agents` section in the extension's `extension.yml`.
   - Extract the `agents` map — each key (`code`, `comments`, `tests`, `errors`, `types`, `simplify`) is a boolean toggle.
   - Agents set to `false` **MUST** be excluded from this run. Do not launch them.

2. **Determine Review Scope**
   - Parse arguments to see if user requested specific review aspects.
   - If specific aspects were requested, run exactly those — config toggles do **not** apply (explicit user request overrides config).
   - Default (no arguments): Run all applicable reviews that are enabled in config.

3. **Available Review Aspects:**

   - **comments** - Analyze code comment accuracy and maintainability
   - **tests** - Review test coverage quality and completeness
   - **errors** - Check error handling for silent failures
   - **types** - Analyze type design and invariants (if new types added)
   - **code** - General code review for project guidelines
   - **simplify** - Simplify code for clarity and maintainability
   - **all** - Run all applicable reviews (default)

4. **Identify Changed Files**

   - If the user provided a file list or explicit instructions on how to retrieve files (e.g., only staged, only unstaged, a specific folder, etc.), follow those instructions directly.
   - Otherwise, you **MUST** execute the `{SCRIPT}` with `--json` to detect changed files. **Do not** attempt to detect changes by running `git` commands directly, reading git state manually, or using any other method — always delegate to the script.
     - The script automatically picks the best detection mode:
       - **Mode A (feature branch):** diffs the current branch against the default branch (`main`/`master`) from the merge-base, plus any staged and unstaged changes.
       - **Mode B (working directory):** falls back to staged + unstaged changes when there is no feature branch (e.g., working directly on the default branch).
     - JSON output: `{"branch", "default_branch", "repo_root", "diff_range", "mode", "changed_files": [...]}`
     - `repo_root` is the absolute path of **this** worktree and `diff_range` is the exact `<merge-base>...HEAD` range (empty in Mode B). Both **MUST** be carried into every reviewer prompt — see step 6. Do not re-derive either one yourself.
   - **Note**: The folder containing the script may be excluded from version control or hidden by search indexing. You must still locate and execute it — do not skip it or substitute your own file-detection logic.
   - **Ignore** the `graphify-out/` directory in all review passes — exclude it from diffs, file reads, and issue reporting. If the changed-files list includes paths under `graphify-out/`, filter them out before dispatching to specialist agents. Generated knowledge-graph artifacts are out of scope for review.

5. **Determine Applicable Reviews**

   Based on changes **and** config toggles (skip any agent where `agents.<name>` is `false`):
   - **Always applicable** (if enabled): `/speckit.review.code` (general quality)
   - **If test files changed** (if enabled): `/speckit.review.tests`
   - **If comments/docs added** (if enabled): `/speckit.review.comments`
   - **If error handling changed** (if enabled): `/speckit.review.errors`
   - **If types added/modified** (if enabled): `/speckit.review.types`
   - **After passing review** (if enabled): `/speckit.review.simplify` (polish and refine)
   - If an agent is disabled by config, note it in the final summary (e.g., "simplify: skipped (disabled in config)"). Degraded aspects (step 6c) are noted the same way.

6. **Launch Review Agents**

   **Sequential approach** (one at a time):
   - Easier to understand and act on
   - Each report is complete before next
   - Good for interactive review

   **Parallel approach** (user can request):
   - Launch all agents simultaneously
   - Faster for comprehensive review
   - Results come back together

   **6a. Scope contract — every reviewer prompt MUST carry the scope explicitly.**

   A subagent inherits the session's cwd, which is regularly the main checkout on
   the default branch rather than the feature worktree. A reviewer that inherits
   the wrong tree produces confident findings about unrelated files, and nothing in
   its output says so. So each prompt **MUST** open with, verbatim from the
   script's JSON (never re-derived):

   ```
   Review scope — do not infer it, do not use your inherited cwd:
     worktree: <repo_root>          # absolute path
     branch:   <branch>
     diff:     git -C <repo_root> diff <diff_range>
   Before reviewing, verify: `git -C <repo_root> rev-parse --abbrev-ref HEAD` equals
   <branch>, and the diff above is non-empty. If either check fails, abort
   immediately and reply with exactly `SCOPE ERROR: <what mismatched>` — do not
   review whatever is in your working directory instead.
   ```

   If `diff_range` is empty (Mode B — working directory), pass
   `git -C <repo_root> diff HEAD` as the diff command and drop the branch check.

   A reviewer that returns `SCOPE ERROR:` is a failed launch, not a finding:
   re-dispatch it with the corrected scope, and never fold its output into the
   summary.

   **6b. Wait contract — do not poll, do not narrate.**

   After dispatching, you **MUST NOT** emit a turn that only reports on the
   reviewers' status. "Waiting on the four reviewers", "three passes still
   running", "I'll stop polling and wait" are all the same anti-pattern: they
   consume a turn and change nothing. Completion notifications arrive on their
   own; you do not need to check for them.

   Either do useful work that cannot conflict with a reviewer (verify a claim you
   already flagged, check CI, draft the PR body) or stop and produce no output at
   all until a notification arrives. Do not edit files the reviewers are reading.

   **6c. Hang recovery.**

   If a reviewer has produced no output and its elapsed time has not advanced for
   **10 minutes**, `TaskStop` it and run that aspect inline yourself against the
   same scope from 6a. Record every aspect handled this way in the final summary
   as `<aspect>: degraded (agent hung, run inline)` — a degraded aspect is not the
   same as a clean pass and must not be reported as one.

7. **Aggregate Results**

   After agents complete, summarize using the four-bucket severity scheme. Always render the section headers with these emoji icons — do not substitute or drop them:
   - 🚨 **Critical** — must fix before merge (bugs, security vulnerabilities, broken contracts)
   - ⚠️ **Important** — strongly recommended (significant quality or correctness concerns)
   - 💡 **Suggestions** — worth addressing (code quality, missing tests, refactors)
   - ✨ **Optional Polish** — nice-to-have style/naming/cosmetic improvements
   - ✅ **Strengths** — what's well-done (be genuine, not perfunctory)
   - 🛠 **Recommended Action** — numbered next-steps list

8. **Provide Action Plan**

   Organize findings:
   ```markdown
   # PR Review Summary

   ## Overview
   [2–3 sentences: what this PR does and why it matters]

   ## 🚨 Critical Issues (must fix before merge)
   - [agent-name]: Issue description [file:line]

   ## ⚠️ Important Issues
   - [agent-name]: Issue description [file:line]

   ## 💡 Suggestions
   - [agent-name]: Suggestion [file:line]

   ## ✨ Optional Polish
   - [agent-name]: Polish item [file:line]

   ## ✅ Strengths
   - [What's well-done — be genuine, not perfunctory]

   ## 🛠 Recommended Action
   1. [Numbered next-steps list]

   ## Recommendation
   **[Approve | Approve with conditions | Request changes]**
   [One paragraph explaining the reasoning]
   ```

   Omit any severity bucket that has nothing to report.

## Usage Examples:

**Full review (default):**
```
/speckit-review-run
```

**Specific aspects:**
```
/speckit-review-run tests errors
# Reviews only test coverage and error handling

/speckit-review-run comments
# Reviews only code comments

/speckit-review-run simplify
# Simplifies code after passing review
```

**Parallel review:**
```
/speckit-review-run all parallel
# Launches all agents in parallel
```

## Agent Descriptions:

**comment**:
- Verifies comment accuracy vs code
- Identifies comment rot
- Checks documentation completeness

**tests**:
- Reviews behavioral test coverage
- Identifies critical gaps
- Evaluates test quality

**errors**:
- Finds silent failures
- Reviews catch blocks
- Checks error logging

**types**:
- Analyzes type encapsulation
- Reviews invariant expression
- Rates type design quality

**code**:
- Checks project-specific guidelines (`.specify/memory/constitution.md`, `CLAUDE.md`, `.github/copilot-instructions.md`, or equivalent) compliance
- Detects bugs and issues
- Reviews general code quality

**simplify**:
- Simplifies complex code
- Improves clarity and readability
- Applies project standards
- Preserves functionality

## Tips:

- **Run early**: Before creating PR, not after
- **Focus on changes**: Agents analyze diff by default
- **Address critical first**: Fix high-priority issues before lower priority
- **Re-run after fixes**: Verify issues are resolved
- **Use specific reviews**: Target specific aspects when you know the concern

## Notes:

- Agents run autonomously and return detailed reports
- Each agent focuses on its specialty for deep analysis
- Results are actionable with specific file:line references
- Agents use appropriate models for their complexity