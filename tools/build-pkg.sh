#!/bin/sh
# build-pkg.sh - build PHP in pkg mode on FreeBSD: the core phpXY and every
# module of freebsd/ext.conf as a package of its own, as the FreeBSD ports do,
# and check them installed together. The workflow .github/workflows/az-php.yml
# runs it in a FreeBSD VM as root; it works the same on a FreeBSD server.
#
# Usage (from the top of a php-src checkout of master, as root):
#   sh tools/build-test.sh --deps 7.4      the packages of the build (apache24, memcached, redis, ...)
#   sh tools/build-test.sh --az <dir>      azsupport and ImageMagick7 of the repository of pkg in <dir>
#   sh tools/build-pkg.sh 7.4 ...          build dist/php-<target>-fbsd-latest.tar.xz in pkg mode
#
# phpize needs autoconf and GNU m4: without them build-pkg.sh installs the
# package autoconf (pkg install -y autoconf, which brings m4) and says so.
#
# The core: the release tarball unpacked into build-pkg/<target>/core, configured
# with the layout of the static packages (/usr/local, bin/php74, sbin/php-fpm74,
# etc/php74, lib/php74, include/php74), --disable-all, CLI, FPM, the Apache module,
# OPcache built in (--enable-opcache-static), libxml and argon2 of azsupport, and
# with extension loading (no --disable-extension-loading); EXTENSION_DIR
# /usr/local/lib/php/<API> (that of the ports: 20190902 for 7.4), so that php-config74
# --extension-dir and every module take it. main/php_config.h includes
# ext/php_config.h, as the port lang/phpXY does it: each module package adds the
# config.h of its module there, so that the modules built later see its HAVE_
# macros (HAVE_SOCKETS for swoole, HAVE_DOM for xmlreader). make install into a
# stage, the package php74 of it by tools/az-menu.sh --package ... core, pkg add.
#
# The modules: each line of freebsd/ext.conf for the target, in its order, built in
# a copy of ext/<module> next to the others in a second unpacked tree (so that a
# module does not see the build of the core, and relative includes such as
# ../dom/xml_common.h of xsl still resolve): phpize74, ./configure
# --with-php-config=/usr/local/bin/php-config74 <options>, make, make install into a
# stage, the headers and the config.h of the module (include/php74/php/ext/<module>),
# the ini etc/php74/conf.d/ext-<prio>-<module>.ini.sample (@sample: pkg copies it to
# .ini and keeps a changed one), +MANIFEST written by the shell, pkg create into
# dist/az-php/, pkg add (the next modules need its headers).
#
# The compiler flags are those of build-test.sh (-O3 -pipe -march=$AZ_CPUTYPE
# -fstack-protector-strong -fno-strict-aliasing, LIBS=-lpthread), the libraries the
# shared ones of /usr/local/azsupport/lib (its pkg-config, run path
# /usr/local/azsupport/lib) or those of the base system.
#
# Results go to build-pkg-results/<target>/: summary.txt (its last line "result:
# OK" or "result:   FAIL (...)", as build-test.sh writes it), the logs of the core
# and one directory per package (modules/<package>/), tests.txt (the checks).
# The packages go to dist/az-php/ (the core and the modules), AZ_STAMP the revision
# of their versions (default: the hour of the build).
#
# Exit status: 0 everything built and passed, 1 otherwise.

set -u

top="$(pwd)"
res="$top/build-pkg-results"
work="$top/build-pkg"
dist="$top/dist"
pkgdir="$dist/az-php"
AZ=/usr/local/azsupport
conf="$top/freebsd/ext.conf"
peclconf="$top/freebsd/pecl.conf"

say() { printf '[build-pkg %s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

[ $# -gt 0 ] || { sed -n 's/^# \{0,1\}//; 7,10p' "$0" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "build-pkg: as root (pkg add of the packages it builds)" >&2; exit 2; }
[ -f "$conf" ] || { echo "build-pkg: no $conf (run it from the top of a checkout of master)" >&2; exit 2; }
if [ ! -x "$AZ/bin/pkg-config" ] || ! pkg info -e azsupport; then
    echo "build-pkg: no azsupport with $AZ/bin/pkg-config: sh tools/build-test.sh --az <dir> first" >&2
    exit 2
fi
if ! command -v autoconf > /dev/null 2>&1 || ! command -v autoheader > /dev/null 2>&1; then
    say "phpize needs autoconf and GNU m4, not installed: pkg install -y autoconf"
    env ASSUME_ALWAYS_YES=yes pkg install -y autoconf ||
        { echo "build-pkg: cannot install autoconf" >&2; exit 2; }
fi

# -march as build-test.sh: x86-64-v3 if this CPU runs it, else v2; AZ_CPUTYPE wins
cpu_feats() {
    cc "-march=$1" -dM -E - < /dev/null 2>/dev/null |
        sed -n -E 's/^#define __(SSE4_2|POPCNT|AVX|AVX2|BMI|BMI2|FMA|F16C|LZCNT|MOVBE)__ 1$/\1/p' | LC_ALL=C sort -u
}
mkdir -p "$work" "$res" "$pkgdir" || exit 2
cpu_feats x86-64-v3 > "$work/cpu-need"
cpu_feats native > "$work/cpu-have"
march=x86-64-v3
[ -n "$(LC_ALL=C comm -23 "$work/cpu-need" "$work/cpu-have")" ] && march=x86-64-v2
[ -n "${AZ_CPUTYPE:-}" ] && march="$AZ_CPUTYPE"
CFLAGS="-O3 -pipe -march=$march -fstack-protector-strong -fno-strict-aliasing"
CXXFLAGS="$CFLAGS"
LDFLAGS="-L$AZ/lib -Wl,-rpath,$AZ/lib"
LIBS="-lpthread"
PKG_CONFIG="$AZ/bin/pkg-config"
ncpu="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
# one revision for the core and the modules of this run (az-menu.sh takes it too)
AZ_STAMP="${AZ_STAMP:-$(date -u +%y%m%d%H)}"
export AZ_STAMP

# core_options <target> <short>: the configure options of the core, one per line
core_options() {
    case "$1" in
        7.4)
            printf '%s\n' --prefix=/usr/local "--program-suffix=$2" "--sysconfdir=/usr/local/etc/php$2" \
                "--libdir=/usr/local/lib/php$2" "--includedir=/usr/local/include/php$2" \
                "--datadir=/usr/local/share/php$2" --mandir=/usr/local/share/man --with-layout=GNU \
                --localstatedir=/var "--with-config-file-path=/usr/local/etc/php$2" \
                "--with-config-file-scan-dir=/usr/local/etc/php$2/conf.d" --disable-all --enable-cli \
                --enable-fpm --with-fpm-user=www --with-fpm-group=www --with-apxs2=/usr/local/sbin/apxs \
                --enable-opcache --enable-opcache-static --with-libxml --enable-json \
                "--with-password-argon2=$AZ"
            ;;
        *) return 1 ;;
    esac
}

# build_core <target>: the core of the target from its tarball, packaged and installed;
# sets src (the core tree), esrc (the tree of the modules), short, api, phpver
build_core() {
    t="$1"; o="$res/$t"
    short="$(echo "$t" | tr -d .)"
    tarball="$dist/php-$t-fbsd-latest.tar.xz"
    [ -f "$tarball" ] || { echo "no tarball $tarball" > "$o/core.log"; return 1; }
    echo "tarball:  ${tarball##*/} ($(sha256 -q "$tarball" | cut -c1-16)...)" >> "$o/summary.txt"
    mkdir -p "$work/$t/core" "$work/$t/ext"
    tar -xf "$tarball" -C "$work/$t/core" && tar -xf "$tarball" -C "$work/$t/ext" ||
        { echo "cannot unpack $tarball" > "$o/core.log"; return 1; }
    src="$(ls -d "$work/$t/core"/php-* | head -n 1)"
    esrc="$(ls -d "$work/$t/ext"/php-* | head -n 1)"
    echo "source:   ${src##*/}" >> "$o/summary.txt"
    api="$(sed -n 's/^#define[[:space:]]*ZEND_MODULE_API_NO[[:space:]]*\([0-9]*\).*/\1/p' "$src/Zend/zend_modules.h")"
    phpver="$(sed -n 's/^#define PHP_VERSION "\([^"]*\)".*/\1/p' "$src/main/php_version.h")"
    [ -n "$api" ] && [ -n "$phpver" ] || { echo "no PHP version or module API in $src" > "$o/core.log"; return 1; }
    core_options "$t" "$short" > "$o/configure-options.txt" ||
        { echo "no options of the core for $t in build-pkg.sh" > "$o/core.log"; return 1; }
    extdir="/usr/local/lib/php/$api"
    # the configure script, as az_package of build-test.sh writes it (az-menu.sh
    # --package takes the prefix and the options from it)
    {
        echo "#!/bin/sh"
        printf "CFLAGS='%s' \\\\\n" "$CFLAGS"
        printf "CXXFLAGS='%s' \\\\\n" "$CXXFLAGS"
        printf "LDFLAGS='%s' \\\\\n" "$LDFLAGS"
        printf "LIBS='%s' \\\\\n" "$LIBS"
        printf "PKG_CONFIG='%s' \\\\\n" "$PKG_CONFIG"
        printf "EXTENSION_DIR='%s' \\\\\n" "$extdir"
        echo "'./configure' \\"
        sed "s/'/'\\\\''/g; s/^/'/; s/\$/' \\\\/" "$o/configure-options.txt"
        echo '"$@"'
    } > "$o/config.sh"
    say "$t: configure the core"
    # shellcheck disable=SC2046
    if ! (cd "$src" && env CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" LDFLAGS="$LDFLAGS" LIBS="$LIBS" \
            PKG_CONFIG="$PKG_CONFIG" EXTENSION_DIR="$extdir" ./configure $(cat "$o/configure-options.txt")) \
            > "$o/configure.log" 2>&1; then
        tail -n 40 "$o/configure.log" > "$o/core.log"; return 1
    fi
    say "$t: make -j$ncpu the core"
    start=$(date +%s)
    if ! (cd "$src" && make -j"$ncpu") > "$o/make.log" 2>&1; then
        { grep ' error:' "$o/make.log" | head -n 20; tail -n 20 "$o/make.log"; } > "$o/core.log"; return 1
    fi
    echo "core:     make $(( $(date +%s) - start ))s, $(grep -c 'warning:' "$o/make.log") warnings" >> "$o/summary.txt"
    # the include of the config.h files of the module packages (lang/phpXY of the ports)
    grep -q '^#include "ext/php_config.h"' "$src/main/php_config.h" ||
        echo '#include "ext/php_config.h"' >> "$src/main/php_config.h"
    st="$work/$t/stage-core"
    rm -rf "$st"
    (cd "$src" && make install INSTALL_ROOT="$st") > "$o/install.log" 2>&1 ||
        { tail -n 20 "$o/install.log" > "$o/core.log"; return 1; }
    mkdir -p "$st/usr/local/include/php$short/php/ext" && : > "$st/usr/local/include/php$short/php/ext/php_config.h" ||
        return 1
    f="$(AZ_MENU_WORK="$pkgdir" sh "$top/tools/az-menu.sh" --package "$t" "$src" "$st" "$o/config.sh" core 2> "$o/package.log")" ||
        { tail -n 20 "$o/package.log" > "$o/core.log"; return 1; }
    echo "package:  ${f##*/} ($(( $(wc -c < "$f") / 1024 )) KB)" >> "$o/summary.txt"
    af=""
    if pkg info -e "php$short"; then
        say "$t: php$short is installed already: pkg add -f puts this build in its place"
        af=-f
    fi
    # shellcheck disable=SC2086
    if ! pkg add $af "$f" > "$o/pkg-add.log" 2>&1 || ! pkg info -e "php$short"; then
        { echo "pkg add of ${f##*/} failed:"; tail -n 10 "$o/pkg-add.log"; } > "$o/core.log"; return 1
    fi
    echo "core:     $(/usr/local/bin/php"$short" -n -v | head -n 1)" >> "$o/summary.txt"
    return 0
}

rc=0
for target in "$@"; do
    out="$res/$target"
    rm -rf "${out:?}" "${work:?}/$target"
    mkdir -p "$out" "$work/$target"
    sum="$out/summary.txt"
    {
        echo "target:   $target"
        echo "host:     $(uname -sr), $(cc --version | head -n 1)"
        echo "cpu:      $(sysctl -n hw.model 2>/dev/null); -march=$march"
        echo "openssl:  $(openssl version 2>/dev/null)"
        echo "azsupport: $(pkg query '%v' azsupport)"
        echo "CFLAGS:   $CFLAGS"
    } > "$sum"
    say "$target: the core php$(echo "$target" | tr -d .)"
    if ! build_core "$target"; then
        echo "result:   FAIL (core: $(grep . "$out/core.log" | tail -n 1))" >> "$sum"
        say "$target: FAIL in the core: $(grep . "$out/core.log" | tail -n 1)"
        rc=1; continue
    fi
    echo "result:   OK" >> "$sum"
    say "$target: OK"
done
exit "$rc"
