#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

SNELL_PORT=${1:-26216}
SNELL_PSK=${2:-kokonoeyukari}
NET_MODE=${3:-}

echo "=============================="
echo " Snell v5 官方版一键部署"
echo "=============================="

if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 运行"
    exit 1
fi

echo "-> 检查系统..."

if [ -f /etc/os-release ]; then
    . /etc/os-release
    CODENAME="${VERSION_CODENAME:-}"
fi

if [ "$CODENAME" = "bullseye" ]; then
cat >/etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian bullseye main contrib non-free
EOF
rm -f /etc/apt/sources.list.d/debian.sources 2>/dev/null || true
fi

apt-get update -y

echo "-> 安装依赖..."

apt-get install -y \
curl \
wget \
unzip \
ufw \
fail2ban \
ca-certificates

echo "-> 设置 IPv4 优先..."

grep -q "precedence ::ffff:0:0/96 100" /etc/gai.conf 2>/dev/null || \
echo "precedence ::ffff:0:0/96 100" >> /etc/gai.conf

echo "-> 配置 DNS..."

systemctl disable systemd-resolved --now 2>/dev/null || true

chattr -i /etc/resolv.conf 2>/dev/null || true

cat >/etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
EOF

echo "-> 启用 BBR..."

cat >/etc/sysctl.d/99-network-opt.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

sysctl --system >/dev/null

echo "-> 获取公网 IP..."

IPV4=$(curl -4 -s --max-time 5 https://api.ipify.org || echo "无")
IPV6=$(curl -6 -s --connect-timeout 5 https://api64.ipify.org || echo "无")

MAIN_IP=$IPV4

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

echo "-> 下载 Snell v5..."

mkdir -p /opt/snell

ARCH=$(uname -m)

case "$ARCH" in
x86_64)
    SNELL_URL="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip"
    ;;
aarch64)
    SNELL_URL="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-aarch64.zip"
    ;;
*)
    echo "不支持架构: $ARCH"
    exit 1
    ;;
esac

wget -O /tmp/snell.zip "$SNELL_URL"

unzip -o /tmp/snell.zip -d /opt/snell

chmod +x /opt/snell/snell-server

echo "-> 创建配置文件..."

cat >/etc/snell-server.conf <<EOF
[snell-server]
listen = ${LISTEN_ADDR}:${SNELL_PORT}
psk = ${SNELL_PSK}
ipv6 = ${ENABLE_IPV6}
EOF

echo "-> 创建 systemd 服务..."

cat >/etc/systemd/system/snell.service <<EOF
[Unit]
Description=Snell Proxy Service
After=network.target

[Service]
Type=simple
ExecStart=/opt/snell/snell-server -c /etc/snell-server.conf
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable snell
systemctl restart snell

echo "-> 配置 UFW..."

SSH_PORT=22

if command -v sshd >/dev/null 2>&1; then
    DETECTED=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)
    [ -n "$DETECTED" ] && SSH_PORT=$DETECTED
fi

ufw default deny incoming || true
ufw default allow outgoing || true

ufw allow ${SSH_PORT}/tcp comment 'SSH'
ufw allow ${SNELL_PORT}/tcp comment 'Snell'

ufw --force enable

echo "-> 配置 Fail2ban..."

cat >/etc/fail2ban/jail.d/ssh.conf <<EOF
[sshd]
enabled = true
backend = systemd
maxretry = 3
bantime = 7h
findtime = 10m
EOF

systemctl enable fail2ban
systemctl restart fail2ban

echo "-> 配置每周自动清理..."

cat >/etc/cron.d/snell-cleanup <<'EOF'
7 7 * * 0 root /bin/bash -c '
apt-get clean
apt-get autoremove -y
journalctl --vacuum-time=7d
find /tmp -type f -mtime +7 -delete
find /var/tmp -type f -mtime +7 -delete
'
EOF

chmod 644 /etc/cron.d/snell-cleanup

systemctl reload cron 2>/dev/null || true

echo
echo "=============================="
echo " Snell 部署完成"
echo "=============================="
echo " IPv4 : $IPV4"
echo " IPv6 : $IPV6"
echo " Port : $SNELL_PORT"
echo " PSK  : $SNELL_PSK"
echo " Mode : $([ "$NET_MODE" = "4" ] && echo IPv4-Only || echo Dual-Stack)"
echo "=============================="
echo
echo "Surge 配置："
echo "Snell_${SNELL_PORT} = snell, ${MAIN_IP}, ${SNELL_PORT}, psk=${SNELL_PSK}, version=5, tfo=true, reuse=true, ecn=true"
echo
