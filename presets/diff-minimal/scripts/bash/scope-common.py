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


def logical_lines(lines, start=1):
    """[(lineno, text)] with wrapped continuations folded into what they continue.

    The artifacts these checkers read are prose, and every editor wraps prose.
    Matching physical lines meant a bullet that wrapped ended the MUST-NOT list
    at its first continuation line — 9 forbidden paths silently became 1, and
    the gate passed (issue #68). A wrapped bullet is one bullet.

    Only a BULLET or a `**marker:**` line absorbs a continuation — plus whatever
    has already been folded onto one. Every other line, prose included, stands
    alone. Letting any non-blank line absorb its successor merged two sentences
    of one paragraph into a single logical line, and a negation in the first
    sentence then exempted a forbidden path named in the second — a real
    violation silently passing `check-plan-scope.sh`, which is worse than the
    truncation issue #68 fixed. Both of #68's defects were wrapped BULLETS
    (a truncated `MUST NOT touch:` list, a restatement bullet losing its
    negation); prose never needed folding.

    A continuation is a non-blank line that does not itself open something (see
    `_opens_block`); a blank line closes the block, and nothing inside a ```
    fence ever folds. `lineno` is the line the block STARTED on, so a report
    still points at the bullet rather than at its tail.

    `_opens_block`'s ordered items, blockquotes and table rows are belt-and-
    braces now that only bullets fold, but they still earn their keep for a
    numbered list or a table written directly under a bullet.
    """
    out = []
    in_fence = False
    accepting = False  # does out[-1] take a wrapped continuation?
    for n, line in enumerate(lines, start):
        # Code is not prose: nothing inside a fence wraps, so a fenced line is
        # always its own entry and never absorbs the line after the fence.
        if FENCE.match(line):
            in_fence = not in_fence
            out.append((n, line))
            accepting = False
            continue
        if in_fence or not line.strip():
            out.append((n, line))
            accepting = False
            continue
        if accepting and not _opens_block(line):
            n0, text = out[-1]
            out[-1] = (n0, text.rstrip() + " " + line.strip())
            # The folded block keeps taking further wrapped lines: a bullet may
            # wrap onto three physical lines as readily as two.
            continue
        out.append((n, line))
        accepting = _accepts_continuation(line)
    return out


# A line that starts something of its own, so it never folds into its predecessor.
_MARKER_LINE = re.compile(r'^\s*\*{2}[^*]+\*{2}\s*:?\s*$')
FENCE = re.compile(r'^\s*(?:```|~~~)')
# Ordered-list items, blockquote lines, table rows and thematic breaks are each
# their own line of markdown. Folding them into their predecessor merged whole
# numbered plans and whole tables into one entry, which both misreported the
# line number and — worse — let a negation anywhere in the block exempt every
# forbidden path in it.
_OTHER_BLOCK = re.compile(r'^\s*(?:\d+[.)]\s+|>|\||-{3,}\s*$|={3,}\s*$|\*{3,}\s*$|_{3,}\s*$)')


def _opens_block(line):
    return bool(
        HEADING.match(line)
        or BULLET.match(line)
        or _MARKER_LINE.match(line)
        or _OTHER_BLOCK.match(line)
    )


def _accepts_continuation(line):
    """Only a list item or a `**marker:**` line can have a wrapped tail.

    Narrow on purpose: see `logical_lines`. Anything wider merges independent
    prose sentences, and one sentence's negation then exempts the next
    sentence's forbidden path.
    """
    return bool(BULLET.match(line) or _MARKER_LINE.match(line))


def has_content(body):
    """True when a section body says anything at all (blank lines don't count)."""
    return any(line.strip() for line in (body or []))


def bullet_path(text):
    """The path a MUST-NOT bullet names, else None.

    Whichever candidate comes FIRST in the text wins — a backticked token (the
    documented spelling) or a path-shaped bare one (the fallback, so a spec that
    forgot the backticks is still checked rather than silently passing). Ties go
    to the backticks, so a bullet that opens with a backticked path is unchanged.

    Position, not preference, because the bullet's wrapped tail is now part of
    this text: preferring backticks unconditionally made a bare-spelled bullet
    return a backticked path out of its own prose, inverting enforcement — the
    forbidden path passes and a permitted one is blocked.
    """
    best = None  # (offset, path)
    m = re.search(r'`([^`]+)`', text)
    if m:
        best = (m.start(), m.group(1).strip())
    for tm in re.finditer(r'\S+', text):
        if best and tm.start() >= best[0]:
            break
        token = tm.group(0).strip('.,;:()[]"\'')
        # A token carrying a backtick belongs to the backticked candidate above.
        if not token or '`' in token:
            continue
        if '/' in token or token.startswith('*') or re.search(r'\.[A-Za-z0-9]{1,6}$', token):
            return token
    return best[1] if best else None


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
    for _n, line in logical_lines(body):
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
