#!/usr/bin/env bash
# counters.sh — sample the GUI's own user-data counters at 1 Hz.
#
# Prints two raw series so the "no work while hidden" claim is evidenced
# independently of perf.sh:
#   * HIDDEN  10 s: no pointer movement, no keys  (the GUI must have hidden)
#   * VISIBLE 10 s: one 1 px pointer wiggle per second keeps the bar shown
#
# Usage:
#   selftest/counters.sh [--script DIR] [--media FILE] [--seconds N] [--hidden-first N]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../ipc.sh"
HARNESS_SCENARIO=counters

SECONDS_PER_PHASE=10
PRE_HIDE=3

help() {
    cat <<'EOF'
counters.sh — 1 Hz raw sample of user-data/mpvgui/updates*

USAGE
  selftest/counters.sh [--script DIR] [--media FILE] [--seconds N]

OPTIONS
  --script DIR     GUI script dir (required, or run from the repo with ./mpvgui)
  --media FILE     media (default media/video1080p60.mp4, looped)
  --seconds N      seconds per phase (default 10)
  --geometry WxH / --timeout S / --extra "ARGS"   common options

OUTPUT
  phase  t  visible  updates  updates_<layer>...   (one line per second)
  A HIDDEN phase (no interaction) followed by a VISIBLE phase (1 px wiggle/s).
EOF
}

harness_parse_common "$@"
set -- ${HARNESS_ARGS[@]+"${HARNESS_ARGS[@]}"}
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) help; exit 0 ;;
        --seconds) SECONDS_PER_PHASE="$2"; shift 2 ;;
        *) echo "counters.sh: unknown argument '$1' (try --help)" >&2; exit 2 ;;
    esac
done

[ -n "$HARNESS_SCRIPT_DIR" ] || { [ -d "$PWD/mpvgui" ] && HARNESS_SCRIPT_DIR="$PWD/mpvgui"; }
harness_require_script "$HARNESS_SCRIPT_DIR"
[ -n "$HARNESS_MEDIA" ] || HARNESS_MEDIA="$HARNESS_MEDIA_DIR/video1080p60.mp4"

mpv_start counters "$HARNESS_SCRIPT_DIR" --loop-file=inf "$HARNESS_MEDIA"
harness_wait_playback
SOCK="$HARNESS_MPV_SOCK"
osd_refresh "$SOCK"

series() { # series <label> <visibility: hidden|visible>
    local label="$1" mode="$2" i vis ud line
    printf '\n# %s phase: %s\n' "$label" "$mode"
    printf '%4s %8s %10s  %s\n' "t" "visible" "updates" "counters"
    # let the GUI reach the desired state first
    if [ "$mode" = hidden ]; then sleep "$PRE_HIDE"; else harness_reveal_osd "$SOCK" >/dev/null 2>&1; fi
    for i in $(seq 1 "$SECONDS_PER_PHASE"); do
        if [ "$mode" = visible ]; then
            # 1 px wiggle keeps an auto-hiding bar on screen
            ipc_mouse_move "$SOCK" "$((OSD_W / 2 + (i % 2)))" "$((OSD_H / 2))" >/dev/null 2>&1
        fi
        sleep 1
        vis="$(ipc_get_r "$SOCK" user-data/mpvgui/visible 2>/dev/null || echo 'null')"
        ud="$(ipc_get_num "$SOCK" user-data/mpvgui/updates 2>/dev/null || echo '?')"
        line="$(ud_dump "$SOCK" mpvgui '^updates' | paste -sd' ' -)"
        printf '%4s %8s %10s  %s\n' "${i}s" "$vis" "$ud" "$line"
    done
}

series HIDDEN hidden
series VISIBLE visible

printf '\n# final user-data/mpvgui map: %s\n' "$(ud_dump "$SOCK" mpvgui | paste -sd' ' -)"
HARNESS_LOG_CHECKED=1
finish
