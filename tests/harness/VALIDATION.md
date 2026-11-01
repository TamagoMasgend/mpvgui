# Validation report: mpvgui v1

Independent verification of the GUI in `mpvgui/` (5 modules + `nix/package.nix`).
**The GUI sources were not modified** — every run takes the script directory as a
parameter. All paths below are relative to the repo root (`<repo>`), and every
command runs from there; the harness itself lives in `tests/harness/`.

All commands were executed inside the repo dev shell (mpv 0.41.0 / libplacebo
7.360.1 / Lua 5.2.4, ffmpeg 9.0.2, niri 26.04, Wayland surface sizes as reported
at runtime: 956x538 for the `white.mp4` fixture, 960x540 for
`video1080p60.mp4`, 1920x1080 in one run where niri gave the window the whole
column — nothing in the harness is hardcoded).

The runs below were originally made from a scratch copy of this harness before it
was vendored into `tests/harness/`; the scripts are byte-identical apart from the
path defaults (only the default `--script` changed, from `./mpvgui` to
`./mpvgui`, then `<harness>/../../mpvgui`), and file paths are shown relative to
the repo root.

```bash
cd <repo>
nix develop --command bash -c '<command>'
```

## Harness fixes made before validating

| # | Fix | Evidence |
|---|---|---|
| 1 | `click.sh --control seek:F` selected `time-pos` into an unused `PROP_DEFAULT` and kept reading `pause`. Now the control presets set the property **only if the user did not pass `--prop`**, and `--control vol` asserts a volume change. | repro `--control seek:0.5 --x 471 --y 512` now reports `before: time-pos = 1.000000` / `PASS click seek: time-pos after click: 3.965000 within 0.6 of 4.000` (previously it asserted on `pause`) |
| 2 | Geometry is now driven by the GUI's published `user-data/mpvgui/layout`, with the old fractions only as a fallback (`layout_arr_csv` / `layout_n` / `layout_btn_*` / `panel_row_center` / `layout_panel_crop`). `playlist.sh` re-reads it after the panel opens (the `panel` key only exists while open). | every scenario prints `layout: bar=7,495,953,533 seek=188,495,759,533 volume=829,898 buttons=back,forward,fullscreen,mute,play,playlist,speed,volume` |
| 3 | `drag.sh` traces were collected in a subshell (`TP=$(sample x)`) and were always empty; they now go to `run/drag-trace.txt`. Added `--control` (boots `selftest/noop`, i.e. mpv without the GUI) and `--strict-follow`. | trace tables below |
| 4 | Quoting bug: `$(layout_q ".bar|…")` inside double-quoted `info` strings silently produced empty values (nested `"`); replaced with quoting-safe accessors. | smoke now prints the full layout |
| 5 | New `scenarios/shaders.sh`: `--config-dir` must be the **mpv** config root (`mpv` expands `~~/` to it), so the presets land at `~~/mpvgui/shaders.conf`. Verified with `expand-path`: `~~/mpvgui/shaders.conf` → `run/shaders-cfg/mpv/mpvgui/shaders.conf`. | part 0 lists 6 entries (Off + 3 presets + 1 discovered + Import…), i.e. the conf *and* the import dir were read |
| 6 | `shaders.sh` asserted pixels after a fixed `0.4 s` sleep, which raced libplacebo's compile: one run produced 3 FAILs (`RGB (255 255 255)` still white), the next 0. Replaced with `wait_pixel` (fresh screenshot every 200 ms, ≤6 s). | three consecutive runs: 38 PASS / 0 FAIL each |
| 7 | `wait_chain_len` used `local want=… t=… deadline=$((SECONDS + ${t%.*}))`; bash expands all words *before* assigning, so `${t}` was the (unset) outer variable and `set -u` aborted the scenario. Split into two statements. | the scenario reached part 7 instead of dying at line 202 |
| 8 | Negative test: `shaders.sh` against `selftest/noop` (a script that publishes nothing) must fail fast with a diagnostic, never hang. | `2.35 s`, `rc=1`: `FAIL shader contract missing: user-data/mpvgui/shaders is not published`, parts 1–7 `SKIP` with "needs user-data/mpvgui/shaders + mpvgui-shader/mpvgui-import", log still checked |

## Results — `run.sh --script ./mpvgui --all`

```
===== harness summary =====
PASS  smoke        script loads, log clean, user-data/mpvgui/updates readable
PASS  render       window screenshot has OSD pixels (bar bbox) over white.mp4
PASS  click        synthetic click on a control -> expected property change
PASS  drag         seekbar drag: time-pos follows and settles at the release point
PASS  wheel        wheel over the volume area changes volume
PASS  playlist     Tab opens a panel; clicking row 2 changes playlist-pos
PASS  shaders      shader presets: apply/switch/off, import, compile failure, persistence, cost
PASS  robustness   audio-only, idle start, resize, seek past EOF: no script errors
PASS  perf         10s of 1080p60: frame drops, vf-fps, CPU, GUI update counters
```

Wall time 128.74 s, 105 PASS lines, 2 SKIPs (both the niri resize check, see below),
no mpv process or socket left behind. `shaders.sh` stops the shared mpv and boots
its own with `--config-dir` (see "Shader chains" below).

## Scenario table

| scenario | expected | observed | verdict |
|---|---|---|---|
| `smoke.sh --extra '--force-window=yes'` | script loads, `updates` readable, clean log, playback advances | osd 956x538, `updates=8`, map with 9 keys, `time-pos 1.666667 -> 2.133333`, log clean (58 lines) | **PASS** |
| `render.sh` | window screenshot == osd size, not black, mostly white, OSD pixels inside the bar band, bar spans ≥40% width | png 960x540; mean luma 241.23 (min 48, max 255); 36745 non-white px; bar band (bottom 38 px) holds 35900 px spanning 946 px (99% of width); extra OSD bands y=10..20 (title) and y=471..488 (tooltip) | **PASS** |
| `click.sh --control play` | click play → `pause` flips | click at (20,514) = centre of published play button [7,495,33,533]; `pause` false → true | **PASS** |
| `click.sh --control seek:0.5 --x 471 --y 512` | `time-pos` ≈ 0.5·duration | 1.000 → **3.965 s** (expected 4.000, tol 0.6); layout prediction (471−188)/(759−188)·8 = 3.965 | **PASS** (fix 1 verified) |
| `drag.sh --strict-follow` | press-seek, 4 moves all follow, settle at release | see trace below: 1.200 → 2.483 → 3.783 → 5.083 → 6.400, release 6.400 | **PASS** |
| `drag.sh --control` (no GUI) | no following | see trace below: 1.2167 frozen through all 4 moves and the release click | **PASS** (control) |
| `wheel.sh` | wheel over volume slider changes `volume` | wheel-up ×3 at (863,514) = centre of published volume slider [829,898]: 50 → **65** (+5/event); wheel-down ×3: 65 → 50; GUI counters moved (`updates` +, `updates_hover` +) so the GUI handled it, not mpv's builtin | **PASS** |
| `playlist.sh` | Tab paints the panel region; row 2 click sets `playlist-pos` | published panel `x0=637 x1=956 rows_y0=26 row_h=48 rows=10`; diff inside crop `319x506+637+0` = **161291 px**; row 2 at (796,98) = 26+1.5·48; `playlist-pos 0 -> 1` | **PASS** (10 rows, not 5 — read from the layout) |
| `robustness.sh` | 4 sub-cases, no script errors | audio-only: aid=1, vid=false, `time-pos 0.045823 -> 0.489715`, surface 956x538 via `--force-window`; idle start: alive 2 s with no file, `loadfile` works, surface 960x540; resize: **SKIP** (niri refused `window-scale` 0.40/0.30/0.60 and fullscreen); seek past EOF: alive, EOF unloads the file → `loadfile` resumes at 0.500; all four logs clean | **PASS** (1 SKIP) |
| `perf.sh --samples 10` | drops 0, idle-hidden updates 0 | drops 0/0, `estimated-vf-fps` 60.000000 throughout, avg mpv CPU **15.2%** (12-18% per second), `updates` 18 -> 71 (+53 -> **5.3/s** while the bar is visible and the pointer is nudged once per second), idle phase `updates` 82 -> 82 with every layer delta 0 | **PASS** |
| `shaders.sh` | presets apply/switch/off with a visible frame change, import, broken shader reverted, persistence, zero idle cost | 35 assertions, see the shader section below | **PASS** |

### Drag, with the GUI loaded (`--strict-follow`)

```
press  (273,514) -> expected 1.200s      release(644,514) -> expected 6.400s  steps=4
trace (run/drag-trace.txt):
  press   time-pos=1.200000 mouse-pos.x=273
  move1@365 time-pos=2.483333 mouse-pos.x=365
  move2@458 time-pos=3.783333 mouse-pos.x=458
  move3@551 time-pos=5.083333 mouse-pos.x=551
  move4@644 time-pos=6.400000 mouse-pos.x=644
  release time-pos=6.400000 mouse-pos.x=644
PASS  press-seek at 0.15 of the bar: 1.200000 within 0.60 of 1.200
PASS  settled at the release point (0.80): 6.400000 within 0.60 of 6.400
PASS  drag-follow: 4 intermediate move(s) moved time-pos
```

### Drag, control run without the GUI (`--control`, `selftest/noop` script)

```
press  (163,513) -> expected 1.200s      release(662,513) -> expected 6.400s  steps=4
trace (run/drag-trace.txt):
  press   time-pos=1.216667 mouse-pos.x=163
  move1@287 time-pos=1.216667 mouse-pos.x=287
  move2@412 time-pos=1.216667 mouse-pos.x=412
  move3@537 time-pos=1.216667 mouse-pos.x=537
  move4@662 time-pos=1.216667 mouse-pos.x=662
  release time-pos=1.216667 mouse-pos.x=662
  release-click time-pos=1.216667 mouse-pos.x=662
PASS  control (no GUI): time-pos did not follow the pointer (1.216667s -> 1.216667s)
      control: 7/7 samples reported a pointer x
```

**Difference, stated explicitly:** with the GUI, every one of the four pointer
moves re-seeks the playhead (2.48 → 3.78 → 5.08 → 6.40 s) and the release lands
exactly on the release coordinate; without the GUI, the same IPC event stream
leaves `time-pos` frozen at 1.2167 s — the only time-pos change there came from
mpv's built-in `MBTN_LEFT = cycle pause` on the initial press (the file had been
paused by the scenario), which the release click toggles back. So the GUI's
mouse handling is what makes drag-follow work over IPC (claim **CONFIRMED** for
the observable behaviour). Note the mechanism named in the implementer's report
— "mouse areas stop mpv's built-in vo-dragging" — is **UNVERIFIED**: mpv
auto-releases a synthetically held button on the first pointer-position command,
so no held-drag/vo-drag path can engage in *either* run; `mouse-pos.x` was
delivered in 7/7 samples with and without the GUI.

## Shader chains (`scenarios/shaders.sh`)

Three consecutive runs of the new scenario against `./mpvgui` (the shader
feature landed between my first poll and this run: `mpvgui/shaders.lua`,
10.5 KB, publishes `user-data/mpvgui/shaders`, registers `mpvgui-shader` /
`mpvgui-import`). Results were identical, so this is not a one-off:

```bash
nix develop --command bash -c 'tests/harness/scenarios/shaders.sh --script ./mpvgui'
# 38 PASS  0 FAIL  0 SKIP   wall 45 s   (run 3 times, identical verdicts)
```

The scenario builds its own isolated config dir, so nothing of the real GUI
config is touched:

```
config dir: run/shaders-cfg            (removed at exit unless --keep-config)
  mpv/mpvgui/shaders.conf              # tint-red=<abs>, tint-blue=<abs>, broken=<abs>
  mpv/mpvgui/shaders/discovered-tint.hook
media/shaders/{tint-red,tint-blue,broken}.hook
```

| part | assertion | observed |
|---|---|---|
| 0 | the GUI publishes a shader list; `count` is a number and equals `#entries` | `{"active":"Off","count":6,"entries":[Off(off),tint-red(preset),tint-blue(preset),broken(preset),discovered-tint.hook(file),Import…(import)]}` |
| 1 | baseline has no chain; the **FX button** in the published layout opens the panel; `Shift+S` toggles it; the list names the presets and the discovered file | `glsl-shaders []`, centre `255 255 255`; FX `[774,495,800,533]` → click → diff `161909 px` in the right column, `panel_open=true`; `Shift+S` → `panel_open=false`; entries contain `off/tint-red/tint-blue/discovered-tint` |
| 1b | **clicking a row** applies that preset (the panel's own interaction, not `script-message`) and clicking `Off` clears it | panel `[640,960]`, `rows_y0=26 row_h=48 visible_rows=10`; row 1 at `(800,98)` → `[".../tint-red.hook"]`, centre `255 0 0`; row 0 at `(800,50)` → `[]` |
| 2 | applying a preset sets `glsl-shaders` **and** repaints | `[".../tint-red.hook"]`, centre `255 255 255 → 255 0 0` (tol 12) |
| 3 | switching preset; `off` clears | `[".../tint-blue.hook"]`, centre `0 0 255`; `off` → `[]`, centre back to `255 255 255` |
| 4 | `mpvgui-import <file>` copies into the config dir and the file appears in the list | copied to `run/shaders-cfg/mpv/mpvgui/shaders/imported-tint.hook` within 100 ms; entries grow to 7; applying it sets the chain and paints `255 0 0` |
| 5 | a **broken** shader: mpv logs the compile error, the GUI surfaces it, the chain is restored, no Lua error | `shaderc compile status 'error' (1 errors, 0 warnings)` + `vk_compile_glsl(...): VK_ERROR_INITIALIZATION_FAILED`; OSD diff `1393 px` at `bbox x0=368 y0=33 x1=592 y1=52` (top centre = toast); `glsl-shaders` before == after (`imported-tint.hook`); log clean |
| 6 | the active preset survives a restart with the same config dir | before quit `tint-blue`; after restart `[".../tint-blue.hook"]` and `shaders.active = "tint-blue"` |
| 7 | hidden and idle cost nothing | bar hidden after 3 s; 10 × 1 s samples: `updates`, `updates_static`, `updates_hover`, `updates_panel`, `updates_transient` deltas **all 0**; `frame-drop-count 0 → 0`; panel open + untouched for 5 s: **no** counter moved |

The implementation-specific parts are *probed*, not assumed: the conf syntax
(`name=path`, `#` comments — the scenario can also write `name: path` or JSON),
the entry shape (`{name,kind,active}`, files by basename) and the message names
are read back from the GUI's own publication, and the scenario dumps the entry
JSON on failure instead of guessing.

## Idle-zero claim: independent 1 Hz evidence (`selftest/counters.sh`)

No interaction for 10 s, then one 1-pixel pointer nudge per second for 10 s:

```
# HIDDEN phase
   t  visible    updates  counters
  1s    false         62  updates=62 updates_static=4 updates_hover=58 updates_panel=0 updates_transient=0
  2s    false         62  ... (identical for 2s..10s)
 10s    false         62  updates=62 updates_static=4 updates_hover=58 updates_panel=0 updates_transient=0

# VISIBLE phase
   t  visible    updates  counters
  1s     true         71  updates=71 updates_static=5 updates_hover=66 updates_panel=0 updates_transient=0
  2s     true         76  ...
  3s     true         82  ...
  4s     true         88  ...
  5s     true         93  ...
  6s     true         99  ...
  7s     true        104  ...
  8s     true        109  ...
  9s     true        115  ...
 10s     true        120  updates=120 updates_static=5 updates_hover=115 updates_panel=0 updates_transient=0
```

* hidden: `visible=false` and **zero** counter movement for 10 consecutive
  samples — all five counters (`updates`, `updates_static`, `updates_hover`,
  `updates_panel`, `updates_transient`).
* visible: **+49 updates / 10 s = 4.9/s** (`updates_hover` +49, `updates_static`
  +1), consistent with the 4 Hz tick plus one hover repaint per nudge. perf.sh
  measured 5.3/s with the same nudge pattern.

## Does the published layout match the pixels?

| element | published (`user-data/mpvgui/layout`) | measured from the screenshot / behaviour | verdict |
|---|---|---|---|
| bar | `[7,495,953,533]` (956x538 surface) | non-white bbox of the bar band `x0=7 y0=495 x1=952 y1=532` (inclusive) = exclusive 953/533; 38 rows tall | **match** |
| bar on the other surface | `[7,493,949,531]` (960x540 surface) | same offset pattern, 38 rows | **match** |
| seekbar | `[188,495,759,533]` | click at x=471 → 3.965 s; `(471−188)/(759−188)·8 s = 3.965 s` | **match to 3 decimals** |
| volume slider | `[829,898]` | wheel at x=863 (the published centre) changes volume 50 -> 65 -> 50 and the GUI counters move | **match (centre is over the slider)** |
| play button | `[7,495,33,533]` | click at (20,514) (published centre) toggles `pause` | **match** |
| panel | `[637,956,26,48,10]` while open | row 2 at (796,98) = `26+1.5·48` selects `playlist-pos=1`; panel diff bbox is inside `x≥637` | **match** |

## SKIP / UNVERIFIED (not invented as passes)

| item | status | why |
|---|---|---|
| resize robustness (niri) | **SKIP** | niri refused `window-scale` 0.40/0.30/0.60 and the fullscreen fallback did not change the surface; the OSD-redraw-on-resize path is exercised only by `render.sh`'s own resize attempt (also skipped on this compositor) |
| "mouse areas stop mpv's built-in vo-dragging" | **UNVERIFIED** | mpv releases a synthetic button on the first pointer move, so the vo-drag path cannot engage in either arm of the experiment; the *effect* the claim is about (drag-follow) is verified |
| real pointer drag (physical press/hold) | **SKIP** | needs uinput/ydotool; only synthetic IPC events are available |
| pixel aesthetics (colours, contrast, alignment, font) | **UNVERIFIED** | the harness only decides "OSD present / changed / where", not whether it looks right |
| `decoder-frame-drop-count` | 0 observed, not asserted | informational |
| audio-only *surface* | **PASS with `--force-window=yes`** | with the flag the audio-only file gets a 956x538 surface, `aid=1`, `vid=false`, playback advances and the log stays clean; no run without the flag was made, so "audio-only needs force-window" is NOT verified here |
| shader *visual quality* (does the chain look right, shader order, hook phases) | **UNVERIFIED** | `shaders.sh` asserts that a chain is loaded, that it changes the frame and that a broken chain is reverted; whether a real upscaler chain looks correct is out of scope |
| shader list ordering (presets before files) | **UNVERIFIED** | the published list is used as-is; the scenario only requires the entries to be *present* |

## Cleanup

Every scenario's trap (`trap _harness_cleanup EXIT INT TERM HUP`) killed its mpv
and removed its socket; verified afterwards:

```
$ pgrep -cf 'mpv --no-config'      # -> 0
$ ls tests/harness/run/*.sock   # -> none
```
