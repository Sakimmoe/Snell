#!/bin/bash

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Run as root"
  exit 1
fi

GAI_CONF="/etc/gai.conf"
RULE="precedence ::ffff:0:0/96  100"

[ ! -f "$GAI_CONF" ] && touch "$GAI_CONF"

# 删除所有旧规则（避免重复/冲突）
sed -i '/::ffff:0:0\/96/d' "$GAI_CONF"

# 添加新规则
echo "$RULE" >> "$GAI_CONF"

echo "IPv4 priority enabled (gai.conf updated)"

# 测试（可选）
curl -I -s --max-time 3 https://google.com | head -n 1 || true
