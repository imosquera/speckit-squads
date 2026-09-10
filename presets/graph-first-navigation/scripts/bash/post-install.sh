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
# Resolve our own directory before cd'ing away — BASH_SOURCE is relative when the
# script is invoked by a relative path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
LSP tool spawns `typescript-language-server` as a bare command name **from the
agent process**, so a copy in `node_modules/.bin` does not count and an unprobed
call fails with `ENOENT`:

```bash
command -v typescript-language-server
```

Not found → do not call the LSP tool. Use the graph and grep, and record which
one the call sites came from. To make it found, re-run this preset's
`post-install.sh`: it installs a shim under that name into a directory on `PATH`,
which resolves a project-local server at spawn time — walking up from the cwd,
then `$CLAUDE_PROJECT_DIR`, then the repo's **main** worktree (a feature worktree
has no `node_modules` of its own), then `npx`. One file, every repo, every
worktree, nothing to go stale.

**`export PATH=…` in a shell tool cannot work** — do not re-add it. Shell state
does not persist between tool calls, and even within one call the LSP tool
resolves the binary against the `PATH` the *agent process* inherited at startup,
which no child shell can change. For the same reason a hook cannot fix it, and
`env` in `.claude/settings.json` takes literal strings with no `${PATH}`
expansion. A name on the inherited `PATH` is the only seam.

Do **not** point that name at a symlink into some project's `node_modules`: it
breaks on the next `npm ci`, and in a *different* repo's worktree the server
would silently resolve that first project's TypeScript instead of this one's.

`npm install` in the checkout is still worth having — with it the shim finds this
project's own server and TypeScript version rather than the main worktree's copy
or an `npx` download.

**A cold language server under-reports across files.**
`typescript-language-server` loads a project lazily, so the *first* cross-file
`findReferences` can answer "2 references across 1 file" for a symbol that has 26
across 4 once the callers are loaded. Warm it first — query inside the target
file, or open the files you expect to be callers — and, exactly as with the
graph, never trust a **negative** answer ("nothing else uses this") without
cross-checking it against `graphify query`.

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

# ------------------------------------------------- language server reachability
# The LSP tool spawns `typescript-language-server` as a bare command name from
# the agent process, whose PATH is fixed at startup. There is no lsp.path
# setting and a hook cannot alter that PATH, so the only working remedy is a
# name on it. Install our shim under that name: it resolves a project-local
# server at spawn time (cwd walk-up, then CLAUDE_PROJECT_DIR, then the repo's
# main worktree, then npx), so one file serves every repo and every worktree
# and never goes stale. A symlink into some project's node_modules would.
SHIM_SRC="$SCRIPT_DIR/lsp-shim.sh"
SHIM_TAG="speckit:graph-first-navigation:lsp-shim"

if [[ ! -f "$SHIM_SRC" ]]; then
  echo "  warn: lsp-shim.sh not found beside post-install.sh — skipping language-server setup" >&2
elif [[ "${SPECKIT_LSP_SHIM:-}" != "force" ]] && \
     existing="$(command -v typescript-language-server 2>/dev/null)" && \
     ! grep -qF "$SHIM_TAG" "$existing" 2>/dev/null; then
  echo "  typescript-language-server already on PATH ($existing) — left alone"
  if [[ -L "$existing" ]]; then
    echo "        (it is a symlink to $(readlink "$existing") — if that points into a project's" >&2
    echo "         node_modules it breaks on the next npm ci and leaks that project's TypeScript" >&2
    echo "         into other repos; SPECKIT_LSP_SHIM=force replaces it with the resolver shim)" >&2
  fi
else
  BIN_DIR="${SPECKIT_LSP_BIN_DIR:-}"
  if [[ -z "$BIN_DIR" ]]; then
    for cand in "$HOME/.local/bin" "$HOME/bin"; do
      case ":$PATH:" in *":$cand:"*) BIN_DIR="$cand"; break ;; esac
    done
  fi
  ON_PATH=1
  if [[ -z "$BIN_DIR" ]]; then BIN_DIR="$HOME/.local/bin"; ON_PATH=0; fi

  mkdir -p "$BIN_DIR"
  install -m 0755 "$SHIM_SRC" "$BIN_DIR/typescript-language-server"
  echo "  installed the typescript-language-server shim -> $BIN_DIR/typescript-language-server"
  if (( ! ON_PATH )); then
    echo "  warn: $BIN_DIR is not on PATH — the LSP tool still cannot find it." >&2
    echo "        Add it in your shell profile (a login-shell one, e.g. ~/.zprofile, so" >&2
    echo "        non-interactive runs such as launchd-scheduled autopilot inherit it)," >&2
    echo "        or re-run with SPECKIT_LSP_BIN_DIR=<a dir already on PATH>." >&2
  fi
fi
