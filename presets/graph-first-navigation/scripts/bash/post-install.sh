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

# ------------------------------------------------- keep graphify-out out of git
# The graph is local, per-checkout, and rebuilt constantly. Committed, it is
# stale by construction (every commit moves HEAD past its built_at_commit) and
# every rebuild dirties the tree, which is exactly the hand-scrub the freshness
# gate kept demanding. Excluding it here makes the rebuild free.
#   * untracked output      -> the repo's info/exclude (shared by every worktree)
#   * already-tracked files -> skip-worktree in this checkout's index
# Best effort: a project that deliberately commits its graph is not our call to
# break, and neither failure is worth aborting an install over.
COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$COMMON_DIR" ]]; then
  case "$COMMON_DIR" in
    /*) ;;
    *) COMMON_DIR="$(cd "$COMMON_DIR" && pwd)" ;;
  esac
  EXCLUDE="$COMMON_DIR/info/exclude"
  mkdir -p "$COMMON_DIR/info" 2>/dev/null || true
  if ! grep -qxF 'graphify-out/' "$EXCLUDE" 2>/dev/null; then
    {
      echo ''
      echo '# Local knowledge graph — rebuilt per checkout, never committed.'
      echo '# A committed graph makes the freshness gate report STALE forever.'
      echo 'graphify-out/'
    } >> "$EXCLUDE" 2>/dev/null && echo "  excluded graphify-out/ in $EXCLUDE"
  fi

  TRACKED="$(git ls-files -- graphify-out 2>/dev/null)"
  if [[ -n "$TRACKED" ]]; then
    if printf '%s\n' "$TRACKED" | tr '\n' '\0' \
         | xargs -0 git update-index --skip-worktree -- 2>/dev/null; then
      echo "  skip-worktree'd $(printf '%s\n' "$TRACKED" | wc -l | tr -d ' ') tracked graphify-out files"
      echo "        (they are still committed — \`git rm -r --cached graphify-out\` to finish the job)"
    else
      echo "  warn: could not skip-worktree the tracked graphify-out files" >&2
    fi
  fi
fi

# ---------------------------------------------------------------- CLAUDE.md
BEGIN="<!-- BEGIN graph-first-navigation -->"
END="<!-- END graph-first-navigation -->"

# NOTE: this heredoc sits inside $( ), where bash still scans the body for
# quotes — keep the apostrophes in the prose below EVEN in number, or the
# parser reports a syntax error a hundred lines further down.
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

Four verdicts, and only one of them is a demand:

| Verdict | Exit | Means |
| --- | --- | --- |
| `FRESH` | 0 | the graph matches HEAD and the tree is clean — trust it |
| `STALE` | 1 | provably behind — **rebuild**, never fall back to grep |
| `ABSENT` | 2 | no graph here — build one; grep only until you do |
| `UNKNOWN` | 3 | freshness is *unanswerable*, not failed — an older build recording no `built_at_commit`, or no HEAD to compare against. The graph may well be current; rebuild to get a comparable one, and until then treat only **negative** answers as unverified |

Every verdict prints the remedy with its path (`graphify update <checkout>`).
Run it exactly as printed: a bare `graphify update` rebuilds whichever project
the CWD resolves to, which from a worktree has already been the wrong one.

A graph is local to its checkout — keep it out of version control. Installing this
preset excludes `graphify-out/` in the repo's `info/exclude` and, if the repo
already tracks a graph, marks those files `skip-worktree` in this checkout, so a
rebuild costs nothing and never has to be hand-scrubbed before a commit. A
committed `graphify-out/` is stale by construction: every commit moves HEAD past
its `built_at_commit`. `/speckit-git-worktree` and `/speckit-git-feature` do the
same at worktree creation and build the graph there (`seed-graph.sh`, skippable
with `SPECKIT_SKIP_GRAPH=1`).

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
