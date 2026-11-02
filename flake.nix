{
  description = "Horizon (Minecraft-in-Rust) launcher, packaged for Nix/NixOS";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux"; # Horizon currently ships Linux x86_64 only
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (pkgs) lib appimageTools symlinkJoin makeWrapper;

      # The real derivation lives in nix/horizon-launcher.nix, which reads
      # version/url/hash exclusively from nix/sources.json (the single-file
      # pin — see nix/update.sh for the bump procedure).
      horizon-launcher = pkgs.callPackage ./nix/horizon-launcher.nix { };

      # --- Diagnostic apps (verification-only utilities for Phase 1, not
      # shipped end-user features — see threat_model T-01-05 in 01-01-PLAN.md).
      # Both reuse appimageTools.defaultFhsEnvArgs so they share the exact
      # same FHS library surface as the real package above.
      #
      # SECURITY NOTE (code review CR-01, 01-REVIEW.md): buildFHSEnv's bubblewrap
      # sandbox is an FHS *compatibility* shim, not a security sandbox — by default
      # it bind-mounts every top-level host dir except /nix /dev /proc /etc
      # (including $HOME) read-write, and does not unshare the network namespace.
      # RESOLVED (Phase 3, 03-01-PLAN.md): the shipped horizon-launcher package
      # (nix/horizon-launcher.nix) now narrows this via extraPreBwrapCmds +
      # extraBwrapArgs — --tmpfs $HOME followed by an explicit --bind of only
      # ${HORIZON_MINECRAFT_DIR:-$HOME/.minecraft} and
      # $HOME/.local/share/horizon-launcher, so it no longer inherits the "bind
      # all of /home" default. The two diagnostic apps below intentionally keep
      # using the full (unnarrowed) defaultFhsEnvArgs FHS env, since they are
      # verification-only utilities that never touch real user state; the new
      # home-passthrough-check app further below reuses the real narrowing args
      # specifically to empirically prove the narrowing works (nix/check-home-passthrough.sh).
      # vulkaninfo-check/env-check need neither network nor $HOME, so they unshare
      # net below as a free hardening win.

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

      # RUN-01 verification probe (03-01-PLAN.md): reuses the SAME
      # extraPreBwrapCmds/extraBwrapArgs narrowing as nix/horizon-launcher.nix's
      # real package above (literal duplication is intentional, matching the
      # existing diagnostic-app convention in this file — standalone
      # verification probes are not meant to share code with the shipped
      # package's derivation module). Proves a decoy file outside the narrowed
      # paths is invisible, and that $HOME/.minecraft (or HORIZON_MINECRAFT_DIR)
      # round-trips reads/writes correctly through the narrowed sandbox.
      homePassthroughCheckEnv = pkgs.buildFHSEnv (
        appimageTools.defaultFhsEnvArgs
        // {
          name = "horizon-launcher-home-passthrough-check";
          extraPreBwrapCmds = ''
            mkdir -p "$HOME/.local/share/horizon-launcher"
            mkdir -p "''${HORIZON_MINECRAFT_DIR:-$HOME/.minecraft}"
          '';
          extraBwrapArgs = [
            "--tmpfs $HOME"
            "--bind \${HORIZON_MINECRAFT_DIR:-$HOME/.minecraft} \${HORIZON_MINECRAFT_DIR:-$HOME/.minecraft}"
            "--bind $HOME/.local/share/horizon-launcher $HOME/.local/share/horizon-launcher"
          ];
          runScript = "${pkgs.writeShellScript "horizon-home-passthrough-check" ''
            MC_DIR="''${HORIZON_MINECRAFT_DIR:-$HOME/.minecraft}"
            echo "RESULT: MC_DIR=$MC_DIR"
            if [ -f "$HOME/secret.txt" ]; then
              echo "RESULT: LEAK_TEST=FAIL"
            else
              echo "RESULT: LEAK_TEST=PASS"
            fi
            if [ -d "$MC_DIR" ]; then
              echo "sandbox-write-ok-$$" > "$MC_DIR/.sandbox-write-probe" \
                && [ "$(cat "$MC_DIR/.sandbox-write-probe")" = "sandbox-write-ok-$$" ] \
                && echo "RESULT: WRITE_TEST=PASS" \
                || echo "RESULT: WRITE_TEST=FAIL"
              ls -A "$MC_DIR" | sed 's/^/RESULT: MC_DIR_ENTRY=/'
            else
              echo "RESULT: WRITE_TEST=FAIL (MC_DIR does not exist)"
            fi
          ''}";
          unshareNet = true;
        }
      );
    in
    {
      packages.${system} = {
        inherit horizon-launcher;
        default = horizon-launcher;
      };

      apps.${system} = {
        default = {
          type = "app";
          program = lib.getExe horizon-launcher;
        };
        vulkaninfo-check = {
          type = "app";
          program = "${vulkaninfoCheckEnv}/bin/horizon-launcher-vulkaninfo-check";
        };
        env-check = {
          type = "app";
          program = "${envCheck}/bin/horizon-launcher-env-check";
        };
        home-passthrough-check = {
          type = "app";
          program = "${homePassthroughCheckEnv}/bin/horizon-launcher-home-passthrough-check";
        };
      };
    };
}
