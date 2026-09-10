#!/usr/bin/env bash
# Check for parse_dont_validate.py's change-set handling:
#   1. the scan anchors at the git worktree root (it used to collapse to the
#      untracked files below the cwd when run from a subdirectory);
#   2. --new-only subtracts findings that already reproduce on the base ref.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/presets/parse-dont-validate/scripts/python/parse_dont_validate.py"
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

[[ $fail -eq 0 ]] && echo "test-pdv-changeset: PASS" || echo "test-pdv-changeset: FAIL"
exit $fail
