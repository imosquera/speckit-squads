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
# (If you change a manifest itself — extension.yml / preset.yml — run with
# --force to re-register installed items and refresh command/template registry.)
#
# Usage:
#   ./install.sh [--force] <project-dir>
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORCE_REINSTALL=0

PROJECT_DIR=""
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      echo "usage: $(basename "$0") [--force|-f] <project-dir>"
      exit 0
      ;;
    -f|--force)
      FORCE_REINSTALL=1
      ;;
    -*)
      echo "error: unknown flag: $arg" >&2
      echo "usage: $(basename "$0") [--force|-f] <project-dir>" >&2
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
  echo "usage: $(basename "$0") [--force|-f] <project-dir>" >&2
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

  reinstall_one() {
    local rm_out rm_rc add_out add_rc

    set +o pipefail
    rm_out="$(yes | specify "$kind" remove "$name" 2>&1)"
    rm_rc=$?
    set -o pipefail

    if [[ $rm_rc -ne 0 ]] && ! grep -qi "not installed\|not found\|unknown" <<<"$rm_out"; then
      echo "  FAILED during remove:"
      sed 's/^/    /' <<<"$rm_out" >&2
      return 1
    fi

    set +o pipefail
    add_out="$(yes | specify "$kind" add --dev "$src" 2>&1)"
    add_rc=$?
    set -o pipefail

    if [[ $add_rc -eq 0 ]]; then
      echo "  reinstalled (--force refresh)"
      return 0
    fi

    echo "  FAILED during re-add:"
    sed 's/^/    /' <<<"$add_out" >&2
    return 1
  }

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
    if [[ $FORCE_REINSTALL -eq 1 ]]; then
      reinstall_one
      return $?
    fi

    # --dev means the existing registration already points at this source
    # tree, so file edits are live. Manifest changes still require --force.
    echo "  already installed (live via --dev; use --force to refresh manifest)"
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
