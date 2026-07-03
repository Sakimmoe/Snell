#!/bin/bash
set -e

# 参数处理：端口(参数1), 密码(参数2), 网络模式(参数3: 4 / 6 / d)
SNELL_PORT=${1:-"6666"}
SNELL_PSK=${2:-"RandomPass123"}
NET_MODE=${3:-"d"}

# 根据网络模式设定监听地址和 IPv6 开关
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

# 获取公网 IP (设置 3 秒超时防止卡死)
IPV4=$(curl -s4 --connect-timeout 3 ipv4.icanhazip.com || echo "无")
IPV6=$(curl -s6 --connect-timeout 3 ipv6.icanhazip.com || echo "无")

# 决定 Surge 配置中使用的主要 IP
if [ "$NET_MODE" = "6" ] && [ "$IPV6" != "无" ]; then
    MAIN_IP=$IPV6
else
    MAIN_IP=${IPV4:-$IPV6} # 优先用 v4，没有则用 v6
fi

# 清理旧环境
if [ -d "/root/snelldocker" ]; then
    echo "🔄 检测到旧环境，正在清理..."
    cd /root/snelldocker && docker compose down 2>/dev/null || true
    rm -rf /root/snelldocker
fi

# 环境准备
echo "1. 更新系统并安装 Docker..."
apt-get update -y && bash <(curl -sL 'https://get.docker.com')

echo "2. 生成配置..."
mkdir -p /root/snelldocker/snell-conf

# 生成 Docker Compose 文件
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

# 生成 Snell 配置文件
cat > /root/snelldocker/snell-conf/snell.conf << EOF
[snell-server]
listen = ${LISTEN_ADDR}:${SNELL_PORT}
psk = ${SNELL_PSK}
ipv6 = ${ENABLE_IPV6}
EOF

# 修复潜在换行符问题
sed -i 's/\r//g' /root/snelldocker/snell-conf/snell.conf
sed -i 's/\r//g' /root/snelldocker/docker-compose.yml

# 启动容器
echo "3. 启动服务..."
cd /root/snelldocker
docker compose pull
docker compose up -d

# 输出配置信息面板
echo ""
echo "Snell Server 配置信息："
echo "——————————————————————————————————————————————————"
echo " IPv4 地址      : ${IPV4}"
echo " IPv6 地址      : ${IPV6}"
echo " 端口           : ${SNELL_PORT}"
echo " 密钥           : ${SNELL_PSK}"
echo " OBFS           : off"
echo " IPv6           : ${ENABLE_IPV6}"
echo " TFO            : false"
echo " DNS            : 1.1.1.1, 8.8.8.8, 2001:4860:4860::8888"
echo " 版本           : 5"
echo "——————————————————————————————————————————————————"
echo "[信息] Surge 配置："
echo "Snell_${SNELL_PORT} = snell, ${MAIN_IP}, ${SNELL_PORT}, psk=${SNELL_PSK}, version=5, tfo=false, reuse=true, ecn=true"
echo "——————————————————————————————————————————————————"
