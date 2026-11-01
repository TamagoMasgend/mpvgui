#!/usr/bin/env bash
# robustness.sh — the GUI must survive awkward states without script errors.
#
# Four independent sub-cases, each on its own mpv instance and socket:
#   a) audio-only file      (no video track, force-window surface)
#   b) idle startup         (no file at all, then a file is loaded via IPC)
#   c) resize               (window-scale change -> osd-dimensions change)
#   d) seek past EOF        (then seek back and keep playing)
#
# PASS means: for every sub-case, mpv is still alive, the log has no
# Lua error / Traceback / stack traceback / Error in, and playback/time-pos is
# still sane afterwards. Sub-cases that the compositor refuses (resize) are
# reported as SKIP, not as failures.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../ipc.sh"
HARNESS_SCENARIO=robustness

KEEP_RUNNING=0

help() {
    cat <<'EOF'
robustness.sh — audio-only, idle start, resize, seek-past-EOF

USAGE
  scenarios/robustness.sh [--script DIR] [--media FILE] [options]

OPTIONS
  --script DIR|FILE   GUI script (required unless run via run.sh)
  --media FILE        base video (default media/video1080p60.mp4; the audio case
                      always uses media/audio.m4a)
  --script/--media/--geometry/--timeout   common options
  --help

CHECKS (each restarts mpv on its own socket under run/)
  a) audio-only       time-pos advances, aid=1, no video track, log clean
  b) idle startup     mpv --idle with no file survives 2s; then loadfile works
  c) resize           window-scale changes the surface; OSD/surface still sane
  d) seek past EOF    seek 999 -> eof, still alive; seek 0 -> playing again

PASS means no script error line in any of the four logs and mpv still alive.
EOF
}

harness_parse_common "$@"
set -- ${HARNESS_ARGS[@]+"${HARNESS_ARGS[@]}"}
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) help; exit 0 ;;
        *) echo "robustness.sh: unknown argument '$1' (try --help)" >&2; exit 2 ;;
    esac
done

SCRIPT="${HARNESS_SCRIPT_DIR:-}"
[ -n "$SCRIPT" ] || SCRIPT="$(harness_default_script_dir || true)"
harness_require_script "$SCRIPT"
[ -n "$HARNESS_MEDIA" ] || HARNESS_MEDIA="$HARNESS_MEDIA_DIR/video1080p60.mp4"
VIDEO="$HARNESS_MEDIA"
AUDIO="$HARNESS_MEDIA_DIR/audio.m4a"
[ -e "$AUDIO" ] || die "audio fixture missing: $AUDIO (run fixtures.sh)"

LOGS=()
check_log() { # check_log <label> <logfile>
    local label="$1" log="$2"
    if [ ! -f "$log" ]; then fail "$label: no log file ($log)"; return 1; fi
    local hits
    hits="$(grep -E "$LOG_FORBIDDEN_DEFAULT" "$log" 2>/dev/null | grep -Ev "${HARNESS_LOG_ALLOW:-$LOG_ALLOW_DEFAULT}" || true)"
    if [ -z "$hits" ]; then
        pass "$label: log clean ($log)"
        return 0
    fi
    fail "$label: script error in $log:"
    printf '%s\n' "$hits" | head -n 5 | sed 's/^/        /' >&2
    return 1
}

# stop whatever the orchestrator started: every sub-case boots its own mpv
[ -n "${HARNESS_MPV_PID:-}" ] && mpv_stop

# ---------------------------------------------------------------- a) audio-only
echo "--- a) audio-only file"
mpv_start rb-audio "$SCRIPT" "$AUDIO"
LOGS+=("$HARNESS_MPV_LOG")
LOG_A="$HARNESS_MPV_LOG"
if ipc_wait "$HARNESS_MPV_SOCK" time-pos nonnull 15; then
    pass "audio-only: playback started (time-pos=$(ipc_get "$HARNESS_MPV_SOCK" time-pos))"
else
    fail "audio-only: no playback after 15s: $IPC_LAST_ERROR"
fi
AID="$(ipc_get "$HARNESS_MPV_SOCK" aid 2>/dev/null || echo null)"
VID="$(ipc_get "$HARNESS_MPV_SOCK" vid 2>/dev/null || echo null)"
info "audio-only: aid=$AID vid=$VID"
[ "$AID" != "null" ] && [ "$AID" != "false" ] && pass "audio-only: audio track present (aid=$AID)" ||
    fail "audio-only: no audio track reported (aid=$AID)"
if t1="$(ipc_get_num "$HARNESS_MPV_SOCK" time-pos 2>/dev/null)" && sleep 0.4 && t2="$(ipc_get_num "$HARNESS_MPV_SOCK" time-pos 2>/dev/null)"; then
    awk -v a="$t1" -v b="$t2" 'BEGIN { exit !(b > a) }' && pass "audio-only: time-pos advances ($t1 -> $t2)" ||
        fail "audio-only: time-pos frozen at $t1"
fi
mpv_alive && pass "audio-only: mpv alive" || fail "audio-only: mpv died"
sleep 0.3
check_log "audio-only" "$LOG_A" || true
mpv_stop

# ---------------------------------------------------------------- b) idle startup
echo "--- b) idle startup (no file)"
mpv_start rb-idle "$SCRIPT"
LOGS+=("$HARNESS_MPV_LOG")
LOG_B="$HARNESS_MPV_LOG"
sleep 2
mpv_alive && pass "idle: mpv alive after 2s with no file" || fail "idle: mpv died while idle"
if osd="$(ipc_wait_osd "$HARNESS_MPV_SOCK" 5)"; then
    pass "idle: surface exists (${osd/ /x})"
else
    skip "idle: no osd surface while idle ($IPC_LAST_ERROR) — normal for an empty window"
fi
if ipc_cmd "$HARNESS_MPV_SOCK" loadfile "$VIDEO" >/dev/null; then
    if ipc_wait "$HARNESS_MPV_SOCK" time-pos nonnull 15; then
        pass "idle: loadfile after idle works (time-pos=$(ipc_get "$HARNESS_MPV_SOCK" time-pos))"
        ipc_wait_osd "$HARNESS_MPV_SOCK" 8 >/dev/null && pass "idle: surface after loadfile ${OSD_W}x${OSD_H}" ||
            fail "idle: no surface after loadfile: $IPC_LAST_ERROR"
    else
        fail "idle: loadfile did not start playback: $IPC_LAST_ERROR"
    fi
else
    fail "idle: loadfile command failed: $IPC_LAST_ERROR"
fi
mpv_alive && pass "idle: mpv alive after loadfile" || fail "idle: mpv died after loadfile"
sleep 0.3
check_log "idle" "$LOG_B" || true
mpv_stop

# ---------------------------------------------------------------- c) resize
echo "--- c) resize"
mpv_start rb-resize "$SCRIPT" "$VIDEO"
LOGS+=("$HARNESS_MPV_LOG")
LOG_C="$HARNESS_MPV_LOG"
ipc_wait "$HARNESS_MPV_SOCK" time-pos nonnull 15 >/dev/null || diag "resize: playback did not start"
osd_refresh "$HARNESS_MPV_SOCK"
W_OLD=$OSD_W; H_OLD=$OSD_H
info "resize: before ${W_OLD}x${H_OLD}"
RESIZED=0
for s in 0.40 0.30 0.60; do
    ipc_set "$HARNESS_MPV_SOCK" window-scale "$s" >/dev/null 2>&1 || continue
    sleep 0.8
    if osd="$(ipc_wait_osd "$HARNESS_MPV_SOCK" 4)"; then
        if [ "${OSD_W}x${OSD_H}" != "${W_OLD}x${H_OLD}" ]; then
            pass "resize: window-scale $s -> ${W_OLD}x${H_OLD} => ${OSD_W}x${OSD_H}"
            RESIZED=1
            break
        fi
        info "resize: window-scale $s kept ${OSD_W}x${OSD_H}"
    else
        diag "resize: surface unreadable after window-scale $s: $IPC_LAST_ERROR"
    fi
done
if [ "$RESIZED" = 0 ]; then
    # fallback: fullscreen is a guaranteed surface change on any compositor
    ipc_set "$HARNESS_MPV_SOCK" fullscreen yes >/dev/null 2>&1 || true
    sleep 0.9
    if osd="$(ipc_wait_osd "$HARNESS_MPV_SOCK" 4)" && [ "${OSD_W}x${OSD_H}" != "${W_OLD}x${H_OLD}" ]; then
        pass "resize (fallback): fullscreen -> ${W_OLD}x${H_OLD} => ${OSD_W}x${OSD_H}"
        RESIZED=1
        ipc_set "$HARNESS_MPV_SOCK" fullscreen no >/dev/null 2>&1 || true
    fi
fi
if [ "$RESIZED" = 0 ]; then
    skip "resize: the compositor refused every window-scale change (niri tiles the window) — nothing to assert"
else
    mpv_alive && pass "resize: mpv alive after resize" || fail "resize: mpv died after resize"
    if t1="$(ipc_get_num "$HARNESS_MPV_SOCK" time-pos 2>/dev/null)" && sleep 0.4 && t2="$(ipc_get_num "$HARNESS_MPV_SOCK" time-pos 2>/dev/null)"; then
        awk -v a="$t1" -v b="$t2" 'BEGIN { exit !(b > a) }' && pass "resize: still playing ($t1 -> $t2)" ||
            fail "resize: playback stopped after resize ($t1 -> $t2)"
    fi
    ipc_set "$HARNESS_MPV_SOCK" window-scale 1 >/dev/null 2>&1 || true
fi
sleep 0.3
check_log "resize" "$LOG_C" || true
mpv_stop

# ---------------------------------------------------------------- d) seek past EOF
echo "--- d) seek beyond EOF"
mpv_start rb-eof "$SCRIPT" "$VIDEO"
LOGS+=("$HARNESS_MPV_LOG")
LOG_D="$HARNESS_MPV_LOG"
ipc_wait "$HARNESS_MPV_SOCK" time-pos nonnull 15 >/dev/null || diag "eof: playback did not start"
DUR="$(ipc_get_num "$HARNESS_MPV_SOCK" duration 2>/dev/null || echo 0)"
info "eof: duration=$DUR"
ipc_cmd "$HARNESS_MPV_SOCK" seek 999 absolute >/dev/null 2>&1 || diag "eof: seek 999 returned an error: $IPC_LAST_ERROR"
sleep 0.8
mpv_alive && pass "eof: mpv alive after seeking past the end" || fail "eof: mpv died on seek past EOF"
eof="$(ipc_get "$HARNESS_MPV_SOCK" eof-reached 2>/dev/null || echo '<unreadable>')"
info "eof: eof-reached=$eof core-idle=$(ipc_get "$HARNESS_MPV_SOCK" core-idle 2>/dev/null)"
# after EOF mpv unloads the file (--idle): a plain seek can fail, so recover by
# seeking first, then by re-loading the file — both must keep the GUI alive.
recovered=0
if ipc_cmd "$HARNESS_MPV_SOCK" seek 0 absolute >/dev/null 2>&1; then
    sleep 0.6
    ipc_set "$HARNESS_MPV_SOCK" pause false >/dev/null 2>&1 || true
    if ipc_wait "$HARNESS_MPV_SOCK" time-pos ">0.05" 6; then
        pass "eof: seek back to 0 resumes playback (time-pos=$(ipc_get "$HARNESS_MPV_SOCK" time-pos))"
        recovered=1
    fi
else
    diag "eof: seek after EOF returned '$IPC_LAST_ERROR' (mpv unloads the file when it reaches the end with --idle) — falling back to loadfile"
fi
if [ "$recovered" = 0 ]; then
    ipc_cmd "$HARNESS_MPV_SOCK" loadfile "$VIDEO" >/dev/null 2>&1 || diag "eof: loadfile failed: $IPC_LAST_ERROR"
    sleep 0.4
    ipc_set "$HARNESS_MPV_SOCK" pause false >/dev/null 2>&1 || true
    if ipc_wait "$HARNESS_MPV_SOCK" time-pos ">0.05" 8; then
        pass "eof: loadfile after EOF resumes playback (time-pos=$(ipc_get "$HARNESS_MPV_SOCK" time-pos))"
    else
        fail "eof: playback did not resume after EOF (neither seek 0 nor loadfile): $IPC_LAST_ERROR"
        diag "state: pause=$(ipc_get "$HARNESS_MPV_SOCK" pause 2>/dev/null) idle=$(ipc_get "$HARNESS_MPV_SOCK" core-idle 2>/dev/null) eof=$(ipc_get "$HARNESS_MPV_SOCK" eof-reached 2>/dev/null) path=$(ipc_get "$HARNESS_MPV_SOCK" path 2>/dev/null)"
    fi
fi
mpv_alive && pass "eof: mpv alive at the end" || fail "eof: mpv died after seeking back"
sleep 0.3
check_log "eof" "$LOG_D" || true
mpv_stop

echo
info "logs: ${LOGS[*]}"
HARNESS_LOG_CHECKED=1  # every instance log was checked above
finish
