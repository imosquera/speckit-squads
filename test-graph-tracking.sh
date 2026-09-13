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

# post-install.sh also registers a settings.json hook, a CLAUDE.md block and a
# language-server shim; confine all of that to the temp dir.
mkdir -p "$TMP/home" "$TMP/bin" "$TMP/fakebin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/fakebin/graphify"
chmod +x "$TMP/fakebin/graphify"
run_post() { HOME="$TMP/home" SPECKIT_LSP_BIN_DIR="$TMP/bin" bash "$POST" "$1" 2>&1; }
run_pre()  { HOME="$TMP/home" bash "$PRE" "$1" 2>&1; }
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

if [[ $fail -eq 0 ]]; then echo "graph tracking check: ok"; else
  echo "graph tracking check: FAILED" >&2; fi
exit $fail
