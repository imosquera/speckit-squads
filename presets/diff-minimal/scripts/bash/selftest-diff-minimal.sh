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

# run <script> <arg>... -> sets RC, OUT, ERR
run() {
    OUT="$("$@" 2>"$WORK/.stderr")"
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

# A MUST-NOT list whose bullets wrap, the way any editor writes prose. Four
# paths; the first and third each continue onto further physical lines. Before
# issue #68 the parser stopped at the first continuation and saw exactly one.
SCOPE_WRAPPED='
## Scope discipline

**MUST NOT touch:**

- `firestore.rules` — the read runs on the Admin SDK, which never consults
  rules, so a rules edit changes nothing here and drags a deploy in behind it
- `infra/**` — a Terraform apply is not part of this change
- `scripts/deploy.sh` — the release path is unchanged by this feature, and a
  change here lands on every service at once rather than on this one
- `package-lock.json` — no dependency moves
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

start "sections: wrapped MUST NOT bullets report every path, not the first"
d="$(mkfeature s8)"
printf '%s%s%s' "$SPEC_HEAD" "$CORRECTIONS_OK" "$SCOPE_WRAPPED" > "$d/spec.md"
before="$(digest "$d/spec.md")"
run "$SECTIONS" "$d/spec.md"
if expect_rc 0; then
    # rc=0 alone is exactly the silent pass this bug produced: a 4-path list read
    # as 1 path still exits 0. Assert the count and every name.
    if [[ "$before" != "$(digest "$d/spec.md")" ]]; then
        fail "spec.md was modified by a read-only check"
    elif [[ "$(grep -c '^  - ' <<<"$OUT")" -ne 4 ]]; then
        fail "wrapped bullets truncated the list: $OUT"
    elif ! grep -q '4 path(s)' <<<"$OUT"; then
        fail "reported count is not 4: $OUT"
    else
        missing=""
        for p in 'firestore.rules' 'infra/\*\*' 'scripts/deploy.sh' 'package-lock.json'; do
            grep -q -- "$p" <<<"$OUT" || missing="$missing $p"
        done
        [[ -z "$missing" ]] && pass || fail "paths lost to wrapping:$missing"
    fi
fi

start "sections: a wrapped bullet's tail is not read as a second path"
d="$(mkfeature s9)"
printf '%s%s\n## Scope discipline\n\n**MUST NOT touch:**\n\n- `infra/**` — a rules change pulls a Terraform\n  apply in behind it, and `terraform.tfstate` is not ours to move\n' \
    "$SPEC_HEAD" "$CORRECTIONS_OK" > "$d/spec.md"
run "$SECTIONS" "$d/spec.md"
if expect_rc 0; then
    [[ "$(grep -c '^  - ' <<<"$OUT")" -eq 1 ]] && pass || fail "one wrapped bullet is one path: $OUT"
fi

start "sections: a bare-spelled bullet keeps its own path, not its tail's backticks"
d="$(mkfeature s10)"
printf '%s%s\n## Scope discipline\n\n**MUST NOT touch:**\n\n- infra/** — a Terraform apply is not part of this change; the queue is\n  provisioned already and `src/queue/worker.ts` is the only consumer\n' \
    "$SPEC_HEAD" "$CORRECTIONS_OK" > "$d/spec.md"
run "$SECTIONS" "$d/spec.md"
if expect_rc 0; then
    # Preferring backticks over position picks a path out of the bullet's own
    # prose: `infra/**` would be permitted and `src/queue/worker.ts` forbidden —
    # enforcement inverted, not merely weakened.
    if grep -q 'src/queue/worker.ts' <<<"$OUT"; then
        fail "took the path from the wrapped tail: $OUT"
    else
        grep -q 'infra/\*\*' <<<"$OUT" && pass || fail "lost the bullet's own path: $OUT"
    fi
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

# mkwrappedfeature <name> -> a feature whose spec's MUST-NOT bullets wrap
mkwrappedfeature() {
    local d; d="$(mkfeature "$1")"
    printf '%s%s%s' "$SPEC_HEAD" "$CORRECTIONS_OK" "$SCOPE_WRAPPED" > "$d/spec.md"
    echo "$d"
}

start "plan: a negation split across a line wrap is still a negation -> 0"
d="$(mkplanfeature p10)"
printf '# Plan\n\n- `firestore.rules` is deliberately\n  left untouched; the Admin SDK never consults it\n- we must not\n  apply `infra/main.tf` as part of this change\n- edit `src/handlers/claim.ts`\n' > "$d/plan.md"
before="$(digest "$d/plan.md")"
run "$PLAN" "$d"
if expect_rc 0; then
    [[ "$before" == "$(digest "$d/plan.md")" ]] && pass || fail "plan.md was modified"
fi

start "plan: a path declared in a WRAPPED spec bullet is still enforced -> 1"
d="$(mkwrappedfeature p11)"
printf '# Plan\n\n- edit `src/handlers/claim.ts`\n- run `scripts/deploy.sh` after the migration\n' > "$d/plan.md"
run "$PLAN" "$d"
if expect_rc 1; then
    # `scripts/deploy.sh` sits on a continuation line in the spec; if the spec
    # parse truncated, this violation would go unseen and the gate would pass.
    grep -q 'plan.md:4' <<<"$ERR" && grep -q 'scripts/deploy.sh' <<<"$ERR" \
        && pass || fail "wrapped-bullet path was not enforced: $ERR"
fi

start "plan: a heading is never folded into by the prose line after it"
d="$(mkplanfeature p12)"
printf '# Plan\n\n## Non-goals\n\nDeliberately parked for a follow-up: `firestore.rules` and its tests.\n\n## Steps\n\n- apply `infra/main.tf`\n' > "$d/plan.md"
run "$PLAN" "$d"
if expect_rc 1; then
    # The prose names a forbidden path with no negation of its own. It is exempt
    # only because `## Non-goals` was seen as a heading — folding it into the
    # prose would lose the heading and flag line 5.
    if grep -q 'plan.md:5' <<<"$ERR"; then
        fail "heading folded into the prose under it; exempt section lost"
    elif grep -q 'plan.md:9' <<<"$ERR"; then
        pass
    else
        fail "did not flag the violation after the exempt section: $ERR"
    fi
fi

# Folding is for WRAPPED PROSE only. Everything below is a line of markdown that
# starts something of its own, so it must arrive as its own logical line — both
# so the report points at the right line, and (the real damage) so a negation
# earlier in the block cannot exempt a forbidden path later in it.

start "plan: an ordered-list step is its own line, not a fold into the step above"
d="$(mkplanfeature p13)"
printf '# Plan\n\n## Steps\n\n1. Add the handler in `src/handlers/claim.ts`; no changes to the schema.\n2. Apply `infra/main.tf` so the new subnet exists.\n3. Deploy.\n' > "$d/plan.md"
run "$PLAN" "$d"
if expect_rc 1; then
    grep -q 'plan.md:6' <<<"$ERR" && pass \
        || fail "numbered step folded into the negation above it: $ERR"
fi

start "plan: a table row is its own line, not a fold into the header"
d="$(mkplanfeature p14)"
printf '# Plan\n\n## File map\n\n| File | Change |\n|------|--------|\n| `firestore.rules` | no changes to this file |\n| `infra/main.tf` | add the subnet |\n' > "$d/plan.md"
run "$PLAN" "$d"
if expect_rc 1; then
    grep -q 'plan.md:8' <<<"$ERR" && pass \
        || fail "table folded into one line; a negating row exempted the rest: $ERR"
fi

start "plan: a blockquote is its own line, not a fold into the prose above"
d="$(mkplanfeature p15)"
printf '# Plan\n\n## Steps\n\nRules are excluded here.\n> We still need to apply `infra/main.tf` for the subnet.\n' > "$d/plan.md"
run "$PLAN" "$d"
if expect_rc 1; then
    grep -q 'plan.md:6' <<<"$ERR" && pass || fail "blockquote folded: $ERR"
fi

start "plan: code inside a fence never folds, and the fence never eats prose"
d="$(mkplanfeature p16)"
printf '# Plan\n\n## Steps\n\nThe rules file is out of scope for this change.\n\n```bash\ncd deploy\nterraform apply infra/main.tf\n```\n' > "$d/plan.md"
run "$PLAN" "$d"
if expect_rc 1; then
    # Without fence handling the whole block folds onto line 5, whose text
    # negates — a real violation silently exempted.
    grep -q 'plan.md:9' <<<"$ERR" && pass \
        || fail "fenced code folded into the prose above it: $ERR"
fi

start "plan: two prose sentences are two logical lines, not one exempt block"
d="$(mkplanfeature p17)"
printf '# Plan\n\n## Steps\n\nThe read path stays on the Admin SDK, so `firestore.rules` is out of scope.\nWe then apply `infra/main.tf` to add the new subnet the queue needs.\n' > "$d/plan.md"
before="$(digest "$d/plan.md")"
run "$PLAN" "$d"
if expect_rc 1; then
    # Fold these two sentences together and the first one's "out of scope"
    # exempts the second one's forbidden path: the gate exits 0 on a real
    # violation, which is worse than the truncation issue #68 fixed.
    if grep -q 'plan.md:5' <<<"$ERR"; then
        fail "flagged the negating sentence: $ERR"
    elif ! grep -q 'plan.md:6' <<<"$ERR"; then
        fail "did not report the violating sentence's own line: $ERR"
    elif [[ "$before" != "$(digest "$d/plan.md")" ]]; then
        fail "plan.md was modified"
    else
        pass
    fi
fi

start "plan: artifact file paths are accepted, and reported once -> 1"
d="$(mkplanfeature p18)"
printf '# Plan\n\n- update `firestore.rules` to allow the read\n' > "$d/plan.md"
run "$PLAN" "$d/spec.md" "$d/plan.md"
if expect_rc 1; then
    if [[ "$(grep -c 'plan.md:3' <<<"$ERR")" -ne 1 ]]; then
        fail "same feature dir reported more than once: $ERR"
    else
        pass
    fi
fi

start "plan: dir spellings that differ only by a trailing slash dedupe -> 1, once"
d="$(mkplanfeature p19)"
printf '# Plan\n\n- update `firestore.rules` to allow the read\n' > "$d/plan.md"
run "$PLAN" "$d/" "$d" "$d/plan.md"
if expect_rc 1; then
    if [[ "$(grep -c 'plan.md:3' <<<"$ERR")" -ne 1 ]]; then
        fail "same feature dir reported more than once: $ERR"
    else
        pass
    fi
fi

start "plan: a lone artifact file path resolves its feature dir -> 0"
d="$(mkplanfeature p20)"
printf '# Plan\n\n- edit `src/handlers/claim.ts`\n' > "$d/plan.md"
run "$PLAN" "$d/plan.md"
expect_rc 0 && pass

start "plan: argument that is neither dir nor file -> 2"
run "$PLAN" "$WORK/nope/plan.md"
expect_rc 2 && pass

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
