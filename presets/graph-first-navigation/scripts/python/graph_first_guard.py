#!/usr/bin/env python3
"""PreToolUse hook: keep structural navigation on the graph, and typed refactors on the LSP.

Reads the Claude Code hook payload on stdin and emits a NON-BLOCKING reminder in
three situations:

  1. A structural search — Grep/Glob, or a `grep`/`rg` shelled through Bash —
     where the question ("what calls X", "who imports Y") is one the knowledge
     graph answers by parsing rather than by text matching.
  2. The same, but the project has NO graph yet (a fresh worktree). The answer
     there is `graphify update <path>`, not a fallback to grep. This is the case
     the old "when graphify-out/ exists" phrasing silently exempted.
  3. The first edit to a TypeScript file in a session: a rename or signature
     change should be scoped with LSP findReferences/incomingCalls BEFORE the
     edit, not with `tsc --noEmit` in a loop afterwards.

Survivability rules (a hook that cries wolf gets disabled within a day):

  * Never blocks. No `permissionDecision` is emitted, so the tool call proceeds
    exactly as it would have; the agent is redirected, not stopped.
  * Fires only on patterns that look STRUCTURAL. Literal-string searches —
    quoted config values, prose/log/comment text, URLs, anything with
    whitespace — are left alone, as are searches scoped to non-code files.
  * Per-session, per-category fire budgets. After that the hook is silent for
    the rest of the session; the point has been made.
  * Identical tool inputs fire once, so a guard registered both globally and by
    a project preset does not double up.
  * Any internal error exits 0 with no output. A broken guard must never
    interfere with a working search.

Exit codes: always 0.  Stdlib only.
"""

from __future__ import annotations

import hashlib
import json
import mmap
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# Per-category budgets. "absent" is the loudest signal and the cheapest to act
# on (one command), so it gets fewer fires, not more.
BUDGETS = {"structural": 3, "absent": 2, "typescript": 1}

# Patterns whose *shape* says "I am looking for a symbol", not "I am looking for
# a string". At least one identifier-ish token, no whitespace, no quotes.
IDENT_TOKEN = re.compile(r"[A-Za-z_$][A-Za-z0-9_$]{2,}")
LITERAL_HINTS = ("://", '"', "'", "`", " ", "\t")

CODE_EXTS = {
    "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "go", "rs", "java", "rb",
    "php", "swift", "kt", "kts", "c", "h", "cc", "cpp", "hpp", "cs", "scala",
    "m", "mm", "vue", "svelte",
}
TS_EXTS = {".ts", ".tsx", ".mts", ".cts"}

SEARCH_BINS = {"grep", "egrep", "fgrep", "rg", "ripgrep", "ack", "ag"}


def project_dir() -> Path:
    return Path(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())


# --------------------------------------------------------------- classifiers

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


def bash_search_pattern(command: str) -> str | None:
    """Return the search term when a Bash command is a structural grep/rg.

    Only the first pipeline stage is considered: `... | grep foo` is filtering
    another command's output, not searching the tree, and is none of the graph's
    business.
    """
    if not command:
        return None
    head = re.split(r"[|;&]|\n", command, maxsplit=1)[0].strip()
    try:
        argv = shlex.split(head)
    except ValueError:
        return None
    # Step past env assignments and common prefixes.
    while argv and ("=" in argv[0].split("/")[-1].split(" ")[0] and "=" in argv[0]):
        argv = argv[1:]
    if not argv:
        return None
    if Path(argv[0]).name not in SEARCH_BINS:
        return None
    for arg in argv[1:]:
        if arg.startswith("-"):
            continue
        # First non-flag token is the pattern; everything after is a path.
        if any(h in arg for h in LITERAL_HINTS) or not IDENT_TOKEN.search(arg):
            return None
        return arg
    return None


def graph_is_expected_here(root: Path) -> bool:
    """Would a graph exist in this checkout if someone had built it?

    Answering "no" keeps the missing-graph reminder off projects that have
    simply never used graphify. It answers "yes" for the case this hook exists
    to catch: a fresh worktree of a repo whose primary checkout has a graph.
    """
    if not shutil.which("graphify"):
        return False
    if (root / ".specify" / "presets" / "graph-first-navigation").is_dir():
        return True
    try:
        common = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--path-format=absolute", "--git-common-dir"],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return False
    if not common:
        return False
    primary = Path(common).parent
    return (primary / "graphify-out" / "graph.json").is_file()


def touches_typescript(tool_input: dict) -> bool:
    path = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
    return Path(str(path)).suffix in TS_EXTS


# ------------------------------------------------------------------ freshness

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
        f"A stale graph means REBUILD it (`graphify update {root}`) — it does "
        "not mean fall back to grep."
    )


# -------------------------------------------------------------------- budgets

def state_dir(session_id: str) -> Path | None:
    if not session_id:
        return None
    slug = re.sub(r"[^A-Za-z0-9_-]", "_", session_id)[:64]
    d = Path(tempfile.gettempdir()) / "claude-graph-first" / slug
    try:
        d.mkdir(parents=True, exist_ok=True)
    except OSError:
        return None
    return d


def already_fired_for(d: Path | None, tool: str, tool_input: dict) -> bool:
    """Dedupe identical inputs so a doubly-registered guard fires once."""
    if d is None:
        return False
    try:
        key = hashlib.sha1(
            (tool + json.dumps(tool_input, sort_keys=True, default=str)).encode()
        ).hexdigest()[:32]
        marker = d / f"seen-{key}"
        if marker.exists():
            return True
        marker.write_text("1")
    except (OSError, TypeError, ValueError):
        return False
    return False


def budget_spent(d: Path | None, category: str) -> bool:
    if d is None:
        return False
    counter = d / f"count-{category}"
    try:
        n = int(counter.read_text()) if counter.exists() else 0
        if n >= BUDGETS.get(category, 3):
            return True
        counter.write_text(str(n + 1))
    except (OSError, ValueError):
        return False
    return False


# ------------------------------------------------------------------- messages

DECISION_TABLE = (
    "  structure / callers / dependents / imports   -> graphify query \"what calls X\"\n"
    "  how two things connect                       -> graphify path \"A\" \"B\"\n"
    "  what is this, what does it touch             -> graphify explain \"X\"\n"
    "  exact string, prose, config, env var, route  -> grep (correct as-is)\n"
)


def message_structural(tool: str, pattern: str, note: str) -> str:
    return (
        f"Graph-first navigation: this {tool} (`{pattern}`) looks like a structural "
        "question, and this project has a built knowledge graph "
        "(`graphify-out/`) that answers those definitively — it was produced by "
        "parsing, not text matching.\n"
        "\n"
        f"{DECISION_TABLE}"
        "\n"
        "For a TypeScript rename or signature change, scope it with the LSP tool "
        "(findReferences / incomingCalls / goToDefinition) before the first edit "
        "— but only once `command -v typescript-language-server` finds it; "
        "unprobed, that call fails with ENOENT. See CLAUDE.md for the "
        "project-local bootstrap."
        f"{note}\n"
        "\n"
        "This is a reminder, not a block — the search you asked for is running."
    )


def message_absent(root: Path, tool: str, pattern: str) -> str:
    return (
        f"Graph-first navigation: this {tool} (`{pattern}`) is a structural question, "
        f"and this checkout has no knowledge graph yet ({root}/graphify-out is "
        "missing). A missing graph means BUILD it — it does not mean fall back to "
        "grep:\n"
        "\n"
        f"  graphify update {root}\n"
        "\n"
        "Pass the path explicitly. A bare `graphify update` rebuilds whichever "
        "project the CWD resolves to, which in a worktree is the wrong one.\n"
        "\n"
        f"{DECISION_TABLE}"
        "\n"
        "This is a reminder, not a block — the search you asked for is running."
    )


def message_typescript(path: str) -> str:
    return (
        f"Typed-refactor reminder (first TypeScript edit this session: {path}).\n"
        "\n"
        "If this edit renames a symbol, changes a signature, or changes a type, "
        "scope it FIRST with the LSP tool — findReferences / incomingCalls / "
        "goToDefinition — rather than discovering the breakage afterwards by "
        "running `tsc --noEmit` in a loop. Probe first — "
        "`command -v typescript-language-server`; unfound, the LSP tool fails "
        "with ENOENT and CLAUDE.md has the project-local bootstrap. "
        "For module-level blast radius, "
        "`graphify query \"what calls <symbol>\"` covers the same ground across "
        "languages the language server does not load.\n"
        "\n"
        "This is a reminder, not a block — the edit you asked for is running."
    )


def emit(summary: str, text: str) -> None:
    json.dump(
        {
            "systemMessage": summary,
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "additionalContext": text,
            },
        },
        sys.stdout,
    )


# ----------------------------------------------------------------------- main

def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    tool = payload.get("tool_name") or ""
    tool_input = payload.get("tool_input") or {}
    if not isinstance(tool_input, dict):
        return 0

    root = project_dir()
    graph = root / "graphify-out" / "graph.json"
    d = state_dir(str(payload.get("session_id") or ""))

    # ---- the TypeScript half
    if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        if not touches_typescript(tool_input):
            return 0
        if already_fired_for(d, tool, tool_input) or budget_spent(d, "typescript"):
            return 0
        emit(
            "typed refactor: scope renames/signature changes with LSP before editing",
            message_typescript(str(tool_input.get("file_path") or "")),
        )
        return 0

    # ---- the search half
    if tool == "Grep":
        fires = structural_grep(tool_input)
        pattern = tool_input.get("pattern") or ""
    elif tool == "Glob":
        fires = structural_glob(tool_input)
        pattern = tool_input.get("pattern") or ""
    elif tool == "Bash":
        pattern = bash_search_pattern(str(tool_input.get("command") or "")) or ""
        fires = bool(pattern)
        tool = "grep/rg via Bash"
    else:
        return 0

    if not fires:
        return 0
    if already_fired_for(d, tool, tool_input):
        return 0

    if not graph.is_file():
        if not graph_is_expected_here(root):
            return 0
        if budget_spent(d, "absent"):
            return 0
        emit(
            f"graph-first: no graph in this checkout — build it (`graphify update {root}`)",
            message_absent(root, tool, pattern[:120]),
        )
        return 0

    if budget_spent(d, "structural"):
        return 0
    emit(
        "graph-first: structural question — prefer `graphify query` / LSP over grep",
        message_structural(tool, pattern[:120], freshness_note(root, graph)),
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # never interfere with a working search
        sys.exit(0)
