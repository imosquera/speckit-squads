#!/usr/bin/env bash
#
# launchd entry point: run ONE unattended autopilot pass in PROJECT_DIR.
# Invoked by the agent installed via autopilot-schedule.sh — not meant to be
# called by hand (though it's safe to). Everything it prints goes to the per-repo
# log the plist points StandardOutPath/StandardErrorPath at.
#
# Design notes:
#   * Single-flight lock — a pass can outlast the interval; if the previous one is
#     still running we skip this tick rather than stack two autopilots on one repo.
#   * Headless + non-interactive — autopilot is built to run without a human, so it
#     needs tool permissions granted up front (`--dangerously-skip-permissions`).
#   * Fails soft on a missing CLI so launchd doesn't spin on a broken environment.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DECODER="$SCRIPT_DIR/stream-decode.py"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

PROJECT="${1:?usage: autopilot-run.sh <project-dir>}"
cd "$PROJECT" 2>/dev/null || { echo "$(ts) FATAL cannot cd into $PROJECT"; exit 1; }

lock="${TMPDIR:-/tmp}/speckit-autopilot-$(printf '%s' "$PROJECT" | shasum | cut -c1-8).lock"
if ! mkdir "$lock" 2>/dev/null; then
  echo "$(ts) previous pass still active ($lock) — skipping this tick"
  exit 0
fi
trap 'rmdir "$lock" 2>/dev/null' EXIT

if ! command -v claude >/dev/null 2>&1; then
  echo "$(ts) FATAL 'claude' CLI not on PATH (${PATH}) — cannot run autopilot"
  exit 127
fi

echo "$(ts) === autopilot pass start :: $PROJECT ==="
# The slash command drives the speckit-autopilot-run skill; the flag lets the
# unattended session use git/gh/file tools without an interactive prompt.
#
# Stream the session live into this log instead of only the final result:
# --output-format stream-json emits one JSON event per line, which stream-decode.py
# turns into pretty, timestamped lines. The decoder is piped as `claude … | python3
# FILE` (a real file, NOT `python3 - <<'HEREDOC'`) — piping data into a stdin-heredoc
# script silently loses the data, the same trap Step 1 warns about.
#
# `PIPESTATUS[0]` preserves claude's real exit code (a pipe would otherwise report
# the decoder's). If stream-json/verbose ever stops being supported, fall back to a
# plain `claude -p "/speckit-autopilot-run" --dangerously-skip-permissions`.
if [ -f "$DECODER" ]; then
  claude -p "/speckit-autopilot-run" --dangerously-skip-permissions \
         --verbose --output-format stream-json 2>&1 \
    | python3 "$DECODER"
  status=${PIPESTATUS[0]}
else
  claude -p "/speckit-autopilot-run" --dangerously-skip-permissions
  status=$?
fi
echo "$(ts) === autopilot pass end (exit $status) ==="
exit "$status"
