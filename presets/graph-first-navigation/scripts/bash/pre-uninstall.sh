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
