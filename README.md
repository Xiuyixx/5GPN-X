# 高性能反代系统一键部署

> **服务器端透明代理网关。** 由智能 DNS（dnsdist DoT）+ SNI/QUIC 透明代理组成，支持可切换的多协议出口（WireGuard / SS / VMess / Trojan / VLESS / Hysteria2 / TUIC / AnyTLS / SOCKS5 / HTTP）、基于规则的智能分流，以及 Telegram 控制 Bot。客户端只要把 DNS 指向它就行，不需要安装客户端。适合 512 MB VPS。

本项目基于 5G NPN + N6 互通架构，在服务器端部署高性能透明反代基础设施，为终端提供智能 DNS 解析与 SNI 透明代理服务。

## 一键安装

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Xiuyixx/5GPN-X/main/install.sh)"
```

会自动拉取仓库到 `/opt/5gpn` 并运行安装脚本（交互输入你自己的域名）。装好后可随时重进 `/opt/5gpn` 跑 `./install.sh --status` 等管理命令；额外参数会透传给安装脚本，例如 `sudo bash /tmp/5gpn.sh --status`（参数透传给安装脚本）。


## 系统要求

### 支持的操作系统

| 发行版 | 版本 |
|--------|------|
| Ubuntu | 20.04 / 22.04 / 24.04 LTS |
| Debian | 11 / 12 / 13 |
| CentOS / Stream | 7 / 8 / 9 |
| AlmaLinux | 8 / 9 |
| Rocky Linux | 8 / 9 |
| RHEL | 8 / 9 |
| Fedora | 39+ |

### 硬件与架构

- **CPU 架构**: x86_64 (`amd64`) 或 ARM64 (`aarch64`)
- **内存**: 最低 512 MB（脚本会对 ≤ 1GB 主机自动启用低内存模式,见下）
- **网络**: 需要公网 IPv4 地址（用于 Let's Encrypt 证书申请和代理转发）
- **权限**: 必须以 `root` 身份运行安装脚本

## 核心组件

| 组件 | 协议/端口 | 作用 |
|------|-----------|------|
| sniproxy (dlundquist) | TCP 80/443 | SNI 透明代理（HTTP/HTTPS） |
| quic-proxy (Go) | UDP 443 | QUIC SNI 透明代理（HTTP/3） |
| china-dns-race-proxy (Go) | TCP/UDP 127.0.0.1:5301 | ChinaList 上游 DNS 并发竞速与 fallback |
| dnsdist (PowerDNS) | TCP/UDP 53, TCP 853 | 智能 DNS + DoT 服务 |
| Certbot | - | Let's Encrypt 证书自动申请与续期 |

## 访问策略

### DNS / DoT

- **普通 DNS 53 端口**：仅允许 `172.22.0.0/16` 来源访问。
- **DoT 853 端口**：允许所有来源访问，但按来源 IP 区分解析策略。
- **单 IP QPS 限制**：`10000 qps`，超过后由 dnsdist 丢弃。

| 来源 IP | 被墙域名（GFWList） | 国内域名（ChinaList） | 其他海外域名 |
|---------|----------------------|------------------------|--------------|
| `172.22.0.0/16` | 返回服务器本机 IP，进入 TCP/QUIC 代理 | 转发至本机 China DNS 竞速代理 | 返回服务器本机 IP，进入 TCP/QUIC 代理 |
| 其他来源 | 不做代理劫持，正常海外解析 | 转发至本机 China DNS 竞速代理 | 转发至海外 DNS 池 |

国内 DNS：dnsdist 将 ChinaList 查询转发到本机 `china-dns-race-proxy` (`127.0.0.1:5301`)；该代理同时接受 UDP 和 TCP DNS 请求，兼容 dnsdist 的普通 DNS、TCP DNS 和 DoT 转发。代理会先并发查询 `101.226.4.6`、`218.30.118.6`、`180.76.76.76`、`119.29.29.29` 的 UDP 53。如果国内 UDP 无响应，会在 `150ms` 后改用国内 TCP 53；国内 TCP 也无响应时，才启用海外 fallback（默认 `1.1.1.1`、`8.8.8.8`、`22.22.22.22`），避免单个国内 DNS 不通导致页面长时间卡住。

海外 DNS 池：`1.1.1.1`、`8.8.8.8`、`9.9.9.9`。对 `172.22.0.0/16` 私网客户端，非 ChinaList 的 IPv4 查询默认劫持到网关本机 IP，让所有国际 HTTP/HTTPS/QUIC 流量先进入服务器，再由当前出口出站；公网 DoT 客户端仍保持正常海外解析。

ChinaList 查询会强制携带 EDNS Client Subnet：`139.226.48.0/24`，用于让上游按中国大陆客户端位置返回更合适的 IPv4 解析结果。DNS 服务不返回 AAAA 记录，客户端只使用 IPv4。

## 快速开始

一键安装（推荐）：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Xiuyixx/5GPN-X/main/install.sh)"
```

或手动：上传所有文件到服务器后运行：

```bash
chmod +x install.sh
sudo ./install.sh
```

安装过程会自动完成：
- 系统检测与依赖安装
- 交互输入你自己的域名（或通过 `DOMAIN` 环境变量预设）
- 域名 A 记录解析验证
- Let's Encrypt 证书申请
- sniproxy (TCP) 编译安装
- quic-proxy (UDP) 编译安装
- china-dns-race-proxy 编译安装
- dnsdist 配置与启动
- GFWList / ChinaList 规则初始化
- 系统网络优化（BBR、fq、TCP buffer、conntrack、THP、journald 限制等）
- 自动续期与规则更新定时任务

### 域名选择

安装脚本会提示你输入自己的域名（裸域或子域均可）：

```
==================================================
  请输入你自己的域名
==================================================
  示例: dns.example.com 或 example.com
  该域名需要你能管理其 DNS（添加一条 A 记录指向本机）
==================================================

请输入域名: dns.example.com
```

**前提条件**：你必须能管理该域名的 DNS，并在自己的 DNS 服务商处添加一条 A 记录，把该域名指向服务器公网 IP（脚本会在申请证书前显示需要的 IP 并轮询验证解析，最长等待 120 秒）。建议把该记录的 TTL 设小一些（如 60-300）以便快速生效。

> 如需降低被主动探测的概率，可自行使用一个不规则的子域名（如 `a1b2c3.example.com`）。

### 环境变量（非交互式 / 自动化部署）

如果你希望跳过交互提示，可通过 `DOMAIN` 环境变量直接指定完整域名：

```bash
# 直接指定你自己的完整域名，跳过交互输入
export DOMAIN="dns.example.com"
export EMAIL="admin@example.com"   # 用于 Let's Encrypt
./install.sh
```

> 非交互式运行（无 TTY）时必须设置 `DOMAIN`，否则脚本会直接报错退出，而不会卡在输入提示上。A 记录仍需你提前配置好。

### 更改海外上游 DNS 与反代 resolver

安装交互里的 `DNS 设置` 只需要填写一组海外 DNS，上游会同时用于私网 DoT、公网 DoT 和 TCP 反代 resolver，支持逗号或空格分隔：

```bash
export DNS_UPSTREAMS="1.1.1.1,8.8.8.8,9.9.9.9"
./install.sh
```

高级场景仍可分别设置 `PRIVATE_OVERSEAS_DNS`、`PUBLIC_OVERSEAS_DNS`、`SNIPROXY_DNS` 覆盖三处上游。旧参数 `OVERSEAS_DNS` 仍可使用，等同于 `PRIVATE_OVERSEAS_DNS`。

安装脚本会保存配置到 `/etc/dnsdist/.overseas_private_dns`、`/etc/dnsdist/.overseas_public_dns`、`/etc/dnsdist/.sniproxy_dns`，后续执行 `./install.sh --update-rules` 或定时更新规则时会继续使用这些上游配置。

安装脚本会把 sniproxy resolver 写入 `/etc/sniproxy.conf`，并强制 `mode ipv4_only`，避免 sniproxy 绕过自定义解析或优先连接 AAAA 地址。

### 本地补充 GFWList

`172.22.0.0/16` 私网客户端现在默认把非 ChinaList 的 IPv4 查询劫持到网关，因此普通国际站不再依赖 GFWList 覆盖率。`/etc/dnsdist/gfwlist-extra-local.txt` 仍保留用于兼容旧规则和显式标记；每行一个域名，支持 `#` 注释。执行 `./install.sh --update-rules` 或等待定时任务更新后，这些域名会去重追加到 dnsdist 的 GFWList 规则中。

## 客户端配置

### Android (DoT)
设置 → 网络和互联网 → 私人 DNS → 输入脚本生成的域名

### iOS / iPadOS
安装脚本会自动生成 iOS DNS over TLS 描述文件，并在终端输出二维码。iPhone 扫码后可安装描述文件：

```text
http://your-domain.com:8111/ios-dot.mobileconfig
```

该描述文件只在蜂窝网络下启用本系统 DoT DNS；连接 Wi-Fi 时会自动停用，避免影响局域网或家庭 Wi-Fi 的 DNS 策略。

### Windows / macOS / Linux
在系统网络设置中配置 DNS over TLS，或使用 Stubby、cloudflared 等本地 DoT 转发器指向服务器。

## 命令行接口

```bash
./install.sh --status          # 查看运行状态（含当前出口）
./install.sh --update-rules    # 立即更新 GFWList/ChinaList
./install.sh --renew-cert      # 立即续期证书并重载服务
./install.sh --set-dot-domain dns.example.com  # 更改 DoT 域名并重新签发证书
./install.sh --set-dot-domain-force dns.example.com  # 强制更改域名（跳过本次证书签发）
./install.sh --set-dns "1.1.1.1 8.8.8.8"       # 更改海外 DNS，上游同步用于 DoT/sniproxy
./install.sh -ios              # 重新生成 iOS 描述文件并显示二维码
./install.sh --list-exits      # 列出所有出口及当前激活的出口
./install.sh --add-exit <名字> <wg.conf>   # 注册一个 WireGuard 出口
./install.sh --set-exit <名字|local>       # 切换出口（local = 本机直出）
./install.sh --del-exit <名字>             # 删除一个出口
./install.sh --setup-tgbot     # 配置/启用 Telegram 控制 Bot
./install.sh --uninstall       # 卸载所有组件
```


## Telegram 控制 Bot（可选）

安装一个 Telegram Bot,**直接在 Telegram 上用按钮完成运维**:查看状态、切换出口、更新规则、DoT 管理、重启服务、查看日志、调出 iOS 二维码。

**安全模型**:
- Bot Token 存放在 root-only 的 `/opt/proxy-gateway/etc/tgbot.env`(`chmod 600`),由 systemd `EnvironmentFile` 注入。
- **只有白名单数字 ID(`TG_ADMIN_IDS`)能操作**,其余消息一律忽略。
- 所有操作映射到**固定命令白名单**,出口名/服务名经严格正则与允许列表校验,**绝不把用户输入拼进 shell**(无 `shell=True`、无 `os.system`)。
- Bot 支持**切换 / 添加 / 删除出口**。添加出口时可以直接粘贴 WireGuard 客户端配置或多协议节点 URI；敏感配置会经 Telegram 传输,Bot 会在引导时提示;仅白名单管理员可操作。
- Bot 的长任务（更新规则、续期证书、更改域名、更改 DNS、检查出口、查看日志、生成 iOS 二维码等）会在后台执行，点击后先立即停止按钮转圈并显示处理中，主轮询不会被长命令卡住。
- 出于安全,Bot **不暴露** `--uninstall`,卸载仅限服务器本地执行。

### 启用

```bash
# 安装时交互输入,或用环境变量预设后启用:
export TG_BOT_TOKEN="123456:ABC-your-bot-token"
export TG_ADMIN_IDS="11111111,22222222"   # 你的 Telegram 数字 ID
./install.sh --setup-tgbot
```

不知道自己的数字 ID?先留空 `TG_ADMIN_IDS` 启用 Bot,给它发送 `/id`,它会回复你的数字 ID;填入 `tgbot.env` 后 `systemctl restart proxy-gateway-tgbot` 即可。

> 安装主流程也会询问是否配置 Bot;不提供 Token 就跳过,**默认安装行为不变**。

### Bot 命令

| 命令 | 作用 |
|------|------|
| `/start` `/menu` | 打开操作面板(内联按钮) |
| `/status` | 查看运行状态与当前出口 |
| `/exits` | 列出出口并一键切换 |
| `/rules` | 打开智能分流规则管理 |
| `/cancel` | 取消当前输入流程 |
| `/id` | 获取自己的 Telegram 数字 ID(任何人可用,仅返回本人 ID) |

面板按钮:📊 状态 · 🌐 出口(切换/➕添加/🗑删除)· 🧭 智能分流 · 🔄 更新规则 · 🔐 DoT 管理 · ♻️ 重启服务 · 📜 日志 · 📱 iOS 二维码。

### DoT 管理

Bot 面板里的 `🔐 DoT 管理` 包含：

- `🌐 更改域名`：输入新的 DoT 域名。脚本会先校验该域名 A 记录是否已经指向本机公网 IP；证书签发成功后才写入新域名并重载 dnsdist，失败不会覆盖原配置。若证书签发失败但你确认解析无误，Bot 会给出二次确认按钮用于强制更换域名；强制模式会跳过本次证书签发，DoT 客户端可能因证书不匹配暂时无法连接。之后点 `🔄 续期证书` 会对当前域名签发/续期证书，并在失败时显示 certbot 的真实输出。
- `🧭 更改 DNS`：输入一行海外 DNS，例如 `1.1.1.1 8.8.8.8 9.9.9.9`。这组 DNS 会同步用于私网 DoT、公网 DoT 和 sniproxy。高级用法仍可在命令行使用 `--set-dns <dns-list> [public-dns] [sniproxy-dns]` 分别指定三组上游。
- DoT 管理状态里，三组 DNS 相同时只显示一条 `当前 DNS`；只有高级分组配置不一致时才展开显示当前私网 DoT / 公网 DoT / sniproxy DNS。
- `🔄 续期证书`：对当前 DoT 域名签发/续期证书并重载 dnsdist。证书签发使用 Let's Encrypt HTTP-01 standalone 模式，脚本会在签发期间临时停止 sniproxy 释放 TCP/80，完成后自动恢复。

更改域名成功后，脚本会重新生成 iOS 描述文件；Bot 的 `📱 iOS 二维码` 会优先读取当前 DoT 域名即时生成二维码，避免旧 URL 文件残留导致输出旧二维码。

添加出口流程:点 🌐 出口 → ➕ 添加出口 → 直接粘贴一条节点链接即可；也可发送 `出口名 链接` 指定名称。WireGuard 则粘贴整段客户端配置。完成后在出口列表里点它即可切换。中途随时 `/cancel` 取消。

## 切换出口（多出口中转）

默认出口是 `local`——被代理的流量从**本机公网 IP**直接出网（目标网站看到的是这台服务器的 IP）。你可以把出口切换到其他服务器，让目标网站看到**远端服务器的 IP**。

**实现原理**：sniproxy / quic-proxy 以专用用户 `pxout` 运行，其出站流量被 nftables 打 mark，再由策略路由（`ip rule fwmark` → 独立路由表 `100`）导入选定出口的 `pgw-<名字>` 设备。只有被代理的出站流量走出口，**SSH、DNS、证书续期等本机流量不受影响**；切回 `local` 即恢复直出。这个路由层对所有出口类型是统一的——区别只在 `pgw-<名字>` 设备由谁创建。

### 支持的出口类型

| 类型 | 引擎 | 远端要求 | 添加方式 |
|------|------|----------|----------|
| **WireGuard** | `wg-quick`（内核） | 普通 Linux VPS：开 IP 转发 + NAT（用 `exit-server-setup.sh` 生成） | 粘贴 WireGuard 客户端配置 |
| **SOCKS5** | sing-box TUN（自动安装） | 一个 SOCKS5 服务 | `socks5://[用户:密码@]host:port` / `socks5h://...` |
| **Shadowsocks / SS2022** | sing-box TUN（自动安装） | 一个 SS / SS2022 服务 | `ss://...`（SIP002，含 `2022-blake3-*`） |
| **VMess / Trojan / VLESS** | sing-box TUN（自动安装） | 常见机场/节点分享链接 | `vmess://...` / `trojan://...` / `vless://...` |
| **Hysteria2 / TUIC / AnyTLS** | sing-box TUN（自动安装） | UDP/QUIC/TLS 类节点 | `hysteria2://...` / `tuic://...` / `anytls://...` |
| **HTTP/HTTPS 代理** | sing-box TUN（自动安装） | HTTP CONNECT 代理 | `http://...` / `https://...` |

> URI 出口走 [sing-box](https://github.com/SagerNet/sing-box) 的 TUN（tun2socks）转发，TCP 和 UDP/QUIC 都支持。首次添加该类出口时会自动下载锁定版 sing-box `1.12.25`（仍可用 `SINGBOX_VERSION` 显式覆盖）。
>
> **socks5h（远程 DNS）**：默认 `socks5://` 由网关本地解析目标域名再把 IP 交给代理；`socks5h://` 则让 sing-box 从 TLS ClientHello 嗅探出域名、转发**域名**给 SOCKS5 服务器去解析（DNS 在出口侧完成）。任意出口也可单独加一行 `remote-dns: on` 开启。

### 添加并切换出口

```bash
# WireGuard 出口：
sudo ./exit-server-setup.sh               # 在远端 VPS 运行，生成客户端配置
./install.sh --add-exit us us.conf        # 文件 / stdin / 交互粘贴皆可

# SOCKS5 出口（支持账号密码鉴权；无鉴权则去掉 user:pass@）：
./install.sh --add-exit jp 'socks5://user:pass@1.2.3.4:1080'
# SOCKS5 远程 DNS（socks5h）：目标域名由出口服务器解析，把 socks5:// 换成 socks5h://
./install.sh --add-exit jp 'socks5h://user:pass@1.2.3.4:1080'
# 密码含 @ : / # 等特殊字符时，把账号/密码单独成行（免转义；可加 remote-dns: on）：
printf 'socks5://1.2.3.4:1080\nuser: myuser\npass: my@p:ss/word\nremote-dns: on\n' | ./install.sh --add-exit jp

# Shadowsocks / SS2022 出口：
./install.sh --add-exit hk 'ss://2022-blake3-aes-128-gcm:PASSWORD@5.6.7.8:443'

# 切换 / 验证 / 切回：
./install.sh --set-exit us
curl --interface pgw-us -4 -s https://api.ipify.org; echo    # 应为出口的 IP
./install.sh --set-exit local
```

可以混合预存多个不同类型的出口（如 WireGuard `us`、VLESS `jp`、Hysteria2 `hk`），用 `--set-exit <名字>` 一键切换；切换时会自动停掉上一个出口以省资源。当前出口记录在 `/opt/proxy-gateway/etc/current-exit`，开机由 `proxy-gateway-exit.service` 自动恢复。这些操作在 Telegram Bot 上同样可做（🌐 出口 → ➕ 添加出口，粘贴配置或 URI）。

### 智能分流（规则列表 / `smart` 出口）

除了"所有代理流量走同一个出口"，还可以用 **`smart` 出口**按域名把流量分到不同出口 / 直连 / 拒绝。它由一个 规则列表文件驱动，底层是 sing-box 多 outbound 路由 + `rule_set`。

```bash
# 1) 写规则文件（首行匹配优先）：
cat > rules.conf <<'EOF'
DOMAIN-SUFFIX,google.com,us          # 走名为 us 的出口
DOMAIN-KEYWORD,netflix,jp            # 走 jp 出口
DOMAIN,api.example.com,direct        # 直连
GEOSITE,telegram,us                  # sing-box geosite 分类
GEOIP,cn,direct                      # 国内 IP 直连
RULE-SET,https://example.com/list.txt,us   # 远程域名表（纯文本）
RULE-SET,https://example.com/rules.srs,jp  # 远程 sing-box .srs
RULE-SET,/etc/proxy-gateway/rules/my.list,jp  # 本地域名表
DOMAIN-SUFFIX,cn,direct
FINAL,us                             # 兜底策略
EOF

# 2) 安装规则（会用 sing-box 校验，并自动下载所需 geosite/规则集）：
./install.sh --set-rules rules.conf
# 3) 启用智能分流：
./install.sh --set-exit smart
./install.sh --show-rules            # 查看当前规则
```

- **规则类型**：`DOMAIN` / `DOMAIN-SUFFIX` / `DOMAIN-KEYWORD` / `IP-CIDR` / `GEOSITE` / `GEOIP` / `RULE-SET` / `FINAL`。
- **策略**：任意已配置的出口名（socks/ss/wireguard）、`direct`（本机直出）、`block`（拒绝）。
- **外部规则集**：`RULE-SET` 支持**本地文件**和**远程 URL**；纯文本/Clash 域名表会自动解析为 sing-box 规则集，`.srs` 直接引用。`GEOSITE/GEOIP` 用官方 sing-geosite/sing-geoip 的 `.srs`。
- 强制某些分类直连：导入时设 `PGW_DIRECT_CATEGORIES="小红书,bilibili,iqiyi"`（会被记住），这些分类的规则会标成直连而不进代理。
- 改了出口或规则后，重新 `--set-rules` 即可刷新（若 `smart` 正在用会自动重载）。
- **Telegram Bot**：🧭 智能分流 / `/rules` —— 查看、整体设置（粘贴）、追加一条、删除一条、一键启用，均经 sing-box 校验。

#### 导入规则列表 + 分类→出口映射

可以直接导入一份规则列表，自动转换并按**分类**路由：

```bash
./install.sh --import-rules /path/to/rule.conf   # 转换 + 播种映射表 + 重建
./install.sh --show-policy                        # 查看 分类=出口 映射
./install.sh --set-policy Netflix hk              # 某分类改走某出口
```

- 转换会**丢弃服务器无意义的规则**（`PROCESS-NAME` / `SRC-IP` / `MAC-ADDRESS` / `DEST-PORT`），**拆解 `OR/AND`** 取其中的域名/IP，剥离 `no-resolve`/`update-interval` 等修饰，保留 `DOMAIN*/IP-CIDR/RULE-SET/GEOIP/GEOSITE`。
- 规则里的**策略组保留为"分类"**（AI、Netflix、小红书…），由一张 `分类=出口/direct/block` 的**映射表**（`/etc/proxy-gateway/policy-map.conf`）解析；导入时按 `dir→直连`、`广告/劫持/隐私→拒绝`、其余→第一个出口 播种默认值。
- 外部 `RULE-SET` 列表会被拉取并**编译成 sing-box 二进制 `.srs`**（40 个列表实测仅占 ~232KB、运行内存约 30MB，512MB 也轻松）。已编译的会缓存复用，改映射不必重新拉取。
- **Telegram Bot**：🧭 智能分流 → 🎯 分类→出口映射，逐个分类点选目标出口 / 直连 / 拒绝，改完自动重建。
- 域名靠嗅探 TLS SNI 识别，因此天然是"远程 DNS"。
- `172.22.0.0/16` 私网客户端的非 ChinaList IPv4 查询默认进入代理；ChinaList 域名仍按国内解析直连，其他来源的公网 DoT 查询不做代理劫持。

> 两层分流：**①哪些走代理**由 DNS 层的 ChinaList 决定（私网客户端非 ChinaList 默认进代理）；**②代理流量走哪个出口**由 `smart` 规则决定。

## 文件说明

| 文件 | 说明 |
|------|------|
| `install.sh` | 主安装脚本 |
| `exit-server-setup.sh` | 远端出口 VPS 一键配置脚本（WireGuard + NAT） |
| `singbox-exit-config.py` | 把多协议节点 URI 转成 sing-box 出口配置 |
| `singbox-router-config.py` | 把分流规则 + 分类映射转成 sing-box 智能分流（`smart`）配置 |
| `rules-import.py` | 把规则列表转换为网关分流规则（按分类） |
| `tgbot.py` | Telegram 控制 Bot（标准库实现；长任务后台执行） |
| `ios-http.py` | iOS 描述文件按需 HTTP 响应器（socket 激活） |
| `quic-proxy.go` | QUIC SNI UDP 代理源码 |
| `china-dns-race-proxy.go` | ChinaList DNS 上游并发竞速代理源码 |
| `sniproxy.conf` | sniproxy 配置文件 |
| `dnsdist.conf.template` | dnsdist 配置模板 |
| `update-rules.sh` | GFWList/ChinaList 更新脚本 |
| `renew-hook.sh` | 证书续期 Hook |

## iOS 描述文件

安装完成后会生成：

| 文件 | 说明 |
|------|------|
| `/opt/proxy-gateway/www/ios-dot.mobileconfig` | iOS DoT 描述文件 |
| `/opt/proxy-gateway/www/ios-dot.qr.txt` | 终端二维码文本 |
| `/opt/proxy-gateway/www/ios-profile-url.txt` | 描述文件下载地址 |

系统会创建 `proxy-gateway-ios-profile.socket`（systemd socket 激活，监听 TCP `8111`），平时无常驻进程，仅在有连接时临时拉起一个轻量 Python 响应器（`ios-http.py`）返回描述文件。二维码和下载地址指向：

```text
http://<安装生成的域名>:8111/ios-dot.mobileconfig
```

描述文件使用 `com.apple.dnsSettings.managed`，协议为 DoT (`TLS`)。`OnDemandRules` 会让 iPhone 仅在蜂窝网络 (`Cellular`) 下连接该 DoT DNS，在 Wi-Fi (`WiFi`) 下断开。

如需重新调出二维码，随时运行：

```bash
./install.sh -ios
```

## 技术说明

### TCP 代理
使用 [dlundquist/sniproxy](https://github.com/dlundquist/sniproxy)（C 语言），基于 SNI/Host 头做 Layer-4/7 透明转发，不解密 TLS，性能极高。

### UDP/QUIC 代理
原版 sniproxy 已于 2023 年弃用，且不支持 UDP/QUIC。本项目包含一个 **Go 实现的极简 QUIC SNI 代理**（`quic-proxy.go`），它：
- 监听 UDP 443
- 使用标准 RFC 9000 算法解密 QUIC Initial 包
- 提取 TLS ClientHello 中的 SNI
- 建立到真实后端的 UDP 会话并双向转发

> 注：quic-proxy 仅支持 QUIC v1 (RFC 9000) 的 Initial 包解密。若浏览器使用其他 QUIC 版本，可能会自动回退到 TCP/HTTP2。

### DNS 分流策略

dnsdist 会先检查来源 IP 和查询端口：

- 非 `172.22.0.0/16` 来源访问普通 DNS 53 端口会被丢弃。
- `172.22.0.0/16` 来源访问 DNS/DoT 时，非 ChinaList 的 IPv4 查询返回服务器本机 IP，使国际流量进入 sniproxy / quic-proxy。
- 其他来源访问 DoT 时，不做 GFWList 代理劫持，只按 ChinaList / 默认海外 DNS 池正常解析。
- ChinaList 查询会覆盖 ECS 为 `139.226.48.0/24`，再转发到本机 `china-dns-race-proxy`。
- `china-dns-race-proxy` 对国内上游做并发查询，默认 `150ms` 后启动国内 TCP 53 重试，默认 `750ms` 后才启动海外 fallback；如果所有上游都失败，会返回 SERVFAIL，避免客户端一直等待无响应 UDP 包。

### 系统网络优化

安装脚本会写入 `/etc/sysctl.d/99-proxy-gateway.conf` 并立即应用，主要包括：

- 启用 `fq` 队列和 `bbr` 拥塞控制。
- 提高 `somaxconn`、文件句柄、TCP 收发 buffer 和临时端口范围。
- 提高 `nf_conntrack_max` 并缩短部分连接跟踪超时。
- 启用 TCP Fast Open、窗口扩展、SACK、MTU probing。
- 创建 `disable-transparent-huge-pages.service`，开机自动关闭 THP。
- 创建 journald drop-in，限制日志占用空间。

### 低内存模式（自动）

安装时脚本会读取 `MemTotal`，**内存 ≤ 1GB 自动启用低内存模式**(也可 `export LOWMEM=1` 强制开启、`LOWMEM=0` 强制关闭)。低内存模式会：

- **dnsdist 三个 packet cache:50 万 → 各 2 万条**(这是 512MB 上最大的内存隐患;缓存大小写入 `/etc/dnsdist/.cache_size`,每周规则更新沿用)。
- **sysctl 缩小**:`nf_conntrack_max` → 13 万、`somaxconn` → 4096、`file-max` → 100 万、TCP buffer 上限 128MB → 16MB 等,避免大机器参数在小内存上分配过大的内核结构。
- **iOS 描述文件服务改为 systemd socket 按需启动**:平时 0 进程,手机扫码访问时才临时拉起一个短命 Python(省 ~15-20MB 常驻)。
- **Go 代理加内存上限**:quic-proxy / china-dns-race-proxy 注入 `GOMEMLIMIT=64MiB GOGC=50` drop-in。
- **先确认再创建自定义大小 swap**(磁盘够且无现有 swap 时)：安装时会先询问是否创建 swap；输入 `y` 后再输入 `0.5` / `1` / `2` / `4` 这类数字（默认按 `G` 处理），也支持直接输入 `0.5G` / `1G` / `2G`，回车默认 `1G`。创建后会自动写入 `/swapfile`，并把编译并行度限到 `-j1`，避免安装期 `make` / `go build` OOM；不输入 `y` 则跳过创建。

标准内存(> 1GB)主机保持原有大参数,不受影响。当前档位可用 `./install.sh --status` 查看(`Mem profile` 行)。

> Telegram Bot(`tgbot.py`)与 iOS 描述文件常驻进程在低内存模式下已分别变为可选 / 按需,512MB 主机空闲占用明显下降。

## 安全与合规

- 本系统仅用于企业合法的跨境业务互通。
- 服务器开放端口：22(SSH)、53(DNS)、853(DoT)、8111(iOS 描述文件)。80/443 反代端口仅允许 `172.22.0.0/16` 访问；证书申请或续期时会临时放行公网 80，完成后自动恢复白名单。
- DNS 53 仅允许 `172.22.0.0/16`，DoT 853 面向所有来源但按来源 IP 分流解析。
- 海外 DNS 池会显式发送中性 ECS `0.0.0.0/0` / `::/0`，避免上游递归按服务器公网 IP 生成对应 `/24` 这类 ECS。
- 使用不规则子域名可降低被主动探测概率，但无法完全消除服务器 IP 被封禁的风险。

## 故障排查

```bash
# 查看各服务状态
systemctl status sniproxy
systemctl status quic-proxy
systemctl status china-dns-race-proxy
systemctl status dnsdist

# 查看实时日志
journalctl -u sniproxy -f
journalctl -u quic-proxy -f
journalctl -u china-dns-race-proxy -f
journalctl -u dnsdist -f

# 测试 DoT 解析
dig +tls @your-domain.com -p 853 youtube.com

# 测试 sniproxy TCP
curl -I --resolve youtube.com:443:127.0.0.1 https://youtube.com
```
