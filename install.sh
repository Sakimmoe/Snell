#!/bin/bash
set -e

# ─── 1. 参数处理：端口(参数1), 密码(参数2), 网络模式(参数3: 4 / 6 / d) ───
SNELL_PORT=${1:-"6666"}
SNELL_PSK=${2:-"RandomPass123"}
NET_MODE=${3:-"d"}

# ─── 2. 网络与 IPv6 模式设定 ───
if [ "$NET_MODE" = "4" ]; then
    LISTEN_ADDR="0.0.0.0"
    ENABLE_IPV6="false"
elif [ "$NET_MODE" = "6" ]; then
    LISTEN_ADDR="::"
    ENABLE_IPV6="true"
else
    # 默认为双栈模式 (d)
    LISTEN_ADDR="::"
    ENABLE_IPV6="true"
fi

# ─── 3. 强行修改服务器系统 DNS ───
echo "🌐 正在接管服务器 DNS 设置..."
# 解除可能存在的文件锁定并写入新 DNS
chattr -i /etc/resolv.conf 2>/dev/null || true
cat > /etc/resolv.conf << EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 2001:4860:4860::8888
EOF
# 兼容 systemd-resolved 守护进程
if systemctl is-active --quiet systemd-resolved; then
    sed -i 's/^#*DNS=.*/DNS=1.1.1.1 8.8.8.8 2001:4860:4860::8888/g' /etc/systemd/resolved.conf 2>/dev/null || true
    systemctl restart systemd-resolved 2>/dev/null || true
fi

# ─── 4. 在系统内核层开启 TFO (TCP Fast Open) ───
echo "⚡ 正在配置内核 TCP Fast Open..."
sysctl -w net.ipv4.tcp_fastopen=3 > /dev/null
# 写入配置以保证重启后依然生效
if ! grep -q "net.ipv4.tcp_fastopen=3" /etc/sysctl.conf; then
    echo "net.ipv4.tcp_fastopen=3" >> /etc/sysctl.conf
fi
TFO_STATUS="true"

# ─── 5. 获取公网 IP (3秒超时防卡死) ───
IPV4=$(curl -s4 --connect-timeout 3 ipv4.icanhazip.com || echo "无")
IPV6=$(curl -s6 --connect-timeout 3 ipv6.icanhazip.com || echo "无")

# 决定 Surge 配置中使用的主要 IP
if [ "$NET_MODE" = "6" ] && [ "$IPV6" != "无" ]; then
    MAIN_IP=$IPV6
else
    MAIN_IP=${IPV4:-$IPV6} # 优先用 v4，没有则用 v6
fi

# ─── 6. 清理旧环境 ───
if [ -d "/root/snelldocker" ]; then
    echo "🔄 检测到旧环境，正在执行清理..."
    cd /root/snelldocker && docker compose down 2>/dev/null || true
    rm -rf /root/snelldocker
fi

# ─── 7. 环境准备与文件生成 ───
echo "📦 更新系统并安装 Docker..."
apt-get update -y && bash <(curl -sL 'https://get.docker.com')

echo "⚙️ 生成部署配置..."
mkdir -p /root/snelldocker/snell-conf

# Docker Compose 文件
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

# Snell 配置文件
cat > /root/snelldocker/snell-conf/snell.conf << EOF
[snell-server]
listen = ${LISTEN_ADDR}:${SNELL_PORT}
psk = ${SNELL_PSK}
ipv6 = ${ENABLE_IPV6}
EOF

# 修复因 Windows 拷贝导致的潜在回车符 Bug
sed -i 's/\r//g' /root/snelldocker/snell-conf/snell.conf
sed -i 's/\r//g' /root/snelldocker/docker-compose.yml

# ─── 8. 启动容器 ───
echo "🚀 拉取镜像并启动服务..."
cd /root/snelldocker
docker compose pull
docker compose up -d

# ─── 9. 输出真实配置面板 ───
echo ""
echo "Snell Server 配置信息："
echo "——————————————————————————————————————————————————"
echo " IPv4 地址      : ${IPV4}"
echo " IPv6 地址      : ${IPV6}"
echo " 端口           : ${SNELL_PORT}"
echo " 密钥           : ${SNELL_PSK}"
echo " OBFS           : off (Snell v5 已移除原生 OBFS 支持)"
echo " IPv6           : ${ENABLE_IPV6} (脚本内已配置)"
echo " TFO            : ${TFO_STATUS} (系统内核已开启)"
echo " DNS            : 1.1.1.1, 8.8.8.8, 2001:4860:4860::8888"
echo " 版本           : 5"
echo "——————————————————————————————————————————————————"
echo "[信息] Surge 配置："
echo "Snell_${SNELL_PORT} = snell, ${MAIN_IP}, ${SNELL_PORT}, psk=${SNELL_PSK}, version=5, tfo=${TFO_STATUS}, reuse=true, ecn=true"
echo "——————————————————————————————————————————————————"
