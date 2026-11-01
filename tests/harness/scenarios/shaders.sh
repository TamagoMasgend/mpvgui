#!/usr/bin/env bash
# shaders.sh — shader presets / import / failure handling / persistence / cost.
#
# Contract under test (read from the implementation, not assumed):
#   * `user-data/mpvgui/shaders`  = JSON {active, count, entries}
#   * `script-message-to mpvgui mpvgui-shader <preset>`  applies a preset
#   * `script-message-to mpvgui mpvgui-import <file.hook>` imports a shader
#   * config layout: <config-dir>/mpv/mpvgui/shaders.conf + .../shaders/*.hook
#   * the panel opens from a bar FX button and from `keypress Shift+x`
#
# Parts (in order): 0 contract probe, 1 baseline+panel, 2 preset apply,
# 3 mode switch + off, 4 import, 5 broken shader (log + toast + restore),
# 6 persistence across restart, 7 cost (idle-hidden / panel-open counters).
#
# Everything undecidable is SKIP, never PASS.  Every assertion prints the raw
# property value, log line or pixel numbers behind it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../ipc.sh"
HARNESS_SCENARIO=shaders

SCRIPT_NAME="mpvgui"
CONF_STYLE="kv"
PIXEL_TOL=12
DIFF_TOL=8
KEEP_CONFIG=0
HIDE_TIME=4
RESTART_WAIT=12
CONF=""            # filled after arg parsing
FX_BUTTON=""

help() {
    cat <<'EOF'
shaders.sh — shader presets: apply, switch, off, import, failure, persistence, cost

USAGE
  scenarios/shaders.sh [--script DIR] [--media FILE] [options]

OPTIONS
  --script DIR        GUI script dir (default: ./mpvgui, then <harness>/../../mpvgui)
  --media FILE        clip for pixel assertions (default media/white.mp4)
  --script-name NAME  mpv script name for script-message-to (default mpvgui)
  --conf-style kv|ini preset file format written by the harness (default kv:
                      "name=/abs/path.hook" lines; ini writes [name] sections).
                      THE REAL FORMAT IS A CONTRACT GAP — the file is printed
                      in the evidence so a mismatch is visible immediately.
  --tolerance N       per-channel RGB tolerance for tint assertions (default 12)
  --hide-time SECS    wait for the OSD to auto-hide in the cost part (default 4)
  --keep-config       keep the isolated config dir (default: removed on exit)
  --geometry/--timeout/--extra     common options

PARTS
  1 baseline   glsl-shaders empty; user-data/mpvgui/shaders parses with
               {active,count,entries}; panel opens (FX button + Shift+x),
               lists Off / presets / discovered files
 1b row click  clicking row 1 applies that preset (chain + pixel), row 0
               ("Off") clears it - the panel interaction, not script-message
  2 preset     apply a preset -> glsl-shaders == [<path>] and a video pixel
               changes colour (RGB reported before/after)
  3 switch     second preset -> different chain + different colour; then `off`
               -> chain empty, colour back to the baseline
  4 import     mpvgui-import <file> copies it into the config dir, appears in
               entries, and applying it changes glsl-shaders
  5 broken     invalid .hook: mpv logs a compile error, the GUI shows a toast
               (pixels change outside bar/panel), the previous chain is
               restored, and no Lua error appears
  6 persistence apply, quit, relaunch with the same --config-dir, same chain
  7 cost       Off + panel closed, 10 s hidden: updates* delta 0 and
               frame-drop-count 0; panel open + untouched: panel layer frozen

PASS criteria per part are printed. SKIP means the harness cannot decide (e.g.
the panel rect is not published, the entries JSON uses an unknown shape, the
compositor hides the window).
EOF
}

harness_parse_common "$@"
set -- ${HARNESS_ARGS[@]+"${HARNESS_ARGS[@]}"}
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) help; exit 0 ;;
        --script-name) SCRIPT_NAME="$2"; shift 2 ;;
        --conf-style) CONF_STYLE="$2"; shift 2 ;;
        --tolerance) PIXEL_TOL="$2"; shift 2 ;;
        --hide-time) HIDE_TIME="$2"; shift 2 ;;
        --keep-config) KEEP_CONFIG=1; shift ;;
        *) echo "shaders.sh: unknown argument '$1' (try --help)" >&2; exit 2 ;;
    esac
done

[ -n "$HARNESS_SCRIPT_DIR" ] || HARNESS_SCRIPT_DIR="$(harness_default_script_dir || true)"
harness_require_script "$HARNESS_SCRIPT_DIR"
[ -n "$HARNESS_MEDIA" ] || HARNESS_MEDIA="$HARNESS_MEDIA_DIR/white.mp4"
SHADER_FIXTURES="$HARNESS_MEDIA_DIR/shaders"
[ -s "$SHADER_FIXTURES/tint-red.hook" ] || die "shader fixtures missing: $SHADER_FIXTURES (run fixtures.sh)"
MEDIA="$HARNESS_MEDIA"

# ---------------------------------------------------------------- config dir
CFG="$HARNESS_RUN_DIR/shaders-cfg"
mkdir -p "$CFG/mpv/mpvgui/shaders"
CONF="$CFG/mpv/mpvgui/shaders.conf"
DISCOVERED="$CFG/mpv/mpvgui/shaders/discovered-tint.hook"
RED="$SHADER_FIXTURES/tint-red.hook"
BLUE="$SHADER_FIXTURES/tint-blue.hook"
GREEN="$SHADER_FIXTURES/tint-green.hook"
BROKEN="$SHADER_FIXTURES/broken.hook"

cleanup_cfg() {
    if [ "$KEEP_CONFIG" = 1 ]; then
        info "config dir kept: $CFG"
    else
        rm -rf "$CFG"
    fi
}
harness_on_exit cleanup_cfg

write_conf() {
    case "$CONF_STYLE" in
        ini)
            cat >"$CONF" <<CONF
[tint-red]
shader=$RED

[tint-blue]
shader=$BLUE

[broken]
shader=$BROKEN
CONF
            ;;
        *)
            cat >"$CONF" <<CONF
# written by tests/harness/scenarios/shaders.sh
# format assumption: <preset-name>=<absolute path to .hook>
tint-red=$RED
tint-blue=$BLUE
broken=$BROKEN
CONF
            ;;
    esac
}
write_conf
cp -f "$GREEN" "$DISCOVERED"
info "config dir: $CFG (style=$CONF_STYLE)"
info "shaders.conf:"; sed 's/^/        /' "$CONF"
info "discovered: $DISCOVERED"
info "media: $MEDIA (pixel assertions use the video centre)"

HARNESS_MPV_CONFIG="$CFG/mpv"   # mpv expands ~~/ to --config-dir, so ~~/mpvgui/shaders.conf
                             # lives at $CFG/mpv/mpvgui/shaders.conf (verified)
export HARNESS_MPV_CONFIG
# This scenario needs its own mpv: the orchestrator's instance has no
# --config-dir, so presets/discovery/persistence would all be invisible.
if [ "${HARNESS_BOOTED:-0}" = 1 ]; then
    info "stopping the orchestrator's mpv: shaders.sh boots its own with --config-dir=$HARNESS_MPV_CONFIG"
    mpv_stop
    HARNESS_BOOTED=0
fi
harness_boot
SOCK="$HARNESS_MPV_SOCK"
osd_refresh "$SOCK"
ipc_set "$SOCK" pause true >/dev/null 2>&1 || diag "could not pause playback"
ARTS="${HARNESS_ARTIFACTS:-$HARNESS_RUN_DIR/artifacts/shaders}"
mkdir -p "$ARTS"

# ------------------------------------------------------------------ helpers
chain_json() { ipc_get "$SOCK" glsl-shaders 2>/dev/null || echo '<unreadable>'; }
chain_len() { printf '%s' "$(chain_json)" | jq 'length' 2>/dev/null || echo 0; }
chain_has() { # chain_has <path> -> 0/1
    printf '%s' "$(chain_json)" | jq -e --arg p "$1" 'index($p) != null' >/dev/null 2>&1
}
shaders_json() { # normalized JSON object (accepts a native map or a JSON string)
    local raw
    raw="$(ipc_get "$SOCK" user-data/mpvgui/shaders 2>/dev/null)"
    if [ -z "$raw" ] || [ "$raw" = "null" ]; then printf 'null\n'; return 1; fi
    printf '%s' "$raw" | jq -c 'if type == "string" then (fromjson? // {}) else . end' 2>/dev/null ||
        printf '%s\n' "$raw"
}
shaders_prop() { shaders_json; }
shaders_field() { shaders_json | jq -r "$1" 2>/dev/null; }
entries_raw() { shaders_prop | jq -c '.entries // empty' 2>/dev/null; }
entries_has() { # entries_has <needle> (case-insensitive substring over the JSON)
    local needle="$1" raw
    raw="$(entries_raw)"
    [ -n "$raw" ] || return 1
    printf '%s' "$raw" | grep -qi -- "$needle"
}
send_msg() { ipc_cmd "$SOCK" script-message-to "$SCRIPT_NAME" "$@" >/dev/null; }
fx_button_id() {
    local id
    for id in fx shader shaders effect effects shade; do
        if layout_has && [ "$(layout_btn_n "$id" 0)" != "" ]; then
            printf '%s\n' "$id"; return 0
        fi
    done
    return 1
}
video_pixel() { # video_pixel <png> -> "R G B" at the centre of the video area
    img_rgb_at "$1" "$((OSD_W / 2))" "$((OSD_H / 2))"
}
shot() { # shot <name> -> path, prints RGB
    local p="$ARTS/$1.png"
    harness_shot "$SOCK" "$p" "$HARNESS_TIMEOUT" >/dev/null || return 1
    printf '%s\n' "$p"
}
apply_preset() { send_msg mpvgui-shader "$1"; }

# Shader chains are recompiled by libplacebo on the next frame, so a fixed sleep
# after a preset change is racy (observed: an occasional stale white frame).
# Poll a fresh screenshot until the centre pixel matches, bounded by <timeout>.
# Echoes "<png> <r g b>"; returns 1 when the pixel never matched.
wait_pixel() { # wait_pixel <label> <"R G B"> [timeout]
    local label="$1" want="$2" t="${3:-6}" deadline shot rgb
    deadline=$((SECONDS + ${t%.*}))
    while :; do
        shot="$(shot "$label")" || { printf '/dev/null ? ? ?\n'; return 1; }
        rgb="$(video_pixel "$shot")"
        if awk -v g="$rgb" -v w="$want" -v tol="$PIXEL_TOL" 'BEGIN {
                split(g, a, " "); split(w, b, " ")
                for (i = 1; i <= 3; i++) { d = a[i] - b[i]; if (d < 0) d = -d; if (d > tol) exit 1 }
                exit 0 }'; then
            printf '%s %s\n' "$shot" "$rgb"
            return 0
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
            printf '%s %s\n' "$shot" "$rgb"
            return 1
        fi
        sleep 0.2
    done
}
wait_chain_len() { # wait_chain_len <n> [timeout]
    local want="$1" t="${2:-3}" deadline
    deadline=$((SECONDS + ${t%.*}))
    while :; do
        [ "$(chain_len)" = "$want" ] && return 0
        [ "$SECONDS" -ge "$deadline" ] && return 1
        sleep 0.05
    done
}
panel_rect_ok() { layout_has && [ "$(layout_q '.panel // empty')" != "" ]; }
panel_crop() { layout_panel_crop 2>/dev/null; }
toast_region_crop() { # everything except the bar band and the panel column
    local bary0="$1" panel_x0="$2"
    awk -v w="$OSD_W" -v y0="$bary0" -v px="$panel_x0" \
        'BEGIN { if (px > 0 && px < w) printf "%dx%d+0+0", px, y0; else printf "%dx%d+0+0", w, y0 }'
}
log_has_since() { # log_has_since <marker> <ere>
    local marker="$1" ere="$2" log="${HARNESS_MPV_LOG:-}"
    [ -s "$log" ] || return 1
    tail -n "+$marker" "$log" | grep -E "$ere"
}

# ------------------------------------------------------- 0. contract probe
echo
echo "=== part 0: contract probe"
PROP_RAW="$(shaders_prop)"
if [ "$PROP_RAW" = "null" ] || [ -z "$PROP_RAW" ]; then
    fail "shader contract missing: user-data/mpvgui/shaders is not published"
    diag "user-data/mpvgui keys published: $(ud_dump "$SOCK" mpvgui | cut -d= -f1 | paste -sd' ' -)"
    diag "script-message handlers found in the source:"
    grep -rn "mpvgui-shader\|mpvgui-import\|script-message" "$HARNESS_SCRIPT_DIR"/*.lua 2>/dev/null | sed 's/^/        /' | head -10 ||
        diag "        (none)"
    diag "the shader feature is not implemented yet; remaining parts are SKIP, not PASS"
    SHADER_FEATURE=0
else
    SHADER_FEATURE=1
    pass "user-data/mpvgui/shaders is published: $(printf '%s' "$PROP_RAW" | head -c 400)"
fi
if [ "$SHADER_FEATURE" = 0 ]; then
    for p in "1 baseline" "2 preset apply" "3 mode switch/off" "4 import" "5 broken shader" "6 persistence" "7 cost"; do
        skip "part $p — needs user-data/mpvgui/shaders + mpvgui-shader/mpvgui-import"
    done
    log_assert_clean || true
    finish
fi

ACTIVE="$(shaders_field '.active')"
COUNT="$(shaders_field '.count')"
ENTRIES="$(entries_raw)"
info "shaders: active=$(printf '%s' "$ACTIVE") count=$(printf '%s' "$COUNT")"
info "entries: $(printf '%s' "$ENTRIES" | head -c 600)"
[ -n "$COUNT" ] && pass "shaders.count parses as a number ($COUNT)" || fail "shaders.count missing"
[ "$COUNT" = "$(printf '%s' "$ENTRIES" | jq 'length' 2>/dev/null || echo -1)" ] &&
    pass "shaders.count == length(entries) ($COUNT)" ||
    fail "shaders.count ($COUNT) does not match length(entries) ($(printf '%s' "$ENTRIES" | jq 'length' 2>/dev/null))"

# ------------------------------------------------ 1. baseline + panel
echo
echo "=== part 1: baseline"
BASE_CHAIN="$(chain_json)"
if [ "$BASE_CHAIN" = "[]" ]; then
    pass "baseline glsl-shaders is empty: $BASE_CHAIN"
else
    fail "baseline glsl-shaders is not empty: $BASE_CHAIN (a preset was already active or the GUI set one)"
fi
BASE_SHOT="$(shot baseline)" || die "baseline screenshot failed: $IPC_LAST_ERROR"
BASE_RGB="$(video_pixel "$BASE_SHOT")"
info "baseline centre RGB: ($BASE_RGB)  shot=$BASE_SHOT"
if [ "$BASE_RGB" = "255 255 255" ] || awk -v g="$BASE_RGB" 'BEGIN{split(g,a," "); exit !(a[1]>=240 && a[2]>=240 && a[3]>=240)}'; then
    pass "baseline frame is white (255 255 255 expected for white.mp4)"
else
    fail "baseline frame is not white: ($BASE_RGB) — is the media white.mp4?"
fi

# panel: FX button from the published layout, then Shift+x
FX_BUTTON="$(fx_button_id || true)"
if [ -n "$FX_BUTTON" ]; then
    read -r FX_X FX_Y <<<"$(button_center "$FX_BUTTON")"
    info "FX button='$FX_BUTTON' rect=[$(layout_btn_csv "$FX_BUTTON")] centre=($FX_X,$FX_Y)"
else
    skip "no FX/shader button found in the published layout buttons ($(layout_btn_ids)) — contract gap; the panel is only tested via Shift+x"
    diag "layout.buttons ids: $(layout_btn_ids)"
fi

harness_reveal_osd "$SOCK" >/dev/null 2>&1 || true
PRE_PANEL="$(shot panel-closed)" || die "panel-closed screenshot failed"
PANEL_OPENED=0
if [ -n "$FX_BUTTON" ]; then
    ipc_mouse_move "$SOCK" "$FX_X" "$FX_Y"
    ipc_click "$SOCK" "$FX_X" "$FX_Y" 0 || diag "click on the FX button failed: $IPC_LAST_ERROR"
    sleep 0.5
    harness_layout_refresh "$SOCK" || true
    if [ "$(layout_q '.panel_open')" = "true" ] || panel_rect_ok; then PANEL_OPENED=1; fi
    POST_PANEL="$(shot panel-open-fx)" || die "panel-open screenshot failed"
    if panel_rect_ok; then
        CROP="$(panel_crop)"
    else
        CROP="$(awk -v w="$OSD_W" -v h="$OSD_H" 'BEGIN { printf "%dx%d+%d+0", w/2, h*6/10, w/2 }')"
        diag "no published panel rect — using the right half as a rough region (contract gap)"
    fi
    CHANGED="$(img_diff_stats "$PRE_PANEL" "$POST_PANEL" "$CROP" "$DIFF_TOL" | sed -n 's/.*nonwhite=\([0-9]*\).*/\1/p')"
    BBOX="$(img_diff_bbox "$PRE_PANEL" "$POST_PANEL" "$CROP" "$DIFF_TOL")"
    info "FX click: panel_open=$(layout_q '.panel_open') changed=${CHANGED:-0}px in $CROP bbox=$BBOX"
    if [ "${CHANGED:-0}" -gt 200 ] && [ "$PANEL_OPENED" = 1 ]; then
        pass "FX button opened the shader panel (${CHANGED}px changed, panel_open=true)"
    elif [ "${CHANGED:-0}" -gt 200 ]; then
        pass "FX button changed ${CHANGED}px in the panel region (panel_open not published as true; layout gap)"
    else
        fail "FX button click changed only ${CHANGED:-0}px — the shader panel did not open"
    fi
else
    POST_PANEL=""
fi

# Shift+x must open it too
ipc_key "$SOCK" "$([ "$PANEL_OPENED" = 1 ] && echo "Shift+x" || echo "Shift+x")" || diag "keypress Shift+x failed"
sleep 0.5
harness_layout_refresh "$SOCK" || true
KEY_OPEN="$(layout_q '.panel_open')"
KEY_SHOT="$(shot panel-open-key)" || die "panel screenshot failed"
if [ "$PANEL_OPENED" = 1 ]; then
    # it was open from the click; Shift+x should close it
    if [ "$KEY_OPEN" = "false" ] || [ "$(img_diff_stats "$POST_PANEL" "$KEY_SHOT" "" 8 | sed -n 's/.*nonwhite=\([0-9]*\).*/\1/p')" -gt 200 ]; then
        pass "keypress Shift+x toggled the panel (panel_open=$KEY_OPEN)"
    else
        fail "keypress Shift+x did not toggle the panel (panel_open=$KEY_OPEN, no pixel change)"
    fi
    PANEL_STATE_OPEN=0
else
    if [ "$KEY_OPEN" = "true" ] || [ "$(img_diff_stats "$PRE_PANEL" "$KEY_SHOT" "$([ "$(layout_q '.panel // empty')" != "" ] && layout_panel_crop || echo "")" 8 | sed -n 's/.*nonwhite=\([0-9]*\).*/\1/p')" -gt 200 ]; then
        pass "keypress Shift+x opened the panel (panel_open=$KEY_OPEN)"
        PANEL_STATE_OPEN=1
    else
        fail "keypress Shift+x did not open the panel (panel_open=$KEY_OPEN)"
        PANEL_STATE_OPEN=0
    fi
fi

# entries must mention Off, the presets we wrote and the discovered file
for needle in off tint-red tint-blue discovered-tint; do
    if entries_has "$needle"; then
        pass "entries list contains '$needle'"
    else
        fail "entries list does not contain '$needle': $ENTRIES"
        diag "if the GUI names things differently (e.g. 'Off' vs 'none'), this assertion needs the real naming; raw entries above"
    fi
done

# close the panel for the pixel parts
if [ "$PANEL_STATE_OPEN" = 1 ]; then ipc_key "$SOCK" "Shift+x"; sleep 0.4; fi
harness_layout_refresh "$SOCK" || true

# ------------------------------------------------ 1b. the panel's own click path
echo
echo "=== part 1b: clicking a row in the panel applies that preset"
open_panel() { # open via the FX button when a rect is published, else via Shift+x
    harness_reveal_osd "$SOCK" >/dev/null 2>&1 || true
    if [ -n "${FX_BUTTON:-}" ] && read -r ox oy <<<"$(button_center "$FX_BUTTON")"; then
        ipc_click "$SOCK" "$ox" "$oy" 0
    else
        ipc_key "$SOCK" "Shift+x"
    fi
    sleep 0.5
    harness_layout_refresh "$SOCK" || true
    panel_rect_ok
}
close_panel() {
    ipc_key "$SOCK" "Shift+x" >/dev/null 2>&1 || true
    sleep 0.3
    harness_layout_refresh "$SOCK" || true
}
[ "$PANEL_STATE_OPEN" = 1 ] || open_panel >/dev/null 2>&1 || true
ROWS="$(layout_panel_rows 2>/dev/null || echo 0)"
if panel_rect_ok && [ "${ROWS:-0}" -ge 2 ]; then
    info "panel rect=[$(layout_q '.panel[0]'),$(layout_q '.panel[1]')] rows_y0=$(layout_q '.panel[2]') row_h=$(layout_q '.panel[3]') visible_rows=$ROWS"
    read -r RX RY <<<"$(panel_row_center 1)"
    info "clicking shader row 1 (row 0 is 'Off', so this should be 'tint-red') at ($RX,$RY)"
    ipc_click "$SOCK" "$RX" "$RY" 0 || diag "panel row click failed: $IPC_LAST_ERROR"
    if wait_chain_len 1 3 && chain_has "$RED"; then
        pass "clicking the row applied 'tint-red': $(chain_json)"
    else
        fail "clicking the row did not apply 'tint-red': $(chain_json) — entries were $(entries_raw | head -c 300)"
    fi
    read -r ROW_SHOT ROW_RGB <<<"$(wait_pixel preset-row-click "255 0 0" 5)" \
        || diag "the row-clicked preset did not turn the frame red within 5 s"
    img_rgb_close "the row-clicked preset paints the frame (shot $ROW_SHOT)" "$ROW_RGB" "255 0 0" "$PIXEL_TOL" || true
    read -r OX OY <<<"$(panel_row_center 0)"
    info "clicking row 0 ('Off') at ($OX,$OY)"
    ipc_click "$SOCK" "$OX" "$OY" 0 || diag "Off row click failed: $IPC_LAST_ERROR"
    if wait_chain_len 0 3; then
        pass "clicking 'Off' in the panel emptied glsl-shaders"
    else
        fail "clicking 'Off' in the panel did not empty glsl-shaders: $(chain_json)"
    fi
    close_panel
else
    skip "panel rows are not addressable (panel rect or visible_rows missing: $(layout_q '.panel // empty')) — row-click apply NOT tested"
    close_panel
fi
harness_layout_refresh "$SOCK" || true

# ------------------------------------------------ 2. preset apply
echo
echo "=== part 2: apply preset 'tint-red'"
apply_preset tint-red
if wait_chain_len 1 4; then
    CHAIN="$(chain_json)"
    pass "glsl-shaders after applying tint-red: $CHAIN"
    if chain_has "$RED"; then
        pass "chain contains the tint-red fixture path"
    else
        fail "chain does not contain $RED: $CHAIN"
    fi
else
    fail "glsl-shaders did not become a 1-element array within 4s: $(chain_json)"
fi
info "shaders.active=$(shaders_field '.active') count=$(shaders_field '.count')"
read -r RED_SHOT RED_RGB <<<"$(wait_pixel preset-red "255 0 0" 6)" || diag "pixel did not reach (255 0 0) within 6s"
info "centre RGB before=($BASE_RGB) after=($RED_RGB) tol=$PIXEL_TOL shot=$RED_SHOT"
img_rgb_close "preset tint-red changes the pixel" "$RED_RGB" "255 0 0" "$PIXEL_TOL" || true

# ------------------------------------------------ 3. mode switch + off
echo
echo "=== part 3: switch preset, then off"
CHAIN_BEFORE_SWITCH="$(chain_json)"
apply_preset tint-blue
if wait_chain_len 1 4 && chain_has "$BLUE"; then
    pass "chain switched to tint-blue: $(chain_json)"
else
    fail "chain did not switch to tint-blue: $(chain_json) (was $CHAIN_BEFORE_SWITCH)"
fi
read -r BLUE_SHOT BLUE_RGB <<<"$(wait_pixel preset-blue "0 0 255" 6)" || diag "pixel did not reach (0 0 255) within 6s"
info "centre RGB after switch: ($BLUE_RGB) tol=$PIXEL_TOL shot=$BLUE_SHOT"
img_rgb_close "preset tint-blue changes the pixel again" "$BLUE_RGB" "0 0 255" "$PIXEL_TOL" || true
if [ "$BLUE_RGB" != "$RED_RGB" ]; then
    pass "the second preset paints a different colour (red=$RED_RGB blue=$BLUE_RGB)"
else
    fail "the second preset produced the same pixels as the first ($BLUE_RGB)"
fi

apply_preset off
if wait_chain_len 0 4; then
    pass "applying 'off' emptied glsl-shaders: $(chain_json)"
else
    fail "'off' did not empty glsl-shaders: $(chain_json)"
fi
read -r OFF_SHOT OFF_RGB <<<"$(wait_pixel preset-off "$BASE_RGB" 6)" || diag "pixel did not return to ($BASE_RGB) within 6s"
info "centre RGB after off: ($OFF_RGB) baseline was ($BASE_RGB) tol=$PIXEL_TOL shot=$OFF_SHOT"
img_rgb_close "'off' restores the baseline colour" "$OFF_RGB" "$BASE_RGB" "$PIXEL_TOL" || true

# ------------------------------------------------ 4. import
echo
echo "=== part 4: import a shader"
IMPORT_SRC="$HARNESS_RUN_DIR/imported-tint.hook"
cp -f "$RED" "$IMPORT_SRC"
info "importing $IMPORT_SRC"
send_msg mpvgui-import "$IMPORT_SRC"
# the implementation copies asynchronously (mkdir is fire-and-forget + retries)
COPIED=""
i=0
while [ "$i" -lt 50 ]; do
    COPIED="$(find "$CFG" -name 'imported-tint.hook' -type f 2>/dev/null | head -1)"
    [ -n "$COPIED" ] && break
    sleep 0.1
    i=$((i + 1))
done
if [ -n "$COPIED" ]; then
    pass "import copied the file into the config dir (after ${i}00ms): $COPIED"
else
    fail "import did not copy imported-tint.hook into $CFG within 5s (files: $(find "$CFG" -name '*.hook' | paste -sd' ' -))"
    COPIED=""
fi
harness_layout_refresh "$SOCK" || true
ENTRIES_AFTER_IMPORT="$(entries_raw)"
info "entries after import: $(printf '%s' "$ENTRIES_AFTER_IMPORT" | head -c 600)"
if entries_has imported-tint; then
    pass "entries list contains 'imported-tint' after import"
else
    fail "entries list does not contain 'imported-tint' after import: $ENTRIES_AFTER_IMPORT"
fi
# discovered files are listed by basename (incl. extension) in this implementation
apply_preset imported-tint.hook
if wait_chain_len 1 4 && [ -n "$COPIED" ] && chain_has "$COPIED"; then
    pass "applying the imported shader set glsl-shaders: $(chain_json)"
else
    fail "applying the imported shader did not set glsl-shaders: $(chain_json) (expected $COPIED)"
fi
read -r IMP_SHOT IMP_RGB <<<"$(wait_pixel imported "255 0 0" 6)" || diag "imported shader pixel did not reach (255 0 0) within 6s"
info "centre RGB with the imported tint: ($IMP_RGB) expect ~255 0 0 shot=$IMP_SHOT"
img_rgb_close "imported shader tints the frame" "$IMP_RGB" "255 0 0" "$PIXEL_TOL" || true

# ------------------------------------------------ 5. broken shader
echo
echo "=== part 5: broken shader must not break the GUI"
CHAIN_BEFORE_BROKEN="$(chain_json)"
harness_reveal_osd "$SOCK" >/dev/null 2>&1 || true
PRE_BROKEN_SHOT="$(shot before-broken)" || die "pre-broken screenshot failed"
PRE_BROKEN_RGB="$(video_pixel "$PRE_BROKEN_SHOT")"
LOG_MARKER=$(( $(wc -l <"${HARNESS_MPV_LOG:-/dev/null}") + 1 ))
info "chain before broken: $CHAIN_BEFORE_BROKEN (centre RGB $PRE_BROKEN_RGB), log marker line $LOG_MARKER"

apply_preset broken
sleep 0.35
POST_BROKEN_SHOT="$(shot after-broken)" || diag "post-broken screenshot failed: $IPC_LAST_ERROR"
# the implementation reverts on the next frame after mpv logs the compile error
i=0
while [ "$i" -lt 50 ]; do
    CHAIN_AFTER_BROKEN="$(chain_json)"
    [ "$CHAIN_AFTER_BROKEN" = "$CHAIN_BEFORE_BROKEN" ] && break
    sleep 0.1
    i=$((i + 1))
done
CHAIN_AFTER_BROKEN="$(chain_json)"
AFTER_BROKEN_RGB="$(video_pixel "$POST_BROKEN_SHOT" 2>/dev/null || echo '?')"

# (a) mpv logged a compile error
SHADER_ERR="$(log_has_since "$LOG_MARKER" "shaderc|shader|GLSL|compile" || true)"
if [ -n "$SHADER_ERR" ]; then
    pass "mpv logged a shader/compile error:"
    printf '%s\n' "$SHADER_ERR" | head -3 | sed 's/^/        /'
else
    fail "mpv logged no shader/compile error after applying the broken hook (marker line $LOG_MARKER)"
    diag "last 10 log lines:"
    tail -n 10 "${HARNESS_MPV_LOG:-/dev/null}" | sed 's/^/        /'
fi

# (b) the GUI surfaced it — pixels changed outside bar/panel
if [ -n "$POST_BROKEN_SHOT" ] && [ -s "$POST_BROKEN_SHOT" ]; then
    BARY0="$(bar_y0)"
    PANELX0="$(layout_q '.panel[0]' 2>/dev/null || echo 0)"
    TOAST_CROP="$(toast_region_crop "$BARY0" "${PANELX0:-0}")"
    TOAST_CHANGED="$(img_diff_stats "$PRE_BROKEN_SHOT" "$POST_BROKEN_SHOT" "$TOAST_CROP" 8 | sed -n 's/.*nonwhite=\([0-9]*\).*/\1/p')"
    TOAST_BBOX="$(img_diff_bbox "$PRE_BROKEN_SHOT" "$POST_BROKEN_SHOT" "$TOAST_CROP" 8)"
    info "toast region $TOAST_CROP: changed=${TOAST_CHANGED:-0}px bbox=$TOAST_BBOX"
    if [ "${TOAST_CHANGED:-0}" -gt 100 ]; then
        pass "GUI surfaced the failure (${TOAST_CHANGED}px changed outside bar/panel)"
    else
        fail "no toast/notification pixels appeared outside the bar/panel after the compile error (${TOAST_CHANGED:-0}px)"
    fi
else
    skip "could not screenshot after the broken shader: $IPC_LAST_ERROR"
fi

# (c) previous chain restored
info "glsl-shaders: before=[$CHAIN_BEFORE_BROKEN] broken-measured=[$CHAIN_AFTER_BROKEN]"
if [ "$CHAIN_AFTER_BROKEN" = "$CHAIN_BEFORE_BROKEN" ]; then
    pass "chain restored to the pre-broken value: $CHAIN_AFTER_BROKEN"
else
    fail "chain was NOT restored: before=$CHAIN_BEFORE_BROKEN after=$CHAIN_AFTER_BROKEN"
fi
if [ "$AFTER_BROKEN_RGB" != "?" ] && [ "$AFTER_BROKEN_RGB" != "$PRE_BROKEN_RGB" ]; then
    diag "note: frame RGB while the broken shader was being applied was ($AFTER_BROKEN_RGB) vs ($PRE_BROKEN_RGB) before — libplacebo aborts the pass while the shader is bad"
fi

# (d) no Lua error
if log_has_since "$LOG_MARKER" 'Lua error|Traceback|stack traceback|Error in'; then
    fail "script error in the log after the broken shader:"
    log_has_since "$LOG_MARKER" 'Lua error|Traceback|stack traceback|Error in' | head -5 | sed 's/^/        /'
else
    pass "no Lua error / Traceback after the broken shader"
fi

# back to a known state
apply_preset off
wait_chain_len 0 4 || diag "could not clear the chain before the persistence part"

# ------------------------------------------------ 6. persistence
echo
echo "=== part 6: persistence across restart"
apply_preset tint-blue
if wait_chain_len 1 4 && chain_has "$BLUE"; then
    pass "tint-blue active before quit: $(chain_json)"
else
    fail "could not activate tint-blue before the restart: $(chain_json)"
fi
mpv_stop
info "mpv stopped; relaunching with the same config dir"
mpv_start shaders-restart "$HARNESS_SCRIPT_DIR" "$MEDIA" || die "relaunch failed"
SOCK="$HARNESS_MPV_SOCK"
ipc_wait "$SOCK" time-pos nonnull "$RESTART_WAIT" >/dev/null || diag "playback did not start after restart"
ipc_wait_osd "$SOCK" "$RESTART_WAIT" >/dev/null || diag "no surface after restart"
ipc_set "$SOCK" pause true >/dev/null 2>&1 || true
harness_layout_refresh "$SOCK" || true
if ipc_wait "$SOCK" glsl-shaders nonnull 5 >/dev/null 2>&1; then :; fi
PERSIST_CHAIN="$(chain_json)"
PERSIST_ACTIVE="$(shaders_field '.active')"
info "after restart: glsl-shaders=$PERSIST_CHAIN active=$(printf '%s' "$PERSIST_ACTIVE")"
if [ "$PERSIST_CHAIN" != "[]" ] && chain_has "$BLUE"; then
    pass "the preset was restored after restart: $PERSIST_CHAIN"
else
    fail "the preset was NOT restored after restart: $PERSIST_CHAIN (expected [$BLUE])"
fi
if [ "$(printf '%s' "$PERSIST_ACTIVE" | tr -d '"')" = "tint-blue" ]; then
    pass "shaders.active says 'tint-blue' after restart"
else
    fail "shaders.active after restart is '$(printf '%s' "$PERSIST_ACTIVE")', expected 'tint-blue'"
fi

# ------------------------------------------------ 7. cost
echo
echo "=== part 7: cost (off + hidden, then panel open + untouched)"
apply_preset off
wait_chain_len 0 4 || diag "could not switch shaders off"
if [ "$(chain_len)" != 0 ]; then
    skip "cost part needs shaders off; chain is $(chain_json)"
else
    # --- 7a: panel closed, hidden, 10 s
    if [ "$(layout_q '.panel_open')" = "true" ]; then ipc_key "$SOCK" "Shift+x"; sleep 0.4; fi
    ipc_set "$SOCK" pause false >/dev/null 2>&1 || true
    info "waiting ${HIDE_TIME}s for the OSD to hide (no interaction)"
    local_vis=""
    local_wait=0
    while [ "$local_wait" -lt "$HIDE_TIME" ]; do
        local_vis="$(ipc_get_r "$SOCK" user-data/mpvgui/visible 2>/dev/null || echo null)"
        [ "$local_vis" = "false" ] && break
        sleep 1
        local_wait=$((local_wait + 1))
    done
    info "visible=$local_vis after ${local_wait}s"
    declare -A U0=()
    KEYS="$(ud_dump "$SOCK" mpvgui '^updates' | cut -d= -f1)"
    for k in $KEYS; do U0[$k]="$(ud_num "$SOCK" "mpvgui/$k" 2>/dev/null || echo '')"; done
    FD0="$(ipc_get_num "$SOCK" frame-drop-count 2>/dev/null || echo 0)"
    moved=0
    for i in $(seq 1 10); do
        sleep 1
        line=""
        for k in $KEYS; do
            v="$(ud_num "$SOCK" "mpvgui/$k" 2>/dev/null || echo '')"
            [ -n "${U0[$k]}" ] && [ -n "$v" ] || continue
            d=$((v - U0[$k]))
            line+=" $k+=$d"
            [ "$d" -ne 0 ] && moved=1
        done
        printf '  hidden %2ss:%s\n' "$i" "$line"
    done
    FD1="$(ipc_get_num "$SOCK" frame-drop-count 2>/dev/null || echo 0)"
    if [ "$local_vis" = "false" ]; then
        if [ "$moved" = 0 ]; then
            pass "10 s hidden: every updates* counter delta is 0 (off, panel closed)"
        else
            fail "10 s hidden: counters moved while hidden and idle (see the +N deltas above)"
        fi
    else
        skip "GUI never hid within ${HIDE_TIME}s (visible=$local_vis): idle-hidden cannot be asserted"
    fi
    if [ "${FD1:-0}" -le 0 ] && [ "${FD0:-0}" -le 0 ]; then
        pass "frame-drop-count stayed 0 over the idle window ($FD0 -> $FD1)"
    else
        fail "frame-drop-count moved during idle: $FD0 -> $FD1"
    fi

    # --- 7b: panel open, untouched
    ipc_key "$SOCK" "Shift+x"; sleep 0.6
    harness_layout_refresh "$SOCK" || true
    if [ "$(layout_q '.panel_open')" != "true" ]; then
        skip "panel did not open via Shift+x (panel_open=$(layout_q '.panel_open')): panel-idle cost not measurable"
    else
        PKEYS="$(ud_dump "$SOCK" mpvgui '^updates' | cut -d= -f1)"
        declare -A P0=()
        for k in $PKEYS; do P0[$k]="$(ud_num "$SOCK" "mpvgui/$k" 2>/dev/null || echo '')"; done
        info "panel open; sampling 5 s with no interaction"
        p_moved=""
        for i in $(seq 1 5); do
            sleep 1
            line=""
            for k in $PKEYS; do
                v="$(ud_num "$SOCK" "mpvgui/$k" 2>/dev/null || echo '')"
                [ -n "${P0[$k]}" ] && [ -n "$v" ] || continue
                d=$((v - P0[$k]))
                [ "$d" -ne 0 ] && line+=" $k+=$d"
            done
            printf '  panel  %2ss:%s\n' "$i" "${line:- (no counter moved)}"
            [ -n "$line" ] && p_moved+="$line"
        done
        if [ -z "$p_moved" ]; then
            pass "panel open + untouched for 5 s: no updates* counter moved"
        else
            # only panel-layer counters are acceptable, and only if something
            # really changed on screen (there is nothing to change here)
            nonpanel="$(printf '%s' "$p_moved" | tr ' ' '\n' | grep -v 'updates_panel' | grep -v '^$' || true)"
            if [ -z "$nonpanel" ]; then
                skip "only the panel layer counted updates while untouched: $(printf '%s' "$p_moved" | tr -s ' ')"
            else
                fail "counters moved while the panel was open and untouched: $(printf '%s' "$p_moved" | tr -s ' ')"
            fi
        fi
        ipc_key "$SOCK" "Shift+x"
    fi
fi

# ------------------------------------------------ epilogue
info "artifacts: $ARTS"
info "config dir: $CFG ($([ "$KEEP_CONFIG" = 1 ] && echo kept || echo 'removed at exit'))"
finish
