#!/bin/sh
# build-ffmpeg-report.sh - turn the results of tools/build-ffmpeg.sh and
# tools/ffmpeg-test.sh (ffmpeg-results/), or of tools/build-imagemagick.sh and
# tools/imagemagick-test.sh (imagemagick-results/), into the job log, the job
# summary and annotations: one for the whole build (notice when it built and
# every test passed, error when not), one per failed library with the end of its
# log, one with the failed tests.
#
# Usage: sh tools/build-ffmpeg-report.sh [results-dir [title]]
#        (default: ffmpeg-results, "FFmpeg for the video sites")

set -u
res="${1:-ffmpeg-results}"
title="${2:-FFmpeg for the video sites}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
escape() { sed 's/%/%25/g; s/\r/%0D/g' | awk '{ printf "%s%%0A", $0 }'; }

[ -s "$res/summary.txt" ] || { echo "::error title=$title::no results in $res"; exit 1; }
{
    cat "$res/summary.txt"
    for v in "$res"/version.txt "$res"/*-version.txt; do [ -s "$v" ] && { echo; head -n 1 "$v"; }; done
    if [ -s "$res/bins.txt" ]; then echo; cat "$res/bins.txt"; fi
    if [ -s "$res/bins-bad.txt" ]; then echo; echo "not as it should be:"; cat "$res/bins-bad.txt"; fi
    if [ -s "$res/tests.txt" ]; then
        echo
        grep -v '^ok ' "$res/tests.txt"
        echo "($(grep -c '^ok ' "$res/tests.txt") checks passed: ${res##*/}/tests.txt)"
    fi
} > "$res/report.txt"
cat "$res/report.txt"
if [ -s "$res/tests.txt" ]; then
    echo; echo "== tests.txt"; cat "$res/tests.txt"
fi
if grep -q ' FAIL ' "$res/summary.txt" || ! grep -q '^tarball:' "$res/summary.txt" || [ -s "$res/bins-bad.txt" ] ||
    ! tail -n 1 "$res/tests.txt" 2>/dev/null | grep -q '^tests: [0-9]* ok, 0 failed$'; then
    level=error; rc=1
else
    level=notice; rc=0
fi
printf '::%s title=%s::%s\n' "$level" "$title" "$(head -c 3800 "$res/report.txt" | escape)"
{ echo "### $title"; echo; echo '```'; cat "$res/report.txt"; echo '```'; echo; } >> "$summary"
for t in "$res"/*.tail; do
    [ -f "$t" ] || continue
    n="$(basename "$t" .tail)"
    printf '::error title=%s %s::%s\n' "$title" "$n" "$(cut -c1-240 "$t" | head -c 3800 | escape)"
    { echo "#### $n"; echo; echo '```'; cat "$t"; echo '```'; echo; } >> "$summary"
done
exit "$rc"
