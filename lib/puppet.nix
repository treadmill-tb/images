{ }: let

  # Pull in fenix to be able to build statically-linked Rust binaries with musl:
  fenix = import (builtins.fetchGit {
    url = "https://github.com/nix-community/fenix.git";
    ref = "refs/heads/main";
    rev = "667e3751a708b886bb67879147f71c07b0014c7f";
  }) { };

  treadmillSrc = builtins.fetchGit {
    url = "https://github.com/treadmill-tb/treadmill.git";
    ref = "main";
    rev = "eda5c55a0915f31f3698adac5eb613b5eaefa47c";
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
