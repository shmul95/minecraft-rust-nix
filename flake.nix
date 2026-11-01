{
  description = "Horizon (Minecraft-in-Rust) launcher, packaged for Nix/NixOS";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux"; # Horizon currently ships Linux x86_64 only
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (pkgs) appimageTools symlinkJoin makeWrapper;

      pname = "horizon-launcher";
      version = "0.2.32";
      src = ./horizon-launcher-linux-x86_64.AppImage; # LOCAL FILE this phase only — fetchurl is PKG-04/Phase 2

      # Derivation defined inline (not split into nix/horizon-launcher.nix) per
      # CONTEXT.md "Claude's Discretion" — the nix/ module split is the Phase 2+
      # target shape, not a Phase 1 requirement.
      wrapped = appimageTools.wrapType2 {
        inherit pname version src;
        extraPkgs = pkgs: [ ]; # defaultFhsEnvArgs already covers vulkan/alsa/udev/gl/wayland/openssl — do not hand-list libraries
      };

      horizon-launcher = symlinkJoin {
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
          license = pkgs.lib.licenses.mit;
          platforms = [ "x86_64-linux" ];
          mainProgram = pname;
        };
      };

      # --- Diagnostic apps (verification-only utilities for Phase 1, not
      # shipped end-user features — see threat_model T-01-05 in 01-01-PLAN.md).
      # Both reuse appimageTools.defaultFhsEnvArgs so they share the exact
      # same FHS library surface as the real package above.
      #
      # SECURITY NOTE (code review CR-01, 01-REVIEW.md): buildFHSEnv's bubblewrap
      # sandbox is an FHS *compatibility* shim, not a security sandbox — by default
      # it bind-mounts every top-level host dir except /nix /dev /proc /etc
      # (including $HOME) read-write, and does not unshare the network namespace.
      # This means horizon-launcher and these diagnostics already have full $HOME
      # + network access today, not merely from Phase 3 onward as 01-01-PLAN.md's
      # threat model T-01-03 incorrectly assumed. vulkaninfo-check needs neither
      # network nor $HOME, so it unshares net below as a free hardening win. The
      # real horizon-launcher package needs both (MS OAuth, ~/.minecraft in Phase 3)
      # and is tracked as a Phase 3 input to scope down deliberately rather than
      # inherit the "bind all of /home" default silently.

      vulkaninfoCheckEnv = pkgs.buildFHSEnv (
        appimageTools.defaultFhsEnvArgs
        // {
          name = "horizon-launcher-vulkaninfo-check";
          targetPkgs = pkgs: (appimageTools.defaultFhsEnvArgs.targetPkgs pkgs) ++ [ pkgs.vulkan-tools ];
          runScript = "vulkaninfo";
          unshareNet = true;
        }
      );

      envCheckBase = pkgs.buildFHSEnv (
        appimageTools.defaultFhsEnvArgs
        // {
          name = "horizon-launcher-env-check";
          # Filtered to HORIZON_* only (not a bare `env`) — buildFHSEnv does not
          # clear the host environment, so an unfiltered dump would leak any
          # secrets exported in the invoking shell (review finding WR-01).
          runScript = "${pkgs.writeShellScript "horizon-env-check" ''
            env | grep '^HORIZON_'
          ''}";
          unshareNet = true;
        }
      );

      envCheck = symlinkJoin {
        name = "horizon-launcher-env-check-wrapped";
        paths = [ envCheckBase ];
        nativeBuildInputs = [ makeWrapper ];
        postBuild = ''
          wrapProgram $out/bin/horizon-launcher-env-check \
            --set HORIZON_LAUNCHER_NO_SELF_UPDATE 1
        '';
      };
    in
    {
      packages.${system} = {
        inherit horizon-launcher;
        default = horizon-launcher;
      };

      apps.${system} = {
        default = {
          type = "app";
          program = "${horizon-launcher}/bin/${pname}";
        };
        vulkaninfo-check = {
          type = "app";
          program = "${vulkaninfoCheckEnv}/bin/horizon-launcher-vulkaninfo-check";
        };
        env-check = {
          type = "app";
          program = "${envCheck}/bin/horizon-launcher-env-check";
        };
      };
    };
}
