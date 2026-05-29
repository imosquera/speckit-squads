#!/usr/bin/env bash
# graphify-update.sh — Spec Kit after-hook for Principle VIII (Knowledge Graph Freshness).
#
# Resolves the feature's worktree path and the configured scan_subpath, then
# runs `graphify update <worktree>/<scan_subpath>` if and only if
# (a) graphify-out/ already exists in the worktree and (b) the `graphify`
# binary is on PATH. Non-blocking by design: every failure path exits 0 with
# a warning so the triggering Spec Kit command is not aborted.
#
# Invoked by .specify/extensions/graphify/commands/speckit.graphify.update.md.

set -u   # NOT set -e — we want to swallow failures from graphify itself.

log() { printf '[graphify-update] %s\n' "$*"; }

# Tolerant YAML scalar parser: prints the value of `<key>: <value>` or empty.
# Strips inline comments and surrounding quotes. Does NOT support nested keys.
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

# 2. Resolve scan_subpath from config (default ".").
CONFIG_FILE=".specify/extensions/graphify/graphify-config.yml"
SCAN_SUBPATH="$(yaml_scalar "$CONFIG_FILE" scan_subpath)"
[[ -z "$SCAN_SUBPATH" ]] && SCAN_SUBPATH="."

# 3. Compose the target path (avoid trailing /. when subpath is ".").
if [[ "$SCAN_SUBPATH" == "." ]]; then
  TARGET="${WORKTREE_PATH}"
else
  TARGET="${WORKTREE_PATH}/${SCAN_SUBPATH}"
fi

# 4. Skip if graphify-out/ doesn't exist in the worktree (init wasn't run).
if [[ ! -d "${WORKTREE_PATH}/graphify-out" ]]; then
  log "graphify-out/ not present at ${WORKTREE_PATH}; skipping update (run /speckit-graphify-init once to build the initial graph)"
  exit 0
fi

# 5. Warn if binary missing.
if ! command -v graphify >/dev/null 2>&1; then
  log "graphify binary not on PATH; skipping update"
  exit 0
fi

# 6. Refuse if the resolved target doesn't exist (config drift).
if [[ ! -d "$TARGET" ]]; then
  log "scan_subpath '${SCAN_SUBPATH}' resolves to '${TARGET}' which does not exist; skipping update. Check ${CONFIG_FILE}."
  exit 0
fi

# 7. Run the update non-blockingly.
log "updating graphify-out/ via: graphify update ${TARGET}"
if ! graphify update "${TARGET}"; then
  log "warn: graphify update exited non-zero; graph may be stale. Not blocking the Spec Kit phase."
fi
exit 0
