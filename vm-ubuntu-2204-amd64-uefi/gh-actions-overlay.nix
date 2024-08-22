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
      passthru.backingImage = image;
    }
    ''
      mkdir -p /mnt
      ${pkgs.mount}/bin/mount /dev/vda2 /mnt
      ls /mnt

      cp -r ${githubRunner} /mnt/opt/gh-actions-runner

      cat > "/mnt/etc/systemd/system/gh-actions-runner.service" <<EOF
      [Unit]
      Description=GitHub Actions Runner
      After=network.target tml-puppet.service
      Requires=tml-puppet.service

      [Service]
      ExecStartPre=/bin/bash -c 'export REPO_URL=\$(cat /run/tml/parameters/gh-actions-runner-repo-url) && export TOKEN=\$(cat /run/tml/parameters/gh-actions-runner-token) && export JOB_ID=\$(cat /run/tml/job-id) && /opt/gh-actions-runner/config.sh --url \$REPO_URL --token \$TOKEN --name tml-ghactionsrunner-\$JOB_ID --labels tml-ghactionsrunner-\$JOB_ID --unattended --ephemeral'
      ExecStart=/opt/gh-actions-runner/run.sh
      Restart=on-failure
      User=root
      WorkingDirectory=/opt/gh-actions-runner

      [Install]
      WantedBy=multi-user.target
      EOF

      # Manually enable the service:
      ln -s /etc/systemd/system/gh-actions-runner.service /mnt/etc/systemd/system/multi-user.target.wants/gh-actions-runner.service
    ''
  );
in
  pkgs.stdenv.mkDerivation {
    pname = "new-image-store";
    version = "1.0";
    buildInputs = [overlayedImage];
    src = ./.;
    installPhase = ''
      mkdir -p $out/images
      mkdir -p $out/blobs
      cp -r ${overlayedImage.backingImage}/images/* $out/images
      cp -r ${overlayedImage.backingImage}/blobs/* $out/blobs

      # Locate the image manifest within the store expression:
      BACKING_IMAGE_HASH="$(cat "${overlayedImage.backingImage}/image.txt")"
      BACKING_MANIFEST_PATH="${overlayedImage.backingImage}/images/''${BACKING_IMAGE_HASH:0:2}/''${BACKING_IMAGE_HASH:2:2}/''${BACKING_IMAGE_HASH:4:2}/$BACKING_IMAGE_HASH"

      # Extract the name of the "head" blob in the image:
      # Backing head blob contains the layer of backing image
      BACKING_HEAD_BLOB="$(${dasel}/bin/dasel -f "$BACKING_MANIFEST_PATH" -r toml -w - '.org\.tockos\.treadmill\.manifest-ext\.base\.attrs.org\.tockos\.treadmill\.image\.qemu_layered_v0\.head')"

      # Retrieve the head blob's SHA-256 digest:
      BACKING_BLOB_HASH="$(${dasel}/bin/dasel -f "$BACKING_MANIFEST_PATH" -r toml -w - '.org\.tockos\.treadmill\.manifest-ext\.base\.blobs.'"$BACKING_HEAD_BLOB"'.org\.tockos\.treadmill\.manifest-ext\.base\.sha256-digest')"
      BACKING_BLOB_PATH="../../../''${BACKING_BLOB_HASH:0:2}/''${BACKING_BLOB_HASH:2:2}/''${BACKING_BLOB_HASH:4:2}/$BACKING_BLOB_HASH"

      OVERLAY_BLOB_HASH=$(sha256sum "${overlayedImage}/overlay.qcow2" | cut -d' ' -f1)
      OVERLAY_BLOB_PATH="$out/blobs/''${OVERLAY_BLOB_HASH:0:2}/''${OVERLAY_BLOB_HASH:2:2}/''${OVERLAY_BLOB_HASH:4:2}/$OVERLAY_BLOB_HASH"

      mkdir -p "$(dirname "$OVERLAY_BLOB_PATH")"
      cp "$(readlink -f "${overlayedImage}/overlay.qcow2")" "$OVERLAY_BLOB_PATH"
      chmod +w "$OVERLAY_BLOB_PATH"
      ${pkgs.qemu}/bin/qemu-img rebase -f qcow2 -F qcow2 -u -b "$BACKING_BLOB_PATH" "$OVERLAY_BLOB_PATH"

      echo "Creating new image manifest..."

      cat "$BACKING_MANIFEST_PATH" > "$TMPDIR/backing_manifest.toml"

      cat > "$out/new_image_manifest.toml" <<EOF
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

      ${dasel}/bin/dasel -f $TMPDIR/backing_manifest.toml put -r toml -t string -v "Ubuntu 22.04 with GitHub Actions Runner" 'org\.tockos\.treadmill\.manifest-ext\.base.label'
      ${dasel}/bin/dasel -f $TMPDIR/backing_manifest.toml put -r toml -t string -v 1 'org\.tockos\.treadmill\.manifest-ext\.base.revision'
      ${dasel}/bin/dasel -f $TMPDIR/backing_manifest.toml put -r toml -t string -v "Base Ubuntu 22.04 with added GitHub Actions Runner service and scripts." 'org\.tockos\.treadmill\.manifest-ext\.base.description'

      BACKING_LAYER_NUMBER=$(echo "$BACKING_HEAD_BLOB" | grep -oP 'layer-\K\d+')
      OVERLAY_LAYER_NUMBER=$((BACKING_LAYER_NUMBER + 1))
      OVERLAY_HEAD_BLOB="layer-$OVERLAY_LAYER_NUMBER"

      ${dasel}/bin/dasel -f $TMPDIR/backing_manifest.toml put -r toml -t string -v "$OVERLAY_HEAD_BLOB" 'org\.tockos\.treadmill\.manifest-ext\.base\.attrs.org\.tockos\.treadmill\.image\.qemu_layered_v0\.head'

      ${dasel}/bin/dasel -f $TMPDIR/backing_manifest.toml put -r toml -t string -v "$OVERLAY_BLOB_HASH" "org\.tockos\.treadmill\.manifest-ext\.base\.blobs.$OVERLAY_HEAD_BLOB.org\.tockos\.treadmill\.manifest-ext\.base\.sha256-digest"
      ${dasel}/bin/dasel -f $TMPDIR/backing_manifest.toml put -r toml -t int -v "$(stat -c%s "$OVERLAY_BLOB_PATH")" "org\.tockos\.treadmill\.manifest-ext\.base\.blobs.$OVERLAY_HEAD_BLOB.org\.tockos\.treadmill\.manifest-ext\.base\.size"
      ${dasel}/bin/dasel -f $TMPDIR/backing_manifest.toml put -r toml -t string -v "10737418240" "org\.tockos\.treadmill\.manifest-ext\.base\.blobs.$OVERLAY_HEAD_BLOB.org\.tockos\.treadmill\.manifest-ext\.base\.attrs.org\.tockos\.treadmill\.image\.qemu_layered_v0\.blob-virtual-size"


      IMAGE_HASH=$(sha256sum "$TMPDIR/backing_manifest.toml" | cut -d' ' -f1)

      MANIFEST_PATH="$out/images/''${IMAGE_HASH:0:2}/''${IMAGE_HASH:2:2}/''${IMAGE_HASH:4:2}/$IMAGE_HASH"
      mkdir -p "$(dirname "$MANIFEST_PATH")"
      mv "$TMPDIR/backing_manifest.toml" "$MANIFEST_PATH"
      echo $IMAGE_HASH > "$out/image.txt"
    '';
  }
