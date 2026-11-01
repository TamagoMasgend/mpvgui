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
    mkdir -p "$out/share/mpv-gui" "$out/bin" "$out/share/applications"
    cp -r mpvgui "$out/share/mpv-gui/mpvgui"
    # Launcher entry (Walker, rofi, GNOME, KDE, …). Icon=mpv reuses the icon
    # shipped by the mpv we wrap; StartupWMClass matches the window mpv opens.
    # printf keeps the file free of the build script's indentation.
    printf '%s\n' \
      '[Desktop Entry]' \
      'Type=Application' \
      'Version=1.5' \
      'Name=mpv GUI' \
      'GenericName=Media Player' \
      'Comment=mpv with the mpvgui OSD interface (Lua/ASS overlays)' \
      "Exec=$out/bin/mpv-gui %F" \
      'TryExec=mpv-gui' \
      'Icon=mpv' \
      'Terminal=false' \
      'Categories=AudioVideo;Player;Video;Audio;' \
      'Keywords=mpv;gui;video;audio;anime;player;' \
      'StartupNotify=false' \
      'StartupWMClass=mpv' \
      'MimeType=video/mp4;video/x-matroska;video/webm;video/x-msvideo;video/quicktime;video/mpeg;audio/mpeg;audio/flac;audio/ogg;audio/x-wav;' \
      > "$out/share/applications/mpvgui.desktop"
    # Optional shader presets shipped with the repo; the script scans
    # <script dir>/../shaders for *.glsl / *.hook / *.vpy.
    if [ -d shaders ]; then
      cp -r shaders "$out/share/mpv-gui/shaders"
    fi
    makeWrapper ${lib.getExe mpv} "$out/bin/.mpv-gui-wrapped" \
      --add-flags "--osc=no" \
      --add-flags "--input-cursor=yes" \
      --add-flags "--script=$out/share/mpv-gui/mpvgui"
    # Launched with no file (desktop entry, launcher, panel button) mpv would
    # print its usage and exit, i.e. the shortcut appears to do nothing. Fall
    # back to an idle window in that case only, so normal playback keeps mpv's
    # default "exit after the last file" behaviour.
    cat > "$out/bin/mpv-gui" <<EOF
#!${stdenv.shell}
if [ "\$#" -eq 0 ]; then
  set -- --idle=yes --force-window=yes
fi
exec "$out/bin/.mpv-gui-wrapped" "\$@"
EOF
    chmod +x "$out/bin/mpv-gui"
    runHook postInstall
  '';

  meta = {
    description = "Zero-overhead mpv GUI drawn as ASS OSD overlays by a Lua script";
    mainProgram = "mpv-gui";
    platforms = lib.platforms.linux;
  };
}
