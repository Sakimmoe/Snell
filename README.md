# Snell V5 一键部署脚本

> 一个简单、高效的 **Snell V5** 代理服务一键部署脚本，专为 Debian / Ubuntu 系统设计。  
> 支持参数化配置、系统网络自动优化，即开即用。

---

## 简介

本脚本可以一键在 Linux 服务器上完成 Snell v5.0.1 的部署，自动处理依赖安装、网络优化、systemd 服务配置、UFW 防火墙和定时清理任务。

**推荐使用场景**：全新服务器快速搭建个人 Surge Snell 代理节点。

## 特性

- ✅ 自动下载安装官方 Snell v5.0.1（支持 `amd64` / `aarch64`）
- ✅ 自动启用 **BBR** 拥塞控制 + `fq` qdisc
- ✅ 配置 Cloudflare + Google 公共 DNS（同时支持 IPv4/IPv6）
- ✅ 设置 IPv4 优先解析（`gai.conf`）
- ✅ 使用 systemd 管理服务（开机自启 + 失败自动重启）
- ✅ 自动配置 UFW 防火墙（仅开放 SSH + Snell 端口）
- ✅ 内置每周自动清理任务（apt 缓存、journal 日志、/tmp 临时文件）
- ✅ 支持 **双栈（IPv4+IPv6）** 或 **纯 IPv4** 模式
- ✅ 部署成功后自动输出 Snell 客户端配置
- ✅ 重新运行脚本即可更新二进制或修改端口/密码（自动覆盖旧配置）

## 部署方法

使用 **root** 用户在服务器终端执行以下命令：

```bash
bash <(curl -sL https://raw.githubusercontent.com/Sakimmoe/Snell/main/install.sh) [端口] [密码] [模式]
```

> **提示**：请将上面命令中的 `[端口] [密码] [模式]` 替换为你自己 需要自定义的参数。

### 默认值（不带参数时）

| 参数 | 默认值          | 说明             |
|------|-----------------|------------------|
| 端口 | `26216`         | Snell 监听端口   |
| 密码 | `kokonoeyukari` | PSK 密钥         |
| 模式 | 双栈            | IPv4 + IPv6      |

### 参数说明

| 参数 | 位置 | 说明                                      | 示例          |
|------|------|-------------------------------------------|---------------|
| 端口 | $1   | Snell 服务监听端口                        | `26216`       |
| 密码 | $2   | Snell PSK 密钥（建议使用复杂密码）        | `kokonoeyukari` |
| 模式 | $3   | `4` = 仅监听 IPv4<br>留空 = 双栈模式      | `4`           |

### 使用示例

**1. 默认双栈部署（最简单）**

```bash
bash <(curl -sL https://raw.githubusercontent.com/Sakimmoe/Snell/main/install.sh)
```

**2. 自定义端口 + 密码（双栈）**

```bash
bash <(curl -sL https://raw.githubusercontent.com/Sakimmoe/Snell/main/install.sh) 12345 MyStrongPSK2026
```

**3. 仅 IPv4 模式**

```bash
bash <(curl -sL https://raw.githubusercontent.com/Sakimmoe/Snell/main/install.sh) 26216 kokonoeyukari 4
```

## 部署成功后

脚本执行完毕会输出以下信息：

```
==============================
 ✅ Snell 部署完成
==============================
 IPv4 : xxx.xxx.xxx.xxx
 IPv6 : xxxx:xxxx:xxxx::xxxx
 Port : 26216
 PSK  : kokonoeyukari
 Mode : Dual Stack
==============================
Surge 配置：
Snell_26216 = snell, your_server_ip, 26216, psk=kokonoeyukari, version=5, reuse=true, ecn=true
==============================
```


## 日常管理命令

```bash
# 查看服务状态
systemctl status snell

# 实时查看日志
journalctl -u snell -f

# 重启服务
systemctl restart snell

# 停止服务
systemctl stop snell

# 禁用开机自启
systemctl disable snell
```

**重要文件位置**：

- 主程序：`/usr/local/bin/snell-server`
- 配置文件：`/etc/snell/snell-server.conf`
- systemd 服务文件：`/etc/systemd/system/snell.service`

## 修改配置 / 更新 Snell

**无需卸载**，直接**重新运行部署命令**即可。

脚本会自动：
1. 停止旧服务
2. 下载/更新 Snell 二进制
3. 覆盖配置文件
4. 重启服务

非常适合修改端口、密码或重新部署。

## 卸载

```bash
# 停止并禁用服务
systemctl stop snell 2>/dev/null || true
systemctl disable snell 2>/dev/null || true
rm -f /etc/systemd/system/snell.service
systemctl daemon-reload

# 删除程序与配置
rm -f /usr/local/bin/snell-server
rm -rf /etc/snell

# 删除定时清理任务
rm -f /etc/cron.d/snell-cleanup

# 可选：删除 UFW 规则（请把 26216 替换为实际端口）
ufw delete allow 26216/tcp 2>/dev/null || true
ufw delete allow 26216/udp 2>/dev/null || true

echo "✅ Snell 已完全卸载"
```

## 注意事项

1. **必须使用 root 用户运行**，脚本会自动检测 `$EUID`。
2. 脚本会修改 `/etc/resolv.conf` 和 `/etc/gai.conf`，如有特殊 DNS 需求请提前备份。
3. UFW 默认拒绝所有入站连接，仅放行 SSH（自动检测端口）和 Snell 端口。请同步在云服务商安全组/防火墙中放行对应端口。
4. 支持架构：`x86_64` / `amd64` 和 `aarch64` / `arm64`。
5. Snell 协议是否被墙、是否安全，请自行判断和测试。
6. 本脚本仅供学习与个人测试使用，请勿用于任何非法用途。

## 反馈与贡献

欢迎提交 Issue 和 Pull Request 帮助改进脚本！

---

