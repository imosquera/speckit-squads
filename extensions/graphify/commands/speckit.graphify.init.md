---
description: "Build the initial graphify-out/ knowledge graph for the current feature worktree"
---

# Initialize Knowledge Graph

Run a one-time full `/graphify <worktree-path>` build so the worktree gets a fresh `graphify-out/` directory. Pair this with `speckit.graphify.update` (which only refreshes an existing graph and is wired into after-hooks).

This is an explicit developer action — not a hook. Run it once per worktree before any after-hook would attempt an update.

## Behavior

1. Resolve the worktree path from `.specify/feature.json#worktree_path`. Fall back to `pwd` if absent.
2. If `<worktree-path>/graphify-out/` already exists, refuse with a non-zero exit. Use `speckit.graphify.update` for refreshes; delete `graphify-out/` first if a clean rebuild is intended.
3. If the `graphify` binary is not on `PATH`, exit non-zero with a pointer to the README install section.
4. Append graphify's machine-specific internal-state patterns to `<worktree-path>/.gitignore` if not already present. The block lives in `gitignore-additions.txt` next to the extension manifest:

   ```
   # Graphify internal state (machine-specific or absolute paths)
   graphify-out/cache/
   graphify-out/manifest.json
   graphify-out/cost.json
   .graphify_root
   ```

   Detection is via the comment header — if that exact line already exists in `.gitignore`, the block is skipped.
5. Run `graphify "<worktree-path>"` and surface its exit code.

## Execution

- **Bash**: `.specify/extensions/graphify/scripts/bash/graphify-init.sh`
- **PowerShell**: not provided (macOS/Linux; WSL works via the bash script)

## Configuration

None.
