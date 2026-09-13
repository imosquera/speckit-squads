#!/usr/bin/env bash
# Check the four verdicts of graph-first-navigation's freshness gate, and that
# every remedy it prints names the checkout path.
#
# The gate opens the plan phase of every unattended run; when it cried STALE on
# a graph whose provenance was merely *absent*, every one of those runs paid a
# full rebuild for nothing (issue #67).
#
# Usage: ./test-graph-freshness.sh
set -uo pipefail

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/presets/graph-first-navigation/scripts/bash/graph-freshness.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

check() { # check <what> <condition-desc> <expected> <actual>
  if [[ "$3" == "$4" ]]; then echo "  ok: $1 $2"; else
    echo "  FAIL: $1 $2 — expected '$3', got '$4'" >&2; fail=1
  fi
}
contains() {
  if grep -qF -- "$2" <<<"$3"; then echo "  ok: $1 mentions '$2'"; else
    echo "  FAIL: $1 does not mention '$2'" >&2
    printf '%s\n' "$3" | sed 's/^/        /' >&2; fail=1
  fi
}

REPO="$TMP/repo"
mkdir -p "$REPO" && git -C "$REPO" init -q
git -C "$REPO" config user.email t@t && git -C "$REPO" config user.name t
echo hi > "$REPO/a.txt" && git -C "$REPO" add a.txt && git -C "$REPO" commit -qm one

echo "1. no graph -> ABSENT"
out="$("$GATE" "$REPO")"; rc=$?
check ABSENT "exit code" 2 "$rc"
contains ABSENT "graphify update $REPO" "$out"

echo "2. graph with no provenance -> UNKNOWN, not STALE"
mkdir -p "$REPO/graphify-out"
printf '{"nodes": [], "links": []}' > "$REPO/graphify-out/graph.json"
out="$("$GATE" "$REPO")"; rc=$?
check UNKNOWN "exit code" 3 "$rc"
contains UNKNOWN "UNKNOWN:" "$out"
if grep -q '^STALE' <<<"$out"; then echo "  FAIL: no-provenance reported as STALE" >&2; fail=1; fi

echo "3. graph behind HEAD -> STALE, remedy carries the path"
BUILT="$(git -C "$REPO" rev-parse HEAD)"
printf '{"built_at_commit": "%s", "nodes": []}' "$BUILT" > "$REPO/graphify-out/graph.json"
echo more > "$REPO/b.txt" && git -C "$REPO" add b.txt && git -C "$REPO" commit -qm two
out="$("$GATE" "$REPO")"; rc=$?
check STALE "exit code" 1 "$rc"
contains STALE "graphify update $REPO" "$out"

echo "4. graph at HEAD, tree clean -> FRESH"
printf '{"built_at_commit": "%s", "nodes": []}' "$(git -C "$REPO" rev-parse HEAD)" \
  > "$REPO/graphify-out/graph.json"
out="$("$GATE" "$REPO")"; rc=$?
check FRESH "exit code" 0 "$rc"

echo "5. a relative path still yields an absolute remedy"
echo dirty > "$REPO/c.txt"
out="$(cd "$REPO" && "$GATE" .)"
contains "relative-arg run" "graphify update $REPO" "$out"

echo "6. a commit touching only graphify-out/ after the build -> FRESH, not STALE"
rm -f "$REPO/c.txt"
git -C "$REPO" add -f graphify-out && git -C "$REPO" commit -qm graph
out="$("$GATE" "$REPO")"; rc=$?
check "graph-only commit" "exit code" 0 "$rc"
contains "graph-only commit" "touch only graphify-out/" "$out"
if grep -q 'WARNING' <<<"$out"; then echo "  FAIL: warned with no .graphify_root tracked" >&2; fail=1; fi

echo "7. a tracked graphify-out/.graphify_root is warned about, verdict unchanged"
echo "$REPO" > "$REPO/graphify-out/.graphify_root"
git -C "$REPO" add -f graphify-out/.graphify_root && git -C "$REPO" commit -qm root
out="$("$GATE" "$REPO")"; rc=$?
check ".graphify_root" "exit code" 0 "$rc"
contains ".graphify_root" "WARNING: graphify-out/.graphify_root is committed" "$out"
contains ".graphify_root" "git rm --cached graphify-out/.graphify_root" "$out"
git -C "$REPO" rm -q --cached graphify-out/.graphify_root && git -C "$REPO" commit -qm unroot
rm -f "$REPO/graphify-out/.graphify_root"

echo "8. a code commit after the build -> STALE, listing the code file only"
echo code > "$REPO/d.txt" && git -C "$REPO" add d.txt && git -C "$REPO" commit -qm code
out="$("$GATE" "$REPO")"; rc=$?
check "code commit" "exit code" 1 "$rc"
contains "code commit" "d.txt" "$out"
if grep -q '^graphify-out/' <<<"$out"; then echo "  FAIL: STALE listing includes graphify-out/" >&2; fail=1; fi

echo "9. built_at_commit not in this clone -> UNKNOWN, not STALE"
printf '{"built_at_commit": "%s", "nodes": []}' "0123456789abcdef0123456789abcdef01234567" \
  > "$REPO/graphify-out/graph.json"
out="$("$GATE" "$REPO")"; rc=$?
check "missing built commit" "exit code" 3 "$rc"
contains "missing built commit" "not a commit in this clone" "$out"
contains "missing built commit" "graphify update $REPO" "$out"

if [[ $fail -eq 0 ]]; then echo "graph freshness check: ok"; else
  echo "graph freshness check: FAILED" >&2; fi
exit $fail
