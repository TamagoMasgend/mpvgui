#!/usr/bin/env bash
# ipc.sh — mpv JSON-IPC + process-lifecycle helpers for the GUI harness.
#
# Sourced by every scenario. Also sources img.sh (pixel helpers) so scenarios
# only need one `source`.
#
#   source "$(dirname "$0")/../ipc.sh"
#
# Sourcing installs an EXIT/INT/TERM/HUP trap that always kills every mpv this
# process group started and removes its sockets — scenarios cannot leak mpv.
#
# Env knobs (all optional):
#   HARNESS_DIR      harness root            (default: dir of this file)
#   HARNESS_RUN_DIR  per-run scratch dir     (default: $HARNESS_DIR/run)
#   HARNESS_GEOMETRY requested window size   (default: 960x540)
#   HARNESS_TIMEOUT  default wait budget, s  (default: 10)
#   HARNESS_MPV_EXTRA extra mpv argv (string, word-split)
#   HARNESS_LOG_ALLOW regex of log lines to ignore in log_assert_clean
#   IPC_POLL         poll interval, s        (default: 0.05)
#
# Verified mpv 0.41.0 facts baked in here (see README "Known traps"):
#   * `screenshot-to-file <png> window` is the only mode that includes the OSD.
#   * osd-dimensions can read 0x0 right after startup and the surface can be
#     resized by the compositor at any time -> always re-read, never hardcode.
#   * mouse buttons: 0=MBTN_LEFT 1=MBTN_MID 2=MBTN_RIGHT 3=WHEEL_UP 4=WHEEL_DOWN
#     (5..7 also decode as WHEEL_DOWN) — a `mouse` command therefore *does*
#     carry wheel events, at the given coordinates.
#   * `mouse-pos.hover` only turns true after a real pointer move.

if [ -z "${HARNESS_DIR:-}" ]; then
    HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
export HARNESS_DIR
HARNESS_RUN_DIR="${HARNESS_RUN_DIR:-$HARNESS_DIR/run}"
export HARNESS_RUN_DIR
HARNESS_MEDIA_DIR="${HARNESS_MEDIA_DIR:-$HARNESS_DIR/media}"
export HARNESS_MEDIA_DIR
HARNESS_GEOMETRY="${HARNESS_GEOMETRY:-960x540}"
HARNESS_TIMEOUT="${HARNESS_TIMEOUT:-10}"
IPC_POLL="${IPC_POLL:-0.05}"
IPC_TIMEOUT="${IPC_TIMEOUT:-5}"

mkdir -p "$HARNESS_RUN_DIR"

# Default GUI script dir, resolved from the cwd / the harness location only:
#   1) ./mpvgui               (run from the repo root)
#   2) <harness>/../../mpvgui (the vendored layout: <repo>/tests/harness)
#   3) .                      (a script dir/file passed as the cwd)
# Prints the chosen path and returns 0, or returns 1 when none has main.lua.
harness_default_script_dir() {
    local cand
    for cand in "$PWD/mpvgui" "$HARNESS_DIR/../../mpvgui"; do
        if [ -f "$cand/main.lua" ]; then printf '%s\n' "$cand"; return 0; fi
    done
    if [ -f "$PWD/main.lua" ]; then printf '%s\n' "$PWD"; return 0; fi
    return 1
}

# shellcheck source=img.sh
[ -f "$HARNESS_DIR/img.sh" ] && . "$HARNESS_DIR/img.sh"

# ------------------------------------------------------------------ reporting
HARNESS_FAILS=${HARNESS_FAILS:-0}
HARNESS_SCENARIO="${HARNESS_SCENARIO:-scenario}"

c_reset=$'\033[0m'; c_red=$'\033[31m'; c_green=$'\033[32m'
c_yellow=$'\033[33m'; c_dim=$'\033[2m'
if [ ! -t 1 ] || [ "${NO_COLOR:-}" != "" ]; then
    c_reset=""; c_red=""; c_green=""; c_yellow=""; c_dim=""
fi

info() { printf '      %s\n' "$*"; }
pass() { printf '%sPASS%s  %s\n' "$c_green" "$c_reset" "$*"; }
skip() { printf '%sSKIP%s  %s\n' "$c_yellow" "$c_reset" "$*"; }
diag() { printf '%sDIAG%s  %s\n' "$c_yellow" "$c_reset" "$*" >&2; }

fail() { # fail <message> — records the failure and keeps going
    HARNESS_FAILS=$((HARNESS_FAILS + 1))
    printf '%sFAIL%s  %s\n' "$c_red" "$c_reset" "$*" >&2
}

die() { # die <message> — prints FAIL + recent mpv log, exits 1
    HARNESS_FAILS=$((HARNESS_FAILS + 1))
    printf '%sFAIL%s  %s\n' "$c_red" "$c_reset" "$*" >&2
    local log="${HARNESS_MPV_LOG:-}"
    if [ -n "$log" ] && [ -s "$log" ]; then
        printf '%s--- last 25 lines of %s ---%s\n' "$c_dim" "$log" "$c_reset" >&2
        tail -n 25 "$log" >&2
        printf '%s--- end log ---%s\n' "$c_dim" "$c_reset" >&2
    fi
    exit 1
}

assert_eq() { # assert_eq <label> <actual> <expected>
    if [ "$2" = "$3" ]; then
        pass "$1 == $3"
    else
        fail "$1: expected '$3', got '$2'"
        return 1
    fi
}

assert_ne() { # assert_ne <label> <actual> <not-expected>
    if [ "$2" != "$3" ]; then
        pass "$1 != $3 (got '$2')"
    else
        fail "$1: value is still '$3' (no change observed)"
        return 1
    fi
}

assert_num_close() { # assert_num_close <label> <actual> <expected> <tol>
    local label="$1" a="$2" e="$3" tol="$4"
    if ! awk -v a="$a" -v e="$e" -v t="$tol" 'BEGIN { exit !(a == a+0 && e == e+0) }' 2>/dev/null; then
        fail "$label: non-numeric values (actual='$a' expected='$e')"
        return 1
    fi
    if awk -v a="$a" -v e="$e" -v t="$tol" 'BEGIN { d = a - e; if (d < 0) d = -d; exit !(d <= t) }'; then
        pass "$label: $a within $tol of $e"
    else
        fail "$label: $a is not within $tol of $e"
        return 1
    fi
}

assert_ge() { # assert_ge <label> <actual> <minimum>
    if awk -v a="$2" -v m="$3" 'BEGIN { exit !(a >= m) }'; then
        pass "$1: $2 >= $3"
    else
        fail "$1: $2 < $3"
        return 1
    fi
}

assert_gt() { # assert_gt <label> <actual> <minimum-exclusive>
    if awk -v a="$2" -v m="$3" 'BEGIN { exit !(a > m) }'; then
        pass "$1: $2 > $3"
    else
        fail "$1: $2 <= $3"
        return 1
    fi
}

assert_exists() { # assert_exists <label> <file>
    if [ -s "$2" ]; then
        pass "$1: $2 ($(stat -c%s "$2") bytes)"
    else
        fail "$1: missing or empty '$2'"
        return 1
    fi
}

finish() { # finish — scenario epilogue
    if [ "${HARNESS_LOG_CHECKED:-0}" != 1 ]; then log_assert_clean || true; fi
    if [ "$HARNESS_FAILS" -eq 0 ]; then
        pass "$HARNESS_SCENARIO: all assertions passed"
        exit 0
    fi
    printf '%sFAIL%s  %s: %d assertion(s) failed -- log: %s\n' \
        "$c_red" "$c_reset" "$HARNESS_SCENARIO" "$HARNESS_FAILS" "${HARNESS_MPV_LOG:-<no log>}" >&2
    exit 1
}

# ------------------------------------------------ process / socket lifecycle
HARNESS_MPV_PIDS=()
HARNESS_MPV_SOCKS=()
HARNESS_EXIT_HOOKS=()

harness_on_exit() { HARNESS_EXIT_HOOKS+=("$1"); }

_harness_cleanup() {
    local rc=$?
    trap - EXIT INT TERM HUP
    for fn in "${HARNESS_EXIT_HOOKS[@]}"; do "$fn" || true; done
    mpv_stop_all
    exit $rc
}
trap _harness_cleanup EXIT INT TERM HUP

_mpv_kill_pid() { # $1 pid
    local pid="$1" i
    kill -0 "$pid" 2>/dev/null || return 0
    kill -TERM "$pid" 2>/dev/null || true
    for i in $(seq 1 40); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.05
    done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

mpv_stop_all() {
    local i
    for i in "${!HARNESS_MPV_SOCKS[@]}"; do
        rm -f "${HARNESS_MPV_SOCKS[$i]}"
    done
    HARNESS_MPV_SOCKS=()
    for i in "${!HARNESS_MPV_PIDS[@]}"; do
        _mpv_kill_pid "${HARNESS_MPV_PIDS[$i]}"
    done
    HARNESS_MPV_PIDS=()
}

mpv_stop() { # stop the current instance (graceful quit over IPC, then SIGTERM)
    local pid="${HARNESS_MPV_PID:-}" sock="${HARNESS_MPV_SOCK:-}"
    if [ -n "$sock" ] && [ -S "$sock" ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        ipc_send "$sock" '{"command":["quit"]}' >/dev/null 2>&1 || true
        local i
        for i in $(seq 1 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
    fi
    [ -n "$pid" ] && _mpv_kill_pid "$pid"
    [ -n "$sock" ] && rm -f "$sock"
    HARNESS_MPV_PID=""
    HARNESS_MPV_SOCK=""
    HARNESS_MPV_LOG=""
    return 0
}

mpv_alive() { # exit 0 if the started mpv is still running
    [ -n "${HARNESS_MPV_PID:-}" ] && kill -0 "$HARNESS_MPV_PID" 2>/dev/null
}

mpv_cpu_ticks() { # $1 pid -> utime+stime in clock ticks (fields 14+15 of stat)
    local pid="${1:-${HARNESS_MPV_PID:-}}"
    [ -r "/proc/$pid/stat" ] || return 1
    # comm can contain spaces/parens -> split after the last ')'
    awk '{
        n = 0; s = ""
        for (i = length($0); i > 0; i--) if (substr($0, i, 1) == ")") { n = i; break }
        s = substr($0, n + 2)
        split(s, f, " ")
        print f[12] + f[13]   # utime(14) stime(15) -> 12th/13th field after comm
    }' "/proc/$pid/stat"
}

mpv_cpu_percent() { # $1 delta-ticks $2 elapsed-seconds
    local tck pct
    tck=$(getconf CLK_TCK 2>/dev/null || echo 100)
    pct=$(awk -v d="$1" -v t="$tck" -v e="$2" 'BEGIN { if (e <= 0) { print 0 } else { printf "%.1f", (d / t) / e * 100 } }')
    pct=$(awk -v p="$pct" 'BEGIN { printf "%.1f", p }')
    printf '%s\n' "$pct"
}

# mpv_start <name> <script-path> [file-or-mpv-arg ...]
#   name      -> "$HARNESS_RUN_DIR/<name>.sock" / ".log"
#   script    -> lua file or directory containing main.lua
# Sets HARNESS_MPV_PID, HARNESS_MPV_SOCK, HARNESS_MPV_LOG, HARNESS_MPV_NAME.
# Fails loudly (die) if the script path is missing or mpv never opens its socket.
mpv_start() {
    local name="$1" script="$2"
    shift 2
    if [ -z "$script" ] || [ ! -e "$script" ]; then
        die "mpv_start: script path '$script' does not exist (build the GUI or pass --script DIR)"
    fi
    if [ -d "$script" ] && [ ! -f "$script/main.lua" ]; then
        die "mpv_start: script dir '$script' has no main.lua"
    fi
    if [ -f "$script" ] && [ "${script##*.}" != "lua" ]; then
        die "mpv_start: script file '$script' is not a .lua file"
    fi

    mkdir -p "$HARNESS_RUN_DIR"
    local sock="$HARNESS_RUN_DIR/$name.sock"
    local log="$HARNESS_RUN_DIR/$name.log"
    rm -f "$sock" "$log"

    local args=(
        --vo=gpu-next --gpu-api=vulkan --gpu-context=waylandvk --hwdec=auto
        --osc=no --input-cursor=yes
        --input-ipc-server="$sock"
        --geometry="$HARNESS_GEOMETRY" --autofit="$HARNESS_GEOMETRY"
        --script="$script"
        --force-window=yes --idle=yes
    )
    # HARNESS_MPV_CONFIG=<dir> switches to an isolated config dir *without*
    # --no-config, because mpv only expands `~~/` when config loading is on
    # (verified: --no-config makes expand-path return the literal path).  The
    # XDG dir is redirected into the same isolation so nothing from the user's
    # real ~/.config/mpv leaks in.
    if [ -n "${HARNESS_MPV_CONFIG:-}" ]; then
        mkdir -p "$HARNESS_MPV_CONFIG"
        export XDG_CONFIG_HOME="$HARNESS_MPV_CONFIG/.xdg"
        mkdir -p "$XDG_CONFIG_HOME"
        args+=(--config-dir="$HARNESS_MPV_CONFIG")
    else
        args+=(--no-config)
    fi
    # shellcheck disable=SC2206
    if [ -n "${HARNESS_MPV_EXTRA:-}" ]; then
        local extra_arr=($HARNESS_MPV_EXTRA)
        args+=(${extra_arr[@]+"${extra_arr[@]}"})
    fi

    : >"$log"
    mpv "${args[@]}" "$@" >>"$log" 2>&1 &
    local pid=$!
    HARNESS_MPV_PIDS+=("$pid")
    HARNESS_MPV_PID="$pid"
    HARNESS_MPV_SOCK="$sock"
    HARNESS_MPV_LOG="$log"
    HARNESS_MPV_NAME="$name"
    HARNESS_MPV_SOCKS+=("$sock")

    local i
    for i in $(seq 1 $(( ${HARNESS_TIMEOUT%.*} * 20 ))); do
        [ -S "$sock" ] && break
        mpv_alive || die "mpv died before creating its IPC socket (see log above)"
        sleep 0.05
    done
    [ -S "$sock" ] || die "mpv did not create IPC socket '$sock' within ${HARNESS_TIMEOUT}s"
    info "mpv pid=$pid sock=$sock log=$log"
}

# ----------------------------------------------------------------------- IPC
ipc_send() { # ipc_send <sock> '<json-line>' ['<json-line>' ...] -> replies
    local sock="$1"; shift
    [ -S "$sock" ] || { IPC_LAST_ERROR="socket-missing:$sock"; return 2; }
    printf '%s\n' "$@" | timeout "$IPC_TIMEOUT" socat -t "$IPC_TIMEOUT" - "UNIX-CONNECT:$sock" 2>/dev/null
}

_json_escape() { printf '%s' "$1" | jq -R . ; }

# turn argv into a JSON array, auto-typing tokens that are already valid JSON
_json_args() {
    local out="[" sep="" a j
    for a in "$@"; do
        if j="$(printf '%s' "$a" | jq -c . 2>/dev/null)" && [ -n "$j" ]; then
            out+="$sep$j"
        else
            out+="$sep$(printf '%s' "$a" | jq -R .)"
        fi
        sep=","
    done
    printf '%s]' "$out"
}

IPC_LAST_ERROR=""

ipc_cmd() { # ipc_cmd <sock> <command> [args...] -> first reply line
    local sock="$1"; shift
    local payload
    payload="{\"command\":$(_json_args "$@")}"
    local reply
    reply="$(ipc_send "$sock" "$payload")" || { IPC_LAST_ERROR="send-failed"; return 2; }
    reply="${reply%%$'\n'*}"
    if [ -z "$reply" ]; then IPC_LAST_ERROR="empty-reply"; return 2; fi
    local err
    err="$(printf '%s' "$reply" | jq -r '.error // "malformed-reply"' 2>/dev/null)"
    if [ "$err" != "success" ]; then
        IPC_LAST_ERROR="$err"
        return 1
    fi
    printf '%s\n' "$reply"
}

ipc_get() { # ipc_get <sock> <property> -> compact JSON of .data (false/null preserved)
    local sock="$1" prop="$2" reply
    reply="$(ipc_cmd "$sock" get_property "$prop")" || return 1
    printf '%s\n' "$reply" | jq -c '.data'
}

ipc_get_r() { # ipc_get_r <sock> <property> -> raw string (null -> literal "null")
    local v
    v="$(ipc_get "$1" "$2")" || return 1
    if [ "$v" = "null" ]; then printf 'null\n'; else printf '%s\n' "$v" | jq -r .; fi
}

ipc_get_num() { # ipc_get_num <sock> <property> -> number (fails if null/non-numeric)
    local v
    v="$(ipc_get "$1" "$2")" || { IPC_LAST_ERROR="${IPC_LAST_ERROR:+$IPC_LAST_ERROR}"; return 1; }
    case "$v" in
        null|"") IPC_LAST_ERROR="null"; return 1 ;;
    esac
    if ! printf '%s' "$v" | jq -e 'type == "number"' >/dev/null 2>&1; then
        IPC_LAST_ERROR="not-a-number:$v"; return 1
    fi
    printf '%s\n' "$v"
}

ipc_set() { # ipc_set <sock> <property> <json-value>
    ipc_cmd "$1" set_property "$2" "$3" >/dev/null
}

ipc_key() { ipc_cmd "$1" keypress "$2" >/dev/null; }

ipc_mouse() { # ipc_mouse <sock> <x> <y> [button]   (button default -1 = move only)
    local sock="$1" x="$2" y="$3" b="${4:--1}"
    ipc_cmd "$sock" mouse "$x" "$y" "$b" >/dev/null
}

ipc_mouse_move() { ipc_mouse "$1" "$2" "$3" -1; }

ipc_click() { # ipc_click <sock> <x> <y> [button]
    local sock="$1" x="$2" y="$3" b="${4:-0}"
    ipc_mouse "$sock" "$x" "$y" "$b"
}

# ipc_wait <sock> <property> <condition> [timeout]
#   condition: =VALUE | !=VALUE | >NUM | >=NUM | <NUM | <=NUM | ~REGEX | nonnull | null | true | false
ipc_wait() {
    local sock="$1" prop="$2" cond="$3" timeout="${4:-$HARNESS_TIMEOUT}"
    local deadline=$((SECONDS + ${timeout%.*}))
    local v last="<none>"
    while :; do
        if v="$(ipc_get "$sock" "$prop" 2>/dev/null)"; then
            last="$v"
            case "$cond" in
                nonnull) [ "$v" != "null" ] && return 0 ;;
                null)    [ "$v" = "null" ] && return 0 ;;
                "="*)    [ "$(printf '%s' "$v" | jq -r .)" = "${cond#=}" ] && return 0 ;;
                "!="*)   [ "$(printf '%s' "$v" | jq -r .)" != "${cond#!=}" ] && return 0 ;;
                ">="*)   awk -v a="$v" -v b="${cond#>=}" 'BEGIN{exit !(a+0 >= b+0)}' && return 0 ;;
                "<="*)   awk -v a="$v" -v b="${cond#<=}" 'BEGIN{exit !(a+0 <= b+0)}' && return 0 ;;
                ">"*)    awk -v a="$v" -v b="${cond#\>}" 'BEGIN{exit !(a+0 > b+0)}' && return 0 ;;
                "<"*)    awk -v a="$v" -v b="${cond#<}" 'BEGIN{exit !(a+0 < b+0)}' && return 0 ;;
                "~"*)    printf '%s' "$v" | grep -Eq "${cond#\~}" && return 0 ;;
                true)    [ "$v" = "true" ] && return 0 ;;
                false)   [ "$v" = "false" ] && return 0 ;;
                *)       IPC_LAST_ERROR="bad-condition:$cond"; return 2 ;;
            esac
        else
            last="<${IPC_LAST_ERROR:-unreadable}>"
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
            IPC_LAST_ERROR="timeout: $prop $cond (last='$last' after ${timeout}s)"
            return 1
        fi
        sleep "$IPC_POLL"
    done
}

ipc_wait_value() { # ipc_wait_value <sock> <prop> <expected> [timeout]
    ipc_wait "$1" "$2" "=$3" "${4:-$HARNESS_TIMEOUT}"
}

ipc_wait_num() { # ipc_wait_num <sock> <prop> <op> <value> [timeout]  op: gt|lt|ge|le|eq|ne
    local op="$1"; shift
    local sock="$1" prop="$2" o="$3" val="$4" timeout="${5:-$HARNESS_TIMEOUT}"
    case "$o" in
        gt) ipc_wait "$sock" "$prop" ">$val" "$timeout" ;;
        lt) ipc_wait "$sock" "$prop" "<$val" "$timeout" ;;
        ge) ipc_wait "$sock" "$prop" ">=$val" "$timeout" ;;
        le) ipc_wait "$sock" "$prop" "<=$val" "$timeout" ;;
        eq) ipc_wait "$sock" "$prop" "=$val" "$timeout" ;;
        ne) ipc_wait "$sock" "$prop" "!=$val" "$timeout" ;;
        *)  IPC_LAST_ERROR="bad-op:$o"; return 2 ;;
    esac
}

# ------------------------------------------------------------- osd / surface
OSD_W=""; OSD_H=""

ipc_osd_raw() { ipc_get "$1" osd-dimensions; }

# ipc_wait_osd <sock> [timeout] -> sets OSD_W/OSD_H, echoes "W H"
# Waits for a non-zero surface that stays constant for 3 consecutive samples,
# because niri may resize (or re-tile) the window after the video is loaded.
ipc_wait_osd() {
    local sock="$1" timeout="${2:-$HARNESS_TIMEOUT}"
    local deadline=$((SECONDS + ${timeout%.*}))
    local prev_w="" prev_h="" stable=0 cur_w cur_h v
    while :; do
        if v="$(ipc_get "$sock" osd-dimensions 2>/dev/null)"; then
            cur_w=$(printf '%s' "$v" | jq -r '.w // 0' 2>/dev/null)
            cur_h=$(printf '%s' "$v" | jq -r '.h // 0' 2>/dev/null)
            if [ "${cur_w:-0}" -gt 0 ] && [ "${cur_h:-0}" -gt 0 ]; then
                if [ "$cur_w" = "$prev_w" ] && [ "$cur_h" = "$prev_h" ]; then
                    stable=$((stable + 1))
                    if [ "$stable" -ge 3 ]; then
                        OSD_W="$cur_w"; OSD_H="$cur_h"
                        printf '%s %s\n' "$OSD_W" "$OSD_H"
                        return 0
                    fi
                else
                    stable=0
                fi
                prev_w="$cur_w"; prev_h="$cur_h"
            fi
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
            IPC_LAST_ERROR="timeout waiting for non-zero osd-dimensions (last=${prev_w}x${prev_h})"
            return 1
        fi
        sleep 0.1
    done
}

osd_refresh() { # re-read OSD_W/OSD_H, die on failure
    ipc_wait_osd "${1:-$HARNESS_MPV_SOCK}" "$HARNESS_TIMEOUT" >/dev/null ||
        die "cannot read stable osd-dimensions: $IPC_LAST_ERROR"
}

osd_px() { # osd_px <fraction>  -> pixel coordinate (int) along the axis
    awk -v f="$1" -v d="$2" 'BEGIN { printf "%d", int(f * d + 0.5) }'
}
osd_x() { osd_px "$1" "$OSD_W"; }
osd_y() { osd_px "$1" "$OSD_H"; }

# ------------------------------------------------------------- bar geometry
# The GUI may publish its real geometry as JSON in
# `user-data/mpvgui/layout`.  When present, EVERY geometry helper below uses it;
# only when it is absent do we fall back to the documented fractions.  Never
# hardcode pixel values in the harness.
#
# Verified shape of the published layout (mpvgui v1):
#   { w, h, panel_open,
#     bar    = [x0, y0, x1, y1],
#     seek   = [x0, y0, x1, y1],
#     volume = [x0, x1],
#     buttons = { play=[x0,y0,x1,y1], back=…, forward=…, speed=…, playlist=…,
#                 mute=…, volume=…, fullscreen=… },
#     panel  = [x0, x1, rows_y0, row_h, visible_rows]     (only while open) }
LAYOUT_JSON="${LAYOUT_JSON:-}"
HARNESS_BAR_FRAC="${HARNESS_BAR_FRAC:-0.10}"

# harness_layout_refresh <sock> -> 0 when a layout was loaded
harness_layout_refresh() {
    local sock="$1" raw inner
    raw="$(ipc_get "$sock" user-data/mpvgui/layout 2>/dev/null)" || { LAYOUT_JSON=""; return 1; }
    [ -n "$raw" ] && [ "$raw" != "null" ] || { LAYOUT_JSON=""; return 1; }
    inner="$(printf '%s' "$raw" | jq -r 'if type == "string" then . else tojson end' 2>/dev/null)" ||
        { LAYOUT_JSON=""; return 1; }
    printf '%s' "$inner" | jq -e 'type == "object"' >/dev/null 2>&1 || { LAYOUT_JSON=""; return 1; }
    LAYOUT_JSON="$inner"
    return 0
}

layout_q() { printf '%s' "$LAYOUT_JSON" | jq -r "$1" 2>/dev/null; }
layout_has() { [ -n "$LAYOUT_JSON" ]; }

# Quoting-safe accessors: callers pass a bare key, never a nested jq filter
# inside a double-quoted string (that silently broke earlier versions).
layout_n() { # layout_n <key> <index>  -> number or empty
    local key="$1" idx="$2"
    printf '%s' "$LAYOUT_JSON" |
        jq -r --arg k "$key" --argjson i "$idx" '.[$k][$i] // empty' 2>/dev/null
}
layout_arr_csv() { # layout_arr_csv <key> -> "a,b,c"
    local key="$1"
    printf '%s' "$LAYOUT_JSON" |
        jq -r --arg k "$key" '.[$k] // [] | if type == "array" then map(tostring) | join(",") else empty end' 2>/dev/null
}
layout_btn_csv() { # layout_btn_csv <id> -> "x0,y0,x1,y1"
    local id="$1"
    printf '%s' "$LAYOUT_JSON" |
        jq -r --arg k "$id" '.buttons[$k] // [] | if type == "array" then map(tostring) | join(",") else empty end' 2>/dev/null
}
layout_btn_ids() { printf '%s' "$LAYOUT_JSON" | jq -r '.buttons // {} | keys | join(",")' 2>/dev/null; }
layout_btn_n() { # layout_btn_n <id> <index>
    local id="$1" idx="$2"
    printf '%s' "$LAYOUT_JSON" |
        jq -r --arg k "$id" --argjson i "$idx" '.buttons[$k][$i] // empty' 2>/dev/null
}

# Geometry: published layout first, fractions only as a fallback.
bar_height() {
    if layout_has; then awk -v y0="$(layout_q '.bar[1]')" -v y1="$(layout_q '.bar[3]')" 'BEGIN { printf "%d", y1 - y0 }'
    else awk -v h="$OSD_H" -v f="$HARNESS_BAR_FRAC" 'BEGIN { printf "%d", h * f }'; fi
}
bar_y0() {
    if layout_has; then layout_q '.bar[1] | floor'
    else awk -v h="$OSD_H" -v f="$HARNESS_BAR_FRAC" 'BEGIN { printf "%d", h - h * f }'; fi
}
bar_y_center() {
    if layout_has; then awk -v y0="$(layout_q '.bar[1]')" -v y1="$(layout_q '.bar[3]')" 'BEGIN { printf "%d", (y0 + y1) / 2 }'
    else awk -v h="$OSD_H" -v f="$HARNESS_BAR_FRAC" 'BEGIN { printf "%d", h - (h * f) / 2 }'; fi
}

# x of the leftmost control (play button centre with a layout, 3% otherwise)
bar_left_x() {
    if layout_has && [ "$(layout_q '.buttons.play // empty')" != "" ]; then
        awk -v a="$(layout_q '.buttons.play[0]')" -v b="$(layout_q '.buttons.play[2]')" 'BEGIN { printf "%d", (a + b) / 2 }'
    else
        awk -v w="$OSD_W" 'BEGIN { printf "%d", w * 0.03 }'
    fi
}

# seekbar_x_at <fraction 0..1> [left-frac] [right-frac]
seekbar_x_at() {
    if layout_has; then
        awk -v a="$(layout_q '.seek[0]')" -v b="$(layout_q '.seek[2]')" -v f="$1" \
            'BEGIN { printf "%d", a + (b - a) * f }'
    else
        awk -v w="$OSD_W" -v f="$1" -v l="${2:-0.05}" -v r="${3:-0.85}" \
            'BEGIN { printf "%d", (l + f * (r - l)) * w }'
    fi
}
seekbar_y() {
    if layout_has; then awk -v a="$(layout_q '.seek[1]')" -v b="$(layout_q '.seek[3]')" 'BEGIN { printf "%d", (a + b) / 2 }'
    else bar_y_center; fi
}
seekbar_left()  { if layout_has; then layout_q '.seek[0] | floor'; else awk -v w="$OSD_W" 'BEGIN { printf "%d", w * 0.05 }'; fi; }
seekbar_right() { if layout_has; then layout_q '.seek[2] | floor'; else awk -v w="$OSD_W" 'BEGIN { printf "%d", w * 0.85 }'; fi; }

# volume slider centre (layout) or the right end of the bar (fallback)
volume_center_x() {
    if layout_has && [ "$(layout_q '.volume // empty')" != "" ]; then
        awk -v a="$(layout_q '.volume[0]')" -v b="$(layout_q '.volume[1]')" 'BEGIN { printf "%d", (a + b) / 2 }'
    else
        printf '%s\n' "$((OSD_W - 60))"
    fi
}

# "cx cy" of a named button (layout only; falls back to the play-button guess)
button_center() {
    local id="$1" x0 x1 y0 y1
    x0="$(layout_btn_n "$id" 0)"; x1="$(layout_btn_n "$id" 2)"
    y0="$(layout_btn_n "$id" 1)"; y1="$(layout_btn_n "$id" 3)"
    if [ -n "$x0" ] && [ -n "$y0" ]; then
        awk -v a="$x0" -v b="$x1" -v c="$y0" -v d="$y1" 'BEGIN { printf "%d %d", (a + b) / 2, (c + d) / 2 }'
    else
        printf '%s %s\n' "$(bar_left_x)" "$(bar_y_center)"
    fi
}

layout_panel_rows() {
    layout_has && [ "$(layout_q '.panel // empty')" != "" ] || return 1
    layout_q '.panel[4] | floor'
}

# "cx cy" of a 0-based visible panel row
panel_row_center() {
    local row="$1"
    layout_has && [ "$(layout_q '.panel // empty')" != "" ] || return 1
    awk -v x0="$(layout_q '.panel[0]')" -v x1="$(layout_q '.panel[1]')" \
        -v y0="$(layout_q '.panel[2]')" -v rh="$(layout_q '.panel[3]')" -v r="$row" \
        'BEGIN { printf "%d %d", (x0 + x1) / 2, y0 + (r + 0.5) * rh }'
}

# panel crop "WxH+X+Y" covering the whole panel (header + rows)
layout_panel_crop() {
    layout_has && [ "$(layout_q '.panel // empty')" != "" ] || return 1
    awk -v x0="$(layout_q '.panel[0]')" -v x1="$(layout_q '.panel[1]')" \
        -v y0="$(layout_q '.panel[2]')" -v rh="$(layout_q '.panel[3]')" -v n="$(layout_panel_rows)" \
        'BEGIN {
            hh = (y0 - 0 > 0) ? y0 : 0          # header area above rows
            w = x1 - x0
            h = y0 + n * rh                     # header + all visible rows
            printf "%dx%d+%d+%d", w, h, x0, 0
        }'
}


# ---------------------------------------------------------------- screenshots
harness_shot() { # harness_shot <sock> <outfile> [timeout]
    local sock="$1" out="$2" timeout="${3:-$HARNESS_TIMEOUT}"
    local attempt=0 png_w png_h dim
    while [ "$attempt" -lt 4 ]; do
        attempt=$((attempt + 1))
        osd_refresh "$sock"
        rm -f "$out"
        local reply
        reply="$(ipc_cmd "$sock" screenshot-to-file "$out" window 2>/dev/null || true)"
        local i
        for i in $(seq 1 $((timeout * 20))); do
            [ -s "$out" ] && break
            sleep 0.05
        done
        if [ ! -s "$out" ]; then
            IPC_LAST_ERROR="screenshot-to-file produced no file (reply='${reply:-none}')"
            continue
        fi
        # wait for the png to stop growing
        local s1 s2
        s1=$(stat -c%s "$out"); sleep 0.08; s2=$(stat -c%s "$out")
        [ "$s1" = "$s2" ] || continue
        dim="$(img_dim "$out" 2>/dev/null || true)"
        png_w="${dim%% *}"; png_h="${dim##* }"
        if [ "${png_w:-0}" = "$OSD_W" ] && [ "${png_h:-0}" = "$OSD_H" ]; then
            printf 'shot=%s osd=%sx%s png=%sx%s\n' "$out" "$OSD_W" "$OSD_H" "$png_w" "$png_h"
            return 0
        fi
        # surface changed between reading osd-dimensions and grabbing the frame
        IPC_LAST_ERROR="osd ${OSD_W}x${OSD_H} != png ${png_w}x${png_h}"
        sleep 0.15
    done
    IPC_LAST_ERROR="could not take a screenshot matching osd-dimensions after 4 tries: $IPC_LAST_ERROR"
    return 1
}

# harness_reveal_osd <sock> [x] [y]
# Real GUIs hide their bar; hover is what brings it back.  mpv's
# --osd-duration is 1000ms, so a script-set OSD that is not re-created
# disappears again — every screenshot in this harness is therefore preceded by
# a pointer nudge, and the scenario re-checks for OSD pixels afterwards.
harness_reveal_osd() {
    local sock="$1" x="${2:-}" y="${3:-}"
    [ -n "$x" ] || x=$(awk -v w="$OSD_W" 'BEGIN { printf "%d", w * 0.5 }')
    [ -n "$y" ] || y="$(bar_y_center)"
    ipc_mouse_move "$sock" "$x" "$y" >/dev/null 2>&1 || return 1
    ipc_mouse_move "$sock" "$((x + 1))" "$y" >/dev/null 2>&1 || true
    local vis
    vis="$(ipc_get_r "$sock" user-data/mpvgui/visible 2>/dev/null || true)"
    if [ "$vis" = "true" ] || [ "$vis" = "false" ]; then
        [ "$vis" = "true" ] || ipc_wait "$sock" user-data/mpvgui/visible "=true" 2 >/dev/null || true
    fi
    sleep 0.15
    return 0
}

# ------------------------------------------------------------------ mpv log
log_path() { printf '%s\n' "${HARNESS_MPV_LOG:-}"; }

log_grep() { # log_grep <ere> -> matching lines (rc 1 if none)
    local log="${HARNESS_MPV_LOG:-}"
    [ -s "$log" ] || return 1
    grep -E "$1" "$log"
}

# The forbidden patterns are the harness contract from the brief.
LOG_FORBIDDEN_DEFAULT='Lua error|Traceback|stack traceback|Error in|Script error'
LOG_ALLOW_DEFAULT='Write error \(Broken pipe\)'

log_assert_clean() { # log_assert_clean [extra-forbidden-regex] — records failure on matches
    HARNESS_LOG_CHECKED=1
    local log="${HARNESS_MPV_LOG:-}" extra="${1:-}"
    if [ -z "$log" ] || [ ! -f "$log" ]; then
        fail "log_assert_clean: no log file recorded"
        return 1
    fi
    local pattern="$LOG_FORBIDDEN_DEFAULT"
    [ -n "$extra" ] && pattern="$pattern|$extra"
    local allow="${HARNESS_LOG_ALLOW:-$LOG_ALLOW_DEFAULT}"
    local hits
    hits="$(grep -E "$pattern" "$log" 2>/dev/null | grep -Ev "$allow" || true)"
    if [ -z "$hits" ]; then
        pass "log clean: no /$(printf '%s' "$LOG_FORBIDDEN_DEFAULT" | sed 's/|/ , /g')/ in $log"
        return 0
    fi
    fail "log contains script errors ($(printf '%s\n' "$hits" | wc -l) line(s)) in $log:"
    printf '%s\n' "$hits" | head -n 10 | sed 's/^/        /' >&2
    return 1
}

# ---------------------------------------------------------- boot / preflight
HARNESS_BOOTED=${HARNESS_BOOTED:-0}
HARNESS_SCRIPT_DIR="${HARNESS_SCRIPT_DIR:-}"
HARNESS_MEDIA="${HARNESS_MEDIA:-}"

harness_require_script() { # harness_require_script <path>
    local p="$1"
    if [ -z "$p" ]; then
        die "no GUI script given (use --script DIR, or run through run.sh)"
    fi
    if [ ! -e "$p" ]; then
        die "GUI script path '$p' does not exist"
    fi
    if [ -d "$p" ] && [ ! -f "$p/main.lua" ]; then
        die "GUI script dir '$p' contains no main.lua"
    fi
    info "script: $p"
}

harness_wait_playback() { # waits for a loaded file and a live surface
    local sock="${1:-$HARNESS_MPV_SOCK}"
    ipc_wait "$sock" time-pos nonnull "$HARNESS_TIMEOUT" ||
        die "playback never started (time-pos stayed null: $IPC_LAST_ERROR)"
    ipc_wait_osd "$sock" "$HARNESS_TIMEOUT" >/dev/null ||
        die "no usable video surface (osd-dimensions): $IPC_LAST_ERROR"
    info "osd: ${OSD_W}x${OSD_H}"
    # the GUI may publish its real geometry; everything below prefers it
    if harness_layout_refresh "$sock"; then
        info "layout: bar=$(layout_arr_csv bar) seek=$(layout_arr_csv seek) volume=$(layout_arr_csv volume) buttons=$(layout_btn_ids)"
    else
        info "layout: user-data/mpvgui/layout not published -> using fraction fallbacks (bar=${HARNESS_BAR_FRAC})"
    fi
}

# harness_boot — idempotent: run.sh may already have started mpv.
harness_boot() {
    if [ "$HARNESS_BOOTED" = 1 ] && [ -n "${HARNESS_MPV_SOCK:-}" ]; then
        # run.sh already started mpv: re-read surface + published layout here,
        # because this is a separate shell and LAYOUT_JSON is not inherited.
        [ -n "${OSD_W:-}" ] || osd_refresh "$HARNESS_MPV_SOCK"
        harness_layout_refresh "$HARNESS_MPV_SOCK" || true
        return 0
    fi
    harness_require_script "$HARNESS_SCRIPT_DIR"
    [ -n "$HARNESS_MEDIA" ] || die "no media given (use --media FILE, or run through run.sh)"
    [ -e "$HARNESS_MEDIA" ] || die "media '$HARNESS_MEDIA' does not exist"
    # shellcheck disable=SC2086
    mpv_start "$HARNESS_SCENARIO" "$HARNESS_SCRIPT_DIR" $HARNESS_MEDIA
    harness_wait_playback
    HARNESS_BOOTED=1
    export HARNESS_BOOTED
    return 0
}

# Common --help/--script/--media argument parser shared by all scenarios.
# Leaves scenario-specific args in HARNESS_ARGS.
harness_parse_common() {
    HARNESS_ARGS=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --script) HARNESS_SCRIPT_DIR="$2"; shift 2 ;;
            --media)  HARNESS_MEDIA="$2"; shift 2 ;;
            --geometry) HARNESS_GEOMETRY="$2"; shift 2 ;;
            --timeout) HARNESS_TIMEOUT="$2"; shift 2 ;;
            --extra) HARNESS_MPV_EXTRA="$2"; shift 2 ;;
            *) HARNESS_ARGS+=("$1"); shift ;;
        esac
    done
    export HARNESS_SCRIPT_DIR HARNESS_MEDIA HARNESS_GEOMETRY HARNESS_TIMEOUT
    return 0
}

# Look up a user-data counter, tolerating both `N` and `{...}` shapes.
ud_get() { # ud_get <sock> <name>  -> value or empty
    local sock="$1" name="$2"
    ipc_get "$sock" "user-data/$name" 2>/dev/null || true
}

ud_num() { # ud_num <sock> <name> -> integer or empty
    local v
    v="$(ud_get "$1" "$2")"
    case "$v" in ""|null) return 1 ;; esac
    printf '%s' "$v" | jq -e 'type == "number"' >/dev/null 2>&1 || return 1
    printf '%s\n' "$v"
}

# ud_dump <sock> [prefix] -> "key=value" lines from the user-data map
ud_dump() {
    local sock="$1" prefix="${2:-mpvgui}" suffix="${3:-}"
    ipc_get "$sock" "user-data" 2>/dev/null |
        jq -r --arg p "$prefix" --arg s "$suffix" '
            (.[$p] // {}) | to_entries[]
            | select($s == "" or (.key | test($s)))
            | "\(.key)=\(.value | tostring)"' 2>/dev/null || true
}

ipc_help() {
    cat <<'EOF'
ipc.sh — helper library (source it; do not execute)

PROCESS / SOCKET
  mpv_start NAME SCRIPT [media|mpv-args...]  launch mpv, wait for socket
  mpv_stop                                   quit current mpv, clean socket
  mpv_stop_all                               kill every mpv this shell started
  mpv_alive                                  true while mpv runs
  mpv_cpu_ticks [PID]                        utime+stime from /proc/PID/stat
  mpv_cpu_percent DELTA_TICKS ELAPSED_S   -> "%CPU" for that sample

IPC
  ipc_send SOCK JSON...            raw reply lines
  ipc_cmd SOCK CMD [ARG...]        build {"command":[...]} (args auto-typed) and send
  ipc_get SOCK PROP                .data as compact JSON (false/null preserved)
  ipc_get_r SOCK PROP              .data as raw string
  ipc_get_num SOCK PROP            .data as number (fails on null)
  ipc_set SOCK PROP JSONVALUE
  ipc_key SOCK KEYNAME
  ipc_mouse SOCK X Y [BUTTON]      0=L 1=M 2=R 3=WHEEL_UP 4=WHEEL_DOWN -1=move
  ipc_click SOCK X Y [BUTTON]
  ipc_wait SOCK PROP COND [TIMEOUT]  =V !=V >N >=N <N <=N ~RE nonnull null true false
  ipc_wait_value SOCK PROP VALUE [TIMEOUT]
  ipc_wait_num SOCK PROP OP VALUE [TIMEOUT]   OP: gt lt ge le eq ne
  ipc_wait_osd SOCK [TIMEOUT]       stable non-zero surface -> OSD_W/OSD_H
  osd_x FRAC / osd_y FRAC           fraction -> pixel in the real surface
  harness_shot SOCK OUT.png         window screenshot validated against osd-dimensions

LOG
  log_path / log_grep ERE / log_assert_clean [extra-regex]

ASSERTIONS
  pass MSG / fail MSG / skip MSG / info MSG / diag MSG / die MSG
  assert_eq L A B / assert_ne L A B / assert_num_close L A E TOL
  assert_ge L A MIN / assert_gt L A MIN / assert_exists L FILE
  finish          epilogue: log_assert_clean + exit 0/1

BOOT
  harness_require_script PATH / harness_wait_playback / harness_boot
  harness_parse_common "$@"   -> consumes --script --media --geometry --timeout --extra
  ud_get / ud_num / ud_dump   user-data/<base>[...] helpers

A trap on EXIT/INT/TERM/HUP kills every mpv started here.
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        -h|--help|"") ipc_help ;;
        *) echo "ipc.sh is a library — source it, or run with --help" >&2; exit 2 ;;
    esac
fi
