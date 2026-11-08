#!/bin/sh
# build-deps-report.sh - turn deps-results/ of tools/build-deps.sh (the libraries
# of /usr/local/azsupport and the curl program) into the job log, the job summary and
# annotations: one for all of them (notice when every library built, error when
# not) and one per failed library with the end of its log.
#
# Usage: sh tools/build-deps-report.sh [results-dir]   (default: deps-results)

set -u
res="${1:-deps-results}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
escape() { sed 's/%/%25/g; s/\r/%0D/g' | awk '{ printf "%s%%0A", $0 }'; }

[ -s "$res/summary.txt" ] || { echo "::error title=azsupport::no results in $res"; exit 1; }
{
    cat "$res/summary.txt"
    if [ -s "$res/pic.txt" ]; then echo; echo "not position independent:"; cat "$res/pic.txt"; fi
    if [ -s "$res/links.txt" ]; then echo; echo "static link lines that miss libraries of the tree (tools/check-deps-links.py):"; cat "$res/links.txt"; fi
    if [ -s "$res/bins-bad.txt" ]; then echo; echo "not as it should be:"; cat "$res/bins-bad.txt"; fi
    if [ -s "$res/shared-bad.txt" ]; then echo; echo "the shared tree is not as it should be (finish_so of tools/build-deps.sh):"; cat "$res/shared-bad.txt"; fi
    if [ -s "$res/curl-bins.txt" ]; then echo; cat "$res/curl-bins.txt"; fi
    if [ -s "$res/pic-notes.txt" ]; then echo; echo "link test notes:"; cat "$res/pic-notes.txt"; fi
    if [ -s "$res/localbase.txt" ]; then echo; echo "files that name /usr/local/lib:"; cat "$res/localbase.txt"; fi
    if [ -s "$res/audit.txt" ]; then echo; echo "pkg audit (FreeBSD VuXML):"; head -n 30 "$res/audit.txt"; fi
} > "$res/report.txt"
cat "$res/report.txt"
if grep -q ' FAIL ' "$res/summary.txt" || [ -s "$res/pic.txt" ] || [ -s "$res/links.txt" ] || [ -s "$res/bins-bad.txt" ] ||
    [ -s "$res/shared-bad.txt" ] ||
    ! grep -q -E '^(tarball|installed):' "$res/summary.txt"; then
    level=error; rc=1
else
    level=notice; rc=0
fi
printf '::%s title=azsupport::%s\n' "$level" "$(head -c 3800 "$res/report.txt" | escape)"
{ echo "### azsupport (the libraries of /usr/local/azsupport) and the curl program"; echo; echo '```'; cat "$res/report.txt"; echo '```'; echo; } >> "$summary"
for t in "$res"/*.tail; do
    [ -f "$t" ] || continue
    n="$(basename "$t" .tail)"
    echo; echo "== the end of the log of $n"; cat "$t"
    printf '::error title=azsupport %s::%s\n' "$n" "$(cut -c1-240 "$t" | tail -c 3800 | escape)"
    { echo "#### $n"; echo; echo '```'; cat "$t"; echo '```'; echo; } >> "$summary"
done
exit "$rc"
