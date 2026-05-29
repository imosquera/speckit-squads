#!/usr/bin/env bash
# Install every extension and preset in this repo into a Spec Kit project
# via `specify ... add --dev`.
#
# Usage:
#   ./install.sh <project-dir>           # install; skip anything already installed
#   ./install.sh --force <project-dir>   # remove existing first, then reinstall
#   ./install.sh <project-dir> --force   # same
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FORCE=false
PROJECT_DIR=""
for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=true ;;
    -h|--help)
      echo "usage: $(basename "$0") [--force] <project-dir>"
      exit 0
      ;;
    -*)
      echo "error: unknown flag: $arg" >&2
      echo "usage: $(basename "$0") [--force] <project-dir>" >&2
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
  echo "usage: $(basename "$0") [--force] <project-dir>" >&2
  exit 2
fi

if [[ ! -d "$PROJECT_DIR/.specify" ]]; then
  echo "error: $PROJECT_DIR is not a Spec Kit project (.specify/ missing)" >&2
  exit 1
fi

cd "$PROJECT_DIR"

shopt -s nullglob

# install_one <kind> <name> <source-dir>
#   kind: "extension" or "preset"
# Returns/prints one of: installed, skipped (already), reinstalled, failed
install_one() {
  local kind="$1" name="$2" src="$3"
  local out rc

  if $FORCE; then
    # Best-effort removal; ignore errors (e.g. not installed).
    yes | specify "$kind" remove "$name" >/dev/null 2>&1 || true
  fi

  # `yes | specify` produces SIGPIPE on `yes`; pipefail would surface it as
  # the pipeline's exit code even when `specify` itself succeeded. Disable
  # pipefail just for this call so we read `specify`'s real status.
  set +o pipefail
  out="$(yes | specify "$kind" add --dev "$src" 2>&1)"
  rc=$?
  set -o pipefail

  if [[ $rc -eq 0 ]]; then
    if $FORCE; then
      echo "  reinstalled"
    else
      echo "  installed"
    fi
    return 0
  fi

  if grep -q "already installed" <<<"$out"; then
    echo "  skipped (already installed; pass --force to reinstall)"
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
if $FORCE; then
  echo "Done (--force). Target: $PROJECT_DIR"
else
  echo "Done. Target: $PROJECT_DIR"
fi
exit $EXIT
