# BypassProxy

旁路由代理助手。把一台 Debian/Ubuntu 设备变成透明分流代理旁路由：国内直连，国外走订阅节点，手机只需要把网关指向它。

适合这种用法：

- 手机把网关设为旁路由 IP 后分流上网
- 游戏、国内 App 尽量直连
- 国外流量走订阅节点
- 用 `bp` 菜单管理，不手改配置文件

适用范围：

- Debian/Ubuntu 服务器，建议直接装在实体机、虚拟机或 LXC 上
- 服务器和手机在同一个家里 LAN，手机手动把网关设成旁路由 IP
- WSL 可以用来测试菜单、订阅、面板和显式代理，不适合作为真正的家用旁路由
- 这不是 OpenWrt 固件，也不接管主路由 DHCP

默认分流策略：

- 国内域名走 `geosite-cn` 规则集直连
- 国内 IP 走 `geoip-cn` 规则集直连
- 常见国内 App、游戏、网盘域名额外兜底直连
- 其他流量默认走订阅代理

## 一键安装

在服务器上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/samsamsue/BypassProxy/main/bootstrap.sh | sudo sh
```

如果 GitHub 访问慢，脚本启动后会自动尝试几个常见 GitHub 下载加速前缀。
下载大文件时会显示进度；如果 30 秒内速度低于约 10KB/s，会自动尝试下一个下载地址。

如果连上面这条命令里的 `raw.githubusercontent.com` 都打不开，需要先用你自己的代理或 raw 加速地址把 `bootstrap.sh` 拉下来。例如：

```bash
curl -fsSL https://raw.githubusercontent.com/samsamsue/BypassProxy/main/bootstrap.sh | sudo env DOWNLOAD_PROXY=http://127.0.0.1:7890 sh
```

也可以手动指定 GitHub 下载加速前缀：

```bash
curl -fsSL https://raw.githubusercontent.com/samsamsue/BypassProxy/main/bootstrap.sh | sudo env GITHUB_DOWNLOAD_PREFIX=https://你的加速地址/ sh
```

脚本会提示输入：

- 代理端口
- 面板端口
- 面板密钥，默认 `abc123`
- 订阅/节点地址

LAN 网卡、旁路由 LAN IP、LAN 网段会自动检测。正常直接回车确认即可；检测不对时再选择修改。
DNS 默认使用 `223.5.5.5` 和 `119.29.29.29`，安装时不用填。

看不懂的地方直接回车，保留默认值即可。订阅地址可以填 Clash/Mihomo 订阅、v2ray base64 订阅，或直接填 `vmess://` 节点链接。
多个订阅/节点地址用空格分隔。

安装完成后会显示：

```text
Panel: http://旁路由IP:9091/ui/
Proxy: http://旁路由IP:7890
Menu: sudo bp
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
sudo bp
```

菜单功能：

- 查看运行状态
- 重启 sing-box
- 查看日志
- 显示面板和代理地址
- 显示面板密钥
- 用提示输入修改基础设置
- 更新订阅
- 更新国内分流规则
- 更新 MetaCubeXD Web 面板
- 更新本项目脚本
- 检查配置
- 网络诊断
- 重新应用旁路由转发/NAT
- 干净卸载

主命令是 `sudo bp`。

几个“更新”的区别：

- 更新订阅：重新拉取订阅/节点地址并生成节点，支持多个地址和 `vmess://`
- 更新国内分流规则：检查 `geosite-cn`、`geoip-cn` 是否有新版本，有变化才下载
- 更新 Web 面板：检查 MetaCubeXD 最新版本，有新版本才更新
- 更新本项目脚本：检查 GitHub 上这个安装器有没有新提交，有新版本才更新

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
新安装默认是 `abc123`，也可以在 `sudo bp` 里修改。普通菜单不会直接显示明文密钥，需要选择“显示面板密钥”并确认后才显示。

如果通过 ZeroTier 远程管理，`sudo bp` 会自动显示 ZeroTier 面板地址。

## 手机设网关后不能上网

先在旁路由服务器运行：

```bash
sudo bp
```

然后按这个顺序处理：

- 选择“网络诊断”，看有没有 `FAIL`
- 选择“应用旁路由转发/NAT”，重新写入转发规则
- 再选择“检查配置”，确认 sing-box 配置通过

真正关键的是：旁路由必须打开 IPv4 转发，并且要有 LAN 到 sing-box TUN 的转发/NAT 规则。只装好 sing-box 但没放通内核转发，手机把网关改成旁路由 IP 后就容易表现为不能上网。

网络诊断是通用检查。它会顺便检查 Docker 容器 DNS；如果机器上刚好有 OpenList，会额外测一下天翼云解析，但没有 OpenList 也不会报错。

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
sudo bp
```

选择“干净卸载”，按提示输入：

```text
UNINSTALL
```

卸载前会自动备份到：

```text
/root/bypassproxy-uninstall-backup-时间.tar.gz
```

会清理：

- `bp` 命令
- BypassProxy systemd 服务和 timer
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
/etc/bypassproxy/router.conf
```

真实订阅地址、面板密钥、节点文件不要提交到公开 GitHub。

## 常用命令

```bash
sudo bp
systemctl status sing-box
journalctl -u sing-box -f
sing-box check -C /etc/sing-box
```
