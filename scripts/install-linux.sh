#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run with sudo.'; exit 1; }
[[ $# -eq 1 ]] || { echo 'Usage: sudo bash scripts/install-linux.sh /absolute/path/to/config'; exit 1; }
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../companion" && pwd)
config_dir=$(realpath -- "$1")
[[ -f "$config_dir/config.json" && -f "$config_dir/cert.pem" && -f "$config_dir/key.pem" ]] || { echo 'Configuration is incomplete.'; exit 1; }
[[ ! -e /opt/powerbridge ]] || { echo 'Already installed. Stop the service and follow the upgrade instructions in README.'; exit 1; }
install -d -m 700 /opt/powerbridge /etc/powerbridge
install -m 600 "$config_dir/config.json" "$config_dir/cert.pem" "$config_dir/key.pem" /etc/powerbridge/
install -m 600 "$source_dir/server.py" "$source_dir/platform_ops.py" /opt/powerbridge/
# Runtime uses the Python standard library only. cryptography is needed solely for setup.
cat > /etc/systemd/system/powerbridge.service <<'UNIT'
[Unit]
Description=PowerBridge secure PC companion
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /opt/powerbridge/server.py --config /etc/powerbridge/config.json
WorkingDirectory=/opt/powerbridge
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now powerbridge
echo 'Installed. Check: sudo systemctl status powerbridge'
echo 'Open TCP 45831 only to your LAN/VPN subnet if a firewall is active. Do not forward the port on your router.'
