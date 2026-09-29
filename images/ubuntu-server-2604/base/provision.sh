#!/bin/sh
set -eu

apt-get install -y \
	bc \
	build-essential \
	ca-certificates \
	cmake \
	curl \
	dbus \
	device-tree-compiler \
	dfu-util \
	file \
	gcc-arm-none-eabi \
	gcc-riscv64-unknown-elf \
	gdb-multiarch \
	git \
	gnupg \
	gpg \
	gpiod \
	htop \
	i2c-tools \
	jq \
	libnewlib-arm-none-eabi \
	libstdc++-arm-none-eabi-newlib \
	libudev-dev \
	libusb-1.0-0-dev \
	libzmq3-dev \
	lsof \
	minicom \
	mtr-tiny \
	nano \
	ninja-build \
	nload \
	pciutils \
	picocom \
	picolibc-riscv64-unknown-elf \
	pipx \
	pkg-config \
	rsync \
	socat \
	stlink-tools \
	strace \
	tio \
	tmux \
	unzip \
	usbutils \
	vim \
	wget \
	xxd \
	zip

"$TML_IMAGE_DIR/install-openocd.sh"

daemon_args=''
serial_consoles='ttyS0'
# shellcheck disable=SC2090
export daemon_args serial_consoles
"$TML_IMAGE_DIR/treadmill-guest.sh"

usermod -a -G dialout tml

apt-get purge -y cloud-init
rm -f /etc/netplan/*.yaml

# /etc/default/grub is sourced by update-grub, so appended assignments win
# over the cloud image's defaults.
cat >>/etc/default/grub <<'GRUB'

GRUB_TIMEOUT=5
GRUB_CMDLINE_LINUX="console=ttyS0"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_TERMINAL="serial"
GRUB
sed -i '/GRUB_TIMEOUT_STYLE/d;/GRUB_HIDDEN_TIMEOUT/d' /etc/default/grub
update-grub
