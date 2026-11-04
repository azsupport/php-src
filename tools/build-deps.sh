#!/bin/sh
# build-deps.sh - build the libraries of /usr/local/az (lib/, include/), static
# and position independent, from the FreeBSD ports listed in freebsd/deps.conf,
# and the curl program (bin/curl). PHP built against them (php, php-fpm, php-cgi,
# libphp.so) and the programs of /usr/local/az (FFmpeg, ImageMagick) need no
# library of /usr/local/lib: a pkg upgrade or packages of another FreeBSD version
# cannot break them, and in Apache the copies of the libraries in PHP do not mix
# with those of other modules (their symbols stay hidden). tools/build-az.sh runs
# this first, then the programs, the tests and the tarball.
#
# Usage (FreeBSD, as root, from the top of a php-src checkout of master):
#   sh tools/build-deps.sh --tools     install the build tools (pkg)
#   sh tools/build-deps.sh             build everything (into an empty directory)
#   sh tools/build-deps.sh icu curl    rebuild only these (the rest must be there)
#
# For every library the ports framework fetches the distfiles of the port at the
# commit of deps.conf, checks them against its distinfo, extracts them and
# applies the port's patches (make patch); this script then configures and builds
# the source tree that way with its own options. A "take" line of deps.conf (a
# new upstream release the port does not have yet) gives the release file
# instead: fetched here, checked against the SHA-256 of the line, handed to the
# framework with a distinfo of its own, with the port's patches or those of
# freebsd/deps/<name>-<version>/. curl and the libraries it needs
# ("bundle" in deps.conf) are the ones of --with-curl=bundled instead: the
# release files of freebsd/curl.conf and freebsd/curl-deps.conf (tools/curl-sources.sh),
# built by freebsd/curl/build-libcurl.sh; the curl program and libcurl.so of the
# same build go to a stage, for the package curl (the line "program curl", see
# build_curl_program). All: only static libraries, -fPIC, into
# AZ_PREFIX (default /usr/local/az), in AZ_WORK/deps (default
# /var/tmp/az-work/deps); the licences go to LICENSES/. Results go to
# deps-results/ (summary.txt, one log per library, VERSIONS, also installed as
# share/doc/az-libs/VERSIONS).
#
# Compiler flags as on the servers: CPUTYPE and CFLAGS of /etc/make.conf (such as
# CPUTYPE?=x86-64-v3 and CFLAGS=-O3 -pipe) with -fstack-protector-strong and
# -fno-strict-aliasing, and -fPIC. AZ_CPUTYPE and AZ_CFLAGS (the inputs of the
# workflow az.yml) win over make.conf (MAKE_CONF, default /etc/make.conf);
# without either: x86-64-v3 and -O3 -pipe. The build runs what it compiles
# (configure tests, the data tools of ICU), so it stops at once on a CPU that
# cannot run code of that level; PHP built against the bundle needs it too.
#
# Exit status: 0 everything built, 1 a library failed (the others are still
# built where they can be) or this CPU cannot run the level, 2 usage.

set -u
top="$(pwd)"
conf="$top/freebsd/deps.conf"
P="${AZ_PREFIX:-/usr/local/az}"
work="${AZ_WORK:-/var/tmp/az-work}/deps"
res="$top/deps-results"
dist="$top/dist"
ports="${PORTSDIR:-$work/ports}"
ncpu="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
major="$(uname -r | cut -d. -f1)"

if [ "${1:-}" = "--tools" ]; then
    # Build tools only; none of their libraries is linked into the bundle (the
    # compiler does not search /usr/local, pkg-config only the bundle and base).
    tools="git cmake ninja meson python3 gmake nasm perl5 pkgconf lzip bison autoconf automake libtool gettext-tools m4 gperf"
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
cputype="${AZ_CPUTYPE:-$(mc_get CPUTYPE)}"
cputype="${cputype:-x86-64-v3}"
opt="${AZ_CFLAGS:-$(mc_get CFLAGS)}"
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
# LTO (x264, as its port) puts LLVM bitcode into static archives: their index
# needs the ar of LLVM, taken by name when ar of the base system is another one.
unset AR RANLIB NM
if ! ar --version 2>/dev/null | grep -q LLVM && command -v llvm-ar >/dev/null 2>&1; then
    export AR=llvm-ar RANLIB=llvm-ranlib NM=llvm-nm
fi

ports_commit="$(awk '$1 == "ports" { print $2 }' "$conf")"
libs_all="$(awk '$1 == "lib" { print $2 }' "$conf")"
port_of() { awk -v n="$1" '$1 == "lib" && $2 == n { print $3 }' "$conf"; }
# take_of <name>: "version release-file SHA-256 source-dir" of its take line, if any
take_of() { awk -v n="$1" '$1 == "take" && $2 == n { print $3, $4, $5, $6 }' "$conf"; }

# A sparse checkout of freebsd-ports at the commit of deps.conf: the framework
# (Mk, Templates, Keywords) and the ports of deps.conf, with what they include
# (devel/gettext; multimedia/x264, the master port of libx264; lang/perl5.* and
# lang/python3* for the version files that USES=perl5 and USES=python read).
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
            /multimedia/x264/ '/lang/perl5*/' '/lang/python3*/' &&
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
    cmake -S "$src" -B "$src/_az" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$P" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_PREFIX_PATH="$P" \
        -DCMAKE_IGNORE_PREFIX_PATH=/usr/local -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_C_FLAGS="$CFLAGS" -DCMAKE_CXX_FLAGS="$CXXFLAGS" "$@" &&
        cmake --build "$src/_az" -j "$ncpu" && cmake --install "$src/_az"
}
# meson as USES=meson of the ports (release, the optimization of CFLAGS), static
# and position independent
ms() {
    src="$1"; shift
    (cd "$src" && meson setup _az --prefix="$P" --libdir=lib --buildtype=release -Doptimization=plain \
        --default-library=static -Db_staticpic=true --wrap-mode=nodownload "$@" &&
        ninja -C _az -j "$ncpu" && ninja -C _az install)
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
# For ImageMagick and FFmpeg:
b_expat() { at "$1" --without-docbook --without-examples --without-tests --without-xmlwf; }
# fontconfig with the paths of the port, so that it reads the configuration, fonts
# and cache of the system; installed through a stage directory (nothing into
# /usr/local outside the tree)
b_fontconfig() {
    st="$work/stage-fontconfig"
    rm -rf "$st"
    (cd "$1" && meson setup _az --prefix="$P" --libdir=lib --sysconfdir=/usr/local/etc --localstatedir=/var \
        --buildtype=release -Doptimization=plain --default-library=static -Db_staticpic=true \
        --wrap-mode=nodownload -Ddoc=disabled -Dtests=disabled -Dtools=disabled -Dnls=disabled \
        -Dcache-build=disabled -Dcache-dir=/var/db/fontconfig -Ddefault-fonts-dirs=/usr/local/share/fonts \
        -Dadditional-fonts-dirs=/usr/local/lib/X11/fonts -Dtemplate-dir=/usr/local/etc/fonts/conf.avail \
        -Dxml-dir=/usr/local/etc/fonts &&
        ninja -C _az -j "$ncpu" && DESTDIR="$st" ninja -C _az install) &&
        cp -R "$st$P/." "$P/"
}
# lcms2 as the port (fast float and threaded plugins), without its tools
b_lcms2() { at "$1" --with-fastfloat --with-threaded --without-jpeg --without-tiff; }
# x264 as the port (options ASM, LTO and OPTIMIZED_CFLAGS on), the library only
b_x264() { ms "$1" -Dcli=false -Dasm=enabled -Db_lto=true; }
# dav1d as the port, without its tools, tests and examples
b_dav1d() { ms "$1" -Denable_tools=false -Denable_tests=false -Denable_examples=false; }
# the HEVC decoder of libheif (HEIC), no encoder, no tools
b_libde265() {
    cm "$1" -DENABLE_ENCODER=OFF -DENABLE_DECODER=OFF -DENABLE_SDL=OFF -DENABLE_INTERNAL_DEVELOPMENT_TOOLS=OFF
}
# libheif: reading HEIC (libde265) and AVIF (dav1d), built in (no plugins); no
# encoders, JPEG 2000, VVC or uncompressed codecs, no tools
b_libheif() {
    cm "$1" -DBUILD_TESTING=OFF -DCMAKE_COMPILE_WARNING_AS_ERROR=OFF -DCMAKE_DISABLE_FIND_PACKAGE_Doxygen=ON \
        -DBUILD_DOCUMENTATION=OFF -DWITH_EXAMPLES=OFF -DWITH_GDK_PIXBUF=OFF -DENABLE_PLUGIN_LOADING=OFF \
        -DWITH_LIBSHARPYUV=OFF -DWITH_FUZZERS=OFF -DBUILD_DEVELOPMENT_TOOLS=OFF \
        -DWITH_LIBDE265=ON -DWITH_LIBDE265_PLUGIN=OFF -DWITH_DAV1D=ON -DWITH_DAV1D_PLUGIN=OFF \
        -DWITH_AOM_DECODER=OFF -DWITH_AOM_ENCODER=OFF -DWITH_X265=OFF -DWITH_X264=OFF -DWITH_RAV1E=OFF \
        -DWITH_SvtEnc=OFF -DWITH_FFMPEG_DECODER=OFF -DWITH_OpenH264_DECODER=OFF -DWITH_OpenH264_ENCODER=OFF \
        -DWITH_JPEG_DECODER=OFF -DWITH_JPEG_ENCODER=OFF -DWITH_OpenJPEG_DECODER=OFF -DWITH_OpenJPEG_ENCODER=OFF \
        -DWITH_OPENJPH_DECODER=OFF -DWITH_OPENJPH_ENCODER=OFF -DWITH_KVAZAAR=OFF -DWITH_UVG266=OFF \
        -DWITH_VVDEC=OFF -DWITH_VVENC=OFF -DWITH_UNCOMPRESSED_CODEC=OFF
}

# lic <name> <source>: the licence files of a library into LICENSES/ (libpng
# 1.6.59 has a directory LICENSES too)
lic() {
    mkdir -p "$P/LICENSES"
    for f in "$2"/COPYING* "$2"/LICENSE* "$2"/LICENCE* "$2"/PATENTS* "$2"/COPYRIGHT*; do
        [ -e "$f" ] && cp -R "$f" "$P/LICENSES/$1-${f##*/}"
    done
    return 0
}

# take_args <name> <port>: the make arguments that build the release of the take
# line of <name> instead of the port's distfiles, after fetching the file into
# DISTDIR and checking its SHA-256; nothing when there is no take line. The
# version goes to $take_ver.
take_args() {
    take_ver=""
    t="$(take_of "$1")"
    [ -n "$t" ] || return 0
    set -- $t "$2"
    take_ver="$1"
    # several addresses of the same file, separated by commas: the first one that works
    tf="${2%%,*}"; tf="${tf##*/}"
    mkdir -p "$work/distfiles"
    if [ ! -f "$work/distfiles/$tf" ] || [ "$(sha256 -q "$work/distfiles/$tf")" != "$3" ]; then
        rm -f "$work/distfiles/$tf"
        for u in $(echo "$2" | tr ',' ' '); do
            fetch -q -T 60 -o "$work/distfiles/$tf" "$u" && break
            echo "== fetch $u failed" >&2
            rm -f "$work/distfiles/$tf"
        done
        [ -f "$work/distfiles/$tf" ] || return 1
    fi
    if [ "$(sha256 -q "$work/distfiles/$tf")" != "$3" ]; then
        echo "== $tf: SHA-256 $(sha256 -q "$work/distfiles/$tf"), not $3 as in deps.conf" >&2
        return 1
    fi
    printf 'TIMESTAMP = %s\nSHA256 (%s) = %s\nSIZE (%s) = %s\n' "$(date +%s)" "$tf" "$3" "$tf" \
        "$(stat -f %z "$work/distfiles/$tf")" > "$work/distinfo-take-$n"
    wd="$(pmake "$5" -V WRKDIR)"
    pd="$top/freebsd/deps/$n-$take_ver"
    printf '%s\n' "DISTFILES=$tf" "PATCHFILES=" "DISTINFO_FILE=$work/distinfo-take-$n" "WRKSRC=$wd/$4"
    if [ -d "$pd" ]; then printf '%s\n' "PATCHDIR=$pd"; fi
}

# One library: fetch, check, extract and patch with the ports framework, then build.
build_one() {
    n="$1"
    port="$(port_of "$n")"
    log="$res/$n.log"
    start=$(date +%s)
    if [ "$port" = bundle ]; then build_bundle "$n"; return; fi
    targs="$(take_args "$n" "$port" 2>"$res/$n.take")"
    trc=$?
    take_of "$n" | grep -q . && take_ver="$(take_of "$n" | awk '{ print $1 }')" || take_ver=""
    (
        if [ "$trc" != 0 ]; then cat "$res/$n.take"; echo "== $n: the release of the take line could not be had"; exit 1; fi
        if [ -n "$take_ver" ]; then
            echo "== $n: $port at $ports_commit with the release $take_ver of the take line in deps.conf:"
            printf '   %s\n' $targs
        else
            echo "== $n: $port at $ports_commit"
        fi
        # shellcheck disable=SC2086
        pmake "$port" $targs clean >/dev/null 2>&1
        # shellcheck disable=SC2086
        pmake "$port" $targs patch || { echo "make patch failed"; exit 1; }
        # shellcheck disable=SC2086
        src="$(pmake "$port" $targs -V WRKSRC)"
        echo "== source: $src"
        : > "$work/stamp-$n"
        "b_$n" "$src" || exit 1
        lic "$n" "$src"
        # every library leaves a static archive of its own in lib/ (mozjpeg did not)
        if [ -z "$(find "$P/lib" -maxdepth 1 -name '*.a' -newer "$work/stamp-$n" | head -n 1)" ]; then
            echo "== no new static library of $n in $P/lib"; exit 1
        fi
    ) > "$log" 2>&1
    rc=$?
    ver="$(pmake "$port" -V PKGVERSION 2>/dev/null)"
    pkgname="$(pmake "$port" -V PKGNAME 2>/dev/null)"
    if [ -n "$take_ver" ]; then
        # the name pkg audit knows, with the version taken and the epoch of the port
        epoch="$(pmake "$port" -V PORTEPOCH 2>/dev/null)"
        case "$epoch" in ""|0) epoch="" ;; *) epoch=",$epoch" ;; esac
        pkgname="${pkgname%-*}-$take_ver$epoch"
        ver="$take_ver (port: $ver)"
    fi
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
            curl) LIBICONV_PREFIX="$P" OBJDIR="$work/obj-curl" sh "$b" --curl "$work/curl-src/libcurl" "$P" "$P" ;;
            libidn2) LIBICONV_PREFIX="$P" OBJDIR="$work/obj-curl" sh "$b" --lib libidn2 "$work/curl-src/deps/libidn2" "$P" ;;
            *) OBJDIR="$work/obj-curl" sh "$b" --lib "$n" "$work/curl-src/deps/$n" "$P" ;;
        esac || exit 1
        if [ -z "$(find "$P/lib" -maxdepth 1 -name '*.a' -newer "$work/stamp-$n" | head -n 1)" ]; then
            echo "== no new static library of $n in $P/lib"; exit 1
        fi
        if [ "$n" = curl ]; then lic curl "$work/curl-src/libcurl"; else lic "$n" "$work/curl-src/deps/$n"; fi
    ) > "$log" 2>&1
    rc=$?
    ver="$(bundle_ver "$n")"
    # the names of the ports for pkg audit: libnghttp2, and the epoch of archivers/brotli
    # (PORTEPOCH 1: VuXML has "brotli < 1.2.1,1", and 1.2.1 without it would be older)
    case "$n" in nghttp2) pkgname="libnghttp2-$ver" ;; brotli) pkgname="brotli-$ver,1" ;; *) pkgname="$n-$ver" ;; esac
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
        printf '%s\n' '#!/bin/sh' "# curl-config of $P: --libs gives the static link line." \
            'case "$1" in' "    --libs|--static-libs) echo \"$libs\" ;;" "    *) exec \"$P/bin/curl-config.orig\" \"\$@\" ;;" \
            'esac' > "$P/bin/curl-config"
        chmod +x "$P/bin/curl-config"
    fi
    # pkg-config for PHP builds against the tree (config-check.sh writes PKG_CONFIG
    # with it): the tree first (with ImageMagick 7 for imagick), then the base system
    # and the packages (for what the tree has not, such as GraphicsMagick), and
    # static link lines.
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
        # x264 is for FFmpeg only (a PIE program, where its assembly may be as it is)
        case "${a##*/}" in libx264.a) echo "libx264.a: not tried (FFmpeg only)" >> "$res/pic-notes.txt"; continue ;; esac
        if ! cc -shared -o "$work/pic-test.so" -Wl,--whole-archive "$a" -Wl,--no-whole-archive \
                -Wl,--unresolved-symbols=ignore-all > "$work/pic-test.log" 2>&1; then
            if grep -q -i 'relocation' "$work/pic-test.log"; then
                echo "${a##*/}: not position independent: $(grep -m 1 -i relocation "$work/pic-test.log")" >> "$res/pic.txt"
            else
                echo "${a##*/}: link test failed: $(grep -m 1 -i error "$work/pic-test.log")" >> "$res/pic-notes.txt"
            fi
        fi
    done
    # Nothing may point to /usr/local outside the tree (the libraries of pkg); the
    # configuration and fonts of the system that fontconfig reads are meant.
    grep -rn '/usr/local/' "$P/lib/pkgconfig" "$P/bin" 2>/dev/null | grep -v "^$P/bin/pkg-config:" | sed "s#$P##g" |
        sed -e 's#/usr/local/etc/fonts##g' -e 's#/usr/local/share/fonts##g' -e 's#/usr/local/lib/X11/fonts##g' \
            -e 's#sysconfdir=/usr/local/etc$##' |
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
        echo "az libraries for FreeBSD $major (amd64, $cputype), built $(date '+%Y-%m-%d %H:%M %Z') on $(uname -sr)"
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
            t="$(take_of "$n")"
            if [ -n "$t" ]; then
                # shellcheck disable=SC2086
                set -- $t
                echo "    ${2##*/} sha256 $3 (upstream release $1, ahead of the port: take line of deps.conf)"
                if [ -d "$top/freebsd/deps/$n-$1" ]; then
                    np="$(ls "$top/freebsd/deps/$n-$1" | grep -c '^patch-')"
                    [ "$np" -gt 0 ] && echo "    $np patches of the port, brought up to $1 (freebsd/deps/$n-$1)"
                else
                    np="$(ls "$ports/$port/files" 2>/dev/null | grep -c '^patch-')"
                    [ "$np" -gt 0 ] && echo "    $np patches of the port"
                fi
                continue
            fi
            sed -n 's/^SHA256 (\(.*\)) = \(.*\)/    \1 sha256 \2/p' "$ports/$port/distinfo"
            np="$(ls "$ports/$port/files" 2>/dev/null | grep -c '^patch-')"
            [ "$np" -gt 0 ] && echo "    $np patches of the port"
        done < "$res/built.txt"
        echo
        echo "The package curl (tools/build-az.sh): bin/curl and lib/libcurl.so.4 of /usr/local, of the bundled"
        echo "curl above (the same options and libraries), libcurl.a in $P for the builds of PHP."
    } > "$res/VERSIONS"
    mkdir -p "$P/share/doc/az-libs"
    cp "$res/VERSIONS" "$P/share/doc/az-libs/VERSIONS"
}

# The curl program and libcurl.so (deps.conf: "program curl"), for the package curl
# of tools/build-az.sh, which takes the place of the curl of the ports (git and the
# other packages that link libcurl.so get this one): into the stage AZ_STAGE/curl
# (default AZ_WORK/stage/curl) as files of /usr/local: bin/curl, the program of the
# build of libcurl above (freebsd/curl/build-libcurl.sh configured the whole tree
# in $work/obj-curl/curl and built lib/), static, PIE, RELRO, BIND_NOW, stripped;
# lib/libcurl.so.4 of the libcurl.a above (curl and its libraries, only curl_*
# global) with the static OpenSSL of the tree inside, its symbols hidden, so that it
# needs only libz and libthr of the base system; include/curl/, libcurl.pc,
# curl-config (--static-libs: the static libcurl of /usr/local/az, for PHP),
# libcurl.m4, the licence.
build_curl_program() {
    o="$work/obj-curl/curl"
    cs="$work/curl-src/libcurl"
    r="${AZ_STAGE:-${AZ_WORK:-/var/tmp/az-work}/stage}/curl/usr/local"
    log="$res/curl-program.log"
    start=$(date +%s)
    cv="$(bundle_ver curl)"
    (
        [ -f "$o/src/Makefile" ] || { echo "== no build of curl in $o (build curl first)"; exit 1; }
        rm -rf "${r%/usr/local}"
        mkdir -p "$r/bin" "$r/lib" "$r/include" "$r/libdata/pkgconfig" "$r/share/aclocal" "$r/share/licenses/curl" || exit 1
        rm -f "$o/src/curl"
        cd "$o/src" && gmake -j"$ncpu" ACLOCAL=: AUTOCONF=: AUTOMAKE=: AUTOHEADER=: MAKEINFO=: \
            LDFLAGS="-L$P/lib -pie -Wl,-z,relro,-z,now" curl || exit 1
        install -s -m 755 "$o/src/curl" "$r/bin/curl" || exit 1
        # the name of libcurl.so of curl's libtool numbers (lib/Makefile.soname):
        # libcurl.so.<change - del>.<del>.<add>, as the port has it (libcurl.so.4.8.0)
        eval "$(sed -n -E 's/^(VERSIONCHANGE|VERSIONADD|VERSIONDEL)=([0-9]+).*/\1=\2/p' "$cs/lib/Makefile.soname")"
        so="libcurl.so.$((VERSIONCHANGE - VERSIONDEL))"
        full="$so.$VERSIONDEL.$VERSIONADD"
        echo "== $full of $P/lib/libcurl.a"
        cc -shared -o "$r/lib/$full" -Wl,-soname,"$so" -Wl,--whole-archive "$P/lib/libcurl.a" -Wl,--no-whole-archive \
            "$P/lib/libssl.a" "$P/lib/libcrypto.a" "$P/lib/libiconv.a" -lz -lm -lpthread \
            -Wl,--exclude-libs,libssl.a:libcrypto.a:libiconv.a \
            -Wl,-z,relro,-z,now -Wl,--no-undefined || exit 1
        strip --strip-unneeded "$r/lib/$full" || exit 1
        ln -sf "$full" "$r/lib/$so" && ln -sf "$full" "$r/lib/libcurl.so" || exit 1
        bad="$(nm -D --defined-only "$r/lib/$full" | awk 'NF >= 3 && $3 !~ /^(curl_|_init$|_fini$|_edata$|_end$|__bss_start$)/ { print $3 }' | head -n 5 | tr '\n' ' ')"
        [ -z "$bad" ] || { echo "== $full exports more than curl_*: $bad"; exit 1; }
        cp -R "$P/include/curl" "$r/include/" || exit 1
        sed -e 's|^prefix=.*|prefix=/usr/local|' -e 's|^Libs:.*|Libs: -L${libdir} -lcurl|' \
            -e '/^Libs.private:/d' -e '/^Requires/d' "$P/lib/pkgconfig/libcurl.pc" > "$r/libdata/pkgconfig/libcurl.pc" || exit 1
        printf '%s\n' '#!/bin/sh' \
            '# curl-config of libcurl in /usr/local (the package curl of https://github.com/azsupport/php-src:' \
            '# libcurl.so, the bundled curl of the fork); --static-libs: the static libcurl of /usr/local/az.' \
            'case "${1:-}" in' \
            '    --libs) echo "-L/usr/local/lib -lcurl" ;;' \
            '    --cflags) echo "-I/usr/local/include" ;;' \
            '    --prefix|--exec-prefix) echo /usr/local ;;' \
            "    --static-libs) exec $P/bin/curl-config --static-libs ;;" \
            "    *) exec $P/bin/curl-config.orig \"\$@\" ;;" \
            'esac' > "$r/bin/curl-config" && chmod 755 "$r/bin/curl-config" || exit 1
        cp "$cs/docs/libcurl/libcurl.m4" "$r/share/aclocal/" && cp "$cs/COPYING" "$r/share/licenses/curl/COPYING" || exit 1
        # the program and libcurl.so as they are, with the libraries of the base system only
        LD_LIBRARY_PATH="$r/lib" "$r/bin/curl" --version > "$res/curl-version.txt" 2>&1 || exit 1
    ) > "$log" 2>&1
    rc=$?
    : > "$res/curl-bins.txt"
    if [ "$rc" = 0 ]; then
        for f in "$r/bin/curl" "$r/lib/$(cd "$r/lib" && ls libcurl.so.*.*.* | head -n 1)"; do
            b="${f##*/}"
            type="$(readelf -h "$f" | awk '/Type:/ { print $2 }')"
            relro="$(readelf -l "$f" | grep -c GNU_RELRO)"
            now="$(readelf -d "$f" | grep -c -E 'BIND_NOW|FLAGS_1.*NOW')"
            libs="$(ldd "$f" 2>/dev/null | awk 'NF > 2 && $2 == "=>" { print $3 }' | tr '\n' ' ' | sed 's/ *$//')"
            printf '%s: %s KB, ELF type %s, RELRO %s, BIND_NOW %s; libraries: %s\n' "$b" \
                "$(du -k "$f" | cut -f1)" "$type" "$relro" "$now" "$libs" >> "$res/curl-bins.txt"
            case "$libs" in *"/usr/local/"*) echo "$b: links a library of /usr/local" >> "$res/bins-bad.txt" ;; esac
            [ "$type" = DYN ] || echo "$b: not position independent (ELF type $type)" >> "$res/bins-bad.txt"
            [ "$relro" -gt 0 ] || echo "$b: no RELRO" >> "$res/bins-bad.txt"
            [ "$now" -gt 0 ] || echo "$b: no BIND_NOW" >> "$res/bins-bad.txt"
        done
        printf '%-14s OK    %-22s %-24s %4ss\n' "curl program" "$cv" "bin/curl, libcurl.so" "$(( $(date +%s) - start ))" >> "$res/summary.txt"
    else
        printf '%-14s FAIL  %-22s %-24s %4ss (deps-results/curl-program.log)\n' "curl program" "$cv" "bin/curl, libcurl.so" "$(( $(date +%s) - start ))" >> "$res/summary.txt"
        tail -n 25 "$log" > "$res/curl-program.tail"
    fi
    say "curl program: $(tail -n 1 "$res/summary.txt" | awk '{ print $3 }')"
    return "$rc"
}

mkdir -p "$res" "$work"
cpu_model="$(sysctl -n hw.model 2>/dev/null)"
if [ $# -eq 0 ]; then
    set -- $libs_all
    # a full build starts from an empty tree; the PHP builds of a server in it
    # (phpXY directories, bin/phpXY) are never removed
    if [ -n "$(ls -d "$P"/php* "$P"/bin/php* "$P"/etc/php* 2>/dev/null | head -n 1)" ]; then
        echo "build-deps: $P has PHP builds in it; build into an empty directory (AZ_PREFIX=...)" >&2
        exit 2
    fi
    rm -rf "$P"
    rm -f "$res"/*.tail "$res/bins-bad.txt"
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
    echo "build-deps: this CPU ${why:-cannot tell the features of} -march=$cputype; build on a CPU that has them, or set AZ_CPUTYPE to a lower level" >&2
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
# the curl program first: it links with the .la files of curl's libraries, which finish removes
if grep -q '^program curl' "$conf" && grep -q '^curl ' "$res/built.txt" 2>/dev/null; then
    build_curl_program || rc=1
fi
finish
manifest
# Known vulnerabilities of these versions (FreeBSD VuXML), for the report.
pkg audit -F -q $(awk '{ print $2 }' "$res/built.txt") > "$res/audit.txt" 2>&1 || true
if [ "$rc" = 0 ] && [ ! -s "$res/pic.txt" ] && [ ! -s "$res/links.txt" ] && [ ! -s "$res/bins-bad.txt" ]; then
    echo "installed: $P ($(du -sk "$P" | cut -f1) KB)" >> "$res/summary.txt"
else
    rc=1
fi
exit "$rc"
