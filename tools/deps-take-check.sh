#!/bin/sh
# deps-take-check.sh - do the patches of a port still apply to the release of its
# "take" line in freebsd/deps.conf (a new upstream release that phpdeps builds
# before the port has it)?
#
# Usage: sh tools/deps-take-check.sh [<name>...]     (default: every take line)
# Runs on Linux or FreeBSD from the top of a checkout of master (workflow
# deps-take-check.yml); needs git, curl or fetch, patch and diff.
#
# For each take line: fetches the release file, checks its SHA-256, extracts it and
# applies the patches as the ports framework does (patch -p0 in the source dir),
# from freebsd/deps/<name>-<version>/ when there is that directory, else from
# files/ of the port at the ports commit of deps.conf. It reports each patch as
# exact, applied with offset or fuzz, or failed; prints the failed hunks and the
# files a failed patch is for, so that the patch can be brought up to the release;
# and writes every patch that applies again against the release, without offset or
# fuzz, into deps-take-check/<name>-<version>/ (what freebsd/deps/<name>-<version>/
# would carry). Exit status: 0 every patch applies, 1 one does not, 2 usage.

set -u
top="$(pwd)"
conf="$top/freebsd/deps.conf"
out="$top/deps-take-check"
work="${DEPS_TAKE_WORK:-${TMPDIR:-/tmp}/deps-take-check.$$}"
[ -f "$conf" ] || { echo "deps-take-check: no $conf (run from the top of a checkout of master)" >&2; exit 2; }

commit="$(awk '$1 == "ports" { print $2 }' "$conf")"
names="$*"
[ -n "$names" ] || names="$(awk '$1 == "take" { print $2 }' "$conf")"
[ -n "$names" ] || { echo "deps-take-check: no take line in $conf"; exit 0; }

sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else sha256 -q "$1"; fi; }
get() { if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$1" "$2"; else fetch -q -o "$1" "$2"; fi; }

mkdir -p "$work" "$out"
ports="$work/ports"
paths=""
for n in $names; do
    p="$(awk -v n="$n" '$1 == "lib" && $2 == n { print $3 }' "$conf")"
    [ -n "$p" ] && [ "$p" != bundle ] || { echo "deps-take-check: $n is no library of a port in deps.conf" >&2; exit 2; }
    paths="$paths /$p/"
done
git init -q "$ports" &&
    git -C "$ports" remote add origin https://github.com/freebsd/freebsd-ports &&
    git -C "$ports" fetch -q --depth 1 --filter=blob:none origin "$commit" &&
    # shellcheck disable=SC2086
    git -C "$ports" sparse-checkout set --no-cone $paths &&
    git -C "$ports" checkout -q FETCH_HEAD || { echo "deps-take-check: freebsd-ports at $commit: failed" >&2; exit 1; }

rc=0
for n in $names; do
    port="$(awk -v n="$n" '$1 == "lib" && $2 == n { print $3 }' "$conf")"
    t="$(awk -v n="$n" '$1 == "take" && $2 == n { print $3, $4, $5, $6 }' "$conf")"
    [ -n "$t" ] || { echo "deps-take-check: $n has no take line" >&2; rc=1; continue; }
    # shellcheck disable=SC2086
    set -- $t
    ver="$1"; url="$2"; sha="$3"; srcdir="$4"
    f="$work/${url##*/}"
    echo "==== $n $ver ($port at $commit)"
    get "$f" "$url" || { echo "FAIL fetch $url"; rc=1; continue; }
    got="$(sha256_of "$f")"
    [ "$got" = "$sha" ] || { echo "FAIL $f: SHA-256 $got, not $sha as in deps.conf"; rc=1; continue; }
    x="$work/x-$n"; o="$work/o-$n"
    rm -rf "$x" "$o"; mkdir -p "$x" "$o"
    tar -xf "$f" -C "$x" && tar -xf "$f" -C "$o" || { echo "FAIL extract $f"; rc=1; continue; }
    src="$x/$srcdir"; orig="$o/$srcdir"
    [ -d "$src" ] || { echo "FAIL no $srcdir in the release (the top: $(ls "$x"))"; rc=1; continue; }
    pdir="$top/freebsd/deps/$n-$ver"
    if [ -d "$pdir" ]; then echo "patches: freebsd/deps/$n-$ver/"; else pdir="$ports/$port/files"; echo "patches: files/ of $port"; fi
    new="$out/$n-$ver"
    rm -rf "$new"; mkdir -p "$new"
    for p in "$pdir"/patch-*; do
        [ -f "$p" ] || continue
        b="${p##*/}"
        if patch -p0 -d "$src" --dry-run -s -F 0 < "$p" >/dev/null 2>&1 &&
            ! patch -p0 -d "$src" --dry-run -F 0 < "$p" 2>&1 | grep -q 'offset'; then
            echo "exact   $b"
        elif patch -p0 -d "$src" --dry-run -s < "$p" >/dev/null 2>&1; then
            echo "applies $b: $(patch -p0 -d "$src" --dry-run < "$p" 2>&1 | grep -E 'offset|fuzz' | tr '\n' ' ')"
        else
            echo "FAIL    $b"
            rc=1
            r="$work/rej-$b"
            rm -rf "$r"; cp -R "$o" "$r"
            patch -p0 -d "$r/$srcdir" -f --no-backup-if-mismatch -r "$work/$b.rej" < "$p" 2>&1 | sed 's/^/    /'
            echo "---- the hunks that fail ($b):"
            cat "$work/$b.rej" 2>/dev/null
            for g in $(sed -n 's#^+++ \([^	 ]*\).*#\1#p' "$p"); do
                echo "---- $srcdir/$g of the release (as it is):"
                cat "$orig/$g"
                echo "---- end of $g"
            done
            continue
        fi
        patch -p0 -d "$src" -s --no-backup-if-mismatch < "$p" || { echo "FAIL applying $b"; rc=1; continue; }
        # the same change, written against the release
        for g in $(sed -n 's#^+++ \([^	 ]*\).*#\1#p' "$p"); do
            diff -u --label "$g.orig" --label "$g" "$orig/$g" "$src/$g"
        done > "$new/$b"
    done
    echo "patches against $ver: deps-take-check/$n-$ver/"
done
rm -rf "$work"
exit "$rc"
