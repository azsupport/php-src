#!/bin/sh
# take-fetch.sh - fetch the files of the take lines of freebsd/*.conf into distfiles/
# of the checkout, on the runner before the FreeBSD VM (az.yml).
#
# Usage: sh tools/take-fetch.sh      (from the top of a checkout of master; curl, sha256sum)
#
# build-deps.sh, build-imagemagick.sh and build-ffmpeg.sh in the VM take a file from
# distfiles/ when its SHA-256 is that of the take line, and fetch it themselves only
# when it is not there. The runner reaches GitHub better than the VM does: on
# 08.11.2026 libde265 1.1.3 failed three times from the VM (fetch: transfer timed out)
# and came on the runner at once. Every address of a take line is tried up to five
# times. Exit status 0 always: a file not had here is a warning, the VM tries again.

set -u
top="$(pwd)"
out="$top/distfiles"
ls "$top"/freebsd/*.conf > /dev/null 2>&1 || { echo "take-fetch: no freebsd/*.conf (run from the top of a checkout of master)" >&2; exit 0; }
mkdir -p "$out"
awk '$1 == "take" { print $2, $3, $4, $5 }' "$top"/freebsd/*.conf | while read -r n v urls sha; do
    f="${urls%%,*}"; f="${f##*/}"
    if [ -f "$out/$f" ] && [ "$(sha256sum "$out/$f" | cut -d' ' -f1)" = "$sha" ]; then
        echo "take $n $v: $f is here"
        continue
    fi
    got=""
    for u in $(echo "$urls" | tr ',' ' '); do
        if curl -fsSL --retry 4 --retry-all-errors --retry-delay 10 --connect-timeout 30 --max-time 600 -o "$out/$f.part" "$u"; then
            s="$(sha256sum "$out/$f.part" | cut -d' ' -f1)"
            if [ "$s" = "$sha" ]; then mv "$out/$f.part" "$out/$f"; got="$u"; break; fi
            echo "::warning title=take $n::$u: SHA-256 $s, not $sha as in the take line"
        else
            echo "::warning title=take $n::$u: fetch failed"
        fi
        rm -f "$out/$f.part"
    done
    if [ -n "$got" ]; then echo "take $n $v: $f from $got"
    else echo "::warning title=take $n::$f was not had on the runner; the VM fetches it itself"; fi
done
exit 0
