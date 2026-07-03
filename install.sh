#!/bin/bash
set -e

########################################
# Snell Installer v4 Stable
########################################

PORT=${1:-6666}
PSK=${2:-$(openssl rand -base64 12 | tr -d '\n')}
MODE=${3:-d}

echo "=============================="
echo " Snell Installer v4"
echo "=============================="

########################################
# Root check
########################################

if [ "$EUID" -ne 0 ]; then
  echo "❌ 必须 root 运行"
  exit 1
fi

########################################
# Docker install
########################################

if ! command -v docker >/dev/null 2>&1; then
  echo "📦 安装 Docker..."
  curl -fsSL https://get.docker.com | bash
fi

########################################
# 网络模式
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
# IPv6 检测
########################################

if [ "$IPV6_ENABLE" = "true" ]; then
  if [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)" = "1" ]; then
    echo "⚠️ IPv6 已禁用 → 切 IPv4"
    ADDR="0.0.0.0"
    IPV6_ENABLE="false"
  fi
fi

########################################
# DNS（安全模式，不破坏系统）
########################################

if systemctl is-active --quiet systemd-resolved; then
cat > /etc/systemd/resolved.conf <<EOF
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=9.9.9.9
EOF
systemctl restart systemd-resolved || true
fi

########################################
# sysctl 优化
########################################

cat > /etc/sysctl.d/99-snell.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
EOF

sysctl --system >/dev/null 2>&1 || true

########################################
# IP 获取
########################################

IPV4=$(curl -s4 --connect-timeout 3 ipv4.icanhazip.com || echo "无")
IPV6=$(curl -s6 --connect-timeout 3 ipv6.icanhazip.com || echo "无")

MAIN_IP=$IPV4
[ "$MODE" = "6" ] && [ "$IPV6" != "无" ] && MAIN_IP=$IPV6

########################################
# 🔥 镜像自动探测（核心）
########################################

try_image() {
  docker pull "$1" >/dev/null 2>&1 && echo "$1"
}

echo "🔍 检测可用 Snell 镜像..."

IMAGE=""

# 1️⃣ 官方常见
IMAGE=$(try_image "accors/snell:latest")

# 2️⃣ fallback
if [ -z "$IMAGE" ]; then
  IMAGE=$(try_image "surenpi/snell-server:latest")
fi

# 3️⃣ ghcr fallback
if [ -z "$IMAGE" ]; then
  IMAGE=$(try_image "ghcr.io/surge-simulator/snell:latest")
fi

if [ -z "$IMAGE" ]; then
  echo "❌ 没有可用 Snell 镜像"
  echo "👉 请检查 Docker Hub / GHCR 网络"
  exit 1
fi

echo "✅ 使用镜像: $IMAGE"

########################################
# 清理旧环境
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
echo " Snell 部署成功"
echo "=============================="
echo " 镜像   : $IMAGE"
echo " IPv4   : $IPV4"
echo " IPv6   : $IPV6"
echo " 端口   : $PORT"
echo " 密钥   : $PSK"
echo " IPv6   : $IPV6_ENABLE"
echo "=============================="
echo ""
echo "Surge:"
echo "Snell_${PORT} = snell, ${MAIN_IP}, ${PORT}, psk=${PSK}, version=5, tfo=true, reuse=true, ecn=true"
echo "=============================="
