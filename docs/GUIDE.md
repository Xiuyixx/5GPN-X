# 日常管理与配置参考

[返回首页](../README.md) · [安装、升级与排障](INSTALL.md)

先用 `sudo /opt/5gpn/bin/5gpn-ctl --status` 检查状态；完整参数可用 `--help` 查看。以下命令中的域名、出口名和节点链接请换成自己的值。

## 出口管理

默认出口为 `local`（本机公网 IP 直出）。

```bash
# WireGuard：导入你自己准备好的 WireGuard client 配置
sudo /opt/5gpn/bin/5gpn-ctl --add-exit us us.conf

# URI 出口
sudo /opt/5gpn/bin/5gpn-ctl --add-exit jp 'socks5://user:pass@1.2.3.4:1080'
sudo /opt/5gpn/bin/5gpn-ctl --add-exit hk 'ss://2022-blake3-aes-128-gcm:PASSWORD@5.6.7.8:443'

# 切换 / 验证
sudo /opt/5gpn/bin/5gpn-ctl --set-exit hk
curl --interface pgw-hk -4 -s https://api.ipify.org; echo
```

密码含特殊字符时可用多行输入避免 URL 转义：

```bash
printf 'socks5://1.2.3.4:1080
user: myuser
pass: my@p:ss/word
remote-dns: on
' | sudo /opt/5gpn/bin/5gpn-ctl --add-exit jp
```

当前出口记录在 `/opt/5gpn/etc/current-exit`，开机自动恢复。

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

sudo /opt/5gpn/bin/5gpn-ctl --set-rules rules.conf
sudo /opt/5gpn/bin/5gpn-ctl --set-exit smart
```

单独追加规则或规则集（不覆盖整份文件）：

```bash
sudo /opt/5gpn/bin/5gpn-ctl --add-rule 'DOMAIN-SUFFIX,openai.com,us'
sudo /opt/5gpn/bin/5gpn-ctl --add-ruleset 'https://example.com/openai.mrs' us
```

规则类型：`DOMAIN`、`DOMAIN-SUFFIX`、`DOMAIN-KEYWORD`、`IP-CIDR`、`GEOSITE`、`GEOIP`、`RULE-SET`、`FINAL`。

`RULE-SET` 支持 mihomo `.mrs`、Clash YAML 和纯文本列表（不支持旧 sing-box `.srs`）。类型按文件名自动推断，命名不明确时可在 URL 后加 `#domain` / `#ipcidr` / `#classical`。远程规则集由 mihomo 默认每 24 小时更新。

导入整份规则并按分类映射出口：

```bash
sudo /opt/5gpn/bin/5gpn-ctl --import-rules /path/to/rule.conf
sudo /opt/5gpn/bin/5gpn-ctl --set-policy Netflix hk
```

## Telegram Bot

```bash
sudo /opt/5gpn/bin/5gpn-ctl --setup-tgbot
```

按提示输入 Bot Token 和管理员数字 ID。可先通过 Telegram 的 ID 查询机器人获取自己的 ID；启用后也可向本 Bot 发送 `/id` 核对。不要公开 Token。已有配置会用于后续设置。

命令：`/start` 打开面板、`/status` 状态、`/exits` 出口、`/rules` 分流、`/cancel` 取消输入、`/id` 查 ID。

添加出口：`🌐 出口 -> ➕ 添加出口`，直接粘贴节点链接（`ss:// vmess:// trojan:// vless:// hysteria2:// tuic:// anytls:// socks5:// http://`），备注会自动作为出口名。

轮询进度持久化在 `/var/lib/5gpn/tgbot-state.json`（权限 600），服务重启后从断点继续；停机期间尚未确认的积压更新仍可能被处理。Telegram 的下一次 `getUpdates(offset)` 即确认更小 ID，并不是本地保存 offset 才确认。被 Telegram 限流（429）时按 `retry_after` 等待，其他轮询失败指数退避（上限 60s）。如需自定义状态文件路径，把 `TG_STATE_FILE` 写入 `/opt/5gpn/etc/tgbot.env` 后重启服务。

点击 iOS 二维码会先发送新图片，再删除主菜单；旧菜单超过 Telegram 删除时限时会改为无按钮的提示。返回时删除二维码并恢复主菜单，重启后仍可返回。超过删除时限或 API 拒绝时会清除二维码按钮并提示手动删除；网络故障也可能阻止清除按钮或恢复菜单，此时请重试 `/menu`。

## 配置参考

### 关键路径

| 路径 | 说明 |
| --- | --- |
| `/opt/5gpn-source` | 默认固定提交源码目录（与运行数据分离） |
| `/opt/5gpn` | 运行时主目录（`bin/5gpn-ctl`、`bin/tgbot.py`、`bin/mihomo` 等） |
| `/opt/5gpn/etc/current-exit` | 当前出口 |
| `/opt/5gpn/etc/tgbot.env` | Bot Token 和管理员 ID（权限 600） |
| `/var/lib/5gpn/tgbot-state.json` | tgbot 轮询断点，重启续传（权限 600） |
| `/etc/mosdns/config.yaml` | mosdns 实际配置 |
| `/etc/mosdns/gfwlist-extra-local.txt` | 本地补充 GFWList 域名 |
| `/etc/sniproxy.conf` | sniproxy 配置（resolver 强制 `ipv4_only`） |

### 端口

| 端口 | 协议 | 范围 | 用途 |
| --- | --- | --- | --- |
| 80 | TCP | 私网（ACME 时临时公网） | HTTP 透明代理 / HTTP-01 |
| 443 | TCP | `172.22.0.0/16` | wa-shim（无 SNI / HTTPS fail-open 到 sniproxy 回环 8443） |
| 443 | UDP | `172.22.0.0/16` | QUIC 透明代理 |
| 853 | TCP | 公网 | DNS over TLS |
| 8111 | TCP | 公网 | iOS 描述文件下载 |

### 环境变量

```bash
DOMAIN="dns.example.com"        # DoT 域名（必需）
EMAIL="admin@example.com"       # ACME 邮箱
REMOTE_DNS="1.1.1.1,8.8.8.8,9.9.9.9"     # 海外 DNS 池
LOCAL_DNS="101.226.4.6,218.30.118.6,180.76.76.76,119.29.29.29"  # 国内 DNS 竞速池（4路 UDP 并发）
LOWMEM=1                        # 强制低内存模式（≤1GB 自动启用）
MIHOMO_VERSION="1.19.28"        # 覆盖锁定版；非锁定版本跳过 sha256 校验（安装时 warn）
MOSDNS_VERSION="5.3.4"          # 覆盖锁定版；行为同 MIHOMO_VERSION
TG_BOT_TOKEN="123456:ABC"
TG_ADMIN_IDS="11111111,22222222"
TG_STATE_FILE="/var/lib/5gpn/tgbot-state.json"  # tgbot 轮询断点路径；自定义时写入 tgbot.env
FIREWALL_MODE=preserve          # preserve(默认)/auto/managed，见下方说明
PGW_TUNING=essential            # essential(默认)/performance 内核调优档位
```

旧兼容变量 `DNS_UPSTREAMS`、`OVERSEAS_DNS`、`PRIVATE_OVERSEAS_DNS`、`SNIPROXY_DNS` 等同于 `REMOTE_DNS`。DNS 上游统一使用纯 IP 或 `IP:53`；不接受 DoH/DoT 或其他协议前缀，避免不同 DNS 消费者产生不一致行为。

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

**为什么不返回 IPv6？** 当前透明代理路径按 IPv4 设计；所有来源的 AAAA 均返回 NOERROR/NODATA。这是保留既有行为，不会自动开放 IPv6 绕过代理。

**为什么国内网站直连？** ChinaList 域名由 mosdns 转发到 4 路国内 DNS 竞速代理（携带 ECS `139.226.48.0/24`），获得更适合大陆访问的结果。UDP 150ms 无响应后自动切 TCP，都不通才走海外兜底（含 `22.22.22.22`），避免单一国内 DNS 故障卡住页面。

**如何更新 DNS 规则？**

```bash
sudo /opt/5gpn/bin/5gpn-ctl --update-rules
```

**服务、证书或 DoT 出问题？** 先看 [安装与排障指南](INSTALL.md#5-失败排查)。

**从旧 sing-box 版本升级？** 内核级迁移：旧 sing-box 服务和二进制会被移除，旧配置备份到 `/etc/5gpn/exits/singbox-backup/`。URI 出口需用原节点链接重新 `--add-exit`；`rules.conf` 和策略映射保留，出口补齐后重新 `--set-rules` / `--set-exit smart`。当前 WireGuard 出口不受影响。

**WhatsApp Patch 的风险控制？** wa-shim 仅对私网和 loopback 来源启用 ED/WA 分流；未知协议、TLS ClientHello、短包和超时都 fail-open 到 sniproxy；以 `pxout` 用户运行，跟随当前出口出站。


## 运行原理

面向 5G NPN / N6 互通、私网终端出海和轻量透明代理场景：

- `172.22.0.0/16` 私网客户端把 DNS/DoT 指向网关。
- ChinaList 域名默认走国内 DNS 竞速代理（4 路 UDP 并发 + TCP fallback + 海外兜底含 `22.22.22.22`），保持本地访问体验。
- 私网客户端的 `push.apple.com` 及其子域优先返回海外 DNS 的真实地址，供设备直达 Apple TCP/5223（443 回退）；显式域名覆盖仍优先。不新增网关监听，不扩大为整个 `apple.com`。
- 内网来源其余非 ChinaList 的 A 查询返回服务器 IP，流量进入 TCP/QUIC 代理。
- 其他来源：被墙域名不劫持，正常海外解析；其他域名也正常海外解析。
- wa-shim / sniproxy / quic-proxy 负责 WhatsApp Noise、SNI/Host 和 QUIC 转发，出站由当前出口控制。
- 所有来源的 AAAA 查询返回 NOERROR/NODATA，保持现有 IPv4-only 透明代理策略，避免 IPv6 绕过代理。
- 国内 DNS 三层 fallback：UDP 竞速（4 路）→ 150ms 超时后 TCP 竞速 → 都不通时海外兜底（1.1.1.1、8.8.8.8、22.22.22.22）。国际 DNS primary/secondary fallback。

支持的出口：本机直出、WireGuard、SOCKS5/SOCKS5H、SS/SS2022、VMess、Trojan、VLESS、Hysteria2、TUIC、AnyTLS、HTTP/HTTPS。URI 类出口由锁定版 mihomo `1.19.28` 提供 TUN 出口和智能分流。

出口切换基于 `ip rule fwmark` + 独立路由表，只影响代理进程出站，不影响 SSH、DNS、证书续期。

### 组件能力

- 加密 DNS：客户端统一通过 DoT 853 接入；mosdns 不监听本机 53，因此不会与 `systemd-resolved` 冲突。来源 IP 按段区分解析策略，海外 DNS 池 `1.1.1.1`、`8.8.8.8`、`9.9.9.9`，ChinaList 查询携带 ECS `139.226.48.0/24`；所有来源过滤 AAAA（IPv4-only）。
- iOS WhatsApp Patch：wa-shim 监听 TCP 443，仅分流客户端网段内 `ED`/`WA` 开头的无 SNI Noise 连接，其余 fail-open 交给 sniproxy。
- 智能分流：mihomo `smart` 出口按域名 / IP / GEOSITE / GEOIP / RULE-SET 分流，远程规则集自动更新。
- Telegram Bot：状态、出口管理、分流规则、DNS/DoT 设置、日志、iOS 二维码。
- 供应链校验：mihomo / mosdns 二进制从官方 release 下载并锁定 sha256 校验，不匹配即中止安装。
- 低内存模式：≤ 1 GB 内存自动降低缓存与内核参数，512 MB VPS 可运行。

