#!/usr/bin/env bash
set -euo pipefail

# ==================== Snell 原生一键部署脚本（优化稳定版 v5.0.1）====================
# 基于官方二进制 + 用户原有优化（BBR/TFO/DNS/ufw/fail2ban/每周清理/IPv6智能判断等）
# 完全移除 Docker，采用 systemd 托管，更轻量高效
# 用法: sudo bash snell-native-setup.sh [端口] [PSK] [4]
#   - 端口为空则随机生成可用高位端口
#   - PSK 为空或为默认弱密码则自动生成强随机 PSK (base64 24字节)
#   - 第3参数传 "4" 则强制 IPv4 only，否则自动双栈（若IPv6可用）
# ================================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# 错误处理
trap 'log_error "脚本执行出错，已退出。"; exit 1' ERR

# 参数处理
SNELL_PORT=${1:-}
SNELL_PSK=${2:-}
NET_MODE=${3:-}

check_root() {
    if [ "$(id -u)" != "0" ]; then
        log_error "请使用 root 权限运行此脚本 (sudo bash ...)"
        exit 1
    fi
}

# 生成随机可用端口 (10000-30000 范围内)
generate_random_port() {
    local attempts=0
    local max_attempts=20
    while [ $attempts -lt $max_attempts ]; do
        local port=$(shuf -i 10000-30000 -n 1)
        if ! ss -tuln 2>/dev/null | grep -q ":${port} " && ! nc -z 127.0.0.1 "$port" 2>/dev/null; then
            echo "$port"
            return 0
        fi
        ((attempts++))
    done
    log_error "无法在 20 次尝试内找到可用端口"
    exit 1
}

# 生成强随机 PSK
generate_random_psk() {
    openssl rand -base64 24 | tr -d '\n'
}

# 修复 Debian 11 (bullseye) 旧源
fix_debian_sources() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        local codename="${VERSION_CODENAME:-}"
        if [ "$codename" = "bullseye" ]; then
            log_info "检测到 Debian 11 bullseye，修复 APT 源..."
            cat > /etc/apt/sources.list << 'EOF'
deb http://archive.debian.org/debian bullseye main contrib non-free
deb http://archive.debian.org/debian-security bullseye-security main contrib non-free
EOF
            rm -f /etc/apt/sources.list.d/debian.sources 2>/dev/null || true
        fi
    fi
}

# 安装必要工具
install_tools() {
    log_info "安装必要依赖工具..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl wget unzip openssl ufw fail2ban netcat-openbsd iproute2 ca-certificates \
        2>/dev/null || log_warn "部分软件包安装可能不完整，但不影响核心功能"
    log_info "依赖工具安装完成"
}

# 系统网络优化（保留用户原有最佳配置）
system_optimize() {
    log_info "应用系统网络优化..."

    # IPv4 优先
    grep -q "precedence ::ffff:0:0/96 100" /etc/gai.conf 2>/dev/null || \
        echo "precedence ::ffff:0:0/96 100" >> /etc/gai.conf

    # DNS（Cloudflare + Google + IPv6）
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
EOF

    # 时区
    timedatectl set-timezone Asia/Shanghai 2>/dev/null || true

    # BBR + TFO + fq（性能关键优化）
    cat > /etc/sysctl.d/99-network-opt.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_ecn=1
net.core.rmem_max=134217728
net.core.wmem_max=134217728
EOF
    sysctl --system >/dev/null 2>&1 || true

    log_info "系统优化完成（BBR + TFO=3 + 优化 DNS + IPv4优先）"
}

# 获取公网 IP
get_public_ip() {
    log_info "检测公网 IP..."
    IPV4=$(curl -4 -s --max-time 6 https://api.ipify.org || curl -4 -s --max-time 6 https://ifconfig.me || echo "无")
    IPV6=$(curl -6 -s --connect-timeout 4 https://api64.ipify.org || echo "无")
    MAIN_IP=${IPV4:-$IPV6}

    # 尝试获取位置（可选）
    LOCATION=$(curl -s --max-time 5 ipinfo.io/city 2>/dev/null || echo "未知位置")

    if [ "$IPV4" = "无" ] && [ "$IPV6" = "无" ]; then
        log_warn "无法获取公网 IP，请检查网络"
    else
        log_info "公网 IPv4: $IPV4 | IPv6: $IPV6 | 位置: $LOCATION"
    fi
}

# 判断监听地址和 IPv6 启用
determine_listen_mode() {
    if [ "$NET_MODE" = "4" ]; then
        LISTEN_ADDR="0.0.0.0"
        ENABLE_IPV6="false"
        log_info "强制 IPv4 Only 模式"
    else
        LISTEN_ADDR="::"
        # 简单检测 IPv6 连通性
        if [ "$IPV6" != "无" ] && (ping6 -c 1 -W 2 ipv6.google.com >/dev/null 2>&1 || curl -6 -s --max-time 4 https://ipv6.google.com >/dev/null 2>&1); then
            ENABLE_IPV6="true"
            log_info "启用双栈模式 (IPv6 可用)"
        else
            ENABLE_IPV6="false"
            LISTEN_ADDR="0.0.0.0"
            log_warn "IPv6 不可用或检测失败，降级为 IPv4 监听"
        fi
    fi
}

# 下载并安装官方 Snell 二进制 (v5.0.1)
install_snell_binary() {
    local ARCH
    case "$(uname -m)" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="aarch64" ;;
        armv7l)  ARCH="armv7l" ;;
        i386|i686) ARCH="i386" ;;
        *) log_error "不支持的架构: $(uname -m)"; exit 1 ;;
    esac

    local VERSION="v5.0.1"
    local URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-${ARCH}.zip"
    local BIN_PATH="/usr/local/bin/snell-server"

    log_info "准备安装 Snell Server ${VERSION} (${ARCH}) ..."

    # 停止已有服务
    if systemctl is-active --quiet snell 2>/dev/null; then
        log_info "停止现有 Snell 服务..."
        systemctl stop snell || true
    fi

    # 备份旧二进制
    if [ -f "$BIN_PATH" ]; then
        log_warn "检测到已存在二进制，备份为 .bak"
        mv -f "$BIN_PATH" "${BIN_PATH}.bak.$(date +%s)" || true
    fi

    log_info "下载官方二进制: $URL"
    if ! wget --no-check-certificate --timeout=30 -qO /tmp/snell.zip "$URL"; then
        log_error "下载失败！请检查网络或手动下载后放置到 /usr/local/bin/snell-server"
        log_error "手动命令参考: wget $URL -O /tmp/snell.zip && unzip ... && mv snell-server $BIN_PATH"
        exit 1
    fi

    unzip -oq /tmp/snell.zip -d /tmp/
    if [ ! -f /tmp/snell-server ]; then
        log_error "解压失败，未找到 snell-server"
        exit 1
    fi

    mv /tmp/snell-server "$BIN_PATH"
    chmod +x "$BIN_PATH"
    rm -f /tmp/snell.zip

    log_info "Snell 二进制安装完成: $BIN_PATH"
}

# 创建配置文件
create_config() {
    mkdir -p /etc/snell

    cat > /etc/snell/snell.conf << EOF
[snell-server]
listen = ${LISTEN_ADDR}:${SNELL_PORT}
psk = ${SNELL_PSK}
ipv6 = ${ENABLE_IPV6}
obfs = off
dns = 8.8.8.8,8.8.4.4,1.1.1.1,9.9.9.9,2606:4700:4700::1111
tfo = true
EOF

    log_info "配置文件已生成: /etc/snell/snell.conf"
}

# 创建 systemd 服务
create_systemd_service() {
    cat > /etc/systemd/system/snell.service << 'EOF'
[Unit]
Description=Snell Proxy Server (Official v5)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/snell-server -c /etc/snell/snell.conf
Restart=always
RestartSec=3
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
SyslogIdentifier=snell

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable snell >/dev/null 2>&1
    log_info "systemd 服务已创建并启用"
}

# 配置防火墙 + fail2ban
setup_firewall_and_fail2ban() {
    log_info "配置 ufw + fail2ban..."

    # 检测 SSH 端口
    local SSH_PORT=22
    if command -v sshd >/dev/null 2>&1; then
        local detected
        detected=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)
        [ -n "$detected" ] && SSH_PORT=$detected
    fi

    # ufw
    ufw default deny incoming >/dev/null 2>&1 || true
    ufw default allow outgoing >/dev/null 2>&1 || true
    ufw allow "${SSH_PORT}/tcp" comment 'SSH' >/dev/null 2>&1 || true
    ufw allow "${SNELL_PORT}/tcp" comment 'Snell' >/dev/null 2>&1 || true
    ufw allow "${SNELL_PORT}/udp" comment 'Snell' >/dev/null 2>&1 || true

    # fail2ban (仅保护 SSH)
    mkdir -p /etc/fail2ban/jail.d
    cat > /etc/fail2ban/jail.d/ssh.conf << 'JAILEOF'
[sshd]
enabled = true
backend = systemd
maxretry = 3
bantime = 7h
findtime = 10m
JAILEOF

    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban >/dev/null 2>&1 || true

    log_info "ufw + fail2ban 配置完成 (SSH 保护: maxretry=3, bantime=7h)"
}

# 配置每周清理任务
setup_weekly_cleanup() {
    log_info "配置每周日 07:07 自动清理任务..."

    cat > /etc/cron.d/snell-cleanup << 'CRONEOF'
7 7 * * 0 root /bin/bash -c '
  echo "[$(date "+%F %T")] Starting weekly cleanup..." >> /var/log/snell-cleanup.log 2>/dev/null || true
  # 清理 Docker（如果存在）
  if command -v docker >/dev/null 2>&1; then
    docker system prune -af --volumes 2>/dev/null || true
  fi
  apt-get clean 2>/dev/null || true
  apt-get autoremove -y 2>/dev/null || true
  journalctl --vacuum-time=7d 2>/dev/null || true
  find /tmp -type f -mtime +7 -delete 2>/dev/null || true
  find /var/tmp -type f -mtime +7 -delete 2>/dev/null || true
  echo "[$(date "+%F %T")] Weekly cleanup completed." >> /var/log/snell-cleanup.log 2>/dev/null || true
' 2>/dev/null || true
CRONEOF

    chmod 644 /etc/cron.d/snell-cleanup 2>/dev/null || true
    systemctl reload cron 2>/dev/null || true

    log_info "每周清理任务已设置"
}

# 启动服务并验证
start_service() {
    log_info "启动 Snell 服务..."
    systemctl restart snell

    sleep 2
    if systemctl is-active --quiet snell; then
        log_info "✅ Snell 服务启动成功！"
        systemctl status snell --no-pager -l | head -n 8
    else
        log_error "Snell 服务启动失败，请检查日志: journalctl -u snell -n 50"
        exit 1
    fi
}

# 输出最终信息
print_summary() {
    echo ""
    echo "=============================="
    echo -e "${GREEN} Snell 原生部署完成 (v5.0.1) ${NC}"
    echo "=============================="
    echo " 位置     : $LOCATION"
    echo " IPv4     : $IPV4"
    echo " IPv6     : $IPV6"
    echo " 监听地址 : ${LISTEN_ADDR}:${SNELL_PORT}"
    echo " PSK      : $SNELL_PSK"
    echo " 模式     : $([ "$NET_MODE" = "4" ] && echo "IPv4 Only" || echo "Dual Stack (若可用)")"
    echo " Fail2ban : maxretry=3, bantime=7h (仅保护 SSH)"
    echo " 每周清理 : 每周日 07:07 (Asia/Shanghai)"
    echo "=============================="
    echo ""
    echo -e "${BLUE}Surge / Stash / sing-box 配置示例：${NC}"
    echo "Snell_${SNELL_PORT} = snell, ${MAIN_IP}, ${SNELL_PORT}, psk=${SNELL_PSK}, version=5, tfo=true, reuse=true, ecn=true"
    echo ""
    echo -e "${YELLOW}常用管理命令：${NC}"
    echo "  systemctl status snell          # 查看状态"
    echo "  journalctl -u snell -f          # 实时日志"
    echo "  systemctl restart snell         # 重启服务"
    echo "  ufw status numbered             # 防火墙规则"
    echo "  cat /etc/snell/snell.conf       # 查看配置"
    echo "=============================="
    echo ""
    log_info "部署完成！享受极速稳定的 Snell 体验～"
}

# ==================== 主流程 ====================
main() {
    echo "=============================="
    echo " Snell 原生部署脚本（稳定优化版）"
    echo "=============================="

    check_root

    # 参数补全：端口随机 + PSK 强随机
    if [ -z "$SNELL_PORT" ]; then
        SNELL_PORT=$(generate_random_port)
        log_info "未指定端口，自动生成随机端口: $SNELL_PORT"
    fi
    if [ -z "$SNELL_PSK" ] || [ "$SNELL_PSK" = "kokonoeyukari" ]; then
        SNELL_PSK=$(generate_random_psk)
        log_info "未指定或使用默认弱 PSK，已自动生成强随机 PSK"
    fi

    fix_debian_sources
    install_tools
    system_optimize
    get_public_ip
    determine_listen_mode

    install_snell_binary
    create_config
    create_systemd_service
    setup_firewall_and_fail2ban
    setup_weekly_cleanup
    start_service
    print_summary
}

main "$@"
