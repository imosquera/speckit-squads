#!/usr/bin/env bash
# diff-minimal preset: check-scope-sections.sh
# Assert that a spec.md carries the two sections the minimum-diff mandate adds,
# and that they actually say something.
#
#   ## Corrections to the issue as filed   — non-empty, or an explicit "None."
#   ## Scope discipline                    — a `MUST NOT touch:` list with at
#                                            least one path, or an explicit "None."
#
# Read-only: it never edits the spec. The point is that a mandate nobody checks
# is a suggestion, and a spec with an empty Scope discipline heading is worse
# than one without it — the later phases would be held to nothing while looking
# like they were held to something.
#
# Usage: check-scope-sections.sh <spec.md>
# Exit:  0 both sections present and populated
#        1 a section is missing or empty (message on stderr says which)
#        2 bad usage

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPL="$HERE/../ts/check-scope-sections.ts"

SPEC="${1:-}"
if [[ -z "$SPEC" ]]; then
    echo "error: spec.md path required" >&2
    echo "usage: $(basename "$0") <spec.md>" >&2
    exit 2
fi
if [[ ! -f "$SPEC" ]]; then
    echo "error: not a file: $SPEC" >&2
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

exec bun "$IMPL" "$SPEC"
