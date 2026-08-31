#!/usr/bin/env bash
# Register the graph-first PreToolUse hook in a consumer project.
#
# `specify` copies presets into `.specify/presets/<id>/`, but it has no reach
# into the Claude Code harness — a preset cannot declare a PreToolUse hook, and
# an extension's `hooks:` block only covers Spec Kit lifecycle phases, not tool
# calls. So the harness-level half of this preset is installed here, by
# install.sh's generic `post-install.sh` step.
#
# Two edits, both idempotent and both re-runnable:
#   1. .claude/settings.json  — PreToolUse hook on Grep|Glob -> graph_first_guard.py
#   2. CLAUDE.md              — the graph-first navigation rule, in a sentinel block
#
# Usage: post-install.sh <project-dir>
set -euo pipefail

PROJECT_DIR="${1:?usage: post-install.sh <project-dir>}"
cd "$PROJECT_DIR"

GUARD_REL=".specify/presets/graph-first-navigation/scripts/python/graph_first_guard.py"
SETTINGS=".claude/settings.json"
CMD="[ ! -f \"\${CLAUDE_PROJECT_DIR}/$GUARD_REL\" ] || python3 \"\${CLAUDE_PROJECT_DIR}/$GUARD_REL\""

if ! command -v jq >/dev/null 2>&1; then
  echo "  warn: jq not found — skipping .claude/settings.json hook registration" >&2
else
  mkdir -p .claude
  [[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"

  if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
    echo "  warn: $SETTINGS is not valid JSON — leaving it alone" >&2
  else
    tmp="$(mktemp)"
    jq --arg cmd "$CMD" '
      # Drop any previous registration of this guard, then append the current one.
      .hooks //= {}
      | .hooks.PreToolUse //= []
      | .hooks.PreToolUse |= (
          map(select(
            ((.hooks // []) | map(.command // "") | join(" ") | contains("graph_first_guard.py")) | not
          ))
          + [{
              matcher: "Grep|Glob",
              hooks: [{
                type: "command",
                command: $cmd,
                timeout: 10,
                statusMessage: "Graph-first check"
              }]
            }]
        )
    ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    echo "  registered PreToolUse hook (Grep|Glob) in $SETTINGS"
  fi
fi

# ---------------------------------------------------------------- CLAUDE.md
BEGIN="<!-- BEGIN graph-first-navigation -->"
END="<!-- END graph-first-navigation -->"

BLOCK="$(cat <<'EOF'
<!-- BEGIN graph-first-navigation -->
## Navigating this codebase

When `graphify-out/` exists in this project, query the graph **before** reaching
for Grep/Glob for any question about structure, callers, dependencies, imports,
or file relationships. The graph was built by parsing, so it answers those
definitively; grep is text matching and is the slower, noisier instrument for
exactly the questions the graph exists to answer.

```bash
graphify query "what calls <symbol>"    # callers, dependents, readers
graphify path "<A>" "<B>"               # how two modules connect
graphify explain "<symbol>"             # what a node is and what it touches
```

For TypeScript, the language server is the instrument for exact call sites:
use the LSP tool (`findReferences`, `incomingCalls`, `goToDefinition`) to scope
a rename, signature change, or type change **before the first edit** — not
`tsc --noEmit` in a loop afterwards.

**Staleness.** A graph is built against a commit; a feature worktree diverges
from it. Before trusting a negative answer ("nothing else reads this"), check
freshness:

```bash
.specify/presets/graph-first-navigation/scripts/bash/graph-freshness.sh .
```

A stale graph means **rebuild it** (`graphify update`). It does not mean fall
back to grep.

**Grep remains correct for:** literal string searches; comment, log, and prose
text; config values and env-var names; generated, vendored, or minified files;
file-content questions in languages or formats the graph does not model; and
confirming an exact textual occurrence the graph pointed you at.
<!-- END graph-first-navigation -->
EOF
)"

if [[ -f CLAUDE.md ]] && grep -qF "$BEGIN" CLAUDE.md; then
  python3 - "$BLOCK" <<'PYEOF'
import re, sys, pathlib
block = sys.argv[1]
p = pathlib.Path("CLAUDE.md")
text = p.read_text(encoding="utf-8")
new = re.sub(
    r"<!-- BEGIN graph-first-navigation -->.*?<!-- END graph-first-navigation -->",
    lambda _: block,
    text,
    flags=re.S,
)
if new != text:
    p.write_text(new, encoding="utf-8")
PYEOF
  echo "  refreshed the graph-first navigation block in CLAUDE.md"
else
  { [[ -f CLAUDE.md ]] && printf '\n'; printf '%s\n' "$BLOCK"; } >> CLAUDE.md
  echo "  added the graph-first navigation block to CLAUDE.md"
fi
