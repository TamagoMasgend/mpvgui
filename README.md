# mpvgui

Playback controls, menus, a playlist panel and shader presets for mpv. The
interface runs as a Lua script inside the player and draws ASS overlays, without
a separate GUI window or persistent GUI process.

This is an independent project, not part of mpv.

## Requirements

- **Nix package:** `x86_64-linux`, with Nix and flakes enabled.
- **Standalone script:** mpv with Lua scripting and a working ASS OSD.

Tested on Linux/Wayland with mpv 0.41.0, Lua 5.2.4 and libplacebo 7.360.1
(`vo=gpu-next`, `gpu-api=vulkan`). Compatibility with other mpv versions, Lua
runtimes and renderers has not been verified.

## Quick start

Run these commands from the checkout root:

```bash
# Packaged (wrapper adds --osc=no --input-cursor=yes --script=<script dir>)
nix run .# -- file.mkv

# Build it, then run the binary from the store path
nix build .# && result/bin/mpv-gui file.mkv

# Without Nix: run the script directory directly
mpv --osc=no --input-cursor=yes --script=./mpvgui file.mkv
```

The package wraps the stock mpv from the pinned nixpkgs, adding `--osc=no`,
`--input-cursor=yes` and `--script=<script dir>`. Your normal mpv configuration
and other scripts still load. With no arguments, `nix run .#` opens an idle
window.

## Controls

Bar, left to right: menu, play/pause, −10 s, +10 s, elapsed/duration, seekbar,
speed, FX, playlist, volume, mute, fullscreen.

| Element | Action |
|---|---|
| Seekbar | Click or drag to seek; hovering shows the target time |
| Volume | Click or drag the slider; wheel over it moves volume by 5 |
| Speed | Cycles 0.5 → 0.75 → 1 → 1.25 → 1.5 → 2 → 0.5 |
| FX | Opens the shader panel |
| Playlist | Opens the playlist panel (click a row to play it) |
| Menu | Opens the menu pages (see below) |
| Mute / Fullscreen | Toggle the mpv property |
| Right click | Toggle pause when no panel is visible; ignored while a panel is visible |

| Key | Action |
|---|---|
| `Tab` | Toggle the playlist panel |
| `Shift+m` | Toggle the menu panel |
| `Shift+x` | Toggle the shader panel |
| `Esc` | Back one menu page; close at the root or in other panels. With no panel: leave fullscreen |
| `g` | Toggle the GUI on/off |

These shortcuts, left click/double-click and the vertical mouse wheel use forced
bindings: they override your `input.conf` mappings, even when the GUI is disabled
with `g`. Fallback actions use mpv's stock commands rather than your remappings.
The script does not assign screenshot (`s`, `S`), audio/subtitle cycling (`#`,
`j`) or aspect cycling (`A`).

## Menu

The menu button or `Shift+m` toggles the menu panel. Opening it starts at the
root page. Click a row to activate it; the header and `Esc` go back one page,
or close the panel at the root.

| Page | Rows |
|---|---|
| Root | Playlist, Chapters, Audio track, Subtitles, Video track, Speed, Aspect ratio, Loop, Tools, Shaders, Fullscreen, Screenshot, Quit |
| Audio track / Video track | Automatic, Off, one row per track (title or language · codec · channels · flags), cycle |
| Subtitles | Automatic, Off, tracks, visibility, cycle, "Add subtitle file…" (see [Known limits](#known-limits)) |
| Chapters | one row per chapter with its start time; click seeks |
| Speed | 0.25×…4×, −0.05/+0.05, reset |
| Aspect ratio | Default, 16:9, 4:3, 1:1, 21:9, 2.35:1 |
| Loop | Off, loop file, loop playlist, shuffle |
| Tools | three screenshot modes, subtitle/audio delay −0.1 s/+0.1 s/reset, zoom ±, reset zoom/pan, rotate 90°, deinterlace cycle, A-B loop set/clear, stop, quit |

Track and chapter rows reflect the current file. Long pages scroll with the
wheel over the panel.

## Shader presets

Paths below use mpv's config directory, `~~/` (normally `~/.config/mpv/`).
Presets live in `~~/mpvgui/shaders.conf`, one named chain per line:

```
sharp = ~~/shaders/my-upscaler.glsl, ~~/shaders/clamp.hook
```

Blank lines and lines beginning with `#` after optional whitespace are ignored;
inline comments are not supported. Chains are comma-separated. Relative entries
are tried as written, relative to mpv's working directory, then under
`~~/mpvgui/`, `~~/`, and the discovery directories:

1. `~~/shaders/`
2. `~~/mpvgui/shaders/`
3. `<script dir>/../shaders/`, if present

Discovery lists individual `.glsl` and `.hook` files without searching
subdirectories. No shader packs are bundled.

Applying an entry sets mpv's `glsl-shaders` property. For recognized compilation
errors reported within five seconds, the GUI restores its previous GUI-selected
chain and shows a toast. A chain configured outside the GUI is not captured as
the rollback target.

The selected entry is saved in `~~/mpvgui/state.json` and restored by name on
startup if it is still available. **A failed apply remains saved even after
rollback:** select a working entry or Off before quitting to avoid restoring the
failed entry next time.

Saving selections and importing files need a writable config directory.
Creating directories uses `mkdir` from `PATH`. Imports copy one file into
`~~/mpvgui/shaders/`, overwriting an existing file with the same basename;
companion files are not copied. The panel's import prompt is currently
unavailable; see [Known limits](#known-limits).

## Automation

The script accepts these mpv commands:

```text
script-message mpvgui-shader <name|off>
script-message mpvgui-import <path>
script-message mpvgui-reset-stats
script-message mpvgui-page <root|chapters|audio|subs|video|speed|aspect|loop|tools|off>
```

They can be sent through mpv input bindings or JSON IPC. For an external IPC
client, enable a socket with mpv's `--input-ipc-server` option; the wrapper does
not enable one by default.

## How it works

Four ASS overlay layers hold the bar background and tracks (`static`), panel
rows (`panel`), icons, labels and fills (`hover`), and tooltips and toasts
(`transient`). A layer is submitted to mpv only when its generated ASS content
changes.

The script handles properties and input events through mpv's Lua API. One
periodic timer refreshes progress at 4 Hz while the bar is visible during
unpaused playback. One-shot timers handle autohide, toasts, shader monitoring
and import/write retries. There is no redraw loop tied to video frames.

## Tests

The black-box harness uses real mpv windows in an existing Wayland session with
a working Vulkan backend. It drives synthetic input over JSON IPC and asserts
on mpv properties and window screenshots. Fixtures are generated on demand.

```bash
nix develop --command bash -c 'tests/harness/run.sh --all'
```

Ten scenarios cover loading, rendering, clicks, dragging, wheel input, playlists,
menus, shaders, robustness and performance.
[VALIDATION.md](tests/harness/VALIDATION.md) records a development-machine run
with all ten scenarios passing and resize checks skipped. Its hidden-idle
measurements show unchanged overlay-update counters, not zero CPU cost.

Logs, sockets and screenshots land in `tests/harness/run/` (gitignored).
See the [harness README](tests/harness/README.md) for scenario coverage and
invocation options.

## Known limits

- The panel's **Import…** and **Add subtitle file…** actions do not open input
  prompts in the packaged build; they show "no input API". Shader import is
  available through [Automation](#automation).
- Input checks use synthetic IPC events; physical clicks and held drags have
  not been verified.
- Resize checks on niri were skipped; compositor-driven resize remains
  unverified.
- `.vpy` files appear in shader discovery but are passed to `glsl-shaders`,
  not loaded as VapourSynth scripts. Use mpv-compatible GLSL hooks.

## License

Project code is MIT licensed; see [LICENSE](LICENSE). mpv and the dev-shell
reference packages, uosc and thumbfast, retain their own licenses.
