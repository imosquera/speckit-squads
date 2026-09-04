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
COMMON="$HERE/scope-common.py"

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
if [[ ! -f "$COMMON" ]]; then
    echo "error: missing helper: $COMMON" >&2
    exit 2
fi

python3 - "$SPEC" "$COMMON" <<'PY'
import pathlib
import sys

spec = pathlib.Path(sys.argv[1])
exec(compile(pathlib.Path(sys.argv[2]).read_text(), sys.argv[2], "exec"))

lines = spec.read_text().splitlines()
problems = []

corrections = section(lines, CORRECTIONS_TITLE)
if corrections is None:
    problems.append(
        "missing section: `## Corrections to the issue as filed`\n"
        "  Every file and precondition the issue asserts is a hypothesis. Record\n"
        "  which ones you re-derived against main and dropped, and why — or write\n"
        "  `None.` if the issue was right in every particular."
    )
elif not has_content(corrections):
    problems.append(
        "empty section: `## Corrections to the issue as filed`\n"
        "  Write the corrections, or `None.` if there were none."
    )

scope = section(lines, SCOPE_TITLE)
if scope is None:
    problems.append(
        "missing section: `## Scope discipline`\n"
        "  This section is the contract /speckit-plan and the review passes are\n"
        "  held to. Expected shape:\n"
        "\n"
        "    ## Scope discipline\n"
        "\n"
        "    **MUST NOT touch:**\n"
        "\n"
        "    - `infra/**` — no Terraform apply behind this change\n"
        "    - `firestore.rules` — the read runs on the Admin SDK, which never consults rules\n"
    )
elif not has_content(scope):
    problems.append(
        "empty section: `## Scope discipline`\n"
        "  List what MUST NOT be touched, or state `None.` explicitly."
    )
else:
    text = "\n".join(scope)
    declared_none = any(NONE_ANSWER.match(line) for line in scope if line.strip())
    if not MUST_NOT_MARKER.search(text) and not declared_none:
        problems.append(
            "`## Scope discipline` has no `MUST NOT touch:` list\n"
            "  The list is the machine-checkable half — without it nothing downstream\n"
            "  can be held to this section. Add the list, or state `None.`"
        )
    elif MUST_NOT_MARKER.search(text) and not must_not_paths(lines) and not declared_none:
        problems.append(
            "`## Scope discipline` declares `MUST NOT touch:` but lists no paths\n"
            "  Each entry must be a bullet naming a path or glob in backticks,\n"
            "  e.g. ``- `infra/**` — no Terraform apply behind this change``."
        )

if problems:
    print(f"error: {spec} does not satisfy the minimum-diff mandate", file=sys.stderr)
    for p in problems:
        print(f"  - {p}", file=sys.stderr)
    sys.exit(1)

paths = must_not_paths(lines)
if paths:
    print(f"diff-minimal: scope sections present; {len(paths)} path(s) held out of scope:")
    for p in paths:
        print(f"  - {p}")
else:
    print("diff-minimal: scope sections present (nothing held out of scope).")
PY
