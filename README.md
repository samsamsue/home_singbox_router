# Home Router sing-box Installer

一键把 Debian 服务器配置成 sing-box TUN 旁路由，并提供：

- TUN 旁路由
- `7890` mixed 显式代理
- `9091` MetaCubeXD 面板
- 单网卡旁路由转发/NAT 保活
- 可配置的 LAN 网卡、网段、端口和面板密钥

## 1. 准备配置

```bash
cp router.conf.example router.conf
```

编辑 `router.conf`：

```text
LAN_IF=enp3s0
LAN_NET=192.168.3.0/24
LAN_IP=192.168.3.88
PROXY_PORT=7890
PANEL_PORT=9091
PANEL_SECRET=change-me
SUBSCRIBE_URL='https://example.com/api/v1/client/subscribe?token=...'
```

## 2. 准备节点

推荐方式是在 `router.conf` 里填写 Clash/Mihomo 订阅：

```text
SUBSCRIBE_URL='https://example.com/api/v1/client/subscribe?token=...'
SUBSCRIBE_USER_AGENT=clash.meta
```

安装时会自动下载订阅并生成 sing-box 节点配置。

也可以手动创建 `secrets/outbounds.json`。它是 sing-box outbound 列表，只放真实代理节点。

如果你已有 Clash/Mihomo 配置，可以转换：

```bash
mkdir -p secrets
python3 scripts/extract-outbounds.py /tmp/ShellCrash/config.yaml secrets/outbounds.json
```

支持当前用到的：

- hysteria2
- vless reality
- vless websocket tls

`secrets/` 默认被 `.gitignore` 忽略，不要提交到公开 GitHub。

## 3. 安装

```bash
sudo ./install.sh
```

如果 GitHub 下载慢，可以临时指定下载代理：

```bash
DOWNLOAD_PROXY=http://127.0.0.1:7890 sudo -E ./install.sh
```

## 4. 客户端设置

家里手机：

```text
网关：LAN_IP，例如 192.168.3.88
DNS：223.5.5.5 或 119.29.29.29
```

目前不要求把 DNS 设为旁路由 IP。

## 5. 面板

打开：

```text
http://LAN_IP:9091/ui/
```

后端地址：

```text
http://LAN_IP:9091
```

密钥：`router.conf` 里的 `PANEL_SECRET`。

如果通过 ZeroTier 远程管理，`sudo sb` 会自动检测 ZeroTier IP 并显示远程面板地址。

## 6. 显式代理

```text
http://LAN_IP:7890
```

测试：

```powershell
curl.exe https://api.ipify.org --proxy http://LAN_IP:7890
```

## 7. 管理

安装后直接运行菜单：

```bash
sudo sb
```

菜单可以：

- 查看状态
- 重启 sing-box
- 看日志
- 显示面板/代理地址
- 用提示输入的方式修改基础配置，回车保留当前值
- 更新订阅
- 检查配置
- 重新应用旁路由转发/NAT

安装器也会创建兼容命令 `sc`，所以 `sudo sc` 仍然可用；推荐记 `sudo sb`。

命令行管理：

```bash
./manage.sh status
./manage.sh restart
./manage.sh logs
./manage.sh check
./manage.sh apply-forward
```

## 安全提醒

不要把真实的 `router.conf` 和 `secrets/outbounds.json` 提交到公开仓库。
公开仓库只适合放模板和脚本。真实节点和密钥请放私有仓库，或单独加密保存。
