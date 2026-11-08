#!/bin/sh
# build-imagemagick.sh - build ImageMagick 6 and 7 for the video sites (the "im"
# lines of freebsd/imagemagick.conf; the packages ImageMagick6 and ImageMagick7 of
# tools/build-az.sh, in the place of those of the ports): static programs side by
# side in /usr/local/bin, with only the formats listed there (see the head of
# that file for which and why), against the static libraries of the static tree
# of az, /usr/local/az/static (tools/build-deps.sh first;
# tools/build-az.sh runs both, the tests and the packages).
#
# Usage (FreeBSD, as root, from the top of a php-src checkout of master):
#   sh tools/build-imagemagick.sh --tools   install the build tools (pkg)
#   sh tools/build-imagemagick.sh           build both ImageMagicks
#
# As tools/build-deps.sh: for every im line the ports framework fetches the
# distfiles of the port at the ports commit of freebsd/deps.conf, checks them
# against its distinfo, extracts them and applies the port's patches (make
# patch); this script then builds the source tree with its own options. A take
# line gives a new upstream release instead (with the port's patches, or those of
# freebsd/deps/<name>-<version>/). Each ImageMagick links the static libraries of
# AZ_PREFIX/static (AZ_PREFIX: default /usr/local/az) in, is built with the
# prefix /usr/local and installed into a stage directory first; what it keeps then
# goes to the stage of its package, AZ_STAGE/ImageMagick<6|7> (default
# AZ_WORK/stage/...), as files of /usr/local: its programs in bin/ (ImageMagick 7:
# magick and the usual names linked to it; ImageMagick 6: every name with a 6 at
# the end, convert6, identify6...), etc/ImageMagick-<6|7>/ (its configuration,
# with the policy freebsd/imagemagick/policy.xml), share/ImageMagick-<6|7>/,
# lib/ImageMagick-<version>/ (its configure.xml), share/licenses/ImageMagick<6|7>/.
# ImageMagick 7 also keeps its static libraries, headers and .pc files in the
# static tree, /usr/local/az/static (lib, include/ImageMagick-7,
# lib/pkgconfig), for the static imagick of PHP, with bin/MagickWand-config and
# bin/MagickCore-config there printing the static link line (tools/build-az.sh
# links a test program with them as imagick does, once installed). Then it is
# built once more from a copy of the same patched source, taken before the static
# build, as shared libraries for imagick of the PHP packages (pkg mode, phpize
# against /usr/local/az): the same options with --enable-shared
# --disable-static, coders built in, against the shared libraries of
# /usr/local/az (run path /usr/local/az/lib) and the base system,
# nothing of the static tree; the prefix stays /usr/local, so the library reads
# the configuration, the policy and the share files of the package
# (/usr/local/etc/ImageMagick-7), as the programs and the static imagick do. It
# keeps lib/libMagickCore-7.so*, lib/libMagickWand-7.so*, their .pc files in
# lib/pkgconfig, include/ImageMagick-7, lib/ImageMagick-<version>/ (configure.xml)
# and bin/MagickWand-config, bin/MagickCore-config (the link line with the run
# path) in /usr/local/az; no programs, no Magick++. fontconfig takes its
# configuration and fonts from the system (/usr/local/etc/fonts,
# /usr/local/share/fonts; its cache /var/db/fontconfig), as the port does. The
# work directory is AZ_WORK/imagemagick (default /var/tmp/az-work/imagemagick).
# Results go to imagemagick-results/ (summary.txt with a line for the shared
# libraries, imagemagick7-so; one log per ImageMagick, <name>.VERSIONS,
# shared.txt: the SONAME, run path and libraries of each shared library).
# tools/imagemagick-test.sh tests them, once installed.
#
# Compiler flags as for PHP, the libraries and FFmpeg: CPUTYPE and CFLAGS of
# /etc/make.conf with -fstack-protector-strong and -fno-strict-aliasing (and
# -fPIC: the libraries of ImageMagick 7 go into libphp.so and imagick.so); AZ_CPUTYPE and
# AZ_CFLAGS (the inputs of the workflow az.yml) win over make.conf (MAKE_CONF,
# default /etc/make.conf); without either: x86-64-v3 and -O3 -pipe. The
# programs: PIE, RELRO and BIND_NOW; the shared libraries: RELRO and BIND_NOW.
#
# Exit status: 0 everything built, 1 an ImageMagick failed, the libraries are not
# there, or this CPU cannot run the level, 2 usage.

set -u
top="$(pwd)"
conf="$top/freebsd/imagemagick.conf"
A="${AZ_PREFIX:-/usr/local/az}"
# the static tree of az (the programs and the static imagick); the shared
# libraries are those of $A itself (lib, include, lib/pkgconfig, bin)
S="$A/static"
I=/usr/local
work="${AZ_WORK:-/var/tmp/az-work}/imagemagick"
stage="${AZ_STAGE:-${AZ_WORK:-/var/tmp/az-work}/stage}"
res="$top/imagemagick-results"
ports="${PORTSDIR:-$work/ports}"
ncpu="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
major="$(uname -r | cut -d. -f1)"

if [ "${1:-}" = "--tools" ]; then
    tools="git gmake perl5 pkgconf python3"
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

cputype="${AZ_CPUTYPE:-$(mc_get CPUTYPE)}"
cputype="${cputype:-x86-64-v3}"
opt="${AZ_CFLAGS:-$(mc_get CFLAGS)}"
# shellcheck disable=SC2086
opt="$(printf '%s\n' ${opt:--O3 -pipe} | grep -v -e '^-march=' -e '^-fPIC$' | tr '\n' ' ' | sed 's/ *$//')"
export CC=cc CXX=c++
export CFLAGS="$opt -march=$cputype -fstack-protector-strong -fno-strict-aliasing -fPIC"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="-I$S/include"
export LDFLAGS="-L$S/lib"
# pkg-config with --static (only static libraries): the libraries of the static tree,
# then the base system
mkdir -p "$work/bin"
printf '%s\n' '#!/bin/sh' 'exec pkgconf --static "$@"' > "$work/bin/pkg-config"
chmod +x "$work/bin/pkg-config"
export PKG_CONFIG="$work/bin/pkg-config"
export PKG_CONFIG_LIBDIR="$S/lib/pkgconfig:/usr/libdata/pkgconfig"
unset PKG_CONFIG_PATH
export PATH="$work/bin:$PATH"

ports_commit="$(awk '$1 == "ports" { print $2 }' "$top/freebsd/deps.conf")"
ims_all="$(awk '$1 == "im" { print $2 }' "$conf")"
port_of() { awk -v n="$1" '$1 == "im" && $2 == n { print $3 }' "$conf"; }
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
            $(awk '$1 == "im" { printf "/%s/ ", $3 }' "$conf") \
            '/lang/perl5*/' '/lang/python3*/' &&
        git -C "$ports" checkout -q FETCH_HEAD
}
# the ImageMagick ports in their flavor without X11
# JPEG_PORT as in make.conf of the servers: the ports with USES=jpeg (gd, ImageMagick) take mozjpeg
pmake() {
    p="$1"; shift
    make -C "$ports/$p" BATCH=yes NO_DEPENDS=yes DISABLE_VULNERABILITIES=yes JPEG_PORT=graphics/mozjpeg FLAVOR=nox11 \
        PORTSDIR="$ports" WRKDIRPREFIX="$work/wrk" DISTDIR="$work/distfiles" "$@"
}

fix_guess() {
    find "$1" \( -name config.guess -o -name config.sub \) -type f | while IFS= read -r f; do
        cp "$ports/Templates/${f##*/}" "$f" && chmod a+rx "$f"
    done
}

# pc_add <file.pc> <Libs|Libs.private> <-lname>...: add to that line of a .pc file the
# libraries it does not name yet (as in tools/build-deps.sh)
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

# config_wrap <name> <pc module> <tree> <static|shared>: <tree>/bin/<name> of
# ImageMagick 7 (in the stage of the package), printing the link line from the .pc
# files of that tree: static, the static link line; shared, the libraries with
# their run path <tree>/lib. The scripts of ImageMagick give neither (they read the
# .pc files where make install put them, and print no run path); imagick of PHP
# runs MagickWand-config.
config_wrap() {
    if [ "$4" = static ]; then
        what='static libraries, so --libs gives the static link line'
        libs="exec /usr/local/bin/pkgconf --static --libs $2"
    else
        what="shared libraries, so --libs gives them with the run path $3/lib"
        libs="l=\"\$(/usr/local/bin/pkgconf --libs $2)\" || exit 1; echo \"\$l -Wl,-rpath,$3/lib\""
    fi
    cat > "$root$3/bin/$1" <<EOF
#!/bin/sh
# $1 of ImageMagick 7 in $3 (tools/build-imagemagick.sh of
# https://github.com/azsupport/php-src): $what, from the .pc files of $3.
PKG_CONFIG_LIBDIR='$3/lib/pkgconfig:/usr/libdata/pkgconfig'
export PKG_CONFIG_LIBDIR
unset PKG_CONFIG_PATH
case "\${1:-}" in
    --cflags|--cppflags) exec /usr/local/bin/pkgconf --cflags $2 ;;
    --libs|--ldflags) $libs ;;
    --prefix|--exec-prefix) echo '$3' ;;
    --version) exec /usr/local/bin/pkgconf --modversion $2 ;;
    *) echo "Usage: $1 [--cflags] [--cppflags] [--exec-prefix] [--ldflags] [--libs] [--prefix] [--version]" >&2; exit 1 ;;
esac
EOF
    chmod 755 "$root$3/bin/$1"
}

# b_im7_shared <name> <source>: ImageMagick 7 once more, from the copy of the patched
# source that b_im took before its static build, as shared libraries for imagick of
# the PHP packages (see the head of this file), in a subshell with an environment of
# its own: nothing of the static tree $S. Installed into a stage directory of its
# own; into the stage of the package: the libraries, .pc files, headers,
# lib/ImageMagick-<version>/ and the config scripts in $A; not its programs.
b_im7_shared() {
    sst="$work/stage-$1-shared"
    rm -rf "$sst"
    for pc in libpng16 libjpeg libwebp freetype2 fontconfig lcms2 libheif; do
        [ -f "$A/lib/pkgconfig/$pc.pc" ] ||
            { echo "== shared: no $A/lib/pkgconfig/$pc.pc of the shared libraries (tools/build-deps.sh)"; return 1; }
    done
    echo "== shared libraries: configure, gmake and gmake install-strip in $2"
    (
        cd "$2" || exit 1
        PATH="${PATH#"$work/bin:"}"
        PKG_CONFIG=pkgconf
        PKG_CONFIG_LIBDIR="$A/lib/pkgconfig:/usr/libdata/pkgconfig"
        CPPFLAGS="-I$A/include"
        LDFLAGS="-L$A/lib -Wl,-rpath,$A/lib -Wl,-z,relro,-z,now"
        export PATH PKG_CONFIG PKG_CONFIG_LIBDIR CPPFLAGS LDFLAGS
        unset PKG_CONFIG_PATH
        # shellcheck disable=SC2046
        ./configure --prefix="$I" --libdir="$A/lib" --includedir="$A/include" LIBS="-lc++ -lpthread -lm" \
            PTHREAD_LIBS=-lpthread $(conf_opts configure) $(conf_opts configure7) \
            --enable-shared --disable-static --without-modules &&
            gmake -j"$ncpu" && gmake install-strip DESTDIR="$sst"
    ) || { echo "== shared: configure, gmake or gmake install-strip failed ($(df -h "$work" | awk 'NR == 2 { print $4 " free" }'))"; return 1; }
    cp "$2/config.log" "$res/$1-shared-config.log" 2>/dev/null
    l="$sst$A/lib"
    ls "$l"/libMagickCore-7.so* "$l"/libMagickWand-7.so* > /dev/null 2>&1 ||
        { echo "== shared: no libMagickCore-7.so or libMagickWand-7.so in $l: $(ls "$l" 2>/dev/null | tr '\n' ' ')"; return 1; }
    [ -d "$sst$A/include/ImageMagick-7" ] || { echo "== shared: no headers in $sst$A/include/ImageMagick-7"; return 1; }
    # the .pc files: in libdata/pkgconfig of the prefix (USES=pathfix of the port), or in lib/pkgconfig
    pcd=""
    for d in "$sst$I/libdata/pkgconfig" "$l/pkgconfig" "$sst$I/lib/pkgconfig"; do
        if ls "$d"/MagickWand-7*.pc > /dev/null 2>&1; then pcd="$d"; break; fi
    done
    [ -n "$pcd" ] || { echo "== shared: no MagickWand-7 .pc in $sst$I/libdata/pkgconfig, $l/pkgconfig or $sst$I/lib/pkgconfig"; return 1; }
    mkdir -p "$root$A/lib/pkgconfig" "$root$A/include" "$root$A/bin" || return 1
    keep="$(cd "$l" && ls -d libMagickCore-7.so* libMagickWand-7.so* ImageMagick-7.* 2>/dev/null)"
    echo "== into $root$A/lib:" $keep
    # shellcheck disable=SC2086
    (cd "$l" && tar -cf - $keep) | (cd "$root$A/lib" && tar -xpf -) || return 1
    cp -R "$sst$A/include/ImageMagick-7" "$root$A/include/" || return 1
    # libdir and includedir are those of $A already (configure was given them)
    for pc in "$pcd"/*.pc; do
        cp "$pc" "$root$A/lib/pkgconfig/${pc##*/}" || return 1
    done
    echo "== .pc files into $root$A/lib/pkgconfig: $(cd "$root$A/lib/pkgconfig" && ls | tr '\n' ' ')"
    mc="$(cd "$root$A/lib/pkgconfig" && ls MagickCore-7*.pc 2>/dev/null | head -n 1)"
    mw="$(cd "$root$A/lib/pkgconfig" && ls MagickWand-7*.pc 2>/dev/null | head -n 1)"
    [ -n "$mc" ] && [ -n "$mw" ] ||
        { echo "== shared: no MagickCore-7 or MagickWand-7 .pc: $(ls "$root$A/lib/pkgconfig" | tr '\n' ' ')"; return 1; }
    config_wrap MagickCore-config "${mc%.pc}" "$A" shared
    config_wrap MagickWand-config "${mw%.pc}" "$A" shared
    rm -rf "$sst"
    return 0
}

# One ImageMagick: after the port's patches those of freebsd/imagemagick/<name>-*.patch,
# configure with the lines of the conf (configure, configure6 or configure7), static
# programs (PIE, RELRO, BIND_NOW; stripped), installed into a stage directory; then
# what it keeps goes into the stage of its package (see the head of this file);
# ImageMagick 7 then once more as shared libraries (b_im7_shared). Not conjure: it runs
# MSL scripts, which need libxml2.
b_im() {
    n="$1"; src="$2"; v="${n#imagemagick}"
    st="$work/stage-$n"
    root="$stage/ImageMagick$v"
    rm -rf "$st" "$root"
    for p in "$top"/freebsd/imagemagick/"$n"-*.patch; do
        [ -f "$p" ] || continue
        echo "== freebsd/imagemagick/${p##*/}"
        patch -p1 -N -s -d "$src" < "$p" || { echo "== ${p##*/} does not apply"; return 1; }
    done
    fix_guess "$src"
    if [ "$v" = 7 ]; then
        # a copy of the patched source for the shared libraries (b_im7_shared): each
        # configure starts from the tree of make patch, without fetching and patching
        # it again; in the work directory of the ports, removed with it
        shsrc="$work/wrk/$n-shared"
        rm -rf "$shsrc"
        cp -Rp "$src" "$shsrc" ||
            { echo "== cannot copy $src to $shsrc ($(df -h "$work" | awk 'NR == 2 { print $4 " free" }'))"; return 1; }
    fi
    (
        cd "$src" || exit 1
        # shellcheck disable=SC2046
        ./configure --prefix="$I" LDFLAGS="$LDFLAGS -pie -Wl,-z,relro,-z,now" LIBS="-lc++ -lpthread -lm" \
            PTHREAD_LIBS=-lpthread $(conf_opts configure) $(conf_opts "configure$v") &&
            gmake -j"$ncpu" && gmake install-strip DESTDIR="$st"
    ) || { echo "== configure, gmake or gmake install-strip failed ($(df -h "$work" | awk 'NR == 2 { print $4 " free" }'))"; return 1; }
    echo "== installed into $st"
    cp "$src/config.log" "$res/$n-config.log" 2>/dev/null
    s="$st$I"
    [ -d "$s/bin" ] || { echo "== nothing was installed into $s"; return 1; }
    if [ "$v" = 6 ]; then
        progs="$(cd "$s/bin" && ls | grep '6$' | grep -v -e '-config6$' -e '^conjure6$')"
    else
        progs="$(cd "$s/bin" && ls | grep -v -e '-config$' -e '^conjure$')"
    fi
    [ -n "$progs" ] || { echo "== no programs in $s/bin"; return 1; }
    keep="$(for p in $progs; do echo "bin/$p"; done; cd "$s" && ls -d "etc/ImageMagick-$v" "share/ImageMagick-$v" lib/ImageMagick-"$v".* 2>/dev/null)"
    echo "== into $root$I:" $keep
    mkdir -p "$root$I" || return 1
    # shellcheck disable=SC2086
    (cd "$s" && tar -cf - $keep) | (cd "$root$I" && tar -xpf -) || return 1
    cp "$top/freebsd/imagemagick/policy.xml" "$root$I/etc/ImageMagick-$v/policy.xml" || return 1
    if [ "$v" = 7 ]; then
        # the static libraries, headers and .pc files, for the static imagick of PHP: in
        # the static tree $S (the configuration they read stays that of
        # /usr/local/etc/ImageMagick-7)
        mkdir -p "$root$S/lib/pkgconfig" "$root$S/include" "$root$S/bin" || return 1
        # the names of the port (its post-patch strips the Q16HDRI of the names):
        # libMagickCore-7.a, libMagickWand-7.a, MagickCore-7.pc, MagickWand-7.pc
        cp "$s"/lib/libMagick*-7*.a "$root$S/lib/" && cp -R "$s/include/ImageMagick-7" "$root$S/include/" ||
            { echo "== no static libraries or headers of ImageMagick 7 in $s: $(ls "$s/lib" | tr '\n' ' ')"; return 1; }
        # the .pc files: in libdata/pkgconfig, as the port puts them (lib/pkgconfig without it)
        pcd="$s/libdata/pkgconfig"; [ -d "$pcd" ] || pcd="$s/lib/pkgconfig"
        ls "$pcd"/*.pc > /dev/null 2>&1 || { echo "== no .pc files of ImageMagick 7 in $s/libdata/pkgconfig or $s/lib/pkgconfig"; return 1; }
        for pc in "$pcd"/*.pc; do
            sed -e "s|^prefix=$I\$|prefix=$S|" -e "s|=$I/include/|=$S/include/|g" -e "s|=$I/lib\$|=$S/lib|" \
                "$pc" > "$root$S/lib/pkgconfig/${pc##*/}" || return 1
        done
        # the C++ runtime and the threads of libheif and libde265, for a static link line
        for pc in "$root$S"/lib/pkgconfig/MagickCore*.pc "$root$S"/lib/pkgconfig/ImageMagick*.pc; do
            pc_add "$pc" Libs.private -lc++ -lpthread -lm
        done
        mc="$(cd "$root$S/lib/pkgconfig" && ls MagickCore-7*.pc 2>/dev/null | head -n 1)"
        mw="$(cd "$root$S/lib/pkgconfig" && ls MagickWand-7*.pc 2>/dev/null | head -n 1)"
        [ -n "$mc" ] && [ -n "$mw" ] ||
            { echo "== no MagickCore-7 or MagickWand-7 .pc: $(ls "$root$S/lib/pkgconfig" | tr '\n' ' ')"; return 1; }
        config_wrap MagickCore-config "${mc%.pc}" "$S" static
        config_wrap MagickWand-config "${mw%.pc}" "$S" static
        # then the shared libraries, for imagick of the PHP packages: in $A
        b_im7_shared "$n" "$shsrc" || return 1
    fi
    mkdir -p "$root$I/share/licenses/ImageMagick$v"
    for f in LICENSE NOTICE; do [ -f "$src/$f" ] && cp "$src/$f" "$root$I/share/licenses/ImageMagick$v/$f"; done
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

# build_one <name>: fetch, check, extract and patch with the ports framework, then b_im
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
            # the failed tries before the one that worked
            [ ! -s "$res/$n.take" ] || cat "$res/$n.take"
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
        b_im "$n" "$src" || exit 1
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
        {
            tail -n 40 "$log"
            echo "== disk: $(df -h "$work" | awk 'NR == 2 { print $4 " free of " $2 }')"
            echo "== errors in the log:"
            grep -n -E '\*\*\*|Error [0-9]+|No space|[Ee]rror:' "$log" | tail -n 20
        } > "$res/$n.tail"
    fi
    say "$n: $(tail -n 1 "$res/summary.txt" | awk '{ print $2 }')"
    return "$rc"
}

# manifest <im name>: imagemagick-results/<name>.VERSIONS
manifest() {
    im="$1"; v="${im#imagemagick}"
    {
        echo "ImageMagick $v for FreeBSD $major (amd64, $cputype), built $(date '+%Y-%m-%d %H:%M %Z') on $(uname -sr)"
        echo "freebsd-ports $ports_commit; CFLAGS: $CFLAGS"
        echo "libraries: the static ones of $S (az, the static tree): libpng, mozjpeg, libwebp, FreeType, fontconfig, expat, lcms2, libheif, libde265, dav1d"
        echo
        while read -r n pkgname port; do
            [ "$n" = "$im" ] || continue
            printf '%-13s %-26s %s\n' "$n" "$pkgname" "$port"
            t="$(take_of "$n")"
            if [ -n "$t" ]; then
                # shellcheck disable=SC2086
                set -- $t
                echo "    ${2##*/} sha256 $3 (upstream release $1, ahead of the port: take line of imagemagick.conf)"
            else
                di="$(pmake "$port" -V DISTINFO_FILE 2>/dev/null)"
                for d in $(pmake "$port" -V DISTFILES 2>/dev/null) $(pmake "$port" -V PATCHFILES 2>/dev/null); do
                    d="${d%%:*}"
                    awk -v d="$d" '$1 == "SHA256" { f = $2; gsub(/[()]/, "", f); b = f; sub(/.*\//, "", b)
                        if (b == d) print "    " f " sha256 " $4 }' "$di"
                done
            fi
            np="$(port_patches "$port")"
            [ "$np" -gt 0 ] && echo "    $np patches of the port"
            for p in "$top"/freebsd/imagemagick/"$n"-*.patch; do
                [ -f "$p" ] && echo "    freebsd/imagemagick/${p##*/}: $(head -n 1 "$p")"
            done
        done < "$res/built.txt"
        echo
        echo "configure (after --prefix=$I and the flags):"
        { conf_opts configure; conf_opts "configure$v"; } | sed 's/^/    /'
        echo
        if [ "$v" = 6 ]; then
            echo "Programs: $I/bin/*6 (convert6, identify6, mogrify6, composite6, ...)."
        else
            echo "Programs: $I/bin/magick and the names linked to it (convert, identify, mogrify, composite, ...);"
            echo "for the static imagick of PHP: $S/lib/libMagickCore-7.a, libMagickWand-7.a, $S/include/ImageMagick-7,"
            echo "$S/bin/MagickWand-config (the static link line). For imagick of the PHP packages (pkg mode): the shared"
            echo "libraries $(sonames "$stage/ImageMagick7$A/lib" | tr "\n" " " | sed "s/ *$//") in $A/lib (built again with the options above and"
            echo "--enable-shared --disable-static, against the shared libraries of $A, run path $A/lib),"
            echo "$A/include/ImageMagick-7, $A/lib/pkgconfig/MagickWand-7.pc, $A/bin/MagickWand-config."
        fi
        echo "Policy: $I/etc/ImageMagick-$v/policy.xml (freebsd/imagemagick/policy.xml)."
        echo "Licences: $I/share/licenses/ImageMagick$v/. Sources: the distfiles above (their SHA-256), the patches of the"
        echo "port at the commit above and tools/build-imagemagick.sh of https://github.com/azsupport/php-src"
        echo "(freebsd/imagemagick.conf)."
    } > "$res/$im.VERSIONS"
}

# sonames <dir>: the SONAME of each shared library of ImageMagick 7 in <dir>
sonames() {
    for f in "$1"/libMagickCore-7.so* "$1"/libMagickWand-7.so*; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        readelf -d "$f" | sed -n 's/.*[Ll]ibrary soname: \[\(.*\)\].*/\1/p'
    done
}

# The shared libraries of ImageMagick 7: a SONAME, the run path $A/lib (RUNPATH, or
# RPATH), RELRO and BIND_NOW, only libraries of $A/lib and of the base system (ldd,
# with those of the stage first); the line imagemagick7-so of summary.txt, the
# details in shared.txt.
check_shared() {
    l="$stage/ImageMagick7$A/lib"
    bad=""; names=""
    : > "$res/shared.txt"
    for f in "$l"/libMagickCore-7.so* "$l"/libMagickWand-7.so*; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        b="${f##*/}"
        so="$(readelf -d "$f" | sed -n 's/.*[Ll]ibrary soname: \[\(.*\)\].*/\1/p')"
        rp="$(readelf -d "$f" | sed -n 's/.*[Ll]ibrary r\(un\)\{0,1\}path: \[\(.*\)\].*/\2/p')"
        relro="$(readelf -l "$f" | grep -c GNU_RELRO)"
        now="$(readelf -d "$f" | grep -c -E 'BIND_NOW|FLAGS_1.*NOW')"
        libs="$(LD_LIBRARY_PATH="$l" ldd "$f" | awk 'NR > 1 { print ($3 == "not" ? $1 "(not-found)" : $3) }' | tr '\n' ' ' | sed 's/ *$//')"
        printf '%s: SONAME %s, run path %s, RELRO %s, BIND_NOW %s; libraries: %s\n' \
            "$b" "${so:-none}" "${rp:-none}" "$relro" "$now" "$libs" >> "$res/shared.txt"
        names="$names ${so:-?}"
        [ -n "$so" ] || bad="$bad $b: no SONAME;"
        # libtool may name the directory twice (its own -rpath for the library it links
        # with, and LDFLAGS): every part of the run path has to be $A/lib
        case ":$rp:" in *":$A/lib:"*) ;; *) bad="$bad $b: run path ${rp:-none}, not $A/lib;" ;; esac
        other="$(printf '%s\n' "$rp" | tr ':' '\n' | grep -v -x -F "$A/lib" | tr '\n' ' ')"
        [ -z "$other" ] || bad="$bad $b: run path $rp has more than $A/lib;"
        [ "$relro" -gt 0 ] || bad="$bad $b: no RELRO;"
        [ "$now" -gt 0 ] || bad="$bad $b: no BIND_NOW;"
        for p in $libs; do
            case "$p" in
                "$A"/lib/*|"$l"/*|/lib/*|/usr/lib/*) ;;
                *) bad="$bad $b: links $p, not of $A/lib or the base system;" ;;
            esac
        done
    done
    [ -n "$names" ] || bad=" no libMagickCore-7.so or libMagickWand-7.so in $l;"
    if [ -z "$bad" ]; then
        printf '%-13s OK    sonames:%s; run path %s\n' imagemagick7-so "$names" "$A/lib" >> "$res/summary.txt"
    else
        printf '%-13s FAIL  sonames:%s;%s (imagemagick-results/shared.txt)\n' imagemagick7-so "${names:- none}" "$bad" >> "$res/summary.txt"
        echo "imagemagick7 shared libraries:$bad" >> "$res/bins-bad.txt"
    fi
}

# The programs: PIE, RELRO, BIND_NOW, libraries of the base system only.
check_bins() {
    im="$1"; r="$stage/ImageMagick${im#imagemagick}$I"
    case "$im" in imagemagick6) progs="convert6 identify6 mogrify6 composite6" ;; *) progs="magick" ;; esac
    for b in $progs; do
        f="$r/bin/$b"
        [ -x "$f" ] || { echo "$im $b: missing" >> "$res/bins-bad.txt"; continue; }
        type="$(readelf -h "$f" | awk '/Type:/ { print $2 }')"
        relro="$(readelf -l "$f" | grep -c GNU_RELRO)"
        now="$(readelf -d "$f" | grep -c -E 'BIND_NOW|FLAGS_1.*NOW')"
        libs="$(ldd "$f" | awk 'NR > 1 { print $3 }' | tr '\n' ' ' | sed 's/ *$//')"
        printf '%s %s: %s KB, ELF type %s, RELRO %s, BIND_NOW %s; libraries: %s\n' "$im" "$b" \
            "$(du -Ak "$f" | cut -f1)" "$type" "$relro" "$now" "$libs" >> "$res/bins.txt"
        case "$libs" in *"/usr/local/"*) echo "$im $b: links a library of /usr/local" >> "$res/bins-bad.txt" ;; esac
        [ "$type" = DYN ] || echo "$im $b: not a PIE (ELF type $type)" >> "$res/bins-bad.txt"
        [ "$relro" -gt 0 ] || echo "$im $b: no RELRO" >> "$res/bins-bad.txt"
        [ "$now" -gt 0 ] || echo "$im $b: no BIND_NOW" >> "$res/bins-bad.txt"
    done
    case "$im" in imagemagick6) "$r/bin/convert6" -version ;; *) "$r/bin/magick" -version ;; esac > "$res/$im-version.txt" 2>&1
}

mkdir -p "$res" "$work"
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
for pc in libpng16 libjpeg libwebp freetype2 fontconfig lcms2 libheif; do
    if [ ! -f "$S/lib/pkgconfig/$pc.pc" ]; then
        printf '%-13s FAIL  no %s of the static libraries in %s/lib/pkgconfig: build them first (tools/build-deps.sh)\n' libs "$pc" "$S" >> "$res/summary.txt"
        echo "build-imagemagick: no $S/lib/pkgconfig/$pc.pc; build the libraries first (tools/build-deps.sh)" >&2
        exit 1
    fi
done
ports_checkout || { echo "build-imagemagick: cannot check out freebsd-ports $ports_commit" >> "$res/summary.txt"; exit 1; }
rc=0
for im in $ims_all; do
    say "$im ($(port_of "$im"))"
    if build_one "$im"; then
        manifest "$im"
        check_bins "$im"
        if [ "$im" = imagemagick7 ]; then check_shared; fi
        if ! grep -q "^$im " "$res/bins-bad.txt" 2>/dev/null; then
            echo "installed: $im into the stage $stage/ImageMagick${im#imagemagick} ($(du -Ask "$stage/ImageMagick${im#imagemagick}" | cut -f1) KB)" >> "$res/summary.txt"
        else
            rc=1
        fi
        # its work directory, for the space of the next one
        rm -rf "$work/wrk"
    else
        rc=1
    fi
done
rm -rf "$work/wrk"
exit "$rc"
