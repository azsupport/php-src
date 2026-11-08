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

# a JSON string (as az-menu.sh writes them)
TAB="$(printf '\t')"
js() { printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$TAB/\\\\t/g")"; }

# build_module: the package of one line of freebsd/ext.conf (in mod msrc pname origin
# prio needs lic ini_mode opts) for the target $t of build_core, built, packaged into
# dist/az-php/ and installed; its logs in build-pkg-results/<target>/modules/<package>/,
# what went wrong in error.txt there. $work/<target>/built lists the packages built
# so far: module, package, priority, file.
build_module() {
    pn="$(echo "$pname" | sed "s/@V@/$short/g")"
    og="$(echo "$origin" | sed "s/@V@/$short/g")"
    op="$(echo "$opts" | sed -e "s|@AZ@|$AZ|g" -e "s/@V@/$short/g")"
    [ "$op" = - ] && op=""
    mo="$res/$t/modules/$pn"
    rm -rf "$mo"; mkdir -p "$mo" || return 1
    case "$msrc" in
        php) ver="$phpver" ;;
        pecl)
            ver="$(awk -v t="$t" -v m="$mod" '$1 == t && $2 == m { print $3; exit }' "$peclconf")"
            [ -n "$ver" ] || { echo "no version of $mod for $t in freebsd/pecl.conf" > "$mo/error.txt"; return 1; }
            ;;
        *) echo "source $msrc in freebsd/ext.conf: neither php nor pecl" > "$mo/error.txt"; return 1 ;;
    esac
    [ -d "$esrc/ext/$mod" ] || { echo "no ext/$mod in ${esrc##*/}" > "$mo/error.txt"; return 1; }
    # the packages it depends on: the core, and those of the modules it needs, built
    # (so installed) before it with a lower priority, or the same one and a name that
    # sorts first, so that PHP loads them first
    deps="php$short"
    if [ "$needs" != - ]; then
        for n in $(echo "$needs" | tr ',' ' '); do
            case "$n" in
                pkg:*) d="${n#pkg:}" ;;
                *)
                    d="$(awk -v m="$n" '$1 == m { print $2; exit }' "$work/$t/built")"
                    np="$(awk -v m="$n" '$1 == m { print $3; exit }' "$work/$t/built")"
                    [ -n "$d" ] || { echo "needs the module $n, which was not built before it" > "$mo/error.txt"; return 1; }
                    if [ "$np" -gt "$prio" ] || { [ "$np" = "$prio" ] && ! expr "x$n" \< "x$mod" > /dev/null; }; then
                        echo "needs $n (ext-$np-$n.ini), which PHP would load after ext-$prio-$mod.ini" > "$mo/error.txt"; return 1
                    fi
                    ;;
            esac
            pkg info -e "$d" || { echo "needs the package $d, which is not installed" > "$mo/error.txt"; return 1; }
            deps="$deps $d"
        done
    fi
    # a copy of ext/<module> next to the others (relative includes such as
    # ../dom/xml_common.h resolve), the original stays as it is for the next build
    bd="$esrc/ext/$pn"
    rm -rf "$bd"; cp -R "$esrc/ext/$mod" "$bd" || return 1
    # phpize reads config.m4: the extensions whose file is config0.m4 or config9.m4
    # (so that php-src runs them first or last) get it under that name, as the ports do
    if [ ! -f "$bd/config.m4" ]; then
        for c in "$bd"/config[0-9].m4; do
            [ -f "$c" ] && { mv "$c" "$bd/config.m4"; echo "${c##*/} as config.m4" >> "$mo/phpize.log"; break; }
        done
    fi
    (cd "$bd" && "/usr/local/bin/phpize$short") >> "$mo/phpize.log" 2>&1 ||
        { tail -n 20 "$mo/phpize.log" > "$mo/error.txt"; return 1; }
    printf '%s\n' "--with-php-config=/usr/local/bin/php-config$short" $op > "$mo/configure-options.txt"
    # shellcheck disable=SC2086
    (cd "$bd" && env CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" LDFLAGS="$LDFLAGS" LIBS="$LIBS" PKG_CONFIG="$PKG_CONFIG" \
        ./configure "--with-php-config=/usr/local/bin/php-config$short" $op) > "$mo/configure.log" 2>&1 ||
        { tail -n 30 "$mo/configure.log" > "$mo/error.txt"; return 1; }
    grep -i 'unrecognized option' "$mo/configure.log" > "$mo/configure-unrecognized.txt"
    (cd "$bd" && make -j"$ncpu") > "$mo/make.log" 2>&1 ||
        { { grep ' error:' "$mo/make.log" | head -n 20; tail -n 20 "$mo/make.log"; } > "$mo/error.txt"; return 1; }
    mst="$work/$t/stage-$pn"
    rm -rf "$mst"
    (cd "$bd" && make install INSTALL_ROOT="$mst") > "$mo/install.log" 2>&1 ||
        { tail -n 20 "$mo/install.log" > "$mo/error.txt"; return 1; }
    so="$mst/usr/local/lib/php/$api/$mod.so"
    [ -f "$so" ] || { echo "make install put no lib/php/$api/$mod.so into the stage" > "$mo/error.txt"; return 1; }
    # the headers of the module and its config.h (the COMPILE_, HAVE_ and USE_ macros),
    # as the ports install them; the plist adds the config.h to ext/php_config.h
    inc="/usr/local/include/php$short/php/ext/$mod"
    mkdir -p "$mst$inc" || return 1
    for h in "$bd"/*.h; do [ -f "$h" ] && cp "$h" "$mst$inc/"; done
    grep -E '^#define (COMPILE|HAVE|USE)_' "$bd/config.h" > "$mst$inc/config.h"
    # the ini; off:<module>: its line commented out, and the message of the package says why
    ini="/usr/local/etc/php$short/conf.d/ext-$prio-$mod.ini"
    mkdir -p "$mst${ini%/*}" || return 1
    msg=""
    case "$ini_mode" in
        on) echo "extension=$mod.so" > "$mst$ini.sample" ;;
        off:*)
            other="${ini_mode#off:}"
            msg="PHP stops when $mod.so and $other.so are loaded together (they define the same classes), so $ini comes with its line commented out. To load $mod: comment out the line of $other in its ext-*-$other.ini in ${ini%/*}, remove the ';' before extension=$mod.so in $ini, then restart php-fpm$short or Apache."
            { echo "; $msg"; echo ";extension=$mod.so"; } > "$mst$ini.sample"
            ;;
        *) echo "ini $ini_mode in freebsd/ext.conf: neither on nor off:<module>" > "$mo/error.txt"; return 1 ;;
    esac
    # azsupport when the module links one of its libraries
    readelf -d "$so" > "$mo/readelf.txt" 2>&1
    for l in $(sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p' "$mo/readelf.txt"); do
        if [ -f "$AZ/lib/$l" ]; then deps="$deps azsupport"; break; fi
    done
    # the plist: the files, the ini as @sample (pkg copies it to .ini and keeps a
    # changed one), the include of its config.h in ext/php_config.h (the ports' lines)
    pl="$work/$t/plist-$pn"
    h="%D/include/php$short/php/ext/php_config.h"
    {
        (cd "$mst" && find . ! -type d | sed 's#^\.##' | LC_ALL=C sort) |
            awk -v s="$ini.sample" '$0 == s { print "@sample " $0; next } { print }'
        printf '%s\n' "@postexec echo \\#include \\\"ext/$mod/config.h\\\" >> $h" "@preunexec cp $h $h.orig" \
            "@preunexec grep -v ext/$mod/config.h $h.orig > $h || true" "@preunexec rm $h.orig"
    } > "$pl"
    m="$work/$t/meta-$pn"
    rm -rf "$m"; mkdir -p "$m" || return 1
    case "$msrc" in
        php) what="the extension $mod of PHP $t" ;;
        *) what="the PECL extension $mod $ver (bundled into ext/$mod of the fork, freebsd/pecl.conf)" ;;
    esac
    cfg="$(tr '\n' ' ' < "$mo/configure-options.txt" | sed 's/ *$//')"
    {
        printf '{\n "name": %s,\n "origin": %s,\n "version": %s,\n' "$(js "$pn")" "$(js "$og")" "$(js "${ver}_$AZ_STAMP")"
        printf ' "comment": %s,\n' "$(js "The $mod module of PHP $t of azsupport/php-src (pkg mode)")"
        printf ' "desc": %s,\n' "$(js "The module $mod.so of PHP $t of https://github.com/azsupport/php-src for php$short of pkg mode, built by tools/build-pkg.sh: $what, built against the installed core (phpize$short) into /usr/local/lib/php/$api, loaded by $ini, its headers in $inc. Linked with the shared libraries of $AZ/lib or those of the base system. configure: $cfg")"
        printf ' "maintainer": "github@azsupport.com",\n "www": "https://github.com/azsupport/php-src",\n "prefix": "/usr/local",\n'
        printf ' "licenselogic": "single",\n "licenses": [%s],\n "categories": [%s, "az"],\n "deps": {' "$(js "$lic")" "$(js "${og%%/*}")"
        sep=""
        for d in $deps; do
            printf '%s\n  %s: {"origin": %s, "version": %s}' "$sep" "$(js "$d")" "$(js "$(pkg query %o "$d")")" "$(js "$(pkg query %v "$d")")"
            sep=","
        done
        printf '\n },\n'
        [ -n "$msg" ] && printf ' "messages": [{"message": %s}],\n' "$(js "$msg")"
        printf ' "annotations": {"configure": %s, "cflags": %s, "mode": "pkg", "built_by": %s}\n}\n' "$(js "$cfg")" "$(js "$CFLAGS")" \
            "$(js "tools/build-pkg.sh of https://github.com/azsupport/php-src")"
    } > "$m/+MANIFEST" || return 1
    rm -f "$pkgdir/$pn"-[0-9]*.pkg
    pkg create -m "$m" -p "$pl" -r "$mst" -o "$pkgdir" > "$mo/create.log" 2>&1 ||
        { tail -n 10 "$mo/create.log" > "$mo/error.txt"; return 1; }
    pf="$(ls "$pkgdir/$pn"-[0-9]*.pkg 2>/dev/null | head -n 1)"
    [ -f "$pf" ] || { echo "pkg create made no $pn-*.pkg" > "$mo/error.txt"; return 1; }
    # installed for the modules after it; not a second kind of a module that is
    # installed already (openssl-legacy after openssl: the same files): the checks swap them
    if awk -v m="$mod" '$1 == m { f = 1 } END { exit !f }' "$work/$t/built"; then
        echo "not installed now: the module $mod of another package is" >> "$mo/pkg-add.log"
    else
        af=""
        pkg info -e "$pn" && af=-f
        # shellcheck disable=SC2086
        if ! pkg add $af "$pf" >> "$mo/pkg-add.log" 2>&1 || ! pkg info -e "$pn"; then
            { echo "pkg add of ${pf##*/} failed:"; tail -n 10 "$mo/pkg-add.log"; } > "$mo/error.txt"; return 1
        fi
    fi
    echo "$mod $pn $prio $pf" >> "$work/$t/built"
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
    # the modules of the target, in the order of freebsd/ext.conf (no pathname
    # expansion of the version patterns such as 8.*)
    t="$target"
    : > "$work/$t/built"
    grep -v '^#' "$conf" | awk 'NF' > "$work/$t/lines"
    nb=0; failed=""
    while read -r vers mod msrc pname origin prio needs lic ini_mode opts; do
        match=0
        set -f
        for p in $(echo "$vers" | tr ',' ' '); do
            # shellcheck disable=SC2254
            case "$t" in $p) match=1 ;; esac
        done
        set +f
        [ "$match" = 1 ] || continue
        if [ -z "$opts" ]; then
            say "$t: a line of freebsd/ext.conf with too few fields, skipped: $vers $mod $msrc $pname"
            failed="$failed $mod"; continue
        fi
        if build_module < /dev/null; then
            nb=$((nb + 1))
            say "$t: $pn built ($(( $(wc -c < "$pf") / 1024 )) KB)"
        else
            failed="$failed $pn"
            echo "failed:   $pn: $(grep . "$mo/error.txt" 2>/dev/null | tail -n 1)" >> "$sum"
            say "$t: $pn FAILED: $(grep . "$mo/error.txt" 2>/dev/null | tail -n 1)"
        fi
    done < "$work/$t/lines"
    echo "modules:  $nb built${failed:+, failed:$failed}" >> "$sum"
    if [ -n "$failed" ]; then
        echo "result:   FAIL (modules:$failed)" >> "$sum"
        say "$t: FAIL (modules:$failed)"
        rc=1; continue
    fi
    echo "result:   OK" >> "$sum"
    say "$target: OK"
done
exit "$rc"
