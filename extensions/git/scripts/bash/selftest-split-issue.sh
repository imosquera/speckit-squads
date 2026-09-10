#!/usr/bin/env bash
# git extension: selftest-split-issue.sh
# Self-contained test for split-issue.sh's registry parser (`child_of`), driven
# through the real script's `--show` path with a stubbed `gh` on PATH.
#
# No test framework required.
# Usage: ./extensions/git/scripts/bash/selftest-split-issue.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPLIT="$HERE/split-issue.sh"
[ -r "$SPLIT" ] || { echo "error: not found: $SPLIT" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# `gh issue view <n> --json body --jq .body` — prints whatever the case wrote.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
cat "$GH_STUB_BODY"
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
export GH_STUB_BODY="$WORK/body.md"

FAILURES=0
# check <name> <expected --show output> <parent body>
check() {
    local name="$1" want="$2" body="$3" got
    printf '%s\n' "$body" > "$GH_STUB_BODY"
    got="$(bash "$SPLIT" 1 --show 2>/dev/null)"
    if [ "$got" = "$want" ]; then
        echo "PASS: $name"
    else
        echo "FAIL: $name — want [$want] got [$got]"
        FAILURES=$((FAILURES + 1))
    fi
}

BEGIN='<!-- speckit:work-breakdown -->'
END='<!-- /speckit:work-breakdown -->'

check "unwrapped bullets (the generator's own output)" \
"frontend 11
backend 12
integration 13" \
"$BEGIN
## Work breakdown

- [ ] frontend — mock first, fixtures only: #11
- [ ] backend — no UI: #12
- [ ] integration — wire-up, blocked by the two above: #13
$END"

check "wrapped bullet carries its #N on a continuation line" \
"frontend 11
backend 12
integration 61" \
"$BEGIN
- [ ] frontend — mock first, fixtures only: #11
- [ ] backend — no UI: #12
- [ ] integration — wire the saved-search UI to the real endpoint and retire
      the fixtures (#61)
$END"

check "a passing reference ahead of the child number does not win" \
"backend 12" \
"$BEGIN
- [ ] backend — supersedes #99, see #98: #12
$END"

check "no block at all — nothing is split yet" \
"" \
"Some issue body with a stray bullet:

- [ ] frontend — not in any registry: #11"

check "text outside the block cannot be folded into a bullet" \
"frontend 11" \
"$BEGIN
- [ ] frontend — mock first: #11

Unindented prose mentioning #77 ends the bullet.
$END"

if [ "$FAILURES" -eq 0 ]; then
    echo "all cases passed"
else
    echo "$FAILURES case(s) failed" >&2
fi
exit $(( FAILURES > 0 ))
