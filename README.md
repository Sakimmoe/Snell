# Snell V5 Docker 一键部署脚本

这是一个支持参数化部署与系统内核自动优化的 Snell V5 一键安装脚本。脚本内不写死任何敏感配置，适合托管在公开的 GitHub 仓库。
脚本会自动开启BBR、IPV4优先、改时区为中国上海、更改适合的DNS，非常推荐一台全新环境的翻墙机器的部署。
至于Snell协议是非安全请自行判断，个人使用两年，IP从未墙过，我个人也是主用IPV6的，所以也不太在意IPV4墙不墙的。

## 部署方法

在服务器终端运行以下命令，并在末尾依次填写端口、密码和模式：

```bash
bash <(curl -sL https://raw.githubusercontent.com/Sakimmoe/Snell-Docker/main/install.sh) 端口 密码 模式
```
不填写端口密码模式的话默认开启双栈，端口为26216 密码为kokonoeyukari

### 示例（IPv4 + IPv6 双栈）

```bash
bash <(curl -sL https://raw.githubusercontent.com/Sakimmoe/Snell-Docker/main/install.sh) 26216 kokonoeyukari
```

### 参数说明

* 端口：Snell 监听端口
* 密码：Snell PSK 密钥
* 模式（可选）：

  * 不填写：IPv4 + IPv6 双栈（默认）
  * 4：仅 IPv4

### IPv4 Only 示例

```bash
bash <(curl -sL https://raw.githubusercontent.com/Sakimmoe/Snell-Docker/main/install.sh) 26216 kokonoeyukari 4
```

## 自动更新与重置

本脚本内置自动清理逻辑。当需要修改端口、密码或更新 Snell 版本时，无需手动删除旧环境，直接重新运行安装命令即可。

脚本会自动识别并清理旧环境，完成重新部署。

## 日常管理

所有配置文件及数据存放于：

```text
/root/snelldocker
```

常用命令：

```bash
# 查看实时日志
docker logs -f snell

# 重启服务
cd /root/snelldocker && docker compose restart

# 查看容器状态
docker ps -a | grep snell
```

## 卸载

如需彻底移除 Snell 服务及相关配置：

```bash
cd /root/snelldocker && docker compose down
rm -rf /root/snelldocker
```
