---
description: "Build the initial graphify-out/ knowledge graph at the worktree root. Optionally seeds .graphifyignore on first run."
---

## User Input

```text
$ARGUMENTS
```

# Initialize Knowledge Graph

Run a one-time full build so the worktree gets a fresh `graphify-out/` directory at its root.

This is an explicit developer action — not a hook. Run it once per worktree before any `after_*` hook tries to update the graph.

## Why scope lives in `.graphifyignore`, not a Spec Kit config

`graphify` writes its output (`graph.json`, `graph.html`, `GRAPH_REPORT.md`, `cache/`, …) **next to whatever path you scan**. If you point it at `<worktree>/src`, `graphify-out/` lands at `<worktree>/src/graphify-out/`, which fragments the artifact location and breaks the gitignore patterns this extension installs at the worktree root.

So this extension always scans the worktree root and lets `graphify`'s native `.graphifyignore` file control what gets indexed. The format mirrors `.gitignore`.

## Behavior

### 1. Resolve the worktree

Read `.specify/feature.json#worktree_path`. Fall back to `pwd` if absent.

### 2. Refuse if already built

If `<worktree-path>/graphify-out/` exists, ABORT with:
> graphify-out/ already exists. Use /speckit-graphify-update for refreshes, or delete graphify-out/ first for a clean rebuild.

### 3. Offer to seed `.graphifyignore` (only if absent)

If `<worktree-path>/.graphifyignore` does NOT exist, list the worktree's top-level directories (excluding dotfiles, `node_modules/`, `graphify-out/`, common build dirs `dist/`/`build/`/`out/`/`target/`/`.next/`, virtualenvs `venv/`/`.venv/`).

Use `AskUserQuestion` with **multi-select** to ask: **"Which top-level directories should `graphify` skip? (These become entries in `.graphifyignore`.)"**. Offer up to four typical candidates from what's present, e.g.:
- `ios/`, `android/`, `web/` (platform mirrors of the same logic)
- `scripts/`, `infra/`, `specs/`, `docs/` (non-source noise)
- `tests/`, `__tests__/` (depending on project conventions)

Write the user's selections to `<worktree-path>/.graphifyignore`, one per line, each with a trailing `/` to indicate a directory pattern. Prepend a one-line header comment dated today.

If the user picks nothing, write an empty file with the header so the next init doesn't re-prompt.

If `.graphifyignore` already exists, skip this step entirely.

### 4. Ensure `.gitignore` covers graphify's internal state

Append the block below to `<worktree-path>/.gitignore` if the comment header isn't already present (the bash script does this; no manual action needed here):

```
# Graphify internal state (machine-specific or absolute paths)
graphify-out/cache/
graphify-out/manifest.json
graphify-out/cost.json
.graphify_root
```

### 5. Run the build

Invoke the bash script. It runs `graphify "<worktree-path>"` and graphify writes to `<worktree-path>/graphify-out/`. Surface the exit code.

## Execution

- **Bash**: `.specify/extensions/graphify/scripts/bash/graphify-init.sh`
- **PowerShell**: not provided (macOS/Linux; WSL works via the bash script)

## Configuration

None at the Spec Kit layer. Scope is `.graphifyignore` (worktree-rooted, gitignore-style). Edit by hand to refine; both `init` and `update` always run against the worktree root, so the ignore file is the single lever.
