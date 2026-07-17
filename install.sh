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

if [ "$EUID" -ne 0 ]; then
    echo "Error: 请使用 root 用户运行"
    exit 1
fi

echo "📦 安装依赖..."
apt-get update -qq || true
apt-get install -y -qq wget unzip curl ufw iproute2 cron 2>/dev/null || true

echo "🌐 优化网络配置..."
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

echo "🚀 部署 Snell..."
systemctl stop snell 2>/dev/null || true
sleep 1

if ss -tlnp | grep -q ":${SNELL_PORT} "; then
    echo "❌ 端口 ${SNELL_PORT} 已被占用"
    ss -tlnp | grep ":${SNELL_PORT} "
    exit 1
fi

case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="aarch64" ;;
    *) echo "❌ 不支持的架构"; exit 1 ;;
esac

SNELL_URL="https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-${ARCH}.zip"
wget -q -O /tmp/snell.zip "$SNELL_URL" || {
    echo "❌ Snell 下载失败"
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
systemctl enable snell >/dev/null 2>&1 || true
systemctl restart snell >/dev/null 2>&1 || true
sleep 2

if ! systemctl is-active --quiet snell; then
    echo "❌ Snell 启动失败"
    journalctl -u snell -n 20 --no-pager
    exit 1
fi

echo "🛡️ 配置防火墙..."

# 重置 UFW 并重新添加必要规则（最可靠方式）
ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming >/dev/null 2>&1 || true
ufw default allow outgoing >/dev/null 2>&1 || true

# SSH 端口检测
SSH_PORT=""
if [ -f /etc/ssh/sshd_config ]; then
    SSH_PORT=$(grep -Ei '^\s*Port\s+' /etc/ssh/sshd_config | head -1 | awk '{print $2}' | tr -d '\r\n')
fi
if [ -z "$SSH_PORT" ] && [ -d /etc/ssh/sshd_config.d ]; then
    SSH_PORT=$(grep -Ei '^\s*Port\s+' /etc/ssh/sshd_config.d/*.conf 2>/dev/null | head -1 | awk '{print $2}' | tr -d '\r\n')
fi
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]]; then
    SSH_PORT=22
fi

ufw allow 22/tcp comment 'SSH fallback' >/dev/null 2>&1 || true
ufw allow ${SSH_PORT}/tcp comment 'SSH' >/dev/null 2>&1 || true
ufw allow ${SNELL_PORT}/tcp comment 'Snell TCP' >/dev/null 2>&1 || true
ufw allow ${SNELL_PORT}/udp comment 'Snell UDP' >/dev/null 2>&1 || true
ufw --force enable >/dev/null 2>&1 || true
ufw reload >/dev/null 2>&1 || true
echo "✅ UFW 配置完成"

echo "🧹 配置定时清理..."
cat > /etc/cron.d/snell-cleanup << 'CRONEOF'
7 7 * * 0 root /bin/bash -c 'apt-get clean && apt-get autoremove -y && journalctl --vacuum-time=7d && find /tmp /var/tmp -type f -mtime +7 -delete' >/dev/null 2>&1
CRONEOF
chmod 644 /etc/cron.d/snell-cleanup

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
