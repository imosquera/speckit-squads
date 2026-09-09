#!/usr/bin/env bash
# Git extension: seed-graph.sh
#
# Build the knowledge graph for a freshly created worktree, so graph-first
# navigation is available from the worktree's first minute instead of being
# silently switched off by a missing `graphify-out/`.
#
# The path argument is not optional and is not a nicety: a bare `graphify
# update` rebuilds whichever project the CWD resolves to, which — run from a
# worktree — is regularly the wrong one.
#
# Version control: the worktree's graph is LOCAL. A graph committed on a feature
# branch makes the freshness gate report STALE forever (it compares the graph's
# built_at_commit against HEAD, and committing the graph moves HEAD past it), so
# this arranges for the rebuild to be invisible to git in this worktree:
#   * untracked graphify-out output -> the repo's info/exclude
#   * already-tracked graphify-out files -> skip-worktree in THIS worktree's index
#
# Best effort throughout. A worktree without a graph is a worse worktree; a
# worktree that failed to be created is no worktree at all, so nothing here is
# allowed to fail the caller.
#
# Usage: seed-graph.sh <worktree-path>
# Env:   SPECKIT_SKIP_GRAPH=1  skip entirely
set -uo pipefail

WORKTREE_PATH="${1:-}"
if [[ -z "$WORKTREE_PATH" || ! -d "$WORKTREE_PATH" ]]; then
    echo "[specify] seed-graph: no such worktree '$WORKTREE_PATH'; skipping graph build" >&2
    exit 0
fi

if [[ "${SPECKIT_SKIP_GRAPH:-}" == "1" ]]; then
    echo "[specify] seed-graph: SPECKIT_SKIP_GRAPH=1; skipping graph build" >&2
    exit 0
fi

if ! command -v graphify >/dev/null 2>&1; then
    echo "[specify] seed-graph: graphify not on PATH; skipping graph build" >&2
    exit 0
fi

# ---- keep the rebuild out of version control (before it writes anything)
COMMON_DIR="$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$COMMON_DIR" ]]; then
    case "$COMMON_DIR" in
        /*) ;;
        *) COMMON_DIR="$(cd "$WORKTREE_PATH" && cd "$COMMON_DIR" && pwd)" ;;
    esac
    EXCLUDE="$COMMON_DIR/info/exclude"
    mkdir -p "$COMMON_DIR/info" 2>/dev/null
    if ! grep -qxF 'graphify-out/' "$EXCLUDE" 2>/dev/null; then
        {
            echo ''
            echo '# Local knowledge graph — rebuilt per worktree, never committed.'
            echo '# A committed graph makes the freshness gate report STALE forever.'
            echo 'graphify-out/'
        } >> "$EXCLUDE" 2>/dev/null
    fi
fi

# Tracked graphify-out files (a repo that committed its graph once) would show
# as modified after the rebuild. skip-worktree is per-index, and a linked
# worktree has its own index, so this is local to this worktree.
TRACKED="$(git -C "$WORKTREE_PATH" ls-files -- graphify-out 2>/dev/null)"
if [[ -n "$TRACKED" ]]; then
    printf '%s\n' "$TRACKED" \
        | tr '\n' '\0' \
        | xargs -0 git -C "$WORKTREE_PATH" update-index --skip-worktree -- 2>/dev/null \
        || echo "[specify] seed-graph: could not skip-worktree tracked graphify-out files" >&2
fi

echo "[specify] seed-graph: building knowledge graph for $WORKTREE_PATH ..." >&2
if graphify update "$WORKTREE_PATH" >/dev/null 2>&1; then
    echo "[specify] seed-graph: graph ready at $WORKTREE_PATH/graphify-out" >&2
else
    echo "[specify] seed-graph: 'graphify update $WORKTREE_PATH' failed; run it by hand before navigating" >&2
fi

exit 0
