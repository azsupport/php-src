#!/bin/sh
# kvs-test.sh - the command lines the video sites (KVS 6.4.0) give to ffmpeg,
# ffprobe and ImageMagick, run on test files with the packages ffmpeg,
# ImageMagick6 and ImageMagick7 of the repository az: those of the vendor's
# release, of its media-security patch (6.3.0-7.0.3) and of our
# version, where they differ. Only the command lines: no code of KVS is here.
#
# What each call needs must work; what freebsd/ffmpeg.conf and
# freebsd/imagemagick/policy.xml leave out on purpose must be refused. A call
# that fails for a reason known and not ours is not a failure of the test:
#   gap   the build does not have it (a decision to take: GIF out of ffmpeg,
#         writing AVIF)
#   bug   the command line of KVS is wrong and fails with any build (the
#         vendor's \[0\] of the first frame, an operator before the image for
#         magick); the line says which version has it
#
# Usage (FreeBSD, as root; or with the KVS_* variables below anywhere):
#   sh tools/kvs-test.sh --samples   make the samples with the ffmpeg and
#                                    ImageMagick 7 of the ports (they have every
#                                    encoder), before the packages az replace them
#   sh tools/kvs-test.sh             the tests, with the samples made before
#
# KVS_FFMPEG, KVS_FFPROBE    ffmpeg and ffprobe (default /usr/local/bin/...)
# KVS_MAGICK                 ImageMagick 7 (default /usr/local/bin/magick; its
#                            convert, identify, montage next to it)
# KVS_CONVERT6               ImageMagick 6 (default /usr/local/bin/convert6; KVS
#                            takes identify and montage by replacing /convert
#                            in the path)
# KVS_TEST_WORK              the samples and the outputs (default /var/tmp/kvs-test)
#
# Results: kvs-results/tests.txt, one line per check ("ok", "FAIL", "gap", "bug",
# "skip"), the counts at the end; exit status 0 when nothing failed.

set -u
top="$(pwd)"
res="$top/kvs-results"
T="${KVS_TEST_WORK:-/var/tmp/kvs-test}"
S="$T/samples"
O="$T/out"
L="$T/log"
FF="${KVS_FFMPEG:-/usr/local/bin/ffmpeg}"
FP="${KVS_FFPROBE:-/usr/local/bin/ffprobe}"
IM7="${KVS_MAGICK:-/usr/local/bin/magick}"
IM6="${KVS_CONVERT6:-/usr/local/bin/convert6}"
BIN7="$(dirname "$IM7")"
mkdir -p "$res"

# --- the samples ------------------------------------------------------------------
if [ "${1:-}" = --samples ]; then
    rm -rf "$T"; mkdir -p "$S"
    out="$res/samples.txt"; : > "$out"
    n() { echo "note  $*" >> "$out"; }
    if [ ! -x "$FF" ] || [ ! -x "$IM7" ]; then
        env ASSUME_ALWAYS_YES=yes pkg install -y ffmpeg-nox11 ImageMagick7-nox11 dejavu > "$res/pkg.log" 2>&1 ||
            env ASSUME_ALWAYS_YES=yes pkg install -y ffmpeg ImageMagick7 dejavu >> "$res/pkg.log" 2>&1
    fi
    [ -x "$FF" ] || { n "no $FF to make the samples with"; cat "$out"; exit 1; }
    n "samples made with $("$FF" -hide_banner -version | head -n 1)"
    rim="$IM7"; [ -x "$rim" ] || rim="$(command -v convert)"
    n "pictures made with $("$rim" -version 2>/dev/null | head -n 1)"
    av="-f lavfi -i testsrc2=size=640x360:rate=25:duration=4 -f lavfi -i sine=frequency=440:sample_rate=48000:duration=4"
    vo="-f lavfi -i testsrc2=size=640x360:rate=25:duration=4"
    x264="-c:v libx264 -preset veryfast -pix_fmt yuv420p"
    x265="-c:v libx265 -preset ultrafast -tag:v hvc1"
    if "$FF" -hide_banner -encoders 2>/dev/null | grep -q ' libsvtav1 '; then av1="-c:v libsvtav1 -preset 12"; else av1="-c:v libaom-av1 -cpu-used 8"; fi
    # mk <file> <ffmpeg options before the file>: a sample, noted when it cannot be made
    mk() {
        f="$1"; shift
        # shellcheck disable=SC2068
        "$FF" -hide_banner -loglevel error -y $@ "$S/$f" > "$S/$f.log" 2>&1 && [ -s "$S/$f" ] && rm -f "$S/$f.log" ||
            n "sample $f: $(tail -n 1 "$S/$f.log")"
    }
    # shellcheck disable=SC2086
    {
        mk v_h264_aac.mp4 $av $x264 -c:a aac
        mk v_h264_noaudio.mp4 $vo $x264
        mk v_h264_10.mp4 $av -c:v libx264 -preset veryfast -pix_fmt yuv420p10le -c:a aac
        mk v_hevc_aac.mp4 $av $x265 -c:a aac
        mk v_hevc10.mov $av $x265 -pix_fmt yuv420p10le -c:a aac
        mk v_av1_opus.mkv $av $av1 -c:a libopus
        mk v_av1_aac.mp4 $av $av1 -c:a aac
        mk v_vp9_opus.webm $av -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -c:a libopus
        mk v_vp8_vorbis.webm $av -c:v libvpx -deadline realtime -cpu-used 8 -c:a libvorbis
        mk v_h264_mp3.mp4 $av $x264 -c:a libmp3lame
        mk v_h264_ac3.mkv $av $x264 -c:a ac3
        mk v_h264_eac3.mp4 $av $x264 -c:a eac3
        mk v_mjpeg_pcm.mov $av -c:v mjpeg -pix_fmt yuvj422p -c:a pcm_s16le
        mk v_sar.mp4 $av -vf scale=480:360,setsar=4/3 $x264 -c:a aac
        mk v_pre.mp4 -f lavfi -i testsrc2=size=320x240:rate=25:duration=2 $x264
        mk v_post.mp4 -f lavfi -i testsrc2=size=1280x720:rate=25:duration=2 -f lavfi -i sine=frequency=880:sample_rate=44100:duration=2 $x264 -c:a aac
        mk v_video_only.mp4 $vo $x264
        mk v_audio_only.m4a -f lavfi -i sine=frequency=440:sample_rate=48000:duration=4 -c:a aac
        # MPEG-TS has no index: ffmpeg seeks into it and decodes from the next keyframe,
        # so one every second, as in HLS segments and camera files
        mk v_ts.mp4 $av $x264 -g 25 -c:a aac -f mpegts
        mk v_test.avi $av -c:v mpeg4 -c:a pcm_s16le -f avi
        mk v_vp9_aac.mp4 $av -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -c:a aac
        mk v_pre_vp9.mp4 -f lavfi -i testsrc2=size=320x240:rate=25:duration=2 -c:v libvpx-vp9 -deadline realtime -cpu-used 8
    }
    printf '1\n00:00:00,000 --> 00:00:02,000\nsubtitle\n\n' > "$S/sub.srt"
    # shellcheck disable=SC2086
    {
        mk v_h264_sub.mp4 $av -i "$S/sub.srt" -map 0:v -map 1:a -map 2:s $x264 -c:a aac -c:s mov_text
        mk v_h264_srt.mkv $av -i "$S/sub.srt" -map 0:v -map 1:a -map 2:s $x264 -c:a aac -c:s srt
    }
    [ -f "$S/v_h264_aac.mp4" ] && mk v_rot90.mp4 -display_rotation:v:0 90 -i "$S/v_h264_aac.mp4" -c copy
    # pictures
    pk() {
        f="$1"; shift
        "$rim" "$@" > "$S/$f.log" 2>&1 && [ -s "$S/$f" ] && rm -f "$S/$f.log" || { n "picture $f: $(tail -n 1 "$S/$f.log")"; rm -f "$S/$f"; }
    }
    pk i_photo.jpg -size 800x600 plasma:fractal -quality 90 "$S/i_photo.jpg"
    # EXIF Orientation 6 (turned 90 degrees): an APP1 segment of 34 bytes after the SOI
    [ -s "$S/i_photo.jpg" ] && { printf '\377\330\377\341\000\042Exif\000\000II*\000\010\000\000\000\001\000\022\001\003\000\001\000\000\000\006\000\000\000\000\000\000\000'
        tail -c +3 "$S/i_photo.jpg"; } > "$S/i_orient6.jpg"
    pk i_alpha.png -size 300x200 xc:none -fill red -draw "circle 150,100 150,20" "$S/i_alpha.png"
    pk i_wm.png -size 120x40 xc:none -fill '#ffffff80' -draw 'roundrectangle 2,2 118,38 8,8' "$S/i_wm.png"
    pk i_static.gif -size 200x150 xc:blue "$S/i_static.gif"
    pk i_anim.gif -size 200x150 -delay 20 xc:red xc:green xc:blue -loop 0 "$S/i_anim.gif"
    pk i_static.webp "$S/i_photo.jpg" -quality 80 "webp:$S/i_static.webp"
    pk i_anim.webp "$S/i_anim.gif" -quality 80 "webp:$S/i_anim.webp"
    pk i_photo.avif "$S/i_photo.jpg" -quality 60 "avif:$S/i_photo.avif"
    pk i_photo.heic "$S/i_photo.jpg" -quality 60 "heic:$S/i_photo.heic"
    [ -f "$S/v_h264_aac.mp4" ] && [ -f "$S/i_photo.jpg" ] &&
        mk v_cover.mp4 -i "$S/v_h264_aac.mp4" -i "$S/i_alpha.png" -map 0 -map 1 -c copy -c:v:1 png -disposition:v:1 attached_pic
    touch "$T/.samples"
    echo "samples: $(ls "$S" | grep -c -v '\.log$') in $S" >> "$out"
    cat "$out"
    exit 0
fi

# --- the checks ---------------------------------------------------------------------
[ -f "$T/.samples" ] || { echo "no samples in $T: sh tools/kvs-test.sh --samples first"; exit 2; }
rm -rf "$O" "$L"; mkdir -p "$O" "$L"
out="$res/tests.txt"; : > "$out"
[ -f "$res/samples.txt" ] && grep -v '^samples: ' "$res/samples.txt" >> "$out"
n_ok=0; n_fail=0; n_gap=0; n_bug=0; n_skip=0
line() { echo "$*" >> "$out"; }
note() { line "note  $*"; }
skip() { line "skip  $*"; n_skip=$((n_skip + 1)); }
last() { tail -n 2 "$1" 2>/dev/null | tr '\n' ' ' | sed "s#$T/##g" | cut -c1-200; }
# x <id> <command...>: run it, its output in $L/<id>.log, its status in $rc
# (the helpers keep their variables to names with _: sh has no local ones)
x() { _xi="$1"; shift; "$@" > "$L/$_xi.log" 2>&1; rc=$?; }
# v <id> <want> <label> <0 when the result is what KVS needs> [detail]
#   want: ok; no:<why> (must be refused); gap:<why>; bug:<why>
v() {
    _vi="$1"; _vw="$2"; _vl="$3"; _vc="$4"; _vd="${5:-}"
    case "$_vw" in
        ok)
            if [ "$_vc" = 0 ]; then line "ok    $_vi $_vl${_vd:+: $_vd}"; n_ok=$((n_ok + 1))
            else line "FAIL  $_vi $_vl: ${_vd:+$_vd; }$(last "$L/$_vi.log")"; n_fail=$((n_fail + 1)); fi ;;
        no:*)
            if [ "$_vc" = 0 ]; then line "FAIL  $_vi $_vl: not refused (${_vw#no:})"; n_fail=$((n_fail + 1))
            else line "ok    $_vi $_vl: refused, ${_vw#no:}"; n_ok=$((n_ok + 1)); fi ;;
        gap:*|bug:*)
            _vk="${_vw%%:*}"
            if [ "$_vc" = 0 ]; then line "ok    $_vi $_vl${_vd:+: $_vd} (works here: $_vk ${_vw#*:})"; n_ok=$((n_ok + 1))
            else line "$_vk   $_vi $_vl: ${_vw#*:} [$(last "$L/$_vi.log")]"
                if [ "$_vk" = gap ]; then n_gap=$((n_gap + 1)); else n_bug=$((n_bug + 1)); fi; fi ;;
    esac
}
have() { [ -s "$S/$1" ]; }
# the streams of a video as this ffprobe sees them: "format codec,codec..."
probe() {
    "$FP" -v error -show_entries format=format_name:stream=codec_name -of default=nw=1 "$1" 2>/dev/null |
        awk -F= '$1 == "format_name" { f = $2 } $1 == "codec_name" { c = c (c ? "," : "") $2 } END { print f, c }'
}
dims() { "$FP" -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$1" 2>/dev/null; }
pixf() { "$FP" -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$1" 2>/dev/null; }
dur() { "$FP" -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null | cut -d. -f1; }
# identify for the checks (ImageMagick 7 when there is one)
idc() { if [ -x "$IM7" ]; then "$IM7" identify "$@"; else "$(echo "$IM6" | sed 's#/convert#/identify#')" "$@"; fi; }
img() { idc -format '%m %wx%h\n' "$1" 2>/dev/null | head -n 1; }
frames() { idc "$1" 2>/dev/null | awk 'END { print NR }'; }

note "ffmpeg: $("$FF" -hide_banner -version 2>&1 | head -n 1)"
for p in "$IM7" "$IM6"; do [ -x "$p" ] && note "$p: $("$p" -version 2>&1 | head -n 1)"; done

# --- the site: video checks, duration, size, screenshots (main server) ---------------
# The vendor's release reads videos with plain ffmpeg -i; the patch puts the whitelists
# of setup.php before every input (defaults when setup.php has none), and first asks
# ffprobe: a "not on whitelist" there rejects the upload.
#   off  the release: no whitelists
#   pat  the patch, its defaults
#   prg  our version, its defaults (no libdav1d, libaom-av1, mp2, mp3on4)
#   set  the lists we put into setup.php
WL_PAT_C="h264,hevc,av1,libdav1d,libaom-av1,vp9,vp8,mp2,mpeg4,wmv1,wmv2,wmv3,vc1,mjpeg,aac,mp3,mp3float,mp3on4,mp3on4float,opus,vorbis,flac,ac3,eac3,wmav1,wmav2,wmapro,pcm_s16le,pcm_s24le,pcm_f32le"
WL_PRG_C="h264,hevc,av1,vp9,vp8,mpeg4,wmv1,wmv2,wmv3,vc1,mjpeg,aac,mp3,mp3float,opus,vorbis,flac,ac3,eac3,wmav1,wmav2,wmapro,pcm_s16le,pcm_s24le,pcm_f32le"
WL_DEF_F="mov,matroska,avi,asf,mp3,aac,flac,wav,ogg"
WL_SET_C="h264,hevc,av1,libdav1d,vp9,vp8,aac,mp3,mp3float,opus,vorbis,ac3,eac3,mov_text,srt,subrip"
WL_SET_F="mov,matroska"
# the decoders our ffmpeg uses for each sample (AV1: libdav1d; MP3: mp3float; the
# subtitles have no decoder, so no whitelist sees them)
decs() {
    case "$1" in
        v_av1_*) echo libdav1d ;;
        *) echo "" ;;
    esac
    case "$1" in
        v_h264_mp3.mp4) echo "h264 mp3float" ;; v_h264_ac3.mkv) echo "h264 ac3" ;; v_h264_eac3.mp4) echo "h264 eac3" ;;
        v_h264_noaudio.mp4|v_pre.mp4|v_video_only.mp4) echo h264 ;; v_hevc*) echo "hevc aac" ;; v_av1_opus.mkv) echo opus ;;
        v_av1_aac.mp4) echo aac ;; v_vp9_opus.webm) echo "vp9 opus" ;; v_vp8_vorbis.webm) echo "vp8 vorbis" ;;
        v_mjpeg_pcm.mov) echo "mjpeg pcm_s16le" ;; v_cover.mp4) echo "h264 aac png" ;;
        v_h264_sub.mp4) echo "h264 aac${SUBDEC:+ mov_text}" ;; v_h264_srt.mkv) echo "h264 aac${SUBDEC:+ srt}" ;; *) echo "h264 aac" ;;
    esac
}
# a demuxer or decoder this ffmpeg has (the list of -demuxers / -decoders)
built() { "$FF" -hide_banner "-$1s" 2>/dev/null | awk 'f { print $2 } /^ *-+ *$/ { f = 1 }' | tr ',' '\n' | grep -qx "$2"; }
SUBDEC=""; built decoder mov_text && SUBDEC=1
inlist() { case ",$2," in *",$1,"*) return 0 ;; esac; return 1; }
# want <variant> <sample>: what the variant must do with the sample
want() {
    [ "$1" = off ] && { echo ok; return; }
    case "$1" in pat) c="$WL_PAT_C"; f="$WL_DEF_F" ;; prg) c="$WL_PRG_C"; f="$WL_DEF_F" ;; set) c="$WL_SET_C"; f="$WL_SET_F" ;; esac
    case "$2" in *.mkv|*.webm) m=matroska ;; v_ts.mp4) m=mpegts ;; *) m=mov ;; esac
    inlist "$m" "$f" || { echo "no:container $m not in the whitelist"; return; }
    for k in $(decs "$2"); do
        inlist "$k" "$c" && continue
        case "$1:$k" in
            prg:libdav1d) echo "bug:our default list has av1 but not libdav1d, the only AV1 decoder (only without video_allowed_codecs in setup.php)" ;;
            *) echo "no:$k not in the whitelist" ;;
        esac
        return
    done
    echo ok
}
for s in v_h264_aac.mp4 v_h264_noaudio.mp4 v_h264_10.mp4 v_hevc_aac.mp4 v_hevc10.mov v_av1_opus.mkv v_av1_aac.mp4 \
    v_vp9_opus.webm v_vp8_vorbis.webm v_h264_mp3.mp4 v_h264_ac3.mkv v_h264_eac3.mp4 v_mjpeg_pcm.mov v_h264_sub.mp4 \
    v_h264_srt.mkv v_rot90.mp4 v_sar.mp4 v_cover.mp4 v_ts.mp4; do
    have "$s" || { skip "site $s: no sample"; continue; }
    if [ "$s" = v_ts.mp4 ] && ! built demuxer mpegts; then skip "site $s: no MPEG-TS demuxer in this build"; continue; fi
    f="$S/$s"
    for w in off pat prg set; do
        id="site-$w-${s%.*}"
        case "$w" in
            off) wl="" ;;
            pat) wl="-protocol_whitelist file -format_whitelist $WL_DEF_F -codec_whitelist $WL_PAT_C" ;;
            prg) wl="-protocol_whitelist file -format_whitelist $WL_DEF_F -codec_whitelist $WL_PRG_C" ;;
            set) wl="-protocol_whitelist file -format_whitelist $WL_SET_F -codec_whitelist $WL_SET_C" ;;
        esac
        ww="$(want "$w" "$s")"
        if [ "$w" != off ]; then
            # the check of the patch: ffprobe -show_streams, "not on whitelist" rejects it
            # shellcheck disable=SC2086
            x "$id-check" "$FP" $wl -i "$f" -show_streams
            c=1; [ "$rc" = 0 ] && ! grep -q 'not on whitelist' "$L/$id-check.log" && c=0
            v "$id-check" "$ww" "site $w: ffprobe -show_streams $s" "$c"
            case "$ww" in no:*|bug:*|gap:*) continue ;; esac
        fi
        # duration: ffmpeg -i (no output: exit 1 by design), Duration: in its output
        # shellcheck disable=SC2086
        x "$id-dur" "$FF" $wl -i "$f"
        c=1; grep -q 'Duration: 00:00:0[1-9]' "$L/$id-dur.log" && grep -q 'Video:' "$L/$id-dur.log" && c=0
        v "$id-dur" ok "site $w: ffmpeg -i $s (duration, video)" "$c"
        # size: one frame at 1 s into a JPEG, then its size
        rm -f "$O/$id.jpg"
        # shellcheck disable=SC2086
        x "$id-size" "$FF" $wl -i "$f" -ss 1 -vframes 1 -y -f mjpeg -qscale 1 -vf 'scale=trunc(iw*sar/2)*2:ih' "$O/$id.jpg"
        g="$(img "$O/$id.jpg")"; c=1; case "$g" in "JPEG "*) c=0 ;; esac
        v "$id-size" ok "site $w: ffmpeg -ss 1 -vframes 1 -f mjpeg $s" "$c" "$g"
        # the screenshot, fast (-ss before -i) and slow
        rm -f "$O/$id-f.jpg" "$O/$id-s.jpg"
        # shellcheck disable=SC2086
        x "$id-shot" "$FF" $wl -ss 2 -i "$f" -vframes 1 -y -f mjpeg -qscale 1 -vf 'scale=trunc(iw*sar/2)*2:ih' "$O/$id-f.jpg"
        # shellcheck disable=SC2086
        "$FF" $wl -i "$f" -ss 2 -vframes 1 -y -f mjpeg -qscale 1 -vf 'scale=trunc(iw*sar/2)*2:ih' "$O/$id-s.jpg" >> "$L/$id-shot.log" 2>&1
        c=1; [ "$(img "$O/$id-f.jpg" | cut -c1-4)$(img "$O/$id-s.jpg" | cut -c1-4)" = JPEGJPEG ] && c=0
        v "$id-shot" ok "site $w: screenshot fast and slow $s" "$c" "$(img "$O/$id-f.jpg")"
        if [ "$w" != off ]; then
            # shellcheck disable=SC2086
            x "$id-meta" "$FP" $wl -i "$f" -show_streams -select_streams v:0
            c=1; grep -q '^width=[1-9]' "$L/$id-meta.log" && grep -q '^avg_frame_rate=' "$L/$id-meta.log" && c=0
            v "$id-meta" ok "site $w: ffprobe -show_streams -select_streams v:0 $s" "$c"
        fi
    done
done
# a playlist named .mp4 never reaches ffmpeg in the patch (EXTM3U in its first bytes);
# a container we do not build is refused by ffmpeg itself
for s in v_test.avi; do
    have "$s" || continue
    if built demuxer avi; then skip "site off: $s: this ffmpeg has the demuxer avi (not the build of az)"; continue; fi
    x "site-off-${s%.*}" "$FF" -i "$S/$s"
    c=1; grep -q 'Duration:' "$L/site-off-${s%.*}.log" && c=0
    v "site-off-${s%.*}" "no:not built (freebsd/ffmpeg.conf)" "site off: ffmpeg -i $s" "$c"
done

# --- ImageMagick: the class of the site and the screenshots ------------------------------
# The image path of KVS (image_magick_path): magick (the default of 6.4.0: "magick
# identify", "magick montage"), convert next to magick (ImageMagick 7: identify and
# montage by replacing /convert), convert6 (ImageMagick 6: identify6, montage6).
#   off  the release: no format before the inputs
#   pat  the patch (= our version): jpeg:, png:, gif:, webp:, avif: before them
fls=""
[ -x "$IM7" ] && fls="$fls 7"
[ -x "$BIN7/convert" ] && "$BIN7/convert" -version 2>/dev/null | grep -q 'ImageMagick 7' && fls="$fls 7c"
[ -x "$IM6" ] && fls="$fls 6"
[ -n "$fls" ] || skip "ImageMagick: no $IM7, $BIN7/convert or $IM6"
KP=""
cv() { "$KP" "$@"; }
idn() { case "$KP" in */convert*) "$(echo "$KP" | sed 's#/convert#/identify#g')" "$@" ;; *) "$KP" identify "$@" ;; esac; }
mtg() { case "$KP" in */convert*) "$(echo "$KP" | sed 's#/convert#/montage#g')" "$@" ;; *) "$KP" montage "$@" ;; esac; }
type_of() { case "$1" in *.jpg) echo jpeg ;; *.png) echo png ;; *.gif) echo gif ;; *.webp) echo webp ;; *.avif) echo avif ;; esac; }
for fl in $fls; do
    case "$fl" in 7) KP="$IM7" ;; 7c) KP="$BIN7/convert" ;; 6) KP="$IM6" ;; esac
    for k in off pat; do
        p() { if [ "$k" = pat ]; then echo "$(type_of "$1"):$1"; else echo "$1"; fi; }
        id="im$fl-$k"
        # the size of an AVIF (getimagesize knows no AVIF size): identify -format %wx%h
        if have i_photo.avif; then
            x "$id-avifsize" idn -format '%wx%h' "$(p "$S/i_photo.avif")"
            c=1; [ "$(tail -n 1 "$L/$id-avifsize.log")" = 800x600 ] && c=0
            v "$id-avifsize" ok "im$fl $k: identify -format %wx%h avif" "$c" "$(tail -n 1 "$L/$id-avifsize.log")"
        fi
        # can it write WebP and AVIF (into .jpg names, as KVS checks it)
        rm -f "$O/$id-w.jpg" "$O/$id-a.jpg"
        x "$id-webp" cv "$(p "$S/i_photo.jpg")" "webp:$O/$id-w.jpg"
        c=1; case "$(img "$O/$id-w.jpg")" in "WEBP "*) c=0 ;; esac
        v "$id-webp" ok "im$fl $k: jpeg -> webp: (supports WebP)" "$c"
        x "$id-avif" cv "$(p "$S/i_photo.jpg")" "avif:$O/$id-a.jpg"
        c=1; case "$(img "$O/$id-a.jpg")" in "AVIF "*) c=0 ;; esac
        v "$id-avif" "gap:no AV1 encoder in libheif of az (writing AVIF: aZ's open question)" "im$fl $k: jpeg -> avif: (supports AVIF)" "$c"
        # animated GIF and WebP: identify lists the frames
        for s in i_anim.gif i_static.gif i_anim.webp i_static.webp; do
            have "$s" || continue
            x "$id-frames-$(echo "$s" | tr . _)" idn "$(p "$S/$s")"
            nf="$(awk 'END { print NR }' "$L/$id-frames-$(echo "$s" | tr . _).log")"
            case "$s" in i_anim*) wf=3 ;; *) wf=1 ;; esac
            c=1; [ "$rc" = 0 ] && [ "$nf" = "$wf" ] && c=0
            v "$id-frames-$(echo "$s" | tr . _)" ok "im$fl $k: identify $s: $nf frames" "$c"
        done
        # transparency of a WebP: its first frame into a PNG
        rm -f "$O/$id-t.png"
        x "$id-transp" cv "$(p "$S/i_anim.webp")[0]" "$O/$id-t.png"
        c=1; [ "$(img "$O/$id-t.png" | cut -d' ' -f1)" = PNG ] && [ "$(frames "$O/$id-t.png")" = 1 ] && c=0
        v "$id-transp" ok "im$fl $k: webp[0] -> png" "$c"
        # montage of two pictures side by side
        rm -f "$O/$id-m.jpg"
        x "$id-montage" mtg "$(p "$S/i_photo.jpg")" "$(p "$S/i_photo.jpg")" -tile 2x1 -geometry +0+0 "$O/$id-m.jpg"
        g="$(img "$O/$id-m.jpg")"; c=1; [ "$g" = "JPEG 1600x600" ] && c=0
        v "$id-montage" ok "im$fl $k: montage -tile 2x1 -geometry +0+0" "$c" "$g"
        # crop and trim
        rm -f "$O/$id-c.jpg"
        x "$id-crop" cv "$(p "$S/i_photo.jpg")" -crop 700x500+50+50 -fuzz 7% -trim "$O/$id-c.jpg"
        c=1; case "$(img "$O/$id-c.jpg")" in "JPEG "*) c=0 ;; esac
        v "$id-crop" ok "im$fl $k: -crop -fuzz 7% -trim" "$c" "$(img "$O/$id-c.jpg")"
        # EXIF orientation, -auto-orient into the same file
        if have i_orient6.jpg; then
            cp "$S/i_orient6.jpg" "$O/$id-o.jpg"
            x "$id-orient" idn -format '%[exif:orientation]' "$(p "$O/$id-o.jpg")"
            o="$(tail -n 1 "$L/$id-orient.log")"
            cv "$(p "$O/$id-o.jpg")" -auto-orient "$O/$id-o.jpg" >> "$L/$id-orient.log" 2>&1
            g="$(img "$O/$id-o.jpg")"; c=1; [ "$o" = 6 ] && [ "$g" = "JPEG 600x800" ] && c=0
            v "$id-orient" ok "im$fl $k: exif:orientation $o, -auto-orient" "$c" "$g"
        fi
        # an animated GIF: all frames for a GIF or WebP target
        rm -f "$O/$id-co.gif"
        x "$id-coalesce" cv "$(p "$S/i_anim.gif")" -coalesce -repage 0x0 "$O/$id-co.gif"
        c=1; [ "$(frames "$O/$id-co.gif")" = 3 ] && c=0
        v "$id-coalesce" ok "im$fl $k: gif -coalesce -repage 0x0" "$c"
        # resize to a fixed size (the first frame of an animation for a JPEG target) and
        # to a maximum size; WebP into a .jpg name when the site tries WebP
        for s in i_photo.jpg i_alpha.png i_anim.gif i_static.webp i_anim.webp i_photo.avif; do
            have "$s" || continue
            fr=""; case "$s" in i_anim*) fr="[0]" ;; esac
            bg=black; case "$s" in i_alpha.png|i_anim.gif) bg=none ;; esac
            rm -f "$O/$id-fix-$s.jpg" "$O/$id-max-$s.jpg" "$O/$id-wfix-$s.jpg"
            x "$id-fix-$(echo "$s" | tr . _)" cv "$(p "$S/$s")$fr" -quality 80 -resize 321x241 -background "$bg" -gravity center -extent 320x180 "$O/$id-fix-$s.jpg"
            g="$(img "$O/$id-fix-$s.jpg")"; c=1; [ "$g" = "JPEG 320x180" ] && c=0
            v "$id-fix-$(echo "$s" | tr . _)" ok "im$fl $k: $s$fr -resize -extent 320x180 -> jpg" "$c" "$g"
            x "$id-wfix-$(echo "$s" | tr . _)" cv "$(p "$S/$s")$fr" -quality 80 -resize 321x241 -background "$bg" -gravity center -extent 320x180 "webp:$O/$id-wfix-$s.jpg"
            g="$(img "$O/$id-wfix-$s.jpg")"; c=1; [ "$g" = "WEBP 320x180" ] && c=0
            v "$id-wfix-$(echo "$s" | tr . _)" ok "im$fl $k: $s$fr -extent 320x180 -> webp:" "$c" "$g"
            x "$id-max-$(echo "$s" | tr . _)" cv "$(p "$S/$s")$fr" -quality 80 -resize '240x160^' -gravity center -crop 240x160+0+0 +repage "$O/$id-max-$s.jpg"
            g="$(img "$O/$id-max-$s.jpg")"; c=1; [ "$g" = "JPEG 240x160" ] && c=0
            v "$id-max-$(echo "$s" | tr . _)" ok "im$fl $k: $s$fr -resize ^ -crop +repage -> jpg" "$c" "$g"
        done
        # an animated GIF into an animated GIF and WebP (after -coalesce)
        if [ -s "$O/$id-co.gif" ]; then
            for e in gif webp; do
                rm -f "$O/$id-anim.$e"
                x "$id-anim-$e" cv "gif:$O/$id-co.gif" -quality 80 -resize 101x76 -background none -gravity center -extent 100x75 "$O/$id-anim.$e"
                c=1; [ "$(frames "$O/$id-anim.$e")" = 3 ] && c=0
                v "$id-anim-$e" ok "im$fl $k: animated gif -> $e, 3 frames" "$c" "$(img "$O/$id-anim.$e")"
            done
        fi
    done

    # the screenshot of the site (and the image of an album): the template of the
    # format (im_options of 6.4.0) into a BMP, the blurred background, the canvas, the
    # watermark, -comment, the target type (0 JPEG, 1 WebP, 2 AVIF)
    imo="-enhance -strip -unsharp 1.0x1.0+0.5 -unsharp 1.0x1.0+0.5 -modulate 110,102,100 -unsharp 1.0x1.0+0.5 -contrast -gamma 1.2 -resize 321x181 -filter Lanczos -filter Blackman -quality 80"
    for k in off prg; do
        id="shot$fl-$k"
        for s in i_photo.jpg i_anim.gif i_anim.webp; do
            have "$s" || continue
            # the first frame of an animation: \[0\] in the vendor's code, [0] in ours
            fr=""; case "$s:$k" in i_anim*:off) fr='\[0\]' ;; i_anim*:prg) fr='[0]' ;; esac
            ws=ok; case "$s:$k" in i_anim*:off) ws='bug:the vendor writes the first frame as \[0\] (fixed in ours), any ImageMagick fails' ;; esac
            rm -f "$O/$id-$(echo "$s" | tr . _).bmp"
            # shellcheck disable=SC2086
            x "$id-tpl-$(echo "$s" | tr . _)" cv "$S/$s$fr" $imo "$O/$id-$(echo "$s" | tr . _).bmp"
            g="$(img "$O/$id-$(echo "$s" | tr . _).bmp")"; c=1; case "$g" in "BMP "*) c=0 ;; esac
            v "$id-tpl-$(echo "$s" | tr . _)" "$ws" "shot$fl $k: $s$fr im_options -> bmp" "$c" "$g"
        done
        b="$O/$id-i_photo_jpg.bmp"
        [ -s "$b" ] || { skip "shot$fl $k: no BMP of the template"; continue; }
        # the blurred background: the vendor puts -resize before the image (magick: no images)
        rm -f "$O/$id-bg.bmp"
        if [ "$k" = off ]; then
            x "$id-bg" cv -resize '320x180^' -gravity center -extent 320x180 "$b" -blur 0x6 -modulate 100,60 "$O/$id-bg.bmp"
        else
            x "$id-bg" cv "$b" -resize '320x180^' -gravity center -extent 320x180 -blur 0x6 -modulate 100,60 "$O/$id-bg.bmp"
        fi
        wb=ok; [ "$k:$fl" = off:7 ] && wb='bug:the vendor puts -resize before the image; magick wants the image first (fixed in ours)'
        g="$(img "$O/$id-bg.bmp")"; c=1; [ "$g" = "BMP 320x180" ] && c=0
        v "$id-bg" "$wb" "shot$fl $k: blurred background bmp" "$c" "$g"
        bgi="xc:#000000"; [ -s "$O/$id-bg.bmp" ] && bgi="$O/$id-bg.bmp"
        for t in jpg webp avif; do
            rm -f "$O/$id-final.$t"
            case "$t" in jpg) tp="" ;; webp) tp="webp:" ;; avif) tp="avif:" ;; esac
            x "$id-final-$t" cv -quality 80 -interlace plane -comment kvs-test -size 320x180 "$bgi" "$b" -gravity center -composite \
                "$S/i_wm.png" -gravity SouthEast -composite "$tp$O/$id-final.$t"
            g="$(img "$O/$id-final.$t")"; c=1
            case "$t:$g" in "jpg:JPEG 320x180"|"webp:WEBP 320x180"|"avif:AVIF 320x180") c=0 ;; esac
            wt=ok; [ "$t" = avif ] && wt="gap:no AV1 encoder in libheif of az (a screenshot format of type AVIF fails)"
            v "$id-final-$t" "$wt" "shot$fl $k: canvas + bmp + watermark -composite -> $t" "$c" "$g"
        done
        x "$id-xc" cv -quality 80 -size 320x180 'xc:#000000' "$b" -gravity center -composite "$O/$id-xc.jpg"
        g="$(img "$O/$id-xc.jpg")"; c=1; [ "$g" = "JPEG 320x180" ] && c=0
        v "$id-xc" ok "shot$fl $k: xc:#000000 + bmp -composite" "$c" "$g"
    done
    # the comment of a format goes in as it is: @file must not put a file into the picture
    rm -f "$O/cm$fl.jpg"
    x "shot$fl-comment" cv -quality 80 -comment @/etc/passwd -size 320x180 'xc:#000000' "$S/i_photo.jpg" -gravity center -composite "$O/cm$fl.jpg"
    c=1; [ -s "$O/cm$fl.jpg" ] && idc -format '%c' "$O/cm$fl.jpg" 2>/dev/null | grep -q 'root:' && c=0
    v "shot$fl-comment" "no:the policy forbids @file" "shot$fl: -comment @/etc/passwd" "$c"
done

# --- the conversion servers (remote_cron.php): sources, formats, screenshots, rolls -------
# the default formats of 6.4.0 (install_db.sql); KVS puts -pix_fmt yuv420p first when
# the options have no -pix_fmt
fmt_main="-pix_fmt yuv420p -vcodec libx264 -movflags +faststart -threads 0 -r 25 -g 50 -crf 25 -me_method hex -trellis 0 -bf 8 -acodec aac -strict -2 -ar 44100 -ab 128k -f mp4"
fmt_prev="-pix_fmt yuv420p -vcodec libx264 -movflags +faststart -threads 0 -r 25 -g 50 -crf 25 -me_method hex -trellis 0 -bf 8 -an -f mp4"
# the checks of the programs: ffmpeg -version, ImageMagick without arguments, ffprobe -version
x "conv-version" "$FF" -version; c=1; grep -q 'ffmpeg version ' "$L/conv-version.log" && c=0
v conv-version ok "conv: ffmpeg -version has 'ffmpeg version '" "$c"
x "conv-ffprobe" "$FP" -version; c=1; grep -q 'ffprobe version ' "$L/conv-ffprobe.log" && c=0
v conv-ffprobe ok "conv: ffprobe -version" "$c"
for p in "$IM7" "$BIN7/convert" "$IM6"; do
    [ -x "$p" ] || continue
    x "conv-im-${p##*/}" "$p"; c=1; grep -qi 'imagemagick' "$L/conv-im-${p##*/}.log" && c=0
    v "conv-im-${p##*/}" ok "conv: $p without arguments names ImageMagick" "$c"
done
# multiple sources into one: the format of the first (ffprobe -show_format), a concat
# list, -c copy -f <that format>
join() {
    _ji="$1"; _jw="$2"; shift 2
    : > "$O/$_ji.txt"
    for _js in "$@"; do have "$_js" || { skip "$_ji: no $_js"; return; }; echo "file '$S/$_js'" >> "$O/$_ji.txt"; done
    "$FP" "$S/$1" -show_format > "$L/$_ji.log" 2>&1
    _jf="$(sed -n 's/^format_name=//p' "$L/$_ji.log" | cut -d, -f1)"
    rm -f "$O/$_ji.mp4"
    "$FF" -f concat -safe 0 -i "$O/$_ji.txt" -c copy -f "$_jf" "$O/$_ji.mp4" >> "$L/$_ji.log" 2>&1
    _jd="$(dur "$O/$_ji.mp4")"; _jc=1; [ -n "$_jf" ] && [ "${_jd:-0}" -ge 7 ] && _jc=0
    v "$_ji" "$_jw" "conv: join $* with -f concat -safe 0 -c copy -f ${_jf:-?}" "$_jc" "$(probe "$O/$_ji.mp4"), ${_jd:-?}s"
}
join conv-join-mp4 ok v_h264_aac.mp4 v_h264_aac.mp4
join conv-join-mov ok v_hevc10.mov v_hevc10.mov
join conv-join-mkv ok v_vp9_opus.webm v_vp9_opus.webm
join conv-join-sub ok v_h264_sub.mp4 v_h264_sub.mp4
# a non-square pixel source to square pixels
if have v_sar.mp4; then
    x conv-sar "$FF" -i "$S/v_sar.mp4"; c=1; grep -q 'SAR 4:3 ' "$L/conv-sar.log" && c=0
    v conv-sar ok "conv: ffmpeg -i shows SAR 4:3" "$c"
    rm -f "$O/square.mp4"
    x conv-square "$FF" -y -i "$S/v_sar.mp4" -c:v libx264 -preset ultrafast -crf 18 -c:a aac -strict -2 -vf 'format=yuv420p,scale=trunc(iw*sar/2)*2:ih' "$O/square.mp4"
    g="$(dims "$O/square.mp4")"; c=1; [ "$g" = 640x360 ] && c=0
    v conv-square ok "conv: SAR to square pixels" "$c" "$g, $(probe "$O/square.mp4")"
fi
# the source filter of the admin (offsets, flip, rotation with crop, crop top and bottom)
for s in v_h264_aac.mp4 v_hevc10.mov v_vp9_opus.webm; do
    have "$s" || continue
    id="conv-filter-${s%.*}"; rm -f "$O/$id.mp4"
    x "$id" "$FF" -y -ss 1 -t 2 -i "$S/$s" -c:v libx264 -preset ultrafast -crf 18 -c:a aac -strict -2 \
        -vf 'hflip,rotate=-3*PI/180,crop=in_w-20:in_h-34,crop=in_w:in_h-40:0:20' "$O/$id.mp4"
    c=1; [ "$(probe "$O/$id.mp4" | cut -d' ' -f2)" = h264,aac ] && c=0
    v "$id" ok "conv: source filter of $s" "$c" "$(dims "$O/$id.mp4")"
done
# a format: the options of the database, the scale of the format, a watermark (the movie
# filter reads the PNG), two watermarks; the preview without sound; then -movflags
# +faststart with copies
for s in v_h264_aac.mp4 v_h264_noaudio.mp4 v_h264_10.mp4 v_hevc_aac.mp4 v_hevc10.mov v_av1_opus.mkv v_av1_aac.mp4 \
    v_vp9_opus.webm v_vp8_vorbis.webm v_h264_mp3.mp4 v_h264_ac3.mkv v_h264_eac3.mp4 v_mjpeg_pcm.mov v_h264_sub.mp4 \
    v_h264_srt.mkv v_rot90.mp4; do
    have "$s" || continue
    id="conv-fmt-${s%.*}"; f="$S/$s"; rm -f "$O/$id"*.mp4
    # shellcheck disable=SC2086
    x "$id" "$FF" -y -i "$f" $fmt_main -vf 'scale=480:270' "$O/$id.mp4"
    want_a=h264,aac; case "$s" in v_h264_noaudio.mp4) want_a=h264 ;; esac
    o="$(probe "$O/$id.mp4")"; px="$(pixf "$O/$id.mp4")"; c=1
    # KVS takes an .mp4 format with +faststart only when ffmpeg says it moved the moov atom
    [ "${o#* }" = "$want_a" ] && [ "$px" = yuv420p ] && grep -q -e 'moving the moov atom' -e 'moving header' "$L/$id.log" && c=0
    v "$id" ok "conv: format 480p of $s (and 'moving the moov atom')" "$c" "$o $px $(dims "$O/$id.mp4")"
    # shellcheck disable=SC2086
    x "$id-wm" "$FF" -y -i "$f" $fmt_main -vf "scale=480:270[sc];movie=$S/i_wm.png[wm];[sc][wm]overlay=10:10" "$O/$id-wm.mp4"
    c=1; [ "$(probe "$O/$id-wm.mp4" | cut -d' ' -f2)" = "$want_a" ] && c=0
    v "$id-wm" ok "conv: format with a watermark (movie=...png) of $s" "$c"
done
if have v_h264_aac.mp4; then
    f="$S/v_h264_aac.mp4"
    # shellcheck disable=SC2086
    x conv-wm2 "$FF" -y -i "$f" $fmt_main -vf "scale=480:270[sc];movie=$S/i_wm.png[wm];[sc][wm]overlay='if(lte(t,2),10,W-w-10)':'10'[wmsc];movie=$S/i_alpha.png[wm2];[wmsc][wm2]overlay=0:0" "$O/wm2.mp4"
    c=1; [ "$(probe "$O/wm2.mp4" | cut -d' ' -f2)" = h264,aac ] && c=0
    v conv-wm2 ok "conv: two watermarks, the first moving" "$c"
    # shellcheck disable=SC2086
    x conv-wm-noscale "$FF" -y -i "$f" $fmt_main -vf "movie=$S/i_wm.png[wm];[in][wm]overlay=10:10" "$O/wm0.mp4"
    c=1; [ "$(probe "$O/wm0.mp4" | cut -d' ' -f2)" = h264,aac ] && c=0
    v conv-wm-noscale ok "conv: watermark without a scale ([in])" "$c"
    # shellcheck disable=SC2086
    x conv-preview "$FF" -y -ss 1 -t 2 -i "$f" $fmt_prev -vf 'scale=320:180' "$O/preview.mp4"
    c=1; [ "$(probe "$O/preview.mp4" | cut -d' ' -f2)" = h264 ] && c=0
    v conv-preview ok "conv: preview format (-an) with -ss -t" "$c" "$(dims "$O/preview.mp4")"
    x conv-faststart "$FF" -y -i "$O/preview.mp4" -acodec copy -vcodec copy -movflags +faststart -strict -2 "$O/preview_temp.mp4"
    c=1; [ "$(dur "$O/preview_temp.mp4")" = 2 ] && c=0
    v conv-faststart ok "conv: -acodec copy -vcodec copy -movflags +faststart" "$c"
    # the GIF of a format: palettegen, then paletteuse into a .gif
    rm -f "$O/p.png" "$O/p.gif"
    x conv-gif-palette "$FF" -y -t 2 -i "$f" -vf 'scale=320:180,palettegen' "$O/p.png"
    c=1; [ -s "$O/p.png" ] && c=0
    v conv-gif-palette ok "conv: a GIF format: palettegen into a PNG" "$c"
    x conv-gif "$FF" -y -t 2 -i "$f" -i "$O/p.png" -filter_complex '[0:v]scale=320:180[out];[out][1:v]paletteuse' "$O/p.gif"
    c=1; [ -s "$O/p.gif" ] && c=0
    v conv-gif "gap:no GIF encoder or muxer in ffmpeg of az (a video format .gif fails)" "conv: a GIF format: paletteuse into a .gif" "$c"
    # screenshots: the default screenshot_options of config.properties, fast and slow
    for m in fast slow; do
        rm -f "$O/result-$m.jpg"
        if [ "$m" = fast ]; then x "conv-shot-$m" "$FF" -ss 2 -i "$f" -y -vframes 1 -f mjpeg -qscale 1 "$O/result-$m.jpg"
        else x "conv-shot-$m" "$FF" -i "$f" -ss 2 -y -vframes 1 -f mjpeg -qscale 1 "$O/result-$m.jpg"; fi
        g="$(img "$O/result-$m.jpg")"; c=1; [ "$g" = "JPEG 640x360" ] && c=0
        v "conv-shot-$m" ok "conv: screenshot $m" "$c" "$g"
    done
    # the probes of the rolls and of the duration
    x conv-probe-a "$FP" "$f" -show_streams -select_streams a:0; c=1; grep -q '^codec_type=audio' "$L/conv-probe-a.log" && c=0
    v conv-probe-a ok "conv: ffprobe -show_streams -select_streams a:0" "$c"
    x conv-probe-v "$FP" "$f" -show_streams -select_streams v:0; c=1; grep -q '^width=640' "$L/conv-probe-v.log" && c=0
    v conv-probe-v ok "conv: ffprobe -show_streams -select_streams v:0" "$c"
fi
# odd sizes: the text of x264 KVS looks for, then the retry with -s
if have v_h264_aac.mp4; then
    f="$S/v_h264_aac.mp4"
    # shellcheck disable=SC2086
    x conv-odd "$FF" -y -i "$f" $fmt_main -vf 'scale=481:271' "$O/odd.mp4"
    c=1; grep -q 'not divisible by 2' "$L/conv-odd.log" && c=0
    v conv-odd ok "conv: odd size: x264 says 'not divisible by 2'" "$c"
    # shellcheck disable=SC2086
    x conv-s "$FF" -y -i "$f" -s 480x270 $fmt_main "$O/s.mp4"
    g="$(dims "$O/s.mp4")"; c=1; [ "$g" = 480x270 ] && c=0
    v conv-s ok "conv: the retry with -s 480x270" "$c" "$g"
    # the size of a video by its first frame
    x conv-dims "$FF" -ss 0 -i "$f" -vframes 1 -y -f mjpeg -vf 'scale=trunc(iw*sar/2)*2:ih' "$O/dims.jpg"
    g="$(img "$O/dims.jpg")"; c=1; [ "$g" = "JPEG 640x360" ] && c=0
    v conv-dims ok "conv: size by the first frame (-ss 0 -vframes 1 -f mjpeg)" "$c" "$g"
    # a watermark that moves: KVS cuts the last closing quote off (overlay='X':'Y)
    # shellcheck disable=SC2086
    x conv-wm-quote "$FF" -y -i "$f" $fmt_main -vf "scale=480:270[sc];movie=$S/i_wm.png[wm];[sc][wm]overlay='if(lte(t,2),10,W-w-10)':'10" "$O/wmq.mp4"
    c=1; [ "$(probe "$O/wmq.mp4" | cut -d' ' -f2)" = h264,aac ] && c=0
    v conv-wm-quote ok "conv: moving watermark with the closing quote cut off" "$c"
    # the preview from parts: 3 parts, then joined with a crossfade (the graph of KVS,
    # with the filter fifo) or without (-f concat -c copy)
    for i in 0 1 2; do
        x "conv-part$i" "$FF" -y -ss "$i" -t 2 -i "$f" -c:v libx264 -preset ultrafast -crf 18 -strict -2 "$O/part$i.mp4"
    done
    c=1; [ "$(dur "$O/part2.mp4")" = 2 ] && c=0
    v conv-part2 ok "conv: preview parts (-ss -t -c:v libx264 -preset ultrafast)" "$c"
    xf() {
        _q="$1"
        printf '%s' "[0:v]trim=start=0:end=1,setpts=PTS-STARTPTS[clip0];[0:v]trim=start=1:end=2,setpts=PTS-STARTPTS[fadeoutsrc0];[fadeoutsrc0]format=pix_fmts=yuva420p,fade=t=out:st=0:d=1:alpha=1[fadeout0];[fadeout0]${_q}[fadeoutfifo0];"
        printf '%s' "[1:v]trim=start=0:end=1,setpts=PTS-STARTPTS[fadeinsrc1];[fadeinsrc1]format=pix_fmts=yuva420p,fade=t=in:st=0:d=1:alpha=1[fadein1];[fadein1]${_q}[fadeinfifo1];[fadeoutfifo0][fadeinfifo1]overlay[crossfade0_1];[1:v]trim=start=1:end=1,setpts=PTS-STARTPTS[clip1];"
        printf '%s' "[1:v]trim=start=1:end=2,setpts=PTS-STARTPTS[fadeoutsrc1];[fadeoutsrc1]format=pix_fmts=yuva420p,fade=t=out:st=0:d=1:alpha=1[fadeout1];[fadeout1]${_q}[fadeoutfifo1];"
        printf '%s' "[2:v]trim=start=0:end=1,setpts=PTS-STARTPTS[fadeinsrc2];[fadeinsrc2]format=pix_fmts=yuva420p,fade=t=in:st=0:d=1:alpha=1[fadein2];[fadein2]${_q}[fadeinfifo2];[fadeoutfifo1][fadeinfifo2]overlay[crossfade1_2];[2:v]trim=start=1:end=2,setpts=PTS-STARTPTS[clip2];"
        printf '%s' "[clip0][crossfade0_1][clip1][crossfade1_2][clip2]concat=n=5[output];[0:a][1:a]acrossfade=d=1:o=1[audio0_1];[audio0_1][2:a]acrossfade=d=1:o=1[audio1_2]"
    }
    x conv-xfade "$FF" -y -i "$O/part0.mp4" -i "$O/part1.mp4" -i "$O/part2.mp4" -filter_complex "$(xf fifo)" -map '[output]' -map '[audio1_2]' -strict -2 "$O/merged_x.mp4"
    c=1; [ "$(probe "$O/merged_x.mp4" | cut -d' ' -f2)" = h264,aac ] && c=0
    v conv-xfade "bug:the vendor's crossfade uses the filter fifo, removed in FFmpeg 7.0: a preview with a crossfade fails with any FFmpeg 7 or later" "conv: preview parts joined with a crossfade (fifo)" "$c"
    x conv-xfade-nofifo "$FF" -y -i "$O/part0.mp4" -i "$O/part1.mp4" -i "$O/part2.mp4" -filter_complex "$(xf null)" -map '[output]' -map '[audio1_2]' -strict -2 "$O/merged_n.mp4"
    c=1; [ "$(probe "$O/merged_n.mp4" | cut -d' ' -f2)" = h264,aac ] && c=0
    v conv-xfade-nofifo ok "conv: the same crossfade with null in the place of fifo (the fix)" "$c"
    printf "file '%s'\nfile '%s'\nfile '%s'\n" "$O/part0.mp4" "$O/part1.mp4" "$O/part2.mp4" > "$O/merged_c.txt"
    x conv-parts-join "$FF" -y -f concat -safe 0 -i "$O/merged_c.txt" -c copy "$O/merged_c.mp4"
    c=1; [ "$(dur "$O/merged_c.mp4")" -ge 5 ] 2>/dev/null && c=0
    v conv-parts-join ok "conv: preview parts joined without a crossfade (-f concat -c copy)" "$c"
fi
# the vendor joins MP4 sources with -f mov: AV1 (and VP9, Opus) are not written into MOV
join conv-join-av1 "bug:the vendor joins MP4 sources with -f mov, and MOV takes no AV1 (nor VP9, Opus) with any build" v_av1_aac.mp4 v_av1_aac.mp4
# a format that only moves the moov atom of an uploaded MP4 (VP9 needs the bsf vp9_superframe)
if have v_vp9_aac.mp4; then
    x conv-fast-vp9 "$FF" -y -i "$S/v_vp9_aac.mp4" -acodec copy -vcodec copy -movflags +faststart -strict -2 "$O/vp9_temp.mp4"
    c=1; [ "$(probe "$O/vp9_temp.mp4" | cut -d' ' -f2)" = vp9,aac ] && c=0
    v conv-fast-vp9 ok "conv: +faststart of an MP4 with VP9 (copies: vp9_superframe)" "$c"
fi
# our master format: the source copied (-c copy -movflags +faststart) into _o.mp4
for s in v_h264_aac.mp4 v_h264_10.mp4 v_hevc10.mov v_av1_opus.mkv v_av1_aac.mp4 v_h264_mp3.mp4 v_h264_ac3.mkv \
    v_h264_sub.mp4 v_vp9_opus.webm v_vp8_vorbis.webm v_mjpeg_pcm.mov; do
    have "$s" || continue
    id="conv-master-$(echo "$s" | tr . _)"; rm -f "$O/$id.mp4"
    x "$id" "$FF" -y -i "$S/$s" -c copy -movflags +faststart "$O/$id.mp4"
    c=1; [ -n "$(dur "$O/$id.mp4")" ] && c=0
    case "$s" in
        v_vp8_*) wm="bug:our master copy: VP8 does not go into MP4 with any build" ;;
        *) wm=ok ;;
    esac
    v "$id" "$wm" "conv prg: master copy of $s into _o.mp4" "$c" "$(probe "$O/$id.mp4")"
done
# rolls: silence for a roll without sound, the roll scaled and padded to the video, the
# join, -movflags +faststart
if have v_pre.mp4 && have v_post.mp4 && have v_h264_aac.mp4; then
    x conv-roll-silence "$FF" -y -i "$S/v_pre.mp4" -f lavfi -i anullsrc=cl=stereo:r=44100 -shortest -c:v copy "$O/pre_a.mp4"
    c=1; [ "$(probe "$O/pre_a.mp4" | cut -d' ' -f2)" = h264,aac ] && c=0
    v conv-roll-silence ok "conv: roll without sound + -f lavfi -i anullsrc -shortest -c:v copy" "$c"
    for r in pre_a post; do
        src="$O/pre_a.mp4"; [ "$r" = post ] && src="$S/v_post.mp4"
        # shellcheck disable=SC2086
        x "conv-roll-$r" "$FF" -y -i "$src" -vf 'scale=640:360:force_original_aspect_ratio=decrease,pad=640:360:(ow-iw)/2:(oh-ih)/2' -aspect 640:360 $fmt_main -ar 48000 -ac 2 -r 25 -video_track_timescale 12800 "$O/roll_$r.mp4"
        g="$(dims "$O/roll_$r.mp4")"; c=1; [ "$g" = 640x360 ] && c=0
        v "conv-roll-$r" ok "conv: roll $r scaled and padded" "$c" "$g $(probe "$O/roll_$r.mp4")"
    done
    # shellcheck disable=SC2086
    x conv-roll-main "$FF" -y -i "$S/v_h264_aac.mp4" $fmt_main "$O/roll_main.mp4"
    printf "file '%s'\nfile '%s'\nfile '%s'\n" "$O/roll_pre_a.mp4" "$O/roll_main.mp4" "$O/roll_post.mp4" > "$O/merged_rolls.txt"
    x conv-roll-join "$FF" -y -f concat -safe 0 -i "$O/merged_rolls.txt" -c copy "$O/rolled.mp4"
    "$FF" -y -i "$O/rolled.mp4" -c copy -movflags +faststart "$O/rolled2.mp4" >> "$L/conv-roll-join.log" 2>&1
    d="$(dur "$O/rolled2.mp4")"; c=1; [ "${d:-0}" -ge 7 ] && c=0
    v conv-roll-join ok "conv: rolls joined with -f concat -c copy, then +faststart" "$c" "$(probe "$O/rolled2.mp4"), ${d:-?}s"
fi
if have v_pre_vp9.mp4; then
    x conv-roll-vp9 "$FF" -y -i "$S/v_pre_vp9.mp4" -f lavfi -i anullsrc=cl=stereo:r=44100 -shortest -c:v copy "$O/pre_vp9.mp4"
    c=1; [ "$(probe "$O/pre_vp9.mp4" | cut -d' ' -f2)" = vp9,aac ] && c=0
    v conv-roll-vp9 ok "conv: VP9 roll without sound + anullsrc -c:v copy" "$c"
fi
if have v_post.mp4; then
    x conv-roll-master "$FF" -y -i "$S/v_post.mp4" -vf 'scale=640:360:force_original_aspect_ratio=decrease,pad=640:360:(ow-iw)/2:(oh-ih)/2' -aspect 640:360 -c copy -movflags +faststart "$O/roll_master.mp4"
    c=1; [ -n "$(dur "$O/roll_master.mp4")" ] && c=0
    v conv-roll-master "bug:ours gives the rolls of a master format -c copy with -vf: ffmpeg refuses it with any build" "conv prg: roll of a master format (-vf with -c copy)" "$c"
fi
# the pictures of the conversion servers: identify -format %wx%h, the watermark resized
for fl in $fls; do
    case "$fl" in 7) KP="$IM7" ;; 7c) KP="$BIN7/convert" ;; 6) KP="$IM6" ;; esac
    x "conv-im$fl-size" idn -format '%wx%h' "$S/i_photo.jpg"
    c=1; [ "$(tail -n 1 "$L/conv-im$fl-size.log")" = 800x600 ] && c=0
    v "conv-im$fl-size" ok "conv im$fl: identify -format %wx%h" "$c"
    rm -f "$O/wmr$fl.png"
    x "conv-im$fl-wm" cv "$S/i_wm.png" -resize 60x20 "$O/wmr$fl.png"
    g="$(img "$O/wmr$fl.png")"; c=1; [ "$g" = "PNG 60x20" ] && c=0
    v "conv-im$fl-wm" ok "conv im$fl: watermark -resize" "$c" "$g"
    tpl="-enhance -strip -unsharp 1.0x1.0+0.5 -modulate 110,102,100 -contrast -gamma 1.2 -resize 241x161 -filter Lanczos -filter Blackman -quality 80"
    rm -f "$O/alb$fl-off.bmp" "$O/alb$fl-prg.bmp"
    # shellcheck disable=SC2086
    x "conv-im$fl-album-off" cv -crop +10+10 -crop -10-10 "$S/i_photo.jpg" $tpl "$O/alb$fl-off.bmp"
    wa=ok; [ "$fl" = 7 ] && wa='bug:the crop of an album comes before the image (the vendor on the conversion servers, and both versions on the site; ours fixed only the conversion servers); magick wants the image first'
    c=1; case "$(img "$O/alb$fl-off.bmp")" in "BMP "*) c=0 ;; esac
    v "conv-im$fl-album-off" "$wa" "conv im$fl off: album: -crop ... before the image + template -> bmp" "$c"
    # shellcheck disable=SC2086
    x "conv-im$fl-album-prg" cv "$S/i_photo.jpg" -crop +10+10 -crop -10-10 $tpl "$O/alb$fl-prg.bmp"
    c=1; case "$(img "$O/alb$fl-prg.bmp")" in "BMP "*) c=0 ;; esac
    v "conv-im$fl-album-prg" ok "conv im$fl prg: album: the image first, -crop, template -> bmp" "$c"
    if [ -s "$O/alb$fl-prg.bmp" ]; then
        rm -f "$O/albbg$fl.bmp"
        x "conv-im$fl-albbg-off" cv -resize '240x160^' -gravity center -extent 240x160 "$O/alb$fl-prg.bmp" -blur 0x6 -modulate 100,60 "$O/albbg$fl.bmp"
        wb=ok; [ "$fl" = 7 ] && wb='bug:the vendor puts -resize before the image of an album; magick wants the image first (fixed in ours)'
        c=1; [ "$(img "$O/albbg$fl.bmp")" = "BMP 240x160" ] && c=0
        v "conv-im$fl-albbg-off" "$wb" "conv im$fl off: album: blurred background with -resize before the image" "$c"
        x "conv-im$fl-albfinal" cv -quality 80 -interlace line -comment 'a comment with spaces' -size 240x160 'xc:#000000' "$O/alb$fl-prg.bmp" -gravity Center -composite "$S/i_wm.png" -gravity NorthWest -composite "$O/albfinal$fl.jpg"
        g="$(idc -format '%m %wx%h|%c' "$O/albfinal$fl.jpg" 2>/dev/null)"; c=1; [ "$g" = "JPEG 240x160|a comment with spaces" ] && c=0
        v "conv-im$fl-albfinal" ok "conv im$fl: album picture: canvas, bmp, watermark, -comment with spaces" "$c" "$g"
    fi
    if [ -s "$O/result-fast.jpg" ]; then
        cp "$O/result-fast.jpg" "$O/r$fl.jpg"
        x "conv-im$fl-crop" cv "$O/r$fl.jpg" -quality 90 -crop +10+10 -crop -10-10 "$O/r$fl.jpg"
        g="$(img "$O/r$fl.jpg")"; c=1; [ "$g" = "JPEG 620x340" ] && c=0
        v "conv-im$fl-crop" ok "conv im$fl: screenshot -quality -crop +L+T -crop -R-B into itself" "$c" "$g"
    fi
done

# --- the plugin movie_from_image: a video from one picture ----------------------------
if have i_photo.jpg; then
    for i in 1 2 3 4 5; do cp "$S/i_photo.jpg" "$O/task-1-$i.jpg"; done
    rm -f "$O/task-1.mp4"
    x movie "$FF" -i "$O/task-1-%d.jpg" -vcodec libx264 -threads 0 -crf 28 -vf 'fps=25,format=yuv420p' -t 5 -f mp4 "$O/task-1.mp4"
    c=1; [ "$(probe "$O/task-1.mp4" | cut -d' ' -f2)" = h264 ] && c=0
    v movie ok "movie_from_image: task-%d.jpg -> mp4" "$c" "$(dims "$O/task-1.mp4")"
fi

# --- the plugin audit: its test video is an AVI ----------------------------------------
if have v_test.avi && built demuxer avi; then
    skip "audit: this ffmpeg has the demuxer avi (not the build of az)"
elif have v_test.avi; then
    x audit-shot "$FF" -ss 2 -i "$S/v_test.avi" -vframes 1 -y -f mjpeg "$O/audit.jpg"
    c=1; [ -s "$O/audit.jpg" ] && c=0
    v audit-shot "no:AVI is not built: audit reports FFmpeg as failing although conversion works" "audit: screenshot of an AVI" "$c"
fi

# --- yt-dlp of the grabbers: it calls ffmpeg itself --------------------------------------
# merging a video and an audio format; fixing an HLS download (MPEG-TS in an .mp4)
if have v_vp9_aac.mp4 && have v_audio_only.m4a; then
    # a VP9 rendition of an HLS site and its sound into MP4 (vp9_superframe)
    x ytdlp-merge-vp9 "$FF" -y -loglevel repeat+info -i "file:$S/v_vp9_aac.mp4" -i "file:$S/v_audio_only.m4a" -c copy -map 0:v:0 -map 1:a:0 -movflags +faststart "file:$O/merged_vp9.temp.mp4"
    c=1; [ "$(probe "$O/merged_vp9.temp.mp4" | cut -d' ' -f2)" = vp9,aac ] && c=0
    v ytdlp-merge-vp9 ok "yt-dlp: merge a VP9 video and the audio (-c copy -map)" "$c"
fi
if have v_video_only.mp4 && have v_audio_only.m4a; then
    x ytdlp-merge "$FF" -y -loglevel repeat+info -i "file:$S/v_video_only.mp4" -i "file:$S/v_audio_only.m4a" -c copy -map 0:v:0 -map 1:a:0 -movflags +faststart "file:$O/merged.temp.mp4"
    c=1; [ "$(probe "$O/merged.temp.mp4" | cut -d' ' -f2)" = h264,aac ] && c=0
    v ytdlp-merge ok "yt-dlp: merge video and audio (-c copy -map)" "$c"
fi
if have v_ts.mp4; then
    # fixing an HLS download (MPEG-TS in an .mp4): yt-dlp asks ffprobe whether the file
    # is MPEG-TS, then copies it into MP4, with aac_adtstoasc on an AAC sound
    wts=ok; built demuxer mpegts || wts="gap:no MPEG-TS demuxer in this build: yt-dlp leaves an HLS download as MPEG-TS in .mp4"
    x ytdlp-probe "$FP" -hide_banner -show_format -show_streams -print_format json "file:$S/v_ts.mp4"
    c=1; grep -q '"format_name": "mpegts"' "$L/ytdlp-probe.log" && c=0
    v ytdlp-probe "$wts" "yt-dlp: is the download MPEG-TS (ffprobe)" "$c"
    x ytdlp-fixup "$FF" -y -loglevel repeat+info -i "file:$S/v_ts.mp4" -map 0 -dn -ignore_unknown -c copy -f mp4 -bsf:a aac_adtstoasc -movflags +faststart "file:$O/v_ts.temp.mp4"
    c=1; [ "$(probe "$O/v_ts.temp.mp4" | cut -d' ' -f2)" = h264,aac ] && c=0
    v ytdlp-fixup "$wts" "yt-dlp: MPEG-TS in .mp4 into MP4 (-c copy -f mp4 -bsf:a aac_adtstoasc)" "$c"
fi

line "counts: $n_ok ok, $n_fail failed, $n_gap gaps, $n_bug bugs of KVS, $n_skip skipped"
line "tests: $n_ok ok, $n_fail failed"
cat "$out"
[ "$n_fail" = 0 ]
