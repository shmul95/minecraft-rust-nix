{
  description = "Horizon (Minecraft-in-Rust) launcher, packaged for Nix/NixOS";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  outputs =
    { nixpkgs, self, ... }:
    let
      system = "x86_64-linux"; # Horizon currently ships Linux x86_64 only
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (pkgs)
        lib
        appimageTools
        symlinkJoin
        makeWrapper
        ;

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

      # RUN-01 verification probe (03-01-PLAN.md): reuses the real package's
      # homeNarrowingArgs via passthru (not a hand-duplicated copy — 03-REVIEW.md
      # WR-02 flagged the original literal-duplication approach as a drift risk).
      # Proves a decoy file outside the narrowed paths is invisible, and that
      # $HOME/.minecraft (or HORIZON_MINECRAFT_DIR) round-trips reads/writes
      # correctly through the exact same narrowed sandbox the shipped package uses.
      homePassthroughCheckEnv = pkgs.buildFHSEnv (
        appimageTools.defaultFhsEnvArgs
        // horizon-launcher.homeNarrowingArgs
        // {
          name = "horizon-launcher-home-passthrough-check";
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
            HORIZON_HOME_DIR="''${HORIZON_HOME:-$HOME/.local/share/horizon}"
            echo "RESULT: HORIZON_HOME_DIR=$HORIZON_HOME_DIR"
            if [ -d "$HORIZON_HOME_DIR" ]; then
              echo "sandbox-write-ok-$$" > "$HORIZON_HOME_DIR/.sandbox-write-probe" \
                && [ "$(cat "$HORIZON_HOME_DIR/.sandbox-write-probe")" = "sandbox-write-ok-$$" ] \
                && echo "RESULT: HORIZON_HOME_WRITE_TEST=PASS" \
                || echo "RESULT: HORIZON_HOME_WRITE_TEST=FAIL"
              ls -A "$HORIZON_HOME_DIR" | sed 's/^/RESULT: HORIZON_HOME_DIR_ENTRY=/'
            else
              echo "RESULT: HORIZON_HOME_WRITE_TEST=FAIL (HORIZON_HOME_DIR does not exist)"
            fi
          ''}";
          unshareNet = true;
        }
      );

      # Quick-task probe (261105-o0f): proves the four native-build deps the launcher's
      # "Native build of Horizon" check enumerates resolve inside a live FHS sandbox run.
      # Reuses the real package's toolchain list via passthru (03-REVIEW.md WR-02 anti-drift),
      # so this probe can never silently diverge from what the shipped package provides.
      nativeBuildDepsCheckEnv = pkgs.buildFHSEnv (
        appimageTools.defaultFhsEnvArgs
        // {
          name = "horizon-launcher-native-build-deps-check";
          targetPkgs =
            pkgs: (appimageTools.defaultFhsEnvArgs.targetPkgs pkgs) ++ (horizon-launcher.nativeBuildToolchainPkgs pkgs);
          runScript = "${pkgs.writeShellScript "horizon-native-build-deps-check" ''
            fails=0
            command -v cc >/dev/null 2>&1 && echo "RESULT: CC_TEST=PASS" || { echo "RESULT: CC_TEST=FAIL"; fails=$((fails+1)); }
            command -v pkg-config >/dev/null 2>&1 && echo "RESULT: PKG_CONFIG_BIN_TEST=PASS" || { echo "RESULT: PKG_CONFIG_BIN_TEST=FAIL"; fails=$((fails+1)); }
            pkg-config --exists alsa 2>/dev/null && echo "RESULT: ALSA_PC_TEST=PASS" || { echo "RESULT: ALSA_PC_TEST=FAIL"; fails=$((fails+1)); }
            pkg-config --exists libudev 2>/dev/null && echo "RESULT: UDEV_PC_TEST=PASS" || { echo "RESULT: UDEV_PC_TEST=FAIL"; fails=$((fails+1)); }
            [ -f /usr/include/alsa/asoundlib.h ] && echo "RESULT: ALSA_HEADER_TEST=PASS" || { echo "RESULT: ALSA_HEADER_TEST=FAIL"; fails=$((fails+1)); }
            [ -f /usr/include/libudev.h ] && echo "RESULT: UDEV_HEADER_TEST=PASS" || { echo "RESULT: UDEV_HEADER_TEST=FAIL"; fails=$((fails+1)); }
            [ "$fails" -eq 0 ] && echo "RESULT: NATIVE_BUILD_DEPS_OVERALL=PASS" || echo "RESULT: NATIVE_BUILD_DEPS_OVERALL=FAIL"
          ''}";
          unshareNet = true;
        }
      );

      # --- Install app (shipped end-user feature): `nix run [github:<owner>/minecraft-rust]#install`
      # persistently installs the wrapped launcher into the invoking user's default Nix
      # profile (the profile entry doubles as the GC root). Embeds self.outPath so the
      # exact flake source being invoked is what gets installed — identically from a
      # GitHub ref, a rev-pinned ref, or a local `nix run .#install`. The re-run path
      # (remove-then-install, deliberately NOT `nix profile upgrade`) is justified
      # empirically in 261105-k7p-PLAN.md <ground_truth> items 3-4: on Nix 2.34.7 a
      # colliding `install` is a silent no-op (no error, no upgrade), and `upgrade`
      # re-resolves the recorded `path:/nix/store/...` ref which can never reach a newer
      # source and breaks after GC. Scope: installs this package only (binary + .desktop
      # entry + icons) — never Minecraft game assets, sign-in state, or config files.
      installScript = pkgs.writeShellScript "horizon-launcher-install" ''
        set -eu
        if nix profile list 2>/dev/null | grep -q 'Name:.*horizon-launcher'; then
          nix profile remove horizon-launcher
        fi
        nix profile install "${self.outPath}#horizon-launcher"
        echo "Horizon launcher installed: horizon-launcher is on your PATH and \"Horizon\" appears in your app menu."
        echo "Sign in happens inside the launcher via Microsoft device-code."
      '';
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
        install = {
          type = "app";
          program = "${installScript}";
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
        native-build-deps-check = {
          type = "app";
          program = "${nativeBuildDepsCheckEnv}/bin/horizon-launcher-native-build-deps-check";
        };
      };

      # MAINT-01: a packaging-tool shell for anyone hacking on this flake, not a
      # Horizon-development shell — no Rust/Cargo/JDK, since this project never
      # builds Horizon from source (see PROJECT.md Out of Scope).
      devShells.${system}.default = pkgs.mkShell {
        name = "horizon-launcher-maintainer-shell";
        packages = [
          pkgs.jq # used by nix/update.sh to parse `nix store prefetch-file --json`
          pkgs.curl # fetching/inspecting upstream release metadata by hand
          pkgs.patchelf # debugging the wrapped binary's ELF interpreter/RPATH directly
          pkgs.shellcheck # lints nix/*.sh (update.sh, check-*.sh)
          pkgs.nixfmt-rfc-style # Nix formatter (`nix fmt` via the formatter output below)
        ];
      };

      formatter.${system} = pkgs.nixfmt-rfc-style;

      # MAINT-02/MAINT-04: offline/sandboxed checks run by `nix flake check`. None of
      # these invoke network — network-requiring scripts (check-self-update.sh,
      # check-home-passthrough.sh, check-oauth-reachability.sh) stay separate,
      # manually-run apps.${system}.* entries above, unchanged.
      checks.${system} = {
        # MAINT-02: "the package builds" — reuse the exact same derivation shipped as
        # packages.${system}.default so `nix flake check` building this check IS the build check.
        build = horizon-launcher;

        # MAINT-02: desktop-file-validate on the installed, Nix-shipped .desktop entry.
        # Offline-safe: only inspects a file already present in horizon-launcher's own output.
        desktop-file-validate =
          pkgs.runCommand "horizon-launcher-desktop-file-validate"
            {
              nativeBuildInputs = [ pkgs.desktop-file-utils ];
            }
            ''
              desktop-file-validate ${horizon-launcher}/share/applications/horizon-launcher.desktop
              touch $out
            '';

        # MAINT-04: static, build-time closure inspection — confirms no Mojang-owned
        # Minecraft-asset-named store path ever lands in the world-readable Nix store.
        # Uses pkgs.closureInfo (pure-Nix primitive), NOT `nix path-info` — the latter needs
        # Nix daemon/socket access unavailable inside a sandboxed check derivation's build.
        no-mojang-assets-in-closure =
          pkgs.runCommand "horizon-launcher-no-mojang-assets-in-closure"
            {
              closureInfo = pkgs.closureInfo { rootPaths = [ horizon-launcher ]; };
            }
            ''
              if grep -iE 'mojang|minecraft' "$closureInfo/store-paths"; then
                echo "FAIL: closure contains a store path name matching Mojang/Minecraft asset patterns" >&2
                exit 1
              fi
              touch $out
            '';
      };
    };
}
