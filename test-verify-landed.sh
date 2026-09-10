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
# Physical path: git reports worktree paths resolved, and on macOS $TMPDIR is a
# symlink — a logical path makes clean.sh mistake the primary checkout for a
# secondary worktree and try to remove it.
TMP="$(cd "$(mktemp -d)" && pwd -P)"
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

echo "11. squash landed on the fetched origin/main while local main is stale -> LANDED"
# The everyday GitHub flow: the squash is created on the remote, so origin/main
# moves and the local `main` branch does not. Resolving the local branch first
# compares the branch against a base that predates its own merge.
R="$TMP/stale-base"; new_repo "$R"
BARE="$TMP/stale-base-origin.git"; git init -q --bare -b main "$BARE"
git -C "$R" remote add origin "$BARE"
PRE_MERGE="$(git -C "$R" rev-parse main)"
git -C "$R" checkout -qb feat
for d in functions web infra specs; do echo work > "$R/$d/f.txt"; done
git -C "$R" add -A && git -C "$R" commit -qm "feature work"
git -C "$R" checkout -q main
git -C "$R" merge --squash -q feat >/dev/null && git -C "$R" commit -qm "feat (#11)"
git -C "$R" push -q origin main
git -C "$R" reset -q --hard "$PRE_MERGE"   # local main back to pre-merge; origin/main has the squash
run feat --repo "$R"
check stale-base "exit code" 0 "$RC"
check stale-base "verdict" LANDED "$(verdict)"
contains stale-base "origin/main" "$OUT"

echo "12. path changed then reverted after the squash -> NOT-LANDED"
# The endpoint tree diff forgets a path the branch changed and changed back; the
# commit history does not. Without the history the revert of functions/f.txt is
# invisible and the branch reads LANDED off the one path that still differs.
R="$TMP/reverted"; new_repo "$R"
git -C "$R" checkout -qb feat
echo work > "$R/functions/f.txt"; echo work > "$R/web/f.txt"
git -C "$R" add -A && git -C "$R" commit -qm "change f and g"
git -C "$R" checkout -q main
git -C "$R" merge --squash -q feat >/dev/null && git -C "$R" commit -qm "feat (#12)"
git -C "$R" checkout -q feat
echo base > "$R/functions/f.txt"           # back to the fork-point content
git -C "$R" add -A && git -C "$R" commit -qm "revert functions/f.txt"
git -C "$R" checkout -q main
run feat --repo "$R"
check reverted "exit code" 1 "$RC"
check reverted "verdict" NOT-LANDED "$(verdict)"
contains reverted "functions/f.txt" "$OUT"

# --- clean.sh: the gate must fail closed, not skip ---------------------------
CLEAN_SRC="$(dirname "$VERIFY")"
clean_repo() { # clean_repo <path> — a repo with its own copy of the script tree
  local r="$1"
  new_repo "$r"
  mkdir -p "$r/ext/scripts/bash"
  cp "$CLEAN_SRC"/*.sh "$r/ext/scripts/bash/"
  chmod +x "$r/ext/scripts/bash/"*.sh
  git -C "$r" add -A && git -C "$r" commit -qm scripts
}
run_clean() { OUT="$("$1/ext/scripts/bash/clean.sh" "${@:2}" 2>&1)"; RC=$?; }

echo "13. clean.sh on a detached HEAD carrying unlanded work -> refuse"
R="$TMP/clean-detached"; clean_repo "$R"
git -C "$R" checkout -qb feat
echo stranded > "$R/infra/late.txt"
git -C "$R" add -A && git -C "$R" commit -qm "late fix"
git -C "$R" checkout -q main
git -C "$R" checkout -q --detach feat
run_clean "$R" --worktree "$R"
check detached "exit code" 1 "$RC"
contains detached "refusing" "$OUT"
run_clean "$R" --worktree "$R" --force
check detached-force "exit code (--force is the escape hatch)" 0 "$RC"

echo "14. clean.sh with a verifier it cannot run -> refuse"
R="$TMP/clean-noverify"; clean_repo "$R"
git -C "$R" checkout -qb feat
echo stranded > "$R/infra/late.txt"
git -C "$R" add -A && git -C "$R" commit -qm "late fix"
chmod -x "$R/ext/scripts/bash/verify-landed.sh"
git -C "$R" add -A && git -C "$R" commit -qm "verifier no longer executable"
run_clean "$R" --worktree "$R"
check no-verifier "exit code" 1 "$RC"
contains no-verifier "not executable" "$OUT"

if [[ "$fail" -eq 0 ]]; then echo "ALL PASS"; else echo "FAILURES" >&2; fi
exit "$fail"
