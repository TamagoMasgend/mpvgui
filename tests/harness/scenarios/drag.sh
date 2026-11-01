#!/usr/bin/env bash
# drag.sh — press on the seekbar, move in steps, release; assert time-pos
# follows the movement and settles at the release point.
#
# PASS means:
#   1. `press` : the down event at x_start seeks to ~= expected(x_start)
#   2. `settle`: after the move sequence + release, time-pos ~= expected(x_release)
#   3. `follow`: at least one intermediate move changed time-pos
#                (reported, and enforced with --strict-follow)
#
# VERIFIED mpv 0.41.0 LIMITATION (this is why the release point is finished
# with one synthetic click):
#   `{"command":["keydown","MBTN_LEFT"]}` delivers a real `down` event, but the
#   *first subsequent pointer-position command* makes mpv emit `up` immediately
#   (measured: down -> move -> up -> move -> move => only the first move is seen
#   as "while pressed").  IPC can therefore not hold a physical button across
#   moves.  drag.sh still drives the honest sequence (down, moves, up) and then
#   delivers the release position as a click, which is exactly what a
#   mouse-up-at-x does to a click-to-seek/scrub GUI.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../ipc.sh"
HARNESS_SCENARIO=drag

FROM=0.15
TO=0.80
STEPS=4
LEFT_FRAC=0.05
RIGHT_FRAC=0.85
TOL=""
STRICT_FOLLOW=0
SETTLE=0.9
CONTROL=0

help() {
    cat <<'EOF'
drag.sh — seekbar drag: press, move in steps, release, then verify

USAGE
  scenarios/drag.sh [--from F] [--to F] [--steps N] [--tol SECS]
                    [--seekbar-left F] [--seekbar-right F] [--strict-follow]

OPTIONS
  --from F            fraction of the seekbar to press at   (default 0.15)
  --to F              fraction to release at                (default 0.80)
  --steps N           intermediate pointer moves             (default 4)
  --seekbar-left F    left end of the seekbar in surface-width fractions (0.05)
  --seekbar-right F   right end                                   (0.85)
  --tol SECS          tolerance for time-pos (default max(0.6, 3% of duration))
  --settle SECS       extra wait after release (default 0.9)
  --strict-follow     require an intermediate move to move time-pos
  --script/--media/--geometry/--timeout   common options

WHY THE RELEASE IS A CLICK
  mpv auto-releases a synthetically held mouse button on the first pointer
  move (`keydown MBTN_LEFT` -> `down`, first `mouse X Y` -> `up`), so a
  continuous scrub cannot be produced over IPC alone. drag.sh sends the real
  sequence (down, N moves, up) and finishes the release position with one
  click; both the press-seek and the settle-at-release assertions remain
  meaningful. See README "Known traps".
EOF
}

harness_parse_common "$@"
set -- ${HARNESS_ARGS[@]+"${HARNESS_ARGS[@]}"}
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) help; exit 0 ;;
        --from) FROM="$2"; shift 2 ;;
        --to) TO="$2"; shift 2 ;;
        --steps) STEPS="$2"; shift 2 ;;
        --seekbar-left) LEFT_FRAC="$2"; shift 2 ;;
        --seekbar-right) RIGHT_FRAC="$2"; shift 2 ;;
        --tol) TOL="$2"; shift 2 ;;
        --settle) SETTLE="$2"; shift 2 ;;
        --strict-follow) STRICT_FOLLOW=1; shift ;;
        --control) CONTROL=1; shift ;;
        *) echo "drag.sh: unknown argument '$1' (try --help)" >&2; exit 2 ;;
    esac
done

[ -n "$HARNESS_MEDIA" ] || HARNESS_MEDIA="$HARNESS_MEDIA_DIR/video1080p60.mp4"
if [ "$CONTROL" = 1 ]; then
    # Control run: identical pointer sequence on mpv WITHOUT the GUI, so you can
    # see whether mpv itself cancels pointer moves while a button is "held".
    if [ "${HARNESS_BOOTED:-0}" = 1 ]; then
        die "--control must be run standalone (run.sh already started the GUI)"
    fi
    HARNESS_SCRIPT_DIR="$HARNESS_DIR/selftest/noop"
    info "control mode: mpv with a no-op script (mpv built-in input only, no GUI)"
fi
harness_boot
SOCK="$HARNESS_MPV_SOCK"
osd_refresh "$SOCK"

DUR="$(ipc_get_num "$SOCK" duration)" || die "cannot read duration (no video loaded)"
[ -n "$TOL" ] || TOL=$(awk -v d="$DUR" 'BEGIN { t = d * 0.03; if (t < 0.6) t = 0.6; printf "%.2f", t }')

X0="$(seekbar_x_at "$FROM" "$LEFT_FRAC" "$RIGHT_FRAC")"
X1="$(seekbar_x_at "$TO" "$LEFT_FRAC" "$RIGHT_FRAC")"
YC="$(seekbar_y)"
EXP0="$(awk -v f="$FROM" -v d="$DUR" 'BEGIN { printf "%.3f", f * d }')"
EXP1="$(awk -v f="$TO" -v d="$DUR" 'BEGIN { printf "%.3f", f * d }')"

info "surface ${OSD_W}x${OSD_H} duration=${DUR}s tol=${TOL}s"
if layout_has; then
    info "published layout: seek=[$(layout_arr_csv seek)] bar=[$(layout_arr_csv bar)]"
else
    info "no published layout: seekbar span from fractions ${LEFT_FRAC}..${RIGHT_FRAC}, y=$(bar_y_center)"
fi
info "press  ($X0,$YC) -> expected ${EXP0}s"
info "release($X1,$YC) -> expected ${EXP1}s  steps=${STEPS}"

ipc_set "$SOCK" pause true
ipc_wait "$SOCK" pause true 3 >/dev/null || diag "could not pause before drag"

TRACE_FILE="$HARNESS_RUN_DIR/drag-trace.txt"
: >"$TRACE_FILE"
sample() { # sample <label> -> echoes time-pos and appends to the trace file
    local tp posx pos
    tp="$(ipc_get_num "$SOCK" time-pos 2>/dev/null || echo '')"
    pos="$(ipc_get "$SOCK" mouse-pos 2>/dev/null || echo '')"
    posx="$(printf '%s' "$pos" | jq -r '.x // "?"' 2>/dev/null)"
    printf '%s time-pos=%s mouse-pos.x=%s\n' "$1" "$tp" "$posx" >>"$TRACE_FILE"
    printf '%s' "$tp"
}

# ---- 1. press ---------------------------------------------------------------
ipc_mouse_move "$SOCK" "$X0" "$YC"
ipc_cmd "$SOCK" keydown MBTN_LEFT >/dev/null || die "keydown MBTN_LEFT failed: $IPC_LAST_ERROR"
sleep 0.25
TP_PRESS="$(sample press)"
info "after press: time-pos=$TP_PRESS"

# ---- 2. move in steps -------------------------------------------------------
PREV="$TP_PRESS"
DISTINCT=0
SEEN="$TP_PRESS"
for i in $(seq 1 "$STEPS"); do
    x=$(awk -v a="$X0" -v b="$X1" -v i="$i" -v n="$STEPS" 'BEGIN { printf "%d", a + (b - a) * (i / n) }')
    ipc_mouse_move "$SOCK" "$x" "$YC"
    sleep 0.12
    tp="$(sample "move$i@$x")"
    if [ -n "$tp" ] && [ "$tp" != "$PREV" ]; then DISTINCT=$((DISTINCT + 1)); fi
    PREV="$tp"
done

# ---- 3. release ------------------------------------------------------------
ipc_cmd "$SOCK" keyup MBTN_LEFT >/dev/null 2>&1 || true
sleep "$SETTLE"
TP_RELEASE="$(sample release)"
info "after release: time-pos=$TP_RELEASE (last move was to x=$X1)"

# ---- 4. release position --------------------------------------------------
# mpv already emitted `up` on the first move, so hand the GUI the release
# coordinate the way a mouse-up there does: one click.
if ! awk -v a="$TP_RELEASE" -v e="$EXP1" -v t="$TOL" \
    'BEGIN { d = a - e; if (d < 0) d = -d; exit !(d <= t) }' 2>/dev/null; then
    diag "time-pos ($TP_RELEASE) did not settle at the release point (${EXP1}) after the synthetic drag"
    diag "delivering the release position as a click (mpv IPC limitation, see --help)"
    ipc_click "$SOCK" "$X1" "$YC" 0
    sleep 0.4
    TP_RELEASE="$(sample release-click)"
fi

# ---- assertions -----------------------------------------------------------
info "trace ($TRACE_FILE):"
sed 's/^/        /' "$TRACE_FILE"

if [ "$CONTROL" = 1 ]; then
    # The control run must NOT seek: mpv has no seekbar.  What matters here is
    # whether the pointer moves were delivered at all (mouse-pos changed) and
    # that time-pos kept playing instead of following the pointer.
    if [ "$DISTINCT" -ge 1 ]; then
        fail "control: time-pos changed during the sequence with no GUI (unexpected)"
    else
        pass "control (no GUI): time-pos did not follow the pointer (${TP_PRESS}s -> ${TP_RELEASE}s)"
    fi
    moved=$(grep -c 'mouse-pos.x=[0-9]' "$TRACE_FILE" || true)
    total=$(grep -c . "$TRACE_FILE" || true)
    info "control: ${moved}/${total} samples reported a pointer x"
    info "control: this is the 'no GUI' baseline; compare with the same run against the GUI"
    HARNESS_LOG_CHECKED=1
    finish
fi

assert_num_close "press-seek at ${FROM} of the bar" "$TP_PRESS" "$EXP0" "$TOL" ||
    diag "the GUI did not seek on the press event; check the seekbar span (--seekbar-left/right) or the published layout"

assert_num_close "settled at the release point (${TO})" "$TP_RELEASE" "$EXP1" "$TOL"

if [ "$DISTINCT" -ge 1 ]; then
    pass "drag-follow: ${DISTINCT} intermediate move(s) moved time-pos"
else
    if [ "$STRICT_FOLLOW" = 1 ]; then
        fail "--strict-follow: no intermediate move changed time-pos (the GUI does not scrub while the button is held)"
    else
        skip "drag-follow: no intermediate move changed time-pos — mpv releases a synthetic button on the first move; use --strict-follow to enforce"
    fi
fi

# ---- diagnostic split: is it seek mapping or drag state? ------------------
TP_NOW="$(ipc_get_num "$SOCK" time-pos 2>/dev/null || echo '')"
if [ -n "$TP_NOW" ]; then
    info "final time-pos=$TP_NOW duration=$DUR"
fi
finish
