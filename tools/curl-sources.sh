#!/bin/sh
# curl-sources.sh - the sources of the bundled curl: the curl release of a target
# (freebsd/curl.conf) and the libraries it needs (freebsd/curl-deps.conf).
#
# Usage: sh tools/curl-sources.sh [<target>] <dir>
#
# Puts curl into <dir>/libcurl and every library into <dir>/deps/<name>, from the
# release files, checked against the SHA-256 of the conf (the same as the
# distinfo of the FreeBSD port), without their top directory, with
# freebsd/curl/<name>-<version>.patch where there is one, and writes
# <dir>/deps/VERSIONS ("name version SHA-256 distfile", ext/curl/build-libcurl.sh
# rebuilds when it changes). Without <target>: the curl of the last line of
# curl.conf. tools/sync.sh runs it for ext/curl of every target with a curl,
# tools/build-deps.sh for the curl of /usr/local/phpdeps.
#
# Two changes to the releases, both for a build with only cc and make:
#   - libpsl gets src/suffixes_dafsa.h, the built-in list, made here with its
#     psl-make-dafsa (python3) from the list of psl-list (freebsd-ports
#     dns/public_suffix_list, newer than the one of the release); the name of a
#     file to look for at run time is left empty, so that libpsl uses the built-in
#     list only (psl-make-dafsa writes the base name of its input, which
#     psl_latest() would look for in the current directory);
#   - libpsl/fuzz (46 MB of fuzzing data) is left out.
#
# Downloads are kept in CURL_DISTFILES (default ${TMPDIR:-/tmp}/curl-distfiles);
# a release file that cannot be downloaded is taken from the distfile cache of
# FreeBSD (distcache.freebsd.org). Needs curl, tar (bsdtar, or GNU tar with xz,
# gzip, zstd and lzip), patch and python3.

set -eu
main_dir="$(cd "$(dirname "$0")/.." && pwd)"
curl_conf="$main_dir/freebsd/curl.conf"
deps_conf="$main_dir/freebsd/curl-deps.conf"
patches="$main_dir/freebsd/curl"
case $# in
    1) target="" dir="$1" ;;
    2) target="$1" dir="$2" ;;
    *) echo "usage: sh tools/curl-sources.sh [<target>] <dir>" >&2; exit 2 ;;
esac
cache="${CURL_DISTFILES:-${TMPDIR:-/tmp}/curl-distfiles}"
mkdir -p "$cache" "$dir"

sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | cut -c1-64; else sha256 -q "$1"; fi; }

# fetch <distfile> <sha256> <url>: the release file in the cache, checked
fetch() {
    f="$cache/$(printf '%s' "$1" | tr / _)"
    if [ ! -f "$f" ] || [ "$(sha256_of "$f")" != "$2" ]; then
        rm -f "$f"
        curl -fsSL --retry 3 -o "$f.part" "$3" ||
            curl -fsSL --retry 3 -o "$f.part" "https://distcache.freebsd.org/ports-distfiles/$1" ||
            { rm -f "$f.part"; echo "curl-sources: cannot download $3" >&2; return 1; }
        mv "$f.part" "$f"
    fi
    if [ "$(sha256_of "$f")" != "$2" ]; then
        echo "curl-sources: SHA-256 mismatch: $3 ($1)" >&2
        return 1
    fi
    printf '%s' "$f"
}

# unpack <file> <dir>: without the top directory of the archive
unpack() {
    rm -rf "$2"
    mkdir -p "$2"
    if command -v bsdtar >/dev/null 2>&1; then
        bsdtar -xf "$1" -C "$2" --strip-components 1
    elif tar --version 2>/dev/null | grep -q bsdtar; then
        tar -xf "$1" -C "$2" --strip-components 1
    else
        case "$1" in
            *.zst) zstd -dcq "$1" ;;
            *.lz) lzip -dc "$1" ;;
            *.xz) xz -dc "$1" ;;
            *.bz2) bzip2 -dc "$1" ;;
            *) gzip -dc "$1" ;;
        esac | tar -xf - -C "$2" --strip-components 1
    fi
}

# patch_in <dir> <patch>: a patch of freebsd/curl, -p0 as the ports have them
patch_in() {
    [ -f "$2" ] || return 0
    (cd "$1" && patch -p0 -N -s -f < "$2") || { echo "curl-sources: ${2##*/} does not apply" >&2; return 1; }
}

# curl
if [ -n "$target" ]; then
    set -- $(awk -v t="$target" '$1 == t { print $2, $3, $4 }' "$curl_conf")
else
    set -- $(awk '!/^#/ && NF >= 4 { v = $2; u = $3; s = $4 } END { print v, u, s }' "$curl_conf")
fi
[ $# = 3 ] || { echo "curl-sources: no curl for ${target:-any target} in $curl_conf" >&2; exit 1; }
cv="$1" cu="$2" cs="$3"
f="$(fetch "${cu##*/}" "$cs" "$cu")"
unpack "$f" "$dir/libcurl"
patch_in "$dir/libcurl" "$patches/curl-$cv.patch"

# the libraries
rm -rf "$dir/deps"
mkdir -p "$dir/deps"
: > "$dir/deps/VERSIONS"
awk '!/^#/ && NF >= 7 { print $1, $2, $5, $6, $7 }' "$deps_conf" | while read -r n v df s u; do
    f="$(fetch "$df" "$s" "$u")"
    unpack "$f" "$dir/deps/$n"
    patch_in "$dir/deps/$n" "$patches/$n-$v.patch"
    printf '%s %s %s %s\n' "$n" "$v" "$s" "$df" >> "$dir/deps/VERSIONS"
done
for n in c-ares nghttp2 brotli zstd libidn2 libpsl psl-list; do
    [ -d "$dir/deps/$n" ] || { echo "curl-sources: $n is not in $deps_conf" >&2; exit 1; }
done

# libpsl: the built-in list from psl-list, no file looked for at run time
psl="$dir/deps/libpsl"
rm -rf "$psl/fuzz"
python3 -I "$psl/src/psl-make-dafsa" --output-format=cxx+ \
    "$dir/deps/psl-list/public_suffix_list.dat" "$psl/src/suffixes_dafsa.h.new"
sed 's/^static const char _psl_filename\[\] = ".*";$/static const char _psl_filename[] = "";/' \
    "$psl/src/suffixes_dafsa.h.new" > "$psl/src/suffixes_dafsa.h"
rm -f "$psl/src/suffixes_dafsa.h.new"
grep -q '^static const char _psl_filename\[\] = "";$' "$psl/src/suffixes_dafsa.h" ||
    { echo "curl-sources: no _psl_filename in the output of psl-make-dafsa" >&2; exit 1; }

echo "curl-sources: curl $cv and $(awk '{ printf "%s%s %s", (NR > 1 ? ", " : ""), $1, $2 }' "$dir/deps/VERSIONS") in $dir"
