#!/usr/bin/env bash
# Check the git extension's one handler for `commit_exclude` churn.
#
# `commit_exclude` used to be enforced only by auto-commit.sh's `:(exclude)`
# pathspec, which never runs where `auto_commit.default` is false — so the
# derived data the list exists to keep off a branch landed on it anyway (issue
# #62), and every phase improvised its own recovery from a background rebuild's
# churn (issue #55).
#
# Usage: ./test-commit-exclude.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRUB="$ROOT/extensions/git/scripts/bash/scrub-commit-exclude.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

check() { # check <what> <desc> <expected> <actual>
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

# A repo shaped like a consumer project: the extension installed under
# .specify/extensions/git/, with graphify-out/ tracked and excluded.
make_repo() { # make_repo <dir> [<commit_exclude yaml body>]
  local repo="$1" excl="${2:-  - graphify-out}"
  mkdir -p "$repo/.specify/extensions/git/scripts/bash"
  cp "$ROOT/extensions/git/scripts/bash/git-common.sh" \
     "$ROOT/extensions/git/scripts/bash/scrub-commit-exclude.sh" \
     "$repo/.specify/extensions/git/scripts/bash/"
  printf 'squash_before_pr: true\ncommit_exclude:\n%s\n\nauto_commit:\n  default: false\n' \
    "$excl" > "$repo/.specify/extensions/git/git-config.yml"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
  mkdir -p "$repo/graphify-out"
  echo '{"nodes":[]}' > "$repo/graphify-out/graph.json"
  echo 'source' > "$repo/app.txt"
  git -C "$repo" add -A >/dev/null && git -C "$repo" commit -qm base
}
scrub() { "$1/.specify/extensions/git/scripts/bash/scrub-commit-exclude.sh" --repo "$1" "${@:2}" 2>&1; }

echo "1. a modified excluded path is restored to HEAD; real work is untouched"
R="$TMP/r1"; make_repo "$R"
echo '{"nodes":[1,2,3]}' > "$R/graphify-out/graph.json"
echo 'edited' > "$R/app.txt"
out="$(scrub "$R")"; rc=$?
check scrub "exit code" 0 "$rc"
contains scrub "graphify-out" "$out"
check graph "restored" '{"nodes":[]}' "$(cat "$R/graphify-out/graph.json")"
check work "preserved" "edited" "$(cat "$R/app.txt")"

echo "2. untracked output under an excluded path is removed"
R="$TMP/r2"; make_repo "$R"
mkdir -p "$R/graphify-out/2026-09-10"
echo '{"cost":1}' > "$R/graphify-out/2026-09-10/cost.json"
scrub "$R" >/dev/null
check untracked "removed" "absent" \
  "$([[ -e "$R/graphify-out/2026-09-10/cost.json" ]] && echo present || echo absent)"

echo "3. a STAGED excluded path is unstaged, not committed"
R="$TMP/r3"; make_repo "$R"
echo '{"nodes":[9]}' > "$R/graphify-out/graph.json"
echo 'edited' > "$R/app.txt"
git -C "$R" add -A >/dev/null            # the flow's own `git add -A`
scrub "$R" >/dev/null
check staged "index carries no excluded path" "" \
  "$(git -C "$R" diff --cached --name-only -- graphify-out)"
check staged "real work still staged" "app.txt" \
  "$(git -C "$R" diff --cached --name-only -- app.txt)"

echo "4. the hook enforces it even with auto_commit disabled (issue #62)"
# auto-commit.sh scrubs BEFORE reading the config, so `default: false` — which
# exits 0 without committing — must still leave the excluded path clean.
R="$TMP/r4"; make_repo "$R"
cp "$ROOT/extensions/git/scripts/bash/auto-commit.sh" \
   "$R/.specify/extensions/git/scripts/bash/"
echo '{"nodes":[7]}' > "$R/graphify-out/graph.json"
(cd "$R" && "$R/.specify/extensions/git/scripts/bash/auto-commit.sh" after_plan >/dev/null 2>&1)
check auto-commit "excluded path restored despite auto_commit: false" \
  '{"nodes":[]}' "$(cat "$R/graphify-out/graph.json")"
check auto-commit "no commit made" "base" "$(git -C "$R" log -1 --pretty=%s)"

echo "5. an empty commit_exclude list is a silent no-op"
R="$TMP/r5"; make_repo "$R" "  []"
printf 'commit_exclude: []\nauto_commit:\n  default: false\n' \
  > "$R/.specify/extensions/git/git-config.yml"
echo '{"nodes":[4]}' > "$R/graphify-out/graph.json"
out="$(scrub "$R")"; rc=$?
check empty-list "exit code" 0 "$rc"
check empty-list "no output" "" "$out"
check empty-list "leaves the tree alone" '{"nodes":[4]}' "$(cat "$R/graphify-out/graph.json")"

echo "6. a clean tree scrubs nothing and still exits 0"
R="$TMP/r6"; make_repo "$R"
out="$(scrub "$R")"; rc=$?
check clean-tree "exit code" 0 "$rc"
contains clean-tree "nothing to scrub" "$out"

echo "7. --require-clean flags dirt OUTSIDE the excluded paths only"
R="$TMP/r7"; make_repo "$R"
echo '{"nodes":[5]}' > "$R/graphify-out/graph.json"
out="$(scrub "$R" --require-clean)"; rc=$?
check require-clean "excluded-only dirt exits 0" 0 "$rc"
echo 'edited' > "$R/app.txt"
out="$(scrub "$R" --require-clean)"; rc=$?
check require-clean "real dirt exits 2" 2 "$rc"
contains require-clean "app.txt" "$out"

echo "8. a rebuild in flight is waited for, not raced (issue #55)"
R="$TMP/r8"; make_repo "$R"
touch "$R/graphify-out/.rebuild.lock"
echo '{"nodes":[6]}' > "$R/graphify-out/graph.json"
out="$(SPECKIT_SCRUB_LOCK_TIMEOUT=2 scrub "$R")"
contains lock "Waiting for a rebuild in flight" "$out"
contains lock "scrubbing anyway" "$out"
check lock "still scrubs after the timeout" '{"nodes":[]}' "$(cat "$R/graphify-out/graph.json")"

echo "9. every caller reaches the one handler"
for f in auto-commit.sh create-pr.sh clean.sh; do
  if grep -q 'scrub-commit-exclude.sh' "$ROOT/extensions/git/scripts/bash/$f"; then
    echo "  ok: $f calls scrub-commit-exclude.sh"
  else
    echo "  FAIL: $f does not call scrub-commit-exclude.sh" >&2; fail=1
  fi
done
if grep -q 'scripts/bash/scrub-commit-exclude.sh' "$ROOT/extensions/git/extension.yml"; then
  echo "  ok: declared under provides.scripts"
else
  echo "  FAIL: scrub-commit-exclude.sh is not declared in extension.yml" >&2; fail=1
fi

echo "10. a NEWLY ADDED excluded file is left neither staged nor on disk"
# `git restore --staged` turns a staged addition into an untracked file, so a
# scrubber that read the untracked list once, before unstaging, reported success
# and left `?? graphify-out/...` behind for the next `git add` to commit.
R="$TMP/r10"; make_repo "$R"
mkdir -p "$R/graphify-out/2026-09-10"
echo '{"cost":1}' > "$R/graphify-out/2026-09-10/cost.json"
echo 'edited' > "$R/app.txt"
git -C "$R" add -A >/dev/null            # the flow's own `git add -A`
scrub "$R" >/dev/null
check new-addition "index carries no excluded path" "" \
  "$(git -C "$R" diff --cached --name-only -- graphify-out)"
check new-addition "nothing left untracked" "" \
  "$(git -C "$R" ls-files --others --exclude-standard -- graphify-out)"
check new-addition "removed from disk" "absent" \
  "$([[ -e "$R/graphify-out/2026-09-10/cost.json" ]] && echo present || echo absent)"
check new-addition "real work still staged" "app.txt" \
  "$(git -C "$R" diff --cached --name-only -- app.txt)"

if [[ $fail -eq 0 ]]; then echo "commit_exclude check: ok"; else
  echo "commit_exclude check: FAILED" >&2; fi
exit $fail
