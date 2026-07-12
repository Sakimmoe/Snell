#!/bin/bash
set -euo pipefail

# 强制非交互模式，防止安装软件时弹窗卡死
export DEBIAN_FRONTEND=noninteractive

SNELL_PORT=${1:-26216}
SNELL_PSK=${2:-kokonoeyukari}
NET_MODE=${3:-}

echo "=============================="
echo " Snell Auto Deploy Script"
echo "=============================="

# =========================
# root check
# =========================
if [ "$EUID" -ne 0 ]; then
  echo "Error: Run as root"
  exit 1
fi

# =========================
# 📦 基础设施与依赖安装
# =========================
echo "🔄 Updating APT sources & Installing base tools..."
apt-get update -y -qq || true
apt-get install -y -qq curl wget ufw fail2ban cron || true

# =========================
# IPv4 优先
# =========================
echo "🌐 Setting IPv4 priority..."

GAI_CONF="/etc/gai.conf"
RULE="precedence ::ffff:0:0/96  100"

touch "$GAI_CONF"
sed -i '/::ffff:0:0\/96/d' "$GAI_CONF" 2>/dev/null || true
grep -q "::ffff:0:0/96" "$GAI_CONF" || echo "$RULE" >> "$GAI_CONF"

# =========================
# 网络模式
# =========================
if [ "$NET_MODE" = "4" ]; then
    LISTEN_ADDR="0.0.0.0"
    ENABLE_IPV6="false"
else
    LISTEN_ADDR="::"
    ENABLE_IPV6="true"
fi

# =========================
# DNS
# =========================
echo "🌐 Config DNS..."

if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    systemctl disable systemd-resolved --now 2>/dev/null || true
fi

# 解除可能存在的软链接，确保写入成功
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

# =========================
# 🕒 时区
# =========================
echo "🕒 Setting timezone to Asia/Shanghai..."

if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone Asia/Shanghai || true
else
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime || true
fi

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
# 🛡️ 防火墙配置 (UFW)
# =========================
echo "🛡️ Config Firewall (UFW)..."

# 动态获取 SSH 端口防失联
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
# 🛡️ 防爆破配置 (Fail2ban)
# =========================
echo "🛡️ Config Fail2ban..."

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

# =========================
# 🧹 定时清理任务 (每周日 07:07)
# =========================
echo "🧹 Setup Cron Job for system cleanup..."
cat > /etc/cron.d/system-cleanup << 'EOF'
7 7 * * 0 root apt-get autoremove -y && apt-get clean && (command -v docker >/dev/null && docker image prune -af && docker container prune -f || true) >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/system-cleanup
systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || true

# =========================
# 📡 IP 获取与精准分流
# =========================
echo "📡 Detect IP..."

# 提前确保工具有效，这里直接用刚刚装好的 curl
IPV4=$(curl -4 -s --max-time 3 https://api.ipify.org \
    || curl -4 -s --max-time 3 https://ifconfig.me \
    || echo "无")

IPV6=$(curl -6 -s --max-time 3 https://api.ipify.org \
    || curl -6 -s --max-time 3 https://ifconfig.me \
    || echo "无")

# 采用你优化后的精准 IP 选择逻辑，规避“无”字中规造成的 Bug
if [ "$NET_MODE" = "4" ]; then
    MAIN_IP=$IPV4
else
    if [ "$IPV4" != "无" ]; then
        MAIN_IP="$IPV4"
    else
        MAIN_IP="$IPV6"
    fi
fi

curl -4 -s --max-time 3 https://ip.sb >/dev/null || true

# =========================
# 清理旧环境
# =========================
if [ -d "/root/snelldocker" ]; then
    echo "🧹 Cleaning old env..."
    (cd /root/snelldocker && docker compose down) || true
    rm -rf /root/snelldocker
fi

# =========================
# Docker 检查与安装
# =========================
echo "🐳 Checking Docker..."

if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | bash
fi

# =========================
# 目录与配置生成
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
# 🚀 容器启动
# =========================
echo "🚀 Starting Snell Container..."

cd /root/snelldocker
docker compose pull || true
docker compose up -d --force-recreate || true

# =========================
# 🎉 报告输出
# =========================
echo ""
echo "=============================="
echo " Snell Info"
echo "=============================="
echo " IPv4     : $IPV4"
echo " IPv6     : $IPV6"
echo " Port     : $SNELL_PORT"
echo " PSK      : $SNELL_PSK"
echo " Mode     : $([ "$NET_MODE" = "4" ] && echo "IPv4 Only" || echo "Dual Stack")"
echo " Timezone : Asia/Shanghai"
echo " BBR      : enabled"
echo " TFO      : enabled"
echo " Firewall : UFW Enabled (Ports: $SSH_PORT, 80, 443, $SNELL_PORT)"
echo " Fail2ban : Enabled (3 retries / 7h ban)"
echo " Cleanup  : Every Sunday 07:07 (Aggressive Prune)"
echo "=============================="

echo ""
echo "Surge 配置条目:"
echo "Snell_${SNELL_PORT} = snell, ${MAIN_IP}, ${SNELL_PORT}, psk=${SNELL_PSK}, version=5, tfo=true, reuse=true, ecn=true"
echo "=============================="
