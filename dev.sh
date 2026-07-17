#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SNELL_PORT=${1:-26216}
SNELL_PSK=${2:-kokonoeyukari}
NET_MODE=${3:-}
SNELL_VERSION="v5.0.1"

echo "=========================================="
echo " Snell 部署脚本"
echo "=========================================="

if [ "$EUID" -ne 0 ]; then echo "Error: Run as root"; exit 1; fi

# 1. 安装基础工具
echo "📦 安装依赖 (wget, unzip, curl, ufw, iproute2, e2fsprogs, cron)..."
apt-get update -qq || true
apt-get install -y -qq wget unzip curl ufw iproute2 cron >/dev/null 2>&1

# 2. 修复 Debian 11 源 (仅限 Bullseye)
if [ -f /etc/os-release ]; then
    . /etc/os-release
fi
if [ "${VERSION_CODENAME:-}" = "bullseye" ]; then
    echo "-> 修复 Debian 11 软件源..."
    cat > /etc/apt/sources.list << 'EOF'
deb http://archive.debian.org/debian bullseye main contrib non-free
deb http://archive.debian.org/debian-security bullseye-security main contrib non-free
EOF
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid
    rm -f /etc/apt/sources.list.d/debian.sources 2>/dev/null || true
    apt-get update -qq || true
fi

# 3. 系统网络优化 (IPv4 优先, DNS, BBR)
echo "🌐 优化网络配置 (IPv4 优先, DNS, BBR)..."
grep -q "precedence ::ffff:0:0/96 100" /etc/gai.conf 2>/dev/null || echo "precedence ::ffff:0:0/96 100" >> /etc/gai.conf

systemctl disable systemd-resolved --now 2>/dev/null || true
cat > /etc/resolv.conf << EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
EOF

cat > /etc/sysctl.d/99-bbr.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system >/dev/null || true

# 4. IP 获取与网络模式
echo "📡 获取服务器 IP..."
IPV4=$(curl -4 -s --max-time 5 https://api.ipify.org || echo "无")
IPV6=$(curl -6 -s --connect-timeout 3 https://api64.ipify.org || echo "无")
MAIN_IP=$([ "$IPV4" != "无" ] && echo "$IPV4" || echo "$IPV6")

if [ "$NET_MODE" = "4" ]; then
    LISTEN_ADDR="0.0.0.0"
    ENABLE_IPV6="false"
else
    LISTEN_ADDR="[::]"
    ENABLE_IPV6=$([ "$IPV6" != "无" ] && echo "true" || echo "false")
fi

# 5. 部署 Snell
systemctl stop snell 2>/dev/null || true
sleep 1 # 等待端口彻底释放

if ss -tlnp | grep -q ":${SNELL_PORT} "; then
    echo "❌ 端口 ${SNELL_PORT} 已被占用:" && ss -tlnp | grep ":${SNELL_PORT} " && exit 1
fi

echo "🚀 下载并部署 Snell v5..."
case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="aarch64" ;;
    *) echo "❌ 不支持的架构: $(uname -m)"; exit 1 ;;
esac

SNELL_URL="https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-${ARCH}.zip"
wget -q -O /tmp/snell.zip "$SNELL_URL" || {
    echo "❌ Snell 下载失败，请检查网络或官方下载站状态"
    exit 1
}

rm -f /usr/local/bin/snell-server
unzip -q -o /tmp/snell.zip -d /usr/local/bin/ && rm -f /tmp/snell.zip
chmod +x /usr/local/bin/snell-server

mkdir -p /etc/snell
cat > /etc/snell/snell-server.conf << EOF
[snell-server]
listen = ${LISTEN_ADDR}:${SNELL_PORT}
psk = ${SNELL_PSK}
ipv6 = ${ENABLE_IPV6}
EOF

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

systemctl daemon-reload
systemctl enable snell >/dev/null 2>&1
systemctl restart snell >/dev/null 2>&1
sleep 2

if ! systemctl is-active --quiet snell; then
    echo "❌ Snell 启动失败:" && journalctl -u snell -n 20 --no-pager && exit 1
fi

# 6. 配置 UFW
echo "🛡️ 配置防火墙 (UFW)..."
SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || echo "22")
ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1
ufw allow ${SSH_PORT}/tcp comment 'SSH' >/dev/null 2>&1
ufw allow ${SNELL_PORT}/tcp comment 'Snell TCP' >/dev/null 2>&1
ufw allow ${SNELL_PORT}/udp comment 'Snell UDP' >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1

# 7. 每周清理任务
echo "🧹 配置每周自动清理..."
cat > /etc/cron.d/snell-cleanup << 'CRONEOF'
7 7 * * 0 root /bin/bash -c 'apt-get clean && apt-get autoremove -y && journalctl --vacuum-time=7d && find /tmp /var/tmp -type f -mtime +7 -delete' >/dev/null 2>&1
CRONEOF
chmod 644 /etc/cron.d/snell-cleanup && systemctl reload cron >/dev/null 2>&1 || true

# 8. 完成输出
echo -e "\n=============================="
echo " ✅ Snell 部署完成"
echo "=============================="
echo " IPv4 : $IPV4"
echo " IPv6 : $IPV6"
echo " Port : $SNELL_PORT"
echo " PSK  : $SNELL_PSK"
echo " Mode : $([ "$NET_MODE" = "4" ] && echo "IPv4 Only" || echo "Dual Stack")"
echo "=============================="
echo "Surge 配置："
echo "Snell_${SNELL_PORT} = snell, ${MAIN_IP}, ${SNELL_PORT}, psk=${SNELL_PSK}, version=5, reuse=true, ecn=true"
echo "=============================="
