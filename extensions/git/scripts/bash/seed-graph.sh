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
# Version control: whether the repo tracks a graph at HEAD decides it.
#   * UNTRACKED -> graphify-out/ goes in the repo's info/exclude, so the rebuild
#     is never swept into a commit by accident.
#   * TRACKED   -> the repo committed its graph on purpose; leave it visible (no
#     exclude, no skip-worktree) and heal earlier runs that hid it. A tracked
#     graph is not stale by construction: the freshness gate ignores commits
#     that touch only graphify-out/.
# The graph-first-navigation preset's post-install.sh carries the same logic (a
# separate installable script tree) — keep the two in step.
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

# ---- graphify-out and git (before the rebuild writes anything)
COMMON_DIR="$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$COMMON_DIR" ]]; then
    case "$COMMON_DIR" in
        /*) ;;
        *) COMMON_DIR="$(cd "$WORKTREE_PATH" && cd "$COMMON_DIR" && pwd)" ;;
    esac
    EXCLUDE="$COMMON_DIR/info/exclude"
    TRACKED="$(git -C "$WORKTREE_PATH" ls-files -- graphify-out 2>/dev/null || true)"

    if [[ -z "$TRACKED" ]]; then
        mkdir -p "$COMMON_DIR/info" 2>/dev/null
        if ! grep -qxF 'graphify-out/' "$EXCLUDE" 2>/dev/null; then
            {
                echo ''
                echo '# Local knowledge graph — rebuilt per worktree, not tracked by this repo.'
                echo '# Excluded so a rebuild is never committed by accident.'
                echo 'graphify-out/'
            } >> "$EXCLUDE" 2>/dev/null
        fi
    else
        # Heal: our own stanza only (the same expression pre-uninstall.sh uses),
        # and skip-worktree bits in THIS worktree's index (a linked worktree has
        # its own index).
        if [[ -f "$EXCLUDE" ]] && grep -qxF 'graphify-out/' "$EXCLUDE" && command -v python3 >/dev/null 2>&1; then
            python3 - "$EXCLUDE" <<'PYEOF' >&2 || true
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
new = re.sub(r"\n*# Local knowledge graph[^\n]*\n# [^\n]*\ngraphify-out/\n", "\n", t)
if new != t:
    p.write_text(new, encoding="utf-8")
    print(f"[specify] seed-graph: removed our graphify-out/ exclusion from {p} (the repo tracks its graph)")
PYEOF
        fi
        SKIPPED="$(git -C "$WORKTREE_PATH" ls-files -v -- graphify-out 2>/dev/null | sed -n 's/^S //p')"
        if [[ -n "$SKIPPED" ]]; then
            printf '%s\n' "$SKIPPED" \
                | tr '\n' '\0' \
                | xargs -0 git -C "$WORKTREE_PATH" update-index --no-skip-worktree -- 2>/dev/null \
                || echo "[specify] seed-graph: could not clear skip-worktree on tracked graphify-out files" >&2
        fi
        echo "[specify] seed-graph: graphify-out/ is tracked here — left tracked and visible (no exclude, no skip-worktree)" >&2
        if [[ -n "$(git -C "$WORKTREE_PATH" ls-files -- graphify-out/.graphify_root 2>/dev/null || true)" ]]; then
            echo "[specify] seed-graph: WARNING: graphify-out/.graphify_root is committed. It holds an absolute" >&2
            echo "  checkout path that graphify's post-commit/post-checkout hooks rebuild, so every checkout" >&2
            echo "  rebuilds whichever worktree last committed it. Fix: \`git rm --cached graphify-out/.graphify_root\`" >&2
            echo "  and add graphify-out/.graphify_root to .gitignore (graphify rewrites it on every build and" >&2
            echo "  falls back to the checkout root when it is absent)." >&2
        fi
    fi
fi

echo "[specify] seed-graph: building knowledge graph for $WORKTREE_PATH ..." >&2
if graphify update "$WORKTREE_PATH" >/dev/null 2>&1; then
    echo "[specify] seed-graph: graph ready at $WORKTREE_PATH/graphify-out" >&2
else
    echo "[specify] seed-graph: 'graphify update $WORKTREE_PATH' failed; run it by hand before navigating" >&2
fi

exit 0
