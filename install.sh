#!/bin/bash
set -e

########################################
# Snell Installer v5 Ultimate
########################################

PORT=${1:-6666}
PSK=${2:-$(openssl rand -base64 18 | tr -d '\n')}
MODE=${3:-d}

echo "=============================="
echo " Snell Installer v5 Ultimate"
echo "=============================="

########################################
# root check
########################################

if [ "$EUID" -ne 0 ]; then
  echo "❌ 请用 root 运行"
  exit 1
fi

########################################
# docker install
########################################

if ! command -v docker >/dev/null 2>&1; then
  echo "📦 安装 Docker..."
  curl -fsSL https://get.docker.com | bash
fi

########################################
# network mode
########################################

ADDR="::"
IPV6_ENABLE="true"

if [ "$MODE" = "4" ]; then
  ADDR="0.0.0.0"
  IPV6_ENABLE="false"
elif [ "$MODE" = "6" ]; then
  ADDR="::"
  IPV6_ENABLE="true"
fi

########################################
# IPv6 check
########################################

if [ "$IPV6_ENABLE" = "true" ]; then
  if [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)" = "1" ]; then
    ADDR="0.0.0.0"
    IPV6_ENABLE="false"
  fi
fi

########################################
# IP detect
########################################

IPV4=$(curl -s4 --connect-timeout 3 ifconfig.me || echo "无")
IPV6=$(curl -s6 --connect-timeout 3 ifconfig.me || echo "无")

MAIN_IP=$IPV4
[ "$MODE" = "6" ] && [ "$IPV6" != "无" ] && MAIN_IP=$IPV6

########################################
# 镜像自动探测（核心）
########################################

echo "🔍 检测可用 Snell 镜像..."

IMAGE=""

try_pull() {
    docker pull "$1" >/dev/null 2>&1 && IMAGE="$1"
}

try_pull "accors/snell:latest"
if [ -z "$IMAGE" ]; then
    try_pull "surenpi/snell-server:latest"
fi
if [ -z "$IMAGE" ]; then
    try_pull "ghcr.io/surge-simulator/snell:latest"
fi

if [ -z "$IMAGE" ]; then
    echo "❌ 没有可用 Snell 镜像"
    exit 1
fi

echo "✅ 使用镜像: $IMAGE"

########################################
# clean old
########################################

rm -rf /root/snelldocker
mkdir -p /root/snelldocker/snell-conf

########################################
# compose
########################################

cat > /root/snelldocker/docker-compose.yml <<EOF
services:
  snell:
    image: ${IMAGE}
    container_name: snell
    restart: always
    network_mode: host
    volumes:
      - ./snell-conf/snell.conf:/etc/snell-server.conf
EOF

########################################
# config
########################################

cat > /root/snelldocker/snell-conf/snell.conf <<EOF
[snell-server]
listen = ${ADDR}:${PORT}
psk = ${PSK}
ipv6 = ${IPV6_ENABLE}
EOF

########################################
# start
########################################

cd /root/snelldocker

if docker compose version >/dev/null 2>&1; then
    docker compose up -d
else
    docker-compose up -d
fi

########################################
# output
########################################

echo ""
echo "=============================="
echo " Snell 安装完成"
echo "=============================="
echo " 镜像 : $IMAGE"
echo " IPv4 : $IPV4"
echo " IPv6 : $IPV6"
echo " 端口 : $PORT"
echo " 密钥 : $PSK"
echo " IPv6 : $IPV6_ENABLE"
echo "=============================="
echo ""
echo "Surge 配置："
echo "Snell_${PORT} = snell, ${MAIN_IP}, ${PORT}, psk=${PSK}, version=5, tfo=true, reuse=true, ecn=true"
echo "=============================="
