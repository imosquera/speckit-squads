#!/usr/bin/env bash
# Check for parse_dont_validate.py's change-set handling:
#   1. the scan anchors at the git worktree root (it used to collapse to the
#      untracked files below the cwd when run from a subdirectory);
#   2. --new-only subtracts findings that already reproduce on the base ref;
#   3. a scan that examined ZERO files never exits like a clean pass — a typo'd
#      flag, a path that resolves to nothing, a non-repo cwd and an empty change
#      set each get their own non-zero exit (issue #50), and the Node helper
#      refuses a job it cannot use instead of printing an empty findings list.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$ROOT/presets/parse-dont-validate/scripts/python/parse_dont_validate.py"
TS_HELPER="$ROOT/presets/parse-dont-validate/scripts/node/pdv_ts_scan.cjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
check() { # name expected_status actual_status extra
  if [[ "$2" == "$3" ]]; then echo "  ok   $1"; else
    echo "  FAIL $1 (expected exit $2, got $3)"; echo "$4" | sed 's/^/       /'; fail=1
  fi
}

cd "$TMP"
git init -q -b main .
git config user.email t@t; git config user.name t
mkdir -p functions/src pkg
# pre-existing finding on main
cat > pkg/old.py <<'PY'
from typing import Any
def handle(x: Any) -> None: ...
PY
git add -A && git commit -qm base

git checkout -qb feature
# new finding, committed, in a subdirectory
cat > functions/src/new.py <<'PY'
from typing import Any
def added(y: Any) -> None: ...
PY
# and a new finding still in the working tree, touching the pre-existing file
cat >> pkg/old.py <<'PY'
def later(z: Any) -> None: ...
PY
git add -A && git commit -qm work

echo "test-pdv-changeset"

out="$(cd functions && python3 "$SCRIPT" scan --base main 2>&1)"; st=$?
check "scan from a subdirectory sees the whole change set" 1 "$st" "$out"
for f in functions/src/new.py pkg/old.py; do
  grep -q "$f" <<<"$out" || { echo "  FAIL missing $f in scan output"; echo "$out" | sed 's/^/       /'; fail=1; }
done

out="$(cd functions && python3 "$SCRIPT" scan --base main --new-only 2>&1)"; st=$?
check "--new-only still fails on findings this branch added" 1 "$st" "$out"
grep -q "def added" <<<"$out" || { echo "  FAIL --new-only dropped a new finding"; fail=1; }
grep -q "def handle" <<<"$out" && { echo "  FAIL --new-only kept a pre-existing finding"; fail=1; }
grep -q "def later" <<<"$out" || { echo "  FAIL --new-only dropped a new finding in a pre-existing file"; fail=1; }
grep -q "ignored 1 pre-existing" <<<"$out" || { echo "  FAIL no pre-existing count reported"; echo "$out" | sed 's/^/       /'; fail=1; }

# a branch that only shifts a pre-existing finding down: still reported by
# scan, still clean under --new-only (fingerprints ignore line numbers).
git checkout -q main && git checkout -qb shuffle
printf '# a comment\n%s' "$(cat pkg/old.py)" > pkg/old.py
git commit -qam shuffle
out="$(python3 "$SCRIPT" scan --base main 2>&1)"; st=$?
check "plain scan reports the shifted pre-existing finding" 1 "$st" "$out"
out="$(python3 "$SCRIPT" scan --base main --new-only 2>&1)"; st=$?
check "--new-only is clean when the branch only moved existing code" 0 "$st" "$out"

# --- a scan that examined nothing is never a clean pass (issue #50) ----------
git checkout -q main && git checkout -qb empty
mkdir -p docs && echo hello > docs/readme.md && git add -A && git commit -qm docs

out="$(python3 "$SCRIPT" scan --base main --nwe-only 2>&1)"; st=$?
check "a typo'd flag is a usage error, not a clean scan" 2 "$st" "$out"
grep -q "unknown option" <<<"$out" || { echo "  FAIL typo'd flag not named"; fail=1; }

out="$(python3 "$SCRIPT" scan --base 2>&1)"; st=$?
check "--base with no ref is a usage error" 2 "$st" "$out"

out="$(python3 "$SCRIPT" scan nosuchfile.ts 2>&1)"; st=$?
check "paths that resolve to nothing are a hard error" 3 "$st" "$out"

out="$(cd / && python3 "$SCRIPT" scan 2>&1)"; st=$?
check "no change set outside a git worktree is a hard error" 3 "$st" "$out"

out="$(python3 "$SCRIPT" scan --base main 2>&1)"; st=$?
check "an empty change set exits 4, not 0" 4 "$st" "$out"
grep -q "not a clean scan" <<<"$out" || { echo "  FAIL empty change set not called out"; echo "$out" | sed 's/^/       /'; fail=1; }

if command -v node >/dev/null 2>&1; then
  out="$(node "$TS_HELPER" some/file.ts </dev/null 2>&1)"; st=$?
  check "the Node helper refuses file arguments" 2 "$st" "$out"
  grep -q '\[\]' <<<"$out" && { echo "  FAIL helper printed an empty findings list"; fail=1; }
  out="$(printf '' | node "$TS_HELPER" 2>&1)"; st=$?
  check "the Node helper refuses an empty job" 2 "$st" "$out"
  out="$(printf '{"files":[]}' | node "$TS_HELPER" 2>&1)"; st=$?
  check "the Node helper refuses a zero-file job" 2 "$st" "$out"
else
  echo "  skip node helper checks (node not on PATH)"
fi

[[ $fail -eq 0 ]] && echo "test-pdv-changeset: PASS" || echo "test-pdv-changeset: FAIL"
exit $fail
