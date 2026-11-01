# mpvgui

A GUI for mpv that adds no window, no process and no per-frame work: stock mpv
stays the only Wayland client, and the entire interface — bar, seekbar, panels,
clickable menus, tooltips — is drawn as ASS overlays by a Lua script through
`mp.create_osd_overlay("ass-events")`, driven over mpv's JSON IPC.

mpv's own keys are untouched: everything the GUI adds is reachable with the
mouse, and every feature mpv had before (screenshot, subtitle/audio cycling,
aspect cycling, …) still works from the keyboard.

Nothing is forked: uosc and thumbfast appear in the dev shell as reference
implementations only. This is not an official mpv project.

## How it works

- Four OSD layers, split by how often they change: `static` (bar background and
  tracks), `panel` (playlist/shader rows and the menu pages), `hover` (icons,
  labels, fills, title) and `transient` (seek/volume tooltip). A repaint touches
  only the layers whose inputs changed.
- Updates are event driven. The single timer is a 4 Hz seekbar sampler, and it
  only ticks while the bar is visible during playback.
- Idle costs nothing: hidden for 10 s, all five update counters stay flat
  (measured in `tests/harness/VALIDATION.md`).
- Measured on the dev machine (`tests/harness/scenarios/perf.sh`): 10 s of
  1080p60 playback, 0 frame drops, `estimated-vf-fps` 60.0 throughout, ~5 GUI
  updates/s with the bar visible. A full 30-element redraw at 60 Hz costs about
  5% of one core, which is why nothing redraws per video frame.

## Requirements

- Linux with a GPU-rendering mpv: **mpv 0.41** with libplacebo (`vo=gpu-next`,
  tested with `gpu-api=vulkan`). Lua 5.2 is what mpv embeds; the script avoids
  LuaJIT-only extensions.
- For the packaged path: Nix with flakes.
- For the script path: any mpv 0.41, plus the usual font/OSD setup.

## Quick start

```bash
# Packaged (wrapper adds --osc=no --input-cursor=yes --script=<script dir>)
nix run .# -- file.mkv

# Build it, then run the binary from the store path
nix build .# && result/bin/mpv-gui file.mkv

# Without Nix: run the script directory directly
mpv --osc=no --input-cursor=yes --script=./mpvgui file.mkv
```

`nix run .#`/`nix build .#` use the stock `mpv` from nixpkgs pinned in
`flake.nix`, so no patched player is involved.

## Controls

Bar, left to right: play/pause, −10 s, +10 s, seekbar, elapsed/duration, speed,
FX, playlist, **menu**, volume, mute, fullscreen.

| Element | Action |
|---|---|
| Seekbar | Click or drag to seek; hovering shows the target time |
| Volume | Click or drag the slider; wheel over it moves volume by 5 |
| Speed | Cycles 0.5 → 0.75 → 1 → 1.25 → 1.5 → 2 → 0.5 |
| FX | Opens the shader panel |
| Playlist | Opens the playlist panel (click a row to play it) |
| Menu | Opens the menu pages (see below) |
| Mute / Fullscreen | Toggle the mpv property |
| Right click | Outside an open panel: mpv's default (toggle pause) |

| Key | Action |
|---|---|
| `Tab` | Toggle the playlist panel |
| `Shift+m` | Toggle the menu panel |
| `Shift+x` | Toggle the shader panel |
| `Esc` | Back one menu page / close the panel; with no panel: mpv's default (`set fullscreen no`) |
| `g` | Toggle the GUI on/off |

Every other key stays bound to mpv's defaults — `S` is still "screenshot video",
`s` "screenshot", `#`/`j` cycle audio/subtitles, `A` cycles aspect, and so on.

## Menu

One click on the bar's menu button (or `Shift+m`) opens the root page; the value
column on the right always shows the current state. Rows are clicked, the panel
header goes back one page, `Esc` closes.

| Page | Rows |
|---|---|
| Root | Playlist, Chapters, Audio track, Subtitles, Video track, Speed, Aspect ratio, Loop, Tools, Shaders, Fullscreen, Screenshot, Quit |
| Audio track / Video track | Automatic, Off, one row per track (title or language · codec · channels · flags), cycle |
| Subtitles | the same, plus subtitle visibility, "Add subtitle file…", cycle |
| Chapters | one row per chapter with its start time; click seeks |
| Speed | 0.25×…4×, −0.05/+0.05, reset |
| Aspect ratio | Default, 16:9, 4:3, 1:1, 21:9, 2.35:1 |
| Loop | Off, loop file, loop playlist, shuffle |
| Tools | three screenshot modes, subtitle/audio delay −0.1 s/+0.1 s/reset, zoom ±, reset zoom/pan, rotate 90°, deinterlace cycle, A-B loop set/clear, stop, quit |

Track and chapter rows come straight from mpv's `track-list` / `chapter-list`, so
they follow the file. Long pages scroll with the wheel over the panel.

## Shader presets

Presets live in `~/.config/mpv/mpvgui/shaders.conf`, one per line:

```
sharp = ~/.config/mpv/shaders/my-upscaler.glsl, ~/.config/mpv/shaders/clamp.hook
```

`#` starts a comment. Each entry of the comma-separated chain is resolved
against the config dir and against the discovery directories:

1. `~/.config/mpv/shaders/`
2. `~/.config/mpv/mpvgui/shaders/` (where **Import…** copies files)
3. `<script dir>/../shaders/` (packs shipped next to the script)

Single `.glsl`, `.hook` and `.vpy` files found there are listed on their own.
Applying a preset is one `glsl-shaders` property set; mpv recompiles on the next
frame. If the compile fails, the GUI restores the previous chain and shows a
toast. The chosen entry is stored in `~/.config/mpv/mpvgui/state.json` and
re-applied on the next start.

Scriptable over IPC: `script-message mpvgui-shader <name|off>`,
`script-message mpvgui-import <path>`, `script-message mpvgui-reset-stats`,
`script-message mpvgui-page <root|chapters|audio|subs|video|speed|aspect|loop|tools|off>`.

## Tests

Black-box harness: real mpv windows on the current Wayland session, driven over
JSON IPC, asserting on mpv properties and window screenshots. Fixtures are
generated on demand.

```bash
nix develop --command bash -c 'tests/harness/run.sh --all'
```

Ten scenarios: `smoke`, `render`, `click`, `drag`, `wheel`, `playlist`, `menu`,
`shaders`, `robustness`, `perf` — all pass on the test machine. `menu.sh` drives
the real click path on a fixture with two audio tracks, two subtitle tracks and
three chapters (`media/tracks.mkv`, generated by `fixtures.sh`). Logs, sockets
and screenshots land in `tests/harness/run/` (gitignored); details in
`tests/harness/README.md` and `tests/harness/VALIDATION.md`.

## Known limits

- Real pointer drag (physical press/hold) is untested — the harness can only
  inject synthetic IPC events.
- No shader packs are bundled: bring your own `.glsl`/`.hook` files or import
  them from the panel.
- niri tiles the window, so geometry is read from `osd-dimensions` rather than
  assumed; the resize path is untested on that compositor.

## License

MIT — see `LICENSE`. Third-party names mentioned here (mpv, uosc, thumbfast,
Anime4K) belong to their respective owners and their code is not bundled.
