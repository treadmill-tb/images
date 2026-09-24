#!/bin/sh
set -eu

# Installing nbd-client triggers update-initramfs, which under Raspberry Pi
# OS's default MODULES=dep probes the current root device and fails in a
# no-boot build. MODULES=most bundles a broad set without probing, which an
# NBD-netboot image needs anyway.
mkdir -p /etc/initramfs-tools/conf.d
cat >/etc/initramfs-tools/conf.d/10-tml-netboot <<'CONF'
MODULES=most
CONF

apt-get install -y nbd-client systemd-resolved vim tmux htop build-essential \
    git usbutils pciutils nload nano gnupg bc mtr zip unzip wget curl gpg \
    ca-certificates dbus

# shellcheck disable=SC2016,SC2089,SC2090
daemon_args='--transport tcp --tcp-control-socket-addr "$(ip route show 0.0.0.0/0 | cut -d" " -f3 | head -n1):3859"'
serial_consoles='ttyAMA0 ttyAMA10'
# shellcheck disable=SC2090
export daemon_args serial_consoles
"$TML_IMAGE_DIR/treadmill-guest.sh"

usermod -a -G dialout tml
usermod -a -G gpio tml

cat >/etc/fstab <<'FSTAB'
proc /proc proc defaults 0 0
/dev/nbd0 / ext4 defaults,noatime,nodiratime 0 1
/dev/nbd1 /boot/firmware vfat defaults,x-systemd.requires=tml-nbd-boot.service,x-systemd.after=tml-nbd-boot.service 0 2
FSTAB

# The boot file system is the image's `boot` NBD export, served by the same
# host the root came from: the DHCP server, which is also the default gateway.
cat >/etc/systemd/system/tml-nbd-boot.service <<'SERVICE'
[Unit]
Description=Attach the boot file system over NBD
DefaultDependencies=no
Before=boot-firmware.mount
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'exec nbd-client "$(ip -4 route show default | cut -d" " -f3 | head -n1)" -N boot /dev/nbd1'
ExecStop=/usr/sbin/nbd-client -d /dev/nbd1
SERVICE

cat >/boot/firmware/cmdline.txt <<'CMDLINE'
console=serial0,115200 ip=dhcp root=/dev/nbd0 rw nbdroot=dhcp,root,nbd0 rootfstype=ext4 fsckfix rootwait net.ifnames=0 loglevel=7
CMDLINE
: >/boot/firmware/ssh.txt

mask_units() {
	for unit in "$@"; do
		ln -snf /dev/null "/etc/systemd/system/$unit"
	done
}

mask_units \
	dphys-swapfile.service \
	rpi-eeprom-update.service \
	userconfig.service \
	systemd-hostnamed.service \
	systemd-hostnamed.socket \
	systemd-logind.service \
	rpi-resize.service \
	systemd-growfs-root.service \
	rpi-resize-swap-file.service \
	sshswitch.service \
	cloud-init.service \
	cloud-init-local.service \
	cloud-init-network.service \
	cloud-final.service \
	cloud-init.target

# Raspberry Pi OS defaults to NetworkManager. eth0 carries the NBD root, so
# it must be networkd's alone or the two fight over the interface the root
# filesystem arrives on.
mask_units \
	NetworkManager.service \
	NetworkManager-wait-online.service \
	dhcpcd.service

systemctl enable ssh.service
