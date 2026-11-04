#!/bin/sh
# build-imagemagick.sh - build ImageMagick 6 and 7 for the video sites into
# /usr/local/imagemagick6 and /usr/local/imagemagick7 (the "im" lines of
# freebsd/imagemagick.conf): static programs, both installable at once, with only
# the formats listed there (see the head of that file for which and why).
#
# Usage (FreeBSD, as root, from the top of a php-src checkout of master):
#   sh tools/build-imagemagick.sh --tools   install the build tools (pkg)
#   sh tools/build-imagemagick.sh           build the libraries, both ImageMagicks and the tarballs
#
# As tools/build-ffmpeg.sh: for every lib and im line the ports framework fetches
# the distfiles of the port at the commit of the conf, checks them against its
# distinfo, extracts them and applies the port's patches (make patch); this script
# then builds the source tree with its own options. A take line gives a new
# upstream release instead (with the port's patches, or those of
# freebsd/deps/<name>-<version>/). The libraries go into IM_WORK/prefix (default
# /var/tmp/imagemagick-work) as static, position independent libraries; each
# ImageMagick links them in and goes to the prefix of its im line: bin/ (the
# programs), etc/ImageMagick-<6|7>/ (its configuration, with the policy
# freebsd/imagemagick/policy.xml), share/ImageMagick-<6|7>/, lib/ImageMagick-*/
# (its configure.xml), VERSIONS and LICENSES/. fontconfig takes its configuration
# and fonts from the system (/usr/local/etc/fonts, /usr/local/share/fonts; its
# cache /var/db/fontconfig), as the port does. Results go to imagemagick-results/
# (summary.txt, one log per library), the tarballs to dist/
# (imagemagick<6|7>-fbsd<major>-amd64-<level>.tar.xz, extracted with
# tar -xf ... -C /usr/local). tools/imagemagick-test.sh tests them.
#
# Compiler flags as for PHP, phpdeps and FFmpeg: CPUTYPE and CFLAGS of
# /etc/make.conf with -fstack-protector-strong and -fno-strict-aliasing (and -fPIC);
# IM_CPUTYPE and IM_CFLAGS (the inputs of the workflow imagemagick.yml) win over
# make.conf (MAKE_CONF, default /etc/make.conf); without either: x86-64-v3 and
# -O3 -pipe. The programs: PIE, RELRO and BIND_NOW.
#
# Exit status: 0 everything built, 1 a library or an ImageMagick failed, or this
# CPU cannot run the level, 2 usage.

set -u
top="$(pwd)"
conf="$top/freebsd/imagemagick.conf"
work="${IM_WORK:-/var/tmp/imagemagick-work}"
L="$work/prefix"
res="$top/imagemagick-results"
dist="$top/dist"
ports="${PORTSDIR:-$work/ports}"
ncpu="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
major="$(uname -r | cut -d. -f1)"

if [ "${1:-}" = "--tools" ]; then
    tools="git cmake ninja meson nasm gmake perl5 pkgconf python3 gperf"
    # shellcheck disable=SC2086
    env ASSUME_ALWAYS_YES=yes pkg install -y $tools
    rc=$?
    for t in $tools; do pkg info -e "$t" || echo "build-imagemagick: package $t is not installed"; done
    exit $rc
fi
[ -f "$conf" ] || { echo "build-imagemagick: no $conf (run from the top of a php-src checkout of master)" >&2; exit 2; }

say() { printf '[build-imagemagick %s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

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

cputype="${IM_CPUTYPE:-$(mc_get CPUTYPE)}"
cputype="${cputype:-x86-64-v3}"
opt="${IM_CFLAGS:-$(mc_get CFLAGS)}"
# shellcheck disable=SC2086
opt="$(printf '%s\n' ${opt:--O3 -pipe} | grep -v -e '^-march=' -e '^-fPIC$' | tr '\n' ' ' | sed 's/ *$//')"
level="${cputype#x86-64-}"
export CC=cc CXX=c++
export CFLAGS="$opt -march=$cputype -fstack-protector-strong -fno-strict-aliasing -fPIC"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="-I$L/include"
export LDFLAGS="-L$L/lib"
# pkg-config with --static (only static libraries), the libraries here first, then
# the base system; meson puts .pc files into libdata/pkgconfig on FreeBSD
mkdir -p "$work/bin"
printf '%s\n' '#!/bin/sh' 'exec pkgconf --static "$@"' > "$work/bin/pkg-config"
chmod +x "$work/bin/pkg-config"
export PKG_CONFIG="$work/bin/pkg-config"
export PKG_CONFIG_LIBDIR="$L/lib/pkgconfig:$L/libdata/pkgconfig:/usr/libdata/pkgconfig"
unset PKG_CONFIG_PATH
export PATH="$work/bin:$PATH"

ports_commit="$(awk '$1 == "ports" { print $2 }' "$conf")"
libs_all="$(awk '$1 == "lib" { print $2 }' "$conf")"
ims_all="$(awk '$1 == "im" { print $2 }' "$conf")"
port_of() { awk -v n="$1" '($1 == "lib" || $1 == "im") && $2 == n { print $3 }' "$conf"; }
prefix_of() { awk -v n="$1" '$1 == "im" && $2 == n { print $4 }' "$conf"; }
take_of() { awk -v n="$1" '$1 == "take" && $2 == n { print $3, $4, $5, $6 }' "$conf"; }
# conf_opts <key>: the options of the lines with that first word (configure, configure6, configure7)
conf_opts() { awk -v k="$1" '$1 == k { for (i = 2; i <= NF; i++) print $i }' "$conf"; }

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
            $(awk '$1 == "lib" || $1 == "im" { printf "/%s/ ", $3 }' "$conf") \
            '/lang/perl5*/' '/lang/python3*/' &&
        git -C "$ports" checkout -q FETCH_HEAD
}
# the ImageMagick ports in their flavor without X11 (the others have no flavors)
pmake() {
    p="$1"; shift
    case "$p" in graphics/ImageMagick*) fl="FLAVOR=nox11" ;; *) fl="" ;; esac
    # shellcheck disable=SC2086
    make -C "$ports/$p" BATCH=yes NO_DEPENDS=yes DISABLE_VULNERABILITIES=yes $fl \
        PORTSDIR="$ports" WRKDIRPREFIX="$work/wrk" DISTDIR="$work/distfiles" "$@"
}

fix_guess() {
    find "$1" \( -name config.guess -o -name config.sub \) -type f | while IFS= read -r f; do
        cp "$ports/Templates/${f##*/}" "$f" && chmod a+rx "$f"
    done
}
at() {
    src="$1"; shift
    fix_guess "$src"
    (cd "$src" && ./configure --prefix="$L" --libdir="$L/lib" --includedir="$L/include" \
        --enable-static --disable-shared --with-pic "$@" && gmake -j"$ncpu" && gmake install)
}
cm() {
    src="$1"; shift
    cmake -S "$src" -B "$src/_im" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$L" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_PREFIX_PATH="$L" \
        -DCMAKE_IGNORE_PREFIX_PATH=/usr/local -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_C_FLAGS="$CFLAGS" -DCMAKE_CXX_FLAGS="$CXXFLAGS" "$@" &&
        cmake --build "$src/_im" -j "$ncpu" && cmake --install "$src/_im"
}
ms() {
    src="$1"; shift
    (cd "$src" && meson setup _im --prefix="$L" --libdir=lib --buildtype=release -Doptimization=plain \
        --default-library=static -Db_staticpic=true --wrap-mode=nodownload "$@" &&
        ninja -C _im -j "$ncpu" && ninja -C _im install)
}

b_png() { cm "$1" -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_DEBUG_POSTFIX=""; }
b_mozjpeg() {
    # as for phpdeps (the port: JPEG8 API, SIMD), without its tools' PNG input and TurboJPEG
    cm "$1" -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_JPEG8=ON -DWITH_SIMD=ON -DREQUIRE_SIMD=OFF \
        -DWITH_ARITH_DEC=OFF -DWITH_ARITH_ENC=OFF -DWITH_12BIT=OFF -DWITH_JAVA=OFF -DWITH_JPEG7=OFF \
        -DWITH_TURBOJPEG=OFF -DPNG_SUPPORTED=OFF -DWITH_MEM_SRCDST=ON -DFORCE_INLINE=ON \
        -DCMAKE_INSTALL_LIBDIR="$L/lib" -DCMAKE_INSTALL_INCLUDEDIR="$L/include" \
        -DCMAKE_INSTALL_BINDIR="$L/bin" -DCMAKE_INSTALL_MANDIR="$L/share/man" \
        -DCMAKE_INSTALL_DOCDIR="$L/share/doc/mozjpeg"
}
b_webp() {
    at "$1" --enable-libwebpdecoder --enable-libwebpdemux --enable-libwebpmux --disable-gl --disable-sdl \
        --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-wic
}
# FreeType with zlib only (no PNG glyphs, bzip2 fonts, Brotli WOFF2, HarfBuzz)
b_freetype2() {
    cm "$1" -DFT_REQUIRE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON -DFT_DISABLE_HARFBUZZ=ON \
        -DFT_DISABLE_BROTLI=ON
}
b_expat() { at "$1" --without-docbook --without-examples --without-tests --without-xmlwf; }
# fontconfig with the paths of the port, so that it reads the configuration, fonts and
# cache of the system; installed through a stage directory (nothing into /usr/local)
b_fontconfig() {
    st="$work/stage-fontconfig"
    rm -rf "$st"
    (cd "$1" && meson setup _im --prefix="$L" --libdir=lib --sysconfdir=/usr/local/etc --localstatedir=/var \
        --buildtype=release -Doptimization=plain --default-library=static -Db_staticpic=true \
        --wrap-mode=nodownload -Ddoc=disabled -Dtests=disabled -Dtools=disabled -Dnls=disabled \
        -Dcache-build=disabled -Dcache-dir=/var/db/fontconfig -Ddefault-fonts-dirs=/usr/local/share/fonts \
        -Dadditional-fonts-dirs=/usr/local/lib/X11/fonts -Dtemplate-dir=/usr/local/etc/fonts/conf.avail \
        -Dxml-dir=/usr/local/etc/fonts &&
        ninja -C _im -j "$ncpu" && DESTDIR="$st" ninja -C _im install) &&
        cp -R "$st$L/." "$L/"
}
# lcms2 as the port (fast float and threaded plugins), without its tools
b_lcms2() { at "$1" --with-fastfloat --with-threaded --without-jpeg --without-tiff; }
# the HEVC decoder of libheif (HEIC), no encoder, no tools
b_libde265() {
    cm "$1" -DENABLE_ENCODER=OFF -DENABLE_DECODER=OFF -DENABLE_SDL=OFF -DENABLE_INTERNAL_DEVELOPMENT_TOOLS=OFF
}
# the AV1 decoder of libheif (AVIF), as for FFmpeg
b_dav1d() { ms "$1" -Denable_tools=false -Denable_tests=false -Denable_examples=false; }
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
# One ImageMagick: configure with the lines of the conf (configure, configure6 or
# configure7), static programs (PIE, RELRO, BIND_NOW), the policy of
# freebsd/imagemagick/policy.xml; only the programs and their configuration stay.
b_im() {
    n="$1"; src="$2"; pfx="$(prefix_of "$n")"; v="${n#imagemagick}"
    [ -n "$pfx" ] || { echo "== no prefix for $n"; return 1; }
    rm -rf "$pfx"
    fix_guess "$src"
    (
        cd "$src" || exit 1
        # shellcheck disable=SC2046
        ./configure --prefix="$pfx" LDFLAGS="$LDFLAGS -pie -Wl,-z,relro,-z,now" LIBS="-lc++ -lpthread -lm" \
            PTHREAD_LIBS=-lpthread $(conf_opts configure) $(conf_opts "configure$v") &&
            gmake -j"$ncpu" && gmake install
    ) || return 1
    cp "$src/config.log" "$res/$n-config.log" 2>/dev/null
    cp "$top/freebsd/imagemagick/policy.xml" "$pfx/etc/ImageMagick-$v/policy.xml" || return 1
    rm -rf "$pfx/include" "$pfx/lib/pkgconfig" "$pfx/share/doc" "$pfx/share/man"
    rm -f "$pfx"/lib/*.a "$pfx"/lib/*.la "$pfx"/bin/*-config
    mkdir -p "$pfx/LICENSES"
    for f in LICENSE NOTICE; do [ -f "$src/$f" ] && cp "$src/$f" "$pfx/LICENSES/ImageMagick-$f"; done
    cp "$work"/licenses/* "$pfx/LICENSES/" 2>/dev/null
    return 0
}

take_args() {
    take_ver=""
    t="$(take_of "$1")"
    [ -n "$t" ] || return 0
    # shellcheck disable=SC2086
    set -- $t "$2"
    take_ver="$1"
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
        echo "== $tf: SHA-256 $(sha256 -q "$work/distfiles/$tf"), not $3 as in imagemagick.conf" >&2
        return 1
    fi
    printf 'TIMESTAMP = %s\nSHA256 (%s) = %s\nSIZE (%s) = %s\n' "$(date +%s)" "$tf" "$3" "$tf" \
        "$(stat -f %z "$work/distfiles/$tf")" > "$work/distinfo-take-$n"
    wd="$(pmake "$5" -V WRKDIR)"
    pd="$top/freebsd/deps/$n-$take_ver"
    printf '%s\n' "DISTFILES=$tf" "PATCHFILES=" "DISTINFO_FILE=$work/distinfo-take-$n" "WRKSRC=$wd/$4"
    if [ -d "$pd" ]; then printf '%s\n' "PATCHDIR=$pd"; fi
}

port_patches() {
    fd="$(pmake "$1" -V FILESDIR 2>/dev/null)"
    np="$(ls "$fd" 2>/dev/null | grep -c '^patch-')"
    ne="$(pmake "$1" -V EXTRA_PATCHES 2>/dev/null | wc -w | tr -d ' ')"
    echo $(( np + ne ))
}

# build_one <name>: fetch, check, extract and patch with the ports framework, then
# b_<name> (an im line: b_im)
build_one() {
    n="$1"
    port="$(port_of "$n")"
    log="$res/$n.log"
    start=$(date +%s)
    targs="$(take_args "$n" "$port" 2>"$res/$n.take")"
    trc=$?
    take_of "$n" | grep -q . && take_ver="$(take_of "$n" | awk '{ print $1 }')" || take_ver=""
    (
        if [ "$trc" != 0 ]; then cat "$res/$n.take"; echo "== $n: the release of the take line could not be had"; exit 1; fi
        if [ -n "$take_ver" ]; then
            echo "== $n: $port at $ports_commit with the release $take_ver of the take line in imagemagick.conf:"
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
        if [ -n "$(prefix_of "$n")" ]; then
            b_im "$n" "$src" || exit 1
        else
            "b_$n" "$src" || exit 1
            lic="$(ls "$src" | grep -E '^(COPYING|LICENSE|PATENTS)' | head -n 3)"
            mkdir -p "$work/licenses"
            for f in $lic; do cp "$src/$f" "$work/licenses/$n-$f"; done
        fi
    ) > "$log" 2>&1
    rc=$?
    ver="$(pmake "$port" -V PKGVERSION 2>/dev/null)"
    pkgname="$(pmake "$port" -V PKGNAME 2>/dev/null)"
    if [ -n "$take_ver" ]; then
        epoch="$(pmake "$port" -V PORTEPOCH 2>/dev/null)"
        case "$epoch" in ""|0) epoch="" ;; *) epoch=",$epoch" ;; esac
        pkgname="${pkgname%-*}-$take_ver$epoch"
        ver="$take_ver (port: $ver)"
    fi
    if [ "$rc" = 0 ]; then
        printf '%-13s OK    %-20s %-22s %4ss\n' "$n" "$ver" "$port" "$(( $(date +%s) - start ))" >> "$res/summary.txt"
        printf '%s %s %s\n' "$n" "$pkgname" "$port" >> "$res/built.txt"
    else
        printf '%-13s FAIL  %-20s %-22s %4ss (imagemagick-results/%s.log)\n' "$n" "$ver" "$port" "$(( $(date +%s) - start ))" "$n" >> "$res/summary.txt"
        tail -n 40 "$log" > "$res/$n.tail"
    fi
    say "$n: $(tail -n 1 "$res/summary.txt" | awk '{ print $2 }')"
    return "$rc"
}

# manifest <im name>: <prefix>/VERSIONS
manifest() {
    im="$1"; pfx="$(prefix_of "$im")"; v="${im#imagemagick}"
    {
        echo "ImageMagick $v for FreeBSD $major (amd64, $cputype), built $(date '+%Y-%m-%d %H:%M %Z') on $(uname -sr)"
        echo "freebsd-ports $ports_commit; CFLAGS: $CFLAGS"
        echo
        while read -r n pkgname port; do
            case "$n" in imagemagick*) [ "$n" = "$im" ] || continue ;; esac
            printf '%-13s %-26s %s\n' "$n" "$pkgname" "$port"
            t="$(take_of "$n")"
            if [ -n "$t" ]; then
                # shellcheck disable=SC2086
                set -- $t
                echo "    ${2##*/} sha256 $3 (upstream release $1, ahead of the port: take line of imagemagick.conf)"
            else
                di="$(pmake "$port" -V DISTINFO_FILE 2>/dev/null)"
                for d in $(pmake "$port" -V DISTFILES 2>/dev/null); do
                    d="${d%%:*}"
                    awk -v d="$d" '$1 == "SHA256" { f = $2; gsub(/[()]/, "", f); b = f; sub(/.*\//, "", b)
                        if (b == d) print "    " f " sha256 " $4 }' "$di"
                done
                for d in $(pmake "$port" -V PATCHFILES 2>/dev/null); do
                    d="${d%%:*}"
                    awk -v d="$d" '$1 == "SHA256" { f = $2; gsub(/[()]/, "", f); b = f; sub(/.*\//, "", b)
                        if (b == d) print "    " f " sha256 " $4 }' "$di"
                done
            fi
            np="$(port_patches "$port")"
            [ "$np" -gt 0 ] && echo "    $np patches of the port"
        done < "$res/built.txt"
        echo
        echo "configure (after --prefix=$pfx and the flags):"
        { conf_opts configure; conf_opts "configure$v"; } | sed 's/^/    /'
        echo
        echo "Policy: etc/ImageMagick-$v/policy.xml (freebsd/imagemagick/policy.xml)."
        echo "Licences in LICENSES/. Sources: the distfiles above (their SHA-256), the patches of the ports at"
        echo "the commit above and tools/build-imagemagick.sh of https://github.com/azsupport/php-src"
        echo "(freebsd/imagemagick.conf)."
    } > "$pfx/VERSIONS"
}

# The programs: PIE, RELRO, BIND_NOW, libraries of the base system only.
check_bins() {
    im="$1"; pfx="$(prefix_of "$im")"
    case "$im" in imagemagick6) progs="convert identify mogrify composite" ;; *) progs="magick" ;; esac
    for b in $progs; do
        f="$pfx/bin/$b"
        [ -x "$f" ] || { echo "$im $b: missing" >> "$res/bins-bad.txt"; continue; }
        type="$(readelf -h "$f" | awk '/Type:/ { print $2 }')"
        relro="$(readelf -l "$f" | grep -c GNU_RELRO)"
        now="$(readelf -d "$f" | grep -c -E 'BIND_NOW|FLAGS_1.*NOW')"
        libs="$(ldd "$f" | awk 'NR > 1 { print $3 }' | tr '\n' ' ' | sed 's/ *$//')"
        printf '%s %s: %s KB, ELF type %s, RELRO %s, BIND_NOW %s; libraries: %s\n' "$im" "$b" \
            "$(du -k "$f" | cut -f1)" "$type" "$relro" "$now" "$libs" >> "$res/bins.txt"
        case "$libs" in *"/usr/local/"*) echo "$im $b: links a library of /usr/local" >> "$res/bins-bad.txt" ;; esac
        [ "$type" = DYN ] || echo "$im $b: not a PIE (ELF type $type)" >> "$res/bins-bad.txt"
        [ "$relro" -gt 0 ] || echo "$im $b: no RELRO" >> "$res/bins-bad.txt"
        [ "$now" -gt 0 ] || echo "$im $b: no BIND_NOW" >> "$res/bins-bad.txt"
    done
    case "$im" in imagemagick6) "$pfx/bin/convert" -version ;; *) "$pfx/bin/magick" -version ;; esac > "$res/$im-version.txt" 2>&1
}

mkdir -p "$res" "$work" "$dist"
rm -f "$res"/*.tail "$res/bins-bad.txt" "$res/bins.txt"
: > "$res/summary.txt"; : > "$res/built.txt"
cpu_model="$(sysctl -n hw.model 2>/dev/null)"
printf 'flags:    %s\ncpu:      %s\n' "$CFLAGS" "${cpu_model:-?}" >> "$res/summary.txt"
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
    printf '%-13s FAIL  this CPU (%s) %s -march=%s: code built for it cannot run here\n' \
        cpu "${cpu_model:-?}" "${why:-cannot tell the features of}" "$cputype" >> "$res/summary.txt"
    echo "build-imagemagick: this CPU ${why:-cannot tell the features of} -march=$cputype" >&2
    exit 1
fi
ports_checkout || { echo "build-imagemagick: cannot check out freebsd-ports $ports_commit" >> "$res/summary.txt"; exit 1; }
rm -rf "$L" "$work/licenses"
mkdir -p "$L"
rc=0
for n in $libs_all; do
    say "$n ($(port_of "$n"))"
    if ! build_one "$n"; then rc=1; break; fi
done
if [ "$rc" = 0 ]; then
    for im in $ims_all; do
        say "$im ($(port_of "$im"))"
        if build_one "$im"; then
            pfx="$(prefix_of "$im")"
            manifest "$im"
            check_bins "$im"
            if ! grep -q "^$im " "$res/bins-bad.txt" 2>/dev/null; then
                tarball="$dist/$im-fbsd$major-amd64-$level.tar.xz"
                tar -cJf "$tarball" -C "$(dirname "$pfx")" "$(basename "$pfx")"
                sha256 -q "$tarball" > "$tarball.sha256"
                cp "$pfx/VERSIONS" "$dist/$im-fbsd$major-amd64-$level.VERSIONS.txt"
                echo "tarball: ${tarball##*/} ($(du -Ak "$tarball" | cut -f1) KB, $(du -sk "$pfx" | cut -f1) KB unpacked)" >> "$res/summary.txt"
            else
                rc=1
            fi
        else
            rc=1
        fi
    done
fi
exit "$rc"
