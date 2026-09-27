#!/usr/bin/env bash
# diff-minimal preset: check-plan-scope.sh
# Hold the plan to the contract the spec signed.
#
# Reads the `MUST NOT touch:` list out of `spec.md`'s `## Scope discipline`
# section and reports every place `plan.md` / `tasks.md` (and quickstart.md /
# research.md when present) plans work in one of those paths.
#
# It reads the ARTIFACTS, not the diff — this runs at plan time, when there is
# no diff yet. Catching a forbidden path in the plan is the cheap moment; the
# expensive moment is reviewing the seven-file PR it would have produced.
#
# Two classes of line are deliberately ignored, because a plan that *restates*
# the exclusion is doing the right thing and must not be flagged for it:
#   - any line whose own text negates (MUST NOT, do not touch, out of scope, …)
#   - every line under a heading about scope, non-goals, or corrections
#
# Usage: check-plan-scope.sh <feature-dir>
#        check-plan-scope.sh <artifact.md> [<artifact.md> ...]
#
# Either form works: a feature directory (specs/NNN), or one or more artifact
# paths inside one (spec.md / plan.md / tasks.md, in any combination), whose
# feature directory is taken from their dirname. Files from the same feature
# directory are scanned once, not once per argument. Its sibling
# check-scope-sections.sh takes a spec.md path; accepting both here means a
# caller can pass the same paths to either script.
#
# Exit:  0 no artifact plans work in a forbidden path (or nothing is forbidden)
#        1 at least one violation (each printed as file:line on stderr)
#        2 bad usage (no argument, an argument that is neither a directory nor
#          a file, or no spec.md in a resolved feature dir)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPL="$HERE/../ts/check-plan-scope.ts"

usage() {
    echo "usage: $(basename "$0") <feature-dir>" >&2
    echo "       $(basename "$0") <artifact.md> [<artifact.md> ...]" >&2
}

if [[ $# -eq 0 ]]; then
    echo "error: feature directory or artifact path required" >&2
    usage
    exit 2
fi
if [[ ! -f "$IMPL" ]]; then
    echo "error: missing helper: $IMPL" >&2
    exit 2
fi
if ! command -v bun >/dev/null 2>&1; then
    echo "error: bun is required but not on PATH (https://bun.sh) — $(basename "$0") cannot run" >&2
    exit 2
fi

DIRS=()
CANON=()
for arg in "$@"; do
    if [[ -d "$arg" ]]; then
        dir="$arg"
    elif [[ -f "$arg" ]]; then
        dir="$(dirname "$arg")"
    else
        echo "error: not a directory or file: $arg" >&2
        usage
        exit 2
    fi
    if [[ ! -f "$dir/spec.md" ]]; then
        echo "error: no spec.md in $dir" >&2
        exit 2
    fi
    # Dedupe on the physical absolute path, not the spelling: `specs/001/`,
    # `specs/001` and `$PWD/specs/001` are one feature directory, and scanning
    # it twice reports every violation twice. The dir is still *reported* as the
    # caller spelled it.
    canon="$(cd -P "$dir" 2>/dev/null && pwd)"
    if [[ -z "$canon" ]]; then
        echo "error: cannot resolve: $arg" >&2
        exit 2
    fi
    seen=0
    for d in ${CANON+"${CANON[@]}"}; do
        [[ "$d" == "$canon" ]] && { seen=1; break; }
    done
    if [[ $seen -eq 0 ]]; then
        DIRS+=("$dir")
        CANON+=("$canon")
    fi
done

STATUS=0
for DIR in "${DIRS[@]}"; do
    bun "$IMPL" "$DIR"
    rc=$?
    [[ $rc -ne 0 ]] && STATUS=$rc
done

exit $STATUS
