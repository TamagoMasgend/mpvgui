#!/usr/bin/env bash
# img.sh — dependency-free pixel inspection for PNG screenshots (ffmpeg + od + awk).
#
# Sourced by ipc.sh. Not meant to be run directly except with --help.
#
# Why not ImageMagick/python: the dev shell only guarantees ffmpeg, socat, jq,
# bash.  Every helper here decodes the PNG to 8-bit gray with ffmpeg and then
# scans the bytes with awk.  Luminance is enough for the assertions the harness
# makes ("is there anything that is not the white video?", "did these pixels
# change?"), and it is ~0.2 s for a 960x540 surface (2 M px ≈ 1 s).
#
# IMPORTANT — coordinate space: screenshots taken with
#   {"command":["screenshot-to-file",PATH,"window"]}
# are the *client surface*, i.e. exactly osd-dimensions w/h (verified:
# 956x538 surface -> 956x538 png; 960x540 -> 960x540).  Always re-read
# osd-dimensions and assert the png size matches (harness_shot does).
#
# Conventions:
#   * "non-white"  = gray <= 255 - tol   (tol default 6) — the fixtures are
#     solid white, so anything darker is OSD/letterbox.
#   * "changed"    = |a - b| >= tol
#   * crop         = ffmpeg crop geometry "WxH+X+Y" (default: whole image)

IMG_TOL_DEFAULT="${IMG_TOL_DEFAULT:-6}"

img_help() {
    cat <<'EOF'
img.sh — pixel helpers (ffmpeg + od + awk only)

  img_dim FILE                      -> "W H"
  img_stats FILE [CROP] [TOL]       -> pixels=.. min=.. max=.. mean=.. nonwhite=..
  img_bbox  FILE [CROP] [TOL]       -> x0=.. y0=.. x1=.. y1=.. w=.. h=.. nonwhite=..
                                       (bbox of pixels darker than 255-TOL)
  img_rows  FILE [CROP] [TOL]       -> "y=<n> nonwhite=<count>" for rows with hits
  img_cols  FILE [CROP] [TOL]       -> "x=<n> nonwhite=<count>" for cols with hits
  img_bands FILE [CROP] [TOL]       -> "y0=<a> y1=<b> rows=<n>" contiguous row bands
  img_diff_stats A B [CROP] [TOL]   -> pixels=.. max=.. mean=.. changed=..
  img_diff_bbox  A B [CROP] [TOL]   -> bbox/  span of pixels where |A-B| >= TOL
  img_diff_bands A B [CROP] [TOL]   -> contiguous row bands of change
  img_luma_at FILE X Y              -> gray value of one pixel

CROP accepts "WxH+X+Y" or "W:H:X:Y" (this ffmpeg build only parses the latter,
img.sh converts).
  img_is_mostly_black FILE [TOL]    -> exit 0 if mean <= TOL

All numbers are 0..255 luma.  Coordinates are png pixels, origin top-left.
EOF
}

# ---------------------------------------------------------------- internals
_img_awk() {
    cat <<'AWK'
BEGIN { n = 0; min = 255; max = 0; sum = 0; hits = 0; x0 = -1; y0 = -1; x1 = -1; y1 = -1; extra = 0; total = W * H }
{
    for (i = 1; i <= NF; i++) {
        v = $i + 0
        if (n >= total) { extra++; continue }
        x = n % W; y = int(n / W); n++
        if (v < min) min = v
        if (v > max) max = v
        sum += v
        hit = (dir == "low") ? (v < th) : (v >= th)
        if (hit) {
            hits++
            if (x0 < 0 || x < x0) x0 = x
            if (x > x1) x1 = x
            if (y0 < 0 || y < y0) y0 = y
            if (y > y1) y1 = y
            if (mode == "rows") rowhit[y]++
            if (mode == "cols") colhit[x]++
        }
    }
}
END {
    if (n == 0) { print "img.sh: empty input" > "/dev/stderr"; exit 3 }
    if (extra > 0) { printf "img.sh: byte count %d != W*H %d (crop/size mismatch)\n", n + extra, total > "/dev/stderr"; exit 4 }
    if (mode == "stats") printf "pixels=%d min=%d max=%d mean=%.2f nonwhite=%d\n", n, min, max, sum / n, hits
    else if (mode == "bbox") printf "x0=%d y0=%d x1=%d y1=%d w=%d h=%d nonwhite=%d pixels=%d\n", x0, y0, x1, y1, (hits ? x1 - x0 + 1 : 0), (hits ? y1 - y0 + 1 : 0), hits, n
    else if (mode == "rows") { for (y = 0; y < H; y++) if (rowhit[y]) printf "y=%d nonwhite=%d\n", y, rowhit[y] }
    else if (mode == "cols") { for (x = 0; x < W; x++) if (colhit[x]) printf "x=%d nonwhite=%d\n", x, colhit[x] }
    else { print "img.sh: bad mode " mode > "/dev/stderr"; exit 5 }
    if (min == 255 && max == 0) { }
}
AWK
}

# This ffmpeg build rejects the "WxH+X+Y" shorthand for crop (it parses
# crop=1x1+10+10 as an expression and dies with "Invalid chars"), so accept
# both spellings here and hand ffmpeg the W:H:X:Y form.
_img_crop_norm() {
    local c="${1:-}"
    [ -n "$c" ] || { printf ''; return 0; }
    case "$c" in
        *x*+*) printf '%s' "$c" | awk -F'[x+]' '{ printf "%s:%s:%s:%s", $1, $2, $3, $4 }' ;;
        *x*)   printf '%s' "$c" | awk -F'[x+]' '{ printf "%s:%s", $1, $2 }' ;;
        *)     printf '%s' "$c" ;;
    esac
}

_img_dim() { # FILE [CROP] -> "W H"
    local f="$1" crop="${2:-}" c
    if [ -n "$crop" ]; then
        c="$(printf '%s' "$crop" | tr ':x+' '  ')"
        # shellcheck disable=SC2086
        set -- $c
        printf '%s %s\n' "${1:-0}" "${2:-0}"
        return 0
    fi
    ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
        -of default=nw=1:nk=1 "$f" | awk 'NF { print; if (++n == 2) exit }' | paste -sd' ' -
}

_img_gray() { # FILE [CROP] -> raw gray bytes on stdout
    local f="$1" crop vf=""
    crop="$(_img_crop_norm "${2:-}")"
    [ -n "$crop" ] && vf="crop=$crop,"
    ffmpeg -v error -nostdin -i "$f" -vf "${vf}format=gray" -f rawvideo -pix_fmt gray -
}

_img_diff_gray() { # A B [CROP] -> raw |A-B| gray bytes
    local a="$1" b="$2" crop vf=""
    crop="$(_img_crop_norm "${3:-}")"
    [ -n "$crop" ] && vf=",crop=$crop"
    ffmpeg -v error -nostdin -i "$a" -i "$b" \
        -filter_complex "[0:v][1:v]blend=all_mode=difference${vf},format=gray" \
        -f rawvideo -pix_fmt gray -
}

_img_scan() { # MODE FILE CROP TOL DIR
    local mode="$1" file="$2" crop="${3:-}" tol="${4:-$IMG_TOL_DEFAULT}" dir="${5:-low}"
    local dim W H th
    dim="$(_img_dim "$file" "$crop")"
    if [ -z "$dim" ] || [ "${dim%% *}" = "" ]; then
        echo "img.sh: cannot determine dimensions of '$file'" >&2
        return 1
    fi
    W="${dim%% *}"; H="${dim##* }"
    if [ "$dir" = "low" ]; then th=$((255 - tol)); else th="$tol"; fi
    _img_gray "$file" "$crop" | od -An -v -tu1 -w256 |
        awk -v W="$W" -v H="$H" -v th="$th" -v dir="$dir" -v mode="$mode" "$(_img_awk)"
}

# ------------------------------------------------------------------- public
img_dim()      { _img_dim "$@"; }

img_stats() { # FILE [CROP] [TOL]
    _img_scan stats "$1" "${2:-}" "${3:-$IMG_TOL_DEFAULT}" low
}

img_bbox() { # FILE [CROP] [TOL]
    _img_scan bbox "$1" "${2:-}" "${3:-$IMG_TOL_DEFAULT}" low
}

img_rows() { # FILE [CROP] [TOL]
    _img_scan rows "$1" "${2:-}" "${3:-$IMG_TOL_DEFAULT}" low
}

img_cols() { # FILE [CROP] [TOL]
    _img_scan cols "$1" "${2:-}" "${3:-$IMG_TOL_DEFAULT}" low
}

# img_bands FILE [CROP] [TOL] -> contiguous vertical bands of non-white rows
img_bands() { # FILE [CROP] [TOL]
    img_rows "$@" | awk -F'[ =]' '
        { y = $2; if (!open) { start = y; open = 1; rows = 0 } else if (y != prev + 1) { printf "y0=%d y1=%d rows=%d\n", start, prev, rows; start = y; rows = 0 } rows++; prev = y }
        END { if (open) printf "y0=%d y1=%d rows=%d\n", start, prev, rows }'
}

img_diff_stats() { # A B [CROP] [TOL]
    local a="$1" b="$2" crop="${3:-}" tol="${4:-$IMG_TOL_DEFAULT}" dim W H
    dim="$(_img_dim "$a" "$crop")"; W="${dim%% *}"; H="${dim##* }"
    _img_diff_gray "$a" "$b" "$crop" | od -An -v -tu1 -w256 |
        awk -v W="$W" -v H="$H" -v th="$tol" -v dir="high" -v mode="stats" "$(_img_awk)"
}

img_diff_bbox() { # A B [CROP] [TOL]
    local a="$1" b="$2" crop="${3:-}" tol="${4:-$IMG_TOL_DEFAULT}" dim W H
    dim="$(_img_dim "$a" "$crop")"; W="${dim%% *}"; H="${dim##* }"
    _img_diff_gray "$a" "$b" "$crop" | od -An -v -tu1 -w256 |
        awk -v W="$W" -v H="$H" -v th="$tol" -v dir="high" -v mode="bbox" "$(_img_awk)"
}

img_diff_bands() { # A B [CROP] [TOL]
    local a="$1" b="$2" crop="${3:-}" tol="${4:-$IMG_TOL_DEFAULT}" dim W H
    dim="$(_img_dim "$a" "$crop")"; W="${dim%% *}"; H="${dim##* }"
    _img_diff_gray "$a" "$b" "$crop" | od -An -v -tu1 -w256 |
        awk -v W="$W" -v H="$H" -v th="$tol" -v dir="high" -v mode="rows" "$(_img_awk)" |
        awk -F'[ =]' '
            { y = $2; if (!open) { start = y; open = 1; rows = 0 } else if (y != prev + 1) { printf "y0=%d y1=%d rows=%d\n", start, prev, rows; start = y; rows = 0 } rows++; prev = y }
            END { if (open) printf "y0=%d y1=%d rows=%d\n", start, prev, rows }'
}

_img_rgb() { # FILE [CROP] -> raw rgb24 bytes
    local f="$1" crop vf=""
    crop="$(_img_crop_norm "${2:-}")"
    [ -n "$crop" ] && vf="crop=$crop,"
    ffmpeg -v error -nostdin -i "$f" -vf "${vf}format=rgb24" -f rawvideo -pix_fmt rgb24 -
}

img_rgb_at() { # FILE X Y -> "R G B" (0..255)
    _img_rgb "$1" "1x1+$2+$3" | od -An -tu1 -N3 | awk '{ printf "%d %d %d\n", $1, $2, $3 }'
}

img_rgb_mean() { # FILE [CROP] -> "R G B" means over the region
    _img_rgb "$1" "${2:-}" | od -An -v -tu1 -w256 |
        awk '{ for (i = 1; i <= NF; i++) { idx++; k = idx % 3; if (k == 1) r += $i; else if (k == 2) g += $i; else b += $i } }
             END { n = idx / 3; if (n > 0) printf "%.1f %.1f %.1f\n", r / n, g / n, b / n; else print "0 0 0" }'
}

# img_rgb_close <label> "R G B" "R2 G2 B2" <tol> -> PASS/FAIL line, rc 0/1
img_rgb_close() {
    local label="$1" got="$2" want="$3" tol="$4"
    if awk -v g="$got" -v w="$want" -v t="$tol" 'BEGIN {
            split(g, a, " "); split(w, b, " ")
            for (i = 1; i <= 3; i++) { d = a[i] - b[i]; if (d < 0) d = -d; if (d > t) exit 1 }
            exit 0 }'; then
        pass "$label: RGB ($got) within $tol of ($want)"
    else
        fail "$label: RGB ($got) differs from ($want) by more than $tol"
        return 1
    fi
}

img_luma_at() { # FILE X Y
    local f="$1" x="$2" y="$3"
    _img_gray "$f" "1x1+$x+$y" | od -An -tu1 -N1 | tr -d ' \n'
    echo
}

img_is_mostly_black() { # FILE [MEAN_TOL]
    local f="$1" tol="${2:-20}" stats mean
    stats="$(img_stats "$f")" || return 1
    mean=$(printf '%s\n' "$stats" | sed -n 's/.*mean=\([0-9.]*\).*/\1/p')
    awk -v m="$mean" -v t="$tol" 'BEGIN { exit !(m <= t) }'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        -h|--help|"") img_help ${1:+; exit 0} ;;
        *) img_help; exit 0 ;;
    esac
fi
