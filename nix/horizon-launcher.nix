{ lib, appimageTools, fetchurl, makeWrapper, symlinkJoin }:

let
  pname = "horizon-launcher";
  sources = lib.importJSON ./sources.json;
  version = sources.version;

  src = fetchurl {
    url = sources.url;
    hash = sources.hash;
  };

  wrapped = appimageTools.wrapType2 {
    inherit pname version src;
    extraPkgs = pkgs: [ ]; # defaultFhsEnvArgs already covers vulkan/alsa/udev/gl/wayland/openssl
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
