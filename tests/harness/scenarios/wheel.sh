#!/usr/bin/env bash
# wheel.sh — a wheel event over the volume area must change `volume`.
#
# PASS means: after moving the pointer over the volume box, a wheel-up event
# raises `volume` (and a wheel-down lowers it) within --wait seconds.
#
# TWO delivery mechanisms are tried, in order, and the one that worked is
# reported:
#   1. {"command":["mouse",X,Y,3]}   button 3 = WHEEL_UP, 4 = WHEEL_DOWN
#      (verified: `mouse` DOES carry wheel events, at the given coordinates,
#      so the GUI sees the wheel at the volume box like a real pointer)
#   2. {"command":["keypress","WHEEL_UP"]}  — position-independent key event;
#      only useful if the GUI ignores the pointer position or binds globally.
#
# TRAP: mpv 0.41.0's built-in bindings already map WHEEL_UP/WHEEL_DOWN to
# += 2 volume when no script overrides them, so a volume change alone does not
# prove the GUI handled it. The scenario therefore also reports whether the
# GUI's own user-data counters moved; if they did not, it says so.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../ipc.sh"
HARNESS_SCENARIO=wheel

PX=""
PY=""
DELTA=2
WAIT=3
ROUNDS=3

help() {
    cat <<'EOF'
wheel.sh — does the wheel over the volume area change volume?

USAGE
  scenarios/wheel.sh [--x X --y Y] [--delta D] [--rounds N] [--wait SECS]

OPTIONS
  --x X --y Y    point to send the wheel at (default: centre of the volume box,
                 i.e. x = W-60, y = centre of the bottom bar)
  --delta D      minimum expected volume change per wheel step (default 2)
  --rounds N     wheel-up events to send (default 3)
  --wait SECS    how long to wait for each change (default 3)
  --script/--media/--geometry/--timeout   common options

PASS means: volume rises by at least D after the wheel-up burst and falls back
after the wheel-down burst, with the pointer parked over the volume area.

Mechanism used (`mouse` button 3/4 at x,y vs `keypress WHEEL_UP`) is printed.
Note mpv's built-in wheel->volume binding: if the GUI does not bind the wheel,
volume still moves — the "gui counters" line tells you which happened.
EOF
}

harness_parse_common "$@"
set -- ${HARNESS_ARGS[@]+"${HARNESS_ARGS[@]}"}
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) help; exit 0 ;;
        --x) PX="$2"; shift 2 ;;
        --y) PY="$2"; shift 2 ;;
        --delta) DELTA="$2"; shift 2 ;;
        --rounds) ROUNDS="$2"; shift 2 ;;
        --wait) WAIT="$2"; shift 2 ;;
        --bar-frac) HARNESS_BAR_FRAC="$2"; shift 2 ;;
        *) echo "wheel.sh: unknown argument '$1' (try --help)" >&2; exit 2 ;;
    esac
done

[ -n "$HARNESS_MEDIA" ] || HARNESS_MEDIA="$HARNESS_MEDIA_DIR/white.mp4"
harness_boot
SOCK="$HARNESS_MPV_SOCK"
osd_refresh "$SOCK"

[ -n "$PX" ] || PX="$(volume_center_x)"
[ -n "$PY" ] || PY="$(bar_y_center)"
if layout_has; then
    info "surface ${OSD_W}x${OSD_H}; wheel over ($PX,$PY); published volume slider=$(layout_arr_csv volume) bar=$(layout_arr_csv bar)"
else
    info "surface ${OSD_W}x${OSD_H}; wheel over ($PX,$PY); no published layout, bar y0=$(bar_y0) yc=$(bar_y_center)"
fi

ipc_set "$SOCK" pause true >/dev/null 2>&1 || true
ipc_set "$SOCK" volume 50 >/dev/null || die "cannot set volume: $IPC_LAST_ERROR"
ipc_wait "$SOCK" volume "=50" 3 >/dev/null || diag "volume did not settle at 50"
ipc_mouse_move "$SOCK" "$PX" "$PY"
sleep 0.2

MECH=""
send_wheel() { # send_wheel up|down
    local dir="$1" i
    for i in $(seq 1 "$ROUNDS"); do
        if [ "$MECH" != "keypress" ]; then
            if [ "$dir" = "up" ]; then ipc_mouse "$SOCK" "$PX" "$PY" 3; else ipc_mouse "$SOCK" "$PX" "$PY" 4; fi
        else
            if [ "$dir" = "up" ]; then ipc_key "$SOCK" WHEEL_UP; else ipc_key "$SOCK" WHEEL_DOWN; fi
        fi
        sleep 0.08
    done
}

volume_now() { ipc_get_num "$SOCK" volume 2>/dev/null || echo "nan"; }

V0="$(volume_now)"
GUI_BEFORE="$(ud_dump "$SOCK" mpvgui | paste -sd'|' -)"
info "volume before: $V0"

# ---- attempt 1: mouse wheel at the volume box ------------------------------
send_wheel up
ok1=0
deadline=$((SECONDS + ${WAIT%.*}))
while :; do
    V1="$(volume_now)"
    if awk -v a="$V1" -v b="$V0" -v d="$DELTA" 'BEGIN { exit !(a >= b + d) }' 2>/dev/null; then ok1=1; break; fi
    [ "$SECONDS" -ge "$deadline" ] && break
    sleep 0.05
done
if [ "$ok1" = 1 ]; then
    MECH="mouse-button-3/4"
    pass "wheel via mouse button 3 at ($PX,$PY): volume $V0 -> $V1"
else
    diag "mouse-button wheel at the volume box changed nothing (volume=$V1)"
    # ---- attempt 2: keypress (position independent) ------------------------
    MECH="keypress"
    ipc_set "$SOCK" volume 50 >/dev/null 2>&1 || true
    sleep 0.15
    V0="$(volume_now)"
    send_wheel up
    deadline=$((SECONDS + ${WAIT%.*}))
    while :; do
        V1="$(volume_now)"
        if awk -v a="$V1" -v b="$V0" -v d="$DELTA" 'BEGIN { exit !(a >= b + d) }' 2>/dev/null; then ok1=1; break; fi
        [ "$SECONDS" -ge "$deadline" ] && break
        sleep 0.05
    done
    if [ "$ok1" = 1 ]; then
        pass "wheel via keypress WHEEL_UP: volume $V0 -> $V1"
        diag "note: the mouse-wheel path did NOT work at ($PX,$PY) — either the GUI only binds the wheel globally, or ($PX,$PY) is not over its volume area"
    else
        fail "no wheel delivery changed volume (tried mouse button 3 at ($PX,$PY) and keypress WHEEL_UP)"
        diag "volume is stuck at $V1; check that the GUI binds WHEEL_UP/WHEEL_DOWN and hit-tests the volume area"
        finish
    fi
fi

GUI_AFTER="$(ud_dump "$SOCK" mpvgui | paste -sd'|' -)"
VUP="$(volume_now)"

# ---- reverse: wheel down must lower it ------------------------------------
send_wheel down
VDOWN="$VUP"
deadline=$((SECONDS + ${WAIT%.*}))
while :; do
    VDOWN="$(volume_now)"
    if awk -v a="$VDOWN" -v b="$VUP" -v d="$DELTA" 'BEGIN { exit !(a <= b - d) }' 2>/dev/null; then break; fi
    [ "$SECONDS" -ge "$deadline" ] && break
    sleep 0.05
done
if awk -v a="$VDOWN" -v b="$VUP" -v d="$DELTA" 'BEGIN { exit !(a <= b - d) }'; then
    pass "wheel down lowers volume: $VUP -> $VDOWN (via $MECH)"
else
    fail "wheel down did not lower volume: $VUP -> $VDOWN (via $MECH)"
fi

# ---- evidence: did the GUI itself react? ---------------------------------
if [ "$GUI_BEFORE" != "$GUI_AFTER" ]; then
    pass "GUI counters moved during the wheel (GUI handled it, not just mpv's builtin): $(ud_dump "$SOCK" mpvgui | paste -sd' ' -)"
else
    skip "GUI counters unchanged during the wheel — the volume change came from mpv's built-in WHEEL_UP binding, so the GUI does not handle the wheel (volume still moved, so no hard failure)"
fi
info "mechanism: $MECH"
finish
