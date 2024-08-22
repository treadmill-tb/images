{
  pkgs ? import <nixpkgs> {},
  system ? builtins.currentSystem,
  image ? pkgs.callPackage ./default.nix {},
  ...
}: let
  inherit (pkgs) callPackage dasel;
  githubRunner = import ./github-runner.nix {inherit pkgs;};
  overlayedImage = pkgs.vmTools.runInLinuxVM (
    pkgs.runCommand "nixos-sun-baseline-image"
    {
      memSize = 768;
      preVM = ''
        mkdir -p $out

        # Locate the image manifest within the store expression:
        IMAGE_HASH="$(cat "${image}/image.txt")"
        MANIFEST_PATH="${image}/images/''${IMAGE_HASH:0:2}/''${IMAGE_HASH:2:2}/''${IMAGE_HASH:4:2}/$IMAGE_HASH"

        # Extract the name of the "head" blob in the image:
        HEAD_BLOB="$(${dasel}/bin/dasel -f "$MANIFEST_PATH" -r toml -w - '.org\.tockos\.treadmill\.manifest-ext\.base\.attrs.org\.tockos\.treadmill\.image\.qemu_layered_v0\.head')"

        # Retrieve the head blob's SHA-256 digest:
        BLOB_HASH="$(${dasel}/bin/dasel -f "$MANIFEST_PATH" -r toml -w - '.org\.tockos\.treadmill\.manifest-ext\.base\.blobs.'"$HEAD_BLOB"'.org\.tockos\.treadmill\.manifest-ext\.base\.sha256-digest')"
        BLOB_PATH="${image}/blobs/''${BLOB_HASH:0:2}/''${BLOB_HASH:2:2}/''${BLOB_HASH:4:2}/$BLOB_HASH"

        # The below variable is magically picked up and exposed to the VM.
        diskImage=disk.qcow2
        echo "Creating $diskImage based on $BLOB_PATH"
        ${pkgs.qemu}/bin/qemu-img create -b "$BLOB_PATH" -F qcow2 -f qcow2 "$diskImage"
      '';
      postVM = ''
        mkdir -p $out
        cp $diskImage $out/overlay.qcow2
      '';
      buildInputs = [];
    }
    ''
      mkdir -p /mnt
      ${pkgs.mount}/bin/mount /dev/vda2 /mnt
      ls /mnt

      cp -r ${githubRunner} /mnt/opt/gh-actions-runner

      cat > "/mnt/etc/systemd/system/github-runner.service" <<EOF
      [Unit]
      Description=GitHub Actions Runner
      After=network.target

      [Service]
      ExecStartPre=/bin/bash -c 'export REPO_URL=\$(cat /run/tml/parameters/gh-actions-runner-repo-url) && export TOKEN=\$(cat /run/tml/parameters/gh-actions-runner-token) && export JOB_ID=\$(cat /run/tml/job-id) && /opt/gh-actions-runner/config.sh --url \$REPO_URL --token \$TOKEN --name tml-ghactionsrunner-\$JOB_ID --labels tml-ghactionsrunner-\$JOB_ID --unattended --ephemeral'
      ExecStart=/opt/gh-actions-runner/run.sh
      Restart=on-failure
      User=root
      WorkingDirectory=/opt/gh-actions-runner

      [Install]
      WantedBy=multi-user.target
      EOF
    ''
  );
in
  pkgs.stdenv.mkDerivation {
    pname = "new-image-store";
    version = "1.0";
    buildInputs = [image overlayedImage];
    src = ./.;
    buildPhase = ''
      cp ${overlayedImage}/overlay.qcow2 $TMPDIR/overlay.qcow2
    '';

    installPhase = ''
      mkdir -p $out/images
      mkdir -p $out/blobs
      cp -r ${image}/images/* $out/images
      cp -r ${image}/blobs/* $out/blobs

      OVERLAY_BLOB_HASH=$(sha256sum "$TMPDIR/overlay.qcow2" | cut -d' ' -f1)
      OVERLAY_BLOB_PATH="$out/blobs/''${OVERLAY_BLOB_HASH:0:2}/''${OVERLAY_BLOB_HASH:2:2}/''${OVERLAY_BLOB_HASH:4:2}/$OVERLAY_BLOB_HASH"
      mkdir -p "$(dirname "$OVERLAY_BLOB_PATH")"
      mv "$TMPDIR/overlay.qcow2" "$OVERLAY_BLOB_PATH"

      echo "Creating new image manifest..."

      cat > "$out/image_manifest.toml" <<EOF
      manifest_version = 0
      manifest_extensions = [ "org.tockos.treadmill.manifest-ext.base" ]

      "org.tockos.treadmill.manifest-ext.base.label" = "Ubuntu 22.04 with GitHub Actions Runner"
      "org.tockos.treadmill.manifest-ext.base.revision" = 1
      "org.tockos.treadmill.manifest-ext.base.description" = "Base Ubuntu 22.04 with added GitHub Actions Runner service and scripts."

      ["org.tockos.treadmill.manifest-ext.base.attrs"]
      "org.tockos.treadmill.image.qemu_layered_v0.head" = "layer-0"

      ["org.tockos.treadmill.manifest-ext.base.blobs"."layer-0"]
      "org.tockos.treadmill.manifest-ext.base.sha256-digest" = "$OVERLAY_BLOB_HASH"
      "org.tockos.treadmill.manifest-ext.base.size" = $(stat -c%s "$OVERLAY_BLOB_PATH")

      ["org.tockos.treadmill.manifest-ext.base.blobs"."layer-0"."org.tockos.treadmill.manifest-ext.base.attrs"]
      "org.tockos.treadmill.image.qemu_layered_v0.blob-virtual-size" = "10737418240"
      EOF

      # Calculate the SHA256 hash of the image-specific manifest file
      IMAGE_HASH=$(sha256sum $out/image_manifest.toml | cut -d' ' -f1)

      # Create the image-specific directory and move the manifest
      MANIFEST_PATH="$out/images/''${IMAGE_HASH:0:2}/''${IMAGE_HASH:2:2}/''${IMAGE_HASH:4:2}/$IMAGE_HASH"
      mkdir -p "$(dirname "$MANIFEST_PATH")"
      mv $out/image_manifest.toml "$MANIFEST_PATH"
      echo $IMAGE_HASH > "$out/image.txt"
    '';
  }
