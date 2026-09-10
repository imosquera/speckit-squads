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

python3 - "$SPEC" <<'PY'
import re, sys, pathlib

path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines(keepends=True)

# (heading_level, name, heading_text_regex) — `.*` absorbs the template's
# `*(mandatory)*` / `*(include if ...)*` suffixes.
TARGETS = [
    (2, 'Assumptions', re.compile(r'^##\s+Assumptions\b.*$')),
    (3, 'Key Entities', re.compile(r'^###\s+Key Entities\b.*$')),
    (2, 'Success Criteria', re.compile(r'^##\s+Success Criteria\b.*$')),
]

def heading_level(line):
    m = re.match(r'^(#{1,6})\s+\S', line)
    return len(m.group(1)) if m else None

removed = []
out = []
i = 0
while i < len(lines):
    line = lines[i]
    for level, name, pat in TARGETS:
        if pat.match(line):
            j = i + 1
            while j < len(lines):
                lvl = heading_level(lines[j])
                if lvl is not None and lvl <= level:
                    break
                j += 1
            i = j
            removed.append(name)
            break
    else:
        out.append(line)
        i += 1

path.write_text(''.join(out))

absent = [name for _, name, _ in TARGETS if name not in removed]
parts = []
if removed:
    parts.append("stripped " + " / ".join(removed))
if absent:
    parts.append("not present: " + " / ".join(absent))
print("ok: " + "; ".join(parts) + " (%s)" % path)
PY
