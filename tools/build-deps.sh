#!/bin/sh
# build-deps.sh - build /usr/local/phpdeps, the libraries PHP links against,
# static and position independent, from the FreeBSD ports listed in
# freebsd/deps.conf. PHP built against it (php, php-fpm, php-cgi, libphp.so)
# needs no library of /usr/local/lib: a pkg upgrade or packages of another
# FreeBSD version cannot break it, and in Apache its copies of the libraries do
# not mix with those of other modules (their symbols stay hidden).
#
# Usage (FreeBSD, as root, from the top of a php-src checkout of master):
#   sh tools/build-deps.sh --tools     install the build tools (pkg)
#   sh tools/build-deps.sh             build everything, then the tarball
#   sh tools/build-deps.sh icu curl    rebuild only these (the rest must be there)
#
# For every library the ports framework fetches the distfiles of the port at the
# commit of deps.conf, checks them against its distinfo, extracts them and
# applies the port's patches (make patch); this script then configures and builds
# the source tree that way with its own options: only static libraries, -fPIC,
# into PHPDEPS (default /usr/local/phpdeps), in DEPS_WORK (default
# /var/tmp/phpdeps-work). Results go to deps-results/
# (summary.txt, one log per library), the tarball to dist/
# (phpdeps-fbsd<major>-amd64.tar.xz, extracted with tar -xf ... -C /usr/local).
#
# Exit status: 0 everything built, 1 a library failed (the others are still
# built where they can be), 2 usage.

set -u
top="$(pwd)"
conf="$top/freebsd/deps.conf"
P="${PHPDEPS:-/usr/local/phpdeps}"
work="${DEPS_WORK:-/var/tmp/phpdeps-work}"
res="$top/deps-results"
dist="$top/dist"
ports="${PORTSDIR:-$work/ports}"
ncpu="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
major="$(uname -r | cut -d. -f1)"

if [ "${1:-}" = "--tools" ]; then
    # Build tools only; none of their libraries is linked into the bundle (the
    # compiler does not search /usr/local, pkg-config only the bundle and base).
    tools="git cmake ninja meson python3 gmake nasm perl5 pkgconf lzip bison autoconf automake libtool gettext-tools m4"
    # shellcheck disable=SC2086
    env ASSUME_ALWAYS_YES=yes pkg install -y $tools
    rc=$?
    for t in $tools; do pkg info -e "$t" || echo "build-deps: package $t is not installed"; done
    exit $rc
fi
[ -f "$conf" ] || { echo "build-deps: no $conf (run from the top of a php-src checkout of master)" >&2; exit 2; }

say() { printf '[build-deps %s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

# The flags of every library: portable to any x86-64-v2 CPU (the PHP build adds
# the -march of its server), position independent so that they can go into
# libphp.so, and nothing from /usr/local: the base compiler does not search it,
# pkg-config only sees the bundle and the base system.
export CC=cc CXX=c++
export CFLAGS="-O2 -pipe -march=x86-64-v2 -fPIC -fstack-protector-strong"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="-I$P/include"
export LDFLAGS="-L$P/lib"
# pkg-config with --static: there are only static libraries, so link tests and
# tools need the libraries behind them too (libpsl: libidn2, libunistring).
mkdir -p "$work/bin"
printf '%s\n' '#!/bin/sh' 'exec pkgconf --static "$@"' > "$work/bin/pkg-config-static"
chmod +x "$work/bin/pkg-config-static"
export PKG_CONFIG="$work/bin/pkg-config-static"
export PKG_CONFIG_LIBDIR="$P/lib/pkgconfig:$P/libdata/pkgconfig:/usr/libdata/pkgconfig"
unset PKG_CONFIG_PATH
export PATH="$P/bin:$PATH"

ports_commit="$(awk '$1 == "ports" { print $2 }' "$conf")"
libs_all="$(awk '$1 == "lib" { print $2 }' "$conf")"
port_of() { awk -v n="$1" '$1 == "lib" && $2 == n { print $3 }' "$conf"; }

# A sparse checkout of freebsd-ports at the commit of deps.conf: the framework
# (Mk, Templates, Keywords) and the ports of deps.conf, with what they include
# (devel/gettext; lang/perl5.* and lang/python3* for the version files that
# USES=perl5 and USES=python read).
ports_checkout() {
    if [ "$(git -C "$ports" rev-parse HEAD 2>/dev/null)" = "$ports_commit" ]; then return 0; fi
    say "freebsd-ports at $ports_commit into $ports"
    rm -rf "$ports"
    mkdir -p "$ports"
    # shellcheck disable=SC2046
    git -C "$ports" init -q &&
        git -C "$ports" remote add origin https://github.com/freebsd/freebsd-ports &&
        git -C "$ports" fetch -q --depth 1 --filter=blob:none origin "$ports_commit" &&
        git -C "$ports" sparse-checkout set --no-cone /Mk/ /Templates/ /Keywords/ \
            $(awk '$1 == "lib" { printf "/%s/ ", $3 }' "$conf") /devel/gettext/ \
            '/lang/perl5*/' '/lang/python3*/' &&
        git -C "$ports" checkout -q FETCH_HEAD
}
pmake() {
    p="$1"; shift
    make -C "$ports/$p" BATCH=yes NO_DEPENDS=yes DISABLE_VULNERABILITIES=yes \
        PORTSDIR="$ports" WRKDIRPREFIX="$work/wrk" DISTDIR="$work/distfiles" "$@"
}

# Builds: $1 is the source tree after the ports' patches.
# For GNU configure the ports framework puts its own config.guess and config.sub
# into the tree (old ones do not know FreeBSD 15); so does this.
fix_guess() {
    find "$1" \( -name config.guess -o -name config.sub \) -type f | while IFS= read -r f; do
        cp "$ports/Templates/${f##*/}" "$f" && chmod a+rx "$f"
    done
}
at() {
    src="$1"; shift
    fix_guess "$src"
    (cd "$src" && ./configure --prefix="$P" --libdir="$P/lib" --includedir="$P/include" \
        --enable-static --disable-shared --with-pic "$@" && gmake -j"$ncpu" && gmake install)
}
cm() {
    src="$1"; shift
    cmake -S "$src" -B "$src/_phpdeps" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$P" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_PREFIX_PATH="$P" \
        -DCMAKE_IGNORE_PREFIX_PATH=/usr/local -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_C_FLAGS="$CFLAGS" -DCMAKE_CXX_FLAGS="$CXXFLAGS" "$@" &&
        cmake --build "$src/_phpdeps" -j "$ncpu" && cmake --install "$src/_phpdeps"
}

b_openssl() {
    # no-module: the providers, legacy included, are built into libcrypto; OSSL_PROVIDER_load(NULL,
    # "legacy") of PHP finds it without a module file. /etc/ssl: openssl.cnf and the CA store of base.
    (cd "$1" && ./Configure BSD-x86_64 --prefix="$P" --libdir=lib --openssldir=/etc/ssl \
        no-shared no-module no-tests no-docs $CFLAGS &&
        gmake -j"$ncpu" build_libs && gmake install_dev)
}
b_libiconv() {
    # one job, as the port (MAKE_JOBS_UNSAFE); am_cv_func_iconv=no, as the port: not the iconv of libc
    fix_guess "$1"
    (cd "$1" && ./configure --prefix="$P" --libdir="$P/lib" --enable-static --disable-shared --with-pic \
        --disable-nls --enable-extra-encodings am_cv_func_iconv=no && gmake && gmake install)
}
b_libunistring() { at "$1" --with-libiconv-prefix="$P"; }
b_libidn2() { at "$1" --disable-nls --disable-doc --with-libiconv-prefix="$P" --with-libunistring-prefix="$P" ac_cv_prog_RONN=true; }
b_libpsl() {
    # as the port (built-in list, IDN2), static: prefer_static for the psl tool's link
    (cd "$1" && meson setup _phpdeps --prefix="$P" --libdir=lib -Ddefault_library=static -Db_staticpic=true \
        -Dprefer_static=true -Druntime=libidn2 -Dbuiltin=true -Ddocs=false &&
        ninja -C _phpdeps && ninja -C _phpdeps install)
}
b_nghttp2() { at "$1" --enable-lib-only; }
b_brotli() { cm "$1" -DBROTLI_DISABLE_TESTS=ON; }
b_zstd() {
    (cd "$1/lib" && gmake -j"$ncpu" libzstd.a libzstd.pc PREFIX="$P" LIBDIR="$P/lib" &&
        gmake install-static install-pc install-includes PREFIX="$P" LIBDIR="$P/lib" PKGCONFIGDIR="$P/lib/pkgconfig")
}
b_lz4() {
    (cd "$1/lib" && gmake -j"$ncpu" liblz4.a liblz4.pc PREFIX="$P" LIBDIR="$P/lib" BUILD_SHARED=no &&
        gmake install PREFIX="$P" LIBDIR="$P/lib" PKGCONFIGDIR="$P/lib/pkgconfig" BUILD_SHARED=no)
}
b_libxml2() { at "$1" --sysconfdir="$P/share" --without-python --with-iconv="$P" --with-zlib --without-icu --without-lzma --without-readline --without-history --with-http; }
b_icu() { at "$1" --with-data-packaging=static --disable-layoutex --disable-tests --disable-samples --disable-extras; }
b_oniguruma() { cm "$1" -DBUILD_TEST=OFF -DENABLE_POSIX_API=ON; }
b_libzip() {
    cm "$1" -DENABLE_OPENSSL=ON -DENABLE_GNUTLS=OFF -DENABLE_MBEDTLS=OFF -DENABLE_COMMONCRYPTO=OFF \
        -DENABLE_WINDOWS_CRYPTO=OFF -DENABLE_BZIP2=ON -DENABLE_LZMA=OFF -DENABLE_ZSTD=ON \
        -DBUILD_TOOLS=OFF -DBUILD_REGRESS=OFF -DBUILD_OSSFUZZ=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOC=OFF \
        -DOPENSSL_ROOT_DIR="$P" -DOPENSSL_USE_STATIC_LIBS=ON
}
b_png() { cm "$1" -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_DEBUG_POSTFIX=""; }
b_mozjpeg() {
    # as the port (JPEG8 API, SIMD), without the tools' PNG input and TurboJPEG, which gd does not use.
    # Absolute install directories: the GNUInstallDirs of mozjpeg takes a relative one as relative to
    # the current directory, so that CMAKE_INSTALL_LIBDIR=lib of cm put libjpeg.a, libjpeg.pc and its
    # cmake files outside the bundle (only the headers and manual pages got in).
    cm "$1" -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_JPEG8=ON -DWITH_SIMD=ON -DREQUIRE_SIMD=OFF \
        -DWITH_ARITH_DEC=OFF -DWITH_ARITH_ENC=OFF -DWITH_12BIT=OFF -DWITH_JAVA=OFF -DWITH_JPEG7=OFF \
        -DWITH_TURBOJPEG=OFF -DPNG_SUPPORTED=OFF -DWITH_MEM_SRCDST=ON -DFORCE_INLINE=ON \
        -DCMAKE_INSTALL_LIBDIR="$P/lib" -DCMAKE_INSTALL_INCLUDEDIR="$P/include" \
        -DCMAKE_INSTALL_BINDIR="$P/bin" -DCMAKE_INSTALL_MANDIR="$P/share/man" \
        -DCMAKE_INSTALL_DOCDIR="$P/share/doc/mozjpeg"
}
b_webp() {
    at "$1" --enable-libwebpdecoder --enable-libwebpdemux --enable-libwebpmux --disable-gl --disable-sdl \
        --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-wic
}
b_freetype2() {
    cm "$1" -DFT_REQUIRE_ZLIB=ON -DFT_DISABLE_BZIP2=OFF -DFT_DISABLE_PNG=ON -DFT_DISABLE_HARFBUZZ=ON \
        -DFT_DISABLE_BROTLI=ON
}
b_gd() {
    # the port runs autoreconf (USES=autoreconf); without fontconfig, X, TIFF, AVIF, HEIF
    (cd "$1" && autoreconf -fi) &&
        at "$1" --enable-gd-formats --with-zlib --with-png="$P" --with-jpeg="$P" --with-webp="$P" \
            --with-freetype="$P" --without-fontconfig --without-xpm --without-x --without-tiff \
            --without-avif --without-heif --without-raqm --without-liq --with-libiconv-prefix="$P"
}
b_libmcrypt() { at "$1"; }
b_libevent() { at "$1" --enable-openssl --enable-thread-support --disable-samples --disable-libevent-regress; }
b_libmemcached() {
    # no SASL (cyrus-sasl loads its mechanisms as modules); the hashes of the port
    cm "$1" -DENABLE_SASL=OFF -DBUILD_TESTING=OFF -DBUILD_DOCS=OFF -DBUILD_DOCSONLY=OFF \
        -DENABLE_HASH_FNV64=ON -DENABLE_HASH_HSIEH=ON -DENABLE_HASH_MURMUR=ON -DENABLE_MEMASLAP=OFF
}
b_libsodium() { at "$1"; }
b_argon2() {
    # its Makefile builds static and shared, with -march=$(OPTTARGET) (native by default)
    (cd "$1" && gmake -j"$ncpu" libargon2.a OPTTARGET=x86-64-v2 &&
        mkdir -p "$P/include" "$P/lib/pkgconfig" && cp include/argon2.h "$P/include/" &&
        cp libargon2.a "$P/lib/" &&
        printf '%s\n' "prefix=$P" 'libdir=${prefix}/lib' 'includedir=${prefix}/include' '' \
            'Name: libargon2' 'Description: Argon2 password hashing' 'Version: 20190702' \
            'Libs: -L${libdir} -largon2 -lpthread' 'Cflags: -I${includedir}' > "$P/lib/pkgconfig/libargon2.pc")
}
b_pcre2() {
    cm "$1" -DBUILD_STATIC_LIBS=ON -DPCRE2_STATIC_PIC=ON -DPCRE2_SUPPORT_JIT=ON -DPCRE2_BUILD_TESTS=OFF \
        -DPCRE2_BUILD_PCRE2GREP=OFF -DPCRE2_SUPPORT_LIBREADLINE=OFF -DPCRE2_SUPPORT_LIBEDIT=OFF
}
b_pcre() { at "$1" --enable-utf --enable-unicode-properties --enable-jit --disable-cpp --disable-pcregrep-libz --disable-pcregrep-libbz2; }
b_readline() { at "$1" --with-curses --enable-bracketed-paste-default; }
b_gettext() {
    # gettext-runtime (WRKSRC of the port); only libintl is wanted (ext/gettext of 5.6)
    at "$1" --disable-csharp --disable-java --disable-libasprintf --disable-threads --disable-openmp \
        --disable-acl --with-libiconv-prefix="$P" --without-emacs ac_cv_lib_rt_sched_yield=no
}
b_curl() {
    # the options of freebsd/curl/build-libcurl.sh (--with-curl=bundled), with the bundle's
    # OpenSSL and libraries
    at "$1" --disable-dependency-tracking --with-openssl="$P" --enable-openssl-auto-load-config \
        --with-ca-path=/etc/ssl/certs --without-ca-bundle \
        --with-nghttp2="$P" --with-brotli="$P" --with-zstd="$P" --with-libidn2="$P" --with-libpsl \
        --enable-http --enable-ftp --enable-imap --enable-pop3 --enable-smtp \
        --enable-proxy --enable-cookies --enable-alt-svc --enable-hsts --enable-ntlm \
        --enable-websockets --enable-ipv6 --enable-threaded-resolver \
        --enable-aws --enable-dateparse --enable-dnsshuffle --enable-headers-api \
        --enable-http-auth --enable-mime --enable-netrc --enable-progress-meter \
        --enable-ssls-export --enable-typecheck \
        --disable-httpsig --disable-unity --disable-werror \
        --disable-dict --disable-gopher --disable-ipfs --disable-mqtt --disable-rtsp \
        --disable-telnet --disable-tftp --disable-ldap --disable-ldaps \
        --without-gssapi --without-libssh2 --without-libssh \
        --disable-manual --disable-docs --without-zsh-functions-dir --without-fish-functions-dir \
        ac_cv_func_SSLv2_client_method=no &&
        curl_hide_nghttp2
}

# libcurl.a with libnghttp2.a linked into it and the nghttp2 symbols made local:
# swoole and openswoole carry a copy of nghttp2 of their own (thirdparty/nghttp2),
# which clashed with libnghttp2.a in a static link of PHP ("duplicate symbol:
# nghttp2_strerror", huff_sym_table), and curl keeps the nghttp2 it was built with.
# libcurl.pc no longer names libnghttp2.
curl_hide_nghttp2() {
    m="$work/libcurl-merged.o"
    rm -f "$m"
    ld -r -o "$m" --whole-archive "$P/lib/libcurl.a" "$P/lib/libnghttp2.a" --no-whole-archive || return 1
    nm -g --defined-only "$m" | awk 'NF == 3 && $3 ~ /^(nghttp2_|sfparse_|huff_)/ { print $3 }' > "$work/nghttp2.syms"
    [ -s "$work/nghttp2.syms" ] || { echo "curl_hide_nghttp2: no nghttp2 symbols in libcurl"; return 1; }
    objcopy --localize-symbols="$work/nghttp2.syms" "$m" || return 1
    if nm -g --defined-only "$m" | awk 'NF == 3 { print $3 }' | grep -q -E '^(nghttp2_|sfparse_|huff_)'; then
        echo "curl_hide_nghttp2: nghttp2 symbols still global"; return 1
    fi
    rm -f "$P/lib/libcurl.a" && ar rcs "$P/lib/libcurl.a" "$m" || return 1
    for pc in "$P/lib/pkgconfig/libcurl.pc" "$P/libdata/pkgconfig/libcurl.pc"; do
        [ -f "$pc" ] || continue
        sed -i '' -E -e '/^Libs.private:/ s/ ?-lnghttp2//' \
            -e '/^Requires.private:/ { s/libnghttp2( *[<>=]+ *[^ ,]+)? *,? *//; s/, *$//; }' "$pc"
    done
    echo "curl_hide_nghttp2: $(wc -l < "$work/nghttp2.syms" | tr -d ' ') nghttp2 symbols local in libcurl.a"
}

# One library: fetch, check, extract and patch with the ports framework, then build.
build_one() {
    n="$1"
    port="$(port_of "$n")"
    log="$res/$n.log"
    start=$(date +%s)
    (
        echo "== $n: $port at $ports_commit"
        pmake "$port" clean >/dev/null 2>&1
        pmake "$port" patch || { echo "make patch failed"; exit 1; }
        src="$(pmake "$port" -V WRKSRC)"
        echo "== source: $src"
        : > "$work/stamp-$n"
        "b_$n" "$src" || exit 1
        # every library leaves a static archive of its own in lib/ (mozjpeg did not)
        if [ -z "$(find "$P/lib" -maxdepth 1 -name '*.a' -newer "$work/stamp-$n" | head -n 1)" ]; then
            echo "== no new static library of $n in $P/lib"; exit 1
        fi
    ) > "$log" 2>&1
    rc=$?
    ver="$(pmake "$port" -V PKGVERSION 2>/dev/null)"
    pkgname="$(pmake "$port" -V PKGNAME 2>/dev/null)"
    if [ "$rc" = 0 ]; then
        printf '%-14s OK    %-22s %-24s %4ss\n' "$n" "$ver" "$port" "$(( $(date +%s) - start ))" >> "$res/summary.txt"
        printf '%s %s %s\n' "$n" "$pkgname" "$port" >> "$res/built.txt"
    else
        printf '%-14s FAIL  %-22s %-24s %4ss (deps-results/%s.log)\n' "$n" "$ver" "$port" "$(( $(date +%s) - start ))" "$n" >> "$res/summary.txt"
        tail -n 25 "$log" > "$res/$n.tail"
    fi
    say "$n: $(tail -n 1 "$res/summary.txt" | awk '{ print $2 }')"
    return "$rc"
}

# After the builds: only static libraries, the .pc files in lib/pkgconfig, the
# *-config scripts and headers; every archive position independent.
finish() {
    rm -f "$P"/lib/*.so "$P"/lib/*.so.* "$P"/lib/*.la
    if [ -d "$P/libdata/pkgconfig" ]; then
        mkdir -p "$P/lib/pkgconfig" && mv "$P"/libdata/pkgconfig/*.pc "$P/lib/pkgconfig/" 2>/dev/null
        rm -rf "$P/libdata"
    fi
    if [ -d "$P/bin" ]; then
        find "$P/bin" -type f ! -name '*-config' ! -name '*-config.orig' -delete
    fi
    rm -rf "$P/share/man" "$P/share/doc" "$P/share/info" "$P/share/gtk-doc" "$P/share/locale" "$P/share/emacs"
    # The C++ runtime of libmemcached for static links (its .pc does not name it).
    pc="$P/lib/pkgconfig/libmemcached.pc"
    if [ -f "$pc" ] && ! grep -q -- '-lc++' "$pc"; then
        if grep -q '^Libs.private:' "$pc"; then sed -i '' 's/^Libs.private:.*/& -lc++ -lm/' "$pc"
        else echo 'Libs.private: -lc++ -lm' >> "$pc"; fi
    fi
    # curl-config: --libs gives the static link line, as in freebsd/curl/build-libcurl.sh.
    if [ -f "$P/bin/curl-config" ] && [ ! -f "$P/bin/curl-config.orig" ]; then
        libs="$(pkgconf --static --libs libcurl)"
        mv "$P/bin/curl-config" "$P/bin/curl-config.orig"
        printf '%s\n' '#!/bin/sh' '# curl-config of /usr/local/phpdeps: --libs gives the static link line.' \
            'case "$1" in' "    --libs|--static-libs) echo \"$libs\" ;;" "    *) exec \"$P/bin/curl-config.orig\" \"\$@\" ;;" \
            'esac' > "$P/bin/curl-config"
        chmod +x "$P/bin/curl-config"
    fi
    # pkg-config for PHP builds against the bundle (config-check.sh writes PKG_CONFIG
    # with it): the bundle first, then the base system and the packages (for what the
    # bundle has not, such as ImageMagick), and static link lines.
    mkdir -p "$P/bin"
    printf '%s\n' '#!/bin/sh' "# pkg-config of $P: the bundle first, static link lines." \
        "PKG_CONFIG_LIBDIR='$P/lib/pkgconfig:/usr/libdata/pkgconfig:/usr/local/libdata/pkgconfig:/usr/local/share/pkgconfig'" \
        'export PKG_CONFIG_LIBDIR' 'unset PKG_CONFIG_PATH' 'exec /usr/local/bin/pkgconf --static "$@"' > "$P/bin/pkg-config"
    chmod +x "$P/bin/pkg-config"
    # Position independent: the whole archive links into a shared object. Relocation
    # errors mean it is not (and it could not go into libphp.so); other errors are
    # only noted.
    : > "$res/pic.txt"; : > "$res/pic-notes.txt"
    for a in "$P"/lib/*.a; do
        if ! cc -shared -o "$work/pic-test.so" -Wl,--whole-archive "$a" -Wl,--no-whole-archive \
                -Wl,--unresolved-symbols=ignore-all > "$work/pic-test.log" 2>&1; then
            if grep -q -i 'relocation' "$work/pic-test.log"; then
                echo "${a##*/}: not position independent: $(grep -m 1 -i relocation "$work/pic-test.log")" >> "$res/pic.txt"
            else
                echo "${a##*/}: link test failed: $(grep -m 1 -i error "$work/pic-test.log")" >> "$res/pic-notes.txt"
            fi
        fi
    done
    # Nothing may point to /usr/local outside the bundle (the libraries of pkg).
    grep -rn '/usr/local/' "$P/lib/pkgconfig" "$P/bin" 2>/dev/null | sed 's#/usr/local/phpdeps##g' |
        grep '/usr/local/' > "$res/localbase.txt" || true
}

manifest() {
    {
        echo "phpdeps for FreeBSD $major (amd64), built $(date '+%Y-%m-%d %H:%M %Z') on $(uname -sr)"
        echo "freebsd-ports $ports_commit; static, -fPIC, $CFLAGS"
        echo
        while read -r n pkgname port; do
            printf '%-14s %-28s %s\n' "$n" "$pkgname" "$port"
            sed -n 's/^SHA256 (\(.*\)) = \(.*\)/    \1 sha256 \2/p' "$ports/$port/distinfo"
            np="$(ls "$ports/$port/files" 2>/dev/null | grep -c '^patch-')"
            [ "$np" -gt 0 ] && echo "    $np patches of the port"
        done < "$res/built.txt"
    } > "$P/VERSIONS"
}

mkdir -p "$res" "$work" "$dist"
if [ $# -eq 0 ]; then
    set -- $libs_all
    rm -rf "$P"
    : > "$res/summary.txt"; : > "$res/built.txt"
fi
for n in "$@"; do
    [ -n "$(port_of "$n")" ] || { echo "build-deps: $n is not in $conf" >&2; exit 2; }
done
ports_checkout || { echo "build-deps: cannot check out freebsd-ports $ports_commit" > "$res/summary.txt"; exit 1; }
mkdir -p "$P"
rc=0
for n in "$@"; do
    say "$n ($(port_of "$n"))"
    build_one "$n" || rc=1
done
finish
manifest
# Known vulnerabilities of these versions (FreeBSD VuXML), for the report.
pkg audit -F -q $(awk '{ print $2 }' "$res/built.txt") > "$res/audit.txt" 2>&1 || true
if [ "$rc" = 0 ] && [ ! -s "$res/pic.txt" ]; then
    tarball="$dist/phpdeps-fbsd$major-amd64.tar.xz"
    tar -cJf "$tarball" -C "$(dirname "$P")" "$(basename "$P")"
    sha256 -q "$tarball" > "$tarball.sha256"
    cp "$P/VERSIONS" "$dist/phpdeps-fbsd$major-amd64.VERSIONS.txt"
    echo "tarball: ${tarball##*/} ($(du -k "$tarball" | cut -f1) KB, $(du -sk "$P" | cut -f1) KB unpacked)" >> "$res/summary.txt"
fi
exit "$rc"
