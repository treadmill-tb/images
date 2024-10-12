{ }:

with import <nixpkgs> {}; let
  image = callPackage ./default.nix {};

  sdcardQCOW2 = runCommand "treadmill-image-netboot-raspberrypios-nbd-qcow2.sh" {} ''
    ${qemu}/bin/qemu-img convert -f raw -O qcow2 ${image.customizedSDImage} $out
  '';

  kernel8 = image.customizedSDImage.kernel8;
  qemuRpi3Dtb = image.customizedSDImage.qemuBcm2710Rpi3BPlusDtb;

in
  stdenv.mkDerivation {
    name = "run-qemu-vm";
    buildInputs = [pkgs.qemu];

    unpackPhase = "true";

    installPhase = ''
     mkdir -p $out/bin

      ln -s ${image} $out/image

      # Locate the image manifest within the store expression:
      IMAGE_HASH="$(cat "${image}/image.txt")"
      MANIFEST_PATH="${image}/images/''${IMAGE_HASH:0:2}/''${IMAGE_HASH:2:2}/''${IMAGE_HASH:4:2}/$IMAGE_HASH"

      # Extract the name of the "head" blob in the image:
      HEAD_BLOB="$(${dasel}/bin/dasel -f "$MANIFEST_PATH" -r toml -w - '.org\.tockos\.treadmill\.manifest-ext\.base\.attrs.org\.tockos\.treadmill\.image\.nbd_qcow2_layered_v0\.head')"

      # Retrieve the head blob's root disk SHA-256 digest:
      ROOT_BLOB_HASH="$(${dasel}/bin/dasel -f "$MANIFEST_PATH" -r toml -w - '.org\.tockos\.treadmill\.manifest-ext\.base\.blobs.'"$HEAD_BLOB"'-root.org\.tockos\.treadmill\.manifest-ext\.base\.sha256-digest')"
      ROOT_BLOB_PATH="${image}/blobs/''${ROOT_BLOB_HASH:0:2}/''${ROOT_BLOB_HASH:2:2}/''${ROOT_BLOB_HASH:4:2}/$ROOT_BLOB_HASH"

      # Retrieve the tftp boot archive's SHA-256 digest:
      BOOT_BLOB_HASH="$(${dasel}/bin/dasel -f "$MANIFEST_PATH" -r toml -w - '.org\.tockos\.treadmill\.manifest-ext\.base\.blobs.'"$HEAD_BLOB"'-boot.org\.tockos\.treadmill\.manifest-ext\.base\.sha256-digest')"
      BOOT_BLOB_PATH="${image}/blobs/''${BOOT_BLOB_HASH:0:2}/''${BOOT_BLOB_HASH:2:2}/''${BOOT_BLOB_HASH:4:2}/$BOOT_BLOB_HASH"


      cat > $out/bin/run-qemu-vm <<EOF
      #!/bin/sh
      WORKDIR="\$(mktemp -d -t "treadmill-image-XXXXXXXX")"
      echo "Creating image overlay in temporary directory: \$WORKDIR"
      mkdir -p "\$WORKDIR"

      echo "Creating \$WORKDIR/nbd-disk.qcow2 based on $ROOT_BLOB_PATH"
      ${pkgs.qemu}/bin/qemu-img create -b "$ROOT_BLOB_PATH" -F qcow2 -f qcow2 "\$WORKDIR/nbd-disk.qcow2" 2G

      echo "Unpacking boot archive into \$WORKDIR/tftp-boot (from $BOOT_BLOB_PATH)"
      mkdir -p "\$WORKDIR/tftp-boot"
      ${pkgs.gnutar}/bin/tar -xf "$BOOT_BLOB_PATH" -C "\$WORKDIR/tftp-boot/"

      exec ${pkgs.qemu}/bin/qemu-system-aarch64 \\
        -machine raspi3b -cpu cortex-a72 -m 1G -smp 4 \
        -dtb ${qemuRpi3Dtb} \
        -kernel "\$WORKDIR/tftp-boot/kernel8.img" \
        -device sd-card,drive=drive0 -drive id=drive0,if=none,format=qcow2,file="\$WORKDIR/nbd-disk.qcow2" \
        -append "rw earlyprintk loglevel=8 console=ttyAMA0,115200 dwc_otg.lpm_enable=0 root=/dev/mmcblk0 rootdelay=1" \
        -device usb-net,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::2222-:22 \
        -nographic
      EOF
      chmod +x $out/bin/run-qemu-vm
    '';
  }
