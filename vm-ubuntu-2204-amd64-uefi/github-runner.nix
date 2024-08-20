{
  pkgs ? import <nixpkgs> {},
  runnerVersion ? "2.319.1",
}: let
  runnerUrl = "https://github.com/actions/runner/releases/download/v${runnerVersion}/actions-runner-linux-x64-${runnerVersion}.tar.gz";
in
  pkgs.stdenv.mkDerivation {
    pname = "github-actions-runner";
    version = runnerVersion;

    src = pkgs.fetchurl {
      url = runnerUrl;
      sha256 = "sha256-P277dIihg+KR/Cxih24Uye5zKGQXNzT6zIWhv7F0RGQ=";
    };

    dontUnpack = true;

    installPhase = ''
      mkdir -p $out
      tar -xzf $src -C $out
      chmod -R u+w $out
    '';
  }
