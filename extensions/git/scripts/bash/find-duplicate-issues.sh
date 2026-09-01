#!/usr/bin/env bash
#
# Find existing issues that may already cover the work about to be filed.
#
# `/speckit-git-issue` creates a *new* GitHub issue every time a feature is
# specified with no linked issue, and nothing before this script ever looked at
# what the repo already had. Two people (or two autopilot passes, or one person
# on two days) describing the same bug in different words got two issues, both
# eligible for the picker, both worked — the second one re-implementing or
# reverting the first. This is the read-only scan that runs *before* the create,
# so a near-duplicate can be merged into the existing thread instead.
#
# It only ever finds and ranks candidates. The similarity judgement, and the
# decision to merge / file anyway / abandon, belong to the agent and the human it
# asks — this script never edits, closes, comments on, or creates anything.
#
# Ranking: the title (plus any --keyword) is reduced to its distinctive tokens,
# each token is searched separately (GitHub ANDs the terms in one query, which
# collapses recall to near zero on a full sentence), and candidates score one
# point per distinct token hit plus one per token that also appears in *their*
# title. Closed issues are included by design: "we already fixed this" and "we
# already decided not to" are both answers worth having before filing.
#
# Usage:
#   find-duplicate-issues.sh --title "<issue title>" [--keyword W]...
#                            [--exclude N]... [--state open|closed|all]
#                            [--limit N] [--min-score N] [--repo OWNER/REPO]
#
# Output: one TSV row per candidate, best first, on stdout —
#   score<TAB>number<TAB>state<TAB>labels<TAB>updated<TAB>title<TAB>url
# with a human-readable summary on stderr. No candidates = no rows, exit 0.
#
# Exit codes: 0 scan ran (with or without candidates), 1 usage/`gh` error.

set -uo pipefail

TITLE=""; STATE="all"; LIMIT=8; MIN_SCORE=3; REPO=""; FETCH=40; MAX_TOKENS=8
KEYWORDS=(); EXCLUDE=()

die() { echo "[speckit-git-issue] error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --title)     TITLE="${2:?--title needs a value}"; shift 2;;
    --keyword)   KEYWORDS+=("${2:?--keyword needs a value}"); shift 2;;
    --exclude)   EXCLUDE+=("${2#\#}"); shift 2;;
    --state)     STATE="${2:?--state needs a value}"; shift 2;;
    --limit)     LIMIT="${2:?--limit needs a value}"; shift 2;;
    --min-score) MIN_SCORE="${2:?--min-score needs a value}"; shift 2;;
    --repo)      REPO="${2:?--repo needs a value}"; shift 2;;
    -h|--help)   sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    -*)          die "unknown flag: $1";;
    *)           [ -z "$TITLE" ] || die "unexpected argument: $1"; TITLE="$1"; shift;;
  esac
done

[ -n "$TITLE" ] || die "usage: find-duplicate-issues.sh --title \"<issue title>\" [--keyword W] [--exclude N] [--state all] [--limit N]"
case "$STATE" in open|closed|all) ;; *) die "--state must be one of: open closed all";; esac
command -v gh >/dev/null 2>&1 || die "gh not found — install it or run 'gh auth login'"
command -v jq >/dev/null 2>&1 || die "jq not found — install it (brew install jq)"

# Strip the decorations this repo's own titles carry so they never become search
# tokens: the `NNN: ` feature-number prefix and the split-issue layer prefixes.
CLEAN="$(printf '%s' "$TITLE" \
  | sed -E 's/^[0-9]+:[[:space:]]*//; s/^(frontend\(mock\)|frontend|backend|wire-up|integration):[[:space:]]*//I')"

STOPWORDS=" about above added adding also always another because been before being between both cannot could does doing done during each else even every from have having here into itself just like made make making more most much must need needs only other over same should since some such than that their them then there these they this those through under until upon very what when where which while will with without would your "

# Distinctive tokens only: >=4 chars, no stopwords, longest first (a long token
# is a rarer one), capped so a verbose title does not fan out into 20 searches.
TOKENS="$(printf '%s ' "$CLEAN" ${KEYWORDS[@]+"${KEYWORDS[@]}"} \
  | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '\n' \
  | awk 'length($0) >= 4' \
  | grep -vxF -f <(printf '%s\n' $STOPWORDS) \
  | sort -u \
  | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2 | head -"$MAX_TOKENS")"

if [ -z "$TOKENS" ]; then
  echo "[speckit-git-issue] duplicate scan: no distinctive terms in \"$TITLE\" — nothing to search" >&2
  exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
REPO_ARGS=(); [ -n "$REPO" ] && REPO_ARGS=(--repo "$REPO")

i=0
while IFS= read -r tok; do
  [ -n "$tok" ] || continue
  gh issue list ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} \
     --state "$STATE" --limit "$FETCH" --search "$tok in:title,body" \
     --json number,title,state,labels,updatedAt,url > "$TMP/$i.json" 2>"$TMP/$i.err" \
    || { [ $i -eq 0 ] && die "gh issue list failed: $(head -3 "$TMP/0.err")"; echo '[]' > "$TMP/$i.json"; }
  i=$((i + 1))
done <<< "$TOKENS"

EXCL_JSON="$(printf '%s\n' ${EXCLUDE[@]+"${EXCLUDE[@]}"} | grep -E '^[0-9]+$' | jq -R 'tonumber' | jq -s '.')"
[ -n "$EXCL_JSON" ] || EXCL_JSON='[]'

ROWS="$(jq -r -s \
  --argjson excl "$EXCL_JSON" \
  --arg toks "$(printf '%s' "$TOKENS" | tr '\n' ' ')" \
  --argjson min "$MIN_SCORE" --argjson lim "$LIMIT" '
    ([$toks | split(" ") | .[] | select(length > 0)]) as $t
    | (add // [])
    | map(select(. as $c | ($excl | index($c.number)) | not))
    | group_by(.number)
    | map(. as $g | $g[0] + { hits: ($g | length) })
    | map(. as $c
          | $c + { score: ($c.hits
                           + ([$t[] | . as $tok
                               | select(($c.title | ascii_downcase) | contains($tok))] | length)) })
    | map(select(.score >= $min))
    | sort_by(.score, .updatedAt) | reverse
    | .[0:$lim][]
    | [ .score, .number, (.state | ascii_downcase), ((.labels // []) | map(.name) | join(",")),
        (.updatedAt | split("T")[0]), .title, .url ]
    | @tsv
  ' "$TMP"/*.json 2>/dev/null)"

if [ -z "$ROWS" ]; then
  echo "[speckit-git-issue] duplicate scan: no similar issues (searched: $(printf '%s' "$TOKENS" | tr '\n' ' '))" >&2
  exit 0
fi

echo "[speckit-git-issue] duplicate scan: $(printf '%s\n' "$ROWS" | wc -l | tr -d ' ') candidate(s) for \"$CLEAN\"" >&2
echo "[speckit-git-issue]   searched: $(printf '%s' "$TOKENS" | tr '\n' ' ')" >&2
echo "[speckit-git-issue]   score  number  state  labels  updated  title  url" >&2
printf '%s\n' "$ROWS"
