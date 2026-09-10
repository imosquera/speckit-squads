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
COMMON="$HERE/scope-common.py"

usage() {
    echo "usage: $(basename "$0") <feature-dir>" >&2
    echo "       $(basename "$0") <artifact.md> [<artifact.md> ...]" >&2
}

if [[ $# -eq 0 ]]; then
    echo "error: feature directory or artifact path required" >&2
    usage
    exit 2
fi
if [[ ! -f "$COMMON" ]]; then
    echo "error: missing helper: $COMMON" >&2
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

python3 - "$DIR" "$COMMON" <<'PY'
import pathlib
import re
import sys

feature = pathlib.Path(sys.argv[1])
exec(compile(pathlib.Path(sys.argv[2]).read_text(), sys.argv[2], "exec"))

spec_lines = (feature / "spec.md").read_text().splitlines()
paths = must_not_paths(spec_lines)

if not paths:
    print("diff-minimal: spec forbids no paths — nothing to check.")
    sys.exit(0)

# A line that says "don't touch X" names X on purpose.
NEGATION = re.compile(
    r'must\s+not|do(es)?\s+not\s+(touch|modify|edit|change)|never\s+(touch|modify|edit)'
    r'|out\s+of\s+scope|forbidden|excluded|exclude|no\s+changes?\s+to|not\s+in\s+scope'
    r'|leave\s+(it\s+)?alone|untouched',
    re.I,
)
# Whole sections that exist to restate the exclusions.
EXEMPT_HEADING = re.compile(r'scope|non-goals?|out of scope|corrections|constraints', re.I)

patterns = [(p, path_pattern(p)) for p in paths]
violations = []

for name in ("plan.md", "tasks.md", "quickstart.md", "research.md"):
    path = feature / name
    if not path.is_file():
        continue

    exempt_until = None  # heading level we are exempt beneath, or None
    for n, line in enumerate(path.read_text().splitlines(), 1):
        h = heading(line)
        if h:
            level, title = h
            if exempt_until is not None and level <= exempt_until:
                exempt_until = None
            if EXEMPT_HEADING.search(title):
                exempt_until = level
            continue
        if exempt_until is not None:
            continue
        if NEGATION.search(line):
            continue
        for listed, pat in patterns:
            if pat.search(line):
                violations.append((name, n, listed, line.strip()))
                break

if violations:
    print("error: plan artifacts touch paths the spec put out of scope", file=sys.stderr)
    for name, n, listed, text in violations:
        print(f"  {feature}/{name}:{n}: forbidden by `{listed}`", file=sys.stderr)
        print(f"      {text}", file=sys.stderr)
    print(
        "\nEither remove the work from the plan, or — if the path is genuinely required —\n"
        "amend `## Scope discipline` in spec.md and say so on the tracking issue.\n"
        "Never widen the plan quietly.",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"diff-minimal: plan artifacts respect all {len(paths)} out-of-scope path(s).")
PY
    rc=$?
    [[ $rc -ne 0 ]] && STATUS=$rc
done

exit $STATUS
