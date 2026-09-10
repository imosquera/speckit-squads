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
check "mode A diff_range is <merge-base>...HEAD" "$BASE...HEAD" "$(get diff_range)"
# the range the reviewer is handed must actually resolve to the changed files
check "mode A diff_range resolves" "a.txt" "$(git -C "$REPO" diff --name-only "$(get diff_range)")"
# repo_root is the worktree root, not wherever the caller happened to stand
mkdir -p "$REPO/sub"
OUT=$(cd "$REPO/sub" && "$DETECT" --json)
check "repo_root ignores caller cwd" "$(git -C "$REPO" rev-parse --show-toplevel)" "$(get repo_root)"

# --- Mode B: on the default branch, uncommitted only ---
git -C "$REPO" checkout -q main
echo dirty >> "$REPO/a.txt"
OUT=$(cd "$REPO" && "$DETECT" --json)
check "mode B repo_root still reported" "$(git -C "$REPO" rev-parse --show-toplevel)" "$(get repo_root)"
check "mode B diff_range is empty" "" "$(get diff_range)"

[[ $fail -eq 0 ]] && echo "PASS" || echo "FAIL"
exit $fail
