---
description: "Build the initial graphify-out/ knowledge graph. On first run, scans the worktree and writes scan_subpath to graphify-config.yml."
---

## User Input

```text
$ARGUMENTS
```

# Initialize Knowledge Graph

Run a one-time full build so the worktree gets a fresh `graphify-out/` directory.

This command is an explicit developer action — not a hook. Run it once per worktree before any `after_*` hook tries to update the graph.

## Behavior

### 1. Resolve the worktree

Read `.specify/feature.json#worktree_path`. Fall back to `pwd` if absent.

### 2. Refuse if already built

If `<worktree-path>/graphify-out/` exists, ABORT with:
> graphify-out/ already exists. Use /speckit-graphify-update for refreshes, or delete graphify-out/ first for a clean rebuild.

### 3. Resolve or elicit `scan_subpath`

Config file: `.specify/extensions/graphify/graphify-config.yml`. The relevant key is `scan_subpath` (string; default `.`).

**If the config file is missing OR `scan_subpath` is unset:**

1. List the worktree's top-level directories, excluding dotfiles, `node_modules/`, `graphify-out/`, build artifacts (`dist/`, `build/`, `out/`, `target/`, `.next/`), virtualenvs (`venv/`, `.venv/`), and the directories `tests/` / `__tests__/` (those usually shouldn't be the *only* scope).

2. Use `AskUserQuestion` to ask: **"Which subpath should graphify scan? Pick a single source root, or `.` for the entire worktree."** Offer up to four options:
   - The top 3 most-likely source directories (typically `src/`, `app/`, `lib/`, `packages/`, or the language-specific equivalent — pick what's actually present).
   - **"`.` (whole worktree)"** — for small repos with no clear single source root.

3. Write the user's choice to `.specify/extensions/graphify/graphify-config.yml`:

   ```yaml
   # Written by /speckit-graphify-init on <YYYY-MM-DD>.
   scan_subpath: <user-choice>
   ```

   Create the directory if missing. Preserve any existing keys in the file if it already exists with other content.

**If the config file already has `scan_subpath`:** use it. Do not re-prompt. (Re-prompting is a manual action — the user can edit the file or delete the key and re-run init.)

### 4. Ensure `.gitignore` covers graphify's internal state

Append the block below to `<worktree-path>/.gitignore` if the comment header isn't already present:

```
# Graphify internal state (machine-specific or absolute paths)
graphify-out/cache/
graphify-out/manifest.json
graphify-out/cost.json
.graphify_root
```

### 5. Run the build

Invoke the bash script (which re-reads worktree + config and runs `graphify "<worktree>/<scan_subpath>"`). Surface its exit code.

## Execution

- **Bash**: `.specify/extensions/graphify/scripts/bash/graphify-init.sh`
- **PowerShell**: not provided (macOS/Linux; WSL works via the bash script)

## Configuration

- `graphify-config.yml#scan_subpath` (string, default `.`) — relative path within the worktree that both init and update operate on. Edit by hand to change scope; the init command will not re-prompt once the key is set.
