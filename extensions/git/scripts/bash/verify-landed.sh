#!/usr/bin/env bash
# Answer one question, deterministically: has <branch>'s work actually landed on
# <base>, so deleting the branch loses nothing?
#
# This repo squash-merges, and every squash breaks ancestry. After a squash
# `git branch -d` refuses, `git branch --merged` omits the branch, and
# `git merge-base --is-ancestor` reports "not merged" — all three lie in the same
# direction, and all three are the checks an agent reaches for first. So fifteen-
# plus cleanup turns re-derived the replacement check by hand, each with its own
# hand-typed path list (`functions web infra` one run, `functions web specs
# .github` the next, `functions` alone the run after). A run that omits a path
# deletes a branch holding work in it — that nearly cost a commit pushed seconds
# after a squash merge (issue #49).
#
# The path list is the defect, so this script does not take one: it compares the
# whole tree, minus only the exclusions the repo has already declared in
# `commit_exclude` (generated artifacts CI rebuilds on the default branch).
#
# Usage:
#   verify-landed.sh <branch> [--base <ref>] [--repo <dir>] [--exclude <path>]...
#                             [--no-fetch] [--json]
#
# Verdict (first line of stdout):
#   LANDED:     the work is on <base> — ancestry proves it, or the trees are identical
#   NOT-LANDED: <branch> carries content <base> does not have; the differing paths follow
#   UNKNOWN:    the question could not be answered (no such branch, unresolvable base, …)
#
# Exit: 0 = LANDED, 1 = NOT-LANDED, 2 = UNKNOWN.
#
# Only exit 0 authorises a destructive step. UNKNOWN is a refusal, never a pass:
# when this cannot prove the work landed, the branch stays.
set -uo pipefail

BRANCH=""
BASE=""
REPO=""
DO_FETCH=1
JSON=0
EXCLUDES=()

die_usage() {
    echo "[verify-landed] $1" >&2
    echo "[verify-landed] Usage: verify-landed.sh <branch> [--base <ref>] [--repo <dir>] [--exclude <path>]... [--no-fetch] [--json]" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --base)
            [ $# -ge 2 ] || die_usage "--base requires a ref"
            BASE="$2"; shift 2 ;;
        --repo)
            [ $# -ge 2 ] || die_usage "--repo requires a directory"
            REPO="$2"; shift 2 ;;
        --exclude)
            [ $# -ge 2 ] || die_usage "--exclude requires a path"
            EXCLUDES+=("$2"); shift 2 ;;
        --no-fetch) DO_FETCH=0; shift ;;
        --json) JSON=1; shift ;;
        --help|-h)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) die_usage "unknown option: $1" ;;
        *)
            [ -z "$BRANCH" ] || die_usage "only one branch may be given"
            BRANCH="$1"; shift ;;
    esac
done

[ -n "$BRANCH" ] || die_usage "no branch given"

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./git-common.sh
[ -f "$SCRIPT_DIR/git-common.sh" ] && . "$SCRIPT_DIR/git-common.sh"

if ! command -v git >/dev/null 2>&1; then
    echo "UNKNOWN: git not found — cannot verify anything; do not delete"
    exit 2
fi

if [ -n "$REPO" ]; then
    REPO="$(CDPATH="" cd "$REPO" 2>/dev/null && pwd)" || {
        echo "UNKNOWN: --repo path does not exist; do not delete"
        exit 2
    }
else
    REPO="$PWD"
fi

# The main worktree, not whichever worktree we happen to stand in: branch refs
# and the base live in the common dir, shared by every worktree of the repo.
if ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "UNKNOWN: $REPO is not a git repository; do not delete"
    exit 2
fi
ROOT="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" || ROOT="$REPO"

g() { git -C "$ROOT" "$@"; }

if ! g rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null 2>&1 \
   && ! g rev-parse --verify --quiet "$BRANCH^{commit}" >/dev/null 2>&1; then
    echo "UNKNOWN: no such branch or commit '$BRANCH' — nothing to verify; do not delete"
    exit 2
fi

BASE="${BASE:-main}"

# Prefer the remote-tracking copy: the squash commit is created by GitHub, so a
# stale local `main` is exactly the state in which a landed branch reads as
# not-landed. Fetch first unless told not to (the tests run offline).
resolve_base() {
    local candidate
    if [ "$DO_FETCH" -eq 1 ] && g remote get-url origin >/dev/null 2>&1; then
        g fetch --quiet origin "${BASE#origin/}" >/dev/null 2>&1 || true
    fi
    for candidate in "$BASE" "origin/${BASE#origin/}" "refs/remotes/origin/${BASE#origin/}"; do
        if g rev-parse --verify --quiet "$candidate^{commit}" >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

if ! BASE_REF="$(resolve_base)"; then
    echo "UNKNOWN: base '$BASE' does not resolve to a commit here — cannot prove anything; do not delete"
    exit 2
fi

# The exclusion set is stated once, in the same place commit_exclude already
# lives, rather than re-guessed per run. --exclude adds to it; it never replaces
# it, so a caller cannot narrow the check by forgetting a path.
if type spec_kit_commit_excludes >/dev/null 2>&1; then
    while IFS= read -r _ex; do
        [ -n "$_ex" ] && EXCLUDES+=("$_ex")
    done < <(spec_kit_commit_excludes "$ROOT" 2>/dev/null || true)
fi

PATHSPEC=(-- .)
for _ex in ${EXCLUDES+"${EXCLUDES[@]}"}; do
    PATHSPEC+=(":(exclude)$_ex")
done

BRANCH_SHA="$(g rev-parse "$BRANCH^{commit}" 2>/dev/null)"
BASE_SHA="$(g rev-parse "$BASE_REF^{commit}" 2>/dev/null)"

PATHS_CHECKED=0

emit() { # emit <verdict> <via> <exit>
    if [ "$JSON" -eq 1 ]; then
        printf '{"landed": %s, "verdict": "%s", "branch": "%s", "base": "%s", "via": "%s", "paths_checked": %s}\n' \
            "$([ "$3" -eq 0 ] && echo true || echo false)" "$1" "$BRANCH" "$BASE_REF" "$2" "${PATHS_CHECKED:-0}"
    fi
}

# 1. Ancestry — a true merge or a fast-forward. Cheap, and definitive when true.
if g merge-base --is-ancestor "$BRANCH_SHA" "$BASE_SHA" 2>/dev/null; then
    [ "$JSON" -eq 1 ] || echo "LANDED: $BRANCH (${BRANCH_SHA:0:8}) is an ancestor of $BASE_REF (${BASE_SHA:0:8}) — merged or fast-forwarded"
    emit LANDED ancestry 0
    exit 0
fi

# 2. Content equivalence — the squash and rebase case, where ancestry is gone but
#    the work is present byte-for-byte.
#
#    The comparison is the branch's *own* paths, derived from git rather than
#    typed by hand: every path the branch touched since it forked. Comparing the
#    two whole trees instead would flag every unrelated commit the base has taken
#    on since — a gate that says NOT-LANDED for every branch on a moving main is
#    a gate nobody reads. For each of those paths the branch's blob must match
#    the base's; that holds after a squash (the squash is a faithful copy) and
#    fails the moment the branch carries something the base never took, which is
#    the commit-pushed-seconds-after-the-merge case.
#
#    A path the base has since moved *past* also fails, and that is deliberate:
#    it is unprovable from here, and refusing is the safe direction.
MERGE_BASE="$(g merge-base "$BASE_SHA" "$BRANCH_SHA" 2>/dev/null || true)"

if [ -n "$MERGE_BASE" ]; then
    CHANGED="$(g diff --name-only "$MERGE_BASE" "$BRANCH_SHA" "${PATHSPEC[@]}" 2>/dev/null)"
    if [ -z "$CHANGED" ]; then
        [ "$JSON" -eq 1 ] || echo "LANDED: $BRANCH (${BRANCH_SHA:0:8}) introduces no changes over its fork point — nothing to lose"
        emit LANDED empty 0
        exit 0
    fi
    PATHS_CHECKED="$(printf '%s\n' "$CHANGED" | wc -l | tr -d ' ')"
    COMPARE=(--)
    while IFS= read -r _p; do
        [ -n "$_p" ] && COMPARE+=("$_p")
    done <<<"$CHANGED"
else
    # Unrelated histories: there is no fork point to derive paths from, so fall
    # back to the whole tree, minus the declared exclusions.
    COMPARE=("${PATHSPEC[@]}")
    PATHS_CHECKED="$(g ls-tree -r --name-only "$BRANCH_SHA" "${PATHSPEC[@]}" 2>/dev/null | wc -l | tr -d ' ')"
fi

if ! DIFF="$(g diff --name-only "$BASE_SHA" "$BRANCH_SHA" "${COMPARE[@]}" 2>/dev/null)"; then
    echo "UNKNOWN: could not diff $BRANCH against $BASE_REF; do not delete"
    exit 2
fi

if [ -z "$DIFF" ]; then
    [ "$JSON" -eq 1 ] || {
        echo "LANDED: $BRANCH (${BRANCH_SHA:0:8}) has no content $BASE_REF (${BASE_SHA:0:8}) lacks — squash-merged or rebased"
        echo "        $PATHS_CHECKED path(s) the branch touched, all identical on the base${EXCLUDES+; excluded: ${EXCLUDES[*]}}"
    }
    emit LANDED content 0
    exit 0
fi

if [ "$JSON" -eq 1 ]; then
    emit NOT-LANDED diff 1
else
    _n="$(printf '%s\n' "$DIFF" | wc -l | tr -d ' ')"
    echo "NOT-LANDED: $BRANCH differs from $BASE_REF in $_n of $PATHS_CHECKED path(s) it touched — the work is NOT on the base; refuse to delete"
    echo "--- paths whose branch content is not on $BASE_REF ---"
    printf '%s\n' "$DIFF" | head -50
fi
exit 1
