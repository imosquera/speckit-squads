#!/usr/bin/env bash
# button-design preset: check-buttons.sh
# Deterministic half of the button-design rules. Read-only: never edits a file.
#
#   spec <spec.md>       `## Actions & Buttons` exists and is either `None.` or a
#                        table where: kind is button|link; links take no role;
#                        each screen has at most one primary; button labels are
#                        1–3 words and not generic; destructive labels name
#                        their object and carry a confirm/type/undo safeguard.
#   plan <feature-dir>   when the spec declares actions, plan.md has a
#                        `## Button System` with all five markers populated and
#                        no touch target under 44×44.
#
# Prose rules (jargon, "match the moment", placement quality) stay in the
# command prompts. A checker that guesses at those cries wolf, and one that
# cries wolf gets disabled.
#
# Usage: check-buttons.sh spec <spec.md>
#        check-buttons.sh plan <feature-dir>
# Exit:  0 pass   1 rule violation (stderr says which)   2 bad usage

set -uo pipefail

MODE="${1:-}"
TARGET="${2:-}"
usage() {
    echo "usage: $(basename "$0") spec <spec.md> | plan <feature-dir>" >&2
    exit 2
}
case "$MODE" in
    spec) [[ -f "$TARGET" ]] || { echo "error: not a file: $TARGET" >&2; usage; } ;;
    plan) [[ -f "$TARGET/plan.md" ]] || { echo "error: no plan.md in: $TARGET" >&2; usage; } ;;
    *) usage ;;
esac

if ! command -v bun >/dev/null 2>&1; then
    echo "error: bun is required but not on PATH (install: https://bun.sh)" >&2
    exit 127
fi
exec bun "$(dirname "${BASH_SOURCE[0]}")/../ts/check-buttons.ts" "$MODE" "$TARGET"
