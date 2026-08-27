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
# Runs with or without the `specify` CLI on PATH.
# ---------------------------------------------------------------------------
python3 - <<'PYEOF' || fail=1
import glob, os, re, sys

problems = []
declared = {}

def scripts_block(text):
    m = re.search(r'^provides:[ \t]*$\n(.*?)(?=^\S)', text + "\n\x00", re.M | re.S)
    if not m:
        return ""
    s = re.search(r'^  scripts:[ \t]*$\n(.*?)(?=^  \S|\Z)', m.group(1), re.M | re.S)
    return s.group(1) if s else ""

for kind, manifest in (("extensions", "extension.yml"), ("presets", "preset.yml")):
    for path in sorted(glob.glob(f"{kind}/*/{manifest}")):
        oid = path.split("/")[1]
        files = set(re.findall(r'^\s*file:\s*["\']?([^"\'\s]+)',
                               scripts_block(open(path).read()), re.M))
        declared[(kind, oid)] = files
        for f in sorted(files):
            if not os.path.isfile(os.path.join(kind, oid, f)):
                problems.append(f"{path}: declared script does not exist: {f}")

REF = re.compile(
    r'\.specify/(extensions|presets)/([A-Za-z0-9_-]+)/(scripts/[A-Za-z0-9_./-]+)'
    r'|\.specify/scripts/(bash|powershell|python)/([A-Za-z0-9_./-]+)')

cmd_files = sorted(glob.glob("extensions/*/commands/*.md") + glob.glob("presets/*/commands/*.md"))
for cf in cmd_files:
    owner_kind, owner_id = cf.split("/")[0], cf.split("/")[1]
    for lineno, line in enumerate(open(cf), 1):
        for m in REF.finditer(line):
            if m.group(1):
                kind, oid, rel = m.group(1), m.group(2), m.group(3)
                disk = os.path.join(kind, oid, rel)
                if not os.path.isfile(disk):
                    problems.append(f"{cf}:{lineno}: path does not exist: {m.group(0)}")
                elif (kind, oid) not in declared:
                    problems.append(f"{cf}:{lineno}: unknown {kind[:-1]} id '{oid}'")
                elif rel not in declared[(kind, oid)]:
                    problems.append(
                        f"{cf}:{lineno}: {rel} is not declared in {kind}/{oid}/"
                        f"{'extension.yml' if kind == 'extensions' else 'preset.yml'} "
                        f"(add it under provides.scripts)")
            else:
                # Core tree: flat by construction. A subdirectory here is the
                # `.specify/scripts/bash/<extension-id>/` mistake.
                tail = m.group(5)
                if "/" in tail:
                    problems.append(
                        f"{cf}:{lineno}: `.specify/scripts/{m.group(4)}/` is the FLAT core "
                        f"tree — it has no '{tail.split('/')[0]}/' subdirectory. Extension "
                        f"scripts live at .specify/extensions/<id>/scripts/{m.group(4)}/")

for p in problems:
    print(p, file=sys.stderr)
if problems:
    print("error: command files reference script paths that do not resolve", file=sys.stderr)
    sys.exit(1)
print(f"script path check: ok ({sum(len(v) for v in declared.values())} declared scripts, "
      f"{len(cmd_files)} command files)")
PYEOF

if [[ $fail -ne 0 ]]; then
  echo "error: pre-flight checks failed" >&2
  exit 1
fi

echo "CLI surface check: ok (${#files[@]} command files)"
