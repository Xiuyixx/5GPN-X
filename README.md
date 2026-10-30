# 5GPN-X

服务器端透明代理网关：让指定私网中的设备通过加密 DNS 和透明代理访问网络，客户端无需安装代理软件。默认代理客户端网段为 `172.22.0.0/16`；其他来源可使用 DNS，但不会自动获得透明代理能力。

## 环境要求

主流 Linux 发行版（Ubuntu 20.04+ / Debian 11+ / RHEL 系 8+ / Fedora 39+），`amd64` 或 `arm64`，root 权限，公网 IPv4，以及一个 A 记录指向服务器的域名。内存最低 512 MB，推荐 1 GB+。

## 安装

项目版本：**1.1.5**（见 [CHANGELOG](CHANGELOG.md)）。首次安装和升级使用同一个入口：

```bash
curl -fsSL https://raw.githubusercontent.com/Xiuyixx/5GPN-X/main/install.sh | sudo bash
```

- **安装前**：把域名指向服务器公网 IP，并放行所需端口：公网 TCP `853`；证书验证用 TCP `80`；`172.22.0.0/16` 私网客户端使用 TCP `80/443` 和 UDP `443`；iOS 描述文件使用 TCP `8111`。APNs 域名返回真实地址，设备所在网络需允许直达 Apple TCP `5223/443`，无需在本网关新增入站端口。
- **首次安装**：按提示输入域名，等待安装完成。
- **更新版本**：重新执行上面的命令，已有配置会保留。
- **遇到错误**：先查看终端给出的日志，不要删除配置或备份。

默认不接管主机防火墙。需要放行哪些端口、如何自动安装，以及失败怎么处理，见 [安装与排障指南](docs/INSTALL.md)。

## 客户端配置

- Android：`设置 -> 网络和互联网 -> 私人 DNS`，填入安装时配置的域名。
- iOS / iPadOS：扫描安装时生成的二维码，或访问 `http://<你的域名>:8111/ios-dot.mobileconfig` 安装描述文件（仅蜂窝网络启用 DoT，Wi-Fi 自动停用）。重新生成：`sudo /opt/5gpn/bin/5gpn-ctl -ios`（源码入口兼容：`./install.sh -ios`）
- Windows / macOS / Linux：系统 DoT 设置或 Stubby / cloudflared 指向服务器域名 `853` 端口。

## 管理命令

```bash
sudo /opt/5gpn/bin/5gpn-ctl --status              # 查看状态
sudo /opt/5gpn/bin/5gpn-ctl --update-rules        # 更新 GFWList/ChinaList 并重载 mosdns
sudo /opt/5gpn/bin/5gpn-ctl --renew-cert          # 续期证书
sudo /opt/5gpn/bin/5gpn-ctl --set-dot-domain dns.example.com
sudo /opt/5gpn/bin/5gpn-ctl --set-dns "1.1.1.1 8.8.8.8" "223.5.5.5 119.29.29.29"
sudo /opt/5gpn/bin/5gpn-ctl -ios                  # 重新生成 iOS 描述文件和二维码
sudo /opt/5gpn/bin/5gpn-ctl --list-exits          # 列出出口
sudo /opt/5gpn/bin/5gpn-ctl --check-exits         # 检测出口连通性
sudo /opt/5gpn/bin/5gpn-ctl --setup-tgbot         # 配置 Telegram Bot
sudo /opt/5gpn/bin/5gpn-ctl --uninstall           # 卸载
```

## 功能与原理

- **加密 DNS**：设备通过 DoT 连接服务器，国内域名优先使用国内 DNS。
- **透明代理**：指定私网设备访问其他域名时，由服务器转发 TCP / QUIC 流量。
- **多种出口**：支持本机直出、WireGuard，以及 SOCKS5、SS、VMess、Trojan、VLESS、Hysteria2、TUIC、AnyTLS、HTTP 等节点。
- **按需分流**：可按域名、IP 或规则集选择不同出口。
- **聊天管理**：通过 Telegram Bot 查看状态、切换出口、管理规则和 DNS。
- **低内存适配**：内存不超过 1 GB 时自动减少资源占用。

当前透明代理按 IPv4 设计，DNS 不返回 IPv6 地址。默认仅为 `172.22.0.0/16` 网段提供透明代理；其他来源正常解析，不会自动进入代理。技术细节见 [运行原理](docs/GUIDE.md#运行原理)。

## 更多用法

- [出口管理与智能分流](docs/GUIDE.md#出口管理)：添加节点、切换出口、按域名分流。
- [Telegram Bot](docs/GUIDE.md#telegram-bot)：设置管理员并通过聊天面板管理。
- [配置参考](docs/GUIDE.md#配置参考)：路径、端口、环境变量与防火墙选项。
- [安装、升级与排障](docs/INSTALL.md)：备份、失败日志、证书与服务检查。

## 项目结构

```text
install.sh       # 唯一安装入口，也是管理 CLI 的来源
lib/             # 按职责拆分的 Shell 模块、Python/Go 组件与配置模板
docs/            # 安装排障、日常管理和配置参考
tests/           # Shell / Python / PowerShell / Go 回归测试
.github/         # CI 与上游依赖版本检查
VERSION          # 项目展示版本（不替代部署提交标记）
```

开发与维护说明见 [项目结构与检查](docs/DEVELOPMENT.md)。

## 免责声明

本项目仅用于合法的网络互通、企业专网、测试和学习场景。使用者需自行确认部署和使用行为符合所在地法律法规、云服务商条款及目标网络服务条款。项目不保证在所有网络环境下可用，也不承诺规避封锁、审查或主动探测；因误用、配置错误、服务中断等造成的后果由使用者自行承担。

### 加固边界

- Go 下载使用官方 SHA256，sniproxy 源码固定 commit；修改依赖版本必须同步核验摘要，固定旧版本不等于自动获得上游安全更新。
- Certbot 优先使用系统包；Python 依赖不兼容时停止并提示人工修复，不以 root 无约束升级 pip 包。
- Telegram Bot 仍需要 root 执行服务管理、路由、防火墙及 `/etc` 配置写入。仅限制新文件权限和 core dump，不宣称已做非 root helper 隔离；贸然使用只读系统、私有网络或设备隔离会破坏现有管理功能。
- 安装阶段失败会中止并报告。系统包、运行时网络规则和服务变更不支持跨阶段的全量事务回滚；请保留配置备份和控制台访问，在维护窗口安装。现有 DNS/出口局部恢复不等于整个安装可原子回退。
- 项目版本见本页与 CHANGELOG；安装仍固定完整 Git commit，依赖版本不是项目版本。
