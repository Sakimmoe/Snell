#!/bin/bash
set -e 

# ─── 终极参数化逻辑：接收端口(参数1)和密码(参数2) ───
# 如果没传参数，则使用毫无用处的假数据作为保护色
SNELL_PORT=${1:-"6666"}
SNELL_PSK=${2:-"RandomPass123"}

echo "=========================================="
echo "          开始部署 Snell        "
echo "=========================================="
echo "当前启用的 Snell 端口为: ${SNELL_PORT}"
echo "当前启用的 Snell 密码为: ${SNELL_PSK}"
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
# 这里允许解析我们传入的 $SNELL_PORT 和 $SNELL_PSK
cat > /root/snelldocker/snell-conf/snell.conf << EOF
[snell-server]
listen = 0.0.0.0:${SNELL_PORT}
psk = ${SNELL_PSK}
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
echo "✅ Snell 部署完成！"
echo "=========================================="
