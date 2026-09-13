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
#   FRESH:   graph built at <sha>, and every commit since touches only
#            graphify-out/ (usually none — it matches HEAD); tree clean
#   STALE:   the graph is provably behind the tree — rebuild
#   UNKNOWN: freshness is unanswerable (no provenance in graph.json, no HEAD,
#            or the built commit is not in this clone)
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

# A repo may commit its graph on purpose (one graph shared by every checkout
# and CI runner). That is fine — the commit carrying the graph touches only
# graphify-out/, which the comparison below ignores. What is NOT fine is
# committing graphify-out/.graphify_root: it holds an absolute checkout path
# that graphify's post-commit/post-checkout hooks read and rebuild, so every
# checkout would rebuild whichever worktree last committed it.
graphify_root_warning() {
  [[ -n "$(git -C "$ROOT" ls-files -- graphify-out/.graphify_root 2>/dev/null)" ]] || return 0
  echo "WARNING: graphify-out/.graphify_root is committed. It holds an absolute checkout path that"
  echo "         graphify's post-commit/post-checkout hooks rebuild, so every checkout rebuilds"
  echo "         whichever worktree last committed it. Fix: \`git rm --cached graphify-out/.graphify_root\`"
  echo "         and add graphify-out/.graphify_root to .gitignore (graphify rewrites it on every"
  echo "         build and falls back to the checkout root when it is absent)."
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
  graphify_root_warning
  exit 3
fi

if ! HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"; then
  echo "UNKNOWN: not a git checkout — there is no HEAD to compare the graph against. Rebuild with"
  echo "         \`$REBUILD\` if in doubt."
  exit 3
fi

DIRTY="$(git -C "$ROOT" status --porcelain -- . 2>/dev/null | grep -v '^.. graphify-out/' | head -20)"

# HEAD moving past built_at_commit is staleness only if something other than
# the graph moved with it. A commit that carries the graph (or refreshes it)
# touches only graphify-out/, so treating any divergence as STALE made a
# committed graph stale by construction.
SINCE_NOTE="matches HEAD"
if [[ "$BUILT" != "$HEAD_SHA" ]]; then
  if ! SINCE="$(git -C "$ROOT" diff --name-only "$BUILT" HEAD -- . ':(exclude)graphify-out' 2>/dev/null)"; then
    # Not STALE: the built commit is not in this clone (a shallow CI clone, an
    # unfetched branch), so there is nothing to diff against.
    echo "UNKNOWN: graph built at ${BUILT:0:8}, which is not a commit in this clone — freshness is"
    echo "         unanswerable, not failed. Fetch that commit or rebuild with \`$REBUILD\`; until"
    echo "         then treat NEGATIVE answers as unverified."
    graphify_root_warning
    exit 3
  fi
  if [[ -n "$SINCE" ]]; then
    echo "STALE: graph built at ${BUILT:0:8}, HEAD is ${HEAD_SHA:0:8} — rebuild with \`$REBUILD\` before trusting a negative answer"
    graphify_root_warning
    echo "--- files changed since the graph was built ---"
    printf '%s\n' "$SINCE" | head -50
    exit 1
  fi
  SINCE_NOTE="commits since then (to ${HEAD_SHA:0:8}) touch only graphify-out/"
fi

if [[ -n "$DIRTY" ]]; then
  echo "STALE: graph built at ${BUILT:0:8} ($SINCE_NOTE) but the working tree has uncommitted changes — rebuild with \`$REBUILD\` before trusting a negative answer"
  graphify_root_warning
  echo "--- uncommitted ---"
  printf '%s\n' "$DIRTY"
  exit 1
fi

echo "FRESH: graph built at ${BUILT:0:8}, $SINCE_NOTE, working tree clean"
graphify_root_warning
exit 0
