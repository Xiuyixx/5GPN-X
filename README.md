# 5GPN-X

服务器端透明代理网关：客户端无需安装代理软件，通过加密 DNS 和服务端分流访问网络。

- 默认透明代理客户端网段：`172.22.0.0/16`
- 项目版本：**1.1.18**（见 [CHANGELOG](CHANGELOG.md)）
- 支持：Ubuntu 20.04+、Debian 11+、RHEL 系 8+、Fedora 39+；`amd64` / `arm64`

> [!IMPORTANT]
> 本项目适用于合法的企业专网、定向内网卡、测试和学习场景。它不是通用 VPN，也不会替代客户端网络接入条件。

## 快速开始

### 1. 安装前准备

1. 准备一台具有公网 IPv4 的 Linux 服务器，以 root 权限运行安装器。
2. 将一个域名的 A 记录指向服务器公网 IPv4；Cloudflare 请使用“仅 DNS/灰云”。
3. 按需放行端口：
   - 公网 TCP `80`：Let's Encrypt 证书验证
   - 公网 TCP `853`：DNS over TLS（DoT）
   - 客户端网段 TCP `80/443`、UDP `443`：透明代理
   - 公网或可访问范围 TCP `8111`：iOS 描述文件下载
4. 保留云厂商控制台或其他带外入口。默认 `FIREWALL_MODE=preserve`，安装器不会接管现有主机防火墙。

最低内存为 512 MB，推荐 1 GB 以上；低于约 1 GB 时会自动使用低内存配置。

### 2. 首次安装

```bash
curl -fsSL https://raw.githubusercontent.com/Xiuyixx/5GPN-X/main/install.sh | sudo bash
```

按提示输入 DoT 域名。自动化安装至少提供 `DOMAIN`，可选提供 `EMAIL`：

```bash
curl -fsSL https://raw.githubusercontent.com/Xiuyixx/5GPN-X/main/install.sh | \
  sudo env DOMAIN=dns.example.com EMAIL=admin@example.com bash
```

- 安装日志：`/var/log/5gpn-install.log`
- 源码目录：`/opt/5gpn-source`
- 运行数据：`/opt/5gpn`

> 环境变量必须写在管道右侧的 `sudo env ... bash` 中，不能只写在 `curl` 前面。

### 3. 客户端接入

- **Android**：设置 → 网络和互联网 → 私人 DNS，填写 DoT 域名。
- **iOS / iPadOS**：扫描安装时生成的二维码，或打开：
  `http://<你的域名>:8111/ios-dot.mobileconfig`
  描述文件名为 `5GPN-X`，仅在蜂窝网络启用 DoT，连接 Wi‑Fi 时自动停用。重新生成：
  `sudo /opt/5gpn/bin/5gpn-ctl -ios`（完整源码目录也可运行 `./install.sh -ios`）。
- **Windows / macOS / Linux**：系统 DoT 设置，或使用 Stubby / cloudflared 指向域名的 `853` 端口。

## 能力与工作方式

```text
iPhone 蜂窝 DoT ─┐
                 ├─► DNS 分流 ─► 国内目标：返回真实地址，客户端直连
Android 私人 DNS ─┘          └► 其他目标：返回网关地址
                                      │
                              SNI / Host / DNS 识别
                                      │
                              本机直出或节点出口
```

- **加密 DNS**：设备通过 DoT 连接服务器，国内域名优先使用国内 DNS。
- **透明代理**：指定客户端网段的 TCP / QUIC 流量由网关按规则转发。
- **多出口**：支持本机直出、WireGuard，以及 SOCKS5、SS、VMess、Trojan、VLESS、Hysteria2、TUIC、AnyTLS、HTTP 等节点。
- **智能分流**：按域名、IP、规则集或策略分类选择出口。
- **Telegram Bot**：查看状态、切换出口、管理规则和 DNS、生成 iOS 二维码。
- **邮件兼容**：Gmail/Googlemail 的 IMAP、SMTP、POP 主机名保持真实地址，避免邮件端口被错误送入 Web 代理。
- **低内存适配**：自动减少缓存、构建并发和服务资源占用。

当前透明代理按 IPv4 设计，DNS 不返回 IPv6 地址；其他来源可使用 DNS，但不会自动获得透明代理能力。

## 日常管理

```bash
sudo /opt/5gpn/bin/5gpn-ctl --status
sudo /opt/5gpn/bin/5gpn-ctl --update-rules
sudo /opt/5gpn/bin/5gpn-ctl --renew-cert
sudo /opt/5gpn/bin/5gpn-ctl -ios
sudo /opt/5gpn/bin/5gpn-ctl --list-exits
sudo /opt/5gpn/bin/5gpn-ctl --check-exits
sudo /opt/5gpn/bin/5gpn-ctl --setup-tgbot
sudo /opt/5gpn/bin/5gpn-ctl --uninstall
```

常用配置命令：

```bash
sudo /opt/5gpn/bin/5gpn-ctl --set-dot-domain dns.example.com
sudo /opt/5gpn/bin/5gpn-ctl --set-dns "1.1.1.1 8.8.8.8" "223.5.5.5 119.29.29.29"
```

不要直接编辑生成的配置；出口、规则、DNS 和 Bot 优先使用 `5gpn-ctl` 或 Telegram Bot 管理。

## 升级与故障排查

### 升级

重复执行同一条安装命令即可。安装器会根据完整 Git commit 自动判断首次安装、升级或当前版本：

- 保留域名、DNS、出口、规则、证书和 Bot 状态。
- 升级前在 `/var/backups/5gpn/upgrade.*` 保存 root-only 备份。
- 只重启升级前已经运行的服务，不会擅自启用停用的可选服务。
- 失败会保留 `.install-attempt`、`.upgrade-attempt`、备份和日志，修复后可重试。

固定到已审核提交：

```bash
curl -fsSL https://raw.githubusercontent.com/Xiuyixx/5GPN-X/main/install.sh | \
  sudo env PGW_COMMIT=<40位完整SHA> bash
```

### 安装或升级失败

```bash
sudo tail -n 120 /var/log/5gpn-install.log
sudo find /var/backups/5gpn -maxdepth 2 -type f -name '*.log' -print
sudo systemctl --failed --no-legend
```

### 服务状态与日志

```bash
sudo systemctl status mosdns sniproxy wa-shim quic-proxy --no-pager -l
sudo journalctl -u mosdns -u sniproxy -u wa-shim -u quic-proxy -u 5gpn-tgbot -n 100 --no-pager
```

如果所有域名都解析失败，先检查 `mosdns`、TCP `853`、证书和域名解析；如果只有部分域名异常，先运行 `--update-rules`。证书签发还要求域名 A 记录正确且公网 TCP `80` 可达。

更完整的安装、升级和恢复说明见 [docs/INSTALL.md](docs/INSTALL.md)。

## 文档导航

- [安装、升级与排障](docs/INSTALL.md)
- [日常管理与配置参考](docs/GUIDE.md)
- [项目结构与开发检查](docs/DEVELOPMENT.md)
- [版本变更记录](CHANGELOG.md)

## 安全边界

- mihomo、mosdns 使用锁定版本和 SHA256 校验；校验不匹配会中止安装。
- Go 组件和 sniproxy 使用固定来源/版本；修改依赖版本必须同步核验摘要。
- Certbot 优先使用系统包；遇到 Python 依赖不兼容时停止并提示修复，不以 root 无约束升级 pip。
- 默认不清空主机防火墙；`FIREWALL_MODE=auto` 仅增量放行，`managed` 才接管 INPUT 防火墙，并会先处理检测到的 SSH 端口。
- Telegram Bot 需要 root 执行服务管理、路由、防火墙和 `/etc` 配置写入；敏感配置文件按 root-only 权限保存。
- 首次安装不是全量原子事务；升级有局部事务与备份保护。请在维护窗口操作并保留带外入口。
- 安装管道信任 GitHub `main`；固定 SHA 可复现源码，但不等同于发布签名认证。

## 项目结构

```text
install.sh       # 唯一安装入口，也是管理 CLI 的来源
lib/             # Shell 模块、Python/Go 组件和配置模板
docs/            # 安装、管理、开发文档
tests/           # Shell / Python / PowerShell / Go 回归测试
.github/         # CI 与上游依赖版本检查
VERSION          # 项目展示版本，不替代部署 commit
```

## 免责声明

本项目仅用于合法的网络互通、企业专网、测试和学习场景。使用者需自行确认部署和使用行为符合所在地法律法规、云服务商条款及目标网络服务条款。项目不保证在所有网络环境下可用，也不承诺规避封锁、审查或主动探测；因误用、配置错误、服务中断等造成的后果由使用者自行承担。
