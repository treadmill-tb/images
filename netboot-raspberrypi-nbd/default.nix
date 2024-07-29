{ stdenvNoCC, lib, fetchurl, writeText, writeScript, runCommand, qemu, libraspberrypi, xz, p7zip, lkl }:

let
  nbdClientDeb = fetchurl {
    url = "https://alpha.mirror.svc.schuermann.io/files/treadmill-tb/nbd-client_3.24-1.1_armhf.deb";
    sha256 = "";
  };

in
stdenvNoCC.mkDerivation {
  name = "treadmill-image-netboot-raspberrypios-nbd";

  buildInputs = [
    xz p7zip libraspberrypi qemu lkl
  ];

  src = fetchurl {
    url = "https://downloads.raspberrypi.com/raspios_lite_armhf/images/raspios_lite_armhf-2024-07-04/2024-07-04-raspios-bookworm-armhf-lite.img.xz";
    sha256 = "sha256-35wZLWbTXhzmes3jOltfK4H/AtK5hupS8fbqIR1kahs=";
  };

  unpackPhase = ''
    xz -d --stdout $src > raspios.img
    7z -y x raspios.img 0.fat
    mv 0.fat boot.img
    7z -y x boot.img bcm2710-rpi-3-b-plus.dtb bcm2711-rpi-4-b.dtb kernel8.img overlays/disable-bt.dtbo
    test -f bcm2710-rpi-3-b-plus.dtb
    test -f bcm2711-rpi-4-b.dtb
    test -f kernel8.img
    test -f overlays/disable-bt.dtbo
  '';

  patchPhase = let
    autologinDevices = [ "ttyAMA0" "ttyAMA10" ];

    autologinOverride = targetUser: writeText "autologin-override.conf" ''
      [Service]
      ExecStart=
      ExecStart=-/sbin/agetty --autologin ${targetUser} --noclear %I $TERM
    '';


    autologinEtcPatch = runCommand "autologin-etc-patch" {} (
      lib.concatStringsSep "\n" (
        builtins.map (device: ''
          mkdir -p $out/etc/systemd/system/serial-getty@${device}.service.d/
          cp -L ${autologinOverride "root"} $out/etc/systemd/system/serial-getty@${device}.service.d/override.conf
       '') autologinDevices
      )
    );

    nbdFstab = writeText "fstab" ''
      proc /proc proc defaults 0 0
      # PARTUUID=d28ec40f-01 /boot/firmware vfat defaults 0 2
      /dev/nbd0 / ext4 defaults,remount,noatime,nodiratime 0 1
    '';

    customizeImageScript = writeScript "customize-image.sh" ''
      #!/bin/sh

      set -o xtrace
      set -e

      # Required mountpoint for update-initramfs and cmdline.txt update
      mount /dev/mmcblk0p1 /boot/firmware

      # Update cmdline.txt for nbd boot:
      echo "console=serial0,115200 ip=dhcp root=/dev/nbd0 nbdroot=dhcp,root,nbd0 rootfstype=ext4 fsck.repair=yes rootwait net.ifnames=0 loglevel=7" > /boot/firmware/cmdline.txt

      # Override fstab to mount the nbd volume as root:
      mv /customize-image/fstab /etc/fstab

      # Disable services that fail without /boot/firmware or without an SD card:
      ln -s /dev/null /etc/systemd/system/dphys-swapfile.service
      ln -s /dev/null /etc/systemd/system/rpi-eeprom-update.service
      ln -s /dev/null /etc/systemd/system/userconfig.service
      ln -s /dev/null /etc/systemd/system/systemd-hostnamed.service
      ln -s /dev/null /etc/systemd/system/systemd-logind.service

      # Create a mock firmware directory, in lieu of mounting the actual TFTP
      # boot file system:
      mkdir -p /boot/firmware-mock
      echo "FWLOC=/boot/firmware-mock" > /etc/default/raspberrypi-sys-mods

      # Enable ssh on first boot (picked up by sshswitch.service)
      #
      # Write to both the actual firmware file system and the mock FS, to
      # enable SSHD regardless of which will get mounted.
      touch /boot/firmware/ssh.txt
      touch /boot/firmware-mock/ssh.txt

      # Delete the pre-created pi user:
      userdel -r pi

      # Create a treadmill user in the image and give it password-less sudo:
      useradd -m -u 1000 -s /bin/bash tml
      mv /etc/sudoers.d/010_pi-nopasswd /etc/sudoers.d/010_tml-nopasswd
      sed -i 's/pi/tml/g' /etc/sudoers.d/010_tml-nopasswd

      # Auto-login to the tml user on select serial consoles:
      ${
        lib.concatStringsSep "\n" (
          builtins.map (device: ''
            mkdir -p /etc/systemd/system/serial-getty@${device}.service.d/
            cp /customize-image/autologin-override.conf /etc/systemd/system/serial-getty@${device}.service.d/override.conf
         '') autologinDevices
        )
      }

      # Install nbd-client
      apt install "/customize-image/nbd-client_3.24-1.1_armhf.deb"

      # Delete the customize-image files:
      rm -rf /customize-image

      # Unmount all disk (read-only remount root fs) and force power off.
      # We don't have an init system active:
      umount /boot/firmware

      # This will not work, "mount point is busy":
      #mount -o remount,ro /dev/mmcblk0p2 /

      echo s > /proc/sysrq-trigger
      echo u > /proc/sysrq-trigger

      poweroff -f
    '';
  in
    ''
      # We need to patch the DTB to enable UART console output for the
      # kernel and disable Bluetooth -- that'll hang QEMU. This doesn't
      # touch the DTB in the image itself:
      cp bcm2710-rpi-3-b-plus.dtb bcm2710-rpi-3-b-plus.dtb.cust
      dtmerge bcm2710-rpi-3-b-plus.dtb.cust bcm2710-rpi-3-b-plus.dtb.merged - uart0=on
      mv bcm2710-rpi-3-b-plus.dtb.merged bcm2710-rpi-3-b-plus.dtb.cust
      dtmerge bcm2710-rpi-3-b-plus.dtb.cust bcm2710-rpi-3-b-plus.dtb.merged overlays/disable-bt.dtbo
      mv bcm2710-rpi-3-b-plus.dtb.merged bcm2710-rpi-3-b-plus.dtb.cust

      # Login to shell without password (disabled, running custom init instead
      # which itself enables autologin for the tml user)
      #IMAGEPATH=$PWD/raspios.img
      #pushd ${autologinEtcPatch}
      #cptofs -p -t ext4 -P2 -i "$IMAGEPATH" etc /
      #popd

      # Copy the nbd-client and image customization script in:
      mkdir ./customize-image
      cp -L ${customizeImageScript} ./customize-image/customize.sh
      cp -L ${nbdFstab} ./customize-image/fstab
      cp -L ${autologinOverride "tml"} ./customize-image/autologin-override.conf
      cp -L ${nbdClientDeb} ./customize-image/nbd-client_3.24-1.1_armhf.deb
      cptofs -p -t ext4 -P2 -i raspios.img customize-image /

      # QEMU requires images to be a power of two in size:
      qemu-img resize -f raw ./raspios.img 4G
    '';

  buildPhase = ''
    qemu-system-aarch64 \
      -machine raspi3b -cpu cortex-a72 -m 1G -smp 4 \
      -dtb bcm2710-rpi-3-b-plus.dtb.cust \
      -kernel kernel8.img \
      -device sd-card,drive=drive0 -drive id=drive0,if=none,format=raw,file=raspios.img \
      -append "rw earlyprintk loglevel=8 console=ttyAMA0,115200 dwc_otg.lpm_enable=0 root=/dev/mmcblk0p2 rootdelay=1 init=/customize-image/customize.sh" \
      -nographic
  '';

  installPhase = ''
    mkdir -p $out/

    7z x raspios.img 0.fat
    mkdir bootpart
    pushd bootpart
    7z x ../0.fat
    tar -cvf $out/boot.tar ./
    popd

    7z x raspios.img 1.img
    qemu-img convert -f raw -O qcow2 1.img $out/root.qcow2
  '';
}
