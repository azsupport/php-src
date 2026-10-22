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
            echo "first errors:"
            head -n 20 "$dir/errors.txt" | sed 's#.*/build-test/[^/]*/##' | cut -c1-240
        fi
        if [ -s "$dir/configure-tail.txt" ] && grep -q 'FAIL (configure' "$dir/summary.txt"; then
            echo "configure output (end):"
            tail -n 12 "$dir/configure-tail.txt" | cut -c1-240
        fi
        if [ -s "$dir/tests.txt" ]; then
            echo "failed tests ($(wc -l < "$dir/tests.txt" | tr -d ' ')):"
            # only the test files: the names alone fit into one annotation
            sed -n 's/.*\[\([^]]*\.phpt\)\].*/\1/p' "$dir/tests.txt" | head -n 80 | tr '\n' ' '
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
    printf '::%s title=PHP %s build test::%s\n' "$level" "$target" "$(head -c 3800 "$dir/report.txt" | escape)"
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
