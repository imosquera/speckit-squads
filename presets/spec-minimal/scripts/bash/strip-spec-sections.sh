#!/usr/bin/env bash
# spec-minimal preset: strip-spec-sections.sh
# Remove the Assumptions, Key Entities, and Success Criteria sections from a
# spec.md, in place. Idempotent — safe to run repeatedly.
#
# Section boundary rule: a section starts at its heading line and ends at the
# next heading of the same-or-shallower level, or EOF.
#
# Heading matching tolerates the template's trailing parentheticals, e.g.
# `## Success Criteria *(mandatory)*` — anchoring at `$` silently stripped
# nothing while still reporting success (issue #58).
#
# Usage: strip-spec-sections.sh <spec.md>

set -e

SPEC="${1:-}"
if [[ -z "$SPEC" ]]; then
    echo "error: spec.md path required" >&2
    exit 2
fi
if [[ ! -f "$SPEC" ]]; then
    echo "error: not a file: $SPEC" >&2
    exit 2
fi

if ! command -v bun >/dev/null 2>&1; then
    echo "error: bun is required but not on PATH (install: https://bun.sh)" >&2
    exit 127
fi
exec bun "$(dirname "${BASH_SOURCE[0]}")/../ts/strip-spec-sections.ts" "$SPEC"
