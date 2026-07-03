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

Language-aware:
  * Python (`.py/.pyi`) is analysed with the stdlib `ast` module — a real
    parse tree, so matches inside strings/comments never false-positive and
    multi-line signatures are understood. Files that don't parse fall back to a
    best-effort line scan.
  * TypeScript (`.ts/.tsx/.mts/.cts`) is analysed with line-based regex.
    Python's standard library has no TypeScript parser, and this script is
    stdlib-only (no node/tsc dependency), so a real TS AST isn't available here.

Stdlib-only. Python 3.8+.

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

import ast
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, List, Optional

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

VALIDATOR_NAME_RE = re.compile(r"^(is_[A-Za-z]\w*|validate\w*|check_valid\w*)$")

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


# --- Python: AST-based analysis --------------------------------------------

class _PyVisitor(ast.NodeVisitor):
    """Collect parse-don't-validate findings from a Python AST."""

    def __init__(self, path: str, lines: List[str], is_parser: bool):
        self.path = path
        self.lines = lines
        self.is_parser = is_parser
        self.findings: List[Finding] = []

    def _add(self, rule: str, lineno: int) -> None:
        if rule in _waivers_for_line(self.lines, lineno - 1):
            return
        text = self.lines[lineno - 1].strip() if 0 <= lineno - 1 < len(self.lines) else ""
        self.findings.append(Finding(rule, self.path, lineno, text))

    def _flag_any(self, annotation: Optional[ast.AST]) -> None:
        # PDV001: `Any` anywhere inside a type annotation subtree.
        if annotation is None:
            return
        for node in ast.walk(annotation):
            if isinstance(node, ast.Name) and node.id == "Any":
                self._add("PDV001", node.lineno)
            elif isinstance(node, ast.Attribute) and node.attr == "Any":
                self._add("PDV001", node.lineno)

    def visit_AnnAssign(self, node: ast.AnnAssign) -> None:
        self._flag_any(node.annotation)
        self.generic_visit(node)

    def visit_arg(self, node: ast.arg) -> None:
        self._flag_any(node.annotation)
        self.generic_visit(node)

    def _visit_func(self, node) -> None:
        self._flag_any(node.returns)
        # PDV003: boolean validator at the boundary.
        if (isinstance(node.returns, ast.Name) and node.returns.id == "bool"
                and VALIDATOR_NAME_RE.match(node.name)):
            self._add("PDV003", node.lineno)
        self.generic_visit(node)

    visit_FunctionDef = _visit_func
    visit_AsyncFunctionDef = _visit_func

    def visit_Call(self, node: ast.Call) -> None:
        func = node.func
        # PDV002: raw deserialization outside a parser module.
        if not self.is_parser and isinstance(func, ast.Attribute) \
                and isinstance(func.value, ast.Name):
            mod, fn = func.value.id, func.attr
            if ((mod in {"json", "pickle", "marshal"} and fn in {"load", "loads"})
                    or (mod == "yaml" and fn in {"load", "safe_load"})):
                self._add("PDV002", node.lineno)
        # PDV004: narrowing cast outside a parser module.
        if not self.is_parser:
            is_cast = ((isinstance(func, ast.Name) and func.id == "cast")
                       or (isinstance(func, ast.Attribute) and func.attr == "cast"))
            if is_cast:
                self._add("PDV004", node.lineno)
        self.generic_visit(node)


def _scan_python_ast(path: Path, content: str, lines: List[str],
                     is_parser: bool) -> Optional[List[Finding]]:
    try:
        tree = ast.parse(content, filename=str(path))
    except SyntaxError:
        return None  # signal: fall back to the line scanner
    visitor = _PyVisitor(str(path), lines, is_parser)
    visitor.visit(tree)
    # De-dupe (same Any can be reached via multiple annotation positions).
    seen, unique = set(), []
    for f in visitor.findings:
        key = (f.rule, f.line)
        if key not in seen:
            seen.add(key)
            unique.append(f)
    return unique


# Regex fallback for Python files that fail to parse (partial/py2 sources).
PY_ANY_RE = re.compile(r"(?::|->|\[|,|\()\s*Any\b|\bAny\s*[\]\),]")
PY_DESERIALIZE_RE = re.compile(
    r"\b(json\.loads?|pickle\.loads?|yaml\.safe_load|yaml\.load|marshal\.loads)\s*\("
)
PY_VALIDATOR_RE = re.compile(
    r"\bdef\s+(is_valid\w*|validate\w*|is_\w+)\s*\([^)]*\)\s*->\s*bool\b"
)
PY_CAST_RE = re.compile(r"\b(?:typing\.)?cast\s*\(")


def _scan_python_lines(line: str, is_parser: bool, add: Callable[[str], None]) -> None:
    stripped = line.lstrip()
    if not stripped.startswith(("import ", "from ")) and PY_ANY_RE.search(line):
        add("PDV001")
    if not is_parser and PY_DESERIALIZE_RE.search(line):
        add("PDV002")
    if PY_VALIDATOR_RE.search(line):
        add("PDV003")
    if not is_parser and PY_CAST_RE.search(line):
        add("PDV004")


# --- TypeScript: line-based regex analysis ----------------------------------

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


def _scan_typescript_lines(line: str, is_parser: bool, add: Callable[[str], None]) -> None:
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


def _scan_lines(path: Path, lines: List[str], is_parser: bool,
                scanner: Callable[[str, bool, Callable[[str], None]], None]) -> List[Finding]:
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


def scan_file(path: Path) -> List[Finding]:
    try:
        content = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    lines = content.splitlines()
    is_parser = bool(PARSER_FILE_RE.search(path.name))

    if path.suffix in PY_EXTENSIONS:
        ast_findings = _scan_python_ast(path, content, lines, is_parser)
        if ast_findings is not None:
            return ast_findings
        return _scan_lines(path, lines, is_parser, _scan_python_lines)

    return _scan_lines(path, lines, is_parser, _scan_typescript_lines)


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
