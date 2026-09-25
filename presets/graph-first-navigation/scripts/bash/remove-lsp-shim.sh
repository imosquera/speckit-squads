#!/usr/bin/env bash
# Remove the `typescript-language-server` shim that versions of this preset
# before 2.0.0 installed onto PATH. Sourced by post-install.sh (so a --force
# reinstall cleans up an upgrade) and by pre-uninstall.sh (so an uninstall
# leaves nothing behind); runnable on its own too.
#
# Where to look is where the old post-install.sh put it: $SPECKIT_LSP_BIN_DIR,
# else ~/.local/bin or ~/bin, plus whatever `command -v` resolves. A file is
# removed only when it is a regular file carrying the old shim's marker line —
# a real typescript-language-server (or a symlink into some project's
# node_modules) at the same path is never ours to delete. Best effort: always
# returns 0.

speckit_remove_lsp_shim() {
  local tag="speckit:graph-first-navigation:lsp-shim"
  local cand seen=":" found
  local -a cands=()
  [[ -n "${SPECKIT_LSP_BIN_DIR:-}" ]] && cands+=("$SPECKIT_LSP_BIN_DIR/typescript-language-server")
  cands+=("$HOME/.local/bin/typescript-language-server" "$HOME/bin/typescript-language-server")
  if found="$(command -v typescript-language-server 2>/dev/null)"; then cands+=("$found"); fi
  for cand in "${cands[@]}"; do
    case "$seen" in *":$cand:"*) continue ;; esac
    seen="$seen$cand:"
    [[ -f "$cand" && ! -L "$cand" ]] || continue
    head -n 5 "$cand" 2>/dev/null | grep -qF "$tag" || continue
    if rm -f "$cand" 2>/dev/null; then
      echo "  removed the retired typescript-language-server shim at $cand"
    else
      echo "  warn: could not remove the retired typescript-language-server shim at $cand — rm it yourself" >&2
    fi
  done
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  speckit_remove_lsp_shim
else
  speckit_remove_lsp_shim || true
fi
