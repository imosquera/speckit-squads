#!/usr/bin/env bash
# Git extension: install-deps.sh
#
# Install a freshly created worktree's dependencies at creation time, so the
# first `tsx`/`vitest`/`pytest` in the implement phase resolves instead of
# failing with `command not found` (issue #51).
#
# A linked worktree gets the tracked files and nothing else: no node_modules,
# no .venv. Six autopilot runs in three days each rediscovered that mid-
# implement, after the model had written code and was holding the change in
# its head, and each rediscovered it one confusing resolution error at a time.
# The install is not the cost; the interrupt and the diagnosis are.
#
# Discovery, not a hard-coded list. The base checkout is the oracle: a
# directory is installed here only if the SAME directory in the main worktree
# already carries the ecosystem's installed marker (node_modules/, .venv/).
# That is what makes one script correct for a three-workspace monorepo and a
# no-op for a docs repo, without a config schema for something with one
# sensible default. Manifests are found with `git ls-files`, so vendored trees
# and fixtures under node_modules are never walked.
#
# The package manager is read off the lockfile, never assumed to be npm.
#
# Best effort throughout. A worktree without dependencies is a worse worktree;
# a worktree that failed to be created is no worktree at all, so nothing here
# is allowed to fail the caller: every path exits 0.
#
# Usage: install-deps.sh <worktree-path>
# Env:   SPECKIT_SKIP_INSTALL=1  skip entirely
set -uo pipefail

WORKTREE_PATH="${1:-}"
say() { echo "[specify] install-deps: $*" >&2; }

if [[ -z "$WORKTREE_PATH" || ! -d "$WORKTREE_PATH" ]]; then
    say "no such worktree '$WORKTREE_PATH'; skipping dependency install"
    exit 0
fi

if [[ "${SPECKIT_SKIP_INSTALL:-}" == "1" ]]; then
    say "SPECKIT_SKIP_INSTALL=1; skipping dependency install"
    exit 0
fi

WORKTREE_PATH="$(cd "$WORKTREE_PATH" && pwd)"

# The base checkout: the repository's main worktree, which is the one that has
# been worked in and therefore the one that knows which directories matter.
BASE="$(git -C "$WORKTREE_PATH" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{print $2; exit}')"
if [[ -z "$BASE" || ! -d "$BASE" ]]; then
    say "could not resolve the base checkout; skipping dependency install"
    exit 0
fi
# Compare physical paths: `git worktree list` reports a symlink-resolved path
# (/private/var/... on macOS) while the caller's argument is typically the
# logical one, and a mismatch here would install into the base checkout.
BASE_PHYS="$(cd "$BASE" 2>/dev/null && pwd -P)"
WORKTREE_PHYS="$(cd "$WORKTREE_PATH" 2>/dev/null && pwd -P)"
if [[ "$BASE_PHYS" == "$WORKTREE_PHYS" ]]; then
    # Not a linked worktree — there is no base to mirror, and installing over
    # the checkout the user is sitting in is not this script's business.
    exit 0
fi

# ---- discovery: tracked manifests, deduplicated to their directories
# A repo-root manifest yields "." rather than an empty word, so the root is
# not silently dropped by word splitting — which is exactly the single-package
# repo this exists for.
MANIFEST_DIRS="$(git -C "$WORKTREE_PATH" ls-files 2>/dev/null \
    | grep -E '(^|/)(package\.json|uv\.lock|poetry\.lock)$' \
    | sed -E 's![^/]+$!!; s!/$!!; s!^$!.!' \
    | sort -u)"

if [[ -z "$MANIFEST_DIRS" ]]; then
    exit 0
fi

# ---- plan: one command per directory the base checkout has already installed
declare -a PLAN_DIR=() PLAN_CMD=()
SKIPPED_NO_TOOL=""

plan_node() { # plan_node <rel-dir> <abs-dir>
    local abs="$2" cmd=""
    if   [[ -f "$abs/bun.lockb" || -f "$abs/bun.lock" ]]; then cmd="bun install"
    elif [[ -f "$abs/pnpm-lock.yaml" ]];               then cmd="pnpm install --frozen-lockfile"
    elif [[ -f "$abs/yarn.lock" ]];                    then cmd="yarn install --frozen-lockfile"
    elif [[ -f "$abs/package-lock.json" ]];            then cmd="npm ci"
    else                                                    cmd="npm install"
    fi
    echo "$cmd"
}

for rel in $MANIFEST_DIRS; do
    abs="$WORKTREE_PATH/$rel"
    base_abs="$BASE/$rel"
    [[ -d "$abs" ]] || continue

    cmd=""
    if [[ -f "$abs/package.json" && -d "$base_abs/node_modules" ]]; then
        cmd="$(plan_node "$rel" "$abs")"
    elif [[ -f "$abs/uv.lock" && -d "$base_abs/.venv" ]]; then
        cmd="uv sync"
    elif [[ -f "$abs/poetry.lock" && -d "$base_abs/.venv" ]]; then
        cmd="poetry install"
    fi
    [[ -n "$cmd" ]] || continue

    tool="${cmd%% *}"
    if ! command -v "$tool" >/dev/null 2>&1; then
        SKIPPED_NO_TOOL="$SKIPPED_NO_TOOL $rel($tool)"
        continue
    fi
    PLAN_DIR+=("$rel")
    PLAN_CMD+=("$cmd")
done

if [[ -n "$SKIPPED_NO_TOOL" ]]; then
    say "not on PATH, skipped:$SKIPPED_NO_TOOL"
fi

if [[ ${#PLAN_DIR[@]} -eq 0 ]]; then
    exit 0
fi

# ---- run them concurrently; one line of summary, details only on failure
LOGDIR="$(mktemp -d 2>/dev/null)" || exit 0
say "installing dependencies in ${#PLAN_DIR[@]} director$([[ ${#PLAN_DIR[@]} -eq 1 ]] && echo y || echo ies) ..."

pids=()
for i in "${!PLAN_DIR[@]}"; do
    rel="${PLAN_DIR[$i]}"
    ( cd "$WORKTREE_PATH/$rel" && eval "${PLAN_CMD[$i]}" ) \
        >"$LOGDIR/$i.log" 2>&1 &
    pids+=($!)
done

# Empty-array expansion is an "unbound variable" under `set -u` in bash 3.2,
# still the /bin/bash on macOS, so every array read is length-guarded.
OK_LIST=""; BAD_IDX=""
for i in "${!PLAN_DIR[@]}"; do
    if wait "${pids[$i]}"; then OK_LIST="$OK_LIST ${PLAN_DIR[$i]}"; else BAD_IDX="$BAD_IDX $i"; fi
done

if [[ -n "$OK_LIST" ]]; then
    say "installed:$OK_LIST"
fi
for i in $BAD_IDX; do
    say "FAILED in ${PLAN_DIR[$i]}: ${PLAN_CMD[$i]} — run it by hand before implementing"
    tail -n 15 "$LOGDIR/$i.log" 2>/dev/null | sed 's/^/    /' >&2
done

rm -rf "$LOGDIR" 2>/dev/null
exit 0
