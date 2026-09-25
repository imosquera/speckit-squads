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

# `--base --new-only` used to consume the flag as the ref: the scan then ran
# without --new-only against an unresolvable ref, found no change set, and
# exited 4 — an empty-input answer to what is really a usage error.
out="$(python3 "$SCRIPT" scan --base --new-only 2>&1)"; st=$?
check "--base followed by another option is a usage error" 2 "$st" "$out"
grep -q "needs a ref argument" <<<"$out" || { echo "  FAIL --base misuse not named"; echo "$out" | sed 's/^/       /'; fail=1; }

out="$(python3 "$SCRIPT" scan --base= --new-only 2>&1)"; st=$?
check "--base= with an empty ref is a usage error" 2 "$st" "$out"

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

# --- the prompt's exit contract is internally consistent ---------------------
# The command file grants one exception (proceed past a verified exit 4). Every
# other place that states the exit contract must carry that carve-out, or a
# docs-only run cannot satisfy all the mandatory instructions at once and the
# agent stops or loops instead of using the exception.
CMD="$ROOT/presets/parse-dont-validate/commands/speckit.implement.md"
cmd_rule() { # name regex-that-must-match
  if grep -qiE "$2" "$CMD"; then echo "  ok   $1"; else
    echo "  FAIL $1 (no line matching /$2/ in speckit.implement.md)"; fail=1
  fi
}
# Step 3's rerun loop must not demand a zero exit unconditionally.
if grep -qE 'Re-run `scan --new-only` until it exits zero\.' "$CMD"; then
  echo "  FAIL the rerun loop still demands exit zero with no exit-4 carve-out"; fail=1
else
  echo "  ok   the rerun loop admits the verified exit-4 case"
fi
cmd_rule "the rerun loop names exit 4" 'exits zero, or exits .4.'
cmd_rule "the failure policy names the exit-4 exception" 'exit-.4. exception'
# The completion report must not require claiming a zero exit outright.
if grep -qE '^- Whether the parse-don.t-validate scan ran and that it exited zero\.$' "$CMD"; then
  echo "  FAIL the completion report still requires reporting a zero exit only"; fail=1
else
  echo "  ok   the completion report admits the verified exit-4 case"
fi

# TypeScript 7 ships no JS compiler API (issue #113). A package on TS 7 must
# fall through to a TS 5 install further out, and TS 7 alone must exit 3 with
# the install hint instead of crashing on a missing createSourceFile.
echo "TypeScript 7 resolution"
TSR="$(mktemp -d)"
mkdir -p "$TSR/node_modules/typescript" "$TSR/pkg/node_modules/typescript"
echo 'module.exports = { version: "7.0.2" };' > "$TSR/pkg/node_modules/typescript/index.js"
cat > "$TSR/node_modules/typescript/index.js" <<'JS'
module.exports = {
  version: "5.9.3", ScriptTarget: { Latest: 99 }, SyntaxKind: {},
  // Proves this copy was picked; a real AST walk needs the real compiler.
  createSourceFile: () => { throw new Error("resolved-ts5"); },
};
JS
echo 'export const x = 1;' > "$TSR/pkg/a.ts"
job='{"files":[{"path":"pkg/a.ts","parser":false}]}'
out="$(cd "$TSR" && printf '%s' "$job" | node "$TS_HELPER" 2>&1)"
if grep -q resolved-ts5 <<<"$out"; then echo "  ok   TS 7 in the package falls through to TS 5 at the root"
else echo "  FAIL TS 7 in the package did not fall through to TS 5"; echo "$out" | sed 's/^/       /'; fail=1; fi
rm -rf "$TSR/node_modules"
out="$(cd "$TSR" && printf '%s' "$job" | node "$TS_HELPER" 2>&1)"; st=$?
check "TS 7 alone exits 3" 3 "$st" "$out"
if grep -q 'TS 5.x' <<<"$out"; then echo "  ok   the exit-3 message names the TS 5.x requirement"
else echo "  FAIL the exit-3 message does not name the TS 5.x requirement"; echo "$out" | sed 's/^/       /'; fail=1; fi
rm -rf "$TSR"

[[ $fail -eq 0 ]] && echo "test-pdv-changeset: PASS" || echo "test-pdv-changeset: FAIL"
exit $fail
