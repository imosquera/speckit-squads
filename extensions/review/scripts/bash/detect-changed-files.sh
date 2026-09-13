#!/usr/bin/env bash
# Detect changed files for code review via git diff
#
# The single source of review scope for /speckit-review-run. Three modes; the
# review engine is the same in all of them, only the scope varies:
#
#   Mode A — feature branch: the current branch against the default branch from
#            the merge-base, plus staged, unstaged and untracked work.
#   Mode B — working directory: staged + unstaged + untracked changes when there
#            is no feature branch (e.g. working directly on the default branch).
#   Mode C — pull request (`--pr <N>`): the PR's files from `gh pr diff`, based at
#            the merge-base of origin/<baseRefName> and the PR head sha. When some
#            local worktree has the head branch checked out, repo_root is that
#            worktree (`checkout: worktree`); otherwise repo_root is this checkout
#            and reviewers read the head commit through git objects only
#            (`checkout: none` — `git show <head>:<path>`, `git diff <base> <head>`).
#
# Usage: ./detect-changed-files.sh [--json] [--pr <N>]
#
# OPTIONS:
#   --json        Output in JSON format (for machine consumption)
#   --pr <N>      Review pull request N (Mode C). Requires `gh`.
#   --help, -h    Show this help message
#
# EXIT CODES:
#   0  Changed files detected successfully
#   1  Error (git/gh unavailable, not a git repository, PR unreadable, PR head
#      commit unobtainable, no merge-base)
#   2  No changes detected
#
# OUTPUTS:
#   Text mode:
#     BRANCH: <current branch; the PR head branch in Mode C>
#     DEFAULT_BRANCH: <default branch; the PR base branch in Mode C>
#     REPO_ROOT: <absolute worktree root>
#     DIFF_BASE: <merge-base>  (empty in Mode B; in Mode A `git diff <base>` covers
#                             committed + staged + unstaged)
#     MODE: <detection mode description>
#     PR: <number>        PR_URL: <url>     PR_TITLE: <title>
#     HEAD: <PR head sha> CHECKOUT: worktree|none   (all empty in Modes A/B)
#     CHANGED_FILES:
#       file1
#
#   JSON mode (every key present in every mode, so the shape is stable):
#     {"branch":"...","default_branch":"...","repo_root":"...","diff_base":"...",
#      "mode":"...","pr":"...","pr_url":"...","pr_title":"...","head":"...",
#      "checkout":"...","changed_files":["..."]}
#
# `graphify-out/` paths are NOT filtered here, in any mode: the coordinator drops
# them before dispatch.

set -e

# --- Argument parsing ---
JSON_MODE=false
PR_NUMBER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) JSON_MODE=true ;;
        --pr)
            if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
                echo "ERROR: --pr requires a pull request number" >&2; exit 1
            fi
            PR_NUMBER="$2"; shift ;;
        --pr=*) PR_NUMBER="${1#--pr=}" ;;
        --help|-h)
            cat << 'EOF'
Usage: detect-changed-files.sh [--json] [--pr <N>]

Detect changed files for code review.

  Mode A  feature branch: merge-base with the default branch + staged/unstaged/untracked
  Mode B  default branch: staged/unstaged/untracked working-directory changes
  Mode C  --pr <N>: the PR's files (gh pr diff), diff_base = merge-base of
          origin/<base> and the PR head sha. checkout=worktree when a local
          worktree has the head branch checked out, else checkout=none (read the
          head via `git show <head>:<path>`).

OPTIONS:
  --json        Output in JSON format
  --pr <N>      Review pull request N (requires gh)
  --help, -h    Show this help message

EXIT CODES:
  0  Changed files detected successfully
  1  Error (git/gh unavailable, not a git repository, PR or its head unobtainable)
  2  No changes detected
EOF
            exit 0
            ;;
        *) echo "ERROR: Unknown option '$1'" >&2; exit 1 ;;
    esac
    shift
done

if [[ -n "$PR_NUMBER" && ! "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --pr expects a numeric pull request number, got '$PR_NUMBER'" >&2
    exit 1
fi

# --- Helper: escape a string for safe JSON embedding ---
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"   # \ → \\
    s="${s//\"/\\\"}"   # " → \\"
    s="${s//$'\t'/\\t}"    # tab → \t
    s="${s//$'\n'/\\n}"    # newline → \n
    s="${s//$'\r'/\\r}"    # carriage return → \r
    printf '%s' "$s"
}

# --- Helper: format bash array as JSON array ---
fmt_array() {
    local arr=("$@")
    if [[ ${#arr[@]} -eq 0 ]]; then echo "[]"; return; fi
    local first=true
    local result="["
    for item in "${arr[@]}"; do
        if $first; then first=false; else result+=","; fi
        result+="\"$(json_escape "$item")\""
    done
    result+="]"
    echo "$result"
}

# --- Helper: output error and exit ---
error_exit() {
    local message="$1"
    local code="${2:-1}"
    if $JSON_MODE; then
        printf '{"error":"%s"}\n' "$(json_escape "$message")"
    else
        echo "Error: $message" >&2
    fi
    exit "$code"
}

# --- Helper: append unique non-empty entries to CHANGED_FILES (bash 3, no assoc arrays) ---
add_unique() {
    local f existing _dup
    for f in "$@"; do
        [[ -z "$f" ]] && continue
        _dup=false
        for existing in "${CHANGED_FILES[@]}"; do
            if [[ "$existing" == "$f" ]]; then _dup=true; break; fi
        done
        $_dup || CHANGED_FILES+=("$f")
    done
}

# --- 1a. Verify Git Availability ---
if ! command -v git >/dev/null 2>&1; then
    error_exit "git is not available. The review extension requires git to identify changed files." 1
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    error_exit "Not a git repository. The review extension requires git to identify changed files." 1
fi

# --- 1b. Detect Branch Context ---

# Get current branch (empty string if detached HEAD)
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")

# Absolute root of THIS worktree — reviewers are dispatched against it explicitly
# so a subagent can't inherit the session cwd and review another checkout.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

# Base the reviewers must diff AGAINST (Modes A and C; empty in Mode B).
# A base, not a `base...HEAD` range: two-dot `git diff <base>` reaches the working
# tree, so it covers the staged and unstaged work the detector also lists. A
# three-dot range compares two commits and would silently drop it.
DIFF_BASE=""

# Mode C fields — empty in Modes A/B so the JSON shape never changes.
PR_URL=""
PR_TITLE=""
HEAD_SHA=""
CHECKOUT=""

# Determine default branch
DEFAULT_BRANCH=""

# Try symbolic-ref first
symref=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || echo "")
if [[ -n "$symref" ]]; then
    DEFAULT_BRANCH="${symref##refs/remotes/origin/}"
fi

# Fallback: check origin/main
if [[ -z "$DEFAULT_BRANCH" ]]; then
    if git rev-parse --verify origin/main >/dev/null 2>&1; then
        DEFAULT_BRANCH="main"
    fi
fi

# Fallback: check origin/master
if [[ -z "$DEFAULT_BRANCH" ]]; then
    if git rev-parse --verify origin/master >/dev/null 2>&1; then
        DEFAULT_BRANCH="master"
    fi
fi

# --- 1c. Get Changed Files ---

CHANGED_FILES=()
MODE=""

if [[ -n "$PR_NUMBER" ]]; then
    # Mode C — Pull Request
    if ! command -v gh >/dev/null 2>&1; then
        error_exit "gh is not available. --pr $PR_NUMBER needs the GitHub CLI to read the pull request." 1
    fi

    # One field per line; the title is last because it is the only free text.
    # stderr is kept apart so a gh warning can never be parsed as a field.
    GH_ERR=$(mktemp "${TMPDIR:-/tmp}/review-gh.XXXXXX")
    trap 'rm -f "$GH_ERR"' EXIT
    if ! PR_FIELDS=$(gh pr view "$PR_NUMBER" \
            --json number,headRefName,headRefOid,baseRefName,url,title,isCrossRepository \
            --jq '.number, .headRefName, .headRefOid, .baseRefName, .url, .isCrossRepository, .title' 2>"$GH_ERR"); then
        error_exit "gh pr view $PR_NUMBER failed: $(cat "$GH_ERR")" 1
    fi
    {
        IFS= read -r _num || true
        IFS= read -r HEAD_REF || true
        IFS= read -r HEAD_SHA || true
        IFS= read -r BASE_REF || true
        IFS= read -r PR_URL || true
        IFS= read -r CROSS_REPO || true
        IFS= read -r PR_TITLE || true
    } <<< "$PR_FIELDS"
    if [[ -z "$HEAD_REF" || -z "$HEAD_SHA" || -z "$BASE_REF" ]]; then
        error_exit "gh pr view $PR_NUMBER returned no head/base (got: $PR_FIELDS)" 1
    fi

    # The head commit must exist locally: every reviewer reads through it.
    if ! git cat-file -e "${HEAD_SHA}^{commit}" 2>/dev/null; then
        git fetch -q origin "pull/${PR_NUMBER}/head" >/dev/null 2>&1 \
            || git fetch -q origin "$HEAD_REF" >/dev/null 2>&1 || true
    fi
    if ! git cat-file -e "${HEAD_SHA}^{commit}" 2>/dev/null; then
        error_exit "PR #$PR_NUMBER head $HEAD_SHA is not in this repository and could not be fetched (tried origin pull/$PR_NUMBER/head and origin $HEAD_REF)" 1
    fi

    # Base: refresh origin/<base>; a stale local copy is tolerated, a missing one is not.
    git fetch -q origin "+refs/heads/${BASE_REF}:refs/remotes/origin/${BASE_REF}" >/dev/null 2>&1 || true
    if ! git rev-parse --verify -q "refs/remotes/origin/${BASE_REF}" >/dev/null; then
        error_exit "PR #$PR_NUMBER base origin/$BASE_REF is not available locally and could not be fetched" 1
    fi
    DIFF_BASE=$(git merge-base "refs/remotes/origin/${BASE_REF}" "$HEAD_SHA" 2>/dev/null || echo "")
    if [[ -z "$DIFF_BASE" ]]; then
        error_exit "no merge-base between origin/$BASE_REF and PR #$PR_NUMBER head $HEAD_SHA" 1
    fi

    # Files: gh is authoritative for membership. Paths absent from the head commit
    # (deletions) are dropped, matching the ACMR filter of Modes A/B.
    if ! PR_FILES=$(gh pr diff "$PR_NUMBER" --name-only 2>"$GH_ERR"); then
        error_exit "gh pr diff $PR_NUMBER --name-only failed: $(cat "$GH_ERR")" 1
    fi
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if git cat-file -e "${HEAD_SHA}:${line}" 2>/dev/null; then
            add_unique "$line"
        fi
    done <<< "$PR_FILES"

    # Is the head branch checked out in some local worktree? Paths may contain
    # spaces, so take everything after "worktree " rather than an awk field. A
    # fork's branch name says nothing about a same-named local branch.
    CHECKOUT="none"
    if [[ "$CROSS_REPO" != "true" ]]; then
        _wt=""
        while IFS= read -r line; do
            case "$line" in
                "worktree "*) _wt="${line#worktree }" ;;
                "branch refs/heads/${HEAD_REF}")
                    if [[ -n "$_wt" && -d "$_wt" ]]; then
                        REPO_ROOT="$_wt"; CHECKOUT="worktree"; break
                    fi ;;
            esac
        done < <(git worktree list --porcelain 2>/dev/null)
    fi

    CURRENT_BRANCH="$HEAD_REF"
    DEFAULT_BRANCH="$BASE_REF"
    MODE="Pull request #${PR_NUMBER} (${BASE_REF}...${HEAD_REF} @ ${HEAD_SHA:0:12}), checkout: ${CHECKOUT}"

elif [[ -n "$CURRENT_BRANCH" && -n "$DEFAULT_BRANCH" && "$CURRENT_BRANCH" != "$DEFAULT_BRANCH" ]]; then
    # Mode A — Feature Branch
    MERGE_BASE=$(git merge-base "origin/$DEFAULT_BRANCH" HEAD 2>/dev/null || echo "")

    if [[ -n "$MERGE_BASE" ]]; then
        # Committed changes since merge-base
        COMMITTED=()
        while IFS= read -r -d '' line; do
            [[ -n "$line" ]] && COMMITTED+=("$line")
        done < <(git diff --name-only -z --diff-filter=ACMR "${MERGE_BASE}...HEAD" 2>/dev/null)

        # Staged (index) changes
        STAGED=()
        while IFS= read -r -d '' line; do
            [[ -n "$line" ]] && STAGED+=("$line")
        done < <(git diff --cached --name-only -z --diff-filter=ACMR 2>/dev/null)

        # Unstaged (working tree) changes
        UNSTAGED=()
        while IFS= read -r -d '' line; do
            [[ -n "$line" ]] && UNSTAGED+=("$line")
        done < <(git diff --name-only -z --diff-filter=ACMR 2>/dev/null)

        # Untracked (newly created, not yet staged) files — honors .gitignore
        UNTRACKED=()
        while IFS= read -r -d '' line; do
            [[ -n "$line" ]] && UNTRACKED+=("$line")
        done < <(git ls-files --others --exclude-standard -z 2>/dev/null)

        add_unique "${COMMITTED[@]}" "${STAGED[@]}" "${UNSTAGED[@]}" "${UNTRACKED[@]}"

        DIFF_BASE="${MERGE_BASE}"
        MODE="Feature branch diff (${DEFAULT_BRANCH}...HEAD) + uncommitted changes (staged + unstaged + untracked)"
    else
        # merge-base failed — fall through to Mode B
        DEFAULT_BRANCH=""
    fi
fi

if [[ -z "$MODE" ]]; then
    # Mode B — Working Directory Changes
    STAGED=()
    while IFS= read -r -d '' line; do
        [[ -n "$line" ]] && STAGED+=("$line")
    done < <(git diff --cached --name-only -z --diff-filter=ACMR 2>/dev/null)

    UNSTAGED=()
    while IFS= read -r -d '' line; do
        [[ -n "$line" ]] && UNSTAGED+=("$line")
    done < <(git diff --name-only -z --diff-filter=ACMR 2>/dev/null)

    # Untracked (newly created, not yet staged) files — honors .gitignore
    UNTRACKED=()
    while IFS= read -r -d '' line; do
        [[ -n "$line" ]] && UNTRACKED+=("$line")
    done < <(git ls-files --others --exclude-standard -z 2>/dev/null)

    add_unique "${STAGED[@]}" "${UNSTAGED[@]}" "${UNTRACKED[@]}"

    MODE="Working directory changes (staged + unstaged + untracked)"
    [[ -z "$DEFAULT_BRANCH" ]] && DEFAULT_BRANCH="(unknown)"
fi

# --- Output ---
emit_json() { # emit_json <changed_files JSON array> [extra "key":"value" fragment]
    printf '{"branch":"%s","default_branch":"%s","repo_root":"%s","diff_base":"%s","mode":"%s","pr":"%s","pr_url":"%s","pr_title":"%s","head":"%s","checkout":"%s","changed_files":%s%s}\n' \
        "$(json_escape "$CURRENT_BRANCH")" "$(json_escape "$DEFAULT_BRANCH")" \
        "$(json_escape "$REPO_ROOT")" "$(json_escape "$DIFF_BASE")" "$(json_escape "$MODE")" \
        "$(json_escape "$PR_NUMBER")" "$(json_escape "$PR_URL")" "$(json_escape "$PR_TITLE")" \
        "$(json_escape "$HEAD_SHA")" "$(json_escape "$CHECKOUT")" \
        "$1" "${2:-}"
}

emit_text_header() {
    echo "BRANCH: $CURRENT_BRANCH"
    echo "DEFAULT_BRANCH: $DEFAULT_BRANCH"
    echo "REPO_ROOT: $REPO_ROOT"
    echo "DIFF_BASE: $DIFF_BASE"
    echo "MODE: $MODE"
    echo "PR: $PR_NUMBER"
    echo "PR_URL: $PR_URL"
    echo "PR_TITLE: $PR_TITLE"
    echo "HEAD: $HEAD_SHA"
    echo "CHECKOUT: $CHECKOUT"
}

# --- 1d. Validate Changed Files ---
if [[ ${#CHANGED_FILES[@]} -eq 0 ]]; then
    if $JSON_MODE; then
        emit_json "[]" ',"message":"No changes detected. Nothing to review."'
    else
        echo "No changes detected. Nothing to review."
    fi
    exit 2
fi

if $JSON_MODE; then
    emit_json "$(fmt_array "${CHANGED_FILES[@]}")"
else
    emit_text_header
    echo "CHANGED_FILES:"
    for f in "${CHANGED_FILES[@]}"; do
        echo "  $f"
    done
fi

exit 0
