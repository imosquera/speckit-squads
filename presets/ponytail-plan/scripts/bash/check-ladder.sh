#!/usr/bin/env bash
# ponytail-plan preset: check-ladder.sh
# Mechanical gate for the `## Ladder` section the plan layer requires.
#
# Checks only what is mechanical — a checker that guesses at prose cries wolf
# and gets disabled:
#   - plan.md has a `## Ladder` section (outside code fences)
#   - it holds either a `None — …` line or a table with at least one data row
#   - the table header has `Kind` and `Rung` columns
#   - every row's Kind is file/abstraction/dependency/config
#   - every row's Rung is a single integer 1-7
#   - a dependency row at rung 7 (a new dependency) requires a populated
#     `**Dependency justification:**` line in the section
#
# Whether a rung was honestly climbed is not checkable here; the prompt owns it.
#
# Usage: check-ladder.sh <plan.md>
#        check-ladder.sh <feature-dir>     (reads <feature-dir>/plan.md)
#
# Exit:  0 pass
#        1 violations (each printed as file:line on stderr)
#        2 bad usage or missing plan.md

set -uo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $(basename "$0") <plan.md | feature-dir>" >&2
    exit 2
fi

PLAN="$1"
[[ -d "$PLAN" ]] && PLAN="${PLAN%/}/plan.md"
if [[ ! -f "$PLAN" ]]; then
    echo "error: no such file: $PLAN" >&2
    exit 2
fi

awk -v F="$PLAN" '
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function bare(s) { s = trim(s); gsub(/[*`]/, "", s); return tolower(trim(s)) }
function err(n, msg) { printf "%s:%d: %s\n", F, n, msg > "/dev/stderr"; bad = 1 }
# Split a table row into cells[1..]; returns the count. Leading/trailing pipes dropped.
function cells_of(line, cells,    n, i, parts) {
    delete cells
    line = trim(line)
    sub(/^\|/, "", line); sub(/\|$/, "", line)
    n = split(line, parts, "|")
    for (i = 1; i <= n; i++) cells[i] = trim(parts[i])
    return n
}
BEGIN { found = 0; insec = 0; infence = 0; bad = 0; rows = 0; none = 0
        hdr = 0; kcol = 0; rcol = 0; just = 0; want_cont = 0; depline = 0 }
/^[ \t]*(```|~~~)/ { infence = !infence; next }
infence { next }
{
    line = $0
    if (match(line, /^#+[ \t]/)) {
        level = RLENGTH - 1
        title = bare(substr(line, RLENGTH + 1))
        if (insec && level <= 2) insec = 0
        if (!found && level == 2 && title ~ /^ladder([^a-z]|$)/) {
            found = 1; insec = 1; secline = NR
        }
        want_cont = 0
        next
    }
    if (!insec) next

    t = trim(line)
    if (want_cont) {
        if (t != "" && t !~ /^\|/ && t !~ /^\*\*/ && t !~ /^<[^>]*>$/) just = 1
        if (t != "") want_cont = 0
    }
    if (t ~ /^None[ \t]*(—|--?)[ \t]*[^ \t]/) { none = 1; next }
    if (index(t, "**Dependency justification:**") == 1) {
        rest = trim(substr(t, length("**Dependency justification:**") + 1))
        if (rest != "" && rest !~ /^<[^>]*>$/) just = 1
        else want_cont = 1
        next
    }
    if (t !~ /^\|/) next

    n = cells_of(t, c)
    if (!hdr) {
        hdr = 1; hdrline = NR
        for (i = 1; i <= n; i++) {
            if (bare(c[i]) == "kind") kcol = i
            if (bare(c[i]) == "rung") rcol = i
        }
        if (!kcol || !rcol) err(NR, "## Ladder table header needs `Kind` and `Rung` columns")
        next
    }
    if (t ~ /^\|[ \t:|-]+$/) next      # separator row
    rows++
    if (!kcol || !rcol) next
    kind = bare(c[kcol]); rung = bare(c[rcol])
    if (kind !~ /^(file|abstraction|dependency|config)$/)
        err(NR, "Kind must be file, abstraction, dependency, or config (got `" c[kcol] "`)")
    if (rung !~ /^[1-7]$/)
        err(NR, "Rung must be a single integer 1-7 (got `" c[rcol] "`)")
    else if (kind == "dependency" && rung == "7" && !depline)
        depline = NR
}
END {
    if (!found) {
        err(1, "missing `## Ladder` section")
    } else if (rows == 0 && !none) {
        err(secline, "## Ladder has no table rows and no `None — extends existing code only.` line")
    }
    if (depline && !just)
        err(depline, "new dependency (rung 7) without a populated `**Dependency justification:**` line in ## Ladder")
    if (bad) {
        print "ponytail-plan: fix plan.md and re-run." > "/dev/stderr"
        exit 1
    }
    if (none && rows == 0) print "ponytail-plan: ## Ladder declares no additions."
    else print "ponytail-plan: ## Ladder ok (" rows " item(s))."
}
' "$PLAN"
