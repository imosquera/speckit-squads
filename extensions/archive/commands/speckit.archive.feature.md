---
description: "Archive the current feature directory under specs/archive/YYYY-MM-DD-{slug}/, update CHANGES.md, and close associated GitHub issues."
---

# Archive Current Feature

Move the completed feature planning folder from `specs/{slug}/` to `specs/archive/YYYY-MM-DD-{slug}/` using `git mv`, update (or create) `CHANGES.md`, and close any GitHub issues recorded as `source_issue` in `.specify/feature.json`.

## Behavior

1. Parse arguments. Detect a leading `--force` / `-f` flag. Treat the next positional as the feature slug.
2. Resolve the feature directory from `.specify/feature.json` (`feature_directory`), or from the argument if provided. Refuse if the path is already under `specs/archive/`.
3. Verify the feature is ready to archive (tasks.md exists and contains no unchecked `[ ]` items). If unchecked tasks remain, abort with the list **unless `--force` was passed**, in which case log the count and proceed.
4. Derive archive date `YYYY-MM-DD` from today.
5. Append a `CHANGES.md` entry with the feature title (from `spec.md` H1) and a short summary. Create `CHANGES.md` in Keep-a-Changelog style if absent.
6. `git mv specs/{slug} specs/archive/{date}-{slug}` (creating the parent if needed).
7. If `gh` is available and `.specify/feature.json` has `source_issue`, run `gh issue close <N> -c "Archived in specs/archive/{date}-{slug}/"`.

The archive **can run as part of the feature's PR** — the PR does not have to be merged first. Tasks completion is the real readiness signal; PR merge state is enforced by the platform, not by this script.

## Execution

- **Bash**: `.specify/extensions/archive/scripts/bash/archive-feature.sh [--force] [feature_slug]`

When `feature_slug` is omitted, the script reads `.specify/feature.json`. `--force` skips the unchecked-tasks gate; it does not bypass the "destination exists" or "already-archived" guards.

## Changelog Conventions

The changelog update follows Keep a Changelog conventions (do-changelog style):

- Prefer `CHANGELOG.md`, fall back to `CHANGES.md` if it already exists. Create `CHANGELOG.md` in Keep a Changelog format if neither is present.
- Inspect the existing format before writing — match heading depth and date format.
- Group entries by type: **Added / Changed / Fixed / Removed / Security**. Archive entries are written under `### Changed`.
- Lead with user-visible impact; keep bullets short and specific.
- Do not invent version numbers or release dates — use the archive date `YYYY-MM-DD` as the section heading.

## Graceful Degradation

- If `gh` is missing or no `source_issue` is recorded, the archive still proceeds; issue-close is skipped with a notice.
- If `CHANGES.md` already has a section for today's date, the entry is appended under it rather than duplicating the header.
- If the destination path already exists, the script aborts without overwriting (even with `--force`).
- Unchecked tasks: abort with the list — pass `--force` to override.
