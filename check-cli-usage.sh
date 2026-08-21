#!/usr/bin/env bash
# Verify that every `specify <verb> [<subverb>]` an extension/preset instructs an agent
# to run actually exists in the installed CLI.
#
# Scans fenced bash blocks in extensions/*/commands/*.md and presets/*/commands/*.md,
# extracts `specify` invocations, and checks the verb (and subverb) against
# `specify --help` / `specify <verb> --help`. Prose outside code fences is ignored —
# only lines an agent would actually execute are checked.
#
# Usage: ./check-cli-usage.sh          # exit 1 on any unknown verb
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

if ! command -v specify >/dev/null 2>&1; then
  echo "warn: specify CLI not on PATH — skipping CLI surface check" >&2
  exit 0
fi

# verbs_of <args...> -> space-separated command names from a --help Commands panel
verbs_of() {
  specify "$@" --help 2>/dev/null | sed -n '/Commands/,/╰/p' \
    | grep -oE '^│ [a-z][a-z-]*' | tr -d '│ '
}

TOP_VERBS="$(verbs_of)"
if [[ -z "$TOP_VERBS" ]]; then
  echo "warn: could not parse \`specify --help\` — skipping CLI surface check" >&2
  exit 0
fi

fail=0

# Emit "file:line:verb:subverb" for each specify invocation inside a bash fence.
scan() {
  awk '
    /^[[:space:]]*```/ { infence = !infence; next }
    !infence { next }
    {
      line = $0
      while (match(line, /(^|[^[:alnum:]_.\/-])specify[[:space:]]+[a-z][a-z-]*([[:space:]]+[a-z][a-z-]*)?/)) {
        inv = substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
        sub(/^[^s]*/, "", inv)
        n = split(inv, w, /[[:space:]]+/)
        print FILENAME ":" FNR ":" w[2] ":" (n >= 3 ? w[3] : "")
      }
    }
  ' "$@"
}

shopt -s nullglob
files=(extensions/*/commands/*.md presets/*/commands/*.md)
[[ ${#files[@]} -eq 0 ]] && exit 0

while IFS=: read -r file line verb sub; do
  [[ -z "$verb" ]] && continue
  if ! grep -qx -- "$verb" <<<"$TOP_VERBS"; then
    echo "$file:$line: unknown \`specify $verb\` — not a CLI command" >&2
    fail=1
    continue
  fi
  [[ -z "$sub" ]] && continue
  subverbs="$(verbs_of "$verb")"
  # A verb with no subcommand panel takes free-form args; nothing to check.
  [[ -z "$subverbs" ]] && continue
  if ! grep -qx -- "$sub" <<<"$subverbs"; then
    echo "$file:$line: unknown \`specify $verb $sub\` — valid: $(tr '\n' ' ' <<<"$subverbs")" >&2
    fail=1
  fi
done < <(scan "${files[@]}")

if [[ $fail -ne 0 ]]; then
  echo "error: command files reference CLI surface that does not exist" >&2
  exit 1
fi

echo "CLI surface check: ok (${#files[@]} command files)"
