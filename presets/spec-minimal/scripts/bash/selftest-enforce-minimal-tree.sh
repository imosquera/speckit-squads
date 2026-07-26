#!/usr/bin/env bash
# spec-minimal preset: selftest-enforce-minimal-tree.sh
# Self-contained test for enforce-minimal-tree.sh. No test framework required.
#
# Usage: ./presets/spec-minimal/scripts/bash/selftest-enforce-minimal-tree.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENFORCE="$HERE/enforce-minimal-tree.sh"

if [[ ! -x "$ENFORCE" ]]; then
    echo "error: not executable: $ENFORCE" >&2
    exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
CASE=""

start() { CASE="$1"; }
pass() { echo "PASS: $CASE"; }
fail() { echo "FAIL: $CASE — $1"; FAILURES=$((FAILURES + 1)); }

# Make a fresh feature dir with the baseline allowed files.
mkfeature() {
    local dir="$WORK/$1"
    rm -rf "$dir"
    mkdir -p "$dir"
    printf '# Spec\n\nsome spec\n' > "$dir/spec.md"
    printf '# Plan\n\nsome plan\n' > "$dir/plan.md"
    printf '# Tasks\n\n- T001\n' > "$dir/tasks.md"
    echo "$dir"
}

# run <dir> -> sets RC, OUT, ERR
run() {
    OUT="$("$ENFORCE" "$1" 2>"$WORK/.stderr")"
    RC=$?
    ERR="$(cat "$WORK/.stderr")"
}

# ---------------------------------------------------------------- case 1
start "clean tree => exit 0, nothing changed"
d="$(mkfeature clean)"
before="$(cd "$d" && ls -A | sort)"
plan_before="$(cat "$d/plan.md")"
run "$d"
if [[ $RC -ne 0 ]]; then
    fail "expected exit 0, got $RC ($ERR)"
elif [[ "$(cd "$d" && ls -A | sort)" != "$before" ]]; then
    fail "tree changed"
elif [[ "$(cat "$d/plan.md")" != "$plan_before" ]]; then
    fail "plan.md changed"
elif [[ "$OUT" != ok:* ]]; then
    fail "expected an 'ok:' line, got: $OUT"
else
    pass
fi

# ---------------------------------------------------------------- case 2
start "research.md with content => inlined + removed"
d="$(mkfeature research)"
printf '# Research\n\nWe picked sqlite because it is boring.\n' > "$d/research.md"
run "$d"
if [[ $RC -ne 0 ]]; then
    fail "expected exit 0, got $RC ($ERR)"
elif [[ -e "$d/research.md" ]]; then
    fail "research.md still on disk"
elif ! grep -q '<!-- BEGIN: spec-minimal inlined research.md -->' "$d/plan.md"; then
    fail "BEGIN sentinel missing from plan.md"
elif ! grep -q '<!-- END: spec-minimal inlined research.md -->' "$d/plan.md"; then
    fail "END sentinel missing from plan.md"
elif ! grep -q '## Inlined from research.md' "$d/plan.md"; then
    fail "heading missing from plan.md"
elif ! grep -q 'boring' "$d/plan.md"; then
    fail "research content missing from plan.md"
elif ! grep -q 'some plan' "$d/plan.md"; then
    fail "original plan.md content lost"
else
    pass
fi

# ---------------------------------------------------------------- case 3
start "contracts/ dir with two nested files => both inlined with ### headings"
d="$(mkfeature contracts)"
mkdir -p "$d/contracts/api"
printf 'openapi: 3.0.0\n' > "$d/contracts/api/openapi.yml"
printf '{"kind": "event"}\n' > "$d/contracts/events.json"
run "$d"
if [[ $RC -ne 0 ]]; then
    fail "expected exit 0, got $RC ($ERR)"
elif [[ -e "$d/contracts" ]]; then
    fail "contracts/ still on disk"
elif ! grep -q '### api/openapi.yml' "$d/plan.md"; then
    fail "'### api/openapi.yml' heading missing"
elif ! grep -q '### events.json' "$d/plan.md"; then
    fail "'### events.json' heading missing"
elif ! grep -q 'openapi: 3.0.0' "$d/plan.md"; then
    fail "openapi.yml content missing"
elif ! grep -q '"kind": "event"' "$d/plan.md"; then
    fail "events.json content missing"
else
    pass
fi

# ---------------------------------------------------------------- case 4
start "idempotence: re-running over the same artifact is byte-identical"
d="$(mkfeature idempotent)"
printf '# Research\n\nround one\n' > "$d/research.md"
run "$d"
first="$(cat "$d/plan.md")"
# Recreate the same artifact and heal again — the block must be replaced,
# not duplicated, and plan.md must come out byte-identical.
printf '# Research\n\nround one\n' > "$d/research.md"
run "$d"
second="$(cat "$d/plan.md")"
count="$(grep -c '<!-- BEGIN: spec-minimal inlined research.md -->' "$d/plan.md")"
if [[ $RC -ne 0 ]]; then
    fail "expected exit 0, got $RC ($ERR)"
elif [[ "$first" != "$second" ]]; then
    fail "plan.md differs between runs"
elif [[ "$count" -ne 1 ]]; then
    fail "expected exactly 1 sentinel block, found $count"
else
    pass
fi

# ---------------------------------------------------------------- case 5
start "unknown entry => exit 0, warning on stderr, entry kept"
d="$(mkfeature unknown)"
mkdir -p "$d/checklists"
printf '%s\n' '- [ ] item' > "$d/checklists/ux.md"
run "$d"
if [[ $RC -ne 0 ]]; then
    fail "expected exit 0, got $RC ($ERR)"
elif [[ ! -d "$d/checklists" ]]; then
    fail "checklists/ was removed"
elif [[ "$ERR" != *"warning:"*"checklists"* ]]; then
    fail "expected a warning about checklists on stderr, got: $ERR"
else
    pass
fi

# ---------------------------------------------------------------- case 6
start "forbidden artifact + missing plan.md => exit 1, artifact preserved"
d="$(mkfeature noplan)"
rm -f "$d/plan.md"
printf '# Research\n\nirreplaceable\n' > "$d/research.md"
run "$d"
if [[ $RC -ne 1 ]]; then
    fail "expected exit 1, got $RC"
elif [[ ! -f "$d/research.md" ]]; then
    fail "research.md was destroyed"
elif [[ "$ERR" != *plan.md* ]]; then
    fail "expected stderr to mention plan.md, got: $ERR"
else
    pass
fi

# ---------------------------------------------------------------- case 7
start "missing arg => exit 2"
OUT="$("$ENFORCE" 2>"$WORK/.stderr")"; RC=$?
ERR="$(cat "$WORK/.stderr")"
if [[ $RC -ne 2 ]]; then
    fail "expected exit 2, got $RC"
elif [[ "$ERR" != error:* ]]; then
    fail "expected an 'error:' line on stderr, got: $ERR"
else
    pass
fi

# ---------------------------------------------------------------- case 8
start "empty forbidden artifact => removed, no empty section appended"
d="$(mkfeature empty)"
: > "$d/data-model.md"
run "$d"
if [[ $RC -ne 0 ]]; then
    fail "expected exit 0, got $RC ($ERR)"
elif [[ -e "$d/data-model.md" ]]; then
    fail "data-model.md still on disk"
elif grep -q 'spec-minimal inlined data-model.md' "$d/plan.md"; then
    fail "an empty sentinel block was appended"
elif [[ "$OUT" != *removed:*data-model.md* ]]; then
    fail "expected a 'removed:' line for data-model.md, got: $OUT"
else
    pass
fi

# ---------------------------------------------------------------- case 9
start "paths with spaces are handled"
d="$(mkfeature 'feature with spaces')"
mkdir -p "$d/contracts/sub dir"
printf 'spaced contract\n' > "$d/contracts/sub dir/a file.yml"
run "$d"
if [[ $RC -ne 0 ]]; then
    fail "expected exit 0, got $RC ($ERR)"
elif [[ -e "$d/contracts" ]]; then
    fail "contracts/ still on disk"
elif ! grep -q '### sub dir/a file.yml' "$d/plan.md"; then
    fail "'### sub dir/a file.yml' heading missing"
elif ! grep -q 'spaced contract' "$d/plan.md"; then
    fail "content missing"
else
    pass
fi

echo ""
if [[ $FAILURES -eq 0 ]]; then
    echo "all cases passed"
    exit 0
fi
echo "$FAILURES case(s) failed"
exit 1
