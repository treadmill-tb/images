#!/bin/sh
set -eu

: "${TML_ARCH:?}"
: "${TML_IMAGE_DIR:?}"

case "$TML_ARCH" in
x86_64) runner_arch=x64 ;;
aarch64) runner_arch=arm64 ;;
*)
	echo "no GitHub Actions runner release slug for arch $TML_ARCH" >&2
	exit 1
	;;
esac

install -m 0755 "$TML_IMAGE_DIR/install-gh-actions-runner.sh" \
	/opt/install-gh-actions-runner.sh

cat >/etc/systemd/system/install-gh-actions-runner.service <<SERVICE
[Unit]
Description=Download and install latest GitHub Actions Runner release
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/opt/install-gh-actions-runner.sh
Restart=on-failure
User=root
Group=root
Environment=RUNNER_ARCH=${runner_arch}
Environment=RUNNER_OWNER=1000
Environment=RUNNER_GROUP=1000

[Install]
WantedBy=multi-user.target
SERVICE
systemctl enable install-gh-actions-runner.service

cat >/etc/systemd/system/gh-actions-runner.service <<'SERVICE'
[Unit]
Description=GitHub Actions Runner
After=network.target tml-daemon.service install-gh-actions-runner.service
Wants=tml-daemon.service install-gh-actions-runner.service

[Service]
ExecStartPre=/bin/bash -Eexuo pipefail -c 'cp /opt/gh-actions-runner/bin/runsvc.sh /opt/gh-actions-runner/runsvc.sh && chown tml:tml /opt/gh-actions-runner/runsvc.sh && if [ -f /opt/gh-actions-runner/.credentials ]; then exit 0; fi && if [ -f /run/tml/parameters/gh-actions-runner-encoded-jit-config ]; then exit 0; fi && REPO_URL=$(cat /run/tml/parameters/gh-actions-runner-repo-url) && RUNNER_TOKEN=$(cat /run/tml/parameters/gh-actions-runner-token) && JOB_ID=$(cat /run/tml/job-id) && /opt/gh-actions-runner/config.sh --url $REPO_URL --token $RUNNER_TOKEN --name tml-gh-actions-runner-$JOB_ID --labels tml-gh-actions-runner-$JOB_ID --unattended --ephemeral'
ExecStartPre=-+/bin/bash /run/tml/parameters/gh-actions-runner-exec-start-pre-sh
ExecStart=/bin/bash -Eeuo pipefail -c 'if [ -f /run/tml/parameters/gh-actions-runner-encoded-jit-config ]; then echo "Starting GitHub Actions Runner from JIT config"; /opt/gh-actions-runner/run.sh --jitconfig $(cat /run/tml/parameters/gh-actions-runner-encoded-jit-config); else echo "Starting preconfigured GitHub Actions Runner"; /opt/gh-actions-runner/run.sh; fi'
Restart=on-failure
KillSignal=SIGINT
TimeoutStopSec=5m
User=tml
Group=tml
WorkingDirectory=/opt/gh-actions-runner
ExecStopPost=-+/bin/bash /run/tml/parameters/gh-actions-runner-exec-stop-post-sh

[Install]
WantedBy=multi-user.target
SERVICE
systemctl enable gh-actions-runner.service

cat >/opt/journal-login-shell <<'SCRIPT'
#!/bin/bash
exec /bin/bash --init-file <(echo 'sudo journalctl -f; . "$HOME/.bashrc"')
SCRIPT
chmod +x /opt/journal-login-shell
sed -i -E 's|^(tml:.*):/bin/bash$|\1:/opt/journal-login-shell|' /etc/passwd
