# Snell Docker 一键部署

这是一个支持参数化部署的 Snell 脚本。核心优势是不在脚本内写死敏感信息，端口和密码在运行时通过参数传入，非常适合托管在公开的 GitHub 仓库。

## 部署方法

在服务器终端运行以下命令，并在末尾加上你想设置的端口和密码：

```bash
bash <(curl -sL [https://raw.githubusercontent.com/Sakimmoe/Snell/refs/heads/main/install.sh](https://raw.githubusercontent.com/Sakimmoe/Snell/refs/heads/main/install.sh)) 你的端口 你的密码
```

**示例：**
```bash
bash <(curl -sL [https://raw.githubusercontent.com/Sakimmoe/Snell/refs/heads/main/install.sh](https://raw.githubusercontent.com/Sakimmoe/Snell/refs/heads/main/install.sh)) 6666 RandomPass123
```
> 如果不加任何参数直接运行，脚本会使用默认的占位数据（端口 6666，密码 RandomPass123）进行测试。

## 日常管理

部署完成后，所有相关文件（`docker-compose.yml` 和 `snell.conf`）都会存放在 `/root/snelldocker` 目录下。

常用的管理命令：
- **查看运行日志：** `docker logs snell`
- **重启 Snell 服务：** `cd /root/snelldocker && docker compose restart`

## 卸载与重置

如果想修改端口或密码重新部署，必须先清理掉旧的容器和配置文件，否则会冲突。执行以下命令清理：

```bash
cd /root/snelldocker && docker compose down
rm -rf /root/snelldocker
```
清理干净后，重新运行上面的安装命令即可。
