#!/bin/sh
# build-test-report.sh - turn the results of tools/build-test.sh into the job
# log, the job summary and one annotation per target (notice when the target
# built, error when not), so the outcome shows on the run page and in the API.
#
# Usage: sh tools/build-test-report.sh [results-dir]   (default: build-test-results)

set -u
res="${1:-build-test-results}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

# Workflow commands need %, CR and LF escaped.
escape() { sed 's/%/%25/g; s/\r/%0D/g' | awk '{ printf "%s%%0A", $0 }'; }

[ -d "$res" ] || { echo "::error title=build-test::no results in $res"; exit 1; }
rc=0
# packages that build-test.sh --deps asked for and pkg did not install
if [ -s "$res/deps-missing.txt" ]; then
    echo "packages not installed: $(tr '\n' ' ' < "$res/deps-missing.txt")"
    printf '::warning title=build-test packages::%s\n' "not installed by pkg install: $(tr '\n' ' ' < "$res/deps-missing.txt")"
    printf '**Packages not installed:** %s\n\n' "$(tr '\n' ' ' < "$res/deps-missing.txt")" >> "$summary"
fi
for dir in "$res"/*/; do
    [ -f "$dir/summary.txt" ] || continue
    target="$(basename "$dir")"
    {
        cat "$dir/summary.txt"
        if [ -s "$dir/smoke.txt" ] && grep -q '^FAIL ' "$dir/smoke.txt"; then
            echo "smoke checks that failed:"
            grep '^FAIL ' "$dir/smoke.txt" | cut -c1-200
        fi
        if [ -s "$dir/errors.txt" ] && ! grep -q '^result: *OK' "$dir/summary.txt"; then
            # a link that fails on a static library: every undefined symbol once, with the
            # archive that wants it (the first errors below show only a few)
            if grep -q 'undefined symbol: ' "$dir/errors.txt"; then
                echo "undefined symbols (archive that needs them):"
                awk '
                    function flush() { if (s != "") print s " (" (a == "" ? "?" : a) ")"; s = "" }
                    /undefined symbol: / { flush(); s = $0; sub(/.*undefined symbol: /, "", s); a = ""; next }
                    s != "" && a == "" && / in archive / { a = $0; sub(/.* in archive /, "", a); sub(/.*\//, "", a) }
                    END { flush() }
                ' "$dir/errors.txt" | sort -u | head -n 40 | cut -c1-200
            fi
            echo "first errors:"
            head -n 20 "$dir/errors.txt" | sed 's#.*/build-test/[^/]*/##' | cut -c1-240
        fi
        if [ -s "$dir/configure-tail.txt" ] && grep -q 'FAIL (configure' "$dir/summary.txt"; then
            echo "configure output (end):"
            tail -n 12 "$dir/configure-tail.txt" | cut -c1-240
        fi
        if [ -s "$dir/tests.txt" ]; then
            echo "failed tests ($(wc -l < "$dir/tests.txt" | tr -d ' '); ext/x/tests/y.phpt shown as x/y, so that the list fits into the annotation):"
            sed -n 's/.*\[\([^]]*\.phpt\)\].*/\1/p' "$dir/tests.txt" |
                sed -e 's#^ext/##' -e 's#/tests/#/#' -e 's#\.phpt$##' | head -n 150 | tr '\n' ' '
            echo
        fi
    } > "$dir/report.txt"

    echo "==================== $target"
    cat "$dir/report.txt"
    if grep -q '^result: *OK' "$dir/summary.txt"; then
        level=notice
    else
        level=error
        rc=1
    fi
    # An annotation holds about 4 KB: a report that is longer (the list of failed
    # tests of a full test run) goes on in more annotations, cut at spaces.
    rm -f "$dir"/annot.*
    fold -b -s -w 3600 "$dir/report.txt" |
        LC_ALL=C awk -v d="$dir" '
            { line = $0 "\n"
              if (n == 0 || size + length(line) > 3800) { if (n) close(f); n++; size = 0; f = d "/annot." n }
              printf "%s", line > f; size += length(line) }'
    part=1
    while [ -f "$dir/annot.$part" ]; do
        if [ "$part" -eq 1 ]; then
            title="PHP $target build test"
        else
            title="PHP $target build test, continued ($part)"
        fi
        printf '::%s title=%s::%s\n' "$level" "$title" "$(escape < "$dir/annot.$part")"
        part=$((part + 1))
    done
    {
        echo "### PHP $target"
        echo
        echo '```'
        cat "$dir/report.txt"
        echo '```'
        echo
    } >> "$summary"
done
exit "$rc"
