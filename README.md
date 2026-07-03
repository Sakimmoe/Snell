# Snell V5 Docker 一键部署

这是一个支持参数化部署与系统内核自动优化的 Snell V5 一键脚本。脚本内不写死任何敏感配置，适合托管在公开的 GitHub 仓库。

## 部署方法

在服务器终端运行以下命令，**并在末尾依次填入端口、密码和网络模式**：

    bash <(curl -sL https://raw.githubusercontent.com/Sakimmoe/Snell/refs/heads/main/install.sh) 端口 密码 模式

**示例（默认双栈）：**

    bash <(curl -sL https://raw.githubusercontent.com/Sakimmoe/Snell/refs/heads/main/install.sh) 26216 MyPass123

> **参数说明：**
> - **模式**（可选）：`d` 为双栈（默认），`4` 为纯 IPv4，`6` 为纯 IPv6。

## 自动更新与重置

本脚本内置了智能清理逻辑。当你需要修改端口、密码或更新 Snell 版本时，**无需手动删除，直接重新运行上面的安装命令即可**。脚本会自动识别并清理旧环境，完成无缝升级。

## 日常管理

所有配置文件及数据存放于 `/root/snelldocker` 目录下。

- **查看运行日志：** `docker logs snell`
- **重启 Snell 服务：** `cd /root/snelldocker && docker compose restart`
- **查看容器状态：** `docker ps -a | grep snell`

## 卸载

如需彻底移除 Snell 服务及相关配置：

    cd /root/snelldocker && docker compose down
    rm -rf /root/snelldocker
