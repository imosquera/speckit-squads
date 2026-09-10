#!/usr/bin/env bash
# Check that install-deps.sh installs a fresh worktree's dependencies at
# creation, and — more importantly — that it stays out of the way: no manifest
# is a silent no-op, a failing package manager never fails the caller, and a
# directory the base checkout never installed is never installed here.
#
# The script runs on every worktree creation, so a false positive costs a
# needless install on every feature and a hard failure costs the worktree
# itself (issue #51).
#
# Usage: ./test-worktree-deps.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/extensions/git/scripts/bash/install-deps.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

check() { # check <what> <desc> <expected> <actual>
  if [[ "$3" == "$4" ]]; then echo "  ok: $1 $2"; else
    echo "  FAIL: $1 $2 — expected '$3', got '$4'" >&2; fail=1
  fi
}
contains() {
  if grep -qF -- "$2" <<<"$3"; then echo "  ok: $1 mentions '$2'"; else
    echo "  FAIL: $1 does not mention '$2'" >&2
    printf '%s\n' "$3" | sed 's/^/        /' >&2; fail=1
  fi
}
absent() {
  if grep -qF -- "$2" <<<"$3"; then
    echo "  FAIL: $1 unexpectedly mentions '$2'" >&2; fail=1
  else echo "  ok: $1 does not mention '$2'"; fi
}

# A repo with a base checkout and one linked worktree. $1 = extra setup shell.
make_repo() { # make_repo <name>
  local repo="$TMP/$1" wt="$TMP/$1.wt"
  mkdir -p "$repo" && git -C "$repo" init -q
  git -C "$repo" config user.email t@t && git -C "$repo" config user.name t
  echo hi > "$repo/README.md" && git -C "$repo" add -A && git -C "$repo" commit -qm one
  echo "$repo"
}
add_wt() { # add_wt <repo> -> worktree path
  local repo="$1" wt="$1.wt"
  git -C "$repo" worktree add -q -b "feat-$(basename "$repo")" "$wt" >/dev/null 2>&1
  echo "$wt"
}

# A fake package manager that records its invocations, or fails on demand.
fake_bin() { # fake_bin <dir> <name> <exit-code>
  mkdir -p "$1"
  cat > "$1/$2" <<EOF
#!/usr/bin/env bash
echo "\$(pwd) $2 \$*" >> "$TMP/calls.log"
echo "boom" >&2
exit $3
EOF
  chmod +x "$1/$2"
}

echo "1. no manifest anywhere -> silent no-op, exit 0"
REPO="$(make_repo nomanifest)"; WT="$(add_wt "$REPO")"
out="$("$SCRIPT" "$WT" 2>&1)"; rc=$?
check no-manifest "exit code" 0 "$rc"
check no-manifest "output" "" "$out"

echo "2. manifest the base checkout never installed -> not installed here"
REPO="$(make_repo uninstalled)"
echo '{"name":"x"}' > "$REPO/package.json"; : > "$REPO/package-lock.json"
git -C "$REPO" add -A && git -C "$REPO" commit -qm pkg
WT="$(add_wt "$REPO")"
: > "$TMP/calls.log"
BIN="$TMP/bin2"; fake_bin "$BIN" npm 0
out="$(PATH="$BIN:$PATH" "$SCRIPT" "$WT" 2>&1)"; rc=$?
check uninstalled "exit code" 0 "$rc"
check uninstalled "ran no installer" "" "$(cat "$TMP/calls.log")"

echo "3. base has node_modules -> the lockfile picks the package manager"
REPO="$(make_repo installed)"
echo '{"name":"x"}' > "$REPO/package.json"; : > "$REPO/package-lock.json"
mkdir -p "$REPO/web"; echo '{"name":"w"}' > "$REPO/web/package.json"
: > "$REPO/web/pnpm-lock.yaml"
mkdir -p "$REPO/docs"; echo '{"name":"d"}' > "$REPO/docs/package.json"
git -C "$REPO" add -A && git -C "$REPO" commit -qm pkgs
mkdir -p "$REPO/node_modules" "$REPO/web/node_modules"   # docs/ never installed
WT="$(add_wt "$REPO")"
: > "$TMP/calls.log"
BIN="$TMP/bin3"; fake_bin "$BIN" npm 0; fake_bin "$BIN" pnpm 0
out="$(PATH="$BIN:$PATH" "$SCRIPT" "$WT" 2>&1)"; rc=$?
calls="$(cat "$TMP/calls.log")"
check installed "exit code" 0 "$rc"
contains "root install" "$WT npm ci" "$calls"
contains "workspace install" "$WT/web pnpm install --frozen-lockfile" "$calls"
absent "docs (base never installed it)" "$WT/docs" "$calls"
contains summary "installed:" "$out"

echo "4. a failing install reports but does not fail the caller"
REPO="$(make_repo failing)"
echo '{"name":"x"}' > "$REPO/package.json"; : > "$REPO/package-lock.json"
git -C "$REPO" add -A && git -C "$REPO" commit -qm pkg
mkdir -p "$REPO/node_modules"
WT="$(add_wt "$REPO")"
BIN="$TMP/bin4"; fake_bin "$BIN" npm 1
out="$(PATH="$BIN:$PATH" "$SCRIPT" "$WT" 2>&1)"; rc=$?
check failing "exit code" 0 "$rc"
contains failing "FAILED in" "$out"

echo "5. package manager missing from PATH -> named, not run, still exit 0"
REPO="$(make_repo notool)"
echo '{"name":"x"}' > "$REPO/package.json"; : > "$REPO/bun.lockb"
git -C "$REPO" add -A && git -C "$REPO" commit -qm pkg
mkdir -p "$REPO/node_modules"
WT="$(add_wt "$REPO")"
out="$(PATH="/nonexistent-bin-dir:/usr/bin:/bin" "$SCRIPT" "$WT" 2>&1)"; rc=$?
check no-tool "exit code" 0 "$rc"
contains no-tool "bun" "$out"

echo "6. SPECKIT_SKIP_INSTALL=1 skips everything"
: > "$TMP/calls.log"
BIN="$TMP/bin6"; fake_bin "$BIN" npm 0
out="$(SPECKIT_SKIP_INSTALL=1 PATH="$BIN:$PATH" "$SCRIPT" "$TMP/installed.wt" 2>&1)"; rc=$?
check skip "exit code" 0 "$rc"
contains skip "SPECKIT_SKIP_INSTALL=1" "$out"
check skip "ran no installer" "" "$(cat "$TMP/calls.log")"

echo "7. a missing / non-worktree path is a warning, never an error"
out="$("$SCRIPT" "$TMP/does-not-exist" 2>&1)"; rc=$?
check missing-path "exit code" 0 "$rc"
contains missing-path "no such worktree" "$out"
out="$("$SCRIPT" 2>&1)"; rc=$?
check no-arg "exit code" 0 "$rc"

echo "8. the base checkout itself is never installed into"
: > "$TMP/calls.log"
BIN="$TMP/bin8"; fake_bin "$BIN" npm 0
out="$(PATH="$BIN:$PATH" "$SCRIPT" "$TMP/installed" 2>&1)"; rc=$?
check base-checkout "exit code" 0 "$rc"
check base-checkout "ran no installer" "" "$(cat "$TMP/calls.log")"

if [[ $fail -eq 0 ]]; then echo "worktree deps check: ok"; else
  echo "worktree deps check: FAILED" >&2; fi
exit $fail
