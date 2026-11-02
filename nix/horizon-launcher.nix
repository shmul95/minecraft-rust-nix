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

  # CR-01 fix (01-REVIEW.md): buildFHSEnv's default auto-mount binds every top-level host
  # dir except /nix /dev /proc /etc read-write, including all of /home, not just the
  # invoking user's $HOME and not just .minecraft. Narrow it: tmpfs over $HOME (deny by
  # default), then explicitly re-bind only the two paths Horizon actually needs. Verified
  # empirically against a live build (2026-11-02): see 03-01-PLAN.md's <ground_truth> block.
  #
  # Exported as `homeNarrowingArgs` (via passthru below) rather than duplicated in flake.nix's
  # home-passthrough-check diagnostic app, so the two can never silently drift apart (03-REVIEW.md
  # WR-02). Assumes $HOME is a direct child of /home (e.g. /home/<user>) — a non-standard $HOME
  # (running as root -> /root, or a custom useradd -d outside /home) falls back to the fully-exposed
  # default for its enclosing top-level directory; not handled here (03-REVIEW.md WR-04, tracked
  # follow-up, not re-litigated in this phase).
  homeNarrowingArgs = {
    extraPreBwrapCmds = ''
      for d in "$HOME/.local/share/horizon-launcher" "''${HORIZON_MINECRAFT_DIR:-$HOME/.minecraft}"; do
        case "$d" in
          *" "*) echo "horizon-launcher: refusing to sandbox a path containing a space: $d" >&2; exit 1 ;;
        esac
        mkdir -p "$d"
      done
    '';
    # WR-01 (03-REVIEW.md): these values are spliced unquoted into a bash array by nixpkgs'
    # extraBwrapArgs mechanism — word-splitting/glob risk if $HOME or HORIZON_MINECRAFT_DIR ever
    # contains whitespace/glob chars. The extraPreBwrapCmds guard above fails loudly in that case
    # instead of letting bwrap fail with an opaque argv-parsing error.
    extraBwrapArgs = [
      "--tmpfs $HOME"
      "--bind \${HORIZON_MINECRAFT_DIR:-$HOME/.minecraft} \${HORIZON_MINECRAFT_DIR:-$HOME/.minecraft}"
      "--bind $HOME/.local/share/horizon-launcher $HOME/.local/share/horizon-launcher"
      # Integration-audit fix (v1.0-MILESTONE-AUDIT.md BLOCKER): wrapType2's default script
      # unconditionally does `--chdir "$(pwd)"`. If the invoking shell's cwd is anywhere under
      # the real $HOME other than the two rebind targets above, that path is now an empty
      # tmpfs hole and bwrap fails outright with "Can't chdir" before the binary ever runs —
      # reproduced live via `cd ~/some/project && nix run .#default`. bwrap takes the LAST
      # --chdir on its argv, so appending one more here (to $HOME itself, which the tmpfs
      # mount above guarantees always exists) overrides the caller-cwd default and makes the
      # launcher start regardless of the invoking shell's working directory.
      "--chdir $HOME"
    ];
  };

  wrapped = appimageTools.wrapType2 (
    {
      inherit pname version src;
      extraPkgs = pkgs: [ ]; # defaultFhsEnvArgs already covers vulkan/alsa/udev/gl/wayland/openssl
    }
    // homeNarrowingArgs
    // {
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
    }
  );
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
  # Exposed so flake.nix's home-passthrough-check diagnostic app can reuse the exact
  # same narrowing args instead of a hand-duplicated copy (03-REVIEW.md WR-02).
  passthru.homeNarrowingArgs = homeNarrowingArgs;
}
