#!/usr/bin/env bash
# Git extension: worktree-add.sh
# Creates a worktree under the same ${PROJ}.worktrees convention used by
# create-new-feature.sh.

set -euo pipefail

usage() {
    echo "Usage: $0 [--path <absolute-path>] [--parent <absolute-path>] <branch> [start-point]"
}

EXPLICIT_PATH=""
EXPLICIT_PARENT=""
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --path)
            [[ $# -ge 2 ]] || { echo "Error: --path requires a value" >&2; usage >&2; exit 2; }
            EXPLICIT_PATH="$2"
            shift 2
            ;;
        --parent)
            [[ $# -ge 2 ]] || { echo "Error: --parent requires a value" >&2; usage >&2; exit 2; }
            EXPLICIT_PARENT="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --*)
            echo "Error: Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

if [[ ${#POSITIONAL[@]} -lt 1 || ${#POSITIONAL[@]} -gt 2 ]]; then
    usage >&2
    exit 2
fi

BRANCH_NAME="${POSITIONAL[0]}"
START_POINT="${POSITIONAL[1]:-}"

if [[ "$BRANCH_NAME" =~ [[:space:]] ]]; then
    echo "Error: Branch name cannot contain whitespace" >&2
    exit 2
fi

if ! command -v git >/dev/null 2>&1; then
    echo "[specify] Warning: Git is not installed; cannot create worktree" >&2
    exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "[specify] Warning: Current directory is not a Git repository; cannot create worktree" >&2
    exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Resolve collector path using the same convention as create-new-feature.sh.
PRIMARY_ROOT="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
if [[ -z "$PRIMARY_ROOT" ]]; then
    PRIMARY_ROOT="$REPO_ROOT"
fi

if [[ -n "$EXPLICIT_PATH" ]]; then
    WORKTREE_PATH="$EXPLICIT_PATH"
else
    REPO_BASE="$(basename "$PRIMARY_ROOT")"
    REPO_BASE_STRIPPED="$(echo "$REPO_BASE" | sed -E 's/-(main|master|trunk)$//')"

    if [[ -n "$EXPLICIT_PARENT" ]]; then
        WORKTREE_PARENT="$EXPLICIT_PARENT"
    elif [[ -n "${SPECKIT_WORKTREE_PARENT:-}" ]]; then
        WORKTREE_PARENT="$SPECKIT_WORKTREE_PARENT"
    else
        WORKTREE_PARENT="$(dirname "$PRIMARY_ROOT")/${REPO_BASE_STRIPPED}.worktrees"
    fi

    mkdir -p "$WORKTREE_PARENT"
    WORKTREE_PATH="$WORKTREE_PARENT/$BRANCH_NAME"
fi

if [[ -e "$WORKTREE_PATH" ]]; then
    echo "Error: Worktree target path '$WORKTREE_PATH' already exists." >&2
    echo "       Choose a different branch/path or pass --path to override." >&2
    exit 1
fi

set +e
if [[ -n "$START_POINT" ]]; then
    WORKTREE_ERR="$(git worktree add -b "$BRANCH_NAME" "$WORKTREE_PATH" "$START_POINT" 2>&1)"
    RC=$?
else
    if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
        WORKTREE_ERR="$(git worktree add "$WORKTREE_PATH" "$BRANCH_NAME" 2>&1)"
    else
        WORKTREE_ERR="$(git worktree add -b "$BRANCH_NAME" "$WORKTREE_PATH" 2>&1)"
    fi
    RC=$?
fi
set -e

if [[ $RC -ne 0 ]]; then
    echo "Error: Failed to create worktree for branch '$BRANCH_NAME'." >&2
    if [[ -n "$WORKTREE_ERR" ]]; then
        printf '%s\n' "$WORKTREE_ERR" >&2
    fi
    exit 1
fi

# Write `feature_directory` into the new worktree's .specify/feature.json.
# Core Spec Kit's get_feature_paths() resolves the feature directory out of that
# key and hard-errors without it, so a worktree created here (rather than by
# create-new-feature.sh) failed the moment /speckit-plan ran in it. Only the
# directory: this script is handed a branch, never an issue, and inventing a
# source_issue would link the worktree to whatever issue happened to be there.
# The shared writer merges, so an existing source_issue survives, and it also
# gitignores/untracks the file (issue #33).
GIT_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-common.sh"
if [[ -f "$GIT_COMMON" ]]; then
    # shellcheck source=./git-common.sh
    source "$GIT_COMMON"
    spec_kit_write_feature_directory "$WORKTREE_PATH" \
        "specs/$(spec_kit_effective_branch_name "$BRANCH_NAME")"
else
    echo "[specify] Warning: git-common.sh not found; skipped .specify/feature.json" >&2
fi

# Seed the worktree's knowledge graph, so graph-first navigation is available
# from its first minute rather than being switched off by a missing graphify-out/.
SEED_GRAPH="$(dirname "${BASH_SOURCE[0]}")/seed-graph.sh"
[[ -x "$SEED_GRAPH" ]] && "$SEED_GRAPH" "$WORKTREE_PATH" || true

# Install the worktree's dependencies now, rather than letting the implement
# phase discover a missing node_modules through a confusing resolution error
# (issue #51). Best effort; never fails worktree creation.
INSTALL_DEPS="$(dirname "${BASH_SOURCE[0]}")/install-deps.sh"
[[ -x "$INSTALL_DEPS" ]] && "$INSTALL_DEPS" "$WORKTREE_PATH" || true

echo "BRANCH_NAME: $BRANCH_NAME"
echo "WORKTREE_PATH: $WORKTREE_PATH"
printf '# NEXT STEP: cd %q\n' "$WORKTREE_PATH"
