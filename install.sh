#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SNELL_PORT=${1:-26216}
SNELL_PSK=${2:-kokonoeyukari}
NET_MODE=${3:-}

echo "=============================="
echo " Snell 一体化部署脚本（稳定版）"
echo "=============================="

if [ "$EUID" -ne 0 ]; then
  echo "Error: Run as root"
  exit 1
fi

# ==================== Docker 镜像加速器配置 ====================
configure_docker_registry_mirrors() {
    local daemon_file="/etc/docker/daemon.json"

    echo "🌐 配置 Docker 镜像加速器..."

    mkdir -p /etc/docker

    if [ -f "$daemon_file" ]; then
        cp "$daemon_file" "${daemon_file}.bak.$(date +%s)"
    fi

    cat > "$daemon_file" << 'EOF'
{
  "registry-mirrors": [
    "https://docker.xuanyuan.me",
    "https://docker.1ms.run",
    "https://docker.m.daocloud.io"
  ],
  "live-restore": true
}
EOF

    systemctl daemon-reload
    systemctl restart docker
    sleep 5

    echo "✅ Docker 镜像加速器配置完成"
}
# ======================================================================

# 1. 自动修复 Debian 11 软件源
echo "-> 检查并修复 APT 软件源..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    CODENAME="${VERSION_CODENAME:-}"
fi
if [ "$CODENAME" = "bullseye" ]; then
    cat > /etc/apt/sources.list << 'EOF'
deb http://archive.debian.org/debian bullseye main contrib non-free
EOF
    rm -f /etc/apt/sources.list.d/debian.sources 2>/dev/null || true
fi
apt-get update -qq || true

# 2. 系统优化
echo "🌐 Setting IPv4 priority..."
grep -q "precedence ::ffff:0:0/96 100" /etc/gai.conf 2>/dev/null || echo "precedence ::ffff:0:0/96 100" >> /etc/gai.conf

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

echo "🕒 Setting timezone to Asia/Shanghai..."
timedatectl set-timezone Asia/Shanghai 2>/dev/null || true

echo "⚡ Enable BBR & TFO..."

cat > /etc/sysctl.d/99-network-opt.conf << EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
EOF

sysctl --system >/dev/null || true

# 3. IP 获取
echo "📡 Detect IP..."
IPV4=$(curl -4 -s --max-time 5 https://api.ipify.org || curl -4 -s --max-time 5 https://ifconfig.me || echo "无")
IPV6=$(curl -6 -s --connect-timeout 3 https://api64.ipify.org || echo "无")
MAIN_IP=${IPV4:-$IPV6}

# 网络模式判断 + IPv6 可用性检测
if [ "$NET_MODE" = "4" ]; then
    LISTEN_ADDR="0.0.0.0"
    ENABLE_IPV6="false"
else
    LISTEN_ADDR="::"
    if [ "$IPV6" != "无" ]; then
        ENABLE_IPV6="true"
    else
        ENABLE_IPV6="false"
    fi
fi

# 4. 部署 Snell
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

configure_docker_registry_mirrors

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

# 拉取镜像（带 fallback）
if ! docker pull accors/snell:latest; then
    echo "⚠️  Docker Hub 拉取失败，尝试备用源..."
    if docker pull dockerproxy.com/accors/snell:latest; then
        docker tag dockerproxy.com/accors/snell:latest accors/snell:latest
    else
        echo "❌ Snell 镜像拉取失败"
        exit 1
    fi
fi

docker compose up -d --force-recreate

echo "✅ Snell 容器已启动"

# 5. ufw + fail2ban + 每周清理
echo ""
echo "🛡️ 配置 ufw + fail2ban + 每周日 07:07 清理..."
apt-get install -y ufw fail2ban 2>/dev/null || true

SSH_PORT=22
if command -v sshd >/dev/null 2>&1; then
    DETECTED=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)
    [ -n "$DETECTED" ] && SSH_PORT=$DETECTED
fi

ufw default deny incoming 2>/dev/null || true
ufw default allow outgoing 2>/dev/null || true
ufw allow ${SSH_PORT}/tcp comment 'SSH' 2>/dev/null || true
ufw allow ${SNELL_PORT}/tcp comment 'Snell' 2>/dev/null || true
ufw allow ${SNELL_PORT}/udp comment 'Snell' 2>/dev/null || true

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

echo "🔥 启用 ufw..."
ufw --force enable 2>/dev/null || echo "ufw enable 完成或已启用"

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

# 最终输出
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
