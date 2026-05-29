---
description: "Refresh graphify-out/ knowledge graph for the current feature worktree (non-blocking)"
---

# Refresh Knowledge Graph

Invoke `/graphify <worktree-path> --update` against the feature's worktree so the on-disk knowledge graph at `graphify-out/` stays in sync with the code.

This command is wired into the Spec Kit after-hook chain (`after_specify`, `after_implement`) by `.specify/extensions/graphify/extension.yml`. It is **not** intended to be invoked by humans directly.

## Behavior

1. Resolve the worktree path from `.specify/feature.json#worktree_path`. If the file is missing or the field is absent, fall back to `pwd`.
2. If `<worktree-path>/graphify-out/` does not exist: log a single-line skip message and exit 0. **Do not** trigger a full initial build — that is an explicit developer action per the top-level `README.md`.
3. If the `graphify` binary is not on `PATH`: log a single-line warning pointing at the README's install section and exit 0.
4. Otherwise run `graphify "<worktree-path>" --update`. Capture the exit code; if non-zero, surface stdout and stderr as a warning and still exit 0. The triggering Spec Kit command MUST NOT abort because of this hook.

## Execution

- **Bash**: `.specify/extensions/graphify/scripts/bash/graphify-update.sh`
- **PowerShell**: (not provided; macOS/Linux only — Bash script handles WSL too)

## Graceful Degradation

- Missing `graphify-out/` → skip with one-line log, exit 0 (FR-004).
- Missing `graphify` binary → warning with README pointer, exit 0 (FR-003, SC-003).
- `graphify --update` returns non-zero → warning surfaced, exit 0 (FR-003).
- Spec Kit invoking command itself failed → this hook should not have fired (after-hooks only run on success of the parent phase).

## Configuration

None. The extension reads `.specify/feature.json` directly; there is no per-event toggle and no message template, because there is exactly one behavior.

## Rationale

Per Constitution v2.4.0 Principle VIII, the knowledge graph is the entry point for codebase Q&A in this repo. Keeping it fresh on Spec Kit phase boundaries is cheap; staying stale silently degrades every future `/graphify query`.
