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

      ln -s ${sdcardQCOW2} $out/sdcard.qcow2

      cat > $out/bin/run-qemu-vm <<EOF
      #!/bin/sh
      WORKDIR="\$(mktemp -d -t "treadmill-image-XXXXXXXX")"
      echo "Creating image overlay and OVMF_VARS in temporary directory: \$WORKDIR"
      mkdir -p "\$WORKDIR"

      echo "Creating \$WORKDIR/sdcard.qcow2 based on ${sdcardQCOW2}"
      ${pkgs.qemu}/bin/qemu-img create -b "${sdcardQCOW2}" -F qcow2 -f qcow2 "\$WORKDIR/disk.qcow2" 16G

      exec ${pkgs.qemu}/bin/qemu-system-aarch64 \\
        -machine raspi3b -cpu cortex-a72 -m 1G -smp 4 \
        -dtb ${qemuRpi3Dtb} \
        -kernel ${kernel8} \
        -device sd-card,drive=drive0 -drive id=drive0,if=none,format=qcow2,file="\$WORKDIR/disk.qcow2" \
        -append "rw earlyprintk loglevel=8 console=ttyAMA0,115200 dwc_otg.lpm_enable=0 root=/dev/mmcblk0p2 rootdelay=1" \
        -device usb-net,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::2222-:22 \
        -nographic
      #  -m 2G \\
      #  -smp 2 \\
      #  -drive if=pflash,format=raw,readonly=on,file=ovmf/FV/OVMF_CODE.fd \\
      #  -drive if=pflash,format=raw,file="\$WORKDIR/OVMF_VARS.fd" \\
      #  -device virtio-scsi-pci,id=scsi0 \\
      #  -drive file="\$WORKDIR/disk.qcow2",id=drive0,format=qcow2,if=none \\
      #  -device  scsi-hd,drive=drive0,bus=scsi0.0 \\
      #  -net nic,model=virtio \\
      #  -net user,hostfwd=tcp::2222-:22 \\
      #  -fw_cfg name=opt/org.tockos.treadmill.tcp-ctrl-socket,string=10.0.2.2:3859 \\
      #  -nographic
      EOF
      chmod +x $out/bin/run-qemu-vm
    '';
  }
