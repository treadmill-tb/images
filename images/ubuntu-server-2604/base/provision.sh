#!/bin/sh
set -eu

apt-get install -y vim tmux htop build-essential git usbutils pciutils nload \
	nano gnupg bc mtr zip unzip wget curl gpg ca-certificates dbus

daemon_args=''
serial_consoles='ttyS0'
# shellcheck disable=SC2090
export daemon_args serial_consoles
"$TML_IMAGE_DIR/treadmill-guest.sh"

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
