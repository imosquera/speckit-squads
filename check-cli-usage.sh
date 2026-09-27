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
  SKIP_CLI=1
fi

# verbs_of <args...> -> space-separated command names from a --help Commands panel
verbs_of() {
  specify "$@" --help 2>/dev/null | sed -n '/Commands/,/╰/p' \
    | grep -oE '^│ [a-z][a-z-]*' | tr -d '│ '
}

SKIP_CLI="${SKIP_CLI:-}"
TOP_VERBS=""
[[ -z "$SKIP_CLI" ]] && TOP_VERBS="$(verbs_of)"
if [[ -z "$SKIP_CLI" && -z "$TOP_VERBS" ]]; then
  echo "warn: could not parse \`specify --help\` — skipping CLI surface check" >&2
  SKIP_CLI=1
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


if [[ -z "$SKIP_CLI" ]]; then
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
fi


# ---------------------------------------------------------------------------
# Script-path check.
#
# Extension/preset scripts install to `.specify/{extensions,presets}/<id>/scripts/…`,
# NOT into the flat core `.specify/scripts/bash/` tree. Command names also do not
# predict script names (`/speckit-git-feature` runs `create-new-feature.sh`), so a
# wrong path is easy to write and invisible until an agent runs it and gets ENOENT.
#
# Enforced here so it cannot ship:
#   1. every `provides.scripts[].file` in a manifest exists on disk
#   2. every script path a command file tells an agent to run resolves to a real file
#   3. every extension/preset script a command file references is declared in its manifest
#   4. no command file references `.specify/scripts/bash/<subdir>/…` — the core tree is flat
#   5. no bash block uses a bare `$CLAUDE_PROJECT_DIR` — it is empty in an ordinary
#      interactive session, so the path starts at `/` and the call dies with exit 127
#      (issue #59). Use `${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}`, and
#      re-derive it in every block: each bash call is its own shell.
# Runs with or without the `specify` CLI on PATH.
# ---------------------------------------------------------------------------
# Runs as TypeScript under bun (scripts/check-script-paths.ts). bun is required.
if ! command -v bun >/dev/null 2>&1; then
  echo "error: bun not on PATH — required for the script-path check (https://bun.sh)" >&2
  fail=1
else
  bun "$REPO_DIR/scripts/check-script-paths.ts" || fail=1
fi

# Every shipped bash script must parse. Cheap, and it catches the trap that a
# heredoc inside $( ) still scans its body for quotes — an odd apostrophe in
# prose there is a syntax error reported a hundred lines away.
syntax_bad=0
while IFS= read -r script; do
  bash -n "$script" || { echo "error: $script does not parse" >&2; syntax_bad=1; }
done < <(find extensions presets -path '*/scripts/bash/*.sh' -type f 2>/dev/null)
if [[ $syntax_bad -ne 0 ]]; then fail=1; else
  echo "bash syntax check: ok"
fi

# Our own JS tooling is TypeScript run by bun and typechecked by TS 7. Guarded:
# install.sh runs this as pre-flight on machines that may have no bun, or may
# never have run `bun install` in this checkout.
if ! command -v bun >/dev/null 2>&1; then
  echo "warn: bun not on PATH — skipping TypeScript typecheck" >&2
elif [[ ! -x node_modules/.bin/tsc ]]; then
  echo "warn: node_modules missing — run \`bun install\` here; skipping TypeScript typecheck" >&2
elif bun run --silent typecheck; then
  echo "typecheck: ok"
else
  echo "error: \`bun run typecheck\` failed" >&2
  fail=1
fi

if [[ $fail -ne 0 ]]; then
  echo "error: pre-flight checks failed" >&2
  exit 1
fi

echo "CLI surface check: ok (${#files[@]} command files)"
