{
  pkgs ? import <nixpkgs> {},
  system ? builtins.currentSystem,
  image ? pkgs.callPackage ./default.nix {},
  ...
}: let
  inherit (pkgs) callPackage dasel lib;

  ghActionsRunnerVersion = "2.321.0";

  ghActionsRunnerHashes = {
    "x64" = "17m248brzj4yai6z093bhs7w0fs5zccl9r7v2rmj7mx4wdyblims";
    "arm64" = "1q9ncc4dmh16iff3xcxxahc0rsbld4ypql21fk8dhmrhsqsmgk32";
  };

  ghActionsRunnerArch = "arm64";

  ghActionsRunnerArchive = builtins.fetchurl {
    url = "https://github.com/actions/runner/releases/download/v${ghActionsRunnerVersion}/actions-runner-linux-${ghActionsRunnerArch}-${ghActionsRunnerVersion}.tar.gz";
    sha256 = ghActionsRunnerHashes."${ghActionsRunnerArch}";
  };

  ghActionsRunnerUnpacked = pkgs.runCommand "gh-actions-runner-linux-${ghActionsRunnerArch}-${ghActionsRunnerArch}-unpack.sh" {} ''
    mkdir -p $out
    ${pkgs.gnutar}/bin/tar -xzf ${ghActionsRunnerArchive} -C $out
  '';

  overlayedImage = pkgs.vmTools.runInLinuxVM (
    pkgs.runCommand "install-gh-actions-runner-vm"
    {
      memSize = 768;
      preVM = ''
        mkdir -p $out

        # Locate the image manifest within the store expression:
        IMAGE_HASH="$(cat "${image}/image.txt")"
        MANIFEST_PATH="${image}/images/''${IMAGE_HASH:0:2}/''${IMAGE_HASH:2:2}/''${IMAGE_HASH:4:2}/$IMAGE_HASH"

        # Extract the name of the "head" blob in the image:
        HEAD_BLOB="$(${dasel}/bin/dasel -f "$MANIFEST_PATH" -r toml -w - '.org\.tockos\.treadmill\.manifest-ext\.base\.attrs.org\.tockos\.treadmill\.image\.nbd_qcow2_layered_v0\.head')"

        # Retrieve the head blob's SHA-256 digest:
        BLOB_HASH="$(${dasel}/bin/dasel -f "$MANIFEST_PATH" -r toml -w - '.org\.tockos\.treadmill\.manifest-ext\.base\.blobs.'"$HEAD_BLOB"'-root.org\.tockos\.treadmill\.manifest-ext\.base\.sha256-digest')"
        BLOB_PATH="${image}/blobs/''${BLOB_HASH:0:2}/''${BLOB_HASH:2:2}/''${BLOB_HASH:4:2}/$BLOB_HASH"

        # The below variable is magically picked up and exposed to the VM.
        diskImage=disk.qcow2
        echo "Creating and expanding $diskImage based on $BLOB_PATH"
        ${pkgs.qemu}/bin/qemu-img create -b "$BLOB_PATH" -F qcow2 -f qcow2 "$diskImage" 4G
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
      ${pkgs.e2fsprogs}/bin/e2fsck -yf /dev/vda
      ${pkgs.e2fsprogs}/bin/resize2fs /dev/vda

      ${pkgs.mount}/bin/mount /dev/vda /mnt
      ls /mnt

      cp -r ${ghActionsRunnerUnpacked} /mnt/opt/gh-actions-runner
      chown 1000:1000 -R /mnt/opt/gh-actions-runner
      chmod u+w -R /mnt/opt/gh-actions-runner

      cat > "/mnt/etc/systemd/system/gh-actions-runner.service" <<EOF
      [Unit]
      Description=GitHub Actions Runner
      After=network.target tml-puppet.service
      Wants=tml-puppet.service

      [Service]
      ExecStartPre=/bin/bash -Eexuo pipefail -c '${lib.concatStringsSep " && " [
        # Services are supposed to use the `runsvc.sh` script, which will be
        # created by another setup script in the repository. We simply copy it
        # manually here.
        #
        # This script is not actually used right now; see below.
        "cp /opt/gh-actions-runner/bin/runsvc.sh /opt/gh-actions-runner/runsvc.sh"
        "chown tml:tml /opt/gh-actions-runner/runsvc.sh"
        # Avoid re-configuring if the runner was already configured:
        "if [ -f /opt/gh-actions-runner/.credentials ]; then exit 0; fi"
        # Avoid configuring if we have a JIT configuration:
        "if [ -f /run/tml/parameters/gh-actions-runner-encoded-jit-config ]; then exit 0; fi"
        # Read the configuration parameters and run the configuration script:
        "REPO_URL=\\\$(cat /run/tml/parameters/gh-actions-runner-repo-url)"
        "RUNNER_TOKEN=\\\$(cat /run/tml/parameters/gh-actions-runner-token)"
        "JOB_ID=\\\$(cat /run/tml/job-id)"
        (lib.concatStringsSep " " [
          "/opt/gh-actions-runner/config.sh"
          "--url \\\$REPO_URL"
          "--token \\\$RUNNER_TOKEN"
          "--name tml-gh-actions-runner-\\\$JOB_ID"
          "--labels tml-gh-actions-runner-\\\$JOB_ID"
          "--unattended"
          "--ephemeral"
        ])
      ]}'
      ExecStartPre=-+/bin/bash /run/tml/parameters/gh-actions-runner-exec-start-pre-sh
      ExecStart=/bin/bash -Eeuo pipefail -c '\
        if [ -f /run/tml/parameters/gh-actions-runner-encoded-jit-config ]; then \
          ${""
            # We should use runsvc.sh here, but it doesn't support the jitconfig
            # option. For now, run.sh seems to work fine as well.
           } \
          echo "Starting GitHub Actions Runner from JIT config"; \
          /opt/gh-actions-runner/run.sh --jitconfig \$(cat /run/tml/parameters/gh-actions-runner-encoded-jit-config); \
        else \
          ${""
            # To have a compatible "KillSignal" to the above, also use run.sh:
           } \
          echo "Starting preconfigured GitHub Actions Runner"; \
          /opt/gh-actions-runner/run.sh; \
        fi'
      Restart=on-failure
      # KillMode=process, for runsvc.sh
      # KillSignal=SIGTERM, for runsvc.sh
      KillSignal=SIGINT # for run.sh
      TimeoutStopSec=5m
      User=tml
      Group=tml
      WorkingDirectory=/opt/gh-actions-runner
      ExecStopPost=-+/bin/bash /run/tml/parameters/gh-actions-runner-exec-stop-post-sh

      [Install]
      WantedBy=multi-user.target
      EOF

      # Manually enable the service:
      ln -s /etc/systemd/system/gh-actions-runner.service /mnt/etc/systemd/system/multi-user.target.wants/gh-actions-runner.service

      cat > /mnt/opt/journal-login-shell <<SCRIPT
      #!/bin/bash
      exec /bin/bash --init-file <(echo 'sudo journalctl -f; . "\$HOME/.bashrc"')
      SCRIPT
      chmod +x /mnt/opt/journal-login-shell
      sed -i -E 's|^(tml:.*):/bin/bash$|\1:/opt/journal-login-shell|' /mnt/etc/passwd
    ''
  );
in
  pkgs.stdenv.mkDerivation {
    name = "image-store";
    buildInputs = [overlayedImage];
    src = ./.;
    installPhase = ''
      mkdir -p $out/images
      mkdir -p $out/blobs
      cp -r ${overlayedImage.backingImage}/blobs/* $out/blobs

      # Locate the image manifest within the store expression:
      BACKING_IMAGE_HASH="$(cat "${overlayedImage.backingImage}/image.txt")"
      BACKING_MANIFEST_PATH="${overlayedImage.backingImage}/images/''${BACKING_IMAGE_HASH:0:2}/''${BACKING_IMAGE_HASH:2:2}/''${BACKING_IMAGE_HASH:4:2}/$BACKING_IMAGE_HASH"

      # Extract the name of the "head" blob in the image:
      # Backing head blob contains the layer of backing image
      BACKING_HEAD_BLOB="$(${dasel}/bin/dasel -f "$BACKING_MANIFEST_PATH" -r toml -w - '.org\.tockos\.treadmill\.manifest-ext\.base\.attrs.org\.tockos\.treadmill\.image\.nbd_qcow2_layered_v0\.head')"

      # Retrieve the head blob's SHA-256 digest:
      BACKING_BLOB_HASH="$(${dasel}/bin/dasel -f "$BACKING_MANIFEST_PATH" -r toml -w - '.org\.tockos\.treadmill\.manifest-ext\.base\.blobs.'"$BACKING_HEAD_BLOB"'-root.org\.tockos\.treadmill\.manifest-ext\.base\.sha256-digest')"
      BACKING_BLOB_VIRTUAL_SIZE="$(${dasel}/bin/dasel -f "$BACKING_MANIFEST_PATH" -r toml -w - '.org\.tockos\.treadmill\.manifest-ext\.base\.blobs.'"$BACKING_HEAD_BLOB"'-root.org\.tockos\.treadmill\.manifest-ext\.base\.attrs.org\.tockos\.treadmill\.image\.nbd_qcow2_layered_v0\.blob-virtual-size')"
      BACKING_BLOB_PATH="../../../''${BACKING_BLOB_HASH:0:2}/''${BACKING_BLOB_HASH:2:2}/''${BACKING_BLOB_HASH:4:2}/$BACKING_BLOB_HASH"

      OVERLAY_BLOB_VIRTUAL_SIZE="$(${pkgs.qemu}/bin/qemu-img info --output=json "${overlayedImage}/overlay.qcow2" | ${pkgs.jq}/bin/jq '."virtual-size"')"
      OVERLAY_BLOB_HASH=$(sha256sum "${overlayedImage}/overlay.qcow2" | cut -d' ' -f1)
      OVERLAY_BLOB_PATH="$out/blobs/''${OVERLAY_BLOB_HASH:0:2}/''${OVERLAY_BLOB_HASH:2:2}/''${OVERLAY_BLOB_HASH:4:2}/$OVERLAY_BLOB_HASH"

      mkdir -p "$(dirname "$OVERLAY_BLOB_PATH")"
      cp "$(readlink -f "${overlayedImage}/overlay.qcow2")" "$OVERLAY_BLOB_PATH"
      chmod +w "$OVERLAY_BLOB_PATH"
      ${pkgs.qemu}/bin/qemu-img rebase -f qcow2 -F qcow2 -u -b "$BACKING_BLOB_PATH" "$OVERLAY_BLOB_PATH"

      echo "Creating new image manifest..."

      cat "$BACKING_MANIFEST_PATH" > "$TMPDIR/backing_manifest.toml"
      ${dasel}/bin/dasel -f $TMPDIR/backing_manifest.toml put -r toml -t string -v "Raspberry Pi OS with GitHub Actions Runner" 'org\.tockos\.treadmill\.manifest-ext\.base.label'
      ${dasel}/bin/dasel -f $TMPDIR/backing_manifest.toml put -r toml -t string -v 1 'org\.tockos\.treadmill\.manifest-ext\.base.revision'
      ${dasel}/bin/dasel -f $TMPDIR/backing_manifest.toml put -r toml -t string -v "" 'org\.tockos\.treadmill\.manifest-ext\.base.description'

      BACKING_LAYER_NUMBER=$(echo "$BACKING_HEAD_BLOB" | grep -oP 'layer-\K\d+')
      OVERLAY_LAYER_NUMBER=$((BACKING_LAYER_NUMBER + 1))
      OVERLAY_HEAD_BLOB="layer-$OVERLAY_LAYER_NUMBER"

      ${dasel}/bin/dasel -f $TMPDIR/backing_manifest.toml put -r toml -t string -v "$OVERLAY_HEAD_BLOB" 'org\.tockos\.treadmill\.manifest-ext\.base\.attrs.org\.tockos\.treadmill\.image\.nbd_qcow2_layered_v0\.head'

      ${dasel}/bin/dasel -f $TMPDIR/backing_manifest.toml put -r toml -t string -v "$OVERLAY_BLOB_HASH" 'org\.tockos\.treadmill\.manifest-ext\.base\.blobs.'"$OVERLAY_HEAD_BLOB"'-root.org\.tockos\.treadmill\.manifest-ext\.base\.sha256-digest'
      ${dasel}/bin/dasel -f $TMPDIR/backing_manifest.toml put -r toml -t int -v "$(stat -c%s "$OVERLAY_BLOB_PATH")" 'org\.tockos\.treadmill\.manifest-ext\.base\.blobs.'"$OVERLAY_HEAD_BLOB"'-root.org\.tockos\.treadmill\.manifest-ext\.base\.size'
      ${dasel}/bin/dasel -f $TMPDIR/backing_manifest.toml put -r toml -t string -v "$OVERLAY_BLOB_VIRTUAL_SIZE" 'org\.tockos\.treadmill\.manifest-ext\.base\.blobs.'"$OVERLAY_HEAD_BLOB"'-root.org\.tockos\.treadmill\.manifest-ext\.base\.attrs.org\.tockos\.treadmill\.image\.nbd_qcow2_layered_v0\.blob-virtual-size'
      ${dasel}/bin/dasel -f $TMPDIR/backing_manifest.toml put -r toml -t string -v "$BACKING_HEAD_BLOB""-root" 'org\.tockos\.treadmill\.manifest-ext\.base\.blobs.'"$OVERLAY_HEAD_BLOB"'-root.org\.tockos\.treadmill\.manifest-ext\.base\.attrs.org\.tockos\.treadmill\.image\.nbd_qcow2_layered_v0\.lower'

      # Rename backing layer's boot archive to overlay boot archive:
      ${pkgs.yq}/bin/tomlq -t '."org.tockos.treadmill.manifest-ext.base.blobs" += {"'"$OVERLAY_HEAD_BLOB"'-boot": ."org.tockos.treadmill.manifest-ext.base.blobs"."'"$BACKING_HEAD_BLOB"'-boot"} | del(."org.tockos.treadmill.manifest-ext.base.blobs"."'"$BACKING_HEAD_BLOB"'-boot")' $TMPDIR/backing_manifest.toml > $TMPDIR/backing_manifest_patched.toml
      mv $TMPDIR/backing_manifest_patched.toml $TMPDIR/backing_manifest.toml

      IMAGE_HASH=$(sha256sum "$TMPDIR/backing_manifest.toml" | cut -d' ' -f1)

      MANIFEST_PATH="$out/images/''${IMAGE_HASH:0:2}/''${IMAGE_HASH:2:2}/''${IMAGE_HASH:4:2}/$IMAGE_HASH"
      mkdir -p "$(dirname "$MANIFEST_PATH")"
      mv "$TMPDIR/backing_manifest.toml" "$MANIFEST_PATH"
      echo $IMAGE_HASH > "$out/image.txt"
    '';
  }
