#!/bin/sh
# ffmpeg-test.sh - test ffmpeg and ffprobe of tools/build-ffmpeg.sh (the package
# ffmpeg of tools/build-az.sh, installed: /usr/local/bin) as the video sites use
# it, and that what freebsd/ffmpeg.conf leaves out is refused.
#
# Usage (FreeBSD, as root):
#   sh tools/ffmpeg-test.sh --samples   only make the samples (before our ffmpeg
#                                       is installed in the place of the package's)
#   sh tools/ffmpeg-test.sh             the tests (with the samples made before, if any)
#
# The samples are made with the ffmpeg package (installed here; it has all the
# encoders): every container the sites take (mp4, m4v, mov, mkv, webm) with
# H.264 (also in 10 bit, 4:2:2 and 4:4:4), HEVC (8 and 10 bit), AV1, VP9, VP8 and
# MJPEG, AAC, MP3, Opus, Vorbis, AC3, E-AC3 and PCM, subtitles, a rotated phone
# video, JPEG, PNG and WebP pictures. With each: ffprobe and "ffmpeg -i" (what KVS
# reads), the conversion of KVS (libx264 into mp4, without and with AAC; its
# command has no -pix_fmt), which must give 8-bit 4:2:0 H.264, what browsers play
# (freebsd/ffmpeg/libx264-8bit-420.patch), screenshots, a watermark. The other ways of
# remote_cron.php and the plugins of KVS: joins with -f concat -safe 0 and -c copy
# into mp4, mov (-f mov) and mkv (-f matroska), subtitles left out, not failed on,
# silence from -f lavfi -i anullsrc, a video from pictures (task-%d.jpg).
# VP9 copied into MKV and MP4 (the muxers put vp9_superframe on it); MPEG-TS in an
# .mp4 (an HLS download of yt-dlp) read like the others and copied into MP4 as
# yt-dlp fixes it. Refused, by content: other containers and playlists named .mp4
# (AVI, FLV, MPEG-PS, Ogg, MP3, WAV, GIF, SubRip, HLS; a concat script too: its
# demuxer is built, but only for -f concat), and every protocol but file and pipe.
# The lists of demuxers (with the lavfi device), decoders and protocols must be
# those of ffmpeg.conf.
#
# Results: ffmpeg-results/tests.txt (one line per check, the summary at the end);
# exit status 0 when every check passed.

set -u
top="$(pwd)"
conf="$top/freebsd/ffmpeg.conf"
F="${FFMPEG_PREFIX:-/usr/local}"
res="$top/ffmpeg-results"
T="${FFMPEG_TEST_WORK:-/var/tmp/ffmpeg-test}"
ff="$F/bin/ffmpeg"
fp="$F/bin/ffprobe"
ref=/usr/local/bin/ffmpeg
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

if [ -z "$samples_only" ]; then
[ -x "$ff" ] && [ -x "$fp" ] || { fail "no $ff or $fp (tools/build-ffmpeg.sh first)"; finish; }

# --- the lists of components: those of ffmpeg.conf ---------------------------
# the components of ffmpeg.conf, by the names ffmpeg lists them under (the demuxer
# image_png_pipe is png_pipe; -demuxers lists the input devices too)
want() {
    for k in "$@"; do
        awk -v k="--enable-$k=" '$1 == "configure" { for (i = 2; i <= NF; i++) if (index($i, k) == 1) { s = substr($i, length(k) + 1); gsub(",", "\n", s); print s } }' "$conf"
    done | sed 's/^image_\(.*_pipe\)$/\1/' | LC_ALL=C sort -u
}
# names after the dashed line of -demuxers (" D d lavfi": three flags, then the name;
# the first name of "mov,mp4,...") and of -decoders (" V....D h264"), sorted
listed() {
    "$ff" -hide_banner "-$1" 2>/dev/null | awk -v k="$1" '
        seen && k == "demuxers" { split(substr($0, 6), a, " "); split(a[1], n, ","); if (n[1] != "") print n[1] }
        seen && k != "demuxers" && NF >= 2 { print $2 }
        /^ *-+ *$/ { seen = 1 }' | LC_ALL=C sort -u
}
cmp_list() {
    case "$1" in demuxer) want demuxer indev ;; *) want "$1" ;; esac > "$T/want-$1"
    listed "$2" > "$T/have-$1"
    if cmp -s "$T/want-$1" "$T/have-$1"; then
        pass "$2: $(tr '\n' ' ' < "$T/have-$1" | sed 's/ *$//')"
    else
        fail "$2: built $(tr '\n' ' ' < "$T/have-$1" | sed 's/ *$//'), ffmpeg.conf has $(tr '\n' ' ' < "$T/want-$1" | sed 's/ *$//')"
    fi
}
cmp_list demuxer demuxers
cmp_list decoder decoders
"$ff" -hide_banner -protocols 2>/dev/null | awk '/^Input:/ { s = 1; next } /^Output:/ { s = 2; next } s && NF { print $1 }' |
    LC_ALL=C sort -u > "$T/have-protocol"
want protocol > "$T/want-protocol"
if cmp -s "$T/want-protocol" "$T/have-protocol"; then
    pass "protocols: $(tr '\n' ' ' < "$T/have-protocol" | sed 's/ *$//')"
else
    fail "protocols: built $(tr '\n' ' ' < "$T/have-protocol" | sed 's/ *$//'), ffmpeg.conf has $(tr '\n' ' ' < "$T/want-protocol" | sed 's/ *$//')"
fi
for k in encoders muxers bsfs; do
    "$ff" -hide_banner "-$k" > "$res/$k.txt" 2>&1
done
note "filters: $("$ff" -hide_banner -filters 2>/dev/null | grep -c -- '->') (all of FFmpeg that need no other library)"
fi

# --- the samples --------------------------------------------------------------
av="-f lavfi -i testsrc2=size=640x360:rate=30:duration=3 -f lavfi -i sine=frequency=440:sample_rate=48000:duration=3"
x264="-c:v libx264 -preset veryfast -pix_fmt yuv420p"
if [ -z "$have_samples" ]; then
if [ ! -x "$ref" ]; then
    env ASSUME_ALWAYS_YES=yes pkg install -y ffmpeg-nox11 > "$res/pkg-ffmpeg.log" 2>&1 ||
        env ASSUME_ALWAYS_YES=yes pkg install -y ffmpeg >> "$res/pkg-ffmpeg.log" 2>&1
fi
[ -x "$ref" ] || { fail "the ffmpeg package (for the samples) could not be installed: $(tail -n 2 "$res/pkg-ffmpeg.log" | tr '\n' ' ')"; finish; }
note "samples made with $("$ref" -hide_banner -version | head -n 1)"

: > "$T/samples"
# mk <file> <options of the package's ffmpeg>: one sample, into the list when it could be made
mk() {
    f="$1"; shift
    # shellcheck disable=SC2086
    if "$ref" -hide_banner -loglevel error -y $av "$@" "$T/$f" > "$T/$f.log" 2>&1; then
        echo "$f" >> "$T/samples"
    else
        note "sample $f: the package's ffmpeg cannot make it: $(tail -n 1 "$T/$f.log")"
    fi
}
x265="-c:v libx265 -preset ultrafast"
vp9="-c:v libvpx-vp9 -deadline realtime -cpu-used 8"
vp8="-c:v libvpx -deadline realtime -cpu-used 8"
if "$ref" -hide_banner -encoders 2>/dev/null | grep -q ' libsvtav1 '; then av1="-c:v libsvtav1 -preset 12"; else av1="-c:v libaom-av1 -cpu-used 8"; fi
# shellcheck disable=SC2086
{
    mk h264_aac.mp4 $x264 -c:a aac
    mk h264_aac.m4v $x264 -c:a aac
    mk h264_aac.mov $x264 -c:a aac
    mk h264_mp3.mp4 $x264 -c:a libmp3lame
    mk h264_ac3.mp4 $x264 -c:a ac3
    mk h264_eac3.mp4 $x264 -c:a eac3
    mk h264_10_aac.mp4 -c:v libx264 -preset veryfast -pix_fmt yuv420p10le -c:a aac
    mk h264_422_aac.mov -c:v libx264 -preset veryfast -pix_fmt yuv422p -c:a aac
    mk h264_444_aac.mp4 -c:v libx264 -preset veryfast -pix_fmt yuv444p -c:a aac
    mk h264_full_aac.mp4 -c:v libx264 -preset veryfast -pix_fmt yuvj420p -c:a aac
    mk mjpeg_pcm.mov -c:v mjpeg -pix_fmt yuvj422p -c:a pcm_s16le
    mk hevc_aac.mp4 $x265 -tag:v hvc1 -c:a aac
    mk hevc10_aac.mov $x265 -tag:v hvc1 -pix_fmt yuv420p10le -c:a aac
    mk av1_aac.mp4 $av1 -c:a aac
    mk vp9_aac.mp4 $vp9 -c:a aac
    mk h264_vorbis.mkv $x264 -c:a libvorbis
    mk h264_ac3.mkv $x264 -c:a ac3
    mk h264_eac3.mkv $x264 -c:a eac3
    mk hevc_opus.mkv $x265 -c:a libopus
    mk av1_opus.mkv $av1 -c:a libopus
    mk av1_opus.webm $av1 -c:a libopus
    mk vp9_opus.webm $vp9 -c:a libopus
    mk vp8_vorbis.webm $vp8 -c:a libvorbis
    # an HLS download of yt-dlp before its fix: MPEG-TS in an .mp4
    mk h264_aac_ts.mp4 $x264 -c:a aac -f mpegts
}
printf '1\n00:00:00,000 --> 00:00:02,000\nsubtitle\n\n' > "$T/sub.srt"
# shellcheck disable=SC2086
for s in "h264_aac_sub.mp4 mov_text" "h264_aac_sub.mkv srt"; do
    set -- $s
    if "$ref" -hide_banner -loglevel error -y $av -i "$T/sub.srt" -map 0:v -map 1:a -map 2:s $x264 -c:a aac -c:s "$2" "$T/$1" > "$T/$1.log" 2>&1; then
        echo "$1" >> "$T/samples"
    else
        note "sample $1: $(tail -n 1 "$T/$1.log")"
    fi
done
# a phone video turned by 90 degrees (display matrix): ffmpeg turns the picture itself
if [ -f "$T/h264_aac.mp4" ] &&
    "$ref" -hide_banner -loglevel error -y -display_rotation:v:0 90 -i "$T/h264_aac.mp4" -c copy "$T/h264_aac_rot90.mp4" > "$T/rot.log" 2>&1; then
    echo h264_aac_rot90.mp4 >> "$T/samples"
else
    note "sample h264_aac_rot90.mp4: $(tail -n 1 "$T/rot.log" 2>/dev/null)"
fi
for p in "logo.png" "shot.jpg" "shot.webp"; do
    "$ref" -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=160x90:duration=1 -frames:v 1 "$T/$p" > "$T/$p.log" 2>&1 ||
        note "picture $p: $(tail -n 1 "$T/$p.log")"
done
# made only to be refused: other formats named .mp4, playlists
# shellcheck disable=SC2086
{
    "$ref" -hide_banner -loglevel error -y $av -c:v mpeg4 -c:a pcm_s16le -f avi "$T/no_avi.mp4"
    "$ref" -hide_banner -loglevel error -y $av $x264 -c:a aac -f flv "$T/no_flv.mp4"
    "$ref" -hide_banner -loglevel error -y $av -c:v mpeg2video -c:a mp2 -f mpeg "$T/no_ps.mp4"
    "$ref" -hide_banner -loglevel error -y $av -vn -c:a libvorbis -f ogg "$T/no_ogg.mp4"
    "$ref" -hide_banner -loglevel error -y $av -vn -c:a libmp3lame -f mp3 "$T/no_mp3.mp4"
    "$ref" -hide_banner -loglevel error -y $av -vn -f wav "$T/no_wav.mp4"
    "$ref" -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=160x90:duration=1 -f gif "$T/no_gif.mp4"
} > "$T/no.log" 2>&1
cp "$T/sub.srt" "$T/no_srt.mp4"
printf '#EXTM3U\n#EXT-X-TARGETDURATION:3\n#EXTINF:3.0,\nh264_aac.mp4\n#EXT-X-ENDLIST\n' > "$T/no_hls.mp4"
printf 'ffconcat version 1.0\nfile h264_aac.mp4\n' > "$T/no_ffconcat.mp4"
fi
if [ -n "$samples_only" ]; then
    touch "$T/.samples"
    echo "samples: $(wc -l < "$T/samples" | tr -d ' ') in $T" >> "$out"
    cat "$out"
    exit 0
fi

# --- what the sites do with them -----------------------------------------------
# probe <file>: "format codec,codec..." as ffprobe of this build sees them
probe() {
    "$fp" -v error -show_entries format=format_name:stream=codec_name -of default=nw=1 "$1" 2>"$T/probe.err" |
        awk -F= '$1 == "format_name" { f = $2 } $1 == "codec_name" { c = c (c ? "," : "") $2 } END { print f, c }'
}
dims() { "$fp" -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$1" 2>/dev/null; }
pfmt() { "$fp" -v error -select_streams v:0 -show_entries stream=profile,pix_fmt -of csv=p=0 "$1" 2>/dev/null; }
# libx264 takes 8-bit 4:2:0 in the limited range only
# (freebsd/ffmpeg/libx264-8bit-420.patch); an explicit -pix_fmt of another format
# becomes yuv420p
v="$("$ff" -hide_banner -h encoder=libx264 2>/dev/null | sed -n 's/^ *Supported pixel formats: *//p')"
[ "$v" = "yuv420p nv12 nv21" ] && pass "libx264: pixel formats $v" || fail "libx264: pixel formats ${v:-none} (not those of libx264-8bit-420.patch)"
if [ -f "$T/h264_aac.mp4" ]; then
    if "$ff" -hide_banner -loglevel error -y -i "$T/h264_aac.mp4" -c:v libx264 -pix_fmt yuv444p10le -an -f mp4 "$T/pix.mp4" > "$T/pix.log" 2>&1; then
        v="$(pfmt "$T/pix.mp4")"
        case "$v" in "High,yuv420p") pass "-pix_fmt yuv444p10le -> H.264 $v" ;; *) fail "-pix_fmt yuv444p10le -> H.264 $v" ;; esac
    else
        fail "-pix_fmt yuv444p10le: $(tail -n 2 "$T/pix.log" | tr '\n' ' ')"
    fi
fi
kvs="-vcodec libx264 -movflags +faststart -threads 0 -r 25 -g 50 -crf 25 -me_method hex -trellis 0 -bf 8"
# the full range (an MJPEG of a camera, a phone video) becomes the limited range
# with the -pix_fmt yuv420p of KVS too, as before FFmpeg 7.1 (the same patch)
for s in mjpeg_pcm.mov h264_full_aac.mp4; do
    [ -f "$T/$s" ] || continue
    # shellcheck disable=SC2086
    if "$ff" -hide_banner -loglevel error -y -i "$T/$s" -pix_fmt yuv420p $kvs -an -f mp4 "$T/range.mp4" > "$T/range.log" 2>&1; then
        v="$(pfmt "$T/range.mp4")"
        case "$v" in
            "High,yuv420p") pass "$s: -pix_fmt yuv420p -> H.264 $v (the limited range)" ;;
            *) fail "$s: -pix_fmt yuv420p -> H.264 $v (not the limited range)" ;;
        esac
    else
        fail "$s: -pix_fmt yuv420p: $(tail -n 2 "$T/range.log" | tr '\n' ' ')"
    fi
done
while read -r s; do
    f="$T/$s"
    p="$(probe "$f")"
    case "$p" in
        "mov,mp4,m4a,3gp,3g2,mj2 "*|"matroska,webm "*|"mpegts "*) pass "$s: ffprobe: $p" ;;
        *) fail "$s: ffprobe: ${p:-nothing} $(head -n 1 "$T/probe.err")"; continue ;;
    esac
    "$ff" -hide_banner -i "$f" > "$T/info.txt" 2>&1
    info="$(grep -E '^ *Stream #' "$T/info.txt" | sed -E 's/^ *Stream #[0-9:]+(\[[^]]*\])?(\([a-z]+\))?: //; s/,.*//' | tr '\n' ';' | sed 's/;$//')"
    case "$s" in
        av1*) grep -q 'Video: av1 (libdav1d)' "$T/info.txt" && pass "$s: ffmpeg -i: $info" || fail "$s: ffmpeg -i: $info" ;;
        *_mp3*) grep -q 'Audio: mp3 (mp3float)' "$T/info.txt" && pass "$s: ffmpeg -i: $info" || fail "$s: ffmpeg -i: $info" ;;
        *) grep -q '^Input #0' "$T/info.txt" && pass "$s: ffmpeg -i: $info" || fail "$s: ffmpeg -i: $(tail -n 1 "$T/info.txt")" ;;
    esac
    # shellcheck disable=SC2086
    if "$ff" -hide_banner -loglevel error -y -i "$f" $kvs -an -f mp4 "$T/out.mp4" > "$T/conv.log" 2>&1; then
        o="$(probe "$T/out.mp4")"
        [ "${o#* }" = h264 ] && pass "$s: KVS without sound -> $o" || fail "$s: KVS without sound -> $o"
    else
        fail "$s: KVS without sound: $(tail -n 3 "$T/conv.log" | tr '\n' ' ')"
    fi
    # shellcheck disable=SC2086
    if "$ff" -hide_banner -loglevel error -y -i "$f" $kvs -c:a aac -b:a 128k -f mp4 "$T/out.mp4" > "$T/conv.log" 2>&1; then
        o="$(probe "$T/out.mp4")"
        [ "${o#* }" = h264,aac ] && pass "$s: KVS with AAC -> $o" || fail "$s: KVS with AAC -> $o"
        case "$s" in
            *rot90*) d="$(dims "$T/out.mp4")"; [ "$d" = 360x640 ] && pass "$s: turned: $d" || fail "$s: not turned: $d" ;;
        esac
        # 8-bit 4:2:0 in the limited range whatever the input (10 bit, 4:2:2, 4:4:4,
        # the full range): what browsers play
        v="$(pfmt "$T/out.mp4")"
        case "$v" in
            "Constrained Baseline,yuv420p"|"Main,yuv420p"|"High,yuv420p") pass "$s: KVS -> H.264 $v" ;;
            *) fail "$s: KVS -> H.264 $v (not 8-bit 4:2:0 in the limited range)" ;;
        esac
    else
        fail "$s: KVS with AAC: $(tail -n 3 "$T/conv.log" | tr '\n' ' ')"
    fi
done < "$T/samples"

# screenshots, a watermark and a scaled copy (from the H.264, HEVC, AV1 and VP9 samples)
for s in h264_aac.mp4 hevc_aac.mp4 av1_aac.mp4 vp9_opus.webm; do
    [ -f "$T/$s" ] || continue
    for e in jpg png webp; do
        if "$ff" -hide_banner -loglevel error -y -ss 1 -i "$T/$s" -frames:v 1 "$T/shot-$s.$e" > "$T/shot.log" 2>&1; then
            o="$(probe "$T/shot-$s.$e")"
            case "$e:$o" in
                jpg:*" mjpeg"|png:*" png"|webp:*" webp") pass "$s: screenshot $e -> $o" ;;
                *) fail "$s: screenshot $e -> $o" ;;
            esac
        else
            fail "$s: screenshot $e: $(tail -n 3 "$T/shot.log" | tr '\n' ' ')"
        fi
    done
done
if [ -f "$T/h264_aac.mp4" ] && [ -f "$T/logo.png" ]; then
    # shellcheck disable=SC2086
    "$ff" -hide_banner -loglevel error -y -i "$T/h264_aac.mp4" -i "$T/logo.png" -filter_complex '[0:v][1:v]overlay=10:10' \
        $kvs -c:a aac -b:a 128k -f mp4 "$T/wm.mp4" > "$T/wm.log" 2>&1 &&
        pass "watermark (overlay of a PNG) -> $(probe "$T/wm.mp4")" || fail "watermark: $(tail -n 3 "$T/wm.log" | tr '\n' ' ')"
    # shellcheck disable=SC2086
    "$ff" -hide_banner -loglevel error -y -i "$T/h264_aac.mp4" -vf scale=320:-2 $kvs -an -f mp4 "$T/sc.mp4" > "$T/sc.log" 2>&1 &&
        [ "$(dims "$T/sc.mp4")" = 320x180 ] && pass "scale=320:-2 -> $(dims "$T/sc.mp4")" || fail "scale=320:-2: $(tail -n 3 "$T/sc.log" | tr '\n' ' ')"
fi
for p in logo.png shot.jpg shot.webp; do
    [ -f "$T/$p" ] || continue
    o="$(probe "$T/$p")"
    case "$o" in
        png_pipe*png|jpeg_pipe*mjpeg|webp_pipe*webp|image2*) pass "$p: ffprobe: $o" ;;
        *) fail "$p: ffprobe: ${o:-nothing}" ;;
    esac
done

# --- the other ways of remote_cron.php and the plugins of KVS --------------------
# join <out> <format> <sample>...: a join as remote_cron.php does it (-f concat -safe
# 0, a list of absolute paths, -c copy, -f with the format of the sources); the
# result has the streams of the sources but subtitles (ffmpeg maps subtitles by itself
# only when it has an encoder for them: none here) and their length together
join() {
    o="$1"; fmt="$2"; shift 2
    : > "$T/list.txt"
    for s in "$@"; do
        [ -f "$T/$s" ] || { note "join $o: no sample $s"; return; }
        echo "file '$T/$s'" >> "$T/list.txt"
    done
    if "$ff" -hide_banner -loglevel error -y -f concat -safe 0 -i "$T/list.txt" -c copy -f "$fmt" "$T/$o" > "$T/join.log" 2>&1; then
        o2="$(probe "$T/$o")"
        d="$("$fp" -v error -show_entries format=duration -of csv=p=0 "$T/$o" 2>/dev/null)"
        want="$(probe "$T/$1" | cut -d' ' -f2 | tr ',' '\n' | grep -v -x -e mov_text -e subrip | paste -s -d, -)"
        if [ "${o2#* }" = "$want" ] && awk -v d="${d:-0}" 'BEGIN { exit !(d > 5) }'; then
            pass "join -f concat -safe 0 -c copy -f $fmt ($*) -> $o2, ${d}s"
        else
            fail "join -f concat -safe 0 -c copy -f $fmt ($*) -> $o2, ${d:-?}s"
        fi
    else
        fail "join -f concat -safe 0 -c copy -f $fmt ($*): $(tail -n 3 "$T/join.log" | tr '\n' ' ')"
    fi
}
join join1.mp4 mp4 h264_aac.mp4 h264_aac.mp4
join join2.mp4 mov h264_aac.mp4 h264_aac.mp4
join join.mov mov h264_aac.mov h264_aac.mov
join join.mkv matroska h264_vorbis.mkv h264_vorbis.mkv
join join_sub.mp4 mov h264_aac_sub.mp4 h264_aac_sub.mp4
join join_sub.mkv matroska h264_aac_sub.mkv h264_aac_sub.mkv
# VP9 copied: the muxers put vp9_superframe on it
join join_vp9.mkv matroska vp9_opus.webm vp9_opus.webm
if [ -f "$T/vp9_aac.mp4" ]; then
    "$ff" -hide_banner -loglevel error -y -i "$T/vp9_aac.mp4" -c copy -movflags +faststart "$T/vp9_fast.mp4" > "$T/vp9.log" 2>&1 &&
        [ "$(probe "$T/vp9_fast.mp4" | cut -d' ' -f2)" = vp9,aac ] && pass "VP9 copied into MP4 with +faststart (vp9_superframe)" ||
        fail "VP9 copied into MP4: $(tail -n 3 "$T/vp9.log" | tr '\n' ' ')"
fi
# the fix of an HLS download by yt-dlp: MPEG-TS in an .mp4 copied into MP4
if [ -s "$T/h264_aac_ts.mp4" ]; then
    "$ff" -hide_banner -loglevel error -y -i "$T/h264_aac_ts.mp4" -map 0 -dn -ignore_unknown -c copy -f mp4 -bsf:a aac_adtstoasc -movflags +faststart "$T/ts.mp4" > "$T/ts.log" 2>&1 &&
        [ "$(probe "$T/ts.mp4")" = "mov,mp4,m4a,3gp,3g2,mj2 h264,aac" ] && pass "yt-dlp: MPEG-TS in .mp4 -c copy -f mp4 -bsf:a aac_adtstoasc" ||
        fail "yt-dlp: MPEG-TS in .mp4 into MP4: $(tail -n 3 "$T/ts.log" | tr '\n' ' ')"
fi
# silence for a video without sound (-f lavfi -i anullsrc ... -shortest)
if [ -f "$T/h264_aac.mp4" ]; then
    "$ff" -hide_banner -loglevel error -y -i "$T/h264_aac.mp4" -an -c copy "$T/mute.mp4" > "$T/mute.log" 2>&1
    # shellcheck disable=SC2086
    if "$ff" -hide_banner -loglevel error -y -i "$T/mute.mp4" -f lavfi -i anullsrc=cl=stereo:r=44100 -shortest \
        $kvs -c:a aac -b:a 128k -f mp4 "$T/silence.mp4" > "$T/silence.log" 2>&1; then
        o="$(probe "$T/silence.mp4")"
        [ "${o#* }" = h264,aac ] && pass "-f lavfi -i anullsrc=cl=stereo:r=44100 -shortest -> $o" ||
            fail "-f lavfi -i anullsrc=cl=stereo:r=44100 -shortest -> $o"
    else
        fail "-f lavfi -i anullsrc=cl=stereo:r=44100 -shortest: $(tail -n 3 "$T/silence.log" | tr '\n' ' ')"
    fi
fi
# a video from pictures (the plugin movie_from_image: task-%d.jpg, image2 by the name)
if [ -f "$T/shot.jpg" ]; then
    for i in 1 2 3; do cp "$T/shot.jpg" "$T/task-$i.jpg"; done
    # shellcheck disable=SC2086
    if "$ff" -hide_banner -loglevel error -y -framerate 1 -i "$T/task-%d.jpg" $kvs -pix_fmt yuv420p -an -f mp4 "$T/images.mp4" > "$T/images.log" 2>&1; then
        o="$(probe "$T/images.mp4")"
        [ "${o#* }" = h264 ] && pass "task-%d.jpg -> $o" || fail "task-%d.jpg -> $o"
    else
        fail "task-%d.jpg: $(tail -n 3 "$T/images.log" | tr '\n' ' ')"
    fi
fi

# --- refused: other formats named .mp4, playlists, protocols ---------------------
for f in "$T"/no_*.mp4; do
    s="${f##*/}"
    [ -s "$f" ] || { note "$s: the package's ffmpeg could not make it"; continue; }
    if "$fp" -v error "$f" > /dev/null 2>&1; then
        fail "$s: ffprobe opened it: $(probe "$f")"
    elif "$ff" -hide_banner -i "$f" 2>&1 | grep -q '^Input #0'; then
        fail "$s: ffmpeg -i opened it"
    else
        pass "$s: refused ($("$fp" -v error "$f" 2>&1 | tail -n 1 | sed "s#$T/##"))"
    fi
done
for u in "concat:$T/h264_aac.mp4|$T/h264_aac.mp4" "subfile,,start,0,end,0,,:$T/h264_aac.mp4" \
    "data:video/mp4;base64,AAAAIGZ0eXBpc29t" "http://127.0.0.1:9/x.mp4" "https://127.0.0.1:9/x.mp4" \
    "tcp://127.0.0.1:9" "udp://127.0.0.1:9" "rtmp://127.0.0.1:9/x" "crypto:$T/h264_aac.mp4" \
    "cache:$T/h264_aac.mp4" "async:$T/h264_aac.mp4" "unix:$T/sock" "gopher://127.0.0.1:9/x" "ftp://127.0.0.1:9/x"; do
    n="${u%%:*}"
    if "$fp" -v error "$u" > "$T/proto.log" 2>&1; then
        fail "protocol $n: opened"
    else
        pass "protocol $n: refused ($(tail -n 1 "$T/proto.log" | sed "s#$T/##g"))"
    fi
done
finish
