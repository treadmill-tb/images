#!/bin/sh
set -eu

: "${TML_PAYLOAD_DIR:?}"
: "${TML_IMAGE_DIR:?}"
: "${TML_ARCH:?}"
: "${puppet_daemon_args:?set puppet_daemon_args before running this layer}"
: "${serial_consoles:?set serial_consoles before running this layer}"
: "${rustup_init_url:?}"
: "${rustup_init_sha256:?}"
: "${ttyd_url:?}"
: "${ttyd_sha256:?}"

command -v curl >/dev/null || apt-get install -y curl ca-certificates

fetch_verified() {
	curl -fL --retry 3 "$1" -o "$3"
	echo "$2  $3" | sha256sum -c -
}

install -m 0755 "$TML_PAYLOAD_DIR/tml-puppet" /usr/local/bin/tml-puppet
install -m 0755 "$TML_PAYLOAD_DIR/caddy" /usr/local/bin/caddy

fetch_verified "$ttyd_url" "$ttyd_sha256" /usr/local/bin/ttyd
chmod 0755 /usr/local/bin/ttyd

fetch_verified "$rustup_init_url" "$rustup_init_sha256" /opt/rustup-init
chmod 0755 /opt/rustup-init

install -m 0755 "$TML_IMAGE_DIR/expandroot.sh" /opt/expandroot.sh

# Some base images ship a default user at UID 1000; free the slot before
# claiming it for tml.
existing_uid1000="$(getent passwd 1000 | cut -d: -f1)"
if [ -n "$existing_uid1000" ] && [ "$existing_uid1000" != tml ]; then
	userdel -r "$existing_uid1000" 2>/dev/null || true
fi
useradd -m -u 1000 -s /bin/bash tml
usermod -a -G plugdev tml
usermod -a -G tty tml
echo "tml ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/010_tml-nopasswd
chmod 440 /etc/sudoers.d/010_tml-nopasswd

cat >/etc/udev/rules.d/99-tml.rules <<'RULES'
SUBSYSTEM=="usb", GROUP="plugdev", TAG+="uaccess"
RULES

cat >/etc/dbus-1/system.d/dev.treadmill.Puppet.conf <<'DBUSCONF'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <policy context="default">
    <allow own="dev.treadmill.Puppet"/>
    <allow send_destination="dev.treadmill.Puppet"/>
    <allow receive_sender="dev.treadmill.Puppet"/>
  </policy>
</busconfig>
DBUSCONF

mkdir -p /etc/tml/services.d

# The heredoc is unquoted so ${puppet_daemon_args} expands here while a
# $(...) inside it stays literal for the unit's shell to evaluate at service
# start. puppet_daemon_args must contain no single quote: the ExecStart body
# is wrapped in one.
cat >/etc/systemd/system/tml-puppet.service <<SERVICE
[Install]
WantedBy=multi-user.target
[Unit]
After=network.target
StartLimitIntervalSec=0
[Service]
Type=notify
NotifyAccess=main
ExecStartPre=/bin/mkdir -p /run/tml/parameters
ExecStart=/bin/bash -c 'exec /usr/local/bin/tml-puppet daemon ${puppet_daemon_args} --job-info-dir /run/tml --parameters-dir /run/tml/parameters --services-dir /etc/tml/services.d --caddy-config /run/tml/caddy/services.caddy --caddy-reload-command "systemctl --no-block reload-or-restart tml-caddy.service"'
Restart=always
RestartSec=5s
SERVICE
systemctl enable tml-puppet.service

mkdir -p /etc/caddy
cat >/etc/caddy/Caddyfile <<'CADDY'
{
	admin unix//run/tml-caddy/admin.sock
	auto_https off
	skip_install_trust
	order jwtauth before reverse_proxy
}

http://:339 {
	import /run/tml/caddy/services.caddy
}
CADDY

cat >/etc/systemd/system/tml-caddy.service <<'SERVICE'
[Install]
WantedBy=multi-user.target
[Unit]
After=network.target tml-puppet.service
Wants=tml-puppet.service
ConditionPathExists=/run/tml/caddy/services.caddy
[Service]
RuntimeDirectory=tml-caddy
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile --address unix//run/tml-caddy/admin.sock
Restart=always
RestartSec=5s
SERVICE
systemctl enable tml-caddy.service

cat >/etc/systemd/system/ttyd.service <<'SERVICE'
[Install]
WantedBy=multi-user.target
[Unit]
After=network.target
[Service]
User=tml
Group=tml
RuntimeDirectory=tml-ttyd
RuntimeDirectoryMode=0750
ExecStart=/usr/local/bin/ttyd --interface /run/tml-ttyd/ttyd.sock --writable tmux new-session -A -s tml
Restart=always
RestartSec=5s
SERVICE
systemctl enable ttyd.service

cat >/etc/tml/services.d/webterm.json <<'SERVICEDECL'
{
	"name": "webterm",
	"label": "Terminal",
	"protocol": "webapp",
	"upstream": "unix//run/tml-ttyd/ttyd.sock"
}
SERVICEDECL

sudo -u tml -H /opt/rustup-init -y --default-toolchain none --profile minimal

touch /firstboot-expandroot
cat >/etc/systemd/system/firstboot-expandroot.service <<'SERVICE'
[Install]
WantedBy=multi-user.target
[Unit]
ConditionPathExists=/firstboot-expandroot
[Service]
Type=simple
ExecStart=/opt/expandroot.sh
ExecStartPost=/bin/rm /firstboot-expandroot
SERVICE
systemctl enable firstboot-expandroot.service

rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
cat >/etc/systemd/system/ssh-generate-host-keys.service <<'SERVICE'
[Install]
WantedBy=multi-user.target
[Unit]
Before=ssh.service
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key
[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
RemainAfterExit=true
SERVICE
systemctl enable ssh-generate-host-keys.service

for dev in $serial_consoles; do
	mkdir -p "/etc/systemd/system/serial-getty@${dev}.service.d"
	cat >"/etc/systemd/system/serial-getty@${dev}.service.d/override.conf" <<'OVERRIDE'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin tml --noclear %I
OVERRIDE
done

# KeepConfiguration=yes: on the netboot image eth0 carries the NBD root, so
# networkd must keep the address the initramfs configured rather than flush
# and re-DHCP, which would drop the root mid-boot.
mkdir -p /etc/systemd/network
cat >/etc/systemd/network/10-eth.network <<'NETWORK'
[Match]
Name=en* eth*
[Network]
DHCP=yes
IPv6AcceptRA=yes
IPv6PrivacyExtensions=no
KeepConfiguration=yes
[DHCPv4]
ClientIdentifier=mac
[DHCPv6]
DUIDType=link-layer
[Link]
RequiredForOnline=true
NETWORK
ln -snf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl enable systemd-networkd systemd-resolved
