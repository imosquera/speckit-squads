#!/usr/bin/env bash
#
# Apply (and, when missing, create) the triage labels that describe an issue's
# priority, kind, and layer: `p0`..`p3`, `bug`/`feature`, and
# `frontend`/`backend`/`integration` — plus the `mock-first` and `epic` markers.
#
# These axes are not decoration — they are the input to autopilot's picker.
# `preflight-issues.py` orders the eligible backlog by (priority, bug-before-
# feature, age), so an unlabelled backlog degrades to plain oldest-first and a
# genuine P0 waits behind whatever chore happens to be older. This script is the
# single writer of that vocabulary, shared by `/speckit-git-issue` and
# `/speckit-git-feature`, so the strings a writer emits can never drift from the
# ones the reader matches on. Keep it in sync with `PRIORITY_RE` / `BUG_LABELS`
# in `extensions/autopilot/scripts/bash/preflight-issues.py`.
#
# Priority is exclusive: setting one removes the other three, so an issue can
# never carry `p0, p2` and leave the picker to guess (it takes the lowest, but
# a contradictory pair is a triage bug, not a preference). Kind and layer are
# exclusive the same way.
#
# `mock-first` and `epic` are markers, not axes: they are added or removed on
# their own and coexist with any priority/kind/layer. `epic` is deliberately a
# member of `preflight-issues.py`'s BLOCK set — labelling the parent of a work
# breakdown `epic` is what keeps autopilot working the *children* rather than
# re-implementing the whole feature from the parent issue.
#
# Usage:
#   label-issue.sh <issue-number> [--priority p0|p1|p2|p3] [--kind bug|feature]
#                                 [--layer frontend|backend|integration]
#                                 [--mock-first|--no-mock-first] [--epic|--no-epic]
#   label-issue.sh <issue-number> --show      print current triage labels, one per line
#
# All label flags are optional; passing none with no --show is a no-op exit 0,
# so a caller that resolved nothing to set does not have to branch around it.
#
# Exit codes: 0 ok (or nothing to do), 1 usage/`gh` error.

set -uo pipefail

PRIORITIES="p0 p1 p2 p3"
KINDS="bug feature"
LAYERS="frontend backend integration"
MARKERS="mock-first epic"

die() { echo "[speckit-git-issue] error: $*" >&2; exit 1; }

# Colors/descriptions used only when the label does not exist yet; an existing
# label is never restyled, because the repo's own choices outrank ours.
label_color() {
  case "$1" in
    p0) echo "b60205";;   # red
    p1) echo "d93f0b";;   # orange
    p2) echo "fbca04";;   # yellow
    p3) echo "0e8a16";;   # green
    bug) echo "d73a4a";;
    feature) echo "a2eeef";;
    frontend) echo "1d76db";;
    backend) echo "5319e7";;
    integration) echo "006b75";;
    mock-first) echo "c5def5";;
    epic) echo "3e4b9e";;
    *) echo "ededed";;
  esac
}

label_desc() {
  case "$1" in
    p0) echo "Critical — work this before anything else";;
    p1) echo "High priority";;
    p2) echo "Normal priority (autopilot's default when unlabelled)";;
    p3) echo "Low priority — work only when nothing else is pending";;
    bug) echo "Something is broken";;
    feature) echo "New capability or enhancement";;
    frontend) echo "UI layer — built against fixtures before the API exists";;
    backend) echo "API/data layer — no UI work";;
    integration) echo "Wires the frontend to the real backend, replacing fixtures";;
    mock-first) echo "Build against static fixtures; no network calls";;
    epic) echo "Parent of a work breakdown — work the child issues, not this one";;
    *) echo "";;
  esac
}

ensure_label() {
  local name="$1"
  # `gh label create` fails loudly when the label already exists, which is the
  # common case; --force would rewrite an existing label's color/description and
  # stomp the repo's own styling, so swallow the duplicate instead.
  gh label create "$name" --color "$(label_color "$name")" \
     --description "$(label_desc "$name")" >/dev/null 2>&1 || true
}

ISSUE=""; PRIORITY=""; KIND=""; LAYER=""; MOCK=""; EPIC=""; SHOW=false
while [ $# -gt 0 ]; do
  case "$1" in
    --priority) PRIORITY="$(printf '%s' "${2:?--priority needs a value}" | tr 'A-Z' 'a-z')"; shift 2;;
    --kind)     KIND="$(printf '%s' "${2:?--kind needs a value}" | tr 'A-Z' 'a-z')"; shift 2;;
    --layer)    LAYER="$(printf '%s' "${2:?--layer needs a value}" | tr 'A-Z' 'a-z')"; shift 2;;
    --mock-first)    MOCK=on;  shift;;
    --no-mock-first) MOCK=off; shift;;
    --epic)          EPIC=on;  shift;;
    --no-epic)       EPIC=off; shift;;
    --show)     SHOW=true; shift;;
    -h|--help)  sed -n '3,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    -*)         die "unknown flag: $1";;
    *)          [ -z "$ISSUE" ] || die "unexpected argument: $1"; ISSUE="${1#\#}"; shift;;
  esac
done

[ -n "$ISSUE" ] || die "usage: label-issue.sh <issue-number> [--priority pN] [--kind bug|feature] [--layer frontend|backend|integration] [--mock-first] [--epic] [--show]"
[[ "$ISSUE" =~ ^[0-9]+$ ]] || die "issue number must be numeric (got '$ISSUE')"
command -v gh >/dev/null 2>&1 || die "gh not found — install it or run 'gh auth login'"

if $SHOW; then
  gh issue view "$ISSUE" --json labels --jq '.labels[].name' 2>/dev/null \
    | tr 'A-Z' 'a-z' \
    | grep -Ex "$(echo "$PRIORITIES $KINDS $LAYERS $MARKERS" | tr ' ' '|')" || true
  exit 0
fi

[ -n "$PRIORITY$KIND$LAYER$MOCK$EPIC" ] || exit 0

ADD=(); REMOVE=()

if [ -n "$PRIORITY" ]; then
  echo " $PRIORITIES " | grep -q " $PRIORITY " || die "--priority must be one of: $PRIORITIES"
  ensure_label "$PRIORITY"
  ADD+=("$PRIORITY")
  for p in $PRIORITIES; do [ "$p" = "$PRIORITY" ] || REMOVE+=("$p"); done
fi

if [ -n "$KIND" ]; then
  echo " $KINDS " | grep -q " $KIND " || die "--kind must be one of: $KINDS"
  ensure_label "$KIND"
  ADD+=("$KIND")
  for k in $KINDS; do [ "$k" = "$KIND" ] || REMOVE+=("$k"); done
fi

if [ -n "$LAYER" ]; then
  echo " $LAYERS " | grep -q " $LAYER " || die "--layer must be one of: $LAYERS"
  ensure_label "$LAYER"
  ADD+=("$LAYER")
  for l in $LAYERS; do [ "$l" = "$LAYER" ] || REMOVE+=("$l"); done
fi

# Markers are independent of every axis, so they only ever touch themselves.
if [ "$MOCK" = on ];  then ensure_label mock-first; ADD+=("mock-first"); fi
if [ "$MOCK" = off ]; then REMOVE+=("mock-first"); fi
if [ "$EPIC" = on ];  then ensure_label epic; ADD+=("epic"); fi
if [ "$EPIC" = off ]; then REMOVE+=("epic"); fi

[ ${#ADD[@]} -gt 0 ] || [ ${#REMOVE[@]} -gt 0 ] || exit 0

# One `gh issue edit` for both directions. --remove-label on a label the issue
# does not carry is accepted by gh, so there is no need to read the current set
# first — but a label that does not exist in the *repo* is an error, hence the
# 2>&1 capture and the tolerant treatment of removals below.
ARGS=(issue edit "$ISSUE")
for l in ${ADD[@]+"${ADD[@]}"};       do ARGS+=(--add-label "$l"); done
for l in ${REMOVE[@]+"${REMOVE[@]}"}; do ARGS+=(--remove-label "$l"); done

if ! OUT=$(gh "${ARGS[@]}" 2>&1); then
  # Retry with additions only: the usual cause is a repo that has never had one
  # of the sibling labels, which makes its removal an error even though the
  # label we care about applied cleanly.
  ARGS=(issue edit "$ISSUE")
  for l in ${ADD[@]+"${ADD[@]}"}; do ARGS+=(--add-label "$l"); done
  if [ ${#ARGS[@]} -gt 3 ]; then
    gh "${ARGS[@]}" >/dev/null 2>&1 \
      || die "gh issue edit failed for #$ISSUE: $OUT"
  else
    die "gh issue edit failed for #$ISSUE: $OUT"
  fi
fi

echo "[speckit-git-issue] #$ISSUE labelled: ${ADD[*]:-(removals only)}"
