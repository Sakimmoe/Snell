#!/bin/bash
set -e

PORT=${1:-6666}
PSK=${2:-$(openssl rand -base64 16 | tr -d '\n')}
MODE=${3:-d}

echo "=============================="
echo " Snell Native Installer"
echo "=============================="

apt update -y
apt install -y curl unzip

WORKDIR=/opt/snell
mkdir -p $WORKDIR
cd $WORKDIR

echo "📦 下载 Snell 官方二进制..."

curl -L -o snell.zip https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip
unzip -o snell.zip
chmod +x snell-server

if [ "$MODE" = "4" ]; then
  ADDR="0.0.0.0"
else
  ADDR="::"
fi

cat > /etc/snell-server.conf <<EOF
[snell-server]
listen = ${ADDR}:${PORT}
psk = ${PSK}
ipv6 = true
EOF

echo "🚀 启动 Snell..."

cat > /etc/systemd/system/snell.service <<EOF
[Unit]
Description=Snell Proxy Service
After=network.target

[Service]
ExecStart=/opt/snell/snell-server -c /etc/snell-server.conf
Restart=always
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable snell
systemctl restart snell

echo ""
echo "=============================="
echo " Snell 安装完成"
echo "=============================="
echo " IP   : $(curl -s4 ifconfig.me)"
echo " PORT : $PORT"
echo " PSK  : $PSK"
echo " MODE : $MODE"
echo "=============================="
