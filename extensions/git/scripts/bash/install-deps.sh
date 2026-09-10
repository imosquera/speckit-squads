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
# `worktree <path>` — take everything after the prefix, never field 2: a base
# checkout under "~/My Code/repo" split on the space and resolved to "/Users/me/My",
# which fails the -d test below and silently skips the install for that repo.
# The -z form is newline-proof too; older git rejects it, hence the fallback.
BASE="$(git -C "$WORKTREE_PATH" worktree list --porcelain -z 2>/dev/null \
    | tr '\0' '\n' | sed -n '1s/^worktree //p')"
if [[ -z "$BASE" ]]; then
    BASE="$(git -C "$WORKTREE_PATH" worktree list --porcelain 2>/dev/null \
        | sed -n '1s/^worktree //p')"
fi
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
# Read line by line, never `for rel in $MANIFEST_DIRS` — a directory with a
# space in it is one manifest, not two.

if [[ -z "$MANIFEST_DIRS" ]]; then
    exit 0
fi

# ---- plan: one command per directory the base checkout has already installed
declare -a PLAN_DIR=() PLAN_CMD=()
SKIPPED_NO_TOOL=""

# The directory whose install covers <rel>: the nearest ancestor (self first)
# carrying a node lockfile. A pnpm/npm/yarn workspace installs every project
# from its root, so a child package must NOT be installed separately — running
# `npm install` in a child of a pnpm workspace concurrently with the root's
# `pnpm install` writes a package-lock.json into a tree pnpm is mid-install on.
node_install_root() { # node_install_root <rel-dir>
    local rel="$1" dir
    while :; do
        dir="$WORKTREE_PATH/$rel"
        if [[ -f "$dir/bun.lockb" || -f "$dir/bun.lock" || -f "$dir/pnpm-lock.yaml" \
           || -f "$dir/yarn.lock" || -f "$dir/package-lock.json" ]]; then
            echo "$rel"; return
        fi
        [[ "$rel" == "." ]] && break
        rel="$(dirname "$rel")"
    done
    echo "$1"   # no lockfile anywhere above it — install it where it sits
}

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

PLANNED=""
while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    abs="$WORKTREE_PATH/$rel"
    base_abs="$BASE/$rel"
    [[ -d "$abs" ]] || continue

    cmd=""
    if [[ -f "$abs/package.json" ]]; then
        # Redirect a workspace child to the root that installs it, and gate on
        # either one being installed in the base: pnpm keeps node_modules in
        # both, npm workspaces hoist to the root only.
        root_rel="$(node_install_root "$rel")"
        if [[ -d "$base_abs/node_modules" || -d "$BASE/$root_rel/node_modules" ]]; then
            rel="$root_rel"
            abs="$WORKTREE_PATH/$rel"
            cmd="$(plan_node "$rel" "$abs")"
        fi
    elif [[ -f "$abs/uv.lock" && -d "$base_abs/.venv" ]]; then
        cmd="uv sync"
    elif [[ -f "$abs/poetry.lock" && -d "$base_abs/.venv" ]]; then
        cmd="poetry install"
    fi
    [[ -n "$cmd" ]] || continue
    case "$PLANNED" in *"|$rel|"*) continue ;; esac   # workspace root, already planned

    tool="${cmd%% *}"
    if ! command -v "$tool" >/dev/null 2>&1; then
        SKIPPED_NO_TOOL="$SKIPPED_NO_TOOL $rel($tool)"
        continue
    fi
    PLAN_DIR+=("$rel")
    PLAN_CMD+=("$cmd")
    PLANNED="$PLANNED|$rel|"
done <<< "$MANIFEST_DIRS"

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
