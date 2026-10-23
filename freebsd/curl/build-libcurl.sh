#!/bin/sh
# build-libcurl.sh - build ext/curl/libcurl, with the libraries it needs from
# ext/curl/deps, for "configure --with-curl=bundled".
#
# Usage: sh ext/curl/build-libcurl.sh <prefix>
#        sh build-libcurl.sh --lib <name> <source> <prefix>
#        sh build-libcurl.sh --curl <source> <prefix> <libraries>
#
# ext/curl/config.m4 runs the first form with CC, CFLAGS, CPPFLAGS, LDFLAGS,
# PKG_CONFIG, OPENSSL_INCDIR and OPENSSL_CFLAGS of the PHP build and writes the
# output to <prefix>.log: the libraries of ext/curl/deps (tools/curl-sources.sh
# of the fork puts them there; ext/curl/deps/VERSIONS lists them) go into
# <prefix>.deps, curl into <prefix>. The other two forms are for
# tools/build-deps.sh (/usr/local/phpdeps): one library from an unpacked source
# into <prefix>, and curl against the libraries in <libraries>.
#
# Everything is built static and position independent, so that it can go into
# php, php-fpm, php-cgi and libphp.so, and with only cc, make and ar: brotli, zstd
# and libpsl are compiled here (their own builds want cmake, GNU make, or meson and
# Python), c-ares, nghttp2 and libidn2 with their configure (the autotools are
# never run, see notools). The libraries:
#   c-ares    the DNS resolver of curl (instead of getaddrinfo() in threads: a
#             lookup that runs into a timeout is dropped at once, a getaddrinfo()
#             can only be waited for)
#   nghttp2   HTTP/2 (the library only)
#   brotli    Content-Encoding br (and the encoder, for phpdeps)
#   zstd      Content-Encoding zstd (the whole library, as its Makefile builds it)
#   libidn2   IDN host names, with the part of libunistring it carries
#             (--with-included-libunistring), so no libunistring
#   libpsl    the Public Suffix List for cookies, built-in only (no IDN library:
#             curl gives it the names in punycode)
# curl gets the OpenSSL of the PHP build (the base system one unless PHP is given
# another) and the options of the FreeBSD port ftp/curl minus what PHP has no use
# for (README of the fork, "Bundled curl"). libcurl.a then takes the libraries in
# (ld -r) and all its symbols but curl_* are made local, so that a copy of one of
# them in PHP or in another module (swoole carries nghttp2, libzip links zstd)
# stays apart; the PHP link hides curl_* too (--exclude-libs, config.m4).
#
# <prefix> gets lib/libcurl.a, include/curl/, lib/pkgconfig/libcurl.pc and
# bin/curl-config; both print "-lcurl" with the libraries of the system libcurl
# needs, the -L for <prefix>/lib is added by config.m4 to LDFLAGS (no run path into
# the build tree). A rerun with the same sources and flags keeps the build.

set -eu
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/$(basename "$0")"
make="${MAKE:-make}"
cc="${CC:-cc}"
ar="${AR:-ar}"
ld="${LD:-ld}"
pkgconf="${PKG_CONFIG:-pkg-config}"
ncpu="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 2)"
# A git checkout gives every file the time of the checkout, which can make a
# Makefile.in look older than its Makefile.am: make must not run the autotools
# (they are not there) for that.
notools="ACLOCAL=: AUTOCONF=: AUTOMAKE=: AUTOHEADER=: MAKEINFO=:"
# The libraries in link order, as libcurl.a takes them in.
deplibs="psl idn2 nghttp2 cares brotlidec brotlicommon zstd"

say() { printf '== %s\n' "$*"; }

# pkg-config for the builds: only the .pc files of the libraries here, static
# link lines (there are only static libraries). Without a pkg-config, configure
# falls back to -lfoo, which is enough: none of these needs another library.
pc_wrap() {   # <libraries>
    mkdir -p "$obj"
    w="$obj/pkg-config"
    if command -v "$pkgconf" >/dev/null 2>&1; then
        printf '%s\n' '#!/bin/sh' "PKG_CONFIG_LIBDIR='$1/lib/pkgconfig'" 'export PKG_CONFIG_LIBDIR' \
            'unset PKG_CONFIG_PATH' "exec '$(command -v "$pkgconf")' --static \"\$@\"" > "$w"
    else
        printf '%s\n' '#!/bin/sh' 'exit 1' > "$w"
    fi
    chmod +x "$w"
}

# configure <name> <source> <prefix> <options>: out of the source tree, in
# $obj/<name>, with nothing of the system but the compiler, libc and libm
configure_dep() {
    _n="$1" _s="$2" _p="$3"; shift 3
    rm -rf "${obj:?}/$_n"
    mkdir -p "$obj/$_n"
    (cd "$obj/$_n" && env CC="$cc" CFLAGS="$dcflags" CPPFLAGS="-I$_p/include" LDFLAGS="-L$_p/lib" \
        PKG_CONFIG="$obj/pkg-config" "$_s/configure" --prefix="$_p" --libdir="$_p/lib" \
        --includedir="$_p/include" --disable-shared --enable-static --with-pic \
        --disable-dependency-tracking "$@")
}
mk() { _d="$1"; shift; (cd "$obj/$_d" && $make $notools "$@"); }

# cc_all <objects dir> <flags> -- <sources>: compile the sources (in parallel,
# with a makefile that any make reads), objects named after their directory too
cc_all() {
    _o="$1"; shift
    _fl=""
    while [ "$1" != "--" ]; do _fl="$_fl $1"; shift; done
    shift
    mkdir -p "$_o"
    _m="$_o/build.mk"
    : > "$_m.rules"
    _objs=""
    for _s in "$@"; do
        _b="$(basename "$(dirname "$_s")")_$(basename "$_s")"
        _b="${_b%.*}.o"
        _objs="$_objs $_o/$_b"
        printf '%s: %s\n\t%s -c %s -o %s\n' "$_o/$_b" "$_s" "$cc$_fl" "$_s" "$_o/$_b" >> "$_m.rules"
    done
    { printf 'all:%s\n' "$_objs"; cat "$_m.rules"; } > "$_m"
    $make -j"$ncpu" -f "$_m" all
}

pc_file() {   # <prefix> <name> <version> <description> <libs> <requires.private> <libs.private>
    mkdir -p "$1/lib/pkgconfig"
    printf '%s\n' "prefix=$1" 'libdir=${prefix}/lib' 'includedir=${prefix}/include' '' \
        "Name: $2" "Description: $4" "Version: $3" "Libs: -L\${libdir} $5" \
        ${6:+"Requires.private: $6"} ${7:+"Libs.private: $7"} 'Cflags: -I${includedir}' > "$1/lib/pkgconfig/$2.pc"
}

lib_c_ares() {   # <source> <prefix>
    configure_dep c-ares "$1" "$2" --disable-tests
    mk c-ares -j"$ncpu" -C src/lib
    mk c-ares -C src/lib install
    mk c-ares -C include install
    mk c-ares install-pkgconfigDATA
}

lib_nghttp2() {
    configure_dep nghttp2 "$1" "$2" --enable-lib-only
    mk nghttp2 -j"$ncpu" -C lib
    mk nghttp2 -C lib install
}

lib_brotli() {
    o="$obj/brotli"
    rm -rf "$o"
    for part in common dec enc; do
        # shellcheck disable=SC2046
        cc_all "$o/$part" $dcflags "-I$1/c/include" -- $(ls "$1"/c/$part/*.c)
        rm -f "$2/lib/libbrotli$part.a"
        mkdir -p "$2/lib"
        $ar rcs "$2/lib/libbrotli$part.a" "$o/$part"/*.o
    done
    mkdir -p "$2/include/brotli"
    cp "$1"/c/include/brotli/*.h "$2/include/brotli/"
    v="$(awk '$2 ~ /^BROTLI_VERSION_(MAJOR|MINOR|PATCH)$/ { v = v (v == "" ? "" : ".") $3 } END { print v }' "$1/c/common/version.h")"
    pc_file "$2" libbrotlicommon "$v" "Brotli common dictionary library" -lbrotlicommon "" -lm
    pc_file "$2" libbrotlidec "$v" "Brotli decoder library" -lbrotlidec libbrotlicommon ""
    pc_file "$2" libbrotlienc "$v" "Brotli encoder library" -lbrotlienc libbrotlicommon ""
}

lib_zstd() {
    # what lib/Makefile builds for libzstd.a: all parts, single-threaded (its
    # default for the static library), legacy formats from v0.5 on, the assembly
    # Huffman decoder (the .S turns itself off where it does not apply)
    l="$1/lib"
    # shellcheck disable=SC2046
    cc_all "$obj/zstd" $dcflags -Wa,--noexecstack -DXXH_NAMESPACE=ZSTD_ -DDEBUGLEVEL=0 -DZSTD_LEGACY_SUPPORT=5 \
        "-I$l" "-I$l/common" -- \
        $(ls "$l"/common/*.c "$l"/compress/*.c "$l"/decompress/*.c "$l"/decompress/*_amd64.S \
            "$l"/dictBuilder/*.c "$l"/deprecated/*.c "$l"/legacy/zstd_v05.c "$l"/legacy/zstd_v06.c "$l"/legacy/zstd_v07.c)
    mkdir -p "$2/lib" "$2/include"
    rm -f "$2/lib/libzstd.a"
    $ar rcs "$2/lib/libzstd.a" "$obj"/zstd/*.o
    cp "$l/zstd.h" "$l/zdict.h" "$l/zstd_errors.h" "$2/include/"
    v="$(awk '$2 ~ /^ZSTD_VERSION_(MAJOR|MINOR|RELEASE)$/ { v = v (v == "" ? "" : ".") $3 } END { print v }' "$l/zstd.h")"
    pc_file "$2" libzstd "$v" "fast lossless compression algorithm library" -lzstd "" ""
}

lib_libidn2() {
    # LIBICONV_PREFIX: GNU libiconv to use (phpdeps); else the iconv of libc
    if [ -n "${LIBICONV_PREFIX:-}" ]; then io="--with-libiconv-prefix=$LIBICONV_PREFIX"; else io="--without-libiconv-prefix"; fi
    configure_dep libidn2 "$1" "$2" --disable-nls --with-included-libunistring "$io" ac_cv_prog_RONN=true
    mk libidn2 -j"$ncpu" -C gl
    mk libidn2 -j"$ncpu" -C unistring
    mk libidn2 -j"$ncpu" -C lib
    mk libidn2 -C lib install
    mk libidn2 install-pkgconfigDATA
}

lib_libpsl() {
    # src/suffixes_dafsa.h is the built-in list of tools/curl-sources.sh
    s="$1" o="$obj/libpsl"
    rm -rf "$o"
    mkdir -p "$o/include"
    v="$(tr -d ' \n' < "$s/version.txt")"
    IFS=. read -r a b c <<EOF
$v
EOF
    sed -e "s/@LIBPSL_VERSION@/$v/" -e "s/@LIBPSL_VERSION_MAJOR@/$a/" -e "s/@LIBPSL_VERSION_MINOR@/$b/" \
        -e "s/@LIBPSL_VERSION_PATCH@/$c/" -e "s/@LIBPSL_VERSION_NUMBER@/$(printf '0x%02x%02x%02x' "$a" "$b" "$c")/" \
        -e "s/@COPYRIGHT_YEAR@/$(date +%Y)/" "$s/include/libpsl.h.in" > "$o/include/libpsl.h"
    printf '%s\n' '#define ENABLE_BUILTIN 1' '#define HAVE_NL_LANGINFO 1' "#define PACKAGE_VERSION \"$v\"" > "$o/config.h"
    cc_all "$o" $dcflags -fvisibility=hidden -DHAVE_CONFIG_H -DBUILDING_PSL "-I$o" "-I$o/include" -- \
        "$s/src/psl.c" "$s/src/lookup_string_in_fixed_set.c"
    mkdir -p "$2/lib" "$2/include"
    rm -f "$2/lib/libpsl.a"
    $ar rcs "$2/lib/libpsl.a" "$o"/*.o
    cp "$o/include/libpsl.h" "$2/include/"
    pc_file "$2" libpsl "$v" "Public Suffix List C library" -lpsl "" ""
}

build_lib() {   # <name> <source> <prefix>
    case "$1" in
        c-ares) lib_c_ares "$2" "$3" ;;
        nghttp2) lib_nghttp2 "$2" "$3" ;;
        brotli) lib_brotli "$2" "$3" ;;
        zstd) lib_zstd "$2" "$3" ;;
        libidn2) lib_libidn2 "$2" "$3" ;;
        libpsl) lib_libpsl "$2" "$3" ;;
        *) echo "build-libcurl: no library $1" >&2; return 2 ;;
    esac
}

# The OpenSSL of the PHP build, as its configure found it: OPENSSL_INCDIR (PHP
# 5.6, from --with-openssl=<dir>), else the -I of OPENSSL_CFLAGS (PHP 7.4 and
# later, from pkg-config or the environment), else what pkg-config finds with the
# same environment, else the base system.
openssl_opt() {
    ossl_inc="${OPENSSL_INCDIR:-}"
    if [ -z "$ossl_inc" ]; then
        # shellcheck disable=SC2086
        ossl_inc="$(printf '%s\n' ${OPENSSL_CFLAGS:-} | sed -n 's/^-I//p' | head -n 1)"
    fi
    if [ -z "$ossl_inc" ]; then
        ossl_inc="$($pkgconf --variable=includedir openssl 2>/dev/null || true)"
    fi
    ossl_inc="${ossl_inc:-/usr/include}"
    ossl_opt="--with-openssl=${ossl_inc%/include}"
    if ! grep -q 'OPENSSL_VERSION_MAJOR' "$ossl_inc/openssl/opensslv.h" 2>/dev/null; then
        echo "curl $ver needs OpenSSL 3.0 or later (curl 8.18.0 dropped OpenSSL 1.1.1)," >&2
        echo "$ossl_inc/openssl/opensslv.h has:" \
            "$(sed -n 's/.*OPENSSL_VERSION_TEXT *"\([^"]*\)".*/\1/p' "$ossl_inc/openssl/opensslv.h" 2>/dev/null | head -n 1)" >&2
        echo "FreeBSD 13.x (OpenSSL 1.1.1 in base): build with --with-curl, libcurl from pkg." >&2
        exit 1
    fi
}

# build_curl <source> <prefix> <libraries>
build_curl() {
    src="$1" prefix="$2" deps="$3"
    rm -rf "$obj/curl"
    mkdir -p "$obj/curl"
    # The configure options follow freebsd-ports ftp/curl (CONFIGURE_ARGS and the
    # default OPTIONS) minus what PHP has no use for (README of the fork); c-ares
    # resolves (the port's CARES option, instead of THREADED_RESOLVER);
    # ac_cv_func_SSLv2_client_method=no is from its CONFIGURE_ENV. The -I and -L of
    # the libraries go first, before those the PHP build may have for /usr/local.
    (cd "$obj/curl" && env CC="$cc" CFLAGS="${CFLAGS:-}" CPPFLAGS="-I$deps/include${CPPFLAGS:+ $CPPFLAGS}" \
        LDFLAGS="-L$deps/lib${LDFLAGS:+ $LDFLAGS}" PKG_CONFIG="$obj/pkg-config" \
        ac_cv_func_SSLv2_client_method=no \
        "$src/configure" --prefix="$prefix" --libdir="$prefix/lib" --includedir="$prefix/include" \
        --disable-shared --enable-static --with-pic --disable-dependency-tracking \
        "$ossl_opt" --enable-openssl-auto-load-config \
        --with-ca-path=/etc/ssl/certs --without-ca-bundle \
        --enable-ares="$deps" --disable-threaded-resolver \
        --with-nghttp2="$deps" --with-brotli="$deps" --with-zstd="$deps" \
        --with-libidn2="$deps" --with-libpsl="$deps" \
        --enable-http --enable-ftp --enable-file \
        --enable-proxy --enable-cookies --enable-alt-svc --enable-hsts --enable-ipv6 \
        --enable-aws --enable-dateparse --enable-dnsshuffle --enable-doh \
        --enable-http-auth --enable-mime --enable-netrc --enable-typecheck \
        --disable-imap --disable-pop3 --disable-smtp --disable-websockets --disable-ntlm \
        --disable-headers-api --disable-ssls-export --disable-get-easy-options \
        --disable-progress-meter \
        --disable-httpsig --disable-unity --disable-werror \
        --disable-dict --disable-gopher --disable-ipfs --disable-mqtt --disable-rtsp \
        --disable-telnet --disable-tftp --disable-ldap --disable-ldaps \
        --without-gssapi --without-libssh2 --without-libssh \
        --disable-manual --disable-docs \
        --without-zsh-functions-dir --without-fish-functions-dir)
    mk curl -j"$ncpu" -C lib
    mk curl -C lib install
    mk curl -C include install
    mk curl install-pkgconfigDATA install-binSCRIPTS
    # Only libcurl.a: without libcurl.la libtool passes -lcurl on as it is.
    rm -f "$prefix/lib/libcurl.la"

    # libcurl.a with the libraries in it, their symbols and those of curl local
    # but curl_*: one object, in an archive again
    m="$obj/libcurl-all.o"
    set --
    for l in $deplibs; do set -- "$@" "$deps/lib/lib$l.a"; done
    $ld -r -o "$m" --whole-archive "$prefix/lib/libcurl.a" --no-whole-archive --start-group "$@" --end-group
    nm -g --defined-only "$m" | awk 'NF >= 3 && $NF !~ /^curl_/ { print $NF }' | sort -u > "$obj/local.syms"
    objcopy --localize-symbols="$obj/local.syms" "$m"
    left="$(nm -g --defined-only "$m" | awk 'NF >= 3 && $NF !~ /^curl_/ { print $NF }' | head -n 3 | tr '\n' ' ')"
    [ -z "$left" ] || { echo "build-libcurl: still global in libcurl.a: $left" >&2; exit 1; }
    # (weak references stay open on purpose: the trace hooks of zstd)
    undef="$(nm -u "$m" | awk '$1 == "U" { print $2 }' | grep -E '^(ares_|nghttp2_|Brotli|ZSTD_|idn2_|psl_)' | head -n 3 | tr '\n' ' ' || true)"
    [ -z "$undef" ] || { echo "build-libcurl: libraries missing in libcurl.a: $undef" >&2; exit 1; }
    rm -f "$prefix/lib/libcurl.a"
    $ar rcs "$prefix/lib/libcurl.a" "$m"

    # The link line: libcurl.a and the libraries of the system it needs (OpenSSL,
    # zlib, threads), from the private libraries curl wrote into libcurl.pc, without
    # the ones that are in libcurl.a now and without -L (config.m4 puts the -L of
    # <prefix>/lib into LDFLAGS, so that PHP records no run path into the build
    # tree). It goes into Libs as it is; Requires and the private lines go, so that
    # nothing comes twice.
    pc="$prefix/lib/pkgconfig/libcurl.pc"
    drop=" -lcurl "
    for l in $deplibs; do drop="$drop-l$l "; done
    libs="-lcurl$(sed -n 's/^Libs\.private: *//p' "$pc" | tr ' ' '\n' |
        awk -v drop="$drop" '$0 != "" && $0 !~ /^-L/ && index(drop, " " $0 " ") == 0 && !seen[$0]++ { printf " %s", $0 }')"
    case " $libs " in
        *" -lunistring "*|*" -liconv "*|*" -lintl "*)
            [ -n "${LIBICONV_PREFIX:-}" ] || { echo "build-libcurl: a package library in the link line: $libs" >&2; exit 1; } ;;
    esac
    sed -e "s|^Libs:.*|Libs: $libs|" -e '/^Libs.private:/d' -e '/^Requires/d' "$pc" > "$pc.new"
    mv "$pc.new" "$pc"
    mv "$prefix/bin/curl-config" "$prefix/bin/curl-config.orig"
    cat > "$prefix/bin/curl-config" <<EOF
#!/bin/sh
# curl-config of the bundled libcurl: --libs gives the static link line.
case "\$1" in
    --libs|--static-libs) echo "$libs" ;;
    *) exec "$prefix/bin/curl-config.orig" "\$@" ;;
esac
EOF
    chmod +x "$prefix/bin/curl-config"
}

dcflags="${CFLAGS:--O2 -pipe} -fPIC"
case "${1:-}" in
    --lib)
        [ $# = 4 ] || { echo "usage: build-libcurl.sh --lib <name> <source> <prefix>" >&2; exit 2; }
        obj="${OBJDIR:-$4.obj}"
        pc_wrap "$4"
        say "$2 from $3 into $4"
        build_lib "$2" "$3" "$4"
        exit 0 ;;
    --curl)
        [ $# = 4 ] || { echo "usage: build-libcurl.sh --curl <source> <prefix> <libraries>" >&2; exit 2; }
        obj="${OBJDIR:-$3.obj}"
        ver="$(sed -n 's/^#define LIBCURL_VERSION "\(.*\)"$/\1/p' "$2/include/curl/curlver.h")"
        openssl_opt
        pc_wrap "$4"
        say "curl $ver from $2 into $3, libraries of $4"
        build_curl "$2" "$3" "$4"
        echo "libcurl $ver built: $3 ($ossl_opt; $libs)"
        exit 0 ;;
esac

[ $# = 1 ] || { echo "usage: sh ext/curl/build-libcurl.sh <prefix>" >&2; exit 2; }
prefix="$1"
deps="$prefix.deps"
obj="$prefix.obj"
src="$here/libcurl"
ver="$(sed -n 's/^#define LIBCURL_VERSION "\(.*\)"$/\1/p' "$src/include/curl/curlver.h")"
[ -f "$here/deps/VERSIONS" ] || { echo "build-libcurl: no $here/deps/VERSIONS" >&2; exit 1; }
openssl_opt

stamp="curl $ver | $(tr '\n' ' ' < "$here/deps/VERSIONS") | $ossl_opt | $cc | ${CFLAGS:-} | ${CPPFLAGS:-} | ${LDFLAGS:-} | $(cksum < "$script")"
if [ -f "$prefix/lib/libcurl.a" ] && [ "$(cat "$prefix/.stamp" 2>/dev/null)" = "$stamp" ]; then
    echo "libcurl $ver: built before with the same sources and flags, kept: $prefix"
    exit 0
fi
rm -rf "$prefix" "$obj" "$deps"
mkdir -p "$obj"
pc_wrap "$deps"
for n in c-ares nghttp2 brotli zstd libidn2 libpsl; do
    say "$(awk -v n="$n" '$1 == n { print $1, $2 }' "$here/deps/VERSIONS")"
    build_lib "$n" "$here/deps/$n" "$deps"
done
say "curl $ver"
build_curl "$src" "$prefix" "$deps"

echo "$ver" > "$prefix/VERSION"
cp "$here/deps/VERSIONS" "$prefix/DEPS"
echo "$stamp" > "$prefix/.stamp"
echo "libcurl $ver built: $prefix ($ossl_opt; $libs; with $(awk '$1 != "psl-list" { printf "%s%s %s", (n++ ? ", " : ""), $1, $2 }' "$here/deps/VERSIONS"))"
