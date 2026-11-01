{
  description = "mpv GUI — Path A: stock mpv as the Wayland client, Lua/ASS OSD, JSON IPC";

  # Pinned to the exact nixpkgs revision /etc/nixos is locked to
  # (nixos-unstable 1c89083e451e891152365b799595cf7790a43325), so the dev
  # shell's mpv is the same closure the GUI will run under: mpv 0.41.0,
  # libplacebo 7.360.1, scripting via the embedded Lua 5.2.4 (nixpkgs does
  # *not* build mpv against LuaJIT — the Lua written here must be 5.2-safe and
  # must not assume LuaJIT extensions such as `bit` or `ffi`).
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/1c89083e451e891152365b799595cf7790a43325";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          name = "mpvGUI";

          packages = with pkgs; [
            # --- target runtime (== system build) -------------------------
            mpv # 0.41.0: vo=gpu-next, gpu-api=vulkan, hwdec=auto
            ffmpeg # ffprobe/ffmpeg for fixtures and media probing

            # --- Lua OSD side (embedded Lua 5.2 in mpv) -------------------
            # standalone Lua 5.2 (same version mpv embeds) + luacheck; one
            # package so bin/lua and bin/luacheck agree on the interpreter.
            (lua5_2.withPackages (ps: [ ps.luacheck ]))
            lua-language-server # mp.* API completion; set runtime.version to Lua 5.2
            stylua

            # Reference implementations of the exact architecture in use:
            # ASS/vector OSD drawing (uosc) and a compiled-ish fast thumbnail
            # sidecar over IPC (thumbfast). Read from the store, never fork.
            mpvScripts.uosc
            mpvScripts.thumbfast

            # --- Rust companion binary -----------------------------------
            rustc # 1.99.0
            cargo
            clippy
            rustfmt
            rust-analyzer
            pkg-config
            clang
            sqlite # watch history

            # --- IPC / measurement / debugging ---------------------------
            socat # drive /tmp/mpv-socket by hand
            jq # pretty-print JSON IPC replies
            hyperfine # measure the "0.0% perf loss" claim
            gdb
            strace

            # --- repo hygiene (same set the system config uses) ----------
            git
            curl
            ripgrep
            shellcheck
            nixfmt
            statix
            deadnix
          ];

          # rust-analyzer needs the std sources for doc hovers / goto-def.
          RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";

          shellHook = ''
            echo "mpvGUI dev shell — $(mpv --version | head -n1) | $(lua -v 2>&1) | $(rustc --version)"
          '';
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
