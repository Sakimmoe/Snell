#!/bin/bash
set -euo pipefail
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
# IPv4 优先
# =========================
echo "🌐 Setting IPv4 priority..."
GAI_CONF="/etc/gai.conf"
RULE="precedence ::ffff:0:0/96 100"
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
# 🛡️ 防火墙 (ufw) + fail2ban
# =========================
echo "🛡️ Installing and configuring firewall + fail2ban..."
apt-get update -qq 2>/dev/null || true
apt-get install -y ufw fail2ban 2>/dev/null || true

# ufw 防火墙配置（自动识别 SSH 端口 + 同时放行 TCP/UDP）
echo "🔥 Configuring ufw firewall..."

# 自动检测当前 SSH 端口，防止改端口后把自己锁外面
SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)

if [ -z "$SSH_PORT" ]; then
    SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -1 || true)
fi

if [ -z "$SSH_PORT" ]; then
    SSH_PORT=22
fi

ufw default deny incoming 2>/dev/null || true
ufw default allow outgoing 2>/dev/null || true
ufw allow ${SSH_PORT}/tcp 2>/dev/null || true
ufw allow ${SNELL_PORT}/tcp 2>/dev/null || true
ufw allow ${SNELL_PORT}/udp 2>/dev/null || true
ufw --force enable 2>/dev/null || true

# fail2ban 配置（增加 backend = systemd，更适合 Debian 11/12/13）
echo "🚫 Configuring fail2ban (maxretry=3, bantime=7h)..."
mkdir -p /etc/fail2ban/jail.d 2>/dev/null || true
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
# =========================
# IP 获取
# =========================
echo "📡 Detect IP..."
IPV4=$(curl -4 -s --max-time 3 https://api.ipify.org \
    || curl -4 -s --max-time 3 https://ifconfig.me \
    || echo "无")
IPV6=$(curl -6 -s --max-time 3 https://api.ipify.org \
    || curl -6 -s --max-time 3 https://ifconfig.me \
    || echo "无")
# 双栈默认 IPv4 优先（已修复“无”字符串导致的 fallback 失效问题）
if [ "$NET_MODE" = "4" ]; then
    MAIN_IP=$IPV4
else
    if [ "$IPV4" != "无" ]; then
        MAIN_IP=$IPV4
    else
        MAIN_IP=$IPV6
    fi
fi
curl -4 -s --max-time 3 https://ip.sb || true
# =========================
# 清理旧环境
# =========================
if [ -d "/root/snelldocker" ]; then
    echo "🧹 Cleaning old env..."
    (cd /root/snelldocker && docker compose down) || true
    rm -rf /root/snelldocker
fi
# =========================
# Docker
# =========================
echo "🐳 Checking Docker..."
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | bash
fi

# 确保 docker compose 插件存在
if ! docker compose version >/dev/null 2>&1; then
    apt-get install -y docker-compose-plugin
fi

# 再次验证 docker compose 是否可用（失败则直接退出）
docker compose version >/dev/null 2>&1
# =========================
# 目录
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
# snell config
# =========================
cat > /root/snelldocker/snell-conf/snell.conf << EOF
[snell-server]
listen = ${LISTEN_ADDR}:${SNELL_PORT}
psk = ${SNELL_PSK}
ipv6 = ${ENABLE_IPV6}
EOF
sed -i 's/\r//g' /root/snelldocker/snell-conf/snell.conf
sed -i 's/\r//g' /root/snelldocker/docker-compose.yml
# =========================
# 启动
# =========================
echo "🚀 Starting..."
cd /root/snelldocker
docker compose pull
docker compose up -d --force-recreate
# =========================
# 🧹 每周日 07:07 (上海时间) 清理垃圾
# =========================
echo "🧹 Setting up weekly cleanup at 07:07 every Sunday (Asia/Shanghai)..."
cat > /etc/cron.d/snell-cleanup << 'CRONEOF'
# Weekly garbage cleanup for Snell server
# Every Sunday at 07:07 Shanghai time
7 7 * * 0 root /bin/bash -c '
  echo "[$(date \"+%F %T\")] Starting weekly cleanup..." >> /var/log/snell-cleanup.log 2>/dev/null || true
  # Clean unused Docker data (safe for running containers)
  docker system prune -af --volumes 2>/dev/null || true
  # Clean package cache and unused packages
  apt-get clean 2>/dev/null || true
  apt-get autoremove -y 2>/dev/null || true
  # Vacuum systemd journal (keep last 7 days)
  journalctl --vacuum-time=7d 2>/dev/null || true
  # Remove old temp files (7+ days)
  find /tmp -type f -mtime +7 -delete 2>/dev/null || true
  find /var/tmp -type f -mtime +7 -delete 2>/dev/null || true
  echo "[$(date \"+%F %T\")] Weekly cleanup completed successfully." >> /var/log/snell-cleanup.log 2>/dev/null || true
'
CRONEOF
chmod 644 /etc/cron.d/snell-cleanup 2>/dev/null || true
systemctl reload cron 2>/dev/null || true
# =========================
# 输出
# =========================
echo ""
echo "=============================="
echo " Snell Info"
echo "=============================="
echo " IPv4 : $IPV4"
echo " IPv6 : $IPV6"
echo " Port : $SNELL_PORT"
echo " PSK : $SNELL_PSK"
echo " Mode : $([ "$NET_MODE" = "4" ] && echo "IPv4 Only" || echo "Dual Stack")"
echo " Timezone : Asia/Shanghai"
echo " BBR : enabled"
echo " TFO : enabled"
echo "=============================="
echo ""
echo "Surge:"
echo "Snell_${SNELL_PORT} = snell, ${MAIN_IP}, ${SNELL_PORT}, psk=${SNELL_PSK}, version=5, tfo=true, reuse=true, ecn=true"
echo "=============================="
