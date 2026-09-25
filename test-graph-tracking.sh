#!/usr/bin/env bash
# Check how graph-first-navigation's post-install.sh and the git extension's
# seed-graph.sh treat graphify-out/ in version control — the two copies of one
# rule, kept in step because they live in separate installable script trees.
#
#   untracked graph -> excluded in info/exclude (a rebuild is never committed)
#   tracked graph   -> the repo's deliberate choice: no exclude, no skip-worktree,
#                      and an earlier install that hid it is healed
#
# Every `./install.sh --force` used to re-hide a graph the consumer committed on
# purpose, so each run must leave the tracked case visible and idempotent.
#
# Usage: ./test-graph-tracking.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POST="$HERE/presets/graph-first-navigation/scripts/bash/post-install.sh"
PRE="$HERE/presets/graph-first-navigation/scripts/bash/pre-uninstall.sh"
SEED="$HERE/extensions/git/scripts/bash/seed-graph.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

ok()   { echo "  ok: $1"; }
bad()  { echo "  FAIL: $1" >&2; fail=1; }
expect() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# post-install.sh also registers a settings.json hook and a CLAUDE.md block, and
# both scripts remove the language-server shim a pre-2.0.0 install left on PATH;
# confine all of that to the temp dir. PATH drops every directory holding a
# typescript-language-server, so `command -v` can never reach this machine's own.
mkdir -p "$TMP/home" "$TMP/bin" "$TMP/fakebin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/fakebin/graphify"
chmod +x "$TMP/fakebin/graphify"
SAFE_PATH=""
IFS=: read -r -a _dirs <<<"$PATH"
for _d in "${_dirs[@]}"; do
  [[ -n "$_d" && ! -e "$_d/typescript-language-server" ]] && SAFE_PATH="${SAFE_PATH:+$SAFE_PATH:}$_d"
done
run_post() { PATH="$SAFE_PATH" HOME="$TMP/home" SPECKIT_LSP_BIN_DIR="$TMP/bin" bash "$POST" "$1" 2>&1; }
run_pre()  { PATH="$SAFE_PATH" HOME="$TMP/home" SPECKIT_LSP_BIN_DIR="$TMP/bin" bash "$PRE" "$1" 2>&1; }
run_seed() { PATH="$TMP/fakebin:$PATH" bash "$SEED" "$1" 2>&1; }

mkrepo() { # mkrepo <dir> [tracked]
  mkdir -p "$1" && git -C "$1" init -q
  git -C "$1" config user.email t@t && git -C "$1" config user.name t
  echo hi > "$1/a.txt" && git -C "$1" add a.txt
  if [[ "${2:-}" == tracked ]]; then
    mkdir -p "$1/graphify-out" && echo '{}' > "$1/graphify-out/graph.json"
    git -C "$1" add graphify-out
  fi
  git -C "$1" commit -qm one
}
exclude_of() { echo "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)/info/exclude"; }
stanza_count() { grep -cxF 'graphify-out/' "$(exclude_of "$1")" 2>/dev/null || true; }
skipped_count() { git -C "$1" ls-files -v -- graphify-out | grep -c '^S ' || true; }
plant_old_install() { # what an earlier install left behind in a tracked repo
  printf '%s\n' '# a line the user wrote' '*.log' '' \
    '# Local knowledge graph — rebuilt per checkout, never committed.' \
    '# A committed graph makes the freshness gate report STALE forever.' \
    'graphify-out/' >> "$(exclude_of "$1")"
  git -C "$1" ls-files -- graphify-out | tr '\n' '\0' \
    | xargs -0 git -C "$1" update-index --skip-worktree --
}

for who in post-install seed-graph; do
  run() { if [[ $who == post-install ]]; then run_post "$1"; else run_seed "$1"; fi; }
  # seed-graph is exercised in a linked worktree, where it really runs.
  target() { if [[ $who == post-install ]]; then echo "$1"; else
    git -C "$1" worktree add -q "$1.wt" -b wt >/dev/null 2>&1; echo "$1.wt"; fi; }

  echo "$who: untracked graph -> excluded, idempotently"
  R="$TMP/$who-untracked"; mkrepo "$R"; T="$(target "$R")"
  run "$T" >/dev/null; run "$T" >/dev/null
  expect "exclude stanza written once" '[[ "$(stanza_count "$T")" == 1 ]]'

  echo "$who: tracked graph -> no exclude, no skip-worktree"
  R="$TMP/$who-tracked"; mkrepo "$R" tracked; T="$(target "$R")"
  out="$(run "$T")"; run "$T" >/dev/null
  expect "no exclude stanza" '[[ "$(stanza_count "$T")" == 0 ]]'
  expect "no skip-worktree" '[[ "$(skipped_count "$T")" == 0 ]]'
  expect "says it was left tracked" 'grep -qF "left tracked" <<<"$out"'
  expect "no .graphify_root warning" '! grep -qF "WARNING" <<<"$out"'

  echo "$who: tracked graph hidden by an earlier install -> healed"
  R="$TMP/$who-healed"; mkrepo "$R" tracked; T="$(target "$R")"
  plant_old_install "$T"
  expect "precondition: hidden" '[[ "$(skipped_count "$T")" == 1 && "$(stanza_count "$T")" == 1 ]]'
  run "$T" >/dev/null
  expect "our stanza removed" '[[ "$(stanza_count "$T")" == 0 ]]'
  expect "user exclude lines kept" 'grep -qxF "*.log" "$(exclude_of "$T")"'
  expect "skip-worktree cleared" '[[ "$(skipped_count "$T")" == 0 ]]'

  echo "$who: tracked graphify-out/.graphify_root -> warning, never untracked"
  R="$TMP/$who-root"; mkrepo "$R" tracked
  echo "$R" > "$R/graphify-out/.graphify_root"
  git -C "$R" add -f graphify-out/.graphify_root && git -C "$R" commit -qm root
  T="$(target "$R")"
  out="$(run "$T")"
  expect "warns with the fix" 'grep -qF "git rm --cached graphify-out/.graphify_root" <<<"$out"'
  expect "still tracked" '[[ -n "$(git -C "$T" ls-files -- graphify-out/.graphify_root)" ]]'
done

echo "pre-uninstall: removes the current stanza wording too"
R="$TMP/pre"; mkrepo "$R"
run_post "$R" >/dev/null
expect "precondition: excluded" '[[ "$(stanza_count "$R")" == 1 ]]'
run_pre "$R" >/dev/null
expect "stanza removed" '[[ "$(stanza_count "$R")" == 0 ]]'

# The language server is gone (issue #114): nothing may install a shim, and both
# scripts remove one an older install left — but never a real server binary.
plant_shim() { # plant_shim <path>: what a pre-2.0.0 post-install.sh wrote
  mkdir -p "$(dirname "$1")"
  printf '%s\n' '#!/usr/bin/env bash' \
    '# speckit:graph-first-navigation:lsp-shim — do not edit; reinstalled by post-install.sh' \
    'exit 0' > "$1"; chmod +x "$1"
}
plant_real() { mkdir -p "$(dirname "$1")"; printf '#!/usr/bin/env node\n// real server\n' > "$1"; chmod +x "$1"; }

echo "post-install: installs no shim, and removes an old one"
R="$TMP/shim-post"; mkrepo "$R"
out="$(run_post "$R")"
expect "no shim installed" '[[ ! -e "$TMP/bin/typescript-language-server" && ! -e "$TMP/home/.local/bin/typescript-language-server" ]]'
expect "hook matcher has no Edit|Write" '! grep -qF "Edit" "$R/.claude/settings.json" || ! command -v jq >/dev/null'
expect "seeded CLAUDE.md names no LSP tool" '! grep -qiE "lsp|findReferences|language.server" "$R/CLAUDE.md"'
plant_shim "$TMP/bin/typescript-language-server"
plant_shim "$TMP/home/.local/bin/typescript-language-server"
out="$(run_post "$R")"
expect "old shim removed from SPECKIT_LSP_BIN_DIR" '[[ ! -e "$TMP/bin/typescript-language-server" ]]'
expect "old shim removed from ~/.local/bin" '[[ ! -e "$TMP/home/.local/bin/typescript-language-server" ]]'
expect "says so" 'grep -qF "removed the retired typescript-language-server shim" <<<"$out"'

echo "pre-uninstall: removes an old shim, never a real server"
R="$TMP/shim-pre"; mkrepo "$R"; run_post "$R" >/dev/null
plant_shim "$TMP/bin/typescript-language-server"
plant_real "$TMP/home/bin/typescript-language-server"
run_pre "$R" >/dev/null
expect "old shim removed" '[[ ! -e "$TMP/bin/typescript-language-server" ]]'
expect "real server kept" '[[ -f "$TMP/home/bin/typescript-language-server" ]]'
rm -f "$TMP/home/bin/typescript-language-server"

if [[ $fail -eq 0 ]]; then echo "graph tracking check: ok"; else
  echo "graph tracking check: FAILED" >&2; fi
exit $fail
