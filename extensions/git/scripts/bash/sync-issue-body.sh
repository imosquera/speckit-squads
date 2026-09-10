#!/usr/bin/env bash
#
# Render a feature's `spec.md` into its tracking issue's body, preserving the
# human-written report the sync would otherwise destroy.
#
# Why a script: `/speckit-git-issue` used to describe this in prose, so the
# model hand-wrote the string surgery in a fresh heredoc on every single run.
# Four autopilot runs in one 24-hour window each invented a *different*
# incompatible scheme for keeping the original report — spliced in-body, posted
# as a comment, appended under a hand-invented sentinel, quoted into `spec.md`
# itself (issue #63). Given `(issue number, spec.md)` there is exactly one
# correct body; that made it a missing script, not a judgment call.
#
# The sentinel is what makes a re-sync idempotent, and idempotency is what makes
# it safe (issue #61): the region below `<!-- speckit:original-report -->` is
# carried across verbatim and only the region above it is rewritten. The
# `<!-- speckit:work-breakdown -->` block that `split-issue.sh` appends to a
# parent is carried across too, and always ends up last — so a body sync can no
# longer erase the registry of children.
#
# Usage:
#   sync-issue-body.sh <issue-number> <spec-path> [--omit S]... [--include S]...
#   sync-issue-body.sh <issue-number> --body-file FILE|-      pre-rendered body
#   ... [--dry-run]           compose and print the body, edit nothing
#
#   --omit "<heading>"     drop a `## <heading>` section from the render
#                          (default: Success Criteria — presets such as
#                          spec-minimal strip it out of the spec anyway)
#   --include "<heading>"  keep a section the default omit list drops
#   --body-file FILE       use FILE (or `-`, stdin) as the rendered region
#                          instead of rendering from the spec; the preservation
#                          surgery below is unchanged
#   --current-body FILE    read the issue's current body from FILE instead of
#                          `gh issue view` (testing seam; implies nothing else)
#   --render-only          print the rendered region for a spec and stop — no
#                          issue number, no `gh`, nothing to preserve. This is
#                          the create path: render, then `gh issue create
#                          --body-file`. Every later sync takes the normal path.
#   --dry-run              print the composed body to stdout, run no `gh edit`
#
# Exit codes: 0 ok, 1 usage/gh/spec error, 2 the composed body would not carry
# the preserved region through verbatim (never written — a refusal, not a fix).

set -uo pipefail

ORIG_BEGIN="<!-- speckit:original-report -->"
ORIG_END="<!-- /speckit:original-report -->"
WB_BEGIN="<!-- speckit:work-breakdown -->"
WB_END="<!-- /speckit:work-breakdown -->"
# `/speckit-git-feature` opens the issue with this stub. It is not a human's
# report, so it is not worth preserving as one — but a reporter may have added
# real text to the stub before the first sync, so only the placeholder itself is
# removed and whatever else the body carries is preserved. Keep these two in
# sync with the `_issue_body` heredoc in `create-new-feature.sh`.
STUB_MARK="Stub created by \`/speckit-git-feature\`"
STUB_LEAD="Tracking issue for feature: "
STUB_SENTENCE="Stub created by \`/speckit-git-feature\`. The full spec body will be filled in by \`/speckit-specify\`."

die()  { echo "[speckit-git-issue] error: $*" >&2; exit 1; }
warn() { echo "[speckit-git-issue] warning: $*" >&2; }

ISSUE=""; SPEC=""; BODY_FILE=""; CURRENT_FILE=""; DRY=false; RENDER_ONLY=false
OMIT=("Success Criteria")
while [ $# -gt 0 ]; do
  case "$1" in
    --omit)         OMIT+=("${2:?--omit needs a heading}"); shift 2;;
    --include)      _keep="${2:?--include needs a heading}"; shift 2
                    _new=(); for _s in ${OMIT[@]+"${OMIT[@]}"}; do
                      [ "$_s" = "$_keep" ] || _new+=("$_s"); done
                    OMIT=(${_new[@]+"${_new[@]}"});;
    --body-file)    BODY_FILE="${2:?--body-file needs a path}"; shift 2;;
    --current-body) CURRENT_FILE="${2:?--current-body needs a path}"; shift 2;;
    --render-only)  RENDER_ONLY=true; shift;;
    --dry-run)      DRY=true; shift;;
    -h|--help)      sed -n '3,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    -*)             die "unknown flag: $1";;
    *)              if $RENDER_ONLY && [ -z "$SPEC" ]; then SPEC="$1"
                    elif [ -z "$ISSUE" ]; then ISSUE="${1#\#}"
                    elif [ -z "$SPEC" ]; then SPEC="$1"
                    else die "unexpected argument: $1"; fi; shift;;
  esac
done

if ! $RENDER_ONLY; then
  [ -n "$ISSUE" ] || die "usage: sync-issue-body.sh <issue-number> <spec-path> [--dry-run]"
  [[ "$ISSUE" =~ ^[0-9]+$ ]] || die "issue number must be numeric (got '$ISSUE')"
fi
if [ -z "$BODY_FILE" ]; then
  [ -n "$SPEC" ] || die "need a <spec-path> or --body-file"
  [ -r "$SPEC" ] || die "spec not readable: $SPEC"
fi
if [ -z "$CURRENT_FILE" ] && ! $RENDER_ONLY; then
  command -v gh >/dev/null 2>&1 || die "gh not found — install it or run 'gh auth login'"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------ current body ---
if $RENDER_ONLY; then
  CURRENT=""                       # nothing to preserve; nothing to read
elif [ -n "$CURRENT_FILE" ]; then
  [ -r "$CURRENT_FILE" ] || die "current body not readable: $CURRENT_FILE"
  CURRENT="$(cat "$CURRENT_FILE")"
else
  CURRENT="$(gh issue view "$ISSUE" --json body --jq .body 2>/dev/null)" \
    || die "could not read issue #$ISSUE"
fi

# `sed -n '/a/,/b/p'` on a body with no block prints nothing, which is what a
# missing block should yield.
between() { # between <begin> <end> <text>
  printf '%s\n' "$3" | sed -n "\|$1|,\|$2|p"
}
strip_between() { # strip_between <begin> <end> <text>
  printf '%s\n' "$3" | sed "\|$1|,\|$2|d"
}
has() { printf '%s\n' "$2" | grep -qF -- "$1"; }
# First 1-based line number carrying <needle>, empty when absent.
line_of() { # line_of <needle> <text>
  printf '%s\n' "$2" | grep -nF -- "$1" | head -1 | cut -d: -f1
}
# Drop leading/trailing blank lines.
trim_blank() { printf '%s\n' "$1" | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'; }
# Remove the `/speckit-git-feature` placeholder, keeping everything else on the
# line — a reporter who edits the stub before the first sync keeps their text.
strip_stub() { # strip_stub <text>
  printf '%s\n' "$1" \
    | awk -v lead="$STUB_LEAD" -v s="$STUB_SENTENCE" '
        index($0, lead) == 1 { next }
        { i = index($0, s)
          if (i) $0 = substr($0, 1, i-1) substr($0, i+length(s))
          print }'
}

WORKBREAKDOWN=""
if has "$WB_BEGIN" "$CURRENT"; then
  WORKBREAKDOWN="$(between "$WB_BEGIN" "$WB_END" "$CURRENT")"
fi

# ---------------------------------------------------------- original report ---
# First sync: everything the issue carries today *except* the breakdown block is
# the human's report. Later syncs: whatever is already inside the sentinels,
# byte for byte — this script never re-derives a region it once preserved.
if has "$ORIG_BEGIN" "$CURRENT"; then
  # `between` runs to EOF when the closing sentinel was removed by a manual
  # edit, and `sed '1d;$d'` then eats the reporter's last line — after which the
  # guard below compares the truncated text against itself and passes. An
  # unbalanced region is not repairable here, so refuse before extracting.
  _b="$(line_of "$ORIG_BEGIN" "$CURRENT")"
  _e="$(line_of "$ORIG_END" "$CURRENT")"
  if [ -z "$_e" ] || [ "$_e" -le "$_b" ]; then
    echo "[speckit-git-issue] error: issue #$ISSUE body opens '$ORIG_BEGIN' with no matching '$ORIG_END' after it — refusing to guess where the original report ends; nothing written" >&2
    exit 2
  fi
  PRESERVED="$(between "$ORIG_BEGIN" "$ORIG_END" "$CURRENT" \
    | sed "1d;\$d")"                       # drop the sentinel lines themselves
  HAD_SENTINEL=true
else
  HAD_SENTINEL=false
  PRESERVED="$(trim_blank "$(strip_between "$WB_BEGIN" "$WB_END" "$CURRENT")")"
  if has "$STUB_MARK" "$PRESERVED"; then
    # A stub is not a report — but a reporter may have added one to it before
    # the first sync. Strip only the placeholder; keep anything else.
    PRESERVED="$(trim_blank "$(strip_stub "$PRESERVED")")"
  fi
fi

# ----------------------------------------------------------------- render ----
render_spec() {
  SPEC_PATH="$SPEC" python3 - "$SPEC" ${OMIT[@]+"${OMIT[@]}"} <<'PY'
import os, re, sys
spec, omit = sys.argv[1], {a.strip().lower() for a in sys.argv[2:]}
text = open(spec, encoding="utf-8").read().splitlines()
out, skipping = [], False
seen_h1 = False
for line in text:
    m = re.match(r"^(#{1,6})\s+(.*?)\s*$", line)
    if m:
        level, title = len(m.group(1)), m.group(2)
        if level == 1 and not seen_h1:
            seen_h1 = True          # the H1 is the template heading, not a section
            continue
        if level == 2:
            skipping = title.lower() in omit
    if not skipping:
        out.append(line)
body = "\n".join(out).strip("\n")
print(f"Spec path: {os.environ['SPEC_PATH']}\n")
print(body)
print("\n## Notes\n\nGenerated/updated by /speckit-git-issue")
PY
}

if [ -n "$BODY_FILE" ]; then
  if [ "$BODY_FILE" = "-" ]; then cat > "$TMP/render.md"
  else [ -r "$BODY_FILE" ] || die "body file not readable: $BODY_FILE"
       cat "$BODY_FILE" > "$TMP/render.md"; fi
else
  render_spec > "$TMP/render.md" || die "could not render $SPEC"
fi
[ -s "$TMP/render.md" ] || die "rendered body is empty — refusing to publish it"

if $RENDER_ONLY; then
  cat "$TMP/render.md"
  exit 0
fi

# ---------------------------------------------------------------- compose ----
{
  cat "$TMP/render.md"
  # No wrapper of any kind around the preserved text: the region between the
  # sentinels IS the report, so the next run reads back exactly what this run
  # wrote. A `<details>` wrapper would be re-wrapped on every sync.
  # The heading sits ABOVE the begin sentinel on purpose: everything between
  # the sentinels is the report itself, so the next run reads back byte for byte
  # what this one wrote. A heading inside would be re-preserved every sync.
  if [ -n "$PRESERVED" ]; then
    printf '\n## Original report (as filed)\n\n'
    printf '%s\n' "$ORIG_BEGIN"
    printf '%s\n' "$PRESERVED"
    printf '%s\n' "$ORIG_END"
  fi
  if [ -n "$WORKBREAKDOWN" ]; then
    printf '\n%s\n' "$WORKBREAKDOWN"
  fi
} > "$TMP/new.md"

# ------------------------------------------------------------------ guard ----
# Refuse rather than repair: a body that lost the report is the failure this
# script exists to prevent, so it must never be the thing that writes it.
NEW="$(cat "$TMP/new.md")"
if [ -n "$PRESERVED" ]; then
  GOT="$(between "$ORIG_BEGIN" "$ORIG_END" "$NEW" | sed '1d;$d')"
  if [ "$GOT" != "$PRESERVED" ]; then
    echo "[speckit-git-issue] error: composed body would not carry the original report through verbatim — nothing written" >&2
    exit 2
  fi
fi
if [ -n "$WORKBREAKDOWN" ] && ! has "$WB_BEGIN" "$NEW"; then
  echo "[speckit-git-issue] error: composed body dropped the work-breakdown block — nothing written" >&2
  exit 2
fi

if $DRY; then
  cat "$TMP/new.md"
  exit 0
fi

gh issue edit "$ISSUE" --body-file "$TMP/new.md" >/dev/null \
  || die "gh issue edit failed for #$ISSUE"

URL="$(gh issue view "$ISSUE" --json url --jq .url 2>/dev/null)"
if $HAD_SENTINEL; then note="report preserved"; elif [ -n "$PRESERVED" ]; then
  note="original report preserved below the sentinel"; else note="no prior report to preserve"; fi
echo "[speckit-git-issue] #$ISSUE body synced from ${SPEC:-$BODY_FILE} — $note${URL:+ — $URL}"
