#!/bin/bash
set -e

#####################################
# Snell Docker Installer v3 Stable
#####################################

SNELL_PORT=${1:-6666}
SNELL_PSK=${2:-$(openssl rand -base64 12 | tr -d '\n')}
NET_MODE=${3:-d}

echo "=============================="
echo " Snell Installer v3 Starting"
echo "=============================="

#####################################
# Root check
#####################################

if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root"
  exit 1
fi

#####################################
# Docker check
#####################################

if ! command -v docker >/dev/null 2>&1; then
    echo "📦 安装 Docker..."
    curl -fsSL https://get.docker.com | bash
fi

#####################################
# 网络模式
#####################################

LISTEN_ADDR="::"
ENABLE_IPV6="true"

if [ "$NET_MODE" = "4" ]; then
    LISTEN_ADDR="0.0.0.0"
    ENABLE_IPV6="false"
elif [ "$NET_MODE" = "6" ]; then
    LISTEN_ADDR="::"
    ENABLE_IPV6="true"
fi

#####################################
# IPv6 检测修复
#####################################

if [ "$ENABLE_IPV6" = "true" ]; then
    if [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)" = "1" ]; then
        echo "⚠️ IPv6 已禁用 → 自动切 IPv4"
        LISTEN_ADDR="0.0.0.0"
        ENABLE_IPV6="false"
    fi
fi

#####################################
# DNS（不破坏 resolv.conf）
#####################################

if systemctl is-active --quiet systemd-resolved; then
cat > /etc/systemd/resolved.conf <<EOF
[Resolve]
DNS=1.1.1.1 8.8.8.8 2001:4860:4860::8888
FallbackDNS=9.9.9.9
EOF
systemctl restart systemd-resolved || true
fi

#####################################
# sysctl 优化
#####################################

cat > /etc/sysctl.d/99-snell.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
EOF

sysctl --system >/dev/null 2>&1 || true

#####################################
# IP 获取
#####################################

IPV4=$(curl -s4 --connect-timeout 3 ipv4.icanhazip.com || echo "无")
IPV6=$(curl -s6 --connect-timeout 3 ipv6.icanhazip.com || echo "无")

MAIN_IP=$IPV4
[ "$NET_MODE" = "6" ] && [ "$IPV6" != "无" ] && MAIN_IP=$IPV6

#####################################
# 自动选择镜像（关键修复点）
#####################################

SNELL_IMAGE="accors/snell:latest"

echo "📦 使用镜像: $SNELL_IMAGE"

#####################################
# 清理旧环境
#####################################

rm -rf /root/snelldocker
mkdir -p /root/snelldocker/snell-conf

#####################################
# docker-compose
#####################################

cat > /root/snelldocker/docker-compose.yml <<EOF
services:
  snell:
    image: ${SNELL_IMAGE}
    container_name: snell
    restart: always
    network_mode: host
    volumes:
      - ./snell-conf/snell.conf:/etc/snell-server.conf
EOF

#####################################
# snell config
#####################################

cat > /root/snelldocker/snell-conf/snell.conf <<EOF
[snell-server]
listen = ${LISTEN_ADDR}:${SNELL_PORT}
psk = ${SNELL_PSK}
ipv6 = ${ENABLE_IPV6}
EOF

#####################################
# 启动
#####################################

cd /root/snelldocker

if docker compose version >/dev/null 2>&1; then
    docker compose up -d
else
    docker-compose up -d
fi

#####################################
# 输出
#####################################

echo ""
echo "=============================="
echo " Snell 部署成功"
echo "=============================="
echo " IPv4   : $IPV4"
echo " IPv6   : $IPV6"
echo " 端口   : $SNELL_PORT"
echo " 密钥   : $SNELL_PSK"
echo " IPv6   : $ENABLE_IPV6"
echo "=============================="
echo ""
echo "Surge 配置："
echo "Snell_${SNELL_PORT} = snell, ${MAIN_IP}, ${SNELL_PORT}, psk=${SNELL_PSK}, version=5, tfo=true, reuse=true, ecn=true"
echo "=============================="
