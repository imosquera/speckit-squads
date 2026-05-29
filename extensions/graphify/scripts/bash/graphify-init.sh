#!/usr/bin/env bash
# graphify-init.sh — one-time initial build of the knowledge graph for a worktree.
#
# Resolves the feature's worktree and the configured scan_subpath, then runs
# `graphify <worktree>/<scan_subpath>` to create graphify-out/ from scratch.
# Refuses to clobber an existing graphify-out/ — use the update script for that.
#
# Invoked by .specify/extensions/graphify/commands/speckit.graphify.init.md.
# The command MD is responsible for writing scan_subpath into
# graphify-config.yml interactively BEFORE this script runs; this script only
# reads the resulting config.

set -u

log() { printf '[graphify-init] %s\n' "$*"; }

yaml_scalar() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  grep -E "^[[:space:]]*${key}[[:space:]]*:" "$file" 2>/dev/null \
    | head -1 \
    | sed -E "s/^[[:space:]]*${key}[[:space:]]*:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^['\"]//; s/['\"]$//"
}

# 1. Resolve worktree path.
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

# 3. Require the binary for init.
if ! command -v graphify >/dev/null 2>&1; then
  log "graphify binary not on PATH. Install it before running init (see README)."
  exit 1
fi

# 4. Resolve scan_subpath (default ".").
CONFIG_FILE=".specify/extensions/graphify/graphify-config.yml"
SCAN_SUBPATH="$(yaml_scalar "$CONFIG_FILE" scan_subpath)"
[[ -z "$SCAN_SUBPATH" ]] && SCAN_SUBPATH="."

if [[ "$SCAN_SUBPATH" == "." ]]; then
  TARGET="${WORKTREE_PATH}"
else
  TARGET="${WORKTREE_PATH}/${SCAN_SUBPATH}"
fi

if [[ ! -d "$TARGET" ]]; then
  log "scan_subpath '${SCAN_SUBPATH}' resolves to '${TARGET}' which does not exist. Edit ${CONFIG_FILE} or re-run the init command so it can rewrite the config."
  exit 1
fi

# 5. Ensure .gitignore covers graphify's machine-specific internal state.
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

# 6. Run the initial build over the configured target.
log "building initial knowledge graph via: graphify ${TARGET}"
graphify "${TARGET}"
