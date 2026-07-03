#!/bin/bash
set -euo pipefail

# 参数：端口 / 密码 / 网络模式
SNELL_PORT=${1:-6666}
SNELL_PSK=${2:-RandomPass123}
NET_MODE=${3:-d}

echo "=============================="
echo " Snell Auto Deploy Script"
echo "=============================="

# =========================
# 网络模式
# =========================
if [ "$NET_MODE" = "4" ]; then
    LISTEN_ADDR="0.0.0.0"
    ENABLE_IPV6="false"
elif [ "$NET_MODE" = "6" ]; then
    LISTEN_ADDR="::"
    ENABLE_IPV6="true"
else
    LISTEN_ADDR="::"
    ENABLE_IPV6="true"
fi

# =========================
# DNS（避免 systemd stub 冲突）
# =========================
echo "🌐 Config DNS..."

if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    systemctl disable systemd-resolved --now 2>/dev/null || true
fi

chattr -i /etc/resolv.conf 2>/dev/null || true

cat > /etc/resolv.conf << EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 2001:4860:4860::8888
EOF

# =========================
# BBR + TFO
# =========================
echo "⚡ Enable BBR & TFO..."

sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null || true

if ! grep -q "tcp_fastopen=3" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.tcp_fastopen=3" >> /etc/sysctl.conf
fi

if [ ! -f /etc/sysctl.d/99-bbr.conf ]; then
cat > /etc/sysctl.d/99-bbr.conf << EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
fi

sysctl --system >/dev/null || true

# =========================
# 获取 IP
# =========================
echo "📡 Detect IP..."

IPV4=$(curl -4 -s --max-time 3 https://api.ipify.org || echo "无")
IPV6=$(curl -6 -s --max-time 3 https://api6.ipify.org || echo "无")

if [ "$NET_MODE" = "6" ] && [ "$IPV6" != "无" ]; then
    MAIN_IP=$IPV6
else
    MAIN_IP=${IPV4:-$IPV6}
fi

# =========================
# 清理旧环境
# =========================
if [ -d "/root/snelldocker" ]; then
    echo "🧹 Cleaning old env..."
    (cd /root/snelldocker && docker compose down) || true
    rm -rf /root/snelldocker
fi

# =========================
# Docker 安装（避免重复）
# =========================
echo "🐳 Checking Docker..."

if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | bash
fi

# =========================
# 创建目录
# =========================
mkdir -p /root/snelldocker/snell-conf

# =========================
# docker-compose
# =========================
cat > /root/snelldocker/docker-compose.yml << 'EOF'
services:
  snell:
    image: accors/snell:latest
    container_name: snell
    restart: always
    network_mode: host
    volumes:
      - ./snell-conf/snell.conf:/etc/snell-server.conf
    environment:
      - SNELL_URL=https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip
EOF

# =========================
# Snell config（不改协议）
# =========================
cat > /root/snelldocker/snell-conf/snell.conf << EOF
[snell-server]
listen = ${LISTEN_ADDR}:${SNELL_PORT}
psk = ${SNELL_PSK}
ipv6 = ${ENABLE_IPV6}
EOF

# 去 CRLF
sed -i 's/\r//g' /root/snelldocker/snell-conf/snell.conf
sed -i 's/\r//g' /root/snelldocker/docker-compose.yml

# =========================
# 启动
# =========================
echo "🚀 Starting Snell..."

cd /root/snelldocker

docker compose pull || true
docker compose up -d || true

# =========================
# 输出信息
# =========================
echo ""
echo "=============================="
echo " Snell Server Info"
echo "=============================="
echo " IPv4     : $IPV4"
echo " IPv6     : $IPV6"
echo " Port     : $SNELL_PORT"
echo " PSK      : $SNELL_PSK"
echo " IPv6 Mode: $ENABLE_IPV6"
echo " TFO      : enabled"
echo " BBR      : enabled"
echo " DNS      : 1.1.1.1 / 8.8.8.8 / 2001:4860:4860::8888"
echo "=============================="
echo ""
echo "Surge config:"
echo "Snell_${SNELL_PORT} = snell, ${MAIN_IP}, ${SNELL_PORT}, psk=${SNELL_PSK}, version=5, tfo=true, reuse=true, ecn=true"
echo "=============================="
