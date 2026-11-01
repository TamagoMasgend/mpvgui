#!/usr/bin/env bash
# smoke.sh — the GUI script loads, the log is clean, and the GUI publishes its
# user-data contract (`user-data/mpvgui/updates` readable).
#
# PASS means:
#   * the script dir/file exists and contains main.lua
#   * mpv is still alive and a non-zero OSD surface exists
#   * `user-data/mpvgui/updates` becomes readable within the timeout
#   * the mpv log contains no Lua error / Traceback / stack traceback / Error in
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../ipc.sh"
HARNESS_SCENARIO=smoke

help() {
    cat <<'EOF'
smoke.sh — does the script load and stay clean?

USAGE
  scenarios/smoke.sh [options]

OPTIONS
  --script DIR|FILE   GUI script (default: ./mpvgui, <harness>/../../mpvgui, else ./main.lua)
  --media FILE        media to play (default: media/white.mp4)
  --timeout SECS      per-wait timeout (default 10)
  --geometry WxH      requested window size (default 960x540)
  -h, --help          this help

CHECKS
  1. script path exists and has main.lua
  2. mpv process alive, osd-dimensions non-zero
  3. user-data/mpvgui/updates readable (the brief's liveness contract)
  4. log has no: Lua error | Traceback | stack traceback | Error in
  5. prints every user-data/mpvgui/* counter it can find (evidence)

Run directly, or via ../run.sh smoke.
EOF
}

for a in "$@"; do case "$a" in -h|--help) help; exit 0 ;; esac; done
harness_parse_common "$@"

if [ -z "$HARNESS_SCRIPT_DIR" ] && [ -z "${HARNESS_BOOTED:-}" ]; then
    HARNESS_SCRIPT_DIR="$(harness_default_script_dir || true)"
fi
[ -n "$HARNESS_MEDIA" ] || HARNESS_MEDIA="$HARNESS_MEDIA_DIR/white.mp4"

harness_require_script "$HARNESS_SCRIPT_DIR"
if [ -d "$HARNESS_SCRIPT_DIR" ]; then
    info "main.lua: $HARNESS_SCRIPT_DIR/main.lua ($(stat -c%s "$HARNESS_SCRIPT_DIR/main.lua" 2>/dev/null || echo '?') bytes)"
else
    info "script file: $HARNESS_SCRIPT_DIR"
fi

harness_boot
SOCK="$HARNESS_MPV_SOCK"

mpv_alive || die "mpv is not running (it died during startup)"
pass "mpv alive (pid $HARNESS_MPV_PID)"

if osd="$(ipc_wait_osd "$SOCK" "$HARNESS_TIMEOUT")"; then
    pass "osd-dimensions = ${osd/ /x} (surface is live)"
else
    die "no osd surface: $IPC_LAST_ERROR"
fi

# ---- the user-data contract -------------------------------------------------
if ipc_wait "$SOCK" user-data/mpvgui/updates nonnull "$HARNESS_TIMEOUT"; then
    pass "user-data/mpvgui/updates = $(ipc_get "$SOCK" user-data/mpvgui/updates)"
else
    fail "user-data/mpvgui/updates never became readable: $IPC_LAST_ERROR"
    diag "user-data tree as published by the script:"
    ipc_get "$SOCK" user-data 2>/dev/null | jq -c . >&2 || true
    diag "script messages found in the log:"
    log_grep '\[mpvgui\]|script-message' >&2 || diag "(none)"
fi

map="$(ipc_get "$SOCK" user-data/mpvgui 2>/dev/null || echo null)"
if [ "$map" != "null" ] && [ -n "$map" ]; then
    pass "user-data/mpvgui is a map with $(printf '%s' "$map" | jq 'length' 2>/dev/null || echo '?') key(s)"
    info "counters: $(ud_dump "$SOCK" mpvgui | paste -sd' ' -)"
else
    fail "user-data/mpvgui map missing"
fi

# ---- playback must actually be progressing ---------------------------------
if t1="$(ipc_get_num "$SOCK" time-pos)" && sleep 0.4 && t2="$(ipc_get_num "$SOCK" time-pos)"; then
    if awk -v a="$t1" -v b="$t2" 'BEGIN { exit !(b > a) }'; then
        pass "playback progressing: time-pos $t1 -> $t2"
    elif [ "$(ipc_get_r "$SOCK" pause)" = "true" ]; then
        skip "playback paused by the GUI (time-pos $t1 -> $t2) — not a failure"
    else
        fail "time-pos is not advancing ($t1 -> $t2) while pause=false"
    fi
else
    fail "time-pos unreadable during playback"
fi

log_assert_clean || true
if [ -n "${HARNESS_MPV_LOG:-}" ]; then
    info "log: $HARNESS_MPV_LOG ($(wc -l <"$HARNESS_MPV_LOG" 2>/dev/null || echo 0) lines)"
fi

finish
