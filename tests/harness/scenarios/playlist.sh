#!/usr/bin/env bash
# playlist.sh — Tab opens the playlist panel (pixels change in the panel
# region) and clicking the second row changes `playlist-pos`.
#
# PASS means:
#   * playlist-count >= 2 (the media really is a playlist)
#   * Tab changes pixels inside the panel region (diff against a static frame)
#   * clicking row 2 sets playlist-pos to 1 within --wait
#   * the log stays clean
#
# The video is paused first so the frame is static: any pixel difference is OSD.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../ipc.sh"
HARNESS_SCENARIO=playlist

PANEL_LEFT=0.50
PANEL_TOP=0.00
PANEL_BOTTOM=0.60
ROWS=5
ROW=2
EXPECT_POS=""
KEY="Tab"
MIN_CHANGED=200
TOL=8
WAIT=4

help() {
    cat <<'EOF'
playlist.sh — playlist panel via Tab, row click via IPC

USAGE
  scenarios/playlist.sh [options]

OPTIONS
  --rows N            rows in the panel, used to compute row 2's y (default 5)
  --row N             which row to click (1-based, default 2)
  --expect-pos N      expected playlist-pos after the click (default row-1)
  --key KEY           key that toggles the panel (default Tab)
  --panel-left F      panel region left edge, fraction of width   (default 0.50)
  --panel-top F       panel region top edge, fraction of height   (default 0.00)
  --panel-bottom F    panel region bottom edge                    (default 0.60)
  --min-changed N     changed pixels required inside the panel region (200)
  --tol N             per-pixel difference threshold, 0..255 (default 8)
  --wait SECS         wait for the panel/click to take effect (default 4)
  --x X --y Y         explicit coordinates for the row click (overrides --rows)
  --script/--media/--geometry/--timeout   common options

PASS means: playlist-count >= 2, Tab changed >= MIN_CHANGED pixels inside the
panel region, and clicking row N set playlist-pos to N-1.

If run without --media it plays media/pl/*.mp4 (5 clips) as one playlist.
Tune --panel-* once the real panel geometry is known; the detected change bbox
is printed as evidence.
EOF
}

harness_parse_common "$@"
set -- ${HARNESS_ARGS[@]+"${HARNESS_ARGS[@]}"}
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) help; exit 0 ;;
        --rows) ROWS="$2"; shift 2 ;;
        --row) ROW="$2"; shift 2 ;;
        --expect-pos) EXPECT_POS="$2"; shift 2 ;;
        --key) KEY="$2"; shift 2 ;;
        --panel-left) PANEL_LEFT="$2"; shift 2 ;;
        --panel-top) PANEL_TOP="$2"; shift 2 ;;
        --panel-bottom) PANEL_BOTTOM="$2"; shift 2 ;;
        --min-changed) MIN_CHANGED="$2"; shift 2 ;;
        --tol) TOL="$2"; shift 2 ;;
        --wait) WAIT="$2"; shift 2 ;;
        --x) PX="$2"; shift 2 ;;
        --y) PY="$2"; shift 2 ;;
        *) echo "playlist.sh: unknown argument '$1' (try --help)" >&2; exit 2 ;;
    esac
done

# ---- boot (needs a real playlist) ----------------------------------------
if [ "${HARNESS_BOOTED:-0}" != 1 ] && [ -z "$HARNESS_MEDIA" ]; then
    pls=("$HARNESS_MEDIA_DIR"/pl/ep0*.mp4)
    [ -e "${pls[0]}" ] || die "no playlist media: ${pls[0]} missing (run fixtures.sh)"
    harness_require_script "$HARNESS_SCRIPT_DIR"
    mpv_start playlist "$HARNESS_SCRIPT_DIR" "${pls[@]}"
    harness_wait_playback
    HARNESS_BOOTED=1
    HARNESS_MEDIA="${pls[0]}"
fi
harness_boot
SOCK="$HARNESS_MPV_SOCK"
osd_refresh "$SOCK"

COUNT="$(ipc_get_num "$SOCK" playlist-count 2>/dev/null || echo 0)"
POS_BEFORE="$(ipc_get_num "$SOCK" playlist-pos 2>/dev/null || echo 0)"
info "surface ${OSD_W}x${OSD_H} playlist-count=$COUNT playlist-pos=$POS_BEFORE"
if [ "${COUNT:-0}" -ge 2 ]; then
    pass "playlist loaded (count=$COUNT)"
else
    fail "playlist-count=$COUNT — media is not a playlist; pass 5 files or media/pl/*.mp4"
    info "hint: run via ../run.sh playlist (uses media/pl/ep01..05.mp4)"
    finish
fi

# ---- static frame ---------------------------------------------------------
ipc_set "$SOCK" pause true >/dev/null 2>&1 || true
ipc_wait "$SOCK" pause true 3 >/dev/null || diag "could not pause; diffs may include video motion"

ARTS="${HARNESS_ARTIFACTS:-$HARNESS_RUN_DIR/artifacts/playlist}"
mkdir -p "$ARTS"
harness_reveal_osd "$SOCK" || diag "could not nudge the pointer before screenshot A"
A="$ARTS/panel-closed.png"
B="$ARTS/panel-open.png"

harness_shot "$SOCK" "$A" "$HARNESS_TIMEOUT" >/dev/null || die "screenshot A failed: $IPC_LAST_ERROR"
info "layout before $KEY: panel_open=$(layout_q '.panel_open // "?"')"

# ---- toggle the panel -----------------------------------------------------
ipc_key "$SOCK" "$KEY" || die "keypress $KEY failed: '$IPC_LAST_ERROR'"
harness_reveal_osd "$SOCK" || true
sleep 0.45
harness_shot "$SOCK" "$B" "$HARNESS_TIMEOUT" >/dev/null || die "screenshot B failed: $IPC_LAST_ERROR"

# the panel geometry only exists in the published layout while it is open
harness_layout_refresh "$SOCK" || true
PANELW=""; PANELH=""; PANELX=""; PANELY=""
if layout_has && [ "$(layout_q '.panel // empty')" != "" ]; then
    ROWS="$(layout_panel_rows)"
    info "published panel layout: x0=$(layout_q '.panel[0]') x1=$(layout_q '.panel[1]') rows_y0=$(layout_q '.panel[2]') row_h=$(layout_q '.panel[3]') rows=${ROWS}"
    CROP="$(layout_panel_crop)"
    PANELX="$(layout_q '.panel[0]')"
    PANELW="$(awk -v a="$(layout_q '.panel[0]')" -v b="$(layout_q '.panel[1]')" 'BEGIN { printf "%d", b - a }')"
    PANELY=0
    PANELH="$(awk -v y0="$(layout_q '.panel[2]')" -v rh="$(layout_q '.panel[3]')" -v n="$ROWS" 'BEGIN { printf "%d", y0 + n * rh }')"
    if [ "$ROWS" -lt "$ROW" ]; then
        fail "published panel exposes ${ROWS} rows, cannot click row ${ROW}"
        finish
    fi
else
    # fallback: fraction-based region (see --panel-left/--panel-top/--panel-bottom)
    PANELW=$(awk -v w="$OSD_W" -v l="$PANEL_LEFT" 'BEGIN { printf "%d", w * (1 - l) }')
    PANELH=$(awk -v h="$OSD_H" -v t="$PANEL_TOP" -v b="$PANEL_BOTTOM" 'BEGIN { printf "%d", h * (b - t) }')
    PANELX=$(awk -v w="$OSD_W" -v l="$PANEL_LEFT" 'BEGIN { printf "%d", w * l }')
    PANELY=$(awk -v h="$OSD_H" -v t="$PANEL_TOP" 'BEGIN { printf "%d", h * t }')
    CROP="${PANELW}x${PANELH}+${PANELX}+${PANELY}"
    info "no published panel layout; using fractions: crop=$CROP rows=$ROWS"
fi

changed="$(img_diff_stats "$A" "$B" "$CROP" "$TOL" | sed -n 's/.*nonwhite=\([0-9]*\).*/\1/p')"
bbox="$(img_diff_bbox "$A" "$B" "$CROP" "$TOL")"
info "panel diff: changed=${changed:-0} px  bbox=$bbox  crop=$CROP"

if [ "${changed:-0}" -ge "$MIN_CHANGED" ]; then
    pass "$KEY changed ${changed}px inside the panel region (panel opened)"
else
    fail "$KEY changed only ${changed:-0}px inside the panel region (expected >= $MIN_CHANGED)"
    diag "whole-frame diff for comparison: $(img_diff_stats "$A" "$B" "" "$TOL")"
    diag "screenshots: $A $B"
fi

# ---- click row N ----------------------------------------------------------
if layout_has && [ "$(layout_q '.panel // empty')" != "" ]; then
    set -- $(panel_row_center "$((ROW - 1))")
    [ -n "${PX:-}" ] || PX="$1"
    [ -n "${PY:-}" ] || PY="$2"
    ROW_H="$(layout_q '.panel[3]')"
else
    ROW_H=$(awk -v h="$PANELH" -v r="$ROWS" 'BEGIN { printf "%d", h / r }')
    [ -n "${PX:-}" ] || PX=$(awk -v x="$PANELX" -v w="$PANELW" 'BEGIN { printf "%d", x + w / 2 }')
    [ -n "${PY:-}" ] || PY=$(awk -v y="$PANELY" -v rh="$ROW_H" -v r="$ROW" 'BEGIN { printf "%d", y + (r - 0.5) * rh }')
fi
[ -n "$EXPECT_POS" ] || EXPECT_POS=$((ROW - 1))

# the click must be able to change something: park playlist-pos somewhere else
POS_BEFORE="$(ipc_get_num "$SOCK" playlist-pos 2>/dev/null || echo 0)"
if [ "$POS_BEFORE" = "$EXPECT_POS" ]; then
    ipc_set "$SOCK" playlist-pos 0 >/dev/null 2>&1 || true
    sleep 0.2
    POS_BEFORE="$(ipc_get_num "$SOCK" playlist-pos 2>/dev/null || echo 0)"
    info "playlist-pos was already $EXPECT_POS — moved it to $POS_BEFORE so the click must change it"
    if [ "$POS_BEFORE" = "$EXPECT_POS" ]; then
        skip "cannot move playlist-pos away from $EXPECT_POS; the click assertion would be vacuous"
    fi
fi

info "clicking row $ROW at ($PX,$PY) (row_h=${ROW_H}px), expecting playlist-pos=$EXPECT_POS"
ipc_mouse_move "$SOCK" "$PX" "$PY"
ipc_click "$SOCK" "$PX" "$PY" 0 || die "click failed: $IPC_LAST_ERROR"

deadline=$((SECONDS + ${WAIT%.*}))
POS_AFTER="$POS_BEFORE"
while :; do
    POS_AFTER="$(ipc_get_num "$SOCK" playlist-pos 2>/dev/null || echo "$POS_BEFORE")"
    [ "$POS_AFTER" = "$EXPECT_POS" ] && break
    [ "$SECONDS" -ge "$deadline" ] && break
    sleep 0.05
done

if [ "$POS_AFTER" = "$EXPECT_POS" ]; then
    pass "clicking row $ROW set playlist-pos $POS_BEFORE -> $POS_AFTER"
else
    fail "clicking row $ROW left playlist-pos at $POS_AFTER (expected $EXPECT_POS)"
    diag "mouse-pos now: $(ipc_get "$SOCK" mouse-pos 2>/dev/null)"
    diag "row geometry is a guess (--rows/--panel-*); adjust with --x/--y if the panel rows differ"
fi

# ---- tidy up --------------------------------------------------------------
ipc_key "$SOCK" "$KEY" >/dev/null 2>&1 || true
log_assert_clean || true
info "artifacts: $A $B"
finish
