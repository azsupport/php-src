#!/bin/sh
# build-ffmpeg.sh - build /usr/local/ffmpeg (ffmpeg and ffprobe) for the video
# sites from the FreeBSD ports of freebsd/ffmpeg.conf, with only the formats,
# codecs and protocols listed there (see the head of that file for why).
#
# Usage (FreeBSD, as root, from the top of a php-src checkout of master):
#   sh tools/build-ffmpeg.sh --tools    install the build tools (pkg)
#   sh tools/build-ffmpeg.sh            build the libraries and FFmpeg, then the tarball
#
# As tools/build-deps.sh: for every lib line the ports framework fetches the
# distfiles of the port at the commit of ffmpeg.conf, checks them against its
# distinfo, extracts them and applies the port's patches (make patch; FFmpeg then
# also those of freebsd/ffmpeg/); this script then builds the source tree with its
# own options. A take line gives a new
# upstream release instead (with the port's patches, or those of
# freebsd/deps/<name>-<version>/). x264, dav1d and libwebp go into FFMPEG_WORK
# (default /var/tmp/ffmpeg-work) as static, position independent libraries;
# FFmpeg links them in, so that ffmpeg and ffprobe need no library of /usr/local
# (only libc, libm, libthr and libz of the base system). FFmpeg goes to
# FFMPEG_PREFIX (default /usr/local/ffmpeg): bin/ffmpeg, bin/ffprobe, VERSIONS
# and LICENSES/. Results go to ffmpeg-results/ (summary.txt, one log per
# library), the tarball to dist/ (ffmpeg-fbsd<major>-amd64-<level>.tar.xz,
# extracted with tar -xf ... -C /usr/local). tools/ffmpeg-test.sh tests it.
#
# Compiler flags as for PHP and phpdeps: CPUTYPE and CFLAGS of /etc/make.conf
# with -fstack-protector-strong and -fno-strict-aliasing; FFMPEG_CPUTYPE and
# FFMPEG_CFLAGS (the inputs of the workflow ffmpeg.yml) win over make.conf
# (MAKE_CONF, default /etc/make.conf); without either: x86-64-v3 and -O3 -pipe.
# FFmpeg: LTO, PIE, RELRO and BIND_NOW (configure lines of ffmpeg.conf); its own
# assembly picks the instructions of the CPU at run time.
#
# Exit status: 0 everything built, 1 a library or FFmpeg failed, or this CPU
# cannot run the level, 2 usage.

set -u
top="$(pwd)"
conf="$top/freebsd/ffmpeg.conf"
F="${FFMPEG_PREFIX:-/usr/local/ffmpeg}"
work="${FFMPEG_WORK:-/var/tmp/ffmpeg-work}"
L="$work/prefix"
res="$top/ffmpeg-results"
dist="$top/dist"
ports="${PORTSDIR:-$work/ports}"
ncpu="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
major="$(uname -r | cut -d. -f1)"

if [ "${1:-}" = "--tools" ]; then
    tools="git meson ninja nasm gmake perl5 pkgconf python3"
    # shellcheck disable=SC2086
    env ASSUME_ALWAYS_YES=yes pkg install -y $tools
    rc=$?
    for t in $tools; do pkg info -e "$t" || echo "build-ffmpeg: package $t is not installed"; done
    exit $rc
fi
[ -f "$conf" ] || { echo "build-ffmpeg: no $conf (run from the top of a php-src checkout of master)" >&2; exit 2; }

say() { printf '[build-ffmpeg %s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

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

cputype="${FFMPEG_CPUTYPE:-$(mc_get CPUTYPE)}"
cputype="${cputype:-x86-64-v3}"
opt="${FFMPEG_CFLAGS:-$(mc_get CFLAGS)}"
# shellcheck disable=SC2086
opt="$(printf '%s\n' ${opt:--O3 -pipe} | grep -v -e '^-march=' -e '^-fPIC$' | tr '\n' ' ' | sed 's/ *$//')"
level="${cputype#x86-64-}"
# FFmpeg adds -fPIC itself (--enable-pic); the libraries need it to go into a PIE.
ffcflags="$opt -march=$cputype -fstack-protector-strong -fno-strict-aliasing"
export CC=cc CXX=c++
export CFLAGS="$ffcflags -fPIC"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="-I$L/include"
export LDFLAGS="-L$L/lib"
# meson puts the .pc files into libdata/pkgconfig on FreeBSD (x264, dav1d), autotools into lib/pkgconfig
export PKG_CONFIG_LIBDIR="$L/lib/pkgconfig:$L/libdata/pkgconfig:/usr/libdata/pkgconfig"
unset PKG_CONFIG_PATH
# LTO (x264 and FFmpeg) puts LLVM bitcode into static archives: their index needs
# the ar of LLVM, taken by name when ar of the base system is another one.
unset AR RANLIB NM
if ! ar --version 2>/dev/null | grep -q LLVM && command -v llvm-ar >/dev/null 2>&1; then
    export AR=llvm-ar RANLIB=llvm-ranlib NM=llvm-nm
fi

ports_commit="$(awk '$1 == "ports" { print $2 }' "$conf")"
libs_all="$(awk '$1 == "lib" { print $2 }' "$conf")"
port_of() { awk -v n="$1" '$1 == "lib" && $2 == n { print $3 }' "$conf"; }
take_of() { awk -v n="$1" '$1 == "take" && $2 == n { print $3, $4, $5, $6 }' "$conf"; }
conf_opts() { awk '$1 == "configure" { for (i = 2; i <= NF; i++) print $i }' "$conf"; }

# The framework and the ports of ffmpeg.conf, with what they include
# (multimedia/x264: the master port of libx264; lang/perl5.* and lang/python3*:
# the version files of USES=perl5 and USES=python).
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
            $(awk '$1 == "lib" { printf "/%s/ ", $3 }' "$conf") /multimedia/x264/ \
            '/lang/perl5*/' '/lang/python3*/' &&
        git -C "$ports" checkout -q FETCH_HEAD
}
pmake() {
    p="$1"; shift
    make -C "$ports/$p" BATCH=yes NO_DEPENDS=yes DISABLE_VULNERABILITIES=yes \
        PORTSDIR="$ports" WRKDIRPREFIX="$work/wrk" DISTDIR="$work/distfiles" "$@"
}

fix_guess() {
    find "$1" \( -name config.guess -o -name config.sub \) -type f | while IFS= read -r f; do
        cp "$ports/Templates/${f##*/}" "$f" && chmod a+rx "$f"
    done
}
# meson as USES=meson of the ports (release, the optimization of CFLAGS), static
# and position independent, into $L
ms() {
    src="$1"; shift
    (cd "$src" && meson setup _ffmpeg --prefix="$L" --libdir=lib --buildtype=release -Doptimization=plain \
        --default-library=static -Db_staticpic=true --wrap-mode=nodownload "$@" &&
        ninja -C _ffmpeg -j "$ncpu" && ninja -C _ffmpeg install)
}

# x264 as the port (options ASM, LTO and OPTIMIZED_CFLAGS on), the library only
b_x264() { ms "$1" -Dcli=false -Dasm=enabled -Db_lto=true; }
# dav1d as the port, without its tools, tests and examples
b_dav1d() { ms "$1" -Denable_tools=false -Denable_tests=false -Denable_examples=false; }
# libwebp as for phpdeps (the libraries of the port, no tools)
b_webp() {
    fix_guess "$1"
    (cd "$1" && ./configure --prefix="$L" --libdir="$L/lib" --enable-static --disable-shared --with-pic \
        --enable-libwebpdecoder --enable-libwebpdemux --enable-libwebpmux --disable-gl --disable-sdl \
        --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-wic &&
        gmake -j"$ncpu" && gmake install)
}
# FFmpeg: after the port's patches those of freebsd/ffmpeg/ (in the order of their
# names), then configure with the options of the script and the configure lines
# of ffmpeg.conf
b_ffmpeg() {
    rm -rf "$F"
    for p in "$top"/freebsd/ffmpeg/*.patch; do
        [ -f "$p" ] || continue
        echo "== freebsd/ffmpeg/${p##*/}"
        patch -p1 -N -s -d "$1" < "$p" || { echo "== ${p##*/} does not apply"; return 1; }
    done
    (
        cd "$1" || exit 1
        set -- --prefix="$F" --cc=cc --cxx=c++ --pkg-config=pkgconf --pkg-config-flags=--static \
            --extra-cflags="$ffcflags -I$L/include" --extra-cxxflags="$ffcflags -I$L/include" \
            --extra-ldflags="-L$L/lib"
        if [ -n "${AR:-}" ]; then set -- "$@" --ar="$AR" --ranlib="$RANLIB" --nm="$NM -g"; fi
        # shellcheck disable=SC2046
        ./configure "$@" $(conf_opts) && gmake -j"$ncpu" && gmake install-progs
    ) || { cp "$1/ffbuild/config.log" "$res/ffmpeg-config.log" 2>/dev/null; return 1; }
    cp "$1/ffbuild/config.log" "$res/ffmpeg-config.log" 2>/dev/null
    mkdir -p "$F/LICENSES"
    for f in COPYING.GPLv2 COPYING.LGPLv2.1 LICENSE.md; do cp "$1/$f" "$F/LICENSES/FFmpeg-$f"; done
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
        echo "== $tf: SHA-256 $(sha256 -q "$work/distfiles/$tf"), not $3 as in ffmpeg.conf" >&2
        return 1
    fi
    printf 'TIMESTAMP = %s\nSHA256 (%s) = %s\nSIZE (%s) = %s\n' "$(date +%s)" "$tf" "$3" "$tf" \
        "$(stat -f %z "$work/distfiles/$tf")" > "$work/distinfo-take-$n"
    wd="$(pmake "$5" -V WRKDIR)"
    pd="$top/freebsd/deps/$n-$take_ver"
    printf '%s\n' "DISTFILES=$tf" "PATCHFILES=" "DISTINFO_FILE=$work/distinfo-take-$n" "WRKSRC=$wd/$4"
    if [ -d "$pd" ]; then printf '%s\n' "PATCHDIR=$pd"; fi
}

# The patches the framework applies to a port: files/patch-* and EXTRA_PATCHES.
port_patches() {
    fd="$(pmake "$1" -V FILESDIR 2>/dev/null)"
    np="$(ls "$fd" 2>/dev/null | grep -c '^patch-')"
    ne="$(pmake "$1" -V EXTRA_PATCHES 2>/dev/null | wc -w | tr -d ' ')"
    echo $(( np + ne ))
}

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
            echo "== $n: $port at $ports_commit with the release $take_ver of the take line in ffmpeg.conf:"
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
        "b_$n" "$src" || exit 1
        lic="$(ls "$src" | grep -E '^(COPYING|LICENSE|PATENTS)' | head -n 3)"
        if [ "$n" != ffmpeg ] && [ -n "$lic" ]; then
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
        printf '%-8s OK    %-22s %-22s %4ss\n' "$n" "$ver" "$port" "$(( $(date +%s) - start ))" >> "$res/summary.txt"
        printf '%s %s %s\n' "$n" "$pkgname" "$port" >> "$res/built.txt"
    else
        printf '%-8s FAIL  %-22s %-22s %4ss (ffmpeg-results/%s.log)\n' "$n" "$ver" "$port" "$(( $(date +%s) - start ))" "$n" >> "$res/summary.txt"
        tail -n 40 "$log" > "$res/$n.tail"
    fi
    say "$n: $(tail -n 1 "$res/summary.txt" | awk '{ print $2 }')"
    return "$rc"
}

manifest() {
    {
        echo "FFmpeg for FreeBSD $major (amd64, $cputype), built $(date '+%Y-%m-%d %H:%M %Z') on $(uname -sr)"
        echo "freebsd-ports $ports_commit; CFLAGS: $ffcflags (libraries: -fPIC)"
        echo
        while read -r n pkgname port; do
            printf '%-8s %-24s %s\n' "$n" "$pkgname" "$port"
            t="$(take_of "$n")"
            if [ -n "$t" ]; then
                # shellcheck disable=SC2086
                set -- $t
                echo "    ${2##*/} sha256 $3 (upstream release $1, ahead of the port: take line of ffmpeg.conf)"
            else
                # the distfiles of the port (not those of options it has off, such as the
                # test data of dav1d), as distinfo has them (libx264: that of multimedia/x264)
                di="$(pmake "$port" -V DISTINFO_FILE 2>/dev/null)"
                for d in $(pmake "$port" -V DISTFILES 2>/dev/null); do
                    d="${d%%:*}"
                    awk -v d="$d" '$1 == "SHA256" { f = $2; gsub(/[()]/, "", f); b = f; sub(/.*\//, "", b)
                        if (b == d) print "    " f " sha256 " $4 }' "$di"
                done
            fi
            np="$(port_patches "$port")"
            [ "$np" -gt 0 ] && echo "    $np patches of the port"
            if [ "$n" = ffmpeg ]; then
                for p in "$top"/freebsd/ffmpeg/*.patch; do
                    [ -f "$p" ] && echo "    freebsd/ffmpeg/${p##*/}: $(head -n 1 "$p")"
                done
            fi
        done < "$res/built.txt"
        echo
        echo "configure (after --prefix=$F, the compiler and the flags):"
        conf_opts | sed 's/^/    /'
        echo
        echo "Licence: GPL version 2 or later (FFmpeg with --enable-gpl, x264); the licences are in LICENSES/."
        echo "Sources: the distfiles above (their SHA-256), the patches of the ports at the commit above,"
        echo "freebsd/ffmpeg/ and tools/build-ffmpeg.sh of https://github.com/azsupport/php-src (freebsd/ffmpeg.conf)."
    } > "$F/VERSIONS"
}

# Hardening and links of the programs, for the report and the tests.
check_bins() {
    : > "$res/bins.txt"
    for b in ffmpeg ffprobe; do
        f="$F/bin/$b"
        [ -x "$f" ] || { echo "$b: missing" >> "$res/bins.txt"; continue; }
        type="$(readelf -h "$f" | awk '/Type:/ { print $2 }')"
        relro="$(readelf -l "$f" | grep -c GNU_RELRO)"
        now="$(readelf -d "$f" | grep -c -E 'BIND_NOW|FLAGS_1.*NOW')"
        libs="$(ldd "$f" | awk 'NR > 1 { print $3 }' | tr '\n' ' ' | sed 's/ *$//')"
        printf '%s: %s KB, ELF type %s, RELRO %s, BIND_NOW %s; libraries: %s\n' "$b" \
            "$(du -k "$f" | cut -f1)" "$type" "$relro" "$now" "$libs" >> "$res/bins.txt"
        case "$libs" in *"/usr/local/"*) echo "$b: links a library of /usr/local" >> "$res/bins-bad.txt" ;; esac
        [ "$type" = DYN ] || echo "$b: not a PIE (ELF type $type)" >> "$res/bins-bad.txt"
        [ "$relro" -gt 0 ] || echo "$b: no RELRO" >> "$res/bins-bad.txt"
        [ "$now" -gt 0 ] || echo "$b: no BIND_NOW" >> "$res/bins-bad.txt"
    done
    "$F/bin/ffmpeg" -hide_banner -version > "$res/version.txt" 2>&1
}

mkdir -p "$res" "$work" "$dist"
rm -f "$res"/*.tail "$res/bins-bad.txt"
: > "$res/summary.txt"; : > "$res/built.txt"
cpu_model="$(sysctl -n hw.model 2>/dev/null)"
printf 'flags:    %s\ncpu:      %s\n' "$ffcflags" "${cpu_model:-?}" >> "$res/summary.txt"
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
    printf '%-8s FAIL  this CPU (%s) %s -march=%s: code built for it cannot run here\n' \
        cpu "${cpu_model:-?}" "${why:-cannot tell the features of}" "$cputype" >> "$res/summary.txt"
    echo "build-ffmpeg: this CPU ${why:-cannot tell the features of} -march=$cputype" >&2
    exit 1
fi
ports_checkout || { echo "build-ffmpeg: cannot check out freebsd-ports $ports_commit" >> "$res/summary.txt"; exit 1; }
rm -rf "$L" "$work/licenses"
mkdir -p "$L"
rc=0
for n in $libs_all; do
    say "$n ($(port_of "$n"))"
    if ! build_one "$n"; then rc=1; break; fi
done
if [ "$rc" = 0 ]; then
    cp "$work"/licenses/* "$F/LICENSES/" 2>/dev/null
    manifest
    check_bins
    if [ ! -s "$res/bins-bad.txt" ]; then
        tarball="$dist/ffmpeg-fbsd$major-amd64-$level.tar.xz"
        tar -cJf "$tarball" -C "$(dirname "$F")" "$(basename "$F")"
        sha256 -q "$tarball" > "$tarball.sha256"
        cp "$F/VERSIONS" "$dist/ffmpeg-fbsd$major-amd64-$level.VERSIONS.txt"
        echo "tarball: ${tarball##*/} ($(du -k "$tarball" | cut -f1) KB, $(du -sk "$F" | cut -f1) KB unpacked)" >> "$res/summary.txt"
    else
        rc=1
    fi
fi
exit "$rc"
