#!/usr/bin/env bash
# perf.sh — measure 1080p60 playback: dropped frames, vf-fps, mpv CPU, and the
# GUI's own user-data update counters, then assert the two invariants:
#
#   * frame-drop-count == 0            (no frames dropped by the display path)
#   * idle-hidden updates == 0         (a hidden, untouched GUI does no work)
#
# Phase A (measure, default 10s, 1s samples)
#   frame-drop-count, decoder-frame-drop-count, estimated-vf-fps,
#   video-frame-drop hmm, mpv CPU from /proc/<pid>/stat, and every
#   user-data/mpvgui/updates* counter.
#
# Phase B (idle-hidden, default 4s settle + 3s sample)
#   no pointer movement, no key events. If the GUI publishes
#   user-data/mpvgui/visible and it is false, the delta of every updates*
#   counter must be 0. If it never hides, the check is reported as SKIP (the
#   GUI may intentionally keep its bar on screen) — see --hide-time.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../ipc.sh"
HARNESS_SCENARIO=perf

SAMPLES=10
INTERVAL=1
MAX_DROPS=0
HIDE_TIME=4
IDLE_SAMPLES=3
SHOW_FOR_MEASURE=1

help() {
    cat <<'EOF'
perf.sh — 10s of 1080p60 + idle-hidden verification

USAGE
  scenarios/perf.sh [--samples N] [--interval S] [--max-drops N]
                    [--hide-time S] [--idle-samples N] [--no-show]

OPTIONS
  --samples N        Phase A samples (default 10, one per --interval)
  --interval S       sample interval in seconds (default 1)
  --max-drops N      allowed frame-drop-count (default 0)
  --hide-time S      how long to wait for the GUI to hide its OSD (default 4)
  --idle-samples N   Phase B samples (default 3)
  --no-show          do not nudge the pointer into the window before Phase A
  --script/--media/--geometry/--timeout   common options (see run.sh --help)

METRICS PRINTED PER SECOND
  t, frame-drop-count, decoder-frame-drop-count, estimated-vf-fps,
  mpv CPU % (utime+stime delta / CLK_TCK / elapsed), and every
  user-data/mpvgui/updates* counter

PASS means
  * frame-drop-count <= --max-drops over the whole run
  * while the GUI is hidden and idle, the updates* counters do not move
    (SKIP if the GUI never hides — reported, not failed)

NOTES
  * playback is looped (`--loop-file=inf`) when this script boots mpv itself,
    so an 8s fixture can be measured for 10s;
  * `vo-drop-frame-count` and `mistimed-frame-count` are nil in mpv 0.41.0 —
    only frame-drop-count / decoder-frame-drop-count are meaningful.
EOF
}

harness_parse_common "$@"
set -- ${HARNESS_ARGS[@]+"${HARNESS_ARGS[@]}"}
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) help; exit 0 ;;
        --samples) SAMPLES="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        --max-drops) MAX_DROPS="$2"; shift 2 ;;
        --hide-time) HIDE_TIME="$2"; shift 2 ;;
        --idle-samples) IDLE_SAMPLES="$2"; shift 2 ;;
        --no-show) SHOW_FOR_MEASURE=0; shift ;;
        *) echo "perf.sh: unknown argument '$1' (try --help)" >&2; exit 2 ;;
    esac
done

if [ "${HARNESS_BOOTED:-0}" != 1 ]; then
    [ -n "$HARNESS_MEDIA" ] || HARNESS_MEDIA="$HARNESS_MEDIA_DIR/video1080p60.mp4"
    harness_require_script "$HARNESS_SCRIPT_DIR"
    mpv_start perf "$HARNESS_SCRIPT_DIR" --loop-file=inf "$HARNESS_MEDIA"
    harness_wait_playback
    HARNESS_BOOTED=1
fi
harness_boot
SOCK="$HARNESS_MPV_SOCK"
PID="$HARNESS_MPV_PID"
osd_refresh "$SOCK"

info "surface ${OSD_W}x${OSD_H} pid=$PID samples=$SAMPLES@${INTERVAL}s max-drops=$MAX_DROPS"
info "video: $(ipc_get "$SOCK" width 2>/dev/null)x$(ipc_get "$SOCK" height 2>/dev/null) @ $(ipc_get "$SOCK" container-fps 2>/dev/null)fps, duration=$(ipc_get "$SOCK" duration 2>/dev/null)"

TICKS0="$(mpv_cpu_ticks "$PID" || echo 0)"

if [ "$SHOW_FOR_MEASURE" = 1 ]; then
    # keep the bar visible during the measurement so the counters reflect the
    # GUI actually drawing; a 1px wiggle per sample is enough to keep it up
    harness_reveal_osd "$SOCK" >/dev/null 2>&1 || true
fi

# ---- Phase A: measure ------------------------------------------------------
GRAB_INFO=""
cpu_total=0; cpu_n=0; fps_min=""; drops_final=0; ddrops_final=0
updates_first=""; updates_last=""

printf '\n%4s %10s %10s %10s %8s  %s\n' "t" "frameDrop" "decDrop" "vf-fps" "cpu%" "updates*"
declare -A UD_FIRST=()
for i in $(seq 1 "$SAMPLES"); do
    sleep "$INTERVAL"
    if [ "$SHOW_FOR_MEASURE" = 1 ]; then
        ipc_mouse_move "$SOCK" "$((OSD_W / 2 + (i % 2)))" "$((OSD_H / 2))" >/dev/null 2>&1 || true
    fi
    t_now=$((i * INTERVAL))
    fdc=$(ipc_get_num "$SOCK" frame-drop-count 2>/dev/null || echo "?")
    dfdc=$(ipc_get_num "$SOCK" decoder-frame-drop-count 2>/dev/null || echo "?")
    fps=$(ipc_get_num "$SOCK" estimated-vf-fps 2>/dev/null || echo "?")
    ticks=$(mpv_cpu_ticks "$PID" 2>/dev/null || echo "$TICKS0")
    dt=$((ticks - TICKS0))
    cpu=$(mpv_cpu_percent "$dt" "$INTERVAL")
    cpu_total=$(awk -v a="$cpu_total" -v b="$cpu" 'BEGIN { print a + b }')
    cpu_n=$((cpu_n + 1))
    [ "$fdc" != "?" ] && drops_final="$fdc"
    [ "$dfdc" != "?" ] && ddrops_final="$dfdc"
    if [ "$fps" != "?" ] && { [ -z "$fps_min" ] || awk -v a="$fps" -v b="$fps_min" 'BEGIN { exit !(a < b) }'; }; then
        fps_min="$fps"
    fi
    TICKS0="$ticks"
    uds="$(ud_dump "$SOCK" mpvgui '^updates' | paste -sd' ' -)"
    while IFS='=' read -r k v; do
        [ -n "$k" ] || continue
        [ -n "${UD_FIRST[$k]:-}" ] || UD_FIRST[$k]="$v"
        updates_last="$uds"
    done < <(ud_dump "$SOCK" mpvgui '^updates')
    printf '%4s %10s %10s %10s %8s  %s\n' "${t_now}s" "$fdc" "$dfdc" "$fps" "$cpu" "$uds"
done

cpu_avg=$(awk -v s="$cpu_total" -v n="$cpu_n" 'BEGIN { if (n == 0) print 0; else printf "%.1f", s / n }')
printf '\nPhase A summary: avg mpv CPU %s%%, min estimated-vf-fps %s, frame-drop-count %s, decoder-frame-drop-count %s\n' \
    "$cpu_avg" "${fps_min:-?}" "$drops_final" "$ddrops_final"
info "audio/video sync: $(ipc_get "$SOCK" audio-pts 2>/dev/null) / $(ipc_get "$SOCK" time-pos 2>/dev/null)"

# ---- assertions -----------------------------------------------------------
if [ "$drops_final" != "?" ] && [ "${drops_final:-0}" -le "$MAX_DROPS" ]; then
    pass "no dropped frames: frame-drop-count=$drops_final (<= $MAX_DROPS)"
else
    fail "frame-drop-count=$drops_final exceeds --max-drops=$MAX_DROPS (display path cannot keep up)"
fi
if [ "${ddrops_final:-0}" -gt 0 ]; then
    skip "decoder-frame-drop-count=$ddrops_final — decoder-side drops (hwdec may be off); not asserted by default"
fi
if [ -n "$fps_min" ] && awk -v f="$fps_min" -v e="$(ipc_get_num "$SOCK" container-fps 2>/dev/null || echo 60)" 'BEGIN { exit !(f >= 0.9 * e) }'; then
    pass "estimated-vf-fps never fell below 90% of the container fps (min $fps_min)"
else
    skip "estimated-vf-fps min ${fps_min:-?} (informational; vsync/latency can depress it)"
fi

# ---- Phase B: idle-hidden -------------------------------------------------
echo
echo "Phase B: idle-hidden (no pointer movement, no keys, waiting ${HIDE_TIME}s for the OSD to hide)"
vis="$(ipc_get_r "$SOCK" user-data/mpvgui/visible 2>/dev/null || echo 'null')"
delayed=0
while [ "$delayed" -lt "$HIDE_TIME" ]; do
    vis="$(ipc_get_r "$SOCK" user-data/mpvgui/visible 2>/dev/null || echo 'null')"
    [ "$vis" = "false" ] && break
    sleep 1
    delayed=$((delayed + 1))
done
info "visible=$vis after ${delayed}s (user-data/mpvgui/visible; 'null' = not published)"

IDLE_SPECIFIC="$(ud_dump "$SOCK" mpvgui '^(updates[-_]idle|updates[-_]hidden|idle[-_]updates|hidden[-_]updates)' | cut -d= -f1)"
ALL_UPDATES="$(ud_dump "$SOCK" mpvgui '^updates' | cut -d= -f1)"
if [ -n "$IDLE_SPECIFIC" ]; then
    IDLE_KEYS="$IDLE_SPECIFIC"
    info "dedicated idle/hidden counters: $(printf '%s' "$IDLE_KEYS" | paste -sd' ' -)"
else
    # no dedicated counter: every updates* counter (total + per-layer) must be
    # frozen while the GUI is hidden and idle.
    IDLE_KEYS="$ALL_UPDATES"
    info "no dedicated idle/hidden counter; asserting on every updates* counter: $(printf '%s' "$IDLE_KEYS" | paste -sd' ' -)"
fi
[ -n "$IDLE_KEYS" ] || { skip "GUI publishes no updates* counters at all"; IDLE_KEYS=""; }

declare -A B0=()
for k in $IDLE_KEYS; do
    B0[$k]="$(ud_num "$SOCK" "mpvgui/$k" 2>/dev/null || ipc_get_num "$SOCK" "user-data/mpvgui/$k" 2>/dev/null || echo '')"
done
# also remember the totals so the report can show deltas
TOT0_UPD="$(ud_num "$SOCK" mpvgui/updates 2>/dev/null || echo '')"

idle_moved=0
for i in $(seq 1 "$IDLE_SAMPLES"); do
    sleep 1
    line=""
    for k in $IDLE_KEYS; do
        v="$(ud_num "$SOCK" "mpvgui/$k" 2>/dev/null || echo '')"
        [ -n "${B0[$k]}" ] && [ -n "$v" ] || continue
        d=$((v - B0[$k]))
        line+=" $k+=$d"
        [ "$d" -ne 0 ] && idle_moved=1
    done
    echo "  idle ${i}s:$line"
done

TOT1_UPD="$(ud_num "$SOCK" mpvgui/updates 2>/dev/null || echo '')"
[ -n "$TOT0_UPD" ] && [ -n "$TOT1_UPD" ] && \
    info "total updates during idle phase: ${TOT0_UPD} -> ${TOT1_UPD}"

if [ "$vis" = "false" ]; then
    if [ "$idle_moved" = 0 ]; then
        pass "idle-hidden updates == 0 (counters: $(printf '%s' "$IDLE_KEYS" | paste -sd',' -))"
    else
        fail "the GUI keeps updating while hidden and idle (see the +N deltas above)"
        diag "a hidden bar must do no per-frame work: no OSD redraw, no counter churn"
    fi
elif [ "$vis" = "null" ]; then
    skip "GUI does not publish user-data/mpvgui/visible: cannot prove it was hidden (idle_moved=$idle_moved)"
else
    skip "GUI never hid its OSD within ${HIDE_TIME}s (visible=$vis) — idle-hidden cannot be verified; consider --hide-time or hiding the bar when untouched"
fi

# ---- final state ----------------------------------------------------------
mpv_alive && pass "mpv survived the measurement (pid $PID)" || fail "mpv died during the measurement"
info "final frame stats: frame-drop-count=$(ipc_get "$SOCK" frame-drop-count 2>/dev/null) decoder-frame-drop-count=$(ipc_get "$SOCK" decoder-frame-drop-count 2>/dev/null)"
log_assert_clean || true
finish
