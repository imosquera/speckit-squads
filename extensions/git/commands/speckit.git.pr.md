---
description: "Open a GitHub PR for the current feature branch, auto-appending Closes #N from .specify/feature.json when source_issue is set"
---

# Create PR for Current Feature

Open a GitHub pull request from the current feature branch into `main` (or another base passed as an argument). If `.specify/feature.json` carries a `source_issue` field — written by `/speckit-specify` when the input referenced a GitHub issue — the PR body will include a `Closes #N` line so merging the PR automatically closes that issue.

Designed to be invoked as the `after_implement` hook (alongside the existing auto-commit hook), or directly via `/speckit-git-pr`.

## Behavior

1. Verify `gh` is installed and the cwd is a git repo on a non-default branch.
2. Read `.specify/feature.json`:
   - `feature_directory` → used to derive the PR title from the spec's H1 and to mention spec/plan/tasks paths in the PR body.
   - `source_issue` → if present and numeric, append `Closes #N` to the PR body.
3. If the branch isn't yet on `origin`, push it (`git push -u origin <branch>`).
4. If a PR already exists for the branch, print its URL and exit.
5. Otherwise, run `gh pr create --base <base> --head <branch> --title <derived> --body <derived>`.

## Execution

Run the script:

- **Bash**: `.specify/extensions/git/scripts/bash/create-pr.sh [base_branch]`

Default `base_branch` is `main`. Pass an alternative as the first argument if needed.

## Graceful Degradation

- If `gh` is missing: error with install hint.
- If the current branch equals the base branch: refuse.
- If no `source_issue` is recorded: PR is created without a closing keyword (still works, just doesn't auto-close an issue).
- If a PR already exists for this branch: prints the existing URL, does not duplicate.
