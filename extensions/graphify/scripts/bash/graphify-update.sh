#!/usr/bin/env bash
# graphify-update.sh — Spec Kit after-hook for Principle VIII (Knowledge Graph Freshness).
#
# Resolves the feature's worktree path, then runs `graphify <worktree-path> --update`
# if and only if (a) graphify-out/ already exists in that worktree and (b) the
# `graphify` binary is on PATH. Non-blocking by design: every failure path exits 0
# with a warning so the triggering Spec Kit command is not aborted.
#
# Invoked by .specify/extensions/graphify-update/commands/speckit.graphify.update.md.

set -u   # NOT set -e — we want to swallow failures from /graphify itself.

log() { printf '[graphify-update] %s\n' "$*"; }

# 1. Resolve worktree path.
WORKTREE_PATH=""
FEATURE_JSON=".specify/feature.json"
if [[ -f "$FEATURE_JSON" ]]; then
  # Tolerant grep: works without jq.
  WORKTREE_PATH="$(grep -o '"worktree_path"[^,}]*' "$FEATURE_JSON" 2>/dev/null \
    | head -1 \
    | sed -E 's/.*"worktree_path"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')"
fi
if [[ -z "${WORKTREE_PATH}" || "${WORKTREE_PATH}" == "null" ]]; then
  WORKTREE_PATH="$(pwd)"
fi

# 2. Skip if graphify-out/ doesn't exist.
if [[ ! -d "${WORKTREE_PATH}/graphify-out" ]]; then
  log "graphify-out/ not present at ${WORKTREE_PATH}; skipping update (run /graphify . once to build the initial graph — see README)"
  exit 0
fi

# 3. Warn if binary missing.
if ! command -v graphify >/dev/null 2>&1; then
  log "graphify binary not on PATH; skipping update (see README → Developer setup → Graphify)"
  exit 0
fi

# 4. Run the update non-blockingly.
log "updating graphify-out/ via: graphify ${WORKTREE_PATH} --update"
if ! graphify "${WORKTREE_PATH}" --update; then
  log "warn: graphify --update exited non-zero; graph may be stale. Not blocking the Spec Kit phase."
fi
exit 0
