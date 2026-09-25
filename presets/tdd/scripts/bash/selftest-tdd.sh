#!/usr/bin/env bash
# tdd preset: selftest-tdd.sh
# Self-contained test for check-tests-accompany.sh. No test framework required.
#
# Usage: ./presets/tdd/scripts/bash/selftest-tdd.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/check-tests-accompany.sh"
[[ -x "$CHECK" ]] || { echo "error: not executable: $CHECK" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

# case_ <name> <want-rc> <file>... — fresh repo on main, feature branch, files
# created (committed if prefixed "c:", untracked otherwise), then the check runs.
case_() {
    local name="$1" want="$2" dir="$WORK/$1" rc f
    shift 2
    git init -q -b main "$dir" && cd "$dir" || exit 2
    git -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
    git checkout -q -b feature
    for f in "$@"; do
        local p="${f#c:}"
        mkdir -p "$(dirname "$p")" && echo x > "$p"
        [[ "$f" == c:* ]] && git add "$p" && git -c user.name=t -c user.email=t@t commit -q -m "$p"
    done
    "$CHECK" > "$WORK/$name.out" 2>&1
    rc=$?
    if [[ "$rc" -eq "$want" ]]; then echo "PASS: $name"
    else echo "FAIL: $name — want rc=$want, got rc=$rc"; sed 's/^/    /' "$WORK/$name.out"; FAILURES=$((FAILURES + 1)); fi
    cd "$WORK" || exit 2
}

case_ empty                4
case_ prod-only            1 src/app.py
case_ prod-committed-only  1 c:src/app.ts
case_ prod-and-pytest      0 src/app.py tests/test_app.py
case_ prod-and-jest        0 c:src/app.ts src/app.test.ts
case_ prod-and-go          0 pkg/x.go pkg/x_test.go
case_ prod-and-dunder      0 lib/a.js lib/__tests__/a.js
case_ tests-only           0 tests/test_new.py
case_ docs-only            0 README.md docs/guide.md
case_ config-only          0 package.json

# A bad --base is a usage error, never a pass.
cd "$WORK/prod-only" && { "$CHECK" --base no-such-ref >/dev/null 2>&1; rc=$?; }
if [[ "$rc" -eq 2 ]]; then echo "PASS: bad-base"; else echo "FAIL: bad-base — got rc=$rc"; FAILURES=$((FAILURES + 1)); fi

[[ "$FAILURES" -eq 0 ]] && echo "all passed" || { echo "$FAILURES failure(s)"; exit 1; }
