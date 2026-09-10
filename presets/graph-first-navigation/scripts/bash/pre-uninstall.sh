#!/usr/bin/env bash
# Undo what post-install.sh registered in a consumer project: the PreToolUse
# hook entry and the CLAUDE.md sentinel block. Leaves every other setting and
# every other line of CLAUDE.md untouched.
#
# Usage: pre-uninstall.sh <project-dir>
set -euo pipefail

PROJECT_DIR="${1:?usage: pre-uninstall.sh <project-dir>}"
cd "$PROJECT_DIR"

SETTINGS=".claude/settings.json"

if [[ -f "$SETTINGS" ]] && command -v jq >/dev/null 2>&1 && jq -e . "$SETTINGS" >/dev/null 2>&1; then
  tmp="$(mktemp)"
  jq '
    if .hooks.PreToolUse then
      .hooks.PreToolUse |= map(select(
        ((.hooks // []) | map(.command // "") | join(" ") | contains("graph_first_guard.py")) | not
      ))
      | if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end
      | if (.hooks | length) == 0 then del(.hooks) else . end
    else . end
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  echo "  removed the graph-first PreToolUse hook from $SETTINGS"
fi

if [[ -f CLAUDE.md ]] && grep -qF "<!-- BEGIN graph-first-navigation -->" CLAUDE.md; then
  python3 - <<'PYEOF'
import re, pathlib
p = pathlib.Path("CLAUDE.md")
text = p.read_text(encoding="utf-8")
new = re.sub(
    r"\n*<!-- BEGIN graph-first-navigation -->.*?<!-- END graph-first-navigation -->\n?",
    "\n",
    text,
    flags=re.S,
)
p.write_text(new, encoding="utf-8")
PYEOF
  echo "  removed the graph-first navigation block from CLAUDE.md"
fi

# Undo the graphify-out exclusion: our own info/exclude stanza, and the
# skip-worktree bits we set on files the repo tracks. A half-reversal (dropping
# the exclude but leaving files invisible to `git status`) is worse than none.
COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$COMMON_DIR" ]]; then
  case "$COMMON_DIR" in /*) ;; *) COMMON_DIR="$(cd "$COMMON_DIR" && pwd)" ;; esac
  EXCLUDE="$COMMON_DIR/info/exclude"
  if [[ -f "$EXCLUDE" ]] && grep -qxF 'graphify-out/' "$EXCLUDE"; then
    python3 - "$EXCLUDE" <<'PYEOF'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
p.write_text(re.sub(
    r"\n*# Local knowledge graph.*?\n# A committed graph makes the freshness gate report STALE forever\.\ngraphify-out/\n",
    "\n", t, flags=re.S), encoding="utf-8")
PYEOF
    echo "  removed the graphify-out/ exclusion from $EXCLUDE"
  fi
  SKIPPED="$(git ls-files -v -- graphify-out 2>/dev/null | sed -n 's/^S //p')"
  if [[ -n "$SKIPPED" ]]; then
    printf '%s\n' "$SKIPPED" | tr '\n' '\0' \
      | xargs -0 git update-index --no-skip-worktree -- 2>/dev/null \
      && echo "  cleared skip-worktree on the tracked graphify-out files"
  fi
fi

# The typescript-language-server shim is machine-level and shared by every
# project that installed this preset, so one project's uninstall must not remove
# it. Say where it is instead.
if shim="$(command -v typescript-language-server 2>/dev/null)" && \
   grep -qF "speckit:graph-first-navigation:lsp-shim" "$shim" 2>/dev/null; then
  echo "  note: the language-server shim at $shim is shared across projects — left in place (rm it yourself if nothing else uses it)"
fi
