{
  lib,
  stdenv,
  mpv,
  makeWrapper,
}:

# Thin wrapper around the stock mpv binary: the GUI is the Lua script in
# ./mpvgui, drawn entirely as ASS OSD overlays.  No extra window, no extra
# process, no patched mpv.
stdenv.mkDerivation {
  pname = "mpv-gui";
  version = "0.1.0";

  src = lib.cleanSource ../.;

  nativeBuildInputs = [ makeWrapper ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/mpv-gui" "$out/bin"
    cp -r mpvgui "$out/share/mpv-gui/mpvgui"
    # Optional shader presets shipped with the repo; the script scans
    # <script dir>/../shaders for *.glsl / *.hook / *.vpy.
    if [ -d shaders ]; then
      cp -r shaders "$out/share/mpv-gui/shaders"
    fi
    makeWrapper ${lib.getExe mpv} "$out/bin/mpv-gui" \
      --add-flags "--osc=no" \
      --add-flags "--input-cursor=yes" \
      --add-flags "--script=$out/share/mpv-gui/mpvgui"
    runHook postInstall
  '';

  meta = {
    description = "Zero-overhead mpv GUI drawn as ASS OSD overlays by a Lua script";
    mainProgram = "mpv-gui";
    platforms = lib.platforms.linux;
  };
}
