#!/bin/sh
# build-az.sh - build /usr/local/az for FreeBSD and its packages: the static
# libraries PHP and the programs are built against (tools/build-deps.sh,
# freebsd/deps.conf), the curl program, FFmpeg (tools/build-ffmpeg.sh,
# freebsd/ffmpeg.conf), ImageMagick 6 and 7 (tools/build-imagemagick.sh,
# freebsd/imagemagick.conf); then the tests of each (tools/ffmpeg-test.sh,
# tools/imagemagick-test.sh, tools/curl-test.sh) and the packages, with a
# repository of pkg made of them:
#   az-libs           the static libraries (lib/, include/, lib/pkgconfig/, the
#                     *-config scripts and bin/pkg-config for builds against them)
#   az-curl           bin/curl and libcurl (lib/libcurl.a, include/curl/, curl-config)
#   az-ffmpeg         bin/ffmpeg, bin/ffprobe
#   az-imagemagick6   bin/convert6, identify6, mogrify6, composite6... and its
#                     etc/ImageMagick-6, share/ImageMagick-6, lib/ImageMagick-6.*
#   az-imagemagick7   bin/magick and the names linked to it, its etc/, share/,
#                     lib/ImageMagick-7.*, and its static libraries, headers and
#                     bin/MagickWand-config, for imagick of PHP
# Each one has its list of versions and options in share/doc/<name>/VERSIONS and
# its licences in LICENSES/. The programs are static: none of the packages
# depends on another at run time.
#
# Usage (FreeBSD, as root, from the top of a php-src checkout of master):
#   sh tools/build-az.sh --tools   install the build tools of every part (pkg)
#   sh tools/build-az.sh           build, test and package
#
# AZ_PREFIX (default /usr/local/az) must be empty or missing (a tree with PHP
# builds in it is refused); AZ_CPUTYPE and AZ_CFLAGS as for the parts (default:
# CPUTYPE and CFLAGS of /etc/make.conf, else x86-64-v3 and -O3 -pipe); AZ_STAMP:
# the revision of every package (default: the time of the build, UTC,
# YYMMDDHH), so that a new build is an upgrade for pkg. Results: az-results/
# (summary.txt, tests.txt: the checks of the packages and of their repository),
# deps-results/, ffmpeg-results/, imagemagick-results/, curl-results/. The
# repository: dist/az-fbsd<major>-amd64-<level>/ (the packages, meta.conf,
# packagesite.pkg, data.pkg: pkg repo), served as it is from one directory, such
# as the files of a GitHub release.
#
# Exit status: 0 everything built, every test passed and the packages are made;
# 1 something failed (the results say what); 2 usage.

set -u
top="$(pwd)"
A="${AZ_PREFIX:-/usr/local/az}"
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

rm -rf "$res" "$repo"
mkdir -p "$res" "$repo"
: > "$res/summary.txt"
: > "$res/tests.txt"
rm -rf "$A"
# the files of the tree (no directories), sorted, relative to it
snap() { (cd "$A" 2>/dev/null && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort) > "$res/files.$1"; }
part() { printf '%-16s %s\n' "$1" "$2" >> "$res/summary.txt"; }

rc=0
say "libraries and the curl program (tools/build-deps.sh)"
if sh "$top/tools/build-deps.sh"; then part libraries OK; else part libraries FAIL; rc=1; fi
snap deps
if [ "$rc" = 0 ]; then
    say "FFmpeg (tools/build-ffmpeg.sh)"
    if sh "$top/tools/build-ffmpeg.sh"; then part ffmpeg OK; else part ffmpeg FAIL; rc=1; fi
    snap ffmpeg
    say "ImageMagick 6 and 7 (tools/build-imagemagick.sh)"
    if sh "$top/tools/build-imagemagick.sh"; then part imagemagick OK; else part imagemagick FAIL; rc=1; fi
    snap imagemagick
fi
if [ "$rc" != 0 ]; then
    echo "not packaged: a part failed (its results say why)" >> "$res/summary.txt"
    exit 1
fi

# --- the tests --------------------------------------------------------------------
say "tests"
for t in ffmpeg imagemagick curl; do
    if sh "$top/tools/$t-test.sh" > "$res/$t-test.log" 2>&1; then part "$t tests" "OK ($(tail -n 1 "$res/$t-test.log"))"
    else part "$t tests" "FAIL ($(tail -n 1 "$res/$t-test.log"))"; rc=1; fi
done
{ cat "$top/deps-results/summary.txt" | grep '^curl program'; cat "$top/deps-results/curl-bins.txt" 2>/dev/null; } > "$top/curl-results/summary.txt"
[ "$rc" = 0 ] && echo "installed: $A/bin/curl" >> "$top/curl-results/summary.txt"

# --- the packages -----------------------------------------------------------------
# Who owns what: the files of the libraries' build (but curl's), the new ones of
# FFmpeg's, and of ImageMagick's, split by version.
LC_ALL=C comm -13 "$res/files.deps" "$res/files.ffmpeg" > "$res/new.ffmpeg"
LC_ALL=C comm -13 "$res/files.ffmpeg" "$res/files.imagemagick" > "$res/new.imagemagick"
grep -E '^(bin/curl|bin/curl-config|bin/curl-config\.orig|lib/libcurl\.a|lib/pkgconfig/libcurl\.pc|include/curl/.*|LICENSES/curl-.*)$' \
    "$res/files.deps" > "$res/plist.az-curl"
grep -v -x -F -f "$res/plist.az-curl" "$res/files.deps" > "$res/plist.az-libs"
cp "$res/new.ffmpeg" "$res/plist.az-ffmpeg"
grep -E '^(bin/[^/]*6|etc/ImageMagick-6/.*|share/ImageMagick-6/.*|lib/ImageMagick-6\..*|LICENSES/ImageMagick6-.*)$' \
    "$res/new.imagemagick" > "$res/plist.az-imagemagick6"
grep -v -x -F -f "$res/plist.az-imagemagick6" "$res/new.imagemagick" > "$res/plist.az-imagemagick7"

# versions: of the port (without its revision and epoch), of the build of the libraries
pv() { awk -v n="$2" '$1 == n { v = $2; sub(/^.*-/, "", v); sub(/[_,].*$/, "", v); print v }' "$1"; }
ports_commit="$(awk '$1 == "ports" { print $2 }' "$top/freebsd/deps.conf")"
v_libs="$(date -u +%Y%m%d)"
v_curl="$(pv "$top/deps-results/built.txt" curl)"
v_ffmpeg="$(pv "$top/ffmpeg-results/built.txt" ffmpeg)"
v_im6="$(pv "$top/imagemagick-results/built.txt" imagemagick6)"
v_im7="$(pv "$top/imagemagick-results/built.txt" imagemagick7)"

# share/doc/<name>/VERSIONS of each package
docs() {
    mkdir -p "$A/share/doc/$1"
    cp "$2" "$A/share/doc/$1/VERSIONS"
    echo "share/doc/$1/VERSIONS" >> "$res/plist.$1"
}
{
    echo "curl $v_curl for FreeBSD $major (amd64, $cputype): bin/curl and libcurl (lib/libcurl.a, include/curl/, bin/curl-config)"
    echo "of the bundled curl (freebsd/curl.conf, freebsd/curl-deps.conf, freebsd/curl/build-libcurl.sh), with the libraries"
    echo "of az-libs; the build of the libraries:"
    echo
    cat "$top/deps-results/VERSIONS"
    echo
    cat "$top/deps-results/curl-version.txt"
} > "$res/VERSIONS.az-curl"
docs az-curl "$res/VERSIONS.az-curl"
docs az-ffmpeg "$top/ffmpeg-results/VERSIONS"
docs az-imagemagick6 "$top/imagemagick-results/imagemagick6.VERSIONS"
docs az-imagemagick7 "$top/imagemagick-results/imagemagick7.VERSIONS"

# manifest <name> <version> <comment> <licence> <category> <description>: the
# +MANIFEST of a package (in az-results/meta.<name>/, for pkg create -m)
manifest() {
    mkdir -p "$res/meta.$1"
    python3 - "$@" "$stamp" "$cputype" "$ports_commit" "$A" > "$res/meta.$1/+MANIFEST" <<'EOF'
import json, sys
name, version, comment, lic, cat, desc, stamp, cputype, commit, prefix = sys.argv[1:11]
print(json.dumps({
    "name": name, "origin": "az/" + name[3:], "version": "%s_%s" % (version, stamp),
    "comment": comment, "desc": desc, "maintainer": "github@azsupport.com",
    "www": "https://github.com/azsupport/php-src", "prefix": prefix,
    "licenselogic": "single", "licenses": [lic], "categories": ["az", cat],
    "annotations": {"cputype": cputype, "freebsd_ports": commit,
                    "built_by": "tools/build-az.sh of https://github.com/azsupport/php-src"},
}, indent=1))
EOF
}
manifest az-libs "$v_libs" "Static libraries of /usr/local/az, for builds of PHP and the programs" \
    "MULTI" devel "The static, position independent libraries of /usr/local/az (freebsd/deps.conf): PHP built against them (az-menu.sh, config-check.sh) and the programs of /usr/local/az need no library of /usr/local/lib. Versions: share/doc/az-libs/VERSIONS."
manifest az-curl "$v_curl" "curl and libcurl, static (the bundled curl of the fork)" \
    "MIT" ftp "curl $v_curl with c-ares, HTTP/2, brotli, zstd, IDN and the Public Suffix List, the OpenSSL of az-libs: bin/curl and the static libcurl for builds of PHP against /usr/local/az. Versions: share/doc/az-curl/VERSIONS."
manifest az-ffmpeg "$v_ffmpeg" "FFmpeg for the video sites, static (ffmpeg, ffprobe)" \
    "GPLv2+" multimedia "FFmpeg $v_ffmpeg with only what the video sites need (freebsd/ffmpeg.conf): bin/ffmpeg and bin/ffprobe of /usr/local/az. Versions and options: share/doc/az-ffmpeg/VERSIONS."
manifest az-imagemagick6 "$v_im6" "ImageMagick 6 for the video sites, static (convert6, identify6, ...)" \
    "ImageMagick" graphics "ImageMagick $v_im6 with JPEG, PNG, WebP, GIF, HEIC and AVIF only, and the policy of freebsd/imagemagick/policy.xml: bin/convert6, identify6, mogrify6, composite6 and the others of /usr/local/az. Versions and options: share/doc/az-imagemagick6/VERSIONS."
manifest az-imagemagick7 "$v_im7" "ImageMagick 7 for the video sites, static (magick), and its libraries for imagick" \
    "ImageMagick" graphics "ImageMagick $v_im7 with JPEG, PNG, WebP, GIF, HEIC and AVIF only, and the policy of freebsd/imagemagick/policy.xml: bin/magick and the names linked to it (convert, identify, ...) of /usr/local/az, and its static libraries for imagick of PHP (--with-imagick=/usr/local/az). Versions and options: share/doc/az-imagemagick7/VERSIONS."

say "packages"
: > "$res/packages.txt"
pok=0; pbad=0
tpass() { echo "ok    $*" >> "$res/tests.txt"; pok=$((pok + 1)); }
tfail() { echo "FAIL  $*" >> "$res/tests.txt"; pbad=$((pbad + 1)); }
for n in az-libs az-curl az-ffmpeg az-imagemagick6 az-imagemagick7; do
    if [ ! -s "$res/plist.$n" ]; then tfail "$n: no files"; continue; fi
    missing="$(while read -r f; do [ -e "$A/$f" ] || [ -L "$A/$f" ] || echo "$f"; done < "$res/plist.$n" | head -n 3 | tr '\n' ' ')"
    [ -z "$missing" ] || { tfail "$n: files gone since the build: $missing"; continue; }
    if pkg create -m "$res/meta.$n" -p "$res/plist.$n" -r / -o "$repo" > "$res/create.$n.log" 2>&1; then
        f="$(ls "$repo"/"$n"-[0-9]*.pkg 2>/dev/null | head -n 1)"
        nf="$(pkg info -F "$f" -l 2>/dev/null | grep -c "^	$A/")"
        echo "${f##*/} $(du -Ak "$f" | cut -f1) KB, $nf files" >> "$res/packages.txt"
        if [ "$nf" = "$(wc -l < "$res/plist.$n" | tr -d ' ')" ]; then tpass "$n: ${f##*/}, $nf files"
        else tfail "$n: ${f##*/} has $nf files, the list $(wc -l < "$res/plist.$n" | tr -d ' ')"; fi
    else
        tfail "$n: pkg create: $(tail -n 2 "$res/create.$n.log" | tr '\n' ' ')"
    fi
done
# every file of the tree in exactly one package
cat "$res"/plist.az-* | LC_ALL=C sort > "$res/owned"
dups="$(uniq -d "$res/owned" | head -n 3 | tr '\n' ' ')"
(cd "$A" && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort) > "$res/files.all"
left="$(LC_ALL=C comm -23 "$res/files.all" "$res/owned" | head -n 5 | tr '\n' ' ')"
if [ -z "$dups$left" ]; then tpass "every file of $A in exactly one package ($(wc -l < "$res/owned" | tr -d ' ') files)"
else tfail "files in two packages: ${dups:-none}; in none: ${left:-none}"; fi
# the repository, and an install from it into an empty root
if pkg repo "$repo" > "$res/repo.log" 2>&1; then
    tpass "pkg repo: $(cd "$repo" && ls | grep -v -E '^az-.*-[0-9].*\.pkg$' | tr '\n' ' ')"
    rd="$top/az-results/repos"; root="/var/tmp/az-pkg-root"
    rm -rf "$rd" "$root"; mkdir -p "$rd" "$root"
    printf 'aztest: { url: "file://%s", signature_type: "none", enabled: yes }\n' "$repo" > "$rd/aztest.conf"
    abi="$(pkg config ABI)"
    tp() { pkg -o REPOS_DIR="$rd" -o PKG_DBDIR="$root/var/db/pkg" -o PKG_CACHEDIR="$root/var/cache/pkg" \
        -o ABI="$abi" -o IGNORE_OSVERSION=yes -r "$root" "$@"; }
    if tp update -f > "$res/install-test.log" 2>&1 &&
        tp install -y -r aztest az-libs az-curl az-ffmpeg az-imagemagick6 az-imagemagick7 \
            >> "$res/install-test.log" 2>&1; then
        (cd "$root$A" && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort) > "$res/files.installed"
        if cmp -s "$res/files.installed" "$res/owned"; then tpass "pkg install from the repository into an empty root: the same $(wc -l < "$res/owned" | tr -d ' ') files"
        else tfail "pkg install into an empty root: other files ($(LC_ALL=C comm -3 "$res/files.installed" "$res/owned" | head -n 3 | tr '\n' ' '))"; fi
        if "$root$A/bin/ffmpeg" -hide_banner -version > /dev/null 2>&1 && "$root$A/bin/curl" --version > /dev/null 2>&1; then
            tpass "the installed ffmpeg and curl run"
        else tfail "the installed ffmpeg or curl does not run"; fi
    else
        tfail "pkg install from the repository: $(tail -n 3 "$res/install-test.log" | tr '\n' ' ')"
    fi
else
    tfail "pkg repo: $(tail -n 2 "$res/repo.log" | tr '\n' ' ')"
fi
echo "tests: $pok ok, $pbad failed" >> "$res/tests.txt"
{
    echo
    cat "$res/packages.txt"
} >> "$res/summary.txt"
if [ "$pbad" = 0 ] && [ "$rc" = 0 ]; then
    echo "repo: ${repo#"$top"/} ($(du -sk "$repo" | cut -f1) KB): $(ls "$repo" | wc -l | tr -d ' ') files" >> "$res/summary.txt"
else
    rc=1
fi
exit "$rc"
