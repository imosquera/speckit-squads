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
              matcher: "Grep|Glob|Bash|Edit|Write|MultiEdit",
              hooks: [{
                type: "command",
                command: $cmd,
                timeout: 10,
                statusMessage: "Graph-first check"
              }]
            }]
        )
    ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    echo "  registered PreToolUse hook (Grep|Glob|Bash|Edit|Write|MultiEdit) in $SETTINGS"
  fi
fi

# ---------------------------------------------------------------- CLAUDE.md
BEGIN="<!-- BEGIN graph-first-navigation -->"
END="<!-- END graph-first-navigation -->"

BLOCK="$(cat <<'EOF'
<!-- BEGIN graph-first-navigation -->
## Navigating this codebase

**The knowledge graph is the first instrument for any question about structure,
callers, dependencies, imports, or file relationships — in every checkout,
including a fresh worktree that has no `graphify-out/` yet.** The graph was
built by parsing, so it answers those definitively; grep is text matching, and
the slower, noisier instrument for exactly the questions the graph exists to
answer.

| Question | Instrument |
| --- | --- |
| structure, callers, dependents, imports, "what reads this" | `graphify query "what calls <symbol>"` |
| how two modules connect | `graphify path "<A>" "<B>"` |
| what is this node, what does it touch | `graphify explain "<symbol>"` |
| TypeScript rename / signature change / type change | LSP `findReferences`, `incomingCalls`, `goToDefinition` — **before the first edit**, not `tsc --noEmit` in a loop afterwards (probe for it first, below) |
| exact string, comment/log/prose text, config value, env var name, route path, generated or vendored file | grep — correct as-is |

**Missing or stale means BUILD, never grep.**

```bash
graphify update /abs/path/to/this/checkout
```

Always pass the path. A bare `graphify update` rebuilds whichever project the
CWD resolves to — from a worktree that is regularly another worktree's graph.

**The language server has to be reachable before it can be the instrument.** The
LSP tool spawns `typescript-language-server` as a bare command name, so a copy in
`node_modules/.bin` does not count and an unprobed call fails with `ENOENT`:

```bash
command -v typescript-language-server
```

Not found → do not call the LSP tool. Use the graph and grep, and record which
one the call sites came from. To make it found, project-locally (never
`npm i -g`):

```bash
cd "$(git rev-parse --show-toplevel)"
npm install
export PATH="$PWD/node_modules/.bin:$PATH"
```

The `npm install` is load-bearing in a worktree, which starts with no root
`node_modules` at all: without it even `npx typescript-language-server`
"succeeds" only by downloading the package at run time.

**Staleness.** A graph is built against a commit; a feature worktree diverges
from it. Before trusting a negative answer ("nothing else reads this"), check
freshness:

```bash
.specify/presets/graph-first-navigation/scripts/bash/graph-freshness.sh .
```

STALE means rebuild. It does not mean fall back to grep.

A worktree's graph is local — keep it out of version control. `/speckit-git-worktree`
and `/speckit-git-feature` build it at creation time (`seed-graph.sh`, skippable
with `SPECKIT_SKIP_GRAPH=1`) and arrange for git not to see it, because a
committed `graphify-out/` makes the freshness gate report STALE forever.

A PreToolUse hook reminds — never blocks — when a Grep/Glob/`rg` looks
structural, when the checkout has no graph, and on the first TypeScript edit of
a session.
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
