#!/usr/bin/env bash
#
# Split a full-stack tracking issue into layer child issues — frontend (mock
# first), backend, and the integration pass that replaces the mocks — and keep
# the parent's work-breakdown block pointing at them.
#
# Why split at all: a single "add saved searches" issue mixes two jobs with
# different shapes and different reviewers, and autopilot works an issue in one
# pass, so the UI only ever appears at the end, wired to an API nobody has
# looked at yet. Three issues let the mock UI land first and be reviewed on its
# own, while the backend proceeds against the contract the mock froze.
#
# Why the frontend child is mock-first: it is the child that can start
# immediately. Built against static in-repo fixtures with no network calls, it
# needs nothing from the backend, so the two can be worked in either order (or
# at once) and the UI is reviewable long before an endpoint exists. The
# integration child is the only one that needs both, and it carries a
# `Blocked by:` line so `preflight-issues.py` keeps autopilot off it until its
# dependencies close.
#
# ORDER OF CREATION IS LOAD-BEARING. Children are created frontend → backend →
# integration. Autopilot's ranking breaks ties by age, so with equal priority
# labels the frontend child is picked first — the mock-first policy falls out of
# creation order rather than needing a rule in the picker.
#
# Usage:
#   split-issue.sh <parent-issue> --title "<feature title>" \
#       --frontend-body FILE --backend-body FILE [--integration-body FILE] \
#       [--priority p0|p1|p2|p3] [--kind bug|feature] [--dry-run]
#   split-issue.sh <parent-issue> --show     print "<layer> <number>" per child, if split
#
# `--integration-body` is optional; a default body is generated naming the two
# siblings and the fixtures to retire.
#
# IDEMPOTENT. The parent's body carries a sentinel block listing its children;
# a re-run parses that block and *edits* the existing children's bodies instead
# of opening a second set. Never pass `--title` through to a child edit — a
# child's title, like the parent's, is owned by whoever created it.
#
# Exit codes: 0 ok (including "already split, updated in place"), 1 usage/gh error.

set -uo pipefail

BEGIN="<!-- speckit:work-breakdown -->"
END="<!-- /speckit:work-breakdown -->"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL_SCRIPT="$SCRIPT_DIR/label-issue.sh"

die() { echo "[speckit-git-issue] error: $*" >&2; exit 1; }
warn() { echo "[speckit-git-issue] warning: $*" >&2; }

PARENT=""; TITLE=""; FE_BODY=""; BE_BODY=""; INT_BODY=""
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
    *)                  [ -z "$PARENT" ] || die "unexpected argument: $1"; PARENT="${1#\#}"; shift;;
  esac
done

[ -n "$PARENT" ] || die "usage: split-issue.sh <parent-issue> --title T --frontend-body F --backend-body F"
[[ "$PARENT" =~ ^[0-9]+$ ]] || die "parent issue number must be numeric (got '$PARENT')"
command -v gh >/dev/null 2>&1 || die "gh not found — install it or run 'gh auth login'"

PARENT_BODY="$(gh issue view "$PARENT" --json body --jq .body 2>/dev/null)" \
  || die "could not read issue #$PARENT"

# ------------------------------------------------------- existing children ---
# The parent's own body is the registry. Nothing else survives a re-clone, and
# searching GitHub for "issues that mention #N" matches every passing reference.
child_of() {
  printf '%s\n' "$PARENT_BODY" \
    | sed -n "\|$BEGIN|,\|$END|p" \
    | grep -iE "^- \[[ x]\] $1\b" \
    | grep -oE '#[0-9]+' | head -1 | tr -d '#'
}

FE="$(child_of frontend)"; BE="$(child_of backend)"; INT="$(child_of integration)"

if $SHOW; then
  [ -n "$FE" ]  && echo "frontend $FE"
  [ -n "$BE" ]  && echo "backend $BE"
  [ -n "$INT" ] && echo "integration $INT"
  exit 0
fi

[ -n "$TITLE" ] || die "--title is required"
[ -n "$FE_BODY" ] && [ -r "$FE_BODY" ] || die "--frontend-body must name a readable file"
[ -n "$BE_BODY" ] && [ -r "$BE_BODY" ] || die "--backend-body must name a readable file"
[ -z "$INT_BODY" ] || [ -r "$INT_BODY" ] || die "--integration-body names an unreadable file"

# Shared triage flags every child inherits from the parent, held as an array so
# an empty priority/kind contributes no argument at all rather than an empty one.
TRIAGE=()
[ -n "$PRIORITY" ] && TRIAGE+=(--priority "$PRIORITY")
[ -n "$KIND" ]     && TRIAGE+=(--kind "$KIND")

label() {  # label <issue> <args…> — labels are advisory; never fail the split
  $DRY && return 0
  [ -f "$LABEL_SCRIPT" ] || { warn "label-issue.sh not found at $LABEL_SCRIPT"; return 0; }
  bash "$LABEL_SCRIPT" "$@" || warn "labelling #$1 failed — continuing"
}

# upsert <existing-number> <child-title> <body-file> — sets the global UPSERTED.
# Deliberately NOT `$(…)`: `die` inside a command substitution kills only the
# subshell, so a failed `gh issue create` would return an empty number and the
# split would carry on writing a breakdown pointing at nothing.
UPSERTED=""
upsert() {
  local num="$1" ctitle="$2" bodyfile="$3"
  if [ -n "$num" ]; then
    UPSERTED="$num"
    $DRY && return 0
    gh issue edit "$num" --body-file "$bodyfile" >/dev/null \
      || die "gh issue edit failed for child #$num"
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

parent_ref() { printf 'Parent: #%s\n\n' "$PARENT"; }

{ parent_ref; cat "$FE_BODY"; } > "$TMP/fe.md"
{ parent_ref; cat "$BE_BODY"; } > "$TMP/be.md"

upsert "$FE" "frontend(mock): $TITLE" "$TMP/fe.md"; FE="$UPSERTED"
label "$FE" --layer frontend --mock-first ${TRIAGE[@]+"${TRIAGE[@]}"}

upsert "$BE" "backend: $TITLE" "$TMP/be.md"; BE="$UPSERTED"
label "$BE" --layer backend ${TRIAGE[@]+"${TRIAGE[@]}"}

# The integration child is written last because its body names its siblings.
# `Blocked by:` is the exact string `preflight-issues.py` reads, so autopilot
# leaves this issue alone until both numbers are closed.
{
  parent_ref
  printf 'Blocked by: #%s, #%s\n\n' "$FE" "$BE"
  if [ -n "$INT_BODY" ]; then
    cat "$INT_BODY"
  else
    cat <<EOF
Wire the frontend built in #$FE to the backend built in #$BE.

## Functional Requirements

- Replace the static fixtures added by #$FE with real calls to the API from #$BE.
- Delete the fixture modules and any mock-only branches; no fixture may remain
  reachable from production code paths.
- Reconcile the contract: where the shipped API differs from the shape the mock
  assumed, change one side deliberately and say which in the PR.
- Cover the real states the mock could not: loading, empty, error, and slow
  responses.
EOF
  fi
} > "$TMP/int.md"

upsert "$INT" "wire-up: $TITLE" "$TMP/int.md"; INT="$UPSERTED"
label "$INT" --layer integration ${TRIAGE[@]+"${TRIAGE[@]}"}

# ----------------------------------------------------- parent body rewrite ---
# Strip any previous block and append a fresh one, so a re-run never stacks two.
# `epic` parks the parent in autopilot's BLOCK set: the work lives in the
# children now, and re-implementing it from the parent would duplicate all three.
{
  printf '%s\n' "$PARENT_BODY" | sed "\|$BEGIN|,\|$END|d"
  printf '%s\n' "$BEGIN"
  printf '## Work breakdown\n\n'
  printf -- '- [ ] frontend — mock first, fixtures only: #%s\n' "$FE"
  printf -- '- [ ] backend — no UI: #%s\n' "$BE"
  printf -- '- [ ] integration — wire-up, blocked by the two above: #%s\n' "$INT"
  printf '\nThis issue is the parent and is not worked directly.\n'
  printf '%s\n' "$END"
} > "$TMP/parent.md"

if $DRY; then
  echo "[speckit-git-issue] dry run — parent #$PARENT body would become:"
  cat "$TMP/parent.md"
  exit 0
fi

gh issue edit "$PARENT" --body-file "$TMP/parent.md" >/dev/null \
  || die "gh issue edit failed for parent #$PARENT"
label "$PARENT" --epic

echo "[speckit-git-issue] #$PARENT split: frontend #$FE (mock-first), backend #$BE, wire-up #$INT"
