#!/usr/bin/env python3
"""Parse, Don't Validate — deterministic anti-pattern scanner.

Enforces the "parse, don't validate" discipline: push untrusted data through a
parser at the boundary that returns a *more precise type*, instead of scattering
re-validation (`isValid...`, defensive `if`s) across the call stack. A validator
says "this is fine, continue" and throws the proof away the instant it returns;
a parser returns either a precise type or a typed error and the type carries the
proof forward. This script gives the preset teeth: an implementer can't claim
"no validators left" while an `is_valid_user` / `isValidUser` still sits in the
diff.

Language-aware: understands TypeScript (`.ts/.tsx/.mts/.cts`) and Python
(`.py/.pyi`). Stdlib-only. Python 3.8+.

Subcommands
-----------
  checklist
      Print the discipline items an implementation audit must cover.

  scan [paths ...]
      Scan TypeScript/Python sources for parse-don't-validate anti-patterns.
      With no paths, scans files changed in the working tree (git). Exits
      non-zero when un-waived findings exist.

Waivers
-------
Any finding can be suppressed with a trailing or preceding line comment
(`//` for TypeScript, `#` for Python):

      const raw = input as User; // parse-dont-validate: allow PDV004 (boundary)
      user = cast(User, raw)      # parse-dont-validate: allow PDV004 (boundary)

The rule id is required; the parenthetical reason is for humans. Waive at the
*parser boundary* — that is the one place a narrowing cast is legitimate. A
waiver that leaks outside a parser module is the bug this scheme exists to
prevent.
"""

from __future__ import annotations

import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, List

# --- discipline items (language-general) ------------------------------------

CHECKLIST = [
    ("PDV001", "No dynamic-typing escape hatch",
     "TypeScript `any`/`as any` and Python `Any` erase the boundary. Untrusted "
     "input is `unknown` (TS) or a parsed model (Py), never `any`/`Any`."),
    ("PDV002", "Deserialization stays at a parser boundary",
     "`JSON.parse` / `json.loads` / `pickle.loads` are deserializers, not "
     "validators. Keep them inside a parser module that hands back a precise "
     "domain type; don't scatter raw deserialization through domain code."),
    ("PDV003", "No boolean validators at the boundary",
     "A `boolean`/`bool`-returning `isValid*`/`validate*` throws information "
     "away the instant it returns. Return a parsed, more-precise type (or a "
     "Result) instead."),
    ("PDV004", "Narrowing casts only inside parser modules",
     "TypeScript `x as Brand` and Python `cast(Brand, x)` are the one "
     "sanctioned lie — confine them to the parser at the boundary. A cast "
     "elsewhere forges trust the type system never granted."),
]

WAIVER_RE = re.compile(r"parse-dont-validate:\s*allow\s+(PDV\d{3})", re.IGNORECASE)

# A parser boundary module — the sanctioned home for narrowing casts and raw
# deserialization. Covers TS parser/schema idioms and Python model/schema ones.
PARSER_FILE_RE = re.compile(
    r"(parse|parser|schema|schemas|codec|decoder|brand|model|models)",
    re.IGNORECASE,
)

# --- TypeScript patterns ----------------------------------------------------

TS_ANY_RE = re.compile(r"\bas\s+any\b|:\s*any\b")
TS_JSON_PARSE_RE = re.compile(r"\bJSON\.parse\s*\(")
TS_UNKNOWN_RE = re.compile(r":\s*unknown\b")
TS_VALIDATOR_RE = re.compile(
    r"\b(?:function\s+|const\s+|let\s+)?"
    r"(is[A-Z]\w*|validate\w*|checkValid\w*)\b"
    r"[^=;{]*(:\s*boolean\b|=>\s*boolean\b)"
)
TS_BRAND_CAST_RE = re.compile(r"\bas\s+([A-Z]\w+)\b")
TS_BRAND_CAST_IGNORE = {"const", "String", "Number", "Boolean", "Array",
                        "Object", "Record", "Readonly", "Partial", "Promise",
                        "Error", "unknown"}

# --- Python patterns --------------------------------------------------------

PY_ANY_RE = re.compile(r"(?::|->|\[|,|\()\s*Any\b|\bAny\s*[\]\),]")
PY_DESERIALIZE_RE = re.compile(
    r"\b(json\.loads?|pickle\.loads?|yaml\.safe_load|yaml\.load|marshal\.loads)\s*\("
)
PY_VALIDATOR_RE = re.compile(
    r"\bdef\s+(is_valid\w*|validate\w*|is_\w+)\s*\([^)]*\)\s*->\s*bool\b"
)
PY_CAST_RE = re.compile(r"\b(?:typing\.)?cast\s*\(")

TS_EXTENSIONS = {".ts", ".tsx", ".mts", ".cts"}
PY_EXTENSIONS = {".py", ".pyi"}
EXTENSIONS = TS_EXTENSIONS | PY_EXTENSIONS


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


def _scan_typescript(line: str, is_parser: bool, add: Callable[[str], None]) -> None:
    if TS_ANY_RE.search(line):
        add("PDV001")
    if TS_JSON_PARSE_RE.search(line) and not TS_UNKNOWN_RE.search(line):
        add("PDV002")
    if TS_VALIDATOR_RE.search(line):
        add("PDV003")
    if not is_parser:
        for m in TS_BRAND_CAST_RE.finditer(line):
            if m.group(1) not in TS_BRAND_CAST_IGNORE:
                add("PDV004")
                break


def _scan_python(line: str, is_parser: bool, add: Callable[[str], None]) -> None:
    stripped = line.lstrip()
    is_import = stripped.startswith(("import ", "from "))
    if not is_import and PY_ANY_RE.search(line):
        add("PDV001")
    if not is_parser and PY_DESERIALIZE_RE.search(line):
        add("PDV002")
    if PY_VALIDATOR_RE.search(line):
        add("PDV003")
    if not is_parser and PY_CAST_RE.search(line):
        add("PDV004")


def scan_file(path: Path) -> List[Finding]:
    try:
        content = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    scanner = _scan_python if path.suffix in PY_EXTENSIONS else _scan_typescript
    lines = content.splitlines()
    is_parser = bool(PARSER_FILE_RE.search(path.name))
    findings: List[Finding] = []

    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith(("//", "*", "#")):
            continue
        waived = _waivers_for_line(lines, i)

        def add(rule: str, _i=i, _stripped=stripped, _waived=waived):
            if rule not in _waived:
                findings.append(Finding(rule, str(path), _i + 1, _stripped))

        scanner(line, is_parser, add)

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
    skip = {"node_modules", "dist", "__pycache__", ".venv", "venv", "build"}
    return [p for p in out if not (skip & set(p.parts))]


def cmd_checklist() -> int:
    for rule, title, why in CHECKLIST:
        print(f"{rule}\t{title}")
        print(f"\t{why}")
    return 0


def cmd_scan(paths: List[str]) -> int:
    targets = _expand(paths) if paths else _changed_files()
    if not targets:
        print("parse-dont-validate: no TypeScript/Python files to scan.")
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
          f"at the parser boundary with a `parse-dont-validate: allow PDVxxx` "
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
