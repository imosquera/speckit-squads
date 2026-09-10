#!/usr/bin/env bash
# Check the three verdicts of the git extension's landed gate, and that the
# squash-merge case reads as LANDED while an unlanded commit reads as a refusal.
#
# This repo squash-merges. A squash breaks ancestry, so `git branch -d`,
# `git branch --merged` and `git merge-base --is-ancestor` all report "not
# merged" for work that is safely on main — and fifteen-plus cleanup turns
# replaced them with a hand-typed path list that differed every run. A run that
# omits a path deletes a branch holding work in it (issue #49).
#
# Usage: ./test-verify-landed.sh
set -uo pipefail

VERIFY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/extensions/git/scripts/bash/verify-landed.sh"
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

# A fresh repo with a main branch and one commit in each of several directories,
# so a check that quietly narrows to one directory shows up as a wrong verdict.
new_repo() { # new_repo <path>
  local r="$1"
  mkdir -p "$r" && git -C "$r" init -q -b main
  git -C "$r" config user.email t@t && git -C "$r" config user.name t
  mkdir -p "$r/functions" "$r/web" "$r/infra" "$r/specs"
  for d in functions web infra specs; do echo base > "$r/$d/f.txt"; done
  git -C "$r" add -A && git -C "$r" commit -qm base
}

run() { OUT="$("$VERIFY" "$@" --no-fetch 2>&1)"; RC=$?; }
# The verdict is the first word of the first line. Matched whole, because
# `grep LANDED` also matches NOT-LANDED — the exact confusion this gate exists
# to prevent.
verdict() { head -1 <<<"$OUT" | cut -d: -f1; }

echo "1. squash-merged branch -> LANDED (ancestry says otherwise, content does not)"
R="$TMP/squash"; new_repo "$R"
git -C "$R" checkout -qb feat
for d in functions web infra specs; do echo work > "$R/$d/f.txt"; done
git -C "$R" add -A && git -C "$R" commit -qm "feature work"
git -C "$R" checkout -q main
git -C "$R" merge --squash -q feat >/dev/null && git -C "$R" commit -qm "feat (#1)"
# The three checks every agent reaches for first all say "not merged" here.
if git -C "$R" merge-base --is-ancestor feat main; then
  echo "  FAIL: precondition — squash left ancestry intact, test proves nothing" >&2; fail=1
else
  echo "  ok: precondition — merge-base --is-ancestor still reports not-merged"
fi
run feat --repo "$R"
check squash "exit code" 0 "$RC"
check squash "verdict" LANDED "$(verdict)"

echo "2. commit pushed after the squash -> NOT-LANDED (the near-miss from #49)"
echo "stranded" > "$R/infra/late.txt"
git -C "$R" checkout -q feat
git -C "$R" add -A && git -C "$R" commit -qm "late fix"
git -C "$R" checkout -q main
run feat --repo "$R"
check stranded "exit code" 1 "$RC"
check stranded "verdict" NOT-LANDED "$(verdict)"
contains stranded "infra/late.txt" "$OUT"

echo "3. never-merged branch -> NOT-LANDED"
R="$TMP/never"; new_repo "$R"
git -C "$R" checkout -qb solo
echo mine > "$R/web/only-here.txt"
git -C "$R" add -A && git -C "$R" commit -qm solo
git -C "$R" checkout -q main
run solo --repo "$R"
check unmerged "exit code" 1 "$RC"
contains unmerged "web/only-here.txt" "$OUT"

echo "4. true merge -> LANDED via ancestry"
R="$TMP/merged"; new_repo "$R"
git -C "$R" checkout -qb feat
echo work > "$R/web/f.txt" && git -C "$R" commit -qaqm work
git -C "$R" checkout -q main && git -C "$R" merge -q --no-ff -m merge feat
run feat --repo "$R"
check merge "exit code" 0 "$RC"
contains merge "ancestor" "$OUT"

echo "5. rebase-and-merge -> LANDED (new shas, identical content)"
R="$TMP/rebase"; new_repo "$R"
git -C "$R" checkout -qb feat
echo work > "$R/functions/f.txt" && git -C "$R" commit -qaqm work
git -C "$R" checkout -q main
echo other > "$R/specs/f.txt" && git -C "$R" commit -qaqm other
git -C "$R" cherry-pick feat >/dev/null 2>&1
run feat --repo "$R"
check rebase "exit code" 0 "$RC"
check rebase "verdict" LANDED "$(verdict)"

echo "6. base moved on independently -> still LANDED (the gate must not cry wolf)"
echo more > "$R/web/f.txt" && git -C "$R" commit -qaqm "unrelated main work"
run feat --repo "$R"
check moved-base "exit code" 0 "$RC"

echo "7. unknown branch -> UNKNOWN, and UNKNOWN refuses"
run no-such-branch --repo "$R"
check unknown-branch "exit code" 2 "$RC"
check unknown-branch "verdict" UNKNOWN "$(verdict)"
contains unknown-branch "do not delete" "$OUT"

echo "8. unresolvable base -> UNKNOWN, never a pass"
run feat --repo "$R" --base release-that-does-not-exist
check unknown-base "exit code" 2 "$RC"
check unknown-base "verdict" UNKNOWN "$(verdict)"

echo "9. differences confined to an excluded path -> LANDED"
R="$TMP/excluded"; new_repo "$R"
git -C "$R" checkout -qb feat
mkdir -p "$R/graphify-out" && echo generated > "$R/graphify-out/graph.json"
git -C "$R" add -A && git -C "$R" commit -qm graph
git -C "$R" checkout -q main
run feat --repo "$R"
check excluded-off "exit code (not excluded yet)" 1 "$RC"
run feat --repo "$R" --exclude graphify-out
check excluded-on "exit code" 0 "$RC"

echo "10. --json emits a machine-readable verdict"
R="$TMP/json"; new_repo "$R"
git -C "$R" checkout -qb feat && echo w > "$R/web/f.txt" && git -C "$R" commit -qaqm w
git -C "$R" checkout -q main && git -C "$R" merge --squash -q feat >/dev/null \
  && git -C "$R" commit -qm "feat (#2)"
run feat --repo "$R" --json
check json "exit code" 0 "$RC"
contains json '"landed": true' "$OUT"
contains json '"paths_checked"' "$OUT"

if [[ "$fail" -eq 0 ]]; then echo "ALL PASS"; else echo "FAILURES" >&2; fi
exit "$fail"
