#!/usr/bin/env bash
# Git-specific common functions for the git extension.
# Extracted from scripts/bash/common.sh — contains only git-specific
# branch validation and detection logic.

# Check if we have git available at the repo root
has_git() {
    local repo_root="${1:-$(pwd)}"
    { [ -d "$repo_root/.git" ] || [ -f "$repo_root/.git" ]; } && \
        command -v git >/dev/null 2>&1 && \
        git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# Strip a single optional path segment (e.g. gitflow "feat/004-name" -> "004-name").
# Only when the full name is exactly two slash-free segments; otherwise returns the raw name.
spec_kit_effective_branch_name() {
    local raw="$1"
    if [[ "$raw" =~ ^([^/]+)/([^/]+)$ ]]; then
        printf '%s\n' "${BASH_REMATCH[2]}"
    else
        printf '%s\n' "$raw"
    fi
}

# Validate that a branch name matches the expected feature branch pattern.
# Accepts sequential (###-* with >=3 digits) or timestamp (YYYYMMDD-HHMMSS-*) formats.
# Logic aligned with scripts/bash/common.sh check_feature_branch after effective-name normalization.
check_feature_branch() {
    local raw="$1"
    local has_git_repo="$2"

    # For non-git repos, we can't enforce branch naming but still provide output
    if [[ "$has_git_repo" != "true" ]]; then
        echo "[specify] Warning: Git repository not detected; skipped branch validation" >&2
        return 0
    fi

    local branch
    branch=$(spec_kit_effective_branch_name "$raw")

    # Accept sequential prefix (3+ digits) but exclude malformed timestamps
    # Malformed: 7-or-8 digit date + 6-digit time with no trailing slug (e.g. "2026031-143022" or "20260319-143022")
    local is_sequential=false
    if [[ "$branch" =~ ^[0-9]{3,}- ]] && [[ ! "$branch" =~ ^[0-9]{7}-[0-9]{6}- ]] && [[ ! "$branch" =~ ^[0-9]{7,8}-[0-9]{6}$ ]]; then
        is_sequential=true
    fi
    if [[ "$is_sequential" != "true" ]] && [[ ! "$branch" =~ ^[0-9]{8}-[0-9]{6}- ]]; then
        echo "ERROR: Not on a feature branch. Current branch: $raw" >&2
        echo "Feature branches should be named like: 001-feature-name, 1234-feature-name, or 20260319-143022-feature-name" >&2
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Feature identity resolution.
#
# `.specify/feature.json` is per-worktree runtime state, NOT project
# configuration: it is gitignored and regenerated per worktree. The only field
# our tooling reads out of it is `source_issue` — the only piece of feature
# identity that cannot be derived from git. (`create-new-feature.sh` also writes
# a `feature_directory` key there, solely for core Spec Kit's own
# get_feature_paths(); nothing here reads it.)
#
# Everything else (branch, number, worktree path, spec directory) is read
# from git at call time, so it can never go stale — a feature's paths are never
# resolved from this file. Historically all five were written to it *and* the
# file was tracked, which meant a new worktree inherited the previous feature's
# identity from the base branch (issue #33).
# ---------------------------------------------------------------------------

# Read `source_issue` from a worktree's feature.json. Prints nothing when the
# file is absent or carries no issue. Deliberately dependency-free (no jq) so
# every extension can inline the same two lines when it cannot source this file.
spec_kit_feature_source_issue() {
    local root="${1:-$(pwd)}"
    local json="$root/.specify/feature.json"
    [ -f "$json" ] || return 0
    sed -nE 's/.*"source_issue"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$json" | head -1
}

# Read `feature_directory` from a worktree's feature.json, still JSON-escaped
# exactly as stored, so it can be re-emitted verbatim without a decode/encode
# round trip. Private: nothing in this repo consumes the key's *value* — it
# exists only so core Spec Kit's get_feature_paths() resolves (see the header
# above) — and the only caller is the printf fallback below.
_spec_kit_feature_directory_raw() {
    local root="${1:-$(pwd)}"
    local json="$root/.specify/feature.json"
    [ -f "$json" ] || return 0
    sed -nE 's/.*"feature_directory"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' "$json" | head -1
}

# Escape a string for use inside a JSON string literal. Core Spec Kit's
# common.sh has its own `json_escape`, but git-common.sh is sourced by callers
# that never load core (bind-feature-issue.sh, worktree-add.sh), so the writers
# below cannot depend on it.
spec_kit_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# Derive the feature number from a branch name: the leading sequential prefix
# (`014-slug` -> `014`) or timestamp prefix (`20260319-143022-slug` ->
# `20260319-143022`). Prints nothing for a non-feature branch.
spec_kit_feature_num_from_branch() {
    local branch
    branch=$(spec_kit_effective_branch_name "$1")
    if [[ "$branch" =~ ^([0-9]{8}-[0-9]{6})- ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    elif [[ "$branch" =~ ^([0-9]{3,})- ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    fi
}

# Resolve the full feature identity for the worktree containing $1 (default cwd).
# Sets, in the caller's scope:
#   FEATURE_BRANCH        raw current branch
#   FEATURE_NUM           sequential/timestamp prefix, or ""
#   FEATURE_WORKTREE      absolute worktree root
#   FEATURE_DIRECTORY     specs/<slug> relative to FEATURE_WORKTREE, or "" when absent
#   FEATURE_SOURCE_ISSUE  linked GitHub issue number, or ""
# Returns 1 (with the variables cleared) when not inside a git worktree.
spec_kit_resolve_feature() {
    local start="${1:-$(pwd)}"
    FEATURE_BRANCH=""
    FEATURE_NUM=""
    FEATURE_WORKTREE=""
    FEATURE_DIRECTORY=""
    FEATURE_SOURCE_ISSUE=""

    command -v git >/dev/null 2>&1 || return 1
    FEATURE_WORKTREE=$(git -C "$start" rev-parse --show-toplevel 2>/dev/null) || {
        FEATURE_WORKTREE=""
        return 1
    }

    FEATURE_BRANCH=$(git -C "$FEATURE_WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    FEATURE_NUM=$(spec_kit_feature_num_from_branch "$FEATURE_BRANCH")

    # SPECIFY_FEATURE_DIRECTORY pins the directory outright; SPECIFY_FEATURE
    # pins the slug. Both are core Spec Kit overrides and win over the branch.
    local slug
    if [ -n "${SPECIFY_FEATURE_DIRECTORY:-}" ]; then
        FEATURE_DIRECTORY="$SPECIFY_FEATURE_DIRECTORY"
    else
        slug="${SPECIFY_FEATURE:-$(spec_kit_effective_branch_name "$FEATURE_BRANCH")}"
        if [ -n "$slug" ] && [ -d "$FEATURE_WORKTREE/specs/$slug" ]; then
            FEATURE_DIRECTORY="specs/$slug"
        fi
    fi

    FEATURE_SOURCE_ISSUE=$(spec_kit_feature_source_issue "$FEATURE_WORKTREE")
    return 0
}

# Write the per-worktree feature.json, gitignore it, and untrack it if a
# previous (pre-#33) commit put it under version control.
#
#   spec_kit_write_feature_json <worktree> [source_issue] [feature_directory]
#
# This is the ONLY writer of `.specify/feature.json` in this repo. It MERGES:
# passing just a source_issue preserves an existing feature_directory, and
# passing just a feature_directory preserves an existing source_issue. A writer
# that overwrote instead let bind-feature-issue.sh erase the feature_directory
# create-new-feature.sh had written, restoring core Spec Kit's hard
# "Feature directory not found" error on autopilot's own bind path.
#
# `feature_directory` is written FOR CORE SPEC KIT ONLY, never read back by us:
# core's `.specify/scripts/bash/common.sh` get_feature_paths() resolves the
# feature directory out of that key and hard-errors when it is missing. Our own
# tooling derives every path from git (spec_kit_resolve_feature) and must never
# read it. `branch_name`, `feature_num` and `worktree_path` stay banned.
#
# Both values are JSON-escaped, so a branch name carrying a quote
# (GIT_BRANCH_NAME='074-say"hi') cannot write a file that jq then refuses to
# parse — which core swallows into that same hard error.
#
# Whether an existing file is stale turns on one question:
# is it TRACKED?
#
#   tracked   -> it arrived from the base branch when this worktree was
#                materialised, so it describes the PREVIOUS feature. Remove it,
#                or /speckit-git-pr closes the wrong issue (issue #33).
#   untracked -> the file is gitignored, so it can only have been written for
#                THIS worktree by an earlier run of this script or by autopilot.
#                Preserve it: re-running /speckit-git-feature against an
#                existing branch (--allow-existing-branch, or an idempotent
#                worktree rematerialisation) creates no issue, and must not
#                destroy the linkage the first run established.
spec_kit_write_feature_json() {
    local worktree="$1"
    local source_issue="${2:-}"
    local feature_dir="${3:-}"
    local json="$worktree/.specify/feature.json"

    if [ -n "$source_issue" ] && ! [[ "$source_issue" =~ ^[0-9]+$ ]]; then
        >&2 echo "[specify] Refusing to write a non-numeric source_issue: $source_issue"
        return 1
    fi

    mkdir -p "$worktree/.specify"

    if [ -f "$json" ]; then
        # Check trackedness BEFORE spec_kit_ignore_feature_json runs its
        # `git rm --cached`, which would make every file look untracked.
        if git -C "$worktree" ls-files --error-unmatch ".specify/feature.json" >/dev/null 2>&1; then
            # Unconditional: a tracked file is inherited whether or not this
            # call carries a source_issue, and merging into it would carry the
            # previous feature's feature_directory forward -- which core
            # resolves without cross-checking the branch, so /speckit-plan
            # would write into the previous feature's spec dir (issue #33).
            rm -f "$json"
            >&2 echo "[specify] Removed inherited .specify/feature.json (it described the previous feature)."
        elif [ -z "$source_issue" ]; then
            >&2 echo "[specify] Kept this worktree's existing .specify/feature.json (issue #$(spec_kit_feature_source_issue "$worktree")); this run created no issue."
        fi
    fi

    if [ -n "$source_issue" ] || [ -n "$feature_dir" ]; then
        _spec_kit_merge_feature_json "$worktree" "$source_issue" "$feature_dir"
    fi

    spec_kit_ignore_feature_json "$worktree"
}

# Convenience wrapper for the callers that only own the directory half
# (worktree-add.sh): write `feature_directory` while preserving whatever
# `source_issue` the file already carries.
spec_kit_write_feature_directory() {
    spec_kit_write_feature_json "$1" "" "$2"
}

# Merge the given keys into $worktree/.specify/feature.json, leaving every key
# already present untouched. jq when it is available and the existing file
# parses; otherwise a printf rebuild from the two dependency-free readers above.
# Private — go through spec_kit_write_feature_json, which owns the issue-#33
# inheritance rule and the gitignore/untrack step.
_spec_kit_merge_feature_json() {
    local worktree="$1"
    local source_issue="${2:-}"
    local feature_dir="${3:-}"
    local json="$worktree/.specify/feature.json"
    local merged dir_json

    if command -v jq >/dev/null 2>&1 && [ -s "$json" ] \
        && merged=$(jq -c --arg i "$source_issue" --arg d "$feature_dir" \
            '. + (if $i == "" then {} else {source_issue: ($i | tonumber)} end)
               + (if $d == "" then {} else {feature_directory: $d} end)' \
            "$json" 2>/dev/null); then
        printf '%s\n' "$merged" > "$json"
        return 0
    fi

    # Fallback: no jq, no existing file, or a file jq could not parse. Read the
    # halves this call did not supply BEFORE the redirect truncates the file.
    [ -n "$source_issue" ] || source_issue=$(spec_kit_feature_source_issue "$worktree")
    if [ -n "$feature_dir" ]; then
        dir_json=$(spec_kit_json_escape "$feature_dir")
    else
        # Already stored escaped; re-emit verbatim rather than decode/re-encode.
        dir_json=$(_spec_kit_feature_directory_raw "$worktree")
    fi

    {
        local sep=""
        printf '{'
        if [ -n "$source_issue" ]; then
            printf '"source_issue":%s' "$source_issue"
            sep=","
        fi
        if [ -n "$dir_json" ]; then
            printf '%s"feature_directory":"%s"' "$sep" "$dir_json"
        fi
        printf '}\n'
    } > "$json"
}

# Ensure `.specify/feature.json` is gitignored in this worktree, and drop it
# from the index when an older layout tracked it. Idempotent; best-effort.
spec_kit_ignore_feature_json() {
    local worktree="$1"
    local gitignore="$worktree/.gitignore"
    local pattern=".specify/feature.json"

    if ! grep -qxF "$pattern" "$gitignore" 2>/dev/null; then
        if [ -s "$gitignore" ] && [ -n "$(tail -c 1 "$gitignore")" ]; then
            printf '\n' >> "$gitignore"
        fi
        printf '# Per-worktree feature identity (regenerated by /speckit-git-feature).\n%s\n' \
            "$pattern" >> "$gitignore"
    fi

    if git -C "$worktree" ls-files --error-unmatch "$pattern" >/dev/null 2>&1; then
        git -C "$worktree" rm --cached -q "$pattern" >/dev/null 2>&1 || true
        >&2 echo "[specify] Untracked $pattern (it is per-worktree state, not project config; see issue #33)."
        >&2 echo "[specify]   The removal is staged in this worktree and lands when this feature merges."
    fi
}

# ---------------------------------------------------------------------------
# commit_exclude: paths the auto-commit hook must never stage.
#
# Some repos track a large generated artifact whose canonical copy is rebuilt on
# the default branch by CI — lead-drop's `graphify-out/` is a 440k-line dated
# snapshot rebuilt by a dedicated `chore(graphify)` job. A feature branch that
# regenerates it (the graphify lifecycle hook does, every phase) and lets
# `git add .` sweep it in produces an unreviewable PR diff AND massive rebase
# conflicts — "440920 insertions(+), 88677 deletions(-)" on one branch. Every
# autopilot run then had to hand-reconcile it before opening the PR (issue #22).
#
# Listing the path here keeps the hook running (the graph stays accurate for the
# rest of the session) while its output stays out of every commit, so the branch
# never carries the snapshot in the first place.
#
# Usage: spec_kit_commit_excludes [repo_root]   → one path per line, or nothing.
spec_kit_commit_excludes() {
    local root="${1:-$(git rev-parse --show-toplevel 2>/dev/null)}"
    local cfg="$root/.specify/extensions/git/git-config.yml"
    [ -f "$cfg" ] || return 0

    awk '
        /^[[:space:]]*commit_exclude:[[:space:]]*$/ { inlist = 1; next }
        inlist && /^[[:space:]]*-[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]*-[[:space:]]*/, "", line)      # strip the bullet
            sub(/[[:space:]]*#.*$/, "", line)                 # strip trailing comment
            gsub(/^["'"'"']|["'"'"']$/, "", line)             # strip quotes
            gsub(/[[:space:]]+$/, "", line)
            if (line != "") print line
            next
        }
        inlist && /^[[:space:]]*[^[:space:]-]/ { inlist = 0 }  # next key ends the list
    ' "$cfg"
}
