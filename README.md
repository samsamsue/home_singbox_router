# Home sing-box Router

把一台 Debian/Ubuntu 服务器变成家用 sing-box 旁路由。

适合这种用法：

- 手机把网关设为旁路由 IP 后分流上网
- 游戏、国内 App 尽量直连
- 国外流量走订阅节点
- 用 `sb` 菜单管理，不手改配置文件

## 一键安装

在服务器上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/samsamsue/home_singbox_router/main/bootstrap.sh | sudo sh
```

如果 GitHub 下载慢，可以临时加下载代理：

```bash
curl -fsSL https://raw.githubusercontent.com/samsamsue/home_singbox_router/main/bootstrap.sh | sudo env DOWNLOAD_PROXY=http://127.0.0.1:7890 sh
```

脚本会提示输入：

- LAN 网卡
- 旁路由 LAN IP
- LAN 网段
- 代理端口
- 面板端口
- 面板密钥
- DNS
- Clash/Mihomo 订阅地址

看不懂的地方直接回车，保留默认值即可。订阅地址可以直接填 Clash 可用的订阅链接。

安装完成后会显示：

```text
Panel: http://旁路由IP:9091/ui/
Proxy: http://旁路由IP:7890
Menu: sudo sb
```

## 手机怎么设置

在家里的 Wi-Fi 高级设置里：

```text
网关：旁路由 LAN IP，例如 192.168.3.88
DNS：223.5.5.5 或 119.29.29.29
```

目前不要求把 DNS 设置成旁路由 IP。

## 管理菜单

安装后运行：

```bash
sudo sb
```

菜单功能：

- 查看运行状态
- 重启 sing-box
- 查看日志
- 显示面板和代理地址
- 用提示输入修改基础设置
- 更新订阅
- 更新 MetaCubeXD Web 面板
- 检查配置
- 重新应用旁路由转发/NAT
- 干净卸载

为了兼容习惯，也会创建 `sudo sc`，但推荐记 `sudo sb`。

## Web 面板

打开：

```text
http://旁路由IP:9091/ui/
```

后端地址：

```text
http://旁路由IP:9091
```

密钥就是安装时设置的面板密钥。

如果通过 ZeroTier 远程管理，`sudo sb` 会自动显示 ZeroTier 面板地址。

## 显式代理

代理地址：

```text
http://旁路由IP:7890
```

Windows 上可以这样测试：

```powershell
curl.exe https://api.ipify.org --proxy http://旁路由IP:7890
```

## 卸载

运行：

```bash
sudo sb
```

选择 `Uninstall cleanly`，按提示输入：

```text
UNINSTALL
```

卸载前会自动备份到：

```text
/root/home-router-singbox-uninstall-backup-时间.tar.gz
```

会清理：

- `sb`/`sc` 命令
- home-router systemd 服务和 timer
- sing-box 配置
- MetaCubeXD 面板文件
- 本脚本创建的旁路由转发/NAT 规则

卸载时会询问是否连 `sing-box` 软件包一起卸载。直接回车就是不卸载软件包，只清理本项目内容。

## 高级用法

如果不想交互输入，可以先准备配置文件：

```bash
cp router.conf.example router.conf
sudo ./install.sh
```

配置文件会被安装到：

```text
/etc/home-router-singbox/router.conf
```

真实订阅地址、面板密钥、节点文件不要提交到公开 GitHub。

## 常用命令

```bash
sudo sb
systemctl status sing-box
journalctl -u sing-box -f
sing-box check -C /etc/sing-box
```
