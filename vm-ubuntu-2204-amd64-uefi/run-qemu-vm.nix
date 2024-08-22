{ pkgs ? import <nixpkgs> {},
  enableKVM ? true,
  image ? pkgs.callPackage ./default.nix {},
}:

with pkgs; let
  inherit (pkgs) dasel;
  ovmf = pkgs.OVMF.fd;
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
      HEAD_BLOB="$(${dasel}/bin/dasel -f "$MANIFEST_PATH" -r toml -w - '.org\.tockos\.treadmill\.manifest-ext\.base\.attrs.org\.tockos\.treadmill\.image\.qemu_layered_v0\.head')"

      # Retrieve the head blob's SHA-256 digest:
      BLOB_HASH="$(${dasel}/bin/dasel -f "$MANIFEST_PATH" -r toml -w - '.org\.tockos\.treadmill\.manifest-ext\.base\.blobs.'"$HEAD_BLOB"'.org\.tockos\.treadmill\.manifest-ext\.base\.sha256-digest')"
      BLOB_PATH="${image}/blobs/''${BLOB_HASH:0:2}/''${BLOB_HASH:2:2}/''${BLOB_HASH:4:2}/$BLOB_HASH"


      cat > $out/bin/run-qemu-vm <<EOF
      #!/bin/sh
      WORKDIR="\$(mktemp -d -t "treadmill-image-XXXXXXXX")"
      echo "Creating image overlay and OVMF_VARS in temporary directory: \$WORKDIR"
      mkdir -p "\$WORKDIR"


      echo "Creating \$WORKDIR/disk.qcow2 based on $BLOB_PATH"
      ${pkgs.qemu}/bin/qemu-img create -b "$BLOB_PATH" -F qcow2 -f qcow2 "\$WORKDIR/disk.qcow2" 10G

      exec ${pkgs.qemu}/bin/qemu-system-x86_64 \\
        ${lib.optionalString enableKVM "-enable-kvm"} \\
        -m 2G \\
        -smp 2 \\
        -drive if=pflash,format=raw,readonly=on,file=${ovmf}/FV/OVMF_CODE.fd \\
        -drive if=pflash,format=raw,file="\$WORKDIR/OVMF_VARS.fd" \\
        -device virtio-scsi-pci,id=scsi0 \\
        -drive file="\$WORKDIR/disk.qcow2",id=drive0,format=qcow2,if=none \\
        -device  scsi-hd,drive=drive0,bus=scsi0.0 \\
        -net nic,model=virtio \\
        -net user,hostfwd=tcp::2222-:22 \\
        -fw_cfg name=opt/org.tockos.treadmill.tcp-ctrl-socket,string=10.0.2.2:3859 \\
        -nographic
      EOF
      chmod +x $out/bin/run-qemu-vm
    '';
  }
