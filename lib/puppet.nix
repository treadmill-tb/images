{ }: let

  # Pull in fenix to be able to build statically-linked Rust binaries with musl:
  fenix = import (builtins.fetchGit {
    url = "https://github.com/nix-community/fenix.git";
    ref = "refs/heads/main";
    rev = "0900ff903f376cc822ca637fef58c1ca4f44fab5";
  }) { };

  treadmillSrc = builtins.fetchGit {
    url = "https://github.com/treadmill-tb/treadmill.git";
    ref = "main";
    rev = "86f7ec7066ee0832a35b57774902200f91f82632";
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
