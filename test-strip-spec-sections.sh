#!/usr/bin/env bash
# Check for spec-minimal's strip-spec-sections.sh (issue #58):
#   1. headings carrying the template's trailing parenthetical are stripped;
#   2. the summary line names what was removed and what was absent.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/presets/spec-minimal/scripts/bash/strip-spec-sections.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
check() { # name expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok   $1"; else
    echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; fail=1
  fi
}

cat > "$TMP/spec.md" <<'MD'
# Feature

## User Scenarios

Some prose.

### Key Entities *(include if feature involves data)*

- **Thing**: a thing

## Success Criteria *(mandatory)*

- SC-001: fast

## Requirements

- FR-001: works
MD

out="$($SCRIPT "$TMP/spec.md")"
check "exit 0" 0 $?
check "remaining headings" \
  "# Feature|## User Scenarios|## Requirements" \
  "$(grep '^#' "$TMP/spec.md" | paste -sd'|' -)"
check "body kept" "- FR-001: works" "$(grep 'FR-001' "$TMP/spec.md")"
case "$out" in
  *"stripped Key Entities / Success Criteria"*) echo "  ok   reports what was stripped";;
  *) echo "  FAIL reports what was stripped: $out"; fail=1;;
esac
case "$out" in
  *"not present: Assumptions"*) echo "  ok   reports what was absent";;
  *) echo "  FAIL reports what was absent: $out"; fail=1;;
esac

# idempotent: second run removes nothing
out2="$($SCRIPT "$TMP/spec.md")"
check "idempotent headings" \
  "# Feature|## User Scenarios|## Requirements" \
  "$(grep '^#' "$TMP/spec.md" | paste -sd'|' -)"
case "$out2" in
  *"not present: Assumptions / Key Entities / Success Criteria"*) echo "  ok   second run reports all absent";;
  *) echo "  FAIL second run report: $out2"; fail=1;;
esac

exit $fail
