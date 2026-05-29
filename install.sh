#!/usr/bin/env bash
# Install every extension and preset in this repo into a Spec Kit project
# via `specify ... add --dev`.
#
# Because every install uses --dev, the project's .specify/extensions/<id>/
# and .specify/presets/<id>/ stay pointed at this repo's source tree —
# edits to command files, scripts, or templates are picked up live with no
# reinstall step. "Already installed" is therefore a no-op success, not an
# error.
#
# (If you change a manifest itself — extension.yml / preset.yml — re-register
# manually: ./uninstall.sh <project-dir> && ./install.sh <project-dir>.)
#
# Usage:
#   ./install.sh <project-dir>
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_DIR=""
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      echo "usage: $(basename "$0") <project-dir>"
      exit 0
      ;;
    -*)
      echo "error: unknown flag: $arg" >&2
      echo "usage: $(basename "$0") <project-dir>" >&2
      exit 2
      ;;
    *)
      if [[ -n "$PROJECT_DIR" ]]; then
        echo "error: only one project-dir may be given" >&2
        exit 2
      fi
      PROJECT_DIR="$arg"
      ;;
  esac
done

if [[ -z "$PROJECT_DIR" ]]; then
  echo "usage: $(basename "$0") <project-dir>" >&2
  exit 2
fi

if [[ ! -d "$PROJECT_DIR/.specify" ]]; then
  echo "error: $PROJECT_DIR is not a Spec Kit project (.specify/ missing)" >&2
  exit 1
fi

cd "$PROJECT_DIR"

shopt -s nullglob

# install_one <kind> <name> <source-dir>
install_one() {
  local kind="$1" name="$2" src="$3"
  local out rc

  # `yes | specify` produces SIGPIPE on `yes`; pipefail would surface it as
  # the pipeline's exit code even when `specify` itself succeeded. Disable
  # pipefail just for this call so we read `specify`'s real status.
  set +o pipefail
  out="$(yes | specify "$kind" add --dev "$src" 2>&1)"
  rc=$?
  set -o pipefail

  if [[ $rc -eq 0 ]]; then
    echo "  installed"
    return 0
  fi

  if grep -q "already installed" <<<"$out"; then
    # --dev means the existing registration already points at this source
    # tree, so file edits are live. Nothing to do.
    echo "  already installed (live via --dev; no action needed)"
    return 0
  fi

  echo "  FAILED:"
  sed 's/^/    /' <<<"$out" >&2
  return 1
}

EXIT=0

for ext_dir in "$REPO_DIR"/extensions/*/; do
  [[ -f "$ext_dir/extension.yml" ]] || continue
  name="$(basename "$ext_dir")"
  echo "==> extension: $name"
  install_one extension "$name" "$ext_dir" || EXIT=1
done

for preset_dir in "$REPO_DIR"/presets/*/; do
  [[ -f "$preset_dir/preset.yml" ]] || continue
  name="$(basename "$preset_dir")"
  echo "==> preset: $name"
  install_one preset "$name" "$preset_dir" || EXIT=1
done

echo
echo "Done. Target: $PROJECT_DIR"
exit $EXIT
