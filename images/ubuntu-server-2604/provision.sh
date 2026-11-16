#!/bin/sh
set -eu

# Only what the Treadmill guest runtime needs. Everything a job wants to build
# or flash with comes from a layer.
#
# growpart: expandroot.sh grows the root partition on first boot, and the
# cloud-init purge below is what would otherwise take cloud-guest-utils with it.
apt-get install -y \
	ca-certificates \
	cloud-guest-utils \
	curl \
	dbus \
	tmux

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
