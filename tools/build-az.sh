#!/bin/sh
# build-az.sh - build the static programs of the fork for FreeBSD as packages
# that take the place of those of the ports, and the static libraries they and
# PHP are built against, with a repository of pkg made of them:
#   az-libs        the static libraries of /usr/local/az (tools/build-deps.sh,
#                  freebsd/deps.conf): lib/, include/, lib/pkgconfig/, the
#                  *-config scripts and bin/pkg-config, for builds against them
#                  (PHP: tools/az-menu.sh, tools/config-check.sh); only there,
#                  since those of the packages (png, pcre2, libxml2, expat...) stay
#                  in /usr/local for the others (apache24, git...)
#   curl           in the place of ftp/curl: bin/curl (static) and lib/libcurl.so.4
#                  (the libraries of curl and OpenSSL inside it, only curl_*
#                  exported), so that git and the other packages that link libcurl
#                  take this one; the static libcurl in /usr/local/az for PHP
#   ffmpeg         in the place of multimedia/ffmpeg: bin/ffmpeg, bin/ffprobe
#                  (tools/build-ffmpeg.sh, freebsd/ffmpeg.conf)
#   ImageMagick6   bin/convert6, identify6, mogrify6, composite6... with
#                  etc/ImageMagick-6, share/ImageMagick-6, lib/ImageMagick-6.*
#   ImageMagick7   in the place of graphics/ImageMagick7: bin/magick and the
#                  names linked to it, etc/ImageMagick-7...; its static libraries,
#                  headers and MagickWand-config in /usr/local/az, for imagick
#                  (tools/build-imagemagick.sh, freebsd/imagemagick.conf)
# The names, origins and epochs are those of the ports, the versions those of the
# ports with a revision of the build (AZ_STAMP, default the time of the build,
# UTC, YYMMDDHH), so that a new build is an upgrade; the repository az is given a
# priority over that of FreeBSD on the servers. The programs are static: none of
# the packages depends on another to run. Each has its list of versions and
# options in share/doc/<name>/VERSIONS and its licences in share/licenses/<name>/
# (az-libs: /usr/local/az/LICENSES/).
#
# Usage (FreeBSD, as root, from the top of a php-src checkout of master; it
# installs the packages it makes, in the place of those of the ports: a build
# machine, not a server):
#   sh tools/build-az.sh --tools   install the build tools of every part (pkg)
#   sh tools/build-az.sh           build, package, install and test
#
# The steps: the libraries and the curl program (tools/build-deps.sh), FFmpeg,
# ImageMagick 6 and 7, all into stages (AZ_STAGE, default AZ_WORK/stage) but the
# libraries (/usr/local/az, which must be empty or missing); the samples of the
# tests, made with the packages of FreeBSD (ffmpeg-test.sh and imagemagick-test.sh
# --samples), which are then removed; the packages and the repository
# (dist/az-fbsd<major>-amd64-<level>/: the packages, meta.conf, packagesite.pkg,
# data.pkg of pkg repo, served as it is from one directory, such as the files of a
# GitHub release); an install from it into an empty root; the install here, curl
# over the one of the ports; the tests of the installed programs
# (tools/ffmpeg-test.sh, tools/imagemagick-test.sh, tools/curl-test.sh with git)
# and a program linked as imagick links ImageMagick 7. AZ_CPUTYPE and AZ_CFLAGS as
# for the parts (default: CPUTYPE and CFLAGS of /etc/make.conf, else x86-64-v3 and
# -O3 -pipe). Results: az-results/ (summary.txt, tests.txt: the packages, the
# repository, the installs, imagick), deps-results/, ffmpeg-results/,
# imagemagick-results/, curl-results/.
#
# Exit status: 0 everything built, every test passed and the packages are made;
# 1 something failed (the results say what); 2 usage.

set -u
top="$(pwd)"
A="${AZ_PREFIX:-/usr/local/az}"
work="${AZ_WORK:-/var/tmp/az-work}"
stage="${AZ_STAGE:-$work/stage}"
export AZ_STAGE="$stage"
res="$top/az-results"
major="$(uname -r | cut -d. -f1)"

if [ "${1:-}" = "--tools" ]; then
    rc=0
    for p in deps ffmpeg imagemagick; do sh "$top/tools/build-$p.sh" --tools || rc=1; done
    exit $rc
fi
[ $# -eq 0 ] || { echo "usage: sh tools/build-az.sh [--tools]" >&2; exit 2; }
[ -f "$top/freebsd/deps.conf" ] || { echo "build-az: run from the top of a php-src checkout of master" >&2; exit 2; }

say() { printf '[build-az %s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
if [ -n "$(ls -d "$A"/php* "$A"/bin/php* "$A"/etc/php* 2>/dev/null | head -n 1)" ]; then
    echo "build-az: $A has PHP builds in it; build into an empty directory (AZ_PREFIX=...)" >&2
    exit 2
fi

mk_conf="${MAKE_CONF:-/etc/make.conf}"
mc_get() {
    [ -r "$mk_conf" ] || return 0
    awk -v v="$1" '
        { sub(/#.*/, "") }
        $0 ~ "^[ \t]*" v "[ \t]*[?:]?=" { s = $0; sub("^[ \t]*" v "[ \t]*[?:]?=[ \t]*", "", s); val = s; have = 1; next }
        END { if (have) { sub(/[ \t]+$/, "", val); print val } }
    ' "$mk_conf"
}
cputype="${AZ_CPUTYPE:-$(mc_get CPUTYPE)}"
cputype="${cputype:-x86-64-v3}"
level="${cputype#x86-64-}"
stamp="${AZ_STAMP:-$(date -u +%y%m%d%H)}"
repo="$top/dist/az-fbsd$major-amd64-$level"
ports_commit="$(awk '$1 == "ports" { print $2 }' "$top/freebsd/deps.conf")"

rm -rf "$res" "$repo" "$stage"
mkdir -p "$res" "$repo" "$stage"
: > "$res/summary.txt"
: > "$res/tests.txt"
rm -rf "$A"
part() { printf '%-16s %s\n' "$1" "$2" >> "$res/summary.txt"; }
pok=0; pbad=0
tpass() { echo "ok    $*" >> "$res/tests.txt"; pok=$((pok + 1)); }
tfail() { echo "FAIL  $*" >> "$res/tests.txt"; pbad=$((pbad + 1)); }
# space <after what>: the free space of the work directory, into the summary
space() {
    d="$work"; [ -d "$d" ] || d=/var/tmp
    f="$(df -h "$d" | awk 'NR == 2 { print $4 " free of " $2 " (" $5 " used, " $6 ")" }')"
    say "disk after $1: $f"
    printf '%-16s %s\n' "disk" "after $1: $f" >> "$res/summary.txt"
}

# --- the builds ---------------------------------------------------------------------
rc=0
mkdir -p "$work"
space "the start"
say "libraries and the curl program (tools/build-deps.sh)"
if sh "$top/tools/build-deps.sh"; then part libraries OK; else part libraries FAIL; rc=1; fi
space "the libraries"
if [ "$rc" = 0 ]; then
    say "FFmpeg (tools/build-ffmpeg.sh)"
    if sh "$top/tools/build-ffmpeg.sh"; then part ffmpeg OK; else part ffmpeg FAIL; rc=1; fi
    space "FFmpeg"
    say "ImageMagick 6 and 7 (tools/build-imagemagick.sh)"
    if sh "$top/tools/build-imagemagick.sh"; then part imagemagick OK; else part imagemagick FAIL; rc=1; fi
    space "ImageMagick"
fi
if [ "$rc" != 0 ]; then
    echo "not packaged: a part failed (its results say why)" >> "$res/summary.txt"
    exit 1
fi

# --- the samples of the tests, with the packages of FreeBSD, which then go ---------
say "samples"
for t in ffmpeg imagemagick; do
    sh "$top/tools/$t-test.sh" --samples > "$res/$t-samples.log" 2>&1 || part "$t samples" "FAIL ($(tail -n 1 "$res/$t-samples.log"))"
done
old="$(pkg query %n ffmpeg ffmpeg-nox11 ImageMagick7 ImageMagick7-nox11 ImageMagick6 ImageMagick6-nox11 2>/dev/null | tr '\n' ' ')"
# shellcheck disable=SC2086
[ -n "$old" ] && pkg delete -y $old > "$res/pkg-delete.log" 2>&1

# --- the packages -------------------------------------------------------------------
# the files of curl in /usr/local/az (its static libcurl, for PHP) go with it
mkdir -p "$stage/curl$A"
# shellcheck disable=SC2046
(cd "$A" && tar -cf - bin/curl-config bin/curl-config.orig lib/libcurl.a lib/pkgconfig/libcurl.pc include/curl \
    $(ls -d LICENSES/curl-* 2>/dev/null)) | (cd "$stage/curl$A" && tar -xpf -) ||
    tfail "curl: the files of $A could not be copied"
# version and epoch of a port, from the built.txt of a part ("<name> <pkgname> <port>")
pv() { awk -v n="$2" '$1 == n { v = $2; sub(/^.*-/, "", v); e = ""; if (index(v, ",")) e = substr(v, index(v, ",")); sub(/[_,].*$/, "", v); print v "|" e }' "$1"; }
v_curl="$(pv "$top/deps-results/built.txt" curl)"
v_ffmpeg="$(pv "$top/ffmpeg-results/built.txt" ffmpeg)"
v_im6="$(pv "$top/imagemagick-results/built.txt" imagemagick6)"
v_im7="$(pv "$top/imagemagick-results/built.txt" imagemagick7)"
# share/doc/<name>/VERSIONS
docs() { mkdir -p "$stage/$1/usr/local/share/doc/$1" && cp "$2" "$stage/$1/usr/local/share/doc/$1/VERSIONS"; }
{
    echo "curl ${v_curl%|*} for FreeBSD $major (amd64, $cputype): bin/curl, lib/libcurl.so.4 (and the static libcurl of"
    echo "$A for PHP) of the bundled curl of the fork (freebsd/curl.conf, freebsd/curl-deps.conf,"
    echo "freebsd/curl/build-libcurl.sh), with the libraries of az-libs; the build of the libraries:"
    echo
    cat "$top/deps-results/VERSIONS"
    echo
    cat "$top/deps-results/curl-version.txt"
} > "$res/VERSIONS.curl"
docs curl "$res/VERSIONS.curl"
docs ffmpeg "$top/ffmpeg-results/VERSIONS"
docs ImageMagick6 "$top/imagemagick-results/imagemagick6.VERSIONS"
docs ImageMagick7 "$top/imagemagick-results/imagemagick7.VERSIONS"

# manifest <name> <origin> <version|epoch> <prefix> <comment> <licence> <category> <description>:
# the +MANIFEST of a package (in az-results/meta.<name>/, for pkg create -m)
manifest() {
    mkdir -p "$res/meta.$1"
    python3 - "$@" "$stamp" "$cputype" "$ports_commit" > "$res/meta.$1/+MANIFEST" <<'EOF'
import json, sys
name, origin, ve, prefix, comment, lic, cat, desc, stamp, cputype, commit = sys.argv[1:12]
v, e = ve.split("|")
print(json.dumps({
    "name": name, "origin": origin, "version": "%s_%s%s" % (v, stamp, e),
    "comment": comment, "desc": desc, "maintainer": "github@azsupport.com",
    "www": "https://github.com/azsupport/php-src", "prefix": prefix,
    "licenselogic": "single", "licenses": [lic], "categories": [cat, "az"],
    "annotations": {"cputype": cputype, "freebsd_ports": commit,
                    "built_by": "tools/build-az.sh of https://github.com/azsupport/php-src"},
}, indent=1))
EOF
}
manifest az-libs az/libs "$(date -u +%Y%m%d)|" "$A" "Static libraries of /usr/local/az, for builds of PHP and the programs" \
    MULTI devel "The static, position independent libraries of $A (freebsd/deps.conf of https://github.com/azsupport/php-src): PHP built against them (az-menu.sh, config-check.sh) and the programs of the fork need no library of /usr/local/lib. Versions: $A/share/doc/az-libs/VERSIONS."
manifest curl ftp/curl "$v_curl" /usr/local "Command line tool and library for transferring data with URLs (static, of azsupport/php-src)" \
    MIT ftp "curl ${v_curl%|*} with c-ares, HTTP/2, brotli, zstd, IDN and the Public Suffix List, the OpenSSL of az-libs inside: bin/curl (static) and lib/libcurl.so.4 in the place of those of the port ftp/curl (no IMAP, POP3, SMTP, LDAP, NTLM, telnet, TFTP, DICT, gopher, MQTT, RTSP), and the static libcurl of $A for PHP. Versions: share/doc/curl/VERSIONS."
manifest ffmpeg multimedia/ffmpeg "$v_ffmpeg" /usr/local "FFmpeg for the video sites, static (ffmpeg, ffprobe)" \
    GPLv2+ multimedia "FFmpeg ${v_ffmpeg%|*} with only what the video sites need (freebsd/ffmpeg.conf of https://github.com/azsupport/php-src): bin/ffmpeg and bin/ffprobe, static, in the place of those of the port. Versions and options: share/doc/ffmpeg/VERSIONS."
manifest ImageMagick6 graphics/ImageMagick6 "$v_im6" /usr/local "ImageMagick 6 for the video sites, static (convert6, identify6, ...)" \
    ImageMagick graphics "ImageMagick ${v_im6%|*} with JPEG, PNG, WebP, GIF, HEIC and AVIF only and the policy of freebsd/imagemagick/policy.xml (https://github.com/azsupport/php-src): bin/convert6, identify6, mogrify6, composite6 and the others, static, next to ImageMagick 7. Versions and options: share/doc/ImageMagick6/VERSIONS."
manifest ImageMagick7 graphics/ImageMagick7 "$v_im7" /usr/local "ImageMagick 7 for the video sites, static (magick), and its libraries for imagick" \
    ImageMagick graphics "ImageMagick ${v_im7%|*} with JPEG, PNG, WebP, GIF, HEIC and AVIF only and the policy of freebsd/imagemagick/policy.xml (https://github.com/azsupport/php-src): bin/magick and the names linked to it (convert, identify, ...), static, in the place of those of the port; its static libraries in $A for imagick of PHP (--with-imagick=$A). Versions and options: share/doc/ImageMagick7/VERSIONS."

say "packages"
: > "$res/packages.txt"
# plist <name> <root>: every file of the root (absolute paths), config files with @config
plist() {
    (cd "$2" && find . ! -type d | sed 's#^\.##' | LC_ALL=C sort) |
        awk '/\/etc\/ImageMagick-[67]\/policy\.xml$/ { print "@config " $0; next } { print }' > "$res/plist.$1"
}
# the files of az-libs: those of /usr/local/az but curl's
(cd / && find ".$A" ! -type d | sed 's#^\.##' | LC_ALL=C sort) > "$res/files.az"
(cd "$stage/curl" && find ".$A" ! -type d | sed 's#^\.##' | LC_ALL=C sort) > "$res/files.az-curl"
LC_ALL=C comm -23 "$res/files.az" "$res/files.az-curl" > "$res/plist.az-libs"
for n in curl ffmpeg ImageMagick6 ImageMagick7; do plist "$n" "$stage/$n"; done
for n in az-libs curl ffmpeg ImageMagick6 ImageMagick7; do
    if [ "$n" = az-libs ]; then r=/; else r="$stage/$n"; fi
    if [ ! -s "$res/plist.$n" ]; then tfail "$n: no files"; continue; fi
    if pkg create -m "$res/meta.$n" -p "$res/plist.$n" -r "$r" -o "$repo" > "$res/create.$n.log" 2>&1; then
        f="$(ls "$repo"/"$n"-[0-9]*.pkg 2>/dev/null | head -n 1)"
        nf="$(pkg info -l -F "$f" 2>/dev/null | grep -c '^	/')"
        echo "${f##*/} $(du -Ak "$f" | cut -f1) KB, $nf files" >> "$res/packages.txt"
        if [ "$nf" = "$(wc -l < "$res/plist.$n" | tr -d ' ')" ]; then tpass "$n: ${f##*/}, $nf files"
        else tfail "$n: ${f##*/} has $nf files, the list $(wc -l < "$res/plist.$n" | tr -d ' ')"; fi
    else
        tfail "$n: pkg create: $(tail -n 2 "$res/create.$n.log" | tr '\n' ' ')"
    fi
done
# no file in two packages
cat "$res"/plist.* | sed 's/^@config //' | LC_ALL=C sort | uniq -d | head -n 3 > "$res/dups.txt"
if [ -s "$res/dups.txt" ]; then tfail "files in two packages: $(tr '\n' ' ' < "$res/dups.txt")"
else tpass "no file in two packages ($(cat "$res"/plist.* | wc -l | tr -d ' ') files)"; fi

# --- the repository, an install into an empty root, the install here ---------------
names="az-libs curl ffmpeg ImageMagick6 ImageMagick7"
rd="$res/repos"
mkdir -p "$rd"
printf 'aztest: { url: "file://%s", signature_type: "none", priority: 100, enabled: yes }\n' "$repo" > "$rd/aztest.conf"
if pkg repo "$repo" > "$res/repo.log" 2>&1; then
    tpass "pkg repo: $(cd "$repo" && ls | grep -v -E '^(az-libs|curl|ffmpeg|ImageMagick[67])-[0-9].*\.pkg$' | tr '\n' ' ')"
    root="/var/tmp/az-pkg-root"
    rm -rf "$root"; mkdir -p "$root"
    abi="$(pkg config ABI)"
    tp() { pkg -o REPOS_DIR="$rd" -o PKG_DBDIR="$root/var/db/pkg" -o PKG_CACHEDIR="$root/var/cache/pkg" \
        -o ABI="$abi" -o IGNORE_OSVERSION=yes -r "$root" "$@"; }
    # shellcheck disable=SC2086
    if tp update -f > "$res/install-root.log" 2>&1 && tp install -y -r aztest $names >> "$res/install-root.log" 2>&1; then
        (cd "$root" && find . ! -type d | sed 's#^\.##' | grep -v -E '^/var/(db|cache)/pkg/' | LC_ALL=C sort) > "$res/files.root"
        cat "$res"/plist.* | sed 's/^@config //' | LC_ALL=C sort > "$res/files.packages"
        if cmp -s "$res/files.root" "$res/files.packages"; then tpass "pkg install into an empty root: the $(wc -l < "$res/files.packages" | tr -d ' ') files of the packages"
        else tfail "pkg install into an empty root: other files ($(LC_ALL=C comm -3 "$res/files.root" "$res/files.packages" | head -n 3 | tr '\n' ' '))"; fi
    else
        tfail "pkg install into an empty root: $(tail -n 3 "$res/install-root.log" | tr '\n' ' ')"
    fi
    # here: curl over that of the ports (git takes it), the others where those of the ports were
    # shellcheck disable=SC2086
    if pkg -o REPOS_DIR="$rd" update -f -r aztest > "$res/install.log" 2>&1 &&
        pkg -o REPOS_DIR="$rd" install -y -r aztest $names >> "$res/install.log" 2>&1; then
        tpass "pkg install here: $(pkg query '%n-%v' $names | tr '\n' ' ')"
    else
        tfail "pkg install here: $(tail -n 3 "$res/install.log" | tr '\n' ' ')"
    fi
else
    tfail "pkg repo: $(tail -n 2 "$res/repo.log" | tr '\n' ' ')"
fi

# --- the tests of the installed programs --------------------------------------------
say "tests"
for t in ffmpeg imagemagick curl; do
    if sh "$top/tools/$t-test.sh" > "$res/$t-test.log" 2>&1; then part "$t tests" "OK ($(tail -n 1 "$res/$t-test.log"))"
    else part "$t tests" "FAIL ($(tail -n 1 "$res/$t-test.log"))"; rc=1; fi
done
mkdir -p "$top/curl-results"
{ grep '^curl program' "$top/deps-results/summary.txt"; cat "$top/deps-results/curl-bins.txt" 2>/dev/null; } > "$top/curl-results/summary.txt"
if grep -q '^ok .*pkg install here' "$res/tests.txt"; then
    echo "installed: the package curl, /usr/local/bin/curl and lib/libcurl.so.4" >> "$top/curl-results/summary.txt"
fi
# imagick of PHP links the static libraries of ImageMagick 7 in, with the line of
# MagickWand-config of /usr/local/az: a program (and a shared object, as libphp.so)
# that does so, run once; it has to find HEIC among the formats (libheif, the policy)
t="$work/imagick-link"
rm -rf "$t"; mkdir -p "$t"
cat > "$t/t.c" <<'EOF'
#include <stdio.h>
#include <string.h>
#include <MagickWand/MagickWand.h>
int main(void)
{
    size_t n = 0, i, heic = 0;
    char **f;
    MagickWandGenesis();
    f = MagickQueryFormats("*", &n);
    for (i = 0; i < n; i++)
        if (strcmp(f[i], "HEIC") == 0)
            heic = 1;
    printf("%s; %zu formats; HEIC %s\n", MagickGetVersion(NULL), n, heic ? "yes" : "no");
    MagickWandTerminus();
    return heic ? 0 : 1;
}
EOF
if cf="$("$A/bin/MagickWand-config" --cflags)" && lf="$("$A/bin/MagickWand-config" --libs)" &&
    {
        echo "MagickWand-config --cflags: $cf"
        echo "MagickWand-config --libs: $lf"
        # shellcheck disable=SC2086
        cc -O2 -fPIC $cf -o "$t/t" "$t/t.c" $lf && "$t/t" &&
            cc -O2 -fPIC -shared $cf -o "$t/t.so" "$t/t.c" $lf -Wl,--no-undefined &&
            echo "shared object: linked" &&
            echo "libraries of the program: $(ldd "$t/t" | awk 'NF > 2 && $2 == "=>" { print $3 }' | tr '\n' ' ')"
    } > "$res/imagick-link.txt" 2>&1; then
    tpass "imagick: $(grep -m 1 'formats' "$res/imagick-link.txt"), linked as imagick links it"
else
    tfail "imagick: the static libraries of ImageMagick 7 do not link as imagick links them: $(tail -n 3 "$res/imagick-link.txt" | tr '\n' ' ')"
fi

echo "tests: $pok ok, $pbad failed" >> "$res/tests.txt"
{
    echo
    cat "$res/packages.txt"
} >> "$res/summary.txt"
if [ "$pbad" = 0 ] && [ "$rc" = 0 ]; then
    echo "repo: ${repo#"$top"/} ($(du -Ask "$repo" | cut -f1) KB): $(ls "$repo" | wc -l | tr -d ' ') files" >> "$res/summary.txt"
else
    rc=1
fi
exit "$rc"
