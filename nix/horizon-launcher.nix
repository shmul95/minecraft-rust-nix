{ lib, appimageTools, fetchurl, makeWrapper, symlinkJoin }:

let
  pname = "horizon-launcher";
  sources = lib.importJSON ./sources.json;
  version = sources.version;

  src = fetchurl {
    url = sources.url;
    hash = sources.hash;
  };

  # Extracted separately (cheap, content-addressed, independently cached from wrapType2's own
  # internal extraction) purely to source the AppImage's own bundled .desktop file + icon set
  # for a Nix-native static install. Confirmed present at these exact paths by direct
  # --appimage-extract inspection of v0.2.32, 2026-11-02 (see 03-02-PLAN.md's <ground_truth>).
  appimageContents = appimageTools.extractType2 { inherit pname version src; };

  wrapped = appimageTools.wrapType2 {
    inherit pname version src;
    extraPkgs = pkgs: [ ]; # defaultFhsEnvArgs already covers vulkan/alsa/udev/gl/wayland/openssl

    # CR-01 fix (01-REVIEW.md): buildFHSEnv's default auto-mount binds every top-level host
    # dir except /nix /dev /proc /etc read-write, including all of /home, not just the
    # invoking user's $HOME and not just .minecraft. Narrow it: tmpfs over $HOME (deny by
    # default), then explicitly re-bind only the two paths Horizon actually needs. Verified
    # empirically against a live build (2026-11-02): see 03-01-PLAN.md's <ground_truth> block.
    extraPreBwrapCmds = ''
      mkdir -p "$HOME/.local/share/horizon-launcher"
      mkdir -p "''${HORIZON_MINECRAFT_DIR:-$HOME/.minecraft}"
    '';
    # Residual scope: top-level host dirs other than /home (e.g. /mnt, /media) remain fully
    # auto-mounted by buildFHSEnv's default — out of this narrowing's scope (CR-01 specifically
    # flagged /home); $HOME/.config and other XDG dirs are now ephemeral per-run inside the
    # sandbox too (only .minecraft and .local/share/horizon-launcher persist) — this may
    # degrade xdg-open's default-browser detection for the OAuth flow, but does not break the
    # flow itself since the device code + microsoft.com/link URL are always printed to stdout
    # regardless (verified in nix/check-oauth-reachability.sh).
    extraBwrapArgs = [
      "--tmpfs $HOME"
      "--bind \${HORIZON_MINECRAFT_DIR:-$HOME/.minecraft} \${HORIZON_MINECRAFT_DIR:-$HOME/.minecraft}"
      "--bind $HOME/.local/share/horizon-launcher $HOME/.local/share/horizon-launcher"
    ];

    # RUN-03: ship the AppImage's own bundled .desktop + icon set via the Nix-native
    # convention instead of letting the binary run its own `desktop-entry` self-write
    # subcommand. Collision with that self-write is already structurally avoided by 03-01's
    # $HOME narrowing above: the self-write targets $HOME/.local/share/applications, a path
    # intentionally left unbound, so it only ever reaches the sandbox's ephemeral per-run
    # tmpfs — see nix/check-desktop-entry.sh for the empirical proof.
    extraInstallCommands = ''
      install -Dm444 ${appimageContents}/usr/share/applications/horizon-launcher.desktop \
        $out/share/applications/horizon-launcher.desktop
      for size in 16x16 24x24 32x32 48x48 64x64 128x128 256x256 512x512; do
        install -Dm444 ${appimageContents}/usr/share/icons/hicolor/$size/apps/horizon.png \
          $out/share/icons/hicolor/$size/apps/horizon.png
      done
      install -Dm444 ${appimageContents}/usr/share/icons/hicolor/scalable/apps/horizon.svg \
        $out/share/icons/hicolor/scalable/apps/horizon.svg
    '';
  };
in
symlinkJoin {
  inherit pname version; # REQUIRED so .pname/.version resolve on the result (plain `name =` string alone does not set these — plan-checker verified empirically)
  name = "${pname}-${version}";
  paths = [ wrapped ];
  nativeBuildInputs = [ makeWrapper ];
  postBuild = ''
    wrapProgram $out/bin/${pname} \
      --set HORIZON_LAUNCHER_NO_SELF_UPDATE 1 \
      --set HORIZON_LAUNCHER_DESKTOP_EXEC "$out/bin/${pname}"
  '';
  meta = {
    description = "Horizon launcher (Minecraft-in-Rust), packaged via appimageTools.wrapType2";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = pname;
  };
}
