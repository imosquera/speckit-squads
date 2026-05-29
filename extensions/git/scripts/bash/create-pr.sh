#!/usr/bin/env bash
# Git extension: create-pr.sh
# Open a GitHub PR for the current feature branch. If .specify/feature.json
# carries `source_issue`, the PR body includes `Closes #N` so merging the PR
# automatically closes the originating GitHub issue.
#
# Usage: create-pr.sh [base_branch]
#   base_branch defaults to "main".

set -e

BASE_BRANCH="${1:-main}"

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_find_project_root() {
    local dir="$1"
    while [ "$dir" != "/" ]; do
        if [ -d "$dir/.specify" ] || [ -d "$dir/.git" ]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

REPO_ROOT=$(_find_project_root "$SCRIPT_DIR") || REPO_ROOT="$(pwd)"
cd "$REPO_ROOT"

if ! command -v git >/dev/null 2>&1; then
    echo "[specify] Error: git not found" >&2
    exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
    echo "[specify] Error: gh CLI not found; install https://cli.github.com/" >&2
    exit 1
fi
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "[specify] Error: not inside a git repository" >&2
    exit 1
fi

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" = "$BASE_BRANCH" ]; then
    echo "[specify] Error: refuse to open a PR from $BASE_BRANCH into itself" >&2
    exit 1
fi

# Locate feature directory and source_issue
_feature_json="$REPO_ROOT/.specify/feature.json"
_feature_dir=""
_source_issue=""
if [ -f "$_feature_json" ]; then
    _feature_dir=$(grep -E '"feature_directory"[[:space:]]*:' "$_feature_json" \
        | head -1 \
        | sed -E 's/.*"feature_directory"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
    _source_issue=$(grep -E '"source_issue"[[:space:]]*:' "$_feature_json" 2>/dev/null \
        | head -1 \
        | sed -E 's/.*"source_issue"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/')
fi

# Build PR title from the spec.md H1 if available, otherwise from branch name
_pr_title=""
if [ -n "$_feature_dir" ] && [ -f "$REPO_ROOT/$_feature_dir/spec.md" ]; then
    _pr_title=$(grep -m1 -E '^#[[:space:]]*Feature Specification:' "$REPO_ROOT/$_feature_dir/spec.md" \
        | sed -E 's/^#[[:space:]]*Feature Specification:[[:space:]]*//')
fi
if [ -z "$_pr_title" ]; then
    _pr_title="$CURRENT_BRANCH"
fi

# Build PR body
_pr_body=""
if [ -n "$_feature_dir" ]; then
    _pr_body="Spec: \`${_feature_dir}/spec.md\`

See plan, tasks, and quickstart under \`${_feature_dir}/\`."
else
    _pr_body="See branch \`${CURRENT_BRANCH}\`."
fi

if echo "$_source_issue" | grep -Eq '^[0-9]+$'; then
    _pr_body="${_pr_body}

Closes #${_source_issue}"
fi

# Ensure branch is pushed
if ! git ls-remote --exit-code --heads origin "$CURRENT_BRANCH" >/dev/null 2>&1; then
    echo "[specify] Pushing $CURRENT_BRANCH to origin..." >&2
    git push -u origin "$CURRENT_BRANCH" >/dev/null
fi

# Open the PR (skip if one already exists for this branch)
if gh pr view "$CURRENT_BRANCH" >/dev/null 2>&1; then
    _url=$(gh pr view "$CURRENT_BRANCH" --json url -q .url)
    echo "[OK] PR already exists: $_url" >&2
    exit 0
fi

_url=$(gh pr create --base "$BASE_BRANCH" --head "$CURRENT_BRANCH" \
    --title "$_pr_title" --body "$_pr_body")
echo "[OK] PR created: $_url" >&2
