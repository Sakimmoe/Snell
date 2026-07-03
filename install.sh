#!/bin/bash
set -e

########################################
# Snell Docker Stable Installer v2
########################################

# 参数
SNELL_PORT=${1:-6666}
SNELL_PSK=${2:-$(openssl rand -base64 12 | tr -d '\n')}
NET_MODE=${3:-d}

echo "=============================="
echo " Snell Installer v2 Starting"
echo "=============================="

########################################
# 0. 基础检查
########################################

if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 运行"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  apt-get update -y && apt-get install -y curl
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "📦 安装 Docker..."
  curl -fsSL https://get.docker.com | bash
fi

########################################
# 1. 网络模式
########################################

LISTEN_ADDR="::"
ENABLE_IPV6="true"

if [ "$NET_MODE" = "4" ]; then
    LISTEN_ADDR="0.0.0.0"
    ENABLE_IPV6="false"
elif [ "$NET_MODE" = "6" ]; then
    LISTEN_ADDR="::"
    ENABLE_IPV6="true"
fi

########################################
# 2. IPv6 检测（避免假可用）
########################################

if [ "$ENABLE_IPV6" = "true" ]; then
    IPV6_DISABLE=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)
    if [ "$IPV6_DISABLE" = "1" ]; then
        echo "⚠️ 系统 IPv6 已禁用，自动切换 IPv4"
        LISTEN_ADDR="0.0.0.0"
        ENABLE_IPV6="false"
    fi
fi

########################################
# 3. DNS（不破坏系统，只覆盖 resolved）
########################################

if systemctl is-active --quiet systemd-resolved; then
    cat > /etc/systemd/resolved.conf << EOF
[Resolve]
DNS=1.1.1.1 8.8.8.8 2001:4860:4860::8888
FallbackDNS=9.9.9.9
EOF
    systemctl restart systemd-resolved || true
fi

########################################
# 4. 内核优化（安全写入）
########################################

cat > /etc/sysctl.d/99-snell.conf << EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
EOF

sysctl --system >/dev/null 2>&1 || true

########################################
# 5. IP 获取（多源 fallback）
########################################

get_ip() {
    curl -s --connect-timeout 3 ipv4.icanhazip.com ||
    curl -s --connect-timeout 3 ip.sb ||
    curl -s --connect-timeout 3 ifconfig.me || echo "unknown"
}

IPV4=$(curl -s4 --connect-timeout 3 ipv4.icanhazip.com || echo "无")
IPV6=$(curl -s6 --connect-timeout 3 ipv6.icanhazip.com || echo "无")

MAIN_IP=$IPV4
[ "$NET_MODE" = "6" ] && [ "$IPV6" != "无" ] && MAIN_IP=$IPV6

########################################
# 6. 清理旧容器
########################################

if [ -d /root/snelldocker ]; then
    echo "🧹 清理旧环境..."
    cd /root/snelldocker && docker compose down >/dev/null 2>&1 || true
    rm -rf /root/snelldocker
fi

mkdir -p /root/snelldocker/snell-conf

########################################
# 7. Compose 文件
########################################

cat > /root/snelldocker/docker-compose.yml << EOF
services:
  snell:
    image: accors/snell:v5
    container_name: snell
    restart: always
    network_mode: host
    volumes:
      - ./snell-conf/snell.conf:/etc/snell-server.conf
EOF

########################################
# 8. Snell 配置
########################################

cat > /root/snelldocker/snell-conf/snell.conf << EOF
[snell-server]
listen = ${LISTEN_ADDR}:${SNELL_PORT}
psk = ${SNELL_PSK}
ipv6 = ${ENABLE_IPV6}
EOF

########################################
# 9. 启动容器（兼容 compose v1/v2）
########################################

cd /root/snelldocker

if docker compose version >/dev/null 2>&1; then
    docker compose pull
    docker compose up -d
else
    docker-compose pull
    docker-compose up -d
fi

########################################
# 10. 输出信息
########################################

echo ""
echo "=============================="
echo " Snell 部署完成"
echo "=============================="
echo " IPv4   : $IPV4"
echo " IPv6   : $IPV6"
echo " 监听IP : $LISTEN_ADDR"
echo " 端口   : $SNELL_PORT"
echo " 密钥   : $SNELL_PSK"
echo " IPv6   : $ENABLE_IPV6"
echo " BBR    : enabled"
echo " TFO    : enabled"
echo "=============================="
echo ""
echo "Surge 配置："
echo "Snell_${SNELL_PORT} = snell, ${MAIN_IP}, ${SNELL_PORT}, psk=${SNELL_PSK}, version=5, tfo=true, reuse=true, ecn=true"
echo "=============================="
