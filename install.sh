#!/usr/bin/env bash
# Install every extension and preset in this repo into a Spec Kit project
# via `specify ... add --dev`.
#
# Usage:
#   ./install.sh <project-dir>    # install into the given Spec Kit project
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 1 || -z "${1:-}" ]]; then
  echo "usage: $(basename "$0") <project-dir>" >&2
  exit 2
fi
PROJECT_DIR="$1"

if [[ ! -d "$PROJECT_DIR/.specify" ]]; then
  echo "error: $PROJECT_DIR is not a Spec Kit project (.specify/ missing)" >&2
  exit 1
fi

cd "$PROJECT_DIR"

shopt -s nullglob

for ext_dir in "$REPO_DIR"/extensions/*/; do
  [[ -f "$ext_dir/extension.yml" ]] || continue
  name="$(basename "$ext_dir")"
  echo "==> extension: $name"
  yes | specify extension add --dev "$ext_dir" || echo "  (failed: $name)"
done

for preset_dir in "$REPO_DIR"/presets/*/; do
  [[ -f "$preset_dir/preset.yml" ]] || continue
  name="$(basename "$preset_dir")"
  echo "==> preset: $name"
  yes | specify preset add --dev "$preset_dir" || echo "  (failed: $name)"
done

echo
echo "Done. Installed into: $PROJECT_DIR"
