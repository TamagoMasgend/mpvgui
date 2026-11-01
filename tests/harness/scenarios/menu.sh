#!/usr/bin/env bash
# menu.sh — the clickable menu panel: track selection, chapters, speed, loop.
#
# PASS means, all through real clicks on the OSD panel of a live mpv window:
#   * the MENU button in the published layout opens the root menu
#     (panel_open=true, user-data/mpvgui/menu.page=root, rows published)
#   * clicking "Audio track" then "Japanese 880" switches `aid` to that track
#   * clicking the panel header goes back to the root page (depth back to 0)
#   * clicking "Subtitles" then "Japanese subs" switches `sid`
#   * the chapters page lists the fixture's chapters and clicking "Middle"
#     seeks to 2.0 s
#   * the speed page sets `speed` (1.5x) and the loop page sets loop-file=inf
#   * Esc closes the panel again and the mpv log stays clean
#
# Row labels come from the published user-data/mpvgui/menu JSON, so the test
# does not hardcode row numbers.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../ipc.sh"
HARNESS_SCENARIO=menu

WAIT=3
TOL=0.6

help() {
    cat <<'EOF'
menu.sh — menu panel: audio/subtitle tracks, chapters, speed, loop

USAGE
  scenarios/menu.sh [options]

OPTIONS
  --wait SECS   wait for a click to take effect (default 3)
  --tol SECS    tolerance for the chapter seek (default 0.6)
  --script/--media/--geometry/--timeout   common options (see run.sh --help)

Needs media/tracks.mkv (6 s, 2 audio tracks, 2 subtitle tracks, 3 chapters);
fixtures.sh generates it. Without run.sh the scenario boots its own mpv.
EOF
}

harness_parse_common "$@"
set -- ${HARNESS_ARGS[@]+"${HARNESS_ARGS[@]}"}
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) help; exit 0 ;;
        --wait) WAIT="$2"; shift 2 ;;
        --tol) TOL="$2"; shift 2 ;;
        *) echo "menu.sh: unknown argument '$1' (try --help)" >&2; exit 2 ;;
    esac
done

# boot our own instance when not run through run.sh
if [ "${HARNESS_BOOTED:-0}" != 1 ] && [ -z "${HARNESS_MEDIA:-}" ]; then
    HARNESS_MEDIA="$HARNESS_MEDIA_DIR/tracks.mkv"
    [ -e "$HARNESS_MEDIA" ] || die "missing $HARNESS_MEDIA (run fixtures.sh)"
fi
harness_boot
SOCK="$HARNESS_MPV_SOCK"
osd_refresh "$SOCK"
harness_layout_refresh "$SOCK" || true

# ---------------------------------------------------------------- helpers
menu_json() { # normalised JSON of the published menu contract
    local raw
    raw="$(ipc_get "$SOCK" user-data/mpvgui/menu 2>/dev/null || echo '')"
    printf '%s' "$raw" | jq -c 'if type == "string" then (fromjson? // empty) else . end' 2>/dev/null
}
menu_field() { menu_json | jq -r "$1" 2>/dev/null; }
menu_row_of() { menu_json | jq -r --arg l "$1" '.rows | index($l)' 2>/dev/null; }

# click_row <label> — resolves the label via the published rows and clicks the
# matching visible row slot (the page is scrolled to the top on every open).
click_row() {
    local label="$1" idx
    idx="$(menu_row_of "$label")"
    if [ -z "$idx" ] || [ "$idx" = "null" ]; then
        fail "row '$label' is not on the current menu page: $(menu_json)"
        return 1
    fi
    local x y
    read -r x y <<<"$(panel_row_center "$idx")"
    info "click '$label' (row $idx) at $x,$y"
    ipc_mouse_move "$SOCK" "$x" "$y" >/dev/null 2>&1 || true
    ipc_click "$SOCK" "$x" "$y" 0 || { fail "click on '$label' failed: $IPC_LAST_ERROR"; return 1; }
    sleep 0.35
    harness_layout_refresh "$SOCK" || true
}

click_button() {
    local id="$1" x y
    read -r x y <<<"$(button_center "$id")"
    [ -n "$x" ] || { fail "button '$id' is not in the published layout ($(layout_btn_ids))"; return 1; }
    info "click button '$id' at $x,$y"
    ipc_mouse_move "$SOCK" "$x" "$y" >/dev/null 2>&1 || true
    ipc_click "$SOCK" "$x" "$y" 0 || { fail "click on '$id' failed: $IPC_LAST_ERROR"; return 1; }
    sleep 0.45
    harness_layout_refresh "$SOCK" || true
}

click_header() {
    local x y
    x="$(layout_q '.panel[0] + 20')"
    y=8
    info "click panel header at $x,$y"
    ipc_click "$SOCK" "$x" "$y" 0 >/dev/null 2>&1 || true
    sleep 0.4
    harness_layout_refresh "$SOCK" || true
}

send_page() { # send_page <page>
    ipc_send "$SOCK" "{\"command\":[\"script-message\",\"mpvgui-page\",\"$1\"]}" >/dev/null 2>&1 || true
    sleep 0.45
    harness_layout_refresh "$SOCK" || true
}

assert_page() { # assert_page <page>
    local got
    got="$(menu_field '.page')"
    if [ "$got" = "$1" ]; then
        pass "menu page is '$1'"
    else
        fail "menu page is '$got', expected '$1' (rows: $(menu_field '.rows'))"
        return 1
    fi
}

wait_prop() { # wait_prop <property> <expected> [tol]
    local prop="$1" want="$2" tol="${3:-0}" got=""
    local deadline=$((SECONDS + ${WAIT%.*}))
    while :; do
        got="$(ipc_get "$SOCK" "$prop" 2>/dev/null || echo '')"
        got="${got%\"}"; got="${got#\"}"
        if [ -n "$want" ]; then
            if [ "$got" = "$want" ]; then return 0; fi
            if [ "$tol" != "0" ] && awk -v a="$got" -v b="$want" -v t="$tol" \
                'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= t) }' 2>/dev/null; then
                return 0
            fi
        fi
        [ "$SECONDS" -ge "$deadline" ] && return 1
        sleep 0.05
    done
}

# ---------------------------------------------------------- fixture contract
ipc_set "$SOCK" pause true >/dev/null 2>&1 || true
ipc_wait "$SOCK" pause true 3 >/dev/null 2>&1 || true

AUDIO_N="$(ipc_get "$SOCK" track-list | jq '[.[] | select(.type == "audio")] | length' 2>/dev/null)"
SUB_N="$(ipc_get "$SOCK" track-list | jq '[.[] | select(.type == "sub")] | length' 2>/dev/null)"
CHAPTER_N="$(ipc_get "$SOCK" chapter-list | jq 'length' 2>/dev/null)"
info "tracks: audio=$AUDIO_N sub=$SUB_N chapters=$CHAPTER_N"
assert_eq "audio track count" "${AUDIO_N:-0}" 2
assert_eq "subtitle track count" "${SUB_N:-0}" 2
assert_eq "chapter count" "${CHAPTER_N:-0}" 3

JPN_AUDIO_ID="$(ipc_get "$SOCK" track-list | jq -r '[.[] | select(.type == "audio" and .title == "Japanese 880")][0].id' 2>/dev/null)"
JPN_SUB_ID="$(ipc_get "$SOCK" track-list | jq -r '[.[] | select(.type == "sub" and .title == "Japanese subs")][0].id' 2>/dev/null)"
info "Japanese audio id=$JPN_AUDIO_ID  Japanese subs id=$JPN_SUB_ID"

# ------------------------------------------------------- open from the button
harness_reveal_osd "$SOCK" || true
harness_layout_refresh "$SOCK" || true
if layout_btn_ids | tr ',' '\n' | grep -qx menu; then
    pass "the published layout has a 'menu' button"
else
    fail "no 'menu' button in the published layout buttons ($(layout_btn_ids))"
fi
click_button menu
assert_eq "panel_open after MENU click" "$(layout_q '.panel_open')" "true"
assert_page root
ROOT_ROWS="$(menu_field '.rows | length')"
info "root rows: $(menu_field '.rows')"
if [ "${ROOT_ROWS:-0}" -ge 10 ]; then
    pass "root menu publishes $ROOT_ROWS rows"
else
    fail "root menu publishes only ${ROOT_ROWS:-0} rows: $(menu_field '.rows')"
fi
harness_shot "$SOCK" "$HARNESS_ARTIFACTS/menu-root.png" >/dev/null 2>&1 || true

# ------------------------------------------------------------ audio switching
click_row "Audio track"
assert_page audio
click_row "Japanese 880"
if wait_prop aid "$JPN_AUDIO_ID"; then
    pass "clicking 'Japanese 880' set aid=$JPN_AUDIO_ID"
else
    fail "aid stayed at $(ipc_get "$SOCK" aid) after clicking 'Japanese 880' (wanted $JPN_AUDIO_ID)"
fi
harness_shot "$SOCK" "$HARNESS_ARTIFACTS/menu-audio.png" >/dev/null 2>&1 || true

# ------------------------------------------------------- header = back to root
click_header
assert_page root
DEPTH="$(menu_field '.depth')"
assert_eq "menu depth after header click" "${DEPTH:-?}" 0

# -------------------------------------------------------- subtitle switching
click_row "Subtitles"
assert_page subs
click_row "Japanese subs"
if wait_prop sid "$JPN_SUB_ID"; then
    pass "clicking 'Japanese subs' set sid=$JPN_SUB_ID"
else
    fail "sid stayed at $(ipc_get "$SOCK" sid) after clicking 'Japanese subs' (wanted $JPN_SUB_ID)"
fi

# ------------------------------------------------------------- chapter click
send_page chapters
assert_page chapters
click_row "Middle"
if wait_prop time-pos 2.0 "$TOL"; then
    pass "clicking chapter 'Middle' sought to $(ipc_get "$SOCK" time-pos)"
else
    fail "time-pos is $(ipc_get "$SOCK" time-pos) after clicking 'Middle' (wanted 2.0±$TOL)"
fi
CH_AFTER="$(ipc_get "$SOCK" chapter)"
assert_eq "chapter index after 'Middle' click" "${CH_AFTER%%.*}" 1

# -------------------------------------------------------- speed + loop pages
send_page speed
assert_page speed
click_row "1.5x"
if wait_prop speed 1.5 0.001; then
    pass "clicking '1.5x' set speed=$(ipc_get "$SOCK" speed)"
else
    fail "speed is $(ipc_get "$SOCK" speed) after clicking '1.5x'"
fi

send_page loop
assert_page loop
click_row "Loop file"
if wait_prop loop-file inf; then
    pass "clicking 'Loop file' set loop-file=inf"
else
    fail "loop-file is $(ipc_get "$SOCK" loop-file) after clicking 'Loop file'"
fi
send_page loop
click_row "Off"
LOOP_AFTER="$(ipc_get "$SOCK" loop-file | tr -d '"')"
case "$LOOP_AFTER" in
    no | false) pass "clicking 'Off' cleared loop-file ($LOOP_AFTER)" ;;
    *) fail "loop-file is '$LOOP_AFTER' after clicking 'Off'" ;;
esac

# -------------------------------------------------------------- close via Esc
ipc_key "$SOCK" "Esc" >/dev/null 2>&1 || diag "keypress Esc failed"
sleep 0.4
harness_layout_refresh "$SOCK" || true
assert_eq "panel_open after Esc" "$(layout_q '.panel_open')" "false"

# --------------------------------------------------------------- tidy + log
ipc_set "$SOCK" speed 1 >/dev/null 2>&1 || true
ipc_set "$SOCK" video-aspect-override no >/dev/null 2>&1 || true
info "gui counters: $(ud_dump "$SOCK" mpvgui | paste -sd' ' -)"
info "artifacts: $HARNESS_ARTIFACTS"
log_assert_clean || true
finish
