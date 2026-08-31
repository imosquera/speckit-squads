#!/usr/bin/env python3
"""PreToolUse hook: redirect structural Grep/Glob questions to the knowledge graph.

Reads the Claude Code hook payload on stdin and, when the project has a built
graph (`graphify-out/graph.json`), emits a NON-BLOCKING reminder that structural
questions — callers, dependents, imports, "what reads this" — are graph queries,
not text searches.

Survivability rules (a hook that cries wolf gets disabled within a day):

  * Fires only when `graphify-out/graph.json` exists.
  * Never blocks. No `permissionDecision` is emitted, so the tool call proceeds
    exactly as it would have; the agent is redirected, not stopped.
  * Fires only on patterns that look STRUCTURAL. Literal-string searches —
    quoted config values, prose/log/comment text, URLs, anything with
    whitespace — are left alone, as are searches scoped to non-code files.
  * At most FIRE_BUDGET reminders per session. After that the hook is silent
    for the rest of the session; the point has been made.
  * Any internal error exits 0 with no output. A broken guard must never
    interfere with a working search.

Exit codes: always 0.  Stdlib only.
"""

from __future__ import annotations

import json
import mmap
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

FIRE_BUDGET = 3

# Patterns whose *shape* says "I am looking for a symbol", not "I am looking for
# a string". At least one identifier-ish token, no whitespace, no quotes.
IDENT_TOKEN = re.compile(r"[A-Za-z_$][A-Za-z0-9_$]{2,}")
LITERAL_HINTS = ("://", '"', "'", "`", " ", "\t")

CODE_EXTS = {
    "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "go", "rs", "java", "rb",
    "php", "swift", "kt", "kts", "c", "h", "cc", "cpp", "hpp", "cs", "scala",
    "m", "mm", "vue", "svelte",
}


def project_dir() -> Path:
    return Path(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())


def structural_grep(tool_input: dict) -> bool:
    pattern = tool_input.get("pattern") or ""
    if not pattern or any(h in pattern for h in LITERAL_HINTS):
        return False
    if not IDENT_TOKEN.search(pattern):
        return False
    # A search already scoped to non-code files is a docs/config search.
    scope = (tool_input.get("glob") or "") + " " + (tool_input.get("type") or "")
    if scope.strip():
        exts = set(re.findall(r"[A-Za-z0-9]+", scope))
        if exts and not (exts & CODE_EXTS):
            return False
    return True


def structural_glob(tool_input: dict) -> bool:
    pattern = tool_input.get("pattern") or ""
    ext = pattern.rsplit(".", 1)[-1].lower() if "." in pattern else ""
    return ext in CODE_EXTS


def graph_commit(graph: Path) -> str | None:
    """Find `built_at_commit` without parsing the graph.

    The key is top-level but not near the top of the file — in a real project it
    sits megabytes in — so this mmaps and byte-scans instead of decoding JSON.
    """
    try:
        with graph.open("rb") as fh:
            with mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_READ) as mm:
                m = re.search(rb'"built_at_commit"\s*:\s*"([0-9a-f]{7,40})"', mm)
                return m.group(1).decode() if m else None
    except (OSError, ValueError):
        return None


def freshness_note(root: Path, graph: Path) -> str:
    built = graph_commit(graph)
    if not built:
        return ""
    try:
        head = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""
    if not head or head == built:
        return ""
    return (
        f"\nFreshness: the graph was built at {built[:8]}, HEAD is {head[:8]}. "
        "A stale graph means REBUILD it (`graphify update`) — it does not mean "
        "fall back to grep."
    )


def budget_spent(session_id: str) -> bool:
    """Count fires per session in a temp file. Returns True when over budget."""
    if not session_id:
        return False
    slug = re.sub(r"[^A-Za-z0-9_-]", "_", session_id)[:64]
    counter = Path(tempfile.gettempdir()) / "claude-graph-first" / slug
    try:
        counter.parent.mkdir(parents=True, exist_ok=True)
        n = int(counter.read_text()) if counter.exists() else 0
        if n >= FIRE_BUDGET:
            return True
        counter.write_text(str(n + 1))
    except (OSError, ValueError):
        return False
    return False


def message(tool: str, pattern: str, note: str) -> str:
    return (
        f"Graph-first navigation: this {tool} (`{pattern}`) looks like a structural "
        "question, and this project has a built knowledge graph "
        "(`graphify-out/`) that answers those definitively — it was produced by "
        "parsing, not text matching.\n"
        "\n"
        "Use instead:\n"
        '  graphify query "what calls <symbol>"   — callers / dependents / readers\n'
        '  graphify path "<A>" "<B>"              — how two modules connect\n'
        '  graphify explain "<symbol>"            — what a node is and touches\n'
        "  the LSP tool (findReferences / incomingCalls / goToDefinition) for exact\n"
        "  TypeScript call sites before a rename or signature change.\n"
        "\n"
        "Grep is still the right tool for: literal strings, comment/log text, config\n"
        "values, generated or vendored files, and anything the graph does not model."
        f"{note}\n"
        "\n"
        "This is a reminder, not a block — the search you asked for is running."
    )


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    tool = payload.get("tool_name") or ""
    if tool not in ("Grep", "Glob"):
        return 0

    tool_input = payload.get("tool_input") or {}
    if not isinstance(tool_input, dict):
        return 0

    root = project_dir()
    graph = root / "graphify-out" / "graph.json"
    if not graph.is_file():
        return 0

    fires = structural_grep(tool_input) if tool == "Grep" else structural_glob(tool_input)
    if not fires:
        return 0

    if budget_spent(str(payload.get("session_id") or "")):
        return 0

    text = message(tool, (tool_input.get("pattern") or "")[:120], freshness_note(root, graph))
    json.dump(
        {
            "systemMessage": "graph-first: structural question — prefer `graphify query` / LSP over grep",
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "additionalContext": text,
            },
        },
        sys.stdout,
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # never interfere with a working search
        sys.exit(0)
