{
  lib,
  vmTools,
  gptfdisk,
  util-linux,
  dosfstools,
  e2fsprogs,
  systemd,
  coreutils,
  tree,
  bash,
  pkgsStatic,
  writeText,
  writeScript
}: let
  distro = vmTools.debDistros.ubuntu2204x86_64;
  distroRepoName = "jammy";
  disk = "/dev/vda";

  # Pull in fenix to be able to build statically-linked Rust binaries with musl:
  fenix = import (builtins.fetchGit {
    url = "https://github.com/nix-community/fenix.git";
    ref = "refs/heads/main";
    rev = "0900ff903f376cc822ca637fef58c1ca4f44fab5";
  }) { };

  treadmillSrc = builtins.fetchGit {
    url = "https://github.com/treadmill-tb/treadmill.git";
    ref = "main";
    rev = "a22a7af0440d6a71606bddbf61bbed159f540e9f";
  };

  rustupInit = builtins.fetchurl {
    # TODO: re-host on mirror because version changes ...
    url = "https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init";
    sha256 = "sha256:0vgm43wl33apxxyvip85nkmi9fqx1m6d02djhf4p00p9jdlwxvka";
  };

  expandrootScript = writeScript "expandroot.sh" ''
    #!/bin/bash
    set -e -x

    ROOTDEV="$(findmnt -n -o SOURCE /)"
    ROOTDISK="/dev/$(lsblk -ndo pkname "$ROOTDEV")"
    ROOTPART="$(echo "$ROOTDEV" | sed -E 's|^/dev/[a-z]+([0-9]+).*|\1|')"

    echo "Expanding partition $ROOTPART of device $ROOTDISK using growpart..." >&2
    growpart -u force "$ROOTDISK" "$ROOTPART" || true # this fails if part can't be grown

    echo "Resizing root file system on $ROOTDEV to partition size..." >&2
    resize2fs "$ROOTDEV" # doesn't fail if nothing to do

    echo "Successfully expanded root disk!" >&2
  '';

  puppetBuilder = src: rustPlatform': target: rustPlatform'.buildRustPackage {
    pname = "treadmill-puppet";
    version = "0.0.1";

    inherit src;
    buildAndTestSubdir = "puppet";

    cargoLock.lockFile = "${src}/Cargo.lock";
    cargoLock.outputHashes."inquire-0.7.5" = "sha256-iEdsjq4IYYl6QoJmDkPQS5bJJvPG3sehDygefAOhTrY=";

    inherit target;
  };

  puppetx8664Musl = src: let
    rust = fenix.combine (with fenix; [
      stable.rustc
      stable.cargo
      targets.x86_64-unknown-linux-musl.stable.rust-std
    ]);
    rustPlatform = pkgsStatic.makeRustPlatform {
      rustc = rust;
      cargo = rust;
    };
  in
    puppetBuilder src rustPlatform "x86_64-unknown-linux-musl";

  ubuntuImage = vmTools.makeImageFromDebDist {
    inherit (distro) name fullName urlPrefix packagesLists;

    packages = (
      lib.filter (p:
        !lib.elem p [
          "g++"
          "make"
          "dpkg-dev"
          "pkg-config"
          "sysvinit"
        ])
        distro.packages
    ) ++ [
        "systemd"
        "init-system-helpers"
        "systemd-sysv"
        "linux-image-generic"
        "initramfs-tools"
        "e2fsprogs"
        "grub-efi"
        "apt"
        "openssh-server"
        "sudo"
        "iproute2"
        "terminfo"
        "ncurses-bin"
        "ncurses-term"
        "cloud-guest-utils" # growpart
        "git"
        "build-essential"
        "usbutils"
        "pciutils"
        "vim"
        "tmux"
        "htop"
        "nload"
        "nano"
        "gnupg"
        "bc"
        "mtr"
        "zip"
        "unzip"
        "wget"
        "ping"
        "ca-certificates"
    ];

    size = 5 * 1024; # Minimum image size, 5GB

    createRootFS = ''
      ${gptfdisk}/bin/sgdisk "${disk}" \
        -n1:0:+100M -t1:ef00 -c1:esp \
        -n2:0:0 -t2:8300 -c2:root

      ${util-linux}/bin/partx -u "${disk}"
      ${dosfstools}/bin/mkfs.vfat -F32 -n ESP "${disk}1"
      ${e2fsprogs}/bin/mkfs.ext4 "${disk}2" -L root

      mkdir /mnt
      ${util-linux}/bin/mount -t ext4 "${disk}2" /mnt
      mkdir -p /mnt/{proc,dev,sys,boot/efi}
      ${util-linux}/bin/mount -t vfat "${disk}1" /mnt/boot/efi

      touch /mnt/.debug
    '';

    postInstall = ''
      disk=/dev/vda

      # update-grub needs udev to detect the filesystem UUID -- without,
      # we'll get root=/dev/vda2 on the cmdline which will only work in
      # a limited set of scenarios.
      ${systemd}/lib/systemd/systemd-udevd &
      ${systemd}/bin/udevadm trigger
      ${systemd}/bin/udevadm settle

      ${util-linux}/bin/mount -t proc proc /mnt/proc
      ${util-linux}/bin/mount -t sysfs sysfs /mnt/sys
      ${util-linux}/bin/mount -o bind /dev /mnt/dev
      ${util-linux}/bin/mount -o bind /dev/pts /mnt/dev/pts

      # Copy the treadmill puppet binary into the root file system:
      mkdir -p /mnt/opt/
      cp ${puppetx8664Musl treadmillSrc}/bin/tml-puppet /mnt/opt/tml-puppet

      # Copy rustup-init binary and the rustup-init config into the image
      cp ${rustupInit} /mnt/opt/rustup-init
      chmod +x /mnt/opt/rustup-init

      # Copy the expandroot script:
      cp ${expandrootScript} /mnt/opt/expandroot
      chmod +x /mnt/opt/expandroot

      chroot /mnt /bin/bash -exuo pipefail <<CHROOT
      export PATH=/usr/sbin:/usr/bin:/sbin:/bin
      find /usr/sbin/
      find /usr/bin/
      find /sbin/
      find /bin/

      # update-initramfs needs to know where its root filesystem lives,
      # so that the initial userspace is capable of finding and mounting it.
      echo "/dev/disk/by-uuid/$(${util-linux}/bin/blkid -s UUID -o value "${disk}2") / ext4 defaults" > /etc/fstab
      echo "/dev/disk/by-uuid/$(${util-linux}/bin/blkid -s UUID -o value "${disk}1") /boot/efi vfat defaults" >> /etc/fstab

      cat /etc/fstab

      # rebuild the initramfs
      update-initramfs -k all -c

      # APT sources so we can update the system and install new packages
      cat > /etc/apt/sources.list <<SOURCES
      deb http://archive.ubuntu.com/ubuntu ${distroRepoName} main restricted universe
      deb http://security.ubuntu.com/ubuntu ${distroRepoName}-security main restricted universe
      deb http://archive.ubuntu.com/ubuntu ${distroRepoName}-updates main restricted universe
      SOURCES

      # Install the boot loader to the EFI System Partition
      # Remove "quiet" from the command line so that we can see what's happening during boot,
      # and enable the grub terminal on the serial console (no monitor attached)
      cat >> /etc/default/grub <<EOF
      GRUB_TIMEOUT=5
      GRUB_CMDLINE_LINUX="console=ttyS0"
      GRUB_CMDLINE_LINUX_DEFAULT=""
      GRUB_TERMINAL="serial"
      EOF
      sed -i '/TIMEOUT_HIDDEN/d' /etc/default/grub
      update-grub
      grub-install --target x86_64-efi

      # Configure networking
      ln -snf /lib/systemd/resolv.conf /etc/resolv.conf
      systemctl enable systemd-networkd systemd-resolved
      cat >/etc/systemd/network/10-eth.network <<NETWORK
      [Match]
      Name=en*
      Name=eth*
      [Link]
      RequiredForOnline=true
      [Network]
      DHCP=yes
      NETWORK

      # Expand root partition on first boot
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

      # Configure SSH
      rm /etc/ssh/ssh_host_*
      cat > /etc/systemd/system/generate-host-keys.service <<SERVICE
      [Install]
      WantedBy=ssh.service
      [Unit]
      Before=ssh.service
      [Service]
      Type=simple
      ExecStart=dpkg-reconfigure openssh-server
      SERVICE
      systemctl enable generate-host-keys

      # Create treadmill user and enable password-less sudo and autologin
      useradd -m -u 1000 -s /bin/bash tml
      echo "tml ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers.d/010_tml-nopasswd
      mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d/
      cat > /etc/systemd/system/serial-getty@ttyS0.service.d/override.conf <<SERVICE
      [Service]
      ExecStart=
      ExecStart=-/sbin/agetty --autologin tml --noclear %I $TERM
      SERVICE

      # Autostart the treadmill puppet daemon and always restart on exit:
      cat > /etc/systemd/system/tml-puppet.service <<SERVICE
      [Install]
      WantedBy=multi-user.target
      [Unit]
      After=network.target
      StartLimitIntervalSec=0
      [Service]
      Type=simple
      ExecStartPre=/bin/mkdir -p /run/tml/parameters /home/tml/.ssh
      ExecStartPre=/usr/bin/touch /home/tml/.ssh/authorized_keys
      ExecStartPre=/bin/chmod 500 /home/tml/.ssh
      ExecStartPre=/bin/chown -R tml /home/tml/.ssh
      ExecStart=/opt/tml-puppet --transport auto_discover --authorized-keys-file /home/tml/.ssh/authorized_keys --exit-on-authorized-keys-update-error --parameters-dir /run/tml/parameters
      Restart=always
      RestartSec=5s
      SERVICE
      ln -s /etc/systemd/system/tml-puppet.service /etc/systemd/system/multi-user.target.wants/tml-puppet.service

      # Install rustup-init as the tml user:
      sudo -u tml /opt/rustup-init -y --default-toolchain none --profile minimal

      CHROOT

      ${util-linux}/bin/umount /mnt/dev/pts
      ${util-linux}/bin/umount /mnt/dev
      ${util-linux}/bin/umount /mnt/sys
      ${util-linux}/bin/umount /mnt/proc
      ${util-linux}/bin/umount /mnt/boot/efi
    '';
  };

in
  derivation {
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

        # Calculate the SHA256 hash of the qcow2 file
        BLOB_HASH=$(${coreutils}/bin/sha256sum ${ubuntuImage}/disk-image.qcow2 | ${coreutils}/bin/cut -d' ' -f1)

        # Create the blob directory structure and copy the qcow2 file
        BLOB_PATH="$out/blobs/''${BLOB_HASH:0:2}/''${BLOB_HASH:2:2}/''${BLOB_HASH:4:2}/$BLOB_HASH"
        ${coreutils}/bin/mkdir -p "$(${coreutils}/bin/dirname "$BLOB_PATH")"
        ${coreutils}/bin/cp ${ubuntuImage}/disk-image.qcow2 "$BLOB_PATH"

        # Create the image-specific manifest file
        ${coreutils}/bin/cat > $out/image_manifest.toml << EOF
        manifest_version = 0
        manifest_extensions = [ "org.tockos.treadmill.manifest-ext.base" ]

        "org.tockos.treadmill.manifest-ext.base.label" = "Ubuntu 20.04 base installation"
        "org.tockos.treadmill.manifest-ext.base.revision" = 0
        "org.tockos.treadmill.manifest-ext.base.description" = ''''
        Base Ubuntu 20.04 installation, without any customizations.
        Minimal packages selected, DHCP network configuration.
        Credentials: root / root
        ''''

        ["org.tockos.treadmill.manifest-ext.base.attrs"]
        "org.tockos.treadmill.image.qemu_layered_v0.head" = "layer-0"

        ["org.tockos.treadmill.manifest-ext.base.blobs".layer-0]
        "org.tockos.treadmill.manifest-ext.base.sha256-digest" = "$BLOB_HASH"
        "org.tockos.treadmill.manifest-ext.base.size" = $(${coreutils}/bin/stat -c%s ${ubuntuImage}/disk-image.qcow2)

        ["org.tockos.treadmill.manifest-ext.base.blobs".layer-0."org.tockos.treadmill.manifest-ext.base.attrs"]
        "org.tockos.treadmill.image.qemu_layered_v0.blob-virtual-size" = "5368709120"
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
    buildInputs = [coreutils tree];
  }
