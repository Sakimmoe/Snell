#!/bin/bash
set -e # 遇到错误时自动停止运行

echo "=========================================="
echo "          开始安装并部署 Snell            "
echo "=========================================="

echo "1. 开始安装 Docker..."
bash <(curl -sL 'https://get.docker.com')

echo "2. 创建目录结构..."
mkdir -p /root/snelldocker/snell-conf

echo "3. 生成 docker-compose.yml..."
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

echo "4. 生成 snell.conf..."
cat > /root/snelldocker/snell-conf/snell.conf << 'EOF'
[snell-server]
listen = 0.0.0.0:26216
psk = kokonoyu9162799.Y
ipv6 = false
EOF

echo "5. 自动修复配置文件换行符格式..."
sed -i 's/\r//g' /root/snelldocker/snell-conf/snell.conf
sed -i 's/\r//g' /root/snelldocker/docker-compose.yml

echo "6. 正在拉取镜像并启动容器..."
cd /root/snelldocker
docker compose pull
docker compose up -d

echo "=========================================="
echo "✅ Snell 部署完成并已在后台运行！"
echo "=========================================="
