#!/usr/bin/env bash
# render.sh — the OSD is actually rasterised into the window: the screenshot is
# not all-black, and it contains non-white (i.e. non-video) pixels inside the
# bar region, measured against white.mp4.
#
# PASS means:
#   * a `window` screenshot was captured whose size == osd-dimensions
#   * mean luma > 20 (not an all-black surface)
#   * the frame is mostly white (the white.mp4 fixture decoded correctly)
#   * non-white pixels exist in the bottom BAR_FRAC of the surface
#   * the detected non-white bbox is reported (bar bbox), and its width spans
#     at least --min-span of the bar region's width
#
# The scenario pauses playback first so the video frame is static: every
# non-white pixel is then OSD (the fixture is solid white).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../ipc.sh"
HARNESS_SCENARIO=render

BAR_FRAC="$HARNESS_BAR_FRAC"
MIN_SPAN=0.40
TOL=6

help() {
    cat <<'EOF'
render.sh — is the OSD drawn, and where?

USAGE
  scenarios/render.sh [options]

OPTIONS
  --script DIR|FILE   GUI script (default: ./mpvgui, then <harness>/../../mpvgui)
  --media FILE        must be a mostly-white clip (default media/white.mp4)
  --bar-frac F        bar height as a fraction of surface height (default 0.10)
  --min-span F        required horizontal span of OSD pixels in the bar, as a
                      fraction of the bar region width (default 0.40)
  --tol N             "non-white" threshold: gray <= 255-N (default 6)
  --keep              keep the screenshots in the artifact dir
  -h, --help          this help

PASS means: screenshot == osd size, not all black, mostly white (white.mp4),
and non-white pixels exist in the bottom BAR_FRAC (the bar). The bar bbox is
printed; if the GUI draws its bar elsewhere, re-run with --bar-frac or read the
reported bbox and tune the harness.

Trap: only screenshots in `window` mode contain the OSD, and mpv clears the
OSD whenever osd-dimensions changes, so the GUI must redraw on resize.
EOF
}

harness_parse_common "$@"
set -- ${HARNESS_ARGS[@]+"${HARNESS_ARGS[@]}"}
KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) help; exit 0 ;;
        --bar-frac) BAR_FRAC="$2"; shift 2 ;;
        --min-span) MIN_SPAN="$2"; shift 2 ;;
        --tol) TOL="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        *) echo "render.sh: unknown argument '$1' (try --help)" >&2; exit 2 ;;
    esac
done
HARNESS_BAR_FRAC="$BAR_FRAC"
[ -n "$HARNESS_MEDIA" ] || HARNESS_MEDIA="$HARNESS_MEDIA_DIR/white.mp4"

harness_boot
SOCK="$HARNESS_MPV_SOCK"
osd_refresh "$SOCK"
info "surface: ${OSD_W}x${OSD_H}  bar region: y=${OSD_H}..$((OSD_H)) minus $(bar_height)px  tol=$TOL"

# ---- static frame: pause so the only changing pixels are OSD -----------------
ipc_set "$SOCK" pause true
ipc_wait "$SOCK" pause true 3 >/dev/null || diag "could not pause playback (continuing: frame may not be static)"
sleep 0.3

ARTS="${HARNESS_ARTIFACTS:-$HARNESS_RUN_DIR/artifacts/render}"
harness_reveal_osd "$SOCK" || diag "could not nudge the pointer (OSD may be hidden)"
mkdir -p "$ARTS"
SHOT="$ARTS/render.png"

if ! out="$(harness_shot "$SOCK" "$SHOT" "$HARNESS_TIMEOUT")"; then
    die "no usable screenshot: $IPC_LAST_ERROR"
fi
pass "screenshot $out"
assert_exists "screenshot file" "$SHOT" || finish

# ---- 1. not all black ------------------------------------------------------
stats="$(img_stats "$SHOT" "" "$TOL")" || die "cannot scan $SHOT"
mean=$(printf '%s' "$stats" | sed -n 's/.*mean=\([0-9.]*\).*/\1/p')
max=$(printf '%s' "$stats" | sed -n 's/.*max=\([0-9]*\).*/\1/p')
bbox="$(img_bbox "$SHOT" "" "$TOL")" || die "cannot scan $SHOT"
nonwhite=$(printf '%s' "$bbox" | sed -n 's/.*nonwhite=\([0-9]*\).*/\1/p')

if [ "${nonwhite:-0}" -eq 0 ]; then
    # an auto-hiding bar may have expired (--osd-duration is 1000ms): hover
    # again and take one more frame before declaring the OSD missing
    diag "first frame has no non-white pixels — nudging the pointer and re-shooting"
    harness_reveal_osd "$SOCK" >/dev/null 2>&1 || true
    if harness_shot "$SOCK" "$SHOT" "$HARNESS_TIMEOUT" >/dev/null 2>&1; then
        stats="$(img_stats "$SHOT" "" "$TOL")"
        mean=$(printf '%s' "$stats" | sed -n 's/.*mean=\([0-9.]*\).*/\1/p')
        max=$(printf '%s' "$stats" | sed -n 's/.*max=\([0-9]*\).*/\1/p')
        bbox="$(img_bbox "$SHOT" "" "$TOL")"
        nonwhite=$(printf '%s' "$bbox" | sed -n 's/.*nonwhite=\([0-9]*\).*/\1/p')
    fi
fi
info "frame stats: $stats"

# ---- 1. not all black ------------------------------------------------------
if awk -v m="$mean" 'BEGIN { exit !(m > 20) }'; then
    pass "surface is not all black (mean luma $mean, max $max)"
else
    fail "surface is essentially black (mean luma $mean) — nothing rendered"
fi

# ---- 2. the white fixture really is white ----------------------------------
if awk -v m="$mean" 'BEGIN { exit !(m >= 200) }'; then
    pass "frame is mostly white (mean luma $mean) — white.mp4 decoded correctly"
else
    fail "mean luma $mean is too low for a white.mp4 frame: either the fixture is wrong or the OSD covers most of the surface"
fi

# ---- 3. non-white pixels anywhere ------------------------------------------
info "non-white bbox: $bbox"
if [ "${nonwhite:-0}" -gt 0 ]; then
    pass "$nonwhite non-white pixel(s) found (OSD present)"
else
    fail "no non-white pixels at all: the OSD was not drawn into the window screenshot"
    diag "screenshot: $SHOT"
    diag "if the GUI only draws when needed, make sure it redraws after osd-dimensions changes and keeps the OSD alive while it is meant to be visible (osd-duration=1000ms)"
    finish
fi

# ---- 4. non-white pixels inside the bar region -----------------------------
barh=$(bar_height)
bary0=$(bar_y0)
bar_crop="${OSD_W}x${barh}+0+${bary0}"
bar_bbox="$(img_bbox "$SHOT" "$bar_crop" "$TOL")" || die "cannot scan bar region"
bar_hits=$(printf '%s' "$bar_bbox" | sed -n 's/.*nonwhite=\([0-9]*\).*/\1/p')
bar_w=$(printf '%s' "$bar_bbox" | sed -n 's/.*w=\([0-9]*\).*/\1/p')
info "bar region crop=$bar_crop -> $bar_bbox"

if [ "${bar_hits:-0}" -gt 0 ]; then
    pass "bar region (bottom ${barh}px) contains ${bar_hits} non-white pixel(s), span ${bar_w}px"
else
    fail "no non-white pixels in the bar region (bottom ${barh}px) — the bar is not where the harness expects it"
    diag "detected OSD bbox is $bbox; re-run with --bar-frac if the bar is taller/shorter"
    diag "screenshot: $SHOT"
fi

# ---- 5. the bar spans a useful part of the width ---------------------------
need=$(awk -v w="$OSD_W" -v f="$MIN_SPAN" 'BEGIN { printf "%d", w * f }')
if [ "${bar_w:-0}" -ge "$need" ]; then
    pass "bar OSD spans ${bar_w}px >= ${need}px ($(awk -v a="$bar_w" -v w="$OSD_W" 'BEGIN{printf "%.0f%%", 100*a/w}') of the surface width)"
else
    fail "bar OSD spans only ${bar_w}px, expected >= ${need}px — the bar looks missing/partial"
fi

# ---- evidence: vertical bands of non-white rows ---------------------------
info "non-white row bands (y0..y1, rows):"
img_bands "$SHOT" "" "$TOL" | sed 's/^/        /' || true

# ---- 6. OSD must survive an osd-dimensions change -------------------------
if ipc_set "$SOCK" window-scale 0.5 2>/dev/null; then
    sleep 0.8
    if osd2="$(ipc_wait_osd "$SOCK" 5)"; then
        if [ "${osd2/ /x}" != "${OSD_W}x${OSD_H}" ]; then
            pass "resize observed: ${OSD_W}x${OSD_H} -> ${osd2/ /x}"
            if harness_shot "$SOCK" "$ARTS/render-resized.png" 5 >/dev/null 2>&1; then
                nb=$(img_bbox "$ARTS/render-resized.png" "" "$TOL" | sed -n 's/.*nonwhite=\([0-9]*\).*/\1/p')
                if [ "${nb:-0}" -gt 0 ]; then
                    pass "OSD still drawn after resize (${nb} non-white px) — GUI redraws on osd-dimensions"
                else
                    fail "OSD vanished after the resize: the GUI does not redraw on osd-dimensions change"
                fi
            else
                skip "could not screenshot after resize: $IPC_LAST_ERROR"
            fi
            ipc_set "$SOCK" window-scale 1 2>/dev/null || true
        else
            skip "window-scale 0.5 did not change the surface (compositor ignored it) — resize check skipped"
        fi
    else
        skip "surface did not come back after resize: $IPC_LAST_ERROR"
    fi
else
    skip "window-scale is not settable — resize check skipped"
fi

[ "$KEEP" = 1 ] || true
info "artifacts: $ARTS"
finish
