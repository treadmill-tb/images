{
  description = "Treadmill OCI disk images";

  nixConfig = {
    extra-substituters = [ "https://treadmill-tb.cachix.org" ];
    extra-trusted-public-keys = [
      "treadmill-tb.cachix.org-1:ivmCI8wWEGxVE0+599Bwd5wynPFV+Tw+mW6RHzlqxuE="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    treadmill = {
      url = "github:treadmill-tb/treadmill";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        {
          pkgs,
          system,
          ...
        }:
        let
          tml = inputs.treadmill.packages.${system};

          # `build-image.sh` runtime dependencies:
          toolchain = [
            tml.image-util
          ] ++ (with pkgs; [
            qemu-utils
            util-linux
            cloud-utils
            e2fsprogs
            xz
            curl
            jq
            skopeo
            coreutils
            systemd
          ]);
        in
        {
          devShells.default = pkgs.mkShell {
            name = "treadmill-images-shell";
            packages = toolchain ++ (with pkgs; [
              shellcheck
              shfmt
              nixfmt
              taplo
            ]);
          };

          packages = {
            inherit (tml) image-util;
            tml-puppet-x86_64 = tml.tml-puppet-static-x86_64;
            tml-puppet-aarch64 = tml.tml-puppet-static-aarch64;
            tml-caddy-x86_64 = tml.tml-caddy-static-x86_64;
            tml-caddy-aarch64 = tml.tml-caddy-static-aarch64;
          };

          checks = {
            schema =
              pkgs.runCommand "image-schema" { nativeBuildInputs = [ pkgs.jq ]; }
                ''
                  cd ${./.}
                  bash tools/ci/plan.sh --check
                  touch $out
                '';

            shellcheck =
              pkgs.runCommand "shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; }
                ''
                  cd ${./.}
                  shellcheck -x --source-path=SCRIPTDIR \
                    build/build-image.sh build/build-chain.sh tools/ci/plan.sh
                  shellcheck --shell=sh shared/*/provision.sh \
                    shared/treadmill-guest/treadmill-guest.sh images/*/base/provision.sh
                  shellcheck shared/treadmill-guest/expandroot.sh \
                    shared/gha-runner/install-gh-actions-runner.sh
                  touch $out
                '';

            shfmt =
              pkgs.runCommand "shfmt" { nativeBuildInputs = [ pkgs.shfmt ]; }
                ''
                  cd ${./.}
                  shfmt --diff --language-dialect bash --indent 0 \
                    build/build-image.sh build/build-chain.sh build/lib/*.sh \
                    tools/ci/plan.sh
                  shfmt --diff --language-dialect posix --indent 0 \
                    shared/*/provision.sh shared/treadmill-guest/treadmill-guest.sh \
                    images/*/base/provision.sh
                  touch $out
                '';
          };
        };
    };
}
