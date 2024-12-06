{ }: let

  # Pull in fenix to be able to build statically-linked Rust binaries with musl:
  fenix = import (builtins.fetchGit {
    url = "https://github.com/nix-community/fenix.git";
    ref = "refs/heads/main";
    rev = "c1bb57f954601094bfacc2a7ca65551b3f1bcecd";
  }) { };

  treadmillSrc = builtins.fetchGit {
    url = "https://github.com/treadmill-tb/treadmill.git";
    ref = "main";
    rev = "f10874dd456631b46ed0ab2cb2d3cf3c9177a662";
  };

  puppetBuilder = src: rustPlatform': target: rustPlatform'.buildRustPackage {
    pname = "treadmill-puppet";
    version = "0.0.1";

    inherit src;
    buildAndTestSubdir = "puppet";

    cargoLock.lockFile = "${src}/Cargo.lock";
    cargoLock.outputHashes."inquire-0.7.5" = "sha256-iEdsjq4IYYl6QoJmDkPQS5bJJvPG3sehDygefAOhTrY=";

    inherit target;
  };

in {
  inherit fenix treadmillSrc puppetBuilder;
}
