# 5GPN-X

服务器端透明代理网关：通过 dnsdist DoT、SNI/QUIC 透明代理和可切换多协议出口，让客户端只配置 DNS 即可使用网关转发。

## 项目介绍

5GPN-X 面向 5G NPN / N6 互通、私网终端出海和轻量透明代理场景。项目在服务器侧部署 DNS over TLS、HTTP/HTTPS/QUIC 透明代理、多协议出口和 Telegram 管理 Bot。客户端不需要安装代理客户端，只需要把 DNS 或 DoT 指向服务器域名。

核心链路如下：

- `172.22.0.0/16` 私网客户端访问 DNS/DoT。
- ChinaList 域名走国内 DNS 解析，适合保持本地访问体验。
- 非 ChinaList 的 IPv4 查询默认返回服务器本机 IP，让国际 HTTP/HTTPS/QUIC 流量进入网关。
- wa-shim / sniproxy / quic-proxy 负责 WhatsApp Noise、SNI/Host 和 QUIC 转发，出站流量由当前出口控制。
- 出口可以是本机直出、WireGuard、SOCKS5、Shadowsocks、VMess、Trojan、VLESS、Hysteria2、TUIC、AnyTLS 或 HTTP/HTTPS 代理。

项目默认适配低内存 VPS，512 MB 主机也可运行；首次添加 URI 类出口时会自动安装锁定版 mihomo `1.19.28` 作为 TUN 出口和智能分流内核。

## 功能特点

- DNS + DoT：dnsdist 提供 TCP/UDP 53 和 TCP 853，支持来源网段策略、AAAA NODATA、ECS 覆盖和高 QPS 限制。
- 国内解析优化：ChinaList 查询转发到本机 `china-dns-race-proxy`，并发查询多个国内 DNS，必要时 fallback。
- 默认国际流量进网关：私网客户端的非 ChinaList IPv4 查询劫持到服务器 IP，减少国际站漏走客户端国内 IP 的情况。
- TCP 透明代理：sniproxy 监听 80 和回环端口 8443，通过 SNI/Host 转发 HTTP/HTTPS，不解密 TLS。
- iOS WhatsApp Patch：wa-shim 监听 TCP 443，仅把客户端网段内以 `ED` / `WA` 开头的无 SNI Noise 连接送往 WhatsApp，其余连接原样、fail-open 转交 sniproxy。
- QUIC 透明代理：内置 Go 实现的 `quic-proxy` 监听 UDP 443，解析 QUIC Initial 中的 SNI 后转发。
- 多协议出口：支持 WireGuard、SOCKS5/SOCKS5H、SS/SS2022、VMess、Trojan、VLESS、Hysteria2、TUIC、AnyTLS、HTTP/HTTPS。
- 出口切换：通过 `ip rule fwmark` + 独立路由表 `100`，只让代理进程的出站流量走所选出口，不影响 SSH、DNS、证书续期等本机流量。
- 智能分流：mihomo `smart` 出口可按域名、IP、GEOSITE、GEOIP、RULE-SET 分流；远程 `.mrs`、Clash YAML 和文本规则集由内核定时更新。
- Telegram Bot：支持状态查看、出口管理、规则更新、DoT 域名和 DNS 管理、日志查看、iOS 二维码等常用操作。
- iOS 描述文件：自动生成 DoT mobileconfig，并通过 `8111` 端口按需提供下载。
- 低内存模式：≤ 1 GB 内存自动降低缓存和内核参数，限制 Go 进程内存，并使用 systemd socket 按需启动 iOS 文件服务。

## 适用场景

- 5G NPN、专网或内网客户端需要统一通过服务器访问国际站点。
- 终端无法安装代理客户端，但可以配置 DNS over TLS。
- 希望用一台服务器统一管理多个出口节点，并随时切换。
- 希望国内域名保持直连/国内解析，国际域名默认进入服务器出口。
- 小内存 VPS 上部署轻量透明代理网关。

不适合的场景：

- 需要完整 VPN 隧道、全端口透明转发或客户端任意协议代理。
- 不具备服务器公网 IPv4、域名 DNS 管理权或 root 权限。
- 需要隐藏服务器 IP 或规避所有主动探测风险。

## 系统要求

### 操作系统

支持以下 Linux 发行版：

| 发行版 | 版本 |
| --- | --- |
| Ubuntu | 20.04 / 22.04 / 24.04 LTS |
| Debian | 11 / 12 / 13 |
| CentOS / Stream | 7 / 8 / 9 |
| AlmaLinux | 8 / 9 |
| Rocky Linux | 8 / 9 |
| RHEL | 8 / 9 |
| Fedora | 39+ |

### 硬件与网络

- CPU：`amd64` 或 `arm64`。
- 内存：最低 512 MB，推荐 1 GB 以上。
- 网络：需要公网 IPv4。
- 权限：安装脚本必须以 root 运行。
- 域名：需要一个可管理的域名或子域名，A 记录指向服务器公网 IP。

## 安装方法

### 一键安装

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Xiuyixx/5GPN-X/main/install.sh)"
```

脚本会自动拉取仓库到 `/opt/5gpn` 并执行安装流程。安装后可进入该目录继续使用管理命令：

```bash
cd /opt/5gpn
sudo ./install.sh --status
```

### 手动安装

```bash
git clone https://github.com/Xiuyixx/5GPN-X.git
cd 5GPN-X
chmod +x install.sh
sudo ./install.sh
```

### 非交互安装

无 TTY 环境必须设置 `DOMAIN`，否则脚本会直接退出，避免卡在输入提示。

```bash
export DOMAIN="dns.example.com"
export EMAIL="admin@example.com"
export REMOTE_DNS="1.1.1.1,8.8.8.8"
export LOCAL_DNS="223.5.5.5,119.29.29.29"
sudo ./install.sh
```

安装前请先把 `DOMAIN` 的 A 记录指向服务器公网 IP。脚本会在申请 Let's Encrypt 证书前验证解析，最长等待 120 秒。

## 使用方法

### 客户端配置

Android：

```text
设置 -> 网络和互联网 -> 私人 DNS -> 输入安装时配置的域名
```

iOS / iPadOS：

安装完成后，脚本会生成 DoT 描述文件和二维码。也可以手动访问：

```text
http://<你的域名>:8111/ios-dot.mobileconfig
```

重新生成 iOS 描述文件和二维码：

```bash
sudo ./install.sh -ios
```

描述文件仅在蜂窝网络下启用 DoT，连接 Wi-Fi 时会自动停用。

Windows / macOS / Linux：

在系统网络设置中配置 DoT，或使用 Stubby、cloudflared 等本地 DoT 转发器指向服务器域名和 `853` 端口。

### 常用管理命令

```bash
sudo ./install.sh --status
sudo ./install.sh --update-rules
sudo ./install.sh --renew-cert
sudo ./install.sh --set-dot-domain dns.example.com
sudo ./install.sh --set-dot-domain-force dns.example.com
sudo ./install.sh --set-dns "1.1.1.1 8.8.8.8" "223.5.5.5 119.29.29.29"
sudo ./install.sh -ios
sudo ./install.sh --list-exits
sudo ./install.sh --check-exits
sudo ./install.sh --setup-tgbot
sudo ./install.sh --setup-whatsapp
sudo ./install.sh --uninstall
```

### 添加和切换出口

默认出口为 `local`，即代理流量从本机公网 IP 出站。

WireGuard 出口：

```bash
# 在远端出口 VPS 上运行，生成 WireGuard 客户端配置
sudo ./exit-server-setup.sh

# 在网关服务器上添加并切换
sudo ./install.sh --add-exit us us.conf
sudo ./install.sh --set-exit us
```

SOCKS5 / SOCKS5H 出口：

```bash
sudo ./install.sh --add-exit jp 'socks5://user:pass@1.2.3.4:1080'
sudo ./install.sh --add-exit jp-dns 'socks5h://user:pass@1.2.3.4:1080'
```

密码包含特殊字符时，可使用多行输入，避免 URL 转义：

```bash
printf 'socks5://1.2.3.4:1080
user: myuser
pass: my@p:ss/word
remote-dns: on
' | sudo ./install.sh --add-exit jp
```

其他 URI 出口：

```bash
sudo ./install.sh --add-exit hk 'ss://2022-blake3-aes-128-gcm:PASSWORD@5.6.7.8:443'
sudo ./install.sh --add-exit sg 'vless://uuid@example.com:443?security=tls#sg-node'
sudo ./install.sh --set-exit hk
sudo ./install.sh --set-exit local
```

验证出口 IP：

```bash
curl --interface pgw-hk -4 -s https://api.ipify.org; echo
```

当前出口记录在：

```text
/opt/proxy-gateway/etc/current-exit
```

开机后由 `proxy-gateway-exit.service` 自动恢复。

### 智能分流

`smart` 出口支持把不同域名或规则集分配到不同出口。

```bash
cat > rules.conf <<'EOF'
DOMAIN-SUFFIX,google.com,us
DOMAIN-KEYWORD,netflix,jp
DOMAIN,api.example.com,direct
GEOSITE,telegram,us
GEOIP,cn,direct
RULE-SET,https://example.com/list.txt,us
RULE-SET,https://example.com/rules.mrs,jp
DOMAIN-SUFFIX,cn,direct
FINAL,us
EOF

sudo ./install.sh --set-rules rules.conf
sudo ./install.sh --set-exit smart
sudo ./install.sh --show-rules
```

规则类型支持：`DOMAIN`、`DOMAIN-SUFFIX`、`DOMAIN-KEYWORD`、`IP-CIDR`、`GEOSITE`、`GEOIP`、`RULE-SET`、`FINAL`。

单独添加一条最高优先级规则或远程规则集，不需要覆盖整份文件：

```bash
sudo ./install.sh --add-rule 'DOMAIN-SUFFIX,openai.com,us'
sudo ./install.sh --add-ruleset 'https://example.com/openai.mrs' us
```

`RULE-SET` 支持 mihomo `.mrs`、Clash YAML 和纯文本列表；旧 sing-box `.srs` 会明确拒绝。生成器会按 `domain-set` / `geosite` / `geoip` 等文件名推断 provider 类型；命名不明确时可在 URL 后加 `#domain`、`#ipcidr` 或 `#classical`。远程 provider 由 mihomo 按 24 小时默认间隔更新，配置生成阶段不下载远程内容。

策略可以是已配置的出口名，也可以是 `direct` 或 `block`。

导入规则列表并按分类映射出口：

```bash
sudo ./install.sh --import-rules /path/to/rule.conf
sudo ./install.sh --show-policy
sudo ./install.sh --set-policy Netflix hk
```

## 配置说明

### 目录和文件

| 路径 | 说明 |
| --- | --- |
| `/opt/5gpn` | 一键安装脚本拉取的项目目录 |
| `/opt/proxy-gateway` | 运行时主目录 |
| `/opt/proxy-gateway/bin/proxy-gateway-ctl` | 安装后的管理脚本 |
| `/opt/proxy-gateway/bin/tgbot.py` | Telegram Bot |
| `/opt/proxy-gateway/bin/mihomo` | 锁定版 mihomo 内核 |
| `/opt/proxy-gateway/bin/wa-shim.py` | WhatsApp 无 SNI shim |
| `/opt/proxy-gateway/etc/mihomo/<出口>` | mihomo 运行目录与 provider 缓存 |
| `/opt/proxy-gateway/www/ios-dot.mobileconfig` | iOS DoT 描述文件 |
| `/opt/proxy-gateway/etc/current-exit` | 当前出口 |
| `/opt/proxy-gateway/etc/tgbot.env` | Bot Token 和管理员 ID，权限 `600` |
| `/etc/dnsdist/dnsdist.conf` | dnsdist 实际配置 |
| `/etc/sniproxy.conf` | sniproxy 配置，resolver 强制 `ipv4_only` |
| `/etc/dnsdist/gfwlist-extra-local.txt` | 本地补充 GFWList 域名 |

### 端口

| 端口 | 协议 | 访问范围 | 用途 |
| --- | --- | --- | --- |
| 22 | TCP | 公网 | SSH |
| 53 | TCP/UDP | `172.22.0.0/16` | 普通 DNS |
| 80 | TCP | `172.22.0.0/16`，证书签发时临时公网 | HTTP 透明代理 / ACME HTTP-01 |
| 443 | TCP | `172.22.0.0/16` | wa-shim（WhatsApp 无 SNI / HTTPS fail-open） |
| 8443 | TCP | 回环 | sniproxy TLS 后端，不对公网开放 |
| 443 | UDP | `172.22.0.0/16` | QUIC 透明代理 |
| 853 | TCP | 公网 | DNS over TLS |
| 8111 | TCP | 公网 | iOS 描述文件下载 |

### DNS 策略

| 来源 | ChinaList | 非 ChinaList IPv4 | AAAA |
| --- | --- | --- | --- |
| `172.22.0.0/16` | 国内 DNS 池 | 返回服务器 IP，进入代理 | NOERROR/NODATA |
| 其他 DoT 来源 | 国内 DNS 池 | 海外 DNS 池正常解析 | NOERROR/NODATA |

海外 DNS 默认值：

```text
1.1.1.1 8.8.8.8 9.9.9.9
```

相关环境变量：

```bash
DOMAIN="dns.example.com"
EMAIL="admin@example.com"
REMOTE_DNS="1.1.1.1,8.8.8.8"
LOCAL_DNS="223.5.5.5,119.29.29.29"
DNS_UPSTREAMS="1.1.1.1,8.8.8.8"
LOWMEM=1
MIHOMO_VERSION="1.19.28"
TG_BOT_TOKEN="123456:ABC"
TG_ADMIN_IDS="11111111,22222222"
```

说明：

- `REMOTE_DNS` 用于国际/代理侧解析，会同时供 dnsdist remote 池和 sniproxy 使用。
- `LOCAL_DNS` 用于 ChinaList 国内直连解析，会写入 `china-dns-race-proxy` 的并发上游。
- `DNS_UPSTREAMS`、`OVERSEAS_DNS`、`PRIVATE_OVERSEAS_DNS`、`SNIPROXY_DNS` 仍作为旧兼容变量，等同于 `REMOTE_DNS`。
- `MIHOMO_VERSION` 可覆盖默认锁定版，但默认建议保持 `1.19.28`。

### Telegram Bot

启用 Bot：

```bash
export TG_BOT_TOKEN="123456:ABC-your-bot-token"
export TG_ADMIN_IDS="11111111,22222222"
sudo ./install.sh --setup-tgbot
```

如果不知道自己的 Telegram 数字 ID，可先启用 Bot 后发送：

```text
/id
```

然后把返回的 ID 写入 `/opt/proxy-gateway/etc/tgbot.env` 并重启：

```bash
sudo systemctl restart proxy-gateway-tgbot
```

常用命令：

| 命令 | 作用 |
| --- | --- |
| `/start` `/menu` | 打开面板 |
| `/status` | 查看状态 |
| `/exits` | 管理出口 |
| `/rules` | 管理智能分流 |
| `/cancel` | 取消当前输入 |
| `/id` | 获取自己的 Telegram 数字 ID |

Bot 添加出口流程：点击 `🌐 出口` -> `➕ 添加出口`，直接粘贴节点链接即可。链接有备注时会提取节点名称作为出口名；也可以发送 `出口名 链接` 手动指定名称。智能分流页面可直接添加单条规则或发送 `规则集URL 目标` 添加 mihomo rule-provider。

支持的链接前缀：

```text
ss:// vmess:// trojan:// vless:// hysteria2:// tuic:// anytls:// socks5:// http://
```

### 低内存模式

内存 ≤ 1 GB 时自动启用低内存模式，也可通过 `LOWMEM=1` 强制开启。主要变化：

- dnsdist packet cache 降低到每组 2 万条。
- 缩小 conntrack、TCP buffer、file-max 等系统参数。
- iOS 描述文件服务使用 systemd socket 按需启动。
- quic-proxy 和 china-dns-race-proxy 使用 `GOMEMLIMIT=64MiB GOGC=50`。
- 可按提示创建 swap，并降低编译并行度，减少安装期 OOM。

## 常见问题

### 为什么有些国际站之前显示国内 IP？

旧逻辑只把 GFWList 命中的域名解析到网关 IP，未命中的国际站可能拿到真实海外 IP，客户端就会直连。当前版本对 `172.22.0.0/16` 私网客户端默认把非 ChinaList 的 IPv4 查询返回服务器 IP，让国际站先进入网关，再从当前出口出站。

### 为什么国内网站仍然直连？

ChinaList 域名会转发到本机国内 DNS 竞速代理，并携带 `139.226.48.0/24` ECS，目标是获得更适合中国大陆访问的 IPv4 结果。

### 为什么不返回 IPv6？

项目是 IPv4-only 透明代理设计。dnsdist 会对 AAAA 返回 NOERROR/NODATA，避免客户端优先使用 IPv6 绕过网关或连接失败。

### 只更新 `tgbot.py` 能生效吗？

只涉及 Bot 交互的修复可以只更新 `tgbot.py`。如果修改涉及 DNS、出口切换、`proxy-gateway-ctl` 或模板文件，就需要同步对应脚本并重载服务。最近的 DNS 默认代理逻辑需要重新渲染并重载 dnsdist。

### 如何更新 DNS 规则和重载 dnsdist？

```bash
cd /opt/5gpn
sudo git pull
sudo ./install.sh --update-rules
```

### 如何查看服务状态和日志？

```bash
systemctl status dnsdist
systemctl status sniproxy
systemctl status wa-shim
systemctl status 'proxy-gateway-mihomo@*'
systemctl status quic-proxy
systemctl status china-dns-race-proxy
systemctl status proxy-gateway-tgbot

journalctl -u dnsdist -f
journalctl -u sniproxy -f
journalctl -u wa-shim -f
journalctl -u quic-proxy -f
journalctl -u china-dns-race-proxy -f
journalctl -u proxy-gateway-tgbot -f
```

### 如何测试 DoT 和代理入口？

```bash
dig +tls @dns.example.com -p 853 youtube.com
curl -I --resolve youtube.com:443:127.0.0.1 https://youtube.com
```

### 证书签发失败怎么办？

检查域名 A 记录是否指向服务器公网 IP，并确认 TCP 80 可被公网访问。证书申请或续期时脚本会临时停止 sniproxy 并放行公网 80，完成后恢复 80/443 白名单。

### 从旧 sing-box 版本升级要注意什么？

这是一次内核级迁移。安装器会停用并删除旧 sing-box 服务和二进制，把旧 JSON 与类型文件备份到 `/etc/proxy-gateway/exits/singbox-backup/`。只有当前正在使用的出口属于这些失效旧配置时才会回退到 `local`；当前 WireGuard 出口不受影响。旧 JSON 没有保留原始分享链接，部分协议无法无损反推，因此 URI 出口需要用原节点链接重新执行 `--add-exit`；`rules.conf` 和策略映射会保留，出口补齐后可重新执行 `--set-rules` / `--set-exit smart`。

### WhatsApp Patch 如何限制风险？

wa-shim 仅对 `172.22.0.0/16` 和 loopback 来源启用 ED/WA 分流，公网来源不会被转发到 WhatsApp。未知协议、TLS ClientHello、短包和超时都 fail-open 到本机 sniproxy；上游 DNS 回复若等于网关自身 IP 会被拒绝，避免劫持环路。wa-shim 以 `pxout` 用户运行，因此 WhatsApp 消息连接跟随当前 mihomo/WireGuard 出口。

### 如何卸载？

```bash
sudo ./install.sh --uninstall
```

卸载会移除安装的服务、配置和 `/opt/proxy-gateway` 运行目录。执行前请备份需要保留的配置。

## 更新日志 / 版本说明

当前 main 分支的重要行为：

- 私网客户端非 ChinaList IPv4 查询默认返回服务器 IP，国际 HTTP/HTTPS/QUIC 默认进入网关。
- mihomo URI 出口默认锁定 `1.19.28`，用于多协议 TUN 出口和原生 rule-provider 智能分流。
- iOS WhatsApp 无 SNI 补丁内置启用，普通 TLS 仍 fail-open 到 sniproxy。
- Telegram Bot 支持直接粘贴节点链接添加出口，并从节点备注提取出口名。
- 添加出口后，Bot 出口列表会立即刷新；新出口 TUN 设备进入 `UP` 状态后才写路由，避免刚添加后立刻切换失败。
- 保留 GFWList / ChinaList 更新、本地 GFWList 补充、iOS 描述文件、低内存模式和 Telegram 管理面板。

建议生产环境固定使用 GitHub main 的已验证提交，升级前先备份 `/opt/proxy-gateway/etc`、`/etc/dnsdist` 和 `/etc/sniproxy.conf`。

## 免责声明

本项目仅用于合法的网络互通、企业专网、测试和学习场景。使用者需要自行确认部署和使用行为符合所在地法律法规、云服务商条款以及目标网络服务条款。

项目不保证在所有网络环境下可用，也不承诺规避封锁、审查、风控或主动探测。因误用、违规使用、配置错误、服务中断、数据泄露、账号封禁或其他风险造成的后果，由使用者自行承担。
