#!/usr/bin/env bash
# Git extension: scrub-commit-exclude.sh
#
# The one handler for `commit_exclude` churn. Restores every path listed under
# `commit_exclude:` in git-config.yml back to HEAD — unstaging it if it is
# staged, discarding tracked modifications, and dropping untracked additions —
# and reports on stderr exactly what it discarded.
#
# Why a script and not three inline blocks:
#
#   * `commit_exclude` used to be enforced only by auto-commit.sh's `:(exclude)`
#     pathspec, which never runs in a project whose `auto_commit.default` is
#     `false` — the default. There the commits are made by the flow's own
#     `git add`, so the derived data the list exists to keep off a branch landed
#     on the branch anyway, and each recovery was re-derived by hand (issue #62).
#   * create-pr.sh, clean.sh and auto-commit.sh each improvised their own
#     reconcile — or forgot to — so a background graph rebuild that dirtied the
#     tree at an arbitrary moment blocked the squash, the pull, and the cleanup
#     step in three different ways (issue #55).
#
# A rebuild running *right now* is waited for, not raced: if a lock file is
# present under an excluded path the script blocks for a bounded timeout before
# scrubbing, because scrubbing under a live writer just re-dirties the tree.
#
# Usage: scrub-commit-exclude.sh [--repo <dir>] [--require-clean] [--quiet]
#
#   --repo <dir>     Worktree to operate on (default: the enclosing worktree).
#   --require-clean  Exit 2 when anything OUTSIDE the excluded paths is dirty.
#                    That is a real dirty tree and the caller should still
#                    refuse; without the flag such dirt is left alone.
#   --quiet          Suppress the per-path report.
#
# Exit codes: 0 scrubbed (or nothing to do)   2 --require-clean and other dirt
#
# It is a no-op with exit 0 when the list is empty, when nothing matched, or
# when git is unavailable. It never passes `-x` to `git clean`, so genuinely
# ignored files that are not themselves excluded paths survive.

set -uo pipefail

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO=""
REQUIRE_CLEAN=0
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)
            [ $# -ge 2 ] || { echo "[specify] --repo requires a path" >&2; exit 1; }
            REPO="$2"; shift 2 ;;
        --require-clean) REQUIRE_CLEAN=1; shift ;;
        --quiet|-q)      QUIET=1; shift ;;
        --help|-h)       sed -n '3,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[specify] scrub-commit-exclude: unknown argument: $1" >&2; exit 1 ;;
    esac
done

command -v git >/dev/null 2>&1 || exit 0

if [ -z "$REPO" ]; then
    REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
[ -n "$REPO" ] && [ -d "$REPO" ] || exit 0
REPO="$(CDPATH="" cd "$REPO" && pwd)"
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# shellcheck source=./git-common.sh
[ -f "$SCRIPT_DIR/git-common.sh" ] && source "$SCRIPT_DIR/git-common.sh"
type spec_kit_commit_excludes >/dev/null 2>&1 || exit 0

EXCLUDES=()
while IFS= read -r _ex; do
    [ -n "$_ex" ] || continue
    EXCLUDES+=("${_ex%/}")
done < <(spec_kit_commit_excludes "$REPO")

[ ${#EXCLUDES[@]} -gt 0 ] || exit 0

_say() { [ "$QUIET" -eq 1 ] || echo "[specify] $*" >&2; }

# --- Wait out a rebuild in flight -------------------------------------------
# graphify's post-commit/post-checkout hooks rebuild in the background, so the
# tree can go dirty on its own between the check and the scrub. Whichever
# session noticed the lock used to handle this by hand, and the others raced it.
_lock_timeout="${SPECKIT_SCRUB_LOCK_TIMEOUT:-30}"
_wait_for_locks() {
    local waited=0 found
    while [ "$waited" -lt "$_lock_timeout" ]; do
        found=""
        for _ex in "${EXCLUDES[@]}"; do
            for _lock in "$REPO/$_ex/.rebuild.lock" "$REPO/$_ex/.lock" "$REPO/$_ex.lock"; do
                [ -e "$_lock" ] && found="$_lock"
            done
        done
        [ -n "$found" ] || return 0
        [ "$waited" -eq 0 ] && _say "Waiting for a rebuild in flight: $found (up to ${_lock_timeout}s)"
        sleep 1
        waited=$((waited + 1))
    done
    _say "Warning: rebuild lock still present after ${_lock_timeout}s; scrubbing anyway"
    return 0
}
[ "$_lock_timeout" -gt 0 ] 2>/dev/null && _wait_for_locks

# --- Scrub -------------------------------------------------------------------
scrubbed=""
for _ex in "${EXCLUDES[@]}"; do
    _staged=$(git -C "$REPO" diff --cached --name-only -- "$_ex" 2>/dev/null | head -1)
    _tracked=$(git -C "$REPO" diff --name-only -- "$_ex" 2>/dev/null | head -1)
    _untracked=$(git -C "$REPO" ls-files --others --exclude-standard -- "$_ex" 2>/dev/null | head -1)

    [ -n "$_staged$_tracked$_untracked" ] || continue

    what=""
    if [ -n "$_staged" ]; then
        git -C "$REPO" restore --staged -- "$_ex" 2>/dev/null \
            || git -C "$REPO" rm -rq --cached --ignore-unmatch -- "$_ex" 2>/dev/null || true
        what="unstaged"
    fi
    if [ -n "$_staged$_tracked" ]; then
        git -C "$REPO" checkout -- "$_ex" 2>/dev/null || true
        what="${what:+$what, }restored to HEAD"
    fi
    if [ -n "$_untracked" ]; then
        git -C "$REPO" clean -qfd -- "$_ex" 2>/dev/null || true
        what="${what:+$what, }removed untracked output"
    fi

    _say "Scrubbed excluded artifact: $_ex ($what)"
    scrubbed="${scrubbed:+$scrubbed, }$_ex"
done

[ -n "$scrubbed" ] || _say "commit_exclude: nothing to scrub"

# --- Optional strictness -----------------------------------------------------
# Anything still dirty after the scrub is real work; the caller decides.
if [ "$REQUIRE_CLEAN" -eq 1 ]; then
    _pathspec=(.)
    for _ex in "${EXCLUDES[@]}"; do _pathspec+=(":(exclude)$_ex"); done
    _rest="$(git -C "$REPO" status --porcelain -- "${_pathspec[@]}" 2>/dev/null)"
    if [ -n "$_rest" ]; then
        echo "[specify] Working tree still dirty outside commit_exclude:" >&2
        printf '%s\n' "$_rest" | sed 's/^/[specify]   /' >&2
        exit 2
    fi
fi

exit 0
