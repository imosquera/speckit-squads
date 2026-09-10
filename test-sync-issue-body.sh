#!/usr/bin/env bash
# Check the git extension's spec->issue body render: what it renders, what it
# preserves, and that a re-sync is byte-stable.
#
# The render used to be prose in speckit.git.issue.md, so every run hand-wrote
# the string surgery and invented its own scheme for the human report the sync
# destroys — four runs, four incompatible formats (issue #63, policy in #61).
#
# Usage: ./test-sync-issue-body.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$HERE/extensions/git/scripts/bash/sync-issue-body.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

ORIG_BEGIN="<!-- speckit:original-report -->"
ORIG_END="<!-- /speckit:original-report -->"
WB_BEGIN="<!-- speckit:work-breakdown -->"
WB_END="<!-- /speckit:work-breakdown -->"

contains() { # contains <what> <needle> <haystack>
  if grep -qF -- "$2" <<<"$3"; then echo "  ok: $1 contains '$2'"; else
    echo "  FAIL: $1 does not contain '$2'" >&2
    printf '%s\n' "$3" | sed 's/^/        /' >&2; fail=1
  fi
}
lacks() {
  if grep -qF -- "$2" <<<"$3"; then
    echo "  FAIL: $1 unexpectedly contains '$2'" >&2; fail=1
  else echo "  ok: $1 omits '$2'"; fi
}
check() { # check <what> <desc> <expected> <actual>
  if [[ "$3" == "$4" ]]; then echo "  ok: $1 $2"; else
    echo "  FAIL: $1 $2 — expected '$3', got '$4'" >&2; fail=1
  fi
}

SPEC="$TMP/spec.md"
cat > "$SPEC" <<'SPEC'
# Feature Specification: Saved Searches

Users can save a search and re-run it later.

## User Scenarios

- A user saves a search from the results page.

## Functional Requirements

- FR-001: the list persists across sessions.

## Success Criteria

- SC-001: 95% of saves complete in under 200ms.

## Clarifications

### Session 2026-09-10

- Q: How many saved searches? -> A: 20.
SPEC

REPORT="$TMP/report.md"
cat > "$REPORT" <<'BODY'
The saved-search list disappears after a reload.

Steps: save a search, reload, list is empty.
Expected: the search is still there.
BODY

echo "1. render: spec sections in, H1 and Success Criteria out"
out="$(bash "$SYNC" 41 "$SPEC" --current-body "$REPORT" --dry-run)"; rc=$?
check render "exit code" 0 "$rc"
contains render "Spec path: $SPEC" "$out"
contains render "## Functional Requirements" "$out"
contains render "FR-001: the list persists across sessions." "$out"
contains render "## Clarifications" "$out"
contains render "Generated/updated by /speckit-git-issue" "$out"
lacks render "# Feature Specification: Saved Searches" "$out"
lacks render "## Success Criteria" "$out"
lacks render "SC-001" "$out"

echo "2. first sync preserves the human report below the sentinel"
contains preserve "$ORIG_BEGIN" "$out"
contains preserve "$ORIG_END" "$out"
contains preserve "The saved-search list disappears after a reload." "$out"
contains preserve "Expected: the search is still there." "$out"
# --include puts a default-omitted section back.
inc="$(bash "$SYNC" 41 "$SPEC" --current-body "$REPORT" --include "Success Criteria" --dry-run)"
contains "--include" "SC-001" "$inc"

echo "3. re-sync is byte-stable — the preserved region is not re-wrapped"
printf '%s\n' "$out" > "$TMP/synced.md"
again="$(bash "$SYNC" 41 "$SPEC" --current-body "$TMP/synced.md" --dry-run)"
check re-sync "is idempotent" "$out" "$again"
check re-sync "has exactly one begin sentinel" 1 "$(grep -cF -- "$ORIG_BEGIN" <<<"$again")"

echo "4. an edited spec rewrites only the region above the sentinel"
sed -i.bak 's/FR-001: the list persists across sessions./FR-001: the list syncs across devices./' "$SPEC"
edited="$(bash "$SYNC" 41 "$SPEC" --current-body "$TMP/synced.md" --dry-run)"
contains edited "FR-001: the list syncs across devices." "$edited"
lacks edited "FR-001: the list persists across sessions." "$edited"
contains edited "The saved-search list disappears after a reload." "$edited"

echo "5. a /speckit-git-feature stub is not preserved as a report"
cat > "$TMP/stub.md" <<'STUB'
Tracking issue for feature: saved searches

Stub created by `/speckit-git-feature`. The full spec body will be filled in by `/speckit-specify`.
STUB
stub="$(bash "$SYNC" 41 "$SPEC" --current-body "$TMP/stub.md" --dry-run)"
lacks stub "$ORIG_BEGIN" "$stub"
lacks stub "Stub created by" "$stub"
contains stub "## Functional Requirements" "$stub"

echo "6. the work-breakdown registry survives a body sync, and lands last"
{ cat "$TMP/synced.md"
  printf '\n%s\n' "$WB_BEGIN"
  printf '## Work breakdown\n\n- [ ] frontend — mock first, fixtures only: #42\n'
  printf '%s\n' "$WB_END"; } > "$TMP/split.md"
wb="$(bash "$SYNC" 41 "$SPEC" --current-body "$TMP/split.md" --dry-run)"
contains work-breakdown "- [ ] frontend — mock first, fixtures only: #42" "$wb"
check work-breakdown "block is last" "$WB_END" "$(printf '%s\n' "$wb" | grep -v '^$' | tail -1)"
lacks work-breakdown "#42" "$(sed -n "1,\|$ORIG_END|p" <<<"$wb")"

echo "7. --body-file supplies the rendered region; preservation is unchanged"
printf 'A body the caller rendered itself.\n' > "$TMP/pre.md"
pre="$(bash "$SYNC" 41 --body-file "$TMP/pre.md" --current-body "$REPORT" --dry-run)"
contains --body-file "A body the caller rendered itself." "$pre"
contains --body-file "The saved-search list disappears after a reload." "$pre"

echo "8. it edits the real issue through gh --body-file, and prints the URL"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# gh issue view N --json body|url --jq ... | gh issue edit N --body-file F
if [ "${2:-}" = "view" ]; then
  case "$*" in *--json\ url*) echo "https://github.com/o/r/issues/41";;
                *) cat "$GH_STUB_BODY";; esac
  exit 0
fi
if [ "${2:-}" = "edit" ]; then
  for i in $(seq 1 $#); do
    [ "${!i}" = "--body-file" ] && { j=$((i+1)); cp "${!j}" "$GH_STUB_EDITED"; }
  done
  exit 0
fi
exit 1
STUB
chmod +x "$TMP/bin/gh"
export GH_STUB_BODY="$REPORT" GH_STUB_EDITED="$TMP/edited.md"
out8="$(PATH="$TMP/bin:$PATH" bash "$SYNC" 41 "$SPEC" 2>&1)"; rc=$?
check gh "exit code" 0 "$rc"
contains gh "https://github.com/o/r/issues/41" "$out8"
contains gh "The saved-search list disappears after a reload." "$(cat "$TMP/edited.md" 2>/dev/null)"

echo "9. --render-only is the create path: no issue number, no gh, no sentinel"
ro="$(PATH="/usr/bin:/bin" bash "$SYNC" --render-only "$SPEC")"; rc=$?
check --render-only "exit code" 0 "$rc"
contains --render-only "## Functional Requirements" "$ro"
lacks --render-only "$ORIG_BEGIN" "$ro"

echo "10. usage errors are refusals, not partial writes"
bash "$SYNC" 41 "$TMP/nope.md" --current-body "$REPORT" --dry-run >/dev/null 2>&1
check "missing spec" "exit code" 1 "$?"
bash "$SYNC" notanumber "$SPEC" --dry-run >/dev/null 2>&1
check "non-numeric issue" "exit code" 1 "$?"

if [ "$fail" -eq 0 ]; then echo "all cases passed"; else echo "FAILURES" >&2; fi
exit "$fail"
