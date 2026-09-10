#!/usr/bin/env bash
# Check that detect-changed-files.sh reports the scope a reviewer must be given:
# the absolute worktree root and the exact diff range.
#
# Without them the coordinator re-derives scope from its own cwd, and a reviewer
# forked in the main checkout reviewed an unrelated working tree while looking
# exactly like a clean pass (issue #52).
#
# Usage: ./test-review-scope.sh
set -uo pipefail

DETECT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/extensions/review/scripts/bash/detect-changed-files.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

check() { # check <what> <expected> <actual>
  if [[ "$2" == "$3" ]]; then echo "  ok: $1"; else
    echo "  FAIL: $1 — expected '$2', got '$3'" >&2; fail=1
  fi
}

REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@t && git -C "$REPO" config user.name t
echo base > "$REPO/a.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -qm base
# origin/main is what the detector resolves the merge-base against
git -C "$REPO" remote add origin "$REPO"
git -C "$REPO" update-ref refs/remotes/origin/main main
BASE=$(git -C "$REPO" rev-parse main)

# --- Mode A: feature branch ---
git -C "$REPO" checkout -qb feat
echo change >> "$REPO/a.txt"
git -C "$REPO" commit -qam change
OUT=$(cd "$REPO" && "$DETECT" --json)

get() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" <<<"$OUT"; }
check "mode A repo_root is the worktree root" "$(git -C "$REPO" rev-parse --show-toplevel)" "$(get repo_root)"
check "mode A diff_base is the merge-base" "$BASE" "$(get diff_base)"
# the base the reviewer is handed must resolve to the changed files
check "mode A diff_base resolves" "a.txt" "$(git -C "$REPO" diff --name-only "$(get diff_base)")"

# A two-dot diff against the base reaches the working tree; a three-dot range would
# compare two commits and drop uncommitted work the detector still lists.
echo uncommitted >> "$REPO/b.txt"
git -C "$REPO" add b.txt
OUT=$(cd "$REPO" && "$DETECT" --json)
check "diff_base covers staged work" "a.txt
b.txt" "$(git -C "$REPO" diff --name-only "$(get diff_base)")"
git -C "$REPO" reset -q && rm -f "$REPO/b.txt"
# repo_root is the worktree root, not wherever the caller happened to stand
mkdir -p "$REPO/sub"
OUT=$(cd "$REPO/sub" && "$DETECT" --json)
check "repo_root ignores caller cwd" "$(git -C "$REPO" rev-parse --show-toplevel)" "$(get repo_root)"

# --- Mode B: on the default branch, uncommitted only ---
git -C "$REPO" checkout -q main
echo dirty >> "$REPO/a.txt"
OUT=$(cd "$REPO" && "$DETECT" --json)
check "mode B repo_root still reported" "$(git -C "$REPO" rev-parse --show-toplevel)" "$(get repo_root)"
check "mode B diff_base is empty" "" "$(get diff_base)"

# Untracked files appear in no diff at all, in either mode — changed_files is the
# only place a reviewer can learn about them, so it must list them.
git -C "$REPO" checkout -q -- a.txt
echo new > "$REPO/brand-new.txt"
OUT=$(cd "$REPO" && "$DETECT" --json)
case "$OUT" in
  *'"brand-new.txt"'*) echo "  ok: untracked-only change set is still reported" ;;
  *) echo "  FAIL: untracked-only change set missing from changed_files" >&2; fail=1 ;;
esac
check "untracked-only diff is empty (so the file list must carry it)" "" "$(git -C "$REPO" diff --name-only HEAD)"

[[ $fail -eq 0 ]] && echo "PASS" || echo "FAIL"
exit $fail
