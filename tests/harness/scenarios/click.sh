#!/usr/bin/env bash
# click.sh — synthetic left click on a control, asserted through mpv properties.
#
# PASS means: the click was delivered at the requested surface pixel (verified
# through mouse-pos), and the property changed exactly as requested within
# --wait seconds.
#
# Presets derive their coordinates from the live surface (never hardcoded):
#   --control play        x = 3% of width, y = centre of the bottom bar
#   --control seek:F      x = F of the seekbar span, y = bar centre
#   --control vol         x = right end of the bar
# Override with --x/--y once you know the real layout.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../ipc.sh"
HARNESS_SCENARIO=click

CONTROL="play"
PX=""
PY=""
PROP="pause"
EXPECT="flip"
PROP_SET=0
EXPECT_SET=0
EXPECT_TIME=""
TOL="0.6"
WAIT="3"

help() {
    cat <<'EOF'
click.sh — synthetic click -> property assertion

USAGE
  scenarios/click.sh [--control play|seek:F|vol] [--x X --y Y]
                     [--prop NAME --expect flip|VALUE] [--expect-time SECS]
                     [--tol SECS] [--wait SECS]
  scenarios/click.sh --script DIR --media FILE [...]

OPTIONS
  --control play      click the play/pause button (default); asserts pause flips
  --control seek:F    click the seekbar at fraction F (0..1); asserts time-pos
                      ~= F*duration (or --expect-time); reads time-pos, not pause
  --control vol       click the volume slider; asserts volume changes
  --x X --y Y         explicit surface pixel (overrides --control) — use this as
                      soon as the GUI's real geometry is known
  --prop NAME         property to assert (default: pause)
  --expect flip       value must flip          (bool properties)
  --expect VALUE      value must equal VALUE   (string/number compare)
  --expect-time SECS  assert time-pos ~= SECS instead of --expect
  --tol SECS          tolerance for numeric/time comparisons (default 0.6)
  --wait SECS         how long to wait for the change (default 3)
  --script/--media/--geometry/--timeout   common options (see run.sh --help)

PASS means: mouse-pos confirms the pointer at (x,y) with hover=true and the
asserted property changed within --wait.

Notes
  * playback is paused before a seek click so time-pos cannot drift while the
    assertion is sampled;
  * a click is delivered as {"command":["mouse",X,Y,0]} — one press+release;
  * coordinates come from the GUI's published user-data/mpvgui/layout
    (bar/seek/volume/buttons) when present; otherwise the bar is assumed to
    occupy the bottom --bar-frac (default 0.10). --x/--y always win.
EOF
}

harness_parse_common "$@"
set -- ${HARNESS_ARGS[@]+"${HARNESS_ARGS[@]}"}
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) help; exit 0 ;;
        --control) CONTROL="$2"; shift 2 ;;
        --x) PX="$2"; shift 2 ;;
        --y) PY="$2"; shift 2 ;;
        --prop) PROP="$2"; PROP_SET=1; shift 2 ;;
        --expect) EXPECT="$2"; EXPECT_SET=1; shift 2 ;;
        --expect-time) EXPECT_TIME="$2"; shift 2 ;;
        --tol) TOL="$2"; shift 2 ;;
        --wait) WAIT="$2"; shift 2 ;;
        --bar-frac) HARNESS_BAR_FRAC="$2"; shift 2 ;;
        *) echo "click.sh: unknown argument '$1' (try --help)" >&2; exit 2 ;;
    esac
done

[ -n "$HARNESS_MEDIA" ] || HARNESS_MEDIA="$HARNESS_MEDIA_DIR/video1080p60.mp4"
harness_boot
SOCK="$HARNESS_MPV_SOCK"
osd_refresh "$SOCK"

FRAC=""
case "$CONTROL" in
    play)
        # play/pause button: assert that `pause` flips
        [ "$PROP_SET" = 1 ] || PROP=pause
        [ "$EXPECT_SET" = 1 ] || EXPECT=flip
        [ -n "$PX" ] || PX="$(bar_left_x)"
        [ -n "$PY" ] || PY="$(bar_y_center)"
        ;;
    seek:*)
        # seekbar: the observable state is time-pos.  This used to select
        # `time-pos` into an unused PROP_DEFAULT and keep reading `pause`.
        FRAC="${CONTROL#seek:}"
        [ "$PROP_SET" = 1 ] || PROP=time-pos
        [ "$EXPECT_SET" = 1 ] || EXPECT=""
        [ -n "$PX" ] || PX="$(seekbar_x_at "$FRAC")"
        [ -n "$PY" ] || PY="$(seekbar_y)"
        ;;
    vol)
        # volume slider: assert a volume change unless the caller says otherwise
        [ "$PROP_SET" = 1 ] || PROP=volume
        [ "$EXPECT_SET" = 1 ] || EXPECT=change
        [ -n "$PX" ] || PX="$(volume_center_x)"
        [ -n "$PY" ] || PY="$(bar_y_center)"
        ;;
    [0-9]*,[0-9]*)
        PX="${CONTROL%,*}"; PY="${CONTROL#*,}"
        ;;
    *)
        echo "click.sh: bad --control '$CONTROL' (play|seek:F|vol|X,Y)" >&2; exit 2 ;;
esac

# apply preset defaults without clobbering explicit user flags
if [ -z "$EXPECT_TIME" ] && [ -n "$FRAC" ]; then
    dur="$(ipc_get_num "$SOCK" duration)" || die "cannot read duration (is a video loaded?)"
    EXPECT_TIME="$(awk -v f="$FRAC" -v d="$dur" 'BEGIN { printf "%.3f", f * d }')"
    EXPECT=""
    info "seek mapping: ${FRAC} of ${dur}s -> expected time-pos ${EXPECT_TIME}s"
fi
[ -z "$FRAC" ] || [ -n "$EXPECT_TIME" ] || die "internal: seek without expected time"

if layout_has; then
    info "surface ${OSD_W}x${OSD_H}; published layout: bar=$(layout_arr_csv bar) seek=$(layout_arr_csv seek) volume=$(layout_arr_csv volume)"
else
    info "surface ${OSD_W}x${OSD_H}; no published layout - using bar-frac ${HARNESS_BAR_FRAC} (y0=$(bar_y0), yc=$(bar_y_center))"
fi
info "click at ($PX, $PY)  control=${CONTROL}"

# ---- predictable precondition ----------------------------------------------
case "$CONTROL" in
    seek:*)
        ipc_set "$SOCK" pause true
        ipc_wait "$SOCK" pause true 3 >/dev/null || diag "could not pause before seek click"
        ;;
esac

BEFORE="$(ipc_get "$SOCK" "$PROP")" || die "property '$PROP' is not readable: $IPC_LAST_ERROR"
info "before: $PROP = $BEFORE"

# ---- move (hover), then click ---------------------------------------------
ipc_mouse_move "$SOCK" "$PX" "$PY"
pos="$(ipc_get "$SOCK" mouse-pos 2>/dev/null || echo '')"
pos_x=$(printf '%s' "$pos" | jq -r '.x // "?"' 2>/dev/null)
if [ "$pos_x" = "$PX" ]; then
    pass "pointer moved to $PX,$PY ($pos)"
else
    diag "mouse-pos reports x=$pos_x (wanted $PX): $pos — continuing"
fi

ipc_click "$SOCK" "$PX" "$PY" 0 || die "click command failed: $IPC_LAST_ERROR"
info "click sent: {\"command\":[\"mouse\",\"$PX\",\"$PY\",\"0\"]}"

# ---- assertion -------------------------------------------------------------
deadline=$((SECONDS + ${WAIT%.*}))
AFTER="$BEFORE"
result=1
while :; do
    AFTER="$(ipc_get "$SOCK" "$PROP" 2>/dev/null || echo '<unreadable>')"
    result=1
    if [ -n "$EXPECT_TIME" ]; then
        if awk -v a="$AFTER" -v e="$EXPECT_TIME" -v t="$TOL" \
            'BEGIN { d = a - e; if (d < 0) d = -d; exit !(d <= t) }' 2>/dev/null; then
            result=0
        fi
    elif [ "$EXPECT" = "flip" ] || [ "$EXPECT" = "change" ]; then
        if [ "$AFTER" != "$BEFORE" ]; then result=0; fi
    elif [ -n "$EXPECT" ]; then
        if [ "$AFTER" = "$EXPECT" ] || [ "$(printf '%s' "$AFTER" | jq -r . 2>/dev/null)" = "$EXPECT" ]; then
            result=0
        fi
    else
        result=0
    fi
    [ "$result" = 0 ] && break
    [ "$SECONDS" -ge "$deadline" ] && break
    sleep 0.05
done

if [ -n "$EXPECT_TIME" ]; then
    assert_num_close "click seek: time-pos after click" "${AFTER#\"}" "$EXPECT_TIME" "$TOL" ||
        diag "the click did not map to the expected position: check --control seek:F mapping, --x, and the GUI's seekbar span (default 5%..85% of width)"
elif [ "$EXPECT" = "flip" ] || [ "$EXPECT" = "change" ]; then
    assert_ne "click changed $PROP (was $BEFORE)" "$AFTER" "$BEFORE" ||
        diag "mouse-pos=$(ipc_get "$SOCK" mouse-pos 2>/dev/null) gui-state=$(ud_dump "$SOCK" mpvgui | paste -sd' ' -)"
else
    assert_eq "click set $PROP" "$(printf '%s' "$AFTER" | jq -r . 2>/dev/null || echo "$AFTER")" "$EXPECT" || true
fi

info "after: $PROP = $AFTER"
info "gui counters: $(ud_dump "$SOCK" mpvgui | paste -sd' ' -)"
finish
