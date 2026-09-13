#!/usr/bin/env bash
# ponytail-plan preset: selftest-ponytail-plan.sh
# Self-contained test for check-ladder.sh. No test framework required.
#
# The checker is read-only, so every case asserts the exit code AND that
# plan.md was left byte-identical.
#
# Usage: ./presets/ponytail-plan/scripts/bash/selftest-ponytail-plan.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/check-ladder.sh"
[[ -x "$CHECK" ]] || { echo "error: not executable: $CHECK" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0

# case_ <name> <expected-rc> <stderr-substring or ""> ; plan body on stdin
case_() {
    local name="$1" want="$2" needle="$3" dir="$WORK/$1"
    mkdir -p "$dir"
    cat > "$dir/plan.md"
    local before after out err rc
    before="$(cksum < "$dir/plan.md")"
    out="$("$CHECK" "$dir/plan.md" 2>"$dir/.err")"; rc=$?
    err="$(cat "$dir/.err")"
    after="$(cksum < "$dir/plan.md")"
    if [[ "$rc" -ne "$want" ]]; then
        echo "FAIL: $name — expected rc=$want, got rc=$rc (stderr: $err)"; FAILURES=$((FAILURES + 1)); return
    fi
    if [[ -n "$needle" && "$err" != *"$needle"* ]]; then
        echo "FAIL: $name — stderr missing '$needle' (stderr: $err)"; FAILURES=$((FAILURES + 1)); return
    fi
    if [[ "$before" != "$after" ]]; then
        echo "FAIL: $name — plan.md was modified"; FAILURES=$((FAILURES + 1)); return
    fi
    echo "PASS: $name"
}

HEAD='# Implementation Plan: thing

## Summary

Add a thing.
'

case_ pass-table 0 "" <<EOF
$HEAD
## Ladder

| Item | Kind | Rung | Reason |
|------|------|------|--------|
| \`src/cache.ts\` | file | 1 | cut: no measured latency problem |
| RetryPolicy | abstraction | 2 | reuse \`withBackoff()\` |
| \`zod\` | dependency | 5 | already installed |
| \`p-queue\` | dependency | 7 | concurrency cap |

**Dependency justification:** \`p-queue\` — nothing in rungs 2-6 caps
concurrency across workers.

## Project Structure

- src/
EOF

case_ pass-wrapped-justification 0 "" <<EOF
$HEAD
## Ladder

| Item | Kind | Rung | Reason |
|---|---|---|---|
| \`p-queue\` | dependency | **7** | concurrency cap |

**Dependency justification:**
\`p-queue\` — no installed dependency caps concurrency.
EOF

case_ none-line 0 "" <<EOF
$HEAD
## Ladder

None — extends existing code only.
EOF

case_ missing-section 1 "missing \`## Ladder\` section" <<EOF
$HEAD
## Project Structure

- src/
EOF

case_ section-only-in-fence 1 "missing \`## Ladder\` section" <<EOF
$HEAD
\`\`\`markdown
## Ladder

None — extends existing code only.
\`\`\`
EOF

case_ empty-section 1 "no table rows" <<EOF
$HEAD
## Ladder

Nothing to say.

## Next
EOF

case_ bad-rung 1 "Rung must be a single integer 1-7" <<EOF
$HEAD
## Ladder

| Item | Kind | Rung | Reason |
|------|------|------|--------|
| \`src/a.ts\` | file | 8 | too high |
EOF

case_ bad-rung-range 1 "plan.md:11: Rung" <<EOF
$HEAD
## Ladder

| Item | Kind | Rung | Reason |
|------|------|------|--------|
| \`src/a.ts\` | file | 2-3 | ambiguous |
EOF

case_ bad-kind 1 "Kind must be" <<EOF
$HEAD
## Ladder

| Item | Kind | Rung | Reason |
|------|------|------|--------|
| \`src/a.ts\` | module | 7 | new |
EOF

case_ dependency-without-justification 1 "without a populated" <<EOF
$HEAD
## Ladder

| Item | Kind | Rung | Reason |
|------|------|------|--------|
| \`p-queue\` | dependency | 7 | concurrency cap |
EOF

case_ dependency-placeholder-justification 1 "without a populated" <<EOF
$HEAD
## Ladder

| Item | Kind | Rung | Reason |
|------|------|------|--------|
| \`p-queue\` | dependency | 7 | concurrency cap |

**Dependency justification:** <why rungs 2-6 fail>
EOF

case_ justification-outside-section 1 "without a populated" <<EOF
$HEAD
## Ladder

| Item | Kind | Rung | Reason |
|------|------|------|--------|
| \`p-queue\` | dependency | 7 | concurrency cap |

## Elsewhere

**Dependency justification:** \`p-queue\` — stated in the wrong section.
EOF

# Usage errors.
"$CHECK" >/dev/null 2>&1; rc=$?
if [[ $rc -eq 2 ]]; then echo "PASS: no-args"; else echo "FAIL: no-args — rc=$rc"; FAILURES=$((FAILURES + 1)); fi
"$CHECK" "$WORK/does-not-exist.md" >/dev/null 2>&1; rc=$?
if [[ $rc -eq 2 ]]; then echo "PASS: missing-file"; else echo "FAIL: missing-file — rc=$rc"; FAILURES=$((FAILURES + 1)); fi
"$CHECK" "$WORK/none-line" >/dev/null 2>&1; rc=$?
if [[ $rc -eq 0 ]]; then echo "PASS: feature-dir-arg"; else echo "FAIL: feature-dir-arg — rc=$rc"; FAILURES=$((FAILURES + 1)); fi

echo
if [[ $FAILURES -eq 0 ]]; then
    echo "all ponytail-plan selftests passed"
    exit 0
fi
echo "$FAILURES ponytail-plan selftest(s) failed"
exit 1
