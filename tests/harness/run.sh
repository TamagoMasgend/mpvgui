#!/usr/bin/env bash
# run.sh — orchestrator: preflight, start mpv on the GUI script, wait for
# playback, then run one scenario file against the live instance.
#
# Usage:
#   ./run.sh                       # smoke against ./mpvgui (or <harness>/../../mpvgui)
#   ./run.sh render                # one scenario
#   ./run.sh --script /path/to/gui --scenario click
#   ./run.sh --all                 # every scenario, one mpv each
#   ./run.sh --list
#
# Every scenario can also be run standalone (they boot their own mpv):
#   scenarios/click.sh --script /path/to/gui
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HARNESS_DIR
# shellcheck source=ipc.sh
. "$HARNESS_DIR/ipc.sh"

SCEN_DIR="$HARNESS_DIR/scenarios"
ARTROOT="$HARNESS_DIR/run/artifacts"

SCENARIOS=(smoke render click drag wheel playlist shaders robustness perf)

desc_of() { local v="DESC_$1"; printf "%s" "${!v:-}"; }

DESC_smoke="script loads, log clean, user-data/mpvgui/updates readable"
DESC_render="window screenshot has OSD pixels (bar bbox) over white.mp4"
DESC_click="synthetic click on a control -> expected property change"
DESC_drag="seekbar drag: time-pos follows and settles at the release point"
DESC_wheel="wheel over the volume area changes volume"
DESC_playlist="Tab opens a panel; clicking row 2 changes playlist-pos"
DESC_robustness="audio-only, idle start, resize, seek past EOF: no script errors"
DESC_perf="10s of 1080p60: frame drops, vf-fps, CPU, GUI update counters"
DESC_shaders="shader presets: apply/switch/off, import, compile failure, persistence, cost"

# per-scenario default media ("" -> white.mp4, "pl" -> the 5-episode playlist)
declare -A SCEN_MEDIA=(
    [smoke]=white.mp4
    [render]=white.mp4
    [click]=video1080p60.mp4
    [drag]=video1080p60.mp4
    [wheel]=white.mp4
    [playlist]=pl
    [robustness]=white.mp4
    [perf]=video1080p60.mp4
    [shaders]=white.mp4
)
declare -A SCEN_EXTRA=(
    [perf]="--loop-file=inf"
)

usage() {
    cat <<EOF
run.sh — mpv Lua-OSD GUI verification harness orchestrator

USAGE
  ./run.sh [options] [SCENARIO]

SCENARIOS
$(for s in "${SCENARIOS[@]}"; do printf '  %-12s %s\n' "$s" "$(desc_of "$s")"; done)

OPTIONS
  -s, --script DIR       GUI script dir (dir with main.lua) or a .lua file.
                         Default: ./mpvgui, else <harness>/../../mpvgui
                         (i.e. the repo checkout this harness is vendored in),
                         else $PWD if it holds main.lua.
  -m, --media FILE       override the scenario's default media
      --scenario NAME    scenario to run (same as the positional argument)
      --all              run every scenario in sequence (fresh mpv each time)
      --list             print scenario names + descriptions, exit
  -g, --geometry WxH     requested window size (default 960x540; niri decides
                         the real surface, the harness always re-reads it)
  -t, --timeout SECS     per-wait timeout for helpers (default 10)
      --scenario-timeout SECS   hard cap on one scenario (default 300)
      --extra "MPV ARGS" extra mpv arguments for the orchestrator's instance
      --no-fixtures      do not auto-generate fixtures
      --debug            keep mpv stdout in the log AND echo it at the end
  -h, --help             this help

WHAT HAPPENS
  1. fixtures.sh runs (idempotent) unless media is missing and --no-fixtures.
  2. mpv is started with:
       --no-config --vo=gpu-next --gpu-api=vulkan --gpu-context=waylandvk
       --hwdec=auto --osc=no --input-cursor=yes --geometry=WxH --autofit=WxH
       --script=<script> --force-window=yes --idle=yes --input-ipc-server=<sock>
     (this is the verified 0.41.0 recipe; --autofit keeps niri from tiling the
     window to full screen so pixel coordinates stay predictable)
  3. it waits for time-pos and a *stable* non-zero osd-dimensions surface.
  4. the scenario script runs with these exported:
       HARNESS_BOOTED=1 HARNESS_MPV_PID HARNESS_MPV_SOCK HARNESS_MPV_LOG
       OSD_W OSD_H HARNESS_SCRIPT_DIR HARNESS_MEDIA HARNESS_ARTIFACTS
  5. mpv is always stopped (graceful IPC quit, then SIGTERM) — also on ^C.

EXIT STATUS
  0 = every assertion in the scenario passed, 1 = at least one failed,
  2 = usage/preflight error, 124 = per-scenario hard timeout.
EOF
}

SCRIPT_ARG=""
MEDIA_ARG=""
SCENARIO=""
RUN_ALL=0
DO_FIXTURES=1
DEBUG=0
SCEN_TIMEOUT=300

while [ $# -gt 0 ]; do
    case "$1" in
        -s|--script) SCRIPT_ARG="$2"; shift 2 ;;
        -m|--media) MEDIA_ARG="$2"; shift 2 ;;
        --scenario) SCENARIO="$2"; shift 2 ;;
        --all) RUN_ALL=1; shift ;;
        --list)
            for s in "${SCENARIOS[@]}"; do printf '%-12s %s\n' "$s" "$(desc_of "$s")"; done
            exit 0 ;;
        -g|--geometry) HARNESS_GEOMETRY="$2"; shift 2 ;;
        -t|--timeout) HARNESS_TIMEOUT="$2"; shift 2 ;;
        --scenario-timeout) SCEN_TIMEOUT="$2"; shift 2 ;;
        --extra) HARNESS_MPV_EXTRA="${HARNESS_MPV_EXTRA:+$HARNESS_MPV_EXTRA }$2"; shift 2 ;;
        --no-fixtures) DO_FIXTURES=0; shift ;;
        --debug) DEBUG=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "run.sh: unknown option '$1' (try --help)" >&2; exit 2 ;;
        *) SCENARIO="$1"; shift ;;
    esac
done

export HARNESS_GEOMETRY HARNESS_TIMEOUT

# ------------------------------------------------------------------ preflight
if [ -z "$SCRIPT_ARG" ]; then
    SCRIPT_ARG="$(harness_default_script_dir)" || {
        echo "run.sh: no --script given, and neither ./mpvgui nor $HARNESS_DIR/../../mpvgui contains main.lua" >&2
        echo "        (cwd: $PWD) -- pass --script DIR" >&2
        exit 2
    }
fi
if [ ! -e "$SCRIPT_ARG" ]; then
    echo "run.sh: script path '$SCRIPT_ARG' does not exist" >&2
    exit 2
fi
if [ -d "$SCRIPT_ARG" ] && [ ! -f "$SCRIPT_ARG/main.lua" ]; then
    echo "run.sh: '$SCRIPT_ARG' is a directory without main.lua" >&2
    ls -la "$SCRIPT_ARG" >&2 || true
    exit 2
fi
[ -d "$SCRIPT_ARG" ] || { [ "${SCRIPT_ARG##*.}" = "lua" ] || { echo "run.sh: '$SCRIPT_ARG' is not .lua" >&2; exit 2; }; }

if [ "$RUN_ALL" = 0 ] && [ -z "$SCENARIO" ]; then SCENARIO=smoke; fi
if [ "$RUN_ALL" = 0 ]; then
    found=0
    for s in "${SCENARIOS[@]}"; do [ "$s" = "$SCENARIO" ] && found=1; done
    if [ "$found" = 0 ]; then
        echo "run.sh: unknown scenario '$SCENARIO' (see --list)" >&2
        exit 2
    fi
fi

TIMEOUT_BIN=""
command -v timeout >/dev/null && TIMEOUT_BIN=timeout

if [ "$DO_FIXTURES" = 1 ]; then
    if ! "$HARNESS_DIR/fixtures.sh" >/dev/null 2>"$HARNESS_RUN_DIR/fixtures.err"; then
        echo "run.sh: fixtures.sh failed:" >&2
        cat "$HARNESS_RUN_DIR/fixtures.err" >&2 || true
        exit 2
    fi
fi

media_args_for() { # media_args_for <scenario> -> mpv file args on stdout (newline sep)
    local s="$1"
    local spec="${MEDIA_ARG:-${SCEN_MEDIA[$s]:-white.mp4}}"
    if [ "$spec" = "pl" ] && [ -z "$MEDIA_ARG" ]; then
        local f
        for f in "$HARNESS_MEDIA_DIR"/pl/ep0*.mp4; do
            [ -e "$f" ] && printf '%s\n' "$f"
        done
        return 0
    fi
    case "$spec" in
        /*) printf '%s\n' "$spec" ;;
        *)  printf '%s\n' "$HARNESS_MEDIA_DIR/$spec" ;;
    esac
}

mpv_version() { mpv --version 2>/dev/null | head -n1; }

run_one() { # run_one <scenario> -> scenario rc
    local scen="$1"
    local scen_file="$SCEN_DIR/$scen.sh"
    [ -f "$scen_file" ] || { echo "run.sh: missing scenario file $scen_file" >&2; return 2; }

    local arts="$ARTROOT/$scen"
    rm -rf "$arts"; mkdir -p "$arts"

    local -a files=()
    while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(media_args_for "$scen")
    if [ ${#files[@]} -eq 0 ]; then
        echo "run.sh: no media resolved for scenario '$scen'" >&2
        return 2
    fi
    local i
    for i in "${files[@]}"; do
        [ -e "$i" ] || { echo "run.sh: media '$i' missing (run fixtures.sh)" >&2; return 2; }
    done

    HARNESS_MPV_EXTRA="${HARNESS_MPV_EXTRA_ORIG:-}${SCEN_EXTRA[$scen]:+ ${SCEN_EXTRA[$scen]}}"
    export HARNESS_MPV_EXTRA

    printf '\n=== %s ===  %s\n' "$scen" "$(desc_of "$scen")"
    info "mpv: $(mpv_version)"
    info "media: ${files[*]}"
    info "artifacts: $arts"

    mpv_start "$scen" "$SCRIPT_ARG" "${files[@]}" || return 1
    if ! harness_wait_playback; then
        # don't die() here: give the scenario a chance to diagnose
        diag "orchestrator: playback/surface not ready ($IPC_LAST_ERROR) — running the scenario anyway so it can report precisely"
    fi
    HARNESS_BOOTED=1
    export HARNESS_BOOTED HARNESS_MPV_PID HARNESS_MPV_SOCK HARNESS_MPV_LOG \
        OSD_W OSD_H HARNESS_SCRIPT_DIR="$SCRIPT_ARG" HARNESS_MEDIA="${files[0]}" \
        HARNESS_MEDIA_LIST="$(printf '%s\n' "${files[@]}")" HARNESS_ARTIFACTS="$arts" \
        HARNESS_SCENARIO="$scen"

    local rc=0 cmd=(bash "$scen_file")
    if [ -n "$TIMEOUT_BIN" ]; then
        cmd=("$TIMEOUT_BIN" --signal=INT --kill-after=10 "$SCEN_TIMEOUT" bash "$scen_file")
    fi
    "${cmd[@]}"
    rc=$?
    if [ "$rc" = 124 ] || [ "$rc" = 130 ]; then
        echo "run.sh: scenario '$scen' hit the ${SCEN_TIMEOUT}s hard timeout" >&2
    fi
    if [ "$DEBUG" = 1 ] && [ -n "${HARNESS_MPV_LOG:-}" ] && [ -s "$HARNESS_MPV_LOG" ]; then
        echo "--- mpv log ($HARNESS_MPV_LOG) ---"
        cat "$HARNESS_MPV_LOG"
        echo "--- end mpv log ---"
    fi
    mpv_stop
    HARNESS_MPV_EXTRA="${HARNESS_MPV_EXTRA_ORIG:-}"
    return "$rc"
}

export HARNESS_MPV_EXTRA
HARNESS_MPV_EXTRA_ORIG="${HARNESS_MPV_EXTRA:-}"

if [ "$RUN_ALL" = 1 ]; then
    declare -A RC=()
    overall=0
    for s in "${SCENARIOS[@]}"; do
        run_one "$s"
        RC[$s]=$?
        [ "${RC[$s]}" = 0 ] || overall=1
    done
    printf '\n===== harness summary =====\n'
    for s in "${SCENARIOS[@]}"; do
        if [ "${RC[$s]}" = 0 ]; then
            printf '%sPASS%s  %-12s %s\n' "$c_green" "$c_reset" "$s" "$(desc_of "$s")"
        else
            printf '%sFAIL%s  %-12s (rc=%s) %s\n' "$c_red" "$c_reset" "$s" "${RC[$s]}" "$(desc_of "$s")"
        fi
    done
    exit "$overall"
fi

run_one "$SCENARIO"
rc=$?
printf '\n%s: %s (rc=%s)\n' "$SCENARIO" "$([ "$rc" = 0 ] && echo PASS || echo FAIL)" "$rc"
exit "$rc"
