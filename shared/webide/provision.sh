#!/bin/sh
set -eu

: "${code_server_url:?}"
: "${code_server_sha256:?}"

command -v curl >/dev/null || apt-get install -y curl ca-certificates

deb=/var/tmp/code-server.deb
curl -fL --retry 3 "$code_server_url" -o "$deb"
echo "$code_server_sha256  $deb" | sha256sum -c -

# The .deb declares no dependencies (it bundles its own node), so this needs
# no apt resolution.
dpkg -i "$deb"
rm -f "$deb"

# --auth none: the socket is only reachable through the job's caddy, which
# validates a gateway-issued JWT for this job's `webide` audience first. The
# 0750 runtime directory keeps other users in the job out.
cat >/etc/systemd/system/code-server.service <<'SERVICE'
[Install]
WantedBy=multi-user.target
[Unit]
After=network.target
[Service]
User=tml
Group=tml
RuntimeDirectory=tml-code-server
RuntimeDirectoryMode=0750
ExecStart=/usr/bin/code-server --auth none --socket /run/tml-code-server/code-server.sock --socket-mode 0600 --disable-telemetry --disable-update-check --disable-workspace-trust /home/tml
Restart=always
RestartSec=5s
SERVICE
systemctl enable code-server.service

cat >/etc/tml/services.d/webide.json <<'SERVICEDECL'
{
	"name": "webide",
	"label": "Web IDE",
	"protocol": "webapp",
	"upstream": "unix//run/tml-code-server/code-server.sock"
}
SERVICEDECL
