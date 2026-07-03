#!/bin/bash
set -e

PORT=${1:-6666}
PSK=${2:-$(openssl rand -base64 16 | tr -d '\n')}
MODE=${3:-d}

echo "=============================="
echo " Snell Ultimate Stable v1"
echo "=============================="

#################################
# root check
#################################

if [ "$EUID" -ne 0 ]; then
  echo "❌ 请用 root 运行"
  exit 1
fi

#################################
# install deps
#################################

apt update -y
apt install -y curl unzip ca-certificates

#################################
# download snell official
#################################

WORKDIR=/opt/snell
mkdir -p $WORKDIR
cd $WORKDIR

echo "📦 下载 Snell 官方 binary..."

curl -L -o snell.zip https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip
unzip -o snell.zip
chmod +x snell-server

#################################
# network mode
#################################

ADDR="::"

if [ "$MODE" = "4" ]; then
  ADDR="0.0.0.0"
elif [ "$MODE" = "6" ]; then
  ADDR="::"
fi

#################################
# config
#################################

cat > /etc/snell-server.conf <<EOF
[snell-server]
listen = ${ADDR}:${PORT}
psk = ${PSK}
ipv6 = true
EOF

#################################
# systemd service
#################################

cat > /etc/systemd/system/snell.service <<EOF
[Unit]
Description=Snell Server
After=network.target

[Service]
ExecStart=/opt/snell/snell-server -c /etc/snell-server.conf
Restart=always
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

#################################
# enable service
#################################

systemctl daemon-reload
systemctl enable snell
systemctl restart snell

#################################
# IP detect
#################################

IPV4=$(curl -s4 --connect-timeout 3 ifconfig.me || echo "无")
IPV6=$(curl -s6 --connect-timeout 3 ifconfig.me || echo "无")

MAIN_IP=$IPV4
[ "$MODE" = "6" ] && [ "$IPV6" != "无" ] && MAIN_IP=$IPV6

#################################
# output
#################################

echo ""
echo "=============================="
echo " ✅ Snell 安装完成"
echo "=============================="
echo " IP   : $MAIN_IP"
echo " PORT : $PORT"
echo " PSK  : $PSK"
echo " MODE : $MODE"
echo "=============================="
echo ""
echo "Surge 配置："
echo "Snell_${PORT} = snell, ${MAIN_IP}, ${PORT}, psk=${PSK}, version=5, tfo=true, reuse=true, ecn=true"
echo "=============================="
