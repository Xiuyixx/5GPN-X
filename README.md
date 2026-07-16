# 5GPN-X

服务器端透明代理网关：mosdns DoT + SNI/QUIC 透明代理 + 可切换多协议出口。客户端只需把 DNS/DoT 指向服务器域名，无需安装任何代理客户端。

## 工作原理

面向 5G NPN / N6 互通、私网终端出海和轻量透明代理场景：

- `172.22.0.0/16` 私网客户端把 DNS/DoT 指向网关。
- ChinaList 域名走 mosdns 国内主/备用上游，保持本地访问体验。
- 非 ChinaList 的 IPv4 查询返回服务器 IP，国际 HTTP/HTTPS/QUIC 流量进入网关。
- wa-shim / sniproxy / quic-proxy 负责 WhatsApp Noise、SNI/Host 和 QUIC 转发，出站由当前出口控制。
- 上述伪造和 AAAA 抑制仅应用于 `172.22.0.0/16` 来源；Wi-Fi、公网及其他来源始终返回正常的 A/AAAA 解析结果。
- 国内和国际解析路径都配置 primary/secondary fallback，上游失败或超时会自动切换。

支持的出口：本机直出、WireGuard、SOCKS5/SOCKS5H、SS/SS2022、VMess、Trojan、VLESS、Hysteria2、TUIC、AnyTLS、HTTP/HTTPS。URI 类出口由锁定版 mihomo `1.19.28` 提供 TUN 出口和智能分流。

出口切换基于 `ip rule fwmark` + 独立路由表，只影响代理进程出站，不影响 SSH、DNS、证书续期。

## 主要功能

- DNS + DoT：客户端使用 TCP/UDP 53 或 DoT 853；mosdns 主上游使用 DoH，UDP 独立 fallback，保留来源网段策略与 ECS 覆盖。
- iOS WhatsApp Patch：wa-shim 监听 TCP 443，仅分流客户端网段内 `ED`/`WA` 开头的无 SNI Noise 连接，其余 fail-open 交给 sniproxy。
- 智能分流：mihomo `smart` 出口按域名 / IP / GEOSITE / GEOIP / RULE-SET 分流，远程规则集自动更新。
- Telegram Bot：状态、出口管理、分流规则、DNS/DoT 设置、日志、iOS 二维码。
- 低内存模式：≤ 1 GB 内存自动降低缓存与内核参数，512 MB VPS 可运行。

## 环境要求

主流 Linux 发行版（Ubuntu 20.04+ / Debian 11+ / RHEL 系 8+ / Fedora 39+），`amd64` 或 `arm64`，root 权限，公网 IPv4，以及一个 A 记录指向服务器的域名。内存最低 512 MB，推荐 1 GB+。

## 安装

一键安装（自动拉取仓库到 `/opt/5gpn`）：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Xiuyixx/5GPN-X/main/install.sh)"
```

手动安装：

```bash
git clone https://github.com/Xiuyixx/5GPN-X.git
cd 5GPN-X
sudo ./install.sh
```

非交互安装（无 TTY 时必须设置 `DOMAIN`）：

```bash
export DOMAIN="dns.example.com"
export EMAIL="admin@example.com"
sudo ./install.sh
```

安装前请先把域名 A 记录指向服务器公网 IP；脚本在申请 Let's Encrypt 证书前会验证解析（最长等待 120 秒）。

## 客户端配置

- Android：`设置 -> 网络和互联网 -> 私人 DNS`，填入安装时配置的域名。
- iOS / iPadOS：扫描安装时生成的二维码，或访问 `http://<你的域名>:8111/ios-dot.mobileconfig` 安装描述文件（仅蜂窝网络启用 DoT，Wi-Fi 自动停用）。重新生成：`sudo ./install.sh -ios`
- Windows / macOS / Linux：系统 DoT 设置或 Stubby / cloudflared 指向服务器域名 `853` 端口。

## 管理命令

```bash
sudo ./install.sh --status              # 查看状态
sudo ./install.sh --update-rules        # 更新 GFWList/ChinaList 并重载 mosdns
sudo ./install.sh --renew-cert          # 续期证书
sudo ./install.sh --set-dot-domain dns.example.com
sudo ./install.sh --set-dns "1.1.1.1 8.8.8.8" "223.5.5.5 119.29.29.29"
sudo ./install.sh -ios                  # 重新生成 iOS 描述文件和二维码
sudo ./install.sh --list-exits          # 列出出口
sudo ./install.sh --check-exits         # 检测出口连通性
sudo ./install.sh --setup-tgbot         # 配置 Telegram Bot
sudo ./install.sh --uninstall           # 卸载
```

## 出口管理

默认出口为 `local`（本机公网 IP 直出）。

```bash
# WireGuard：导入你自己准备好的 WireGuard client 配置
sudo ./install.sh --add-exit us us.conf

# URI 出口
sudo ./install.sh --add-exit jp 'socks5://user:pass@1.2.3.4:1080'
sudo ./install.sh --add-exit hk 'ss://2022-blake3-aes-128-gcm:PASSWORD@5.6.7.8:443'

# 切换 / 验证
sudo ./install.sh --set-exit hk
curl --interface pgw-hk -4 -s https://api.ipify.org; echo
```

密码含特殊字符时可用多行输入避免 URL 转义：

```bash
printf 'socks5://1.2.3.4:1080
user: myuser
pass: my@p:ss/word
remote-dns: on
' | sudo ./install.sh --add-exit jp
```

当前出口记录在 `/opt/proxy-gateway/etc/current-exit`，开机自动恢复。

## 智能分流

`smart` 出口可把不同域名 / 规则集分配到不同出口。策略可以是已配置的出口名、`direct` 或 `block`。

```bash
cat > rules.conf <<'EOF'
DOMAIN-SUFFIX,google.com,us
DOMAIN-KEYWORD,netflix,jp
GEOSITE,telegram,us
GEOIP,cn,direct
RULE-SET,https://example.com/rules.mrs,jp
FINAL,us
EOF

sudo ./install.sh --set-rules rules.conf
sudo ./install.sh --set-exit smart
```

单独追加规则或规则集（不覆盖整份文件）：

```bash
sudo ./install.sh --add-rule 'DOMAIN-SUFFIX,openai.com,us'
sudo ./install.sh --add-ruleset 'https://example.com/openai.mrs' us
```

规则类型：`DOMAIN`、`DOMAIN-SUFFIX`、`DOMAIN-KEYWORD`、`IP-CIDR`、`GEOSITE`、`GEOIP`、`RULE-SET`、`FINAL`。

`RULE-SET` 支持 mihomo `.mrs`、Clash YAML 和纯文本列表（不支持旧 sing-box `.srs`）。类型按文件名自动推断，命名不明确时可在 URL 后加 `#domain` / `#ipcidr` / `#classical`。远程规则集由 mihomo 默认每 24 小时更新。

导入整份规则并按分类映射出口：

```bash
sudo ./install.sh --import-rules /path/to/rule.conf
sudo ./install.sh --set-policy Netflix hk
```

## Telegram Bot

```bash
export TG_BOT_TOKEN="123456:ABC-your-bot-token"
export TG_ADMIN_IDS="11111111,22222222"
sudo ./install.sh --setup-tgbot
```

不知道自己的数字 ID 时，先启用 Bot 后发送 `/id`，把返回的 ID 写入 `/opt/proxy-gateway/etc/tgbot.env` 并 `sudo systemctl restart proxy-gateway-tgbot`。

命令：`/start` 打开面板、`/status` 状态、`/exits` 出口、`/rules` 分流、`/cancel` 取消输入、`/id` 查 ID。

添加出口：`🌐 出口 -> ➕ 添加出口`，直接粘贴节点链接（`ss:// vmess:// trojan:// vless:// hysteria2:// tuic:// anytls:// socks5:// http://`），备注会自动作为出口名。

## 配置参考

### 仓库结构

```text
install.sh        # 安装/管理入口（唯一需要直接运行的脚本）
quick-install.sh  # 一键安装引导
lib/              # 组件源码与模板（tgbot、wa-shim、Go 代理、mosdns 模板等）
tests/            # 策略测试
```

### 关键路径

| 路径 | 说明 |
| --- | --- |
| `/opt/5gpn` | 项目目录（一键安装拉取） |
| `/opt/proxy-gateway` | 运行时主目录（含 `bin/proxy-gateway-ctl`、`bin/tgbot.py`、`bin/mihomo` 等） |
| `/opt/proxy-gateway/etc/current-exit` | 当前出口 |
| `/opt/proxy-gateway/etc/tgbot.env` | Bot Token 和管理员 ID（权限 600） |
| `/etc/mosdns/config.yaml` | mosdns 实际配置 |
| `/etc/mosdns/gfwlist-extra-local.txt` | 本地补充 GFWList 域名 |
| `/etc/sniproxy.conf` | sniproxy 配置（resolver 强制 `ipv4_only`） |

### 端口

| 端口 | 协议 | 范围 | 用途 |
| --- | --- | --- | --- |
| 53 | TCP/UDP | `172.22.0.0/16` | DNS |
| 80 | TCP | 私网（ACME 时临时公网） | HTTP 透明代理 / HTTP-01 |
| 443 | TCP | `172.22.0.0/16` | wa-shim（无 SNI / HTTPS fail-open 到 sniproxy 回环 8443） |
| 443 | UDP | `172.22.0.0/16` | QUIC 透明代理 |
| 853 | TCP | 公网 | DNS over TLS |
| 8111 | TCP | 公网 | iOS 描述文件下载 |

### 环境变量

```bash
DOMAIN="dns.example.com"        # DoT 域名（必需）
EMAIL="admin@example.com"       # ACME 邮箱
REMOTE_DNS="https://1.1.1.1/dns-query,udp://8.8.8.8:53"  # 国际 DoH 主路 + UDP fallback
LOCAL_DNS="https://223.5.5.5/dns-query,udp://119.29.29.29:53"  # 国内 DoH 主路 + UDP fallback
LOWMEM=1                        # 强制低内存模式（≤1GB 自动启用）
MIHOMO_VERSION="1.19.28"        # 可覆盖锁定版，建议保持默认
TG_BOT_TOKEN="123456:ABC"
TG_ADMIN_IDS="11111111,22222222"
FIREWALL_MODE=preserve          # preserve(默认)/auto/managed，见下方说明
PGW_TUNING=essential            # essential(默认)/performance 内核调优档位
```

旧兼容变量 `DNS_UPSTREAMS`、`OVERSEAS_DNS`、`PRIVATE_OVERSEAS_DNS`、`SNIPROXY_DNS` 等同于 `REMOTE_DNS`。

### 防火墙与内核调优

安装脚本默认**不接管**主机防火墙（`FIREWALL_MODE=preserve`）：只维护项目自己的
出口打标规则（`pgw_exit` 表），并提示需要放行的端口，不会覆盖 `/etc/nftables.conf`、
不会 `flush ruleset`、不会修改 INPUT 默认策略。

- `FIREWALL_MODE=auto`：在现有防火墙（UFW / firewalld / nftables / iptables）里
  **增量**放行所需端口，不清空任何已有规则。
- `FIREWALL_MODE=managed`：由项目完整接管 INPUT 防火墙（旧版行为），每次运行安装器都必须显式指定，历史标记不会自动启用。应用前会
  自动识别并放行**所有检测到的 SSH 端口**（当前会话端口、`sshd -T` 配置、实际
  监听端口的并集，检测失败才回落 22），校验新规则并备份原有
  `/etc/nftables.conf` 到 `/etc/nftables.conf.pgw-backup`。
- 从旧版本升级或重装也默认保持 `preserve`；历史标记不会自动触发 `managed`，
  避免覆盖用户后来添加的规则。

内核参数同理分档：默认 `PGW_TUNING=essential` 只设置网关必需项（转发、
`rp_filter`、可用时启用 BBR）；`PGW_TUNING=performance` 使用旧版激进吞吐调优
（大连接表、短超时等）。旧版本升级时沿用 performance，不会悄悄改变内核行为。

## 常见问题

**为什么内网客户端不返回 IPv6？** 透明代理路径按 IPv4 设计；只有 `172.22.0.0/16` 来源的 AAAA 返回 NOERROR/NODATA。Wi-Fi、公网及其他来源正常返回 IPv6。

**为什么国内网站直连？** ChinaList 域名由 mosdns 转发到国内主/备用 DNS 并携带国内 ECS，获得更适合大陆访问的结果。

**如何更新 DNS 规则？**

```bash
cd /opt/5gpn && sudo git pull && sudo ./install.sh --update-rules
```

**如何查看日志？** 相关服务：`mosdns`、`sniproxy`、`wa-shim`、`quic-proxy`、`proxy-gateway-tgbot`、`proxy-gateway-mihomo@*`，用 `systemctl status` / `journalctl -u <服务> -f` 查看。

**如何测试 DoT？**

```bash
dig +tls @dns.example.com -p 853 youtube.com
curl -I --resolve youtube.com:443:127.0.0.1 https://youtube.com
```

**证书签发失败？** 确认域名 A 记录指向服务器公网 IP 且 TCP 80 可被公网访问。签发/续期时脚本会临时停止 sniproxy 并放行公网 80，完成后恢复 80/443 白名单。

**从旧 sing-box 版本升级？** 内核级迁移：旧 sing-box 服务和二进制会被移除，旧配置备份到 `/etc/proxy-gateway/exits/singbox-backup/`。URI 出口需用原节点链接重新 `--add-exit`；`rules.conf` 和策略映射保留，出口补齐后重新 `--set-rules` / `--set-exit smart`。当前 WireGuard 出口不受影响。

**WhatsApp Patch 的风险控制？** wa-shim 仅对私网和 loopback 来源启用 ED/WA 分流；未知协议、TLS ClientHello、短包和超时都 fail-open 到 sniproxy；以 `pxout` 用户运行，跟随当前出口出站。

## 免责声明

本项目仅用于合法的网络互通、企业专网、测试和学习场景。使用者需自行确认部署和使用行为符合所在地法律法规、云服务商条款及目标网络服务条款。项目不保证在所有网络环境下可用，也不承诺规避封锁、审查或主动探测；因误用、配置错误、服务中断等造成的后果由使用者自行承担。
