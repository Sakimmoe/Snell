#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SNELL_PORT=${1:-26216}
SNELL_PSK=${2:-kokonoeyukari}
NET_MODE=${3:-}
SNELL_VERSION="v5.0.1" # 当前官方最新版

echo "=========================================="
echo " Snell 官方原生一体化部署脚本（免 Docker 完美优化版）"
echo "=========================================="

if [ "$EUID" -ne 0 ]; then
  echo "Error: Run as root"
  exit 1
fi

# ======================================================================
# 0. 检查并彻底清理旧的 Docker 部署痕迹（防止端口冲突）
echo "♻️ 检查 Docker 部署痕迹..."
if [ -d "/root/snelldocker" ]; then
    if command -v docker >/dev/null 2>&1; then
        (cd /root/snelldocker && docker compose down 2>/dev/null) || true
    fi
    rm -rf /root/snelldocker
fi
# 深度清理可能遗留的 Snell 容器
if command -v docker >/dev/null 2>&1; then
    docker ps -a --format '{{.Names}}' | grep -i snell | while read c
    do
        [ -n "$c" ] && docker rm -f "$c" 2>/dev/null || true
    done
fi

# 安装基础依赖 (包含 iproute2 提供 ss 命令)
echo "📦 安装基础工具 (wget, unzip, curl, ufw, fail2ban, iproute2)..."
apt-get update -qq || true
apt-get install -y -qq wget unzip curl ufw fail2ban iproute2 >/dev/null 2>&1

# 1. 自动修复 Debian 11 软件源（解决 Archive 证书/有效期过期报错）
echo "-> 检查并修复 APT 软件源..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    CODENAME="${VERSION_CODENAME:-}"
fi
if [ "$CODENAME" = "bullseye" ]; then
    cat > /etc/apt/sources.list << 'EOF'
deb http://archive.debian.org/debian bullseye main contrib non-free
deb http://archive.debian.org/debian-security bullseye-security main contrib non-free
EOF
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid
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
cat > /etc/sysctl.d/99-network-opt.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
EOF
sysctl --system >/dev/null || true

# 3. IP 获取与网络模式判断
echo "📡 Detect IP..."
IPV4=$(curl -4 -s --max-time 5 https://api.ipify.org || curl -4 -s --max-time 5 https://ifconfig.me || echo "无")
IPV6=$(curl -6 -s --connect-timeout 3 https://api64.ipify.org || echo "无")

if [ "$IPV4" != "无" ]; then
    MAIN_IP="$IPV4"
else
    MAIN_IP="$IPV6"
fi

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

# 4. 下载并部署官方 Snell 原生程序
echo "🔍 检查端口占用情况..."
if ss -tlnp | grep -q ":${SNELL_PORT} "; then
    echo "❌ 端口 ${SNELL_PORT} 已被占用，占用进程信息如下："
    ss -tlnp | grep ":${SNELL_PORT} "
    exit 1
fi

echo "🚀 开始下载部署 Snell 官方二进制文件..."
# 判断系统架构
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) SNELL_ARCH="amd64" ;;
    aarch64) SNELL_ARCH="aarch64" ;;
    *) echo "❌ 不支持的架构: $ARCH"; exit 1 ;;
esac

SNELL_URL="https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-${SNELL_ARCH}.zip"

# 创建目录并下载
mkdir -p /etc/snell
wget -q -O /tmp/snell-server.zip "$SNELL_URL"
unzip -q -o /tmp/snell-server.zip -d /usr/local/bin/
rm -f /tmp/snell-server.zip
chmod +x /usr/local/bin/snell-server

# 生成配置文件
cat > /etc/snell/snell-server.conf << EOF
[snell-server]
listen = ${LISTEN_ADDR}:${SNELL_PORT}
psk = ${SNELL_PSK}
ipv6 = ${ENABLE_IPV6}
EOF

# 生成 Systemd 服务文件
cat > /etc/systemd/system/snell.service << EOF
[Unit]
Description=Snell Proxy Service
After=network.target

[Service]
Type=simple
LimitNOFILE=32768
ExecStart=/usr/local/bin/snell-server -c /etc/snell/snell-server.conf
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

# 启动 Snell 服务并验证
systemctl daemon-reload
systemctl enable snell >/dev/null 2>&1
systemctl restart snell
sleep 2
if ! systemctl is-active --quiet snell; then
    echo "❌ Snell 启动失败，最近日志如下："
    journalctl -u snell -n 50 --no-pager
    exit 1
fi
echo "✅ Snell 官方原生服务已启动"

# 5. ufw + fail2ban + 每周清理
echo ""
echo "🛡️ 配置 ufw + fail2ban + 每周日 07:07 清理..."

SSH_PORT=22
if command -v sshd >/dev/null 2>&1; then
    DETECTED=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)
    [ -n "$DETECTED" ] && SSH_PORT=$DETECTED
fi

ufw default deny incoming 2>/dev/null || true
ufw default allow outgoing 2>/dev/null || true
ufw allow ${SSH_PORT}/tcp comment 'SSH' 2>/dev/null || true
ufw allow ${SNELL_PORT}/tcp comment 'Snell' 2>/dev/null || true

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

# 垃圾清理脚本 (纯净版)
cat > /etc/cron.d/snell-cleanup << 'CRONEOF'
7 7 * * 0 root /bin/bash -c '
  echo "[$(date \"+\%F \%T\")] Starting weekly cleanup..." >> /var/log/snell-cleanup.log 2>/dev/null || true
  apt-get clean 2>/dev/null || true
  apt-get autoremove -y 2>/dev/null || true
  journalctl --vacuum-time=7d 2>/dev/null || true
  find /tmp -type f -mtime +7 -delete 2>/dev/null || true
  find /var/tmp -type f -mtime +7 -delete 2>/dev/null || true
  echo "[$(date \"+\%F \%T\")] Weekly cleanup completed." >> /var/log/snell-cleanup.log 2>/dev/null || true
'
CRONEOF
chmod 644 /etc/cron.d/snell-cleanup 2>/dev/null || true
systemctl reload cron 2>/dev/null || true
echo "✅ ufw + fail2ban + 每周清理配置完成"

# 最终输出
echo ""
echo "=============================="
echo " Snell 原生部署完成"
echo "=============================="
echo " IPv4 : $IPV4"
echo " IPv6 : $IPV6"
echo " Port : $SNELL_PORT"
echo " PSK : $SNELL_PSK"
echo " Mode : $([ "$NET_MODE" = "4" ] && echo "IPv4 Only" || echo "Dual Stack")"
echo " Fail2ban : maxretry=3, bantime=7h"
echo " Weekly Cleanup : 每周日 07:07 (Asia/Shanghai)"
echo " Service Status : systemctl status snell"
echo "=============================="
echo ""
echo "Surge 配置："
echo "Snell_${SNELL_PORT} = snell, ${MAIN_IP}, ${SNELL_PORT}, psk=${SNELL_PSK}, version=5, tfo=true, reuse=true, ecn=true"
echo "=============================="
