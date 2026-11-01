#!/usr/bin/env bash
# fixtures.sh — generate the media fixtures the mpv GUI harness needs.
#
# Idempotent: a fixture is only (re)generated when it is missing or when its
# probed duration / dimensions do not match the spec below.  Safe to call from
# every scenario / run.sh; it is a no-op once the tree is warm.
#
# Usage:
#   ./fixtures.sh [--force] [--dir DIR] [--help]
#
# Exit status: 0 = all fixtures present and valid, non-zero = generation failed.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEDIA_DIR="${HARNESS_MEDIA_DIR:-$HARNESS_DIR/media}"
FORCE=0

usage() {
    cat <<'EOF'
fixtures.sh — generate media fixtures for the mpv Lua-OSD GUI harness

USAGE
  ./fixtures.sh [options]

OPTIONS
  -d, --dir DIR   output directory (default: <harness>/media, env HARNESS_MEDIA_DIR)
  -f, --force     regenerate everything even if valid
  -h, --help      this help

FIXTURES (all h264 / yuv420p / faststart unless noted)
  video1080p60.mp4   8s 1920x1080@60 testsrc2, crf 23   (perf + seek/click target)
  white.mp4          4s 1920x1080 solid white, 30fps    (pixel assertions vs white)
  audio.m4a          3s 440Hz sine, AAC                 (audio-only robustness)
  pl/ep01..ep05.mp4  5x 1s 320x180@30 distinct clips    (playlist tests)
  tracks.mkv         6s 640x360, 2 audio + 2 subs + 3 chapters (menu pages)
  shaders/*.hook     tint red/blue/green + deliberately broken (shader tests)

REQUIRES
  ffmpeg / ffprobe (the repo dev shell provides ffmpeg 9.0.2).

NOTES
  white.mp4 is encoded limited-range (tv) exactly like a normal file, so decoded
  RGB is (255,255,255) — verified: pixel scans see 255, not 235.
  Generation of video1080p60.mp4 takes a few seconds; the result is ~50-100 MB.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--dir) MEDIA_DIR="$2"; shift 2 ;;
        -f|--force) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "fixtures.sh: unknown argument '$1' (try --help)" >&2; exit 2 ;;
    esac
done

command -v ffmpeg  >/dev/null || { echo "fixtures.sh: ffmpeg not found (run inside the repo dev shell)" >&2; exit 2; }
command -v ffprobe >/dev/null || { echo "fixtures.sh: ffprobe not found (run inside the repo dev shell)" >&2; exit 2; }

mkdir -p "$MEDIA_DIR/pl"
MEDIA_DIR="$(cd "$MEDIA_DIR" && pwd)"

# probe_ok <file> <want_duration> <want_w> <want_h> ; duration tolerance 0.35s
probe_ok() {
    local f="$1" want_dur="$2" want_w="$3" want_h="$4"
    [ -s "$f" ] || return 1
    local info
    info=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=width,height -show_entries format=duration \
        -of default=nw=1:nk=1 "$f" 2>/dev/null) || return 1
    local w h dur
    w=$(printf '%s\n' "$info" | sed -n 1p)
    h=$(printf '%s\n' "$info" | sed -n 2p)
    dur=$(printf '%s\n' "$info" | sed -n 3p)
    [ "$w" = "$want_w" ] || return 1
    [ "$h" = "$want_h" ] || return 1
    awk -v d="$dur" -v w="$want_dur" 'BEGIN { exit !(d > w - 0.35 && d < w + 0.35) }' || return 1
}

probe_audio_ok() {
    local f="$1" want_dur="$2"
    [ -s "$f" ] || return 1
    local dur
    dur=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$f" 2>/dev/null) || return 1
    awk -v d="$dur" -v w="$want_dur" 'BEGIN { exit !(d > w - 0.35 && d < w + 0.35) }' || return 1
}

# ---------------------------------------------------------------- video1080p60
gen_video1080p60() {
    local out="$MEDIA_DIR/video1080p60.mp4"
    if [ "$FORCE" = 0 ] && probe_ok "$out" 8 1920 1080; then
        echo "  ok      video1080p60.mp4 (cached)"
        return 0
    fi
    echo "  build   video1080p60.mp4  (8s 1920x1080@60 testsrc2 crf23) ..."
    ffmpeg -y -loglevel error -f lavfi -i "testsrc2=size=1920x1080:rate=60:duration=8" \
        -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -g 60 \
        -movflags +faststart "$out"
    probe_ok "$out" 8 1920 1080 || { echo "fixtures.sh: video1080p60.mp4 is invalid after generation" >&2; return 1; }
    echo "  ok      video1080p60.mp4 ($(du -h "$out" | cut -f1))"
}

# --------------------------------------------------------------------- white.mp4
gen_white() {
    local out="$MEDIA_DIR/white.mp4"
    if [ "$FORCE" = 0 ] && probe_ok "$out" 4 1920 1080; then
        echo "  ok      white.mp4 (cached)"
        return 0
    fi
    echo "  build   white.mp4  (4s 1920x1080 white) ..."
    ffmpeg -y -loglevel error -f lavfi -i "color=c=white:size=1920x1080:rate=30:duration=4" \
        -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p -g 30 \
        -movflags +faststart "$out"
    probe_ok "$out" 4 1920 1080 || { echo "fixtures.sh: white.mp4 is invalid after generation" >&2; return 1; }
    echo "  ok      white.mp4 ($(du -h "$out" | cut -f1))"
}

# -------------------------------------------------------------------- audio.m4a
gen_audio() {
    local out="$MEDIA_DIR/audio.m4a"
    if [ "$FORCE" = 0 ] && probe_audio_ok "$out" 3; then
        echo "  ok      audio.m4a (cached)"
        return 0
    fi
    echo "  build   audio.m4a  (3s 440Hz sine, aac) ..."
    ffmpeg -y -loglevel error -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=3" \
        -c:a aac -b:a 128k "$out"
    probe_audio_ok "$out" 3 || { echo "fixtures.sh: audio.m4a is invalid after generation" >&2; return 1; }
    echo "  ok      audio.m4a ($(du -h "$out" | cut -f1))"
}

# ------------------------------------------------------------ shaders/
# mpv user shaders ("hooks"). Verified against mpv 0.41.0: a shader hooked to
# MAIN with `//!BIND HOOKED` and no `//!SAVE` overwrites the hooked texture, so
# multiplying by a colour tints the whole video. These are *known-good*
# fixtures: fixtures.sh renders white.mp4 through tint-red.hook with plain mpv
# (no GUI) and prints the resulting pixel so a bad fixture surfaces here.
gen_shaders() {
    local dir="$MEDIA_DIR/shaders"
    mkdir -p "$dir"
    local f

    _hook() { # _hook <file> <desc> <r> <g> <b>
        local fn="$dir/$1"
        cat >"$fn" <<HOOK
//!DESC $2
//!HOOK MAIN
//!BIND HOOKED
vec4 hook() {
    vec3 c = HOOKED_tex(HOOKED_pos).rgb;
    return vec4(c * vec3($3, $4, $5), 1.0);
}
HOOK
        echo "  ok      shaders/$1"
    }

    if [ "$FORCE" = 1 ]; then rm -f "$dir"/*.hook; fi
    local have=0
    for f in tint-red.hook tint-blue.hook tint-green.hook; do [ -s "$dir/$f" ] && have=$((have + 1)); done
    if [ "$have" = 3 ]; then
        for f in tint-red.hook tint-blue.hook tint-green.hook; do echo "  ok      shaders/$f (cached)"; done
    else
        _hook tint-red.hook   "harness tint red (multiply RGB by 1,0,0)"   1.0 0.0 0.0
        _hook tint-blue.hook  "harness tint blue (multiply RGB by 0,0,1)"  0.0 0.0 1.0
        _hook tint-green.hook "harness tint green (multiply RGB by 0,1,0)" 0.0 1.0 0.0
    fi

    if [ ! -s "$dir/broken.hook" ] || [ "$FORCE" = 1 ]; then
        cat >"$dir/broken.hook" <<'HOOK'
//!DESC harness deliberately broken shader
//!HOOK MAIN
//!BIND HOOKED
vec4 hook() {
    this_is_not_glsl(;   // <- compile error on purpose
    return undefined_symbol * 2.0;
}
HOOK
        echo "  ok      shaders/broken.hook"
    else
        echo "  ok      shaders/broken.hook (cached)"
    fi
}

# Render white.mp4 through tint-red.hook with a plain mpv (no GUI) and print the
# centre pixel: a broken fixture must be caught by fixtures.sh, not by a scenario.
_check_shader_pixels() {
    command -v mpv >/dev/null 2>&1 || return 0
    command -v socat >/dev/null 2>&1 || return 0
    local tag="fixtures-shader-$$"
    local sock="/tmp/$tag.sock" log="/tmp/$tag.log" png="/tmp/$tag.png"
    rm -f "$sock" "$log" "$png"
    mpv --no-config --vo=gpu-next --gpu-api=vulkan --gpu-context=waylandvk --osc=no \
        --input-ipc-server="$sock" --geometry=320x180 --autofit=320x180 \
        --glsl-shaders="$MEDIA_DIR/shaders/tint-red.hook" --pause \
        --force-window=yes --idle=yes "$MEDIA_DIR/white.mp4" >"$log" 2>&1 &
    local pid=$! i
    for i in $(seq 1 120); do [ -S "$sock" ] && break; sleep 0.05; done
    if [ ! -S "$sock" ]; then
        echo "  WARN    could not start mpv to validate the shader fixtures (see $log)"
        kill "$pid" 2>/dev/null || true
        return 0
    fi
    sleep 1
    printf '%s\n' "{\"command\":[\"screenshot-to-file\",\"$png\",\"window\"]}" |
        timeout 5 socat -t 5 - "UNIX-CONNECT:$sock" >/dev/null 2>&1
    sleep 0.5
    printf '%s\n' '{"command":["quit"]}' | timeout 5 socat -t 5 - "UNIX-CONNECT:$sock" >/dev/null 2>&1
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f "$sock"
    if [ -s "$png" ]; then
        # shellcheck source=img.sh
        . "$HARNESS_DIR/img.sh"
        echo "  check   tint-red.hook -> RGB ($(img_rgb_at "$png" 160 90 2>/dev/null)) at 160,90 (expect ~255 0 0)"
        rm -f "$png"
    else
        echo "  WARN    could not screenshot the shader fixture check (see $log)"
    fi
    rm -f "$log"
}

# ------------------------------------------------------------------------ pl/
gen_playlist() {
    local colors=(red green blue yellow magenta) i out
    for i in 1 2 3 4 5; do
        out="$MEDIA_DIR/pl/ep0$i.mp4"
        if [ "$FORCE" = 0 ] && probe_ok "$out" 1 320 180; then
            echo "  ok      pl/ep0$i.mp4 (cached)"
            continue
        fi
        echo "  build   pl/ep0$i.mp4 ..."
        ffmpeg -y -loglevel error \
            -f lavfi -i "color=c=${colors[$((i-1))]}:size=320x180:rate=30:duration=1" \
            -f lavfi -i "sine=frequency=$((300 + i * 60)):sample_rate=48000:duration=1" \
            -vf "drawbox=x=8:y=8:w=$((i * 40)):h=24:color=black@1:t=fill" \
            -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p -g 30 \
            -c:a aac -b:a 64k -shortest -movflags +faststart "$out"
        probe_ok "$out" 1 320 180 || { echo "fixtures.sh: pl/ep0$i.mp4 is invalid after generation" >&2; return 1; }
        echo "  ok      pl/ep0$i.mp4"
    done
}

# ------------------------------------------------------------------- tracks.mkv
# 6 s 640x360 clip with two audio tracks, two subtitle tracks and three
# chapters: the fixture for the menu pages (track switching, chapter seeks).
probe_tracks_ok() {
    local f="$1"
    [ -s "$f" ] || return 1
    local na ns nc
    na=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$f" 2>/dev/null | grep -c .)
    ns=$(ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$f" 2>/dev/null | grep -c .)
    nc=$(ffprobe -v error -show_entries chapter=start_time -of csv=p=0 "$f" 2>/dev/null | grep -c .)
    [ "$na" = 2 ] && [ "$ns" = 2 ] && [ "$nc" = 3 ]
}

gen_tracks() {
    local out="$MEDIA_DIR/tracks.mkv"
    if [ "$FORCE" = 0 ] && probe_tracks_ok "$out"; then
        echo "  ok      tracks.mkv (cached)"
        return 0
    fi
    echo "  build   tracks.mkv  (6s 640x360, 2 audio, 2 subs, 3 chapters) ..."
    local tmp
    tmp=$(mktemp -d)
    printf '1\n00:00:00,000 --> 00:00:02,000\nEnglish line one\n\n2\n00:00:02,000 --> 00:00:05,000\nEnglish line two\n' \
        >"$tmp/eng.srt"
    printf '1\n00:00:00,000 --> 00:00:02,000\n日本語 その一\n\n2\n00:00:02,000 --> 00:00:05,000\n日本語 その二\n' \
        >"$tmp/jpn.srt"
    cat >"$tmp/meta.txt" <<'META'
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=2000
title=Intro
[CHAPTER]
TIMEBASE=1/1000
START=2000
END=4000
title=Middle
[CHAPTER]
TIMEBASE=1/1000
START=4000
END=6000
title=End
META
    ffmpeg -y -loglevel error \
        -f lavfi -i "testsrc2=size=640x360:rate=30:duration=6" \
        -f lavfi -i "sine=frequency=440:duration=6" \
        -f lavfi -i "sine=frequency=880:duration=6" \
        -i "$tmp/eng.srt" -i "$tmp/jpn.srt" -i "$tmp/meta.txt" \
        -map 0:v -map 1:a -map 2:a -map 3 -map 4 -map_metadata 5 -map_chapters 5 \
        -c:v libx264 -preset veryfast -crf 26 -pix_fmt yuv420p \
        -c:a aac -b:a 96k -c:s srt \
        -metadata:s:a:0 language=eng -metadata:s:a:0 title="English 440" \
        -metadata:s:a:1 language=jpn -metadata:s:a:1 title="Japanese 880" \
        -metadata:s:s:0 language=eng -metadata:s:s:0 title="English subs" \
        -metadata:s:s:1 language=jpn -metadata:s:s:1 title="Japanese subs" \
        -metadata:s:v:0 title="Main video" \
        "$out"
    rm -rf "$tmp"
    probe_tracks_ok "$out" || { echo "fixtures.sh: tracks.mkv is invalid after generation" >&2; return 1; }
    echo "  ok      tracks.mkv ($(du -h "$out" | cut -f1))"
}

echo "fixtures.sh: media dir $MEDIA_DIR"
gen_video1080p60
gen_white
gen_audio
gen_playlist
gen_tracks
gen_shaders
_check_shader_pixels
echo "fixtures.sh: all fixtures ready"
