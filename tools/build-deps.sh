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
# the source tree that way with its own options. curl and the libraries it needs
# ("bundle" in deps.conf) are the ones of --with-curl=bundled instead: the
# release files of freebsd/curl.conf and freebsd/curl-deps.conf (tools/curl-sources.sh),
# built by freebsd/curl/build-libcurl.sh. All: only static libraries, -fPIC,
# into PHPDEPS (default /usr/local/phpdeps), in DEPS_WORK (default
# /var/tmp/phpdeps-work). Results go to deps-results/
# (summary.txt, one log per library), the tarball to dist/
# (phpdeps-fbsd<major>-amd64-<level>.tar.xz, such as -v3 for -march=x86-64-v3,
# extracted with tar -xf ... -C /usr/local).
#
# Compiler flags as on the servers: CPUTYPE and CFLAGS of /etc/make.conf (such as
# CPUTYPE?=x86-64-v3 and CFLAGS=-O3 -pipe) with -fstack-protector-strong and
# -fno-strict-aliasing, and -fPIC. PHPDEPS_CPUTYPE and PHPDEPS_CFLAGS (the inputs
# of the workflow deps.yml) win over make.conf (MAKE_CONF, default /etc/make.conf);
# without either: x86-64-v3 and -O3 -pipe. The build runs what it compiles
# (configure tests, the data tools of ICU), so it stops at once on a CPU that
# cannot run code of that level; PHP built against the bundle needs it too.
#
# Exit status: 0 everything built, 1 a library failed (the others are still
# built where they can be) or this CPU cannot run the level, 2 usage.

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

# A variable of make.conf (VAR=, ?=, := and += lines; comments dropped), as in
# tools/config-check.sh.
mk_conf="${MAKE_CONF:-/etc/make.conf}"
mc_get() {
    [ -r "$mk_conf" ] || return 0
    awk -v v="$1" '
        { sub(/#.*/, "") }
        $0 ~ "^[ \t]*" v "[ \t]*[?:]?=" { s = $0; sub("^[ \t]*" v "[ \t]*[?:]?=[ \t]*", "", s); val = s; have = 1; next }
        $0 ~ "^[ \t]*" v "[ \t]*\\+=" { s = $0; sub("^[ \t]*" v "[ \t]*\\+=[ \t]*", "", s); val = val " " s; have = 1 }
        END { if (have) { sub(/[ \t]+$/, "", val); print val } }
    ' "$mk_conf"
}

# The flags of every library: CPUTYPE and CFLAGS of the servers (see above), the
# two protections, position independent so that they can go into libphp.so, and
# nothing from /usr/local: the base compiler does not search it, pkg-config only
# sees the bundle and the base system. A -march in CFLAGS gives way to CPUTYPE.
cputype="${PHPDEPS_CPUTYPE:-$(mc_get CPUTYPE)}"
cputype="${cputype:-x86-64-v3}"
opt="${PHPDEPS_CFLAGS:-$(mc_get CFLAGS)}"
# shellcheck disable=SC2086
opt="$(printf '%s\n' ${opt:--O3 -pipe} | grep -v -e '^-march=' -e '^-fPIC$' | tr '\n' ' ' | sed 's/ *$//')"
level="${cputype#x86-64-}"
export CC=cc CXX=c++
export CFLAGS="$opt -march=$cputype -fstack-protector-strong -fno-strict-aliasing -fPIC"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="-I$P/include"
export LDFLAGS="-L$P/lib"
# pkg-config with --static: there are only static libraries, so link tests and
# tools need the libraries behind them too (libidn2: libiconv).
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
            $(awk '$1 == "lib" && $3 != "bundle" { printf "/%s/ ", $3 }' "$conf") /devel/gettext/ \
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
    (cd "$1" && gmake -j"$ncpu" libargon2.a OPTTARGET="$cputype" &&
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

# One library: fetch, check, extract and patch with the ports framework, then build.
build_one() {
    n="$1"
    port="$(port_of "$n")"
    log="$res/$n.log"
    start=$(date +%s)
    if [ "$port" = bundle ]; then build_bundle "$n"; return; fi
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

# One library of the bundled curl (port "bundle" in deps.conf): the sources of
# tools/curl-sources.sh (once per run), built by freebsd/curl/build-libcurl.sh as
# for --with-curl=bundled; curl takes its libraries into libcurl.a with their
# symbols local (swoole carries a copy of nghttp2, libzip links zstd).
bundle_ver() {
    if [ "$1" = curl ]; then
        sed -n 's/^#define LIBCURL_VERSION "\(.*\)"$/\1/p' "$work/curl-src/libcurl/include/curl/curlver.h"
    else
        awk -v n="$1" '$1 == n { print $2 }' "$work/curl-src/deps/VERSIONS"
    fi
}
build_bundle() {
    n="$1"
    (
        echo "== $n: the bundled curl (freebsd/curl.conf, freebsd/curl-deps.conf)"
        if [ ! -f "$work/curl-src/deps/VERSIONS" ]; then
            sh "$top/tools/curl-sources.sh" "$work/curl-src" || { echo "tools/curl-sources.sh failed"; exit 1; }
        fi
        : > "$work/stamp-$n"
        b="$top/freebsd/curl/build-libcurl.sh"
        case "$n" in
            curl) OBJDIR="$work/obj-curl" sh "$b" --curl "$work/curl-src/libcurl" "$P" "$P" ;;
            libidn2) LIBICONV_PREFIX="$P" OBJDIR="$work/obj-curl" sh "$b" --lib libidn2 "$work/curl-src/deps/libidn2" "$P" ;;
            *) OBJDIR="$work/obj-curl" sh "$b" --lib "$n" "$work/curl-src/deps/$n" "$P" ;;
        esac || exit 1
        if [ -z "$(find "$P/lib" -maxdepth 1 -name '*.a' -newer "$work/stamp-$n" | head -n 1)" ]; then
            echo "== no new static library of $n in $P/lib"; exit 1
        fi
    ) > "$log" 2>&1
    rc=$?
    ver="$(bundle_ver "$n")"
    case "$n" in nghttp2) pkgname="libnghttp2-$ver" ;; *) pkgname="$n-$ver" ;; esac
    if [ "$rc" = 0 ]; then
        printf '%-14s OK    %-22s %-24s %4ss\n' "$n" "$ver" bundle "$(( $(date +%s) - start ))" >> "$res/summary.txt"
        printf '%s %s %s\n' "$n" "$pkgname" bundle >> "$res/built.txt"
    else
        printf '%-14s FAIL  %-22s %-24s %4ss (deps-results/%s.log)\n' "$n" "$ver" bundle "$(( $(date +%s) - start ))" "$n" >> "$res/summary.txt"
        tail -n 25 "$log" > "$res/$n.tail"
    fi
    say "$n: $(tail -n 1 "$res/summary.txt" | awk '{ print $2 }')"
    return "$rc"
}

# pc_add <file.pc> <Libs|Libs.private> <-lname>...: add to that line of a .pc file the
# libraries it does not name yet (the line is added when there is none). Idempotent;
# nothing when the file is not there.
pc_add() {
    pc="$1"; field="$2"; shift 2
    [ -f "$pc" ] || return 0
    awk -v field="$field:" -v libs="$*" '
        function add(line,   n, i, t, have) {
            n = split(line, t, " "); for (i = 2; i <= n; i++) have[t[i]] = 1
            n = split(libs, t, " "); for (i = 1; i <= n; i++) if (!(t[i] in have)) line = line " " t[i]
            return line
        }
        $1 == field { $0 = add($0); found = 1 }
        { print }
        END { if (!found) print add(field) }
    ' "$pc" > "$pc.new" && mv "$pc.new" "$pc"
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
    # Static link lines that the .pc files, written for shared libraries, leave short
    # (tools/check-deps-links.py below finds them): libmemcached needs libhashkit
    # (libmemcached.so links it itself: every PHP build failed on hashkit_* symbols), the
    # C++ runtime, backtrace() of libexecinfo and the threads; libevent_extra needs
    # libevent_core.
    pc_add "$P/lib/pkgconfig/libmemcached.pc" Libs -lhashkit
    pc_add "$P/lib/pkgconfig/libmemcached.pc" Libs.private -lc++ -lm -lexecinfo -lpthread
    pc_add "$P/lib/pkgconfig/libevent_extra.pc" Libs.private -levent_core
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
    # Every .pc names the archives of the bundle that its archives need (a short one
    # fails the PHP builds at the link only); a finding stops the tarball.
    : > "$res/links.txt"
    if ! python3 "$top/tools/check-deps-links.py" "$P" /usr/libdata/pkgconfig > "$res/links.log" 2>&1; then
        cp "$res/links.log" "$res/links.txt"
    fi
}

manifest() {
    {
        echo "phpdeps for FreeBSD $major (amd64, $cputype), built $(date '+%Y-%m-%d %H:%M %Z') on $(uname -sr)"
        echo "freebsd-ports $ports_commit; static libraries, CFLAGS: $CFLAGS"
        echo
        while read -r n pkgname port; do
            printf '%-14s %-28s %s\n' "$n" "$pkgname" "$port"
            if [ "$port" = bundle ]; then
                if [ "$n" = curl ]; then
                    awk '!/^#/ && NF >= 4 { u = $3; s = $4 } END { n = split(u, p, "/"); print "    " p[n] " sha256 " s }' "$top/freebsd/curl.conf"
                else
                    awk -v n="$n" '$1 == n { print "    " $4 " sha256 " $3 }' "$work/curl-src/deps/VERSIONS"
                fi
                continue
            fi
            sed -n 's/^SHA256 (\(.*\)) = \(.*\)/    \1 sha256 \2/p' "$ports/$port/distinfo"
            np="$(ls "$ports/$port/files" 2>/dev/null | grep -c '^patch-')"
            [ "$np" -gt 0 ] && echo "    $np patches of the port"
        done < "$res/built.txt"
    } > "$P/VERSIONS"
}

mkdir -p "$res" "$work" "$dist"
cpu_model="$(sysctl -n hw.model 2>/dev/null)"
if [ $# -eq 0 ]; then
    set -- $libs_all
    rm -rf "$P"
    : > "$res/summary.txt"; : > "$res/built.txt"
    printf 'flags:    %s\ncpu:      %s\n' "$CFLAGS" "${cpu_model:-?}" >> "$res/summary.txt"
fi
# This CPU has to run code of the level (configure tests, the data tools of ICU):
# where it cannot, configure decides wrong without a word and ICU stops.
cpu_feats() {
    cc "-march=$1" -dM -E - < /dev/null 2>/dev/null |
        sed -n -E 's/^#define __(SSE4_2|POPCNT|AVX|AVX2|BMI|BMI2|FMA|F16C|LZCNT|MOVBE|AVX512F|AVX512BW|AVX512CD|AVX512DQ|AVX512VL)__ 1$/\1/p' |
        LC_ALL=C sort -u
}
cpu_feats "$cputype" > "$work/cpu-need"
cpu_feats native > "$work/cpu-have"
lacks="$(LC_ALL=C comm -23 "$work/cpu-need" "$work/cpu-have" | tr '\n' ' ' | sed 's/ *$//')"
if [ ! -s "$work/cpu-need" ] || [ -n "$lacks" ]; then
    why="${lacks:+lacks $lacks of}"
    printf '%-14s FAIL  this CPU (%s) %s -march=%s: code built for it cannot run here\n' \
        cpu "${cpu_model:-?}" "${why:-cannot tell the features of}" "$cputype" >> "$res/summary.txt"
    echo "build-deps: this CPU ${why:-cannot tell the features of} -march=$cputype; build on a CPU that has them, or set PHPDEPS_CPUTYPE to a lower level" >&2
    exit 1
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
if [ "$rc" = 0 ] && [ ! -s "$res/pic.txt" ] && [ ! -s "$res/links.txt" ]; then
    tarball="$dist/phpdeps-fbsd$major-amd64-$level.tar.xz"
    tar -cJf "$tarball" -C "$(dirname "$P")" "$(basename "$P")"
    sha256 -q "$tarball" > "$tarball.sha256"
    cp "$P/VERSIONS" "$dist/phpdeps-fbsd$major-amd64-$level.VERSIONS.txt"
    echo "tarball: ${tarball##*/} ($(du -k "$tarball" | cut -f1) KB, $(du -sk "$P" | cut -f1) KB unpacked)" >> "$res/summary.txt"
fi
exit "$rc"
