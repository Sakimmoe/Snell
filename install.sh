#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

SNELL_PORT=${1:-26216}
SNELL_PSK=${2:-kokonoeyukari}
NET_MODE=${3:-}

echo "=============================="
echo " Snell Auto Deploy Script v9 (Final - Proper Order)"
echo "=============================="

if [ "$EUID" -ne 0 ]; then
  echo "Error: Run as root"
  exit 1
fi

# =========================
# 1. DNS 配置（最优先，尽早执行）
# =========================
echo "🌐 Configuring DNS (earliest possible)..."

if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    systemctl disable systemd-resolved --now 2>/dev/null || true
fi

if [ -L /etc/resolv.conf ]; then
    rm -f /etc/resolv.conf
fi
chattr -i /etc/resolv.conf 2>/dev/null || true

cat > /etc/resolv.conf << EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
EOF

echo "✅ DNS configured"

# =========================
# 2. Bullseye 源检测（此时 DNS 已修复）
# =========================
echo "🔧 Checking APT sources..."

# 更安全的备份逻辑（只在传统 sources.list 存在时备份）
if [ -f /etc/apt/sources.list ] && [ ! -f /etc/apt/sources.list.bak ]; then
    cp /etc/apt/sources.list /etc/apt/sources.list.bak
fi

if command -v lsb_release >/dev/null 2>&1; then
    CODENAME=$(lsb_release -cs 2>/dev/null || echo "unknown")
else
    CODENAME=$(grep VERSION_CODENAME /etc/os-release 2>/dev/null | cut -d= -f2 || echo "unknown")
fi

if [ "$CODENAME" = "bullseye" ]; then
    echo "🔄 Testing current APT sources for Bullseye..."
    NEED_ARCHIVE=false

    if ! apt-get update -qq >/tmp/apt_update.log 2>&1; then
        if grep -qE "(404 Not Found|Release file.*not found|does not have a Release file)" /tmp/apt_update.log; then
            echo "⚠️ Broken sources detected. Switching to archive.debian.org..."
            NEED_ARCHIVE=true
        else
            echo "⚠️ apt-get update failed (not due to missing Release file)."
            tail -10 /tmp/apt_update.log
        fi
    else
        echo "✅ Current APT sources working."
    fi

    if [ "$NEED_ARCHIVE" = true ]; then
        cat > /etc/apt/sources.list << 'EOF'
deb http://archive.debian.org/debian bullseye main contrib non-free
deb http://archive.debian.org/debian-security bullseye-security main contrib non-free
deb http://archive.debian.org/debian bullseye-updates main contrib non-free
EOF
        if ! apt-get update -qq; then
            echo "❌ Failed to update from archive.debian.org"
            exit 1
        fi
        echo "✅ Switched to archive.debian.org"
    fi
fi

# =========================
# 3. 更新索引 + 安装基础依赖
# =========================
echo "🔄 Updating package index..."
apt-get update

echo "📦 Installing base packages..."
apt-get install -y curl wget ufw fail2ban cron ca-certificates

# =========================
# IPv4 优先 + BBR + 时区
# =========================
echo "🌐 Setting IPv4 priority..."
GAI_CONF="/etc/gai.conf"
touch "$GAI_CONF"
sed -i '/::ffff:0:0\/96/d' "$GAI_CONF" 2>/dev/null || true
grep -q "::ffff:0:0/96" "$GAI_CONF" || echo "precedence ::ffff:0:0/96 100" >> "$GAI_CONF"

if [ "$NET_MODE" = "4" ]; then
    LISTEN_ADDR="0.0.0.0"
    ENABLE_IPV6="false"
else
    LISTEN_ADDR="::"
    ENABLE_IPV6="true"
fi

echo "🕒 Setting timezone to Asia/Shanghai..."
if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone Asia/Shanghai || true
else
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime || true
fi

echo "⚡ Enabling BBR + TCP Fast Open..."
sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null || true
grep -q "tcp_fastopen=3" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.tcp_fastopen=3" >> /etc/sysctl.conf
if [ ! -f /etc/sysctl.d/99-bbr.conf ]; then
cat > /etc/sysctl.d/99-bbr.conf << EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
fi
sysctl --system >/dev/null || true

# =========================
# 🛡️ UFW
# =========================
echo "🛡️ Configuring UFW..."
ufw --force reset

if command -v sshd >/dev/null 2>&1; then
    SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)
else
    SSH_PORT=""
fi
[ -n "$SSH_PORT" ] || SSH_PORT=22

ufw default deny incoming
ufw default allow outgoing
ufw allow ${SSH_PORT}/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw allow ${SNELL_PORT}/tcp comment 'Snell TCP'
ufw allow ${SNELL_PORT}/udp comment 'Snell UDP'
ufw --force enable

# =========================
# 🛡️ Fail2ban + 定时清理
# =========================
echo "🛡️ Configuring Fail2ban..."
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 7h
findtime = 10m
maxretry = 3
[sshd]
enabled = true
backend = systemd
port = ${SSH_PORT}
EOF
systemctl enable fail2ban --now
systemctl restart fail2ban

cat > /etc/cron.d/system-cleanup << 'EOF'
7 7 * * 0 root apt-get autoremove -y && apt-get clean && (command -v docker >/dev/null && docker image prune -af && docker container prune -f || true) >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/system-cleanup
systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || true

# =========================
# 📡 获取公网 IP（带更快超时 + 兜底）
# =========================
echo "📡 Detecting public IP..."

IPV4=$(curl -4 -s --connect-timeout 2 --max-time 4 https://api.ipify.org 2>/dev/null || \
       curl -4 -s --connect-timeout 2 --max-time 4 https://ifconfig.me 2>/dev/null || \
       echo "无")

IPV6=$(curl -6 -s --connect-timeout 2 --max-time 4 https://api.ipify.org 2>/dev/null || \
       curl -6 -s --connect-timeout 2 --max-time 4 https://ifconfig.me 2>/dev/null || \
       echo "无")

if [ "$NET_MODE" = "4" ]; then
    MAIN_IP=$IPV4
else
    MAIN_IP=$([ "$IPV4" != "无" ] && echo "$IPV4" || echo "$IPV6")
fi

if [ "$MAIN_IP" = "无" ]; then
    MAIN_IP="<SERVER_IP>"
    echo "⚠️ Failed to auto-detect public IP. Please replace <SERVER_IP> manually."
fi

# =========================
# 清理旧环境
# =========================
if [ -d "/root/snelldocker" ]; then
    echo "🧹 Cleaning old environment..."
    (cd /root/snelldocker && docker compose down) || true
    rm -rf /root/snelldocker
fi

# =========================
# 🐳 Docker 安装 + 严格验证
# =========================
echo "🐳 Checking Docker..."
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | bash
fi

systemctl enable docker --now

if ! docker version >/dev/null 2>&1; then
    echo "❌ Docker daemon is not responding."
    exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "🔧 Installing docker-compose-plugin..."
    apt-get install -y docker-compose-plugin
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "❌ Docker Compose is still not available."
    exit 1
fi

# =========================
# 生成配置
# =========================
mkdir -p /root/snelldocker/snell-conf

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

cat > /root/snelldocker/snell-conf/snell.conf << EOF
[snell-server]
listen = ${LISTEN_ADDR}:${SNELL_PORT}
psk = ${SNELL_PSK}
ipv6 = ${ENABLE_IPV6}
EOF

sed -i 's/\r//g' /root/snelldocker/snell-conf/snell.conf
sed -i 's/\r//g' /root/snelldocker/docker-compose.yml

# =========================
# 🚀 启动容器 + 健康检查
# =========================
echo "🚀 Starting Snell container..."
cd /root/snelldocker
docker compose pull
docker compose up -d --force-recreate

sleep 3

if ! docker ps --format '{{.Names}}' | grep -q '^snell$'; then
    echo "❌ Snell container failed to start!"
    docker compose logs --tail=50
    exit 1
fi

echo "✅ Snell container is running successfully."

# =========================
# 🎉 输出信息
# =========================
echo ""
echo "=============================="
echo " Snell Deployment Successful"
echo "=============================="
echo " IPv4     : $IPV4"
echo " IPv6     : $IPV6"
echo " Port     : $SNELL_PORT"
echo " PSK      : $SNELL_PSK"
echo " Mode     : $([ "$NET_MODE" = "4" ] && echo "IPv4 Only" || echo "Dual Stack")"
echo " Timezone : Asia/Shanghai"
echo " BBR/TFO  : enabled"
echo " UFW      : Reset + Enabled"
echo " Fail2ban : Enabled"
echo " Docker   : Verified"
echo "=============================="
echo ""
echo "Surge 配置："
echo "Snell_${SNELL_PORT} = snell, ${MAIN_IP}, ${SNELL_PORT}, psk=${SNELL_PSK}, version=5, tfo=true, reuse=true, ecn=true"
echo "=============================="
