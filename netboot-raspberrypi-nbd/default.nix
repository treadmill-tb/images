{ lib
, bash
, coreutils
, fetchurl
, writeText
, writeScript
, runCommand
, qemu
, libraspberrypi
, xz
, p7zip
, lkl
, pkgsCross
, gnutar
, tree
, jq
}:

let
  puppet = import ../lib/puppet.nix { };

  nbdClientDeb = fetchurl {
    url = "https://alpha.mirror.svc.schuermann.io/files/treadmill-tb/nbd-client_3.24-1.1_arm64.deb";
    sha256 = "sha256-SM5aIKwFqggjqzlJlZQr6tj1UfkA5f+VmrW//m/yJtk=";
  };

  rustupInit = builtins.fetchurl {
    url = "https://alpha.mirror.svc.schuermann.io/files/treadmill-tb/2024-08-21_rustup-init_aarch64-unknown-linux-musl";
    sha256 = "sha256:0r6c2xk03bfylqfq21xx8akh6jl08qd408q3iq6a09yd0slsv1vh";
  };

  raspberryPiOSImage = fetchurl {
    urls = [
      "https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2024-07-04/2024-07-04-raspios-bookworm-arm64-lite.img.xz"
      "https://alpha.mirror.svc.schuermann.io/files/treadmill-tb/2024-07-04_raspios-bookworm-arm64-lite.img.xz"

    ];
    sha256 = "sha256-Q9FQ55AVg5GeTrHw+oP+A2OvLR6Xd6W7cH1pbVNeJZk=";
  };

  puppetAarch64Musl = src: let
    crossPkgs = pkgsCross.aarch64-multiplatform;
    rust = puppet.fenix.combine (with puppet.fenix; [
      stable.rustc
      stable.cargo
      targets.aarch64-unknown-linux-musl.stable.rust-std
    ]);
    rustPlatform = crossPkgs.pkgsStatic.makeRustPlatform {
      rustc = rust;
      cargo = rust;
    };
  in
    puppet.puppetBuilder src rustPlatform "aarch64-unknown-linux-musl";

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

    # Normally done by init system:
    mkdir -p /proc /sys
    mount -t proc proc /proc
    mount -t sysfs sysfs /sys

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

    # Expand root partition on first boot
    mv /customize-image/expandroot.sh /opt/expandroot
    chmod +x /opt/expandroot
    touch /firstboot-expandroot
    cat > /etc/systemd/system/firstboot-expandroot.service <<SERVICE
    [Install]
    WantedBy=multi-user.target
    [Unit]
    ConditionPathExists=/firstboot-expandroot
    [Service]
    Type=simple
    ExecStart=/opt/expandroot
    ExecStartPost=/bin/rm /firstboot-expandroot
    SERVICE
    ln -s /etc/systemd/system/firstboot-expandroot.service /etc/systemd/system/multi-user.target.wants/firstboot-expandroot.service

    # Delete the pre-created pi user:
    userdel -r pi

    # Create a treadmill user in the image and give it password-less sudo:
    useradd -m -u 1000 -s /bin/bash tml
    usermod -a -G plugdev tml
    usermod -a -G tty tml
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

    # Move the puppet daemon to /opt, autostart and always restart on exit:
    mkdir -p /opt
    mv /customize-image/tml-puppet /usr/local/bin/tml-puppet
    # Type=notify: Only report as started after connected to supervisor
    # NotifyAccess=main: Don't accept status updates from child processes
    cat > /etc/systemd/system/tml-puppet.service <<SERVICE
    [Install]
    WantedBy=multi-user.target
    [Unit]
    After=network.target
    StartLimitIntervalSec=0
    [Service]
    Type=notify
    NotifyAccess=main
    ExecStartPre=/bin/mkdir -p /run/tml/parameters /home/tml/.ssh
    ExecStartPre=/usr/bin/touch /home/tml/.ssh/authorized_keys
    ExecStartPre=/bin/chmod 500 /home/tml/.ssh
    ExecStartPre=/bin/chown -R tml /home/tml/.ssh
    ExecStart=/bin/bash -c '/usr/local/bin/tml-puppet daemon --transport tcp --tcp-control-socket-addr "\$(ip route show 0.0.0.0/0 | cut -d" " -f3):3859" --authorized-keys-file /home/tml/.ssh/authorized_keys --exit-on-authorized-keys-update-error --parameters-dir /run/tml/parameters --job-id-file /run/tml/job-id'
    Restart=always
    RestartSec=5s
    SERVICE
    ln -s /etc/systemd/system/tml-puppet.service /etc/systemd/system/multi-user.target.wants/tml-puppet.service

    # Allow the puppet daemon to bind to its D-Bus service
    cat > /etc/dbus-1/system.d/ci.treadmill.Puppet.conf <<DBUSCONF
    <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
    <busconfig>
      <policy context="default">
        <allow own="ci.treadmill.Puppet"/>
        <allow send_destination="ci.treadmill.Puppet"/>
        <allow receive_sender="ci.treadmill.Puppet"/>
      </policy>
    </busconfig>
    DBUSCONF

    # Install rustup as the tml user:
    chmod +x /customize-image/rustup-init
    sudo -u tml /customize-image/rustup-init -y --default-toolchain none --profile minimal

    # Install nbd-client
    apt install "/customize-image/nbd-client_3.24-1.1_arm64.deb"

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

  customizedSDImage = derivation {
    name = "treadmill-image-netboot-raspberrypios-nbd-customized-sd";
    system = builtins.currentSystem;
    builder = "${bash}/bin/bash";
    outputs = [ "out" "qemuBcm2710Rpi3BPlusDtb" "kernel8" ];
    args = [ "-c" ''
      set -euo pipefail

      ${xz}/bin/xz -d --stdout ${raspberryPiOSImage} > raspios.img
      ${p7zip}/bin/7z -y x raspios.img 0.fat
      ${coreutils}/bin/mv 0.fat boot.img
      ${p7zip}/bin/7z -y x boot.img bcm2710-rpi-3-b-plus.dtb bcm2711-rpi-4-b.dtb kernel8.img overlays/disable-bt.dtbo
      ${coreutils}/bin/test -f bcm2710-rpi-3-b-plus.dtb
      ${coreutils}/bin/test -f bcm2711-rpi-4-b.dtb
      ${coreutils}/bin/test -f kernel8.img
      ${coreutils}/bin/test -f overlays/disable-bt.dtbo

      # We need to patch the DTB to enable UART console output for the
      # kernel and disable Bluetooth -- that'll hang QEMU. This doesn't
      # touch the DTB in the image itself:
      ${coreutils}/bin/cp bcm2710-rpi-3-b-plus.dtb bcm2710-rpi-3-b-plus.dtb.cust
      ${libraspberrypi}/bin/dtmerge bcm2710-rpi-3-b-plus.dtb.cust bcm2710-rpi-3-b-plus.dtb.merged - uart0=on
      ${coreutils}/bin/mv bcm2710-rpi-3-b-plus.dtb.merged bcm2710-rpi-3-b-plus.dtb.cust
      ${libraspberrypi}/bin/dtmerge bcm2710-rpi-3-b-plus.dtb.cust bcm2710-rpi-3-b-plus.dtb.merged overlays/disable-bt.dtbo
      ${coreutils}/bin/mv bcm2710-rpi-3-b-plus.dtb.merged bcm2710-rpi-3-b-plus.dtb.cust

      # Login to shell without password (disabled, running custom init instead
      # which itself enables autologin for the tml user)
      #IMAGEPATH=$PWD/raspios.img
      #pushd ${autologinEtcPatch}
      #cptofs -p -t ext4 -P2 -i "$IMAGEPATH" etc /
      #popd

      # Copy the nbd-client and image customization script in:
      ${coreutils}/bin/mkdir ./customize-image
      ${coreutils}/bin/cp -L ${customizeImageScript} ./customize-image/customize.sh
      ${coreutils}/bin/cp -L ${nbdFstab} ./customize-image/fstab
      ${coreutils}/bin/cp -L ${autologinOverride "tml"} ./customize-image/autologin-override.conf
      ${coreutils}/bin/cp -L ${../lib/expandroot.sh} ./customize-image/expandroot.sh
      ${coreutils}/bin/cp -L ${nbdClientDeb} ./customize-image/nbd-client_3.24-1.1_arm64.deb
      ${coreutils}/bin/cp -L ${puppetAarch64Musl puppet.treadmillSrc}/bin/tml-puppet ./customize-image/tml-puppet
      ${coreutils}/bin/cp -L ${rustupInit} ./customize-image/rustup-init
      ${lkl.out}/bin/cptofs -p -t ext4 -P2 -i raspios.img customize-image /

      # QEMU requires images to be a power of two in size:
      ${qemu}/bin/qemu-img resize -f raw ./raspios.img 4G

      # Perform the remaining image customizations in a VM:
      ${qemu}/bin/qemu-system-aarch64 \
        -machine raspi3b -cpu cortex-a72 -m 1G -smp 4 \
        -dtb bcm2710-rpi-3-b-plus.dtb.cust \
        -kernel kernel8.img \
        -device sd-card,drive=drive0 -drive id=drive0,if=none,format=raw,file=raspios.img \
        -append "rw earlyprintk loglevel=8 console=ttyAMA0,115200 dwc_otg.lpm_enable=0 root=/dev/mmcblk0p2 rootdelay=1 init=/customize-image/customize.sh" \
        -nographic

      ${coreutils}/bin/mv raspios.img $out
      ${coreutils}/bin/mv bcm2710-rpi-3-b-plus.dtb.cust $qemuBcm2710Rpi3BPlusDtb
      ${coreutils}/bin/mv kernel8.img $kernel8
    '' ];
  };

  bootPartArchive = runCommand "treadmill-image-netboot-raspberrypios-nbd-bootpart-archive.sh" {} ''
    ${p7zip}/bin/7z x ${customizedSDImage} 0.fat
    mkdir bootpart
    pushd bootpart
    ${p7zip}/bin/7z x ../0.fat
    ${gnutar}/bin/tar -cvf $out ./
    popd
  '';

  rootPartQCOW2 = runCommand "treadmill-image-netboot-raspberrypios-nbd-rootpart-qcow2.sh" {} ''
    ${p7zip}/bin/7z x ${customizedSDImage} 1.img
    ${qemu}/bin/qemu-img convert -f raw -O qcow2 1.img $out
  '';


in
  (derivation {
    name = "treadmill-store";
    system = builtins.currentSystem;
    builder = "${bash}/bin/bash";
    args = [
      "-c"
      ''
        set -euo pipefail

        # Create the base directory structure
        ${coreutils}/bin/mkdir -p $out/blobs
        ${coreutils}/bin/mkdir -p $out/images

        # Calculate the SHA256 hash of the boot archive and copy it to blobs/
        BOOT_BLOB_HASH=$(${coreutils}/bin/sha256sum ${bootPartArchive} | ${coreutils}/bin/cut -d' ' -f1)
        BOOT_BLOB_PATH="$out/blobs/''${BOOT_BLOB_HASH:0:2}/''${BOOT_BLOB_HASH:2:2}/''${BOOT_BLOB_HASH:4:2}/$BOOT_BLOB_HASH"
        ${coreutils}/bin/mkdir -p "$(${coreutils}/bin/dirname "$BOOT_BLOB_PATH")"
        ${coreutils}/bin/cp ${bootPartArchive} "$BOOT_BLOB_PATH"

        # Get the virtual size of the root partition QCOW2 disk:
        ROOT_BLOB_VIRTUAL_SIZE="$(${qemu}/bin/qemu-img info --output=json "${rootPartQCOW2}" | ${jq}/bin/jq '."virtual-size"')"

        # Calculate the SHA256 hash of the QCOW2 root partition and copy it to blobs/
        ROOT_BLOB_HASH=$(${coreutils}/bin/sha256sum ${rootPartQCOW2} | ${coreutils}/bin/cut -d' ' -f1)
        ROOT_BLOB_PATH="$out/blobs/''${ROOT_BLOB_HASH:0:2}/''${ROOT_BLOB_HASH:2:2}/''${ROOT_BLOB_HASH:4:2}/$ROOT_BLOB_HASH"
        ${coreutils}/bin/mkdir -p "$(${coreutils}/bin/dirname "$ROOT_BLOB_PATH")"
        ${coreutils}/bin/cp ${rootPartQCOW2} "$ROOT_BLOB_PATH"

        # Create the image-specific manifest file
        ${coreutils}/bin/cat > $out/image_manifest.toml << EOF
        manifest_version = 0
        manifest_extensions = [ "org.tockos.treadmill.manifest-ext.base" ]

        "org.tockos.treadmill.manifest-ext.base.label" = "Raspberry Pi OS Bookworm (2024-07-04) NBD QCOW2 Image"
        "org.tockos.treadmill.manifest-ext.base.revision" = 0
        "org.tockos.treadmill.manifest-ext.base.description" = ""

        ["org.tockos.treadmill.manifest-ext.base.attrs"]
        "org.tockos.treadmill.image.nbd_qcow2_layered_v0.head" = "layer-0"

        ["org.tockos.treadmill.manifest-ext.base.blobs".layer-0-boot]
        "org.tockos.treadmill.manifest-ext.base.sha256-digest" = "$BOOT_BLOB_HASH"
        "org.tockos.treadmill.manifest-ext.base.size" = $(${coreutils}/bin/stat -c%s ${bootPartArchive})

        ["org.tockos.treadmill.manifest-ext.base.blobs".layer-0-root]
        "org.tockos.treadmill.manifest-ext.base.sha256-digest" = "$ROOT_BLOB_HASH"
        "org.tockos.treadmill.manifest-ext.base.size" = $(${coreutils}/bin/stat -c%s ${rootPartQCOW2})

        ["org.tockos.treadmill.manifest-ext.base.blobs".layer-0-root."org.tockos.treadmill.manifest-ext.base.attrs"]
        "org.tockos.treadmill.image.nbd_qcow2_layered_v0.blob-virtual-size" = "$ROOT_BLOB_VIRTUAL_SIZE"
        EOF

        # Calculate the SHA256 hash of the image-specific manifest file
        IMAGE_HASH=$(${coreutils}/bin/sha256sum $out/image_manifest.toml | ${coreutils}/bin/cut -d' ' -f1)

        # Create the image-specific directory and move the manifest
        MANIFEST_PATH="$out/images/''${IMAGE_HASH:0:2}/''${IMAGE_HASH:2:2}/''${IMAGE_HASH:4:2}/$IMAGE_HASH"
        ${coreutils}/bin/mkdir -p "$(${coreutils}/bin/dirname "$MANIFEST_PATH")"
        ${coreutils}/bin/mv $out/image_manifest.toml "$MANIFEST_PATH"

        # Print the directory structure
        ${tree}/bin/tree $out/

        # Output the IMAGE_HASH for future reference
        ${coreutils}/bin/echo "$IMAGE_HASH" > $out/image.txt
      ''
    ];
  }) // {
    inherit
      customizedSDImage
      bootPartArchive
      rootPartQCOW2;
  }
