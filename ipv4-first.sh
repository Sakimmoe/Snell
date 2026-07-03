#!/bin/bash

# 遇到错误立即停止
set -e

# 确保 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "Error: Run as root"
  exit 1
fi

GAI_CONF="/etc/gai.conf"
RULE="precedence ::ffff:0:0/96  100"

# 1. 确保文件存在
touch "$GAI_CONF"

# 2. 删除旧 IPv4-mapped 优先规则
sed -i '/::ffff:0:0\/96/d' "$GAI_CONF"

# 3. 保证文件末尾换行
sed -i -e '$a\' "$GAI_CONF"

# 4. 写入规则
echo "$RULE" >> "$GAI_CONF"

# 5. 输出状态
echo "======================================"
echo " IPv4 priority enabled (gai.conf)"
echo " IPv6 inbound remains available"
echo " No routing changes applied"
echo "======================================"

# 6. 验证（打印出出口 IP 地址）
echo "Current outbound IP:"
curl -s --max-time 3 https://ip.sb || echo "Verification failed."
