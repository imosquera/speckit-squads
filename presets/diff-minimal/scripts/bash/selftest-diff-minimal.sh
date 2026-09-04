#!/usr/bin/env bash
# diff-minimal preset: selftest-diff-minimal.sh
# Self-contained test for check-scope-sections.sh and check-plan-scope.sh.
# No test framework required.
#
# Both scripts are read-only, so every case asserts the exit code AND that the
# inputs were left byte-identical — "it exited 1" is not evidence that it kept
# its hands off the spec.
#
# Usage: ./presets/diff-minimal/scripts/bash/selftest-diff-minimal.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECTIONS="$HERE/check-scope-sections.sh"
PLAN="$HERE/check-plan-scope.sh"

for s in "$SECTIONS" "$PLAN"; do
    [[ -x "$s" ]] || { echo "error: not executable: $s" >&2; exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
CASE=""
start() { CASE="$1"; }
pass() { echo "PASS: $CASE"; }
fail() { echo "FAIL: $CASE — $1"; FAILURES=$((FAILURES + 1)); }

# run <script> <arg> -> sets RC, OUT, ERR
run() {
    OUT="$("$1" "$2" 2>"$WORK/.stderr")"
    RC=$?
    ERR="$(cat "$WORK/.stderr")"
}

# mkfeature <name> -> prints the dir; caller writes spec.md/plan.md into it
mkfeature() {
    local dir="$WORK/$1"
    rm -rf "$dir"
    mkdir -p "$dir"
    echo "$dir"
}

digest() { cksum < "$1" ; }

expect_rc() {
    [[ "$RC" -eq "$1" ]] || { fail "expected rc=$1, got rc=$RC (stderr: $ERR)"; return 1; }
}

SPEC_HEAD='# Feature Specification: thing

## User Scenarios

- a user does a thing
'

CORRECTIONS_OK='
## Corrections to the issue as filed

- `firestore.indexes.json` — dropped: the query is a single equality filter.
'

SCOPE_OK='
## Scope discipline

**MUST NOT touch:**

- `firestore.rules` — the read runs on the Admin SDK
- `infra/**` — a rules change pulls a Terraform apply in behind it
'

# --------------------------------------------------------------- sections
start "sections: both present and populated -> 0"
d="$(mkfeature s1)"
printf '%s%s%s' "$SPEC_HEAD" "$CORRECTIONS_OK" "$SCOPE_OK" > "$d/spec.md"
before="$(digest "$d/spec.md")"
run "$SECTIONS" "$d/spec.md"
if expect_rc 0; then
    if [[ "$before" != "$(digest "$d/spec.md")" ]]; then
        fail "spec.md was modified by a read-only check"
    elif ! grep -q 'firestore.rules' <<<"$OUT"; then
        fail "did not report the out-of-scope paths: $OUT"
    else
        pass
    fi
fi

start "sections: Corrections missing -> 1, names the section"
d="$(mkfeature s2)"
printf '%s%s' "$SPEC_HEAD" "$SCOPE_OK" > "$d/spec.md"
before="$(digest "$d/spec.md")"
run "$SECTIONS" "$d/spec.md"
if expect_rc 1; then
    if ! grep -q 'Corrections to the issue as filed' <<<"$ERR"; then
        fail "stderr does not name the missing section: $ERR"
    elif [[ "$before" != "$(digest "$d/spec.md")" ]]; then
        fail "spec.md was modified"
    else
        pass
    fi
fi

start "sections: Scope discipline missing -> 1, shows expected shape"
d="$(mkfeature s3)"
printf '%s%s' "$SPEC_HEAD" "$CORRECTIONS_OK" > "$d/spec.md"
run "$SECTIONS" "$d/spec.md"
if expect_rc 1; then
    grep -q 'MUST NOT touch' <<<"$ERR" && pass || fail "stderr lacks the expected shape: $ERR"
fi

start "sections: heading present but empty -> 1"
d="$(mkfeature s4)"
printf '%s%s\n## Scope discipline\n\n' "$SPEC_HEAD" "$CORRECTIONS_OK" > "$d/spec.md"
run "$SECTIONS" "$d/spec.md"
if expect_rc 1; then
    grep -qi 'empty section' <<<"$ERR" && pass || fail "stderr should say the section is empty: $ERR"
fi

start "sections: MUST NOT list declared but no paths -> 1"
d="$(mkfeature s5)"
printf '%s%s\n## Scope discipline\n\n**MUST NOT touch:**\n\n' "$SPEC_HEAD" "$CORRECTIONS_OK" > "$d/spec.md"
run "$SECTIONS" "$d/spec.md"
if expect_rc 1; then
    grep -q 'lists no paths' <<<"$ERR" && pass || fail "wrong diagnosis: $ERR"
fi

start "sections: explicit None. is accepted for both -> 0"
d="$(mkfeature s6)"
printf '%s\n## Corrections to the issue as filed\n\nNone.\n\n## Scope discipline\n\nNone.\n' \
    "$SPEC_HEAD" > "$d/spec.md"
run "$SECTIONS" "$d/spec.md"
expect_rc 0 && pass

start "sections: section boundary respects a following H2"
d="$(mkfeature s7)"
printf '%s%s%s\n## Functional Requirements\n\n- FR-001 modify `infra/main.tf`\n' \
    "$SPEC_HEAD" "$CORRECTIONS_OK" "$SCOPE_OK" > "$d/spec.md"
run "$SECTIONS" "$d/spec.md"
if expect_rc 0; then
    # `infra/main.tf` lives outside Scope discipline, so it must not be read as
    # a fourth forbidden path.
    [[ "$(grep -c '^  - ' <<<"$OUT")" -eq 2 ]] && pass || fail "wrong path count: $OUT"
fi

start "sections: missing file -> 2"
run "$SECTIONS" "$WORK/nope/spec.md"
expect_rc 2 && pass

start "sections: no argument -> 2"
OUT="$("$SECTIONS" 2>"$WORK/.stderr")"; RC=$?; ERR="$(cat "$WORK/.stderr")"
expect_rc 2 && pass

# ------------------------------------------------------------------- plan
mkplanfeature() {
    local d; d="$(mkfeature "$1")"
    printf '%s%s%s' "$SPEC_HEAD" "$CORRECTIONS_OK" "$SCOPE_OK" > "$d/spec.md"
    echo "$d"
}

start "plan: clean plan -> 0"
d="$(mkplanfeature p1)"
printf '# Plan\n\n- edit `src/handlers/claim.ts`\n- add a test in `test/claim.test.ts`\n' > "$d/plan.md"
before="$(digest "$d/plan.md")"
run "$PLAN" "$d"
if expect_rc 0; then
    [[ "$before" == "$(digest "$d/plan.md")" ]] && pass || fail "plan.md was modified"
fi

start "plan: forbidden literal path -> 1 with file:line"
d="$(mkplanfeature p2)"
printf '# Plan\n\n- edit `src/handlers/claim.ts`\n- update `firestore.rules` to allow the read\n' > "$d/plan.md"
run "$PLAN" "$d"
if expect_rc 1; then
    grep -q 'plan.md:4' <<<"$ERR" && grep -q 'firestore.rules' <<<"$ERR" \
        && pass || fail "missing file:line or path: $ERR"
fi

start "plan: forbidden glob (infra/** matches a nested path) -> 1"
d="$(mkplanfeature p3)"
printf '# Plan\n\n- apply `infra/modules/db/main.tf`\n' > "$d/plan.md"
run "$PLAN" "$d"
if expect_rc 1; then
    grep -q 'infra/\*\*' <<<"$ERR" && pass || fail "glob not attributed: $ERR"
fi

start "plan: negation line is not a violation -> 0"
d="$(mkplanfeature p4)"
printf '# Plan\n\n- do not touch `firestore.rules`; the Admin SDK ignores it\n- `infra/**` is out of scope\n' > "$d/plan.md"
run "$PLAN" "$d"
expect_rc 0 && pass

start "plan: a restating ## Scope section is exempt, but later prose is not -> 1"
d="$(mkplanfeature p5)"
printf '# Plan\n\n## Scope\n\n- `firestore.rules`\n- `infra/**`\n\n## Steps\n\n- edit `infra/main.tf`\n' > "$d/plan.md"
run "$PLAN" "$d"
if expect_rc 1; then
    if grep -q 'plan.md:5' <<<"$ERR"; then
        fail "flagged a line inside the exempt ## Scope section"
    elif grep -q 'plan.md:10' <<<"$ERR"; then
        pass
    else
        fail "did not flag the violation after the exempt section: $ERR"
    fi
fi

start "plan: tasks.md is scanned too -> 1"
d="$(mkplanfeature p6)"
printf '# Plan\n\nclean\n' > "$d/plan.md"
printf '# Tasks\n\n- T001 edit `firestore.rules`\n' > "$d/tasks.md"
run "$PLAN" "$d"
if expect_rc 1; then
    grep -q 'tasks.md:3' <<<"$ERR" && pass || fail "tasks.md not scanned: $ERR"
fi

start "plan: spec with no Scope discipline -> 0 and says so"
d="$(mkfeature p7)"
printf '%s%s' "$SPEC_HEAD" "$CORRECTIONS_OK" > "$d/spec.md"
printf '# Plan\n\n- edit `infra/main.tf`\n' > "$d/plan.md"
run "$PLAN" "$d"
if expect_rc 0; then
    grep -q 'forbids no paths' <<<"$OUT" && pass || fail "unexpected output: $OUT"
fi

start "plan: single * does not span a separator"
d="$(mkfeature p8)"
printf '%s%s\n## Scope discipline\n\n**MUST NOT touch:**\n\n- `src/*.ts`\n' \
    "$SPEC_HEAD" "$CORRECTIONS_OK" > "$d/spec.md"
printf '# Plan\n\n- edit `src/handlers/claim.ts`\n' > "$d/plan.md"
run "$PLAN" "$d"
expect_rc 0 && pass

start "plan: no spec.md -> 2"
d="$(mkfeature p9)"
printf '# Plan\n' > "$d/plan.md"
run "$PLAN" "$d"
expect_rc 2 && pass

echo
if [[ $FAILURES -eq 0 ]]; then
    echo "all cases passed"
    exit 0
fi
echo "$FAILURES case(s) failed"
exit 1
