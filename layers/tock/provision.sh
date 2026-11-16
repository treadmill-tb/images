#!/bin/sh
set -eu

: "${TML_IMAGE_DIR:?}"
: "${rustup_init_url:?}"
: "${rustup_init_sha256:?}"

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

# After the list above, so the packages it shares with OpenOCD's build
# dependencies are already installed and do not get autoremoved again.
"$TML_IMAGE_DIR/install-openocd.sh"

curl -fL --retry 3 "$rustup_init_url" -o /opt/rustup-init
echo "$rustup_init_sha256  /opt/rustup-init" | sha256sum -c -
chmod 0755 /opt/rustup-init
sudo -u tml -H /opt/rustup-init -y --default-toolchain none --profile minimal
# Default to the stable toolchain (lazily downloaded on first use):
sudo -u tml sed -i \
	'/^default_toolchain = /d; /^profile = /a default_toolchain = "stable"' \
	/home/tml/.rustup/settings.toml
grep -qx 'default_toolchain = "stable"' /home/tml/.rustup/settings.toml

# ~/.profile adds ~/.local/bin only if it exists at login, and pipx creates it
# only on its first install.
sudo -u tml mkdir -p /home/tml/.local/bin
