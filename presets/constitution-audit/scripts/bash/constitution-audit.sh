#!/usr/bin/env bash
# constitution-audit.sh
#
# Deterministic helper for the constitution-audit preset.
#
# Subcommands:
#   list                          Print each principle heading from
#                                 .specify/memory/constitution.md, one per line.
#                                 Exit 0 if any principle is found, 1 otherwise.
#
#   validate <audit-file>         Validate <audit-file> against the constitution:
#                                   - every principle heading is referenced
#                                   - each principle has a verdict line containing
#                                     exactly one of PASS / VIOLATES / N/A
#                                   - each principle has at least one quoted span
#                                     (text inside double quotes, backticks, or a
#                                     `>` blockquote) that is a substring of the
#                                     constitution body for that principle —
#                                     this is the fabrication-killer.
#                                 Exit 0 on success, non-zero with a list of
#                                 missing / unquoted / fabricated entries.
#
# Principle heading detection (permissive):
#   ^#{1,4}\s+(Principle\s+)?(\d+|[IVXLCDM]+)[.:)]\s+<name>
# i.e. matches "## I. Foo", "### Principle 1: Bar", "#### 3) Baz", etc.

set -e

SUBCOMMAND="${1:-}"
shift || true

# ---------------------------------------------------------------------------
# Resolve repo root + constitution path
# ---------------------------------------------------------------------------
_find_project_root() {
    local dir="$1"
    while [ "$dir" != "/" ]; do
        if [ -d "$dir/.specify" ] || [ -d "$dir/.git" ]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=$(_find_project_root "$SCRIPT_DIR" || true)
if [ -z "$REPO_ROOT" ] && git rev-parse --show-toplevel >/dev/null 2>&1; then
    REPO_ROOT=$(git rev-parse --show-toplevel)
fi
if [ -z "$REPO_ROOT" ]; then
    REPO_ROOT="$PWD"
fi

CONSTITUTION="${CONSTITUTION_PATH:-$REPO_ROOT/.specify/memory/constitution.md}"

# Regex used by every subcommand. Captures the full heading text after the
# leading `#`s for display, and the principle key (number or roman) for
# matching against audit-file sections.
PRINCIPLE_RE='^#{1,4}[[:space:]]+(Principle[[:space:]]+)?([0-9]+|[IVXLCDMivxlcdm]+)[.):][[:space:]]+.+'

# Extract principle headings from the constitution. Output:
#   <line-number><TAB><key><TAB><full-heading-text>
# where <key> is the normalised principle identifier (digits or uppercase
# roman numerals) used to match audit sections.
_extract_principles() {
    awk -v re="$PRINCIPLE_RE" '
        match($0, re) {
            line = $0
            # Strip leading #s and spaces
            sub(/^#+[[:space:]]+/, "", line)
            # Capture key (number or roman) -- strip optional "Principle " prefix
            key = line
            sub(/^Principle[[:space:]]+/, "", key)
            # Now key starts with digits or roman; pull characters up to .):
            n = index(key, ".")
            c = index(key, ":")
            p = index(key, ")")
            stop = 0
            for (i = 0; i < 3; i++) {
                v = (i == 0 ? n : (i == 1 ? c : p))
                if (v > 0 && (stop == 0 || v < stop)) stop = v
            }
            if (stop > 0) key = substr(key, 1, stop - 1)
            # Uppercase roman numerals for stable matching
            key = toupper(key)
            printf "%d\t%s\t%s\n", NR, key, line
        }
    ' "$CONSTITUTION"
}

# Extract the body of a single principle from the constitution: every line
# between its heading and the next heading of equal-or-shallower depth.
# Used by `validate` to substring-check quoted spans.
_principle_body() {
    local target_line="$1"
    awk -v start="$target_line" '
        NR == start {
            match($0, /^#+/)
            depth = RLENGTH
            collecting = 1
            next
        }
        collecting && match($0, /^#+/) && RLENGTH <= depth { exit }
        collecting { print }
    ' "$CONSTITUTION"
}

# ---------------------------------------------------------------------------
# Subcommand: list
# ---------------------------------------------------------------------------
_cmd_list() {
    if [ ! -f "$CONSTITUTION" ]; then
        >&2 echo "[constitution-audit] No constitution at $CONSTITUTION; nothing to list."
        exit 1
    fi
    local count=0
    while IFS=$'\t' read -r _line _key heading; do
        [ -z "$heading" ] && continue
        printf '%s\n' "$heading"
        count=$((count + 1))
    done < <(_extract_principles)
    if [ "$count" -eq 0 ]; then
        >&2 echo "[constitution-audit] No principle headings matched in $CONSTITUTION."
        >&2 echo "[constitution-audit] Expected pattern: '## I. Name', '### Principle 1: Name', etc."
        exit 1
    fi
    exit 0
}

# ---------------------------------------------------------------------------
# Subcommand: validate <audit-file>
# ---------------------------------------------------------------------------
# Pull every quoted span from the audit section for one principle. Quotes
# can appear as:
#   - inside double quotes:   "..."
#   - inside backticks:       `...`
#   - on blockquote lines:    > ...
# Outputs one quote per line.
_extract_quotes() {
    local section_text="$1"
    {
        # Double-quoted spans (handles non-greedy match across one line).
        printf '%s\n' "$section_text" | grep -oE '"[^"]+"' | sed -E 's/^"//; s/"$//'
        # Backtick-quoted spans.
        printf '%s\n' "$section_text" | grep -oE '`[^`]+`' | sed -E 's/^`//; s/`$//'
        # Blockquote lines (strip leading "> ").
        printf '%s\n' "$section_text" | grep -E '^>[[:space:]]?' | sed -E 's/^>[[:space:]]?//'
    } | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$' || true
}

_cmd_validate() {
    local audit_file="${1:-}"
    if [ -z "$audit_file" ]; then
        >&2 echo "Usage: $0 validate <audit-file>"
        exit 2
    fi
    if [ ! -f "$CONSTITUTION" ]; then
        >&2 echo "[constitution-audit] No constitution at $CONSTITUTION; nothing to validate against."
        exit 0
    fi
    if [ ! -f "$audit_file" ]; then
        >&2 echo "[constitution-audit] Error: audit file not found: $audit_file"
        exit 1
    fi

    local audit_text
    audit_text=$(cat "$audit_file")

    local errors=0
    local checked=0

    while IFS=$'\t' read -r line key heading; do
        [ -z "$heading" ] && continue
        checked=$((checked + 1))

        # Section detection: the audit file must reference either the full
        # heading text or the key (number/roman). We pick the section as the
        # span from the first matching line up to the next blank-separated
        # heading or the end of file.
        local section
        section=$(awk -v key="$key" -v head="$heading" '
            BEGIN { collecting = 0 }
            {
                # Match a line that contains either the full heading text
                # OR a "Principle <key>" / "<key>." / "<key>:" reference.
                if (!collecting) {
                    if (index($0, head) > 0) { collecting = 1; print; next }
                    pat = "(^|[^A-Za-z0-9])(Principle[[:space:]]+)?" key "([.:)[:space:]])"
                    if ($0 ~ pat) { collecting = 1; print; next }
                } else {
                    # Stop at the next markdown heading or a new "Principle X" line
                    if ($0 ~ /^#{1,4}[[:space:]]+/) { exit }
                    print
                }
            }
        ' "$audit_file")

        if [ -z "$section" ]; then
            >&2 echo "[constitution-audit] MISSING: principle \"$heading\" has no section in $audit_file"
            errors=$((errors + 1))
            continue
        fi

        # Verdict check: must contain exactly one of PASS / VIOLATES / N/A
        # as a standalone token (not embedded in a word).
        if ! printf '%s' "$section" | grep -Eq '(^|[^A-Za-z])(PASS|VIOLATES|N/A)([^A-Za-z]|$)'; then
            >&2 echo "[constitution-audit] NO VERDICT: principle \"$heading\" section lacks a PASS / VIOLATES / N/A line"
            errors=$((errors + 1))
            continue
        fi

        # Quote check: at least one quoted span must be a substring of the
        # principle's body in the constitution. This is the fabrication-killer.
        local body
        body=$(_principle_body "$line")
        if [ -z "$body" ]; then
            # Fallback: search the entire constitution for the quote so we
            # don't false-negative on unusual heading structures.
            body=$(cat "$CONSTITUTION")
        fi

        # Normalise whitespace in the body for substring checks: collapse all
        # runs of whitespace (including newlines) to a single space.
        local body_norm
        body_norm=$(printf '%s' "$body" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g')

        local quote_ok=false
        local quotes
        quotes=$(_extract_quotes "$section")
        if [ -n "$quotes" ]; then
            while IFS= read -r q; do
                [ -z "$q" ] && continue
                # Reject trivially short quotes (single word) — too easy to fake.
                local word_count
                word_count=$(printf '%s' "$q" | wc -w | tr -d ' ')
                if [ "$word_count" -lt 4 ]; then continue; fi
                local q_norm
                q_norm=$(printf '%s' "$q" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g')
                if [ "${body_norm#*"$q_norm"}" != "$body_norm" ]; then
                    quote_ok=true
                    break
                fi
            done <<< "$quotes"
        fi

        if [ "$quote_ok" != "true" ]; then
            >&2 echo "[constitution-audit] UNQUOTED OR FABRICATED: principle \"$heading\" has no quoted span (>=4 words) that appears in the constitution"
            errors=$((errors + 1))
        fi
    done < <(_extract_principles)

    if [ "$checked" -eq 0 ]; then
        >&2 echo "[constitution-audit] No principle headings matched in $CONSTITUTION; treating as no-op."
        exit 0
    fi

    if [ "$errors" -gt 0 ]; then
        >&2 echo "[constitution-audit] $errors / $checked principles failed validation. Fix the audit and re-run."
        exit 1
    fi

    >&2 echo "[constitution-audit] OK: all $checked principles have a verdict and a verified quote."
    exit 0
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "$SUBCOMMAND" in
    list)     _cmd_list "$@" ;;
    validate) _cmd_validate "$@" ;;
    -h|--help|"")
        cat <<EOF
Usage: $(basename "$0") <subcommand> [args]

Subcommands:
  list                      Print constitution principle headings, one per line.
  validate <audit-file>     Validate an audit file (or plan.md) against the
                            constitution. Exits non-zero on missing principles,
                            missing verdicts, or unquoted/fabricated quotes.

Environment:
  CONSTITUTION_PATH         Override the constitution path
                            (default: <repo>/.specify/memory/constitution.md)
EOF
        [ -z "$SUBCOMMAND" ] && exit 2 || exit 0
        ;;
    *)
        >&2 echo "Unknown subcommand: $SUBCOMMAND"
        >&2 echo "Run '$(basename "$0") --help' for usage."
        exit 2
        ;;
esac
