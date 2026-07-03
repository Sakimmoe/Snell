#!/bin/bash

set -e

cat >/etc/systemd/system/ipv4-only-egress.service <<'EOF'
[Unit]
Description=Force IPv4-only Egress (Remove IPv6 Default Route)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ip -6 route del default

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ipv4-only-egress.service
systemctl start ipv4-only-egress.service

echo
echo "======================================"
echo " IPv6 default route removed."
echo " IPv6 inbound remains available."
echo " IPv4 outbound only mode enabled."
echo "======================================"
echo

ip -6 route || true
