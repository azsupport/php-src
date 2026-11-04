#!/bin/sh
# imagemagick-test.sh - test ImageMagick 6 and 7 of tools/build-imagemagick.sh
# (the packages ImageMagick6 and ImageMagick7 of tools/build-az.sh, installed:
# /usr/local/bin/convert6, identify6, composite6...; magick) as the video sites
# use them, and that what freebsd/imagemagick.conf and
# freebsd/imagemagick/policy.xml leave out is refused.
#
# Usage (FreeBSD, as root):
#   sh tools/imagemagick-test.sh --samples   only make the samples (before our
#                                            ImageMagick 7 is installed in the
#                                            place of the package's)
#   sh tools/imagemagick-test.sh             the tests (with the samples made before, if any)
#
# The samples are made with the ImageMagick7 package (installed here, with its
# libheif for HEIC and AVIF) and the fonts of the dejavu package: JPEG (also a
# 4032x3024 photo and CMYK), PNG with alpha, WebP (lossy, lossless, animated),
# animated GIF, HEIC, AVIF. With each ImageMagick: identify; the conversions of a
# site (thumbnail to JPEG, resize to WebP, the first frame of an animation, all
# frames); a PNG watermark (composite); text (-annotate, label:) with a font that
# fontconfig finds; CMYK to sRGB. Refused: SVG, MVG, MSL, PostScript, EPS, PDF,
# TIFF, BMP, MNG, text:, label:@file, caption:@file, @file, inline:,
# http:, https:, ftp:, a file in /etc, a ../ path, standard input. The delegates
# built in (-version) must be those of the conf, and the policy ours.
#
# Results: imagemagick-results/tests.txt (one line per check, the summary at the
# end); exit status 0 when every check passed.

set -u
top="$(pwd)"
conf="$top/freebsd/imagemagick.conf"
res="$top/imagemagick-results"
T="${IM_TEST_WORK:-/var/tmp/imagemagick-test}"
ref=/usr/local/bin/magick
samples_only=""; [ "${1:-}" = --samples ] && samples_only=1
mkdir -p "$res"
have_samples=""
if [ -z "$samples_only" ] && [ -f "$T/.samples" ]; then have_samples=1; else rm -rf "$T"; mkdir -p "$T"; fi
out="$res/tests.txt"
[ -n "$samples_only" ] && out="$res/samples.txt"
: > "$out"
[ -n "$have_samples" ] && [ -f "$res/samples.txt" ] && grep -v '^samples: ' "$res/samples.txt" >> "$out"
ok=0; bad=0
pass() { echo "ok    $*" >> "$out"; ok=$((ok + 1)); }
fail() { echo "FAIL  $*" >> "$out"; bad=$((bad + 1)); }
note() { echo "note  $*" >> "$out"; }
finish() {
    echo "tests: $ok ok, $bad failed" >> "$out"
    cat "$out"
    [ "$bad" = 0 ]
    exit $?
}
last() { tail -n 2 "$1" | tr '\n' ' ' | sed "s#$T/##g"; }

# --- the samples --------------------------------------------------------------
if [ -z "$have_samples" ]; then
if [ ! -x "$ref" ]; then
    env ASSUME_ALWAYS_YES=yes pkg install -y ImageMagick7-nox11 dejavu > "$res/pkg-imagemagick.log" 2>&1 ||
        env ASSUME_ALWAYS_YES=yes pkg install -y ImageMagick7 dejavu >> "$res/pkg-imagemagick.log" 2>&1
fi
[ -x "$ref" ] || { fail "the ImageMagick7 package (for the samples) could not be installed: $(tail -n 2 "$res/pkg-imagemagick.log" | tr '\n' ' ')"; finish; }
note "samples made with $("$ref" -version | head -n 1)"
mk() {
    f="$1"; shift
    if "$ref" "$@" "$T/$f" > "$T/$f.log" 2>&1 && [ -s "$T/$f" ]; then
        echo "$f" >> "$T/samples"
    else
        note "sample $f: the package's ImageMagick cannot make it: $(last "$T/$f.log")"
    fi
}
: > "$T/samples"
mk photo.jpg -size 800x600 plasma:fractal -quality 90
mk big.jpg -size 4032x3024 gradient:navy-orange -quality 90
mk cmyk.jpg -size 400x300 gradient:red-blue -colorspace CMYK
mk logo.png -size 200x100 xc:none -fill red -draw "circle 100,50 100,10"
mk photo.webp -size 640x480 plasma:fractal -quality 80
mk lossless.webp -size 320x240 gradient:white-green -define webp:lossless=true
mk anim.webp -size 120x80 -delay 20 xc:red xc:green xc:blue
mk anim.gif -size 120x80 -delay 20 xc:red xc:green xc:blue
mk photo.heic -size 640x480 plasma:fractal -quality 80
mk photo.avif -size 640x480 plasma:fractal -quality 80
# made only to be refused
"$ref" -size 64x64 xc:gray "$T/no.tiff" > /dev/null 2>&1
"$ref" -size 64x64 xc:gray "$T/no.bmp" > /dev/null 2>&1
"$ref" -size 64x64 -delay 20 xc:red xc:green "$T/no.mng" > /dev/null 2>&1
printf '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>\n' > "$T/no.svg"
printf 'push graphic-context\nviewbox 0 0 10 10\nfill red\nrectangle 0,0 9,9\npop graphic-context\n' > "$T/no.mvg"
printf '<?xml version="1.0"?>\n<image><read filename="photo.jpg"/><write filename="msl-out.png"/></image>\n' > "$T/no.msl"
printf '%%!PS-Adobe-3.0\n%%%%BoundingBox: 0 0 10 10\nnewpath 0 0 moveto 10 10 lineto stroke showpage\n' > "$T/no.ps"
printf '%%!PS-Adobe-3.0 EPSF-3.0\n%%%%BoundingBox: 0 0 10 10\nnewpath 0 0 moveto 10 10 lineto stroke\n' > "$T/no.eps"
printf '%%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n2 0 obj << /Type /Pages /Kids [] /Count 0 >> endobj\ntrailer << /Root 1 0 R >>\n%%%%EOF\n' > "$T/no.pdf"
echo "a secret line" > "$T/secret.txt"
echo "$T/photo.jpg" > "$T/list.txt"
fi
if [ -n "$samples_only" ]; then
    touch "$T/.samples"
    echo "samples: $(wc -l < "$T/samples" | tr -d ' ') in $T" >> "$out"
    cat "$out"
    exit 0
fi

# --- each ImageMagick ----------------------------------------------------------
for im in $(awk '$1 == "im" { print $2 }' "$conf"); do
    pfx="${IM_PREFIX:-/usr/local}"
    v="${im#imagemagick}"
    if [ "$v" = 6 ]; then
        cv="$pfx/bin/convert6"; idf="$pfx/bin/identify6"; cps="$pfx/bin/composite6"
    else
        cv="$pfx/bin/magick"; idf="$pfx/bin/magick identify"; cps="$pfx/bin/magick composite"
    fi
    [ -x "$cv" ] || { fail "$im: no $cv (tools/build-imagemagick.sh first)"; continue; }
    w="$T/$im"; mkdir -p "$w"
    # what is built in, and whose policy
    "$cv" -version > "$w/version.txt" 2>&1
    dl="$(sed -n 's/^Delegates (built-in): *//p' "$w/version.txt")"
    miss=""; extra=""
    for d in fontconfig freetype heic jpeg lcms png webp zlib; do
        case " $dl " in *" $d "*) ;; *) miss="$miss $d" ;; esac
    done
    for d in bzlib cairo djvu fftw fpx gslib gvc jbig jxl lqr lzma openexr openjp2 pango ps raqm raw rsvg tiff wmf x xml zip zstd; do
        case " $dl " in *" $d "*) extra="$extra $d" ;; esac
    done
    if [ -z "$miss$extra" ]; then pass "$im: delegates: $dl"; else fail "$im: delegates: $dl (missing:${miss:- -}; not wanted:${extra:- -})"; fi
    "$cv" -list policy > "$w/policy.txt" 2>&1
    if grep -q "$pfx/etc/ImageMagick-$v/policy.xml" "$w/policy.txt"; then pass "$im: policy $pfx/etc/ImageMagick-$v/policy.xml"
    else fail "$im: not our policy: $(grep -m 1 -i 'path' "$w/policy.txt")"; fi
    # shellcheck disable=SC2086
    if "$cv" -list font 2>/dev/null | grep -q 'DejaVu-Sans'; then pass "$im: fontconfig finds DejaVu-Sans"
    else fail "$im: fontconfig finds no DejaVu-Sans"; fi

    while read -r s; do
        f="$T/$s"
        want="$(echo "${s##*.}" | tr a-z A-Z)"; [ "$want" = JPG ] && want=JPEG
        # shellcheck disable=SC2086
        got="$($idf -format '%m %wx%h\n' "$f" 2>"$w/id.err" | head -n 1)"
        case "$got" in "$want "*) pass "$im: identify $s: $got" ;; *) fail "$im: identify $s: ${got:-nothing} $(last "$w/id.err")" ;; esac
        # a thumbnail as the sites make them, and a resized WebP
        if "$cv" "${f}[0]" -auto-orient -thumbnail '320x240^' -gravity center -extent 320x240 -strip -quality 85 "$w/thumb-$s.jpg" > "$w/c.log" 2>&1; then
            # shellcheck disable=SC2086
            o="$($idf -format '%m %wx%h' "$w/thumb-$s.jpg" 2>/dev/null)"
            [ "$o" = "JPEG 320x240" ] && pass "$im: $s -> thumbnail $o" || fail "$im: $s -> thumbnail $o"
        else
            fail "$im: $s -> thumbnail: $(last "$w/c.log")"
        fi
        if "$cv" "${f}[0]" -resize 200x -quality 80 "$w/small-$s.webp" > "$w/c.log" 2>&1; then
            # shellcheck disable=SC2086
            o="$($idf -format '%m %w' "$w/small-$s.webp" 2>/dev/null)"
            [ "$o" = "WEBP 200" ] && pass "$im: $s -> WebP $o" || fail "$im: $s -> WebP $o"
        else
            fail "$im: $s -> WebP: $(last "$w/c.log")"
        fi
    done < "$T/samples"
    # every frame of the animations
    for s in anim.gif anim.webp; do
        [ -f "$T/$s" ] || continue
        if "$cv" "$T/$s" -coalesce -resize 60x "$w/frames-$s" > "$w/c.log" 2>&1; then
            # shellcheck disable=SC2086
            n="$($idf "$w/frames-$s" 2>/dev/null | wc -l | tr -d ' ')"
            [ "$n" = 3 ] && pass "$im: $s: all 3 frames" || fail "$im: $s: $n frames"
        else
            fail "$im: $s: frames: $(last "$w/c.log")"
        fi
    done
    # a PNG watermark, text, CMYK to sRGB
    # shellcheck disable=SC2086
    if $cps -gravity southeast -geometry +10+10 "$T/logo.png" "$T/photo.jpg" "$w/wm.jpg" > "$w/c.log" 2>&1 && [ -s "$w/wm.jpg" ]; then
        pass "$im: watermark (composite of a PNG)"
    else
        fail "$im: watermark: $(last "$w/c.log")"
    fi
    if "$cv" "$T/photo.jpg" -font DejaVu-Sans -pointsize 32 -fill white -gravity south -annotate +0+20 'video site' "$w/text.jpg" > "$w/c.log" 2>&1 && [ -s "$w/text.jpg" ]; then
        pass "$im: text (-annotate with DejaVu-Sans)"
    else
        fail "$im: text: $(last "$w/c.log")"
    fi
    if "$cv" -background none -fill black -font DejaVu-Sans -pointsize 24 label:'label text' "$w/label.png" > "$w/c.log" 2>&1 && [ -s "$w/label.png" ]; then
        pass "$im: label:"
    else
        fail "$im: label: $(last "$w/c.log")"
    fi
    if "$cv" "$T/cmyk.jpg" -colorspace sRGB "$w/srgb.jpg" > "$w/c.log" 2>&1; then
        # shellcheck disable=SC2086
        o="$($idf -format '%[colorspace]' "$w/srgb.jpg" 2>/dev/null)"
        [ "$o" = sRGB ] && pass "$im: CMYK -> $o" || fail "$im: CMYK -> $o"
    else
        fail "$im: CMYK -> sRGB: $(last "$w/c.log")"
    fi

    # refused: formats not built or not allowed, pseudo files, indirection, paths;
    # refused = an error and no output (../photo.jpg and /etc/... exist, so only the
    # policy can refuse them)
    cp "$T/photo.jpg" /etc/imagemagick-test.jpg 2>/dev/null
    mkdir -p "$w/sub"
    cp "$T/photo.jpg" "$w/photo.jpg"
    for x in "$T/no.svg" "svg:$T/no.svg" "$T/no.mvg" "mvg:$T/no.mvg" "msl:$T/no.msl" "$T/no.ps" "$T/no.eps" \
        "$T/no.pdf" "$T/no.tiff" "$T/no.bmp" "$T/no.mng" "text:$T/secret.txt" "txt:$T/secret.txt" \
        "label:@$T/secret.txt" "caption:@$T/secret.txt" "@$T/list.txt" \
        "inline:data:image/gif;base64,R0lGODlhAQABAAAAACw=" \
        "http://127.0.0.1:9/x.jpg" "https://127.0.0.1:9/x.jpg" "ftp://127.0.0.1:9/x.jpg" \
        "/etc/imagemagick-test.jpg" "../photo.jpg"; do
        case "$x" in
            *://*|inline:*|label:*|caption:*|@*|../*) ;;
            *) [ -e "${x#*:}" ] || [ -e "$x" ] || { note "$im: no $x to refuse"; continue; } ;;
        esac
        rm -f "$w/sub/no.png"
        (cd "$w/sub" && "$cv" "$x" "$w/sub/no.png") > "$w/c.log" 2>&1
        rc=$?
        if [ "$rc" = 0 ] || [ -s "$w/sub/no.png" ]; then
            fail "$im: read $(echo "$x" | sed "s#$T/##g") (exit $rc)"
        else
            pass "$im: refused $(echo "$x" | sed "s#$T/##g"): $(tail -n 1 "$w/c.log" | sed "s#$T/##g" | cut -c1-120)"
        fi
    done
    rm -f /etc/imagemagick-test.jpg
    rm -f "$w/stdin.png"
    cat "$T/photo.jpg" | "$cv" - "$w/stdin.png" > "$w/c.log" 2>&1
    rc=$?
    if [ "$rc" = 0 ] || [ -s "$w/stdin.png" ]; then
        fail "$im: read standard input (exit $rc)"
    else
        pass "$im: refused standard input: $(tail -n 1 "$w/c.log" | cut -c1-120)"
    fi
done
finish
