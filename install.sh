#!/bin/bash
set -e

# 参数处理
SNELL_PORT=${1:-"6666"}
SNELL_PSK=${2:-"RandomPass123"}

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
listen = 0.0.0.0:${SNELL_PORT}
psk = ${SNELL_PSK}
ipv6 = false
EOF

# 修复潜在换行符问题
sed -i 's/\r//g' /root/snelldocker/snell-conf/snell.conf
sed -i 's/\r//g' /root/snelldocker/docker-compose.yml

# 启动容器
echo "3. 启动服务..."
cd /root/snelldocker
docker compose pull
docker compose up -d

echo "✅ 部署完成！端口: ${SNELL_PORT}, 密码: ${SNELL_PSK}"
