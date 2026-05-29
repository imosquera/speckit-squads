#!/usr/bin/env bash
# graphify-init.sh — one-time initial build of the knowledge graph for a worktree.
#
# Resolves the feature's worktree path (same logic as graphify-update.sh) and
# runs `graphify <worktree-path>` to create graphify-out/ from scratch. Refuses
# to clobber an existing graphify-out/ — use the update command for that.
#
# Invoked by .specify/extensions/graphify/commands/speckit.graphify.init.md.

set -u

log() { printf '[graphify-init] %s\n' "$*"; }

# 1. Resolve worktree path (same convention as graphify-update.sh).
WORKTREE_PATH=""
FEATURE_JSON=".specify/feature.json"
if [[ -f "$FEATURE_JSON" ]]; then
  WORKTREE_PATH="$(grep -o '"worktree_path"[^,}]*' "$FEATURE_JSON" 2>/dev/null \
    | head -1 \
    | sed -E 's/.*"worktree_path"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')"
fi
if [[ -z "${WORKTREE_PATH}" || "${WORKTREE_PATH}" == "null" ]]; then
  WORKTREE_PATH="$(pwd)"
fi

# 2. Refuse if graphify-out/ already exists — caller should use update instead.
if [[ -d "${WORKTREE_PATH}/graphify-out" ]]; then
  log "graphify-out/ already exists at ${WORKTREE_PATH}; refusing to clobber. Use speckit.graphify.update."
  exit 1
fi

# 3. Require the binary for init (unlike update, init is an explicit action).
if ! command -v graphify >/dev/null 2>&1; then
  log "graphify binary not on PATH. Install it before running init (see README)."
  exit 1
fi

# 4. Ensure .gitignore covers graphify's machine-specific internal state.
ensure_gitignore() {
  local gi="${WORKTREE_PATH}/.gitignore"
  local marker="# Graphify internal state (machine-specific or absolute paths)"
  if [[ -f "$gi" ]] && grep -qF "$marker" "$gi"; then
    return 0
  fi
  log "appending graphify entries to ${gi}"
  {
    [[ -f "$gi" ]] && [[ -s "$gi" ]] && printf '\n'
    printf '%s\n' "$marker"
    printf 'graphify-out/cache/\n'
    printf 'graphify-out/manifest.json\n'
    printf 'graphify-out/cost.json\n'
    printf '.graphify_root\n'
  } >> "$gi"
}
ensure_gitignore

# 5. Run the initial build. Surface failures — this command IS the user action.
log "building initial knowledge graph via: graphify ${WORKTREE_PATH}"
graphify "${WORKTREE_PATH}"
