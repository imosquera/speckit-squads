#!/usr/bin/env bash
# button-design preset: selftest-button-design.sh
# Self-contained test for check-buttons.sh. No test framework required.
#
# The checker is read-only, so every case asserts the exit code AND that
# spec.md was left byte-identical.
#
# Usage: ./presets/button-design/scripts/bash/selftest-button-design.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/check-buttons.sh"
[[ -x "$CHECK" ]] || { echo "error: not executable: $CHECK" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

# check <name> <want-rc> <spec|plan> <spec-body> [<plan-body>]
check() {
    local name="$1" want="$2" mode="$3" spec="$4" plan="${5:-}"
    local dir="$WORK/$name" arg before rc
    mkdir -p "$dir"
    printf '# Feature\n\n%s\n' "$spec" > "$dir/spec.md"
    printf '# Plan\n\n%s\n' "$plan" > "$dir/plan.md"
    before="$(cksum < "$dir/spec.md")"
    arg="$dir/spec.md"; [[ "$mode" == plan ]] && arg="$dir"
    "$CHECK" "$mode" "$arg" > "$dir/out" 2>&1
    rc=$?
    if [[ "$rc" -ne "$want" ]]; then
        echo "FAIL: $name — want rc=$want, got rc=$rc"
        sed 's/^/    /' "$dir/out"
        FAILURES=$((FAILURES + 1))
    elif [[ "$(cksum < "$dir/spec.md")" != "$before" ]]; then
        echo "FAIL: $name — spec.md was modified"
        FAILURES=$((FAILURES + 1))
    else
        echo "PASS: $name"
    fi
}

HEAD='## Actions & Buttons

| Screen | Label | Kind | Role | Safeguard |
|---|---|---|---|---|'

GOOD="$HEAD
| Export | Download Report | button | primary | — |
| Export | Cancel | button | secondary | — |
| Settings | Save Changes | button | primary | — |
| Settings | Delete Account | button | secondary | type-to-confirm |
| Settings | Privacy policy | link | — | — |

## Functional Requirements"

NONE='## Actions & Buttons

None — no user-facing UI.'

# --- spec mode -------------------------------------------------------------
check spec-good               0 spec "$GOOD"
check spec-none               0 spec "$NONE"
check spec-toolbar-no-primary 0 spec "$HEAD
| Toolbar | Bold | button | tertiary | — |"
check spec-missing            1 spec '## User Scenarios'
check spec-no-table           1 spec '## Actions & Buttons

Some prose about buttons.'
check spec-missing-column     1 spec '## Actions & Buttons

| Screen | Label | Kind |
|---|---|---|
| Export | Download Report | button |'
check spec-two-primaries      1 spec "$HEAD
| Export | Download Report | button | primary | — |
| Export | Email Report | button | primary | — |"
check spec-generic-label      1 spec "$HEAD
| Export | Submit | button | primary | — |"
check spec-generic-link       1 spec "$HEAD
| Home | Click here | link | — | — |"
check spec-long-label         1 spec "$HEAD
| Export | Download The Quarterly Report | button | primary | — |"
check spec-bare-delete        1 spec "$HEAD
| Files | Delete | button | secondary | confirm dialog |"
check spec-unguarded-delete   1 spec "$HEAD
| Files | Delete File | button | secondary | — |"
check spec-unguarded-cancel   1 spec "$HEAD
| Billing | Cancel Subscription | button | primary | — |"
check spec-link-with-role     1 spec "$HEAD
| Home | Pricing | link | primary | — |"
check spec-bad-kind           1 spec "$HEAD
| Home | Pricing | chip | — | — |"

# --- plan mode -------------------------------------------------------------
PLAN_GOOD='## Button System

**Component:** reuse `Button` from `src/ui/Button.tsx`.
**Color roles:**
- **Primary:** brand color
- **Destructive:** danger red
**States:** default, hover, focus-visible, disabled, loading; 4.5:1 text contrast.
**Touch targets:** 44×44 minimum; 8px gaps.
**Placement:** primary at the end of the form.'

check plan-good               0 plan "$GOOD" "$PLAN_GOOD"
check plan-spec-none          0 plan "$NONE" ''
check plan-spec-legacy        0 plan '## User Scenarios' ''
check plan-missing-section    1 plan "$GOOD" '## Summary'
check plan-missing-marker     1 plan "$GOOD" "${PLAN_GOOD%'**Placement:**'*}"
check plan-empty-marker       1 plan "$GOOD" "${PLAN_GOOD%'**Placement:**'*}**Placement:**"
check plan-small-target       1 plan "$GOOD" "${PLAN_GOOD/44×44/32x32}"

# --- usage -----------------------------------------------------------------
"$CHECK" > /dev/null 2>&1
if [[ $? -eq 2 ]]; then echo "PASS: usage-no-args"; else echo "FAIL: usage-no-args"; FAILURES=$((FAILURES + 1)); fi

if [[ "$FAILURES" -gt 0 ]]; then
    echo "$FAILURES failure(s)"
    exit 1
fi
echo "all button-design checks passed"
