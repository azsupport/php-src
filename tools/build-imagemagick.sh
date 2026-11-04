#!/bin/sh
# build-imagemagick.sh - build ImageMagick 6 and 7 for the video sites (the "im"
# lines of freebsd/imagemagick.conf; the packages ImageMagick6 and ImageMagick7 of
# tools/build-az.sh, in the place of those of the ports): static programs side by
# side in /usr/local/bin, with only the formats listed there (see the head of
# that file for which and why), against the static libraries of /usr/local/az
# (tools/build-deps.sh first; tools/build-az.sh runs both, the tests and the
# packages).
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
# freebsd/deps/<name>-<version>/). Each ImageMagick links the libraries of
# AZ_PREFIX (default /usr/local/az) in, is built with the prefix /usr/local and
# installed into a stage directory first; what it keeps then goes to the stage of
# its package, AZ_STAGE/ImageMagick<6|7> (default AZ_WORK/stage/...), as files of
# /usr/local: its programs in bin/ (ImageMagick 7: magick and the usual names
# linked to it; ImageMagick 6: every name with a 6 at the end, convert6,
# identify6...), etc/ImageMagick-<6|7>/ (its configuration, with the policy
# freebsd/imagemagick/policy.xml), share/ImageMagick-<6|7>/,
# lib/ImageMagick-<version>/ (its configure.xml), share/licenses/ImageMagick<6|7>/.
# ImageMagick 7 also keeps its static libraries, headers and .pc files, in
# /usr/local/az, for imagick of PHP (--with-imagick=/usr/local/az), with
# bin/MagickWand-config and bin/MagickCore-config there printing the static link
# line (tools/build-az.sh links a test program with them as imagick does, once
# installed). fontconfig takes its configuration and fonts from the system
# (/usr/local/etc/fonts, /usr/local/share/fonts; its cache /var/db/fontconfig),
# as the port does. The work directory is AZ_WORK/imagemagick (default
# /var/tmp/az-work/imagemagick). Results go to imagemagick-results/ (summary.txt,
# one log per ImageMagick, <name>.VERSIONS). tools/imagemagick-test.sh tests them,
# once installed.
#
# Compiler flags as for PHP, the libraries and FFmpeg: CPUTYPE and CFLAGS of
# /etc/make.conf with -fstack-protector-strong and -fno-strict-aliasing (and
# -fPIC: the libraries of ImageMagick 7 go into libphp.so); AZ_CPUTYPE and
# AZ_CFLAGS (the inputs of the workflow az.yml) win over make.conf (MAKE_CONF,
# default /etc/make.conf); without either: x86-64-v3 and -O3 -pipe. The
# programs: PIE, RELRO and BIND_NOW.
#
# Exit status: 0 everything built, 1 an ImageMagick failed, the libraries are not
# there, or this CPU cannot run the level, 2 usage.

set -u
top="$(pwd)"
conf="$top/freebsd/imagemagick.conf"
A="${AZ_PREFIX:-/usr/local/az}"
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
export CPPFLAGS="-I$A/include"
export LDFLAGS="-L$A/lib"
# pkg-config with --static (only static libraries): the libraries of the tree,
# then the base system
mkdir -p "$work/bin"
printf '%s\n' '#!/bin/sh' 'exec pkgconf --static "$@"' > "$work/bin/pkg-config"
chmod +x "$work/bin/pkg-config"
export PKG_CONFIG="$work/bin/pkg-config"
export PKG_CONFIG_LIBDIR="$A/lib/pkgconfig:/usr/libdata/pkgconfig"
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
pmake() {
    p="$1"; shift
    make -C "$ports/$p" BATCH=yes NO_DEPENDS=yes DISABLE_VULNERABILITIES=yes FLAVOR=nox11 \
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

# config_wrap <name> <pc module>: bin/<name> of ImageMagick 7, printing the static
# link line from the .pc files of the tree (the scripts of ImageMagick give the
# one for shared libraries); imagick of PHP runs MagickWand-config.
config_wrap() {
    cat > "$root$A/bin/$1" <<EOF
#!/bin/sh
# $1 of ImageMagick 7 in $A (tools/build-imagemagick.sh of
# https://github.com/azsupport/php-src): static libraries, so --libs gives the
# static link line, from the .pc files of $A.
PKG_CONFIG_LIBDIR='$A/lib/pkgconfig:/usr/libdata/pkgconfig'
export PKG_CONFIG_LIBDIR
unset PKG_CONFIG_PATH
case "\${1:-}" in
    --cflags|--cppflags) exec /usr/local/bin/pkgconf --cflags $2 ;;
    --libs|--ldflags) exec /usr/local/bin/pkgconf --static --libs $2 ;;
    --prefix|--exec-prefix) echo '$A' ;;
    --version) exec /usr/local/bin/pkgconf --modversion $2 ;;
    *) echo "Usage: $1 [--cflags] [--cppflags] [--exec-prefix] [--ldflags] [--libs] [--prefix] [--version]" >&2; exit 1 ;;
esac
EOF
    chmod 755 "$root$A/bin/$1"
}

# One ImageMagick: after the port's patches those of freebsd/imagemagick/<name>-*.patch,
# configure with the lines of the conf (configure, configure6 or configure7), static
# programs (PIE, RELRO, BIND_NOW; stripped), installed into a stage directory; then
# what it keeps goes into the tree (see the head of this file). Not conjure: it runs
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
        # the static libraries, headers and .pc files, for imagick of PHP: in /usr/local/az
        # (the configuration they read stays that of /usr/local/etc/ImageMagick-7)
        mkdir -p "$root$A/lib/pkgconfig" "$root$A/include" "$root$A/bin" || return 1
        # the names of the port (its post-patch strips the Q16HDRI of the names):
        # libMagickCore-7.a, libMagickWand-7.a, MagickCore-7.pc, MagickWand-7.pc
        cp "$s"/lib/libMagick*-7*.a "$root$A/lib/" && cp -R "$s/include/ImageMagick-7" "$root$A/include/" ||
            { echo "== no static libraries or headers of ImageMagick 7 in $s: $(ls "$s/lib" | tr '\n' ' ')"; return 1; }
        for pc in "$s"/lib/pkgconfig/*.pc; do
            sed -e "s|^prefix=$I\$|prefix=$A|" -e "s|=$I/include/|=$A/include/|g" -e "s|=$I/lib\$|=$A/lib|" \
                "$pc" > "$root$A/lib/pkgconfig/${pc##*/}" || return 1
        done
        # the C++ runtime and the threads of libheif and libde265, for a static link line
        for pc in "$root$A"/lib/pkgconfig/MagickCore*.pc "$root$A"/lib/pkgconfig/ImageMagick*.pc; do
            pc_add "$pc" Libs.private -lc++ -lpthread -lm
        done
        mc="$(cd "$root$A/lib/pkgconfig" && ls MagickCore-7*.pc 2>/dev/null | head -n 1)"
        mw="$(cd "$root$A/lib/pkgconfig" && ls MagickWand-7*.pc 2>/dev/null | head -n 1)"
        [ -n "$mc" ] && [ -n "$mw" ] ||
            { echo "== no MagickCore-7 or MagickWand-7 .pc: $(ls "$root$A/lib/pkgconfig" | tr '\n' ' ')"; return 1; }
        config_wrap MagickCore-config "${mc%.pc}"
        config_wrap MagickWand-config "${mw%.pc}"
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
        echo "libraries: the static ones of $A (az-libs): libpng, mozjpeg, libwebp, FreeType, fontconfig, expat, lcms2, libheif, libde265, dav1d"
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
            echo "for imagick of PHP: $A/lib/libMagickCore-7.a, libMagickWand-7.a, $A/include/ImageMagick-7,"
            echo "$A/bin/MagickWand-config (the static link line)."
        fi
        echo "Policy: $I/etc/ImageMagick-$v/policy.xml (freebsd/imagemagick/policy.xml)."
        echo "Licences: $I/share/licenses/ImageMagick$v/. Sources: the distfiles above (their SHA-256), the patches of the"
        echo "port at the commit above and tools/build-imagemagick.sh of https://github.com/azsupport/php-src"
        echo "(freebsd/imagemagick.conf)."
    } > "$res/$im.VERSIONS"
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
    if [ ! -f "$A/lib/pkgconfig/$pc.pc" ]; then
        printf '%-13s FAIL  no %s of the libraries in %s/lib/pkgconfig: build them first (tools/build-deps.sh)\n' libs "$pc" "$A" >> "$res/summary.txt"
        echo "build-imagemagick: no $A/lib/pkgconfig/$pc.pc; build the libraries first (tools/build-deps.sh)" >&2
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
