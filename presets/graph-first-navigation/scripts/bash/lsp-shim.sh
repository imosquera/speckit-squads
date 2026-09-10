#!/usr/bin/env bash
# speckit:graph-first-navigation:lsp-shim — do not edit; reinstalled by post-install.sh
#
# Installed onto the agent's PATH as `typescript-language-server`. It resolves a
# project-local server *at spawn time* rather than freezing a path at install
# time, which is what makes it correct across many repos and their worktrees.
#
# Why a shim at all: the LSP tool spawns `typescript-language-server` as a bare
# command name from the agent process. Its PATH is fixed at startup, there is no
# lsp.path setting, and a hook runs in its own process — so an `export PATH=...`
# from a shell tool can never make the binary findable. Only a name on that PATH
# works. The name is stable; the target must not be.
#
# Resolution order, first hit wins:
#   1. walk up from $PWD                  — the ordinary case
#   2. $CLAUDE_PROJECT_DIR                — when the server is spawned elsewhere
#   3. the repo's main worktree           — a feature worktree has no node_modules
#   4. npx                                — last resort, downloads at run time
set -euo pipefail

ARGS=("$@")

try() {
  local cli="$1/node_modules/typescript-language-server/lib/cli.mjs"
  [[ -f "$cli" ]] || return 1
  exec node "$cli" ${ARGS+"${ARGS[@]}"}
}

command -v node >/dev/null 2>&1 || {
  echo "typescript-language-server shim: 'node' is not on PATH" >&2; exit 127; }

d="$PWD"
while [[ "$d" != / && -n "$d" ]]; do try "$d" || true; d="$(dirname "$d")"; done

[[ -n "${CLAUDE_PROJECT_DIR:-}" ]] && { try "$CLAUDE_PROJECT_DIR" || true; }

# In a worktree, --git-common-dir is the main checkout's .git; its parent is the
# main working tree, which is where node_modules normally lives. Using the
# common dir (never --show-toplevel) is what keeps this worktree-correct.
if common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
  try "$(dirname "$common")" || true
fi

exec npx --yes typescript-language-server ${ARGS+"${ARGS[@]}"}
