{
  description = "Horizon (Minecraft-in-Rust) launcher, packaged for Nix/NixOS";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  outputs =
    { self, nixpkgs }:
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
      };
    in
    {
      packages.${system} = {
        inherit horizon-launcher;
        default = horizon-launcher;
      };

      apps.${system}.default = {
        type = "app";
        program = "${horizon-launcher}/bin/${pname}";
      };
    };
}
