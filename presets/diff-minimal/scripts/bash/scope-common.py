#!/usr/bin/env python3
"""diff-minimal preset: shared parsing for the two scope checkers.

One job: read the machine-checkable half of a spec's `## Scope discipline`
section out of a `spec.md`. Both `check-scope-sections.sh` (does the section
exist and say anything) and `check-plan-scope.sh` (does a later artifact touch
what it forbade) parse the same shape, so the shape is spelled once here.

The shape it parses:

    ## Scope discipline

    **MUST NOT touch:**

    - `path/or/glob` — reason
    - `another/path`

    **Scope justification:** <only when the change is inherently wide>

Not imported as a module — the two callers exec this file — so it deliberately
has no dependencies beyond the stdlib.
"""

import re

# A heading at any level: (level, title)
HEADING = re.compile(r'^(#{1,6})\s+(.+?)\s*$')
BULLET = re.compile(r'^\s*[-*+]\s+(.*)$')

CORRECTIONS_TITLE = re.compile(r'^corrections to the issue as filed$', re.I)
SCOPE_TITLE = re.compile(r'^scope discipline$', re.I)
MUST_NOT_MARKER = re.compile(r'must\s+not\s+touch', re.I)
JUSTIFICATION_MARKER = re.compile(r'scope\s+justification', re.I)

# An explicit "the issue was right" answer. Without this a spec that legitimately
# has no corrections has to invent one, which is worse than no rule at all.
NONE_ANSWER = re.compile(r'^\s*(?:[-*+]\s+)?(?:\*{0,2}|_{0,2})none[.!]?(?:\*{0,2}|_{0,2})\b', re.I)


def heading(line):
    """(level, title) for a heading line, else None."""
    m = HEADING.match(line)
    return (len(m.group(1)), m.group(2)) if m else None


def section(lines, title_re):
    """Body lines of the first section whose title matches, else None.

    A section runs from its heading to the next heading of the same or a
    shallower level, or EOF — the same boundary rule spec-minimal's stripper
    uses, so the two presets agree on where a section ends.
    """
    for i, line in enumerate(lines):
        h = heading(line)
        if not h or not title_re.match(h[1]):
            continue
        level = h[0]
        body = []
        for line in lines[i + 1:]:
            hh = heading(line)
            if hh and hh[0] <= level:
                break
            body.append(line)
        return body
    return None


def has_content(body):
    """True when a section body says anything at all (blank lines don't count)."""
    return any(line.strip() for line in (body or []))


def bullet_path(text):
    """The path a MUST-NOT bullet names, else None.

    Prefers a backticked token — that is the documented spelling. Falls back to
    the first whitespace-delimited token that looks like a path so a spec that
    forgot the backticks still gets checked rather than silently passing.
    """
    m = re.search(r'`([^`]+)`', text)
    if m:
        return m.group(1).strip()
    for token in text.split():
        token = token.strip('.,;:()[]"\'')
        if '/' in token or token.startswith('*') or re.search(r'\.[A-Za-z0-9]{1,6}$', token):
            return token
    return None


def must_not_paths(lines):
    """Every path listed under a `MUST NOT touch` marker in `## Scope discipline`.

    Returns [] when the section is absent — the caller decides whether that is a
    failure, because the two checkers answer that differently.
    """
    body = section(lines, SCOPE_TITLE)
    if body is None:
        return []

    paths = []
    collecting = False
    for line in body:
        if MUST_NOT_MARKER.search(line):
            collecting = True
            continue
        if not collecting:
            continue
        if not line.strip():
            continue
        m = BULLET.match(line)
        if not m:
            # A non-bullet, non-blank line ends the list (e.g. the justification
            # paragraph, or free prose after it).
            break
        if NONE_ANSWER.match(line):
            continue
        p = bullet_path(m.group(1))
        if p:
            paths.append(p)
    return paths


def path_pattern(path):
    """Compile a listed path into a substring regex.

    `**` spans directory separators, a lone `*` does not — glob semantics, so a
    spec can forbid `infra/**` without also forbidding `infrastructure`.
    Trailing `/` means "this directory and everything under it".
    """
    p = path.rstrip()
    if p.endswith('/'):
        p = p + '**'
    out = []
    i = 0
    while i < len(p):
        if p[i:i + 2] == '**':
            out.append('.*')
            i += 2
        elif p[i] == '*':
            out.append('[^/]*')
            i += 1
        else:
            out.append(re.escape(p[i]))
            i += 1
    return re.compile(''.join(out))
