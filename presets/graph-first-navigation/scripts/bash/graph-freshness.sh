#!/usr/bin/env bash
# Report whether the knowledge graph is fresh relative to the working tree.
#
# A graph is built against a commit; a feature worktree diverges from it. Any
# "nothing else reads this" answer taken from a stale graph is a guess wearing a
# fact's clothes, so this check gates that claim.
#
# Usage: graph-freshness.sh [project-dir]
#
# Output (stdout, one verdict line first):
#   FRESH: graph built at <sha>, matches HEAD, working tree clean
#   STALE: <reason>
#   ABSENT: no graphify-out/graph.json — the graph does not exist here
#
# Exit: 0 = FRESH, 1 = STALE, 2 = ABSENT.
#
# STALE means REBUILD (`graphify update`), not "fall back to grep".
set -uo pipefail

ROOT="${1:-$PWD}"
GRAPH="$ROOT/graphify-out/graph.json"

if [[ ! -f "$GRAPH" ]]; then
  echo "ABSENT: no $GRAPH — this project has no knowledge graph; grep is the fallback here"
  exit 2
fi

# `built_at_commit` is a top-level key but sits megabytes into a real graph, so
# scan the file rather than parsing JSON that can run to hundreds of thousands
# of lines. `-m1` stops at the first match.
BUILT="$(grep -m1 -oaE '"built_at_commit"[[:space:]]*:[[:space:]]*"[0-9a-f]{7,40}"' "$GRAPH" 2>/dev/null | grep -oE '[0-9a-f]{7,40}')"

if [[ -z "$BUILT" ]]; then
  echo "STALE: graph.json records no built_at_commit — provenance unknown, rebuild with \`graphify update\`"
  exit 1
fi

if ! HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"; then
  echo "STALE: not a git checkout — cannot verify the graph against a commit; rebuild with \`graphify update\` if in doubt"
  exit 1
fi

DIRTY="$(git -C "$ROOT" status --porcelain -- . 2>/dev/null | grep -v '^.. graphify-out/' | head -20)"

if [[ "$BUILT" != "$HEAD_SHA" ]]; then
  echo "STALE: graph built at ${BUILT:0:8}, HEAD is ${HEAD_SHA:0:8} — rebuild with \`graphify update\` before trusting a negative answer"
  echo "--- files changed since the graph was built ---"
  git -C "$ROOT" diff --name-only "$BUILT" HEAD 2>/dev/null | head -50
  exit 1
fi

if [[ -n "$DIRTY" ]]; then
  echo "STALE: graph matches HEAD (${BUILT:0:8}) but the working tree has uncommitted changes — rebuild with \`graphify update\` before trusting a negative answer"
  echo "--- uncommitted ---"
  printf '%s\n' "$DIRTY"
  exit 1
fi

echo "FRESH: graph built at ${BUILT:0:8}, matches HEAD, working tree clean"
exit 0
