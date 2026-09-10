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
#   FRESH:   graph built at <sha>, matches HEAD, working tree clean
#   STALE:   the graph is provably behind the tree — rebuild
#   UNKNOWN: freshness is unanswerable (no provenance in graph.json)
#   ABSENT:  no graphify-out/graph.json — the graph does not exist here
#
# Exit: 0 = FRESH, 1 = STALE, 2 = ABSENT, 3 = UNKNOWN.
#
# STALE means REBUILD, not "fall back to grep". Every remedy line below names
# the path: a bare `graphify update` rebuilds whichever project the CWD
# resolves to, which — run from a worktree — has already been the wrong one.
set -uo pipefail

ROOT="${1:-$PWD}"
# Absolutise before printing it into a remedy: a relative `.` in the hint is
# how the bare-command failure mode comes back.
ROOT="$(cd "$ROOT" 2>/dev/null && pwd)" || ROOT="${1:-$PWD}"
GRAPH="$ROOT/graphify-out/graph.json"
REBUILD="graphify update $ROOT"

if [[ ! -f "$GRAPH" ]]; then
  echo "ABSENT: no $GRAPH — build it with \`$REBUILD\`; grep is the fallback only until you do"
  exit 2
fi

# A graph committed to the repo can never be fresh — every commit moves HEAD
# past its built_at_commit — and the rebuild then dirties the tree, so the gate
# reports it as its own condition rather than as staleness.
committed_note() {
  local n
  n="$(git -C "$ROOT" ls-files -- graphify-out 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${n:-0}" -gt 0 ]] || return 0
  echo "NOTE: graphify-out/ is committed here ($n tracked files) — a committed graph is stale by"
  echo "      construction and its rebuild dirties the tree. Re-run the preset's post-install.sh"
  echo "      (it excludes the directory and skip-worktrees the tracked files), or untrack it."
}

# `built_at_commit` is a top-level key but sits megabytes into a real graph, so
# scan the file rather than parsing JSON that can run to hundreds of thousands
# of lines. `-m1` stops at the first match.
BUILT="$(grep -m1 -oaE '"built_at_commit"[[:space:]]*:[[:space:]]*"[0-9a-f]{7,40}"' "$GRAPH" 2>/dev/null | grep -oE '[0-9a-f]{7,40}')"

if [[ -z "$BUILT" ]]; then
  # Not the same thing as stale: older graphify builds record no provenance at
  # all, so there is no commit to compare against. Reporting that as STALE made
  # the gate cry wolf on every single run.
  echo "UNKNOWN: graph.json records no built_at_commit — this build predates provenance, so freshness"
  echo "         is unanswerable, not failed. The graph may well be current. Rebuild with \`$REBUILD\`"
  echo "         to get a comparable graph; until then treat NEGATIVE answers as unverified."
  committed_note
  exit 3
fi

if ! HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"; then
  echo "UNKNOWN: not a git checkout — there is no HEAD to compare the graph against. Rebuild with"
  echo "         \`$REBUILD\` if in doubt."
  exit 3
fi

DIRTY="$(git -C "$ROOT" status --porcelain -- . 2>/dev/null | grep -v '^.. graphify-out/' | head -20)"

if [[ "$BUILT" != "$HEAD_SHA" ]]; then
  echo "STALE: graph built at ${BUILT:0:8}, HEAD is ${HEAD_SHA:0:8} — rebuild with \`$REBUILD\` before trusting a negative answer"
  committed_note
  echo "--- files changed since the graph was built ---"
  git -C "$ROOT" diff --name-only "$BUILT" HEAD 2>/dev/null | grep -v '^graphify-out/' | head -50
  exit 1
fi

if [[ -n "$DIRTY" ]]; then
  echo "STALE: graph matches HEAD (${BUILT:0:8}) but the working tree has uncommitted changes — rebuild with \`$REBUILD\` before trusting a negative answer"
  echo "--- uncommitted ---"
  printf '%s\n' "$DIRTY"
  exit 1
fi

echo "FRESH: graph built at ${BUILT:0:8}, matches HEAD, working tree clean"
exit 0
