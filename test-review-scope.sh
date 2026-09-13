#!/usr/bin/env bash
# Check that detect-changed-files.sh reports the scope a reviewer must be given:
# the absolute worktree root and the exact diff base — for local changes (Modes
# A/B) and for a pull request (Mode C, `--pr <N>`, with `gh` stubbed on PATH).
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

# --- Mode C: --pr <N>, with `gh` stubbed on PATH ---
# A bare "origin" holds main and the PR branch; the review runs from a clone that
# has never seen the PR head, so the detector must fetch it. The stub answers
# `gh pr view` from $STUB_VIEW (applying --jq like the real gh) and
# `gh pr diff --name-only` from $STUB_DIFF; STUB_FAIL=1 makes every call fail.
if ! command -v jq >/dev/null 2>&1; then
  echo "  FAIL: jq is required for the Mode C tests" >&2; fail=1
else
  STUBBIN="$TMP/bin"; mkdir -p "$STUBBIN"
  cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
[[ "${STUB_FAIL:-}" == 1 ]] && { echo "gh: HTTP 404: Not Found" >&2; exit 1; }
case "$1 $2" in
  "pr view")
    jqexpr="."; while [[ $# -gt 0 ]]; do [[ "$1" == --jq ]] && jqexpr="$2"; shift; done
    jq -r "$jqexpr" <<<"$STUB_VIEW" ;;
  "pr diff") printf '%s\n' "$STUB_DIFF" ;;
  *) echo "stub gh: unexpected $*" >&2; exit 1 ;;
esac
STUB
  chmod +x "$STUBBIN/gh"

  ORIGIN="$TMP/origin.git"; SEED="$TMP/seed"; CLONE="$TMP/clone"
  git init -q --bare -b main "$ORIGIN"
  git clone -q "$ORIGIN" "$SEED" 2>/dev/null
  git -C "$SEED" config user.email t@t && git -C "$SEED" config user.name t
  echo base > "$SEED/keep.txt"; echo doomed > "$SEED/gone.txt"
  git -C "$SEED" add -A && git -C "$SEED" commit -qm base && git -C "$SEED" push -q origin main
  PR_BASE=$(git -C "$SEED" rev-parse HEAD)
  git clone -q "$ORIGIN" "$CLONE" 2>/dev/null   # before the PR exists: no head object
  git -C "$SEED" checkout -qb feat/pr
  echo edit >> "$SEED/keep.txt"; echo new > "$SEED/added.txt"; git -C "$SEED" rm -q gone.txt
  mkdir -p "$SEED/graphify-out"; echo '{}' > "$SEED/graphify-out/graph.json"
  git -C "$SEED" add -A && git -C "$SEED" commit -qm pr && git -C "$SEED" push -q origin feat/pr
  PR_HEAD=$(git -C "$SEED" rev-parse HEAD)

  view() { printf '{"number":7,"headRefName":"feat/pr","headRefOid":"%s","baseRefName":"main","url":"https://github.com/o/r/pull/7","title":"Add \\"thing\\"","isCrossRepository":%s}' "$1" "${2:-false}"; }
  export STUB_DIFF="keep.txt
added.txt
gone.txt
graphify-out/graph.json"
  runc() { (cd "$1" && PATH="$STUBBIN:$PATH" "$DETECT" --json --pr 7); }
  jget() { jq -r "$1" <<<"$OUT"; }

  # checkout=none: the head branch is checked out nowhere, so reviewers get the
  # current checkout plus a head sha to read through git objects.
  export STUB_VIEW="$(view "$PR_HEAD")"
  OUT=$(runc "$CLONE"); rc=$?
  check "mode C (none) exits 0" "0" "$rc"
  check "mode C (none) checkout" "none" "$(jget .checkout)"
  check "mode C (none) repo_root is the current checkout" "$(git -C "$CLONE" rev-parse --show-toplevel)" "$(jget .repo_root)"
  check "mode C (none) head is the PR head sha" "$PR_HEAD" "$(jget .head)"
  check "mode C (none) head was fetched" "commit" "$(git -C "$CLONE" cat-file -t "$PR_HEAD" 2>/dev/null)"
  check "mode C diff_base is merge-base(origin/main, head)" "$PR_BASE" "$(jget .diff_base)"
  check "mode C pr / pr_url / pr_title" "7|https://github.com/o/r/pull/7|Add \"thing\"" "$(jget '"\(.pr)|\(.pr_url)|\(.pr_title)"')"
  # deletions dropped (as ACMR does in A/B); graphify-out left for the coordinator
  check "mode C changed_files from gh minus deletions" "keep.txt added.txt graphify-out/graph.json" "$(jget '.changed_files|join(" ")')"
  check "mode C diff <base> <head> resolves" "added.txt
gone.txt
graphify-out/graph.json
keep.txt" "$(git -C "$CLONE" diff --name-only "$(jget .diff_base)" "$(jget .head)")"
  check "mode C git show <head>:<path> reads the PR copy" "base
edit" "$(git -C "$CLONE" show "$(jget .head):keep.txt")"

  # checkout=worktree: the head branch is checked out in a worktree whose path has
  # a space — repo_root must be that whole path, not a space-split fragment.
  WT="$TMP/wt with space"
  git -C "$CLONE" worktree add -q "$WT" -b feat/pr "$PR_HEAD" 2>/dev/null
  OUT=$(runc "$CLONE"); rc=$?
  check "mode C (worktree) exits 0" "0" "$rc"
  check "mode C (worktree) checkout" "worktree" "$(jget .checkout)"
  check "mode C (worktree) repo_root is the worktree path" "$(cd "$WT" && pwd -P)" "$(cd "$(jget .repo_root)" 2>/dev/null && pwd -P)"
  check "mode C (worktree) branch is the head branch" "feat/pr" "$(jget .branch)"
  check "mode C (worktree) HEAD matches head" "$(jget .head)" "$(git -C "$(jget .repo_root)" rev-parse HEAD)"

  # A fork's branch name says nothing about a same-named local branch.
  export STUB_VIEW="$(view "$PR_HEAD" true)"
  OUT=$(runc "$CLONE")
  check "mode C cross-repo PR never binds a local worktree" "none" "$(jget .checkout)"

  # Failures are loud: gh failing, or a head that cannot be obtained.
  OUT=$(cd "$CLONE" && STUB_FAIL=1 PATH="$STUBBIN:$PATH" "$DETECT" --json --pr 7); rc=$?
  check "mode C gh failure exits 1" "1" "$rc"
  case "$(jget .error)" in *"gh pr view 7 failed"*) echo "  ok: gh failure message names the call" ;;
    *) echo "  FAIL: gh failure message unclear: $OUT" >&2; fail=1 ;; esac
  export STUB_VIEW="$(view 0123456789abcdef0123456789abcdef01234567)"
  OUT=$(runc "$CLONE"); rc=$?
  check "mode C unobtainable head exits 1" "1" "$rc"
  (cd "$CLONE" && PATH="$STUBBIN:$PATH" "$DETECT" --json --pr >/dev/null 2>&1); rc=$?
  check "--pr with no number exits 1" "1" "$rc"

  # Modes A/B keep the same JSON shape: the Mode C keys exist, empty.
  OUT=$(cd "$REPO" && "$DETECT" --json)
  check "mode A/B carry empty pr/pr_url/head/checkout" "|||" "$(jget '"\(.pr)|\(.pr_url)|\(.head)|\(.checkout)"')"
fi

[[ $fail -eq 0 ]] && echo "PASS" || echo "FAIL"
exit $fail
