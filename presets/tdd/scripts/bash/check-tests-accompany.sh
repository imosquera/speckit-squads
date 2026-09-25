#!/usr/bin/env bash
# tdd preset: check-tests-accompany.sh
# Fails when the change set touches production source but no test file.
#
# Usage: check-tests-accompany.sh [--base <ref>]
#
# The change set is everything since the merge-base with <base>: committed,
# staged, unstaged, and untracked. <base> defaults to the remote default branch
# (origin/HEAD), then origin/main, main, origin/master, master.
#
# Exit codes:
#   0  production changes are accompanied by test changes (or only tests /
#      non-source files changed)
#   1  production source changed with no test change — the list is printed
#   2  usage error, not a git worktree, or no resolvable base
#   4  empty change set — nothing was examined, which is NOT a pass

set -uo pipefail

base=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --base) [[ $# -ge 2 && -n "$2" ]] || { echo "error: --base needs a ref" >&2; exit 2; }
                base="$2"; shift 2 ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "error: unknown option: $1" >&2; exit 2 ;;
    esac
done

root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "error: not inside a git worktree" >&2; exit 2; }
cd "$root" || exit 2

if [[ -z "$base" ]]; then
    for cand in "$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)" \
                origin/main main origin/master master; do
        [[ -n "$cand" ]] && git rev-parse -q --verify "$cand^{commit}" >/dev/null && { base="$cand"; break; }
    done
fi
[[ -n "$base" ]] || { echo "error: no base ref resolvable; pass --base <ref>" >&2; exit 2; }
mb="$(git merge-base "$base" HEAD 2>/dev/null)" || { echo "error: no merge-base between $base and HEAD" >&2; exit 2; }

changed="$( { git diff --name-only --diff-filter=d "$mb"; git ls-files --others --exclude-standard; } | sort -u)"
[[ -n "$changed" ]] || { echo "tdd: empty change set against $base — nothing examined"; exit 4; }

is_test() {
    local p="$1" b="${1##*/}"
    [[ "/$p" =~ /(tests?|__tests__|specs?|testing)/ ]] && return 0
    [[ "$b" =~ ^test_.*\.py$ || "$b" =~ _test\.(py|go|rb|exs?)$ || "$b" =~ \.(test|spec)\.[A-Za-z]+$ \
       || "$b" =~ _spec\.rb$ || "$b" =~ (Test|Tests|Spec)\.(java|kt|swift|cs|scala|php)$ || "$b" =~ ^test-.*\.sh$ ]]
}
is_source() {
    [[ "$1" =~ \.(py|ts|tsx|js|jsx|mjs|cjs|go|rs|rb|java|kt|swift|cs|php|c|cc|cpp|h|hpp|scala|ex|exs|sh)$ ]]
}

tests=0; prod=()
while IFS= read -r f; do
    if is_test "$f"; then tests=$((tests + 1))
    elif is_source "$f"; then prod+=("$f")
    fi
done <<< "$changed"

if [[ ${#prod[@]} -gt 0 && $tests -eq 0 ]]; then
    echo "tdd: production source changed against $base with no test change:"
    printf '  %s\n' "${prod[@]}"
    exit 1
fi
echo "tdd: ok — ${#prod[@]} production file(s), $tests test file(s) changed against $base"
exit 0
