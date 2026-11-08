#!/bin/sh
# build-deps.sh - build the libraries of /usr/local/az from the FreeBSD ports
# listed in freebsd/deps.conf, as the kinds of their lib lines say, into two trees:
# static and position independent into the static tree
# /usr/local/az/static (lib/, include/, bin/), shared into the shared tree
# /usr/local/az (lib/*.so with their SONAME and the run path
# /usr/local/az/lib, include/, lib/pkgconfig/, bin/pkg-config without
# --static, the *-config scripts; no ldconfig), for the PHP modules of pkg mode;
# and the curl program (bin/curl). The shared builds take the patched source of
# the static one (a copy of the work directory of the port, or out of the tree of
# the bundled curl), the same options, the OpenSSL of the base system and the
# other libraries of the shared tree; nothing of the static tree (its headers of
# the OpenSSL of the port, its archives, which the linker would take as they are
# or leave for a .so of the same name) is seen by them. VERSIONS and LICENSES/
# are one for both, at the root. PHP built against the static tree (php, php-fpm, php-cgi,
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
# built by freebsd/curl/build-libcurl.sh, with only what PHP needs; the curl
# program and libcurl.so of the package curl are a build of their own, with the
# options of the port ftp/curl, into a stage (the line "program curl", see
# build_curl_program). The static libraries: -fPIC, into AZ_PREFIX/static
# (AZ_PREFIX: default /usr/local/az); the shared ones into AZ_PREFIX; in
# AZ_WORK/deps (default /var/tmp/az-work/deps); the licences go to
# AZ_PREFIX/LICENSES/. Results go to deps-results/ (summary.txt with the status of
# the static and of the shared build of every library, one log per library,
# shared.txt and shared-bad.txt of the checks of the shared tree, see finish_so;
# VERSIONS, also installed as AZ_PREFIX/share/doc/az/VERSIONS).
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
# A: the root of the package az (VERSIONS, LICENSES/); P: the static tree,
# S: the shared tree (see the head comment)
A="${AZ_PREFIX:-/usr/local/az}"
P="$A/static"
S="$A"
work="${AZ_WORK:-/var/tmp/az-work}/deps"
res="$top/deps-results"
dist="$top/dist"
ports="${PORTSDIR:-$work/ports}"
ncpu="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
major="$(uname -r | cut -d. -f1)"

if [ "${1:-}" = "--tools" ]; then
    # Build tools only; none of their libraries is linked into the bundle (the
    # compiler does not search /usr/local, pkg-config only the bundle and base).
    tools="git cmake ninja meson python3 gmake nasm perl5 pkgconf lzip bison autoconf automake libtool gettext-tools m4 gperf tcl86"
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
# the PATH without the static tree, for the shared builds (so_env)
path0="$PATH"
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
# has_kind <name> <static|shared>: the kinds of its lib line name it
has_kind() { awk -v n="$1" -v k="$2" '$1 == "lib" && $2 == n { m = split($4, t, ","); for (i = 1; i <= m; i++) if (t[i] == k) f = 1 } END { exit !f }' "$conf"; }
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
# JPEG_PORT as in make.conf of the servers: the ports with USES=jpeg (gd, ImageMagick) take mozjpeg
pmake() {
    p="$1"; shift
    make -C "$ports/$p" BATCH=yes NO_DEPENDS=yes DISABLE_VULNERABILITIES=yes JPEG_PORT=graphics/mozjpeg \
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

# The shared builds (s_<name>, into S): the patched source of the static build, a
# copy of the work directory (or out of the tree, the libraries of the bundled
# curl), with the options of b_<name>, so that the headers and the behaviour are
# the same; the OpenSSL of the base system and the other libraries of S. so_env
# (in the subshell of the build) leaves nothing of the static tree P to be seen:
# no -I or -L of it, not its pkgconfig, not its bin/. Every library and what links
# it gets the run path S/lib (no ldconfig), RELRO and BIND_NOW.
so_env() {
    export CPPFLAGS="-I$S/include"
    export LDFLAGS="-L$S/lib -Wl,-rpath,$S/lib -Wl,-z,relro,-z,now"
    export PKG_CONFIG=pkgconf
    export PKG_CONFIG_LIBDIR="$S/lib/pkgconfig:/usr/libdata/pkgconfig"
    export PATH="$S/bin:$path0"
}
at_so() {
    src="$1"; shift
    fix_guess "$src"
    (cd "$src" && ./configure --prefix="$S" --libdir="$S/lib" --includedir="$S/include" \
        --disable-static --enable-shared --with-pic "$@" && gmake -j"$ncpu" && gmake install)
}
# cm_so_in <build dir> <source> <options>: CMake writes the run path itself
# (CMAKE_INSTALL_RPATH); one in LDFLAGS it would try to rewrite at the install
cm_so_in() {
    bd="$1" src="$2"; shift 2
    LDFLAGS="-L$S/lib -Wl,-z,relro,-z,now" cmake -S "$src" -B "$bd" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$S" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_PREFIX_PATH="$S" \
        -DCMAKE_IGNORE_PREFIX_PATH="/usr/local;$P" -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_INSTALL_RPATH="$S/lib" -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_C_FLAGS="$CFLAGS" -DCMAKE_CXX_FLAGS="$CXXFLAGS" "$@" &&
        cmake --build "$bd" -j "$ncpu" && cmake --install "$bd"
}
cm_so() { s="$1"; shift; cm_so_in "$s/_az" "$s" "$@"; }
ms_so() {
    src="$1"; shift
    (cd "$src" && meson setup _az --prefix="$S" --libdir=lib --buildtype=release -Doptimization=plain \
        --default-library=shared --wrap-mode=nodownload "$@" &&
        ninja -C _az -j "$ncpu" && ninja -C _az install)
}
# The libraries of the bundled curl: out of the tree of tools/curl-sources.sh (it
# stays as build-libcurl.sh builds it), in $work/obj-so/<name>, with the options
# of build-libcurl.sh; the make variables of notools there keep the autotools
# from running.
so_notools="ACLOCAL=: AUTOCONF=: AUTOMAKE=: AUTOHEADER=: MAKEINFO=:"
so_conf() {
    o="$work/obj-so/$1" s="$2"; shift 2
    rm -rf "$o" && mkdir -p "$o" &&
        (cd "$o" && LIBS= "$s/configure" --prefix="$S" --libdir="$S/lib" --includedir="$S/include" \
            --disable-static --enable-shared --with-pic --disable-dependency-tracking "$@")
}
# shellcheck disable=SC2086
so_mk() { d="$1"; shift; (cd "$work/obj-so/$d" && gmake $so_notools "$@"); }

s_libiconv() {
    fix_guess "$1"
    (cd "$1" && ./configure --prefix="$S" --libdir="$S/lib" --disable-static --enable-shared \
        --disable-nls --enable-extra-encodings am_cv_func_iconv=no && gmake && gmake install) &&
        rm -f "$S/lib/preloadable_libiconv.so"
}
s_c_ares() {
    so_conf c-ares "$1" --disable-tests && so_mk c-ares -j"$ncpu" -C src/lib && so_mk c-ares -C src/lib install &&
        so_mk c-ares -C include install && so_mk c-ares install-pkgconfigDATA
}
s_nghttp2() { so_conf nghttp2 "$1" --enable-lib-only && so_mk nghttp2 -j"$ncpu" -C lib && so_mk nghttp2 -C lib install; }
s_libidn2() {
    so_conf libidn2 "$1" --disable-nls --with-included-libunistring --with-libiconv-prefix="$S" ac_cv_prog_RONN=true &&
        so_mk libidn2 -j"$ncpu" -C gl && so_mk libidn2 -j"$ncpu" -C unistring && so_mk libidn2 -j"$ncpu" -C lib &&
        so_mk libidn2 -C lib install && so_mk libidn2 install-pkgconfigDATA
}
# brotli and zstd with their CMake (build-libcurl.sh compiles them by hand, static)
s_brotli() {
    rm -rf "$work/obj-so/brotli"
    cm_so_in "$work/obj-so/brotli" "$1" -DBROTLI_BUILD_TOOLS=OFF -DBROTLI_DISABLE_TESTS=ON
}
s_zstd() {
    # legacy formats from v0.5 on, as the static one; multithreaded, as its shared library is
    rm -rf "$work/obj-so/zstd"
    cm_so_in "$work/obj-so/zstd" "$1/build/cmake" -DZSTD_BUILD_SHARED=ON -DZSTD_BUILD_STATIC=OFF \
        -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_TESTS=OFF -DZSTD_BUILD_CONTRIB=OFF \
        -DZSTD_LEGACY_SUPPORT=ON -DZSTD_LEGACY_LEVEL=5 -DZSTD_MULTITHREAD_SUPPORT=ON
}
s_libpsl() {
    # as lib_libpsl of build-libcurl.sh (the built-in list only); HAVE_VISIBILITY gives
    # PSL_API the visibility default (include/libpsl.h.in), the rest stays hidden
    s="$1" o="$work/obj-so/libpsl"
    rm -rf "$o" && mkdir -p "$o/include" "$S/lib/pkgconfig" "$S/include" || return 1
    v="$(tr -d ' \n' < "$s/version.txt")"
    IFS=. read -r va vb vc <<EOF
$v
EOF
    sed -e "s/@LIBPSL_VERSION@/$v/" -e "s/@LIBPSL_VERSION_MAJOR@/$va/" -e "s/@LIBPSL_VERSION_MINOR@/$vb/" \
        -e "s/@LIBPSL_VERSION_PATCH@/$vc/" -e "s/@LIBPSL_VERSION_NUMBER@/$(printf '0x%02x%02x%02x' "$va" "$vb" "$vc")/" \
        -e "s/@COPYRIGHT_YEAR@/$(date +%Y)/" "$s/include/libpsl.h.in" > "$o/include/libpsl.h" &&
        printf '%s\n' '#define ENABLE_BUILTIN 1' '#define HAVE_NL_LANGINFO 1' '#define HAVE_VISIBILITY 1' \
            "#define PACKAGE_VERSION \"$v\"" > "$o/config.h" || return 1
    for f in psl lookup_string_in_fixed_set; do
        # shellcheck disable=SC2086
        cc $CFLAGS -fvisibility=hidden -DHAVE_CONFIG_H -DBUILDING_PSL "-I$o" "-I$o/include" -c "$s/src/$f.c" -o "$o/$f.o" || return 1
    done
    # shellcheck disable=SC2086
    cc -shared -o "$S/lib/libpsl.so.5" -Wl,-soname,libpsl.so.5 "$o/psl.o" "$o/lookup_string_in_fixed_set.o" $LDFLAGS &&
        ln -sf libpsl.so.5 "$S/lib/libpsl.so" && cp "$o/include/libpsl.h" "$S/include/" &&
        printf '%s\n' "prefix=$S" 'libdir=${prefix}/lib' 'includedir=${prefix}/include' '' 'Name: libpsl' \
            'Description: Public Suffix List C library' "Version: $v" 'Libs: -L${libdir} -lpsl' \
            'Cflags: -I${includedir}' > "$S/lib/pkgconfig/libpsl.pc"
}
s_curl() {
    # libcurl.so.4 with the features of the static libcurl of PHP (build-libcurl.sh
    # --features), the OpenSSL of the base system; no curl program
    feats="$(sh "$top/freebsd/curl/build-libcurl.sh" --features)" || return 1
    o="$work/obj-so/curl"
    rm -rf "$o" && mkdir -p "$o" || return 1
    # shellcheck disable=SC2086
    (cd "$o" && LIBS= ac_cv_func_SSLv2_client_method=no "$1/configure" --prefix="$S" --libdir="$S/lib" \
        --includedir="$S/include" --enable-shared --disable-static --with-pic --disable-dependency-tracking \
        --with-openssl=/usr --enable-openssl-auto-load-config --with-ca-path=/etc/ssl/certs --without-ca-bundle \
        --enable-ares="$S" --disable-threaded-resolver \
        --with-nghttp2="$S" --with-brotli="$S" --with-zstd="$S" --with-libidn2="$S" --with-libpsl="$S" \
        $feats) &&
        so_mk curl -j"$ncpu" -C lib && so_mk curl -C lib install && so_mk curl -C include install &&
        so_mk curl install-pkgconfigDATA install-binSCRIPTS
}
s_lz4() {
    (cd "$1/lib" && gmake -j"$ncpu" liblz4 liblz4.pc PREFIX="$S" LIBDIR="$S/lib" BUILD_STATIC=no &&
        gmake install PREFIX="$S" LIBDIR="$S/lib" PKGCONFIGDIR="$S/lib/pkgconfig" BUILD_STATIC=no)
}
s_libxml2() { at_so "$1" --sysconfdir="$S/share" --without-python --with-iconv="$S" --with-zlib --without-icu --without-lzma --without-readline --without-history --with-http; }
s_icu() { at_so "$1" --with-data-packaging=library --disable-layoutex --disable-tests --disable-samples --disable-extras; }
s_oniguruma() { cm_so "$1" -DBUILD_TEST=OFF -DENABLE_POSIX_API=ON; }
s_libzip() {
    cm_so "$1" -DENABLE_OPENSSL=ON -DENABLE_GNUTLS=OFF -DENABLE_MBEDTLS=OFF -DENABLE_COMMONCRYPTO=OFF \
        -DENABLE_WINDOWS_CRYPTO=OFF -DENABLE_BZIP2=ON -DENABLE_LZMA=OFF -DENABLE_ZSTD=ON \
        -DBUILD_TOOLS=OFF -DBUILD_REGRESS=OFF -DBUILD_OSSFUZZ=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOC=OFF \
        -DOPENSSL_ROOT_DIR=/usr
}
s_png() { cm_so "$1" -DPNG_SHARED=ON -DPNG_STATIC=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_DEBUG_POSTFIX=""; }
s_mozjpeg() {
    cm_so "$1" -DENABLE_SHARED=ON -DENABLE_STATIC=OFF -DWITH_JPEG8=ON -DWITH_SIMD=ON -DREQUIRE_SIMD=OFF \
        -DWITH_ARITH_DEC=OFF -DWITH_ARITH_ENC=OFF -DWITH_12BIT=OFF -DWITH_JAVA=OFF -DWITH_JPEG7=OFF \
        -DWITH_TURBOJPEG=OFF -DPNG_SUPPORTED=OFF -DWITH_MEM_SRCDST=ON -DFORCE_INLINE=ON \
        -DCMAKE_INSTALL_LIBDIR="$S/lib" -DCMAKE_INSTALL_INCLUDEDIR="$S/include" \
        -DCMAKE_INSTALL_BINDIR="$S/bin" -DCMAKE_INSTALL_MANDIR="$S/share/man" \
        -DCMAKE_INSTALL_DOCDIR="$S/share/doc/mozjpeg"
}
s_webp() {
    at_so "$1" --enable-libwebpdecoder --enable-libwebpdemux --enable-libwebpmux --disable-gl --disable-sdl \
        --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-wic
}
s_freetype2() {
    cm_so "$1" -DFT_REQUIRE_ZLIB=ON -DFT_DISABLE_BZIP2=OFF -DFT_DISABLE_PNG=ON -DFT_DISABLE_HARFBUZZ=ON \
        -DFT_DISABLE_BROTLI=ON
}
s_gd() {
    (cd "$1" && autoreconf -fi) &&
        at_so "$1" --enable-gd-formats --with-zlib --with-png="$S" --with-jpeg="$S" --with-webp="$S" \
            --with-freetype="$S" --without-fontconfig --without-xpm --without-x --without-tiff \
            --without-avif --without-heif --without-raqm --without-liq --with-libiconv-prefix="$S"
}
s_libmcrypt() { at_so "$1"; }
s_libmemcached() {
    cm_so "$1" -DENABLE_SASL=OFF -DBUILD_TESTING=OFF -DBUILD_DOCS=OFF -DBUILD_DOCSONLY=OFF \
        -DENABLE_HASH_FNV64=ON -DENABLE_HASH_HSIEH=ON -DENABLE_HASH_MURMUR=ON -DENABLE_MEMASLAP=OFF
}
s_libsodium() { at_so "$1"; }
s_argon2() {
    # the shared library as the port security/libargon2 builds it (SO_LDFLAGS with the
    # soname libargon2.so.0), -march=$cputype as b_argon2
    (cd "$1" && gmake libargon2.so OPTTARGET="$cputype" SO_LDFLAGS="-shared -Wl,-soname=libargon2.so.0 $LDFLAGS" &&
        mkdir -p "$S/include" "$S/lib/pkgconfig" && cp include/argon2.h "$S/include/" &&
        install -m 755 libargon2.so "$S/lib/libargon2.so.0" && ln -sf libargon2.so.0 "$S/lib/libargon2.so" &&
        printf '%s\n' "prefix=$S" 'libdir=${prefix}/lib' 'includedir=${prefix}/include' '' \
            'Name: libargon2' 'Description: Argon2 password hashing' 'Version: 20190702' \
            'Libs: -L${libdir} -largon2' 'Libs.private: -lpthread' 'Cflags: -I${includedir}' > "$S/lib/pkgconfig/libargon2.pc")
}
# SHLIB_LIBS, the libraries that shlib/Makefile of readline links libreadline.so
# with, gets libncursesw of the base system (the curses of b_readline), so that
# libreadline.so names it itself and a module that links only -lreadline loads
s_readline() {
    fix_guess "$1"
    (cd "$1" && ./configure --prefix="$S" --libdir="$S/lib" --includedir="$S/include" \
        --disable-static --enable-shared --with-curses --enable-bracketed-paste-default &&
        gmake -j"$ncpu" SHLIB_LIBS=-lncursesw && gmake install SHLIB_LIBS=-lncursesw)
}
s_gettext() {
    at_so "$1" --disable-csharp --disable-java --disable-libasprintf --disable-threads --disable-openmp \
        --disable-acl --with-libiconv-prefix="$S" --without-emacs ac_cv_lib_rt_sched_yield=no
}
s_expat() { at_so "$1" --without-docbook --without-examples --without-tests --without-xmlwf; }
s_fontconfig() {
    st="$work/stage-fontconfig-so"
    rm -rf "$st"
    (cd "$1" && meson setup _az --prefix="$S" --libdir=lib --sysconfdir=/usr/local/etc --localstatedir=/var \
        --buildtype=release -Doptimization=plain --default-library=shared \
        --wrap-mode=nodownload -Ddoc=disabled -Dtests=disabled -Dtools=disabled -Dnls=disabled \
        -Dcache-build=disabled -Dcache-dir=/var/db/fontconfig -Ddefault-fonts-dirs=/usr/local/share/fonts \
        -Dadditional-fonts-dirs=/usr/local/lib/X11/fonts -Dtemplate-dir=/usr/local/etc/fonts/conf.avail \
        -Dxml-dir=/usr/local/etc/fonts &&
        ninja -C _az -j "$ncpu" && DESTDIR="$st" ninja -C _az install) &&
        cp -R "$st$S/." "$S/"
}
s_lcms2() { at_so "$1" --with-fastfloat --with-threaded --without-jpeg --without-tiff; }
s_dav1d() { ms_so "$1" -Denable_tools=false -Denable_tests=false -Denable_examples=false; }
s_libde265() {
    cm_so "$1" -DENABLE_ENCODER=OFF -DENABLE_DECODER=OFF -DENABLE_SDL=OFF -DENABLE_INTERNAL_DEVELOPMENT_TOOLS=OFF
}
s_libheif() {
    cm_so "$1" -DBUILD_TESTING=OFF -DCMAKE_COMPILE_WARNING_AS_ERROR=OFF -DCMAKE_DISABLE_FIND_PACKAGE_Doxygen=ON \
        -DBUILD_DOCUMENTATION=OFF -DWITH_EXAMPLES=OFF -DWITH_GDK_PIXBUF=OFF -DENABLE_PLUGIN_LOADING=OFF \
        -DWITH_LIBSHARPYUV=OFF -DWITH_FUZZERS=OFF -DBUILD_DEVELOPMENT_TOOLS=OFF \
        -DWITH_LIBDE265=ON -DWITH_LIBDE265_PLUGIN=OFF -DWITH_DAV1D=ON -DWITH_DAV1D_PLUGIN=OFF \
        -DWITH_AOM_DECODER=OFF -DWITH_AOM_ENCODER=OFF -DWITH_X265=OFF -DWITH_X264=OFF -DWITH_RAV1E=OFF \
        -DWITH_SvtEnc=OFF -DWITH_FFMPEG_DECODER=OFF -DWITH_OpenH264_DECODER=OFF -DWITH_OpenH264_ENCODER=OFF \
        -DWITH_JPEG_DECODER=OFF -DWITH_JPEG_ENCODER=OFF -DWITH_OpenJPEG_DECODER=OFF -DWITH_OpenJPEG_ENCODER=OFF \
        -DWITH_OPENJPH_DECODER=OFF -DWITH_OPENJPH_ENCODER=OFF -DWITH_KVAZAAR=OFF -DWITH_UVG266=OFF \
        -DWITH_VVDEC=OFF -DWITH_VVENC=OFF -DWITH_UNCOMPRESSED_CODEC=OFF
}
# Shared only (deps.conf), for the PHP modules sqlite3 and pdo_sqlite, gmp, xsl, ffi, tidy:
# sqlite3 as the port with its default options (CPPFLAGS and OPTIONS of
# databases/sqlite3), one make job (MAKE_JOBS_UNSAFE); the library, its headers and
# sqlite3.pc only (main.mk: the target so, install-dll, install-headers, install-pc).
# Its code generators run with the tclsh of the port's USES=tcl:build (lang/tcl86
# of --tools), else with the jimsh it builds itself (B.tclsh of main.mk).
s_sqlite3() {
    tclsh=""
    [ -x /usr/local/bin/tclsh8.6 ] && tclsh="--with-tclsh=/usr/local/bin/tclsh8.6"
    (CPPFLAGS="$CPPFLAGS -DHAVE_FCHOWN=1 -DHAVE_FDATASYNC=1 -DHAVE_GMTIME_R=1 -DHAVE_ISNAN=1 \
-DHAVE_LOCALTIME_R=1 -DHAVE_LSTAT=1 -DHAVE_MALLOC_USABLE_SIZE=1 -DHAVE_PREAD=1 -DHAVE_PWRITE=1 \
-DHAVE_READLINK=1 -DHAVE_STRCHRNUL=1 -DHAVE_STRERROR_R=1 -DHAVE_USLEEP=1 -DSQLITE_DEFAULT_FILE_PERMISSIONS=0644 \
-DSQLITE_OS_UNIX=1 -DSQLITE_STRICT_SUBTYPE=1 -DSQLITE_ENABLE_DBPAGE_VTAB=1 -DSQLITE_ENABLE_DBSTAT_VTAB=1 \
-DSQLITE_ENABLE_FTS3_TOKENIZER=1 -DSQLITE_ENABLE_FTS3_PARENTHESIS=1 -DSQLITE_ENABLE_COLUMN_METADATA=1 \
-DSQLITE_SECURE_DELETE=1 -DSQLITE_ENABLE_UNLOCK_NOTIFY=1 -DSQLITE_USE_URI=1"
        export CPPFLAGS
        cd "$1" && ./configure --prefix="$S" --libdir="$S/lib" --includedir="$S/include" \
            --soname=legacy --linemacros --enable-load-extension --fts3 --fts4 --fts5 --rtree --session \
            --with-tempstore=no --disable-tcl --disable-static OPTIONS='-lm -lpthread' $tclsh &&
            gmake so && gmake install-dll install-headers install-pc)
}
# gmp for the generic host of the ports (config.guess of fix_guess), fat: with the
# code of every x86-64 CPU, it takes the one of the CPU it runs on at run time. On
# a server it is built with CPU_OPTS (code for the CPU of that machine); this one
# is built on the CPU of the CI runner for every server of the level, so fat is
# the safe way to the same speed. No C++.
# the manual is not built (doc/ out of SUBDIRS, as the port with INFO off: OPTIONS_UNSET
# of the servers); with INFO on the port removes doc/gmp.info and needs makeinfo
s_gmp() { sed -i '' -e '/^SUBDIRS/ s|doc||' "$1/Makefile.in" && at_so "$1" --disable-cxx --enable-fat; }
s_libxslt() { at_so "$1" --without-python --without-crypto --without-plugins; }
s_libffi() {
    (LDFLAGS="$LDFLAGS -Wl,--undefined-version"; export LDFLAGS
        at_so "$1" --disable-multi-os-directory --disable-docs)
}
# tidy: the library only (no program, no manual page); the static libtidy it builds anyway goes in finish
# lib/libtidy5.so as the port names it (its post-install renames libtidy.so; its patch makes
# tidy.pc say -ltidy5, and ext/tidy of PHP takes libtidy5 first); libtidy.so stays too
s_tidy() {
    cm_so "$1" -DBUILD_SHARED_LIB=ON -DSUPPORT_CONSOLE_APP=OFF &&
        ln -sf "$(readlink "$S/lib/libtidy.so")" "$S/lib/libtidy5.so"
}

# lic <name> <source>: the licence files of a library into LICENSES/ (libpng
# 1.6.59 has a directory LICENSES too)
lic() {
    mkdir -p "$A/LICENSES"
    for f in "$2"/COPYING* "$2"/LICENSE* "$2"/LICENCE* "$2"/PATENTS* "$2"/COPYRIGHT*; do
        [ -e "$f" ] && cp -R "$f" "$A/LICENSES/$1-${f##*/}"
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
        if [ -f "$top/distfiles/$tf" ] && [ "$(sha256 -q "$top/distfiles/$tf")" = "$3" ]; then
            # fetched on the runner before the VM (tools/take-fetch.sh): the runner
            # reaches GitHub better than the VM does
            cp "$top/distfiles/$tf" "$work/distfiles/$tf"
            echo "== $tf: the file fetched on the runner (distfiles/, tools/take-fetch.sh)" >&2
        else
            # every address up to three times: a release file of GitHub sometimes stalls
            for try in 1 2 3; do
                for u in $(echo "$2" | tr ',' ' '); do
                    fetch -q -T 60 -o "$work/distfiles/$tf" "$u" && break 2
                    echo "== fetch $u failed (try $try of 3)" >&2
                    rm -f "$work/distfiles/$tf"
                done
                [ "$try" = 3 ] || sleep $((try * 15))
            done
        fi
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

# One library: fetch, check, extract and patch with the ports framework, then build
# it as its kinds in deps.conf say: static into P (b_<name>), shared into S
# (s_<name>, in a copy of the work directory made right after the patches, so that
# both build the same patched source and the static build leaves nothing in it);
# one log for both, one line of the summary with the status of each ("-": not of
# that kind).
build_one() {
    n="$1"
    port="$(port_of "$n")"
    log="$res/$n.log"
    start=$(date +%s)
    if [ "$port" = bundle ]; then build_bundle "$n"; return; fi
    targs="$(take_args "$n" "$port" 2>"$res/$n.take")"
    trc=$?
    take_of "$n" | grep -q . && take_ver="$(take_of "$n" | awk '{ print $1 }')" || take_ver=""
    # shellcheck disable=SC2086
    src="$(pmake "$port" $targs -V WRKSRC 2>/dev/null)"
    # shellcheck disable=SC2086
    wd="$(pmake "$port" $targs -V WRKDIR 2>/dev/null)"
    (
        if [ "$trc" != 0 ]; then cat "$res/$n.take"; echo "== $n: the release of the take line could not be had"; exit 1; fi
        if [ -n "$take_ver" ]; then
            echo "== $n: $port at $ports_commit with the release $take_ver of the take line in deps.conf:"
            # the failed tries before the one that worked
            [ ! -s "$res/$n.take" ] || cat "$res/$n.take"
            printf '   %s\n' $targs
        else
            echo "== $n: $port at $ports_commit"
        fi
        # shellcheck disable=SC2086
        pmake "$port" $targs clean >/dev/null 2>&1
        [ -n "$wd" ] && [ -n "$src" ] || { echo "== no WRKDIR or WRKSRC of $port (make -V)"; exit 1; }
        rm -rf "$wd.so"
        # shellcheck disable=SC2086
        pmake "$port" $targs patch || { echo "make patch failed"; exit 1; }
        # what the configure stage of the framework fixes in the sources before configure,
        # which make patch does not do: FreeBSD 1x taken for 1.x by old autotools
        # (run-autotools-fixup) and the libtool fixes of USES=libtool (patch-libtool);
        # without them the old libtool of libmcrypt builds no shared library
        for fx in run-autotools-fixup patch-libtool; do
            # shellcheck disable=SC2086
            pmake "$port" $targs "$fx" 2> /dev/null || true
        done
        echo "== source: $src"
        if has_kind "$n" shared; then
            # the whole work directory: relative paths out of WRKSRC (gettext-runtime/../build-aux, icu/source/..)
            cp -Rp "$wd" "$wd.so" || { echo "== cannot copy $wd to $wd.so"; exit 1; }
            echo "== source of the shared build: $wd.so${src#"$wd"}"
        fi
        lic "$n" "$src"
    ) > "$log" 2>&1
    prc=$?
    st_s=-; st_d=-
    if has_kind "$n" static; then
        st_s=FAIL
        if [ "$prc" = 0 ] && (
            echo "== static build into $P"
            : > "$work/stamp-$n"
            "b_$n" "$src" || exit 1
            # every library leaves a static archive of its own in lib/ (mozjpeg did not)
            if [ -z "$(find "$P/lib" -maxdepth 1 -name '*.a' -newer "$work/stamp-$n" | head -n 1)" ]; then
                echo "== no new static library of $n in $P/lib"; exit 1
            fi
        ) >> "$log" 2>&1; then st_s=OK; fi
    fi
    if has_kind "$n" shared; then
        st_d=FAIL
        if [ "$prc" = 0 ] && (
            echo "== shared build into $S"
            so_env
            : > "$work/stamp-so-$n"
            "s_$n" "$wd.so${src#"$wd"}" || exit 1
            if [ -z "$(find "$S/lib" -maxdepth 1 -name '*.so*' -newer "$work/stamp-so-$n" | head -n 1)" ]; then
                echo "== no new shared library of $n in $S/lib"; exit 1
            fi
        ) >> "$log" 2>&1; then st_d=OK; fi
    fi
    rc=0
    [ "$prc" = 0 ] && [ "$st_s" != FAIL ] && [ "$st_d" != FAIL ] || rc=1
    ver="$(pmake "$port" -V PKGVERSION 2>/dev/null)"
    pkgname="$(pmake "$port" -V PKGNAME 2>/dev/null)"
    if [ -n "$take_ver" ]; then
        # the name pkg audit knows, with the version taken and the epoch of the port
        epoch="$(pmake "$port" -V PORTEPOCH 2>/dev/null)"
        case "$epoch" in ""|0) epoch="" ;; *) epoch=",$epoch" ;; esac
        pkgname="${pkgname%-*}-$take_ver$epoch"
        ver="$take_ver (port: $ver)"
    fi
    summ "$n" "$ver" "$port"
    return "$rc"
}

# summ <name> <version> <port>: the line of the summary (st_s, st_d, rc, start), the
# line of built.txt (pkgname) when it built, the end of the log when not
summ() {
    if [ "$rc" = 0 ]; then
        printf '%-14s static %-4s shared %-4s %-22s %-24s %4ss\n' "$1" "$st_s" "$st_d" "$2" "$3" "$(( $(date +%s) - start ))" >> "$res/summary.txt"
        printf '%s %s %s\n' "$1" "$pkgname" "$3" >> "$res/built.txt"
    else
        printf '%-14s static %-4s shared %-4s %-22s %-24s %4ss (deps-results/%s.log)\n' "$1" "$st_s" "$st_d" "$2" "$3" "$(( $(date +%s) - start ))" "$1" >> "$res/summary.txt"
        tail -n 25 "$log" > "$res/$1.tail"
    fi
    say "$1: static $st_s, shared $st_d"
}

# One library of the bundled curl (port "bundle" in deps.conf): the sources of
# tools/curl-sources.sh (once per run), built by freebsd/curl/build-libcurl.sh as
# for --with-curl=bundled; curl takes its libraries into libcurl.a with their
# symbols local (swoole carries a copy of nghttp2, libzip links zstd). The shared
# build (s_<name>) runs out of the source tree, which stays as it is.
bundle_ver() {
    if [ "$1" = curl ]; then
        sed -n 's/^#define LIBCURL_VERSION "\(.*\)"$/\1/p' "$work/curl-src/libcurl/include/curl/curlver.h"
    else
        awk -v n="$1" '$1 == n { print $2 }' "$work/curl-src/deps/VERSIONS"
    fi
}
build_bundle() {
    n="$1"
    if [ "$n" = curl ]; then bs="$work/curl-src/libcurl"; else bs="$work/curl-src/deps/$n"; fi
    (
        echo "== $n: the bundled curl (freebsd/curl.conf, freebsd/curl-deps.conf)"
        if [ ! -f "$work/curl-src/deps/VERSIONS" ]; then
            sh "$top/tools/curl-sources.sh" "$work/curl-src" || { echo "tools/curl-sources.sh failed"; exit 1; }
        fi
        lic "$n" "$bs"
    ) > "$log" 2>&1
    prc=$?
    st_s=-; st_d=-
    if has_kind "$n" static; then
        st_s=FAIL
        if [ "$prc" = 0 ] && (
            echo "== static build into $P"
            : > "$work/stamp-$n"
            b="$top/freebsd/curl/build-libcurl.sh"
            case "$n" in
                curl) LIBICONV_PREFIX="$P" OBJDIR="$work/obj-curl" sh "$b" --curl "$bs" "$P" "$P" ;;
                libidn2) LIBICONV_PREFIX="$P" OBJDIR="$work/obj-curl" sh "$b" --lib libidn2 "$bs" "$P" ;;
                *) OBJDIR="$work/obj-curl" sh "$b" --lib "$n" "$bs" "$P" ;;
            esac || exit 1
            if [ -z "$(find "$P/lib" -maxdepth 1 -name '*.a' -newer "$work/stamp-$n" | head -n 1)" ]; then
                echo "== no new static library of $n in $P/lib"; exit 1
            fi
        ) >> "$log" 2>&1; then st_s=OK; fi
    fi
    if has_kind "$n" shared; then
        st_d=FAIL
        if [ "$prc" = 0 ] && (
            echo "== shared build into $S"
            so_env
            : > "$work/stamp-so-$n"
            "s_$(printf '%s' "$n" | tr - _)" "$bs" || exit 1
            if [ -z "$(find "$S/lib" -maxdepth 1 -name '*.so*' -newer "$work/stamp-so-$n" | head -n 1)" ]; then
                echo "== no new shared library of $n in $S/lib"; exit 1
            fi
        ) >> "$log" 2>&1; then st_d=OK; fi
    fi
    rc=0
    [ "$prc" = 0 ] && [ "$st_s" != FAIL ] && [ "$st_d" != FAIL ] || rc=1
    ver="$(bundle_ver "$n")"
    # the names of the ports for pkg audit: libnghttp2, and the epoch of archivers/brotli
    # (PORTEPOCH 1: VuXML has "brotli < 1.2.1,1", and 1.2.1 without it would be older)
    case "$n" in nghttp2) pkgname="libnghttp2-$ver" ;; brotli) pkgname="brotli-$ver,1" ;; *) pkgname="$n-$ver" ;; esac
    summ "$n" "$ver" bundle
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

# After the builds, the shared tree: only shared libraries in lib/ (with their .pc
# in lib/pkgconfig, the cmake files), the *-config scripts and bin/pkg-config, the
# headers; no programs, sbin, manual pages, documentation or translations. Then the
# checks (deps-results/shared.txt: every library with SONAME, size, DT_NEEDED and run
# path; a finding goes to shared-bad.txt and fails the build): every library has a
# SONAME and RELRO, every DT_NEEDED resolves (ldd) from S/lib or the base system
# (/lib, /usr/lib), never from /usr/local/lib or the static tree, with the run path
# S/lib where it needs a library of S; libcurl and libzip take libssl and libcrypto
# of the base system; the .pc files and *-config scripts name neither /usr/local
# outside S nor the static tree.
finish_so() {
    rm -f "$S"/lib/*.a "$S"/lib/*.la
    if [ -d "$S/libdata/pkgconfig" ]; then
        mkdir -p "$S/lib/pkgconfig" && mv "$S"/libdata/pkgconfig/*.pc "$S/lib/pkgconfig/" 2>/dev/null
        rm -rf "$S/libdata"
    fi
    mkdir -p "$S/bin"
    find "$S/bin" -maxdepth 1 ! -type d ! -name '*-config' -delete
    rm -rf "$S/sbin" "$S/share/man" "$S/share/doc" "$S/share/info" "$S/share/gtk-doc" "$S/share/locale" "$S/share/emacs"
    # pkg-config for the builds against the shared tree (the PHP modules of pkg mode):
    # its libraries and the base system, no static link lines
    printf '%s\n' '#!/bin/sh' "# pkg-config of $S: its shared libraries and the base system." \
        "PKG_CONFIG_LIBDIR='$S/lib/pkgconfig:/usr/libdata/pkgconfig'" \
        'export PKG_CONFIG_LIBDIR' 'unset PKG_CONFIG_PATH' 'exec /usr/local/bin/pkgconf "$@"' > "$S/bin/pkg-config"
    chmod +x "$S/bin/pkg-config"
    : > "$res/shared.txt"; : > "$res/shared-bad.txt"
    for f in "$S"/lib/*.so*; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        b="${f##*/}"
        readelf -d "$f" > "$work/so-dyn.txt" 2>&1
        # the value texts, which the readelf of binutils and that of the ELF Tool Chain both print
        sn="$(sed -n 's/.*[Ll]ibrary soname: \[\(.*\)\].*/\1/p' "$work/so-dyn.txt")"
        need="$(sed -n 's/.*[Ss]hared library: \[\(.*\)\].*/\1/p' "$work/so-dyn.txt" | tr '\n' ' ' | sed 's/ *$//')"
        rp="$(sed -n 's/.*[Ll]ibrary r[a-z]*path: \[\(.*\)\].*/\1/p' "$work/so-dyn.txt" | tr '\n' ':' | sed 's/:*$//')"
        printf '%s: SONAME %s, %s KB, NEEDED %s%s\n' "$b" "${sn:-none}" "$(du -Ak "$f" | cut -f1)" "${need:-none}" \
            "${rp:+, run path $rp}" >> "$res/shared.txt"
        [ -n "$sn" ] || echo "$b: no SONAME" >> "$res/shared-bad.txt"
        # every part of the run path is S/lib (libtool adds its own -rpath to ours: twice is fine)
        for part in $(printf '%s\n' "$rp" | tr ':' ' '); do
            [ "$part" = "$S/lib" ] || echo "$b: run path $part (only $S/lib belongs there: $rp)" >> "$res/shared-bad.txt"
        done
        readelf -l "$f" | grep -q GNU_RELRO || echo "$b: no RELRO" >> "$res/shared-bad.txt"
        ldd "$f" > "$work/so-ldd.txt" 2>&1 || echo "$b: ldd failed: $(head -n 1 "$work/so-ldd.txt")" >> "$res/shared-bad.txt"
        awk '$2 == "=>" { print $1, $3 }' "$work/so-ldd.txt" | while read -r l lp; do
            case "$lp" in
                "$P"/*) echo "$b: $l of the static tree ($lp)" ;;
                "$S"/lib/*) [ -n "$rp" ] || echo "$b: $l of $S/lib without the run path $S/lib" ;;
                /usr/local/*) echo "$b: $l of /usr/local ($lp)" ;;
                /lib/*|/usr/lib/*) ;;
                *) echo "$b: $l not found in $S/lib or the base system (${lp:-?})" ;;
            esac
        done >> "$res/shared-bad.txt"
        case "$b" in
            libcurl.so.*|libzip.so.*)
                # libzip needs only libcrypto (its AES), curl both
                case "$b" in libzip.so.*) ssl="libcrypto" ;; *) ssl="libssl libcrypto" ;; esac
                for l in $ssl; do
                    lp="$(awk -v l="$l" 'index($1, l ".so") == 1 && $2 == "=>" { print $3 }' "$work/so-ldd.txt")"
                    case "$lp" in /lib/*|/usr/lib/*) ;; *) echo "$b: $l not of the base system (${lp:-not linked})" >> "$res/shared-bad.txt" ;; esac
                done ;;
        esac
    done
    [ -s "$res/shared.txt" ] || echo "no shared library in $S/lib" >> "$res/shared-bad.txt"
    # the .pc files and *-config scripts (not the pkg-config wrapper): nothing of the
    # static tree, nothing of /usr/local outside S but the configuration and fonts of
    # the system that fontconfig reads
    for f in "$S"/lib/pkgconfig/*.pc "$S"/bin/*-config; do
        [ -f "$f" ] && [ "$f" != "$S/bin/pkg-config" ] || continue
        grep -n "$P" "$f" | sed "s#^#${f##*/}: the static tree: #" >> "$res/shared-bad.txt"
        sed -e "s#$S##g" -e 's#/usr/local/etc/fonts##g' -e 's#/usr/local/share/fonts##g' \
            -e 's#/usr/local/lib/X11/fonts##g' -e 's#sysconfdir=/usr/local/etc$##' -e '/Print PREFIX to icu install/d' "$f" |
            grep -n '/usr/local' | sed "s#^#${f##*/}: /usr/local outside $S: #" >> "$res/shared-bad.txt"
    done
}

manifest() {
    {
        echo "az libraries for FreeBSD $major (amd64, $cputype), built $(date '+%Y-%m-%d %H:%M %Z') on $(uname -sr)"
        echo "freebsd-ports $ports_commit; static libraries in $P, shared libraries in $S; CFLAGS: $CFLAGS"
        echo
        while read -r n pkgname port; do
            printf '%-14s %-28s %-24s %s\n' "$n" "$pkgname" "$port" "$(awk -v n="$n" '$1 == "lib" && $2 == n { print $4 }' "$conf")"
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
        echo "curl above: the static libcurl.a in $P for the builds of PHP, with only what PHP needs. The package"
        echo "curl (tools/build-az.sh): bin/curl and lib/libcurl.so.4 of /usr/local, a build of its own of the same"
        echo "release with the options of the port ftp/curl, against the libraries above."
        echo
        echo "The shared tree $S (lib/, include/, lib/pkgconfig/, bin/pkg-config and the *-config"
        echo "scripts), for the PHP modules of pkg mode: the libraries of the kind shared above, built"
        echo "from the same patched sources with the same options, with the run path $S/lib and the"
        echo "OpenSSL of the base system (libcurl, libzip); SONAME and DT_NEEDED of each:"
        sed 's/^/    /' "$res/shared.txt" 2>/dev/null
    } > "$res/VERSIONS"
    mkdir -p "$A/share/doc/az"
    cp "$res/VERSIONS" "$A/share/doc/az/VERSIONS"
}

# The curl program and libcurl.so (deps.conf: "program curl"), for the package curl
# of tools/build-az.sh, which takes the place of the curl of the ports (git and the
# other packages that link libcurl.so get this one). A build of its own, apart
# from the curl of PHP above (the static libcurl.a of /usr/local/az, in az,
# with only what PHP needs): the same release, with the options of the port
# ftp/curl (its CONFIGURE_ARGS and its default options: the protocols DICT, FTP,
# GOPHER, HTTP, HTTP/2, IMAP, IPFS, MQTT, POP3, RTSP, SMTP, TELNET, TFTP,
# WebSocket, NTLM, IDN, PSL, brotli, zstd, the threaded resolver), without SCP and
# SFTP (libssh2) and GSSAPI, which the libraries of /usr/local/az do not have;
# against the static libraries of /usr/local/az. Into the stage AZ_STAGE/curl
# (default AZ_WORK/stage/curl) as files of /usr/local: bin/curl, static, PIE,
# RELRO, BIND_NOW, stripped; lib/libcurl.so.4 of the libcurl.a of this build
# (curl_* made visible by tools/elf-export.py and exported, the libraries inside
# hidden), so that both need only libz and libthr of the base system;
# include/curl/, libdata/pkgconfig/libcurl.pc, curl-config, libcurl.m4, the
# manual pages, the licence.
build_curl_program() {
    ob="$work/obj-curl-sys"
    cs="$work/curl-src/libcurl"
    r="${AZ_STAGE:-${AZ_WORK:-/var/tmp/az-work}/stage}/curl/usr/local"
    log="$res/curl-program.log"
    start=$(date +%s)
    cv="$(bundle_ver curl)"
    (
        [ -x "$cs/configure" ] || { echo "== no source of curl in $cs (tools/curl-sources.sh)"; exit 1; }
        rm -rf "$ob" "${r%/usr/local}" "$work/curl-sys-dest"
        mkdir -p "$ob" "$r/bin" "$r/lib" "$r/libdata/pkgconfig" "$r/share/licenses/curl" || exit 1
        echo "== configure (the options of the port ftp/curl)"
        # LIBS: libidn2 of the tree uses the libiconv of the tree
        (cd "$ob" && LIBS="-liconv" LDFLAGS="-L$P/lib -pie -Wl,-z,relro,-z,now" "$cs/configure" \
            --prefix=/usr/local --disable-shared --enable-static --with-pic --disable-dependency-tracking \
            --with-openssl="$P" --enable-openssl-auto-load-config --with-ca-path=/etc/ssl/certs --without-ca-bundle \
            --enable-threaded-resolver --disable-ares \
            --with-nghttp2="$P" --with-brotli="$P" --with-zstd="$P" --with-libidn2="$P" --with-libpsl="$P" \
            --enable-alt-svc --enable-cookies --enable-dict --enable-ftp --enable-file --enable-gopher \
            --enable-http --enable-imap --enable-ipfs --enable-ipv6 --enable-mqtt --enable-ntlm \
            --enable-pop3 --enable-proxy --enable-rtsp --enable-smtp --enable-telnet --enable-tftp \
            --enable-websockets --disable-ldap --disable-ldaps \
            --without-libssh2 --without-libssh --without-gssapi \
            --disable-httpsig --disable-unity --disable-werror --enable-aws --enable-dateparse \
            --enable-dnsshuffle --enable-headers-api --enable-hsts --enable-http-auth --enable-manual \
            --enable-mime --enable-netrc --enable-progress-meter --enable-ssls-export --enable-typecheck \
            --without-zsh-functions-dir --without-fish-functions-dir) || exit 1
        echo "== build"
        gmake -C "$ob" -j"$ncpu" || exit 1
        gmake -C "$ob" install-strip DESTDIR="$work/curl-sys-dest" || exit 1
        d="$work/curl-sys-dest/usr/local"
        install -s -m 755 "$d/bin/curl" "$r/bin/curl" || exit 1
        cp -R "$d/include" "$r/" || exit 1
        [ -d "$d/share/man" ] && { mkdir -p "$r/share" && cp -R "$d/share/man" "$r/share/"; }
        [ -d "$d/share/aclocal" ] && { mkdir -p "$r/share" && cp -R "$d/share/aclocal" "$r/share/"; }
        # the name of libcurl.so of curl's libtool numbers (lib/Makefile.soname):
        # libcurl.so.<change - del>.<del>.<add>, as the port has it (libcurl.so.4.8.0)
        eval "$(sed -n -E 's/^(VERSIONCHANGE|VERSIONADD|VERSIONDEL)=([0-9]+).*/\1=\2/p' "$cs/lib/Makefile.soname")"
        so="libcurl.so.$((VERSIONCHANGE - VERSIONDEL))"
        full="$so.$VERSIONDEL.$VERSIONADD"
        echo "== $full of the libcurl.a of this build"
        # libcurl.a is built with its functions hidden (CURL_STATICLIB, -fvisibility=hidden):
        # one object of it with curl_* visible again (tools/elf-export.py), exported by
        # the version script, the libraries inside hidden (--exclude-libs)
        lo="$work/libcurl-so"
        rm -rf "$lo" && mkdir -p "$lo" || exit 1
        ld -r --whole-archive "$ob/lib/.libs/libcurl.a" -o "$lo/libcurl.o" || exit 1
        nv="$(python3 -I "$top/tools/elf-export.py" "$lo/libcurl.o" curl_)" || { echo "== tools/elf-export.py: no curl_* in libcurl.a"; exit 1; }
        echo "== curl_* made visible: $nv"
        printf '%s\n' '{' '  global: curl_*;' '  local: *;' '};' > "$lo/libcurl.vers"
        # the static link line of libcurl, without its first word (libcurl.a) and the
        # flags of programs (-pie, -z relro, -z now)
        deps="$(sh "$ob/curl-config" --static-libs | tr ' ' '\n' | sed '1d' | grep -v -E '^(-pie|-Wl,-z,.*)$' | tr '\n' ' ')"
        echo "== the libraries inside: $deps"
        # shellcheck disable=SC2086
        cc -shared -o "$r/lib/$full" -Wl,-soname,"$so" "$lo/libcurl.o" $deps -lm -lpthread \
            -Wl,--exclude-libs,ALL -Wl,--version-script="$lo/libcurl.vers" \
            -Wl,-z,relro,-z,now -Wl,--no-undefined || exit 1
        strip --strip-unneeded "$r/lib/$full" || exit 1
        ln -sf "$full" "$r/lib/$so" && ln -sf "$full" "$r/lib/libcurl.so" || exit 1
        bad="$(nm -D --defined-only "$r/lib/$full" | awk 'NF >= 3 && $3 !~ /^(curl_|_init$|_fini$|_edata$|_end$|__bss_start$)/ { print $3 }' | head -n 5 | tr '\n' ' ')"
        [ -z "$bad" ] || { echo "== $full exports more than curl_*: $bad"; exit 1; }
        n="$(nm -D --defined-only "$r/lib/$full" | grep -c ' curl_')"
        for f in curl_global_init curl_easy_init curl_easy_setopt curl_easy_perform curl_multi_perform curl_version_info; do
            nm -D --defined-only "$r/lib/$full" | grep -q " $f\$" || { echo "== $full does not export $f ($n curl_* functions)"; exit 1; }
        done
        echo "== $full exports $n curl_* functions"
        # libcurl.pc and curl-config for libcurl.so: no static libraries in this package
        pcf="$(ls "$d"/lib/pkgconfig/libcurl.pc "$d"/libdata/pkgconfig/libcurl.pc 2>/dev/null | head -n 1)"
        [ -n "$pcf" ] || { echo "== no libcurl.pc in $d"; exit 1; }
        sed -e 's|^Libs:.*|Libs: -L${libdir} -lcurl|' -e '/^Libs.private:/d' -e '/^Requires.private:/d' \
            "$pcf" > "$r/libdata/pkgconfig/libcurl.pc" || exit 1
        awk '/^ *--static-libs\)/ { print; print "    echo \"curl-config: the libcurl of this package is libcurl.so only\" >&2"; print "    exit 1"; skip = 1; next }
            skip && /;;/ { skip = 0 }
            !skip { print }' "$d/bin/curl-config" > "$r/bin/curl-config" && chmod 755 "$r/bin/curl-config" || exit 1
        cp "$cs/COPYING" "$r/share/licenses/curl/COPYING" || exit 1
        # the program and libcurl.so as they are, with the libraries of the base system only
        LD_LIBRARY_PATH="$r/lib" "$r/bin/curl" --version > "$res/curl-version.txt" 2>&1 || exit 1
        cat "$res/curl-version.txt"
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
                "$(du -Ak "$f" | cut -f1)" "$type" "$relro" "$now" "$libs" >> "$res/curl-bins.txt"
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
    if [ -n "$(ls -d "$A"/php* "$A"/bin/php* "$A"/etc/php* "$P"/php* "$P"/bin/php* "$P"/etc/php* 2>/dev/null | head -n 1)" ]; then
        echo "build-deps: $A has PHP builds in it; build into an empty directory (AZ_PREFIX=...)" >&2
        exit 2
    fi
    rm -rf "$A"
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
mkdir -p "$P" "$S"
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
finish_so
if [ -s "$res/shared-bad.txt" ]; then
    printf '%-14s FAIL  %s\n' "shared tree" "$(wc -l < "$res/shared-bad.txt" | tr -d ' ') findings (deps-results/shared-bad.txt): $(head -n 3 "$res/shared-bad.txt" | tr '\n' ' ')" >> "$res/summary.txt"
    rc=1
fi
manifest
# Known vulnerabilities of these versions (FreeBSD VuXML), for the report.
pkg audit -F -q $(awk '{ print $2 }' "$res/built.txt") > "$res/audit.txt" 2>&1 || true
if [ "$rc" = 0 ] && [ ! -s "$res/pic.txt" ] && [ ! -s "$res/links.txt" ] && [ ! -s "$res/bins-bad.txt" ]; then
    echo "installed: $A (static tree $P: $(du -Ask "$P" | cut -f1) KB, all: $(du -Ask "$A" | cut -f1) KB)" >> "$res/summary.txt"
    # the work directories of the ports, for the space of what is built after
    rm -rf "$work/wrk"
else
    rc=1
fi
exit "$rc"
