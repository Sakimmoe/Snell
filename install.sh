#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SNELL_PORT=${1:-26216}
SNELL_PSK=${2:-kokonoeyukari}
NET_MODE=${3:-}

echo "=============================="
echo " Snell 一体化部署脚本（含 ufw + fail2ban + 定时清理）"
echo "=============================="

if [ "$EUID" -ne 0 ]; then
  echo "Error: Run as root"
  exit 1
fi

# ==================== 系统基础准备 ====================
echo "-> 系统更新与准备..."
apt-get update -qq || true
apt-get install -y curl wget iproute2 cron 2>/dev/null || true

# IPv4 优先
echo "🌐 Setting IPv4 priority..."
if ! grep -q "precedence ::ffff:0:0/96 100" /etc/gai.conf 2>/dev/null; then
    echo "precedence ::ffff:0:0/96 100" >> /etc/gai.conf
fi

# DNS
echo "🌐 Config DNS..."
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    systemctl disable systemd-resolved --now 2>/dev/null || true
fi
chattr -i /etc/resolv.conf 2>/dev/null || true
cat > /etc/resolv.conf << EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
EOF

# 时区
echo "🕒 Setting timezone to Asia/Shanghai..."
timedatectl set-timezone Asia/Shanghai 2>/dev/null || true

# BBR + TFO
echo "⚡ Enable BBR & TFO..."
sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null || true
if [ ! -f /etc/sysctl.d/99-bbr.conf ]; then
cat > /etc/sysctl.d/99-bbr.conf << EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
fi
sysctl --system >/dev/null || true

# ==================== Snell 部署（优先保证能跑起来） ====================
echo "📡 Detect IP..."
IPV4=$(curl -4 -s --max-time 5 https://api.ipify.org || curl -4 -s --max-time 5 https://ifconfig.me || echo "无")
IPV6=$(curl -6 -s --max-time 5 https://api.ipify.org || curl -6 -s --max-time 5 https://ifconfig.me || echo "无")
MAIN_IP=${IPV4:-$IPV6}

if [ "$NET_MODE" = "4" ]; then
    LISTEN_ADDR="0.0.0.0"
    ENABLE_IPV6="false"
else
    LISTEN_ADDR="::"
    ENABLE_IPV6="true"
fi

if [ -d "/root/snelldocker" ]; then
    (cd /root/snelldocker && docker compose down) || true
    rm -rf /root/snelldocker
fi

echo "🐳 Checking Docker..."
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | bash
fi
if ! docker compose version >/dev/null 2>&1; then
    apt-get install -y docker-compose-plugin
fi

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

echo "🚀 Starting Snell..."
cd /root/snelldocker
docker compose pull || true
docker compose up -d --force-recreate || true

echo "✅ Snell 容器已启动（即使后面 ufw 断连也没关系）"

# ==================== ufw + fail2ban + 定时清理（放到最后） ====================
echo ""
echo "🛡️ 开始配置 ufw + fail2ban + 每周清理..."

apt-get install -y ufw fail2ban 2>/dev/null || true

# 检测 SSH 端口
SSH_PORT=22
if command -v sshd >/dev/null 2>&1; then
    DETECTED=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)
    [ -n "$DETECTED" ] && SSH_PORT=$DETECTED
fi
echo "检测到 SSH 端口: $SSH_PORT"

# 配置 ufw 规则
ufw default deny incoming 2>/dev/null || true
ufw default allow outgoing 2>/dev/null || true
ufw allow ${SSH_PORT}/tcp comment 'SSH' 2>/dev/null || true
ufw allow ${SNELL_PORT}/tcp comment 'Snell' 2>/dev/null || true
ufw allow ${SNELL_PORT}/udp comment 'Snell' 2>/dev/null || true

# fail2ban 配置
cat > /etc/fail2ban/jail.d/ssh.conf << 'JAILEOF'
[sshd]
enabled = true
backend = systemd
maxretry = 3
bantime = 7h
findtime = 10m
JAILEOF

systemctl enable fail2ban 2>/dev/null || true
systemctl restart fail2ban 2>/dev/null || true

# 启用 ufw
echo "🔥 正在启用 ufw（此步可能导致 SSH 短暂中断）..."
ufw --force enable 2>/dev/null || echo "ufw enable 可能失败或已启用"

# 每周日 07:07 清理
cat > /etc/cron.d/snell-cleanup << 'CRONEOF'
7 7 * * 0 root /bin/bash -c '
  echo "[$(date \"+%F %T\")] Starting weekly cleanup..." >> /var/log/snell-cleanup.log 2>/dev/null || true
  docker system prune -af --volumes 2>/dev/null || true
  apt-get clean 2>/dev/null || true
  apt-get autoremove -y 2>/dev/null || true
  journalctl --vacuum-time=7d 2>/dev/null || true
  find /tmp -type f -mtime +7 -delete 2>/dev/null || true
  find /var/tmp -type f -mtime +7 -delete 2>/dev/null || true
  echo "[$(date \"+%F %T\")] Weekly cleanup completed." >> /var/log/snell-cleanup.log 2>/dev/null || true
'
CRONEOF
chmod 644 /etc/cron.d/snell-cleanup 2>/dev/null || true
systemctl reload cron 2>/dev/null || true

echo "✅ ufw + fail2ban + 每周清理配置完成"

# ==================== 最终输出 ====================
echo ""
echo "=============================="
echo " Snell 部署完成"
echo "=============================="
echo " IPv4 : $IPV4"
echo " IPv6 : $IPV6"
echo " Port : $SNELL_PORT"
echo " PSK : $SNELL_PSK"
echo " Mode : $([ "$NET_MODE" = "4" ] && echo "IPv4 Only" || echo "Dual Stack")"
echo " Fail2ban : maxretry=3, bantime=7h"
echo " Weekly Cleanup : 每周日 07:07 (Asia/Shanghai)"
echo "=============================="
echo ""
echo "Surge 配置："
echo "Snell_${SNELL_PORT} = snell, ${MAIN_IP}, ${SNELL_PORT}, psk=${SNELL_PSK}, version=5, tfo=true, reuse=true, ecn=true"
echo "=============================="
echo ""
echo "如果刚才 ufw 那一步 SSH 断开了，请重新连接后执行："
echo "ufw status && docker ps"
