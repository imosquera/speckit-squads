#!/usr/bin/env python3
"""Parse, Don't Validate — deterministic anti-pattern scanner for TypeScript.

Enforces the discipline from Alexis King's "Parse, don't validate": push
untrusted data through a parser at the boundary that returns a *more precise
type*, instead of scattering re-validation (`isValid...`, defensive `if`s)
across the call stack. This script gives the parse-dont-validate preset teeth:
an LLM can't claim "no validators left" while an `isValidUser` still sits in
the diff.

Stdlib-only. Python 3.8+.

Subcommands
-----------
  checklist
      Print the discipline items an implementation audit must cover.

  scan [paths ...]
      Scan TypeScript/TSX sources for parse-don't-validate anti-patterns.
      With no paths, scans files changed in the working tree (git). Exits
      non-zero when un-waived findings exist.

Waivers
-------
Any finding can be suppressed with a trailing or preceding line comment:

      const raw = input as User; // parse-dont-validate: allow PDV004 (trusted boundary)

The rule id is required; the parenthetical reason is for humans. Waive at the
*parser boundary* — that is the one place casting is legitimate. A waiver that
leaks outside a parser module is the bug this whole scheme exists to prevent.
"""

from __future__ import annotations

import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import List

# --- rules ------------------------------------------------------------------

CHECKLIST = [
    ("PDV001", "No `any` / `as any`",
     "The worst type in the language. Untrusted input is `unknown`, not `any`."),
    ("PDV002", "`JSON.parse` result is typed `unknown`",
     "`JSON.parse` is a deserializer, not a validator. Annotate its result "
     "`unknown` immediately and let a parser earn the domain type."),
    ("PDV003", "No boolean validators at the boundary",
     "A `boolean`-returning `isValid*`/`validate*` throws information away the "
     "instant it returns. Return a parsed, more-precise type (or a Result) "
     "instead."),
    ("PDV004", "Brand casts only inside parser modules",
     "`x as Brand` is the one sanctioned lie — confine it to the parser at the "
     "boundary. A brand cast anywhere else forges trust the type system never "
     "granted."),
]

WAIVER_RE = re.compile(r"parse-dont-validate:\s*allow\s+(PDV\d{3})", re.IGNORECASE)

# A parser boundary module — the sanctioned home for `as Brand` casts.
PARSER_FILE_RE = re.compile(r"(parse|parser|schema|codec|decoder|brand)", re.IGNORECASE)

ANY_RE = re.compile(r"\bas\s+any\b|:\s*any\b")
JSON_PARSE_RE = re.compile(r"\bJSON\.parse\s*\(")
UNKNOWN_RE = re.compile(r":\s*unknown\b")
VALIDATOR_RE = re.compile(
    r"\b(?:function\s+|const\s+|let\s+)?"
    r"(is[A-Z]\w*|validate\w*|checkValid\w*)\b"
    r"[^=;{]*(:\s*boolean\b|=>\s*boolean\b)"
)
# `as <CapitalizedType>` but not the common structural escapes we don't care about.
BRAND_CAST_RE = re.compile(r"\bas\s+([A-Z]\w+)\b")
BRAND_CAST_IGNORE = {"const", "String", "Number", "Boolean", "Array", "Object",
                     "Record", "Readonly", "Partial", "Promise", "Error"}

EXTENSIONS = {".ts", ".tsx", ".mts", ".cts"}


@dataclass
class Finding:
    rule: str
    path: str
    line: int
    text: str


def _waivers_for_line(lines: List[str], idx: int) -> set:
    """Rule ids waived on this line or the line immediately above it."""
    waived = set()
    for probe in (idx, idx - 1):
        if 0 <= probe < len(lines):
            for m in WAIVER_RE.finditer(lines[probe]):
                waived.add(m.group(1).upper())
    return waived


def scan_file(path: Path) -> List[Finding]:
    try:
        content = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    lines = content.splitlines()
    is_parser = bool(PARSER_FILE_RE.search(path.name))
    findings: List[Finding] = []

    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("//") or stripped.startswith("*"):
            continue
        waived = _waivers_for_line(lines, i)

        def add(rule: str):
            if rule not in waived:
                findings.append(Finding(rule, str(path), i + 1, stripped))

        if ANY_RE.search(line):
            add("PDV001")
        if JSON_PARSE_RE.search(line) and not UNKNOWN_RE.search(line):
            add("PDV002")
        if VALIDATOR_RE.search(line):
            add("PDV003")
        if not is_parser:
            for m in BRAND_CAST_RE.finditer(line):
                if m.group(1) not in BRAND_CAST_IGNORE:
                    add("PDV004")
                    break

    return findings


def _changed_files() -> List[Path]:
    cmds = [
        ["git", "diff", "--name-only", "--diff-filter=d", "HEAD"],
        ["git", "diff", "--name-only", "--diff-filter=d"],
        ["git", "ls-files", "--others", "--exclude-standard"],
    ]
    names: List[str] = []
    for cmd in cmds:
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, check=False)
            names.extend(out.stdout.splitlines())
        except OSError:
            pass
    seen, paths = set(), []
    for n in names:
        if n and n not in seen:
            seen.add(n)
            p = Path(n)
            if p.suffix in EXTENSIONS and p.is_file():
                paths.append(p)
    return paths


def _expand(paths: List[str]) -> List[Path]:
    out: List[Path] = []
    for raw in paths:
        p = Path(raw)
        if p.is_dir():
            for ext in EXTENSIONS:
                out.extend(p.rglob(f"*{ext}"))
        elif p.suffix in EXTENSIONS and p.is_file():
            out.append(p)
    # skip node_modules / build output
    return [p for p in out if "node_modules" not in p.parts and "dist" not in p.parts]


def cmd_checklist() -> int:
    for rule, title, why in CHECKLIST:
        print(f"{rule}\t{title}")
        print(f"\t{why}")
    return 0


def cmd_scan(paths: List[str]) -> int:
    targets = _expand(paths) if paths else _changed_files()
    if not targets:
        print("parse-dont-validate: no TypeScript files to scan.")
        return 0

    findings: List[Finding] = []
    for path in sorted(set(targets)):
        findings.extend(scan_file(path))

    if not findings:
        print(f"parse-dont-validate: clean — scanned {len(set(targets))} file(s), "
              f"no anti-patterns.")
        return 0

    titles = {r: t for r, t, _ in CHECKLIST}
    findings.sort(key=lambda f: (f.path, f.line, f.rule))
    for f in findings:
        print(f"{f.path}:{f.line}: {f.rule} {titles.get(f.rule, '')}")
        print(f"    {f.text}")
    print()
    print(f"parse-dont-validate: {len(findings)} finding(s). Fix each, or waive "
          f"at the parser boundary with a `// parse-dont-validate: allow PDVxxx` "
          f"comment.")
    return 1


def main(argv: List[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "checklist":
        return cmd_checklist()
    if cmd == "scan":
        return cmd_scan(rest)
    print(f"unknown command: {cmd!r} (expected 'checklist' or 'scan')",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
