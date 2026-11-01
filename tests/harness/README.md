# mpv Lua-OSD GUI verification harness

Black-box verification for an mpv Lua/ASS OSD GUI. Everything runs through real
mpv windows on the current Wayland session, driven over JSON IPC, and asserts on
**mpv properties** (authoritative) and **window screenshots** (pixels).

Nothing here touches the GUI source: the script directory is a parameter, so the
same harness works for any `--script=<dir>` that follows the tiny contract below.

```
<repo>/tests/harness/          (this directory; run everything from <repo>)
├── fixtures.sh          generate tests/harness/media (idempotent)
├── ipc.sh               library: mpv lifecycle, IPC, waits, assertions, log checks
├── img.sh               library: PNG pixel scans (ffmpeg + od + awk, no python)
├── run.sh               orchestrator: preflight -> start mpv -> run a scenario
├── media/               fixtures (generated, gitignored)
├── run/                 sockets, mpv logs, artifacts (gitignored)
├── scenarios/           smoke render click drag wheel playlist shaders robustness perf
└── selftest/            refgui (a small uosc-flavoured GUI), noop, counters.sh
```

## Quick start

Everything must run inside the repo dev shell (mpv 0.41.0, ffmpeg 9.0.2, socat, jq):

```bash
cd <repo>                                            # the checkout root
nix develop --command bash -c 'tests/harness/run.sh smoke'        # default --script: ./mpvgui
nix develop --command bash -c 'tests/harness/run.sh --all'        # everything
nix develop --command bash -c 'tests/harness/run.sh --list'
```

No argument is needed for the GUI under test: `run.sh` defaults to `./mpvgui`,
then to `<harness>/../../mpvgui` (this repo), so it works from any checkout
without absolute paths. `--script DIR` still points it at any other script dir.

Each scenario also runs standalone (it boots its own mpv):

```bash
tests/harness/scenarios/render.sh --script mpvgui --media tests/harness/media/white.mp4
tests/harness/scenarios/click.sh  --script mpvgui --control seek:0.6
tests/harness/scenarios/perf.sh   --script mpvgui --samples 10
tests/harness/scenarios/shaders.sh --script mpvgui   # sets up its own config dir
```

`shaders.sh` is the one scenario that **forces its own mpv** (it passes
`--config-dir`), so `run.sh --all` stops the shared instance before running it.
It generates its fixtures on the fly in `media/shaders/`:

| fixture | what | used for |
|---|---|---|
| `tint-red.hook` / `tint-blue.hook` | `!DESC`-style `sample` hook: `ALPHA 255`, colour `255 0 0` / `0 0 255`, `LUMA mix SRC` | a preset whose effect is visible as the video centre pixel turning red / blue |
| `broken.hook` | same header, body `THIS IS NOT GLSL` | the compile-failure path |
| `<config>/mpv/mpvgui/shaders/discovered-tint.hook` | copy of the red one, dropped in the import dir | "discovered files are listed" |
| `<config>/mpv/mpvgui/shaders.conf` | `name=/abs/path` lines, `#` comments | the preset list |

`--config-dir` is `run/shaders-cfg/mpv` because mpv expands `~~/` to
`--config-dir`, so `~~/mpvgui/shaders.conf` becomes
`run/shaders-cfg/mpv/mpvgui/shaders.conf`. The conf syntax is *probed*, not
assumed: `--conf-style kv` (default: `name=/abs/path.hook` lines, `#` comments)
can be switched to `ini` (`[name]` + `shader=path` sections). If the GUI reads
the file but reports no presets the scenario says so explicitly (`entries list
contains 'tint-red'` fails with the full entry dump), and the conf it wrote is
printed in the evidence at the top of every run.

Every script supports `--help`. Exit codes: `0` all assertions passed, `1` a
failure, `2` usage/preflight error, `124` per-scenario hard timeout.

`run.sh` only accepts its own options (it starts mpv for you). For
scenario-specific flags (`--control`, `--from/--to`, `--samples`, `--panel-*`, …)
call the scenario directly — it boots its own mpv with the same recipe:

```bash
tests/harness/scenarios/perf.sh  --script DIR --samples 3 --idle-samples 2
tests/harness/scenarios/click.sh --script DIR --control seek:0.6 --tol 0.4
```

Harness self-test (no GUI needed):

```bash
nix develop --command bash -c 'tests/harness/run.sh --script tests/harness/selftest/refgui --all'
```

## The contract the harness assumes

1. The GUI is loadable as `mpv --script=<dir>` (i.e. `<dir>/main.lua`).
2. It publishes `user-data/mpvgui/updates` (a counter) once it is alive.
   `smoke.sh` treats its absence as a failure and dumps the whole `user-data`
   tree so you can see what the script actually published.
3. `perf.sh` looks for a `visible` flag and for `updates*` counters; a counter
   whose name matches `idle|hidden` is used for the idle assertion. Anything
   missing is reported, not invented.

## What each scenario means by PASS

| scenario | PASS means |
|---|---|
| `smoke.sh` | script dir/`main.lua` exists, mpv alive, non-zero `osd-dimensions`, `user-data/mpvgui/updates` readable, playback progressing, log free of `Lua error` / `Traceback` / `stack traceback` / `Error in` |
| `render.sh` | a `window` screenshot whose size equals `osd-dimensions`, not all-black, mostly white (fixture check), non-white pixels exist **inside the bottom `--bar-frac` band**, bar span ≥ `--min-span` of the width; the bar bbox and row bands are printed; plus OSD survives a `window-scale` resize (SKIP if niri refuses) |
| `click.sh` | pointer really moved to `(x,y)` (`mouse-pos`), and the asserted property changed: `pause` flipped, or `time-pos` ≈ fraction×duration within `--tol` |
| `drag.sh` | press on the bar seeks to the press position, the release settles at the release position, and (reported) whether intermediate moves moved `time-pos` |
| `wheel.sh` | wheel over the volume box raises `volume` and a wheel-down lowers it; prints which delivery mechanism worked and whether the **GUI** (not mpv's builtin binding) reacted |
| `playlist.sh` | `playlist-count ≥ 2`, `Tab` changes ≥ `--min-changed` pixels inside the panel region, clicking row 2 sets `playlist-pos` to 1 |
| `shaders.sh` | eight parts against an isolated `--config-dir`: the GUI publishes a shader list (`user-data/mpvgui/shaders`, entries = `Off` + presets + discovered files, `count` == `#entries`); a preset apply sets `glsl-shaders` **and** repaints the frame (centre pixel turns red/blue), both via `script-message` and by **clicking the row** in the panel; switching and `off` follow; `mpvgui-import` copies the file into the config dir and appends it to the list; a **broken shader** logs a compile error, is surfaced in the OSD **and** the previous chain is restored; the active preset survives a restart; `updates*` never move while hidden or while the panel is open and untouched |
| `robustness.sh` | four sub-cases (audio-only, idle start + `loadfile`, resize, seek past EOF) each keep mpv alive, keep playback sane and leave the log clean |
| `perf.sh` | `frame-drop-count ≤ --max-drops` (default 0) and, while the bar is hidden and untouched, the `updates*` counters do not move; prints per-second drops / `estimated-vf-fps` / `%CPU` / counters |

Any `Lua error`, `Traceback`, `stack traceback` or `Error in` line in the mpv
log fails the scenario it belongs to (the harness's IPC reconnects legitimately
produce `Write error (Broken pipe)`, which is whitelisted).

## Tuning the coordinates

Geometry is never hardcoded. In order of precedence:

1. **`user-data/mpvgui/layout`** — if the GUI publishes its real geometry, every
   helper (`bar_y0`, `bar_y_center`, `bar_left_x`, `seekbar_x_at`, `seekbar_y`,
   `volume_center_x`, `button_center`, `panel_row_center`, `layout_panel_crop`)
   uses it. Contract (mpvgui v1):

   ```json
   { "w":956, "h":538, "panel_open":false,
     "bar":[x0,y0,x1,y1], "seek":[x0,y0,x1,y1], "volume":[x0,x1],
     "buttons":{"play":[x0,y0,x1,y1], "back":…, "forward":…, "speed":…,
                "playlist":…, "mute":…, "volume":…, "fullscreen":…},
     "panel":[x0,x1,rows_y0,row_h,visible_rows] }        // only while open
   ```

   `playlist.sh` re-reads it after the panel opens, because `panel` only exists
   while it is open.
2. **Fractions** (fallback only), overridable per scenario:

| knob | default | used by |
|---|---|---|
| `--bar-frac` | `0.10` | bar height = 10% of surface height, anchored to the bottom |
| play button x | 3% of width | `click.sh --control play` |
| seekbar span | 5%..85% of width | `click.sh --control seek:F`, `drag.sh` |
| volume box | x = W-60, y = bar centre | `wheel.sh`, `click.sh --control vol` |
| panel region | x ≥ 50% W, y ≤ 60% H, 5 rows | `playlist.sh` |

`--x/--y` (exact pixels) always wins. `smoke.sh` prints the published layout and
`render.sh` prints the detected pixel bbox, so you can cross-check the two.

Override with `--x/--y` (exact pixels) or the fraction flags as soon as you know
the real layout. `render.sh` prints the detected bbox, `playlist.sh` the diff
bbox, so calibrating is one run. `HARNESS_MPV_EXTRA='--osd-font-size=40'` style
extra arguments can be passed with `--extra`.

## Known traps (all verified on this machine, mpv 0.41.0 / niri 26.04)

* **Screenshots**: `mp.commandv("screenshot", path, mode)` is invalid; use IPC
  `{"command":["screenshot-to-file",PATH,"window"]}`. Only `window` mode
  contains the OSD. For an audio-only file or an idle window it produces no
  file — the harness reports that instead of hanging.
* **Surface size**: niri tiles the window, so `--geometry=960x540` can become
  956x538, or the window can jump to the video size. `run.sh` passes
  `--autofit=960x540` as well (stable across all fixture sizes), and
  `harness_shot` asserts `png size == osd-dimensions` and retries up to 4×.
  Never hardcode a resolution: read `osd-dimensions`.
* **`osd-dimensions` starts at 0x0** and can change at any time;
  `ipc_wait_osd` waits for a value that stays constant for 3 samples.
* **`--osd-duration` is 1000 ms.** A script-set OSD that is not re-created
  disappears; an auto-hiding bar must be revealed by hovering. Every
  screenshot is preceded by `harness_reveal_osd` (pointer nudge), and
  `render.sh` retries once before declaring the OSD missing. A GUI that only
  redraws on `time-pos` will therefore look "blank" while paused — that is a
  real bug (the bar vanishes when the user pauses).
* **ASS drawing**: use ONE event per shape and join events with a real `"\n"`.
  Measured on a 960x540 surface (shapes requested at y = 100 / 200 / 300):
  two `\p1..\p0` segments in one event → only the first renders; `\N`-joined
  lines → later shapes are pushed down 40 px each and per-line `\pos` is
  ignored; newline-separated events → exact pixels. Also: every colour tag
  needs its backslash (`\\1c&H...&`, not `1c&H...&`) or libass silently drops
  mangled events. Colours are BGR: `\1c&H0000FF&` = red.
* **Mouse**: `{"command":["mouse",X,Y,BUTTON]}` — `0`=left, `1`=middle,
  `2`=right, `3`=WHEEL_UP, `4`=WHEEL_DOWN (5..7 also decode as WHEEL_DOWN),
  `-1`/omitted = move only. It *does* carry wheel events at the given
  coordinates, so wheel-over-region is testable. `mouse-pos.hover` only turns
  `true` after a real pointer move — always move before asserting hover.
* **Wheel vs builtin binding**: mpv's builtin bindings already map
  WHEEL_UP/DOWN to ±2 volume when no script overrides them, so a volume change
  alone does not prove the GUI handled it; `wheel.sh` reports whether the GUI's
  own counters moved. A script that binds `WHEEL_UP` (even `add_forced_...`)
  suppresses the builtin — verified.
* **Drag cannot be held over IPC.** `keydown MBTN_LEFT` delivers a real `down`
  event, but the *first* subsequent `mouse X Y` makes mpv emit `up`
  (measured: `down`, move → `up`, further moves ignored). `drag.sh` therefore
  drives the honest sequence (down → N moves → up) and finishes the release
  position with one click; it asserts press-seek and settle-at-release and
  reports drag-follow separately (`--strict-follow` enforces it, which needs a
  real pointer via uinput/ydotool). Complex bindings are required to see
  `down`/`up`/`press` (`{complex=true}`); a plain `mouse` click arrives as the
  `press` event.
* **Dropped frames**: `vo-drop-frame-count` and `mistimed-frame-count` are nil
  in 0.41.0; use `frame-drop-count` and `decoder-frame-drop-count`.
* **`playing` is not a property** in 0.41.0 (`property not found`); use
  `pause`, `core-idle`, `eof-reached`, `time-pos`.
* **ffmpeg crop syntax**: this build rejects `crop=WxH+X+Y`; `img.sh` accepts
  either spelling and passes `W:H:X:Y` to ffmpeg.
* **`user-data`**: `get_property user-data` returns the nested map
  (`{"mpvgui":{...}}`); values set from Lua with `set_property_native` keep
  their type. `mp.set_property` only takes strings — a boolean needs
  `set_property_native`.
* **Audio-only / idle**: `screenshot-to-file` yields no file, `vid` is `false`,
  `width`/`height` are null. `robustness.sh` accepts that and asserts on
  liveness + `time-pos` instead.
* **Shader errors are mpv errors, not Lua errors.** A broken `.hook` produces
  `shaderc compile status 'error'`, `vk_compile_glsl(...): VK_ERROR_...` and
  `Failed executing hook, disabling` from libplacebo — none of these contain
  `Lua error`/`Traceback`, so the generic log check stays green. `shaders.sh`
  greps the shader-specific patterns and requires the GUI to surface it.
  Detecting it from Lua needs `mp.enable_messages("error")` plus a
  `log-message` event handler; `--msg-level=all=no,vo=v` makes the grep cheap.
* **`~~/` is `--config-dir`, not `$XDG_CONFIG_HOME`.** Verified:
  `expand-path ~~/mpvgui/shaders.conf` with `--config-dir=$CFG/mpv` resolves to
  `$CFG/mpv/mpvgui/shaders.conf`. Passing `--config-dir=$CFG` instead would put
  the file at `$CFG/mpvgui/shaders.conf`; the harness always passes the mpv
  config root.
* **A chain change is not a frame change.** `glsl-shaders` updates immediately,
  but libplacebo compiles on the next frame and the first compile can take a
  few hundred ms — a fixed `sleep` after the apply is racy (observed: one stale
  white screenshot). `shaders.sh` polls the frame centre with fresh screenshots
  (`wait_pixel`) and reports the colour it settled on.
* **Import is asynchronous**: the implementation creates the import directory
  with a detached `mkdir -p` and retries the write, so the copy can land after
  the script message returns. `shaders.sh` polls for the file (up to 5 s) before
  asserting on the list.
* **A GUI that reverts a failed shader** should restore `glsl-shaders` to the
  previous chain; `shaders.sh` records the chain *before* the broken apply and
  polls until it matches again (5 s), and reports both values when it does not.

## Cleanup guarantees

* Every scenario uses its own socket `run/<name>.sock` and log `run/<name>.log`
  (the `--all` run reuses names, one mpv at a time).
* `ipc.sh` installs `trap _harness_cleanup EXIT INT TERM HUP`; it kills every
  mpv it started (SIGTERM, then SIGKILL after 2 s) and removes the sockets.
* `run.sh` stops its mpv between scenarios (`quit` over IPC, then SIGTERM).
* Every wait is bounded: `--timeout` for helper waits, `--scenario-timeout`
  (default 300 s) around a whole scenario, `timeout` around every socat call.
* `shaders.sh` additionally removes its isolated config dir
  `run/shaders-cfg/` (and the generated `media/shaders/` stays, it is
  idempotent and reusable) unless `--keep-config` is given; the same trap kills
  the *restarted* mpv of the persistence part (it reuses the trap, so a mid-run
  failure in part 6 still leaves nothing running).

## The self-test GUI

`selftest/refgui/main.lua` is a ~330-line uosc-flavoured GUI written only to
validate this harness: bottom bar with play button / seekbar / volume box,
complex `MBTN_LEFT` handling with drag-to-seek, `Tab` playlist panel with 5
rows, wheel over the volume box, redraw on `osd-dimensions` change, and
`user-data/mpvgui/*` counters with idle suppression. It is **not** a template
for the product — it exists so `run.sh --all` has a known-good target.

---

# Validation report: mpvgui v1

See **`VALIDATION.md`** (same directory) for the independent validation of
`mpvgui/`: the exact commands, the literal
PASS/FAIL lines, the per-scenario expected/observed/verdict table, the
published-layout-vs-pixels comparison, the with/without-GUI drag comparison,
the 1 Hz hidden/visible counter series, and the SKIP/UNVERIFIED list
(niri resize, real pointer drag, vo-drag cancellation mechanism, pixel
aesthetics).

Harness changes that came out of that validation:

* `click.sh` now picks the asserted property per control (`time-pos` for
  `seek:F`, `volume` for `vol`) unless `--prop` is given explicitly.
* All geometry helpers prefer `user-data/mpvgui/layout` (`bar`, `seek`,
  `volume`, `buttons.<id>`, `panel`) and fall back to the documented fractions
  only when it is absent; `playlist.sh` re-reads it after opening the panel.
* `drag.sh` gained `--control` (same pointer sequence against a no-op script,
  i.e. mpv without any GUI) and writes its per-step trace to
  `run/drag-trace.txt`.
* `selftest/counters.sh` samples the GUI's `user-data/mpvgui/updates*`
  counters at 1 Hz for 10 s hidden + 10 s visible.
