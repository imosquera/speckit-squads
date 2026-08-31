#!/usr/bin/env bash
#
# Turn the feature you are about to build into the FRONTEND MOCK of a full-stack
# feature, and file its backend and wire-up siblings for later.
#
# This runs at `/speckit-git-feature` time — branch, worktree, and tracking issue
# have just been created, and no spec exists yet. That timing decides the shape:
# there is exactly one issue the worktree is bound to, so the split cannot make a
# parent epic with three children (the worktree would be bound to something nobody
# implements, and the numbering contract that ties branch/spec/issue together would
# point at a non-unit of work). Instead the issue you already have BECOMES the
# frontend mock — the thing you build first — and two siblings are opened beside it:
#
#     #42  <title>              -> relabelled `frontend` + `mock-first`  (this worktree)
#     #43  backend: <title>     -> new sibling
#     #44  wire-up: <title>     -> new sibling, `Blocked by: #42, #43`
#
# The frontend issue keeps its number, its branch, and its worktree, so nothing the
# core command already wrote has to be undone.
#
# Why the frontend is the mock: it is the half that can be built with nothing else
# in place. Static in-repo fixtures, no network calls, so the UI is reviewable long
# before an endpoint exists and the fixture shape becomes the contract the backend
# sibling implements. The wire-up sibling retires the fixtures.
#
# Usage:
#   split-layers.sh <feature-issue> --title "<feature title>" \
#       --backend-body FILE [--integration-body FILE] [--frontend-body FILE] \
#       [--priority p0|p1|p2|p3] [--kind bug|feature] [--dry-run]
#   split-layers.sh <feature-issue> --show    print "<layer> <number>" per sibling
#
# `--frontend-body` is optional: without it the feature issue's existing body is
# left alone (at `/speckit-git-feature` time it is the stub the core command wrote,
# and a later re-run should not clobber whatever replaced it).
#
# IDEMPOTENT. The frontend issue's body carries a sentinel block naming its
# siblings; a re-run parses that block and edits those issues instead of opening a
# second pair.
#
# Exit codes: 0 ok (including "already split"), 1 usage/gh error.

set -uo pipefail

BEGIN="<!-- speckit:layer-siblings -->"
END="<!-- /speckit:layer-siblings -->"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL_SCRIPT="$SCRIPT_DIR/label-issue.sh"

die() { echo "[frontend-mock-first] error: $*" >&2; exit 1; }
warn() { echo "[frontend-mock-first] warning: $*" >&2; }

FE=""; TITLE=""; FE_BODY=""; BE_BODY=""; INT_BODY=""
PRIORITY=""; KIND=""; SHOW=false; DRY=false
while [ $# -gt 0 ]; do
  case "$1" in
    --title)            TITLE="${2:?--title needs a value}"; shift 2;;
    --frontend-body)    FE_BODY="${2:?--frontend-body needs a path}"; shift 2;;
    --backend-body)     BE_BODY="${2:?--backend-body needs a path}"; shift 2;;
    --integration-body) INT_BODY="${2:?--integration-body needs a path}"; shift 2;;
    --priority)         PRIORITY="${2:?--priority needs a value}"; shift 2;;
    --kind)             KIND="${2:?--kind needs a value}"; shift 2;;
    --show)             SHOW=true; shift;;
    --dry-run)          DRY=true; shift;;
    -h|--help)          sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    -*)                 die "unknown flag: $1";;
    *)                  [ -z "$FE" ] || die "unexpected argument: $1"; FE="${1#\#}"; shift;;
  esac
done

[ -n "$FE" ] || die "usage: split-layers.sh <feature-issue> --title T --backend-body F"
[[ "$FE" =~ ^[0-9]+$ ]] || die "issue number must be numeric (got '$FE')"
command -v gh >/dev/null 2>&1 || die "gh not found — install it or run 'gh auth login'"

FE_CURRENT_BODY="$(gh issue view "$FE" --json body --jq .body 2>/dev/null)" \
  || die "could not read issue #$FE"

# The frontend issue's own body is the registry of its siblings — nothing else
# survives a re-clone, and searching GitHub for "issues mentioning #N" matches
# every passing reference.
sibling_of() {
  printf '%s\n' "$FE_CURRENT_BODY" \
    | sed -n "\|$BEGIN|,\|$END|p" \
    | grep -iE "^- \[[ x]\] $1\b" \
    | grep -oE '#[0-9]+' | head -1 | tr -d '#'
}

BE="$(sibling_of backend)"; INT="$(sibling_of integration)"

if $SHOW; then
  echo "frontend $FE"
  [ -n "$BE" ]  && echo "backend $BE"
  [ -n "$INT" ] && echo "integration $INT"
  exit 0
fi

[ -n "$TITLE" ] || die "--title is required"
[ -n "$BE_BODY" ] && [ -r "$BE_BODY" ] || die "--backend-body must name a readable file"
[ -z "$INT_BODY" ] || [ -r "$INT_BODY" ] || die "--integration-body names an unreadable file"
[ -z "$FE_BODY" ]  || [ -r "$FE_BODY" ]  || die "--frontend-body names an unreadable file"

TRIAGE=()
[ -n "$PRIORITY" ] && TRIAGE+=(--priority "$PRIORITY")
[ -n "$KIND" ]     && TRIAGE+=(--kind "$KIND")

label() {  # labels are advisory; a failure never fails the split
  $DRY && return 0
  [ -f "$LABEL_SCRIPT" ] || { warn "label-issue.sh not found at $LABEL_SCRIPT"; return 0; }
  bash "$LABEL_SCRIPT" "$@" || warn "labelling #$1 failed — continuing"
}

# Sets the global UPSERTED. Deliberately not `$(…)`: `die` inside a command
# substitution kills only the subshell, so a failed create would yield an empty
# number and the sibling block would point at nothing.
UPSERTED=""
upsert() {
  local num="$1" ctitle="$2" bodyfile="$3"
  if [ -n "$num" ]; then
    UPSERTED="$num"
    $DRY && return 0
    gh issue edit "$num" --body-file "$bodyfile" >/dev/null \
      || die "gh issue edit failed for #$num"
    return 0
  fi
  if $DRY; then UPSERTED="NEW"; return 0; fi
  local url
  url="$(gh issue create --title "$ctitle" --body-file "$bodyfile")" \
    || die "gh issue create failed for '$ctitle'"
  [ -n "$url" ] || die "gh issue create returned no URL for '$ctitle'"
  UPSERTED="${url##*/}"
  [[ "$UPSERTED" =~ ^[0-9]+$ ]] || die "could not parse an issue number out of '$url'"
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

{ printf 'Frontend mock: #%s\n\n' "$FE"; cat "$BE_BODY"; } > "$TMP/be.md"
upsert "$BE" "backend: $TITLE" "$TMP/be.md"; BE="$UPSERTED"
label "$BE" --layer backend ${TRIAGE[@]+"${TRIAGE[@]}"}

# Written last because its body names both siblings. `Blocked by:` is the exact
# string autopilot's preflight reads, so the wire-up issue stays out of the
# eligible pool until the frontend and backend issues close.
{
  printf 'Frontend mock: #%s\nBackend: #%s\n\n' "$FE" "$BE"
  printf 'Blocked by: #%s, #%s\n\n' "$FE" "$BE"
  if [ -n "$INT_BODY" ]; then
    cat "$INT_BODY"
  else
    cat <<EOF
Wire the frontend mock built in #$FE to the backend built in #$BE.

## Functional Requirements

- Replace the static fixtures added by #$FE with real calls to the API from #$BE.
- Delete the fixture modules and any mock-only branches; no fixture may remain
  reachable from production code paths.
- Reconcile the contract: where the shipped API differs from the shape the mock
  assumed, change one side deliberately and say which in the PR.
- Cover the states the mock could not: loading, empty, error, and slow responses.
EOF
  fi
} > "$TMP/int.md"

upsert "$INT" "wire-up: $TITLE" "$TMP/int.md"; INT="$UPSERTED"
label "$INT" --layer integration ${TRIAGE[@]+"${TRIAGE[@]}"}

# ------------------------------------------------- frontend issue: label + block ---
label "$FE" --layer frontend --mock-first ${TRIAGE[@]+"${TRIAGE[@]}"}

{
  if [ -n "$FE_BODY" ]; then
    cat "$FE_BODY"
  else
    printf '%s\n' "$FE_CURRENT_BODY" | sed "\|$BEGIN|,\|$END|d"
  fi
  printf '%s\n' "$BEGIN"
  printf '## Layers\n\n'
  printf 'This issue is the **frontend mock**: build it against static in-repo\n'
  printf 'fixtures with no network calls at all. Its siblings:\n\n'
  printf -- '- [ ] backend — no UI: #%s\n' "$BE"
  printf -- '- [ ] integration — wire-up, blocked by this issue and the backend: #%s\n' "$INT"
  printf '%s\n' "$END"
} > "$TMP/fe.md"

if $DRY; then
  echo "[frontend-mock-first] dry run — #$FE body would become:"
  cat "$TMP/fe.md"
  exit 0
fi

gh issue edit "$FE" --body-file "$TMP/fe.md" >/dev/null \
  || die "gh issue edit failed for #$FE"

echo "[frontend-mock-first] #$FE is the frontend mock; filed backend #$BE and wire-up #$INT"
