#!/usr/bin/env bash
# Self-check for the feature.json sidecar contract (issue #78).
#
# The failure this guards: core Spec Kit's _persist_feature_json overwrites
# .specify/feature.json with {"feature_directory":...}, dropping source_issue,
# so /speckit-git-pr opened a PR with no `Closes #N`. Our own writer merges
# (issue #70) — core's does not, hence the sidecar.
#
# Run: ./test-feature-json.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=extensions/git/scripts/bash/git-common.sh
source "$SCRIPT_DIR/extensions/git/scripts/bash/git-common.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" init -q
git -C "$TMP" commit -q --allow-empty -m init

json="$TMP/.specify/feature.json"
fail() { echo "FAIL: $1 (feature.json: $(cat "$json" 2>/dev/null))" >&2; exit 1; }

# 1. Writing the link merges (issue #70) and mirrors to the sidecar.
mkdir -p "$TMP/.specify"
printf '{"feature_directory":"specs/078-x"}\n' > "$json"
spec_kit_write_feature_json "$TMP" 78 >/dev/null 2>&1
grep -q '"feature_directory":"specs/078-x"' "$json" || fail "merge dropped feature_directory"
[ "$(spec_kit_feature_source_issue "$TMP")" = "78" ] || fail "merge dropped source_issue"
[ -s "$(spec_kit_source_issue_sidecar "$TMP")" ] || fail "sidecar not written"

# 2. A foreign writer clobbering the file is recovered from the sidecar.
printf '{"feature_directory":"specs/078-x"}\n' > "$json"   # what core's `>` does
[ "$(spec_kit_feature_source_issue "$TMP" 2>/dev/null)" = "78" ] || fail "no recovery after clobber"
grep -q '"source_issue"' "$json" || fail "recovery did not heal the file"
grep -q '"feature_directory"' "$json" || fail "recovery dropped feature_directory"

# 3. Re-linking updates in place instead of appending a second key.
spec_kit_write_feature_json "$TMP" 99 >/dev/null 2>&1
[ "$(grep -c '"source_issue"' "$json")" = "1" ] || fail "duplicate source_issue key"
[ "$(spec_kit_feature_source_issue "$TMP")" = "99" ] || fail "re-link did not update"

# 4. Never linked, never clobbered -> silence, not a phantom issue.
rm -f "$json" "$(spec_kit_source_issue_sidecar "$TMP")"
[ -z "$(spec_kit_feature_source_issue "$TMP" 2>/dev/null)" ] || fail "phantom source_issue"

echo "OK: feature.json sidecar recovery"
